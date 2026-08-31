import Foundation

/// Derived analytics computed over Envelope Index rows (the MCP B "DERIVED" capabilities:
/// top-senders, statistics, needs-response, awaiting-reply). MCP B returns these as human
/// TEXT blobs; we compute STRUCTURED JSON (a strict superset) over the fast SQLite path —
/// notably `awaiting_reply`, which times out via MCP B's AppleScript but is instant here.
///
/// All functions are PURE (operate on decoded rows) so the ranking/heuristic math is
/// unit-testable with synthetic data.
public enum Analytics {

    /// Lightweight decoded row for analytics (subset of `EnvelopeIndex.analyticsRows`).
    public struct Row {
        public let rowid: Int
        public let senderAddress: String?
        public let senderName: String?
        public let subject: String
        public let dateReceived: Int?
        public let read: Bool
        public let flagged: Bool
        public let hasAttachment: Bool
        public let mailboxRowid: Int
        /// Indexed body preview standing in for oracle B's first-500-chars-of-content question scan
        /// without a per-message AppleScript body fetch. Populated from the Envelope Index
        /// `summaries` table; nil where this store has no cached preview for the message, and on any
        /// Mail schema without that table. See `hasQuestion` for the coverage divergence.
        public let snippet: String?
        /// `snippet` is deliberately NOT defaulted. The shipped Q4e bug was exactly a nil snippet on
        /// every row, and with a default a call site that simply forgets the argument reproduces it
        /// while every test of the join stays green. The same argument is made 40 lines up for
        /// `RowSlice`: a defaulted parameter has already produced one real defect in this repo, so
        /// "discouraged" is not good enough. Make every caller say what it means.
        public init(rowid: Int, senderAddress: String?, senderName: String?, subject: String,
                    dateReceived: Int?, read: Bool, flagged: Bool, hasAttachment: Bool, mailboxRowid: Int,
                    snippet: String?) {
            self.rowid = rowid; self.senderAddress = senderAddress; self.senderName = senderName
            self.subject = subject; self.dateReceived = dateReceived; self.read = read
            self.flagged = flagged; self.hasAttachment = hasAttachment; self.mailboxRowid = mailboxRowid
            self.snippet = snippet
        }
    }

    // MARK: Models

    public struct TopSender: Encodable {
        public let rank: Int
        public let sender: String
        public let address: String?
        public let count: Int
        public let percentage: Double
    }
    public struct TopSendersResult: Encodable {
        public let account: String
        public let mailbox: String
        public let days_back: Int
        public let group_by_domain: Bool
        public let senders: [TopSender]
        public let total_analyzed: Int
        public let unique_senders: Int
    }

    public struct MailboxBreakdown: Encodable { public let path: String; public let count: Int; public let percentage: Double }
    public struct StatisticsResult: Encodable {
        public let account: String
        public let scope: String
        public let days_back: Int
        public let total: Int
        public let unread: Int
        public let read: Int
        public let flagged: Int
        public let with_attachments: Int
        public let unread_pct: Double
        public let read_pct: Double
        public let top_senders: [TopSender]?
        public let mailbox_breakdown: [MailboxBreakdown]?
        /// The mailbox scope actually scanned — `"All"` for the two account-wide scopes, the
        /// resolved name for `mailbox_breakdown`. Inert while `--mailbox` was discarded, but now
        /// that the argument is honored it is the only way a caller can tell an empty result for
        /// the mailbox they meant from an empty result for one they mistyped. `TopSendersResult`
        /// already carries the same field. (Additive optional ⇒ MINOR, per versioning-policy.md.)
        public var mailbox: String? = nil
        /// Whether MCP B's SKIP_FOLDERS were excluded from these counts. Analytics is a
        /// counts-only payload, so silent filtering here is indistinguishable from a sparse
        /// store — worse than on `search`, where the caller at least sees the rows. Mirrors
        /// `MailMessagesResult.system_folders_excluded`; `--include-system-folders` flips it.
        public var system_folders_excluded: Bool? = nil
    }

    public struct NeedsResponseItem: Encodable {
        public let rank: Int
        /// Oracle B's four label strings verbatim: "HIGH (flagged + question)",
        /// "HIGH (flagged)", "MEDIUM (contains question)", "NORMAL". The label text IS
        /// part of B's surface, and the MEDIUM bucket had no CLI counterpart at all.
        public let priority: String
        public let subject: String
        public let sender: String
        public let sender_address: String?
        public let message_id: String
        public let date_received: String?
    }

    public struct AwaitingReplyItem: Encodable {
        public let subject: String
        public let recipient: String
        public let date_sent: String?
        public let message_id: String
    }

    // MARK: Helpers (pure)

    /// Normalize a subject for thread/reply matching: strip leading Re:/Fwd:/Fw: (repeated),
    /// trim, lowercase. Delegates the prefix stripping to `MailFormat.stripThreadPrefixes` so
    /// there is exactly ONE prefix list in the codebase (review L2) — the two halves of the
    /// awaiting-reply feature previously each carried their own copy, which agreed only by
    /// coincidence.
    public static func normalizeSubject(_ s: String) -> String {
        MailFormat.stripThreadPrefixes(s.trimmingCharacters(in: .whitespacesAndNewlines)).lowercased()
    }

    /// Oracle B's needs-response automated-sender markers — EXACTLY these seven
    /// (smart_inbox.py:320), matched `contains` against the lowercased sender string (gap40).
    /// The CLI's earlier 17-marker heuristic was measurably OVER-broad: `support@` / `info@` /
    /// `alerts@` / bare `notification` dropped real correspondence the oracle keeps, so a
    /// narrower list here is a parity fix, not a loosening. (`updates@`/`news@` are NOT in that
    /// kept set — the separate newsletter keyword list below still drops them, exactly as the
    /// oracle's own newsletter_condition does.) Element ORDER mirrors the oracle's `or`-chain
    /// and the pins assert it verbatim — deliberate, though matching is order-independent.
    public static let oracleAutomatedMarkers = [
        "noreply", "no-reply", "donotreply", "do-not-reply",
        "notifications@", "mailer-daemon", "postmaster@",
    ]

    /// Automated-sender test for needs-response, oracle-exact (gap40). B builds `lowerSender`
    /// from the sender string it reads off the message; we match over address + display name so
    /// a marker in either half counts, same as B's combined string.
    public static func isAutomatedSender(address: String?, name: String?) -> Bool {
        let hay = ((address ?? "") + " " + (name ?? "")).lowercased()
        return oracleAutomatedMarkers.contains { hay.contains($0) }
    }

    /// Oracle B's awaiting-reply `exclude_noreply` RECIPIENT patterns — EXACTLY these four
    /// (smart_inbox.py:92), matched against the lowercased recipient address (gap44). This is a
    /// DIFFERENT, smaller list than the sender markers above: the oracle does not drop a
    /// follow-up merely because it went to `notifications@` or `postmaster@`.
    public static let noreplyRecipientPatterns = ["noreply", "no-reply", "do-not-reply", "donotreply"]

    public static func isNoreplyRecipient(_ address: String) -> Bool {
        let a = address.lowercased()
        return noreplyRecipientPatterns.contains { a.contains($0) }
    }

    // MARK: Top senders

    public static func topSenders(_ rows: [Row], topN: Int, byDomain: Bool,
                                  account: String, mailbox: String, daysBack: Int) -> TopSendersResult {
        var counts: [String: (display: String, count: Int)] = [:]
        for r in rows {
            let addr = r.senderAddress ?? ""
            let key: String
            let display: String
            if byDomain {
                key = MailFormat.domain(ofAddress: addr) ?? addr.lowercased()
                display = key
            } else {
                key = addr.lowercased()
                display = MailFormat.person(name: r.senderName, address: addr)
            }
            if key.isEmpty { continue }
            if counts[key] == nil { counts[key] = (display, 0) }   // keep first-seen display name
            counts[key]!.count += 1
        }
        let total = rows.count
        let ranked = counts.sorted { $0.value.count > $1.value.count }.prefix(Swift.max(0, topN))
        var senders: [TopSender] = []
        for (i, entry) in ranked.enumerated() {
            let pct = total > 0 ? (Double(entry.value.count) / Double(total) * 100).rounded(toPlaces: 1) : 0
            senders.append(TopSender(rank: i + 1, sender: entry.value.display,
                                     address: byDomain ? nil : entry.key, count: entry.value.count, percentage: pct))
        }
        return TopSendersResult(account: account, mailbox: mailbox, days_back: daysBack, group_by_domain: byDomain,
                                senders: senders, total_analyzed: total, unique_senders: counts.count)
    }

    // MARK: Statistics scope planning

    /// How a `stats` scope actually scans, per oracle B (`tools/analytics.py`).
    ///
    /// This exists as a named, unit-testable value rather than an inline ternary in the command
    /// because the inline version was wrong in three ways at once and nothing could catch it: the
    /// logic sat behind a live `MailContext`, so no logic-tier test could reach it. Extracting it
    /// makes each rule assertable without Mail, Full Disk Access, or a configured account.
    ///
    /// | scope | mailbox | SKIP_FOLDERS | days_back |
    /// |---|---|---|---|
    /// | `account_overview`  (:142) | ignored — whole account | excluded (:170) | applied |
    /// | `sender_stats`      (:283) | ignored — whole account | excluded (:314) | applied |
    /// | `mailbox_breakdown` (:351) | the named one, default INBOX | NOT excluded | IGNORED |
    ///
    /// `mailbox_breakdown` differs on every axis, which is why getting one right proves nothing
    /// about the others.
    public struct ScopePlan: Equatable, Sendable {
        /// Mailbox name handed to `analyticsRows`; `"All"` means every mailbox of the account.
        public let mailbox: String
        /// Days actually applied — NOT necessarily what the caller asked for.
        public let daysBack: Int
        /// Whether Trash/Junk/Sent*/Drafts/Spam are dropped from the scan.
        public let excludeSystemFolders: Bool
    }

    public static func scopePlan(scope: String, requestedMailbox: String, requestedDays: Int,
                                 includeSystemFolders: Bool) -> ScopePlan {
        let isBreakdown = scope == "mailbox_breakdown"
        // Only mailbox_breakdown reads `mailbox`; the other two always span the account.
        // An empty/whitespace name falls back to INBOX rather than erroring or matching the
        // account-root entries (whose path is ""), because the oracle does exactly that:
        // `mailbox_param = escaped_mailbox if mailbox else "INBOX"` (analytics.py:352).
        let named = requestedMailbox.trimmingCharacters(in: .whitespaces)
        let mailbox = isBreakdown ? (named.isEmpty ? "INBOX" : named) : "All"
        // The oracle's mailbox_breakdown counts `every message of targetMailbox` with no `whose`
        // clause, so days_back is inert there. Reporting 0 keeps the payload honest.
        let days = isBreakdown ? 0 : requestedDays
        // Keyed on the resolved SCAN SCOPE, not on `scope`: never silently filter away a mailbox
        // the caller named (a Trash breakdown must return Trash), while the CLI-extra
        // `--mailbox All` breakdown still gets the sensible exclusion.
        //
        // Ask `isAllWildcard` — do NOT re-test the string. `EnvelopeIndex` documents itself as the
        // single authority on what "All" selects precisely so this cannot desync, and the first cut
        // wrote `mailbox == "All"`, which is case-SENSITIVE while the resolver is not. The result:
        // `--mailbox all` took the resolver's wildcard branch (every mailbox) while this yielded
        // `exclude == false`, so a lowercase spelling silently swept Trash/Junk/Drafts/Sent into
        // the totals with no `--include-system-folders`. Review-caught, reproduced live.
        let exclude = !includeSystemFolders && EnvelopeIndex.isAllWildcard(mailbox)
        return ScopePlan(mailbox: mailbox, daysBack: days, excludeSystemFolders: exclude)
    }

    // MARK: Statistics

    public static func statistics(_ rows: [Row], scope: String, account: String, daysBack: Int,
                                  systemFoldersExcluded: Bool? = nil,
                                  namedMailbox: String? = nil,
                                  mailboxPath: (Int) -> String) -> StatisticsResult {
        let total = rows.count
        let unread = rows.filter { !$0.read }.count
        let read = total - unread
        let flagged = rows.filter { $0.flagged }.count
        let withAtt = rows.filter { $0.hasAttachment }.count
        let unreadPct = total > 0 ? (Double(unread) / Double(total) * 100).rounded(toPlaces: 1) : 0
        let readPct = total > 0 ? (Double(read) / Double(total) * 100).rounded(toPlaces: 1) : 0

        var top: [TopSender]? = nil
        var breakdown: [MailboxBreakdown]? = nil
        if scope == "account_overview" || scope == "sender_stats" {
            top = topSenders(rows, topN: scope == "sender_stats" ? 25 : 5, byDomain: false,
                             account: account, mailbox: "", daysBack: daysBack).senders
        }
        if scope == "account_overview" || scope == "mailbox_breakdown" {
            if let named = namedMailbox {
                // A named breakdown is reported under the caller-supplied label.
                // Results are normalized so aliases and nested names do not produce
                // misleading paths or duplicate entries.
                breakdown = [MailboxBreakdown(path: named, count: total, percentage: total > 0 ? 100 : 0)]
            } else {
                var mb: [Int: Int] = [:]
                for r in rows { mb[r.mailboxRowid, default: 0] += 1 }
                breakdown = mb.sorted { $0.value > $1.value }.map {
                    MailboxBreakdown(path: mailboxPath($0.key), count: $0.value,
                                     percentage: total > 0 ? (Double($0.value) / Double(total) * 100).rounded(toPlaces: 1) : 0)
                }
            }
        }
        return StatisticsResult(account: account, scope: scope, days_back: daysBack, total: total,
                                unread: unread, read: read, flagged: flagged, with_attachments: withAtt,
                                unread_pct: unreadPct, read_pct: readPct, top_senders: top, mailbox_breakdown: breakdown,
                                mailbox: namedMailbox ?? "All",
                                system_folders_excluded: systemFoldersExcluded)
    }

    // MARK: Needs response

    /// Unread, non-automated messages ranked by likelihood of needing a reply
    /// (question marker in subject + urgent keywords + flagged → HIGH).
    /// Mirrors the recorded parity heuristic.
    ///
    /// The unread filter uses the Envelope Index read bit, which may differ from
    /// Mail's synchronized seen state. A direct-recipient boost is not yet
    /// applied because it requires a per-message recipient join; that remains a
    /// follow-up. Question-marker, urgent, and flagged ranking is applied.
    ///
    /// Sender patterns classified as automated or newsletter traffic are
    /// excluded from needs-response results so bulk notices are not presented
    /// as messages awaiting a personal reply.
    public static let newsletterPlatformPatterns = [
        "substack.com", "beehiiv.com", "mailchimp", "sendgrid",
        "convertkit", "buttondown", "ghost.io", "revue.co", "mailgun",
    ]
    public static let newsletterKeywordPatterns = [
        "newsletter", "digest", "weekly", "daily",
        "bulletin", "briefing", "news@", "updates@",
    ]

    /// Matches against the full sender string (address + display name), as B matches its
    /// `lowerSender`.
    public static func isNewsletterSender(address: String?, name: String?) -> Bool {
        let s = ((address ?? "") + " " + (name ?? "")).lowercased()
        guard !s.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return newsletterPlatformPatterns.contains(where: { s.contains($0) })
            || newsletterKeywordPatterns.contains(where: { s.contains($0) })
    }

    /// Oracle B's exact priority label. B decides on flagged-ness and whether a question mark
    /// appears; it reads the first 500 chars of CONTENT, we use subject + indexed preview, which
    /// covers the same signal without a per-message AppleScript body fetch.
    public static func priorityLabel(flagged: Bool, hasQuestion: Bool) -> String {
        if flagged && hasQuestion { return "HIGH (flagged + question)" }
        if flagged { return "HIGH (flagged)" }
        if hasQuestion { return "MEDIUM (contains question)" }
        return "NORMAL"
    }

    /// True when `subject` matches one of `sentSubjects` under B's bidirectional-containment
    /// rule, i.e. the thread has already been answered. Both sides are prefix-stripped and
    /// lowercased first, exactly as B does over the first 200 Sent subjects.
    public static func alreadyReplied(subject: String, sentSubjects: [String]) -> Bool {
        let base = MailFormat.stripThreadPrefixes(subject)
            .trimmingCharacters(in: .whitespaces).lowercased()
        return sentSubjects.contains { sent in
            subjectsMatch(base, sent.trimmingCharacters(in: .whitespaces).lowercased())
        }
    }

    /// Oracle B's bidirectional-containment subject match (`smart_inbox.py:178` in awaiting-reply,
    /// `:327-332` in needs-response) — ONE helper for both tools so the rule cannot drift (the
    /// awaiting-reply half previously used exact equality, silently stricter than the oracle:
    /// review B1). Inputs are pre-normalized (prefix-stripped where applicable, lowercased).
    /// The empty guards are a deliberate, strictly-better CLI divergence: AppleScript's
    /// `x contains ""` is TRUE, so one empty Sent subject would make the oracle suppress
    /// EVERYTHING — disclosed on port-spec rows 37/38.
    public static func subjectsMatch(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.contains(b) || b.contains(a)
    }

    /// Unread mail plausibly awaiting a personal reply (MCP B `get_needs_response`).
    ///
    /// `sentSubjects` are the account's recent Sent subjects (B reads the first 200); a candidate
    /// whose thread already appears there is dropped as answered. Pass an empty array to skip
    /// that cross-reference.
    public static func needsResponse(_ rows: [Row], maxResults: Int,
                                     sentSubjects: [String] = []) -> [NeedsResponseItem] {
        let candidates = rows.filter {
            !$0.read
                && !isAutomatedSender(address: $0.senderAddress, name: $0.senderName)
                && !isNewsletterSender(address: $0.senderAddress, name: $0.senderName)
                && !alreadyReplied(subject: $0.subject, sentSubjects: sentSubjects)
        }
        // Selection + ordering are the ORACLE'S, not a score sort (review H3). The oracle walks
        // the mailbox newest-first, exits once (high + normal) has collected max_results — i.e.
        // it keeps the NEWEST max qualifying candidates — then emits the high-priority bucket
        // (question OR flagged: the HIGH*/MEDIUM labels) in scan order followed by the normal
        // bucket in scan order (smart_inbox.py:306, :351-365, :372-390). The old CLI ranking
        // globally score-sorted with an urgent-keyword term the oracle lacks, and its score put
        // a MEDIUM question-only item ABOVE a HIGH flagged one — an ordering that contradicted
        // its own labels. ROWID breaks date ties so the collected set is deterministic.
        let scanned = candidates.sorted { a, b in
            let ad = a.dateReceived ?? 0, bd = b.dateReceived ?? 0
            if ad != bd { return ad > bd }
            return a.rowid > b.rowid
        }.prefix(Swift.max(0, maxResults))
        let high = scanned.filter { r in r.flagged || hasQuestion(r) }
        let normal = scanned.filter { r in !(r.flagged || hasQuestion(r)) }
        return (high + normal).enumerated().map { i, r in
            NeedsResponseItem(
                rank: i + 1,
                priority: priorityLabel(flagged: r.flagged, hasQuestion: hasQuestion(r)),
                subject: r.subject,
                sender: MailFormat.person(name: r.senderName, address: r.senderAddress),
                sender_address: r.senderAddress,
                message_id: String(r.rowid),
                date_received: MailFormat.iso(fromUnix: r.dateReceived))
        }
    }

    // Preview text is an index-time signal and may differ from the message body.
    // Matching can therefore under- or over-score relative to body inspection.
    // Body retrieval remains a separate latency tradeoff.
    static func hasQuestion(_ r: Row) -> Bool {
        if r.subject.contains("?") { return true }
        return (r.snippet ?? "").prefix(500).contains("?")
    }

    // MARK: Awaiting reply

    /// One recipient of a Sent message. `display` is the "Name <addr>" string the index stores
    /// (or the bare address when Mail recorded no name) — gap44: oracle B reports the recipient
    /// as `name & " <" & addr & ">"`, and the CLI previously stripped it to the bare address.
    /// `address` is the bare address the reply-matching and noreply filtering key on.
    public struct SentRecipient {
        public let display: String
        public let address: String
        public init(display: String, address: String) { self.display = display; self.address = address }
    }

    public struct SentItem { public let subject: String; public let recipients: [SentRecipient]; public let dateSent: Int?; public let rowid: Int
        public init(subject: String, recipients: [SentRecipient], dateSent: Int?, rowid: Int) {
            self.subject = subject; self.recipients = recipients; self.dateSent = dateSent; self.rowid = rowid } }
    public struct ReceivedItem { public let normalizedSubject: String; public let senderAddress: String; public let dateReceived: Int?
        public init(normalizedSubject: String, senderAddress: String, dateReceived: Int?) {
            self.normalizedSubject = normalizedSubject; self.senderAddress = senderAddress; self.dateReceived = dateReceived } }

    /// Sent messages with no matching inbound reply: no received message from a recipient
    /// matching the subject (oracle's bidirectional containment), dated at/after the send.
    /// MCP B's `get_awaiting_reply`, but computed over the index (MCP B's AppleScript version
    /// times out). TWO deliberate, disclosed divergences in the reply test (port-spec row 38):
    /// the `>=` DATE constraint (the oracle has none — a "reply" predating the send would count
    /// for it) and the received set being windowed to --days (lossless GIVEN the date test:
    /// every sent item satisfies effDate >= since, so any reply it can match is >= since too).
    public static func awaitingReply(sent: [SentItem], received: [ReceivedItem], excludeNoreply: Bool) -> [AwaitingReplyItem] {
        var result: [AwaitingReplyItem] = []
        for s in sent {
            let norm = normalizeSubject(s.subject)
            // gap44: the oracle's exclude_noreply filters RECIPIENTS on exactly four patterns
            // (smart_inbox.py:92) — not the broader automated-SENDER marker list.
            let recipients = excludeNoreply ? s.recipients.filter { !isNoreplyRecipient($0.address) } : s.recipients
            if recipients.isEmpty { continue }
            let replied = received.contains { rec in
                // Oracle's bidirectional-containment subject rule (smart_inbox.py:178), shared
                // with needs-response via subjectsMatch (review B1 — this was exact equality,
                // silently stricter than the oracle).
                subjectsMatch(norm, rec.normalizedSubject)
                // Empty addresses are excluded from the match (review L5): a recipient whose
                // address could not be parsed and a received row with no sender address would
                // otherwise compare "" == "" and silently mark the send as replied.
                && recipients.contains { !$0.address.isEmpty
                    && $0.address.caseInsensitiveCompare(rec.senderAddress) == .orderedSame }
                && (rec.dateReceived ?? 0) >= (s.dateSent ?? 0)
            }
            if !replied {
                // recipients is non-empty here (guarded above) — no fallback to mask that.
                result.append(AwaitingReplyItem(subject: s.subject,
                                                recipient: recipients[0].display,
                                                date_sent: MailFormat.iso(fromUnix: s.dateSent),
                                                message_id: String(s.rowid)))
            }
        }
        return result
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let d = pow(10.0, Double(places))
        return (self * d).rounded() / d
    }
}

extension Analytics {
    // System folders are excluded from broad analytics scans.
    // Matching uses the final path component case-insensitively so ordinary user
    // folders are not excluded accidentally.
    public static let skippedSystemFolders: Set<String> = [
        "trash", "junk", "junk email", "deleted items",
        "sent", "sent items", "sent messages", "drafts",
        "spam", "deleted messages",
    ]

    public static func isSkippedSystemFolder(_ mailboxPath: String) -> Bool {
        guard let leaf = systemFolderLeaf(mailboxPath) else { return false }
        return skippedSystemFolders.contains(leaf)
    }

    /// The lowercased final path component — the ONE leaf rule. `isSkippedSystemFolder` and the
    /// Drafts check in `mailboxScopeNote` both go through this rather than re-deriving it, so a
    /// change to how a leaf is extracted cannot make the two disagree.
    public static func systemFolderLeaf(_ mailboxPath: String) -> String? {
        mailboxPath.split(separator: "/").last.map { $0.lowercased() }
    }

    /// Drafts holds UNSENT composes, so a mutation targeting it is qualitatively different from
    /// re-filing received mail — `mailboxScopeNote` calls this out specifically.
    public static func isDraftsMailbox(_ mailboxPath: String) -> Bool {
        systemFolderLeaf(mailboxPath) == "drafts"
    }
}

extension Analytics {
    /// The Sent-mailbox leaf names oracle B probes in order (`Sent Messages` → `Sent` →
    /// `Sent Items`) when collecting subjects for its already-replied cross-reference.
    public static func isSentMailbox(_ mailboxPath: String) -> Bool {
        guard let leaf = mailboxPath.split(separator: "/").last?.lowercased() else { return false }
        return leaf == "sent messages" || leaf == "sent" || leaf == "sent items"
    }

    /// The oracle's Sent-mailbox fallback, in its exact PRIORITY order.
    ///
    /// `smart_inbox.py:274-283` tries `mailbox "Sent Messages"`, then `"Sent"`, then `"Sent Items"`,
    /// taking the first that exists. `first(where: isSentMailbox)` is NOT the same thing: it returns
    /// whichever candidate happens to come first in the mailbox array, so an account owning both
    /// `Sent` and `Sent Messages` could suppress against the one the oracle would have skipped.
    /// Order is a behavior, not an implementation detail, so it is mirrored rather than approximated.
    ///
    /// Callers must pass paths already filtered to ONE account — the oracle resolves
    /// `of targetAccount`, and cross-account suppression would silently hide messages using a
    /// different mailbox's replies.
    /// The oracle's three names come FIRST, in its order. `"sent mail"` is appended as a CLI EXTRA
    /// so reply suppression remains active when none of the oracle's preferred names resolves.
    /// The fallback adds behavior without removing oracle behavior, so strict-superset holds.
    ///
    /// Matching is on the LEAF, so a nested `Work/Sent` matches. That is also a CLI extra —
    /// `mailbox "Sent" of targetAccount` would not resolve a nested mailbox — and is kept because
    /// `resolveMailboxes` already matches leaf-or-path everywhere else.
    public static func preferredSentMailbox(_ paths: [String]) -> String? {
        for wanted in ["sent messages", "sent", "sent items", "sent mail"] {
            if let hit = paths.first(where: {
                $0.split(separator: "/").last?.lowercased() == wanted
            }) { return hit }
        }
        return nil
    }
}
