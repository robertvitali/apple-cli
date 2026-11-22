import AppleKit
import Foundation
import SQLite3
import TestSupport
import Testing
@testable import MessagesKit

struct MessageEventAttachmentSourceTests {
    private typealias Source = MessageEventAttachmentSource
    private let scratch = ScratchDirs("event-attachment-source")

    private func fixture(_ additions: String) throws -> String {
        let path = try scratch.directory().appendingPathComponent("source.sqlite").path
        var handle: OpaquePointer?
        try #require(sqlite3_open(path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        let schema = """
            CREATE TABLE chat_message_join(chat_id INTEGER, message_id INTEGER);
            CREATE INDEX membership ON chat_message_join(chat_id,message_id);
            CREATE TABLE message_attachment_join(message_id INTEGER,attachment_id INTEGER);
            CREATE INDEX links ON message_attachment_join(message_id,attachment_id);
            CREATE TABLE attachment(guid, transfer_state, total_bytes, mime_type, uti, filename, transfer_name, is_sticker, hide_attachment);
            """ + additions
        try #require(sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK)
        return path
    }

    private struct Group: Equatable {
        let chat, message: Int64
        let digest, status: String
    }

    private func scan(_ path: String, chat: Int64? = nil, remaining: Int = 500_000) throws -> [Group] {
        try SQLiteReader.withBoundedReadTransaction(path: path, limits: .init(
            timeout: 5, rows: 4096, bytes: 8 << 20, valueBytes: 1 << 20)) { db in
            let sql = try Source.query(in: db, filtered: chat != nil)
            let pass = MessageEventConversationLookup.Pass(id: chat, guid: chat.map { Data(String($0).utf8) })
            try MessageEventSourcePlan.requireStreaming(sql, bindings: pass.bindings, in: db)
            var groups: [Group] = []
            _ = try Source.scan(in: db, sql: sql, pass: pass, remaining: remaining) { c, m, digest, status in
                groups.append(Group(chat: c, message: m,
                    digest: digest.map { String(format: "%02x", $0) }.joined(), status: status))
            }
            return groups
        }
    }

    @Test(arguments: [true, false])
    func sparseLinksStayWithinTheScanBudgetAfterTheTableGrows(filtered: Bool) throws {
        let path = try fixture("""
            INSERT INTO chat_message_join VALUES (1,1);
            INSERT INTO attachment(guid) VALUES ('shared');
            INSERT INTO message_attachment_join VALUES (1,1);
            ANALYZE;
            WITH RECURSIVE n(i) AS (VALUES(2) UNION ALL SELECT i+1 FROM n WHERE i<100)
            INSERT INTO chat_message_join SELECT 1,i FROM n;
            INSERT INTO message_attachment_join SELECT message_id,1 FROM chat_message_join WHERE message_id>1;
            INSERT INTO chat_message_join VALUES (2,1);
            """)
        var limits = SQLiteReadTransaction.Limits(timeout: 5, rows: 4096, bytes: 8 << 20, valueBytes: 1 << 20)
        limits.fullScanSteps = 1024
        try MessageEventSourceSchema.withSnapshot(path: path, limits: limits, isCancelled: { false }) { db in
            let sql = try Source.query(in: db, filtered: filtered)
            let pass = MessageEventConversationLookup.Pass(id: filtered ? 1 : nil, guid: nil)
            try MessageEventSourcePlan.requireStreaming(sql, bindings: pass.bindings, in: db)
            var ids: [Int64] = []
            let count = try Source.scan(in: db, sql: sql, pass: pass, remaining: 101) { _, message, _, _ in
                ids.append(message)
            }
            let expected = (1...100).map(Int64.init) + (filtered ? [] : [1])
            #expect(ids == expected)
            #expect(count == expected.count)
        }
    }

    @Test func sharedAttachmentIsObservedForEachSelectedMembership() throws {
        let path = try fixture("""
            INSERT INTO attachment VALUES ('guid-a',3,57,'text/plain','public.text','local/path','sample',0,0);
            INSERT INTO chat_message_join VALUES (1,10),(2,10),(2,20),(2,30);
            INSERT INTO message_attachment_join VALUES (10,1),(20,1);
            """)
        let groups = try scan(path, remaining: 3)
        #expect(groups.map(\.chat) == [1,2,2])
        #expect(groups.map(\.message) == [10,10,20])
        #expect(groups.allSatisfy { $0.digest == "948c8bfe3832359346ce99dd083d2541fb04e936e702321597a6fdfbef2f782e" && $0.status == "available" })
        #expect(try scan(path, chat: 2, remaining: 2) == Array(groups.dropFirst()))
        #expect(try scan(path, chat: 3, remaining: 0).isEmpty)
        #expect(throws: MessageEventCaptureLimit.attachmentAssociations) { try scan(path, remaining: 2) }
    }

    @Test(arguments: [
        ("00efbbbf00", "available", "93f65775f84d0331a3cd376ed9d5a1f60192cfd8bbd921e5d2349b2278d79e95"),
        ("f48fbfbf", "available", "c5236a661a50c3992b67324ef8b56d1b06ca3afb9369791e201e58b423117316"),
        ("f4908080", "malformed", "a89e3b2d005fe993a33df8b2c0a4215565e89563a6a99a91e47f188d9af89a72"),
        ("e282", "malformed", "a89e3b2d005fe993a33df8b2c0a4215565e89563a6a99a91e47f188d9af89a72"),
    ])
    func transferNameFingerprintPreservesStoredUTF8(_ hex: String, _ status: String, _ digest: String) throws {
        let path = try fixture("""
            INSERT INTO attachment VALUES ('guid-a',3,57,'text/plain','public.text','local/path',CAST(x'\(hex)' AS TEXT),0,0);
            INSERT INTO chat_message_join VALUES (1,10);
            INSERT INTO message_attachment_join VALUES (10,1);
            """)
        #expect(try scan(path) == [Group(chat: 1, message: 10, digest: digest, status: status)])
    }

    @Test(arguments: ["efbbbf", "efbbbf616263", "61efbbbf", "80", "610062", ""])
    func invalidStoredGUIDRefusesTheScan(_ hex: String) throws {
        let path = try fixture("""
            INSERT INTO attachment(guid) VALUES (CAST(x'\(hex)' AS TEXT));
            INSERT INTO chat_message_join VALUES (1,1);
            INSERT INTO message_attachment_join VALUES (1,1);
            """)
        #expect(throws: Source.Failure.identity) { try scan(path) }
    }

    @Test func duplicateAndDanglingEdgesCannotPublishAGroup() throws {
        let prefix = """
            INSERT INTO attachment(guid) VALUES ('one');
            INSERT INTO chat_message_join VALUES (1,1);
            INSERT INTO message_attachment_join VALUES (1,1);
            """
        #expect(throws: Source.Failure.duplicate) {
            try scan(fixture(prefix + "INSERT INTO message_attachment_join VALUES (1,1)"))
        }
        #expect(throws: Source.Failure.identity) {
            try scan(fixture(prefix + "INSERT INTO message_attachment_join VALUES (1,77)"))
        }
    }

    @Test(arguments: [(1024,0), (1025,0), (64,1024), (65,1024)])
    func exactGroupAndGUIDBudgets(_ count: Int, _ size: Int) throws {
        let guid = size == 0 ? "NULL" : "printf('%0*d',\(size),i)"
        let path = try fixture("""
            INSERT INTO chat_message_join VALUES (1,1);
            WITH RECURSIVE seq(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM seq WHERE i<\(count))
            INSERT INTO attachment(rowid,guid) SELECT i,\(guid) FROM seq;
            INSERT INTO message_attachment_join SELECT 1,rowid FROM attachment;
            """)
        if count > 1024 {
            #expect(throws: MessageEventCaptureLimit.attachmentsPerMembership) { try scan(path) }
        } else if count * size > 65_536 {
            #expect(throws: MessageEventCaptureLimit.attachmentGUIDBytes) { try scan(path) }
        } else {
            #expect(try scan(path).count == 1)
        }
    }
}
