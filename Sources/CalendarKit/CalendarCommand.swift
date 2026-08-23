import ArgumentParser
import AppleKit
import EventKitCore

/// `apple calendar …` — Calendar (EventKit).
///
/// Ports the Calendar half of `mcp-server-apple-events` (@ 1.4.0) to a strict superset:
///   calendar calendars list          → calendar_calendars (collections)
///   calendar events read             → calendar_events read  (window/filters/--id)
///   calendar events create           → calendar_events create
///   calendar events update           → calendar_events update (+ cross-calendar move, span)
///   calendar events delete           → calendar_events delete (--span this|future|all superset)
///   calendar doctor                  → permission/health preflight (extra)
///
/// All heavy EventKit work lives in the shared `EventKitCore` engine (models + mapping +
/// EKEventStore access); this module is the command tree only. Write-model v2: writes EXECUTE
/// by default (oracle parity); `--dry-run` / `APPLE_DRY_RUN=1` preview, and
/// `--test-mode` / `APPLE_TEST_MODE` engages the opt-in sandbox policy (label-scoped targets).
///
/// Asana parent GID: GID-REDACTED
public struct CalendarCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "calendar",
        abstract: "Calendar — events CRUD + calendars (EventKit; ports apple-events calendar half).",
        subcommands: [CalendarsCommand.self, EventsCommand.self, CalendarDoctor.self],
        defaultSubcommand: EventsCommand.self
    )
    public init() {}
}
