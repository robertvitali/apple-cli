import Foundation
import ArgumentParser
import AppleKit

// P2 compose surface: send, reply, forward, draft, draft-rich. Destructive/outbound verbs
// DEFAULT to a dry-run preview; a real send requires --execute AND APPLE_TEST_MODE AND a
// self-only recipient (TestMode). Live sending is intentionally NOT wired in this build —
// the preview + generated .eml are the safe, tested surface (see AGENTS.md Safety).

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

struct SendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "send", abstract: "Compose an email (dry-run preview by default; plain/HTML/attachments; mode send|draft|open).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Recipient (repeatable; comma-joined ok).") var to: [String] = []
    @Option(name: .long) var subject: String = ""
    @Option(name: .long, help: "Plain-text body (fallback when --html is set).") var body: String = ""
    @Option(name: .long, help: "CC recipient (repeatable).") var cc: [String] = []
    @Option(name: .long, help: "BCC recipient (repeatable).") var bcc: [String] = []
    @Option(name: .long, help: "Attachment file path (repeatable).") var attach: [String] = []
    @Option(name: .long, help: "HTML body (sent via multipart .eml for reliable rendering).") var html: String?
    @Option(name: .long, help: "Delivery mode: send | draft | open.") var mode: String = "send"
    @Option(name: .long, help: "Sending account (name or UUID).") var account: String?
    @Option(name: .long, help: "Write the generated .eml to this path (html/attachment sends).") var out: String?

    struct Preview: Encodable {
        let action: String; let mode: String; let account: String?
        let to: [String]; let cc: [String]; let bcc: [String]
        let subject: String; let has_html: Bool; let attachments: [String]
        let eml_path: String?; let dry_run: Bool; let executed: Bool; let note: String?
    }

    func run() throws {
        try runGuarded(tool: "mail") {
            let toL = splitRecipients(to), ccL = splitRecipients(cc), bccL = splitRecipients(bcc)
            guard !toL.isEmpty else { throw AppleError.validation("--to is required.") }
            guard ["send", "draft", "open"].contains(mode) else { throw AppleError.validation("--mode must be send, draft, or open.") }

            // Generate the .eml for HTML/attachment sends (proven-reliable path; MCP B #18).
            var emlPath: String?
            if html != nil || !attach.isEmpty {
                let atts = try attach.map { path -> EmlBuilder.Attachment in
                    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                    guard let data = try? Data(contentsOf: url) else { throw AppleError.notFound("attachment not found: \(path)") }
                    return EmlBuilder.Attachment(filename: url.lastPathComponent,
                                                 mimeType: EmlBuilder.mimeType(forFilename: url.lastPathComponent), data: data)
                }
                let eml = try EmlBuilder(from: account, to: toL, cc: ccL, bcc: bccL, subject: subject,
                                     textBody: body.isEmpty ? nil : body, htmlBody: html, attachments: atts).build()
                let dest = URL(fileURLWithPath: ((out ?? FileManager.default.temporaryDirectory
                    .appendingPathComponent("apple-cli-\(TestMode.sandboxPrefix)-\(UUID().uuidString).eml").path) as NSString).expandingTildeInPath)
                try eml.write(to: dest, atomically: true, encoding: .utf8)
                emlPath = dest.path
            }

            // Real send is guarded (self-only + test-mode) BEFORE any output — one envelope.
            let willSend = global.willExecute && mode == "send"
            var executed = false
            var note: String?
            if willSend {
                try guardOutbound(recipients: toL + ccL + bccL, testMode: global.testMode)
                if html == nil && attach.isEmpty {
                    // Plain-text live send via Mail.app — already self-only + test-mode guarded.
                    try MailScript().send(subject: subject, body: body, to: toL, cc: ccL, bcc: bccL)
                    executed = true
                } else {
                    // HTML/attachment delivery goes via the generated .eml (reliable rendering);
                    // live HTML/attachment SEND is not wired — open the .eml in Mail to send.
                    note = "generated .eml for reliable HTML/attachment delivery — open it in Mail to send"
                        + " (live HTML/attachment send is not wired; plain-text --mode send delivers directly)"
                }
            } else if global.willExecute {
                note = "mode '\(mode)' is preview-only; use --mode send (plain text) to deliver"
            }

            let preview = Preview(action: "send", mode: mode, account: account, to: toL, cc: ccL, bcc: bccL,
                                  subject: subject, has_html: html != nil, attachments: attach,
                                  eml_path: emlPath, dry_run: !global.willExecute, executed: executed, note: note)
            try Output.emit(tool: "mail", data: preview)
        }
    }
}

struct ReplyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reply", abstract: "Reply to a message by id or --subject (dry-run preview by default).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Message id to reply to (ROWID / RFC Message-ID); or use --subject.") var id: String?
    @Option(name: .long, help: "Reply to the newest message matching this subject keyword.") var subject: String?
    @Option(name: .long, help: "Account (name or UUID) for --subject lookup.") var account: String?
    @Option(name: .long) var body: String
    @Flag(name: .long, help: "Reply to all recipients.") var all = false
    @Option(name: .long) var cc: [String] = []
    @Option(name: .long) var bcc: [String] = []
    @Option(name: .long, help: "HTML reply body.") var html: String?
    @Option(name: .long, help: "Attachment file path (repeatable).") var attach: [String] = []
    @Option(name: .long, help: "Delivery mode: send | draft | open.") var mode: String = "send"

    struct Preview: Encodable {
        let action: String; let target: String; let matched_message_id: String?
        let reply_all: Bool; let mode: String; let has_html: Bool
        let to: [String]; let cc: [String]; let bcc: [String]; let attachments: [String]
        let dry_run: Bool; let executed: Bool; let note: String?
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

            let willSend = global.willExecute && mode == "send"
            var executed = false
            var note: String?
            if willSend {
                if html != nil || !attach.isEmpty {
                    note = "HTML/attachment reply is not wired for live send; use plain --body (live) or draft-rich (.eml)."
                } else {
                    try guardOutbound(recipients: recipients + ccL + bccL, testMode: global.testMode)
                    let replySubject = target.subject.lowercased().hasPrefix("re:") ? target.subject : "Re: \(target.subject)"
                    // Quote from the index snippet/content already in hand — avoids a slow full-body
                    // AppleScript scan (message-id has no Mail index; a body fetch can hang on Gmail).
                    let original = target.content ?? target.snippet
                    let quoted = original.map { "\n\n> " + $0.replacingOccurrences(of: "\n", with: "\n> ") } ?? ""
                    try MailScript().send(subject: replySubject, body: body + quoted, to: recipients, cc: ccL, bcc: bccL)
                    executed = true
                }
            } else if global.willExecute {
                note = "mode '\(mode)' is preview-only; use --mode send (plain text) to deliver"
            }

            try Output.emit(tool: "mail", data: Preview(action: "reply", target: id ?? "subject:\(subject ?? "")",
                matched_message_id: target.id, reply_all: all, mode: mode, has_html: html != nil,
                to: recipients, cc: ccL, bcc: bccL, attachments: attach,
                dry_run: !global.willExecute, executed: executed, note: note))
        }
    }
}

struct ForwardCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "forward", abstract: "Forward a message by id or --subject (dry-run preview by default).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Message id to forward; or use --subject.") var id: String?
    @Option(name: .long, help: "Forward the newest message matching this subject keyword.") var subject: String?
    @Option(name: .long, help: "Account for --subject lookup.") var account: String?
    @Option(name: .long, help: "Recipient (repeatable).") var to: [String] = []
    @Option(name: .long) var cc: [String] = []
    @Option(name: .long) var bcc: [String] = []
    @Option(name: .long, help: "Text to prepend before the forwarded content.") var body: String?

    struct Preview: Encodable {
        let action: String; let matched_message_id: String?; let to: [String]
        let cc: [String]; let bcc: [String]; let dry_run: Bool; let executed: Bool; let note: String?
    }

    func run() throws {
        try runGuarded(tool: "mail") {
            let toL = splitRecipients(to), ccL = splitRecipients(cc), bccL = splitRecipients(bcc)
            guard !toL.isEmpty else { throw AppleError.validation("--to is required.") }
            // Outbound guard (self-only) fires BEFORE any resolve/emit → one envelope.
            if global.willExecute { try guardOutbound(recipients: toL + ccL + bccL, testMode: global.testMode) }
            let ctx = try MailContext()
            let target: MailMessage
            if let id {
                guard let row = try resolveMessageRow(ctx: ctx, id: id) else { throw AppleError.notFound("no message for id '\(id)'.") }
                target = ctx.decodeSummary(row)
            } else if let subject {
                var f = EnvelopeIndex.MessageFilters()
                if let account { f.accountUUID = try ctx.requireAccountUUID(account) }
                f.mailboxName = "All"; f.subjectContains = subject; f.limit = 1
                guard let row = try ctx.index.queryMessages(f).first else { throw AppleError.notFound("no message matching subject '\(subject)'.") }
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
                try MailScript().send(subject: fwdSubject, body: fwdBody, to: toL, cc: ccL, bcc: bccL)
                executed = true
            }
            try Output.emit(tool: "mail", data: Preview(action: "forward", matched_message_id: target.id, to: toL,
                cc: ccL, bcc: bccL, dry_run: !global.willExecute, executed: executed, note: note))
        }
    }
}

struct DraftRichCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "draft-rich", abstract: "Generate a multipart .eml draft (reliable HTML) and optionally open it.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long) var account: String?
    @Option(name: .long) var subject: String = ""
    @Option(name: .long, help: "Recipient (repeatable).") var to: [String] = []
    @Option(name: .customLong("text-body"), help: "Plain-text body (--text is reserved for global output mode).") var textBody: String?
    @Option(name: .long, help: "HTML body.") var html: String?
    @Option(name: .long) var cc: [String] = []
    @Option(name: .long) var bcc: [String] = []
    @Option(name: .long, help: "Output .eml path (default: temp dir).") var out: String?

    struct Result: Encodable { let eml_path: String; let subject: String; let to: [String]; let has_html: Bool }

    func run() throws {
        try runGuarded(tool: "mail") {
            let toL = splitRecipients(to)
            let eml = try EmlBuilder(from: account, to: toL, cc: splitRecipients(cc), bcc: splitRecipients(bcc),
                                 subject: subject, textBody: textBody, htmlBody: html).build()
            let dest = URL(fileURLWithPath: ((out ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("apple-cli-\(TestMode.sandboxPrefix)-\(UUID().uuidString).eml").path) as NSString).expandingTildeInPath)
            try eml.write(to: dest, atomically: true, encoding: .utf8)
            try Output.emit(tool: "mail", data: Result(eml_path: dest.path, subject: subject, to: toL, has_html: html != nil))
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
    @Option(name: .long, help: "Subject keyword to find a draft (send/open/delete).") var draftSubject: String?

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
                    try script.createDraft(subject: s, body: body ?? "", to: splitRecipients(to))
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
                    note = "draft send is routed through `mail send` — compose + send there (self-only gated)"
                default: // open
                    note = "draft open is a Mail-UI action; use `mail draft-rich` to generate an .eml and open it"
                }
            }
            let payload: [String: AnyEncodableBox] = [
                "action": AnyEncodableBox(action), "account": AnyEncodableBox(account),
                "subject": AnyEncodableBox(subj), "to": AnyEncodableBox(splitRecipients(to)),
                "dry_run": AnyEncodableBox(!global.willExecute), "executed": AnyEncodableBox(executed),
                "note": AnyEncodableBox(note),
            ]
            try Output.emit(tool: "mail", data: payload)
        }
    }
}
