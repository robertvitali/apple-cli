import AppleKit
import Testing
@testable import MessagesKit

@Suite struct MessagesAttachmentTargetSnapshotTests {
    private func read(_ fx: ChatFixture, chat: Int64 = 3, guid: String = "g6") throws -> [MessagesAttachmentSnapshot.Item] {
        try SQLiteReader.withBoundedReadTransaction(path: fx.path,
            limits: .init(timeout: 5, rows: 2048, bytes: 16 * 1024 * 1024, valueBytes: 65536), isCancelled: { false }) {
            try MessagesAttachmentTargetSnapshot.read(in: $0, chatRowid: chat,
                chatGUID: "iMessage;-;+12125550100", messageRowid: 6, messageGUID: guid)
        }
    }

    @Test func exactMembershipAndDrift() throws {
        let fx = try ChatFixture()
        #expect(try read(fx).map(\.identity.rowid).sorted() == [10, 11])
        #expect(throws: MessagesAttachmentTargetSnapshot.Failure.targetDrift) { try read(fx, chat: 1) }
        #expect(throws: MessagesAttachmentTargetSnapshot.Failure.targetDrift) { try read(fx, guid: "different") }
        try fx.exec("UPDATE message SET guid='changed' WHERE ROWID=6")
        #expect(throws: MessagesAttachmentTargetSnapshot.Failure.targetDrift) { try read(fx) }
    }

    @Test func duplicateJoinIsNotHidden() throws {
        let fx = try ChatFixture()
        try fx.exec("INSERT INTO chat_message_join VALUES(3,6)")
        #expect(throws: MessagesAttachmentTargetSnapshot.Failure.targetDrift) { try read(fx) }
    }

    @Test func malformedJoinStorageIsRejected() throws {
        let fx = try ChatFixture()
        try fx.exec("""
            ALTER TABLE chat_message_join RENAME TO original_chat_message_join;
            CREATE TABLE chat_message_join(chat_id, message_id);
            INSERT INTO chat_message_join VALUES(3.0,6);
            """)
        #expect(throws: MessagesAttachmentTargetSnapshot.Failure.targetDrift) { try read(fx) }
    }

    @Test func shadowRowidAndInvalidTargetAreRejected() throws {
        let fx = try ChatFixture()
        #expect(throws: MessagesAttachmentTargetSnapshot.Failure.invalidTarget) { try read(fx, chat: 0) }
        try fx.exec("ALTER TABLE message ADD COLUMN _rowid_ INTEGER")
        #expect(throws: MessagesAttachmentTargetSnapshot.Failure.unsupportedSchema) { try read(fx) }
    }
}
