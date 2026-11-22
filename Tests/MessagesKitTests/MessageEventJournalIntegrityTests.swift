import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import MessagesKit

struct MessageEventJournalIntegrityTests {
    private typealias Schema = MessageEventJournalSchema
    private let digest = Data(repeating: 0, count: 32)
    private let integritySQL = "PRAGMA main.integrity_check(1)"

    /// Use a real statement for each query and record which checks reached SQLite.
    private func withJournal(_ body: (OpaquePointer, Schema, () -> [String]) throws -> Void) throws {
        var raw: OpaquePointer?
        try #require(sqlite3_open(":memory:", &raw) == SQLITE_OK)
        let db = try #require(raw)
        defer { #expect(sqlite3_close(db) == SQLITE_OK) }
        try execute(db, "CREATE TABLE meta(id INTEGER PRIMARY KEY, state_digest BLOB)")
        try execute(db, "INSERT INTO meta VALUES(1, zeroblob(32))")
        try execute(db, "BEGIN")
        var queries: [String] = []
        let schema = Schema(database: db, prepare: { db, sql, statement in
            queries.append(sql)
            return sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        }, step: sqlite3_step)
        try body(db, schema, { queries })
    }

    private var budget: Schema.IntegrityBudget {
        .init(deadline: .now.advanced(by: .seconds(5)), restoreProgressHandler: {})
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func lostCursorRequiresAnIntactPinnedJournal() throws {
        let stream = UUID().uuidString.lowercased()
        let filter = try MessageEventFilter(conversations: nil)
        let metadata = try PersistedEventMetadata(format: 1, initialized: 1, stream: Data(stream.utf8),
            source: Data(stream.utf8), filterBytes: filter.canonicalBytes, filterDigest: Data(SHA256.hash(data: filter.canonicalBytes)),
            generation: 2, head: 2)
        let expired = try MessageEventCursor(stream: metadata.stream, filter: filter.digest, sequence: 0)
        let boundary = try MessageEventCursor(stream: metadata.stream, filter: filter.digest, sequence: 1)
        try withJournal { db, schema, _ in
            try execute(db, "CREATE TABLE events(sequence INTEGER PRIMARY KEY CHECK(sequence > 0))")
            try execute(db, "INSERT INTO events VALUES(2)")
            try schema.validateReplayCursor(boundary, metadata: metadata, budget: budget)
            #expect(throws: MessageEventCursorFailure.expired) {
                try schema.validateReplayCursor(expired, metadata: metadata, budget: budget)
            }
            let stopped = Schema.IntegrityBudget(deadline: .now, restoreProgressHandler: {})
            #expect(throws: Schema.IntegrityBudgetFailure.deadline) {
                try schema.validateReplayCursor(expired, metadata: metadata, budget: stopped)
            }
            try execute(db, "PRAGMA ignore_check_constraints=ON")
            try execute(db, "INSERT INTO events VALUES(-1)")
            try execute(db, "PRAGMA ignore_check_constraints=OFF")
            #expect(throws: Schema.IntegrityFailure.invalidPages) {
                try schema.validateReplayCursor(expired, metadata: metadata, budget: budget)
            }
            try execute(db, "ROLLBACK")
            #expect(throws: MessageEventReplayReader.Failure.snapshotRequired) {
                try schema.validateReplayCursor(boundary, metadata: metadata, budget: budget)
            }
        }
    }

    @Test func rowValidationPrecedesPhysicalCheckAndPropagatesRefusal() throws {
        enum Limit: Error { case exceeded }
        try withJournal { _, schema, queries in
            #expect(throws: Limit.exceeded) {
                try schema.verifiedStateDigest(budget: budget) { throw Limit.exceeded }
            }
            #expect(throws: Schema.IntegrityFailure.invalidDigest) {
                try schema.verifiedStateDigest(budget: budget) { Data(repeating: 1, count: 32) }
            }
            #expect(!queries().contains(integritySQL))
            let verified = try schema.verifiedStateDigest(budget: budget) { digest }
            #expect(verified == digest && queries().last == integritySQL)
        }
    }

    @Test(arguments: ["DELETE FROM meta", "UPDATE meta SET state_digest=zeroblob(31)",
                      "UPDATE meta SET state_digest=hex(zeroblob(16))"])
    func invalidStoredDigestRefusesBeforeScanning(sql: String) throws {
        try withJournal { db, schema, queries in
            try execute(db, sql)
            #expect(throws: Schema.IntegrityFailure.invalidDigest) {
                try schema.verifiedStateDigest(budget: budget) { Issue.record("unexpected scan"); return digest }
            }
            #expect(!queries().contains(integritySQL))
        }
    }

    @Test func matchingDigestStillRequiresAnIntactDatabase() throws {
        try withJournal { db, schema, _ in
            try execute(db, "CREATE TABLE bounded(n INTEGER CHECK(n>0))")
            try execute(db, "PRAGMA ignore_check_constraints=ON")
            try execute(db, "INSERT INTO bounded VALUES(-1)")
            try execute(db, "PRAGMA ignore_check_constraints=OFF")
            #expect(throws: Schema.IntegrityFailure.invalidPages) {
                try schema.verifiedStateDigest(budget: budget) { digest }
            }
        }
    }

    @Test func physicalWorkLimitPreservesJournalAndRestoresCallerGuard() throws {
        try withJournal { db, schema, _ in
            try execute(db, "CREATE TABLE sample(n INTEGER PRIMARY KEY, value TEXT CHECK(length(value)>0))")
            try execute(db, "WITH RECURSIVE c(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM c WHERE n<4096) INSERT INTO sample SELECT n,'x' FROM c")
            // Commit the fixture before the read snapshot so an interrupt cannot
            // roll back the test data. A subsequent read must see all its rows.
            try execute(db, "COMMIT")
            try execute(db, "BEGIN")
            let guarded = Schema.IntegrityBudget(deadline: budget.deadline, maximumCallbacks: 1,
                restoreProgressHandler: { sqlite3_progress_handler(db, 1, { _ in 1 }, nil) })
            #expect(throws: Schema.IntegrityBudgetFailure.capacity) {
                try schema.verifiedStateDigest(budget: guarded) { digest }
            }
            #expect(sqlite3_exec(db, "SELECT count(*) FROM sample", nil, nil, nil) == SQLITE_INTERRUPT)
            sqlite3_progress_handler(db, 0, nil, nil)
            #expect(try schema.verifiedStateDigest(budget: budget) { digest } == digest)
            try schema.rows("SELECT count(*) FROM sample") { #expect(sqlite3_column_int64($0, 0) == 4096) }
        }
    }

    @Test func expiredAndCancelledChecksRefuseBeforePreparingPageCheck() throws {
        try withJournal { _, schema, queries in
            let expired = Schema.IntegrityBudget(deadline: .now, restoreProgressHandler: {})
            #expect(throws: Schema.IntegrityBudgetFailure.deadline) { try schema.verifyPageIntegrity(budget: expired) }
            var stopped = budget
            stopped.isCancelled = { true }
            #expect(throws: Schema.IntegrityBudgetFailure.cancelled) { try schema.verifyPageIntegrity(budget: stopped) }
            #expect(!queries().contains(integritySQL))
        }
    }
}
