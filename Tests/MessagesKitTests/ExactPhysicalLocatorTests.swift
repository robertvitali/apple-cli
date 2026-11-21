import AppleKit
import Testing
@testable import MessagesKit

struct ExactPhysicalLocatorTests {
    @Test(arguments: ["membership view", "swapped ROWID", "descending primary key"])
    func rejectsSubstitutedIdentitySources(_ replacement: String) throws {
        let fixture = try ChatFixture()
        switch replacement {
        case "membership view":
            try fixture.exec("""
                ALTER TABLE chat_message_join RENAME TO stored_memberships;
                CREATE VIEW chat_message_join AS
                SELECT chat_id, CASE WHEN chat_id=1 AND message_id=4 THEN 1 ELSE message_id END AS message_id
                FROM stored_memberships;
                """)
        case "swapped ROWID":
            try fixture.exec("""
                ALTER TABLE message RENAME COLUMN ROWID TO physical_key;
                ALTER TABLE message ADD COLUMN ROWID INTEGER;
                UPDATE message SET ROWID=CASE physical_key WHEN 1 THEN 4 WHEN 4 THEN 1 ELSE physical_key END;
                """)
        default:
            // SQLite implements this spelling with a separate primary-key index.
            try fixture.exec("""
                ALTER TABLE handle RENAME TO stored_handles;
                CREATE TABLE handle(ROWID INTEGER PRIMARY KEY DESC, id TEXT, service TEXT);
                INSERT INTO handle(ROWID,id,service) SELECT ROWID,id,service FROM stored_handles ORDER BY ROWID DESC;
                """)
        }
        var db = try ChatDB(path: fixture.path, book: AddressBook(), homeDirectoryForTilde: fixture.homePath)
        let messageID: Int64 = replacement == "membership view" ? 1 : 4
        #expect(throws: AppleError.self) { try db.exactGet(chat: .rowid(1), message: .rowid(messageID)) }
        #expect(throws: AppleError.self) { try db.exactHistory(chat: .rowid(1), limit: 10, order: .asc, cursor: nil) }
        #expect(throws: AppleError.self) { try db.exactConversations(limit: 10, order: .asc, cursor: nil) }
    }

    @Test func preservesIntrinsicRowidsAndUnrelatedIndexes() throws {
        let fixture = try ChatFixture()
        try fixture.exec("""
            ALTER TABLE message RENAME COLUMN ROWID TO physical_key;
            CREATE INDEX unrelated_guid_index ON message(guid);
            """)
        var db = try ChatDB(path: fixture.path, book: AddressBook(), homeDirectoryForTilde: fixture.homePath)
        let (_, selected) = try db.exactGet(chat: .rowid(1), message: .rowid(4))
        #expect(selected.rowid == 4)
        let guid = try #require(selected.message_guid)
        let (_, byGUID) = try db.exactGet(chat: .rowid(1), message: .guid(guid))
        #expect(byGUID.rowid == selected.rowid)
        let history = try db.exactHistory(chat: .rowid(1), limit: 10, order: .asc, cursor: nil)
        #expect(history.items.contains { $0.rowid == selected.rowid && $0.message_guid == guid })
    }
}
