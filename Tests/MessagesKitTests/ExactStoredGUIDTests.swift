import Testing
@testable import MessagesKit

struct ExactStoredGUIDTests {
    @Test(arguments: ["42", "42.5", "X'3432'", "NULL", "'42'"])
    func onlyStoredTextIsExposedAsAGUID(value: String) throws {
        let fixture = try ChatFixture()
        for table in ["chat", "message", "attachment"] {
            try fixture.exec("""
                ALTER TABLE \(table) RENAME COLUMN guid TO original_guid;
                ALTER TABLE \(table) ADD COLUMN guid;
                UPDATE \(table) SET guid = original_guid;
                """)
        }
        try fixture.exec("""
            UPDATE chat SET guid = \(value) WHERE ROWID = 1;
            UPDATE message SET guid = \(value) WHERE ROWID = 4;
            UPDATE attachment SET guid = \(value) WHERE ROWID = 10;
            INSERT INTO chat_message_join VALUES (2, 4);
            INSERT INTO message_attachment_join VALUES (4, 10);
            """)
        if value == "42" || value == "42.5" {
            try fixture.exec("""
                UPDATE chat SET guid = '\(value)' WHERE ROWID = 2;
                UPDATE message SET guid = '\(value)' WHERE ROWID = 2;
                INSERT INTO chat_message_join VALUES (1, 2);
                """)
        }
        var db = try ChatDB(path: fixture.path, book: AddressBook(), homeDirectoryForTilde: fixture.homePath)
        let expected: String? = value == "'42'" ? "42" : nil
        let conversations = try db.exactConversations(limit: 10, order: .asc, cursor: nil)
        let firstChat = try #require(conversations.items.first { $0.chat_rowid == 1 })
        #expect(firstChat.chat_guid == expected)
        let (resolved, message) = try db.exactGet(chat: .rowid(1), message: .rowid(4))
        let history = try db.exactHistory(chat: .rowid(1), limit: 10, order: .asc, cursor: nil)
        let listed = try #require(history.items.first { $0.rowid == 4 })
        #expect(resolved.guid == expected)
        #expect(message.chat_guid == expected)
        #expect(listed.chat_guid == expected)
        #expect(message.message_guid == expected)
        #expect(listed.message_guid == expected)
        let attachment = try #require(message.attachments.first { $0.rowid == 10 })
        #expect(attachment.guid == expected)
        let (_, otherMembership) = try db.exactGet(chat: .rowid(2), message: .rowid(4))
        #expect(otherMembership.selected_chat_rowid == 2)
        #expect(otherMembership.message_guid == expected)
        if value == "42" || value == "42.5" {
            let (byChatGUID, _) = try db.exactGet(chat: .guid(value), message: .rowid(4))
            let (_, byMessageGUID) = try db.exactGet(chat: .rowid(1), message: .guid(value))
            #expect(byChatGUID.rowid == 2)
            #expect(byMessageGUID.rowid == 2)
            let first = try db.exactHistory(chat: .rowid(1), limit: 1, order: .asc, cursor: nil)
            let cursor = try #require(first.nextCursor)
            try fixture.exec("UPDATE chat SET guid = '\(value)' WHERE ROWID = 1;")
            var reopened = try ChatDB(path: fixture.path, book: AddressBook(), homeDirectoryForTilde: fixture.homePath)
            #expect(throws: (any Error).self) {
                try reopened.exactHistory(chat: .rowid(1), limit: 1, order: .asc, cursor: cursor)
            }
        }
    }
}
