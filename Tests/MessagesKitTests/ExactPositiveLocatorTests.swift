import AppleKit
import Testing
@testable import MessagesKit

struct ExactPositiveLocatorTests {
    @Test(arguments: [Int64.min, -1, 0])
    func invalidStoredLocatorCannotProduceSuccess(id: Int64) throws {
        let fixture = try ChatFixture()
        try fixture.exec("""
            INSERT INTO message(ROWID,guid,text,is_from_me,handle_id,service,date,error)
            VALUES(\(id),'invalid-message','fixture',0,1,'iMessage',-999999,0);
            INSERT INTO chat_message_join VALUES (3,\(id));
            INSERT INTO chat(ROWID,chat_identifier,guid,style) VALUES(\(id),'fixture','invalid-chat',43);
            """)
        var db = try ChatDB(path: fixture.path, book: AddressBook(), homeDirectoryForTilde: fixture.homePath)
        let conversations = #expect(throws: AppleError.self) {
            try db.exactConversations(limit: 1, order: .asc, cursor: nil)
        }
        #expect(conversations?.type == AppleErrorType.upstream)
        let history = #expect(throws: AppleError.self) {
            try db.exactHistory(chat: .rowid(3), limit: 1, order: .asc, cursor: nil)
        }
        #expect(history?.type == AppleErrorType.upstream)
        let message = #expect(throws: AppleError.self) {
            try db.exactGet(chat: .rowid(3), message: .guid("invalid-message"))
        }
        #expect(message?.type == AppleErrorType.upstream)
        let foreign = #expect(throws: AppleError.self) {
            try db.exactGet(chat: .rowid(4), message: .guid("invalid-message"))
        }
        #expect(foreign?.type == AppleErrorType.notFound)
        let chat = #expect(throws: AppleError.self) {
            try db.exactHistory(chat: .guid("invalid-chat"), limit: 1, order: .asc, cursor: nil)
        }
        #expect(chat?.type == AppleErrorType.upstream)
        let chatSelector = #expect(throws: AppleError.self) {
            try db.exactHistory(chat: .rowid(id), limit: 1, order: .asc, cursor: nil)
        }
        #expect(chatSelector?.type == AppleErrorType.validation)
        let messageSelector = #expect(throws: AppleError.self) {
            try db.exactGet(chat: .rowid(3), message: .rowid(id))
        }
        #expect(messageSelector?.type == AppleErrorType.validation)
        let (_, valid) = try db.exactGet(chat: .rowid(3), message: .rowid(1))
        #expect(valid.rowid == 1)
    }

    @Test func unlinkedNegativeMessageCannotInvalidateConversationCursor() throws {
        let fixture = try ChatFixture()
        try fixture.exec("""
            DELETE FROM chat_message_join;
            DELETE FROM message;
            INSERT INTO message(ROWID,guid) VALUES(-1,'unlinked');
            """)
        var db = try ChatDB(path: fixture.path, book: AddressBook(), homeDirectoryForTilde: fixture.homePath)
        let first = try db.exactConversations(limit: 1, order: .asc, cursor: nil)
        let next = try #require(first.nextCursor)
        let second = try db.exactConversations(limit: 1, order: .asc, cursor: next)
        #expect(first.items.map(\.chat_rowid) == [1])
        #expect(second.items.map(\.chat_rowid) == [2])
    }
}
