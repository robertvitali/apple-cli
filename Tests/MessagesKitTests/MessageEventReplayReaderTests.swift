import CryptoKit
import Foundation
import SQLite3
import TestSupport
import Testing
@testable import MessagesKit

struct MessageEventReplayReaderTests {
    private let scratch = ScratchDirs("event-replay-reader")

    private typealias Reader = MessageEventReplayReader

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    private func pin(_ db: OpaquePointer) throws {
        try execute(db, "BEGIN; SELECT sequence FROM events LIMIT 1")
    }

    private func withDatabase(_ body: (OpaquePointer, MessageEventJournalSchema) throws -> Void) throws {
        var raw: OpaquePointer?
        try #require(sqlite3_open(":memory:", &raw) == SQLITE_OK)
        let db = try #require(raw)
        defer { #expect(sqlite3_close(db) == SQLITE_OK) }
        let schema = MessageEventJournalSchema(database: db, prepare: { sqlite3_prepare_v2($0, $1, -1, &$2, nil) },
                                               step: sqlite3_step)
        try execute(db, "CREATE TABLE events(sequence INTEGER PRIMARY KEY, payload BLOB)")
        try body(db, schema)
    }

    @Test func replayRevalidatesAfterReadyBeforeWritingAnyEvent() throws {
        enum Drift: Error { case lease }
        try withDatabase { db, schema in
            try execute(db, "INSERT INTO events VALUES(1,x'FF')")
            try pin(db)
            let reader = try Reader(journal: schema)
            var ready = false, emitted: [Int64] = []
            #expect(throws: Drift.lease) {
                try reader.replay(after: 0, through: 1, checkpoint: {}, validateLease: {
                    if ready { throw Drift.lease }
                }, beginSnapshot: { try pin(db) }, releaseSnapshot: { try execute(db, "COMMIT") },
                onReady: {
                    #expect(sqlite3_txn_state(db, "main") == SQLITE_TXN_NONE)
                    ready = true
                }, write: { emitted.append($0.sequence) })
            }
            #expect(ready && emitted.isEmpty)
        }
    }

    @Test(arguments: [0, 1, 64, 65, 129])
    func replayReleasesEveryPageAndSignalsReadinessOnce(count: Int) throws {
        try withDatabase { db, schema in
            for i in 0..<count { try execute(db, "INSERT INTO events VALUES(\(i + 1),x'01')") }
            try pin(db)
            let reader = try Reader(journal: schema)
            var opened = 1, released = 0, controls = 0, sequences: [Int64] = []
            let last = try reader.replay(after: 0, through: Int64(count), checkpoint: {}, validateLease: {}, beginSnapshot: {
                opened += 1
                try pin(db)
            }, releaseSnapshot: {
                try execute(db, "COMMIT")
                released += 1
            }, onReady: {
                #expect(released == 1 && sequences.isEmpty)
                controls += 1
            }, write: { row in
                #expect(controls == 1 && sqlite3_txn_state(db, "main") == SQLITE_TXN_NONE)
                sequences.append(row.sequence)
            })
            #expect(last == Int64(count))
            #expect(sequences == (0..<count).map { Int64($0 + 1) })
            #expect(controls == 1 && opened == max(1, (count + 63) / 64) && released == opened)
        }
    }

    private func metadata(head: Int64) throws -> PersistedEventMetadata {
        let filter = try MessageEventFilter(conversations: ["selected"])
        return try PersistedEventMetadata(format: 1, initialized: 1,
            stream: Data("01234567-89ab-cdef-0123-456789abcdef".utf8),
            source: Data("00000000-0000-0000-0000-000000000001".utf8),
            filterBytes: filter.canonicalBytes, filterDigest: Data(SHA256.hash(data: filter.canonicalBytes)),
            generation: 1, head: head)
    }

    private func insertEvent(_ db: OpaquePointer, metadata: PersistedEventMetadata,
                             sequence: Int64, storedSequence: Int64? = nil) throws {
        let projection = #"{"version":1,"date_edited":null,"date_retracted":null,"association":{"target_status":"unresolved","target_message_guid":null,"target_part":null,"native_type":null,"actor_kind":"unknown","supported":false}}"#
        let payload = try MessageEventDelivery.Reader(metadata: metadata).encode(
            sequence: storedSequence ?? sequence, observedAt: "2024-02-29T23:59:59Z", captureMode: "poll",
            conversation: MessageEventGUID("selected"), message: MessageEventGUID("synthetic"), rowID: 1,
            changes: ["content"], availability: Data(repeating: 0, count: 8), projection: Data(projection.utf8))
        let hex = payload.map { String(format: "%02x", $0) }.joined()
        try execute(db, "INSERT INTO events VALUES(\(sequence),x'\(hex)')")
    }

    @Test func retainedWindowSharesReadAndWriteSnapshotRules() throws {
        try withDatabase { db, schema in
            let meta = try metadata(head: .max)
            func oldest() throws -> Int64? {
                try schema.validatedOldestSequence(metadata: meta, checkpoint: {})
            }
            #expect(throws: Reader.Failure.snapshotRequired) { try oldest() }
            try execute(db, "BEGIN")
            #expect(throws: Reader.Failure.snapshotRequired) { try oldest() }
            try execute(db, "SELECT sequence FROM events")
            #expect(try oldest() == nil)
            try execute(db, "ROLLBACK; BEGIN IMMEDIATE")
            try insertEvent(db, metadata: meta, sequence: .max - 2)
            #expect(throws: Reader.Failure.invalidSequence) { try oldest() }
            try insertEvent(db, metadata: meta, sequence: .max)
            #expect(throws: Reader.Failure.invalidSequence) { try oldest() }
            try insertEvent(db, metadata: meta, sequence: .max - 1)
            #expect(try oldest() == Int64.max - 2)
            try execute(db, "COMMIT")
            try pin(db)
            #expect(try oldest() == Int64.max - 2)
        }
    }

    @Test func retainedWindowPollsBeforeEachDecodeAndAtCompletion() throws {
        enum Stop: Error { case interrupted }
        try withDatabase { db, schema in
            let meta = try metadata(head: 3)
            for i: Int64 in 1...3 { try insertEvent(db, metadata: meta, sequence: i) }
            try pin(db)
            for stopAt in 1...5 {
                var checks = 0
                #expect(throws: Stop.interrupted) {
                    try schema.validatedOldestSequence(metadata: meta) {
                        checks += 1
                        if checks == stopAt { throw Stop.interrupted }
                    }
                }
                #expect(checks == stopAt)
            }
        }
    }

    @Test func refusesMalformedEarlierEventsEvenWithAValidLastEvent() throws {
        try withDatabase { db, schema in
            let meta = try metadata(head: 2)
            try insertEvent(db, metadata: meta, sequence: 1, storedSequence: 2)
            try insertEvent(db, metadata: meta, sequence: 2)
            try execute(db, "BEGIN IMMEDIATE")
            #expect(throws: MessageEventDelivery.Failure.invalidRecord) {
                try schema.validatedOldestSequence(metadata: meta, checkpoint: {})
            }
            for value in ["NULL", "'wrong type'", "zeroblob(0)", "zeroblob(65537)"] {
                try execute(db, "UPDATE events SET payload=" + value + " WHERE sequence=1")
                #expect(throws: Reader.Failure.invalidPayload) {
                    try schema.validatedOldestSequence(metadata: meta, checkpoint: {})
                }
            }
        }
    }

    @Test func readsThroughBothPageLimitsWithoutSkippingARow() throws {
        try withDatabase { db, schema in
            try execute(db, """
                WITH RECURSIVE n(v) AS (SELECT 1 UNION ALL SELECT v+1 FROM n WHERE v<70)
                INSERT INTO events SELECT v, zeroblob(CASE WHEN v<=2 THEN 65536 ELSE 1 END) FROM n
                """)
            try pin(db)
            let reader = try Reader(journal: schema)
            var last: Int64 = 0
            for expectedCount in [2, 64, 4, 0] {
                let page = try reader.page(after: last, through: 70, checkpoint: {}) { try execute(db, "COMMIT") }
                #expect(page.count == expectedCount)
                for row in page {
                    last += 1
                    #expect(row.sequence == last)
                    #expect(row.payload == Data(repeating: 0, count: last <= 2 ? 65536 : 1))
                }
                #expect(sqlite3_get_autocommit(db) == 1)
                try pin(db)
            }
            #expect(last == 70)
        }
    }

    @Test(arguments: ["(2,x'00')", "(1,x'00')", "(1,NULL)", "(1,'text')", "(1,x'')", "(1,zeroblob(65537))"])
    func refusesGapsAndMalformedPayloadsBeforeRelease(values: String) throws {
        try withDatabase { db, schema in
            try execute(db, "INSERT INTO events VALUES " + values)
            try pin(db)
            let reader = try Reader(journal: schema)
            let expected: Reader.Failure = ["(2,x'00')", "(1,x'00')"].contains(values) ? .invalidSequence : .invalidPayload
            #expect(throws: expected) {
                _ = try reader.page(after: 0, through: 2, checkpoint: {}) { Issue.record("Released malformed page") }
            }
        }
    }

    @Test func requiresAPinnedReadAndAConfirmedRelease() throws {
        try withDatabase { db, schema in
            #expect(throws: Reader.Failure.snapshotRequired) { try Reader(journal: schema) }
            try execute(db, "BEGIN")
            #expect(throws: Reader.Failure.snapshotRequired) { try Reader(journal: schema) }
            try execute(db, "SELECT sequence FROM events")
            let reader = try Reader(journal: schema)
            #expect(throws: Reader.Failure.snapshotStillOpen) {
                _ = try reader.page(after: 0, through: 0, checkpoint: {}, releaseSnapshot: {})
            }
            try execute(db, "ROLLBACK; BEGIN IMMEDIATE")
            #expect(throws: Reader.Failure.snapshotRequired) { try Reader(journal: schema) }
        }
    }

    @Test func detectsExternalCommitAtReleaseEvenForAnEmptyPage() throws {
        let path = try scratch.directory().appendingPathComponent("replay.sqlite")
        var read: OpaquePointer?, write: OpaquePointer?
        defer {
            sqlite3_close(read)
            sqlite3_close(write)
        }
        try #require(sqlite3_open(path.path, &read) == SQLITE_OK)
        try #require(sqlite3_open(path.path, &write) == SQLITE_OK)
        let db = try #require(read), other = try #require(write)
        try execute(other, "CREATE TABLE events(sequence INTEGER PRIMARY KEY, payload BLOB)")
        try pin(db)
        let reader = try Reader(journal: .init(database: db, prepare: { sqlite3_prepare_v2($0, $1, -1, &$2, nil) },
                                               step: sqlite3_step))
        #expect(throws: Reader.Failure.journalChanged) {
            _ = try reader.page(after: 0, through: 0, checkpoint: {}) {
                try execute(db, "COMMIT")
                try execute(other, "INSERT INTO events VALUES(1,x'FF')")
            }
        }
    }
}
