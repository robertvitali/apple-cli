import ArgumentParser
import AppleKit

/// `apple mail …` — Mail.app.
///
/// Ports the UNION of both fleet mail MCPs (s-morgan-jeffries@v0.6.0 + patrickfreyer@v3.1.3)
/// — 42 capabilities — to a strict superset. Mechanism: `SQLiteReader` over the Envelope
/// Index (fast read/search/analytics) + `AppleScriptRunner` (send/manage/rules/templates) +
/// multipart .eml for HTML send. Hard parts: rules, analytics, dual ID/filter targeting.
///
/// Asana: feat/asana-GID-REDACTED-mail
public struct MailCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Mail.app — send, search, rules, templates, analytics (union of both mail MCPs).",
        subcommands: []
    )
    @OptionGroup public var global: GlobalOptions
    public init() {}
    public func run() throws {
        try runGuarded(tool: "mail") {
            throw AppleError.notImplemented("mail domain not yet implemented — see feat/asana-GID-REDACTED-mail")
        }
    }
}
