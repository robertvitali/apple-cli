import AppleKit
import Foundation

/// Captures necessary pre-action evidence in one pinned, bounded transaction.
/// Native retraction semantics, UI target correlation, sandbox policy and action
/// availability remain separate requirements; this snapshot permits no action.
enum MessagesUndoSendTargetSnapshot {
    enum Failure: Error { case ineligible }

    struct Snapshot: Sendable {
        let part: MessagesUndoSendPart.Snapshot
        let attachments: [MessagesAttachmentRetrievalState.Identity]
        let selectedAttachment: MessagesAttachmentRetrievalState.Identity?
    }

    static func read(databasePath: String, chat: ChatDB.ExactChatSelector,
                     message: ChatDB.ExactMessageSelector, partIndex: Int,
                     deadline: WorkerDeadline, now: () -> Date = { Date() },
                     isCancelled: @escaping () -> Bool = { false }) throws -> Snapshot {
        if isCancelled() { throw WorkerProtocolError.cancelled }
        try checkMessagesAXDeadline(deadline)
        return try SQLiteReader.withBoundedReadTransaction(path: databasePath,
            limits: .init(timeout: min(5, Double(deadline.remainingNanoseconds) / 1_000_000_000),
                          rows: 4096, bytes: 16_777_216, valueBytes: 1_048_576),
            isCancelled: { isCancelled() || deadline.expired }) { scope in
            try read(in: scope, chat: chat, message: message, partIndex: partIndex,
                     deadline: deadline, now: now, isCancelled: isCancelled)
        }
    }

    static func read(in scope: SQLiteReadTransaction, chat: ChatDB.ExactChatSelector,
                     message: ChatDB.ExactMessageSelector, partIndex: Int,
                     deadline: WorkerDeadline, now: () -> Date = { Date() },
                     isCancelled: () -> Bool = { false }) throws -> Snapshot {
        func checkpoint() throws {
            if isCancelled() { throw WorkerProtocolError.cancelled }
            try checkMessagesAXDeadline(deadline)
        }
        try checkpoint()
        let observation = try MessagesUndoSendObservation.read(in: scope, chat: chat, message: message)
        let part = try MessagesUndoSendPart.resolve(observation, partIndex: partIndex,
                                                  deadline: deadline, isCancelled: isCancelled)
        let members = try MessagesAttachmentSnapshot.read(in: scope,
            messageRowid: observation.identity.messageRowid).map(\.identity).sorted { $0.rowid < $1.rowid }
        let selected = try MessagesUndoSendAttachmentBinding.bind(nativeParts: part.nativeParts,
            selectedIndex: partIndex, members: members)
        try checkpoint()
        // Obtain the time after database reads and decoding. Navigation must
        // still acquire a fresh snapshot and repeat the check before invocation.
        guard MessagesUndoSendPreconditions.assess(observation, now: now()) == .satisfied else {
            throw Failure.ineligible
        }
        try checkpoint()
        return Snapshot(part: part, attachments: members, selectedAttachment: selected)
    }
}
