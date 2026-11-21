import AppleKit
import Foundation
import Testing
@testable import MessagesKit

struct ExactCursorNumberTests {
    private func cursor(version: String = "1", message: String = "10", seconds: String = "0") -> String {
        let json = """
        {"v":\(version),"op":"history","order":"asc","chatRowid":3,"chatGuid":"iMessage;-;chat999",
        "maxMessageRowid":\(message),"lastMessageRowid":1,"lastSeconds":\(seconds),"lastNanoseconds":0}
        """
        return Data(json.utf8).base64EncodedString()
    }

    @Test func fractionalAndOverflowingCursorFieldsRefuse() throws {
        let fixture = try ChatFixture()
        try fixture.exec("UPDATE chat SET guid='iMessage;-;chat999' WHERE ROWID=3")
        var db = try ChatDB(path: fixture.path, book: AddressBook())
        for invalid in [cursor(version: "1.0000000000000000001"), cursor(version: "0.99999999999999999999"),
                        cursor(message: "9007199254740993.1"), cursor(seconds: "1e-999"),
                        cursor(seconds: "-1e-999"), cursor(seconds: "9223372036854775808.0"),
                        cursor(seconds: "-9223372036854775809.0"), cursor(seconds: "01")] {
            #expect(throws: AppleError.self) {
                try db.exactHistory(chat: .rowid(3), limit: 1, order: .asc, cursor: invalid)
            }
        }
    }

    @Test func equivalentDecimalAndExponentIntegersResumeAtTheirExactBoundary() throws {
        let fixture = try ChatFixture()
        let large: Int64 = 9_007_199_254_740_993
        try fixture.exec("""
            UPDATE chat SET guid='iMessage;-;chat999' WHERE ROWID=3;
            INSERT INTO message(ROWID,guid,date) VALUES (\(large),'large',1),(\(large + 1),'next',2);
            INSERT INTO chat_message_join VALUES (3,\(large)),(3,\(large + 1));
            """)
        var db = try ChatDB(path: fixture.path, book: AddressBook())
        for max in [String(large), "9007199254740993.0", "900719925474099300e-2", "9.007199254740993e15"] {
            let page = try db.exactHistory(chat: .rowid(3), limit: 100, order: .asc,
                cursor: cursor(version: "0.0100e+2", message: max, seconds: "-0.0e999"))
            #expect(page.items.contains { $0.rowid == large })
            #expect(!page.items.contains { $0.rowid == large + 1 })
        }
    }
}
