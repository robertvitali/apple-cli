import AppleKit
import Foundation

/// Couples the worker command and journal evidence to the same validated request.
/// Only digests and the payload length are persisted by the journal.
struct MessagesEditBinding {
    let command: WorkerCommand
    let target: WorkerObservedTargetBinding

    init(_ request: MessagesEditRequest) throws {
        let payload = try request.workerPayloadData()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func digest(_ components: [String]) throws -> AppleAutomationJournal.TargetDigest {
            let bytes = try encoder.encode(components)
            return try AppleAutomationJournal.targetDigest(forOpaqueIdentifier: String(decoding: bytes, as: UTF8.self))
        }
        command = try WorkerCommand(name: "messages.edit", payload: payload)
        target = WorkerObservedTargetBinding(
            operationType: .editMessage,
            conversationDigest: try digest(["edit-chat-v1", String(request.chatRowid), request.chatGUID]),
            messageDigest: try digest(["edit-message-v1", String(request.messageRowid), request.messageGUID]),
            partDigest: try digest(["edit-part-v1", String(request.nativePartIndex)]),
            minimumEvidence: .init(
                targetHash: try AppleAutomationJournal.targetDigest(forOpaqueIdentifier: String(decoding: payload, as: UTF8.self)),
                targetLength: payload.count))
    }

    func resolvedAction() throws -> WorkerResolvedAction {
        try WorkerResolvedAction(target: target) { _ in command }
    }
}
