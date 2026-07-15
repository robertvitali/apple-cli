import Foundation
import ArgumentParser
import AppleKit
import EventKitCore
import EventKit

/// `apple calendar events …` — the calendar_events strict superset (read/create/update/delete).
public struct EventsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "Calendar events — read/create/update/delete (ports calendar_events).",
        subcommands: [EventsRead.self, EventsCreate.self, EventsUpdate.self, EventsDelete.self],
        defaultSubcommand: EventsRead.self
    )
    public init() {}
}

// MARK: - read

public struct EventsRead: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read events in a window (default today … +14d) or a single event by --id.")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .long, help: "Read a single event by its identifier.") public var id: String?
    @Option(name: .long, help: "Window start (yyyy-MM-dd, 'yyyy-MM-dd HH:mm:ss', or ISO-8601).") public var start: String?
    @Option(name: .long, help: "Window end.") public var end: String?
    @Option(name: .long, help: "Filter by calendar name or id.") public var calendar: String?
    @Option(name: .long, help: "Filter by account (source) name, e.g. iCloud.") public var account: String?
    @Option(name: .long, help: "Substring filter over title/notes/location.") public var search: String?
    @Option(name: .long, help: "Filter by availability: busy|free|tentative|unavailable.") public var availability: String?

    public init() {}

    public func run() throws {
        try runGuarded(tool: "calendar") {
            let store = EventStore()
            try store.requestAccess(to: .event, mode: .read)

            if let id {
                guard let ekEvent = store.event(withIdentifier: id) else {
                    throw AppleError.notFound("no event with id '\(id)'")
                }
                try Output.emit(tool: "calendar", data: EventMapping.event(from: ekEvent))
                return
            }

            // Bare-date bounds floor to start-of-day (midnight), matching the MCP's date-only bounds.
            let window = ReadWindow.resolve(
                start: try start.map { try DateArg.windowBound($0) },
                end: try end.map { try DateArg.windowBound($0) })

            let allCollections = store.calendars(for: .event)
            var fetchCalendars = allCollections
            if let calendar {
                guard let cal = store.calendar(matching: calendar, entity: .event) else {
                    throw AppleError.notFound("no calendar named or id '\(calendar)'")
                }
                fetchCalendars = [cal]
            }
            if let account {
                let known = Set(allCollections.compactMap { $0.source?.title })
                guard known.contains(account) else {
                    throw AppleError.notFound("no account '\(account)' (known: \(known.sorted().joined(separator: ", ")))")
                }
                fetchCalendars = fetchCalendars.filter { $0.source?.title == account }
            }

            var events = store.events(start: window.start, end: window.end, calendars: fetchCalendars)
            if let term = search?.lowercased(), !term.isEmpty {
                events = events.filter {
                    ($0.title?.lowercased().contains(term) ?? false)
                    || ($0.notes?.lowercased().contains(term) ?? false)
                    || ($0.location?.lowercased().contains(term) ?? false)
                }
            }
            if let availability {
                guard EKEnum.availability(from: availability) != nil else {
                    throw AppleError.validation("bad --availability '\(availability)' (busy|free|tentative|unavailable)")
                }
                events = events.filter { EKEnum.availabilityString($0.availability) == availability.lowercased() }
            }

            let data = EventsReadData(
                calendars: allCollections.map { ReadMapping.collection(from: $0) }
                    .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending },
                events: events.map { EventMapping.event(from: $0) })
            try Output.emit(tool: "calendar", data: data)
        }
    }
}

// MARK: - create

public struct EventsCreate: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create an event (dry-run by default; --execute writes under the test-mode gate).")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .long, help: "Event title (required).") public var title: String
    @Option(name: .long, help: "Start date (required).") public var start: String
    @Option(name: .long, help: "End date (required).") public var end: String
    @Option(name: .long, help: "Notes/body.") public var note: String?
    @Option(name: .long, help: "Plain-text location.") public var location: String?
    @Option(name: .long, help: "Associated URL (needs a scheme, e.g. https://…).") public var url: String?
    @Flag(name: .customLong("all-day"), help: "Mark as an all-day event.") public var allDay = false
    @Option(name: .long, help: "Availability: busy|free|tentative|unavailable.") public var availability: String?
    @Option(name: .customLong("target-calendar"), help: "Calendar name/id to create in (default: default calendar).") public var targetCalendar: String?
    @Option(name: .customLong("geo-lat"), help: "Structured-location latitude.") public var geoLat: Double?
    @Option(name: .customLong("geo-lon"), help: "Structured-location longitude.") public var geoLon: Double?
    @Option(name: .customLong("geo-radius"), help: "Structured-location radius (m).") public var geoRadius: Double?
    @Option(name: .customLong("geo-title"), help: "Structured-location title (may stand alone, no coords).") public var geoTitle: String?
    @Option(name: .long, help: "Alarm (repeatable): 15m|2h|1d before, +15m after, geo:lat,lon[,r][,enter|leave][,title], or a date.") public var alarm: [String] = []
    @Option(name: .long, help: "Recurrence spec (repeatable): freq=weekly;interval=2;byday=2,4;count=10.") public var recurrence: [String] = []

    public init() {}

    public func run() throws {
        try runGuarded(tool: "calendar") {
            let startParsed = try DateArg.parse(start)
            let endParsed = try DateArg.parse(end)
            guard endParsed.date >= startParsed.date else {
                throw AppleError.validation("end date must be on or after start date")
            }
            // Match the MCP: is_all_day comes ONLY from the explicit flag (no inference).
            let isAllDay = allDay
            if let availability, EKEnum.availability(from: availability) == nil {
                throw AppleError.validation("bad --availability '\(availability)' (busy|free|tentative|unavailable)")
            }
            let structured = try StructuredLocationArg.parse(lat: geoLat, lon: geoLon, radius: geoRadius, title: geoTitle)
            let alarms = try alarm.map { try AlarmSpec.parse($0) }
            let rules = try recurrence.map { try RecurrenceSpec.parse($0) }
            let validatedURL = try url.flatMap { $0.isEmpty ? nil : try URLArg.require($0) }
            // Validate the EK objects build (throws on bad range) even in dry-run.
            _ = try alarms.map { try AlarmMapping.ekAlarm(from: $0) }
            _ = try rules.map { try RecurrenceMapping.ekRule(from: $0) }

            guard try CalendarWriteGuard.gateOpen(willExecute: global.willExecute, testMode: global.testMode) else {
                try Output.emit(tool: "calendar", data: EventWritePreview(
                    action: "create", title: title, start_date: startParsed.date, end_date: endParsed.date,
                    is_all_day: isAllDay, availability: availability, location: location, url: url, note: note,
                    target_calendar: targetCalendar, structured_location: structured,
                    alarms: alarms.isEmpty ? nil : alarms, recurrence_rules: rules.isEmpty ? nil : rules))
                return
            }
            // Live write: the created item MUST be labeled test data.
            try CalendarWriteGuard.requireLabeled(title)

            let store = EventStore()
            try store.requestAccess(to: .event, mode: .write)
            guard let cal = resolveCalendar(store: store, name: targetCalendar) else {
                throw AppleError.notFound("no calendar named or id '\(targetCalendar ?? "")' and no default calendar")
            }
            let event = store.newEvent()
            event.calendar = cal
            event.title = title
            event.startDate = startParsed.date
            event.endDate = endParsed.date
            event.isAllDay = isAllDay
            event.timeZone = TZDetect.from(start) ?? TimeZone.current
            if let note { event.notes = note }
            if let location { event.location = location }
            if let validatedURL { event.url = validatedURL }
            if let availability, let a = EKEnum.availability(from: availability) { event.availability = a }
            if let structured { event.structuredLocation = ReadMapping.ekStructuredLocation(from: structured) }
            if !alarms.isEmpty { event.alarms = try alarms.map { try AlarmMapping.ekAlarm(from: $0) } }
            if !rules.isEmpty { event.recurrenceRules = try rules.map { try RecurrenceMapping.ekRule(from: $0) } }

            try store.save(event, span: .thisEvent)
            try Output.emit(tool: "calendar", data: EventMapping.event(from: event))
        }
    }

    func resolveCalendar(store: EventStore, name: String?) -> EKCalendar? {
        if let name { return store.calendar(matching: name, entity: .event) }
        return store.defaultCalendarForEvents
    }
}

// MARK: - update

public struct EventsUpdate: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update an event (dry-run by default; --execute writes under the test-mode gate).")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .long, help: "Event identifier (required).") public var id: String
    @Option(name: .long, help: "New title.") public var title: String?
    @Option(name: .long, help: "New start date.") public var start: String?
    @Option(name: .long, help: "New end date.") public var end: String?
    @Option(name: .long, help: "New notes/body.") public var note: String?
    @Option(name: .long, help: "New location.") public var location: String?
    @Option(name: .long, help: "New URL ('' clears; needs a scheme otherwise).") public var url: String?
    @Flag(inversion: .prefixedNo, help: "Set/unset all-day (--all-day / --no-all-day).") public var allDay: Bool?
    @Option(name: .long, help: "Availability: busy|free|tentative|unavailable.") public var availability: String?
    @Option(name: .customLong("target-calendar"), help: "Move to this calendar (cross-calendar move).") public var targetCalendar: String?
    @Option(name: .customLong("geo-lat")) public var geoLat: Double?
    @Option(name: .customLong("geo-lon")) public var geoLon: Double?
    @Option(name: .customLong("geo-radius")) public var geoRadius: Double?
    @Option(name: .customLong("geo-title")) public var geoTitle: String?
    @Flag(name: .customLong("clear-structured-location"), help: "Remove the structured location.") public var clearStructuredLocation = false
    @Option(name: .long, help: "Alarm (repeatable, replaces existing): 15m|2h|1d before, +15m after, geo:…, or a date.") public var alarm: [String] = []
    @Flag(name: .customLong("clear-alarms"), help: "Remove all alarms.") public var clearAlarms = false
    @Option(name: .long, help: "Recurrence spec (repeatable) — replaces existing rules.") public var recurrence: [String] = []
    @Flag(name: .customLong("clear-recurrence"), help: "Remove recurrence.") public var clearRecurrence = false
    @Option(name: .long, help: "Recurring-edit scope: this-event|future-events (default this-event).") public var span: String?

    public init() {}

    public func run() throws {
        try runGuarded(tool: "calendar") {
            // Reject contradictory clear+set flags rather than silently letting "clear" win.
            if clearAlarms && !alarm.isEmpty { throw AppleError.validation("--clear-alarms conflicts with --alarm") }
            if clearRecurrence && !recurrence.isEmpty { throw AppleError.validation("--clear-recurrence conflicts with --recurrence") }
            if clearStructuredLocation && (geoLat != nil || geoLon != nil || geoRadius != nil || geoTitle != nil) {
                throw AppleError.validation("--clear-structured-location conflicts with --geo-*")
            }
            if let availability, EKEnum.availability(from: availability) == nil {
                throw AppleError.validation("bad --availability '\(availability)' (busy|free|tentative|unavailable)")
            }
            let startParsed = try start.map { try DateArg.parse($0) }
            let endParsed = try end.map { try DateArg.parse($0) }
            let structured = try StructuredLocationArg.parse(lat: geoLat, lon: geoLon, radius: geoRadius, title: geoTitle)
            let alarms = try alarm.map { try AlarmSpec.parse($0) }
            let rules = try recurrence.map { try RecurrenceSpec.parse($0) }
            let validatedURL: URL?? = try url.map { $0.isEmpty ? nil : try URLArg.require($0) }
            _ = try alarms.map { try AlarmMapping.ekAlarm(from: $0) }
            _ = try rules.map { try RecurrenceMapping.ekRule(from: $0) }
            let ekSpan = try resolveSpan()

            guard try CalendarWriteGuard.gateOpen(willExecute: global.willExecute, testMode: global.testMode) else {
                try Output.emit(tool: "calendar", data: EventWritePreview(
                    action: "update", id: id, title: title, start_date: startParsed?.date, end_date: endParsed?.date,
                    is_all_day: allDay, availability: availability, location: location, url: url, note: note,
                    target_calendar: targetCalendar, structured_location: structured,
                    alarms: alarms.isEmpty ? nil : alarms, recurrence_rules: rules.isEmpty ? nil : rules,
                    clear_alarms: clearAlarms ? true : nil, clear_recurrence: clearRecurrence ? true : nil,
                    clear_structured_location: clearStructuredLocation ? true : nil, span: span))
                return
            }

            let store = EventStore()
            try store.requestAccess(to: .event, mode: .write)
            guard let event = store.event(withIdentifier: id) else {
                throw AppleError.notFound("no event with id '\(id)'")
            }
            // Fail-closed: only mutate an EXISTING event that is labeled test data (guards against
            // modifying an arbitrary real event by id — a DANGEROUS ACTION).
            try CalendarWriteGuard.requireLabeled(event.title ?? "")

            if let title { event.title = title }
            if let startParsed { event.startDate = startParsed.date }
            if let endParsed { event.endDate = endParsed.date }
            if let start, let startParsed, !startParsed.isDateOnly { event.timeZone = TZDetect.from(start) ?? TimeZone.current }
            if let allDay { event.isAllDay = allDay }
            if let note { event.notes = note }
            if let location { event.location = location }
            if let validatedURL { event.url = validatedURL }
            if let availability, let a = EKEnum.availability(from: availability) { event.availability = a }
            if let targetCalendar {
                guard let cal = store.calendar(matching: targetCalendar, entity: .event) else {
                    throw AppleError.notFound("no calendar named or id '\(targetCalendar)'")
                }
                event.calendar = cal
            }
            if clearStructuredLocation { event.structuredLocation = nil }
            else if let structured { event.structuredLocation = ReadMapping.ekStructuredLocation(from: structured) }
            if clearAlarms { event.alarms = [] }
            else if !alarms.isEmpty { event.alarms = try alarms.map { try AlarmMapping.ekAlarm(from: $0) } }
            if clearRecurrence { event.recurrenceRules = [] }
            else if !rules.isEmpty { event.recurrenceRules = try rules.map { try RecurrenceMapping.ekRule(from: $0) } }

            try store.save(event, span: ekSpan)
            try Output.emit(tool: "calendar", data: EventMapping.event(from: event))
        }
    }

    func resolveSpan() throws -> EKSpan {
        guard let span else { return .thisEvent }
        if span.lowercased() == "all" {
            throw AppleError.validation("span 'all' is only valid for delete; use this-event|future-events for update")
        }
        guard let s = EKEnum.span(from: span) else {
            throw AppleError.validation("bad --span '\(span)' (this-event|future-events)")
        }
        return s
    }
}

// MARK: - delete

public struct EventsDelete: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete an event (dry-run by default; --execute deletes under the test-mode gate).")

    @OptionGroup public var global: GlobalOptions
    @Option(name: .long, help: "Event identifier (required).") public var id: String
    @Option(name: .long, help: "Recurring scope: this|future|all (default this-event). 'all' removes the whole series from the master id.") public var span: String?

    public init() {}

    public func run() throws {
        try runGuarded(tool: "calendar") {
            let (ekSpan, spanLabel) = try resolveSpan()

            guard try CalendarWriteGuard.gateOpen(willExecute: global.willExecute, testMode: global.testMode) else {
                try Output.emit(tool: "calendar", data: EventWritePreview(action: "delete", id: id, span: spanLabel))
                return
            }

            let store = EventStore()
            try store.requestAccess(to: .event, mode: .write)
            guard let event = store.event(withIdentifier: id) else {
                throw AppleError.notFound("no event with id '\(id)'")
            }
            // Fail-closed: only delete an EXISTING event that is labeled test data (never an
            // arbitrary real event / series by id — an irreversible DANGEROUS ACTION).
            try CalendarWriteGuard.requireLabeled(event.title ?? "")

            try store.remove(event, span: ekSpan)
            try Output.emit(tool: "calendar", data: DeleteData(id: id, deleted: true, span: spanLabel))
        }
    }

    /// this|this-event → .thisEvent; future|future-events → .futureEvents; all → .futureEvents
    /// (EventKit has no "all" span; deleting with futureEvents from the series master removes the
    /// whole series — the CLI's documented superset of the MCP's this/future).
    func resolveSpan() throws -> (EKSpan, String) {
        guard let span else { return (.thisEvent, "this-event") }
        switch span.lowercased() {
        case "this", "this-event": return (.thisEvent, "this-event")
        case "future", "future-events": return (.futureEvents, "future-events")
        case "all": return (.futureEvents, "all")
        default: throw AppleError.validation("bad --span '\(span)' (this|future|all)")
        }
    }
}
