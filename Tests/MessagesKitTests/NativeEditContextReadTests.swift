import Foundation
import Testing
import AppleKit
@testable import MessagesKit

@Suite struct NativeEditContextReadTests {
    private let columns = ["date_edited", "date_retracted", "message_summary_info"]

    private func fixture(columns present: [String]) throws -> ChatFixture {
        let fixture = try ChatFixture()
        for column in present { try fixture.exec("ALTER TABLE message ADD COLUMN \(column)") }
        return fixture
    }

    private func database(_ fixture: ChatFixture) throws -> ChatDB {
        try ChatDB(path: fixture.path, book: AddressBook(contacts: [:]), copyToTemp: false,
                   homeDirectoryForTilde: fixture.homePath)
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private func syntheticSummary() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["ep": [0], "rp": [Int](), "ec": [String: Any]()],
                                            format: .binary, options: 0)
    }

    private func installSummary(_ data: Data, in fixture: ChatFixture, rowid: Int = 1) throws {
        // Data is generated in this test, never sampled from a Messages store.
        let hex = data.map { String(format: "%02x", $0) }.joined()
        try fixture.exec("UPDATE message SET message_summary_info=X'\(hex)' WHERE ROWID=\(rowid)")
    }

    @Test func optionalSchemaAndNullsAreIndependent() throws {
        for present in [[]] + columns.map({ [$0] }) {
            let fixture = try fixture(columns: present)
            var db = try database(fixture)
            let message = try db.exactGet(chat: .rowid(3), message: .rowid(1), includeNativeEditContext: true).1
            let context = try json(message.native_edit_context)
            #expect(Set(context.keys) == ["date_edited", "date_retracted", "summary_info"])
            for column in ["date_edited", "date_retracted"] {
                let date = try #require(context[column] as? [String: Any])
                #expect(date["status"] as? String == (present.contains(column) ? "null" : "missing-schema"))
                #expect(date["raw"] is NSNull)
                #expect(date["date"] is NSNull)
            }
            let summary = message.native_edit_context.summary_info
            #expect(summary.status == (present.contains("message_summary_info") ? "null" : "missing-schema"))
            #expect(summary.edit_history.entries == nil)
            #expect(summary.edit_history.reason == summary.status)
            #expect(message.body == "hello from friend")
        }
    }

    @Test(arguments: ["'invalid'", "CAST(X'ff' AS TEXT)", "1.5", "17", "CAST(zeroblob(2097152) AS TEXT)"])
    func wrongSummaryTypesNeverFetchOrDecodePayloads(_ value: String) throws {
        let fixture = try fixture(columns: columns)
        try fixture.exec("UPDATE message SET message_summary_info=\(value),date_edited=1,date_retracted=0 WHERE ROWID=1")
        var db = try database(fixture)
        var fetches = 0
        db.beforeNativeEditSummaryRead = { fetches += 1 }
        let message = try db.exactGet(chat: .rowid(3), message: .rowid(1), includeNativeEditContext: true).1
        #expect(fetches == 0)
        #expect(message.native_edit_context.summary_info.status == "wrong-type")
        #expect(message.native_edit_context.date_edited.status == "available")
        #expect(message.native_edit_context.date_retracted.status == "zero-sentinel")
    }

    @Test func defaultExactReadsSkipAllSummaryWork() throws {
        let fixture = try fixture(columns: columns)
        try installSummary(syntheticSummary(), in: fixture)
        var db = try database(fixture)
        var fetches = 0
        db.beforeNativeEditSummaryRead = { fetches += 1 }
        let message = try db.exactGet(chat: .rowid(3), message: .rowid(1)).1
        let page = try db.exactHistory(chat: .rowid(3), limit: 1, order: .desc, cursor: nil)
        #expect(fetches == 0)
        #expect(message.native_edit_context.summary_info.status == "not-requested")
        #expect(page.items.allSatisfy { $0.native_edit_context.summary_info.status == "not-requested" })
        let enriched = try db.exactGet(chat: .rowid(3), message: .rowid(1), includeNativeEditContext: true).1
        #expect(fetches == 1)
        #expect(enriched.native_edit_context.summary_info.status == "available")
        #expect(enriched.native_edit_context.summary_info.edited_parts.entries?.first?.original_part_index == 0)
    }

    @Test func historyNeverFetchesLookaheadAndMatchesGet() throws {
        let fixture = try fixture(columns: columns)
        for rowid in [1, 2, 3] { try installSummary(syntheticSummary(), in: fixture, rowid: rowid) }
        var db = try database(fixture)
        var fetches = 0
        db.beforeNativeEditSummaryRead = { fetches += 1 }
        let page = try db.exactHistory(chat: .rowid(3), limit: 1, order: .desc, cursor: nil,
                                       includeNativeEditContext: true)
        #expect(page.items.count == 1)
        #expect(page.nextCursor != nil)
        #expect(fetches == 1)
        let first = try #require(page.items.first)
        let exact = try db.exactGet(chat: .rowid(3), message: .rowid(first.rowid), includeNativeEditContext: true).1
        #expect(first.native_edit_context == exact.native_edit_context)
        let second = try db.exactHistory(chat: .rowid(3), limit: 1, order: .desc, cursor: page.nextCursor,
                                         includeNativeEditContext: true)
        #expect(second.items.first?.rowid != first.rowid)
        #expect(fetches == 3)
    }

    @Test func summaryReadFailurePreservesMessageAndIndependentDates() throws {
        enum SyntheticFailure: Error { case unavailable }
        let fixture = try fixture(columns: columns)
        try installSummary(syntheticSummary(), in: fixture)
        try fixture.exec("UPDATE message SET date_edited=1,date_retracted=0 WHERE ROWID=1")
        var db = try database(fixture)
        db.beforeNativeEditSummaryRead = { throw SyntheticFailure.unavailable }
        let message = try db.exactGet(chat: .rowid(3), message: .rowid(1), includeNativeEditContext: true).1
        #expect(message.body == "hello from friend")
        #expect(message.native_edit_context.summary_info.status == "read-error")
        #expect(message.native_edit_context.date_edited.status == "available")
        #expect(message.native_edit_context.date_retracted.status == "zero-sentinel")
    }

    @Test func summaryReadCancellationEscapesExactRead() throws {
        let fixture = try fixture(columns: columns)
        try installSummary(syntheticSummary(), in: fixture)
        var db = try database(fixture)
        db.beforeNativeEditSummaryRead = { throw CancellationError() }
        #expect(throws: CancellationError.self) {
            try db.exactGet(chat: .rowid(3), message: .rowid(1), includeNativeEditContext: true)
        }
    }

    @Test func eventBudgetIsSharedInPageOrderAndResetsPerRequest() throws {
        let fixture = try fixture(columns: columns)
        let body = NSArchiver.archivedData(withRootObject: NSAttributedString(string: "Synthetic edit"))
        let event: [String: Any] = ["d": 0, "t": body]
        let summary = try PropertyListSerialization.data(
            fromPropertyList: ["ec": ["0": Array(repeating: event, count: 256)]], format: .binary, options: 0)
        for id in 100...108 {
            try fixture.exec("""
                INSERT INTO message(ROWID,guid,text,is_from_me,handle_id,service,date,error)
                VALUES (\(id),'synthetic-\(id)','Synthetic body',0,1,'iMessage',\(fixture.base + Int64(id)),0);
                INSERT INTO chat_message_join VALUES (3,\(id));
                """)
            try installSummary(summary, in: fixture, rowid: id)
        }
        var db = try database(fixture)
        let page = try db.exactHistory(chat: .rowid(3), limit: 9, order: .desc, cursor: nil,
                                       includeNativeEditContext: true)
        #expect(page.items.map(\.rowid) == Array((Int64(100)...108).reversed()))
        #expect(page.nextCursor != nil)
        for message in page.items.prefix(8) {
            #expect(message.native_edit_context.summary_info.status == "available")
            #expect(message.native_edit_context.summary_info.edit_history.entries?.first?.events?.count == 256)
        }
        let limited = try #require(page.items.last)
        #expect(limited.native_edit_context.summary_info.status == "request-limit")
        #expect(limited.native_edit_context.summary_info.edit_history.entries == nil)
        #expect(limited.body == "Synthetic body")
        let fresh = try db.exactGet(chat: .rowid(3), message: .rowid(limited.rowid), includeNativeEditContext: true).1
        #expect(fresh.native_edit_context.summary_info.status == "available")
    }

    @Test func inputBudgetBoundsAThousandVisibleRows() throws {
        let fixture = try ChatFixture()
        // One shared synthetic near-limit BLOB behind a view avoids a 1GiB test
        // database. Every row still exercises the real secondary SQL fetch.
        try fixture.exec("""
            ALTER TABLE message RENAME TO message_base;
            CREATE TABLE synthetic_summary(bytes BLOB);
            INSERT INTO synthetic_summary VALUES (zeroblob(1048576));
            CREATE VIEW message AS SELECT b.*,s.bytes AS message_summary_info
              FROM message_base b CROSS JOIN synthetic_summary s;
            WITH RECURSIVE seq(n) AS (SELECT 100 UNION ALL SELECT n+1 FROM seq WHERE n<1099)
            INSERT INTO message_base(ROWID,guid,text,is_from_me,handle_id,service,date,error)
              SELECT n,'synthetic-'||n,'Synthetic body',0,1,'iMessage',900000000000000000+n,0 FROM seq;
            INSERT INTO chat_message_join(chat_id,message_id)
              SELECT 3,ROWID FROM message_base WHERE ROWID BETWEEN 100 AND 1099;
            """)
        var db = try database(fixture)
        var fetches = 0
        db.beforeNativeEditSummaryRead = { fetches += 1 }
        let page = try db.exactHistory(chat: .rowid(3), limit: 1_000, order: .desc, cursor: nil,
                                       includeNativeEditContext: true)
        #expect(page.items.count == 1_000)
        #expect(fetches == 4)
        #expect(page.items.prefix(4).allSatisfy { $0.native_edit_context.summary_info.status == "unsupported-format" })
        #expect(page.items.dropFirst(4).allSatisfy { $0.native_edit_context.summary_info.status == "request-limit" })
        #expect(page.items.allSatisfy { $0.body == "Synthetic body" })
        #expect(page.nextCursor != nil)
    }
}
