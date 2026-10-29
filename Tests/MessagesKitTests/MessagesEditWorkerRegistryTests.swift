@testable import AppleKit
import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesEditWorkerRegistryTests {
    private func command() throws -> WorkerCommand {
        let payload = try MessagesEditRequest(chatRowid: 3, chatGUID: "synthetic-chat", messageRowid: 60,
            messageGUID: "synthetic-message", nativePartIndex: 0, baselineSHA256: String(repeating: "a", count: 64),
            replacement: "synthetic replacement", sandboxPrefix: nil)
        return try MessagesEditBinding(payload).command
    }

    @Test func boundedRegistryRejectsMalformedRequestsWithoutUI() throws {
        let driver = EditRegistryNoUIDriver()
        let registry = MessagesEditWorkerRegistry(driver: driver, databasePath: "/unused")
        #expect(registry.operation(for: try command()) != nil)
        #expect(registry.operation(for: try WorkerCommand(name: "other", payload: command().payload)) == nil)
        #expect(registry.operation(for: try WorkerCommand(name: "messages.edit")) == nil)
        #expect(registry.operation(for: try WorkerCommand(name: "messages.edit", payload: Data("{}".utf8))) == nil)
        #expect(driver.calls == 0)
    }

    @Test func unreadableStoreRefusesWithoutTouchingUI() throws {
        let driver = EditRegistryNoUIDriver()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let registry = MessagesEditWorkerRegistry(driver: driver, databasePath: missing)
        let command = try command()
        let operation = try #require(registry.operation(for: command))
        let identity = WorkerProcessIdentity(pid: 1, parentPID: 0, uid: 1, gid: 1,
            startTimeMicroseconds: 1, executableDevice: 1, executableInode: 1, executablePath: "/tmp/apple")
        let request = WorkerRequest(schemaVersion: 1, operationID: UUID(), nonce: UUID(), deadline: .millisecondsFromNow(5000),
            parent: identity, workerExecutable: .init(uid: 1, gid: 1, device: 1, inode: 1, path: "/tmp/apple"), command: command)
        let result = try operation.run(request, deadline: request.deadline)
        #expect(result.category == .refused)
        #expect(result.detail == "edit-preflight-refused")
        #expect(driver.calls == 0)
        #expect(!FileManager.default.fileExists(atPath: missing))
    }

    @Test func mainRegistryRoutesEditWithoutExecutingIt() throws {
        #expect(MessagesWorkerRegistry().operation(for: try command()) != nil)
    }
}

private final class EditRegistryNoUIDriver: MessagesAXProcessDriving {
    var calls = 0
    private func refused() throws -> Never { calls += 1; throw MessagesAXNavigationError.axFailure }
    func checkAccessibilityTrusted(prompt: Bool) -> Bool { calls += 1; return false }
    func openMessages(url: URL, deadline: WorkerDeadline) throws -> MessagesAXProcess { try refused() }
    func canonicalMessagesProcess(deadline: WorkerDeadline) throws -> MessagesAXProcess { try refused() }
    func messagesProcessIsFrontmost(_ process: MessagesAXProcess, deadline: WorkerDeadline) throws -> Bool { try refused() }
    func focusedElement(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? { try refused() }
}
