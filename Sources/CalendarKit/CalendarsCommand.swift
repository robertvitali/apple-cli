import Foundation
import ArgumentParser
import AppleKit
import EventKitCore

/// `apple calendar calendars …` — the calendar_calendars strict superset. The reference
/// `event` CLI lacked a collection-listing command; this adds it (spec §3a).
public struct CalendarsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "calendars",
        abstract: "Calendar collections (ports calendar_calendars).",
        subcommands: [CalendarsList.self],
        defaultSubcommand: CalendarsList.self
    )
    public init() {}
}

public struct CalendarsList: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List event calendar collections (id/title/account/account_type/color/…).")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .long, help: "Filter to collections in this account (source) name.") public var account: String?

    public init() {}

    public func run() throws {
        try runGuarded(tool: "calendar") {
            let store = EventStore()
            try store.requestAccess(to: .event, mode: .read)
            var collections = store.calendars(for: .event)
            if let account {
                let known = Set(collections.compactMap { $0.source?.title })
                guard known.contains(account) else {
                    throw AppleError.notFound("no account '\(account)' (known: \(known.sorted().joined(separator: ", ")))")
                }
                collections = collections.filter { $0.source?.title == account }
            }
            // CAL-10: the oracle returns calendars in EventKit's native, source-grouped order
            // (`eventStore.calendars(for:)` verbatim) — re-sorting alphabetically was a live
            // diff on every list.
            let data = CalendarsData(
                calendars: collections.map { ReadMapping.collection(from: $0) })
            try Output.emit(tool: "calendar", data: data)
        }
    }
}
