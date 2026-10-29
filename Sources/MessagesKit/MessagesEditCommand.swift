import ArgumentParser
import AppleKit
import Foundation

struct MessagesEdit: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "edit",
        abstract: "Edit an eligible own sent text part and verify persisted content and history.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long) var chatRowid: Int64?
    @Option(name: .long) var chatGuid: String?
    @Option(name: .long) var messageRowid: Int64?
    @Option(name: .long) var messageGuid: String?
    @Option(name: .long, help: "Exact native text part index from messages get.") var partIndex: Int?
    @Option(name: .customLong("replacement-text"), help: "Replacement text for the selected native part.") var text: String
    @Flag(name: .customLong("experimental-ui-handoff"), help: "Allow bounded Messages UI editing.")
    var experimentalUIHandoff = false

    struct Resolved {
        let snapshot: MessagesEditTargetResolver.Snapshot
        let request: MessagesEditRequest
    }

    func run() throws { try run(dependencies: .live, databasePath: ChatDB.defaultPath()) }

    func resolve(databasePath: String, gate: MessagesWriteGuard.Gate, now: Date,
                 deadline: WorkerDeadline = .millisecondsFromNow(5000),
                 isCancelled: @escaping () -> Bool = { false }) throws -> Resolved {
        let chat: ChatDB.ExactChatSelector
        switch (chatRowid, chatGuid) {
        case (.some(let id), nil): chat = .rowid(id)
        case (nil, .some(let guid)): chat = .guid(guid)
        default: throw AppleError.validation("pass exactly one of --chat-rowid or --chat-guid")
        }
        let message: ChatDB.ExactMessageSelector
        switch (messageRowid, messageGuid) {
        case (.some(let id), nil): message = .rowid(id)
        case (nil, .some(let guid)): message = .guid(guid)
        default: throw AppleError.validation("pass exactly one of --message-rowid or --message-guid")
        }
        guard let partIndex, (0...Int(Int32.max)).contains(partIndex) else {
            throw AppleError.validation("pass a nonnegative --part-index within the native range")
        }
        let snapshot: MessagesEditTargetResolver.Snapshot
        do {
            snapshot = try MessagesEditTargetResolver.read(databasePath: databasePath, chat: chat,
                message: message, partIndex: partIndex, sandboxPrefix: gate.sandboxActive ? gate.sandboxPrefix : nil,
                deadline: deadline, isCancelled: isCancelled)
        } catch MessagesEditTargetResolver.Failure.sandboxViolation {
            throw AppleError.safetyViolation("sandboxed edit requires a labeled direct conversation", sandbox: true)
        } catch MessagesEditTargetResolver.Failure.targetNotFound {
            throw AppleError.notFound("edit target was not found")
        } catch MessagesEditTargetResolver.Failure.invalidTarget {
            throw AppleError.validation("edit target must identify a valid own sent native text part")
        } catch {
            throw AppleError.upstream("edit target could not be read and verified within its limits")
        }
        guard MessagesEditEligibility.supportsEditorText(snapshot.partText) else {
            throw AppleError.validation("original text exceeds the editor's 4,096-byte UTF-8 limit")
        }
        guard MessagesEditEligibility.assess(sentDateRaw: snapshot.sentDateRaw, partIndex: partIndex,
            currentText: snapshot.partText, context: snapshot.editContext, now: now) == .eligible else {
            throw AppleError.validation("edit target is expired, at its edit limit, or has unavailable eligibility evidence")
        }
        guard !text.utf8.elementsEqual(snapshot.partText.utf8) else {
            throw AppleError.validation("replacement text is unchanged")
        }
        let request: MessagesEditRequest
        do {
            request = try MessagesEditRequest(snapshot: snapshot, replacement: text,
                sandboxPrefix: gate.sandboxActive ? gate.sandboxPrefix : nil)
        } catch { throw AppleError.validation("replacement or target exceeds the bounded edit payload or is invalid") }
        if gate.sandboxActive {
            guard request.preservesSandbox(snapshot) else {
                throw AppleError.safetyViolation("sandboxed edit must preserve the test label", sandbox: true)
            }
            guard snapshot.participantHandles.count == 1, let participant = snapshot.participantHandles.first,
                  let target = Self.allowedIdentity(participant), gate.allowedRecipients.contains(where: {
                      guard let allowed = Self.allowedIdentity($0) else { return false }
                      return Send.phonesEquivalent(allowed, target)
                  }) else { throw AppleError.safetyViolation("sandboxed edit requires one allowed direct recipient", sandbox: true) }
        }
        return Resolved(snapshot: snapshot, request: request)
    }

    func run(dependencies: MessagesCommandDependencies, databasePath: String,
             now: @escaping () -> Date = Date.init, isCancelled: @escaping () -> Bool = { false }) throws {
        try runGuarded(tool: tool) {
            let gate = try dependencies.resolveGate(global)
            let deadline = WorkerDeadline.millisecondsFromNow(60_000)
            let preview = try resolve(databasePath: databasePath, gate: gate, now: now(),
                deadline: deadline, isCancelled: isCancelled)
            let binding = try MessagesEditBinding(preview.request)
            guard gate.willExecute else {
                try emitWrite(global, EditOutput(preview: preview, executed: false, operationID: nil,
                    verification: "Dry run: eligibility is provisional; no UI worker or journal mutation."), sandboxActive: gate.sandboxActive) {
                    "[dry-run] would edit message \(preview.request.messageRowid) part \(preview.request.nativePartIndex)"
                        + "\nPrevious: \(String(reflecting: preview.snapshot.partText))\nReplacement: \(String(reflecting: preview.request.replacement))"
                }
                return
            }
            guard experimentalUIHandoff else {
                throw AppleError.validation("pass --experimental-ui-handoff to execute an edit")
            }
            let outcome = try dependencies.launchObservedWorker(WorkerObservedAction(
                stateRoot: dependencies.messagesAutomationStateRoot(), deadline: deadline, isCancelled: isCancelled,
                resolveWithContext: { context in
                    let fresh = try resolve(databasePath: databasePath, gate: gate, now: now(),
                        deadline: context.deadline, isCancelled: { context.isCancelled })
                    guard try fresh.request.workerPayloadData() == preview.request.workerPayloadData() else {
                        throw AppleError.validation("edit target changed before journal binding")
                    }
                    return try binding.resolvedAction()
                }, preflight: { _, context in
                    guard !context.isCancelled, !context.deadline.expired else { throw WorkerProtocolError.deadlineExpired }
                    return .requiresMutation
                }, verify: { resolved, response, context in
                    guard !context.isCancelled, !context.deadline.expired,
                          resolved.command.name == binding.command.name, resolved.command.payload == binding.command.payload,
                          response.category == .ack, response.detail == "edit-persisted-verified" else { return nil }
                    // The parent independently reads persisted evidence under the
                    // automation lease; a matching worker ACK alone is insufficient.
                    guard let after = try? MessagesEditTargetResolver.read(databasePath: databasePath,
                        chat: .rowid(preview.request.chatRowid), message: .rowid(preview.request.messageRowid),
                        partIndex: preview.request.nativePartIndex, sandboxPrefix: preview.request.sandboxPrefix,
                        deadline: context.deadline, isCancelled: { context.isCancelled }),
                          !context.isCancelled, !context.deadline.expired,
                          MessagesEditVerification.matches(before: preview.snapshot, after: after, replacement: text) else { return nil }
                    return "Observed exact replacement content and appended native edit history for the bound message part."
                }))
            switch outcome {
            case .observedState(let operationID, let verification):
                try emitWrite(global, EditOutput(preview: preview, executed: true, operationID: operationID,
                    verification: verification), sandboxActive: gate.sandboxActive) { verification }
            case .alreadyInDesiredState:
                throw WorkerProtocolError.malformedFrame
            case .timedOut, .cancelled, .verificationFailed:
                throw AppleError.upstream("Edit was not verified; it may have occurred. Check messages automation status and recover before retrying.")
            case .childRefusedOrFailed(let detail), .protocolViolation(let detail):
                throw AppleError.upstream("Edit was not verified; it may have occurred. Check messages automation status and recover before retrying. Detail: \(detail)")
            case .requestNotSent(let detail), .spawnOrSetupFailedBeforeRequest(let detail):
                throw AppleError.upstream(detail)
            }
        }
    }

    private static func allowedIdentity(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("@") {
            let parts = value.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
                  !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 32 || $0.value == 127 }) else { return nil }
        } else {
            let digits = value.hasPrefix("+") ? value.dropFirst() : value[...]
            guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) || [32, 40, 41, 45, 46].contains($0) }),
                  digits.utf8.contains(where: { (48...57).contains($0) }) else { return nil }
        }
        let normalized = Send.normalizeForAllowlist(value)
        return normalized.isEmpty ? nil : normalized
    }
}

private struct EditOutput: Encodable {
    let action = "messages-edit"
    let experimental = true
    let executed: Bool
    let dry_run: Bool
    let chat_rowid: Int64
    let message_rowid: Int64
    let native_part: Int
    let previous_text: String
    let replacement_text: String
    let operation_id: UUID?
    let verification: String

    init(preview: MessagesEdit.Resolved, executed: Bool, operationID: UUID?, verification: String) {
        self.executed = executed
        dry_run = !executed
        chat_rowid = preview.request.chatRowid
        message_rowid = preview.request.messageRowid
        native_part = preview.request.nativePartIndex
        previous_text = preview.snapshot.partText
        replacement_text = preview.request.replacement
        operation_id = operationID
        self.verification = verification
    }
}
