import SQLite3
import Testing
@testable import MessagesKit

struct MessageEventJournalLimitsTests {
    private func withDatabase(_ body: (OpaquePointer) throws -> Void) throws {
        var raw: OpaquePointer?
        try #require(sqlite3_open(":memory:", &raw) == SQLITE_OK)
        let database = try #require(raw)
        defer { #expect(sqlite3_close(database) == SQLITE_OK) }
        try body(database)
    }

    @Test func limitsOversizedValuesAndEncodedRowsOnThisConnection() throws {
        try withDatabase { db in
            try withDatabase { other in
                let independent = sqlite3_limit(other, SQLITE_LIMIT_LENGTH, -1)
                try MessageEventJournalLimits.configure(db)
                #expect(sqlite3_limit(other, SQLITE_LIMIT_LENGTH, -1) == independent)
                let limit = MessageEventJournalLimits.sqliteLength
                #expect(sqlite3_limit(db, SQLITE_LIMIT_LENGTH, -1) == limit)
                #expect(sqlite3_exec(db, "SELECT zeroblob(\(limit))", nil, nil, nil) == SQLITE_OK)
                #expect(sqlite3_exec(db, "SELECT zeroblob(\(limit + 1))", nil, nil, nil) == SQLITE_TOOBIG)
                #expect(sqlite3_exec(db, "CREATE TABLE data(a,b)", nil, nil, nil) == SQLITE_OK)
                #expect(sqlite3_exec(db, "INSERT INTO data VALUES(zeroblob(263174),zeroblob(256))", nil, nil, nil) == SQLITE_OK)
                #expect(sqlite3_exec(db, "INSERT INTO data VALUES(zeroblob(262144),zeroblob(262144))", nil, nil, nil) == SQLITE_TOOBIG)
            }
        }
    }

    @Test func captureCountAllowsTheLastEventAndRejectsTheNext() throws {
        var window = MessageEventJournalLimits.CaptureWindow()
        for _ in 0..<100_000 { window = try window.appending(payloadSize: 1) }
        #expect(window.eventCount == 100_000)
        #expect(throws: MessageEventCaptureLimit.captureEvents) { try window.appending(payloadSize: 1) }
    }

    @Test func captureBytesAdmitTheLastByteWithoutOverflowingOnExcess() throws {
        var window = MessageEventJournalLimits.CaptureWindow()
        for _ in 0..<1_023 { window = try window.appending(payloadSize: 65_536) }
        window = try window.appending(payloadSize: 65_535)
        #expect(throws: MessageEventCaptureLimit.captureEventBytes) { try window.appending(payloadSize: .max) }
        #expect(throws: MessageEventDelivery.Failure.invalidRecord) { try window.appending(payloadSize: 0) }
        window = try window.appending(payloadSize: 1)
        #expect(window.payloadBytes == 64 << 20)
        #expect(throws: MessageEventCaptureLimit.captureEventBytes) { try window.appending(payloadSize: 1) }
    }

    @Test func oversizedStoredValueFailsBeforeReturningARow() throws {
        try withDatabase { db in
            let size = MessageEventJournalLimits.sqliteLength + 1
            try #require(sqlite3_exec(db, "CREATE TABLE events(payload); INSERT INTO events VALUES(zeroblob(\(size)))",
                                      nil, nil, nil) == SQLITE_OK)
            try MessageEventJournalLimits.configure(db)
            var statement: OpaquePointer?
            try #require(sqlite3_prepare_v2(db, "SELECT payload FROM events", -1, &statement, nil) == SQLITE_OK)
            #expect(sqlite3_step(statement) == SQLITE_TOOBIG)
            #expect(sqlite3_finalize(statement) == SQLITE_TOOBIG)
            #expect(sqlite3_exec(db, "SELECT 1", nil, nil, nil) == SQLITE_OK)
        }
    }

    @Test func preservesLowerLimitsAndRequiresAnUnusedConnection() throws {
        try withDatabase { db in
            sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 32768)
            try MessageEventJournalLimits.configure(db)
            #expect(sqlite3_limit(db, SQLITE_LIMIT_LENGTH, -1) == 32768)
            var statement: OpaquePointer?
            try #require(sqlite3_prepare_v2(db, "SELECT 1", -1, &statement, nil) == SQLITE_OK)
            #expect(throws: MessageEventJournalLimits.Failure.activeConnection) { try MessageEventJournalLimits.configure(db) }
            try #require(sqlite3_finalize(statement) == SQLITE_OK)
            try #require(sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK)
            #expect(throws: MessageEventJournalLimits.Failure.activeConnection) { try MessageEventJournalLimits.configure(db) }
            #expect(sqlite3_exec(db, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        }
    }
}
