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
        /// Indexed body preview — stands in for oracle B's first-500-chars-of-content question
        /// scan without a per-message AppleScript body fetch.
        public let snippet: String?
        public init(rowid: Int, senderAddress: String?, senderName: String?, subject: String,
                    dateReceived: Int?, read: Bool, flagged: Bool, hasAttachment: Bool, mailboxRowid: Int,
                    snippet: String? = nil) {
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
    /// collapse whitespace, lowercase.
    public static func normalizeSubject(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["re:", "fwd:", "fw:"]
        var changed = true
        while changed {
            changed = false
            for p in prefixes where t.lowercased().hasPrefix(p) {
                t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces); changed = true
            }
        }
        return t.lowercased()
    }

    /// Heuristic: is this an automated / newsletter / noreply sender (skip for needs-response)?
    public static func isAutomatedSender(address: String?, name: String?) -> Bool {
        let hay = ((address ?? "") + " " + (name ?? "")).lowercased()
        let markers = ["noreply", "no-reply", "no_reply", "donotreply", "do-not-reply",
                       "notification", "notifications", "newsletter", "mailer", "mailer-daemon",
                       "bounce", "automated", "updates@", "info@", "news@", "alerts@", "support@"]
        return markers.contains { hay.contains($0) }
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
        let ranked = counts.sorted { $0.value.count > $1.value.count }.prefix(topN)
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
                // A NAMED breakdown is one mailbox's stats, so it is one entry labelled with the
                // mailbox the caller asked for.
                //
                // Labelling by the backing store's path (what the rowid gives) is wrong here on
                // label-backed accounts: Gmail's INBOX is a label over `[Gmail]/All Mail`, so
                // `--mailbox INBOX` and `--mailbox Receipts` both reported
                // `path: "[Gmail]/All Mail"` — correct counts under an identifier that names
                // neither request and makes the two indistinguishable. Leaf-matching can also
                // resolve one name to several rowids (`Archive` and `Work/Archive`), which split
                // into duplicate rows under the same label. Both collapse correctly here.
                // Unreachable before this change, because the scan was always the `All` sweep.
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

    /// Unread, non-automated messages ranked by likelihood of needing a reply ("?" in subject
    /// + urgent keywords + flagged → HIGH). Mirrors MCP B's `get_needs_response` heuristic.
    ///
    /// Two documented deltas vs MCP B: (1) the unread filter uses the Envelope Index read-bit,
    /// which can diverge from Mail's server-synced seen-state (observed diverging on one INBOX),
    /// so a few items here may already be read in Mail; (2) MCP B's "direct-To-you" boost is not
    /// yet applied — it needs a per-message recipient join (the account's own address in `To`),
    /// deferred as a follow-up. The `?`/urgent/flagged ranking is applied.
    /// Sender patterns MCP B treats as newsletters (`constants.py`). A sender matching any of
    /// these is dropped from needs-response entirely — without them the CLI surfaced Substack /
    /// Mailchimp / "weekly digest" blasts as mail awaiting a personal reply.
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
        guard !base.isEmpty else { return false }
        return sentSubjects.contains { sent in
            let s = sent.trimmingCharacters(in: .whitespaces).lowercased()
            guard !s.isEmpty else { return false }
            return s.contains(base) || base.contains(s)
        }
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
        let ranked = candidates.sorted { a, b in
            let ap = priorityScore(a), bp = priorityScore(b)
            if ap != bp { return ap > bp }
            return (a.dateReceived ?? 0) > (b.dateReceived ?? 0)
        }.prefix(maxResults)
        return ranked.enumerated().map { i, r in
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

    /// B looks for "?" in the message body's first 500 chars; the index gives us the subject and
    /// the same preview text, so check both.
    static func hasQuestion(_ r: Row) -> Bool {
        if r.subject.contains("?") { return true }
        return (r.snippet ?? "").prefix(500).contains("?")
    }

    private static func priorityScore(_ r: Row) -> Int {
        var score = 0
        if hasQuestion(r) { score += 2 }
        let urgent = ["urgent", "asap", "action required", "action needed", "deadline", "please respond", "reply"]
        let lower = r.subject.lowercased()
        if urgent.contains(where: { lower.contains($0) }) { score += 1 }
        if r.flagged { score += 1 }
        return score
    }

    // MARK: Awaiting reply

    public struct SentItem { public let subject: String; public let recipients: [String]; public let dateSent: Int?; public let rowid: Int
        public init(subject: String, recipients: [String], dateSent: Int?, rowid: Int) {
            self.subject = subject; self.recipients = recipients; self.dateSent = dateSent; self.rowid = rowid } }
    public struct ReceivedItem { public let normalizedSubject: String; public let senderAddress: String; public let dateReceived: Int?
        public init(normalizedSubject: String, senderAddress: String, dateReceived: Int?) {
            self.normalizedSubject = normalizedSubject; self.senderAddress = senderAddress; self.dateReceived = dateReceived } }

    /// Sent messages with no matching inbound reply: no received message from a recipient with
    /// the same normalized subject, dated at/after the send. MCP B's `get_awaiting_reply`,
    /// but computed over the index (MCP B's AppleScript version times out).
    public static func awaitingReply(sent: [SentItem], received: [ReceivedItem], excludeNoreply: Bool) -> [AwaitingReplyItem] {
        var result: [AwaitingReplyItem] = []
        for s in sent {
            let norm = normalizeSubject(s.subject)
            let recipients = excludeNoreply ? s.recipients.filter { !isAutomatedSender(address: $0, name: nil) } : s.recipients
            if recipients.isEmpty { continue }
            let replied = received.contains { rec in
                rec.normalizedSubject == norm
                && recipients.contains { $0.caseInsensitiveCompare(rec.senderAddress) == .orderedSame }
                && (rec.dateReceived ?? 0) >= (s.dateSent ?? 0)
            }
            if !replied {
                result.append(AwaitingReplyItem(subject: s.subject, recipient: recipients.first ?? "",
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
    /// The system folders MCP B excludes from broad scans (`constants.py` `SKIP_FOLDERS`).
    /// Counting them made every CLI volume metric — totals, read ratios, sender counts —
    /// disagree with the oracle's for the same account.
    ///
    /// Matching is on the mailbox path's LAST component, case-insensitively, so
    /// "…/[Gmail]/Trash" and "…/Deleted Messages" both match while a user folder merely
    /// containing the word ("Sent to accountant") does not.
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
}
