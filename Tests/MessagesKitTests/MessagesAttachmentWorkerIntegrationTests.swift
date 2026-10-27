@testable import AppleKit
import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesAttachmentWorkerIntegrationTests {
    private func fixture() throws -> ChatFixture {
        let fx = try ChatFixture()
        let body = NSMutableAttributedString(string: "\u{fffc}")
        body.addAttribute(NSAttributedString.Key("__kIMMessagePartAttributeName"), value: NSNumber(value: 0), range: NSRange(location: 0, length: 1))
        body.addAttribute(NSAttributedString.Key("__kIMFileTransferGUIDAttributeName"), value: "a10", range: NSRange(location: 0, length: 1))
        try fx.insertMessage(rowid: 60, guid: "synthetic-attachment-message", attributedBody: NSArchiver.archivedData(withRootObject: body),
            chatRowid: 3, date: fx.base, cacheHasAttachments: true)
        try fx.exec("INSERT INTO message_attachment_join VALUES(60,10); ALTER TABLE attachment ADD COLUMN transfer_state; UPDATE attachment SET transfer_state=5")
        return fx
    }
    private func command() throws -> WorkerCommand {
        let id = try #require(MessagesAttachmentRetrievalState.Identity(rowid: 10, guid: "a10"))
        let membership = try #require(MessagesAttachmentMembership([id]))
        let payload = try MessagesAttachmentRetrievalRequest(chatRowid: 3, chatGUID: "iMessage;-;+12125550100",
            messageRowid: 60, messageGUID: "synthetic-attachment-message", nativePartIndex: 0, nativePartGUID: nil, selectedAttachmentGUID: "a10",
            participantHandles: ["+12125550100"], isFromMe: false,
            membershipCount: membership.count, membershipSHA256: membership.sha256)
        return try WorkerCommand(name: "messages.attachment.retrieve", payload: payload.workerPayloadData())
    }
    private func request(_ command: WorkerCommand) -> WorkerRequest {
        let identity = WorkerProcessIdentity(pid: 1, parentPID: 0, uid: 1, gid: 1,
            startTimeMicroseconds: 1, executableDevice: 1, executableInode: 1, executablePath: "/tmp/apple")
        return WorkerRequest(schemaVersion: 1, operationID: UUID(), nonce: UUID(), deadline: .millisecondsFromNow(5000),
            parent: identity, workerExecutable: .init(uid: 1, gid: 1, device: 1, inode: 1, path: "/tmp/apple"), command: command)
    }
    @Test func downloadedAttachmentReturnsVerifiedResultWithoutUI() throws {
        let fx = try fixture(), driver = AttachmentNoUIDriver()
        let registry = MessagesAttachmentRetrievalWorkerRegistry(driver: driver, databasePath: fx.path, homeDirectory: fx.homePath)
        let command = try command(), request = request(command)
        let operation = try #require(registry.operation(for: command))
        let result = try operation.run(request, deadline: request.deadline)
        #expect(result.category == .ack)
        #expect(result.detail == "attachment-retrieval-already-downloaded-verified")
        #expect(driver.calls == 0)
    }
    @Test func identityDriftFailsWithoutUI() throws {
        let fx = try fixture(), driver = AttachmentNoUIDriver()
        let registry = MessagesAttachmentRetrievalWorkerRegistry(driver: driver, databasePath: fx.path, homeDirectory: fx.homePath)
        let command = try command(), request = request(command)
        try fx.exec("UPDATE attachment SET guid='changed-attachment' WHERE ROWID=10")
        let operation = try #require(registry.operation(for: command))
        let result = try operation.run(request, deadline: request.deadline)
        #expect(result.category == .failed)
        #expect(driver.calls == 0)
    }
    @Test func registryRejectsWrongNameAndMalformedPayload() throws {
        let driver = AttachmentNoUIDriver()
        let registry = MessagesAttachmentRetrievalWorkerRegistry(driver: driver, databasePath: "/unused", homeDirectory: "/unused")
        #expect(registry.operation(for: try WorkerCommand(name: "other", payload: command().payload)) == nil)
        #expect(registry.operation(for: try WorkerCommand(name: "messages.attachment.retrieve", payload: Data("{}".utf8))) == nil)
        #expect(driver.calls == 0)
    }
}

private final class AttachmentNoUIDriver: MessagesReactionAXDriving {
    var calls = 0
    private func refused() throws -> Never { calls += 1; throw MessagesAXNavigationError.axFailure }
    func checkAccessibilityTrusted(prompt: Bool) -> Bool { calls += 1; return false }
    func openMessages(url: URL, deadline: WorkerDeadline) throws -> MessagesAXProcess { try refused() }
    func canonicalMessagesProcess(deadline: WorkerDeadline) throws -> MessagesAXProcess { try refused() }
    func messagesProcessIsFrontmost(_ process: MessagesAXProcess, deadline: WorkerDeadline) throws -> Bool { try refused() }
    func focusedElement(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? { try refused() }
    func reactActionTitles(deadline: WorkerDeadline) throws -> [String] { try refused() }
    func customEmojiSearchPlan(for emoji: String, deadline: WorkerDeadline) throws -> MessagesCustomEmojiSearchPlan { try refused() }
    func pressCustomEmojiChooserKey(_ key: MessagesCustomEmojiChooserKey, process: MessagesAXProcess, deadline: WorkerDeadline) throws { try refused() }
    func detachedCustomEmojiPopover(process: MessagesAXProcess, deadline: WorkerDeadline) throws -> (any MessagesAXElement)? { try refused() }
}
