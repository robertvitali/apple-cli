import Foundation
import Testing
import AppleKit
@testable import MessagesKit

@Suite struct NativeAttachmentTransferTests {
    private func fixture(present: Bool = true) throws -> ChatFixture {
        let fx = try ChatFixture()
        try fx.exec("""
            DROP TABLE attachment;
            CREATE TABLE attachment(ROWID INTEGER PRIMARY KEY, guid TEXT\(present ? ", transfer_state" : ""));
            INSERT INTO attachment(ROWID,guid) VALUES(1001,'synthetic-transfer-one'),(1002,'synthetic-transfer-two');
            INSERT INTO message_attachment_join VALUES(1,1001),(2,1002);
            """)
        return fx
    }

    private func database(_ fx: ChatFixture) throws -> ChatDB {
        try ChatDB(path: fx.path, book: AddressBook(contacts: [:]), copyToTemp: false,
                   homeDirectoryForTilde: fx.homePath)
    }

    @Test func exactReadsPreserveAllNativeStatesAndJoinedIdentity() throws {
        let states = ["waiting-for-accept", "accepted", "preparing", "transferring", "finalizing",
                      "finished", "error", "recoverable-error", "rejected", "thumbnail"]
        for (raw, state) in states.enumerated() {
            let fx = try fixture()
            try fx.exec("UPDATE attachment SET transfer_state=\(raw) WHERE ROWID=1001; UPDATE attachment SET transfer_state=99 WHERE ROWID=1002")
            var db = try database(fx)
            let item = try #require(db.exactGet(chat: .rowid(3), message: .rowid(1)).1.attachments.first)
            let transfer = try #require(item.native_transfer)
            #expect(item.rowid == 1001 && transfer.status == "available")
            #expect(transfer.raw == Int64(raw) && transfer.state == state)
            let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
            let encodedTransfer = try #require(encoded["native_transfer"] as? [String: Any])
            #expect(Set(encodedTransfer.keys) == ["status", "raw", "state"])
            #expect(encodedTransfer["status"] as? String == "available")
            #expect(encodedTransfer["raw"] as? Int == raw)
            #expect(encodedTransfer["state"] as? String == state)
            // A missing filename remains unavailable for every transfer state.
            #expect(item.path == nil && item.exists == nil)
            let page = try db.exactHistory(chat: .rowid(3), limit: 100, order: .desc, cursor: nil)
            #expect(page.items.first { $0.rowid == 1 }?.attachments.first?.native_transfer == transfer)
            let other = try #require(page.items.first { $0.rowid == 2 }?.attachments.first)
            #expect(other.rowid == 1002 && other.native_transfer?.status == "unknown-state")
            #expect(other.native_transfer?.raw == 99 && other.native_transfer?.state == nil)
        }
    }

    @Test func missingNullWrongTypeAndUnknownRemainDistinct() throws {
        let cases: [(Bool, String, String, Int64?)] = [
            (false, "NULL", "missing-schema", nil), (true, "NULL", "null", nil),
            (true, "'5'", "wrong-type", nil), (true, "5.0", "wrong-type", nil),
            (true, "CAST(X'ff' AS TEXT)", "wrong-type", nil), (true, "X'ff'", "wrong-type", nil),
            (true, "-1", "unknown-state", -1), (true, "10", "unknown-state", 10),
            (true, "9223372036854775807", "unknown-state", Int64.max),
            (true, "-9223372036854775808", "unknown-state", Int64.min)
        ]
        for (present, sql, status, raw) in cases {
            let fx = try fixture(present: present)
            if present { try fx.exec("UPDATE attachment SET transfer_state=\(sql) WHERE ROWID=1001") }
            var db = try database(fx)
            let field = try #require(db.exactGet(chat: .rowid(3), message: .rowid(1)).1.attachments.first?.native_transfer)
            #expect(field.status == status && field.raw == raw && field.state == nil)
            let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(field)) as? [String: Any])
            #expect(Set(encoded.keys) == ["status", "raw", "state"])
            #expect(encoded["state"] is NSNull)
            if raw == nil { #expect(encoded["raw"] is NSNull) }
        }
    }

    @Test func finishedPreservesFilenameAvailabilityAndMultipleAttachmentIdentity() throws {
        let fx = try fixture(present: false)
        try fx.exec("""
            ALTER TABLE attachment ADD COLUMN filename TEXT;
            UPDATE attachment SET filename='~/Library/Messages/Attachments/zz/synthetic-missing.png' WHERE ROWID=1001;
            UPDATE attachment SET filename='~/Library/Messages/Attachments/zz/apple-cli-present.png' WHERE ROWID=1002;
            INSERT INTO message_attachment_join VALUES(1,1002);
            """)
        var beforeDB = try database(fx)
        let before = try beforeDB.exactGet(chat: .rowid(3), message: .rowid(1)).1.attachments
        #expect(Set(before.map(\.rowid)) == [1001, 1002])
        #expect(before.first { $0.rowid == 1001 }?.exists == false)
        #expect(before.first { $0.rowid == 1002 }?.exists == true)
        try fx.exec("ALTER TABLE attachment ADD COLUMN transfer_state INTEGER; UPDATE attachment SET transfer_state=5")
        var afterDB = try database(fx)
        let after = try afterDB.exactGet(chat: .rowid(3), message: .rowid(1)).1.attachments
        #expect(Set(after.map(\.rowid)) == [1001, 1002])
        for item in after {
            let control = try #require(before.first { $0.rowid == item.rowid })
            #expect(item.path == control.path && item.exists == control.exists)
            #expect(item.path != nil)
            #expect(item.native_transfer?.status == "available")
            #expect(item.native_transfer?.raw == 5 && item.native_transfer?.state == "finished")
        }
    }

    @Test func integerAffinityReportsStoredTypeAndEncodesAvailableValues() throws {
        for literal in ["'5'", "5.0"] {
            let fx = try fixture(present: false)
            try fx.exec("ALTER TABLE attachment ADD COLUMN transfer_state INTEGER; UPDATE attachment SET transfer_state=\(literal) WHERE ROWID=1001")
            var db = try database(fx)
            let field = try #require(db.exactGet(chat: .rowid(3), message: .rowid(1)).1.attachments.first?.native_transfer)
            #expect(field.status == "available" && field.raw == 5 && field.state == "finished")
            let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(field)) as? [String: Any])
            #expect(Set(encoded.keys) == ["status", "raw", "state"])
            #expect(encoded["status"] as? String == "available")
            #expect(encoded["raw"] as? Int == 5)
            #expect(encoded["state"] as? String == "finished")
        }
    }

    @Test func legacyReadsRemainUninspected() throws {
        let fx = try fixture()
        try fx.exec("UPDATE attachment SET transfer_state=5")
        var db = try database(fx)
        let recent = try #require(db.recent(hours: 24, handleRowIds: nil, limit: 100).first { $0.rowid == 1 }?.attachments.first)
        let search = try #require(db.search(term: "hello", hours: 24, threshold: 0.6, match: .contains).matches.first { $0.rowid == 1 }?.attachments.first)
        for item in [recent, search] {
            #expect(item.native_transfer == nil)
            let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
            #expect(encoded["native_transfer"] is NSNull)
        }
    }

    @Test func projectionAndDecoderRejectUntrustedShapes() {
        #expect(!NativeAttachmentTransferDecoder.projection(columns: ["transfer_state", "injected); SELECT 1;"]).contains("injected"))
        for value: SQLiteReader.Row.Value in [.null, .text("5"), .real(5), .blob(Data([5]))] {
            let field = NativeAttachmentTransferDecoder.decode(storageType: .text("integer"), value: value)
            #expect(field.status == "wrong-type" && field.raw == nil && field.state == nil)
        }
        #expect(NativeAttachmentTransferDecoder.decode(storageType: nil, value: .integer(5)).status == "wrong-type")
    }
}
