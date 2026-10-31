import AppleKit
import Foundation

/// Captures post-action observations without requiring a surviving native body.
/// Neither absent body/attachments nor raw markers establish retraction here.
/// A separately qualified transition verifier must interpret this evidence.
enum MessagesUndoSendPostSnapshot {
    struct Snapshot: Sendable {
        let observation: MessagesUndoSendObservation.Snapshot
        let attachments: [MessagesAttachmentRetrievalState.Identity]
    }

    static func read(databasePath: String, chat: ChatDB.ExactChatSelector,
                     message: ChatDB.ExactMessageSelector, deadline: WorkerDeadline,
                     isCancelled: @escaping () -> Bool = { false }) throws -> Snapshot {
        if isCancelled() { throw WorkerProtocolError.cancelled }
        try checkMessagesAXDeadline(deadline)
        return try SQLiteReader.withBoundedReadTransaction(path: databasePath,
            limits: .init(timeout: min(5, Double(deadline.remainingNanoseconds) / 1_000_000_000),
                          rows: 4096, bytes: 16_777_216, valueBytes: 1_048_576),
            isCancelled: { isCancelled() || deadline.expired }) { scope in
            try read(in: scope, chat: chat, message: message, deadline: deadline,
                     isCancelled: isCancelled)
        }
    }

    static func read(in scope: SQLiteReadTransaction, chat: ChatDB.ExactChatSelector,
                     message: ChatDB.ExactMessageSelector, deadline: WorkerDeadline,
                     isCancelled: () -> Bool = { false }) throws -> Snapshot {
        if isCancelled() { throw WorkerProtocolError.cancelled }
        try checkMessagesAXDeadline(deadline)
        let observation = try MessagesUndoSendObservation.read(in: scope, chat: chat, message: message)
        let attachments = try MessagesAttachmentSnapshot.read(in: scope,
            messageRowid: observation.identity.messageRowid).map(\.identity).sorted { $0.rowid < $1.rowid }
        if isCancelled() { throw WorkerProtocolError.cancelled }
        try checkMessagesAXDeadline(deadline)
        return Snapshot(observation: observation, attachments: attachments)
    }
}
