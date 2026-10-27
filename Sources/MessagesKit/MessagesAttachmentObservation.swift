import AppleKit
import Foundation

/// One observation attempt. Run in the supervised worker because cooperative
/// cancellation cannot preempt an individual database or filesystem syscall.
struct MessagesAttachmentObservation {
    enum Failure: Error, Equatable { case deadline, cancelled, incompleteMembership, membershipDrift }
    struct Target: Sendable {
        let chatRowid: Int64
        let chatGUID: String
        let messageRowid: Int64
        let messageGUID: String
    }
    struct Result: Sendable {
        let membership: MessagesAttachmentMembership
        let outcome: MessagesAttachmentRetrievalState.Outcome
        let selectedOutcome: MessagesAttachmentRetrievalState.Outcome?

        init(membership: MessagesAttachmentMembership, outcome: MessagesAttachmentRetrievalState.Outcome,
             selectedOutcome: MessagesAttachmentRetrievalState.Outcome? = nil) {
            self.membership = membership
            self.outcome = outcome
            self.selectedOutcome = selectedOutcome
        }

        var pressOutcome: MessagesAttachmentRetrievalState.Outcome {
            // Uncertain membership must never authorize an action, even when
            // the selected member alone appears retrievable.
            if outcome == .failed || outcome == .unavailable { return outcome }
            return selectedOutcome ?? .unavailable
        }
    }

    static func read(databasePath: String, homeDirectory: String, target: Target,
                     expectedMembership: MessagesAttachmentMembership? = nil, selectedAttachmentGUID: String? = nil,
                     deadline: WorkerDeadline, isCancelled: @escaping () -> Bool = { false }) throws -> Result {
        func checkpoint() throws {
            if isCancelled() { throw Failure.cancelled }
            if deadline.expired { throw Failure.deadline }
        }
        try checkpoint()
        let timeout = min(60, Double(deadline.remainingNanoseconds) / 1_000_000_000)
        guard timeout > 0 else { throw Failure.deadline }
        let items = try SQLiteReader.withBoundedReadTransaction(path: databasePath,
            limits: .init(timeout: timeout, rows: 4096, bytes: 16 * 1024 * 1024, valueBytes: 65536),
            isCancelled: { isCancelled() || deadline.expired }) { scope in
            try MessagesAttachmentTargetSnapshot.read(in: scope, chatRowid: target.chatRowid,
                chatGUID: target.chatGUID, messageRowid: target.messageRowid, messageGUID: target.messageGUID)
        }
        return try evaluate(items: items, homeDirectory: homeDirectory,
            expectedMembership: expectedMembership, selectedAttachmentGUID: selectedAttachmentGUID,
            deadline: deadline, isCancelled: isCancelled)
    }

    static func evaluate(items: [MessagesAttachmentSnapshot.Item], homeDirectory: String,
                         expectedMembership: MessagesAttachmentMembership? = nil, selectedAttachmentGUID: String? = nil,
                         deadline: WorkerDeadline, isCancelled: @escaping () -> Bool = { false }) throws -> Result {
        func checkpoint() throws {
            if isCancelled() { throw Failure.cancelled }
            if deadline.expired { throw Failure.deadline }
        }
        try checkpoint()
        guard let membership = MessagesAttachmentMembership(items.map(\.identity)) else { throw Failure.incompleteMembership }
        if let expectedMembership, membership != expectedMembership { throw Failure.membershipDrift }
        if let selectedAttachmentGUID, !items.contains(where: { $0.identity.guid == Data(selectedAttachmentGUID.utf8) }) {
            throw Failure.membershipDrift
        }
        // Release the SQLite transaction before filesystem work; the result
        // describes the captured database state and subsequent instant file checks.
        let inspector = MessagesAttachmentFileInspection(homeDirectory: homeDirectory)
        let observations = try items.map { item in
            try checkpoint()
            return MessagesAttachmentRetrievalState.Observation(identity: item.identity, transfer: item.transfer,
                file: try inspector.inspect(filename: item.filename, checkpoint: checkpoint))
        }
        try checkpoint()
        let selected = selectedAttachmentGUID.flatMap { guid in
            observations.first { $0.identity.guid == Data(guid.utf8) }
        }
        let selectedOutcome = selected.map {
            MessagesAttachmentRetrievalState.evaluate(expected: [$0.identity], observed: [$0], completeJoin: true)
        }
        return Result(membership: membership, outcome: MessagesAttachmentRetrievalState.evaluate(
            expected: items.map(\.identity), observed: observations, completeJoin: true), selectedOutcome: selectedOutcome)
    }
}
