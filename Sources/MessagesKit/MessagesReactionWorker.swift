import Foundation
import AppleKit

struct MessagesReactionWorkerPayload: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Equatable, Sendable {
        case set
        case remove
    }

    let operation: Operation
    let chatGUID: String
    let messageGUID: String
    let nativePartIndex: Int
    // Optional native part address p:<index>/<messageGUID>, never an attachment GUID.
    let nativePartGUID: String?
    let reaction: MessagesReaction
    let experimentalUIHandoff: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.operation == rhs.operation && lhs.chatGUID.utf8.elementsEqual(rhs.chatGUID.utf8) &&
            lhs.messageGUID.utf8.elementsEqual(rhs.messageGUID.utf8) &&
            lhs.nativePartIndex == rhs.nativePartIndex &&
            lhs.nativePartGUID.map { Array($0.utf8) } == rhs.nativePartGUID.map { Array($0.utf8) } &&
            lhs.reaction == rhs.reaction &&
            lhs.experimentalUIHandoff == rhs.experimentalUIHandoff
    }

    enum CodingKeys: String, CodingKey {
        case operation
        case chatGUID = "chat_guid"
        case messageGUID = "message_guid"
        case nativePartIndex = "native_part_index"
        case nativePartGUID = "native_part_guid"
        case reaction
        case experimentalUIHandoff = "experimental_ui_handoff"
    }

    init(operation: Operation,
         chatGUID: String,
         messageGUID: String,
         nativePartIndex: Int,
         nativePartGUID: String?,
         reaction: MessagesReaction,
         experimentalUIHandoff: Bool = false) throws {
        _ = try MessagesReactionRequest(operation: operation, chatGUID: chatGUID,
                                        messageGUID: messageGUID, nativePartIndex: nativePartIndex,
                                        nativePartGUID: nativePartGUID, reaction: reaction,
                                        experimentalUIHandoff: experimentalUIHandoff)
        self.operation = operation
        self.chatGUID = chatGUID
        self.messageGUID = messageGUID
        self.nativePartIndex = nativePartIndex
        self.nativePartGUID = nativePartGUID
        self.reaction = reaction
        self.experimentalUIHandoff = experimentalUIHandoff
        guard try workerPayloadData().count <= 4096 else { throw MessagesReactionAXError.invalidPayload }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(operation: container.decode(Operation.self, forKey: .operation),
                      chatGUID: container.decode(String.self, forKey: .chatGUID),
                      messageGUID: container.decode(String.self, forKey: .messageGUID),
                      nativePartIndex: container.decode(Int.self, forKey: .nativePartIndex),
                      nativePartGUID: container.decodeIfPresent(String.self, forKey: .nativePartGUID),
                      reaction: container.decode(MessagesReaction.self, forKey: .reaction),
                      experimentalUIHandoff: container.decodeIfPresent(Bool.self, forKey: .experimentalUIHandoff) ?? false)
    }

    func workerPayloadData() throws -> Data {
        _ = try request()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 4096 else { throw MessagesReactionAXError.invalidPayload }
        return data
    }

    func request() throws -> MessagesReactionRequest {
        try MessagesReactionRequest(operation: operation,
                                    chatGUID: chatGUID,
                                    messageGUID: messageGUID,
                                    nativePartIndex: nativePartIndex,
                                    nativePartGUID: nativePartGUID,
                                    reaction: reaction,
                                    experimentalUIHandoff: experimentalUIHandoff)
    }
}

struct MessagesReactionWorkerRegistry: WorkerOperationRegistry, @unchecked Sendable {
    private let driver: any MessagesReactionAXDriving

    init(driver: any MessagesReactionAXDriving = LiveMessagesReactionAXDriver()) {
        self.driver = driver
    }

    func operation(for command: WorkerCommand) -> (any WorkerOperation)? {
        guard command.name == "messages.reaction.set" || command.name == "messages.reaction.remove",
              let payload = command.payload, payload.count <= 4096,
              let decoded = try? JSONDecoder().decode(MessagesReactionWorkerPayload.self, from: payload),
              (command.name == "messages.reaction.set") == (decoded.operation == .set)
        else { return nil }
        return MessagesReactionWorkerOperation(payload: decoded, driver: driver)
    }
}

private struct MessagesReactionWorkerOperation: WorkerOperation, @unchecked Sendable {
    let payload: MessagesReactionWorkerPayload
    let driver: any MessagesReactionAXDriving

    func run(_ request: WorkerRequest, deadline: WorkerDeadline) throws -> WorkerOperationResult {
        let outcome = try MessagesReactionAXAutomation(driver: driver).apply(payload.request(), deadline: deadline)
        switch outcome {
        case .ack(let detail):
            return WorkerOperationResult(.ack, detail: detail)
        case .refused(let reason):
            return .refused(reason)
        case .failed(let reason):
            return .failed(reason)
        }
    }
}
