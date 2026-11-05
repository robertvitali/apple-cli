import AppleKit
import Foundation

/// One request binds the worker pipe and journal. Recipients and initial text
/// never enter the durable journal; the baseline is bound by the payload hash.
struct MessagesConversationBinding {
    let command: WorkerCommand
    let target: WorkerObservedTargetBinding

    init(_ request: MessagesConversationRequest) throws {
        let payload = try request.workerPayloadData()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func digest(_ values: [String]) throws -> AppleAutomationJournal.TargetDigest {
            let bytes = try encoder.encode(values)
            return try AppleAutomationJournal.targetDigest(forOpaqueIdentifier: String(decoding: bytes, as: UTF8.self))
        }
        command = try WorkerCommand(name: "messages.conversations.create", payload: payload)
        target = WorkerObservedTargetBinding(operationType: .conversationCreate,
            conversationDigest: try digest(["conversation-create-recipients-v1", request.service] + request.recipients),
            messageDigest: try digest(["conversation-create-text-v1", request.initialText]), partDigest: nil,
            minimumEvidence: .init(
                targetHash: try AppleAutomationJournal.targetDigest(forOpaqueIdentifier: String(decoding: payload, as: UTF8.self)),
                targetLength: payload.count))
    }

    func resolvedAction() throws -> WorkerResolvedAction {
        try WorkerResolvedAction(target: target) { _ in command }
    }
}
