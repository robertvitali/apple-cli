@testable import AppleKit
import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesAttachmentPartDriftTests {
    private func fixture() throws -> ChatFixture {
        let fx = try ChatFixture()
        let body = NSMutableAttributedString(string: "\u{fffc}")
        body.addAttribute(NSAttributedString.Key("__kIMMessagePartAttributeName"), value: NSNumber(value: 0), range: NSRange(location: 0, length: 1))
        body.addAttribute(NSAttributedString.Key("__kIMFileTransferGUIDAttributeName"), value: "unbound-attachment", range: NSRange(location: 0, length: 1))
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
    @Test(arguments: [4, 5])
    func conflictingGUIDBytesRefuseActionAndDownloadedSuccess(_ transferState: Int) throws {
        let fx = try fixture(), driver = AttachmentPartDriftNoUIDriver()
        let first = "\u{e9}", second = "e\u{301}"
        #expect(first == second)
        #expect(Data(first.utf8) != Data(second.utf8))
        let original = NSMutableAttributedString(string: "\u{fffc}")
        let originalRange = NSRange(location: 0, length: 1)
        original.addAttribute(NSAttributedString.Key("__kIMMessagePartAttributeName"), value: NSNumber(value: 0), range: originalRange)
        original.addAttribute(NSAttributedString.Key("__kIMFileTransferGUIDAttributeName"), value: first, range: originalRange)
        let originalHex = NSArchiver.archivedData(withRootObject: original).map { String(format: "%02x", $0) }.joined()
        try fx.exec("UPDATE message SET attributedBody=X'\(originalHex)' WHERE ROWID=60; UPDATE attachment SET guid='\(first)', transfer_state=\(transferState) WHERE ROWID=10")
        let captured = try MessagesAttachmentTargetResolver.read(databasePath: fx.path, chat: .rowid(3), message: .rowid(60),
            partIndex: 0, sandboxPrefix: nil, deadline: .millisecondsFromNow(5000), isCancelled: { false })
        let body = NSMutableAttributedString(string: "\u{fffc} \u{fffc}")
        for (offset, guid) in [(0, first), (2, second)] {
            let range = NSRange(location: offset, length: 1)
            body.addAttribute(NSAttributedString.Key("__kIMMessagePartAttributeName"), value: NSNumber(value: 0), range: range)
            body.addAttribute(NSAttributedString.Key("__kIMFileTransferGUIDAttributeName"), value: guid, range: range)
        }
        let data = NSArchiver.archivedData(withRootObject: body)
        let decoded = NativeMessageParts.decode(data)
        #expect(!decoded.nativePartsAvailable)
        #expect(decoded.nativePartsReason.contains("conflicting-attachment-guid"))
        let hex = data.map { String(format: "%02x", $0) }.joined()
        try fx.exec("UPDATE message SET attributedBody=X'\(hex)' WHERE ROWID=60; UPDATE attachment SET guid='\(first)', transfer_state=\(transferState) WHERE ROWID=10")
        #expect(throws: (any Error).self) {
            try MessagesAttachmentTargetResolver.read(databasePath: fx.path, chat: .rowid(3), message: .rowid(60),
                partIndex: 0, sandboxPrefix: nil, deadline: .millisecondsFromNow(5000), isCancelled: { false })
        }
        let registry = MessagesAttachmentRetrievalWorkerRegistry(driver: driver, databasePath: fx.path, homeDirectory: fx.homePath)
        let command = try WorkerCommand(name: "messages.attachment.retrieve", payload: captured.request.workerPayloadData())
        let request = request(command)
        let operation = try #require(registry.operation(for: command))
        let result = try operation.run(request, deadline: request.deadline)
        #expect(result.category != .ack)
        #expect(driver.calls == 0)
    }

    @Test(arguments: [4, 5], ["native-guid", "native-part-key", "native-guid-key", "database-guid", "chat-guid", "message-guid", "participant", "filename", "body-text", "blob-text", "native-root"])
    func changedUTF8BytesRefuseActionAndDownloadedSuccess(_ transferState: Int, _ scenario: String) throws {
        let fx = try fixture(), driver = AttachmentPartDriftNoUIDriver()
        func archive(partKey: String = "__kIMMessagePartAttributeName",
                     guidKey: String = "__kIMFileTransferGUIDAttributeName", guid: String = "a10",
                     text: String = "apple-cli-test \u{fffc}") -> Data {
            let body = NSMutableAttributedString(string: text)
            let range = NSRange(location: body.length - 1, length: 1)
            body.addAttribute(NSAttributedString.Key(partKey), value: NSNumber(value: 0), range: range)
            body.addAttribute(NSAttributedString.Key(guidKey), value: guid, range: range)
            return NSArchiver.archivedData(withRootObject: body)
        }
        func install(_ data: Data) throws {
            let hex = data.map { String(format: "%02x", $0) }.joined()
            try fx.exec("UPDATE message SET attributedBody=X'\(hex)' WHERE ROWID=60")
        }
        try install(archive())
        try fx.exec("UPDATE attachment SET transfer_state=\(transferState) WHERE ROWID=10")
        let captured = try MessagesAttachmentTargetResolver.read(databasePath: fx.path, chat: .rowid(3), message: .rowid(60),
            partIndex: 0, sandboxPrefix: "apple-cli-test", deadline: .millisecondsFromNow(5000), isCancelled: { false })
        switch scenario {
        case "blob-text":
            try install(archive(text: "unlabeled \u{fffc}"))
            try fx.exec("UPDATE message SET text=CAST('apple-cli-test forged label' AS BLOB) WHERE ROWID=60")
        case "native-root":
            let raw = Data("apple-cli-test \u{fffc}".utf8)
            var data = archive()
            let span = try #require(data.range(of: raw))
            #expect(span.lowerBound > 0)
            #expect(data[span.lowerBound - 1] == UInt8(raw.count))
            data[span.lowerBound - 1] = UInt8(raw.count + 3)
            data.replaceSubrange(span, with: Data([0xef, 0xbb, 0xbf]) + raw)
            // Display decoding keeps its legacy text; retrieval must refuse it.
            #expect(NativeMessageParts.decode(data).text?.hasPrefix("apple-cli-test") == true)
            try install(data)
        case "native-guid": try install(archive(guid: "\u{feff}a10"))
        case "native-part-key": try install(archive(partKey: "\u{feff}__kIMMessagePartAttributeName"))
        case "native-guid-key": try install(archive(guidKey: "\u{feff}__kIMFileTransferGUIDAttributeName"))
        case "database-guid": try fx.exec("UPDATE attachment SET guid=CAST(X'EFBBBF'||CAST(guid AS BLOB) AS TEXT) WHERE ROWID=10")
        case "chat-guid": try fx.exec("UPDATE chat SET guid=CAST(X'EFBBBF'||CAST(guid AS BLOB) AS TEXT) WHERE ROWID=3")
        case "message-guid": try fx.exec("UPDATE message SET guid=CAST(X'EFBBBF'||CAST(guid AS BLOB) AS TEXT) WHERE ROWID=60")
        case "participant": try fx.exec("UPDATE handle SET id=CAST(X'EFBBBF'||CAST(id AS BLOB) AS TEXT) WHERE ROWID=1")
        case "filename": try fx.exec("UPDATE attachment SET filename=CAST(X'EFBBBF'||CAST(filename AS BLOB) AS TEXT) WHERE ROWID=10")
        default: try fx.exec("UPDATE message SET text=CAST(X'EFBBBF' AS TEXT)||'apple-cli-test' WHERE ROWID=60")
        }
        #expect(throws: (any Error).self) {
            try MessagesAttachmentTargetResolver.read(databasePath: fx.path, chat: .rowid(3), message: .rowid(60),
                partIndex: 0, sandboxPrefix: "apple-cli-test", deadline: .millisecondsFromNow(5000), isCancelled: { false })
        }
        let registry = MessagesAttachmentRetrievalWorkerRegistry(driver: driver, databasePath: fx.path, homeDirectory: fx.homePath)
        let command = try WorkerCommand(name: "messages.attachment.retrieve", payload: captured.request.workerPayloadData())
        let request = request(command)
        let operation = try #require(registry.operation(for: command))
        let result = try operation.run(request, deadline: request.deadline)
        #expect(result.category != .ack)
        #expect(driver.calls == 0)
    }

    @Test func unrelatedNativeAttachmentPartCannotReportDownloaded() throws {
        let fx = try fixture(), driver = AttachmentPartDriftNoUIDriver()
        let registry = MessagesAttachmentRetrievalWorkerRegistry(driver: driver, databasePath: fx.path, homeDirectory: fx.homePath)
        let command = try command(), request = request(command)
        let operation = try #require(registry.operation(for: command))
        let result = try operation.run(request, deadline: request.deadline)
        #expect(result.category != .ack)
        #expect(driver.calls == 0)
    }
}

private final class AttachmentPartDriftNoUIDriver: MessagesReactionAXDriving {
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
