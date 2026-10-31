import AppleKit
import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesUndoSendTargetSnapshotTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_010)

    private func body(_ guid: String = "a10") -> Data {
        let value = NSMutableAttributedString(string: "hello \u{fffc}")
        value.addAttribute(NSAttributedString.Key("__kIMMessagePartAttributeName"), value: NSNumber(value: 0),
                           range: NSRange(location: 0, length: 5))
        value.addAttribute(NSAttributedString.Key("__kIMMessagePartAttributeName"), value: NSNumber(value: 1),
                           range: NSRange(location: 6, length: 1))
        value.addAttribute(NSAttributedString.Key("__kIMFileTransferGUIDAttributeName"), value: guid,
                           range: NSRange(location: 6, length: 1))
        return NSArchiver.archivedData(withRootObject: value)
    }

    private func fixture() throws -> ChatFixture {
        let fx = try ChatFixture()
        try fx.insertMessage(rowid: 60, guid: "synthetic-undo", attributedBody: body(), chatRowid: 3,
                             date: 800_000_000_000_000_000, cacheHasAttachments: true)
        try fx.exec("""
            ALTER TABLE message ADD COLUMN is_sent INTEGER;
            ALTER TABLE message ADD COLUMN date_edited INTEGER;
            ALTER TABLE message ADD COLUMN date_retracted INTEGER;
            ALTER TABLE message ADD COLUMN message_summary_info BLOB;
            UPDATE message SET is_from_me=1,is_sent=1,date_edited=0,date_retracted=0 WHERE ROWID=60;
            INSERT INTO message_attachment_join VALUES(60,10);
            """)
        return fx
    }

    private func read(_ fx: ChatFixture, index: Int = 1) throws -> MessagesUndoSendTargetSnapshot.Snapshot {
        try MessagesUndoSendTargetSnapshot.read(databasePath: fx.path, chat: .rowid(3), message: .rowid(60),
            partIndex: index, deadline: .millisecondsFromNow(5000), now: { now })
    }

    @Test func bindsSelectedAttachmentAndRetainsWholeMembership() throws {
        let fx = try fixture()
        let selected = try read(fx)
        #expect(selected.part.observation.identity.messageRowid == 60)
        #expect(selected.selectedAttachment?.rowid == 10)
        #expect(selected.attachments.count == 1)
        #expect(selected.part.selectedPart.index == 1)
        #expect(try read(fx, index: 0).selectedAttachment == nil)
    }

    @Test(arguments: [
        "DELETE FROM message_attachment_join WHERE message_id=60",
        "INSERT INTO message_attachment_join VALUES(60,10)",
        "UPDATE message_attachment_join SET attachment_id=999 WHERE message_id=60",
        "UPDATE message_attachment_join SET attachment_id=10.5 WHERE message_id=60",
        "UPDATE attachment SET guid='different' WHERE ROWID=10",
        "UPDATE attachment SET guid=X'613130' WHERE ROWID=10",
        "UPDATE message SET is_from_me=0 WHERE ROWID=60",
        "UPDATE message SET is_sent=0 WHERE ROWID=60",
        "UPDATE message SET service='RCS' WHERE ROWID=60",
        "UPDATE message SET date=799999000000000000 WHERE ROWID=60"
    ]) func refusesInvalidMembershipOrEligibility(_ sql: String) throws {
        let fx = try fixture()
        try fx.exec(sql)
        #expect(throws: (any Error).self) { try read(fx) }
    }

    @Test func malformedUnselectedMembershipStillRefuses() throws {
        let fx = try fixture()
        try fx.exec("INSERT INTO message_attachment_join VALUES(60,999)")
        #expect(throws: (any Error).self) { try read(fx, index: 0) }
    }

    @Test func readsBodyAndMembershipFromPinnedSnapshot() throws {
        let fx = try fixture()
        try fx.exec("PRAGMA journal_mode=WAL; UPDATE message SET date=date WHERE ROWID=60")
        let changed = body("changed-guid").map { String(format: "%02x", $0) }.joined()
        let captured = try SQLiteReader.withBoundedReadTransaction(path: fx.path,
            limits: .init(timeout: 5, rows: 4096, bytes: 16_777_216, valueBytes: 1_048_576)) { scope in
            var pinned = false
            try scope.forEachRow("SELECT guid FROM message WHERE ROWID=60") { _ in pinned = true }
            #expect(pinned)
            try fx.exec("UPDATE attachment SET guid='changed-guid' WHERE ROWID=10; UPDATE message SET attributedBody=X'\(changed)' WHERE ROWID=60")
            return try MessagesUndoSendTargetSnapshot.read(in: scope, chat: .rowid(3), message: .rowid(60),
                partIndex: 1, deadline: .millisecondsFromNow(5000), now: { now })
        }
        #expect(captured.part.selectedPart.attachmentGUID == "a10")
        #expect(captured.selectedAttachment?.guid == Data("a10".utf8))
        let fresh = try read(fx)
        #expect(fresh.part.selectedPart.attachmentGUID == "changed-guid")
        #expect(fresh.selectedAttachment?.guid == Data("changed-guid".utf8))
    }

    @Test func cancellationPrecedesDatabaseOpen() throws {
        #expect(throws: WorkerProtocolError.cancelled) {
            try MessagesUndoSendTargetSnapshot.read(databasePath: "/not-a-database", chat: .rowid(3),
                message: .rowid(60), partIndex: 1, deadline: .millisecondsFromNow(5000), now: { now },
                isCancelled: { true })
        }
    }
}
