import Foundation
import Testing
import AppleKit
@testable import MessagesKit

@Suite struct NativeAttachmentFlagsTests {
    private let columns = ["is_sticker", "hide_attachment"]

    private func fixture(columns: [String] = ["is_sticker", "hide_attachment"]) throws -> ChatFixture {
        let fx = try ChatFixture()
        let optional = columns.map { ", \($0)" }.joined()
        try fx.exec("""
            DROP TABLE attachment;
            CREATE TABLE attachment(ROWID INTEGER PRIMARY KEY, guid TEXT\(optional));
            INSERT INTO attachment(ROWID,guid) VALUES (1001,'synthetic-attachment-one'),(1002,'synthetic-attachment-two');
            INSERT INTO message_attachment_join VALUES (1,1001),(2,1002);
            """)
        return fx
    }

    private func database(_ fx: ChatFixture) throws -> ChatDB {
        try ChatDB(path: fx.path, book: AddressBook(contacts: [:]), copyToTemp: false,
                   homeDirectoryForTilde: fx.homePath)
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    @Test func missingAndNullColumnsRemainDistinct() throws {
        for present in [[], ["is_sticker"], ["hide_attachment"], columns] {
            let fx = try fixture(columns: present)
            var db = try database(fx)
            let item = try #require(db.exactGet(chat: .rowid(3), message: .rowid(1)).1.attachments.first)
            let flags = try #require(item.native_flags)
            let encoded = try json(flags)
            #expect(Set(encoded.keys) == Set(columns))
            for name in columns {
                let field = try #require(encoded[name] as? [String: Any])
                #expect(Set(field.keys) == ["status", "raw", "value"])
                #expect(field["status"] as? String == (present.contains(name) ? "null" : "missing-schema"))
                #expect(field["raw"] is NSNull && field["value"] is NSNull)
            }
            #expect(item.is_sticker == nil && item.hide_attachment == nil)
        }
    }

    @Test func storageMatrixPreservesLegacyValuesAndExactIdentity() throws {
        let cases: [(String, String, Int64?, Bool?, Bool?)] = [
            ("NULL", "null", nil, nil, nil),
            ("0", "available", 0, false, false),
            ("1", "available", 1, true, true),
            ("2", "invalid-boolean", 2, nil, true),
            ("-1", "invalid-boolean", -1, nil, true),
            ("9223372036854775807", "invalid-boolean", Int64.max, nil, true),
            ("-9223372036854775808", "invalid-boolean", Int64.min, nil, true),
            ("0.7", "wrong-type", nil, nil, false),
            ("1.7", "wrong-type", nil, nil, true),
            ("'1'", "wrong-type", nil, nil, true),
            ("'0'", "wrong-type", nil, nil, false),
            ("'synthetic'", "wrong-type", nil, nil, nil),
            ("X'ff'", "wrong-type", nil, nil, nil)
        ]
        for column in columns {
            for (sql, status, raw, strict, legacy) in cases {
                let fx = try fixture()
                try fx.exec("UPDATE attachment SET \(column)=\(sql) WHERE ROWID=1001")
                var db = try database(fx)
                let exact = try #require(db.exactGet(chat: .rowid(3), message: .rowid(1)).1.attachments.first)
                let flags = try #require(exact.native_flags)
                let field = column == "is_sticker" ? flags.is_sticker : flags.hide_attachment
                let other = column == "is_sticker" ? flags.hide_attachment : flags.is_sticker
                #expect(field.status == status && field.raw == raw && field.value == strict)
                #expect(other.status == "null" && other.raw == nil && other.value == nil)
                #expect((column == "is_sticker" ? exact.is_sticker : exact.hide_attachment) == legacy)
                #expect(exact.rowid == 1001 && exact.guid == "synthetic-attachment-one")
                let recent = try #require(db.recent(hours: 24, handleRowIds: nil, limit: 100).first { $0.rowid == 1 }?.attachments.first)
                #expect(recent.native_flags == nil)
                #expect(exact.is_sticker == recent.is_sticker && exact.hide_attachment == recent.hide_attachment)
                let encoded = try json(field)
                if raw == nil { #expect(encoded["raw"] is NSNull) }
                if strict == nil { #expect(encoded["value"] is NSNull) }
            }
        }
    }

    @Test func historyAndGetKeepFlagsOnTheirJoinedAttachment() throws {
        let fx = try fixture()
        try fx.exec("UPDATE attachment SET is_sticker=1,hide_attachment=0 WHERE ROWID=1001; UPDATE attachment SET is_sticker=0,hide_attachment=1 WHERE ROWID=1002")
        var db = try database(fx)
        let page = try db.exactHistory(chat: .rowid(3), limit: 100, order: .desc, cursor: nil)
        for (message, attachment, sticker) in [(Int64(1), Int64(1001), true), (2, 1002, false)] {
            let item = try #require(page.items.first { $0.rowid == message })
            #expect(item.attachments.map(\.rowid) == [attachment])
            let flags = try #require(item.attachments.first?.native_flags)
            #expect(flags.is_sticker.value == sticker && flags.hide_attachment.value == !sticker)
            let exact = try db.exactGet(chat: .rowid(3), message: .rowid(message)).1
            #expect(exact.attachments.first?.native_flags == flags)
        }
    }

    @Test func legacyRecentAndSearchEncodeExplicitUninspectedNull() throws {
        let fx = try fixture()
        var db = try database(fx)
        let recent = try #require(db.recent(hours: 24, handleRowIds: nil, limit: 100).first { $0.rowid == 1 }?.attachments.first)
        let search = try #require(db.search(term: "hello", hours: 24, threshold: 0.6, match: .contains).matches.first { $0.rowid == 1 }?.attachments.first)
        for item in [recent, search] {
            #expect(item.native_flags == nil)
            #expect(try json(item)["native_flags"] is NSNull)
        }
    }

    @Test func strictProjectionDoesNotMaterializeWrongTypeBytes() throws {
        let fx = try fixture()
        try fx.exec("UPDATE attachment SET is_sticker=CAST(X'ff' AS TEXT),hide_attachment=X'ff' WHERE ROWID=1001")
        let reader = try SQLiteReader(path: fx.path, copyToTemp: false)
        let projected = NativeAttachmentFlagsDecoder.projection(columns: Set(columns + ["injected); SELECT 1;"]))
        #expect(!projected.contains("injected"))
        let row = try #require(reader.rows("SELECT \(projected) FROM attachment a WHERE ROWID=1001").first)
        let flags = NativeAttachmentFlagsDecoder.decode(row)
        for field in [flags.is_sticker, flags.hide_attachment] {
            #expect(field.status == "wrong-type" && field.raw == nil && field.value == nil)
        }
        // The existing raw legacy TEXT projection still rejects malformed UTF8;
        // adding strict flags must not silently change that whole-query behavior.
        var db = try database(fx)
        #expect(throws: (any Error).self) { try db.exactGet(chat: .rowid(3), message: .rowid(1)) }
    }

    @Test func sharedStrictBooleanDecoderRejectsMismatchedProjectionValues() {
        for value: SQLiteReader.Row.Value in [.null, .text("1"), .real(1), .blob(Data([1]))] {
            let field = NativeMessageStatusDecoder.boolean(storageType: .text("integer"), value: value)
            #expect(field.status == "wrong-type" && field.raw == nil && field.value == nil)
        }
        let missing = NativeMessageStatusDecoder.boolean(storageType: nil, value: .integer(1))
        #expect(missing.status == "wrong-type" && missing.raw == nil && missing.value == nil)
    }
}
