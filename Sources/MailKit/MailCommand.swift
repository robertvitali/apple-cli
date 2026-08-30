import ArgumentParser
import AppleKit

/// `apple mail …` — Mail.app.
///
/// Ports the UNION of both fleet mail MCPs (s-morgan-jeffries@v0.6.0 + patrickfreyer@v3.1.3)
/// — 42 capabilities — to a strict superset. Mechanism: `EnvelopeIndex` (SQLite) over the
/// Envelope Index for fast read/search/analytics + `MailScript` (AppleScript) for
/// send/manage/rules/templates + multipart `.eml` for HTML send. Dual targeting model:
/// ID-precise (MCP A) AND subject/sender/date `--match` filters (MCP B).
///
public struct MailCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Mail.app — send, search, rules, templates, analytics (union of both mail MCPs).",
        subcommands: [
            // P1 — reads (Envelope Index + AppleScript)
            AccountsCommand.self,
            MailboxesCommand.self,
            UnreadCountsCommand.self,
            SearchCommand.self,
            ListCommand.self,
            GetCommand.self,
            SelectedCommand.self,
            ThreadCommand.self,
            AttachmentsCommand.self,
            RulesCommand.self,
            TemplatesCommand.self,
            MailDoctor.self,
            // P3 — derived analytics + export (structured supersets of MCP B's text blobs)
            AnalyticsCommand.self,
            ExportCommand.self,
            // P2 — write/manage (dry-run default; live mutation gated + not wired for safety)
            SendCommand.self,
            ReplyCommand.self,
            ForwardCommand.self,
            DraftCommand.self,
            DraftRichCommand.self,
            MoveCommand.self,
            MarkCommand.self,
            FlagCommand.self,
            DeleteCommand.self,
            TrashCommand.self,
        ])
    @OptionGroup public var global: GlobalOptions
    public init() {}
}
