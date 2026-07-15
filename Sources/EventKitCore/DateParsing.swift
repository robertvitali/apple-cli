import Foundation

/// Date parsing + all-day inference, matching the apple-events MCP's accepted input formats
/// so the CLI is a behavioral superset. The MCP accepts (per its tool schema):
///   - `yyyy-MM-dd`                    → date-only ⇒ all-day inferred
///   - `yyyy-MM-dd HH:mm:ss`           → local time (no timezone)
///   - `yyyy-MM-dd'T'HH:mm:ss`         → local time (no timezone)
///   - ISO-8601 with timezone          → honored as given
///
/// "No timezone" is interpreted as the current local timezone (the MCP's documented rule).
public enum DateParsing {

    public struct Parsed: Equatable, Sendable {
        public let date: Date
        /// True when the input was a bare `yyyy-MM-dd` (no time component) — the signal the
        /// MCP/`event` use to infer an all-day event.
        public let isDateOnly: Bool
        public init(date: Date, isDateOnly: Bool) {
            self.date = date
            self.isDateOnly = isDateOnly
        }
    }

    public enum ParseError: Error, CustomStringConvertible {
        case unrecognized(String)
        public var description: String {
            switch self {
            case .unrecognized(let s):
                return "unrecognized date '\(s)' — use 'yyyy-MM-dd', 'yyyy-MM-dd HH:mm:ss', or ISO-8601"
            }
        }
    }

    /// Parse a user-supplied date string. `timeZone` defaults to the current zone (used only
    /// for the no-offset formats). Throws `ParseError.unrecognized` on no match.
    public static func parse(_ raw: String, timeZone: TimeZone = .current) throws -> Parsed {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw ParseError.unrecognized(raw) }

        // 1) Bare date → all-day. Parse at NOON local to dodge DST/midnight boundary drift
        //    (all-day events key off the calendar day, and noon is safely inside it).
        if isBareDate(s) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.isLenient = false   // reject 2026-13-45 instead of rolling it over
            f.dateFormat = "yyyy-MM-dd"
            if let day = f.date(from: s) {
                let noon = Calendar.currentWithZone(timeZone)
                    .date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
                return Parsed(date: noon, isDateOnly: true)
            }
        }

        // 2) Timed, no timezone → interpret as local.
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.isLenient = false
            f.dateFormat = fmt
            if let d = f.date(from: s) { return Parsed(date: d, isDateOnly: false) }
        }

        // 3) Full ISO-8601 with timezone offset / Z.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return Parsed(date: d, isDateOnly: false) }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return Parsed(date: d, isDateOnly: false) }

        throw ParseError.unrecognized(raw)
    }

    /// `true` when the string is exactly `yyyy-MM-dd` (the all-day signal).
    public static func isBareDate(_ s: String) -> Bool {
        guard s.count == 10 else { return false }
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return parts[0].count == 4 && parts[1].count == 2 && parts[2].count == 2
            && s.allSatisfy { $0.isNumber || $0 == "-" }
    }

    /// Format a `Date` as `yyyy-MM-dd` in the given zone (recurrence end-date input parity).
    public static func bareDateString(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Build the `DateComponents` an `EKReminder` due/start date requires (they are stored as
    /// `dueDateComponents`/`startDateComponents`, NOT a `Date`). Mirrors the MCP's granularity
    /// rule: a date-only value yields `[year, month, day]`; a timed value adds
    /// `[hour, minute, second]`. The component's calendar + timeZone are pinned so EventKit
    /// resolves the same instant `DateParsing.parse` produced. This is the write-side inverse of
    /// the `dueDateComponents?.date` read in `ReminderMapping`.
    public static func components(from date: Date, dateOnly: Bool, timeZone: TimeZone = .current) -> DateComponents {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let fields: Set<Calendar.Component> = dateOnly
            ? [.year, .month, .day]
            : [.year, .month, .day, .hour, .minute, .second]
        var comps = cal.dateComponents(fields, from: date)
        comps.calendar = cal
        comps.timeZone = timeZone
        return comps
    }
}

extension Calendar {
    /// A Gregorian calendar pinned to a specific zone (avoids mutating the shared `.current`).
    static func currentWithZone(_ tz: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal
    }
}
