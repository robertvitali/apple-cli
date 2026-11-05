import AppleKit

/// Advisory output only. This type cannot carry a baseline or authorize native
/// work. Execution must resolve the request again under the operation lease.
enum MessagesConversationPreview {
    struct ExistingDM: Encodable, Sendable {
        let status: String
        let chat_rowid: Int64?
        let chat_guid: String?
    }
    struct Payload: Encodable, Sendable {
        let advisory: Bool
        let initial_send_required: Bool
        let initial_message: String
        let service: String
        let recipients: [String]
        let existing_dm: ExistingDM
    }

    /// No native adapter or journal dependency is accepted. Even a plan captured
    /// in execution posture produces only a read-only preview here.
    static func read(databasePath: String, plan: MessagesConversationPlan.Plan,
                     deadline: WorkerDeadline, isCancelled: @escaping () -> Bool = { false }) throws -> Payload {
        let addresses = plan.recipients.map(\.candidate.address)
        let baseline = try MessagesConversationBaseline.read(databasePath: databasePath,
            recipients: addresses, deadline: deadline, isCancelled: isCancelled)
        // Advisory database state may change, but deterministic wire limits
        // must agree with execution. This pure construction performs no handoff.
        _ = try MessagesConversationRequest(plan: plan, baseline: baseline)
        let existing: ExistingDM
        if plan.isGroup {
            // Same participants do not establish native group reuse semantics.
            existing = .init(status: "not_applicable", chat_rowid: nil, chat_guid: nil)
        } else if baseline.matchingConversations.count == 1, let match = baseline.matchingConversations.first {
            existing = .init(status: "unique", chat_rowid: match.rowid, chat_guid: match.guid)
        } else {
            existing = .init(status: baseline.matchingConversations.isEmpty ? "absent" : "ambiguous",
                             chat_rowid: nil, chat_guid: nil)
        }
        return Payload(advisory: true, initial_send_required: true, initial_message: plan.initialText,
                       service: plan.service, recipients: addresses.map(\.canonical), existing_dm: existing)
    }
}
