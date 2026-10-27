import ArgumentParser
import AppleKit
import Foundation

struct MessagesAttachment: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "attachment",
        abstract: "Retrieve attachments from an exact Messages target.", subcommands: [MessagesAttachmentRetrieve.self])
    @OptionGroup var global: GlobalOptions
    func run() throws {
        try runGuarded(tool: tool) { throw AppleError.validation("specify an attachment subcommand: retrieve") }
    }
}

struct MessagesAttachmentRetrieve: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "retrieve",
        abstract: "Request attachment loading through Messages and verify local availability.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long) var chatRowid: Int64?
    @Option(name: .long) var chatGuid: String?
    @Option(name: .long) var messageRowid: Int64?
    @Option(name: .long) var messageGuid: String?
    @Option(name: .long, help: "Exact native attachment part index from messages get.") var partIndex: Int?
    @Flag(name: .customLong("experimental-ui-handoff"), help: "Allow bounded Messages UI attachment loading.")
    var experimentalUIHandoff = false

    func run() throws { try run(dependencies: .live, databasePath: ChatDB.defaultPath()) }

    func resolve(dependencies: MessagesCommandDependencies, databasePath: String,
                 gate: MessagesWriteGuard.Gate, deadline: WorkerDeadline = .millisecondsFromNow(5000),
                 isCancelled: @escaping () -> Bool = { false }) throws -> MessagesAttachmentRetrievalRequest {
        let chat: ChatDB.ExactChatSelector
        switch (chatRowid, chatGuid) {
        case (.some(let id), nil): chat = .rowid(id)
        case (nil, .some(let guid)): chat = .guid(guid)
        default: throw AppleError.validation("pass exactly one of --chat-rowid or --chat-guid")
        }
        let selected: ChatDB.ExactMessageSelector
        switch (messageRowid, messageGuid) {
        case (.some(let id), nil): selected = .rowid(id)
        case (nil, .some(let guid)): selected = .guid(guid)
        default: throw AppleError.validation("pass exactly one of --message-rowid or --message-guid")
        }
        guard let partIndex, partIndex >= 0 else { throw AppleError.validation("pass a nonnegative --part-index") }
        let capture: MessagesAttachmentTargetResolver.Capture
        do {
            capture = try MessagesAttachmentTargetResolver.read(databasePath: databasePath, chat: chat,
                message: selected, partIndex: partIndex, sandboxPrefix: gate.sandboxActive ? gate.sandboxPrefix : nil,
                deadline: deadline, isCancelled: isCancelled)
        } catch MessagesAttachmentTargetResolver.Failure.sandboxViolation {
            throw AppleError.safetyViolation("sandboxed attachment target requires a labeled direct conversation", sandbox: true)
        } catch MessagesAttachmentTargetResolver.Failure.targetNotFound {
            throw AppleError.notFound("attachment target was not found")
        } catch MessagesAttachmentTargetResolver.Failure.invalidTarget {
            throw AppleError.validation("attachment target must identify a valid native attachment part")
        } catch MessagesAttachmentTargetResolver.Failure.unsupportedSchema {
            throw AppleError.upstream("attachment target schema is unsupported")
        } catch is MessagesAttachmentTargetSnapshot.Failure {
            throw AppleError.upstream("attachment target identity or membership could not be verified")
        } catch is MessagesAttachmentSnapshot.Failure {
            throw AppleError.upstream("attachment membership could not be verified")
        } catch is MessagesAttachmentRetrievalRequest.Failure {
            throw AppleError.validation("attachment target cannot be represented by a bounded retrieval request")
        } catch is SQLiteReadTransaction.Failure {
            throw AppleError.upstream("attachment target could not be read within its limits")
        } catch is SQLiteReader.DBError {
            throw AppleError.upstream("attachment target database could not be read")
        } catch MessagesAXNavigationError.deadlineExpired {
            throw AppleError.upstream("attachment target resolution deadline expired")
        } catch WorkerProtocolError.cancelled {
            throw AppleError.upstream("attachment target resolution was cancelled")
        }
        if gate.sandboxActive {
            guard let participant = capture.request.participantHandles.first,
                  capture.request.participantHandles.count == 1,
                  gate.allowedRecipients.contains(where: {
                      guard let allowed = Self.allowedIdentity($0), let target = Self.allowedIdentity(participant) else { return false }
                      return Send.phonesEquivalent(allowed, target)
                  }) else { throw AppleError.safetyViolation("sandboxed attachment target requires one allowed direct recipient", sandbox: true) }
        }
        return capture.request
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

    func run(dependencies: MessagesCommandDependencies, databasePath: String,
             isCancelled: @escaping () -> Bool = { false }) throws {
        try runGuarded(tool: tool) {
            let gate = try dependencies.resolveGate(global)
            let deadline = WorkerDeadline.millisecondsFromNow(60_000)
            let preview = try resolve(dependencies: dependencies, databasePath: databasePath, gate: gate,
                                      deadline: deadline, isCancelled: isCancelled)
            let binding = try MessagesAttachmentRetrievalBinding(preview)
            guard gate.willExecute else {
                try emitWrite(global, AttachmentRetrievalOutput(request: preview, executed: false,
                    operationID: nil, verification: "Dry run: no UI worker or journal mutation."), sandboxActive: gate.sandboxActive) {
                    "[dry-run] would retrieve attachments for message \(preview.messageRowid)"
                }
                return
            }
            guard experimentalUIHandoff else {
                throw AppleError.validation("pass --experimental-ui-handoff to execute attachment retrieval")
            }
            let outcome = try dependencies.launchObservedWorker(WorkerObservedAction(
                stateRoot: dependencies.messagesAutomationStateRoot(), deadline: deadline, isCancelled: isCancelled,
                resolveWithContext: { context in
                    let fresh = try resolve(dependencies: dependencies, databasePath: databasePath, gate: gate,
                                            deadline: context.deadline, isCancelled: { context.isCancelled })
                    guard try fresh.workerPayloadData() == preview.workerPayloadData() else {
                        throw AppleError.validation("attachment target changed before journal binding")
                    }
                    return try binding.resolvedAction()
                }, preflight: { _, context in
                    guard !context.isCancelled, !context.deadline.expired else { throw WorkerProtocolError.deadlineExpired }
                    // Even an already-downloaded target passes the pending-operation
                    // gate and supervised worker verification; no parent-side no-op.
                    return .requiresMutation
                }, verify: { resolved, response, context in
                    guard !context.isCancelled, !context.deadline.expired,
                          resolved.command.name == binding.command.name,
                          resolved.command.payload == binding.command.payload,
                          response.category == .ack,
                          response.detail == "attachment-retrieval-downloaded-verified" ||
                          response.detail == "attachment-retrieval-already-downloaded-verified" else { return nil }
                    return "Observed finished native transfer and confined local readability for the bound attachment membership; no causal completion claim."
                }))
            switch outcome {
            case .observedState(let operationID, let verification):
                try emitWrite(global, AttachmentRetrievalOutput(request: preview, executed: true,
                    operationID: operationID, verification: verification), sandboxActive: gate.sandboxActive) { verification }
            case .alreadyInDesiredState:
                throw WorkerProtocolError.malformedFrame
            case .timedOut, .cancelled, .verificationFailed:
                throw AppleError.upstream("Attachment retrieval was not verified; loading may have occurred. Check messages automation status and recover before retrying.")
            case .requestNotSent(let detail), .spawnOrSetupFailedBeforeRequest(let detail),
                 .childRefusedOrFailed(let detail), .protocolViolation(let detail):
                throw AppleError.upstream(detail)
            }
        }
    }
}

private struct AttachmentRetrievalOutput: Encodable {
    let action = "messages-attachment-retrieve"
    let experimental = true
    let executed: Bool
    let dry_run: Bool
    let chat_rowid: Int64
    let message_rowid: Int64
    let native_part: Int
    let attachment_count: Int
    let operation_id: UUID?
    let verification: String

    init(request: MessagesAttachmentRetrievalRequest, executed: Bool, operationID: UUID?, verification: String) {
        self.executed = executed
        dry_run = !executed
        chat_rowid = request.chatRowid
        message_rowid = request.messageRowid
        native_part = request.nativePartIndex
        attachment_count = request.membershipCount
        operation_id = operationID
        self.verification = verification
    }
}
