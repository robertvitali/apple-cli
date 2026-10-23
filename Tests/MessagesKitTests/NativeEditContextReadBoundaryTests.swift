import Foundation
import Testing
import AppleKit
@testable import MessagesKit

@Suite struct NativeEditContextReadBoundaryTests {
    private func fixture() throws -> ChatFixture {
        let fixture = try ChatFixture()
        try fixture.exec("ALTER TABLE message ADD COLUMN message_summary_info")
        try fixture.exec("ALTER TABLE message ADD COLUMN date_edited")
        let blob = try PropertyListSerialization.data(fromPropertyList: ["ep": [0]], format: .binary, options: 0)
        let hex = blob.map { String(format: "%02x", $0) }.joined()
        try fixture.exec("UPDATE message SET message_summary_info=X'\(hex)',date_edited=1 WHERE ROWID=1")
        return fixture
    }

    private func initial(_ fixture: ChatFixture) throws -> SQLiteReader.Row {
        let reader = try SQLiteReader(path: fixture.path)
        let projection = NativeEditContextRead.projection(columns: ["message_summary_info", "date_edited"])
        return try #require(reader.rows("""
            SELECT m.ROWID AS rowid,m.guid AS message_guid,c.ROWID AS selected_chat_rowid,c.guid AS chat_guid,
                   \(projection)
            FROM message m JOIN chat_message_join cmj ON cmj.message_id=m.ROWID
                 JOIN chat c ON c.ROWID=cmj.chat_id
            WHERE m.ROWID=1 AND c.ROWID=3
            """).first)
    }

    private func read(_ row: SQLiteReader.Row, from fixture: ChatFixture) throws -> ChatDB.ExactNativeEditContext {
        // Reopen after a synthetic mutation: immutable readers do not promise
        // to refresh cached pages. The product still uses its existing reader.
        let reader = try SQLiteReader(path: fixture.path)
        var budget = NativeEditContextRead.Budget()
        return try NativeEditContextRead.context(row, requested: true, budget: &budget, read: reader.rows)
    }

    @Test(arguments: [
        "UPDATE message SET guid='G1' WHERE ROWID=1",
        "UPDATE chat SET guid='changed' WHERE ROWID=3",
        "UPDATE chat SET guid=NULL WHERE ROWID=3",
        "DELETE FROM chat_message_join WHERE message_id=1 AND chat_id=3",
    ])
    func identityOrMembershipChangesRejectFreshSummary(_ mutation: String) throws {
        let fixture = try fixture()
        let row = try initial(fixture)
        try fixture.exec(mutation)
        let context = try read(row, from: fixture)
        #expect(context.summary_info.status == "changed")
        #expect(context.summary_info.edit_history.entries == nil)
        #expect(context.date_edited.raw == 1)
    }

    @Test func observedNullChatGuidIsBoundAsNull() throws {
        let fixture = try fixture()
        try fixture.exec("UPDATE chat SET guid=NULL WHERE ROWID=3")
        let row = try initial(fixture)
        #expect(try read(row, from: fixture).summary_info.status == "available")
        try fixture.exec("UPDATE chat SET guid='' WHERE ROWID=3")
        #expect(try read(row, from: fixture).summary_info.status == "changed")
    }

    @Test func observedNulChatGuidCannotMatchAChangedPrefix() throws {
        let fixture = try fixture()
        // SQLiteReader preserves the stored NUL, but its string bindings are
        // NUL-terminated. Never let this observed identity bind only a prefix.
        try fixture.exec("UPDATE chat SET guid=CAST(X'6368617400737566666978' AS TEXT) WHERE ROWID=3")
        let row = try initial(fixture)
        try fixture.exec("UPDATE chat SET guid='chat' WHERE ROWID=3")
        let reader = try SQLiteReader(path: fixture.path)
        var budget = NativeEditContextRead.Budget()
        var fetches = 0
        let context = try NativeEditContextRead.context(row, requested: true, budget: &budget,
            read: { sql, binds in fetches += 1; return try reader.rows(sql, binds) })
        #expect(context.summary_info.status == "identity-unavailable")
        #expect(context.summary_info.edit_history.entries == nil)
        #expect(fetches == 0)
        #expect(budget.remainingInputBytes == 4_194_304)
    }

    @Test func observedEmptyChatGuidRemainsAnExactIdentity() throws {
        let fixture = try fixture()
        try fixture.exec("UPDATE chat SET guid='' WHERE ROWID=3")
        let row = try initial(fixture)
        #expect(try read(row, from: fixture).summary_info.status == "available")
        try fixture.exec("UPDATE chat SET guid=NULL WHERE ROWID=3")
        #expect(try read(row, from: fixture).summary_info.status == "changed")
    }

    @Test func invalidMessageIdentitiesCannotReachTheReader() throws {
        let fixture = try fixture()
        let row = try initial(fixture)
        let values: [SQLiteReader.Row.Value] = [.null, .integer(1), .real(1), .blob(Data([1])),
            .text(""), .text("line\nbreak"), .text("nul\0suffix"), .text(String(repeating: "a", count: 1_025))]
        for value in values {
            var fields = row.values
            fields["message_guid"] = value
            var budget = NativeEditContextRead.Budget()
            var fetches = 0
            let context = try NativeEditContextRead.context(.init(values: fields), requested: true, budget: &budget,
                                                             read: { _, _ in fetches += 1; return [] })
            #expect(context.summary_info.status == "identity-unavailable")
            #expect(fetches == 0)
            #expect(budget.remainingInputBytes == 4_194_304)
        }
    }

    @Test(arguments: [
        ("NULL", "null"),
        ("CAST(X'ff' AS TEXT)", "wrong-type"),
        ("CAST(zeroblob(2097152) AS TEXT)", "wrong-type"),
        ("X''", "empty"),
        ("zeroblob(1048577)", "too-large"),
    ])
    func secondaryObservationUsesActualTypeAndLength(_ value: String, _ status: String) throws {
        let fixture = try fixture()
        let row = try initial(fixture)
        try fixture.exec("UPDATE message SET message_summary_info=\(value) WHERE ROWID=1")
        let context = try read(row, from: fixture)
        #expect(context.summary_info.status == status)
        #expect(context.date_edited.status == "available")
    }

    @Test func secondaryReadFailureIsFixedButCancellationPropagates() throws {
        let fixture = try fixture()
        let row = try initial(fixture)
        var budget = NativeEditContextRead.Budget()
        let context = try NativeEditContextRead.context(row, requested: true, budget: &budget, read: { _, _ in
            throw SQLiteReader.DBError.step("synthetic SQL failure detail")
        })
        #expect(context.summary_info.status == "read-error")
        #expect(context.date_edited.raw == 1)
        let encoded = try JSONEncoder().encode(context)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("synthetic SQL"))
        #expect(throws: CancellationError.self) {
            try NativeEditContextRead.context(row, requested: true, budget: &budget, read: { _, _ in
                throw CancellationError()
            })
        }
        var checks = 0
        #expect(throws: CancellationError.self) {
            try NativeEditContextRead.context(row, requested: true, budget: &budget,
                read: { _, _ in throw SQLiteReader.DBError.step("synthetic") },
                checkCancellation: { checks += 1; if checks == 2 { throw CancellationError() } })
        }
        #expect(checks == 2)
    }

    @Test func remainingInputCapIsEnforcedBySecondarySQL() throws {
        let fixture = try fixture()
        let row = try initial(fixture)
        // Initial hint fits. Actual stored BLOB grows but still fits its own cap.
        try fixture.exec("UPDATE message SET message_summary_info=zeroblob(1024) WHERE ROWID=1")
        let reader = try SQLiteReader(path: fixture.path)
        var budget = NativeEditContextRead.Budget()
        budget.remainingInputBytes = 512
        var fetches = 0
        let context = try NativeEditContextRead.context(row, requested: true, budget: &budget, read: { sql, binds in
            fetches += 1
            let rows = try reader.rows(sql, binds)
            #expect(rows.first?.values["native_edit_summary_blob"] == .null)
            return rows
        })
        #expect(fetches == 1)
        #expect(context.summary_info.status == "request-limit")
        #expect(budget.remainingInputBytes == 512)
    }
}
