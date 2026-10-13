import ArgumentParser
import AppleKit
import Foundation

private let reactionRowLimit = 512

enum MessagesAutomationState {
    static func productionRoot() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".apple-cli-messages-automation", isDirectory: true)
            .path
    }
}

extension MessagesCommand {
    package static func workerOperationRegistry() -> any WorkerOperationRegistry {
        MessagesReactionWorkerRegistry()
    }
}

struct Reaction: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reaction",
        abstract: "Inspect or mutate an exact message reaction.",
        subcommands: [ReactionInspect.self, ReactionSet.self, ReactionRemove.self]
    )
    @OptionGroup var global: GlobalOptions

    func run() throws {
        try runGuarded(tool: tool) {
            throw AppleError.validation("specify a reaction subcommand: inspect, set, remove")
        }
    }
}

private protocol ReactionTargetOptions {
    var chatRowid: Int64? { get }
    var chatGuid: String? { get }
    var messageRowid: Int64? { get }
    var messageGuid: String? { get }
    var partIndex: Int? { get }
}

private extension ReactionTargetOptions {
    func chatSelector() throws -> ChatDB.ExactChatSelector {
        try parseChatSelector(rowid: chatRowid, guid: chatGuid)
    }

    func messageSelector() throws -> ChatDB.ExactMessageSelector {
        try parseMessageSelector(rowid: messageRowid, guid: messageGuid)
    }
}

private protocol ReactionWriteOptions: ReactionTargetOptions {
    var standardReaction: String? { get }
    var emoji: String? { get }
    var experimentalUIHandoff: Bool { get }
}

private enum ReactionMutation: String, Encodable {
    case set
    case remove
}

private let reactionExperimentalHandoffLimitation =
    "experimental_ui_handoff cannot prove original message continuity after modal; keep Messages untouched during automation."

private func reactionTargetingMode(_ experimentalUIHandoff: Bool) -> String {
    experimentalUIHandoff ? "experimental_ui_handoff" : "strict"
}

private func reactionTargetingLimitation(_ experimentalUIHandoff: Bool) -> String? {
    experimentalUIHandoff ? reactionExperimentalHandoffLimitation : nil
}

private struct ReactionResolvedTarget {
    let inspect: ChatDB.ExactReactionInspect
    let message: ChatDB.ExactMessage
    let reaction: MessagesReaction?
    let reactionKey: String?
    let nativePartGUID: String?
    let workerPayload: MessagesReactionWorkerPayload?
    let workerCommand: WorkerCommand
    let binding: WorkerObservedTargetBinding
    let experimentalUIHandoff: Bool
}

private struct ReactionBoundVerification {
    let verification: String
    let inspect: ChatDB.ExactReactionInspect
    let verificationSource: String
    let reactionChanged: Bool
}

private struct ReactionTargetDrift: Error, CustomStringConvertible {
    let description: String = "target-drift"
}

private struct ReactionCustomExecutionUnsupported: Error, CustomStringConvertible {
    let description: String = "custom-reaction-execution-unsupported"
}

private final class ReactionMutationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var resolvedTarget: ReactionResolvedTarget?
    private var observedVerification: ReactionBoundVerification?

    func recordResolved(_ target: ReactionResolvedTarget) {
        lock.withLock { resolvedTarget = target }
    }

    func resolved(matching command: WorkerCommand) throws -> ReactionResolvedTarget {
        try lock.withLock {
            guard let target = resolvedTarget, sameReactionWorkerCommand(target.workerCommand, command) else {
                throw WorkerProtocolError.malformedFrame
            }
            return target
        }
    }

    func recordObserved(_ verification: ReactionBoundVerification) {
        lock.withLock { observedVerification = verification }
    }

    func target() -> ReactionResolvedTarget? {
        lock.withLock { resolvedTarget }
    }

    func observed() -> ReactionBoundVerification? {
        lock.withLock { observedVerification }
    }
}

private struct ReactionPreview: Encodable {
    let action: String
    let experimental: Bool
    let executed: Bool
    let dry_run: Bool
    let operation: ReactionMutation
    let targeting_mode: String
    let limitation: String?
    let desired_reaction_key: String?
    let inspect: ChatDB.ExactReactionInspect
    let note: String
}

private struct ReactionMutationResult: Encodable {
    let action: String
    let experimental: Bool
    let executed: Bool
    let operation: ReactionMutation
    let operation_id: UUID?
    let observed_state: String
    let verification: String
    let verification_source: String
    let reaction_changed: Bool
    let targeting_mode: String
    let limitation: String?
    let desired_reaction_key: String?
    let inspect: ChatDB.ExactReactionInspect

    enum CodingKeys: String, CodingKey {
        case action, experimental, executed, operation, operation_id, observed_state
        case verification, verification_source, reaction_changed, targeting_mode, limitation, desired_reaction_key, inspect
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(action, forKey: .action)
        try c.encode(experimental, forKey: .experimental)
        try c.encode(executed, forKey: .executed)
        try c.encode(operation, forKey: .operation)
        try encodeOrNull(&c, operation_id, .operation_id)
        try c.encode(observed_state, forKey: .observed_state)
        try c.encode(verification, forKey: .verification)
        try c.encode(verification_source, forKey: .verification_source)
        try c.encode(reaction_changed, forKey: .reaction_changed)
        try c.encode(targeting_mode, forKey: .targeting_mode)
        try encodeOrNull(&c, limitation, .limitation)
        try encodeOrNull(&c, desired_reaction_key, .desired_reaction_key)
        try c.encode(inspect, forKey: .inspect)
    }
}

private struct ReactionStatusData: Encodable {
    struct Pending: Encodable {
        let operation_id: UUID
        let operation_type: String
        let phase: String
    }
    struct Receipt: Encodable {
        let operation_id: UUID
        let disposition: String
    }
    let action: String
    let pending: Pending?
    let receipts: [Receipt]

    enum CodingKeys: String, CodingKey { case action, pending, receipts }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(action, forKey: .action)
        try encodeOrNull(&c, pending, .pending)
        try c.encode(receipts, forKey: .receipts)
    }
}

private struct ReactionRecoverData: Encodable {
    let action: String
    let operation_id: UUID
    let recovered: Bool
    let dry_run: Bool
    let acknowledgement: String
}

private func readReactionStatus(root: String) throws -> ReactionStatusData {
    let snapshot = try AppleAutomationJournal.withLockedJournal(
        root: root,
        deadline: .millisecondsFromNow(1_000)
    ) { try $0.loadSnapshot() }
    return ReactionStatusData(
        action: "messages-automation-status",
        pending: snapshot.pending.map {
            ReactionStatusData.Pending(operation_id: $0.operationID,
                                       operation_type: $0.operationType.rawValue,
                                       phase: $0.phase.rawValue)
        },
        receipts: snapshot.receipts.map {
            ReactionStatusData.Receipt(operation_id: $0.operationID,
                                       disposition: $0.disposition.rawValue)
        }
    )
}

private func recoverReaction(root: String, operationID: UUID, acknowledged: Bool, willExecute: Bool) throws -> ReactionRecoverData {
    guard acknowledged else {
        throw AppleError.validation("pass --acknowledge-possible-late-effects to recover a pending Messages automation operation")
    }
    do {
        guard willExecute else {
            try AppleAutomationJournal.withLockedJournal(root: root, deadline: .millisecondsFromNow(1_000)) { lease in
                let snapshot = try lease.loadSnapshot()
                guard let pending = snapshot.pending, pending.operationID == operationID else {
                    throw AppleAutomationJournal.Error.operationNotFound(operationID.uuidString)
                }
                guard pending.phase == .uncertainAfterHandoff else {
                    throw AppleAutomationJournal.Error.handoffNotRecorded
                }
            }
            return ReactionRecoverData(action: "messages-automation-recover", operation_id: operationID,
                                       recovered: false,
                                       dry_run: true,
                                       acknowledgement: "dry run - possible late effects acknowledged but pending state was not cleared")
        }
        try AppleAutomationJournal.withLockedJournal(root: root, deadline: .millisecondsFromNow(1_000)) { lease in
            try lease.recover(operationID: operationID,
                              acknowledgement: .init(operationID: operationID,
                                                       lateEffectAcknowledged: true))
        }
    } catch let error as AppleAutomationJournal.Error {
        throw reactionStateError(error)
    }
    return ReactionRecoverData(action: "messages-automation-recover", operation_id: operationID,
                               recovered: true,
                               dry_run: false,
                               acknowledgement: "possible late effects acknowledged")
}

private func reactionStateError(_ error: any Error) -> AppleError {
    AppleError(type: AppleErrorType.upstream,
               message: "Messages automation state blocked this write: \(String(describing: error))",
               exitCode: AppleExit.upstream)
}

private func parseRequestedReaction(_ options: any ReactionWriteOptions, current: ChatDB.ExactCurrentOutgoingReaction?,
                                    operation: ReactionMutation) throws -> (MessagesReaction?, String?) {
    if options.emoji != nil, options.standardReaction != nil {
        throw AppleError.validation("pass exactly one of --reaction or --emoji")
    }
    if let raw = options.standardReaction {
        guard options.emoji == nil else { throw AppleError.validation("pass exactly one of --reaction or --emoji") }
        switch raw {
        case "heart": return (.standard(.heart), "heart")
        case "like": return (.standard(.thumbsUp), "like")
        case "dislike": return (.standard(.thumbsDown), "dislike")
        case "laugh": return (.standard(.ha), "laugh")
        case "emphasize": return (.standard(.exclamation), "emphasize")
        case "question": return (.standard(.questionMark), "question")
        default:
            throw AppleError.validation("reaction must be one of: heart, like, dislike, laugh, emphasize, question")
        }
    }
    if let emoji = options.emoji {
        guard emoji.count == 1 else { throw AppleError.validation("emoji must be exactly one grapheme") }
        return (.custom(emoji), "custom:\(emoji)")
    }
    guard operation == .remove, let current else {
        throw AppleError.validation("pass exactly one of --reaction or --emoji")
    }
    guard current.status == "present", let reaction = current.reaction else {
        throw AppleError.validation("pass --reaction when no outgoing standard reaction is recorded for implicit removal")
    }
    if let emoji = reaction.emoji { return (.custom(emoji), reaction.key) }
    return try parseExistingStandardReaction(key: reaction.key)
}

private func parseExistingStandardReaction(key: String) throws -> (MessagesReaction, String) {
    switch key {
    case "heart": return (.standard(.heart), key)
    case "like": return (.standard(.thumbsUp), key)
    case "dislike": return (.standard(.thumbsDown), key)
    case "laugh": return (.standard(.ha), key)
    case "emphasize": return (.standard(.exclamation), key)
    case "question": return (.standard(.questionMark), key)
    default: throw AppleError.validation("current outgoing reaction is not removable by this version")
    }
}

private func byteEqual(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
}

private func byteEqual(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (.some(let left), .some(let right)): return byteEqual(left, right)
    case (.none, .none): return true
    default: return false
    }
}

private func sameReaction(_ current: ChatDB.ExactCurrentOutgoingReaction, desired key: String?) -> Bool {
    guard let key else { return false }
    return current.status == "present" && current.key.map { byteEqual($0, key) } == true
}

private func absentForRemoval(_ current: ChatDB.ExactCurrentOutgoingReaction, desired key: String?) -> Bool {
    guard let key else { return current.status == "absent" }
    return current.status == "absent" || (current.status == "present" && current.key.map { !byteEqual($0, key) } == true)
}

private func sameReactionValue(_ lhs: MessagesReaction, _ rhs: MessagesReaction) -> Bool {
    switch (lhs, rhs) {
    case (.standard(let left), .standard(let right)):
        return byteEqual(left.rawValue, right.rawValue)
    case (.custom(let left), .custom(let right)):
        return byteEqual(left, right)
    default:
        return false
    }
}

private func resolveReactionTarget(db: inout ChatDB, options: any ReactionWriteOptions,
                                   operation: ReactionMutation) throws -> ReactionResolvedTarget {
    let inspect = try db.exactReactionInspect(chat: options.chatSelector(),
                                              message: options.messageSelector(),
                                              partIndex: options.partIndex,
                                              rowLimit: reactionRowLimit)
    guard inspect.target.mutation_eligible else {
        throw AppleError.validation("message reaction target is not mutation-eligible")
    }
    guard let chatGUID = inspect.target.chat_guid, let messageGUID = inspect.target.message_guid,
          let nativePartIndex = inspect.target.part_index else {
        throw AppleError.validation("message reaction target lacks required native identity")
    }
    let (_, message) = try db.exactGet(chat: .rowid(inspect.target.chat_rowid),
                                       message: .rowid(inspect.target.message_rowid))
    let (reaction, reactionKey) = try parseRequestedReaction(options, current: inspect.current_outgoing,
                                                             operation: operation)
    let nativePartGUID = "p:\(nativePartIndex)/\(messageGUID)"
    let payload = try reaction.map { reaction in
        try MessagesReactionWorkerPayload(
            operation: operation == .set ? .set : .remove,
            chatGUID: chatGUID,
            messageGUID: messageGUID,
            nativePartIndex: nativePartIndex,
            nativePartGUID: nativePartGUID,
            reaction: reaction,
            experimentalUIHandoff: options.experimentalUIHandoff
        )
    }
    let rawReaction = reactionKey ?? "absent"
    let rawTarget = "chat:\(inspect.target.chat_rowid):\(chatGUID)|message:\(inspect.target.message_rowid):\(messageGUID)|part:\(nativePartIndex)|reaction:\(rawReaction)|op:\(operation.rawValue)|mode:\(reactionTargetingMode(options.experimentalUIHandoff))"
    let binding = try WorkerObservedTargetBinding(
        operationType: .reactionSet,
        conversationDigest: AppleAutomationJournal.targetDigest(forOpaqueIdentifier: "chat:\(inspect.target.chat_rowid):\(chatGUID)"),
        messageDigest: AppleAutomationJournal.targetDigest(forOpaqueIdentifier: "message:\(inspect.target.message_rowid):\(messageGUID)"),
        partDigest: AppleAutomationJournal.targetDigest(forOpaqueIdentifier: "part:\(nativePartIndex)"),
        minimumEvidence: .init(targetHash: AppleAutomationJournal.targetDigest(forOpaqueIdentifier: rawTarget),
                               targetLength: rawTarget.utf8.count)
    )
    return ReactionResolvedTarget(
        inspect: inspect,
        message: message,
        reaction: reaction,
        reactionKey: reactionKey,
        nativePartGUID: nativePartGUID,
        workerPayload: payload,
        workerCommand: try payload.map { payload in
            try WorkerCommand(name: operation == .set ? "messages.reaction.set" : "messages.reaction.remove",
                              payload: try payload.workerPayloadData())
        } ?? WorkerCommand(name: "messages.reaction.noop", payload: nil),
        binding: binding,
        experimentalUIHandoff: options.experimentalUIHandoff
    )
}

private func validateReactionSandbox(target: ReactionResolvedTarget, db: ChatDB,
                                     gate: MessagesWriteGuard.Gate) throws {
    let body = target.message.body ?? ""
    if gate.sandboxActive, !body.hasPrefix(gate.sandboxPrefix) {
        throw AppleError.safetyViolation("refusing reaction mutation: target message is not labeled \(gate.sandboxPrefix)", sandbox: true)
    }
    guard gate.sandboxActive else { return }
    let participants = try db.exactParticipantHandles(chatRowid: target.inspect.target.chat_rowid)
    if participants.count != 1 {
        throw AppleError.safetyViolation("refusing reaction mutation: sandbox requires exactly one allowed participant", sandbox: true)
    }
    guard let only = participants.first,
          gate.allowedRecipients.contains(where: {
              Send.phonesEquivalent(Send.normalizeForAllowlist($0),
                                    Send.normalizeForAllowlist(only))
          }) else {
        throw AppleError.safetyViolation("refusing reaction mutation: selected conversation is not the single allowed sandbox recipient", sandbox: true)
    }
}


private func sameReactionWorkerCommand(_ lhs: WorkerCommand, _ rhs: WorkerCommand) -> Bool {
    guard byteEqual(lhs.name, rhs.name) else { return false }
    if lhs.payload == rhs.payload { return true }
    guard let leftData = lhs.payload, let rightData = rhs.payload,
          let left = try? JSONDecoder().decode(MessagesReactionWorkerPayload.self, from: leftData),
          let right = try? JSONDecoder().decode(MessagesReactionWorkerPayload.self, from: rightData)
    else { return false }
    return left.operation == right.operation
        && byteEqual(left.chatGUID, right.chatGUID)
        && byteEqual(left.messageGUID, right.messageGUID)
        && left.nativePartIndex == right.nativePartIndex
        && byteEqual(left.nativePartGUID, right.nativePartGUID)
        && sameReactionValue(left.reaction, right.reaction)
        && left.experimentalUIHandoff == right.experimentalUIHandoff
}


private struct ReactionAccessibilityDenied: Error, CustomStringConvertible {
    let description: String = "accessibility-not-trusted: enable Accessibility for apple or the host app shown by macOS in System Settings > Privacy & Security > Accessibility, then retry"
}

private func requireReactionAccessibility(_ diagnostic: Permissions.AccessibilityPreflight) throws {
    guard diagnostic.trusted else { throw ReactionAccessibilityDenied() }
}

private func exactReactionIdentityMatches(_ fresh: ChatDB.ExactReactionInspect,
                                          _ expected: ReactionResolvedTarget) -> Bool {
    fresh.target.chat_rowid == expected.inspect.target.chat_rowid
        && byteEqual(fresh.target.chat_guid, expected.inspect.target.chat_guid)
        && fresh.target.message_rowid == expected.inspect.target.message_rowid
        && byteEqual(fresh.target.message_guid, expected.inspect.target.message_guid)
        && fresh.target.part_index == expected.inspect.target.part_index
        && fresh.target.mutation_eligible
}

private func loadBoundReactionInspect(db: inout ChatDB, expected: ReactionResolvedTarget) throws -> ChatDB.ExactReactionInspect? {
    let fresh = try db.exactReactionInspect(chat: .rowid(expected.inspect.target.chat_rowid),
                                            message: .rowid(expected.inspect.target.message_rowid),
                                            partIndex: expected.inspect.target.part_index,
                                            rowLimit: reactionRowLimit)
    guard exactReactionIdentityMatches(fresh, expected) else { return nil }
    return fresh
}

private func loadBoundReactionTarget(db: inout ChatDB, expected: ReactionResolvedTarget) throws -> ReactionResolvedTarget? {
    guard let fresh = try loadBoundReactionInspect(db: &db, expected: expected) else { return nil }
    let (_, message) = try db.exactGet(chat: .rowid(expected.inspect.target.chat_rowid),
                                       message: .rowid(expected.inspect.target.message_rowid))
    return ReactionResolvedTarget(inspect: fresh,
                                  message: message,
                                  reaction: expected.reaction,
                                  reactionKey: expected.reactionKey,
                                  nativePartGUID: expected.nativePartGUID,
                                  workerPayload: expected.workerPayload,
                                  workerCommand: expected.workerCommand,
                                  binding: expected.binding,
                                  experimentalUIHandoff: expected.experimentalUIHandoff)
}

private func desiredReactionText(_ key: String?) -> String { key ?? "absent" }

private func reactionACKProof(response: WorkerResponse, operation: ReactionMutation) -> Bool? {
    guard response.category == .ack, let detail = response.detail else { return nil }
    switch (operation, detail) {
    case (.set, MessagesReactionACKDetail.verified(operation: .set, changed: true)):
        return true
    case (.set, MessagesReactionACKDetail.verified(operation: .set, changed: false)):
        return false
    case (.remove, MessagesReactionACKDetail.verified(operation: .remove, changed: true)):
        return true
    case (.remove, MessagesReactionACKDetail.verified(operation: .remove, changed: false)):
        return false
    default:
        return nil
    }
}

private func runReactionMutation(global: GlobalOptions, dependencies: MessagesCommandDependencies,
                                 options: any ReactionWriteOptions,
                                 operation: ReactionMutation) throws {
    try runGuarded(tool: tool) {
        let gate = try dependencies.resolveGate(global)
        let book = dependencies.loadAddressBook()
        var previewDB = try dependencies.makeChatDB(book)
        let previewTarget = try resolveReactionTarget(db: &previewDB, options: options, operation: operation)
        try validateReactionSandbox(target: previewTarget, db: previewDB, gate: gate)

        guard gate.willExecute else {
            let data = ReactionPreview(action: "reaction-\(operation.rawValue)",
                                       experimental: true,
                                       executed: false,
                                       dry_run: true,
                                       operation: operation,
                                       targeting_mode: reactionTargetingMode(previewTarget.experimentalUIHandoff),
                                       limitation: reactionTargetingLimitation(previewTarget.experimentalUIHandoff),
                                       desired_reaction_key: previewTarget.reactionKey,
                                       inspect: previewTarget.inspect,
                                       note: "Dry run - no UI worker launched and no automation journal state created.")
            try emitWrite(global, data, sandboxActive: gate.sandboxActive) {
                "[dry-run] would \(operation.rawValue) reaction \(desiredReactionText(previewTarget.reactionKey))"
            }
            return
        }

        let stateRoot = dependencies.messagesAutomationStateRoot()
        let observation = ReactionMutationObservation()
        let outcome = try dependencies.launchObservedWorker(WorkerObservedAction(
            stateRoot: stateRoot,
            deadline: .millisecondsFromNow(30_000),
            resolve: {
                var db = try dependencies.makeChatDB(book)
                let resolved = try resolveReactionTarget(db: &db, options: options, operation: operation)
                try validateReactionSandbox(target: resolved, db: db, gate: gate)
                if case .custom = resolved.reaction,
                   !(operation == .remove && options.emoji != nil) {
                    throw ReactionCustomExecutionUnsupported()
                }
                observation.recordResolved(resolved)
                return try WorkerResolvedAction(target: resolved.binding) { _ in resolved.workerCommand }
            },
            preflight: { resolved, _ in
                let original = try observation.resolved(matching: resolved.command)
                var db = try dependencies.makeChatDB(book)
                guard let target = try loadBoundReactionTarget(db: &db, expected: original) else {
                    throw ReactionTargetDrift()
                }
                try validateReactionSandbox(target: target, db: db, gate: gate)
                try requireReactionAccessibility(dependencies.accessibilityDiagnostic())
                return .requiresMutation
            },
            verify: { resolved, response, context in
                let original = try observation.resolved(matching: resolved.command)
                guard !context.isCancelled else { throw WorkerProtocolError.cancelled }
                guard !context.deadline.expired else { throw WorkerProtocolError.deadlineExpired }
                guard let proof = reactionACKProof(response: response, operation: operation) else { return nil }
                var db = try dependencies.makeChatDB(book)
                guard let fresh = try loadBoundReactionInspect(db: &db, expected: original) else { return nil }
                let verification = ReactionBoundVerification(
                    verification: "observedState: UI selected state and database target identity verified requested \(desiredReactionText(original.reactionKey))",
                    inspect: fresh,
                    verificationSource: MessagesReactionACKDetail.verificationSource,
                    reactionChanged: proof)
                observation.recordObserved(verification)
                return verification.verification
            }
        ))

        switch outcome {
        case .alreadyInDesiredState:
            throw WorkerProtocolError.malformedFrame
        case .observedState(let operationID, let verification):
            guard let target = observation.target(), let verified = observation.observed() else { throw WorkerProtocolError.malformedFrame }
            let data = ReactionMutationResult(action: "reaction-\(operation.rawValue)",
                                              experimental: true,
                                              executed: true,
                                              operation: operation,
                                              operation_id: operationID,
                                              observed_state: "observedState",
                                              verification: verification,
                                              verification_source: verified.verificationSource,
                                              reaction_changed: verified.reactionChanged,
                                              targeting_mode: reactionTargetingMode(target.experimentalUIHandoff),
                                              limitation: reactionTargetingLimitation(target.experimentalUIHandoff),
                                              desired_reaction_key: target.reactionKey,
                                              inspect: verified.inspect)
            try emitWrite(global, ExecutedWrite(data), sandboxActive: gate.sandboxActive) {
                verification
            }
        case .timedOut:
            throw AppleError.upstream("Messages reaction automation timed out; an unresolved pending operation may block later writes until `messages automation status` and `messages automation recover` resolve it")
        case .cancelled:
            throw AppleError.upstream("Messages reaction automation was cancelled; check `messages automation status` before retrying")
        case .verificationFailed:
            throw AppleError.upstream("Messages reaction automation could not verify the requested UI state and database target identity; check `messages automation status` before retrying")
        case .requestNotSent(let value), .spawnOrSetupFailedBeforeRequest(let value),
             .childRefusedOrFailed(let value), .protocolViolation(let value):
            throw reactionStateError(value)
        }
    }
}

private func reactionStateError(_ value: String) -> AppleError {
    if value == "custom-reaction-execution-unsupported" {
        return AppleError.safetyViolation("custom set/replace and implicit custom removal are not supported by this experimental version")
    }
    if value.hasPrefix("accessibility-not-trusted:") {
        return AppleError.permissionDenied(
            "Messages reaction automation requires Accessibility permission before launching the UI worker.",
            status: "accessibility_not_trusted",
            remediation: "Enable Accessibility for apple or the host app shown by macOS in System Settings > Privacy & Security > Accessibility, then retry.")
    }
    return AppleError(type: AppleErrorType.upstream,
                      message: "Messages reaction automation failed: \(value)",
                      exitCode: AppleExit.upstream)
}

struct ReactionInspect: ParsableCommand, ReactionTargetOptions {
    static let configuration = CommandConfiguration(commandName: "inspect",
                                                    abstract: "Inspect outgoing and incoming reactions for an exact message.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Local conversation ROWID from chat.ROWID.") var chatRowid: Int64?
    @Option(name: .long, help: "Conversation GUID from chat.guid.") var chatGuid: String?
    @Option(name: .long, help: "Local message ROWID from message.ROWID.") var messageRowid: Int64?
    @Option(name: .long, help: "Message GUID from message.guid.") var messageGuid: String?
    @Option(name: .long, help: "Native Messages part index to inspect.") var partIndex: Int?
    @Option(name: .long, help: "Maximum reaction rows to inspect (default 512, max 10000).") var rowLimit: Int = 512

    func run() throws { try run(dependencies: .live) }
    func run(dependencies: MessagesCommandDependencies) throws {
        try runGuarded(tool: tool) {
            guard (1...10_000).contains(rowLimit) else {
                throw AppleError.validation("rowLimit must be between 1 and 10000")
            }
            if let partIndex {
                guard partIndex >= 0 else { throw AppleError.validation("partIndex must be >= 0") }
            }
            let chat = try chatSelector()
            let message = try messageSelector()
            var db = try dependencies.makeChatDB(AddressBook())
            let inspect = try db.exactReactionInspect(chat: chat,
                                                       message: message,
                                                       partIndex: partIndex,
                                                       rowLimit: rowLimit)
            try emit(global, inspect) { renderExactReactionInspect(inspect) }
        }
    }
}

private func renderExactReactionInspect(_ result: ChatDB.ExactReactionInspect) -> String {
    let current = result.current_outgoing.key ?? result.current_outgoing.status
    let part = result.target.part_index.map(String.init) ?? "unknown"
    return "reaction status=\(result.status) current=\(current) part=\(part) eligible=\(result.target.mutation_eligible)"
}

struct ReactionSet: ParsableCommand, ReactionWriteOptions {
    static let configuration = CommandConfiguration(commandName: "set",
                                                    abstract: "Set or replace the outgoing reaction on an exact message.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Local conversation ROWID from chat.ROWID.") var chatRowid: Int64?
    @Option(name: .long, help: "Conversation GUID from chat.guid.") var chatGuid: String?
    @Option(name: .long, help: "Local message ROWID from message.ROWID.") var messageRowid: Int64?
    @Option(name: .long, help: "Message GUID from message.guid.") var messageGuid: String?
    @Option(name: .long, help: "Native Messages part index to mutate.") var partIndex: Int?
    @Option(name: .customLong("reaction"), help: "Standard reaction: heart, like, dislike, laugh, emphasize, question.")
    var standardReaction: String?
    @Option(name: .long, help: "Custom emoji reaction. Accepted for preview; execution is refused until AX support is proven.")
    var emoji: String?
    @Flag(name: .customLong("experimental-ui-handoff"), help: "Allow a modal handoff route when the Tapback picker hides the transcript; cannot prove original message continuity after modal, so keep Messages untouched during automation.")
    var experimentalUIHandoff = false

    func run() throws { try run(dependencies: .live) }
    func run(dependencies: MessagesCommandDependencies) throws {
        try runReactionMutation(global: global, dependencies: dependencies, options: self, operation: .set)
    }
}

struct ReactionRemove: ParsableCommand, ReactionWriteOptions {
    static let configuration = CommandConfiguration(commandName: "remove",
                                                    abstract: "Remove an outgoing reaction from an exact message.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Local conversation ROWID from chat.ROWID.") var chatRowid: Int64?
    @Option(name: .long, help: "Conversation GUID from chat.guid.") var chatGuid: String?
    @Option(name: .long, help: "Local message ROWID from message.ROWID.") var messageRowid: Int64?
    @Option(name: .long, help: "Message GUID from message.guid.") var messageGuid: String?
    @Option(name: .long, help: "Native Messages part index to mutate.") var partIndex: Int?
    @Option(name: .customLong("reaction"), help: "Standard reaction to remove: heart, like, dislike, laugh, emphasize, question.")
    var standardReaction: String?
    @Option(name: .long, help: "Custom emoji reaction to remove. Explicit custom emoji removal is experimental; custom set/replace and implicit custom removal are refused.")
    var emoji: String?
    @Flag(name: .customLong("experimental-ui-handoff"), help: "Allow a modal handoff route when the Tapback picker hides the transcript; cannot prove original message continuity after modal, so keep Messages untouched during automation.")
    var experimentalUIHandoff = false

    func run() throws { try run(dependencies: .live) }
    func run(dependencies: MessagesCommandDependencies) throws {
        try runReactionMutation(global: global, dependencies: dependencies, options: self, operation: .remove)
    }
}

struct MessagesAutomationStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status",
                                                    abstract: "Read pending Messages automation state.")
    @OptionGroup var global: GlobalOptions
    func run() throws { try run(dependencies: .live) }
    func run(dependencies: MessagesCommandDependencies) throws {
        try runGuarded(tool: tool) {
            let data = try readReactionStatus(root: dependencies.messagesAutomationStateRoot())
            try emit(global, data) { data.pending == nil ? "No pending Messages automation operation." : "Pending Messages automation operation." }
        }
    }
}

struct MessagesAutomationRecover: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "recover",
                                                    abstract: "Explicitly recover a pending Messages automation operation.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Pending operation id from `messages automation status`.")
    var opID: String
    @Flag(name: .long, help: "Acknowledge possible late effects before clearing pending state.")
    var acknowledgePossibleLateEffects = false

    func run() throws { try run(dependencies: .live) }
    func run(dependencies: MessagesCommandDependencies) throws {
        try runGuarded(tool: tool) {
            guard let id = UUID(uuidString: opID) else { throw AppleError.validation("op-id must be a UUID") }
            let willExecute = try global.willExecute(defaultDryRun: false)
            let data = try recoverReaction(root: dependencies.messagesAutomationStateRoot(),
                                           operationID: id,
                                           acknowledged: acknowledgePossibleLateEffects,
                                           willExecute: willExecute)
            try emit(global, data) {
                data.recovered
                    ? "Recovered pending Messages automation operation \(id.uuidString)."
                    : "[dry-run] would recover pending Messages automation operation \(id.uuidString)."
            }
        }
    }
}

struct MessagesAutomation: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "automation",
        abstract: "Read or recover shared Messages automation state.",
        subcommands: [MessagesAutomationStatus.self, MessagesAutomationRecover.self]
    )
}
