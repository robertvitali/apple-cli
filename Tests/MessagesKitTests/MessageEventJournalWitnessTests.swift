import Foundation
import SQLite3
import Testing
@testable import MessagesKit

struct MessageEventJournalWitnessTests {
    private func withSchema(_ body: (MessageEventJournalSchema) throws -> Void) throws {
        var raw: OpaquePointer?
        try #require(sqlite3_open(":memory:", &raw) == SQLITE_OK)
        let db = try #require(raw)
        defer { #expect(sqlite3_close(db) == SQLITE_OK) }
        try body(MessageEventJournalSchema(database: db, prepare: { sqlite3_prepare_v2($0, $1, -1, &$2, nil) }, step: sqlite3_step))
    }

    @Test func requiresPinnedSnapshot() throws {
        try withSchema { schema in
            for sql in ["", "BEGIN"] {
                try #require(sqlite3_exec(schema.database, sql, nil, nil, nil) == SQLITE_OK)
                #expect(throws: MessageEventReplayReader.Failure.snapshotRequired) {
                    try schema.stateWitness(domain: "test") {}
                }
            }
        }
    }

    @Test func rejectsInvalidSourceBeforeReturningWitness() throws {
        try withSchema { schema in
            let db = schema.database
            func execute(_ sql: String) throws { try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
            try execute("BEGIN")
            for sql in MessageEventJournalFormat.createMain { try execute(sql) }
            try execute("INSERT INTO meta VALUES(1,1,1,zeroblob(36),zeroblob(36),zeroblob(6),zeroblob(32),zeroblob(29),zeroblob(32),3,7,zeroblob(32))")
            #expect(throws: PersistedEventMetadataFailure.invalidMetadata) {
                try schema.stateWitness(domain: "test") {}
            }
            try execute("UPDATE meta SET source_identity=x'0100000000000000010000000000000002000000000000000300000004'")
            let first = try schema.stateWitness(domain: "test") {}
            #expect(first.generation == 3 && first.head == 7 && first.memberships == 0 && first.events == 0)
            try execute("UPDATE meta SET state_digest=zeroblob(32),source_identity=x'0100000000000000010000000000000002000000000000000300000005'")
            let second = try schema.stateWitness(domain: "test") {}
            #expect(second.digest != first.digest)
            enum Interrupted: Error { case stopped }
            #expect(throws: Interrupted.stopped) {
                try schema.stateWitness(domain: "test") { throw Interrupted.stopped }
            }
            #expect(sqlite3_next_stmt(db, nil) == nil)
        }
    }
}
