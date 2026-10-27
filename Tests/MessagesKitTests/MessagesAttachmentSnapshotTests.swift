import Foundation
import Testing
import AppleKit
@testable import MessagesKit

@Suite struct MessagesAttachmentSnapshotTests {
    private func fixture() throws -> ChatFixture {
        let fx = try ChatFixture()
        try fx.exec("INSERT INTO message_attachment_join VALUES(1,10)")
        return fx
    }

    private func read(_ fx: ChatFixture, cancelled: @escaping () -> Bool = { false }) throws -> [MessagesAttachmentSnapshot.Item] {
        try SQLiteReader.withBoundedReadTransaction(path: fx.path,
            limits: .init(timeout: 5, rows: 2_048, bytes: 16 * 1_024 * 1_024, valueBytes: 65_536), isCancelled: cancelled) {
                try MessagesAttachmentSnapshot.read(in: $0, messageRowid: 1)
            }
    }

    @Test func completeSnapshotFeedsActualFileVerification() throws {
        let fx = try fixture()
        try fx.exec("ALTER TABLE attachment ADD COLUMN transfer_state; UPDATE attachment SET transfer_state=5")
        let items = try read(fx)
        #expect(!items.isEmpty)
        let probe = MessagesAttachmentFileInspection(homeDirectory: fx.homePath)
        let observations = try items.map {
            MessagesAttachmentRetrievalState.Observation(identity: $0.identity, transfer: $0.transfer,
                                                          file: try probe.inspect(filename: $0.filename))
        }
        // Fixture message 1 has a real, confined attachment.
        #expect(MessagesAttachmentRetrievalState.evaluate(expected: items.map(\.identity), observed: observations, completeJoin: true) == .downloaded)
    }

    @Test func danglingAndDuplicateMembershipAreRejected() throws {
        let orphan = try fixture()
        try orphan.exec("INSERT INTO message_attachment_join VALUES(1,999999)")
        #expect(throws: MessagesAttachmentSnapshot.Failure.incompleteIdentity) { try read(orphan) }
        let duplicate = try fixture()
        try duplicate.exec("INSERT INTO message_attachment_join SELECT message_id,attachment_id FROM message_attachment_join WHERE message_id=1")
        #expect(throws: MessagesAttachmentSnapshot.Failure.duplicateIdentity) { try read(duplicate) }
    }

    @Test func optionalSchemaAndMalformedNativeStateStayUnavailable() throws {
        let fx = try fixture()
        let missing = try #require(read(fx).first)
        #expect(missing.transfer.status == "missing-schema")
        try fx.exec("ALTER TABLE attachment ADD COLUMN transfer_state; UPDATE attachment SET transfer_state='5'")
        let malformed = try #require(read(fx).first)
        #expect(malformed.transfer.status == "wrong-type")
        #expect(malformed.transfer.raw == nil)
        #expect(throws: SQLiteReadTransaction.Failure.cancelled) { try read(fx, cancelled: { true }) }
    }

    @Test func malformedEdgeStorageAndGuidDoNotCoerce() throws {
        let fx = try fixture()
        try fx.exec("""
            ALTER TABLE message_attachment_join RENAME TO original_message_attachment_join;
            CREATE TABLE message_attachment_join(message_id INTEGER, attachment_id);
            INSERT INTO message_attachment_join SELECT message_id,attachment_id FROM original_message_attachment_join;
            INSERT INTO message_attachment_join VALUES(1,10.0);
            """)
        #expect(throws: MessagesAttachmentSnapshot.Failure.incompleteIdentity) { try read(fx) }
        let guid = try fixture()
        try guid.exec("UPDATE attachment SET guid=CAST(X'ff' AS TEXT)")
        #expect(throws: SQLiteReadTransaction.Failure.invalidText) { try read(guid) }
    }
}
