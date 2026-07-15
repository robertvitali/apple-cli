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
        public init(rowid: Int, senderAddress: String?, senderName: String?, subject: String,
                    dateReceived: Int?, read: Bool, flagged: Bool, hasAttachment: Bool, mailboxRowid: Int) {
            self.rowid = rowid; self.senderAddress = senderAddress; self.senderName = senderName
            self.subject = subject; self.dateReceived = dateReceived; self.read = read
            self.flagged = flagged; self.hasAttachment = hasAttachment; self.mailboxRowid = mailboxRowid
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
    }

    public struct NeedsResponseItem: Encodable {
        public let rank: Int
        public let priority: String        // HIGH | NORMAL
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

    // MARK: Statistics

    public static func statistics(_ rows: [Row], scope: String, account: String, daysBack: Int,
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
            var mb: [Int: Int] = [:]
            for r in rows { mb[r.mailboxRowid, default: 0] += 1 }
            breakdown = mb.sorted { $0.value > $1.value }.map {
                MailboxBreakdown(path: mailboxPath($0.key), count: $0.value,
                                 percentage: total > 0 ? (Double($0.value) / Double(total) * 100).rounded(toPlaces: 1) : 0)
            }
        }
        return StatisticsResult(account: account, scope: scope, days_back: daysBack, total: total,
                                unread: unread, read: read, flagged: flagged, with_attachments: withAtt,
                                unread_pct: unreadPct, read_pct: readPct, top_senders: top, mailbox_breakdown: breakdown)
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
    public static func needsResponse(_ rows: [Row], maxResults: Int) -> [NeedsResponseItem] {
        let candidates = rows.filter { !$0.read && !isAutomatedSender(address: $0.senderAddress, name: $0.senderName) }
        let ranked = candidates.sorted { a, b in
            let ap = priorityScore(a), bp = priorityScore(b)
            if ap != bp { return ap > bp }
            return (a.dateReceived ?? 0) > (b.dateReceived ?? 0)
        }.prefix(maxResults)
        return ranked.enumerated().map { i, r in
            NeedsResponseItem(
                rank: i + 1,
                priority: priorityScore(r) >= 2 ? "HIGH" : "NORMAL",
                subject: r.subject,
                sender: MailFormat.person(name: r.senderName, address: r.senderAddress),
                sender_address: r.senderAddress,
                message_id: String(r.rowid),
                date_received: MailFormat.iso(fromUnix: r.dateReceived))
        }
    }

    private static func priorityScore(_ r: Row) -> Int {
        var score = 0
        if r.subject.contains("?") { score += 2 }
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
