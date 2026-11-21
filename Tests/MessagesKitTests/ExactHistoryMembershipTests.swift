import AppleKit
import Testing
@testable import MessagesKit

struct ExactHistoryMembershipTests {
    @Test func groupNameBelongsToSelectedConversation() throws {
        let fixture = try ChatFixture()
        try fixture.exec("""
            UPDATE chat SET room_name = 'shared', display_name = 'First' WHERE ROWID = 1;
            UPDATE chat SET room_name = 'shared', display_name = 'Second' WHERE ROWID = 2;
            UPDATE message SET cache_roomnames = 'shared' WHERE ROWID = 4;
            INSERT INTO chat_message_join VALUES (2,4), (3,4);
            """)
        var db = try ChatDB(path: fixture.path, book: AddressBook(), homeDirectoryForTilde: fixture.homePath)
        for (chat, expected) in [(Int64(1), "First" as String?), (2, "Second"), (3, nil)] {
            let (_, single) = try db.exactGet(chat: .rowid(chat), message: .rowid(4))
            let page = try db.exactHistory(chat: .rowid(chat), limit: 100, order: .asc, cursor: nil)
            let listed = try #require(page.items.first { $0.rowid == 4 })
            #expect(single.group_name == expected)
            #expect(listed.group_name == expected)
        }
        try fixture.exec("UPDATE message SET cache_roomnames = CAST(x'FF' AS TEXT) WHERE ROWID = 4")
        db = try ChatDB(path: fixture.path, book: AddressBook(), homeDirectoryForTilde: fixture.homePath)
        let (_, single) = try db.exactGet(chat: .rowid(2), message: .rowid(4))
        #expect(single.group_name == "Second")
    }

    @Test(arguments: ["INTEGER", "TEXT", "BLOB", ""])
    func exactAttachmentRowsFollowMessageIdentity(columnType: String) throws {
        let fixture = try ChatFixture()
        try fixture.exec("""
            DROP TABLE message_attachment_join;
            CREATE TABLE message_attachment_join(message_id \(columnType), attachment_id \(columnType));
            INSERT INTO message_attachment_join VALUES
                ('04','010'), (4,11), (4,11), (4.5,10), ('4x',11);
            """)
        var db = try ChatDB(path: fixture.path, book: AddressBook(), homeDirectoryForTilde: fixture.homePath)
        let (_, single) = try db.exactGet(chat: .rowid(1), message: .rowid(4))
        let page = try db.exactHistory(chat: .rowid(1), limit: 10, order: .desc, cursor: nil)
        let listed = try #require(page.items.first { $0.rowid == 4 })
        #expect(single.attachments.map(\.rowid) == [10, 11, 11])
        #expect(listed.attachments.map(\.rowid) == [10, 11, 11])
    }

    @Test(arguments: [ChatDB.ExactOrder.asc, .desc], [1, 2, 4, 10])
    func repeatedMembershipDoesNotChangeHistory(order: ChatDB.ExactOrder, limit: Int) throws {
        let fixture = try ChatFixture()
        try fixture.exec("""
            DELETE FROM chat_message_join WHERE chat_id = 3;
            INSERT INTO chat_message_join VALUES (3,4), (3,2), (3,1), (3,6);
            UPDATE message SET date = NULL WHERE ROWID IN (1, 2);
            UPDATE message SET date = 100 WHERE ROWID IN (4, 6);
            """)
        func readPages() throws -> [[Int64]] {
            var pages: [[Int64]] = []
            var cursor: String?
            repeat {
                var db = try ChatDB(path: fixture.path, book: AddressBook(),
                                    homeDirectoryForTilde: fixture.homePath)
                let page = try db.exactHistory(chat: .rowid(3), limit: limit,
                                               order: order, cursor: cursor)
                #expect(page.items.allSatisfy { $0.selected_chat_rowid == 3 })
                pages.append(page.items.map(\.rowid))
                cursor = page.nextCursor
                try #require(pages.count <= 5)
            } while cursor != nil
            return pages
        }
        let original = try readPages()
        let expected: [Int64] = order == .asc ? [1, 2, 4, 6] : [6, 4, 2, 1]
        #expect(original.flatMap { $0 } == expected)
        try fixture.exec("INSERT INTO chat_message_join VALUES (3,1), (3,4), (3,6), (3,6)")
        let repeated = try readPages()
        #expect(repeated == original)

        var db = try ChatDB(path: fixture.path, book: AddressBook(), homeDirectoryForTilde: fixture.homePath)
        let other = try db.exactHistory(chat: .rowid(1), limit: 10, order: order, cursor: nil)
        #expect(other.items.map(\.rowid) == [4])
        #expect(other.items.first?.selected_chat_rowid == 1)
    }

    @Test(arguments: [ChatDB.ExactOrder.asc, .desc], [1, 2, 4, 8])
    func unsupportedTimestampStoragePagesAsUndated(order: ChatDB.ExactOrder, limit: Int) throws {
        let fixture = try ChatFixture()
        try fixture.exec("""
            DELETE FROM chat_message_join WHERE chat_id = 3;
            INSERT INTO chat_message_join VALUES (3,1), (3,2), (3,4), (3,6), (3,7), (3,8), (3,9), (3,10);
            UPDATE message SET date = CASE ROWID
                WHEN 2 THEN 10.5 WHEN 4 THEN 20 WHEN 5 THEN 2000.25 WHEN 6 THEN x'32303234' WHEN 7 THEN 'missing'
                WHEN 8 THEN -4.25 WHEN 9 THEN -12000000001 WHEN 10 THEN 12000000001 END;
            """)
        var db = try ChatDB(path: fixture.path, book: AddressBook(), homeDirectoryForTilde: fixture.homePath)
        let ascending: [Int64] = [1, 2, 6, 7, 8, 9, 10, 4]
        var cursor: String?
        var ids: [Int64] = []
        repeat {
            let page = try db.exactHistory(chat: .rowid(3), limit: limit, order: order, cursor: cursor)
            for message in page.items {
                if [1, 2, 6, 7, 8].contains(message.rowid) {
                    #expect(message.timestamp == nil)
                    #expect(message.date == nil)
                    #expect(message.normalized_seconds == nil)
                    #expect(message.normalized_nanoseconds == nil)
                }
                ids.append(message.rowid)
            }
            cursor = page.nextCursor
            try #require(cursor == nil || (!page.items.isEmpty && ids.count < ascending.count))
        } while cursor != nil
        #expect(ids == (order == .asc ? ascending : Array(ascending.reversed())))

        let conversations = try db.exactConversations(limit: 10, order: order, cursor: nil)
        let malformed = try #require(conversations.items.first { $0.chat_rowid == 2 })
        #expect(malformed.last_activity == nil)
        #expect(malformed.last_activity_timestamp == nil)
        #expect(malformed.last_activity_normalized_seconds == nil)
        #expect(malformed.last_activity_normalized_nanoseconds == nil)
    }

    @Test(arguments: [ChatDB.ExactOrder.asc, .desc])
    func conversationActivityRequiresAnExistingMembership(order: ChatDB.ExactOrder) throws {
        let fixture = try ChatFixture()
        try fixture.exec("""
            DELETE FROM chat_message_join;
            INSERT INTO chat_message_join VALUES (1, 2), (2, 1), (2, 1), (1.5, 4), (3.75, 4), (9999, 4);
            UPDATE message SET date = CASE ROWID WHEN 1 THEN 100 WHEN 2 THEN 50 WHEN 4 THEN 500 END;
            """)
        var db = try ChatDB(path: fixture.path, book: AddressBook(), homeDirectoryForTilde: fixture.homePath)
        var ids: [Int64] = []
        var cursor: String?
        repeat {
            let page = try db.exactConversations(limit: 1, order: order, cursor: cursor)
            let conversation = try #require(page.items.first)
            let history = try db.exactHistory(chat: .rowid(conversation.chat_rowid), limit: 1,
                                              order: .desc, cursor: nil)
            #expect(conversation.last_activity_timestamp == history.items.first?.timestamp)
            ids.append(conversation.chat_rowid)
            cursor = page.nextCursor
            try #require(ids.count <= 4)
        } while cursor != nil
        let ascending: [Int64] = [3, 4, 1, 2]
        #expect(ids == (order == .asc ? ascending : Array(ascending.reversed())))
    }

    @Test(arguments: [ChatDB.ExactOrder.asc, .desc])
    func historyLoadsPayloadOnlyWhenTheRowIsVisible(order: ChatDB.ExactOrder) throws {
        let fixture = try ChatFixture()
        try fixture.exec("""
            DELETE FROM chat_message_join;
            INSERT INTO chat_message_join VALUES (3,1), (3,2), (3,4);
            UPDATE message SET date = ROWID;
            UPDATE message SET text = CAST(x'80' AS TEXT) WHERE ROWID = 2;
            """)
        var db = try ChatDB(path: fixture.path, book: AddressBook(), homeDirectoryForTilde: fixture.homePath)
        let first = try db.exactHistory(chat: .rowid(3), limit: 1, order: order, cursor: nil)
        #expect(first.items.map(\.rowid) == [order == .asc ? 1 : 4])
        let cursor = try #require(first.nextCursor)
        #expect(throws: SQLiteReader.DBError.self) {
            try db.exactHistory(chat: .rowid(3), limit: 1, order: order, cursor: cursor)
        }
    }

    @Test(arguments: ["display_name", "participant"])
    func conversationsLoadDetailsOnlyForVisibleChats(field: String) throws {
        let fixture = try ChatFixture()
        try fixture.exec("""
            DELETE FROM chat_message_join;
            DELETE FROM chat_handle_join;
            INSERT INTO chat_handle_join (chat_id,handle_id) VALUES (2,1);
            """)
        if field == "participant" {
            try fixture.exec("UPDATE handle SET id = CAST(x'80' AS TEXT) WHERE ROWID = 1")
        } else {
            try fixture.exec("UPDATE chat SET display_name = CAST(x'80' AS TEXT) WHERE ROWID = 2")
        }
        var db = try ChatDB(path: fixture.path, book: AddressBook(), homeDirectoryForTilde: fixture.homePath)
        let first = try db.exactConversations(limit: 1, order: .asc, cursor: nil)
        #expect(first.items.map(\.chat_rowid) == [1])
        let cursor = try #require(first.nextCursor)
        #expect(throws: SQLiteReader.DBError.self) {
            try db.exactConversations(limit: 1, order: .asc, cursor: cursor)
        }
    }

    @Test func participantMembershipUsesChatRowIdentity() throws {
        let fixture = try ChatFixture()
        try fixture.exec("""
            DROP TABLE chat_handle_join;
            CREATE TABLE chat_handle_join(chat_id, handle_id);
            UPDATE handle SET id = 'first@example.invalid' WHERE ROWID = 1;
            UPDATE handle SET id = 'second@example.invalid' WHERE ROWID = 2;
            INSERT INTO chat_handle_join VALUES (1,1), ('02',2), (2.5,1);
            """)
        var db = try ChatDB(path: fixture.path, book: AddressBook(), homeDirectoryForTilde: fixture.homePath)
        let page = try db.exactConversations(limit: 10, order: .asc, cursor: nil)
        #expect(page.items.first { $0.chat_rowid == 1 }?.participants == ["first@example.invalid"])
        #expect(page.items.first { $0.chat_rowid == 2 }?.participants == ["second@example.invalid"])
    }
}
