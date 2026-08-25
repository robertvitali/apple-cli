import Foundation
import ArgumentParser
import AppleKit

// P3: static HTML dashboard + email export to files.

// MARK: dashboard (static HTML — MCP B's inbox_dashboard without the mcp-ui dependency)

struct AnalyticsDashboard: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dashboard", abstract: "Write a static HTML inbox dashboard (EXECUTES by default; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Output HTML path (default ./inbox-dashboard.html).") var out: String = "inbox-dashboard.html"

    struct Result: Encodable { let path: String; let total_unread: Int; let accounts: Int; let dry_run: Bool }

    func run() throws {
        try runGuarded(tool: "mail") {
            // Write-model v2 preamble. This command was review-caught with NO willExecute branch
            // (wrote HTML despite --dry-run) and a bare unconfined `--out` — an operator-supplied
            // write path that skipped confineWriteDestination, so `--out ~/.ssh/authorized_keys`
            // would have clobbered a key with HTML. Confinement runs on the dry-run path too
            // (preview honesty); allowOutsideHome keeps /tmp-style destinations legal while the
            // credential blocklist + control-character rejection stay absolute.
            try TestMode.validateWriteEnvironment()
            let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
            let willExecute = try global.willExecute(defaultDryRun: false)

            try refuseRawFinalLeafSymlink(out, action: "write the dashboard HTML to")
            let url = try confineWriteDestination(out, action: "write the dashboard HTML to", allowOutsideHome: true)
            let ctx = try MailContext()
            let unread = (try? MailScript().unreadCounts(summary: true, includeZero: true, accountFilter: nil)) ?? []
            let total = unread.reduce(0) { $0 + $1.unread }
            var f = EnvelopeIndex.MessageFilters(); f.mailboxName = "INBOX"; f.limit = 15
            let recent = try ctx.index.queryMessages(f).map { ctx.decodeSummary($0) }
            let html = MailDashboard.render(unread: unread, totalUnread: total, recent: recent)
            if willExecute {
                try refuseRawFinalLeafSymlink(out, action: "write the dashboard HTML to")
                try html.write(to: url, atomically: true, encoding: .utf8)
            }
            try Output.emit(tool: "mail", data: Result(path: url.path, total_unread: total,
                accounts: unread.count, dry_run: !willExecute), text: global.text, sandboxActive: sandboxActive)
        }
    }
}

// MARK: export

struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Export messages to files (txt/html) for backup or analysis (EXECUTES by default; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Account name or UUID.") var account: String
    @Option(name: .long, help: "Scope: single_email (needs --subject) or entire_mailbox.") var scope: String = "entire_mailbox"
    @Option(name: .long, help: "Subject keyword (required for single_email).") var subject: String?
    @Option(name: .long, help: "Mailbox to export from (default INBOX).") var mailbox: String = "INBOX"
    @Option(name: .long, help: "Directory to save exports (default ~/Desktop).") var dir: String = "~/Desktop"
    @Option(name: .long, help: "Format: txt or html.") var format: String = "txt"
    @Option(name: .long, help: "Max messages for entire_mailbox (safety cap).") var max: Int = 1000
    @Option(name: .long, help: "File layout: 'oracle' (default, oracle B's — single_email: <dir>/<subject>.<fmt>; entire_mailbox: <dir>/<mailbox>_export/<n>_<subject>.<fmt>, 1-based, '/' replaced by '-') or 'flat' (legacy CLI extra: <dir>/<id>-<subject:60>.<fmt>, collision-proof). NOTE: like the oracle, an existing file of the same name is OVERWRITTEN — the single_email name comes from the matched message's subject; pass --no-clobber to refuse instead.") var layout: String = "oracle"
    @Flag(name: .long, help: "Refuse to overwrite an existing file (the oracle, and the default, overwrite silently — oracle parity).") var noClobber = false

    /// gap45 pure core (pinned): the exported file names, oracle layout by default.
    /// Oracle transforms (analytics.py, verified verbatim): '/' → '-' is the ONLY character
    /// substitution; single_email = `<subject>.<fmt>` directly in the save dir; entire_mailbox
    /// = `<mailbox>_export/<n>_<subject>.<fmt>` with a 1-based index (the '/'→'-' pass runs
    /// over the whole `n_subject` name, and over the MAILBOX segment so a nested name cannot
    /// escape the export dir). CLI deviations, both disclosed: names are capped at 150 chars
    /// before the extension (the oracle would hit the filesystem's 255-byte limit and error),
    /// and the legacy 'flat' layout (`<id>-<subject:60>`) remains as a collision-proof extra.
    static func plannedFiles(layout: String, scope: String, mailbox: String, format: String,
                             messages: [(id: String, subject: String)]) -> [String] {
        func deslash(_ s: String) -> String { s.replacingOccurrences(of: "/", with: "-") }
        // BYTE cap, not a Character cap (review): 150 CJK/emoji graphemes are 450-600 UTF-8
        // bytes, which still breaches the filesystem's 255-byte component limit the cap
        // exists for — the repo's recurring grapheme-vs-code-unit class. Whole Characters
        // only (never split a scalar); empty result falls back to "untitled" so a blank
        // subject cannot yield a HIDDEN dotfile like the oracle's ".txt" (disclosed).
        func capped(_ s: String, bytes: Int = 150) -> String {
            var out = ""
            var used = 0
            for ch in s {
                used += ch.utf8.count
                if used > bytes { break }
                out.append(ch)
            }
            return out.isEmpty ? "untitled" : out
        }
        if layout == "flat" {
            return messages.map { "\($0.id)-\(capped(deslash($0.subject), bytes: 60)).\(format)" }
        }
        if scope == "single_email" {
            return messages.map { "\(capped(deslash($0.subject))).\(format)" }
        }
        let sub = capped(deslash(mailbox)) + "_export"
        return messages.enumerated().map { i, m in
            "\(sub)/\(capped(deslash("\(i + 1)_\(m.subject)"))).\(format)"
        }
    }

    struct Result: Encodable {
        let exported: Int
        /// The directory files actually land in — under the oracle layout's entire_mailbox
        /// scope that is the `<mailbox>_export/` subdir, matching the oracle's `Location:`
        /// report (review L3); otherwise the confined --dir itself.
        let directory: String
        let files: [String]
        let format: String
        let body_source: String
        let dry_run: Bool
        /// File names whose write failed (per-message tolerance, review M3) — the export
        /// continues past them like the oracle; omitted when none.
        var write_failures: [String]? = nil
        /// Oracle B reports BOTH numbers (analytics.py:627-628 emits "Total emails in mailbox"
        /// and "Exported"), so a caller can tell a capped export from a complete one. A single
        /// count cannot distinguish "the mailbox held 800" from "capped at 1000 of 40,000".
        let total_in_mailbox: Int
        let capped: Bool
    }

    func run() throws {
        try runGuarded(tool: "mail") {
            // Write-model v2 preamble. Export EXECUTES by default (oracle B export_emails
            // writes on call); resolveExportDirectory path confinement is bucket 1, unchanged.
            try TestMode.validateWriteEnvironment()
            let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
            let willExecute = try global.willExecute(defaultDryRun: false)

            guard format == "txt" || format == "html" else { throw AppleError.validation("--format must be txt or html.") }
            guard layout == "oracle" || layout == "flat" else {
                throw AppleError.validation("invalid --layout '\(layout)'. Use: oracle, flat.")
            }
            // Review M9: --max was the one write-surface bound without a sign guard (the query
            // clamp turned -1 into a misleading not_found). And the oracle returns a SUCCESS
            // with Exported: 0 for max_emails=0 (its `exit repeat` fires before the first
            // message), where the CLI's no-messages guard threw not_found.
            guard max >= 0 else { throw AppleError.validation("--max must be >= 0.") }
            // Oracle B: "Error: Invalid scope '<s>'. Use: single_email, entire_mailbox"
            // (tools/analytics.py). An unknown scope previously fell through to the
            // entire_mailbox branch and exported the whole mailbox — the opposite of narrowing.
            // Pure flag checks hoisted ABOVE the store open (store-independent usage errors).
            guard ["single_email", "entire_mailbox"].contains(scope) else {
                throw AppleError.validation("invalid --scope '\(scope)'. Use: single_email, entire_mailbox.")
            }
            if scope == "single_email" {
                // TRIMMED emptiness, matching every other subject-keyword guard: a
                // whitespace-only value survives a bare isEmpty test AND the index's empty-skip,
                // binding a `% %` LIKE that nearly every real subject matches (review-caught).
                guard let subject, !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AppleError.validation("single_email scope requires a non-empty --subject.")
                }
            }
            let ctx = try MailContext()
            let uuid = try ctx.requireAccountUUID(account)
            // An unknown --mailbox previously surfaced as "no messages matched" — the oracle
            // raises "Mailbox not found" (security L3 / oracle parity, same guard as search).
            try requireMailboxKnown(ctx: ctx, name: mailbox, accountUUID: uuid)
            var f = EnvelopeIndex.MessageFilters()
            f.accountUUID = uuid; f.mailboxName = mailbox
            if scope == "single_email" {
                f.subjectContains = subject; f.limit = 1
            } else {
                f.limit = max
            }
            var messages = try ctx.index.queryMessages(f).map { ctx.decodeSummary($0) }
            if scope == "entire_mailbox", max == 0 { messages = [] }
            guard scope == "entire_mailbox" && max == 0 || !messages.isEmpty else {
                throw AppleError.notFound("no messages matched to export.")
            }

            // single_email exports the FULL body (AppleScript, bounded to one message = a strict
            // superset of MCP B); entire_mailbox uses the fast indexed preview (documented).
            // The LIVE fetch is execute-only (Q12 [12]: a preview that writes nothing still
            // paid Mail's unindexed body scan — a preview with side costs is not a preview);
            // the preview REPORTS the planned source, which can only differ from execute's if
            // the live fetch fails there and falls back (disclosed here, not silently wrong).
            var bodySource = "indexed_preview"
            if scope == "single_email", let iid = messages[0].internet_message_id, !iid.isEmpty {
                if !willExecute {
                    bodySource = "full_body"
                } else if let body = try? MailScript().body(internetMessageID: iid, accountName: messages[0].account) {
                    messages[0].content = body
                    bodySource = "full_body"
                }
            }

            let outDir = try resolveExportDirectory(dir)
            // Oracle B reports the mailbox total alongside the exported count so a capped run is
            // visible — but ONLY for entire_mailbox, which is the only scope `--max` applies to
            // (analytics.py:627-628 lives in the mailbox branch; the single_email branch emits
            // neither number). Reporting a mailbox-wide total for a one-message subject export
            // produced a bogus `capped: true` retry signal, so single_email reports itself.
            let totalInMailbox: Int
            if scope == "single_email" {
                totalInMailbox = messages.count
            } else {
                var countFilters = f; countFilters.limit = Int.max; countFilters.offset = 0
                totalInMailbox = (try? ctx.index.countMessages(countFilters)) ?? messages.count
            }
            // gap45: file names + directory shape are the ORACLE'S by default
            // (analytics.py:500-513 single, :570-585 mailbox) — computed ONCE by the pure
            // builder so the dry-run preview and --execute agree byte-for-byte.
            let names = ExportCommand.plannedFiles(layout: layout, scope: scope, mailbox: mailbox,
                                                   format: format,
                                                   messages: messages.map { (id: $0.id, subject: $0.subject) })
            let planned = names.map { outDir.appendingPathComponent($0).path }
            // Review L3: the oracle reports the `<mailbox>_export` dir as its Location; report
            // the directory files actually land in (derived from the planned names so preview
            // and execute agree).
            let reportedDir = names.first.flatMap { n -> String? in
                n.contains("/") ? outDir.appendingPathComponent(String(n.split(separator: "/")[0])).path : nil
            } ?? outDir.path
            // `--dry-run` was ADVERTISED in --help and silently ignored: the command mkdir -p'd
            // and wrote one file per message regardless. On a command that writes message bodies
            // to disk that is the worst kind of ignored parameter, so the preview now returns
            // before any filesystem mutation — no directory creation, no writes.
            guard willExecute else {
                try Output.emit(tool: "mail", data: Result(
                    exported: 0, directory: reportedDir, files: planned, format: format,
                    body_source: bodySource, dry_run: true,
                    total_in_mailbox: totalInMailbox, capped: totalInMailbox > messages.count), text: global.text, sandboxActive: sandboxActive)
                return
            }
            var files: [String] = []
            var writeFailures: [String] = []
            for (m, name) in zip(messages, names) {
                let url = outDir.appendingPathComponent(name)
                // Create the per-file parent (the oracle's `<mailbox>_export/` subdir under
                // the entire_mailbox layout; outDir itself otherwise) — mkdir -p semantics.
                let parent = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                // Security M1: confineWriteDestination resolved symlinks on the TOP directory
                // only; a pre-planted `<mailbox>_export` SYMLINK inside it would route message
                // bodies outside the confined dir. Re-confine the RESOLVED parent per write.
                let realParent = parent.resolvingSymlinksInPath().path
                let realOut = outDir.resolvingSymlinksInPath().path
                guard realParent == realOut || realParent.hasPrefix(realOut + "/") else {
                    throw AppleError.mailSafety("export subdirectory '\(parent.path)' resolves outside '\(realOut)' — refusing to write through it.")
                }
                // Oracle B OVERWRITES an existing file of the same name (`set eof of fileRef
                // to 0`) — kept as the parity default; --no-clobber opts out fail-loud (M3).
                // NOTE (review L6): under the oracle naming the single_email file carries no
                // id, and the CLI picks the index's newest subject match where the oracle
                // picks its live-scan first — two runs can overwrite the same path with
                // DIFFERENT messages. Disclosed on row 42; --no-clobber is the guard.
                if noClobber, FileManager.default.fileExists(atPath: url.path) {
                    throw AppleError.mailSafety("refusing to overwrite existing file '\(url.path)' (--no-clobber).")
                }
                let content = (format == "html") ? MailExport.html(m) : MailExport.text(m)
                do {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                    files.append(url.path)
                } catch {
                    // Review M3: the oracle wraps each message in try/on-error and CONTINUES —
                    // one unwritable name must not abort the export with N files already on
                    // disk. Recorded, never silent.
                    writeFailures.append(url.lastPathComponent)
                }
            }
            try Output.emit(tool: "mail", data: Result(
                exported: files.count, directory: reportedDir, files: files, format: format,
                body_source: bodySource, dry_run: false,
                write_failures: writeFailures.isEmpty ? nil : writeFailures,
                total_in_mailbox: totalInMailbox, capped: totalInMailbox > files.count), text: global.text, sandboxActive: sandboxActive)
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
/// `AppleKit.sensitiveWriteDir` so the two surfaces cannot drift apart.
func resolveExportDirectory(_ raw: String) throws -> URL {
    // Delegates to the shared guard so export and `attachments save` cannot drift apart —
    // they refuse exactly the same path set.
    try confineWriteDestination(raw, action: "export messages into")
}
