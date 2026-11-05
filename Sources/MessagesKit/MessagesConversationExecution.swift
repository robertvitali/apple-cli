import AppleKit

/// One synchronous parent session. WorkerLauncher owns the lease and pending gate;
/// constructing this object performs no contact, database, journal or UI work.
/// Callbacks are used only by that serialized observed-action invocation.
final class MessagesConversationExecution {
    enum Failure: Error { case unresolvedRecipients, preflightUnavailable, previewOnly, repeatedResolution, invalidBinding }
    /// Closed, value-free classifications survive launcher refusal without
    /// retaining dependency diagnostics, recipient values or filesystem paths.
    enum ValidationFailure: Error {
        case invalidInput, sandboxViolation, invalidPayload

        static func classify(_ error: any Error) -> Self? {
            if let failure = error as? Self { return failure }
            switch error {
            case MessagesConversationPlan.Failure.sandboxGroupUnavailable,
                 MessagesConversationPlan.Failure.sandboxLabelRequired,
                 MessagesConversationPlan.Failure.recipientNotAllowed,
                 MessagesConversationPlan.Failure.invalidPolicy:
                return .sandboxViolation
            case is MessagesConversationRequest.Failure:
                return .invalidPayload
            case is MessagesConversationPlan.Failure, is MessagesConversationRecipientResolver.Failure,
                 is MessagesConversationAddress.ParseError:
                return .invalidInput
            default: return nil
            }
        }
    }

    private struct Resolution {
        let baseline: MessagesConversationBaseline.Snapshot
        let request: MessagesConversationRequest
        let action: WorkerResolvedAction
    }

    private let inputs: [String]
    private let message: String
    private let service: String?
    private let gate: MessagesWriteGuard.Gate
    private let databasePath: String
    private let stateRoot: String
    private let deadline: WorkerDeadline
    private let isCancelled: () -> Bool
    private let loadContacts: (WorkerObservedContext) throws -> [MessagesConversationRawContacts.Record]
    private var attemptedResolution = false
    private var resolution: Resolution?
    private(set) var verifiedEvidence: MessagesConversationVerification.Evidence?
    private(set) var unresolvedRecipients: [MessagesConversationPlan.UnresolvedRecipient] = []
    private(set) var validationFailure: ValidationFailure?

    init(inputs: [String], message: String, service: String?, gate: MessagesWriteGuard.Gate,
         databasePath: String, stateRoot: String, deadline: WorkerDeadline,
         isCancelled: @escaping () -> Bool = { false },
         loadContacts: @escaping (WorkerObservedContext) throws -> [MessagesConversationRawContacts.Record]) {
        self.inputs = inputs; self.message = message; self.service = service; self.gate = gate
        self.databasePath = databasePath; self.stateRoot = stateRoot; self.deadline = deadline
        self.isCancelled = isCancelled; self.loadContacts = loadContacts
    }

    func action() -> WorkerObservedAction {
        WorkerObservedAction(stateRoot: stateRoot, deadline: deadline, isCancelled: isCancelled,
            resolveWithContext: { try self.resolve($0) }, preflight: { candidate, context in
                try self.checkpoint(context)
                guard self.matches(candidate) else { throw Failure.invalidBinding }
                // Creation requires the initial send, even for an existing DM.
                return .requiresMutation
            }, verify: { candidate, response, context in
                self.verifiedEvidence = nil
                guard self.matches(candidate), let resolved = self.resolution,
                      response.category == .ack, response.detail == "conversation-create-persisted-verified" else { return nil }
                do {
                    try self.checkpoint(context)
                    guard let evidence = try MessagesConversationVerification.read(databasePath: self.databasePath,
                        baseline: resolved.baseline, initialText: resolved.request.initialText,
                        deadline: self.boundedDeadline(context),
                        isCancelled: { self.isCancelled() || context.isCancelled }) else { return nil }
                    try self.checkpoint(context)
                    self.verifiedEvidence = evidence
                    return "Observed one exact sent iMessage with verified conversation membership; creation attribution remains unproven."
                } catch { return nil }
            })
    }

    private func resolve(_ context: WorkerObservedContext) throws -> WorkerResolvedAction {
        guard !attemptedResolution else { throw Failure.repeatedResolution }
        attemptedResolution = true
        do {
            try checkpoint(context)
            guard gate.willExecute else { throw Failure.previewOnly }
            let result = try MessagesConversationPlan.build(inputs: inputs, message: message, service: service, gate: gate,
                deadline: boundedDeadline(context), isCancelled: { self.isCancelled() || context.isCancelled },
                loadContacts: { try self.loadContacts(context) })
            let plan: MessagesConversationPlan.Plan
            switch result {
            case .ready(let value): plan = value
            case .unresolved(let values):
                unresolvedRecipients = values
                throw Failure.unresolvedRecipients
            }
            try checkpoint(context)
            let baseline = try MessagesConversationBaseline.read(databasePath: databasePath,
                recipients: plan.recipients.map(\.candidate.address), deadline: boundedDeadline(context),
                isCancelled: { self.isCancelled() || context.isCancelled })
            try checkpoint(context)
            let request = try MessagesConversationRequest(plan: plan, baseline: baseline)
            let action = try MessagesConversationBinding(request).resolvedAction()
            try checkpoint(context)
            resolution = Resolution(baseline: baseline, request: request, action: action)
            return action
        } catch WorkerProtocolError.cancelled { throw WorkerProtocolError.cancelled }
        catch WorkerProtocolError.deadlineExpired { throw WorkerProtocolError.deadlineExpired }
        catch let failure as Failure { throw failure }
        catch {
            if let failure = ValidationFailure.classify(error) {
                validationFailure = failure
                throw failure
            }
            throw Failure.preflightUnavailable
        }
    }

    private func matches(_ candidate: WorkerResolvedAction) -> Bool {
        guard let resolution else { return false }
        return candidate.command == resolution.action.command && candidate.journalRequest == resolution.action.journalRequest
    }

    private func checkpoint(_ context: WorkerObservedContext) throws {
        if isCancelled() || context.isCancelled { throw WorkerProtocolError.cancelled }
        if deadline.expired || context.deadline.expired { throw WorkerProtocolError.deadlineExpired }
    }

    private func boundedDeadline(_ context: WorkerObservedContext) -> WorkerDeadline {
        deadline.remainingNanoseconds < context.deadline.remainingNanoseconds ? deadline : context.deadline
    }
}
