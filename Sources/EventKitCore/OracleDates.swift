import Foundation

// Ported verbatim from mcp-server-apple-events (FradSer/event) EventKitCLI.swift @1.4.0,
// MIT License, Copyright (c) 2025 Frad LEE — see NOTICE.

/// Verbatim port of the oracle's date-input pipeline (`mcp-server-apple-events`
/// EventKitCLI.swift: `detectExplicitTimezone` :419, `formatterWithBaseLocale` :462,
/// `normalizedComponents` :469, `componentsSet` :476, `parseDateComponents` :483, the
/// instance `parseDate` :1115, and `formatDueDateWithTimezone` :1130) — REM-02/03/04: the
/// hand-written `DateParsing` accepted a fraction of the oracle's input formats, could not
/// carry an input's explicit offset into `timeZone`, and rendered due/start dates as UTC
/// instants with the date-only/timed distinction destroyed.
///
/// Structure is preserved deliberately, quirks included, because the quirks are load-bearing:
///
///   - `detectExplicitTimezone` FALSE-POSITIVES on a bare `yyyy-MM-dd` (the trailing `-dd`
///     matches its `[+-]\d{2}$` alternative), but every timezone-format then fails to parse
///     and control falls through to the local ladder — which is exactly how the oracle ends
///     up anchoring bare dates at LOCAL midnight. Do not "fix" the detector.
///   - `componentsSet` keys granularity off the RAW INPUT containing `:` or `T`, so
///     `2026-09-01-04:00` (offset with a colon) is TIMED (hour 0 in −04:00) while
///     `2026-09-01+0200` is DATE-ONLY with a pinned zone. That asymmetry is the oracle's.
///   - Local (no-offset) formats resolve in `localZone`, injectable ONLY so tests can pin a
///     fixed zone; production callers use the default `.current`, same as the oracle.
public enum OracleDates {

    public struct ExplicitTimezone: Equatable, Sendable {
        public let suffix: String
        public let timeZone: TimeZone
    }

    /// Oracle `detectExplicitTimezone` (EventKitCLI.swift:419) — verbatim.
    public static func detectExplicitTimezone(in dateString: String) -> ExplicitTimezone? {
        let trimmed = dateString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("Z") {
            guard let tz = TimeZone(secondsFromGMT: 0) else { return nil }
            return ExplicitTimezone(suffix: "Z", timeZone: tz)
        }

        let pattern = #"[+-]\d{2}:\d{2}$|[+-]\d{4}$|[+-]\d{2}$"#
        guard let range = trimmed.range(of: pattern, options: .regularExpression) else {
            return nil
        }

        let suffix = String(trimmed[range])
        let sign: Int = suffix.first == "-" ? -1 : 1
        let numeric = suffix.dropFirst()

        let components: (hours: Int, minutes: Int)? = {
            if suffix.contains(":") {
                let parts = numeric.split(separator: ":")
                guard parts.count == 2,
                      let hourValue = Int(parts[0]),
                      let minuteValue = Int(parts[1]) else { return nil }
                return (hourValue, minuteValue)
            }
            if numeric.count == 4 {
                let hoursPart = numeric.prefix(2)
                let minutesPart = numeric.suffix(2)
                guard let hourValue = Int(hoursPart),
                      let minuteValue = Int(minutesPart) else { return nil }
                return (hourValue, minuteValue)
            }
            if numeric.count == 2, let hourValue = Int(numeric) {
                return (hourValue, 0)
            }
            return nil
        }()

        guard let offset = components else { return nil }
        let totalSeconds = sign * ((offset.hours * 60 + offset.minutes) * 60)
        guard let timeZone = TimeZone(secondsFromGMT: totalSeconds) else { return nil }
        return ExplicitTimezone(suffix: suffix, timeZone: timeZone)
    }

    /// Oracle `formatterWithBaseLocale` (:462) — verbatim.
    private static func formatterWithBaseLocale() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }

    /// Oracle `normalizedComponents` (:469) — verbatim.
    private static func normalizedComponents(_ components: inout DateComponents,
                                             using calendar: Calendar, timeZone: TimeZone) {
        components.calendar = calendar
        components.timeZone = timeZone
        if components.second == nil && components.hour != nil { components.second = 0 }
        if components.nanosecond != nil { components.nanosecond = 0 }
    }

    /// Oracle `componentsSet` (:476) — verbatim. Granularity keys off the RAW input.
    private static func componentsSet(for input: String) -> Set<Calendar.Component> {
        if input.contains(":") || input.contains("T") {
            return [.year, .month, .day, .hour, .minute, .second]
        }
        return [.year, .month, .day]
    }

    /// Oracle `parseDateComponents` (:483) — verbatim, `localZone` in place of the two
    /// `TimeZone.current` mentions.
    public static func parseComponents(from dateString: String,
                                       localZone: TimeZone = .current) -> DateComponents? {
        let trimmedInput = dateString.trimmingCharacters(in: .whitespacesAndNewlines)

        if let tzInfo = detectExplicitTimezone(in: trimmedInput) {
            let formatter = formatterWithBaseLocale()
            formatter.timeZone = tzInfo.timeZone

            let formatsWithTimezone = [
                // Formats with colon timezone offsets (ZZZZZ, ZZZ)
                "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ",
                "yyyy-MM-dd HH:mm:ss.SSSZZZZZ",
                "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
                "yyyy-MM-dd HH:mm:ssZZZZZ",
                "yyyy-MM-dd'T'HH:mmZZZZZ",
                "yyyy-MM-dd HH:mmZZZZZ",
                "yyyy-MM-ddZZZZZ",
                "yyyy-MM-dd'T'HH:mm:ss.SSSZZZ",
                "yyyy-MM-dd HH:mm:ss.SSSZZZ",
                "yyyy-MM-dd'T'HH:mm:ssZZZ",
                "yyyy-MM-dd HH:mm:ssZZZ",
                "yyyy-MM-dd'T'HH:mmZZZ",
                "yyyy-MM-dd HH:mmZZZ",
                "yyyy-MM-ddZZZ",
                // Formats with colonless timezone offsets (Z, ZZ) - supports +0200, +02
                "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
                "yyyy-MM-dd HH:mm:ss.SSSZ",
                "yyyy-MM-dd'T'HH:mm:ssZ",
                "yyyy-MM-dd HH:mm:ssZ",
                "yyyy-MM-dd'T'HH:mmZ",
                "yyyy-MM-dd HH:mmZ",
                "yyyy-MM-ddZ"
            ]

            for format in formatsWithTimezone {
                formatter.dateFormat = format
                if let parsedDate = formatter.date(from: trimmedInput) {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = tzInfo.timeZone
                    var components = calendar.dateComponents(componentsSet(for: trimmedInput), from: parsedDate)
                    normalizedComponents(&components, using: calendar, timeZone: tzInfo.timeZone)
                    return components
                }
            }
        }

        let formatter = formatterWithBaseLocale()
        formatter.timeZone = localZone

        let localFormats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd"
        ]

        for format in localFormats {
            formatter.dateFormat = format
            if let parsedDate = formatter.date(from: trimmedInput) {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = localZone
                var components = calendar.dateComponents(componentsSet(for: trimmedInput), from: parsedDate)
                normalizedComponents(&components, using: calendar, timeZone: localZone)
                return components
            }
        }

        return nil
    }

    /// Oracle instance `parseDate` (:1115) — verbatim: components → resolved `Date`.
    public static func parseDate(from dateString: String, localZone: TimeZone = .current) -> Date? {
        guard var components = parseComponents(from: dateString, localZone: localZone) else { return nil }
        let calendar: Calendar = {
            if let existing = components.calendar { return existing }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = components.timeZone ?? localZone
            return calendar
        }()
        components.calendar = calendar
        components.timeZone = components.timeZone ?? calendar.timeZone
        return calendar.date(from: components)
    }

    /// Oracle `formatDueDateWithTimezone` (:1130) — verbatim: renders a reminder due/start from
    /// its COMPONENTS, timed iff `hour` is set, in the components' own zone (falling back to
    /// the hint, then the calendar's, then current) — REM-02's date-only vs timed distinction.
    public static func dueDateString(from dateComponents: DateComponents?,
                                     timeZoneHint: TimeZone?,
                                     localZone: TimeZone = .current) -> String? {
        guard var components = dateComponents else {
            return nil
        }

        let timeZone = components.timeZone
            ?? timeZoneHint
            ?? components.calendar?.timeZone
            ?? localZone
        var calendar = components.calendar ?? Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        components.calendar = calendar
        components.timeZone = timeZone
        guard let date = calendar.date(from: components) else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.calendar = calendar

        if components.hour != nil {
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        } else {
            formatter.dateFormat = "yyyy-MM-ddZZZZZ"
        }

        return formatter.string(from: date)
    }
}
