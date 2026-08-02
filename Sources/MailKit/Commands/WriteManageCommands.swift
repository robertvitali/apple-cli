import Foundation
import ArgumentParser
import AppleKit

// P2 manage/mutate surface: move, mark, flag, delete-to-trash, trash empty, mailboxes create,
// attachments save. Dual targeting (explicit ids OR --match filters). Write-model v2
// (docs/write-model-v2.md): general mutations EXECUTE when invoked (`--dry-run` previews;
// `APPLE_DRY_RUN=1` restores dry-run-by-default); the TRASH surface (`delete`, `trash empty`)
// keeps dry-run as its default (oracle B manage_trash dry_run=True IS parity). Inside the
// opt-in SANDBOX the per-message SUBJECT-LABEL check is the bulk-safety mechanism:
// `executeMessageMutation` validates EVERY target before mutating any, so a batch containing
// any unlabeled/real message aborts before touching anything (all-or-nothing). Unsandboxed,
// mutations operate on real mail as addressed (the oracle model). The two IRREVERSIBLE ops
// keep UNCONDITIONAL operator-only env gates in both modes: permanent-delete
// (APPLE_ALLOW_PERMANENT_DELETE + canonical-label check) and empty-trash
// (APPLE_ALLOW_EMPTY_TRASH + --confirm).

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
    @Flag(name: .long, help: "Operate on the WHOLE mailbox with no subject/sender filter required (MCP B apply_to_all); if a --match filter is also given, that filter still narrows the set. Bounded by --max. MUTATES REAL MAIL when unsandboxed — preview with --dry-run first. Inside the sandbox it stays per-message label-gated: a batch containing any unlabeled real message aborts before mutating anything.") var all = false
    @Option(name: .long, help: "Max messages to affect (safety cap; MCP B max_updates/max_deletes).") var max: Int = 50
    // Count only NON-BLANK keywords: a lone `--match-subject ""` is not an active filter (buildFilter
    // drops empty keywords), so it must not silently mean "whole mailbox" — that intent needs --all.
    var isActive: Bool {
        matchSubject.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            || matchSender != nil || olderThanDays != nil || onlyRead || all
    }
}

/// Resolve targets: explicit ids (precise) OR --match filters (bulk). Returns decoded
/// summaries for the preview + whether a filter was used (surfaced as `filter_based` and the
/// scope_note in the envelope — under write-model v2 filter-based mutations execute like any
/// other; there is no forced dry-run).
/// Oracle A's bulk cap: 100 items per call. BUCKET 1 (oracle-mirrored ⇒ applies UNCONDITIONALLY,
/// sandbox or not), but scoped with two deliberate precisions a careless port gets wrong:
///
///  1. **Only two operations carry it.** `mark_as_read` (server.py:995, via
///     `validate_bulk_operation(len(message_ids), max_items=100)`) and `delete_messages`
///     (server.py:1719-1725, an inline `len(message_ids) > 100` check). `move_messages` and
///     `flag_message` have NO cap in the oracle — grep of every `validate_bulk_operation` call
///     site returns exactly one, plus the one inline check. Applying it to move/flag would narrow
///     the CLI BELOW the oracle, which fails strict-superset in the opposite direction.
///  2. **It bounds the INPUT ID COUNT, not the resolved match set.** The oracle's tools only ever
///     take an explicit `message_ids` list; `--match` is a CLI superset with no oracle counterpart,
///     so capping it would be a CLI-only restriction (bucket 3), not this mirrored gate. The
///     `--match` path keeps its own `--all` whole-mailbox gate instead.
let bulkOperationCap = 100

/// Enforce the oracle's bulk cap. Called by `mark` and `delete` ONLY, and deliberately BEFORE
/// `MailContext()` is constructed: `MailContext.init` opens the Envelope Index and throws
/// `upstream` (exit 69) on a machine with no configured Mail account, so a cap check placed after
/// it is unreachable in CI and untestable without Full Disk Access. Validating first also matches
/// the oracle, which runs `validate_bulk_operation` before touching Mail, and avoids opening the
/// index merely to refuse. (Review-caught: the first cut checked inside `resolveTargets`, one line
/// after `MailContext()`, and shipped a bats test whose comment claimed the opposite.)
///
/// The per-verb wording is the oracle's own, and it differs by op: `mark_as_read` refuses through
/// `validate_bulk_operation` ("Too many items (N), maximum is M", security.py:111) while
/// `delete_messages` uses its own inline string (server.py:1722). MCP-diff parity compares error
/// text, so the two are not unified here.
func enforceBulkCap(_ ids: [String], verb: String) throws {
    guard ids.count > bulkOperationCap else { return }
    switch verb {
    case "delete":
        throw AppleError.validation(
            "Cannot delete \(ids.count) messages at once (max: \(bulkOperationCap))")
    default:
        throw AppleError.validation(
            "Too many items (\(ids.count)), maximum is \(bulkOperationCap)")
    }
}

func resolveTargets(ctx: MailContext, ids: [String], match: MatchOptions, account: String?,
                    mailbox: String) throws -> (messages: [MailMessage], filterBased: Bool) {
    // A blank --match-sender or --match-subject would slip past the filter machinery while
    // contributing NO WHERE predicate (EnvelopeIndex drops empty entries) — or, whitespace-only,
    // bind a `% %` LIKE that nearly every subject matches — silently widening a targeted
    // mutation toward a whole-mailbox sweep whenever another filter (or --all) keeps the gate
    // satisfied. Refuse loud, in both modes (review-caught, in two rounds: sender first, then
    // its subject twin).
    if let s = match.matchSender, s.trimmingCharacters(in: .whitespaces).isEmpty {
        throw AppleError.validation("--match-sender must not be empty or whitespace; an empty value matches every message in the mailbox (use --all for a deliberate whole-mailbox sweep).")
    }
    if match.matchSubject.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
        throw AppleError.validation("--match-subject must not be empty or whitespace; an empty keyword contributes no filter and a whitespace-only one matches nearly every subject (use --all for a deliberate whole-mailbox sweep).")
    }
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
    // EXPLICIT, and load-bearing: bulk mutation scope keeps the INCLUSIVE meaning of "All".
    // `delete --permanent` resolves its mailbox to "All" and its targets are BY DEFINITION in
    // Trash, so excluding system folders here would silently make it match nothing. `search`
    // defaults to EXCLUDING them for MCP B parity, so the two surfaces genuinely differ — the
    // BulkPreview note below discloses that, because `search` is what an operator previews a
    // mutation with. Relying on the struct's default here would make a future default flip
    // silently break the irreversible path.
    f.includeSystemFolders = true
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

/// Scope warning for a FILTER-BASED bulk mutation. Two cases warrant one:
///
/// 1. Scope "All" means something WIDER here than what `search --mailbox All` shows. `search`
///    excludes MCP B's SKIP_FOLDERS by default; bulk mutation deliberately does not
///    (`delete --permanent` must reach Trash). An operator who previews with `search` and then
///    runs the mutation would otherwise be surprised by the extra targets — on this store the
///    two differ by ~1.6k messages.
/// 2. The scope IS a system mailbox. Drafts is the sharp edge: its entries are UNSENT composes,
///    so moving one out of Drafts removes it from Mail's compose surface. That is a different
///    kind of operation from re-filing a received message and deserves saying out loud, even
///    though it is not a divergence from `search`.
///
/// Returns nil for an ordinary named mailbox — and callers MUST pass nil on the explicit-ids
/// path, where `resolveTargets` never consults the mailbox at all (see the call sites): a note
/// describing a sweep that did not happen contradicts `filter_based: false` in the same envelope.
func mailboxScopeNote(_ mailbox: String) -> String? {
    if EnvelopeIndex.isAllWildcard(mailbox) {
        return "scope note: \"All\" here INCLUDES Trash/Junk/Sent/Drafts/Spam, unlike `search --mailbox All`, which excludes them by default. Preview with the same --account/--match filters plus `--mailbox All --include-system-folders` to see the set this covers."
    }
    if Analytics.isSkippedSystemFolder(mailbox) {
        let extra = Analytics.isDraftsMailbox(mailbox)
            ? " Drafts entries are UNSENT composes — moving one out of Drafts removes it from Mail's compose surface."
            : ""
        return "scope note: this targets the system mailbox '\(mailbox)', which `search --mailbox All` excludes by default, so an All-scoped preview would not have shown these.\(extra)"
    }
    return nil
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
    /// Set when the bulk scope is "All", stating that it is WIDER than `search --mailbox All`.
    /// Emitted on every bulk envelope so the difference is visible in the machine contract, not
    /// only in prose the operator may not read.
    var scope_note: String? = nil
    /// `delete --permanent` only: ids that WERE found in trash but survived the erase, because
    /// Mail's AppleScript cannot expunge on this account type. Machine-readable so a caller can
    /// distinguish "couldn't find it" from "found it and could not erase it" without parsing prose.
    var expunge_unsupported: [String]? = nil
}

struct MoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "move", abstract: "Move messages by id or --match to a mailbox (EXECUTES by default; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var match: MatchOptions
    @Argument(help: "Message ids (or use --match).") var ids: [String] = []
    @Option(name: .long, help: "Destination mailbox (use '/' for nested).") var to: String
    @Option(name: .long, help: "Source account (name or UUID).") var account: String?
    @Option(name: .long, help: "Source mailbox (default INBOX).") var source: String = "INBOX"
    @Flag(name: .long, help: "Gmail label-move handling (copy + delete).") var gmailMode = false

    func run() throws {
        try runGuarded(tool: "mail") {
            // Write-model v2 preamble (docs/write-model-v2.md): bind both decisions once.
            try TestMode.validateWriteEnvironment()
            let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
            let willExecute = try global.willExecute(defaultDryRun: false)

            let ctx = try MailContext()
            let (msgs, filterBased) = try resolveTargets(ctx: ctx, ids: ids, match: match, account: account, mailbox: source)
            let scopeNote = filterBased ? mailboxScopeNote(source) : nil
            let detail = ["to": to, "gmail_mode": String(gmailMode)]
            guard willExecute else {
                try previewValidateSandboxTargets(msgs, sandboxActive: sandboxActive)
                try Output.emit(tool: "mail", data: BulkPreview(action: "move", matched: msgs.count, filter_based: filterBased,
                    dry_run: true, executed: false, messages: msgs, detail: detail, note: nil, applied: nil, not_found: nil, scope_note: scopeNote), sandboxActive: sandboxActive); return
            }
            // --gmail-mode routes to gmailMove (Gmail copy+delete label semantics: duplicate to the
            // destination, then delete the original to Trash); plain move otherwise. BOTH go through
            // the SAME executeMessageMutation gate (per-message subject-label check when the sandbox
            // is active, all-or-nothing) — gmail-mode weakens no safety gate, and its `delete` is a
            // recoverable move-to-Trash, the same reversible class as the plain `delete` command.
            let script = MailScript()
            let (applied, notFound) = try executeMessageMutation(msgs, sandboxActive: sandboxActive) { imid, acct in
                if gmailMode {
                    return try script.gmailMove(internetMessageID: imid, accountName: acct, toMailbox: to)
                }
                return try script.move(internetMessageID: imid, accountName: acct, toMailbox: to)
            }
            try Output.emit(tool: "mail", data: BulkPreview(action: "move", matched: msgs.count, filter_based: filterBased,
                dry_run: false, executed: true, messages: msgs, detail: detail, note: notLocatedNote(notFound), applied: applied, not_found: notFound, scope_note: scopeNote), sandboxActive: sandboxActive)
        }
    }
}

struct MarkCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mark", abstract: "Mark messages read/unread by id or --match (EXECUTES by default; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var match: MatchOptions
    @Argument var ids: [String] = []
    @Option(name: .long) var account: String?
    @Option(name: .long) var mailbox: String = "INBOX"
    @Flag(name: .long) var read = false
    @Flag(name: .long) var unread = false

    func run() throws {
        try runGuarded(tool: "mail") {
            // Write-model v2 preamble.
            try TestMode.validateWriteEnvironment()
            let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
            let willExecute = try global.willExecute(defaultDryRun: false)

            let target = try triState(read, unread, "read", "unread")
            guard let markRead = target else { throw AppleError.validation("specify --read or --unread.") }
            try enforceBulkCap(ids, verb: "mark")   // BEFORE MailContext() — see enforceBulkCap
            let ctx = try MailContext()
            let (msgs, filterBased) = try resolveTargets(ctx: ctx, ids: ids, match: match, account: account, mailbox: mailbox)
            let scopeNote = filterBased ? mailboxScopeNote(mailbox) : nil
            let action = markRead ? "mark_read" : "mark_unread"
            guard willExecute else {
                try previewValidateSandboxTargets(msgs, sandboxActive: sandboxActive)
                try Output.emit(tool: "mail", data: BulkPreview(action: action, matched: msgs.count, filter_based: filterBased,
                    dry_run: true, executed: false, messages: msgs, detail: [:], note: nil,
                    applied: nil, not_found: nil, scope_note: scopeNote), sandboxActive: sandboxActive); return
            }
            let script = MailScript()
            let (applied, notFound) = try executeMessageMutation(msgs, sandboxActive: sandboxActive) { imid, acct in
                try script.setRead(internetMessageID: imid, accountName: acct, read: markRead)
            }
            try Output.emit(tool: "mail", data: BulkPreview(action: action, matched: msgs.count, filter_based: filterBased,
                dry_run: false, executed: true, messages: msgs, detail: [:], note: notLocatedNote(notFound), applied: applied, not_found: notFound, scope_note: scopeNote), sandboxActive: sandboxActive)
        }
    }
}

struct FlagCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "flag", abstract: "Flag/unflag messages by id or --match, with optional color (EXECUTES by default; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var match: MatchOptions
    @Argument var ids: [String] = []
    @Option(name: .long) var account: String?
    @Option(name: .long) var mailbox: String = "INBOX"
    @Option(name: .long, help: "Flag color: none/orange/red/yellow/blue/green/purple/gray.") var color: String?
    @Flag(name: .long, help: "Remove the flag.") var unflag = false

    func run() throws {
        try runGuarded(tool: "mail") {
            // Write-model v2 preamble.
            try TestMode.validateWriteEnvironment()
            let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
            let willExecute = try global.willExecute(defaultDryRun: false)

            if let color, !MailFlagColor.acceptedTokens.contains(color.lowercased()) {
                throw AppleError.validation("--color must be one of \(MailFlagColor.acceptedTokens.joined(separator: "/")).")
            }
            let ctx = try MailContext()
            let (msgs, filterBased) = try resolveTargets(ctx: ctx, ids: ids, match: match, account: account, mailbox: mailbox)
            let scopeNote = filterBased ? mailboxScopeNote(mailbox) : nil
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
            guard willExecute else {
                try previewValidateSandboxTargets(msgs, sandboxActive: sandboxActive)
                try Output.emit(tool: "mail", data: BulkPreview(action: act, matched: msgs.count, filter_based: filterBased,
                    dry_run: true, executed: false, messages: msgs, detail: detail, note: nil, applied: nil, not_found: nil, scope_note: scopeNote), sandboxActive: sandboxActive); return
            }
            // clearing (--unflag or --color none) → flagged:false; otherwise flagged:true with the
            // resolved color index (red default).
            let flagged = !clearing
            let colorIndex = flagged ? (MailFlagColor.fromToken(colorName)?.rawValue) : nil
            let script = MailScript()
            let (applied, notFound) = try executeMessageMutation(msgs, sandboxActive: sandboxActive) { imid, acct in
                try script.setFlag(internetMessageID: imid, accountName: acct, flagged: flagged, colorIndex: colorIndex)
            }
            try Output.emit(tool: "mail", data: BulkPreview(action: act, matched: msgs.count, filter_based: filterBased,
                dry_run: false, executed: true, messages: msgs, detail: detail, note: notLocatedNote(notFound), applied: applied, not_found: notFound, scope_note: scopeNote), sandboxActive: sandboxActive)
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
    @Flag(name: .long, help: "IRREVERSIBLE: permanently erase messages that are ALREADY in trash (needs the operator-only APPLE_ALLOW_PERMANENT_DELETE env var — 1/true/yes; targets must carry the canonical apple-cli-test label).") var permanent = false

    /// Operator-only second factor for the irreversible erase — see the gate in `run()`.
    static let operatorEnvVar = "APPLE_ALLOW_PERMANENT_DELETE"

    /// TRASH SURFACE default (write-model v2 per-surface table): dry-run stays the DEFAULT —
    /// oracle B's manage_trash defaults dry_run=True, so keeping it IS parity. Static so the
    /// logic tier can PIN it: flipping this to false would make a flagless delete trash real
    /// mail by default, the spec's named worst-case divergence.
    static let surfaceDefaultDryRun = true

    func run() throws {
        try runGuarded(tool: "mail") {
            // Write-model v2 preamble (see surfaceDefaultDryRun above for the trash carve-out).
            try TestMode.validateWriteEnvironment()
            let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
            let willExecute = try global.willExecute(defaultDryRun: DeleteCommand.surfaceDefaultDryRun)
            // Bound ONCE, pre-store, for BOTH paths: the execute gate reads it below, and the
            // --permanent preview's disclosure note reads it too — a junk value is a clean
            // store-independent 64 on either path (review-caught: the preview read it after
            // MailContext, so junk env surfaced as a store error on index-less machines).
            // Scoped to `permanent`: this var gates ONLY the irreversible path, so a stray
            // `APPLE_ALLOW_PERMANENT_DELETE=0` in a shell profile must not 64 a delete-to-trash
            // that never consults it (review-caught).
            let operatorAllowed = permanent ? try TestMode.truthyEnv(DeleteCommand.operatorEnvVar) : false
            // A blank --account must not silently mean "every account" on the irreversible
            // surface (omitting the flag is the documented all-accounts spelling).
            if let account, account.trimmingCharacters(in: .whitespaces).isEmpty {
                throw AppleError.validation("--account must not be empty or whitespace (omit it to search every account).")
            }

            // Gates for the irreversible path UP FRONT, before resolving any targets. The
            // per-target label gate below only fires when there IS a target, so a filter that
            // happens to match nothing would otherwise let `--permanent --execute` exit 0
            // ungated — a confusing near-miss on a destructive command. These gates are
            // UNCONDITIONAL (not sandbox-scoped): there is no oracle contract to defer to
            // (oracle A's permanent=True is a documented no-op), and the operator env var is
            // an affordance an agent cannot self-grant.
            if permanent && willExecute {
                // The subject label must NEVER be the SOLE gate on an irreversible op (see the
                // invariant on requireLiveMessageMutation): a subject is spoofable — anyone can
                // mail the operator a message titled "apple-cli-test …" — so on its own it would
                // let a third party nominate real mail for erasure. Require an operator-only env
                // var as an independent second factor, exactly as `trash empty` does. Parsed
                // fail-loud through the shared truthy helper (a typo'd value refuses, 64).
                guard operatorAllowed else {
                    throw AppleError.mailSafety("permanent delete is IRREVERSIBLE and its subject label is spoofable, so the label alone does not authorize it — refused. An operator must set \(DeleteCommand.operatorEnvVar) (1/true/yes) to allow it.")
                }
            }
            let script = MailScript()
            // Resolve the account's trash mailboxes BEFORE target resolution, because for
            // `--permanent` they determine BOTH where we search and where we may erase. On the
            // execute path this is a hard failure (see below); on a dry-run it is best-effort so
            // the preview still renders without Mail.
            var trashBoxes: [MailScript.TrashMailbox] = []
            if permanent {
                if willExecute {
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
            try enforceBulkCap(ids, verb: "delete")   // BEFORE MailContext() — see enforceBulkCap
            let ctx = try MailContext()
            let (msgs, filterBased) = try resolveTargets(ctx: ctx, ids: ids, match: match, account: account, mailbox: effectiveMailbox)
            let scopeNote = filterBased ? mailboxScopeNote(effectiveMailbox) : nil
            if permanent && willExecute {
                // Re-check the label against the CANONICAL prefix (ignoring any APPLE_TEST_SANDBOX
                // override) so widening that env var cannot widen what an erase may touch.
                // UNCONDITIONAL — the sandbox does not scope this; an erase only ever touches
                // canonically-labeled test items, period (docs/write-model-v2.md table row).
                try requireCanonicalLabels(msgs)
            }
            let action = permanent ? "delete_permanent" : "delete_to_trash"
            let detail = ["permanent": String(permanent)]
            // The permanent-delete PREVIEW must disclose every execute-side gate (preview
            // honesty; a sanctioned divergence documented in the CHANGELOG): the preview stays
            // renderable without the operator env var — that is what a preview is FOR on this
            // surface (oracle B's dry_run=True previews ungated) — but it names each unmet
            // requirement instead of presenting the plan as authorized (review-caught).
            var previewNote: String?
            if permanent {
                var parts = ["IRREVERSIBLE: --permanent erases messages that are ALREADY in Trash; a message still in a normal mailbox is skipped (trash it first)."]
                if !operatorAllowed {
                    parts.append("--execute will REFUSE until the operator sets \(DeleteCommand.operatorEnvVar) (1/true/yes).")
                }
                let unlabeled = msgs.filter { !$0.subject.hasPrefix(TestMode.canonicalSandboxPrefix) }.count
                if unlabeled > 0 {
                    parts.append("\(unlabeled) of \(msgs.count) matched message(s) lack the canonical \"\(TestMode.canonicalSandboxPrefix)\" label — --execute will REFUSE this set (a permanent delete only ever erases canonically-labeled test items).")
                }
                previewNote = parts.joined(separator: " ")
            }
            guard willExecute else {
                // Non-permanent (delete-to-trash) previews take the same sandbox label parity
                // as move/mark/flag. The --permanent preview instead DISCLOSES its unmet gates
                // in previewNote (the documented sanctioned divergence) so the plan stays
                // renderable, matching oracle B's ungated dry_run=True.
                if !permanent { try previewValidateSandboxTargets(msgs, sandboxActive: sandboxActive) }
                try Output.emit(tool: "mail", data: BulkPreview(action: action, matched: msgs.count, filter_based: filterBased,
                    dry_run: true, executed: false, messages: msgs, detail: detail, note: previewNote, applied: nil, not_found: nil, scope_note: scopeNote), sandboxActive: sandboxActive); return
            }
            // Both paths run through executeMessageMutation (all-or-nothing; sandbox-scoped label
            // gate) — and for --permanent the UNCONDITIONAL requireCanonicalLabels above already
            // validated EVERY target against the canonical `apple-cli-test` prefix in both modes,
            // so a permanent delete can only ever erase canonically-labeled test messages. The
            // permanent path is additionally scoped to Trash inside the AppleScript, so a message
            // that has not been trashed yet is a no-op rather than an erase.
            // Tracks targets that WERE in trash but survived the erase — Mail cannot expunge them
            // from AppleScript on this account type. Reported separately so a no-op is never
            // dressed up as a success.
            var unsupportedIMIDs = Set<String>()
            let (applied, notFound) = try executeMessageMutation(msgs, sandboxActive: sandboxActive) { imid, acct in
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
                note: note, applied: applied, not_found: notFound, scope_note: scopeNote,
                expunge_unsupported: unsupported.isEmpty ? nil : unsupported), sandboxActive: sandboxActive)
        }
    }
}

struct TrashCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "trash", abstract: "Trash operations.", subcommands: [TrashEmpty.self])
}
struct TrashEmpty: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "empty", abstract: "Empty an account's Trash (IRREVERSIBLE; dry-run by default; operator-gated — see --confirm).")
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

    /// TRASH SURFACE default — same contract + logic-tier pin as `DeleteCommand.surfaceDefaultDryRun`.
    static let surfaceDefaultDryRun = true

    func run() throws {
        try runGuarded(tool: "mail") {
            // Write-model v2 preamble. TRASH SURFACE: dry-run stays the DEFAULT (oracle B
            // manage_trash dry_run=True); --confirm and the operator env var below are
            // UNCONDITIONAL — sandbox state never scopes them.
            try TestMode.validateWriteEnvironment()
            let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
            let willExecute = try global.willExecute(defaultDryRun: TrashEmpty.surfaceDefaultDryRun)

            guard max > 0 else { throw AppleError.validation("--max must be greater than 0.") }
            // A blank --account reaches the AppleScript account filter as "" = EVERY account —
            // an unacceptable silent widening on the most destructive surface (review-caught).
            guard !account.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw AppleError.validation("--account must not be empty or whitespace.")
            }
            // Bound pre-store like DeleteCommand's twin so a malformed operator var is the SAME
            // clean 64 on preview and execute — the two irreversible surfaces must not disagree
            // about a junk value, least of all with the more destructive one being lenient
            // (review-caught: this read used to sit inside the willExecute branch).
            let operatorAllowed = try TestMode.truthyEnv(TrashEmpty.operatorEnvVar)
            let script = MailScript()
            // Enumerating trash mailboxes is a pure READ. It is best-effort ONLY on the preview
            // path (so a dry-run still renders, and stays CI-runnable, without Mail); on the
            // execute path a failed read MUST propagate — otherwise an unreadable account would
            // report `executed: true, erased: 0, "nothing to erase"` having never looked.
            // ORDER MATTERS: the pure safety refusals (--confirm, operator env var) run BEFORE any
            // Mail access, so a caller missing them is told exactly that rather than getting an
            // unrelated account/read error first — and so refusing costs no I/O.
            if willExecute {
                guard confirm else {
                    throw AppleError.validation("empty-trash permanently erases messages from trash — pass --confirm to proceed.")
                }
                guard operatorAllowed else {
                    throw AppleError.mailSafety("empty-trash is IRREVERSIBLE and cannot be scoped to \(TestMode.sandboxPrefix) data, so it is never executed autonomously — refused. An operator must set \(TrashEmpty.operatorEnvVar) (1/true/yes) to allow it.")
                }
            }
            var boxes: [MailScript.TrashMailbox] = []
            if willExecute {
                let all = try script.allMailboxes(accountName: account)
                // An unknown account matches no mailbox — that must not read as "nothing to erase".
                guard !all.isEmpty else {
                    throw AppleError.notFound("no mailboxes found for account '\(account)' — check --account.")
                }
                boxes = all.filter { MailScript.isTrashMailboxName($0.name) }
            } else {
                boxes = (try? script.trashMailboxes(accountName: account)) ?? []
            }
            guard willExecute else {
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
                    "note": AnyEncodableBox("IRREVERSIBLE. To execute: --execute --confirm with \(TrashEmpty.operatorEnvVar) (1/true/yes) set. Emptying trash cannot be scoped to \(TestMode.sandboxPrefix) data, so it is never run autonomously.")],
                    sandboxActive: sandboxActive)
                return
            }
            guard let target = try MailScript.resolveTrashMailbox(boxes, explicit: trashMailbox) else {
                try Output.emit(tool: "mail", data: [
                    "action": AnyEncodableBox("empty_trash"), "account": AnyEncodableBox(account),
                    "erased": AnyEncodableBox(0), "in_trash_before": AnyEncodableBox(0),
                    "dry_run": AnyEncodableBox(false), "executed": AnyEncodableBox(true),
                    "note": AnyEncodableBox("nothing to erase — no non-empty trash mailbox on this account")],
                    sandboxActive: sandboxActive)
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
                "note": AnyEncodableBox(emptyNote)], sandboxActive: sandboxActive)
        }
    }
}

struct AttachmentsSave: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "save", abstract: "Save attachments from a message to a directory or an exact path (EXECUTES by default; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Message id (ROWID / RFC Message-ID); or use --subject.") var id: String?
    @Option(name: .long, help: "Subject keyword to find the message.") var subject: String?
    @Option(name: .long) var account: String?
    @Option(name: .long, help: "Destination directory for multiple attachments (mutually exclusive with --out).") var dir: String?
    @Option(name: .long, help: "Exact destination file path — rename-on-save; requires exactly one selected attachment (mutually exclusive with --dir).") var out: String?
    @Option(name: .long, help: "0-based attachment indices to save (comma-separated); default all. Mutually exclusive with --name.") var indices: String?
    @Option(name: .long, help: "Save only the attachment with this name. Mutually exclusive with --indices.") var name: String?
    @Flag(name: .long, help: "Allow a destination outside $HOME (e.g. /tmp, /Volumes/...). Oracle A's save_attachments has no confinement, so this restores that reach. Credential directories (~/.ssh, ~/.aws, ...) stay blocked either way.") var allowOutsideHome = false

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
        /// Oracle A `save_attachments` returns a `saved` COUNT (server.py:1379-1383); the CLI
        /// carried only the path list. Additive, --execute only (null on dry-run).
        let saved: Int?
        let saved_paths: [String]?
        let not_saved: [String]?
    }

    func run() throws {
        try runGuarded(tool: "mail") {
            // Write-model v2 preamble. attachments save EXECUTES by default (oracle A
            // save_attachments writes to disk on call); path confinement above the dry-run
            // gate is bucket 1 and unchanged.
            try TestMode.validateWriteEnvironment()
            let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
            let willExecute = try global.willExecute(defaultDryRun: false)

            // Validate args BEFORE opening the index, so usage errors are store-independent.
            guard id != nil || subject != nil else {
                throw AppleError.validation("provide a message id argument or --subject.")
            }
            // An empty keyword would match the newest message in the store (EnvelopeIndex skips
            // an empty subjectContains) — refuse in both modes (review-caught, same class as
            // the reply/forward/draft empty-subject guards).
            if let subject, subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AppleError.validation("--subject must not be empty or whitespace; an empty keyword matches every message in the store.")
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
            // CONFINE FIRST. Both oracles refuse an out-of-home or credential-directory
            // destination before touching Mail (patrickfreyer manage.py:197-220); this command
            // `--out ~/.ssh/authorized_keys --execute` would have overwritten an SSH key with
            // attachment bytes. Exit 77, not 64: a refused write is a safety violation.
            let absDir = try dir.map { normalize(try confineWriteDestination($0, action: "save attachments into", allowOutsideHome: allowOutsideHome).path) }
            let absOut = try out.map { normalize(try confineWriteDestination($0, action: "save an attachment to", allowOutsideHome: allowOutsideHome).path) }

            // VALIDATE BEFORE PREVIEWING. These checks used to sit after the dry-run guard, so a
            // preview happily reported a destination that --execute would reject — the same
            // preview-honesty rule `trash empty` already follows by re-throwing resolution errors
            // on its dry-run path.
            if let absDir {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: absDir, isDirectory: &isDir) else {
                    throw AppleError.validation("destination directory does not exist: \(absDir)")
                }
                guard isDir.boolValue else {
                    throw AppleError.validation("destination path is not a directory: \(absDir)")
                }
            }
            if let absOut {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: absOut, isDirectory: &isDir), isDir.boolValue {
                    throw AppleError.validation("--out path is a directory, not a file: \(absOut)")
                }
            }

            guard willExecute else {
                try Output.emit(tool: "mail", data: Result(message_id: String(rowid), directory: absDir, out_path: absOut,
                    attachments: selectedNames, dry_run: true, note: nil, saved: nil, saved_paths: nil, not_saved: nil), sandboxActive: sandboxActive); return
            }

            // Live export: extract existing attachment bytes to disk. This is a READ/EXPORT
            // (nothing in Mail is mutated), so it gates on --execute ONLY — no --test-mode/label
            // gate like the write commands.
            var pairs: [(index: Int, destPath: String)] = []
            var notSavedIdx: Set<Int> = []

            if let absDir {
                // Existence / is-a-directory already validated above the dry-run guard so the
                // preview and --execute refuse identically.
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
                // when it already resolves to a directory (can't save a file's bytes onto a dir).
                // is-a-directory already validated above the dry-run guard.
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
                attachments: selectedNames, dry_run: false, note: note, saved: savedPaths.count, saved_paths: savedPaths,
                not_saved: notSaved.isEmpty ? nil : notSaved), sandboxActive: sandboxActive)
        }
    }
}

/// `mailboxes create` — lives under the existing `mailboxes` parent (registered there).
struct MailboxesCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a mailbox/folder (EXECUTES by default; --dry-run previews; nested via '/').")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long) var account: String
    @Option(name: .long, help: "Mailbox name (may contain '/' for a nested path).") var name: String
    @Option(name: .long, help: "Optional parent mailbox for nesting.") var parent: String?

    func run() throws {
        try runGuarded(tool: "mail") {
            // Write-model v2 preamble.
            try TestMode.validateWriteEnvironment()
            let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
            let willExecute = try global.willExecute(defaultDryRun: false)

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
            // Sandbox restriction (bucket 3): inside the sandbox the new folder's name must
            // be a labeled test item, so agent runs only create cleanable folders. Outside
            // it, creation is unrestricted (oracle create_mailbox creates on call). BOTH modes
            // (preview honesty) and BEFORE the store opens (store-independent): the check
            // needs only `name` (review-caught: it sat inside willExecute, so a sandboxed
            // dry-run previewed clean for a name --execute refuses 77).
            if sandboxActive, !name.hasPrefix(TestMode.sandboxPrefix) {
                throw AppleError.mailSafety("sandbox active: mailbox name '\(name)' is not a labeled test item (must start with \"\(TestMode.sandboxPrefix)\") — refusing.")
            }
            let ctx = try MailContext()
            let uuid = try ctx.requireAccountUUID(account)
            let fullPath = parent.map { "\($0)/\(name)" } ?? name
            var executed = false
            let note: String? = nil
            if willExecute {
                try MailScript().createMailbox(accountName: account, path: fullPath)
                executed = true
            }
            // `mailbox` + `parent` are oracle A create_mailbox's wire keys. `path` (the joined
            // form) is the CLI's original key and is kept, but it alone is LOSSY: when `name`
            // itself contains a '/', the name-vs-parent boundary cannot be recovered from it.
            try Output.emit(tool: "mail", data: ["action": AnyEncodableBox("create_mailbox"), "account": AnyEncodableBox(account),
                "account_id": AnyEncodableBox(uuid), "path": AnyEncodableBox(fullPath),
                "mailbox": AnyEncodableBox(name), "parent": AnyEncodableBox(parent),
                "dry_run": AnyEncodableBox(!willExecute),
                "executed": AnyEncodableBox(executed), "note": AnyEncodableBox(note)], sandboxActive: sandboxActive)
        }
    }
}
