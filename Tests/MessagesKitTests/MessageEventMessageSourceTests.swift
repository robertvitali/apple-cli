import AppleKit
import CryptoKit
import Foundation
import SQLite3
import TestSupport
import Testing
@testable import MessagesKit

struct MessageEventMessageSourceTests {
    private typealias Source = MessageEventMessageSource
    private let scratch = ScratchDirs("event-message-source")

    private func database(_ ddl: String = "", typedEdges: Bool = true, _ body: (SQLiteReadTransaction) throws -> Void) throws {
        let path = try scratch.directory().appendingPathComponent("messages.sqlite").path
        var db: OpaquePointer?
        try #require(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let edgeType = typedEdges ? "INTEGER" : ""
        let sql = """
            CREATE TABLE chat(guid TEXT);
            CREATE UNIQUE INDEX chatGUID ON chat(guid);
            CREATE TABLE message(guid TEXT, text, message_summary_info, is_from_me, date_read);
            CREATE TABLE chat_message_join(chat_id \(edgeType), message_id \(edgeType));
            CREATE INDEX membership ON chat_message_join(chat_id, message_id);
            INSERT INTO chat VALUES ('first'), ('second');
            INSERT INTO message VALUES ('m1', CAST(x'80' AS TEXT), x'0080', 3, -7),
                                       ('m2', '', '', 0, NULL);
            INSERT INTO chat_message_join VALUES (2,2), (1,1);
            """ + ddl
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        try SQLiteReader.withBoundedReadTransaction(path: path, limits: .init(
            timeout: 3, rows: 4096, bytes: 1 << 20, valueBytes: 1 << 16), body)
    }

    @Test func hashesMalformedTextAndRetainsValidBytesInSlices() throws {
        let cases: [([UInt8], Bool)] = [
            ([], true), ([0, 0x41, 0], true), ([0xef, 0xbb, 0xbf], true),
            ([0xf4, 0x8f, 0xbf, 0xbf], true), ([0xf4, 0x90, 0x80, 0x80], false),
            ([0xed, 0xa0, 0x80], false), ([0xc0, 0x80], false), ([0xe2, 0x82], false),
        ]
        for (suffix, valid) in cases {
            let bytes = (Data([0xff]) + Data(suffix)).dropFirst()
            let row = SQLiteReader.Row(values: ["text_t": .text("text"), "text_v": .blob(bytes)])
            let result = try Source.Observation(.text, row: row)
            #expect(result.status == (valid ? .available : .malformed))
            #expect(result.bytes == (valid ? bytes : Data(SHA256.hash(data: bytes))))
        }
    }

    @Test func capturedFieldsPreserveV1OrderTypesAndRawBytes() throws {
        #expect(Source.Field.allCases.map(\.rawValue) == [
            "text","attributedBody","thread_originator_guid","thread_originator_part","message_summary_info",
            "date_edited","date_retracted","associated_message_type","associated_message_guid",
            "associated_message_emoji","is_from_me","handle_id","date","error","is_delivered",
            "date_delivered","is_read","date_read"])
        try database { db in
            let sql = try Source.query(in: db, filtered: false)
            _ = try MessageEventSourcePlan.requireStreaming(sql, bindings: [], in: db)
            var ids: [Int64] = []
            try db.forEachRow(sql) { row in
                let member = try Source.Membership(row, pass: .init(id: nil, guid: nil))
                ids.append(member.messageRowID)
                let summary = try Source.Observation(.summary, row: row)
                let text = try Source.Observation(.text, row: row)
                let flag = try Source.Observation(.isFromMe, row: row)
                let date = try Source.Observation(.dateRead, row: row)
                #expect(try Source.Observation(.attributedBody, row: row).status == .missingSchema)
                if member.messageRowID == 1 {
                    #expect(member.chatGUID == Data("first".utf8) && member.messageGUID == Data("m1".utf8))
                    #expect(text.status == .malformed && text.bytes == Data(SHA256.hash(data: Data([0x80]))))
                    #expect(summary.status == .available && summary.bytes == Data([0,128]))
                    #expect(flag.status == .invalidValue && flag.bytes == Data([0,0,0,0,0,0,0,3]))
                    #expect(date.status == .available && date.bytes == Data([255,255,255,255,255,255,255,249]))
                } else {
                    #expect(text.status == .available && text.bytes.isEmpty)
                    #expect(summary.status == .wrongType && summary.bytes.isEmpty)
                    #expect(flag.status == .available && flag.bytes == Data(repeating: 0, count: 8))
                    #expect(date.status == .null && date.bytes.isEmpty)
                }
            }
            #expect(ids == [1,2])
        }
    }

    @Test func summaryPassKeepsExactFilteredMembershipWithoutSelectingBody() throws {
        try database { db in
            let sql = try Source.query(in: db, filtered: true, summaryOnly: true)
            let pass = MessageEventConversationLookup.Pass(id: 2, guid: Data("second".utf8))
            _ = try MessageEventSourcePlan.requireStreaming(sql, bindings: pass.bindings, in: db)
            var count = 0
            try db.forEachRow(sql, pass.bindings) { row in
                let member = try Source.Membership(row, pass: pass)
                #expect(member.chatRowID == 2 && member.messageRowID == 2)
                #expect(row.values["text_t"] == nil && row.values["text_v"] == nil)
                #expect(try Source.Observation(.summary, row: row).status == .wrongType)
                #expect(throws: Source.Failure.invalidMembership) {
                    try Source.Membership(row, pass: .init(id: 2, guid: Data("different".utf8)))
                }
                count += 1
            }
            #expect(count == 1)
        }
    }

    @Test func unindexedFilteredOrderingIsRefusedBeforeCapture() throws {
        #expect(throws: MessageEventSourcePlan.Failure.unsupportedPlan) {
            try database(typedEdges: false) { db in
                let sql = try Source.query(in: db, filtered: true, summaryOnly: true)
                _ = try MessageEventSourcePlan.requireStreaming(sql, bindings: ["2"], in: db)
            }
        }
    }

    @Test(arguments: ["INSERT INTO chat_message_join VALUES (1,99)",
                      "INSERT INTO chat_message_join VALUES ('1',1)",
                      "UPDATE message SET guid=CAST(x'80' AS TEXT) WHERE rowid=1",
                      "UPDATE chat SET guid='bad'||char(10) WHERE rowid=1"])
    func invalidOrOrphanedEdgesCannotAcquireAnIdentity(_ bad: String) throws {
        #expect(throws: Source.Failure.invalidMembership) {
            try database(bad, typedEdges: false) { db in
                try db.forEachRow(Source.query(in: db, filtered: false)) { row in
                    _ = try Source.Membership(row, pass: .init(id: nil, guid: nil))
                }
            }
        }
    }
}
