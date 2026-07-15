import Foundation
import ArgumentParser
import AppleKit

// `apple mail accounts …`, `… mailboxes …`, `… unread-counts`, `… doctor`.

// MARK: accounts

struct AccountsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "accounts",
        abstract: "List configured Mail accounts.",
        subcommands: [AccountsList.self],
        defaultSubcommand: AccountsList.self)
}

struct AccountsList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List all Mail accounts (UUID, name, emails, type, enabled).")
    @OptionGroup var global: GlobalOptions
    func run() throws {
        try runGuarded(tool: "mail") {
            let dir = AccountDirectory()
            guard dir.isLoaded else {
                throw AppleError.upstream("could not read Mail accounts — is Mail.app available and automation permitted?")
            }
            let result = MailAccountsResult(accounts: dir.accounts, count: dir.accounts.count)
            if global.json { try Output.emit(tool: "mail", data: result) }
            else {
                for a in dir.accounts {
                    print("\(a.name) [\(a.account_type)]\(a.enabled ? "" : " (disabled)") — \(a.email_addresses.joined(separator: ", "))  \(a.id)")
                }
            }
        }
    }
}

// MARK: mailboxes

struct MailboxesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mailboxes",
        abstract: "List and create mailboxes.",
        subcommands: [MailboxesList.self, MailboxesCreate.self],
        defaultSubcommand: MailboxesList.self)
}

struct MailboxesList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List mailboxes (optionally for one account), with message counts.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Account name or UUID; omit for all accounts.") var account: String?
    @Flag(name: .long, inversion: .prefixedNo, help: "Include per-mailbox message counts (default: on).") var counts = true

    func run() throws {
        try runGuarded(tool: "mail") {
            let ctx = try MailContext()
            var accountUUID: String?
            if let account { accountUUID = try ctx.requireAccountUUID(account) }
            let dir = ctx.accounts()

            var out: [MailMailbox] = []
            for mb in ctx.index.mailboxes.sorted(by: { $0.url.accountID == $1.url.accountID ? $0.url.path.lowercased() < $1.url.path.lowercased() : $0.url.accountID < $1.url.accountID }) {
                if let accountUUID, mb.url.accountID != accountUUID { continue }
                out.append(MailMailbox(
                    account: dir.name(forUUID: mb.url.accountID),
                    account_id: mb.url.accountID,
                    name: mb.url.leaf,
                    path: mb.url.path,
                    url: mb.url.raw,
                    total_count: counts ? mb.total : nil,
                    unread_count: counts ? mb.unread : nil,
                    deleted_count: counts ? mb.deleted : nil,
                    is_label: mb.isLabel))
            }
            let result = MailMailboxesResult(account: account, mailboxes: out, count: out.count)
            if global.json { try Output.emit(tool: "mail", data: result) }
            else {
                for m in out {
                    let c = counts ? "  [\(m.total_count ?? 0) total, \(m.unread_count ?? 0) unread]" : ""
                    print("\(m.account): \(m.path)\(c)")
                }
            }
        }
    }
}

// MARK: unread-counts

struct UnreadCountsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unread-counts", abstract: "Per-mailbox or per-account unread counts.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Account name or UUID; omit for all accounts.") var account: String?
    @Flag(name: .long, help: "Return only per-account inbox unread totals.") var summary = false
    @Flag(name: .long, help: "Include mailboxes with zero unread.") var includeZero = false

    func run() throws {
        try runGuarded(tool: "mail") {
            // Sourced from Mail.app's live `unread count` (matches the MCP oracle; the
            // Envelope Index read-bit diverges from server-synced seen-state).
            // The AppleScript matches accounts by NAME, so map a UUID selector to its name first.
            var accountFilter = account
            if let account {
                let dir = AccountDirectory()
                guard let name = dir.displayName(for: account) else {
                    let known = dir.accounts.map(\.name).joined(separator: ", ")
                    throw AppleError.notFound("unknown account '\(account)'.\(known.isEmpty ? "" : " Known accounts: \(known).")")
                }
                accountFilter = name
            }
            let rows: [MailScript.UnreadRow]
            do {
                rows = try MailScript().unreadCounts(summary: summary, includeZero: includeZero, accountFilter: accountFilter)
            } catch {
                throw AppleError.upstream("could not read unread counts — is Mail.app running with automation permitted? (\(error))")
            }
            var total = 0
            if summary {
                var flat: [String: Int] = [:]
                for r in rows { flat[r.account, default: 0] += r.unread; total += r.unread }
                let result = MailUnreadCountsResult(summary: flat, by_account: nil, total_unread: total)
                if global.json { try Output.emit(tool: "mail", data: result) }
                else { for (k, v) in flat.sorted(by: { $0.value > $1.value }) { print("\(k): \(v)") } }
            } else {
                var nested: [String: [MailboxUnread]] = [:]
                for r in rows {
                    nested[r.account, default: []].append(MailboxUnread(path: r.mailbox, unread_count: r.unread))
                    total += r.unread
                }
                let result = MailUnreadCountsResult(summary: nil, by_account: nested, total_unread: total)
                if global.json { try Output.emit(tool: "mail", data: result) }
                else {
                    for (acct, boxes) in nested.sorted(by: { $0.key < $1.key }) {
                        print("\(acct):")
                        for b in boxes { print("  \(b.path): \(b.unread_count)") }
                    }
                }
            }
        }
    }
}

// MARK: doctor

struct MailDoctor: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Diagnose Mail access: Full Disk Access, Envelope Index, automation.")
    @OptionGroup var global: GlobalOptions

    struct Report: Encodable {
        let full_disk_access: Bool
        let envelope_index_path: String?
        let envelope_index_readable: Bool
        let mailbox_count: Int
        let account_count: Int
        let mail_automation: Bool
        let notes: [String]
    }

    func run() throws {
        try runGuarded(tool: "mail") {
            let pre = Permissions.preflight()
            var notes = pre.notes
            let dbPath = EnvelopeIndex.locateDB()
            var mailboxCount = 0
            var readable = false
            if let ctx = try? MailContext() {
                readable = true
                mailboxCount = ctx.index.mailboxes.count
            } else if dbPath != nil {
                notes.append("Envelope Index found but could not be opened.")
            } else {
                notes.append("No Envelope Index under ~/Library/Mail/V*/MailData/.")
            }
            let dir = AccountDirectory()
            if !dir.isLoaded { notes.append("Mail automation unavailable — account names and live reads (get content, selected) will be limited.") }
            let report = Report(
                full_disk_access: pre.full_disk_access,
                envelope_index_path: dbPath,
                envelope_index_readable: readable,
                mailbox_count: mailboxCount,
                account_count: dir.accounts.count,
                mail_automation: dir.isLoaded,
                notes: notes)
            if global.json { try Output.emit(tool: "mail", data: report) }
            else {
                print("Full Disk Access: \(report.full_disk_access)")
                print("Envelope Index:   \(report.envelope_index_path ?? "not found") (readable: \(report.envelope_index_readable), \(report.mailbox_count) mailboxes)")
                print("Mail automation:  \(report.mail_automation) (\(report.account_count) accounts)")
                for n in notes { print("• \(n)") }
            }
        }
    }
}
