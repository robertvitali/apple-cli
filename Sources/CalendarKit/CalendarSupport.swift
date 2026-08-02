import Foundation
import AppleKit
import EventKitCore

// Shared helpers for the Calendar command surface: CLI-native parsers for alarms / recurrence
// (a friendlier superset of the MCP's JSON-blob inputs — every MCP parameter is expressible),
// the read-window default that mirrors the apple-events MCP (today … today+14d), timezone
// detection, structured-location + URL validation, the phase write-guard, and the Encodable
// output DTOs. Kept pure + unit-testable (no EKEventStore).

// MARK: - Date argument parsing (maps EventKitCore's ParseError → AppleError.validation/64)

/// Wrap `DateParsing.parse` so a malformed user date becomes a `validation_error` (exit 64)
/// instead of escaping to `runGuarded`'s generic catch as `unknown` (exit 70). EventKitCore is
/// the shared frozen core (it can't depend on the command-layer error mapping), so the command
/// layer adapts its `ParseError` here.
public enum DateArg {
    public static func parse(_ s: String) throws -> DateParsing.Parsed {
        do { return try DateParsing.parse(s) }
        catch { throw AppleError.validation(String(describing: error)) }
    }
    public static func date(_ s: String) throws -> Date { try parse(s).date }

    /// A read-window bound: a bare `yyyy-MM-dd` floors to START-OF-DAY (midnight), matching the
    /// MCP's date-only bounds (`DateParsing.parse` anchors bare dates at noon, which is right for
    /// all-day CREATION but 12h off for a query bound).
    public static func windowBound(_ s: String, calendar: Calendar = .current) throws -> Date {
        let p = try parse(s)
        return p.isDateOnly ? calendar.startOfDay(for: p.date) : p.date
    }
}

// MARK: - Timezone detection (parity: MCP sets event.timeZone from the input's offset)

public enum TZDetect {
    /// Detect an explicit timezone in a timed date string (trailing `Z`, or `±HH:MM`/`±HHMM`/
    /// `±HH`). Returns nil for a no-offset (local) input — the caller uses `TimeZone.current`,
    /// exactly as the MCP does. A bare date's trailing `-15` (a day) is NOT read as an offset:
    /// detection only runs on strings that carry a time component.
    public static func from(_ raw: String) -> TimeZone? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("Z") { return TimeZone(secondsFromGMT: 0) }
        guard s.contains("T") || s.contains(":") else { return nil } // must be timed
        guard let m = s.range(of: #"[+-]\d{2}:?\d{2}$|[+-]\d{2}$"#, options: .regularExpression) else { return nil }
        let off = String(s[m])
        let sign = off.first == "-" ? -1 : 1
        let digits = off.dropFirst().replacingOccurrences(of: ":", with: "")
        let hours: Int, minutes: Int
        if digits.count == 4 { hours = Int(digits.prefix(2)) ?? 0; minutes = Int(digits.suffix(2)) ?? 0 }
        else if digits.count == 2 { hours = Int(digits) ?? 0; minutes = 0 }
        else { return nil }
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }
}

// MARK: - URL validation

public enum URLArg {
    /// Validate a non-empty `--url` (must have a scheme). Throws `validation` on garbage instead
    /// of silently ignoring it (create) or silently clearing an existing URL (update).
    public static func require(_ s: String) throws -> URL {
        guard let u = URL(string: s), u.scheme != nil else {
            throw AppleError.validation("invalid --url '\(s)' (needs a scheme, e.g. https://…)")
        }
        return u
    }
}

// MARK: - Structured location (event geo) parsing

public enum StructuredLocationArg {
    /// Build a `StructuredLocation` from the `--geo-*` flags. A title-only location (no coords)
    /// is VALID and matches the MCP (its `structuredLocation` requires only `title`). When either
    /// coordinate is given, BOTH are required and are range-checked. Returns nil when no geo flag
    /// was supplied.
    public static func parse(lat: Double?, lon: Double?, radius: Double?, title: String?) throws -> StructuredLocation? {
        if lat == nil && lon == nil && radius == nil && title == nil { return nil }
        if lat != nil || lon != nil {
            guard let la = lat, let lo = lon else {
                throw AppleError.validation("structured location needs both --geo-lat and --geo-lon together")
            }
            guard la.isFinite, lo.isFinite, (-90...90).contains(la), (-180...180).contains(lo) else {
                throw AppleError.validation("geo coordinates out of range (lat -90…90, lon -180…180, finite)")
            }
            return StructuredLocation(title: title, latitude: la, longitude: lo, radius: finiteRadius(radius))
        }
        guard title != nil else {
            throw AppleError.validation("structured location needs a --geo-title or --geo-lat/--geo-lon")
        }
        return StructuredLocation(title: title, latitude: nil, longitude: nil, radius: finiteRadius(radius))
    }

    static func finiteRadius(_ r: Double?) -> Double {
        guard let r, r.isFinite, r >= 0 else { return 0 }
        return r
    }
}

// MARK: - Read window (parity: DEFAULT_READ_WINDOW_DAYS = 14, forward from today)

public enum ReadWindow {
    public static let defaultDays = 14

    /// Resolve the [start, end] event query window from optional bounds, matching the MCP's
    /// `resolveReadDateRange`: neither → [startOfToday, +14d]; start only → [start, start+14d];
    /// end only → [end-14d, end]; both → as given. `now`/`calendar` injectable for tests.
    public static func resolve(
        start: Date?, end: Date?, now: Date = Date(), calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let day: TimeInterval = 86_400
        switch (start, end) {
        case let (s?, e?):
            return (s, e)
        case (nil, nil):
            let today = calendar.startOfDay(for: now)
            return (today, today.addingTimeInterval(Double(defaultDays) * day))
        case let (s?, nil):
            return (s, s.addingTimeInterval(Double(defaultDays) * day))
        case let (nil, e?):
            return (e.addingTimeInterval(-Double(defaultDays) * day), e)
        }
    }
}

// MARK: - Alarm spec parsing (--alarm, repeatable)

public enum AlarmSpec {
    /// Parse one `--alarm` spec into an `Alarm` model:
    ///   relative  : `15m`, `2h`, `1d` (unit form, unsigned ⇒ BEFORE start); `+30m` after;
    ///               a bare number is raw seconds with the MCP's `relativeOffset` sign
    ///               (`900` = +900 = after; `-900` = before).
    ///   geofence  : `geo:<lat>,<lon>[,<radius>][,enter|leave][,<title>]`
    ///   absolute  : any date string DateParsing accepts (e.g. `2026-07-15T09:00:00`)
    public static func parse(_ raw: String) throws -> Alarm {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { throw AppleError.validation("empty --alarm spec") }

        if s.lowercased().hasPrefix("geo:") {
            return try parseGeofence(String(s.dropFirst(4)))
        }
        // A date must be tried before the relative parser so ISO strings aren't misread.
        if s.contains("T") || (s.contains("-") && s.count >= 8 && !s.hasPrefix("-") && !s.hasPrefix("+")) {
            if let parsed = try? DateParsing.parse(s) { return Alarm(absolute_date: parsed.date) }
        }
        if let offset = parseRelativeOffset(s) {
            return Alarm(relative_offset: offset)
        }
        if let parsed = try? DateParsing.parse(s) {
            return Alarm(absolute_date: parsed.date)
        }
        throw AppleError.validation("unrecognized --alarm '\(raw)' (use 15m|2h|1d [before], +15m [after], geo:lat,lon,…, or a date)")
    }

    /// Unit form (`15m`/`2h`/`1d`): unsigned ⇒ BEFORE (negative), `+`/`-` honored. Bare number:
    /// raw seconds carrying its own sign (`900` = +900, matching MCP `relativeOffset`). nil if
    /// not a relative form.
    static func parseRelativeOffset(_ s: String) -> Double? {
        var body = Substring(s)
        var explicitSign = false
        var sign: Double = 1
        if let first = body.first, first == "-" || first == "+" {
            explicitSign = true
            sign = first == "-" ? -1 : 1
            body = body.dropFirst()
        }
        guard let unit = body.last else { return nil }
        if unit.isNumber { // bare number → raw seconds, sign as written (default +)
            guard let value = Double(body) else { return nil }
            return sign * value
        }
        let effectiveSign = explicitSign ? sign : -1 // unit form, unsigned ⇒ before start
        let magnitude = body.dropLast()
        guard !magnitude.isEmpty, let value = Double(magnitude) else { return nil }
        let seconds: Double
        switch unit.lowercased() {
        case "s": seconds = value
        case "m": seconds = value * 60
        case "h": seconds = value * 3600
        case "d": seconds = value * 86_400
        default: return nil
        }
        return effectiveSign * seconds
    }

    static func parseGeofence(_ body: String) throws -> Alarm {
        let parts = body.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else {
            throw AppleError.validation("geofence alarm needs at least lat,lon (got '\(body)')")
        }
        guard lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else {
            throw AppleError.validation("geofence lat/lon out of range (lat -90…90, lon -180…180, finite)")
        }
        // Radius is optional: it occupies position 2 ONLY when numeric; otherwise position 2 is
        // already a proximity/title token (so an omitted radius no longer swallows it).
        var radius = 100.0
        var extrasStart = 2
        if parts.count >= 3, let r = Double(parts[2]) {
            guard r.isFinite, r >= 0 else { throw AppleError.validation("geofence radius must be finite and >= 0") }
            radius = r
            extrasStart = 3
        }
        var proximity = "enter"
        var title: String?
        for extra in parts[extrasStart...] {
            let low = extra.lowercased()
            if low == "enter" || low == "leave" || low == "depart" || low == "exit" {
                proximity = low
            } else if !extra.isEmpty {
                title = extra
            }
        }
        return Alarm(location_trigger: LocationTrigger(
            title: title, latitude: lat, longitude: lon, radius: radius, proximity: proximity))
    }
}

// MARK: - Recurrence spec parsing (--recurrence, repeatable)

public enum RecurrenceSpec {
    /// Parse one `--recurrence` spec (`key=value;key=value`) into a `RecurrenceRule`:
    ///   freq=daily|weekly|monthly|yearly (required) · interval=N · count=N · until=YYYY-MM-DD
    ///   byday=1..7 (1=Sun) · bymonthday=1..31/-1..-31 · bymonth=1..12 · bysetpos=N
    public static func parse(_ raw: String) throws -> RecurrenceRule {
        var fields: [String: String] = [:]
        for pair in raw.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else {
                throw AppleError.validation("bad --recurrence segment '\(pair)' (use key=value)")
            }
            fields[kv[0].trimmingCharacters(in: .whitespaces).lowercased()] = kv[1].trimmingCharacters(in: .whitespaces)
        }
        guard let freq = fields["freq"], !freq.isEmpty else {
            throw AppleError.validation("--recurrence requires freq=daily|weekly|monthly|yearly")
        }
        let interval = try fields["interval"].map { try intOf($0, "interval") } ?? 1
        var count = try fields["count"].map { try intOf($0, "count") }
        var endDate: Date?
        if let until = fields["until"] {
            endDate = try DateArg.date(until)
        }
        // RFC-5545 forbids COUNT and UNTIL together; if both are given, endDate wins — matching
        // the MCP (its recurrenceRuleFromJSON checks endDate first). EventKitCore's ekRule would
        // otherwise let count win, so normalize here rather than diverge from the oracle.
        if endDate != nil { count = nil }
        return RecurrenceRule(
            frequency: freq.lowercased(),
            interval: interval,
            end_date: endDate,
            occurrence_count: count,
            days_of_week: try intList(fields["byday"], "byday"),
            days_of_month: try intList(fields["bymonthday"], "bymonthday"),
            months_of_year: try intList(fields["bymonth"], "bymonth"),
            set_positions: try intList(fields["bysetpos"], "bysetpos")
        )
    }

    static func intOf(_ s: String, _ name: String) throws -> Int {
        guard let v = Int(s) else { throw AppleError.validation("--recurrence \(name) must be an integer (got '\(s)')") }
        return v
    }

    static func intList(_ s: String?, _ name: String) throws -> [Int]? {
        guard let s, !s.isEmpty else { return nil }
        return try s.split(separator: ",").map { try intOf($0.trimmingCharacters(in: .whitespaces), name) }
    }
}

// MARK: - Output DTOs (the calendar wire shapes)

/// `events read` (no id): calendars + events, mirroring the MCP's EventsReadResult.
public struct EventsReadData: Encodable {
    public let calendars: [CalendarCollection]
    public let events: [CalendarEvent]
    public init(calendars: [CalendarCollection], events: [CalendarEvent]) {
        self.calendars = calendars
        self.events = events
    }
}

/// `calendars list`: the collections.
public struct CalendarsData: Encodable {
    public let calendars: [CalendarCollection]
    public init(calendars: [CalendarCollection]) { self.calendars = calendars }
}

/// `events delete` result.
public struct DeleteData: Encodable {
    /// Always `false`: this DTO is only emitted from the EXECUTE path, so the flag states outright
    /// that the delete happened rather than leaving the caller to infer it from the ABSENCE of the
    /// preview's `dry_run: true`. Write-model v2 makes execute the default, so "no dry_run key"
    /// would be the common case and silence is the wrong signal for a destructive op.
    public let dry_run: Bool
    public let id: String
    public let deleted: Bool
    public let span: String?
    public init(id: String, deleted: Bool, span: String?) {
        self.dry_run = false
        self.id = id
        self.deleted = deleted
        self.span = span
    }
}

/// Dry-run preview of a create/update/delete — echoes the parsed + normalized intent so the
/// parse is verifiable without touching the live store (the default for a write without
/// `--execute`).
public struct EventWritePreview: Encodable {
    public let dry_run: Bool
    public let action: String
    public let id: String?
    public let title: String?
    public let start_date: Date?
    public let end_date: Date?
    public let is_all_day: Bool?
    public let availability: String?
    public let location: String?
    public let url: String?
    public let note: String?
    public let target_calendar: String?
    public let structured_location: StructuredLocation?
    public let alarms: [Alarm]?
    public let recurrence_rules: [RecurrenceRule]?
    public let clear_alarms: Bool?
    public let clear_recurrence: Bool?
    public let clear_structured_location: Bool?
    public let span: String?
    /// `true` when the sandbox is engaged AND this write is addressed by opaque id, so the label
    /// check could NOT run at preview time: the target's title lives in EventKit and only the
    /// execute path fetches it. Disclosed rather than silently skipped — a preview that omits a
    /// check it cannot perform must say so, otherwise a caller reads "no refusal" as "allowed".
    /// Absent (nil) whenever the check DID run, i.e. every title-addressed write and every
    /// unsandboxed one.
    public let sandbox_target_unchecked: Bool?

    public init(
        action: String, id: String? = nil, title: String? = nil, start_date: Date? = nil,
        end_date: Date? = nil, is_all_day: Bool? = nil, availability: String? = nil,
        location: String? = nil, url: String? = nil, note: String? = nil,
        target_calendar: String? = nil, structured_location: StructuredLocation? = nil,
        alarms: [Alarm]? = nil, recurrence_rules: [RecurrenceRule]? = nil,
        clear_alarms: Bool? = nil, clear_recurrence: Bool? = nil,
        clear_structured_location: Bool? = nil, span: String? = nil,
        sandbox_target_unchecked: Bool? = nil
    ) {
        self.dry_run = true
        self.sandbox_target_unchecked = sandbox_target_unchecked
        self.action = action
        self.id = id
        self.title = title
        self.start_date = start_date
        self.end_date = end_date
        self.is_all_day = is_all_day
        self.availability = availability
        self.location = location
        self.url = url
        self.note = note
        self.target_calendar = target_calendar
        self.structured_location = structured_location
        self.alarms = alarms
        self.recurrence_rules = recurrence_rules
        self.clear_alarms = clear_alarms
        self.clear_recurrence = clear_recurrence
        self.clear_structured_location = clear_structured_location
        self.span = span
    }
}

// MARK: - Write-model v2 gate (docs/write-model-v2.md)

/// Emit a calendar write result, tagging the envelope when the sandbox is engaged so a caller
/// can tell a restricted write from a normal one without re-reading the environment.
func emitCalendarWrite<T: Encodable>(_ data: T, sandboxActive: Bool) throws {
    try Output.emit(tool: "calendar", data: data, sandboxActive: sandboxActive)
}

public enum CalendarWriteGuard {
    /// The resolved write posture for one calendar command. Bound ONCE at the top of every write
    /// `run()` and threaded from there — never re-derived mid-command.
    public struct Gate {
        public let willExecute: Bool
        public let sandboxActive: Bool
    }

    /// Resolve a calendar write under write-model v2: **it executes by default**, exactly as
    /// calling the equivalent `mcp-server-apple-events` `calendar_events` action does. `--dry-run`
    /// previews; `APPLE_DRY_RUN` truthy restores dry-run-by-default; `--test-mode` or
    /// `APPLE_TEST_MODE` truthy engages the opt-in sandbox.
    ///
    /// ORACLE EVIDENCE (`mcp-server-apple-events@1.4.0`, re-derived from BOTH `src/` and `dist/`,
    /// each verified non-empty first): the only runtime `process.env` reads in non-test sources are
    /// `NODE_ENV`, `DEBUG` and `SWIFT_BINARY_HASH` (`utils/errorHandling.ts`, `utils/projectUtils.ts`,
    /// `utils/binaryValidator.ts`) — none is a write gate, so there is NO env-keyed oracle gate to
    /// mirror here (contrast Contacts' `CONTACTS_TEST_MODE`). `tools/index.ts` is pure routing with
    /// no gate, and `handlers/*.ts` go straight to `calendarRepository.deleteEvent` →
    /// `executeCli(['--action','delete-event','--id',id])`. The oracle's own Swift binary
    /// (`src/swift/EventKitCLI.swift`, 1619 lines) reads no environment and self-gates nothing.
    /// So all three calendar writes are bucket 3: the v1 gate was CLI-only and becomes sandbox-only.
    /// NO `defaultDryRun` parameter, deliberately. `GlobalOptions.willExecute(defaultDryRun:)`
    /// leaves it non-defaulted on purpose ("every surface states its own"), and a wrapper that
    /// re-adds a default silently re-creates that footgun: a future preview-by-default surface
    /// would inherit execute-by-default just by forgetting the argument. All three Calendar
    /// writes execute by default and NONE has a per-surface exception (unlike Mail's trash or
    /// Notes' delete-folder), so the honest signature is one that offers no choice. Adding the
    /// parameter back when a real exception appears is then a deliberate, reviewable act.
    public static func resolve(_ global: GlobalOptions) throws -> Gate {
        try TestMode.validateWriteEnvironment()
        let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
        let willExecute = try global.willExecute(defaultDryRun: false)
        return Gate(willExecute: willExecute, sandboxActive: sandboxActive)
    }

    /// SANDBOX-ONLY label check: inside the sandbox the item being created/mutated must be a
    /// labeled test target. For CREATE pass the new title; for UPDATE/DELETE pass the EXISTING
    /// event's title, so a sandboxed run can only touch data it labeled. Outside the sandbox this
    /// is a no-op — the oracle creates and deletes real events on call, and so do we.
    ///
    /// `prefix:` is a test seam. `TestMode.sandboxPrefix` is env-backed (`APPLE_TEST_SANDBOX`), and
    /// swift-testing runs every suite in ONE process in parallel — MailKitTests setenv()s it to
    /// "qa-fixture" mid-run, which flaked the Contacts and Notes posture suites before the seam
    /// existed. A logic-tier test passes the canonical constant explicitly rather than inheriting
    /// a value it hard-codes expectations about.
    public static func requireLabeled(_ name: String, sandboxActive: Bool,
                                      prefix: String? = nil) throws {
        guard sandboxActive else { return }
        let required = prefix ?? TestMode.sandboxPrefix
        guard name.hasPrefix(required) else {
            throw AppleError.validation(
                "Sandbox is engaged: refusing to write to \"\(name)\" — the target must be a "
                + "labeled '\(required)…' test item.")
        }
    }
}
