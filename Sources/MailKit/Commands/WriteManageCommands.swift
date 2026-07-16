import Foundation
import ArgumentParser
import AppleKit

// P2 manage/mutate surface: move, mark, flag, delete-to-trash, trash empty (refused), mailboxes
// create, attachments save. Dual targeting (explicit ids OR --match filters). Live mutation
// requires --execute AND the two-factor test gate; the per-message SUBJECT-LABEL check is the
// bulk-safety mechanism (NOT a forced dry-run): `executeMessageMutation` validates EVERY target
// before mutating any, so a filter-matched batch containing any unlabeled/real message aborts
// before touching anything (all-or-nothing). permanent-delete + empty-trash are hard-refused.

/// Note for an executed mutation envelope when some targets weren't located. The bounded Mail.app
/// locator skips Gmail's "[Gmail]/*" system mailboxes (All Mail, Sent, …) to avoid O(n) hangs, but
/// the Envelope Index (what `search`/`list` read) DOES include them — so an archived/sent message
/// a search surfaced can't be mutated in place, and would otherwise return `applied:[]` silently.
func notLocatedNote(_ notFound: [String]) -> String? {
    notFound.isEmpty ? nil
        : "\(notFound.count) message(s) could not be located to mutate: the Mail.app locator skips Gmail '[Gmail]/*' mailboxes (All Mail, Sent, Trash, …). Mutate archived/sent mail in Mail.app, or move it to INBOX first."
}

/// Filter selector for bulk ops (MCP B move/update/trash filter model).
struct MatchOptions: ParsableArguments {
    @Option(name: .long, help: "Match subject keyword.") var matchSubject: String?
    @Option(name: .long, help: "Match sender substring.") var matchSender: String?
    @Option(name: .long, help: "Only messages older than N days.") var olderThanDays: Int?
    @Flag(name: .long, help: "Only already-read messages.") var onlyRead = false
    @Option(name: .long, help: "Max messages to affect (safety cap).") var max: Int = 50
    var isActive: Bool { matchSubject != nil || matchSender != nil || olderThanDays != nil || onlyRead }
}

/// Resolve targets: explicit ids (precise) OR --match filters (bulk). Returns decoded
/// summaries for the preview + whether a filter was used (→ mandatory dry-run).
func resolveTargets(ctx: MailContext, ids: [String], match: MatchOptions, account: String?, mailbox: String) throws -> (messages: [MailMessage], filterBased: Bool) {
    if !ids.isEmpty {
        var out: [MailMessage] = []
        for id in ids {
            guard let row = try resolveMessageRow(ctx: ctx, id: id) else { throw AppleError.notFound("no message for id '\(id)'.") }
            out.append(ctx.decodeSummary(row))
        }
        return (out, false)
    }
    guard match.isActive else { throw AppleError.validation("provide message ids or at least one --match filter.") }
    var f = EnvelopeIndex.MessageFilters()
    if let account { f.accountUUID = try ctx.requireAccountUUID(account) }
    f.mailboxName = mailbox
    f.subjectContains = match.matchSubject
    f.senderContains = match.matchSender
    if match.onlyRead { f.readStatus = true }
    if let days = match.olderThanDays { f.dateToUnix = Int(Date().timeIntervalSince1970) - days * 86400 }
    f.limit = match.max
    let rows = try ctx.index.queryMessages(f)
    return (rows.map { ctx.decodeSummary($0) }, true)
}

struct BulkPreview: Encodable {
    let action: String
    let matched: Int
    let filter_based: Bool
    let dry_run: Bool
    let executed: Bool
    let messages: [MailMessage]
    let detail: [String: String]
    let note: String?
    var applied: [String]? = nil     // ids the live mutation applied to (executed path)
    var not_found: [String]? = nil   // ids Mail could not locate (executed path)
}

struct MoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "move", abstract: "Move messages by id or --match to a mailbox (dry-run by default).")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var match: MatchOptions
    @Argument(help: "Message ids (or use --match).") var ids: [String] = []
    @Option(name: .long, help: "Destination mailbox (use '/' for nested).") var to: String
    @Option(name: .long, help: "Source account (name or UUID).") var account: String?
    @Option(name: .long, help: "Source mailbox (default INBOX).") var source: String = "INBOX"
    @Flag(name: .long, help: "Gmail label-move handling (copy + delete).") var gmailMode = false

    func run() throws {
        try runGuarded(tool: "mail") {
            let ctx = try MailContext()
            let (msgs, filterBased) = try resolveTargets(ctx: ctx, ids: ids, match: match, account: account, mailbox: source)
            let detail = ["to": to, "gmail_mode": String(gmailMode)]
            guard global.willExecute else {
                try Output.emit(tool: "mail", data: BulkPreview(action: "move", matched: msgs.count, filter_based: filterBased,
                    dry_run: true, executed: false, messages: msgs, detail: detail, note: nil)); return
            }
            // --gmail-mode (Gmail copy+delete label semantics) is NOT wired for live move — reject
            // rather than silently doing a plain move that ignores the flag.
            if gmailMode {
                throw AppleError.validation("--gmail-mode (Gmail copy+delete label semantics) is not yet wired for live move; omit it, or move the message in Mail.app.")
            }
            let script = MailScript()
            let (applied, notFound) = try executeMessageMutation(msgs, testMode: global.testMode) { imid, acct in
                try script.move(internetMessageID: imid, accountName: acct, toMailbox: to)
            }
            try Output.emit(tool: "mail", data: BulkPreview(action: "move", matched: msgs.count, filter_based: filterBased,
                dry_run: false, executed: true, messages: msgs, detail: detail, note: notLocatedNote(notFound), applied: applied, not_found: notFound))
        }
    }
}

struct MarkCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mark", abstract: "Mark messages read/unread by id or --match (dry-run by default).")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var match: MatchOptions
    @Argument var ids: [String] = []
    @Option(name: .long) var account: String?
    @Option(name: .long) var mailbox: String = "INBOX"
    @Flag(name: .long) var read = false
    @Flag(name: .long) var unread = false

    func run() throws {
        try runGuarded(tool: "mail") {
            let target = try triState(read, unread, "read", "unread")
            guard let markRead = target else { throw AppleError.validation("specify --read or --unread.") }
            let ctx = try MailContext()
            let (msgs, filterBased) = try resolveTargets(ctx: ctx, ids: ids, match: match, account: account, mailbox: mailbox)
            let action = markRead ? "mark_read" : "mark_unread"
            guard global.willExecute else {
                try Output.emit(tool: "mail", data: BulkPreview(action: action, matched: msgs.count, filter_based: filterBased,
                    dry_run: true, executed: false, messages: msgs, detail: [:], note: nil)); return
            }
            let script = MailScript()
            let (applied, notFound) = try executeMessageMutation(msgs, testMode: global.testMode) { imid, acct in
                try script.setRead(internetMessageID: imid, accountName: acct, read: markRead)
            }
            try Output.emit(tool: "mail", data: BulkPreview(action: action, matched: msgs.count, filter_based: filterBased,
                dry_run: false, executed: true, messages: msgs, detail: [:], note: notLocatedNote(notFound), applied: applied, not_found: notFound))
        }
    }
}

struct FlagCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "flag", abstract: "Flag/unflag messages by id or --match, with optional color (dry-run by default).")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var match: MatchOptions
    @Argument var ids: [String] = []
    @Option(name: .long) var account: String?
    @Option(name: .long) var mailbox: String = "INBOX"
    @Option(name: .long, help: "Flag color: none/orange/red/yellow/blue/green/purple/gray.") var color: String?
    @Flag(name: .long, help: "Remove the flag.") var unflag = false

    func run() throws {
        try runGuarded(tool: "mail") {
            if let color, !MailFlagColor.acceptedTokens.contains(color.lowercased()) {
                throw AppleError.validation("--color must be one of \(MailFlagColor.acceptedTokens.joined(separator: "/")).")
            }
            let ctx = try MailContext()
            let (msgs, filterBased) = try resolveTargets(ctx: ctx, ids: ids, match: match, account: account, mailbox: mailbox)
            let act = unflag ? "unflag" : "flag"
            let colorName = color ?? (unflag ? "none" : "red")
            let detail = ["color": colorName]
            guard global.willExecute else {
                try Output.emit(tool: "mail", data: BulkPreview(action: act, matched: msgs.count, filter_based: filterBased,
                    dry_run: true, executed: false, messages: msgs, detail: detail, note: nil)); return
            }
            // unflag → flagged:false; flag → flagged:true with the resolved color index (red default).
            let flagged = !unflag
            let colorIndex = flagged ? (MailFlagColor.fromToken(colorName)?.rawValue) : nil
            let script = MailScript()
            let (applied, notFound) = try executeMessageMutation(msgs, testMode: global.testMode) { imid, acct in
                try script.setFlag(internetMessageID: imid, accountName: acct, flagged: flagged, colorIndex: colorIndex)
            }
            try Output.emit(tool: "mail", data: BulkPreview(action: act, matched: msgs.count, filter_based: filterBased,
                dry_run: false, executed: true, messages: msgs, detail: detail, note: notLocatedNote(notFound), applied: applied, not_found: notFound))
        }
    }
}

struct DeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete messages to Trash by id or --match (dry-run by default; --permanent is a DANGEROUS no-op guard).")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var match: MatchOptions
    @Argument var ids: [String] = []
    @Option(name: .long) var account: String?
    @Option(name: .long) var mailbox: String = "INBOX"
    @Flag(name: .long, help: "Permanent delete (DANGEROUS — never executed autonomously).") var permanent = false

    func run() throws {
        try runGuarded(tool: "mail") {
            // Dangerous refuse fires BEFORE any preview → exactly one (error) envelope.
            if global.willExecute && permanent {
                throw AppleError.validation("permanent delete is a DANGEROUS irreversible action and is never executed autonomously — refused.")
            }
            let ctx = try MailContext()
            let (msgs, filterBased) = try resolveTargets(ctx: ctx, ids: ids, match: match, account: account, mailbox: mailbox)
            let action = permanent ? "delete_permanent" : "delete_to_trash"
            let detail = ["permanent": String(permanent)]
            guard global.willExecute else {
                try Output.emit(tool: "mail", data: BulkPreview(action: action, matched: msgs.count, filter_based: filterBased,
                    dry_run: true, executed: false, messages: msgs, detail: detail, note: nil)); return
            }
            // Only the recoverable move-to-Trash executes (permanent was refused above). Each
            // target is label-gated, so an autonomous run can only trash its own test messages.
            let script = MailScript()
            let (applied, notFound) = try executeMessageMutation(msgs, testMode: global.testMode) { imid, acct in
                try script.deleteToTrash(internetMessageID: imid, accountName: acct)
            }
            try Output.emit(tool: "mail", data: BulkPreview(action: action, matched: msgs.count, filter_based: filterBased,
                dry_run: false, executed: true, messages: msgs, detail: detail, note: notLocatedNote(notFound), applied: applied, not_found: notFound))
        }
    }
}

struct TrashCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "trash", abstract: "Trash operations.", subcommands: [TrashEmpty.self])
}
struct TrashEmpty: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "empty", abstract: "Empty the Trash (DANGEROUS — never executed autonomously).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long) var account: String
    @Flag(name: .long, help: "Required confirmation for the destructive empty.") var confirm = false
    func run() throws {
        try runGuarded(tool: "mail") {
            // Dangerous refuse before emit → one envelope.
            if global.willExecute {
                throw AppleError.validation("empty-trash is a DANGEROUS irreversible action and is never executed autonomously — refused.")
            }
            try Output.emit(tool: "mail", data: ["action": AnyEncodableBox("empty_trash"), "account": AnyEncodableBox(account),
                                                 "dry_run": AnyEncodableBox(true), "note": AnyEncodableBox("empty-trash is irreversible and is never executed autonomously")])
        }
    }
}

struct AttachmentsSave: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "save", abstract: "Save attachments from a message to a directory (preview by default).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Message id (ROWID / RFC Message-ID); or use --subject.") var id: String?
    @Option(name: .long, help: "Subject keyword to find the message.") var subject: String?
    @Option(name: .long) var account: String?
    @Option(name: .long, help: "Destination directory.") var dir: String
    @Option(name: .long, help: "0-based attachment indices to save (comma-separated); default all.") var indices: String?
    @Option(name: .long, help: "Save only the attachment with this name.") var name: String?

    struct Result: Encodable { let message_id: String; let directory: String; let attachments: [String]; let dry_run: Bool; let note: String? }

    func run() throws {
        try runGuarded(tool: "mail") {
            let ctx = try MailContext()
            var rowid = 0
            if let id {
                guard let row = try resolveMessageRow(ctx: ctx, id: id) else { throw AppleError.notFound("no message for id '\(id)'.") }
                rowid = intVal(row["rowid"]) ?? 0
            } else if let subject {
                var f = EnvelopeIndex.MessageFilters()
                if let account { f.accountUUID = try ctx.requireAccountUUID(account) }
                f.mailboxName = "All"; f.subjectContains = subject; f.hasAttachment = true; f.limit = 1
                guard let row = try ctx.index.queryMessages(f).first else { throw AppleError.notFound("no message with attachments matching '\(subject)'.") }
                rowid = intVal(row["rowid"]) ?? 0
            } else {
                throw AppleError.validation("provide a message id argument or --subject.")
            }
            var atts = try ctx.index.attachments(messageRowid: rowid).map(\.name)
            if let name { atts = atts.filter { $0 == name } }
            if let indices {
                let want = Set(indices.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
                atts = atts.enumerated().filter { want.contains($0.offset) }.map(\.element)
            }
            try Output.emit(tool: "mail", data: Result(message_id: String(rowid), directory: dir, attachments: atts,
                dry_run: !global.willExecute,
                note: global.willExecute ? "live attachment save (AppleScript content fetch) is disabled in this build; this is the attachment list preview" : nil))
        }
    }
}

/// `mailboxes create` — lives under the existing `mailboxes` parent (registered there).
struct MailboxesCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a mailbox/folder (dry-run by default; nested via '/').")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long) var account: String
    @Option(name: .long, help: "Mailbox name (may contain '/' for a nested path).") var name: String
    @Option(name: .long, help: "Optional parent mailbox for nesting.") var parent: String?

    func run() throws {
        try runGuarded(tool: "mail") {
            let ctx = try MailContext()
            let uuid = try ctx.requireAccountUUID(account)
            let fullPath = parent.map { "\($0)/\(name)" } ?? name
            var executed = false
            let note: String? = nil
            if global.willExecute {
                // Creating a folder is additive, but gate it: test-mode + the new folder's name
                // must be a labeled test item, so autonomous runs only create cleanable folders.
                guard global.testMode && TestMode.isEnabled else {
                    throw AppleError.mailSafety("creating a mailbox requires --test-mode AND APPLE_TEST_MODE=1; refusing. The default dry-run previews instead.")
                }
                guard name.hasPrefix(TestMode.sandboxPrefix) else {
                    throw AppleError.mailSafety("mailbox name '\(name)' is not a labeled test item (must start with \"\(TestMode.sandboxPrefix)\") — refusing.")
                }
                try MailScript().createMailbox(accountName: account, path: fullPath)
                executed = true
            }
            try Output.emit(tool: "mail", data: ["action": AnyEncodableBox("create_mailbox"), "account": AnyEncodableBox(account),
                "account_id": AnyEncodableBox(uuid), "path": AnyEncodableBox(fullPath), "dry_run": AnyEncodableBox(!global.willExecute),
                "executed": AnyEncodableBox(executed), "note": AnyEncodableBox(note)])
        }
    }
}
