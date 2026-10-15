import CryptoKit
import Darwin
import Foundation
import AppleKit


package struct MessagesReplyAttachmentFileStat: Codable, Equatable, Sendable {
    package let device: UInt64
    package let inode: UInt64
    package let size: Int64
    package let mode: UInt16
    package let uid: UInt32
    package let modifiedSeconds: Int64
    package let modifiedNanoseconds: Int64
    package let changedSeconds: Int64
    package let changedNanoseconds: Int64

    enum CodingKeys: String, CodingKey {
        case device, inode, size, mode, uid
        case modifiedSeconds = "mtime_sec"
        case modifiedNanoseconds = "mtime_nsec"
        case changedSeconds = "ctime_sec"
        case changedNanoseconds = "ctime_nsec"
    }

    package init(device: UInt64, inode: UInt64, size: Int64, mode: UInt16, uid: UInt32,
                 modifiedSeconds: Int64, modifiedNanoseconds: Int64,
                 changedSeconds: Int64, changedNanoseconds: Int64) throws {
        guard device > 0, inode > 0,
              size >= 0, size <= AttachmentSource.maxBytes,
              mode == 0o600 || mode == 0o700,
              uid == UInt32(getuid()),
              modifiedNanoseconds >= 0, modifiedNanoseconds < 1_000_000_000,
              changedNanoseconds >= 0, changedNanoseconds < 1_000_000_000 else {
            throw MessagesReplyComposerAXError.invalidPayload
        }
        self.device = device
        self.inode = inode
        self.size = size
        self.mode = mode
        self.uid = uid
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
        self.changedSeconds = changedSeconds
        self.changedNanoseconds = changedNanoseconds
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(device: c.decode(UInt64.self, forKey: .device),
                      inode: c.decode(UInt64.self, forKey: .inode),
                      size: c.decode(Int64.self, forKey: .size),
                      mode: c.decode(UInt16.self, forKey: .mode),
                      uid: c.decode(UInt32.self, forKey: .uid),
                      modifiedSeconds: c.decode(Int64.self, forKey: .modifiedSeconds),
                      modifiedNanoseconds: c.decode(Int64.self, forKey: .modifiedNanoseconds),
                      changedSeconds: c.decode(Int64.self, forKey: .changedSeconds),
                      changedNanoseconds: c.decode(Int64.self, forKey: .changedNanoseconds))
    }
}

package struct MessagesReplyAttachmentDraftEvidence: Codable, Equatable, Sendable {
    package let copyPath: String
    package let copyBasename: String
    package let copySHA256: String
    package let copySize: Int
    package let copyStat: MessagesReplyAttachmentFileStat
    package let directoryPath: String
    package let directoryStat: MessagesReplyAttachmentFileStat

    enum CodingKeys: String, CodingKey {
        case copyPath = "copy_path"
        case copyBasename = "copy_basename"
        case copySHA256 = "copy_sha256"
        case copySize = "copy_size"
        case copyStat = "copy_stat"
        case directoryPath = "directory_path"
        case directoryStat = "directory_stat"
    }

    package init(copyPath: String, copyBasename: String, copySHA256: String, copySize: Int, copyStat: MessagesReplyAttachmentFileStat,
                 directoryPath: String, directoryStat: MessagesReplyAttachmentFileStat) throws {
        try validateReplyAttachmentDraftBasename(copyBasename)
        guard !copyPath.isEmpty, copyPath.utf8.count <= 1024,
              !directoryPath.isEmpty, directoryPath.utf8.count <= 1024,
              copySHA256.hasPrefix("sha256:"), copySHA256.utf8.count == 71,
              copySHA256.dropFirst(7).allSatisfy({ $0 >= "0" && $0 <= "9" || $0 >= "a" && $0 <= "f" }),
              (copyPath as NSString).isAbsolutePath,
              (directoryPath as NSString).isAbsolutePath,
              URL(fileURLWithPath: copyPath).standardizedFileURL.path == copyPath,
              URL(fileURLWithPath: directoryPath, isDirectory: true).standardizedFileURL.path == directoryPath,
              copySize >= 1, copySize <= AttachmentSource.maxBytes,
              copyStat.mode == 0o600, directoryStat.mode == 0o700,
              copyStat.uid == UInt32(getuid()), directoryStat.uid == UInt32(getuid()),
              copyStat.size == Int64(copySize), directoryStat.size >= 0,
              URL(fileURLWithPath: copyPath).standardizedFileURL.deletingLastPathComponent().path == URL(fileURLWithPath: directoryPath, isDirectory: true).standardizedFileURL.path,
              URL(fileURLWithPath: copyPath).lastPathComponent.utf8.elementsEqual(copyBasename.utf8) else { throw MessagesReplyComposerAXError.invalidPayload }
        self.copyPath = copyPath
        self.copyBasename = copyBasename
        self.copySHA256 = copySHA256
        self.copySize = copySize
        self.copyStat = copyStat
        self.directoryPath = directoryPath
        self.directoryStat = directoryStat
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(copyPath: c.decode(String.self, forKey: .copyPath),
                      copyBasename: c.decode(String.self, forKey: .copyBasename),
                      copySHA256: c.decode(String.self, forKey: .copySHA256),
                      copySize: c.decode(Int.self, forKey: .copySize),
                      copyStat: c.decode(MessagesReplyAttachmentFileStat.self, forKey: .copyStat),
                      directoryPath: c.decode(String.self, forKey: .directoryPath),
                      directoryStat: c.decode(MessagesReplyAttachmentFileStat.self, forKey: .directoryStat))
    }
}


package struct MessagesReplyAttachmentProbeCleanupEvidence: Codable, Equatable, Sendable {
    package let disposition: String
    package let copyAbsent: Bool?
    package let directoryAbsent: Bool?

    enum CodingKeys: String, CodingKey {
        case disposition
        case copyAbsent = "copy_absent"
        case directoryAbsent = "directory_absent"
    }
}

package struct MessagesReplyAttachmentProbePrivateResult: Codable, Equatable, Sendable {
    package let schemaVersion: Int
    package let outcome: String
    package let category: String?
    package let detail: String?
    package let phase: String?
    package let workerCommand: String?
    package let observedState: String?
    package let operationID: UUID?
    package let observedResult: String?
    package let payloadSHA256: String?
    package let payloadSize: Int?
    package let attachmentDraft: MessagesReplyAttachmentDraftEvidence?
    package let cleanup: MessagesReplyAttachmentProbeCleanupEvidence?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case outcome, category, detail, phase
        case workerCommand = "worker_command"
        case observedState = "observed_state"
        case operationID = "operation_id"
        case observedResult = "observed_result"
        case payloadSHA256 = "payload_sha256"
        case payloadSize = "payload_size"
        case attachmentDraft = "attachment_draft"
        case cleanup
    }
}

package enum MessagesReplyAttachmentProbePrivateEntrypoint {
    // The timeout/cancellation cases deliberately do not authorize cleanup: they
    // can occur after handoff, while Messages may still refer to the copy.
    package static func cleanupBeforeHandoffIfProven(_ evidence: MessagesReplyAttachmentDraftEvidence?,
                                                    launchStarted: Bool,
                                                    outcome: WorkerObservedOutcome?,
                                                    deadline: WorkerDeadline) throws {
        guard let evidence else { return }
        let noHandoff: Bool
        switch outcome {
        case .requestNotSent, .spawnOrSetupFailedBeforeRequest: noHandoff = true
        default: noHandoff = !launchStarted
        }
        if noHandoff { _ = try removeReplyAttachmentDraftCopyIfOwned(evidence, deadline: deadline) }
    }

    package static func cleanupEvidence(for evidence: MessagesReplyAttachmentDraftEvidence?) -> MessagesReplyAttachmentProbeCleanupEvidence? {
        guard let evidence else { return nil }
        let copyAbsent = lstatAbsent(evidence.copyPath)
        let directoryAbsent = lstatAbsent(evidence.directoryPath)
        let disposition: String
        if copyAbsent == true, directoryAbsent == true { disposition = "removed" }
        else if copyAbsent == false || directoryAbsent == false { disposition = "preserved" }
        else { disposition = "unknown" }
        return MessagesReplyAttachmentProbeCleanupEvidence(disposition: disposition,
                                                          copyAbsent: copyAbsent,
                                                          directoryAbsent: directoryAbsent)
    }

    package static func classify(observed outcome: WorkerObservedOutcome?,
                                 prepared request: MessagesReplyComposerProbeRequest?,
                                 payloadData: Data?,
                                 cleanup: MessagesReplyAttachmentProbeCleanupEvidence?) -> (exitCode: Int32, result: MessagesReplyAttachmentProbePrivateResult) {
        let payloadSHA = payloadData.map { "sha256:" + SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        let phase = request?.phase
        let attachment = request?.attachmentDraft
        let payloadSize = payloadData?.count
        guard case .observedState(let operationID, let verification) = outcome,
              verification == MessagesReplyComposerProbeDetail.attachmentDraftVerified,
              request?.phase == "replyAttachmentDraftInspect",
              request?.attachmentDraft != nil,
              payloadData != nil,
              cleanup?.disposition == "removed",
              cleanup?.copyAbsent == true, cleanup?.directoryAbsent == true else {
            return (65, MessagesReplyAttachmentProbePrivateResult(schemaVersion: 1, outcome: "refused", category: nil,
                                                                  detail: nil, phase: phase, workerCommand: request == nil ? nil : "messages.reply.inspect",
                                                                  observedState: nil, operationID: nil, observedResult: outcome?.description,
                                                                  payloadSHA256: payloadSHA, payloadSize: payloadSize,
                                                                  attachmentDraft: attachment, cleanup: cleanup))
        }
        return (0, MessagesReplyAttachmentProbePrivateResult(schemaVersion: 1, outcome: "completed", category: "ack",
                                                             detail: verification, phase: phase, workerCommand: "messages.reply.inspect",
                                                             observedState: "observedState", operationID: operationID,
                                                             observedResult: outcome?.description, payloadSHA256: payloadSHA,
                                                             payloadSize: payloadSize, attachmentDraft: attachment, cleanup: cleanup))
    }

    private static func lstatAbsent(_ path: String) -> Bool? {
        var st = stat()
        if lstat(path, &st) == 0 { return false }
        if errno == ENOENT { return true }
        return nil
    }
}

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
    package let attachmentDraft: MessagesReplyAttachmentDraftEvidence?

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
        case attachmentDraft = "attachment_draft"
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
                 requiredBodyPrefix: String,
                 attachmentDraft: MessagesReplyAttachmentDraftEvidence? = nil) throws {
        let validPhase = (phase == "replyInspect" && attachmentDraft == nil) || (phase == "replyAttachmentDraftInspect" && attachmentDraft != nil)
        guard validPhase,
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
        self.attachmentDraft = attachmentDraft
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
                      requiredBodyPrefix: c.decode(String.self, forKey: .requiredBodyPrefix),
                      attachmentDraft: c.decodeIfPresent(MessagesReplyAttachmentDraftEvidence.self, forKey: .attachmentDraft))
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
        try c.encodeIfPresent(attachmentDraft, forKey: .attachmentDraft)
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


enum MessagesReplyComposerParentError: String, Error, CustomStringConvertible {
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
    let attachmentDraft: MessagesReplyAttachmentDraftEvidence?

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
        case attachmentDraft = "attachment_draft"
    }
}

private struct MessagesReplyComposerResolvedParentTarget {
    let evidence: MessagesReplyComposerProbeEvidence
    let payload: MessagesReplyComposerProbeRequest
}

package enum MessagesReplyComposerProbeParent {
    package static func productionStateRoot() -> String { MessagesAutomationState.productionRoot() }

    package static func payloadDataForAttachmentDraft(base request: MessagesReplyComposerProbeRequest,
                                                      rawFilePath: String,
                                                      scratchRoot: String,
                                                      repoRoot: String,
                                                      home: String = NSHomeDirectory(),
                                                      deadline: WorkerDeadline) throws -> Data {
        guard request.phase == "replyInspect", request.attachmentDraft == nil else { throw MessagesReplyComposerParentError.unsafeInputFile }
        let evidence = try prepareAttachmentDraft(rawFilePath: rawFilePath, scratchRoot: scratchRoot,
                                                  repoRoot: repoRoot, home: home, deadline: deadline)
        do {
            let prepared = try MessagesReplyComposerProbeRequest(chatGUID: request.chatGUID,
                                                                 messageGUID: request.messageGUID,
                                                                 nativePartIndex: request.nativePartIndex,
                                                                 nativePartGUID: request.nativePartGUID,
                                                                 phase: "replyAttachmentDraftInspect",
                                                                 expectedChatRowID: request.expectedChatRowID,
                                                                 expectedMessageRowID: request.expectedMessageRowID,
                                                                 expectedParticipantHandles: request.expectedParticipantHandles,
                                                                 expectedIsFromMe: request.expectedIsFromMe,
                                                                 expectedBodySHA256: request.expectedBodySHA256,
                                                                 expectedBodyUTF8Length: request.expectedBodyUTF8Length,
                                                                 requiredBodyPrefix: request.requiredBodyPrefix,
                                                                 attachmentDraft: evidence)
            return try prepared.workerPayloadData()
        } catch {
            _ = try? removeReplyAttachmentDraftCopyIfOwned(evidence, deadline: deadline)
            throw error
        }
    }

    private static func prepareAttachmentDraft(rawFilePath: String, scratchRoot: String, repoRoot: String, home: String,
                                               deadline: WorkerDeadline) throws -> MessagesReplyAttachmentDraftEvidence {
        try prepareReplyAttachmentDraftCopy(rawFilePath: rawFilePath, scratchRoot: scratchRoot, home: home, deadline: deadline, excludedRoot: repoRoot)
    }

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
                                                          requiredBodyPrefix: request.requiredBodyPrefix,
                                                          attachmentDraft: request.attachmentDraft)
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
                                                          requiredBodyPrefix: request.requiredBodyPrefix,
                                                          attachmentDraft: request.attachmentDraft)
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
                if let attachment = request.attachmentDraft { _ = try validateReplyAttachmentDraftCopy(attachment, deadline: deadline) }
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
                if let attachment = request.attachmentDraft { _ = try validateReplyAttachmentDraftCopy(attachment, deadline: context.deadline) }
                let clean = try automation.captureStartingDraftSafetyState(request, deadline: context.deadline)
                originalCleanState = clean
                return .requiresMutation
            },
            verify: { _, response, context in
                let expectedDetail = request.phase == "replyAttachmentDraftInspect" ? MessagesReplyComposerProbeDetail.attachmentDraftVerified : MessagesReplyComposerProbeDetail.verified
                guard response.category == .ack, response.detail == expectedDetail else { return nil }
                var db = try makeChatDB()
                _ = try resolveTarget(request: request, db: &db)
                if request.attachmentDraft != nil, response.detail != MessagesReplyComposerProbeDetail.attachmentDraftVerified { return nil }
                if let attachment = request.attachmentDraft { _ = try validateReplyAttachmentDraftCopy(attachment, deadline: context.deadline) }
                guard let originalCleanState else { throw MessagesReplyComposerParentError.targetDrift }
                guard try automation.verifyCleanReplyState(request, original: originalCleanState, deadline: context.deadline) == MessagesReplyComposerProbeDetail.verified else { return nil }
                if let attachment = request.attachmentDraft { _ = try removeReplyAttachmentDraftCopyIfOwned(attachment, deadline: context.deadline) }
                return expectedDetail
            })
    }
}
