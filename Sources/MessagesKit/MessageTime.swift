import Foundation

/// Apple Core Data epoch (2001-01-01 UTC) conversions. `message.date` is stored as
/// nanoseconds since that epoch on modern macOS (older rows: seconds). Mirrors the
/// MCP's timestamp handling in `get_recent_messages` / `fuzzy_search_messages`.
public enum MessageTime {
    /// Seconds between the Unix epoch (1970) and the Apple epoch (2001).
    public static let appleUnixOffset: Double = 978_307_200

    /// The MCP's overflow guard: max 10 years of look-back (87,600 hours).
    public static let maxHours = 10 * 365 * 24

    /// Nanoseconds since the Apple epoch for the instant `hours` before `now`.
    /// Used as the `m.date > ?` lower bound (numeric compare — a correctness
    /// superset of the MCP's same-length `CAST(date AS TEXT) >` string compare).
    public static func thresholdNanos(hoursAgo hours: Int, now: Date = Date()) -> Int64 {
        let appleSecondsNow = now.timeIntervalSince1970 - appleUnixOffset
        let cutoff = appleSecondsNow - Double(hours) * 3600.0
        return Int64(cutoff * 1_000_000_000)
    }

    /// Convert a raw `message.date` value (ns since 2001, or seconds on legacy rows)
    /// to a `Date`. Mirrors the MCP's `len(str(ts)) > 10 → nanoseconds` heuristic.
    public static func date(fromRaw raw: Int64) -> Date {
        let digits = String(abs(raw)).count
        let appleSeconds = digits > 10 ? Double(raw) / 1_000_000_000.0 : Double(raw)
        return Date(timeIntervalSince1970: appleSeconds + appleUnixOffset)
    }

    /// Local-time `yyyy-MM-dd HH:mm:ss` rendering — the exact shape the MCP put in
    /// its `[timestamp]` prefix, preserved as a `date_local` field for parity.
    public static func localString(from date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }
}
