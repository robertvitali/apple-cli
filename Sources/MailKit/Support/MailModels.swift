import Foundation

// Output models for `apple mail`. Field names ARE the wire keys (snake_case, no case
// conversion — see docs/DESIGN.md). Where MCP A and MCP B name the same concept differently
// (A `id` vs B `message_id`; A `read_status` vs B `is_read`; A `date_received` vs B
// `received_date`), the union model carries BOTH names so the CLI is a strict superset of
// each. Extra fields (rowid, structured sender, flag_color, mail_link, …) are additive.

// MARK: Accounts

public struct MailAccount: Encodable {
    public let id: String                 // UUID (stable; matches mailbox-url host)
    public let name: String
    public let email_addresses: [String]
    public let account_type: String
    public let enabled: Bool
}

public struct MailAccountsResult: Encodable {
    public let accounts: [MailAccount]
    public let count: Int
}

// MARK: Mailboxes

public struct MailMailbox: Encodable {
    public let account: String            // account name (or UUID if unresolved)
    public let account_id: String         // UUID
    public let name: String               // leaf name
    public let path: String               // full slash path ("Vendor/Receipts")
    public let url: String                // raw Envelope Index url
    public let total_count: Int?
    public let unread_count: Int?
    public let deleted_count: Int?
    public let is_label: Bool             // Gmail label (membership via `labels`, not m.mailbox)
}

public struct MailMailboxesResult: Encodable {
    public let account: String?
    public let mailboxes: [MailMailbox]
    public let count: Int
}

// MARK: Messages

/// Union message model. Summaries (search/list/thread) leave detail fields nil; `get`/
/// `selected` populate `content`, `to`, `cc`, `bcc`, `headers`.
public struct MailMessage: Encodable {
    // Identifiers (union of A `id` + B `message_id`/`internet_message_id`/`mail_link`)
    public var id: String                 // Envelope Index ROWID (fast, stable-in-store)
    public var message_id: String         // == ROWID (MCP B field name)
    public var rowid: Int
    public var internet_message_id: String?   // RFC-5322 Message-ID (bracket-stripped)
    public var mail_link: String?             // message://… deep link (MCP B)
    public var applescript_id: String?        // Mail.app AppleScript id (nil on SQLite path)

    // Core
    public var subject: String
    public var sender: String                 // "Name <email>" or bare email
    public var sender_name: String?
    public var sender_address: String?
    public var mailbox: String                // path
    public var account: String                // name or UUID
    public var read_status: Bool              // MCP A field name
    public var is_read: Bool                  // MCP B field name
    public var flagged: Bool
    public var flag_color: Int?               // meaningful only when flagged
    public var flag_color_name: String?
    public var date_received: String?         // ISO-8601 UTC (MCP A field name)
    public var received_date: String?         // ISO-8601 UTC (MCP B field name)
    public var date_sent: String?
    public var has_attachments: Bool
    public var attachment_count: Int
    public var size: Int?
    public var conversation_id: Int?

    // Detail (get / selected / include_content)
    public var snippet: String?               // Envelope Index summary preview
    /// MCP B's name for the same preview text. Carried alongside `snippet` per this file's
    /// dual-key rule — a consumer ported from B looks for `content_preview` and previously
    /// found nothing, which is exactly the drop the rule exists to prevent.
    public var content_preview: String?
    public var content: String?               // full body (AppleScript)
    public var to: [String]?
    public var cc: [String]?
    public var bcc: [String]?
}

public struct MailMessagesResult: Encodable {
    public let account: String?
    public let mailbox: String?
    public let messages: [MailMessage]
    public let count: Int
    public let offset: Int?
    public let limit: Int?
    public let has_more: Bool?
    public let next_offset: Int?
    public let sort: String?
    /// True when a `mailbox: "All"` query dropped the MCP B `SKIP_FOLDERS` system mailboxes.
    /// Without this the narrowing is INVISIBLE to a machine consumer: pagination stays internally
    /// consistent (count and has_more share one filter), so nothing else in the envelope reveals
    /// that ~2k messages were excluded from "All". nil when the query was not an "All" sweep.
    public var system_folders_excluded: Bool? = nil
}

public struct MailMessageResult: Encodable {
    public let message: MailMessage
}

public struct MailThreadResult: Encodable {
    public let messages: [MailMessage]
    public let count: Int
    public let matched_by: String             // "message_id" | "subject_keyword"
}

// MARK: Unread counts

public struct MailUnreadCountsResult: Encodable {
    // Mirrors MCP B: summary = flat {account: count}; full = nested {account: {path: count}}.
    public let summary: [String: Int]?
    public let by_account: [String: [MailboxUnread]]?
    public let total_unread: Int
}

public struct MailboxUnread: Encodable {
    public let path: String
    public let unread_count: Int
}

// MARK: Attachments

public struct MailAttachment: Encodable {
    public let name: String
    public let attachment_id: String?         // MIME part id, e.g. "2.10"
    public let size: Int?                      // bytes (AppleScript path only)
    public let message_id: String             // owning message ROWID
}

public struct MailAttachmentsResult: Encodable {
    public let attachments: [MailAttachment]
    public let count: Int
    public let matched_by: String             // "message_id" | "subject_keyword"
}
