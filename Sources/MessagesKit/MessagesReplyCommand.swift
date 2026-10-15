import ArgumentParser
import AppleKit
import Foundation

struct Reply: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reply",
        abstract: "Send an exact threaded reply in Messages.",
        subcommands: [ReplySend.self]
    )
    @OptionGroup var global: GlobalOptions
    func run() throws {
        try runGuarded(tool: tool) {
            throw AppleError.validation("specify a reply subcommand: send")
        }
    }
}

struct ReplySend: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "send",
                                                    abstract: "Send a text or attachment reply to an exact root message in a direct chat.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Local conversation ROWID from chat.ROWID.") var chatRowid: Int64?
    @Option(name: .long, help: "Conversation GUID from chat.guid.") var chatGuid: String?
    @Option(name: .long, help: "Local message ROWID from message.ROWID.") var messageRowid: Int64?
    @Option(name: .long, help: "Message GUID from message.guid.") var messageGuid: String?
    @Option(name: .long, help: "Native Messages part index to reply to.") var partIndex: Int?
    @Option(name: .customLong("body"), help: "Reply text. Must be nonempty and no more than 2048 UTF-8 bytes. Mutually exclusive with --file.") var text: String?
    @Option(name: .customLong("file"), help: "Single attachment file to send as the reply. Mutually exclusive with --body.") var file: String?
    @Flag(name: .customLong("experimental-ui-handoff"), help: "Allow the bounded Messages UI handoff required to send the reply.")
    var experimentalUIHandoff = false

    func run() throws { try run(dependencies: .live) }
    func run(dependencies: MessagesCommandDependencies) throws {
        try runReplySend(global: global, dependencies: dependencies, options: self)
    }
}

private struct ReplyResolvedTarget {
    let target: ChatDB.ExactReplyTarget
    let message: ChatDB.ExactMessage
    let participants: [String]
    let text: String?
    let attachmentDraft: MessagesReplyAttachmentDraftEvidence?
    let highwater: Int64?
    let payload: MessagesReplySendRequest?
    let workerCommand: WorkerCommand?
    let binding: WorkerObservedTargetBinding?
}

private struct ReplyPreview: Encodable {
    let action: String
    let experimental: Bool
    let executed: Bool
    let dry_run: Bool
    let target: ReplyTargetOutput
    let text: String?
    let text_utf8_bytes: Int?
    let attachment: ReplyAttachmentPreview?
    let note: String
}

private struct ReplyResult: Encodable {
    let action: String
    let experimental: Bool
    let executed: Bool
    let operation_id: UUID
    let observed_state: String
    let verification: String
    let verification_source: String
    let sent_message_rowid: Int64
    let sent_message_guid: String
    let parent_message_guid: String
    let parent_native_part: Int
    let target: ReplyTargetOutput
    let attachment: ReplyAttachmentResult?
}

private struct ReplyAttachmentPreview: Encodable {
    let path: String
    let basename: String
    let size: Int
}

private struct ReplyAttachmentResult: Encodable {
    let attachment_rowid: Int64
    let attachment_guid: String
    let attachment_filename: String
    let attachment_sha256: String
    let attachment_size: Int
    let copy_cleanup: String
    let copy_directory: String?
}

private struct ReplyTargetOutput: Encodable {
    let chat_rowid: Int64
    let chat_guid: String?
    let message_rowid: Int64
    let message_guid: String
    let native_part: Int
    let participant_handle: String
    let root_is_from_me: Bool
}

private struct ReplyObservedVerification {
    let verification: String
    let proof: ChatDB.ExactReplyCorrespondence?
    let attachmentProof: ChatDB.ExactReplyAttachmentCorrespondence?
}

private final class ReplyObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var resolvedTarget: ReplyResolvedTarget?
    private var cleanState: MessagesReplyCleanStateToken?
    private var observedVerification: ReplyObservedVerification?

    func recordResolved(_ target: ReplyResolvedTarget) {
        lock.withLock { resolvedTarget = target }
    }

    func resolved(matching command: WorkerCommand) throws -> ReplyResolvedTarget {
        try lock.withLock {
            guard let target = resolvedTarget, let workerCommand = target.workerCommand,
                  sameReplyWorkerCommand(workerCommand, command) else {
                throw WorkerProtocolError.malformedFrame
            }
            return target
        }
    }

    func recordCleanState(_ state: MessagesReplyCleanStateToken) {
        lock.withLock { cleanState = state }
    }

    func startingCleanState() throws -> MessagesReplyCleanStateToken {
        try lock.withLock {
            guard let cleanState else { throw WorkerProtocolError.malformedFrame }
            return cleanState
        }
    }

    func recordObserved(_ verification: ReplyObservedVerification) {
        lock.withLock { observedVerification = verification }
    }

    func target() -> ReplyResolvedTarget? { lock.withLock { resolvedTarget } }
    func hasStartingCleanState() -> Bool { lock.withLock { cleanState != nil } }
    func observed() -> ReplyObservedVerification? { lock.withLock { observedVerification } }
}

private struct ReplyTargetDrift: Error, CustomStringConvertible { let description = "target-drift" }
private struct ReplyAccessibilityDenied: Error, CustomStringConvertible {
    let description = "accessibility-not-trusted: enable Accessibility for apple or the host app shown by macOS in System Settings > Privacy & Security > Accessibility, then retry"
}

private func runReplySend(global: GlobalOptions, dependencies: MessagesCommandDependencies, options: ReplySend) throws {
    try runGuarded(tool: tool) {
        let input = try resolveReplyInput(text: options.text, file: options.file, home: FileManager.default.homeDirectoryForCurrentUser.path)
        let gate = try dependencies.resolveGate(global)
        let book = dependencies.loadAddressBook()
        var previewDB = try dependencies.makeChatDB(book)
        let previewTarget = try resolveReplyTarget(db: &previewDB, options: options, input: input, attachmentDraft: nil, highwater: nil)
        try validateReplySandbox(target: previewTarget, db: previewDB, gate: gate)

        guard gate.willExecute else {
            let data = ReplyPreview(action: "messages-reply-send", experimental: true, executed: false, dry_run: true,
                                    target: outputTarget(previewTarget), text: input.text, text_utf8_bytes: input.text?.utf8.count,
                                    attachment: input.attachmentPreview,
                                    note: "Dry run - no UI worker launched and no automation journal state created.")
            try emitWrite(global, data, sandboxActive: gate.sandboxActive) {
                "[dry-run] would send Messages reply to message \(previewTarget.target.message_rowid)"
            }
            return
        }
        guard options.experimentalUIHandoff else {
            throw AppleError.validation("pass --experimental-ui-handoff to execute Messages reply send")
        }

        let stateRoot = dependencies.messagesAutomationStateRoot()
        let observation = ReplyObservation()
        let outcome: WorkerObservedOutcome
        do {
            outcome = try dependencies.launchObservedWorker(WorkerObservedAction(
            stateRoot: stateRoot,
            deadline: .millisecondsFromNow(30_000),
            resolve: {
                var db = try dependencies.makeChatDB(book)
                let highwater = try db.exactReplyHighwater(chatRowid: previewTarget.target.chat_rowid)
                let attachmentDraft = try input.prepareAttachmentDraftIfNeeded(stateRoot: stateRoot, deadline: .millisecondsFromNow(10_000))
                do {
                    let resolved = try resolveReplyTarget(db: &db, options: options, input: input, attachmentDraft: attachmentDraft, highwater: highwater)
                    try validateReplySandbox(target: resolved, db: db, gate: gate)
                    guard let binding = resolved.binding, let workerCommand = resolved.workerCommand else { throw WorkerProtocolError.malformedFrame }
                    observation.recordResolved(resolved)
                    return try WorkerResolvedAction(target: binding) { _ in workerCommand }
                } catch {
                    try? cleanupReplyAttachmentDraftIfPresent(attachmentDraft)
                    throw error
                }
            },
            preflight: { resolved, context in
                let original = try observation.resolved(matching: resolved.command)
                var db = try dependencies.makeChatDB(book)
                guard let fresh = try loadBoundReplyTarget(db: &db, expected: original, input: input, highwater: original.highwater) else {
                    throw ReplyTargetDrift()
                }
                try validateReplySandbox(target: fresh, db: db, gate: gate)
                try requireReplyAccessibility(dependencies.accessibilityDiagnostic())
                guard let payload = original.payload else { throw WorkerProtocolError.malformedFrame }
                let clean = try dependencies.captureReplyCleanState(payload.probeRequest(), context.deadline)
                observation.recordCleanState(clean)
                return .requiresMutation
            },
            verify: { resolved, response, context in
                let original = try observation.resolved(matching: resolved.command)
                guard !context.isCancelled else { throw WorkerProtocolError.cancelled }
                guard !context.deadline.expired else { throw WorkerProtocolError.deadlineExpired }
                guard response.category == .ack, MessagesReplySendACKDetail.isVerified(response.detail),
                      let highwater = original.highwater else { return nil }
                let proof = try pollReplyProof(dependencies: dependencies, book: book, target: original.target,
                                               highwater: highwater, input: input, attachmentDraft: original.attachmentDraft, context: context)
                guard proof.status == "verified" else { return nil }
                let cleanState = try observation.startingCleanState()
                guard let payload = original.payload else { throw WorkerProtocolError.malformedFrame }
                _ = try dependencies.verifyReplyCleanState(payload.probeRequest(), cleanState, context.deadline)
                let verification = input.text == nil
                    ? "observedState: UI clean state, database reply correspondence, and attachment content verified"
                    : "observedState: UI clean state and database reply correspondence verified"
                observation.recordObserved(ReplyObservedVerification(verification: verification, proof: proof.textProof, attachmentProof: proof.attachmentProof))
                return verification
            }
        ))
        } catch {
            if !observation.hasStartingCleanState() {
                try? cleanupReplyAttachmentDraftIfPresent(observation.target()?.attachmentDraft)
            }
            throw error
        }

        switch outcome {
        case .alreadyInDesiredState:
            throw WorkerProtocolError.malformedFrame
        case .observedState(let operationID, let verification):
            guard let target = observation.target(), let observed = observation.observed() else { throw WorkerProtocolError.malformedFrame }
            let textProof = observed.proof
            let attachmentProof = observed.attachmentProof
            guard let sentRowID = textProof?.message_rowid ?? attachmentProof?.message_rowid,
                  let sentGUID = textProof?.message_guid ?? attachmentProof?.message_guid,
                  let parentGUID = textProof?.parent_message_guid ?? attachmentProof?.parent_message_guid,
                  let parentPart = textProof?.parent_native_part ?? attachmentProof?.parent_native_part else {
                throw WorkerProtocolError.malformedFrame
            }
            // The launcher has durably resolved the operation before returning
            // observedState. Reclamation must never consume recovery evidence
            // from inside its still-uncommitted verification callback.
            var copyCleanupComplete = true
            do { try cleanupReplyAttachmentDraftIfPresent(target.attachmentDraft) }
            catch { copyCleanupComplete = false }
            let data = ReplyResult(action: "messages-reply-send", experimental: true, executed: true,
                                   operation_id: operationID, observed_state: "observedState",
                                   verification: verification,
                                   verification_source: input.text == nil ? MessagesReplySendACKDetail.attachmentVerificationSource : MessagesReplySendACKDetail.verificationSource,
                                   sent_message_rowid: sentRowID, sent_message_guid: sentGUID,
                                   parent_message_guid: parentGUID, parent_native_part: parentPart,
                                   target: outputTarget(target),
                                   attachment: attachmentProof.flatMap {
                                       replyAttachmentResult($0, copyCleanupComplete: copyCleanupComplete,
                                                             copyDirectory: target.attachmentDraft?.directoryPath)
                                   })
            try emitWrite(global, ExecutedWrite(data), sandboxActive: gate.sandboxActive) { verification }
        case .timedOut:
            throw AppleError.upstream("Messages reply automation timed out; send may have occurred. An unresolved pending operation may block later writes until `messages automation status` and `messages automation recover` resolve it")
        case .cancelled:
            throw AppleError.upstream("Messages reply automation was cancelled; send may have occurred. Check `messages automation status` before retrying")
        case .verificationFailed:
            throw AppleError.upstream("Messages reply automation could not verify UI cleanup and database correspondence; send may have occurred. Check `messages automation status` before retrying")
        case .requestNotSent(let value), .spawnOrSetupFailedBeforeRequest(let value):
            try? cleanupReplyAttachmentDraftIfPresent(observation.target()?.attachmentDraft)
            throw replyStateError(value)
        case .childRefusedOrFailed(let value), .protocolViolation(let value):
            throw replyStateError(value)
        }
    }
}

private struct ReplyInput {
    let text: String?
    let filePath: String?
    let attachmentPreview: ReplyAttachmentPreview?

    func prepareAttachmentDraftIfNeeded(stateRoot: String, deadline: WorkerDeadline) throws -> MessagesReplyAttachmentDraftEvidence? {
        guard let filePath else { return nil }
        let scratch = URL(fileURLWithPath: stateRoot, isDirectory: true).appendingPathComponent("reply-attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return try prepareReplyAttachmentDraftCopy(rawFilePath: filePath, scratchRoot: scratch.path,
                                                   home: FileManager.default.homeDirectoryForCurrentUser.path,
                                                   deadline: deadline)
    }
}

private func resolveReplyInput(text: String?, file: String?, home: String) throws -> ReplyInput {
    switch (text, file) {
    case (.some(let value), nil):
        try validateReplyText(value)
        return ReplyInput(text: value, filePath: nil, attachmentPreview: nil)
    case (nil, .some(let raw)):
        let resolved = try AttachmentSource.resolve(raw, home: home)
        let attrs = try FileManager.default.attributesOfItem(atPath: resolved)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let basename = URL(fileURLWithPath: resolved).lastPathComponent
        try validateReplyAttachmentDraftBasename(basename)
        return ReplyInput(text: nil, filePath: resolved,
                          attachmentPreview: ReplyAttachmentPreview(path: resolved, basename: basename, size: size))
    default:
        throw AppleError.validation("pass exactly one of --body or --file")
    }
}

private func validateReplyText(_ text: String) throws {
    guard !text.isEmpty else { throw AppleError.validation("reply text must be nonempty") }
    guard text.utf8.count <= 2048 else { throw AppleError.validation("reply text must be at most 2048 UTF-8 bytes") }
}

private protocol ReplyTargetOptions {
    var chatRowid: Int64? { get }
    var chatGuid: String? { get }
    var messageRowid: Int64? { get }
    var messageGuid: String? { get }
    var partIndex: Int? { get }
}

extension ReplySend: ReplyTargetOptions {}

private func resolveReplyTarget(db: inout ChatDB, options: any ReplyTargetOptions, input: ReplyInput,
                                attachmentDraft: MessagesReplyAttachmentDraftEvidence?, highwater: Int64?) throws -> ReplyResolvedTarget {
    let target = try db.exactReplyTarget(chat: try parseReplyChatSelector(rowid: options.chatRowid, guid: options.chatGuid),
                                         message: try parseReplyMessageSelector(rowid: options.messageRowid, guid: options.messageGuid),
                                         partIndex: options.partIndex)
    let (_, message) = try db.exactGet(chat: .rowid(target.chat_rowid), message: .rowid(target.message_rowid))
    let participants = try db.exactParticipantHandles(chatRowid: target.chat_rowid)
    let body = message.body ?? ""
    let payload: MessagesReplySendRequest?
    let payloadData: Data?
    if input.text != nil || attachmentDraft != nil {
        do {
            let built = try MessagesReplySendRequest(chatGUID: target.chat_guid ?? "",
                                                     messageGUID: target.message_guid,
                                                     nativePartIndex: target.native_part,
                                                     nativePartGUID: "p:\(target.native_part)/\(target.message_guid)",
                                                     expectedChatRowID: target.chat_rowid,
                                                     expectedMessageRowID: target.message_rowid,
                                                     expectedParticipantHandles: participants,
                                                     expectedIsFromMe: target.root_is_from_me,
                                                     expectedBodySHA256: AppleAutomationJournal.targetDigest(forOpaqueIdentifier: body).value,
                                                     expectedBodyUTF8Length: body.utf8.count,
                                                     requiredBodyPrefix: TestMode.canonicalSandboxPrefix,
                                                     text: input.text,
                                                     attachmentDraft: attachmentDraft)
            payload = built
            payloadData = try built.workerPayloadData()
        } catch {
            throw AppleError.validation("reply target or reply content exceeds bounded worker payload")
        }
    } else {
        payload = nil
        payloadData = nil
    }
    let contentEvidence = input.text.map { "text-bytes:\($0.utf8.count)" } ?? "attachment:\(attachmentDraft?.copySHA256 ?? input.attachmentPreview?.path ?? "pending")"
    let rawTarget = "chat:\(target.chat_rowid):\(target.chat_guid ?? "")|message:\(target.message_rowid):\(target.message_guid)|part:\(target.native_part)|\(contentEvidence)"
    let binding: WorkerObservedTargetBinding?
    if let payloadData {
        binding = try WorkerObservedTargetBinding(
            operationType: .replySend,
            conversationDigest: AppleAutomationJournal.targetDigest(forOpaqueIdentifier: "chat:\(target.chat_rowid):\(target.chat_guid ?? "")"),
            messageDigest: AppleAutomationJournal.targetDigest(forOpaqueIdentifier: "message:\(target.message_rowid):\(target.message_guid)"),
            partDigest: AppleAutomationJournal.targetDigest(forOpaqueIdentifier: "part:\(target.native_part)"),
            minimumEvidence: .init(targetHash: AppleAutomationJournal.targetDigest(forOpaqueIdentifier: rawTarget),
                                   targetLength: payloadData.count))
    } else {
        binding = nil
    }
    return ReplyResolvedTarget(target: target, message: message, participants: participants, text: input.text,
                               attachmentDraft: attachmentDraft, highwater: highwater, payload: payload,
                               workerCommand: try payloadData.map { try WorkerCommand(name: "messages.reply.send", payload: $0) },
                               binding: binding)
}

private func loadBoundReplyTarget(db: inout ChatDB, expected: ReplyResolvedTarget, input: ReplyInput, highwater: Int64?) throws -> ReplyResolvedTarget? {
    let fresh = try resolveReplyTarget(db: &db, options: ReplySendOptions(target: expected.target), input: input,
                                       attachmentDraft: expected.attachmentDraft, highwater: highwater)
    guard fresh.target.chat_rowid == expected.target.chat_rowid,
          byteEqual(fresh.target.chat_guid, expected.target.chat_guid),
          fresh.target.message_rowid == expected.target.message_rowid,
          byteEqual(fresh.target.message_guid, expected.target.message_guid),
          fresh.target.native_part == expected.target.native_part,
          byteEqual(fresh.target.part_guid, expected.target.part_guid),
          fresh.participants.elementsEqual(expected.participants) else { return nil }
    if let lhs = fresh.workerCommand, let rhs = expected.workerCommand {
        guard sameReplyWorkerCommand(lhs, rhs) else { return nil }
    } else if fresh.workerCommand != nil || expected.workerCommand != nil {
        return nil
    }
    return fresh
}

private struct ReplySendOptions: ReplyTargetOptions {
    let chatRowid: Int64?
    let chatGuid: String?
    let messageRowid: Int64?
    let messageGuid: String?
    let partIndex: Int?
    init(target: ChatDB.ExactReplyTarget) {
        self.chatRowid = target.chat_rowid
        self.chatGuid = nil
        self.messageRowid = target.message_rowid
        self.messageGuid = nil
        self.partIndex = target.native_part
    }
}

private func parseReplyChatSelector(rowid: Int64?, guid: String?) throws -> ChatDB.ExactChatSelector {
    switch (rowid, guid) {
    case (.some(let rowid), nil): return .rowid(rowid)
    case (nil, .some(let guid)): return .guid(guid)
    default: throw AppleError.validation("pass exactly one of --chat-rowid or --chat-guid")
    }
}

private func parseReplyMessageSelector(rowid: Int64?, guid: String?) throws -> ChatDB.ExactMessageSelector {
    switch (rowid, guid) {
    case (.some(let rowid), nil): return .rowid(rowid)
    case (nil, .some(let guid)): return .guid(guid)
    default: throw AppleError.validation("pass exactly one of --message-rowid or --message-guid")
    }
}

private func validateReplySandbox(target: ReplyResolvedTarget, db: ChatDB, gate: MessagesWriteGuard.Gate) throws {
    guard gate.sandboxActive else { return }
    let prefix = gate.sandboxPrefix
    if let text = target.text {
        guard text.hasPrefix(prefix) else {
            throw AppleError.safetyViolation("sandboxed Messages reply text must start with \(prefix)")
        }
    }
    guard (target.message.body ?? "").hasPrefix(prefix) else {
        throw AppleError.safetyViolation("sandboxed Messages reply target must be labeled \(prefix)")
    }
    guard target.participants.count == 1, let participant = target.participants.first else {
        throw AppleError.safetyViolation("sandboxed Messages reply requires one direct recipient")
    }
    let normalized = Send.normalizeForAllowlist(participant)
    let allowed = gate.allowedRecipients.map(Send.normalizeForAllowlist)
    guard allowed.contains(where: { Send.phonesEquivalent($0, normalized) }) else {
        throw AppleError.safetyViolation("recipient not allowed by APPLE_TEST_RECIPIENTS: \(participant)")
    }
}

private func requireReplyAccessibility(_ diagnostic: Permissions.AccessibilityPreflight) throws {
    guard diagnostic.trusted else { throw ReplyAccessibilityDenied() }
}

private struct PolledReplyProof {
    let status: String
    let textProof: ChatDB.ExactReplyCorrespondence?
    let attachmentProof: ChatDB.ExactReplyAttachmentCorrespondence?
}

private func pollReplyProof(dependencies: MessagesCommandDependencies, book: AddressBook,
                            target: ChatDB.ExactReplyTarget, highwater: Int64,
                            input: ReplyInput, attachmentDraft: MessagesReplyAttachmentDraftEvidence?,
                            context: WorkerObservedContext) throws -> PolledReplyProof {
    var last = PolledReplyProof(status: "waiting", textProof: nil, attachmentProof: nil)
    for attempt in 0...20 {
        guard !context.isCancelled else { throw WorkerProtocolError.cancelled }
        guard !context.deadline.expired else { throw WorkerProtocolError.deadlineExpired }
        var db = try dependencies.makeChatDB(book)
        if let expectedText = input.text {
            let proof = try ChatDB.judgeExactReplyCorrespondence(scan: db.exactReplyRows(chatRowid: target.chat_rowid, afterHighwater: highwater),
                                                                 target: target, expectedText: expectedText)
            last = PolledReplyProof(status: proof.status, textProof: proof, attachmentProof: nil)
        } else if let attachmentDraft {
            let proof = try db.exactReplyAttachmentCorrespondence(chatRowid: target.chat_rowid, afterHighwater: highwater,
                                                                  target: target,
                                                                  expectedAttachmentSHA256: attachmentDraft.copySHA256,
                                                                  expectedAttachmentSize: attachmentDraft.copySize,
                                                                  checkpoint: {
                                                                      guard !context.isCancelled else { throw WorkerProtocolError.cancelled }
                                                                      guard !context.deadline.expired else { throw WorkerProtocolError.deadlineExpired }
                                                                  })
            last = PolledReplyProof(status: proof.status, textProof: nil, attachmentProof: proof)
        } else { throw WorkerProtocolError.malformedFrame }
        if last.status != "waiting" { return last }
        guard attempt < 20 else { return last }
        let remaining = context.deadline.remainingNanoseconds
        if remaining == 0 { throw WorkerProtocolError.deadlineExpired }
        Thread.sleep(forTimeInterval: Double(min(250_000_000, remaining)) / 1_000_000_000)
    }
    return last
}

private func cleanupReplyAttachmentDraftIfPresent(_ draft: MessagesReplyAttachmentDraftEvidence?) throws {
    guard let draft else { return }
    _ = try removeReplyAttachmentDraftCopyIfOwned(draft, deadline: .millisecondsFromNow(5_000))
}

private func replyAttachmentResult(_ proof: ChatDB.ExactReplyAttachmentCorrespondence,
                                    copyCleanupComplete: Bool, copyDirectory: String?) -> ReplyAttachmentResult? {
    guard let rowid = proof.attachment_rowid,
          let guid = proof.attachment_guid,
          let filename = proof.attachment_filename,
          let sha256 = proof.attachment_sha256,
          let size = proof.attachment_size else { return nil }
    return ReplyAttachmentResult(attachment_rowid: rowid, attachment_guid: guid,
                                 attachment_filename: filename, attachment_sha256: sha256,
                                 attachment_size: size,
                                 copy_cleanup: copyCleanupComplete ? "complete" : "incomplete",
                                 copy_directory: copyCleanupComplete ? nil : copyDirectory)
}


private func sameReplyWorkerCommand(_ lhs: WorkerCommand, _ rhs: WorkerCommand) -> Bool {
    lhs.name == rhs.name && lhs.payload == rhs.payload
}

private func outputTarget(_ resolved: ReplyResolvedTarget) -> ReplyTargetOutput {
    ReplyTargetOutput(chat_rowid: resolved.target.chat_rowid,
                      chat_guid: resolved.target.chat_guid,
                      message_rowid: resolved.target.message_rowid,
                      message_guid: resolved.target.message_guid,
                      native_part: resolved.target.native_part,
                      participant_handle: resolved.target.participant_handle,
                      root_is_from_me: resolved.target.root_is_from_me)
}

private func replyStateError(_ detail: String) -> Error {
    if detail.hasPrefix("accessibility-not-trusted") { return AppleError.permissionDenied(detail) }
    return AppleError.upstream(detail)
}

private func byteEqual(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case (.some(let lhs), .some(let rhs)): return lhs.utf8.elementsEqual(rhs.utf8)
    default: return false
    }
}
