import Foundation
import AppleKit

// Shared helpers for the Mail command tree — kept small + pure where possible.

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
