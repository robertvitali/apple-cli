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
    @Option(name: .long, help: "Match subject keyword (repeatable — matches ANY, MCP B subject_keywords).") var matchSubject: [String] = []
    @Option(name: .long, help: "Match sender substring.") var matchSender: String?
    @Option(name: .long, help: "Only messages older than N days.") var olderThanDays: Int?
    @Flag(name: .long, help: "Only already-read messages.") var onlyRead = false
    @Flag(name: .long, help: "Operate on the WHOLE mailbox with no subject/sender filter required (MCP B apply_to_all); if a --match filter is also given, that filter still narrows the set. STILL per-message label-gated: a batch containing any unlabeled real message aborts before mutating anything, so on a real INBOX this refuses; it only affects a mailbox of labeled test data. Bounded by --max.") var all = false
    @Option(name: .long, help: "Max messages to affect (safety cap; MCP B max_updates/max_deletes).") var max: Int = 50
    // Count only NON-BLANK keywords: a lone `--match-subject ""` is not an active filter (buildFilter
    // drops empty keywords), so it must not silently mean "whole mailbox" — that intent needs --all.
    var isActive: Bool {
        matchSubject.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            || matchSender != nil || olderThanDays != nil || onlyRead || all
    }
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
    guard match.isActive else { throw AppleError.validation("provide message ids, a --match filter, or --all.") }
    var f = EnvelopeIndex.MessageFilters()
    if let account { f.accountUUID = try ctx.requireAccountUUID(account) }
    f.mailboxName = mailbox
    // --all leaves subject/sender unset → the query returns every message in the mailbox (bounded
    // by --max). subject keywords match ANY (MCP B subject_keywords OR-semantics).
    f.subjectContainsAny = match.matchSubject
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
    /// `delete --permanent` only: ids that WERE found in trash but survived the erase, because
    /// Mail's AppleScript cannot expunge on this account type. Machine-readable so a caller can
    /// distinguish "couldn't find it" from "found it and could not erase it" without parsing prose.
    var expunge_unsupported: [String]? = nil
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
            // Oracle parity: `flag_color="none"` IS the unflag spelling — oracle A's
            // `flag_message` derives `flagged_status = flag_color != "none"` (mail_connector.py)
            // and maps "none" to flag index -1. So `--color none` unflags exactly like `--unflag`;
            // treating it as a colorless FLAG (the prior behavior) inverted the caller's intent.
            let wantsNone = color?.lowercased() == "none"
            // `--unflag` with a real colour is self-contradictory. It used to be accepted and
            // silently resolved to unflag while echoing `color: red`, i.e. output that disagreed
            // with the action taken (MarkCommand refuses the analogous conflict via `triState`).
            if unflag, let color, !wantsNone {
                throw AppleError.validation("--unflag conflicts with --color \(color); pass --unflag (or --color none) to clear, or --color \(color) alone to set.")
            }
            let clearing = unflag || wantsNone
            let act = clearing ? "unflag" : "flag"
            let colorName = color ?? (unflag ? "none" : "red")
            // `color` is this CLI's original key; `flag_color` mirrors oracle A's wire name
            // (additive — both are emitted).
            let detail = ["color": colorName, "flag_color": colorName]
            guard global.willExecute else {
                try Output.emit(tool: "mail", data: BulkPreview(action: act, matched: msgs.count, filter_based: filterBased,
                    dry_run: true, executed: false, messages: msgs, detail: detail, note: nil)); return
            }
            // clearing (--unflag or --color none) → flagged:false; otherwise flagged:true with the
            // resolved color index (red default).
            let flagged = !clearing
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
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete messages to Trash by id or --match (dry-run by default; --permanent erases from Trash IRREVERSIBLY).")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var match: MatchOptions
    @Argument var ids: [String] = []
    @Option(name: .long) var account: String?
    /// Optional so an omitted value is distinguishable from an explicit "INBOX": `--permanent`
    /// defaults the SEARCH scope to the trash it would erase from (see `run()`), because the
    /// INBOX default can by definition never match a message that is eligible for erasure.
    @Option(name: .long, help: "Mailbox to resolve targets in (default INBOX; --permanent defaults to the account's trash).") var mailbox: String?
    @Flag(name: .long, help: "IRREVERSIBLE: permanently erase messages that are ALREADY in trash (needs --test-mode + APPLE_ALLOW_PERMANENT_DELETE=1).") var permanent = false

    /// Operator-only second factor for the irreversible erase — see the gate in `run()`.
    static let operatorEnvVar = "APPLE_ALLOW_PERMANENT_DELETE"

    func run() throws {
        try runGuarded(tool: "mail") {
            // Check the test-mode gate UP FRONT for the irreversible path, before resolving any
            // targets. The per-target label gate below only fires when there IS a target, so a
            // filter that happens to match nothing would otherwise let `--permanent --execute`
            // exit 0 outside test-mode — a confusing near-miss on a destructive command.
            if permanent && global.willExecute {
                guard global.testMode && TestMode.isEnabled else {
                    throw AppleError.mailSafety("permanent delete is IRREVERSIBLE and requires --test-mode AND APPLE_TEST_MODE=1; refused. The default dry-run previews instead.")
                }
                // The subject label must NEVER be the SOLE gate on an irreversible op (see the
                // invariant on requireLiveMessageMutation): a subject is spoofable — anyone can
                // mail the operator a message titled "apple-cli-test …" — so on its own it would
                // let a third party nominate real mail for erasure. Require an operator-only env
                // var as an independent second factor, exactly as `trash empty` does.
                guard ProcessInfo.processInfo.environment[DeleteCommand.operatorEnvVar] == "1" else {
                    throw AppleError.mailSafety("permanent delete is IRREVERSIBLE and its subject label is spoofable, so the label alone does not authorize it — refused. An operator must set \(DeleteCommand.operatorEnvVar)=1 to allow it.")
                }
            }
            let script = MailScript()
            // Resolve the account's trash mailboxes BEFORE target resolution, because for
            // `--permanent` they determine BOTH where we search and where we may erase. On the
            // execute path this is a hard failure (see below); on a dry-run it is best-effort so
            // the preview still renders without Mail.
            var trashBoxes: [MailScript.TrashMailbox] = []
            if permanent {
                if global.willExecute {
                    let all = try script.allMailboxes(accountName: account ?? "")
                    // An unknown --account matches no mailbox. Fail loudly: silently proceeding
                    // would report a clean "nothing was erased" for a command that never looked.
                    guard !all.isEmpty else {
                        throw AppleError.notFound("no mailboxes found\(account.map { " for account '\($0)'" } ?? "") — check --account.")
                    }
                    trashBoxes = all.filter { MailScript.isTrashMailboxName($0.name) }
                    guard !trashBoxes.isEmpty else {
                        throw AppleError.notFound("could not identify a trash mailbox\(account.map { " on account '\($0)'" } ?? "") — refusing to report an erase outcome without one.")
                    }
                } else {
                    trashBoxes = ((try? script.trashMailboxes(accountName: account ?? "")) ?? [])
                }
            }
            let trashNames = trashBoxes.map(\.name)
            // Default the SEARCH scope for --permanent to the "All" wildcard rather than the
            // inherited "INBOX", which by definition can never match an already-trashed (i.e.
            // erasable) message and would make the command silently match nothing. Searching wide
            // is safe here precisely because the ERASE itself is trash-scoped inside the
            // AppleScript: a match that isn't in trash simply comes back not erased. Note this is
            // deliberately NOT `resolveTrashMailbox` — that guard exists to refuse guessing which
            // trash to DESTROY, and applying it to a read scope would reject the common
            // multi-account case for no safety gain. An explicit --mailbox always wins.
            let effectiveMailbox = mailbox ?? (permanent ? "All" : "INBOX")
            let ctx = try MailContext()
            let (msgs, filterBased) = try resolveTargets(ctx: ctx, ids: ids, match: match, account: account, mailbox: effectiveMailbox)
            if permanent && global.willExecute {
                // Re-check the label against the CANONICAL prefix (ignoring any APPLE_TEST_SANDBOX
                // override) so widening that env var cannot widen what an erase may touch.
                try requireCanonicalLabels(msgs)
            }
            let action = permanent ? "delete_permanent" : "delete_to_trash"
            let detail = ["permanent": String(permanent)]
            let previewNote = permanent
                ? "IRREVERSIBLE: --permanent erases messages that are ALREADY in Trash; a message still in a normal mailbox is skipped (trash it first)."
                : nil
            guard global.willExecute else {
                try Output.emit(tool: "mail", data: BulkPreview(action: action, matched: msgs.count, filter_based: filterBased,
                    dry_run: true, executed: false, messages: msgs, detail: detail, note: previewNote)); return
            }
            // Both paths run through executeMessageMutation, whose all-or-nothing label gate
            // (test-mode + `apple-cli-test` subject) validates EVERY target before mutating ANY —
            // so a permanent delete can only ever erase this run's own labeled test messages. The
            // permanent path is additionally scoped to Trash inside the AppleScript, so a message
            // that has not been trashed yet is a no-op rather than an erase.
            // Tracks targets that WERE in trash but survived the erase — Mail cannot expunge them
            // from AppleScript on this account type. Reported separately so a no-op is never
            // dressed up as a success.
            var unsupportedIMIDs = Set<String>()
            let (applied, notFound) = try executeMessageMutation(msgs, testMode: global.testMode) { imid, acct in
                guard permanent else { return try script.deleteToTrash(internetMessageID: imid, accountName: acct) }
                switch try script.deletePermanentlyFromTrash(internetMessageID: imid, accountName: acct,
                                                             trashNames: trashNames) {
                case .erased: return true
                case .notInTrash: return false
                case .unsupported:
                    unsupportedIMIDs.insert(imid)
                    return false
                }
            }
            // Re-key the survivors from RFC Message-ID back to the caller-facing message id, so the
            // envelope is addressable with the same ids the caller passed in.
            let unsupported = msgs.filter { m in
                guard let imid = m.internet_message_id else { return false }
                return unsupportedIMIDs.contains(imid)
            }.map(\.id)
            var note: String?
            if permanent {
                var parts: [String] = []
                if !unsupported.isEmpty {
                    parts.append("\(unsupported.count) message(s) were found in trash but SURVIVED the erase: Mail's AppleScript cannot expunge an already-trashed message on this account type (IMAP/iCloud), so no permanent delete happened for them. Erase them from Mail.app (Mailbox ▸ Erase Deleted Items).")
                }
                if !notFound.isEmpty {
                    parts.append(notLocatedNote(notFound) ?? "")
                    parts.append("not_found here also covers targets that were NOT in trash — --permanent only erases already-trashed messages.")
                }
                let joined = parts.filter { !$0.isEmpty }.joined(separator: " ")
                note = joined.isEmpty ? nil : joined
            } else {
                note = notLocatedNote(notFound)
            }
            try Output.emit(tool: "mail", data: BulkPreview(action: action, matched: msgs.count, filter_based: filterBased,
                dry_run: false, executed: true, messages: msgs, detail: detail,
                note: note, applied: applied, not_found: notFound,
                expunge_unsupported: unsupported.isEmpty ? nil : unsupported))
        }
    }
}

struct TrashCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "trash", abstract: "Trash operations.", subcommands: [TrashEmpty.self])
}
struct TrashEmpty: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "empty", abstract: "Empty an account's Trash (IRREVERSIBLE; operator-gated — see --confirm).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long) var account: String
    @Flag(name: .long, help: "Required confirmation for the destructive empty (oracle `confirm_empty`).") var confirm = false
    @Option(name: .long, help: "Safety cap on how many messages to erase (oracle `max_deletes`).") var max: Int = 5
    @Option(name: .long, help: "Which trash mailbox to empty (required when the account has more than one non-empty).") var trashMailbox: String?

    /// The operator-only trigger. Unlike every other write in this tool, emptying the Trash CANNOT
    /// be scoped to `apple-cli-test` data — it erases whatever real mail the user has trashed — so
    /// the usual label gate has nothing to bite on. This env var is therefore the gate: an
    /// autonomous run never sets it, which makes the destructive path unreachable without a
    /// deliberate human act, while the code path itself stays fully wired and testable.
    static let operatorEnvVar = "APPLE_ALLOW_EMPTY_TRASH"

    func run() throws {
        try runGuarded(tool: "mail") {
            guard max > 0 else { throw AppleError.validation("--max must be greater than 0.") }
            let script = MailScript()
            // Enumerating trash mailboxes is a pure READ. It is best-effort ONLY on the preview
            // path (so a dry-run still renders, and stays CI-runnable, without Mail); on the
            // execute path a failed read MUST propagate — otherwise an unreadable account would
            // report `executed: true, erased: 0, "nothing to erase"` having never looked.
            // ORDER MATTERS: the pure safety refusals (--confirm, operator env var) run BEFORE any
            // Mail access, so a caller missing them is told exactly that rather than getting an
            // unrelated account/read error first — and so refusing costs no I/O.
            if global.willExecute {
                guard confirm else {
                    throw AppleError.validation("empty-trash permanently erases messages from trash — pass --confirm to proceed.")
                }
                guard ProcessInfo.processInfo.environment[TrashEmpty.operatorEnvVar] == "1" else {
                    throw AppleError.mailSafety("empty-trash is IRREVERSIBLE and cannot be scoped to \(TestMode.sandboxPrefix) data, so it is never executed autonomously — refused. An operator must set \(TrashEmpty.operatorEnvVar)=1 to allow it.")
                }
            }
            var boxes: [MailScript.TrashMailbox] = []
            if global.willExecute {
                let all = try script.allMailboxes(accountName: account)
                // An unknown account matches no mailbox — that must not read as "nothing to erase".
                guard !all.isEmpty else {
                    throw AppleError.notFound("no mailboxes found for account '\(account)' — check --account.")
                }
                boxes = all.filter { MailScript.isTrashMailboxName($0.name) }
            } else {
                boxes = (try? script.trashMailboxes(accountName: account)) ?? []
            }
            guard global.willExecute else {
                // Resolution can legitimately throw here (ambiguous / unknown --trash-mailbox);
                // surface that in the PREVIEW so a dry-run predicts what --execute would do.
                let target = try MailScript.resolveTrashMailbox(boxes, explicit: trashMailbox)
                try Output.emit(tool: "mail", data: [
                    "action": AnyEncodableBox("empty_trash"), "account": AnyEncodableBox(account),
                    "trash_mailbox": AnyEncodableBox(target?.name),
                    "trash_mailboxes": AnyEncodableBox(boxes.map { ["name": AnyEncodableBox($0.name), "count": AnyEncodableBox($0.count)] }),
                    "in_trash": AnyEncodableBox(target?.count),
                    "would_erase": AnyEncodableBox(target.map { Swift.min($0.count, max) } ?? 0), "max": AnyEncodableBox(max),
                    "dry_run": AnyEncodableBox(true), "executed": AnyEncodableBox(false),
                    "note": AnyEncodableBox("IRREVERSIBLE. To execute: --execute --confirm with \(TrashEmpty.operatorEnvVar)=1 set. Emptying trash cannot be scoped to \(TestMode.sandboxPrefix) data, so it is never run autonomously.")])
                return
            }
            guard let target = try MailScript.resolveTrashMailbox(boxes, explicit: trashMailbox) else {
                try Output.emit(tool: "mail", data: [
                    "action": AnyEncodableBox("empty_trash"), "account": AnyEncodableBox(account),
                    "erased": AnyEncodableBox(0), "in_trash_before": AnyEncodableBox(0),
                    "dry_run": AnyEncodableBox(false), "executed": AnyEncodableBox(true),
                    "note": AnyEncodableBox("nothing to erase — no non-empty trash mailbox on this account")])
                return
            }
            let (removed, total, stalled) = try script.emptyTrash(accountName: account, mailboxName: target.name, max: max)
            let emptyNote: String?
            if stalled {
                emptyNote = "STOPPED after \(removed) erase(s): a delete had no effect, so Mail's AppleScript cannot expunge this account type (IMAP/iCloud). \(total - removed) message(s) remain in \(target.name) — erase them from Mail.app (Mailbox ▸ Erase Deleted Items)."
            } else if removed < total {
                emptyNote = "capped by --max \(max); \(total - removed) message(s) remain in \(target.name)"
            } else {
                emptyNote = nil
            }
            try Output.emit(tool: "mail", data: [
                "action": AnyEncodableBox("empty_trash"), "account": AnyEncodableBox(account),
                "trash_mailbox": AnyEncodableBox(target.name),
                "erased": AnyEncodableBox(removed), "in_trash_before": AnyEncodableBox(total),
                "max": AnyEncodableBox(max), "remaining": AnyEncodableBox(total - removed),
                "expunge_unsupported": AnyEncodableBox(stalled),
                "dry_run": AnyEncodableBox(false), "executed": AnyEncodableBox(true),
                "note": AnyEncodableBox(emptyNote)])
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
            // Oracle-parity input validation, BEFORE any Mail/index access so it holds on the
            // dry-run path too (a preview that accepts a name --execute would reject is a lie).
            // Oracle A: "Mailbox name cannot be empty" (validation_error) for empty/whitespace.
            // Oracle B: rejects the `_INVALID_MAILBOX_CHARS` set — characters that break
            // AppleScript strings or mailbox names. Previously `--name ""` returned ok:true with
            // an empty `path`.
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw AppleError.validation("mailbox name cannot be empty.")
            }
            // Applied per '/'-separated SEGMENT: '/' itself is the documented nesting separator,
            // so it is legal in `name` but must not appear inside a segment.
            let segments = name.components(separatedBy: "/")
            guard !segments.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                throw AppleError.validation("mailbox path '\(name)' has an empty path segment.")
            }
            let invalid = CharacterSet(charactersIn: "\\\"<>|?*:").union(.controlCharacters)
            for seg in segments where seg.rangeOfCharacter(from: invalid) != nil {
                throw AppleError.validation("mailbox segment '\(seg)' contains a character that is invalid in a Mail mailbox name (any of \\ \" < > | ? * : or a control character).")
            }
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
