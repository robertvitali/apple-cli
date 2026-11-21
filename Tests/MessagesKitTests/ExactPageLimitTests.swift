import AppleKit
import Testing
@testable import MessagesKit

struct ExactPageLimitTests {
    @Test(arguments: [Int.min, -2, -1, 0, 1001, Int.max])
    func invalidLimitsAreRejectedByBothReadAPIs(limit: Int) throws {
        let fixture = try ChatFixture()
        var db = try ChatDB(path: fixture.path, book: AddressBook(), homeDirectoryForTilde: fixture.homePath)
        #expect(throws: AppleError.self) {
            try db.exactConversations(limit: limit, order: .asc, cursor: nil)
        }
        #expect(throws: AppleError.self) {
            try db.exactHistory(chat: .rowid(3), limit: limit, order: .desc, cursor: nil)
        }
    }

    @Test(arguments: [1, 1000])
    func supportedLimitEndpointsReturnPages(limit: Int) throws {
        let fixture = try ChatFixture()
        var db = try ChatDB(path: fixture.path, book: AddressBook(), homeDirectoryForTilde: fixture.homePath)
        let chats = try db.exactConversations(limit: limit, order: .asc, cursor: nil)
        let history = try db.exactHistory(chat: .rowid(3), limit: limit, order: .desc, cursor: nil)
        #expect(!chats.items.isEmpty && chats.items.count <= limit)
        #expect(!history.items.isEmpty && history.items.count <= limit)
        #expect((chats.nextCursor != nil) == (limit == 1))
        #expect((history.nextCursor != nil) == (limit == 1))
    }
}
