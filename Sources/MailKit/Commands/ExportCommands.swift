import Foundation
import ArgumentParser
import AppleKit

// P3: static HTML dashboard + email export to files.

// MARK: dashboard (static HTML — MCP B's inbox_dashboard without the mcp-ui dependency)

struct AnalyticsDashboard: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dashboard", abstract: "Write a static HTML inbox dashboard (no server).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Output HTML path (default ./inbox-dashboard.html).") var out: String = "inbox-dashboard.html"

    struct Result: Encodable { let path: String; let total_unread: Int; let accounts: Int }

    func run() throws {
        try runGuarded(tool: "mail") {
            let ctx = try MailContext()
            let unread = (try? MailScript().unreadCounts(summary: true, includeZero: true, accountFilter: nil)) ?? []
            let total = unread.reduce(0) { $0 + $1.unread }
            var f = EnvelopeIndex.MessageFilters(); f.mailboxName = "INBOX"; f.limit = 15
            let recent = try ctx.index.queryMessages(f).map { ctx.decodeSummary($0) }
            let html = MailDashboard.render(unread: unread, totalUnread: total, recent: recent)
            let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            try html.write(to: url, atomically: true, encoding: .utf8)
            try Output.emit(tool: "mail", data: Result(path: url.path, total_unread: total, accounts: unread.count))
        }
    }
}

// MARK: export

struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Export messages to files (txt/html) for backup or analysis.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Account name or UUID.") var account: String
    @Option(name: .long, help: "Scope: single_email (needs --subject) or entire_mailbox.") var scope: String = "entire_mailbox"
    @Option(name: .long, help: "Subject keyword (required for single_email).") var subject: String?
    @Option(name: .long, help: "Mailbox to export from (default INBOX).") var mailbox: String = "INBOX"
    @Option(name: .long, help: "Directory to save exports (default ~/Desktop).") var dir: String = "~/Desktop"
    @Option(name: .long, help: "Format: txt or html.") var format: String = "txt"
    @Option(name: .long, help: "Max messages for entire_mailbox (safety cap).") var max: Int = 1000

    struct Result: Encodable { let exported: Int; let directory: String; let files: [String]; let format: String; let body_source: String }

    func run() throws {
        try runGuarded(tool: "mail") {
            guard format == "txt" || format == "html" else { throw AppleError.validation("--format must be txt or html.") }
            let ctx = try MailContext()
            let uuid = try ctx.requireAccountUUID(account)
            var f = EnvelopeIndex.MessageFilters()
            f.accountUUID = uuid; f.mailboxName = mailbox
            // Oracle B: "Error: Invalid scope '<s>'. Use: single_email, entire_mailbox"
            // (tools/analytics.py). An unknown scope previously fell through to the
            // entire_mailbox branch and exported the whole mailbox — the opposite of narrowing.
            guard ["single_email", "entire_mailbox"].contains(scope) else {
                throw AppleError.validation("invalid --scope '\(scope)'. Use: single_email, entire_mailbox.")
            }
            if scope == "single_email" {
                guard let subject, !subject.isEmpty else { throw AppleError.validation("single_email scope requires --subject.") }
                f.subjectContains = subject; f.limit = 1
            } else {
                f.limit = max
            }
            var messages = try ctx.index.queryMessages(f).map { ctx.decodeSummary($0) }
            guard !messages.isEmpty else { throw AppleError.notFound("no messages matched to export.") }

            // single_email exports the FULL body (AppleScript, bounded to one message = a strict
            // superset of MCP B); entire_mailbox uses the fast indexed preview (documented).
            var bodySource = "indexed_preview"
            if scope == "single_email", let iid = messages[0].internet_message_id,
               let body = try? MailScript().body(internetMessageID: iid, accountName: messages[0].account) {
                messages[0].content = body
                bodySource = "full_body"
            }

            let outDir = try resolveExportDirectory(dir)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            var files: [String] = []
            for m in messages {
                let safe = m.subject.replacingOccurrences(of: "/", with: "-").prefix(60)
                let name = "\(m.id)-\(safe).\(format)"
                let url = outDir.appendingPathComponent(String(name))
                let content = (format == "html") ? MailExport.html(m) : MailExport.text(m)
                try content.write(to: url, atomically: true, encoding: .utf8)
                files.append(url.path)
            }
            try Output.emit(tool: "mail", data: Result(exported: files.count, directory: outDir.path, files: files, format: format, body_source: bodySource))
        }
    }
}

// MARK: renderers (pure)

enum MailExport {
    static func text(_ m: MailMessage) -> String {
        var s = ""
        s += "Subject: \(m.subject)\n"
        s += "From: \(m.sender)\n"
        if let to = m.to { s += "To: \(to.joined(separator: ", "))\n" }
        if let cc = m.cc, !cc.isEmpty { s += "Cc: \(cc.joined(separator: ", "))\n" }
        s += "Date: \(m.date_received ?? "")\n"
        s += "Account: \(m.account)   Mailbox: \(m.mailbox)\n"
        if let id = m.internet_message_id { s += "Message-ID: <\(id)>\n" }
        s += "\n"
        s += (m.content ?? m.snippet ?? "")
        s += "\n"
        return s
    }

    static func html(_ m: MailMessage) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
        }
        let body = esc(m.content ?? m.snippet ?? "")
        return """
        <!doctype html><meta charset="utf-8"><title>\(esc(m.subject))</title>
        <body style="font-family:-apple-system,sans-serif;max-width:720px;margin:2rem auto">
        <h2>\(esc(m.subject))</h2>
        <p><b>From:</b> \(esc(m.sender))<br>
        <b>Date:</b> \(esc(m.date_received ?? ""))<br>
        <b>Account:</b> \(esc(m.account)) / \(esc(m.mailbox))</p>
        <hr><pre style="white-space:pre-wrap">\(body)</pre>
        </body>
        """
    }
}

enum MailDashboard {
    static func render(unread: [MailScript.UnreadRow], totalUnread: Int, recent: [MailMessage]) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let accountRows = unread.sorted { $0.unread > $1.unread }
            .map { "<tr><td>\(esc($0.account))</td><td style='text-align:right'>\($0.unread)</td></tr>" }.joined()
        let recentRows = recent.map {
            "<li><b>\(esc($0.subject))</b><br><small>\(esc($0.sender)) — \(esc($0.date_received ?? "")) — \(esc($0.account))</small></li>"
        }.joined()
        return """
        <!doctype html><meta charset="utf-8"><title>Mail Dashboard</title>
        <body style="font-family:-apple-system,sans-serif;max-width:760px;margin:2rem auto;color:#222">
        <h1>Inbox Dashboard</h1>
        <p><b>Total unread:</b> \(totalUnread)</p>
        <h2>Unread by account</h2>
        <table style="border-collapse:collapse"><thead><tr><th style='text-align:left'>Account</th><th>Unread</th></tr></thead>
        <tbody>\(accountRows)</tbody></table>
        <h2>Recent (15)</h2>
        <ul>\(recentRows)</ul>
        <hr><small>Generated by apple mail analytics dashboard</small>
        </body>
        """
    }
}

/// Resolve + guard an export destination, matching oracle B's `export_emails` path validation
/// (`tools/analytics.py`): realpath first, then require the result to be under `$HOME`, then
/// refuse the sensitive-directory list.
///
/// Export WRITES MESSAGE BODIES to disk, so an unguarded `--dir` could scatter mail content into
/// `~/.ssh` or outside the home entirely — the CLI previously accepted any path. Resolving
/// symlinks BEFORE the checks is what stops a symlink into a blocked directory from bypassing
/// them (the same ordering `resolveAttachmentPath` uses), and the blocklist itself is the shared
/// `sensitiveAttachmentDir` so the two surfaces cannot drift apart.
func resolveExportDirectory(_ raw: String) throws -> URL {
    let expanded = (raw as NSString).expandingTildeInPath
    let resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
    let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
    let path = resolved.path
    guard path == home || path.hasPrefix(home + "/") else {
        throw AppleError.mailSafety("export directory must be under your home directory (\(home)); got: \(path)")
    }
    // Check the resolved path AND the pre-resolution literal, so a sensitive dir that is itself a
    // symlink is caught too.
    if let dir = sensitiveAttachmentDir(path, home: home) ?? sensitiveAttachmentDir(expanded, home: home) {
        throw AppleError.mailSafety("cannot export messages into a sensitive directory (\(dir)) — refusing.")
    }
    return resolved
}
