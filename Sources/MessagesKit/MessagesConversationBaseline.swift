import AppleKit

/// Complete baseline only. A returned snapshot is not proof that this invocation
/// will create a new conversation, or that native composition will reuse a group.
enum MessagesConversationBaseline {
    struct Snapshot: Sendable {
        let maximumChatRowid: Int64
        let maximumMessageRowid: Int64
        let requestedRecipients: [MessagesConversationAddress]
        let matchingConversations: [MessagesConversationStore.Conversation]

        fileprivate init(maximumChatRowid: Int64, maximumMessageRowid: Int64,
                         requestedRecipients: [MessagesConversationAddress],
                         matchingConversations: [MessagesConversationStore.Conversation]) {
            self.maximumChatRowid = maximumChatRowid
            self.maximumMessageRowid = maximumMessageRowid
            self.requestedRecipients = requestedRecipients
            self.matchingConversations = matchingConversations
        }
    }

    /// Preview may call this without the lease. Execution must call it again
    /// inside resolveWithContext after the shared pending-operation check.
    static func read(databasePath: String, recipients: [MessagesConversationAddress], deadline: WorkerDeadline,
                     isCancelled: @escaping () -> Bool = { false }) throws -> Snapshot {
        if isCancelled() { throw WorkerProtocolError.cancelled }
        guard !deadline.expired else { throw WorkerProtocolError.deadlineExpired }
        return try SQLiteReader.withBoundedReadTransaction(path: databasePath,
            limits: .init(timeout: min(5, Double(deadline.remainingNanoseconds) / 1_000_000_000),
                          rows: 65_536, bytes: 16_777_216, valueBytes: 1_048_576),
            isCancelled: { isCancelled() || deadline.expired }) { scope in
                try read(in: scope, recipients: recipients)
            }
    }

    static func read(in scope: SQLiteReadTransaction, recipients: [MessagesConversationAddress]) throws -> Snapshot {
        guard (1...32).contains(recipients.count), Set(recipients).count == recipients.count else {
            throw MessagesConversationStore.Failure.invalidRequest
        }
        let requested = recipients.sorted { $0.canonical < $1.canonical }
        let schema = try MessagesConversationStore.validateSchema(in: scope)
        let maximumChat = try MessagesConversationStore.greatestRowid(in: .chat, scope: scope)
        let maximumMessage = try MessagesConversationStore.greatestRowid(in: .message, scope: scope)
        let headers = try MessagesConversationStore.headers(group: recipients.count > 1, in: scope)
        var matches: [MessagesConversationStore.Conversation] = []
        for header in headers {
            guard try MessagesConversationStore.matches(header: header, requested: requested,
                                                        schema: schema, in: scope) else { continue }
            guard matches.count < 256 else { throw MessagesConversationStore.Failure.limitExceeded }
            matches.append(try MessagesConversationStore.verifiedConversation(header: header, members: requested, in: scope))
        }
        return Snapshot(maximumChatRowid: maximumChat, maximumMessageRowid: maximumMessage,
                        requestedRecipients: requested, matchingConversations: matches)
    }
}
