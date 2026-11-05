import ArgumentParser
import AppleKit
import Foundation

/// Kept unregistered until the native creation adapter and registry qualify.
struct MessagesConversationCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create",
        abstract: "Send initial iMessage text to exact recipients and report the observed conversation.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .customLong("recipient"), help: "Recipient address or contact name; repeat for each participant.")
    var recipients: [String] = []
    @Option(name: .long, help: "Required initial message text; creating an empty draft is not supported.")
    var message: String
    @Option(name: .long, help: "Explicit service: imessage. No SMS fallback.") var service: String
    @Flag(name: .customLong("experimental-ui-handoff"), help: "Allow one bounded native initial send.")
    var experimentalUIHandoff = false

    func run() throws {
        try run(dependencies: .live, databasePath: ChatDB.defaultPath(), loadContacts: Self.loadRawContacts)
    }

    func run(dependencies: MessagesCommandDependencies, databasePath: String,
             loadContacts: @escaping (WorkerObservedContext) throws -> [MessagesConversationRawContacts.Record],
             isCancelled: @escaping () -> Bool = { false }) throws {
        try runGuarded(tool: tool) {
            let gate = try dependencies.resolveGate(global)
            let deadline = WorkerDeadline.millisecondsFromNow(60_000)
            guard gate.willExecute else {
                do {
                    let context = WorkerObservedContext(deadline: deadline, isCancelled: isCancelled)
                    let result = try MessagesConversationPlan.build(inputs: recipients, message: message,
                        service: service, gate: gate, deadline: deadline, isCancelled: isCancelled,
                        loadContacts: { try loadContacts(context) })
                    switch result {
                    case .unresolved(let values): try emitUnresolved(values, gate: gate)
                    case .ready(let plan):
                        let preview = try MessagesConversationPreview.read(databasePath: databasePath, plan: plan,
                            deadline: deadline, isCancelled: isCancelled)
                        try emitWrite(global, PreviewOutput(preview: preview), sandboxActive: gate.sandboxActive) {
                            Self.previewText(preview)
                        }
                    }
                } catch { throw Self.planningError(error) }
                return
            }
            guard experimentalUIHandoff else {
                throw AppleError.validation("pass --experimental-ui-handoff to execute an initial send")
            }
            // No authoritative contact or database read happens before the
            // launcher's lease and pending-operation gate call resolveWithContext.
            let session = MessagesConversationExecution(inputs: recipients, message: message, service: service,
                gate: gate, databasePath: databasePath, stateRoot: dependencies.messagesAutomationStateRoot(),
                deadline: deadline, isCancelled: isCancelled, loadContacts: loadContacts)
            let outcome: WorkerObservedOutcome
            do { outcome = try dependencies.launchObservedWorker(session.action()) }
            catch {
                // Unknown launcher failures cannot establish whether a send occurred.
                throw AppleError.upstream(Self.uncertainMessage)
            }
            if !session.unresolvedRecipients.isEmpty {
                guard case .requestNotSent = outcome else { throw AppleError.upstream(Self.uncertainMessage) }
                // The session cannot bind or launch a mutation for this result.
                try emitUnresolved(session.unresolvedRecipients, gate: gate)
                return
            }
            switch outcome {
            case .observedState(let operationID, let verification):
                guard let evidence = session.verifiedEvidence else {
                    throw AppleError.upstream(Self.uncertainMessage)
                }
                try emitWrite(global, SuccessOutput(evidence: evidence, operationID: operationID, verification: verification),
                              sandboxActive: gate.sandboxActive) {
                    "Observed sent message \(evidence.messageRowid) in conversation \(evidence.conversation.rowid). Creation attribution is unproven."
                }
            case .requestNotSent, .spawnOrSetupFailedBeforeRequest:
                if let failure = session.validationFailure { throw Self.planningError(failure) }
                throw AppleError.upstream("Initial send was not handed off. Check recipient inputs and messages automation status before retrying.")
            case .alreadyInDesiredState, .timedOut, .cancelled, .verificationFailed,
                 .childRefusedOrFailed, .protocolViolation:
                throw AppleError.upstream(Self.uncertainMessage)
            }
        }
    }

    private static let uncertainMessage = "Initial send was not verified; it may have occurred. Check messages automation status and recover any pending operation before retrying."

    private static func loadRawContacts(_ context: WorkerObservedContext) throws -> [MessagesConversationRawContacts.Record] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AddressBook", isDirectory: true).path
        let paths = try MessagesConversationContactSources.discover(addressBookRoot: root,
            deadline: context.deadline, isCancelled: { context.isCancelled })
        return try MessagesConversationRawContacts.read(paths: paths, deadline: context.deadline,
                                                        isCancelled: { context.isCancelled })
    }

    private static func planningError(_ error: any Error) -> AppleError {
        switch MessagesConversationExecution.ValidationFailure.classify(error) {
        case .sandboxViolation:
            return .safetyViolation("sandboxed creation requires labeled text and one allowed recipient", sandbox: true)
        case .invalidInput:
            return .validation("creation requires 1–32 distinct valid recipients, nonblank text within 2,048 UTF-8 bytes, and --service imessage")
        case .invalidPayload:
            return .validation("creation request is invalid or exceeds the combined 4,096-byte encoded payload limit; shorten the message or reduce recipient data")
        case nil:
            return .upstream("conversation preview could not be read and verified within its limits")
        }
    }

    private static func previewText(_ preview: MessagesConversationPreview.Payload) -> String {
        var lines = ["[dry-run] Initial iMessage send required.",
            "Service: \(preview.service)",
            "Recipients: " + preview.recipients.map { String(reflecting: $0) }.joined(separator: ", "),
            "Initial text: " + String(reflecting: preview.initial_message),
            "Existing DM: \(preview.existing_dm.status)"]
        if let rowid = preview.existing_dm.chat_rowid, let guid = preview.existing_dm.chat_guid {
            lines.append("Conversation ROWID: \(rowid); GUID: " + String(reflecting: guid))
        }
        lines.append("Advisory preview; execution resolves again under the automation lease.")
        return lines.joined(separator: "\n")
    }

    private func emitUnresolved(_ values: [MessagesConversationPlan.UnresolvedRecipient], gate: MessagesWriteGuard.Gate) throws {
        let payload = UnresolvedOutput(dry_run: !gate.willExecute, unresolved_recipients: values.map(Unresolved.init))
        try emitWrite(global, payload, sandboxActive: gate.sandboxActive) {
            payload.unresolved_recipients.map { value in
                "Recipient \(value.index + 1): \(value.reason). " + value.candidates.map(\.address).joined(separator: ", ")
            }.joined(separator: "\n") + "\nNo send. Re-run with explicit recipient addresses."
        }
    }

    private struct PreviewOutput: Encodable {
        let action = "messages-conversations-create"
        let experimental = true
        let executed = false
        let dry_run = true
        let preview: MessagesConversationPreview.Payload
    }
    private struct SuccessOutput: Encodable {
        let action = "messages-conversations-create"
        let experimental = true
        let executed = true
        let dry_run = false
        let chat_rowid: Int64
        let chat_guid: String
        let message_rowid: Int64
        let message_guid: String
        let conversation_observation: String
        let creation_attribution: String
        let operation_id: UUID
        let verification: String

        init(evidence: MessagesConversationVerification.Evidence, operationID: UUID, verification: String) {
            chat_rowid = evidence.conversation.rowid; chat_guid = evidence.conversation.guid
            message_rowid = evidence.messageRowid; message_guid = evidence.messageGUID
            conversation_observation = evidence.observation.rawValue
            creation_attribution = evidence.creationAttribution; operation_id = operationID
            self.verification = verification
        }
    }
    private struct UnresolvedOutput: Encodable {
        let action = "messages-conversations-create"
        let executed = false
        let dry_run: Bool
        let unresolved_recipients: [Unresolved]
    }
    private struct Unresolved: Encodable {
        struct Candidate: Encodable {
            let address: String
            let display_name: String?
            let score: Double
        }
        let index: Int
        let reason: String
        let candidates: [Candidate]
        init(_ value: MessagesConversationPlan.UnresolvedRecipient) {
            index = value.index
            switch value.reason {
            case .notFound: reason = "not_found"; candidates = []
            case .ambiguous(let matches):
                reason = "ambiguous"
                candidates = matches.map { Candidate(address: $0.address.canonical, display_name: $0.displayName, score: $0.score) }
            }
        }
    }
}
