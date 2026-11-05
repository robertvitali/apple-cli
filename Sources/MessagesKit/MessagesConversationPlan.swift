import AppleKit
import Foundation

/// Read-only request planning. No native adapter, journal or mutation dependency is
/// accepted here. Execution must rebuild under the lease rather than trust preview.
enum MessagesConversationPlan {
    enum Failure: Error {
        case invalidInitialText, unsupportedService, invalidRecipientCount, duplicateRecipient
        case sandboxGroupUnavailable, sandboxLabelRequired, recipientNotAllowed, invalidPolicy
    }

    struct Recipient: Sendable {
        let index: Int
        let input: String
        let candidate: MessagesConversationRecipientResolver.Candidate
    }

    struct Plan: Sendable {
        let recipients: [Recipient]
        let initialText: String
        let service: String
        let gate: MessagesWriteGuard.Gate
        var isGroup: Bool { recipients.count > 1 }

        fileprivate init(recipients: [Recipient], initialText: String, gate: MessagesWriteGuard.Gate) {
            self.recipients = recipients
            self.initialText = initialText
            self.service = "iMessage"
            self.gate = gate
        }
    }

    enum Reason: Sendable { case ambiguous([MessagesConversationRecipientResolver.Candidate]), notFound }
    struct UnresolvedRecipient: Sendable { let index: Int; let input: String; let reason: Reason }
    enum Result: Sendable { case ready(Plan), unresolved([UnresolvedRecipient]) }

    static func build(inputs: [String], message: String, service: String?, gate: MessagesWriteGuard.Gate,
                      deadline: WorkerDeadline, isCancelled: @escaping () -> Bool = { false },
                      loadContacts: () throws -> [MessagesConversationRawContacts.Record]) throws -> Result {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        func checkpoint() throws {
            if isCancelled() { throw WorkerProtocolError.cancelled }
            if deadline.expired || ContinuousClock.now >= end { throw WorkerProtocolError.deadlineExpired }
        }
        try checkpoint()
        guard (1...32).contains(inputs.count) else { throw Failure.invalidRecipientCount }
        guard message.utf8.prefix(2049).count <= 2048, !message.utf8.contains(0),
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.invalidInitialText
        }
        guard service == "imessage" else { throw Failure.unsupportedService }
        if gate.sandboxActive {
            guard !gate.sandboxPrefix.isEmpty, gate.sandboxPrefix.utf8.prefix(513).count <= 512,
                  gate.allowedRecipients.count <= 4096,
                  gate.allowedRecipients.allSatisfy({ $0.utf8.prefix(513).count <= 512 }) else {
                throw Failure.invalidPolicy
            }
            guard inputs.count == 1 else { throw Failure.sandboxGroupUnavailable }
            guard message.hasPrefix(gate.sandboxPrefix) else { throw Failure.sandboxLabelRequired }
        }
        var capturedContacts: [MessagesConversationRawContacts.Record]?
        func contacts() throws -> [MessagesConversationRawContacts.Record] {
            if let capturedContacts { return capturedContacts }
            let complete = try loadContacts()
            try checkpoint()
            capturedContacts = complete
            return complete
        }
        var recipients: [Recipient] = []
        var unresolved: [UnresolvedRecipient] = []
        var seen = Set<MessagesConversationAddress>()
        for (index, input) in inputs.enumerated() {
            try checkpoint()
            let result = try MessagesConversationRecipientResolver.resolve(input, deadline: deadline,
                isCancelled: isCancelled, loadContacts: contacts)
            try checkpoint()
            switch result {
            case .resolved(let candidate):
                guard seen.insert(candidate.address).inserted else { throw Failure.duplicateRecipient }
                do {
                    try Send.assertAllowedRecipient(candidate.address.canonical,
                        groupChat: inputs.count > 1, sandboxActive: gate.sandboxActive,
                        allowedRecipients: gate.allowedRecipients)
                } catch { throw Failure.recipientNotAllowed }
                recipients.append(Recipient(index: index, input: input, candidate: candidate))
            case .ambiguous(let candidates):
                unresolved.append(UnresolvedRecipient(index: index, input: input, reason: .ambiguous(candidates)))
            case .notFound:
                unresolved.append(UnresolvedRecipient(index: index, input: input, reason: .notFound))
            }
        }
        try checkpoint()
        guard unresolved.isEmpty else { return .unresolved(unresolved) }
        return .ready(Plan(recipients: recipients, initialText: message, gate: gate))
    }
}
