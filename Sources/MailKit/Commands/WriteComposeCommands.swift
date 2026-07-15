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
func guardOutbound(recipients: [String]) throws {
    guard TestMode.isEnabled else {
        throw AppleError.validation("live send requires APPLE_TEST_MODE=1 (and --test-mode); refusing. Use the default dry-run to preview.")
    }
    // Fail-closed: EVERY recipient must be the operator's allowlisted self-address.
    for r in recipients {
        try TestMode.requireAllowedRecipient(r)
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
            if willSend { try guardOutbound(recipients: toL + ccL + bccL) }

            let preview = Preview(action: "send", mode: mode, account: account, to: toL, cc: ccL, bcc: bccL,
                                  subject: subject, has_html: html != nil, attachments: attach,
                                  eml_path: emlPath, dry_run: !global.willExecute, executed: false,
                                  note: global.willExecute ? "live send/draft is disabled in this build (safety); this is a preview" + (emlPath != nil ? " + .eml" : "") : nil)
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
        let cc: [String]; let bcc: [String]; let attachments: [String]
        let dry_run: Bool; let note: String?
    }

    func run() throws {
        try runGuarded(tool: "mail") {
            let ctx = try MailContext()
            var targetID: String?
            if let id {
                guard let row = try resolveMessageRow(ctx: ctx, id: id) else { throw AppleError.notFound("no message for id '\(id)'.") }
                targetID = String(intVal(row["rowid"]) ?? 0)
            } else if let subject {
                var f = EnvelopeIndex.MessageFilters()
                if let account { f.accountUUID = try ctx.requireAccountUUID(account) }
                f.mailboxName = "All"; f.subjectContains = subject; f.limit = 1
                targetID = try ctx.index.queryMessages(f).first.map { String(intVal($0["rowid"]) ?? 0) }
                guard targetID != nil else { throw AppleError.notFound("no message matching subject '\(subject)'.") }
            } else {
                throw AppleError.validation("provide a message id argument or --subject.")
            }
            let preview = Preview(action: "reply", target: id ?? "subject:\(subject ?? "")", matched_message_id: targetID,
                                  reply_all: all, mode: mode, has_html: html != nil,
                                  cc: splitRecipients(cc), bcc: splitRecipients(bcc), attachments: attach,
                                  dry_run: !global.willExecute,
                                  note: global.willExecute ? "live reply is disabled in this build (safety); this is a preview" : nil)
            try Output.emit(tool: "mail", data: preview)
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
        let cc: [String]; let bcc: [String]; let dry_run: Bool; let note: String?
    }

    func run() throws {
        try runGuarded(tool: "mail") {
            let toL = splitRecipients(to)
            guard !toL.isEmpty else { throw AppleError.validation("--to is required.") }
            // Outbound guard fires BEFORE emit → one envelope.
            if global.willExecute { try guardOutbound(recipients: toL) }
            let ctx = try MailContext()
            var targetID: String?
            if let id {
                guard let row = try resolveMessageRow(ctx: ctx, id: id) else { throw AppleError.notFound("no message for id '\(id)'.") }
                targetID = String(intVal(row["rowid"]) ?? 0)
            } else if let subject {
                var f = EnvelopeIndex.MessageFilters()
                if let account { f.accountUUID = try ctx.requireAccountUUID(account) }
                f.mailboxName = "All"; f.subjectContains = subject; f.limit = 1
                targetID = try ctx.index.queryMessages(f).first.map { String(intVal($0["rowid"]) ?? 0) }
                guard targetID != nil else { throw AppleError.notFound("no message matching subject '\(subject)'.") }
            } else {
                throw AppleError.validation("provide a message id argument or --subject.")
            }
            try Output.emit(tool: "mail", data: Preview(action: "forward", matched_message_id: targetID, to: toL,
                cc: splitRecipients(cc), bcc: splitRecipients(bcc), dry_run: !global.willExecute,
                note: global.willExecute ? "live forward is disabled in this build (safety); this is a preview" : nil))
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
            // Drafts live in Mail; listing/creating/sending them is a Mail.app write surface.
            // Preview-only in this build (safety): report the intended action + parameters.
            let payload: [String: AnyEncodableBox] = [
                "action": AnyEncodableBox(action),
                "account": AnyEncodableBox(account),
                "subject": AnyEncodableBox(subject ?? draftSubject),
                "to": AnyEncodableBox(splitRecipients(to)),
                "dry_run": AnyEncodableBox(!global.willExecute),
                "note": AnyEncodableBox(global.willExecute ? "live draft \(action) is disabled in this build (safety); this is a preview" : Optional<String>.none),
            ]
            try Output.emit(tool: "mail", data: payload)
        }
    }
}
