import Foundation
import ArgumentParser
import AppleKit

// P2 compose surface: send, reply, forward, draft, draft-rich. Destructive/outbound verbs
// DEFAULT to a dry-run preview; a real send requires --execute AND APPLE_TEST_MODE AND a
// self-only recipient (TestMode). Live delivery is wired for ALL body types — plain text (Mail
// `content`), file attachments (AppleScript `make new attachment`), and HTML (multipart `.eml`
// opened as an X-Unsent outgoing message and sent, since Mail's AppleScript `content` is
// plain-text only). EVERY path is gated by the same self-only `guardOutbound` before any send;
// there is no path that reaches an AppleScript send without it (see AGENTS.md Safety).

/// Split repeatable + comma-joined recipient options into a flat address list.
func splitRecipients(_ raw: [String]) -> [String] {
    raw.flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// Common outbound guard: refuse a live send unless test-mode is on and EVERY recipient is
/// the operator's own allowlisted address. Never sends to a non-self recipient autonomously.
/// Refusals are typed `safety_violation` (exit 77) so they read as deliberate, not as bugs.
func guardOutbound(recipients: [String], testMode: Bool) throws {
    // Two-factor, matching every sibling write domain: the --test-mode flag AND APPLE_TEST_MODE=1.
    guard testMode && TestMode.isEnabled else {
        throw AppleError.mailSafety("live send requires --test-mode AND APPLE_TEST_MODE=1; refusing. Use the default dry-run to preview.")
    }
    guard !recipients.isEmpty else { throw AppleError.validation("no recipients to send to.") }
    // Fail-closed: EVERY recipient must be the operator's allowlisted self-address. Compare
    // case-insensitively (email addresses are case-insensitive) so a legit self-reply whose
    // stored sender_address differs in case from APPLE_TEST_RECIPIENTS isn't wrongly refused.
    let allow = Set(TestMode.allowedRecipients.map { $0.lowercased() })
    for r in recipients where !allow.contains(r.lowercased()) {
        throw AppleError.mailSafety("recipient '\(r)' is not in the self-only test allowlist — refusing. Set APPLE_TEST_RECIPIENTS to your own address.")
    }
}

/// Resolve + validate a single attachment path: expand `~`, require it to exist and be a REGULAR
/// file (a directory / missing path is rejected). Returns the resolved absolute path for both the
/// AppleScript attachment route and the `.eml` builder. Note: the self-only `guardOutbound` is the
/// real containment for attachment CONTENT — a sent attachment can only ever reach the operator's
/// own address, so this is existence/type validation, not a content sandbox. Missing/non-regular
/// files are `not_found` (exit 65), matching the prior inline behavior.
/// Executable / script extensions blocked from attachment sends by default (mirrors s-morgan
/// `validate_attachment_type`'s `dangerous_extensions`). Blocking is the parity default; there is
/// no allow-executables override yet.
let dangerousAttachmentExtensions: Set<String> = [
    "exe", "bat", "cmd", "com", "scr", "pif", "vbs", "vbe", "js", "jse", "wsf", "wsh",
    "msi", "msp", "scf", "lnk", "inf", "reg", "ps1", "psm1", "app", "deb", "rpm", "sh",
    "bash", "csh", "ksh", "zsh", "command",
]

func resolveAttachmentPath(_ raw: String) throws -> String {
    let expanded = (raw as NSString).expandingTildeInPath
    // Resolve symlinks BEFORE the sensitive-dir check so a symlink into ~/.ssh (etc.) cannot
    // bypass it (matches patrickfreyer's realpath). The real path is also what Mail attaches.
    let path = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
        throw AppleError.notFound("attachment not found or not a regular file: \(raw)")
    }
    // Reject oversized attachments before handing the file to Mail (a clean pre-send refusal vs an
    // opaque Mail hang/failure) — matches s-morgan send_email_with_attachments' 25 MB default cap.
    let maxBytes = 25 * 1024 * 1024
    if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber,
       size.intValue > maxBytes {
        throw AppleError.validation("attachment exceeds the 25 MB send limit (\(size.intValue) bytes): \(raw)")
    }
    // Refuse dangerous executable/script types by default (s-morgan validate_attachment_type,
    // which matches on filename `endswith` — so a file literally named ".sh" is blocked too, which
    // NSString.pathExtension would miss).
    let base = (path as NSString).lastPathComponent.lowercased()
    if let blockedExt = dangerousAttachmentExtensions.first(where: { base.hasSuffix(".\($0)") }) {
        throw AppleError.validation("attachment type '.\(blockedExt)' is blocked (executable/script); refusing: \(raw)")
    }
    // Refuse reading from sensitive credential/config directories (patrickfreyer sensitive_dirs) —
    // a safety refusal (don't exfiltrate keys/tokens as an attachment). Check BOTH the resolved
    // path (defeats a symlink INTO a sensitive dir) AND the tilde-expanded literal (defeats a
    // sensitive dir that is ITSELF a symlink, e.g. a stow-managed `~/.ssh` -> `~/dotfiles/ssh`).
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if let dir = sensitiveAttachmentDir(path, home: home) ?? sensitiveAttachmentDir(expanded, home: home) {
        throw AppleError.mailSafety("cannot attach a file from a sensitive directory (\(dir)) — refusing.")
    }
    return path
}

/// The sensitive credential/config directory a resolved path falls under, or nil (mirrors
/// patrickfreyer `sensitive_dirs`). Pure — unit-testable with synthetic paths, no real files.
func sensitiveAttachmentDir(_ resolvedPath: String, home: String) -> String? {
    let dirs = [".ssh", ".gnupg", ".config", ".aws", ".claude",
                "Library/Keychains", "Library/LaunchAgents", "Library/LaunchDaemons"]
        .map { home + "/" + $0 }
    return dirs.first(where: { resolvedPath == $0 || resolvedPath.hasPrefix($0 + "/") })
}

/// Read already-resolved attachment paths into `EmlBuilder.Attachment` parts (for the HTML/`.eml`
/// route). A path that can't be read (e.g. a TOCTOU race after `resolveAttachmentPath`) is
/// `not_found` rather than a silent drop.
func attachmentsFromPaths(_ paths: [String]) throws -> [EmlBuilder.Attachment] {
    try paths.map { path in
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw AppleError.notFound("attachment could not be read: \(path)")
        }
        let name = (path as NSString).lastPathComponent
        return EmlBuilder.Attachment(filename: name, mimeType: EmlBuilder.mimeType(forFilename: name), data: data)
    }
}

/// The `.eml` output path: an explicit `--out`, else a labeled temp file.
func emlDestURL(out: String?) -> URL {
    let p = out ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("apple-cli-\(TestMode.sandboxPrefix)-\(UUID().uuidString).eml").path
    return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
}

struct SendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "send", abstract: "Compose an email (dry-run preview by default; plain/HTML/attachments; mode send|draft|open).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Recipient (repeatable; comma-joined ok).") var to: [String] = []
    @Option(name: .long) var subject: String = ""
    @Option(name: .long, help: "Plain-text body (fallback when --html is set).") var body: String = ""
    @Option(name: .long, help: "CC recipient (repeatable).") var cc: [String] = []
    @Option(name: .long, help: "BCC recipient (repeatable).") var bcc: [String] = []
    @Option(name: .long, help: "Attachment file path (repeatable).") var attach: [String] = []
    @Option(name: .long, help: "HTML body. Default opens a rendered compose window for review (reliable); add --gui-send to auto-send.") var html: String?
    @Option(name: .long, help: "Delivery mode: send | draft | open.") var mode: String = "send"
    @Flag(name: .long, help: "Auto-send an --html message via GUI keystroke automation (needs Accessibility, steals focus, fragile). Opt-in.") var guiSend = false
    @Option(name: .long, help: "Sending account (name or UUID).") var account: String?
    @Option(name: .long, help: "Write the generated .eml to this path (html/attachment sends).") var out: String?

    struct Preview: Encodable {
        let action: String; let mode: String; let account: String?; let sender_address: String?
        let to: [String]; let cc: [String]; let bcc: [String]
        let subject: String; let has_html: Bool; let attachments: [String]
        let eml_path: String?; let dry_run: Bool; let executed: Bool; let opened: Bool; let drafted: Bool; let note: String?
    }

    func run() throws {
        try runGuarded(tool: "mail") {
            let toL = splitRecipients(to), ccL = splitRecipients(cc), bccL = splitRecipients(bcc)
            guard !toL.isEmpty else { throw AppleError.validation("--to is required.") }
            guard ["send", "draft", "open"].contains(mode) else { throw AppleError.validation("--mode must be send, draft, or open.") }
            // --gui-send is the explicit opt-in for GUI-keystroke HTML auto-send; it applies
            // ONLY to an --html send.
            if guiSend {
                guard html != nil else { throw AppleError.validation("--gui-send only applies to an --html send.") }
                guard mode == "send" else { throw AppleError.validation("--gui-send requires --mode send.") }
            }

            // Live actions across the three delivery modes:
            //  send  — plain/attachment AUTO-SEND (reliable AppleScript), HTML GUI auto-send
            //          (--gui-send; fragile), or HTML reliable OPEN (--html without --gui-send).
            //  open  — render a compose window for review (ANY body type), no send.
            //  draft — save to Drafts (ANY body type), no send.
            let willAutoSend = global.willExecute && mode == "send" && html == nil
            let willGuiSend = global.willExecute && guiSend
            let willOpenHtml = global.willExecute && mode == "send" && html != nil && !guiSend
            let willOpen = global.willExecute && mode == "open"
            let willDraft = global.willExecute && mode == "draft"
            let willLiveOutbound = willAutoSend || willGuiSend || willOpenHtml || willOpen || willDraft
            // Paths that render a compose window or send need the self-only recipient gate; a
            // (non-sending) draft does not — it gets the label + test-mode gate below instead.
            let willSelfGuarded = willAutoSend || willGuiSend || willOpenHtml || willOpen

            // Self-only outbound gate FIRST — before any attachment read, .eml/.html build, or
            // AppleScript/GUI action. No self-guarded path below reaches Mail without passing this.
            if willSelfGuarded { try guardOutbound(recipients: toL + ccL + bccL, testMode: global.testMode) }
            // A live open / HTML action needs a real subject — a compose window / sent message with
            // an empty subject is a mistake; refuse before building anything.
            if willGuiSend || willOpenHtml || willOpen {
                guard !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AppleError.validation("--subject is required for a live --mode open / --html action; refusing an empty/whitespace subject.")
                }
            }
            // --mode draft saves a PERSISTENT Drafts item, so it takes the same label + test-mode
            // gate as `draft create` (NOT the self-only recipient guard — a draft is not a send).
            if willDraft {
                guard global.testMode && TestMode.isEnabled else {
                    throw AppleError.mailSafety("saving a draft requires --test-mode AND APPLE_TEST_MODE=1; refusing. Use the default dry-run to preview.")
                }
                guard subject.hasPrefix(TestMode.sandboxPrefix) else {
                    throw AppleError.mailSafety("draft --subject must be a labeled test item (start with \"\(TestMode.sandboxPrefix)\") — refusing.")
                }
            }

            // Resolve --account to a send (From) identity for EVERY live path: the send paths set
            // the outgoing message `sender`; the open path uses it as the `.eml` `From:` so Mail
            // selects the account. Resolved to the account's bare address (a name/UUID `From:`
            // would be malformed and ignored). An unknown/addressless account is a not_found before
            // any Mail action. Only resolved on a LIVE outbound path so a headless dry-run does not
            // require Mail; the dry-run preview `.eml` falls back to the raw --account string below.
            var senderAddress: String?
            if let account, willLiveOutbound {
                guard let addr = AccountDirectory().sendAddress(for: account) else {
                    throw AppleError.notFound("account '\(account)' not found or has no send address.")
                }
                senderAddress = addr
            }

            // Resolve attachment paths once (existence + regular-file), then generate the .eml
            // whenever HTML or attachments are present, OR --mode open (which opens a rendered
            // compose window for ANY body type): it is the preview artifact, the `--out` target,
            // AND the delivery vehicle for the reliable HTML OPEN / --mode open / draft-HTML paths.
            // From: uses the resolved address on a live path, else the raw --account (headless preview).
            let attPaths = try attach.map { try resolveAttachmentPath($0) }
            var emlPath: String?
            if html != nil || !attPaths.isEmpty || willOpen {
                let atts = try attachmentsFromPaths(attPaths)
                // emitBcc: this .eml is only ever OPENED in a compose window (Mail moves Bcc to the
                // bcc field + strips the header on send) or written to --out — never wire-sent — so
                // carrying --bcc into it is safe and lets the open path honor --bcc.
                let eml = try EmlBuilder(from: senderAddress ?? account, to: toL, cc: ccL, bcc: bccL, subject: subject,
                                     textBody: body.isEmpty ? nil : body, htmlBody: html, attachments: atts,
                                     emitBcc: true).build()
                let dest = emlDestURL(out: out)
                try eml.write(to: dest, atomically: true, encoding: .utf8)
                emlPath = dest.path
            }

            var executed = false
            var opened = false
            var drafted = false
            var note: String?
            if willGuiSend {
                // Opt-in HTML auto-send via GUI keystrokes (fragile — see MailScript.sendHtmlViaGui).
                // The raw HTML goes to a temp file the script reads via `cat` (never interpolated).
                let htmlTmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("apple-cli-\(TestMode.sandboxPrefix)-\(UUID().uuidString).html")
                try (html ?? "").write(to: htmlTmp, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: htmlTmp) }
                try MailScript().sendHtmlViaGui(htmlPath: htmlTmp.path, subject: subject,
                    to: toL, cc: ccL, bcc: bccL, attachmentPaths: attPaths, sender: senderAddress)
                executed = true
                note = "sent via GUI keystroke automation (--gui-send); required Accessibility permission and stole window focus"
            } else if willOpenHtml, let emlPath {
                // Reliable HTML path: open the rendered .eml as a compose window for review.
                try MailScript().openEml(path: emlPath)
                opened = true
                note = "HTML rendered in a Mail compose window for review — click Send, or re-run with --gui-send to auto-send (GUI automation; needs Accessibility). The .eml is kept at eml_path."
            } else if willAutoSend {
                if !attPaths.isEmpty {
                    // Attachments, no HTML: direct AppleScript route (matches send_email_with_attachments).
                    try MailScript().sendWithAttachments(subject: subject, body: body, to: toL, cc: ccL, bcc: bccL, attachmentPaths: attPaths, sender: senderAddress)
                } else {
                    // Plain text.
                    try MailScript().send(subject: subject, body: body, to: toL, cc: ccL, bcc: bccL, sender: senderAddress)
                }
                executed = true
            } else if willOpen, let emlPath {
                // --mode open: render the .eml as a compose window for review (ANY body type). No send.
                try MailScript().openEml(path: emlPath)
                opened = true
                note = "compose window opened for review (--mode open) — not sent; click Send in Mail if desired. The .eml is kept at eml_path."
            } else if willDraft {
                // --mode draft: save to Drafts (no send). Plain/attachment bodies save DIRECTLY via
                // AppleScript (`save` an outgoing message) — reliable. HTML cannot be saved to Drafts
                // headlessly (Mail's AppleScript `content` is plain-text only, and a
                // LaunchServices-opened `.eml` window never surfaces in `outgoing messages` to be
                // saved). Rather than force-open a compose window that can't auto-save AND can't be
                // closed programmatically (leaving a stuck window), we WRITE the rendered `.eml` and
                // tell the operator how to file it. drafted:false is honest — it is NOT yet in Drafts.
                if html != nil {
                    drafted = false
                    note = "HTML can't be saved to Drafts headlessly (Mail limitation) — the rendered .eml is at eml_path; open it (`apple mail draft-rich --open`, or `open <eml_path>`) and press Cmd-S to file it in Drafts."
                } else {
                    try MailScript().saveDraft(subject: subject, body: body, to: toL, cc: ccL, bcc: bccL,
                                               attachmentPaths: attPaths, sender: senderAddress)
                    drafted = true
                }
            } else if global.willExecute {
                note = "mode '\(mode)' is preview-only; use --mode send to deliver"
            }

            let preview = Preview(action: "send", mode: mode, account: account, sender_address: senderAddress,
                                  to: toL, cc: ccL, bcc: bccL,
                                  subject: subject, has_html: html != nil, attachments: attach,
                                  eml_path: emlPath, dry_run: !global.willExecute, executed: executed, opened: opened, drafted: drafted, note: note)
            try Output.emit(tool: "mail", data: preview)
        }
    }
}

struct ReplyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reply", abstract: "Reply to a message by id or --subject (dry-run preview by default).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Message id to reply to (ROWID / RFC Message-ID); or use --subject.") var id: String?
    @Option(name: .long, help: "Reply to the newest message matching this subject keyword.") var subject: String?
    @Option(name: .long, help: "Account (name or UUID) — used for --subject lookup AND as the send-from identity.") var account: String?
    @Option(name: .long) var body: String
    @Flag(name: .long, help: "Reply to all recipients.") var all = false
    @Option(name: .long) var cc: [String] = []
    @Option(name: .long) var bcc: [String] = []
    @Option(name: .long, help: "HTML reply body. Default opens a rendered compose window for review; add --gui-send to auto-send.") var html: String?
    @Option(name: .long, help: "Attachment file path (repeatable).") var attach: [String] = []
    @Option(name: .long, help: "Delivery mode: send | draft | open.") var mode: String = "send"
    @Flag(name: .long, help: "Auto-send an --html reply via GUI keystroke automation (needs Accessibility, steals focus, fragile). Opt-in.") var guiSend = false

    struct Preview: Encodable {
        let action: String; let target: String; let matched_message_id: String?
        let reply_all: Bool; let mode: String; let has_html: Bool; let sender_address: String?
        let to: [String]; let cc: [String]; let bcc: [String]; let attachments: [String]
        let dry_run: Bool; let executed: Bool; let opened: Bool; let note: String?
    }

    func run() throws {
        try runGuarded(tool: "mail") {
            let ctx = try MailContext()
            // Resolve the target to a full summary (need original sender + subject to compose).
            let row: [String: String?]
            if let id {
                guard let r = try resolveMessageRow(ctx: ctx, id: id) else { throw AppleError.notFound("no message for id '\(id)'.") }
                row = r
            } else if let subject {
                var f = EnvelopeIndex.MessageFilters()
                if let account { f.accountUUID = try ctx.requireAccountUUID(account) }
                f.mailboxName = "All"; f.subjectContains = subject; f.limit = 1
                guard let r = try ctx.index.queryMessages(f).first else { throw AppleError.notFound("no message matching subject '\(subject)'.") }
                row = r
            } else {
                throw AppleError.validation("provide a message id argument or --subject.")
            }
            var target = ctx.decodeSummary(row)
            // reply-all folds in the original to/cc — but the summary decode omits recipients, so
            // hydrate them from the index (same source `mail get` uses) or --all would fold nothing.
            if all {
                let recips = try ctx.index.recipients(messageRowid: intVal(row["rowid"]) ?? 0)
                target.to = recips.to
                target.cc = recips.cc
            }
            // Reply addresses the ORIGINAL SENDER (never a user-supplied recipient) — so a reply
            // can only be self-safe when the original message is from self. reply-all also folds
            // in the original to/cc. guardOutbound then requires EVERY recipient to be the
            // operator's allowlisted self-address → replying to real mail is refused, fail-closed.
            guard let sender = target.sender_address, !sender.isEmpty else {
                throw AppleError.upstream("cannot determine the original sender address to reply to.")
            }
            var recipients = [sender]
            if all { recipients += (target.to ?? []) + (target.cc ?? []) }
            let ccL = splitRecipients(cc), bccL = splitRecipients(bcc)

            let replySubject = target.subject.lowercased().hasPrefix("re:") ? target.subject : "Re: \(target.subject)"
            // Quote from the index snippet/content already in hand — avoids a slow full-body
            // AppleScript scan (message-id has no Mail index; a body fetch can hang on Gmail).
            let original = target.content ?? target.snippet
            let quotedPlain = original.map { "\n\n> " + $0.replacingOccurrences(of: "\n", with: "\n> ") } ?? ""

            // --gui-send opt-in validity (mirrors SendCommand).
            if guiSend {
                guard html != nil else { throw AppleError.validation("--gui-send only applies to an --html reply.") }
                guard mode == "send" else { throw AppleError.validation("--gui-send requires --mode send.") }
            }
            // Three mutually-exclusive live outbound actions (mirrors SendCommand / Option A).
            let willAutoSend = global.willExecute && mode == "send" && html == nil
            let willGuiSend = global.willExecute && guiSend
            let willOpenHtml = global.willExecute && html != nil && !guiSend
            let willLiveOutbound = willAutoSend || willGuiSend || willOpenHtml

            var executed = false
            var opened = false
            var senderAddress: String?
            var note: String?
            if willLiveOutbound {
                // Self-only gate FIRST — before any attachment read, .eml/.html build, or send.
                try guardOutbound(recipients: recipients + ccL + bccL, testMode: global.testMode)
                // A live reply needs a real subject (replySubject always carries "Re:" today, so
                // this is belt-and-suspenders).
                guard !replySubject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AppleError.validation("--subject is required for a live reply; refusing an empty/whitespace subject.")
                }
                // Resolve --account to the send-from identity (mirrors SendCommand): the reply goes
                // out FROM this account's address, not Mail's default. Live-path only, so headless
                // dry-runs never touch Mail; unknown/addressless account is a not_found up front.
                if let account {
                    guard let addr = AccountDirectory().sendAddress(for: account) else {
                        throw AppleError.notFound("account '\(account)' not found or has no send address.")
                    }
                    senderAddress = addr
                }
                // Quoted original, escaped into the HTML part (shared by the gui-send + open paths).
                let quotedHTML = original.map {
                    "<br><br><blockquote>" + EmlBuilder.escapeHTML($0).replacingOccurrences(of: "\n", with: "<br>") + "</blockquote>"
                } ?? ""
                if willGuiSend {
                    // Opt-in HTML auto-send via GUI keystrokes (fragile — see MailScript.sendHtmlViaGui).
                    let paths = try attach.map { try resolveAttachmentPath($0) }
                    let htmlTmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("apple-cli-\(TestMode.sandboxPrefix)-\(UUID().uuidString).html")
                    try ((html ?? "") + quotedHTML).write(to: htmlTmp, atomically: true, encoding: .utf8)
                    defer { try? FileManager.default.removeItem(at: htmlTmp) }
                    try MailScript().sendHtmlViaGui(htmlPath: htmlTmp.path, subject: replySubject,
                        to: recipients, cc: ccL, bcc: bccL, attachmentPaths: paths, sender: senderAddress)
                    executed = true
                    note = "sent via GUI keystroke automation (--gui-send); required Accessibility and stole focus"
                } else if willOpenHtml {
                    // Reliable HTML reply: build a multipart .eml (quote embedded) and open a
                    // rendered compose window for review.
                    let atts = try attachmentsFromPaths(try attach.map { try resolveAttachmentPath($0) })
                    // emitBcc: safe — this .eml is only opened in a compose window, never wire-sent.
                    let eml = try EmlBuilder(from: senderAddress, to: recipients, cc: ccL, bcc: bccL, subject: replySubject,
                                             textBody: body + quotedPlain, htmlBody: (html ?? "") + quotedHTML, attachments: atts,
                                             emitBcc: true).build()
                    let dest = emlDestURL(out: nil)
                    try eml.write(to: dest, atomically: true, encoding: .utf8)
                    try MailScript().openEml(path: dest.path)
                    opened = true
                    note = "HTML reply rendered in a compose window for review — click Send, or re-run with --gui-send to auto-send."
                } else { // willAutoSend — plain or attachment reply (quoted plain body)
                    if !attach.isEmpty {
                        let paths = try attach.map { try resolveAttachmentPath($0) }
                        try MailScript().sendWithAttachments(subject: replySubject, body: body + quotedPlain,
                                                             to: recipients, cc: ccL, bcc: bccL, attachmentPaths: paths, sender: senderAddress)
                    } else {
                        try MailScript().send(subject: replySubject, body: body + quotedPlain, to: recipients, cc: ccL, bcc: bccL, sender: senderAddress)
                    }
                    executed = true
                }
            } else if global.willExecute {
                note = "mode '\(mode)' is preview-only; use --mode send to deliver"
            }

            try Output.emit(tool: "mail", data: Preview(action: "reply", target: id ?? "subject:\(subject ?? "")",
                matched_message_id: target.id, reply_all: all, mode: mode, has_html: html != nil, sender_address: senderAddress,
                to: recipients, cc: ccL, bcc: bccL, attachments: attach,
                dry_run: !global.willExecute, executed: executed, opened: opened, note: note))
        }
    }
}

struct ForwardCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "forward", abstract: "Forward a message by id or --subject (dry-run preview by default).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Message id to forward; or use --subject.") var id: String?
    @Option(name: .long, help: "Forward the newest message matching this subject keyword.") var subject: String?
    @Option(name: .long, help: "Account (name or UUID) — used for --subject lookup AND as the send-from identity.") var account: String?
    @Option(name: .long, help: "Mailbox to scope the --subject lookup (default All; MCP B forward_email mailbox).") var mailbox: String = "All"
    @Option(name: .long, help: "Recipient (repeatable).") var to: [String] = []
    @Option(name: .long) var cc: [String] = []
    @Option(name: .long) var bcc: [String] = []
    @Option(name: .long, help: "Text to prepend before the forwarded content.") var body: String?

    struct Preview: Encodable {
        let action: String; let matched_message_id: String?; let sender_address: String?; let to: [String]
        let cc: [String]; let bcc: [String]; let dry_run: Bool; let executed: Bool; let note: String?
    }

    func run() throws {
        try runGuarded(tool: "mail") {
            let toL = splitRecipients(to), ccL = splitRecipients(cc), bccL = splitRecipients(bcc)
            guard !toL.isEmpty else { throw AppleError.validation("--to is required.") }
            // Outbound guard (self-only) fires BEFORE any resolve/emit → one envelope.
            if global.willExecute { try guardOutbound(recipients: toL + ccL + bccL, testMode: global.testMode) }
            // Resolve --account to the send-from identity (mirrors SendCommand/ReplyCommand): the
            // forward goes out FROM this account's address. Live-path only (headless dry-runs never
            // touch Mail); fires before the Envelope Index opens, so an unknown account is a clean
            // not_found even where the index is unreadable.
            var senderAddress: String?
            if global.willExecute, let account {
                guard let addr = AccountDirectory().sendAddress(for: account) else {
                    throw AppleError.notFound("account '\(account)' not found or has no send address.")
                }
                senderAddress = addr
            }
            let ctx = try MailContext()
            let target: MailMessage
            if let id {
                guard let row = try resolveMessageRow(ctx: ctx, id: id) else { throw AppleError.notFound("no message for id '\(id)'.") }
                target = ctx.decodeSummary(row)
            } else if let subject {
                var f = EnvelopeIndex.MessageFilters()
                if let account { f.accountUUID = try ctx.requireAccountUUID(account) }
                f.mailboxName = mailbox; f.subjectContains = subject; f.limit = 1
                guard let row = try ctx.index.queryMessages(f).first else { throw AppleError.notFound("no message matching subject '\(subject)' in mailbox '\(mailbox)'.") }
                target = ctx.decodeSummary(row)
            } else {
                throw AppleError.validation("provide a message id argument or --subject.")
            }
            // Forward composes a NEW message to the self-only --to (guardOutbound above), carrying
            // the original body — so forwarding real mail to yourself is fine (recipient is self).
            var executed = false
            let note: String? = nil
            if global.willExecute {
                let fwdSubject = target.subject.lowercased().hasPrefix("fwd:") ? target.subject : "Fwd: \(target.subject)"
                // Quote from the index snippet/content already in hand (avoids a slow body scan).
                let original = target.content ?? target.snippet
                let intro = body.map { $0 + "\n\n" } ?? ""
                let fwdBody = intro + "---------- Forwarded message ----------\nFrom: \(target.sender)\nSubject: \(target.subject)\n\n" + (original ?? "")
                try MailScript().send(subject: fwdSubject, body: fwdBody, to: toL, cc: ccL, bcc: bccL, sender: senderAddress)
                executed = true
            }
            try Output.emit(tool: "mail", data: Preview(action: "forward", matched_message_id: target.id, sender_address: senderAddress,
                to: toL, cc: ccL, bcc: bccL, dry_run: !global.willExecute, executed: executed, note: note))
        }
    }
}

struct DraftRichCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "draft-rich", abstract: "Generate a multipart .eml draft (reliable HTML); optionally open it or save it to Drafts.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long) var account: String?
    @Option(name: .long) var subject: String = ""
    @Option(name: .long, help: "Recipient (repeatable).") var to: [String] = []
    @Option(name: .customLong("text-body"), help: "Plain-text body (--text is reserved for global output mode).") var textBody: String?
    @Option(name: .long, help: "HTML body.") var html: String?
    @Option(name: .long) var cc: [String] = []
    @Option(name: .long) var bcc: [String] = []
    @Option(name: .long, help: "Output .eml path (default: temp dir).") var out: String?
    @Flag(name: .customLong("open"), help: "Open the generated .eml in a Mail compose window for review (no send).") var openInMail = false
    @Flag(name: .long, help: "Open the .eml and save it to Drafts (no send; requires --test-mode + a labeled subject).") var saveAsDraft = false

    struct Result: Encodable { let eml_path: String; let subject: String; let to: [String]; let has_html: Bool; let sender_address: String?; let opened: Bool; let note: String? }

    func run() throws {
        try runGuarded(tool: "mail") {
            let toL = splitRecipients(to)
            // Opening the .eml in Mail (either flag) is a live compose-window action, so gate it
            // consistently with `send --mode open`: the self-only guardOutbound (test-mode +
            // allowlist) + a real subject, BEFORE any Mail access or .eml write. This is deliberately
            // stricter than the create_rich_email_draft oracle (which opens to any recipient) — the
            // fail-closed self-only posture is the pre-1.0 CLI default; relaxing non-sending opens to
            // any recipient is a tracked 1.0 decision. The DEFAULT (neither flag) just writes the
            // .eml headlessly and is ungated.
            var senderAddress: String?
            if openInMail || saveAsDraft {
                try guardOutbound(recipients: toL + splitRecipients(cc) + splitRecipients(bcc), testMode: global.testMode)
                guard !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AppleError.validation("--subject is required to open a draft-rich compose window.")
                }
                // Resolve --account to a real From ADDRESS on the live-open path (mirrors
                // create_rich_email_draft's _resolve_sender_address): a raw account NAME in `From:`
                // is malformed and Mail ignores it. Headless default keeps the raw fallback so it
                // never touches Mail (and never launches it).
                if let account {
                    guard let addr = AccountDirectory().sendAddress(for: account) else {
                        throw AppleError.notFound("account '\(account)' not found or has no send address.")
                    }
                    senderAddress = addr
                }
            }
            // emitBcc: a draft-rich .eml is only opened / written to disk, never wire-sent, so
            // carrying --bcc into it is safe and required for create_rich_email_draft parity.
            let eml = try EmlBuilder(from: senderAddress ?? account, to: toL, cc: splitRecipients(cc), bcc: splitRecipients(bcc),
                                 subject: subject, textBody: textBody, htmlBody: html, emitBcc: true).build()
            let dest = URL(fileURLWithPath: ((out ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("apple-cli-\(TestMode.sandboxPrefix)-\(UUID().uuidString).eml").path) as NSString).expandingTildeInPath)
            try eml.write(to: dest, atomically: true, encoding: .utf8)
            // Optional review window (parity with create_rich_email_draft open_in_mail). Mail cannot
            // auto-save an HTML draft (a LaunchServices-opened .eml window doesn't surface in
            // `outgoing messages`), so --save-as-draft opens the SAME review window and instructs the
            // operator to Cmd-S — it never auto-files, so there is no `saved` claim.
            var opened = false
            var note: String?
            if openInMail || saveAsDraft {
                try MailScript().openEml(path: dest.path)
                opened = true
                note = saveAsDraft
                    ? "compose window opened — press Cmd-S to file it in Drafts (Mail can't auto-save an HTML draft)."
                    : "compose window opened for review (not sent)."
            }
            try Output.emit(tool: "mail", data: Result(eml_path: dest.path, subject: subject, to: toL,
                has_html: html != nil, sender_address: senderAddress, opened: opened, note: note))
        }
    }
}

struct DraftCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "draft", abstract: "Manage drafts: list | create | send | open | delete (dry-run for outbound).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Action: list | create | send | open | delete.") var action: String
    @Option(name: .long) var account: String?
    @Option(name: .long) var subject: String?
    @Option(name: .long, help: "Recipient (repeatable).") var to: [String] = []
    @Option(name: .long) var body: String?
    @Option(name: .long) var cc: [String] = []
    @Option(name: .long) var bcc: [String] = []
    @Option(name: .long, help: "EXACT (case-insensitive) subject of the draft to send/open/delete — not a keyword/substring.") var draftSubject: String?

    func run() throws {
        try runGuarded(tool: "mail") {
            guard ["list", "create", "send", "open", "delete"].contains(action) else {
                throw AppleError.validation("draft action must be list, create, send, open, or delete.")
            }
            let script = MailScript()

            // list — a live READ of Mail's real Drafts mailbox (no gate).
            if action == "list" {
                let drafts = try script.listDrafts()
                struct DraftRow: Encodable { let subject: String; let recipient: String; let date_sent: String }
                struct DraftsResult: Encodable { let action: String; let drafts: [DraftRow]; let count: Int }
                let rows = drafts.map { DraftRow(subject: $0.subject, recipient: $0.recipient, date_sent: $0.date_sent) }
                try Output.emit(tool: "mail", data: DraftsResult(action: "list", drafts: rows, count: rows.count))
                return
            }

            // create / delete — live Mail Drafts mutations behind the 3-flag gate + subject label.
            // send — routed to `mail send` (note); open — Mail-UI only (note).
            var executed = false
            var note: String?
            // On a successful `draft send`, the verified recipients the mail was dispatched to (the
            // draft's OWN pre-set to/cc/bcc, which this command never supplied) — surfaced in the
            // envelope's `to` so the machine contract reflects who it actually went to.
            var draftSentTo: [String]?
            let subj = subject ?? draftSubject
            if global.willExecute {
                switch action {
                case "create":
                    guard global.testMode && TestMode.isEnabled else {
                        throw AppleError.mailSafety("creating a draft requires --test-mode AND APPLE_TEST_MODE=1; refusing.")
                    }
                    guard let s = subj, s.hasPrefix(TestMode.sandboxPrefix) else {
                        throw AppleError.mailSafety("draft --subject must be a labeled test item (start with \"\(TestMode.sandboxPrefix)\") — refusing.")
                    }
                    // Resolve --account to the draft's sender identity (manage_drafts create
                    // parity); live path only, strict not_found on an unknown account.
                    var senderAddress: String?
                    if let account {
                        guard let addr = AccountDirectory().sendAddress(for: account) else {
                            throw AppleError.notFound("account '\(account)' not found or has no send address.")
                        }
                        senderAddress = addr
                    }
                    try script.createDraft(subject: s, body: body ?? "", to: splitRecipients(to),
                                           cc: splitRecipients(cc), bcc: splitRecipients(bcc), sender: senderAddress)
                    executed = true
                case "delete":
                    guard global.testMode && TestMode.isEnabled else {
                        throw AppleError.mailSafety("deleting a draft requires --test-mode AND APPLE_TEST_MODE=1; refusing.")
                    }
                    guard let s = subj, s.hasPrefix(TestMode.sandboxPrefix) else {
                        throw AppleError.mailSafety("draft --subject (or --draft-subject) must be a labeled test item to delete — refusing.")
                    }
                    let n = try script.deleteDrafts(subject: s, prefix: TestMode.sandboxPrefix)
                    executed = n > 0
                    note = "deleted \(n) draft(s) matching \"\(s)\""
                case "send":
                    // Deliver an EXISTING Drafts item (manage_drafts action=send). A draft's
                    // recipients are PRE-SET, so the two-factor gate + label check fire here AND
                    // the draft's own stored to/cc/bcc are verified against the self-only
                    // allowlist INSIDE the single AppleScript call (find→verify→send, no TOCTOU) —
                    // a draft addressed to any non-self recipient is refused fail-closed.
                    guard global.testMode && TestMode.isEnabled else {
                        throw AppleError.mailSafety("sending a draft requires --test-mode AND APPLE_TEST_MODE=1; refusing.")
                    }
                    guard let s = subj, s.hasPrefix(TestMode.sandboxPrefix) else {
                        throw AppleError.mailSafety("draft --subject (or --draft-subject) must be a labeled test item to send — refusing.")
                    }
                    switch try script.sendDraft(subject: s, prefix: TestMode.sandboxPrefix,
                                                account: account, allowlist: TestMode.allowedRecipients) {
                    case .sent(let recipients):
                        executed = true
                        draftSentTo = recipients
                        let who = recipients.isEmpty ? "its stored recipients" : recipients.joined(separator: ", ")
                        note = "sent existing draft \"\(s)\" to \(who) (recipients verified self-only)"
                    case .notFound:
                        let inAcct = account.map { " in account '\($0)'" } ?? ""
                        throw AppleError.notFound("no labeled draft with the exact subject \"\(s)\"\(inAcct) found.")
                    case .noRecipients:
                        throw AppleError.validation("draft \"\(s)\" has no valid recipients; add a recipient in Mail or recreate it.")
                    case .blocked(let addr):
                        let which = addr == "<empty-address>" ? "an empty/blank recipient address" : "'\(addr)'"
                        throw AppleError.mailSafety("draft \"\(s)\" is addressed to \(which), which is not in the self-only test allowlist — refusing to send it. Set APPLE_TEST_RECIPIENTS to your own address(es) or fix the draft's recipients.")
                    case .openFailed:
                        throw AppleError.upstream("draft \"\(s)\" was opened but Mail never surfaced its outgoing message within 30s; nothing was sent (a compose window may be open — close it or send manually), and the draft is unchanged — retry.")
                    case .sendError(let detail):
                        throw AppleError.upstream("draft \"\(s)\" opened and passed recipient verification, but Mail failed to dispatch it (error \(detail)); a compose window may be open — send it manually, or retry.")
                    }
                default: // open — open an EXISTING labeled draft in a compose window (no send).
                    guard let s = subj, s.hasPrefix(TestMode.sandboxPrefix) else {
                        throw AppleError.mailSafety("draft --subject (or --draft-subject) must be a labeled test item to open — refusing.")
                    }
                    let ok = try script.openDraft(subject: s, account: account)
                    executed = ok
                    note = ok ? "opened draft \"\(s)\" in a compose window (not sent)" : "no draft matching \"\(s)\" found"
                }
            }
            let payload: [String: AnyEncodableBox] = [
                "action": AnyEncodableBox(action), "account": AnyEncodableBox(account),
                "subject": AnyEncodableBox(subj), "to": AnyEncodableBox(draftSentTo ?? splitRecipients(to)),
                "dry_run": AnyEncodableBox(!global.willExecute), "executed": AnyEncodableBox(executed),
                "note": AnyEncodableBox(note),
            ]
            try Output.emit(tool: "mail", data: payload)
        }
    }
}
