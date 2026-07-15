import ArgumentParser
import AppleKit
import EventKitCore

/// `apple reminders …` — Reminders (EventKit).
///
/// Ports the Reminders half of `mcp-server-apple-events` (@ 1.4.0) to a strict superset,
/// including the 6 subtask ops. Fork base: FradSer/event. Shares `EventKitCore` with
/// Calendar — build the shared core once (coordinate). Build parity: recurrence set, alarms,
/// completionDate, cross-list move, list color, read filters, subtasks.
///
/// Asana: feat/asana-GID-REDACTED-reminders
public struct RemindersCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "Reminders — tasks/lists/subtasks (EventKit; ports apple-events reminders half).",
        subcommands: []
    )
    @OptionGroup public var global: GlobalOptions
    public init() {}
    public func run() throws {
        try runGuarded(tool: "reminders") {
            _ = EventKitCore.ready // shared engine (Calendar + Reminders)
            throw AppleError.notImplemented("reminders domain not yet implemented — see feat/asana-GID-REDACTED-reminders")
        }
    }
}
