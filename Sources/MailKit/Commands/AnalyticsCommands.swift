import Foundation
import ArgumentParser
import AppleKit

// P3 derived analytics over the Envelope Index (fast; MCP B returns these as text blobs —
// we emit structured JSON supersets). Parent `analytics` + top-level `export`.

struct AnalyticsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analytics",
        abstract: "Derived inbox analytics (overview, needs-response, awaiting-reply, top-senders, stats, dashboard).",
        subcommands: [AnalyticsOverview.self, AnalyticsNeedsResponse.self, AnalyticsAwaitingReply.self,
                      AnalyticsTopSenders.self, AnalyticsStats.self, AnalyticsDashboard.self])
}

// Shared decode: analyticsRows() row → Analytics.Row.
func analyticsRow(_ row: [String: String?]) -> Analytics.Row {
    Analytics.Row(
        rowid: intVal(row["rowid"]) ?? 0,
        senderAddress: strVal(row["sender_address"]),
        senderName: strVal(row["sender_name"]),
        subject: strVal(row["subject"]) ?? "",
        dateReceived: intVal(row["date_received"]),
        read: (intVal(row["read"]) ?? 0) != 0,
        flagged: (intVal(row["flagged"]) ?? 0) != 0,
        hasAttachment: (intVal(row["attachment_count"]) ?? 0) > 0,
        mailboxRowid: intVal(row["mailbox_rowid"]) ?? 0,
        snippet: strVal(row["snippet"]))
}

func sinceUnix(daysBack: Int) -> Int? {
    guard daysBack > 0 else { return nil }
    return Int(Date().timeIntervalSince1970) - daysBack * 86400
}

// MARK: top-senders

struct AnalyticsTopSenders: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "top-senders", abstract: "Most frequent senders (or domains) in a mailbox.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Account name or UUID.") var account: String
    @Option(name: .long, help: "Mailbox (default INBOX; 'All' for every mailbox).") var mailbox: String = "INBOX"
    @Option(name: .long, help: "Look back this many days (0 = all time).") var days: Int = 30
    @Option(name: .long, help: "How many top senders to return.") var topN: Int = 10
    @Flag(name: .long, help: "Group by sender domain instead of address.") var byDomain = false

    func run() throws {
        try runGuarded(tool: "mail") {
            let ctx = try MailContext()
            let uuid = try ctx.requireAccountUUID(account)
            let rows = try ctx.index.analyticsRows(accountUUID: uuid, mailboxName: mailbox, sinceUnix: sinceUnix(daysBack: days)).map(analyticsRow)
            let result = Analytics.topSenders(rows, topN: topN, byDomain: byDomain, account: account, mailbox: mailbox, daysBack: days)
            try Output.emit(tool: "mail", data: result)
        }
    }
}

// MARK: stats

struct AnalyticsStats: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stats", abstract: "Volume/read-ratio/breakdown statistics.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Account name or UUID.") var account: String
    @Option(name: .long, help: "Scope: account_overview | sender_stats | mailbox_breakdown.") var scope: String = "account_overview"
    @Option(name: .long, help: "Sender filter (for sender_stats).") var sender: String?
    @Option(name: .long, help: "Mailbox (default INBOX; 'All' for every mailbox).") var mailbox: String = "INBOX"
    @Option(name: .long, help: "Look back this many days (0 = all time).") var days: Int = 30
    @Flag(name: .long, help: "Include Trash/Junk/Sent/Drafts/Spam in the totals (MCP B excludes them; CLI extra).") var includeSystemFolders = false

    func run() throws {
        try runGuarded(tool: "mail") {
            // Oracle B validates both, returning "Error: Invalid scope '<s>'. Use: …" and
            // "Error: 'sender' parameter required for sender_stats scope" (tools/analytics.py).
            // The CLI accepted an unknown scope silently and returned an account_overview-shaped
            // payload, and accepted sender_stats with no --sender (reporting whole-account
            // numbers as if they were that sender's).
            let scopes = ["account_overview", "sender_stats", "mailbox_breakdown"]
            guard scopes.contains(scope) else {
                throw AppleError.validation("invalid --scope '\(scope)'. Use: \(scopes.joined(separator: ", ")).")
            }
            if scope == "sender_stats", sender?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
                throw AppleError.validation("--sender is required for --scope sender_stats.")
            }
            let ctx = try MailContext()
            let uuid = try ctx.requireAccountUUID(account)
            // account_overview + mailbox_breakdown span every mailbox; sender_stats honors --mailbox.
            let mbx = (scope == "sender_stats") ? mailbox : "All"
            var rows = try ctx.index.analyticsRows(accountUUID: uuid, mailboxName: mbx, sinceUnix: sinceUnix(daysBack: days)).map(analyticsRow)
            // Oracle B excludes SKIP_FOLDERS (Trash/Junk/Sent*/Drafts/Spam/Deleted*) from its
            // broad scans, so every volume metric here diverged from the oracle's by counting
            // them. `--include-system-folders` opts back in (the CLI's own addition).
            if !includeSystemFolders {
                rows = rows.filter { row in
                    let path = ctx.index.mailbox(forRowid: row.mailboxRowid)?.url.path ?? ""
                    return !Analytics.isSkippedSystemFolder(path)
                }
            }
            if scope == "sender_stats", let sender {
                let needle = sender.lowercased()
                rows = rows.filter { ($0.senderAddress?.lowercased().contains(needle) ?? false)
                                   || ($0.senderName?.lowercased().contains(needle) ?? false) }
            }
            let result = Analytics.statistics(rows, scope: scope, account: account, daysBack: days) {
                ctx.index.mailbox(forRowid: $0)?.url.path ?? "?"
            }
            try Output.emit(tool: "mail", data: result)
        }
    }
}

// MARK: needs-response

struct AnalyticsNeedsResponse: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "needs-response", abstract: "Unread messages likely needing a reply (skips newsletters/noreply).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Account name or UUID.") var account: String
    @Option(name: .long, help: "Mailbox (default INBOX).") var mailbox: String = "INBOX"
    @Option(name: .long, help: "Look back this many days.") var days: Int = 7
    @Option(name: .long, help: "Max results.") var max: Int = 20

    struct Result: Encodable { let account: String; let mailbox: String; let days_back: Int; let items: [Analytics.NeedsResponseItem]; let count: Int }

    func run() throws {
        try runGuarded(tool: "mail") {
            let ctx = try MailContext()
            let uuid = try ctx.requireAccountUUID(account)
            let rows = try ctx.index.analyticsRows(accountUUID: uuid, mailboxName: mailbox, sinceUnix: sinceUnix(daysBack: days)).map(analyticsRow)
            // Oracle B drops any candidate whose thread already appears in Sent — a message you
            // have answered is not awaiting your response. B reads the first 200 Sent subjects;
            // we take the same bound from the index. A missing Sent mailbox just means no
            // suppression, never a failure.
            var sentSubjects: [String] = []
            if let sentPath = ctx.index.mailboxes.first(where: {
                Analytics.isSentMailbox($0.url.path)
            })?.url.path {
                sentSubjects = (try? ctx.index.analyticsRows(accountUUID: uuid, mailboxName: sentPath, sinceUnix: nil))?
                    .prefix(200).map { MailFormat.stripThreadPrefixes(strVal($0["subject"]) ?? "") } ?? []
            }
            let items = Analytics.needsResponse(rows, maxResults: max, sentSubjects: sentSubjects)
            try Output.emit(tool: "mail", data: Result(account: account, mailbox: mailbox, days_back: days, items: items, count: items.count))
        }
    }
}

// MARK: awaiting-reply (index cross-ref; MCP B's AppleScript version times out)

struct AnalyticsAwaitingReply: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "awaiting-reply", abstract: "Sent messages with no reply yet (Sent↔Inbox cross-ref).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Account name or UUID.") var account: String
    @Option(name: .long, help: "Look back this many days over Sent.") var days: Int = 7
    @Option(name: .long, help: "Max results.") var max: Int = 20
    @Flag(name: .long, inversion: .prefixedNo, help: "Skip messages sent to noreply addresses (default on).") var excludeNoreply = true

    struct Result: Encodable { let account: String; let days_back: Int; let items: [Analytics.AwaitingReplyItem]; let count: Int }

    func run() throws {
        try runGuarded(tool: "mail") {
            let ctx = try MailContext()
            let uuid = try ctx.requireAccountUUID(account)
            let since = sinceUnix(daysBack: days)

            // Sent messages: find the account's Sent mailbox by leaf name.
            let sentName = ctx.index.mailboxes.first(where: {
                $0.url.accountID == uuid && $0.url.leaf.lowercased().contains("sent")
            })?.url.path ?? "Sent"
            // Fetch ALL sent rows (no SQL since-window): Sent messages' send time is date_sent,
            // and a naive `date_received >= since` filter would drop any account whose Sent rows
            // carry date_received=0. Window in Swift on the effective send date instead.
            let sentRows = try ctx.index.analyticsRows(accountUUID: uuid, mailboxName: sentName, sinceUnix: nil)
            var sent: [Analytics.SentItem] = []
            for row in sentRows {
                let effDate = intVal(row["date_sent"]) ?? intVal(row["date_received"])
                if let since, (effDate ?? 0) < since { continue }
                let rowid = intVal(row["rowid"]) ?? 0
                let recips = try ctx.index.recipients(messageRowid: rowid)
                // recipients() returns display strings; extract addresses.
                let addrs = (recips.to + recips.cc).compactMap { extractAddress($0) }
                sent.append(Analytics.SentItem(subject: strVal(row["subject"]) ?? "", recipients: addrs,
                                               dateSent: effDate, rowid: rowid))
            }

            // Received candidates from INBOX (broad window).
            let inboxRows = try ctx.index.analyticsRows(accountUUID: uuid, mailboxName: "INBOX", sinceUnix: since).map(analyticsRow)
            let received = inboxRows.map {
                Analytics.ReceivedItem(normalizedSubject: Analytics.normalizeSubject($0.subject),
                                       senderAddress: $0.senderAddress ?? "", dateReceived: $0.dateReceived)
            }
            let all = Analytics.awaitingReply(sent: sent, received: received, excludeNoreply: excludeNoreply)
            let items = Array(all.prefix(max))
            try Output.emit(tool: "mail", data: Result(account: account, days_back: days, items: items, count: items.count))
        }
    }
}

/// Extract the bare address from a "Name <addr>" or "addr" display string.
func extractAddress(_ person: String) -> String? {
    if let lt = person.lastIndex(of: "<"), let gt = person.lastIndex(of: ">"), lt < gt {
        return String(person[person.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
    }
    let t = person.trimmingCharacters(in: .whitespaces)
    return t.contains("@") ? t : nil
}

// MARK: overview

struct AnalyticsOverview: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "overview", abstract: "Inbox overview: unread-by-account, recent messages, suggested actions.")
    @OptionGroup var global: GlobalOptions

    struct AccountUnread: Encodable { let account: String; let unread: Int; let total: Int }
    struct Result: Encodable {
        let accounts: [AccountUnread]
        let total_unread: Int
        let recent: [MailMessage]
        let suggestions: [String]
    }

    func run() throws {
        try runGuarded(tool: "mail") {
            let ctx = try MailContext()
            // Unread per account from Mail's live counts (matches the oracle).
            var accounts: [AccountUnread] = []
            var total = 0
            if let unread = try? MailScript().unreadCounts(summary: true, includeZero: true, accountFilter: nil) {
                for u in unread {
                    let totalMsgs = ctx.index.mailboxes.first(where: {
                        ctx.accounts().name(forUUID: $0.url.accountID) == u.account && $0.url.leaf.caseInsensitiveCompare("INBOX") == .orderedSame
                    })?.total ?? 0
                    accounts.append(AccountUnread(account: u.account, unread: u.unread, total: totalMsgs))
                    total += u.unread
                }
            }
            // Recent across all inboxes.
            var f = EnvelopeIndex.MessageFilters()
            f.mailboxName = "INBOX"; f.limit = 10
            let recent = try ctx.index.queryMessages(f).map { ctx.decodeSummary($0) }
            let suggestions = [
                "Review unread messages with `apple mail list --unread`.",
                "Find replies needed with `apple mail analytics needs-response --account <a>`.",
                "Track follow-ups with `apple mail analytics awaiting-reply --account <a>`.",
                "Identify high-volume senders with `apple mail analytics top-senders --account <a>`.",
            ]
            try Output.emit(tool: "mail", data: Result(accounts: accounts, total_unread: total, recent: recent, suggestions: suggestions))
        }
    }
}
