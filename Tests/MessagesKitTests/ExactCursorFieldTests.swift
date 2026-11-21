import AppleKit
import Foundation
import Testing
@testable import MessagesKit

struct ExactCursorFieldTests {
    @Test func historyChecksExactJSONFieldNamesAndDecodesEscapedGUIDs() throws {
        let fixture = try ChatFixture()
        try fixture.exec("UPDATE chat SET guid = 'fixture-🛰️' WHERE ROWID = 3;")
        var db = try ChatDB(path: fixture.path, book: AddressBook(), homeDirectoryForTilde: fixture.homePath)
        let first = try db.exactHistory(chat: .rowid(3), limit: 1, order: .desc, cursor: nil)
        let cursor = try #require(first.nextCursor)
        let raw = try #require(Data(base64Encoded: cursor))
        let object = try #require(String(data: raw, encoding: .utf8))
        let next = try db.exactHistory(chat: .rowid(3), limit: 1, order: .desc, cursor: cursor)
        #expect(next.items.count == 1)

        var fields = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        fields.removeValue(forKey: "chatGuid")
        let rest = try JSONSerialization.data(withJSONObject: fields)
        let prefix = String(decoding: rest.dropLast(), as: UTF8.self)
        let escaped = prefix + #","chatGuid":"fixture-\uD83D\uDEF0\uFE0F"}"#
        let samePage = try db.exactHistory(chat: .rowid(3), limit: 1, order: .desc,
                                           cursor: Data(escaped.utf8).base64EncodedString())
        #expect(samePage.items.map(\.rowid) == next.items.map(\.rowid))

        let changedSortKey = object
            .replacingOccurrences(of: #""lastSeconds""#, with: "\"\u{feff}lastSeconds\"")
            .replacingOccurrences(of: #""lastNanoseconds""#, with: "\"\u{feff}lastNanoseconds\"")
        #expect(changedSortKey != object)
        for malformed in [changedSortKey, String(object.dropLast()) + #","\uFEFFmaxChatRowid":42}"#,
                          String(object.dropLast()) + #","\u0076":1}"#] {
            #expect(throws: AppleError.self) {
                try db.exactHistory(chat: .rowid(3), limit: 1, order: .desc,
                                    cursor: Data(malformed.utf8).base64EncodedString())
            }
        }
    }
}
