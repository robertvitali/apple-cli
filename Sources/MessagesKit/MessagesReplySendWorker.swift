import Foundation
import AppleKit

enum MessagesReplySendACKDetail {
    static let alreadyRestoredVerified = "reply-send-already-restored-clean-verified"
    static let retainedEmptyCancelledVerified = "reply-send-empty-owned-composer-closed-verified"
    static let verificationSource = "ui_clean_state_and_database_correspondence"
    static let attachmentVerificationSource = "ui_clean_state_database_correspondence_and_attachment_content"

    static func isVerified(_ detail: String?) -> Bool {
        detail == alreadyRestoredVerified || detail == retainedEmptyCancelledVerified
    }
}

struct MessagesReplySendRequest: Codable, Equatable, Sendable {
    let chatGUID: String
    let messageGUID: String
    let nativePartIndex: Int
    let nativePartGUID: String?
    let expectedChatRowID: Int64
    let expectedMessageRowID: Int64
    let expectedParticipantHandles: [String]
    let expectedIsFromMe: Bool
    let expectedThreadRelationshipSHA256: String?
    let expectedBodySHA256: String
    let expectedBodyUTF8Length: Int
    let requiredBodyPrefix: String
    let text: String?
    let attachmentDraft: MessagesReplyAttachmentDraftEvidence?

    enum CodingKeys: String, CodingKey {
        case chatGUID = "chat_guid"
        case messageGUID = "message_guid"
        case nativePartIndex = "native_part_index"
        case nativePartGUID = "native_part_guid"
        case expectedChatRowID = "expected_chat_rowid"
        case expectedMessageRowID = "expected_message_rowid"
        case expectedParticipantHandles = "expected_participant_handles"
        case expectedIsFromMe = "expected_is_from_me"
        case expectedThreadRelationshipSHA256 = "expected_thread_relationship_sha256"
        case expectedBodySHA256 = "expected_body_sha256"
        case expectedBodyUTF8Length = "expected_body_utf8_length"
        case requiredBodyPrefix = "required_body_prefix"
        case text
        case attachmentDraft = "attachment_draft"
    }

    init(chatGUID: String,
         messageGUID: String,
         nativePartIndex: Int,
         nativePartGUID: String?,
         expectedChatRowID: Int64,
         expectedMessageRowID: Int64,
         expectedParticipantHandles: [String],
         expectedIsFromMe: Bool,
         expectedBodySHA256: String,
         expectedBodyUTF8Length: Int,
         requiredBodyPrefix: String,
         text: String?,
         attachmentDraft: MessagesReplyAttachmentDraftEvidence? = nil,
         expectedThreadRelationshipSHA256: String? = nil) throws {
        guard !chatGUID.isEmpty, chatGUID.utf8.count <= 512,
              expectedChatRowID > 0, expectedMessageRowID > 0,
              !expectedParticipantHandles.isEmpty, expectedParticipantHandles.count <= 32,
              expectedParticipantHandles.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }),
              expectedBodySHA256.hasPrefix("sha256:"), expectedBodySHA256.utf8.count == 71,
              expectedBodyUTF8Length > 0, expectedBodyUTF8Length <= 4096,
              requiredBodyPrefix == TestMode.canonicalSandboxPrefix
        else { throw MessagesReplyComposerAXError.invalidPayload }
        if let digest = expectedThreadRelationshipSHA256 {
            guard digest.hasPrefix("sha256:"), digest.utf8.count == 71,
                  digest.utf8.dropFirst(7).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw MessagesReplyComposerAXError.invalidPayload
            }
        }
        switch (text, attachmentDraft) {
        case (.some(let value), nil):
            guard !value.isEmpty, value.utf8.count <= 2048 else { throw MessagesReplyComposerAXError.invalidPayload }
        case (nil, .some):
            break
        default:
            throw MessagesReplyComposerAXError.invalidPayload
        }
        try NativeMessagesURL.validate(messageGUID: messageGUID, nativePartIndex: nativePartIndex, nativePartGUID: nativePartGUID)
        self.chatGUID = chatGUID
        self.messageGUID = messageGUID
        self.nativePartIndex = nativePartIndex
        self.nativePartGUID = nativePartGUID
        self.expectedChatRowID = expectedChatRowID
        self.expectedMessageRowID = expectedMessageRowID
        self.expectedParticipantHandles = expectedParticipantHandles
        self.expectedIsFromMe = expectedIsFromMe
        self.expectedThreadRelationshipSHA256 = expectedThreadRelationshipSHA256
        self.expectedBodySHA256 = expectedBodySHA256
        self.expectedBodyUTF8Length = expectedBodyUTF8Length
        self.requiredBodyPrefix = requiredBodyPrefix
        self.text = text
        self.attachmentDraft = attachmentDraft
        guard try workerPayloadData().count <= 4096 else { throw MessagesReplyComposerAXError.invalidPayload }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(chatGUID: c.decode(String.self, forKey: .chatGUID),
                      messageGUID: c.decode(String.self, forKey: .messageGUID),
                      nativePartIndex: c.decode(Int.self, forKey: .nativePartIndex),
                      nativePartGUID: c.decodeIfPresent(String.self, forKey: .nativePartGUID),
                      expectedChatRowID: c.decode(Int64.self, forKey: .expectedChatRowID),
                      expectedMessageRowID: c.decode(Int64.self, forKey: .expectedMessageRowID),
                      expectedParticipantHandles: c.decode([String].self, forKey: .expectedParticipantHandles),
                      expectedIsFromMe: c.decode(Bool.self, forKey: .expectedIsFromMe),
                      expectedBodySHA256: c.decode(String.self, forKey: .expectedBodySHA256),
                      expectedBodyUTF8Length: c.decode(Int.self, forKey: .expectedBodyUTF8Length),
                      requiredBodyPrefix: c.decode(String.self, forKey: .requiredBodyPrefix),
                      text: c.decodeIfPresent(String.self, forKey: .text),
                      attachmentDraft: c.decodeIfPresent(MessagesReplyAttachmentDraftEvidence.self, forKey: .attachmentDraft),
                      expectedThreadRelationshipSHA256: c.decodeIfPresent(String.self, forKey: .expectedThreadRelationshipSHA256))
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(chatGUID, forKey: .chatGUID)
        try c.encode(messageGUID, forKey: .messageGUID)
        try c.encode(nativePartIndex, forKey: .nativePartIndex)
        try c.encodeIfPresent(nativePartGUID, forKey: .nativePartGUID)
        try c.encode(expectedChatRowID, forKey: .expectedChatRowID)
        try c.encode(expectedMessageRowID, forKey: .expectedMessageRowID)
        try c.encode(expectedParticipantHandles, forKey: .expectedParticipantHandles)
        try c.encode(expectedIsFromMe, forKey: .expectedIsFromMe)
        try c.encodeIfPresent(expectedThreadRelationshipSHA256, forKey: .expectedThreadRelationshipSHA256)
        try c.encode(expectedBodySHA256, forKey: .expectedBodySHA256)
        try c.encode(expectedBodyUTF8Length, forKey: .expectedBodyUTF8Length)
        try c.encode(requiredBodyPrefix, forKey: .requiredBodyPrefix)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(attachmentDraft, forKey: .attachmentDraft)
    }

    func workerPayloadData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 4096 else { throw MessagesReplyComposerAXError.invalidPayload }
        return data
    }

    func probeRequest() throws -> MessagesReplyComposerProbeRequest {
        try MessagesReplyComposerProbeRequest(chatGUID: chatGUID,
                                             messageGUID: messageGUID,
                                             nativePartIndex: nativePartIndex,
                                             nativePartGUID: nativePartGUID,
                                             expectedChatRowID: expectedChatRowID,
                                             expectedMessageRowID: expectedMessageRowID,
                                             expectedParticipantHandles: expectedParticipantHandles,
                                             expectedIsFromMe: expectedIsFromMe,
                                             expectedBodySHA256: expectedBodySHA256,
                                             expectedBodyUTF8Length: expectedBodyUTF8Length,
                                             requiredBodyPrefix: requiredBodyPrefix)
    }
}

struct MessagesReplySendWorkerRegistry: WorkerOperationRegistry, @unchecked Sendable {
    private let driver: any MessagesReplyComposerAXDriving

    init(driver: any MessagesReplyComposerAXDriving = LiveMessagesReplyComposerAXDriver()) {
        self.driver = driver
    }

    func operation(for command: WorkerCommand) -> (any WorkerOperation)? {
        guard command.name == "messages.reply.send",
              let payload = command.payload, payload.count <= 4096,
              let decoded = try? JSONDecoder().decode(MessagesReplySendRequest.self, from: payload)
        else { return nil }
        return MessagesReplySendWorkerOperation(payload: decoded, driver: driver)
    }
}

struct MessagesWorkerRegistry: WorkerOperationRegistry, @unchecked Sendable {
    private let reaction: MessagesReactionWorkerRegistry
    private let reply: MessagesReplySendWorkerRegistry
    private let attachment = MessagesAttachmentRetrievalWorkerRegistry()

    init(reactionDriver: any MessagesReactionAXDriving = LiveMessagesReactionAXDriver(),
         replyDriver: any MessagesReplyComposerAXDriving = LiveMessagesReplyComposerAXDriver()) {
        self.reaction = MessagesReactionWorkerRegistry(driver: reactionDriver)
        self.reply = MessagesReplySendWorkerRegistry(driver: replyDriver)
    }

    func operation(for command: WorkerCommand) -> (any WorkerOperation)? {
        reaction.operation(for: command) ?? reply.operation(for: command) ?? attachment.operation(for: command)
    }
}

private struct MessagesReplySendWorkerOperation: WorkerOperation, @unchecked Sendable {
    let payload: MessagesReplySendRequest
    let driver: any MessagesReplyComposerAXDriving

    func run(_ request: WorkerRequest, deadline: WorkerDeadline) throws -> WorkerOperationResult {
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver).send(payload, deadline: deadline)
        switch outcome {
        case .ack(let detail): return WorkerOperationResult(.ack, detail: detail)
        case .refused(let detail): return .refused(detail)
        case .failed(let detail): return .failed(detail)
        }
    }
}
