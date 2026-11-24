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
    @Test func confirmationOnlyObservesAndCannotStartAPendingDownload() throws {
        let fx = try fixture(), driver = AttachmentNoUIDriver()
        let registry = MessagesAttachmentRetrievalWorkerRegistry(driver: driver, databasePath: fx.path, homeDirectory: fx.homePath)
        let observe = try WorkerCommand(name: WorkerCommand.attachmentObservation, payload: command().payload)
        let frame = request(observe)
        let operation = try #require(registry.operation(for: observe))
        #expect(try operation.run(frame, deadline: frame.deadline).category == .ack)
        try fx.exec("UPDATE attachment SET transfer_state=0 WHERE ROWID=10")
        #expect(try operation.run(frame, deadline: frame.deadline).category == .failed)
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

extension MessagesAttachmentWorkerIntegrationTests {
    @Test(arguments: WorkerAttachmentStatus.allCases)
    func statusObservesExactPartWithoutUI(_ expected: WorkerAttachmentStatus) throws {
        let fx = try fixture(), driver = AttachmentNoUIDriver()
        switch expected {
        case .downloaded: break
        case .pending: try fx.exec("UPDATE attachment SET transfer_state=0 WHERE ROWID=10")
        case .failed: try fx.exec("UPDATE attachment SET transfer_state=7 WHERE ROWID=10")
        case .missing:
            try fx.exec("UPDATE attachment SET filename='~/Library/Messages/Attachments/no-such-file' WHERE ROWID=10")
        case .unavailable:
            try fx.exec("UPDATE attachment SET filename='../outside' WHERE ROWID=10")
        }
        let registry = MessagesAttachmentRetrievalWorkerRegistry(driver: driver, databasePath: fx.path, homeDirectory: fx.homePath)
        let status = try WorkerCommand(name: WorkerCommand.attachmentStatus, payload: command().payload)
        let frame = request(status)
        let operation = try #require(registry.operation(for: status))
        let result = try operation.run(frame, deadline: frame.deadline)
        #expect(result.category == .ack)
        #expect(result.detail == expected.detail)
        #expect(driver.calls == 0)
    }

    @Test func statusChecksTransferAgainAfterFileObservation() throws {
        let fx = try fixture()
        let data = try #require(try command().payload)
        let payload = try JSONDecoder().decode(MessagesAttachmentRetrievalRequest.self, from: data)
        let observation = MessagesAttachmentDownloadObservation(payload: payload, databasePath: fx.path,
                                                               homeDirectory: fx.homePath)
        #expect(throws: MessagesAXNavigationError.targetDrift) {
            try observation.selectedStatus(deadline: .millisecondsFromNow(5000)) { _ in
                try fx.exec("UPDATE attachment SET transfer_state=7 WHERE ROWID=10")
                return .downloaded
            }
        }
    }

    @Test func statusOfReadablePartIsIndependentOfFailedSibling() throws {
        let fx = try fixture(), driver = AttachmentNoUIDriver()
        try fx.exec("INSERT INTO message_attachment_join VALUES(60,11); UPDATE attachment SET transfer_state=7 WHERE ROWID=11")
        let deadline = WorkerDeadline.millisecondsFromNow(5000)
        let target = try MessagesAttachmentTargetResolver.read(databasePath: fx.path, chat: .rowid(3), message: .rowid(60),
            partIndex: 0, sandboxPrefix: nil, deadline: deadline)
        let status = try WorkerCommand(name: WorkerCommand.attachmentStatus, payload: target.request.workerPayloadData())
        let frame = request(status)
        let registry = MessagesAttachmentRetrievalWorkerRegistry(driver: driver, databasePath: fx.path, homeDirectory: fx.homePath)
        let operation = try #require(registry.operation(for: status))
        #expect(try operation.run(frame, deadline: frame.deadline).detail == WorkerAttachmentStatus.downloaded.detail)
        #expect(driver.calls == 0)
    }

    @Test func statusRefusesReplacedAttachmentWithoutUI() throws {
        let fx = try fixture(), driver = AttachmentNoUIDriver()
        let registry = MessagesAttachmentRetrievalWorkerRegistry(driver: driver, databasePath: fx.path, homeDirectory: fx.homePath)
        let status = try WorkerCommand(name: WorkerCommand.attachmentStatus, payload: command().payload)
        let frame = request(status)
        try fx.exec("UPDATE attachment SET guid='different-fixture' WHERE ROWID=10")
        let operation = try #require(registry.operation(for: status))
        #expect(throws: (any Error).self) { try operation.run(frame, deadline: frame.deadline) }
        #expect(driver.calls == 0)
    }
}

extension MessagesAttachmentWorkerIntegrationTests {
    @Test func statusCommandBindsExpectedGUIDBeforeObservation() throws {
        let fx = try fixture()
        let args = ["attachment", "status", "--chat-rowid", "3", "--message-rowid", "60",
                    "--part-index", "0", "--expected-attachment-guid", "a10"]
        let status = try #require(try MessagesCommand.parseAsRoot(args) as? MessagesAttachmentStatus)
        let gate = MessagesWriteGuard.Gate(willExecute: false, sandboxActive: false, allowedRecipients: [])
        let deadline = WorkerDeadline.millisecondsFromNow(5000)
        let capture = try status.target.capture(databasePath: fx.path, gate: gate, deadline: deadline, isCancelled: { false })
        #expect(capture.request.selectedAttachmentGUID == "a10")

        let stale = try #require(try MessagesCommand.parseAsRoot(args + ["--expected-attachment-guid", "stale"]) as? MessagesAttachmentStatus)
        #expect(throws: AppleError.self) {
            try stale.target.capture(databasePath: fx.path, gate: gate, deadline: deadline, isCancelled: { false })
        }
    }

    @Test(arguments: ["attachment-status-", "attachment-status-downloaded-other", "attachment-status-pending\nprivate"])
    func arbitraryStatusDetailIsRefused(_ detail: String) {
        #expect(WorkerAttachmentStatus(detail: detail) == nil)
        #expect(WorkerOperationResult(.ack, detail: detail).detail == nil)
    }
}
