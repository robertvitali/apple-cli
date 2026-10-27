import AppleKit
import Testing
@testable import MessagesKit

@Suite struct MessagesAttachmentObservationTests {
    private func fixture() throws -> ChatFixture {
        let fx = try ChatFixture()
        try fx.exec("INSERT INTO message_attachment_join VALUES(1,10); ALTER TABLE attachment ADD COLUMN transfer_state; UPDATE attachment SET transfer_state=5")
        return fx
    }
    private func read(_ fx: ChatFixture, expected: MessagesAttachmentMembership? = nil,
                      deadline: WorkerDeadline = .millisecondsFromNow(5000),
                      cancelled: @escaping () -> Bool = { false }) throws -> MessagesAttachmentObservation.Result {
        try MessagesAttachmentObservation.read(databasePath: fx.path, homeDirectory: fx.homePath,
            target: .init(chatRowid: 3, chatGUID: "iMessage;-;+12125550100", messageRowid: 1, messageGUID: "g1"),
            expectedMembership: expected, deadline: deadline, isCancelled: cancelled)
    }
    @Test func observedTransferAndFileStates() throws {
        let fx = try fixture()
        let initial = try read(fx)
        #expect(initial.outcome == .downloaded)
        try fx.exec("UPDATE attachment SET transfer_state=3 WHERE ROWID=10")
        #expect(try read(fx, expected: initial.membership).outcome == .pending)
        try fx.exec("UPDATE attachment SET transfer_state=6 WHERE ROWID=10")
        #expect(try read(fx, expected: initial.membership).outcome == .failed)
        try fx.exec("UPDATE attachment SET transfer_state=5, filename='~/Library/Messages/Attachments/absent' WHERE ROWID=10")
        #expect(try read(fx, expected: initial.membership).outcome == .missing)
        try fx.exec("UPDATE attachment SET filename='/outside/attachment' WHERE ROWID=10")
        #expect(try read(fx, expected: initial.membership).outcome == .unavailable)
    }
    @Test func changedMembershipDoesNotVerify() throws {
        let fx = try fixture()
        let initial = try read(fx)
        try fx.exec("INSERT INTO message_attachment_join VALUES(1,11)")
        #expect(throws: MessagesAttachmentObservation.Failure.membershipDrift) { try read(fx, expected: initial.membership) }
    }
    @Test func cancellationAndExpiredDeadlineStopObservation() throws {
        let fx = try fixture()
        #expect(throws: MessagesAttachmentObservation.Failure.cancelled) { try read(fx, cancelled: { true }) }
        #expect(throws: MessagesAttachmentObservation.Failure.deadline) { try read(fx, deadline: .millisecondsFromNow(0)) }
    }
}
