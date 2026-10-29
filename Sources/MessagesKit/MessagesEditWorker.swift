import AppleKit
import Foundation

struct MessagesEditWorkerRegistry: WorkerOperationRegistry, @unchecked Sendable {
    let driver: any MessagesAXProcessDriving
    let databasePath: String

    init(driver: any MessagesAXProcessDriving = LiveMessagesReactionAXDriver(),
         databasePath: String = ChatDB.defaultPath()) {
        self.driver = driver
        self.databasePath = databasePath
    }

    func operation(for command: WorkerCommand) -> (any WorkerOperation)? {
        guard command.name == "messages.edit", let data = command.payload, data.count <= 4096,
              let payload = try? JSONDecoder().decode(MessagesEditRequest.self, from: data) else { return nil }
        return MessagesEditWorkerOperation(payload: payload, driver: driver, databasePath: databasePath)
    }
}

private struct MessagesEditWorkerOperation: WorkerOperation, @unchecked Sendable {
    let payload: MessagesEditRequest
    let driver: any MessagesAXProcessDriving
    let databasePath: String

    func run(_ request: WorkerRequest, deadline: WorkerDeadline) throws -> WorkerOperationResult {
        let diagnostic = MessagesEditDiagnostic()
        let sequence = MessagesEditWorkerSequence(payload: payload, read: { bounded in
            try MessagesEditTargetResolver.read(databasePath: databasePath,
                chat: .rowid(payload.chatRowid), message: .rowid(payload.messageRowid),
                partIndex: payload.nativePartIndex, sandboxPrefix: payload.sandboxPrefix,
                deadline: bounded, isCancelled: { Task.isCancelled })
        }, perform: { baseline, bounded, validate in
            try MessagesEditAXAutomation(driver: driver).perform(messageGUID: payload.messageGUID,
                nativePartIndex: payload.nativePartIndex, expectedText: baseline.partText,
                replacement: payload.replacement, deadline: bounded, validateTarget: validate, diagnostic: diagnostic)
        }, diagnostic: diagnostic)
        return sequence.run(deadline: deadline)
    }
}
