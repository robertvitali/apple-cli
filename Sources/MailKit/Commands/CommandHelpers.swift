import Foundation
import AppleKit

// Shared helpers for the Mail command tree — kept small + pure where possible.

extension AppleError {
    /// Mail-side safety refusal (mirrors Contacts' `safetyViolation`): a live mutation blocked
    /// by the test-mode / subject-label / recipient guard. Exit 77 (permission-denied) — a
    /// deliberate refusal, not a bug — so callers can distinguish it from a real failure.
    static func mailSafety(_ m: String) -> AppleError {
        .init(type: "safety_violation", message: m, exitCode: AppleExit.permissionDenied)
    }
}

/// Gate a live mutation on an EXISTING message. Requires the two-factor test gate AND that the
/// target's subject is a labeled `apple-cli-test…` item — so an autonomous run can only mutate
/// test data it created, never real mail (AGENTS.md: "modifying any EXISTING real data the run
/// did not create" is a dangerous action). Returns the RFC Message-ID to operate on.
///
/// NOTE (defense-in-depth boundary): the label key is the message SUBJECT, which anyone can set
/// by emailing the operator a message titled `apple-cli-test …`. That is acceptable ONLY because
/// every op gated by this function is REVERSIBLE (mark/flag/move/trash-to-Trash) and the blast
/// radius of a spoofed subject is that one attacker-authored message. This subject-prefix check
/// must NEVER become the sole gate for an irreversible operation — those stay hard-refused.
func requireLiveMessageMutation(_ m: MailMessage, testMode: Bool) throws -> String {
    guard testMode && TestMode.isEnabled else {
        throw AppleError.mailSafety("live mutation requires --test-mode AND APPLE_TEST_MODE=1; refusing. The default dry-run previews instead.")
    }
    guard m.subject.hasPrefix(TestMode.sandboxPrefix) else {
        throw AppleError.mailSafety("target message '\(m.id)' (subject: \"\(m.subject)\") is not a labeled test item (must start with \"\(TestMode.sandboxPrefix)\") — refusing to mutate real mail.")
    }
    guard let imid = m.internet_message_id, !imid.isEmpty else {
        throw AppleError.upstream("message '\(m.id)' has no RFC Message-ID; cannot mutate it via Mail.app.")
    }
    return imid
}

/// Execute a per-message mutation over resolved targets, ALL-OR-NOTHING on the label gate.
/// Phase 1 validates EVERY target's gate (`requireLiveMessageMutation`) before ANY mutation runs,
/// so a mixed batch containing one unlabeled/real message mutates nothing AND the throw can't
/// leave already-applied ids unreported. Phase 2 then mutates; a target Mail can't locate is
/// collected into `not_found` (not a throw). `op` returns true when the change applied. Returns
/// (applied ids, not-found ids).
func executeMessageMutation(_ msgs: [MailMessage], testMode: Bool,
                            _ op: (_ internetMessageID: String, _ account: String?) throws -> Bool) throws
    -> (applied: [String], notFound: [String]) {
    // Phase 1 — gate every target up front; the first unlabeled/ungated one throws before any op.
    let validated: [(id: String, imid: String, account: String?)] = try msgs.map { m in
        (m.id, try requireLiveMessageMutation(m, testMode: testMode), m.account.isEmpty ? nil : m.account)
    }
    // Phase 2 — mutate the fully-validated set; op failures mean "not locatable", not a gate breach.
    var applied: [String] = [], notFound: [String] = []
    for t in validated {
        if try op(t.imid, t.account) { applied.append(t.id) } else { notFound.append(t.id) }
    }
    return (applied, notFound)
}

/// Collapse two mutually-exclusive boolean flags into an optional tri-state (nil = any).
func triState(_ positive: Bool, _ negative: Bool, _ posName: String, _ negName: String) throws -> Bool? {
    if positive && negative { throw AppleError.validation("--\(posName) and --\(negName) are mutually exclusive.") }
    if positive { return true }
    if negative { return false }
    return nil
}

/// Parse a required `YYYY-MM-DD` option to a Unix epoch, or throw a clear validation error.
func requireISODate(_ iso: String, name: String, endOfDay: Bool = false) throws -> Int {
    guard let unix = MailFormat.unix(fromISODate: iso, endOfDay: endOfDay) else {
        throw AppleError.validation("--\(name) must be an ISO date (YYYY-MM-DD); got '\(iso)'.")
    }
    return unix
}

/// Resolve a user-supplied message identifier — Envelope Index ROWID, RFC-5322 Message-ID,
/// or a `message://` deep link — to a message row. Returns nil if not found.
func resolveMessageRow(ctx: MailContext, id: String) throws -> [String: String?]? {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    if let rowid = Int(trimmed) { return try ctx.index.message(rowid: rowid) }
    if trimmed.lowercased().hasPrefix("message://") {
        // message://%3C<encoded id>%3E  → strip scheme + angle-bracket wrappers, decode.
        var inner = String(trimmed.dropFirst("message://".count))
        inner = inner.removingPercentEncoding ?? inner
        return try ctx.index.message(internetMessageID: inner)
    }
    return try ctx.index.message(internetMessageID: trimmed)
}

/// Emit a messages result as JSON, or a compact human list under `--text`.
func emitMessages(_ result: MailMessagesResult, json: Bool) throws {
    if json { try Output.emit(tool: "mail", data: result); return }
    for m in result.messages { printMessageText(m, full: false) }
    if let hasMore = result.has_more, hasMore, let next = result.next_offset {
        FileHandle.standardError.write(Data("… more (next --offset \(next))\n".utf8))
    }
}

func printMessageText(_ m: MailMessage, full: Bool) {
    let flag = m.flagged ? " ⚑\(m.flag_color_name.map { "(\($0))" } ?? "")" : ""
    let unread = m.is_read ? "" : " •"
    print("[\(m.id)]\(unread)\(flag) \(m.subject)")
    print("    from: \(m.sender)   \(m.date_received ?? "")   \(m.account)/\(m.mailbox)")
    if let to = m.to, !to.isEmpty { print("    to: \(to.joined(separator: ", "))") }
    if let cc = m.cc, !cc.isEmpty { print("    cc: \(cc.joined(separator: ", "))") }
    if full, let content = m.content, !content.isEmpty {
        print("    ----")
        print(content)
    } else if let snip = m.snippet, !snip.isEmpty {
        print("    \(snip.prefix(140))")
    }
}

extension MailMessage {
    /// Build a message from a live Mail.app selection when it isn't in the Envelope Index.
    static func fromSelection(_ sel: MailScript.ScriptSelection) -> MailMessage {
        MailMessage(
            id: sel.applescriptID,
            message_id: sel.applescriptID,
            rowid: 0,
            internet_message_id: sel.internetMessageID,
            mail_link: MailFormat.mailLink(internetMessageID: sel.internetMessageID),
            applescript_id: sel.applescriptID,
            subject: sel.subject,
            sender: sel.sender,
            sender_name: nil,
            sender_address: nil,
            mailbox: "",
            account: "",
            read_status: sel.readStatus,
            is_read: sel.readStatus,
            flagged: sel.flagged,
            flag_color: nil,
            flag_color_name: nil,
            date_received: nil,
            received_date: nil,
            date_sent: nil,
            has_attachments: false,
            attachment_count: 0,
            size: nil,
            conversation_id: nil,
            snippet: nil,
            content: sel.content,
            to: nil, cc: nil, bcc: nil)
    }
}
