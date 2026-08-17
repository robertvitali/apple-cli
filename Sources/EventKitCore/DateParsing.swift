import Foundation
import AppleKit

/// Date parsing + granularity inference, delegating to the ORACLE's own pipeline
/// (`OracleDates`, the verbatim port): the full 21-format offset ladder plus the 7 local
/// formats — bare dates, offset-bearing bare dates (`Z`/`±HH`/`±HHMM`/`±HH:MM`), second- and
/// minute-precision times with or without `T`, fractional seconds, offset or local. "No
/// timezone" resolves in the current local zone, exactly as the oracle does.
public enum DateParsing {

    public struct Parsed: Equatable, Sendable {
        public let date: Date
        /// True when the parse produced no time components (`components.hour == nil`) — the
        /// oracle's own granularity signal (`componentsSet` keys off the raw input containing
        /// `:` or `T`, so `2026-09-01+0200` is date-only with a pinned zone while
        /// `2026-09-01-04:00` is timed at 00:00 in −04:00).
        public let isDateOnly: Bool
        /// The oracle-shaped components (calendar + timeZone always populated). Reminder
        /// writes store these VERBATIM (`dueDateComponents` etc.), and their `timeZone` is
        /// what `reminder.timeZone` gets pinned to — REM-04.
        public let components: DateComponents
        public init(date: Date, isDateOnly: Bool, components: DateComponents) {
            self.date = date
            self.isDateOnly = isDateOnly
            self.components = components
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

    /// Parse a user-supplied date string through the ORACLE's own pipeline (`OracleDates`,
    /// the verbatim port of `parseDateComponents`/`parseDate`) — REM-03: the previous
    /// hand-written ladder rejected 9 input shapes the oracle accepts (offset-bearing bare
    /// dates like `2026-09-01-04:00` / `2026-09-01Z` / `2026-09-01+0200`, minute-precision
    /// times, offset-bearing space forms). `timeZone` is the LOCAL zone for no-offset inputs
    /// (defaults `.current`, same as the oracle; injectable for tests).
    ///
    /// A bare `yyyy-MM-dd` anchors at MIDNIGHT local via the oracle's own mechanism — an
    /// earlier version lifted to noon; that was CAL-02, a 12-hour divergence on every bare
    /// create/update date and recurrence end.
    ///
    /// One deliberate divergence, STRICTER not looser: on garbage the oracle's create/update
    /// silently sets the date components to NIL (a typo in `--due` would silently create a
    /// dateless reminder); we throw `unrecognized` → exit 64. Recorded as an accepted
    /// divergence in the Q10 row.
    public static func parse(_ raw: String, timeZone: TimeZone = .current) throws -> Parsed {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw ParseError.unrecognized(raw) }
        guard let comps = OracleDates.parseComponents(from: s, localZone: timeZone),
              let date = OracleDates.parseDate(from: s, localZone: timeZone) else {
            throw ParseError.unrecognized(raw)
        }
        return Parsed(date: date, isDateOnly: comps.hour == nil, components: comps)
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

}

/// Command-layer adapter: wrap `DateParsing.parse` so a malformed user date becomes an
/// `AppleError.validation` (`validation_error`, exit 64) instead of escaping to `runGuarded`'s
/// generic catch as `unknown` (exit 70). Lives HERE (not per-Kit) because both CalendarKit and
/// RemindersKit need the identical mapping — a RemindersKit copy drifted out of existence once
/// already and empty `--due` shipped as exit 70.
public enum DateArg {
    public static func parse(_ s: String) throws -> DateParsing.Parsed {
        do { return try DateParsing.parse(s) }
        catch { throw AppleError.validation(String(describing: error)) }
    }
    public static func date(_ s: String) throws -> Date { try parse(s).date }

    /// A read-window bound. The oracle uses `parseDate`'s result DIRECTLY — no floor — and since
    /// the CAL-02 fix `parse` anchors a bare local date at its own midnight, flooring is
    /// redundant for local dates and actively WRONG for the offset-bearing date-only forms the
    /// Q10 parser widening admitted (`2026-09-01+0200` is midnight IN +02:00; flooring it to the
    /// LOCAL day shifted the bound by the zone gap — review caught this as an undisclosed
    /// Calendar ripple). So: the parsed instant, verbatim.
    public static func windowBound(_ s: String) throws -> Date {
        try parse(s).date
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
