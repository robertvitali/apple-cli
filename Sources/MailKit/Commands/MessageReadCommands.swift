import Foundation
import ArgumentParser
import AppleKit

// P1 message reads: search, list, get, selected, thread, attachments list.


/// gap2 pure core (pinned; reviews H2/H3/B2): the live body-search paging arithmetic.
/// The oracle collects offset+limit+1 matches in scan order (`collectLimit = limit + 1` plus
/// `offsetRemaining`, search.py:393-421 — the +1 is its has_more probe), then SORTS the
/// collected window and slices `[:limit]` (`_build_search_response`, search.py:146-149).
/// Everything here SATURATES: operator-sized --offset/--limit must never overflow-trap (no
/// envelope, signal exit), and the value handed to AppleScript must stay within its 32-bit
/// integer range, so every collect bound is capped at `scanCap`.
enum LiveBodyPage {
    /// Also the ceiling a `--limit 0` (all) scan collects before reporting has_more.
    static let scanCap = 1_000_000

    static func collectLimit(offset: Int, limit: Int) -> Int {
        guard limit > 0 else { return scanCap }
        let (sum, overflow) = offset.addingReportingOverflow(limit)
        if overflow || sum >= scanCap { return scanCap }
        return sum + 1
    }

    /// Page verdict AFTER the whole post-offset window was resolved and sorted. `resolved` =
    /// rows that mapped into scope; `unindexed` = skipped scan slots (no index row /
    /// out-of-scope). has_more mirrors the oracle's probe (`len(sorted) > limit`) plus the
    /// truncated-scan signal; the cursor advances by the oracle's client contract
    /// (offset+limit) PLUS the skipped slots, so a skipped id never repeats a row on the
    /// next page (review H3) and a truncated scan is never reported complete.
    static func page(resolved: Int, unindexed: Int, offset: Int, limit: Int,
                     totalIDs: Int, collectLimit: Int) -> (hasMore: Bool, nextOffset: Int?) {
        let truncated = totalIDs >= collectLimit
        let more: Bool
        let advance: Int
        if limit == 0 {
            more = truncated
            advance = resolved + unindexed
        } else {
            more = truncated || resolved + unindexed > limit
            advance = limit + unindexed
        }
        guard more else { return (false, nil) }
        let (next, overflow) = offset.addingReportingOverflow(advance)
        return (true, overflow ? nil : next)
    }
}

// MARK: search

struct SearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "search", abstract: "Search messages (subject/sender/body/date/read/flagged/attachment; paginated).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Account name or UUID; omit to search all accounts.") var account: String?
    @Option(name: .long, help: "Mailbox name (default INBOX; use 'All' for every mailbox).") var mailbox: String = "INBOX"
    @Option(name: .long, help: "Substring match on subject (repeatable — matches ANY, MCP B subject_keywords).") var subject: [String] = []
    @Option(name: .long, help: "Substring match on sender name/email.") var sender: String?
    @Option(name: .long, help: "Substring match on the message body. Default: fast match on the indexed body preview (CLI extra — Mail caches previews for only some messages). Add --body-live for oracle B's semantics: a live Mail.app scan of the FULL content of every candidate message (slow; per-Apple-event 180s timeout only — there is NO overall deadline, so a broad sweep can hold Mail busy for a long time; bound it with --limit/--mailbox).") var body: String?
    @Flag(name: .long, help: "With --body: scan live full message content via Mail.app (oracle B body_text semantics) instead of the indexed preview. The collected window is sorted per --sort and sliced, exactly as the oracle's response builder does.") var bodyLive = false
    @Option(name: .long, help: "Lower bound on date received (YYYY-MM-DD).") var fromDate: String?
    @Option(name: .long, help: "Upper bound on date received (YYYY-MM-DD, inclusive).") var toDate: String?
    @Flag(name: .long, help: "Only read messages.") var read = false
    @Flag(name: .long, help: "Only unread messages.") var unread = false
    @Flag(name: .long, help: "Only flagged messages.") var flagged = false
    @Flag(name: .long, help: "Only unflagged messages.") var unflagged = false
    @Flag(name: .long, help: "Only messages with attachments.") var hasAttachment = false
    @Flag(name: .long, help: "Only messages without attachments.") var noAttachment = false
    @Option(name: .long, help: "Max results per page (default 50; 0 = all).") var limit: Int = 50
    @Option(name: .long, help: "Results to skip (pagination).") var offset: Int = 0
    @Option(name: .long, help: "Sort order: date_desc (default) or date_asc.") var sort: String = "date_desc"
    @Flag(name: .long, inversion: .prefixedNo, help: "Include the indexed body preview (default on).") var content = true
    @Option(name: .long, help: "Truncate each included body preview to N chars (0 = unlimited; MCP B max_content_length).") var maxContentLength: Int?
    @Flag(name: .long, help: "With --mailbox All, also sweep the system mailboxes MCP B skips. Excluded by leaf name: Trash, Junk, Junk Email, Deleted Items, Deleted Messages, Sent, Sent Items, Sent Messages, Drafts, Spam. Provider-specific names outside that list (notably Gmail's '[Gmail]/Sent Mail' and '[Gmail]/All Mail') are NOT excluded.") var includeSystemFolders = false

    func run() throws {
        try runGuarded(tool: "mail") {
            if let maxContentLength, maxContentLength < 0 {
                throw AppleError.validation("--max-content-length must be >= 0 (0 = unlimited).")
            }
            // Sibling validations (--sort, --max-content-length, triState) all fail loud; a
            // negative --offset was the one input silently clamped (to 0 in EnvelopeIndex) and
            // then echoed back VERBATIM — the envelope claimed an offset the query never used.
            guard offset >= 0 else {
                throw AppleError.validation("--offset must be >= 0.")
            }
            // A negative --limit was clamped to `LIMIT 0` at the query boundary and returned
            // an EMPTY SUCCESS while echoing the negative value back — indistinguishable from
            // an empty store (git-verified against the base commit; review H3 corrected the
            // first draft's claim that it reached SQLite as unlimited `LIMIT -n`).
            guard limit >= 0 else {
                throw AppleError.validation("--limit must be >= 0 (0 = all).")
            }
            // Pure --body-live usage checks, hoisted above the store open (store-independent
            // usage errors — the export command's established convention; review L1).
            if bodyLive {
                guard let body, !body.isEmpty else {
                    throw AppleError.validation("--body-live requires a non-empty --body needle.")
                }
                // Security L1: a C0 control character (notably the RS/US wire delimiters) in a
                // live-path needle would re-split inside the AppleScript argv protocol —
                // refuse instead of silently altering match semantics.
                for (label, value) in [("--body", body), ("--sender", sender ?? "")] + subject.map({ ("--subject", $0) }) {
                    if value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                        throw AppleError.validation("\(label) must not contain control characters on the --body-live path.")
                    }
                }
            }
            let ctx = try MailContext()
            var f = EnvelopeIndex.MessageFilters()
            if let account { f.accountUUID = try ctx.requireAccountUUID(account) }
            f.mailboxName = mailbox
            // Unknown mailbox was an empty SUCCESS (mailboxPredicate resolves to `0`),
            // indistinguishable from a genuinely empty mailbox — while the unknown-ACCOUNT path
            // throws not_found. Oracle A's `mailbox "X" of account` errors on an unknown name.
            try requireMailboxKnown(ctx: ctx, name: mailbox, accountUUID: f.accountUUID)
            // MCP B excludes SKIP_FOLDERS from a broad "All" sweep, so an All-search used to
            // return Trash/Sent/Junk hits the oracle never would. Naming a system mailbox
            // explicitly still searches it — the exclusion only changes what "All" means.
            f.includeSystemFolders = includeSystemFolders
            f.subjectContainsAny = subject
            f.senderContains = sender
            f.bodyContains = body
            f.readStatus = try triState(read, unread, "read", "unread")
            f.flagged = try triState(flagged, unflagged, "flagged", "unflagged")
            f.hasAttachment = try triState(hasAttachment, noAttachment, "has-attachment", "no-attachment")
            if let fromDate { f.dateFromUnix = try requireISODate(fromDate, name: "from-date") }
            if let toDate { f.dateToUnix = try requireISODate(toDate, name: "to-date", endOfDay: true) }
            // Oracle B validates `sort` against {date_desc, date_asc} and raises
            // "Invalid sort. Use: date_desc, date_asc" (tools/search.py). Accepting anything and
            // silently falling back to date_desc — while echoing the bogus token back in the
            // envelope's `sort` field — told the caller their sort was honoured when it wasn't.
            guard sort == "date_desc" || sort == "date_asc" else {
                throw AppleError.validation("invalid --sort '\(sort)'. Use: date_desc, date_asc.")
            }
            f.sortAscending = (sort == "date_asc")
            f.limit = (limit == 0) ? Int.max : limit
            f.offset = offset

            // gap2: oracle B's live body search. ONE AppleScript pass applies the FULL
            // condition set per message in-loop (with the oracle's early exit) and returns RFC
            // Message-IDs in scan order; the index then supplies the JSON rows. The default
            // --body path (indexed preview) stays the fast CLI extra, disclosed in --help.
            if bodyLive {
                let body = body ?? ""   // non-empty: validated above the store open
                // Review H1: the script's `whose name is` filter is LEAF-ONLY (flattened),
                // so a FULL nested path — which requireMailboxKnown accepts — silently
                // matched nothing and returned an empty success. Reduce a path to its leaf
                // host-side; the leaf then matches every nesting point (disclosed superset,
                // row 4).
                let scriptMailbox = EnvelopeIndex.isAllWildcard(mailbox)
                    ? "All" : (mailbox.split(separator: "/").last.map(String.init) ?? mailbox)
                // Account must be addressed by DISPLAY NAME in AppleScript; requireAccountUUID
                // already validated the selector above. A raw UUID validated against the
                // index but unknown to the directory has NO name Mail.app can match — that
                // would be a silent empty result, so refuse it loudly instead.
                var acctDisplay: String? = nil
                if let account {
                    guard let d = ctx.accounts().displayName(for: account) else {
                        throw AppleError.upstream("--body-live must address the account by its Mail display name, and '\(account)' could not be resolved to one (Mail's account directory is unavailable). Use the account NAME, or drop --body-live for the indexed path.")
                    }
                    acctDisplay = d
                }
                // The oracle consumes offset and limit IN SCAN ORDER (offsetRemaining /
                // collectLimit, search.py:393-421): collect offset+limit+1 matches, drop the
                // offset, keep limit, and the +1 leftover is the has_more signal.
                let collectLimit = LiveBodyPage.collectLimit(offset: offset, limit: limit)
                var liveIDs = try MailScript().bodySearch(
                    needle: body, subjectTerms: subject, sender: sender,
                    readStatus: f.readStatus, flagged: f.flagged,
                    fromUnix: f.dateFromUnix, toUnix: f.dateToUnix,
                    hasAttachment: f.hasAttachment,
                    accountName: acctDisplay, mailboxName: scriptMailbox,
                    collectLimit: collectLimit,
                    includeSystemFolders: includeSystemFolders)
                // Order-preserving de-dupe: a Gmail store lists the same message under INBOX
                // and [Gmail]/All Mail, and both map to ONE index row — byte-identical
                // duplicate rows silently consuming --limit (review).
                var seenIDs = Set<String>()
                liveIDs = liveIDs.filter { seenIDs.insert($0).inserted }
                // Security M4: the live path must enforce the SAME scope the indexed path
                // gets from its SQL predicate — resolveMessageRow is unscoped, so a
                // mismatched live/index view (or a forged id, defense in depth) could
                // otherwise emit rows outside the requested --account/--mailbox. The check is
                // the index's OWN resolution (direct rowids + Gmail LABEL membership): a
                // path/leaf compare on the row's home mailbox wrongly rejects every
                // label-backed hit, whose home row is `[Gmail]/All Mail`.
                let scope = EnvelopeIndex.isAllWildcard(mailbox)
                    ? nil : ctx.index.resolveMailboxes(accountUUID: f.accountUUID, mailboxName: mailbox)
                var live: [MailMessage] = []
                var unindexed = 0
                for rfcID in liveIDs.dropFirst(offset) {
                    guard let row = try resolveMessageRow(ctx: ctx, id: rfcID) else {
                        unindexed += 1; continue
                    }
                    let mbRowid = intVal(row["mailbox_rowid"]) ?? 0
                    if let wantUUID = f.accountUUID,
                       ctx.index.mailbox(forRowid: mbRowid)?.url.accountID != wantUUID {
                        unindexed += 1; continue
                    }
                    if let scope, !ctx.index.messageInScope(rowid: intVal(row["rowid"]) ?? 0,
                                                            direct: scope.direct, label: scope.label) {
                        unindexed += 1; continue
                    }
                    live.append(ctx.decodeSummary(row))
                }
                // Review B2 (the oracle SORTS in body mode): `_build_search_response`
                // sorts the collected window by received_date, then slices `[:limit]`
                // (search.py:94-101, :146-149) — on both its paths, no body-mode branch. The
                // first cut claimed "scan order, --sort not applied" from reading only the
                // collection half; measured live, the echoed sort was a lie. Sorting the ISO
                // strings is byte-what the oracle sorts (its received_date is a string too).
                let asc = (sort == "date_asc")
                live.sort {
                    let a = $0.date_received ?? "", b = $1.date_received ?? ""
                    return asc ? a < b : a > b
                }
                let resolvedCount = live.count
                if limit != 0, live.count > limit { live = Array(live.prefix(limit)) }
                if !content {
                    for i in live.indices { live[i].snippet = nil; live[i].content_preview = nil }
                } else if let cap = maxContentLength, cap > 0 {
                    // Security L2: --max-content-length was validated then ignored here.
                    for i in live.indices where (live[i].snippet?.count ?? 0) > cap {
                        let capped = String(live[i].snippet!.prefix(cap))
                        live[i].snippet = capped
                        live[i].content_preview = capped
                    }
                }
                let (more, nextOff) = LiveBodyPage.page(resolved: resolvedCount, unindexed: unindexed,
                                                        offset: offset, limit: limit,
                                                        totalIDs: liveIDs.count, collectLimit: collectLimit)
                let result = MailMessagesResult(
                    account: account, mailbox: mailbox, messages: live, count: live.count,
                    offset: offset, limit: limit, has_more: more,
                    next_offset: nextOff, sort: sort,
                    system_folders_excluded: EnvelopeIndex.isAllWildcard(mailbox) ? !includeSystemFolders : nil,
                    note: unindexed > 0 ? "\(unindexed) live match(es) were omitted (not present in the Envelope Index, or outside the requested --account/--mailbox scope)." : nil)
                try emitMessages(result, json: global.json)
                return
            }

            let rows = try ctx.index.queryMessages(f)
            var messages = rows.map { ctx.decodeSummary($0) }
            // `snippet` and `content_preview` are ONE value under two wire names (A/B dual-key
            // rule), so every mutation below must touch both — otherwise --no-content would clear
            // `snippet` and leave the same text exposed under `content_preview`.
            if !content {
                for i in messages.indices {
                    messages[i].snippet = nil
                    messages[i].content_preview = nil
                }
            }
            // MCP B max_content_length: cap each included preview (0 = unlimited → no cap).
            else if let cap = maxContentLength, cap > 0 {
                for i in messages.indices where (messages[i].snippet?.count ?? 0) > cap {
                    let capped = String(messages[i].snippet!.prefix(cap))
                    messages[i].snippet = capped
                    messages[i].content_preview = capped
                }
            }
            let total = try ctx.index.countMessages(f)
            // Empty page must NOT report has_more (else a paginating client loops on the same offset).
            let hasMore = !messages.isEmpty && (offset + messages.count < total)
            let isAllSweep = EnvelopeIndex.isAllWildcard(mailbox)
            let result = MailMessagesResult(
                account: account, mailbox: mailbox, messages: messages, count: messages.count,
                offset: offset, limit: limit, has_more: hasMore,
                next_offset: hasMore ? offset + messages.count : nil, sort: sort,
                // Disclose the narrowing: it is otherwise undetectable from the envelope, and this
                // is the surface an operator previews a bulk mutation with — see the scope note
                // BulkPreview emits for "All".
                system_folders_excluded: isAllSweep ? !includeSystemFolders : nil)
            try emitMessages(result, json: global.json)
        }
    }
}

// MARK: list (recent inbox — MCP B list_inbox_emails)

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List recent inbox messages (MCP B list_inbox_emails).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Account name or UUID; omit for all accounts.") var account: String?
    @Flag(name: .long, help: "Only unread messages.") var unread = false
    @Option(name: .long, help: "Max messages GLOBALLY (default 50; 0 = all). CLI extra — oracle B's max_emails caps per account; see --limit-per-account.") var limit: Int = 50
    @Option(name: .long, help: "Cap messages PER ACCOUNT (oracle B max_emails semantics: the cap counts inbox messages EXAMINED, so with --unread fewer rows than the cap can return; 0 = no per-account cap). Accounts are merged newest-first (the oracle groups per account — disclosed); the global --limit still applies, pass --limit 0 for all.") var limitPerAccount: Int?
    @Flag(name: .long, inversion: .prefixedNo, help: "Include the indexed body preview (default on; MCP B include_content).") var content = true

    /// gap9 pure core (pinned; review H2): the oracle's per-account window. `max_emails`
    /// counts messages EXAMINED — the newest `per` inbox rows are taken FIRST and the unread
    /// filter applies INSIDE that window, so fewer rows than the cap can return.
    static func perAccountWindow(_ rows: [[String: String?]], per: Int,
                                 unreadOnly: Bool) -> [[String: String?]] {
        let window = per == 0 ? rows : Array(rows.prefix(per))
        return unreadOnly ? window.filter { (intVal($0["read"]) ?? 0) == 0 } : window
    }

    func run() throws {
        try runGuarded(tool: "mail") {
            guard limit >= 0 else { throw AppleError.validation("--limit must be >= 0 (0 = all).") }
            if let limitPerAccount, limitPerAccount < 0 {
                throw AppleError.validation("--limit-per-account must be >= 0 (0 = no per-account cap).")
            }
            let ctx = try MailContext()
            var f = EnvelopeIndex.MessageFilters()
            if let account { f.accountUUID = try ctx.requireAccountUUID(account) }
            f.mailboxName = "INBOX"
            if unread { f.readStatus = false }
            let rows: [[String: String?]]
            if let per = limitPerAccount {
                // gap9: oracle B's max_emails caps PER ACCOUNT — and it counts inbox messages
                // EXAMINED, not returned: `currentIndex` increments BEFORE the include_read
                // filter (inbox.py:167-176), so `--unread --limit-per-account 2` means "the
                // unread among each account's 2 newest inbox messages", not "2 unread each"
                // (review H2 — the first cut pushed the read predicate into SQL and returned
                // strictly more). Window first (no read predicate in the query), filter
                // inside the window via the pinned helper.
                let uuids = f.accountUUID.map { [$0] } ?? ctx.index.accountUUIDs()
                var merged: [[String: String?]] = []
                for uuid in uuids {
                    var pf = f
                    pf.accountUUID = uuid
                    pf.readStatus = nil
                    pf.limit = (per == 0) ? Int.max : per
                    merged += ListCommand.perAccountWindow(try ctx.index.queryMessages(pf),
                                                           per: per, unreadOnly: unread)
                }
                merged.sort {
                    let a = (intVal($0["date_received"]) ?? 0, intVal($0["rowid"]) ?? 0)
                    let b = (intVal($1["date_received"]) ?? 0, intVal($1["rowid"]) ?? 0)
                    return a > b
                }
                rows = limit == 0 ? merged : Array(merged.prefix(limit))
            } else {
                f.limit = (limit == 0) ? Int.max : limit
                rows = try ctx.index.queryMessages(f)
            }
            var messages = rows.map { ctx.decodeSummary($0) }
            if !content {
                for i in messages.indices {
                    messages[i].snippet = nil
                    messages[i].content_preview = nil   // same value, second wire name
                }
            }
            let result = MailMessagesResult(
                account: account, mailbox: "INBOX", messages: messages, count: messages.count,
                offset: 0, limit: limit, has_more: nil, next_offset: nil, sort: "date_desc",
                limit_per_account: limitPerAccount)
            try emitMessages(result, json: global.json)
        }
    }
}

// MARK: get

struct GetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Get one message by ROWID, RFC Message-ID, or message:// link.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Message id (Envelope Index ROWID, RFC-5322 Message-ID, or message:// link).") var id: String
    @Option(name: .long, help: "Scope the lookup to this account (name or UUID; MCP A account param). Rejects if the message is elsewhere.") var account: String?
    @Option(name: .long, help: "Scope the lookup to this mailbox (MCP A mailbox param). Rejects if the message is elsewhere.") var mailbox: String?
    @Flag(name: .long, help: "Return headers/metadata only (skip recipients + preview).") var headersOnly = false
    @Flag(name: .long, help: "Fetch the full body via Mail.app (slow AppleScript scan; default returns the indexed preview).") var content = false
    @Flag(name: .long, help: "Alias/compat: never fetch the full body (default behavior).") var noContent = false

    func run() throws {
        try runGuarded(tool: "mail") {
            let ctx = try MailContext()
            guard let row = try resolveMessageRow(ctx: ctx, id: id) else {
                throw AppleError.notFound("no message for id '\(id)'.")
            }
            var msg = ctx.decodeSummary(row)
            // MCP A get_message account/mailbox: the CLI resolves by globally-unique id, so these
            // are SCOPING assertions — the returned message must be in that account/mailbox, else
            // not_found. Account compares canonically (name-or-UUID → UUID both sides); mailbox
            // matches the full path or its leaf component, case-insensitively.
            if let account {
                let wantUUID = try ctx.requireAccountUUID(account)
                let msgUUID = (try? ctx.requireAccountUUID(msg.account)) ?? ""
                guard wantUUID == msgUUID else {
                    throw AppleError.notFound("message '\(id)' is not in account '\(account)'.")
                }
            }
            // Same "All"-wildcard short-circuit as attachments list: asserting the CLI-wide
            // wildcard as a literal name made `--mailbox All` an unconditional not_found.
            if let mailbox, !EnvelopeIndex.isAllWildcard(mailbox) {
                let want = mailbox.lowercased()
                let path = msg.mailbox.lowercased()
                let leaf = path.split(separator: "/").last.map(String.init) ?? path
                guard path == want || leaf == want else {
                    throw AppleError.notFound("message '\(id)' is not in mailbox '\(mailbox)' (it is in '\(msg.mailbox)').")
                }
            }
            if !headersOnly {
                let rowid = intVal(row["rowid"]) ?? 0
                let recips = try ctx.index.recipients(messageRowid: rowid)
                msg.to = recips.to; msg.cc = recips.cc; msg.bcc = recips.bcc.isEmpty ? nil : recips.bcc
                msg.snippet = strVal(row["snippet"])
                msg.content_preview = msg.snippet
            } else {
                // `--headers-only` documents "skip … preview", but decodeSummary has already
                // populated both preview keys, and re-assigning `snippet` to itself above never
                // cleared them. Clear BOTH (the dual keys are one value).
                msg.snippet = nil
                msg.content_preview = nil
            }
            // Full body is opt-in: the AppleScript scan is slow (Mail has no body index,
            // mirroring MCP A's own slow-path caveat). The indexed `snippet` covers the fast case.
            if content && !noContent && !headersOnly, let internetID = msg.internet_message_id {
                msg.content = try MailScript().body(internetMessageID: internetID, accountName: msg.account)
            }
            // Oracle A ALWAYS emits the `content` key, "" when suppressed (mail_connector.py
            // msgContent) — a caller ported from A KeyErrors when the key is dropped. nil here
            // (synthesized encodeIfPresent) dropped it under the default, --no-content AND
            // --headers-only; emit the empty string instead.
            if msg.content == nil { msg.content = "" }
            let result = MailMessageResult(message: msg)
            if global.json { try Output.emit(tool: "mail", data: result) }
            else { printMessageText(msg, full: true) }
        }
    }
}

// MARK: selected (Mail UI selection)

struct SelectedCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "selected", abstract: "Get the message(s) currently selected in Mail.app.")
    @OptionGroup var global: GlobalOptions
    @Flag(name: .long, help: "Do not include body content.") var noContent = false

    func run() throws {
        try runGuarded(tool: "mail") {
            let ctx = try? MailContext()   // used to enrich from the index when possible
            let selections: [MailScript.ScriptSelection]
            do {
                selections = try MailScript().selectedMessages(includeContent: !noContent)
            } catch {
                throw AppleError.upstream("could not read Mail selection — is Mail.app running with automation permitted? (\(error))")
            }
            var messages: [MailMessage] = []
            for sel in selections {
                var m: MailMessage
                if let internetID = sel.internetMessageID, let ctx,
                   let row = try? ctx.index.message(internetMessageID: internetID) {
                    m = ctx.decodeSummary(row)
                    m.applescript_id = sel.applescriptID
                    m.content = sel.content
                    m.snippet = strVal(row["snippet"])
                } else {
                    m = MailMessage.fromSelection(sel)
                }
                if noContent {
                    // `--no-content` cleared only `content`; the same body text stayed exposed
                    // under `snippet` AND `content_preview` (one value, two wire names — the
                    // search/list siblings clear both, with a comment saying exactly that).
                    m.snippet = nil
                    m.content_preview = nil
                }
                // Oracle A always emits `content`, "" when suppressed — same key-presence
                // contract as `get` (see GetCommand).
                if m.content == nil { m.content = "" }
                messages.append(m)
            }
            let result = MailMessagesResult(
                account: nil, mailbox: nil, messages: messages, count: messages.count,
                offset: nil, limit: nil, has_more: nil, next_offset: nil, sort: nil)
            try emitMessages(result, json: global.json)
        }
    }
}

// MARK: thread

struct ThreadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "thread", abstract: "All messages in a conversation — by message id (Apple conversation) or by subject keyword.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "A message id in the thread (ROWID / RFC Message-ID / message:// link).") var id: String?
    @Option(name: .long, help: "Subject keyword identifying the thread.") var subject: String?
    @Option(name: .long, help: "Account name or UUID (for subject-based lookup).") var account: String?
    @Option(name: .long, help: "Mailbox for subject-based lookup (default All).") var mailbox: String = "All"
    @Option(name: .long, help: "Max messages. Default: by id, the COMPLETE thread (oracle A get_thread is uncapped); by --subject, 50 (oracle B max_messages). 0 = the complete thread.") var limit: Int?
    // NO --include-system-folders here, deliberately. MCP B applies SKIP_FOLDERS only in
    // `search_emails` and analytics (tools/search.py `_search_mail_records`); its
    // `get_email_thread` has NO skip script and iterates every mailbox. Excluding here was both a
    // parity DROP and wrong on its own terms: Sent/Sent Messages/Drafts hold the operator's OWN
    // half of the conversation, so a "thread" missing your replies is not the thread. It also made
    // the two addressing modes disagree — the by-id conversation branch never applied the flag, so
    // the same thread returned 10 by id and 9 by subject.
    @Flag(name: .long, help: "Thread by RFC References/In-Reply-To headers (MCP A get_thread) instead of Apple's conversation grouping.") var references = false

    func run() throws {
        try runGuarded(tool: "mail") {
            let ctx = try MailContext()
            var messages: [MailMessage] = []
            var matchedBy = ""
            var total: Int? = nil
            // Per-path defaults: the id path is UNCAPPED (oracle A's get_thread has no cap by
            // construction — the old shared default of 50 silently truncated long threads with no
            // signal); the subject path defaults to oracle B's max_messages=50. Explicit
            // `--limit 0` == the complete thread on either path, matching the `0 = all`
            // convention search/list already use (before that mapping landed, 0 reached the query
            // as a literal 0, returned nothing, and fell through to the singleton fallback).
            // A negative --limit reached SQLite as `LIMIT -n` (= unlimited) — the same
            // silently-inverted-meaning class as search's negative --offset, in the same batch.
            if let limit = self.limit, limit < 0 {
                throw AppleError.validation("--limit must be >= 0 (0 = the complete thread).")
            }
            let effectiveLimit = ThreadLimits.effective(self.limit, idPath: id != nil)
            if let id {
                guard let row = try resolveMessageRow(ctx: ctx, id: id) else {
                    throw AppleError.notFound("no message for id '\(id)'.")
                }
                let rowid = intVal(row["rowid"]) ?? 0
                if references {
                    // MCP A header-threading: messages sharing this one's References/In-Reply-To
                    // chain (via the Envelope Index message_references table), chronologically.
                    matchedBy = "references"
                    messages = try ctx.index.referencesThread(rowid: rowid, limit: effectiveLimit).map { ctx.decodeSummary($0) }
                    total = effectiveLimit == Int.max ? messages.count
                        : try ctx.index.referencesThread(rowid: rowid, limit: Int.max).count
                } else {
                    matchedBy = "message_id"
                    let convID = intVal(row["conversation_id"]) ?? 0
                    if convID != 0 {
                        // Query the whole conversation directly (Apple's own thread id), chronologically.
                        var f = EnvelopeIndex.MessageFilters()
                        f.mailboxName = "All"; f.conversationID = convID; f.sortAscending = true; f.limit = effectiveLimit
                        messages = try ctx.index.queryMessages(f).map { ctx.decodeSummary($0) }
                        total = try ctx.index.countMessages(f)
                    }
                }
                if messages.isEmpty { messages = [ctx.decodeSummary(row)]; total = 1 } // singleton thread
            } else if let subject {
                matchedBy = "subject_keyword"
                var f = EnvelopeIndex.MessageFilters()
                if let account { f.accountUUID = try ctx.requireAccountUUID(account) }
                // Oracle B strips Re:/RE:/Fwd:/FW:/Fw: from the keyword before matching, so
                // `--subject "Re: Budget"` finds the whole thread rather than only the replies.
                let cleaned = MailFormat.stripThreadPrefixes(subject)
                // A keyword that is ONLY thread prefixes strips to "" — and an empty
                // `subjectContains` makes EnvelopeIndex append no WHERE clause at all, turning a
                // thread lookup into a full-store dump reported as ok:true.
                // "Re: " is exactly what gets copy-pasted off a subject line, so refuse it.
                guard !cleaned.isEmpty else {
                    throw AppleError.validation("--subject '\(subject)' is only reply/forward prefixes; provide an actual subject keyword.")
                }
                // Unknown mailbox → not_found, same reasoning as SearchCommand (an empty success
                // is indistinguishable from a genuinely empty mailbox).
                try requireMailboxKnown(ctx: ctx, name: mailbox, accountUUID: f.accountUUID)
                f.mailboxName = mailbox; f.subjectContains = cleaned
                // EXPLICIT, same reasoning as resolveTargets: a thread must span EVERY mailbox.
                // Oracle B applies SKIP_FOLDERS in `_search_mail_records` (tools/search.py:236,
                // All-only) and analytics, but `get_email_thread` (tools/search.py:595) builds
                // its own script with no skip. Excluding here dropped the account's own Sent
                // replies out of their own conversation (measured 34 → 24 on this store). The
                // struct already defaults true, but leaving that implicit is what let the
                // regression land silently once — a future default flip must not re-break it.
                f.includeSystemFolders = true
                f.sortAscending = true; f.limit = effectiveLimit
                let rows = try ctx.index.queryMessages(f)
                messages = rows.map { ctx.decodeSummary($0) }
                total = try ctx.index.countMessages(f)
            } else {
                throw AppleError.validation("provide a message id argument or --subject keyword.")
            }
            let result = MailThreadResult(
                messages: messages, count: messages.count, matched_by: matchedBy,
                total: total, has_more: total.map { $0 > messages.count })
            if global.json { try Output.emit(tool: "mail", data: result) }
            else { for m in messages { printMessageText(m, full: false) } }
        }
    }
}

// Per-path thread limit defaults, extracted pure so the logic tier can pin the DEFAULT-change
// half of gap5 without a >50-message live thread: nil on the id path is UNCAPPED (oracle A's
// get_thread has no cap by construction — the old shared default of 50 silently truncated),
// nil on the subject path is oracle B's max_messages=50, and explicit 0 = the complete thread
// on either path. Negative limits are rejected by the caller before this runs.
enum ThreadLimits {
    static func effective(_ limit: Int?, idPath: Bool) -> Int {
        guard let limit else { return idPath ? Int.max : 50 }
        return limit == 0 ? Int.max : limit
    }
}

// MARK: attachments

/// Pure name-keyed join between the live Mail.app attachment enumeration and the
/// Envelope-Index rows (`ORDER BY name`). Positional joins are FORBIDDEN here: the two
/// orders were measured disagreeing on 8/8 multi-attachment messages (22/24 ids mis-paired
/// on one real message). A name that appears more than once in the index — or not at all —
/// yields (nil, nil): ambiguous/unknown beats silently wrong.
enum AttachmentJoin {
    static func byName(_ name: String, in indexRows: [(name: String, attachmentID: String?)])
        -> (attachmentID: String?, saveIndex: Int?) {
        let matches = indexRows.enumerated().filter { $0.element.name == name }
        guard matches.count == 1, let m = matches.first else { return (nil, nil) }
        return (m.element.attachmentID, m.offset)
    }
}

struct AttachmentsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attachments",
        abstract: "List and save message attachments.",
        subcommands: [AttachmentsList.self, AttachmentsSave.self],
        defaultSubcommand: AttachmentsList.self)
}

struct AttachmentsList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List attachments by message id or subject keyword.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Message id (ROWID / RFC Message-ID / message:// link).") var id: String?
    @Option(name: .long, help: "Subject keyword to find messages.") var subject: String?
    @Option(name: .long, help: "Account name or UUID. With an id: scope assertion (rejects if the message is elsewhere — same posture as `get`, see docs/port-specs/mail.md; oracle A treats it as a perf hint). With --subject: which account to search.") var account: String?
    @Option(name: .long, help: "Mailbox. With an id: scope assertion (oracle A's mailbox param, hint there; 'All' is the no-op wildcard). With --subject: where to match (default INBOX, oracle B's scope; 'All' widens). Ignored-with-an-id note: --max-results applies to --subject only (the id path is oracle A's get_attachments, which has no cap).") var mailbox: String?
    @Option(name: .long, help: "Max messages to inspect for --subject (default 1, oracle B's default — each match costs a live Mail.app locator scan, bounded at 30s per Message-ID spelling / 60s per match; raise deliberately). Inert on the id path.") var maxResults: Int = 1
    @Flag(name: .long, help: "Skip the live Mail.app metadata enrichment (fast Envelope-Index rows only; mime_type/size/downloaded omitted, disclosed via note).") var noLive = false

    /// A live lookup failure is a disclosed index fallback, not a command failure. Keep the
    /// catch policy outside MailScript so save can preserve the same error and refuse execute.
    static func liveAttachmentMetadataOrNil(
        _ lookup: () throws -> [MailScript.AttachmentMeta]?
    ) -> [MailScript.AttachmentMeta]? {
        do { return try lookup() }
        catch { return nil }
    }

    static func shapeAttachmentRows(
        indexRows: [(name: String, attachmentID: String?)],
        liveMetas: [MailScript.AttachmentMeta]?,
        rowid: Int
    ) -> (rows: [MailAttachment], degraded: Bool) {
        if let liveMetas {
            return (liveMetas.map { meta in
                let (aid, sidx) = AttachmentJoin.byName(meta.name, in: indexRows)
                return MailAttachment(name: meta.name, attachment_id: aid, mime_type: meta.mimeType,
                                      size: meta.size, downloaded: meta.downloaded,
                                      save_index: sidx, message_id: String(rowid))
            }, false)
        }
        return (indexRows.enumerated().map { i, row in
            MailAttachment(name: row.name, attachment_id: row.attachmentID, mime_type: nil,
                           size: nil, downloaded: nil, save_index: i,
                           message_id: String(rowid))
        }, true)
    }

    static func degradedNote(degraded: Bool, noLive: Bool) -> String? {
        guard degraded else { return nil }
        return noLive
            ? "live enrichment skipped (--no-live) — rows are Envelope-Index only (mime_type/size/downloaded omitted)"
            : "live Mail.app enrichment unavailable — rows are Envelope-Index only (mime_type/size/downloaded omitted)"
    }

    /// Oracle-A-shaped rows: the live Mail.app enumeration (name/mime_type/size/downloaded, in
    /// Mail's own MIME-part order, exactly like oracle A's AppleScript path) is PRIMARY;
    /// Envelope-Index rows are the degraded path when the message is not locatable live (where
    /// oracle A errors, the CLI still returns names — disclosed via `note`).
    ///
    /// attachment_id joins by NAME, never by position. Review measured the two enumerations'
    /// orders DISAGREEING on 8 of 8 multi-attachment messages sampled on this store (the index
    /// is `ORDER BY name`, Mail's live list is MIME-part order) — a positional zip mis-paired
    /// 22 of 24 ids on one real message, silently. A duplicate name maps to nil (ambiguous).
    ///
    /// `save_index` is the position in the INDEX-ordered list — the space `attachments save
    /// --indices` selects from — emitted so a caller can vet a row here and address the same
    /// attachment there for the index-space views. Since the extra32 fix, `attachments save`
    /// builds its own master from the SAME live enumeration (and refuses to execute from the
    /// index fallback), so a row's POSITION here equals save's selection position on the happy
    /// path — `save_index` remains the honest pointer for the degraded/index views.
    private func attachmentRows(ctx: MailContext, row: [String: String?], rowid: Int,
                                live: Bool) throws
        -> (rows: [MailAttachment], degraded: Bool) {
        let indexRows = try ctx.index.attachments(messageRowid: rowid)
        let msg = ctx.decodeSummary(row)
        var liveMetas: [MailScript.AttachmentMeta]? = nil
        if live, let internetID = msg.internet_message_id {
            liveMetas = Self.liveAttachmentMetadataOrNil {
                try MailScript().listAttachments(
                    internetMessageID: internetID, accountName: msg.account)
            }
        }
        return Self.shapeAttachmentRows(
            indexRows: indexRows, liveMetas: liveMetas, rowid: rowid)
    }

    func run() throws {
        try runGuarded(tool: "mail") {
            let ctx = try MailContext()
            var atts: [MailAttachment] = []
            var matchedBy = ""
            var emails: [MailAttachmentEmail]? = nil
            var degraded = false
            if let id {
                matchedBy = "message_id"
                guard let row = try resolveMessageRow(ctx: ctx, id: id) else {
                    throw AppleError.notFound("no message for id '\(id)'.")
                }
                let msg = ctx.decodeSummary(row)
                // --account/--mailbox were previously declared and silently IGNORED on the id
                // path (ok:true with the payload for a nonexistent account). Same scope-assertion
                // semantics as `get`, with the oracle-A hint divergence disclosed in the help/spec.
                if let account {
                    let wantUUID = try ctx.requireAccountUUID(account)
                    let msgUUID = (try? ctx.requireAccountUUID(msg.account)) ?? ""
                    guard wantUUID == msgUUID else {
                        throw AppleError.notFound("message '\(id)' is not in account '\(account)'.")
                    }
                }
                // "All" is the CLI-wide wildcard (search/thread/save) — asserting it literally
                // made `--mailbox All` a guaranteed not_found on every message (review-caught).
                if let mailbox, !EnvelopeIndex.isAllWildcard(mailbox) {
                    let want = mailbox.lowercased()
                    let path = msg.mailbox.lowercased()
                    let leaf = path.split(separator: "/").last.map(String.init) ?? path
                    guard path == want || leaf == want else {
                        throw AppleError.notFound("message '\(id)' is not in mailbox '\(mailbox)' (it is in '\(msg.mailbox)').")
                    }
                }
                let rowid = intVal(row["rowid"]) ?? 0
                (atts, degraded) = try attachmentRows(ctx: ctx, row: row, rowid: rowid, live: !noLive)
            } else if let subject {
                matchedBy = "subject_keyword"
                var f = EnvelopeIndex.MessageFilters()
                if let account { f.accountUUID = try ctx.requireAccountUUID(account) }
                // Oracle B scopes the subject match to the account's INBOX and groups per email,
                // INCLUDING zero-attachment matches ("No attachments") — the old forced
                // hasAttachment=true made a zero-attachment match structurally unreachable.
                f.mailboxName = mailbox ?? "INBOX"
                // Same fail-loud rule as search/thread — an unknown --mailbox on the flag this
                // batch ADDED must not return the empty success the batch exists to kill
                // (review-caught: the defect was reintroduced on the new flag in the same diff).
                try requireMailboxKnown(ctx: ctx, name: f.mailboxName, accountUUID: f.accountUUID)
                f.subjectContains = subject
                f.limit = maxResults
                let rows = try ctx.index.queryMessages(f)
                var grouped: [MailAttachmentEmail] = []
                for row in rows {
                    let rowid = intVal(row["rowid"]) ?? 0
                    let msg = ctx.decodeSummary(row)
                    let (rowsForMsg, deg) = try attachmentRows(ctx: ctx, row: row, rowid: rowid, live: !noLive)
                    degraded = degraded || deg
                    atts += rowsForMsg
                    grouped.append(MailAttachmentEmail(
                        message_id: String(rowid), subject: msg.subject, sender: msg.sender,
                        date_received: msg.date_received, attachment_count: rowsForMsg.count,
                        attachments: rowsForMsg))
                }
                emails = grouped
            } else {
                throw AppleError.validation("provide a message id argument or --subject keyword.")
            }
            let result = MailAttachmentsResult(
                attachments: atts, count: atts.count, matched_by: matchedBy,
                emails: emails, matched_email_count: emails?.count,
                note: Self.degradedNote(degraded: degraded, noLive: noLive))
            if global.json { try Output.emit(tool: "mail", data: result) }
            else { for a in atts { Output.printText("\(a.name)\(a.attachment_id.map { "  [\($0)]" } ?? "")  (msg \(a.message_id))") } }
        }
    }
}
