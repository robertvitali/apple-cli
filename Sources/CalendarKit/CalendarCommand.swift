import ArgumentParser
import AppleKit
import EventKitCore

/// `apple calendar …` — Calendar (EventKit).
///
/// Ports the Calendar half of `mcp-server-apple-events` (@ 1.4.0) to a strict superset.
/// Fork base: FradSer/event (Swift/EventKit). Shares `EventKitCore` with Reminders — build
/// the shared core once (coordinate; don't edit it from both worktrees). Build parity:
/// url/availability/alarms/recurrence/structuredLocation write flags, cross-calendar move.
///
/// Asana: feat/asana-GID-REDACTED-calendar
public struct CalendarCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "calendar",
        abstract: "Calendar — events CRUD + calendars (EventKit; ports apple-events calendar half).",
        subcommands: []
    )
    @OptionGroup public var global: GlobalOptions
    public init() {}
    public func run() throws {
        try runGuarded(tool: "calendar") {
            _ = EventKitCore.ready // shared engine (Calendar + Reminders)
            throw AppleError.notImplemented("calendar domain not yet implemented — see feat/asana-GID-REDACTED-calendar")
        }
    }
}
