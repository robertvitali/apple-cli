import ArgumentParser
import AppleKit

/// `apple messages …` — iMessage / SMS.
///
/// Ports `mac_messages_mcp` (@ 99388d2, 9 tools) to a strict superset. Fork base:
/// openclaw/imsg (Swift, MIT). Mechanism: `SQLiteReader` over chat.db (WAL-aware) +
/// `AppleScriptRunner` send (parameterized argv). Build parity: cross-chat `recent`,
/// fuzzy contact search w/ scores, fuzzy message search w/ threshold+window, doctor.
///
/// Asana: feat/asana-GID-REDACTED-messages
public struct MessagesCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "messages",
        abstract: "iMessage / SMS — send, read, search (ports mac_messages_mcp).",
        subcommands: []
    )
    @OptionGroup public var global: GlobalOptions
    public init() {}
    public func run() throws {
        try runGuarded(tool: "messages") {
            throw AppleError.notImplemented("messages domain not yet implemented — see feat/asana-GID-REDACTED-messages")
        }
    }
}
