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
            // --gmail-mode routes to gmailMove (Gmail copy+delete label semantics: duplicate to the
            // destination, then delete the original to Trash); plain move otherwise. BOTH go through
            // the SAME executeMessageMutation gate (two-factor test gate + per-message subject-label
            // check, all-or-nothing) — gmail-mode weakens no safety gate, and its `delete` is a
            // recoverable move-to-Trash, the same reversible class as the plain `delete` command.
            let script = MailScript()
            let (applied, notFound) = try executeMessageMutation(msgs, testMode: global.testMode) { imid, acct in
                if gmailMode {
                    return try script.gmailMove(internetMessageID: imid, accountName: acct, toMailbox: to)
                }
                return try script.move(internetMessageID: imid, accountName: acct, toMailbox: to)
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
    static let configuration = CommandConfiguration(commandName: "save", abstract: "Save attachments from a message to a directory or an exact path (preview by default).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Message id (ROWID / RFC Message-ID); or use --subject.") var id: String?
    @Option(name: .long, help: "Subject keyword to find the message.") var subject: String?
    @Option(name: .long) var account: String?
    @Option(name: .long, help: "Destination directory for multiple attachments (mutually exclusive with --out).") var dir: String?
    @Option(name: .long, help: "Exact destination file path — rename-on-save; requires exactly one selected attachment (mutually exclusive with --dir).") var out: String?
    @Option(name: .long, help: "0-based attachment indices to save (comma-separated); default all. Mutually exclusive with --name.") var indices: String?
    @Option(name: .long, help: "Save only the attachment with this name. Mutually exclusive with --indices.") var name: String?

    // `out_path` / `saved_paths` / `not_saved` (added MINOR). `directory`/`out_path` are the
    // normalized destination(s) — IDENTICAL in the dry-run preview and the --execute envelope, so
    // a consumer diffing the two never sees the path change shape. `saved_paths` is present
    // (possibly []) on --execute only. `not_saved` lists requested attachment names that did NOT
    // end up saved (a pre-existing-file skip in --dir mode, or an AppleScript-level export
    // failure) so a short save is a visible, agent-detectable signal — never silent success.
    struct Result: Encodable {
        let message_id: String
        let directory: String?
        let out_path: String?
        let attachments: [String]
        let dry_run: Bool
        let note: String?
        let saved_paths: [String]?
        let not_saved: [String]?
    }

    func run() throws {
        try runGuarded(tool: "mail") {
            // Validate args BEFORE opening the index, so usage errors are store-independent.
            guard id != nil || subject != nil else {
                throw AppleError.validation("provide a message id argument or --subject.")
            }
            try requireDirXorOut(dir: dir, out: out)
            try requireNameXorIndices(name: name, indices: indices)

            let ctx = try MailContext()
            let row: [String: String?]
            if let id {
                guard let r = try resolveMessageRow(ctx: ctx, id: id) else { throw AppleError.notFound("no message for id '\(id)'.") }
                row = r
            } else {
                // subject is guaranteed non-nil by the guard above.
                var f = EnvelopeIndex.MessageFilters()
                if let account { f.accountUUID = try ctx.requireAccountUUID(account) }
                f.mailboxName = "All"; f.subjectContains = subject; f.hasAttachment = true; f.limit = 1
                guard let r = try ctx.index.queryMessages(f).first else { throw AppleError.notFound("no message with attachments matching '\(subject ?? "")'.") }
                row = r
            }
            let msg = ctx.decodeSummary(row)
            let rowid = intVal(row["rowid"]) ?? 0

            // Positional selection (never by name — see MailScript.saveAttachments's doc for the
            // known ordering assumption). `master` is the message's attachment list in
            // Envelope-Index order; `wanted` is the ascending 0-based positions --name/--indices/
            // default-all resolves to.
            let master = try ctx.index.attachments(messageRowid: rowid).map(\.name)
            let wanted = resolveAttachmentIndices(names: master, name: name, indices: indices)
            try requireSingleForOut(out: out, selectedCount: wanted.count)
            let selectedNames = wanted.map { master[$0] }

            // Normalize destination(s) ONCE, so preview + execute always agree byte-for-byte.
            func normalize(_ p: String) -> String { URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL.path }
            let absDir = dir.map(normalize)
            let absOut = out.map(normalize)

            guard global.willExecute else {
                try Output.emit(tool: "mail", data: Result(message_id: String(rowid), directory: absDir, out_path: absOut,
                    attachments: selectedNames, dry_run: true, note: nil, saved_paths: nil, not_saved: nil)); return
            }

            // Live export: extract existing attachment bytes to disk. This is a READ/EXPORT
            // (nothing in Mail is mutated), so it gates on --execute ONLY — no --test-mode/label
            // gate like the write commands.
            var pairs: [(index: Int, destPath: String)] = []
            var notSavedIdx: Set<Int> = []

            if let absDir {
                // --dir (multi-save, MCP A style): destination must be an EXISTING directory
                // (matches the MCP oracle, which validates and never creates it).
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: absDir, isDirectory: &isDir) else {
                    throw AppleError.validation("destination directory does not exist: \(absDir)")
                }
                guard isDir.boolValue else {
                    throw AppleError.validation("destination path is not a directory: \(absDir)")
                }
                let basenames = deCollidedBasenames(wanted.map { safeAttachmentBasename(master[$0], fallbackIndex: $0) })
                let fm = FileManager.default
                // Phase 1, all-or-nothing on the dangerous case: a SYMLINK at any computed
                // destination refuses the WHOLE export (a pre-planted symlink could redirect
                // attachment bytes outside --dir). A plain pre-existing FILE just skips that one
                // target — never clobbers an operator's file — recorded in not_saved, not refused.
                for (offset, idx) in wanted.enumerated() {
                    let destPath = (absDir as NSString).appendingPathComponent(basenames[offset])
                    if (try? fm.destinationOfSymbolicLink(atPath: destPath)) != nil {
                        throw AppleError.mailSafety("destination '\(destPath)' is a symlink; refusing to save an attachment through it.")
                    }
                    if fm.fileExists(atPath: destPath) {
                        notSavedIdx.insert(idx); continue
                    }
                    pairs.append((index: idx, destPath: destPath))
                }
            } else if let absOut, let idx = wanted.first {
                // --out (single exact path, MCP B style, rename-on-save): the operator-chosen path
                // is TRUSTED — save verbatim, no de-collision, no pre-existence skip. Only refuse
                // when it already resolves to a directory (can't save a file's bytes onto a dir).
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: absOut, isDirectory: &isDir), isDir.boolValue {
                    throw AppleError.validation("--out path is a directory, not a file: \(absOut)")
                }
                pairs.append((index: idx, destPath: absOut))
            }

            var savedIndices: Set<Int> = []
            if !pairs.isEmpty {
                // Locate the message in Mail.app by its RFC Message-ID: the Envelope-Index row's
                // header, else a raw RFC Message-ID the user passed directly as `id` (a ROWID /
                // `message://` form can't address Mail.app, so those rely on the row header only).
                var rfcID = msg.internet_message_id
                if rfcID == nil || rfcID!.isEmpty, let id {
                    let t = id.trimmingCharacters(in: .whitespacesAndNewlines)
                    if Int(t) == nil, !t.lowercased().hasPrefix("message://"), !t.isEmpty {
                        rfcID = MailFormat.stripAngleBrackets(t) ?? t
                    }
                }
                guard let messageID = rfcID, !messageID.isEmpty else {
                    throw AppleError.upstream("message '\(rowid)' has no RFC Message-ID; cannot fetch its attachments via Mail.app.")
                }
                let acct = msg.account.isEmpty ? nil : msg.account
                guard let saved = try MailScript().saveAttachments(internetMessageID: messageID, accountName: acct, pairs: pairs) else {
                    throw AppleError.upstream("message '\(rowid)' could not be located in Mail.app to save its attachments; the Mail.app locator skips Gmail '[Gmail]/*' mailboxes (All Mail, Sent, …). Move it to INBOX, or save it from Mail.app.")
                }
                savedIndices = saved
            }
            for pair in pairs where !savedIndices.contains(pair.index) { notSavedIdx.insert(pair.index) }

            // Reconcile requested vs actually-saved: a short save is a visible signal (not_saved +
            // note), never a silent "ok" with fewer bytes on disk than the caller asked for.
            let savedPaths = pairs.filter { savedIndices.contains($0.index) }.map(\.destPath)
            let notSaved = wanted.filter { notSavedIdx.contains($0) }.map { master[$0] }
            let note: String? = notSaved.isEmpty ? nil
                : "saved \(savedPaths.count) of \(wanted.count); \(notSaved.count) could not be exported"

            try Output.emit(tool: "mail", data: Result(message_id: String(rowid), directory: absDir, out_path: absOut,
                attachments: selectedNames, dry_run: false, note: note, saved_paths: savedPaths,
                not_saved: notSaved.isEmpty ? nil : notSaved))
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
