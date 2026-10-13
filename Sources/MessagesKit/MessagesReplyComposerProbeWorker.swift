import Darwin
import Foundation
import AppleKit

package struct MessagesReplyComposerProbeRequest: Codable, Equatable, Sendable {
    package let chatGUID: String
    package let messageGUID: String
    package let nativePartIndex: Int
    package let nativePartGUID: String?
    package let phase: String
    package let expectedChatRowID: Int64
    package let expectedMessageRowID: Int64
    package let expectedParticipantHandles: [String]
    package let expectedIsFromMe: Bool
    package let expectedBodySHA256: String
    package let expectedBodyUTF8Length: Int
    package let requiredBodyPrefix: String

    enum CodingKeys: String, CodingKey {
        case chatGUID = "chat_guid"
        case messageGUID = "message_guid"
        case nativePartIndex = "native_part_index"
        case nativePartGUID = "native_part_guid"
        case phase
        case expectedChatRowID = "expected_chat_rowid"
        case expectedMessageRowID = "expected_message_rowid"
        case expectedParticipantHandles = "expected_participant_handles"
        case expectedIsFromMe = "expected_is_from_me"
        case expectedBodySHA256 = "expected_body_sha256"
        case expectedBodyUTF8Length = "expected_body_utf8_length"
        case requiredBodyPrefix = "required_body_prefix"
    }

    package init(chatGUID: String,
                 messageGUID: String,
                 nativePartIndex: Int,
                 nativePartGUID: String?,
                 phase: String = "replyInspect",
                 expectedChatRowID: Int64,
                 expectedMessageRowID: Int64,
                 expectedParticipantHandles: [String],
                 expectedIsFromMe: Bool,
                 expectedBodySHA256: String,
                 expectedBodyUTF8Length: Int,
                 requiredBodyPrefix: String) throws {
        guard phase == "replyInspect",
              !chatGUID.isEmpty, chatGUID.utf8.count <= 512,
              expectedChatRowID > 0, expectedMessageRowID > 0,
              !expectedParticipantHandles.isEmpty, expectedParticipantHandles.count <= 32,
              expectedParticipantHandles.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }),
              expectedBodySHA256.hasPrefix("sha256:"), expectedBodySHA256.utf8.count == 71,
              expectedBodyUTF8Length > 0, expectedBodyUTF8Length <= 4096,
              requiredBodyPrefix == "apple-cli-test"
        else { throw MessagesReplyComposerAXError.invalidPayload }
        try NativeMessagesURL.validate(messageGUID: messageGUID, nativePartIndex: nativePartIndex, nativePartGUID: nativePartGUID)
        self.chatGUID = chatGUID
        self.messageGUID = messageGUID
        self.nativePartIndex = nativePartIndex
        self.nativePartGUID = nativePartGUID
        self.phase = phase
        self.expectedChatRowID = expectedChatRowID
        self.expectedMessageRowID = expectedMessageRowID
        self.expectedParticipantHandles = expectedParticipantHandles
        self.expectedIsFromMe = expectedIsFromMe
        self.expectedBodySHA256 = expectedBodySHA256
        self.expectedBodyUTF8Length = expectedBodyUTF8Length
        self.requiredBodyPrefix = requiredBodyPrefix
        guard try workerPayloadData().count <= 4096 else { throw MessagesReplyComposerAXError.invalidPayload }
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(chatGUID: c.decode(String.self, forKey: .chatGUID),
                      messageGUID: c.decode(String.self, forKey: .messageGUID),
                      nativePartIndex: c.decode(Int.self, forKey: .nativePartIndex),
                      nativePartGUID: c.decodeIfPresent(String.self, forKey: .nativePartGUID),
                      phase: c.decode(String.self, forKey: .phase),
                      expectedChatRowID: c.decode(Int64.self, forKey: .expectedChatRowID),
                      expectedMessageRowID: c.decode(Int64.self, forKey: .expectedMessageRowID),
                      expectedParticipantHandles: c.decode([String].self, forKey: .expectedParticipantHandles),
                      expectedIsFromMe: c.decode(Bool.self, forKey: .expectedIsFromMe),
                      expectedBodySHA256: c.decode(String.self, forKey: .expectedBodySHA256),
                      expectedBodyUTF8Length: c.decode(Int.self, forKey: .expectedBodyUTF8Length),
                      requiredBodyPrefix: c.decode(String.self, forKey: .requiredBodyPrefix))
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(chatGUID, forKey: .chatGUID)
        try c.encode(messageGUID, forKey: .messageGUID)
        try c.encode(nativePartIndex, forKey: .nativePartIndex)
        try c.encodeIfPresent(nativePartGUID, forKey: .nativePartGUID)
        try c.encode(phase, forKey: .phase)
        try c.encode(expectedChatRowID, forKey: .expectedChatRowID)
        try c.encode(expectedMessageRowID, forKey: .expectedMessageRowID)
        try c.encode(expectedParticipantHandles, forKey: .expectedParticipantHandles)
        try c.encode(expectedIsFromMe, forKey: .expectedIsFromMe)
        try c.encode(expectedBodySHA256, forKey: .expectedBodySHA256)
        try c.encode(expectedBodyUTF8Length, forKey: .expectedBodyUTF8Length)
        try c.encode(requiredBodyPrefix, forKey: .requiredBodyPrefix)
    }

    package func workerPayloadData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 4096 else { throw MessagesReplyComposerAXError.invalidPayload }
        return data
    }
}

package struct MessagesReplyComposerProbeWorkerRegistry: WorkerOperationRegistry, @unchecked Sendable {
    private let driver: any MessagesReplyComposerAXDriving

    package init() {
        self.driver = LiveMessagesReplyComposerAXDriver()
    }

    init(driver: any MessagesReplyComposerAXDriving) {
        self.driver = driver
    }

    package func operation(for command: WorkerCommand) -> (any WorkerOperation)? {
        guard command.name == "messages.reply.inspect",
              let payload = command.payload, payload.count <= 4096,
              let decoded = try? JSONDecoder().decode(MessagesReplyComposerProbeRequest.self, from: payload)
        else { return nil }
        return MessagesReplyComposerProbeWorkerOperation(payload: decoded, driver: driver)
    }
}

private struct MessagesReplyComposerProbeWorkerOperation: WorkerOperation, @unchecked Sendable {
    let payload: MessagesReplyComposerProbeRequest
    let driver: any MessagesReplyComposerAXDriving

    func run(_ request: WorkerRequest, deadline: WorkerDeadline) throws -> WorkerOperationResult {
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver).inspect(payload, deadline: deadline)
        switch outcome {
        case .ack(let detail): return WorkerOperationResult(.ack, detail: detail)
        case .refused(let detail): return .refused(detail)
        case .failed(let detail): return .failed(detail)
        }
    }
}


private enum MessagesReplyComposerParentError: String, Error, CustomStringConvertible {
    case targetDrift = "reply-composer-target-drift"
    case participantDrift = "reply-composer-participant-drift"
    case nativePartDrift = "reply-composer-native-part-drift"
    case fixtureUnlabeled = "reply-composer-fixture-unlabeled"
    case unsafeInputFile = "invalid-payload"

    var description: String { rawValue }
}

private struct MessagesReplyComposerProbeEvidence: Codable {
    let phase: String
    let chatRowID: Int64
    let chatGUID: String
    let messageRowID: Int64
    let messageGUID: String
    let nativePartIndex: Int
    let nativePartGUID: String?
    let participantHandles: [String]
    let isFromMe: Bool
    let bodySHA256: String
    let bodyUTF8Length: Int
    let requiredBodyPrefix: String

    enum CodingKeys: String, CodingKey {
        case phase
        case chatRowID = "chat_rowid"
        case chatGUID = "chat_guid"
        case messageRowID = "message_rowid"
        case messageGUID = "message_guid"
        case nativePartIndex = "native_part_index"
        case nativePartGUID = "native_part_guid"
        case participantHandles = "participant_handles"
        case isFromMe = "is_from_me"
        case bodySHA256 = "body_sha256"
        case bodyUTF8Length = "body_utf8_length"
        case requiredBodyPrefix = "required_body_prefix"
    }
}

private struct MessagesReplyComposerResolvedParentTarget {
    let evidence: MessagesReplyComposerProbeEvidence
    let payload: MessagesReplyComposerProbeRequest
}

package enum MessagesReplyComposerProbeParent {
    package static func productionStateRoot() -> String { MessagesAutomationState.productionRoot() }

    package static func payloadData(fromFile path: String, repoRoot: String) throws -> Data {
        guard !path.isEmpty else { throw MessagesReplyComposerParentError.unsafeInputFile }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MessagesReplyComposerParentError.unsafeInputFile }
        defer { close(fd) }

        var opened = stat()
        guard fstat(fd, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_uid == getuid(),
              (opened.st_mode & 0o777) == 0o600,
              opened.st_size > 0,
              opened.st_size <= 4096 else { throw MessagesReplyComposerParentError.unsafeInputFile }

        let canonicalPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalRepo = URL(fileURLWithPath: repoRoot, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        guard canonicalPath != canonicalRepo,
              !canonicalPath.hasPrefix(canonicalRepo.hasSuffix("/") ? canonicalRepo : canonicalRepo + "/") else {
            throw MessagesReplyComposerParentError.unsafeInputFile
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: 4097) ?? Data()
        var afterRead = stat()
        var pathState = stat()
        guard fstat(fd, &afterRead) == 0, stat(path, &pathState) == 0,
              opened.st_dev == afterRead.st_dev, opened.st_ino == afterRead.st_ino, opened.st_size == afterRead.st_size,
              opened.st_mode == afterRead.st_mode, opened.st_uid == afterRead.st_uid,
              opened.st_dev == pathState.st_dev, opened.st_ino == pathState.st_ino,
              !data.isEmpty, data.count == opened.st_size, data.count <= 4096 else {
            throw MessagesReplyComposerParentError.unsafeInputFile
        }
        _ = try JSONDecoder().decode(MessagesReplyComposerProbeRequest.self, from: data)
        return data
    }

    package static func journalRequest(for request: MessagesReplyComposerProbeRequest, payloadData: Data) throws -> AppleAutomationJournal.OperationRequest {
        let evidence = MessagesReplyComposerProbeEvidence(phase: request.phase,
                                                          chatRowID: request.expectedChatRowID,
                                                          chatGUID: request.chatGUID,
                                                          messageRowID: request.expectedMessageRowID,
                                                          messageGUID: request.messageGUID,
                                                          nativePartIndex: request.nativePartIndex,
                                                          nativePartGUID: request.nativePartGUID,
                                                          participantHandles: request.expectedParticipantHandles,
                                                          isFromMe: request.expectedIsFromMe,
                                                          bodySHA256: request.expectedBodySHA256,
                                                          bodyUTF8Length: request.expectedBodyUTF8Length,
                                                          requiredBodyPrefix: request.requiredBodyPrefix)
        return try journalRequest(for: evidence, payloadData: payloadData)
    }

    private static func journalRequest(for evidence: MessagesReplyComposerProbeEvidence, payloadData: Data) throws -> AppleAutomationJournal.OperationRequest {
        let encodedEvidence = try canonicalEvidenceData(evidence)
        return try AppleAutomationJournal.OperationRequest(
            operationType: .replySend,
            conversationDigest: AppleAutomationJournal.targetDigest(forOpaqueIdentifier: "chat-rowid:\(evidence.chatRowID):\(evidence.chatGUID)"),
            messageDigest: AppleAutomationJournal.targetDigest(forOpaqueIdentifier: "message-rowid:\(evidence.messageRowID):\(evidence.messageGUID)"),
            partDigest: AppleAutomationJournal.targetDigest(forOpaqueIdentifier: evidence.nativePartGUID ?? "part-index:\(evidence.nativePartIndex)"),
            minimumEvidence: .init(targetHash: AppleAutomationJournal.targetDigest(forOpaqueIdentifier: String(decoding: encodedEvidence, as: UTF8.self)),
                                   targetLength: encodedEvidence.count)
        )
    }

    private static func canonicalEvidenceData(_ evidence: MessagesReplyComposerProbeEvidence) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(evidence)
        guard !data.isEmpty, data.count <= 4096 else { throw MessagesReplyComposerParentError.unsafeInputFile }
        return data
    }

    private static func resolveTarget(request: MessagesReplyComposerProbeRequest, db: inout ChatDB) throws -> MessagesReplyComposerResolvedParentTarget {
        let (chat, message) = try db.exactGet(chat: .rowid(request.expectedChatRowID), message: .rowid(request.expectedMessageRowID))
        guard chat.rowid == request.expectedChatRowID,
              message.rowid == request.expectedMessageRowID,
              message.selected_chat_rowid == request.expectedChatRowID,
              message.chat_guid == request.chatGUID,
              message.message_guid == request.messageGUID else {
            throw MessagesReplyComposerParentError.targetDrift
        }
        guard let parts = message.native_parts, message.native_parts_available,
              parts.contains(where: { $0.index == request.nativePartIndex }),
              request.nativePartGUID == "p:\(request.nativePartIndex)/\(request.messageGUID)" else {
            throw MessagesReplyComposerParentError.nativePartDrift
        }
        let participants = try db.exactParticipantHandles(chatRowid: request.expectedChatRowID)
        guard participants.elementsEqual(request.expectedParticipantHandles) else {
            throw MessagesReplyComposerParentError.participantDrift
        }
        guard message.is_from_me == request.expectedIsFromMe else {
            throw MessagesReplyComposerParentError.targetDrift
        }
        guard let body = message.body, body.hasPrefix("apple-cli-test"), body.hasPrefix(request.requiredBodyPrefix) else {
            throw MessagesReplyComposerParentError.fixtureUnlabeled
        }
        guard body.utf8.count == request.expectedBodyUTF8Length,
              try AppleAutomationJournal.targetDigest(forOpaqueIdentifier: body).value == request.expectedBodySHA256 else {
            throw MessagesReplyComposerParentError.targetDrift
        }
        let evidence = MessagesReplyComposerProbeEvidence(phase: request.phase,
                                                          chatRowID: request.expectedChatRowID,
                                                          chatGUID: request.chatGUID,
                                                          messageRowID: request.expectedMessageRowID,
                                                          messageGUID: request.messageGUID,
                                                          nativePartIndex: request.nativePartIndex,
                                                          nativePartGUID: request.nativePartGUID,
                                                          participantHandles: participants,
                                                          isFromMe: message.is_from_me,
                                                          bodySHA256: request.expectedBodySHA256,
                                                          bodyUTF8Length: request.expectedBodyUTF8Length,
                                                          requiredBodyPrefix: request.requiredBodyPrefix)
        return MessagesReplyComposerResolvedParentTarget(evidence: evidence, payload: request)
    }

    package static func observedAction(payloadData: Data, deadline: WorkerDeadline) throws -> WorkerObservedAction {
        try observedAction(stateRoot: productionStateRoot(),
                           payloadData: payloadData,
                           deadline: deadline)
    }

    package static func observedAction(stateRoot: String,
                                       payloadData: Data,
                                       deadline: WorkerDeadline) throws -> WorkerObservedAction {
        try observedAction(stateRoot: stateRoot,
                           payloadData: payloadData,
                           deadline: deadline,
                           makeChatDB: { try ChatDB(book: AddressBook()) },
                           automation: MessagesReplyComposerAXAutomation())
    }

    static func observedAction(stateRoot: String,
                               payloadData: Data,
                               deadline: WorkerDeadline,
                               makeChatDB: @escaping @Sendable () throws -> ChatDB,
                               automation: MessagesReplyComposerAXAutomation) throws -> WorkerObservedAction {
        let request = try JSONDecoder().decode(MessagesReplyComposerProbeRequest.self, from: payloadData)
        var originalCleanState: MessagesReplyComposerStartingState?
        return WorkerObservedAction(
            stateRoot: stateRoot,
            deadline: deadline,
            resolve: {
                var db = try makeChatDB()
                let resolved = try resolveTarget(request: request, db: &db)
                let journal = try journalRequest(for: resolved.evidence, payloadData: payloadData)
                return try WorkerResolvedAction(target: WorkerObservedTargetBinding(
                    operationType: journal.operationType,
                    conversationDigest: journal.conversationDigest,
                    messageDigest: journal.messageDigest,
                    partDigest: journal.partDigest,
                    minimumEvidence: journal.minimumEvidence
                ), command: { _ in
                    try WorkerCommand(name: "messages.reply.inspect", payload: payloadData)
                })
            },
            preflight: { _, context in
                var db = try makeChatDB()
                _ = try resolveTarget(request: request, db: &db)
                let clean = try automation.captureStartingDraftSafetyState(request, deadline: context.deadline)
                originalCleanState = clean
                return .requiresMutation
            },
            verify: { _, response, context in
                guard response.category == .ack,
                      response.detail == MessagesReplyComposerProbeDetail.verified else { return nil }
                var db = try makeChatDB()
                _ = try resolveTarget(request: request, db: &db)
                guard let originalCleanState else { throw MessagesReplyComposerParentError.targetDrift }
                return try automation.verifyCleanReplyState(request, original: originalCleanState, deadline: context.deadline)
            })
    }
}
