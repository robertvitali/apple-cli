import AppleKit
import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesUndoSendPostSnapshotTests {
    private func fixture() throws -> ChatFixture {
        let fx = try ChatFixture()
        try fx.insertMessage(rowid: 60, guid: "synthetic-post-undo", chatRowid: 3,
                             date: 800_000_000_000_000_000)
        try fx.exec("""
            ALTER TABLE message ADD COLUMN is_sent INTEGER;
            ALTER TABLE message ADD COLUMN date_edited INTEGER;
            ALTER TABLE message ADD COLUMN date_retracted INTEGER;
            ALTER TABLE message ADD COLUMN message_summary_info BLOB;
            UPDATE message SET is_from_me=1,is_sent=1,text=NULL,attributedBody=NULL,
                date_edited=800000001000000000,date_retracted=0 WHERE ROWID=60;
            """)
        return fx
    }

    private func read(_ fx: ChatFixture) throws -> MessagesUndoSendPostSnapshot.Snapshot {
        try MessagesUndoSendPostSnapshot.read(databasePath: fx.path, chat: .rowid(3),
            message: .rowid(60), deadline: .millisecondsFromNow(5000))
    }

    @Test func capturesAbsentBodyWithoutInventingRetraction() throws {
        let result = try read(fixture())
        #expect(result.observation.textUTF8 == .null)
        #expect(result.observation.attributedBody == .null)
        #expect(result.observation.dateRetracted == .value(0))
        #expect(result.observation.summaryInfo == .null)
        #expect(result.attachments.isEmpty)
    }

    @Test func preservesMalformedAndNullMarkers() throws {
        let fx = try fixture()
        try fx.exec("UPDATE message SET date_retracted='bad',date_edited=NULL,message_summary_info='bad' WHERE ROWID=60")
        let result = try read(fx)
        #expect(result.observation.dateRetracted == .wrongType)
        #expect(result.observation.dateEdited == .null)
        #expect(result.observation.summaryInfo == .wrongType)
    }

    @Test func capturesRemainingAttachmentMembership() throws {
        let fx = try fixture()
        try fx.exec("INSERT INTO message_attachment_join VALUES(60,10)")
        let result = try read(fx)
        #expect(result.attachments.map(\.rowid) == [10])
        #expect(result.attachments.first?.guid == Data("a10".utf8))
    }

    @Test(arguments: [
        "DELETE FROM message WHERE ROWID=60",
        "DELETE FROM chat_message_join WHERE message_id=60",
        "INSERT INTO message_attachment_join VALUES(60,999)",
        "INSERT INTO message_attachment_join VALUES(60,10); INSERT INTO message_attachment_join VALUES(60,10)"
    ]) func invalidIdentityOrMembershipFails(_ sql: String) throws {
        let fx = try fixture()
        try fx.exec(sql)
        #expect(throws: (any Error).self) { try read(fx) }
    }

    @Test func fieldsAndAttachmentMembershipShareSnapshot() throws {
        let fx = try fixture()
        try fx.exec("PRAGMA journal_mode=WAL; INSERT INTO message_attachment_join VALUES(60,10)")
        let result = try SQLiteReader.withBoundedReadTransaction(path: fx.path,
            limits: .init(timeout: 5, rows: 4096, bytes: 16_777_216, valueBytes: 1_048_576)) { scope in
            var pinned = false
            try scope.forEachRow("SELECT guid FROM message WHERE ROWID=60") { _ in pinned = true }
            #expect(pinned)
            try fx.exec("UPDATE message SET date_retracted=800000002000000000 WHERE ROWID=60; DELETE FROM message_attachment_join WHERE message_id=60")
            return try MessagesUndoSendPostSnapshot.read(in: scope, chat: .rowid(3),
                message: .rowid(60), deadline: .millisecondsFromNow(5000))
        }
        #expect(result.observation.dateRetracted == .value(0))
        #expect(result.attachments.map(\.rowid) == [10])
        let current = try read(fx)
        #expect(current.observation.dateRetracted == .value(800_000_002_000_000_000))
        #expect(current.attachments.isEmpty)
    }

    @Test func cancellationPrecedesDatabaseOpen() throws {
        #expect(throws: WorkerProtocolError.cancelled) {
            try MessagesUndoSendPostSnapshot.read(databasePath: "/not-a-database", chat: .rowid(3),
                message: .rowid(60), deadline: .millisecondsFromNow(5000), isCancelled: { true })
        }
    }
}
