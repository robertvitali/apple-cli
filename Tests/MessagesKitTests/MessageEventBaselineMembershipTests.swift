import Foundation
import SQLite3
import Testing
@testable import MessagesKit

struct MessageEventBaselineMembershipTests {
    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    private func withJournal(_ body: (OpaquePointer, MessageEventJournalSchema) throws -> Void) throws {
        var raw: OpaquePointer?
        try #require(sqlite3_open(":memory:", &raw) == SQLITE_OK)
        let db = try #require(raw)
        defer { #expect(sqlite3_close(db) == SQLITE_OK) }
        try execute(db, """
            CREATE TABLE baseline(message_rowid,chat_rowid,message_guid,chat_guid);
            CREATE INDEX baseline_locator ON baseline(message_rowid,chat_rowid)
            """)
        try body(db, MessageEventJournalSchema(database: db,
            prepare: { sqlite3_prepare_v2($0, $1, -1, &$2, nil) }, step: sqlite3_step))
    }

    @Test func allowsSharedMessagesAndSeparateChatsWithByteExactGUIDs() throws {
        try withJournal { db, schema in
            let selected = try MessageEventFilter(conversations: ["é", "e\u{301}"])
            try execute(db, """
                BEGIN IMMEDIATE;
                INSERT INTO baseline VALUES(5,7,x'6D',x'C3A9'),(5,3,x'6D',x'65CC81'),
                  (9223372036854775807,9223372036854775807,x'7A',x'C3A9')
                """)
            try schema.validateBaselineMemberships(filter: selected, expectedCount: 3, checkpoint: {})
            try execute(db, "COMMIT; BEGIN; SELECT * FROM baseline LIMIT 1")
            try schema.validateBaselineMemberships(filter: selected, expectedCount: 3, checkpoint: {})
            let one = try MessageEventFilter(conversations: ["é"])
            #expect(throws: MessageEventJournalSchema.MembershipFailure.invalidMembership) {
                try schema.validateBaselineMemberships(filter: one, expectedCount: 3, checkpoint: {})
            }
        }
    }

    @Test(arguments: ["(1,2,x'7A',x'62')", "(1,2,x'C3A9',x'61')", "(1,3,x'65CC81',x'62')",
                      "(0,3,x'61',x'62')", "(2,-1,x'61',x'62')", "('2',3,x'61',x'62')",
                      "(2,2,'a',x'62')", "(2,2,x'61',zeroblob(1025))"])
    func refusesImpossibleLocatorsAndStorage(values: String) throws {
        try withJournal { db, schema in
            try execute(db, "BEGIN IMMEDIATE; INSERT INTO baseline VALUES(1,2,x'C3A9',x'61')," + values)
            #expect(throws: MessageEventJournalSchema.MembershipFailure.invalidMembership) {
                try schema.validateBaselineMemberships(filter: MessageEventFilter(conversations: nil), expectedCount: 2, checkpoint: {})
            }
        }
    }

    @Test func refusesUnpinnedReadsAndChecksDeadlinesAtEachMembership() throws {
        enum Stop: Error { case now }
        try withJournal { db, schema in
            let filter = try MessageEventFilter(conversations: nil)
            for begin in ["", "BEGIN"] {
                if !begin.isEmpty { try execute(db, begin) }
                #expect(throws: MessageEventReplayReader.Failure.snapshotRequired) {
                    try schema.validateBaselineMemberships(filter: filter, expectedCount: 2, checkpoint: {})
                }
            }
            try execute(db, "ROLLBACK; BEGIN IMMEDIATE; INSERT INTO baseline VALUES(1,1,x'61',x'62'),(1,2,x'61',x'63')")
            for count: Int64 in [-1, 0, 1, 3] {
                #expect(throws: MessageEventJournalSchema.MembershipFailure.invalidMembership) {
                    try schema.validateBaselineMemberships(filter: filter, expectedCount: count, checkpoint: {})
                }
            }
            #expect(throws: MessageEventStateDigest.Failure.limitExceeded) {
                try schema.validateBaselineMemberships(filter: filter, expectedCount: .max, checkpoint: {})
            }
            for limit in 1...4 {
                var calls = 0
                #expect(throws: Stop.now) {
                    try schema.validateBaselineMemberships(filter: filter, expectedCount: 2) {
                        calls += 1
                        if calls == limit { throw Stop.now }
                    }
                }
                #expect(calls == limit)
            }
        }
    }
}
