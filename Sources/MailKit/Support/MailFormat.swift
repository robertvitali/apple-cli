import Foundation

/// Formatting + parsing helpers shared across the Mail domain. Pure (no I/O), so every
/// function here is directly unit-testable and feeds the golden-JSON snapshots.
public enum MailFormat {

    // MARK: Dates

    /// Apple's Envelope Index stores `date_received`/`date_sent`/`display_date` as Unix
    /// epoch seconds (verified: today's mail decodes correctly with `unixepoch`). We render
    /// ISO-8601 in UTC (`…Z`) — deterministic for golden snapshots and a strict quality
    /// superset of MCP A's human string ("Friday, September 5, 2014 …") and MCP B's naive
    /// local "YYYY-MM-DDTHH:MM:SS".
    public static func iso(fromUnix seconds: Int?) -> String? {
        guard let seconds, seconds != 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        return isoFormatter.string(from: date)
    }

    // ISO8601DateFormatter's `.string(from:)` is thread-safe once configured; the formatter
    // is only read after this initializer, so a shared instance is safe under Swift 6 strict
    // concurrency (a fresh formatter per call would be needless allocation for a date-heavy CLI).
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Parse an ISO `YYYY-MM-DD` (date-only) bound to a Unix epoch. `endOfDay` pushes to
    /// 23:59:59 so a `date_to` bound includes the whole day (MCP parity: "full day included").
    public static func unix(fromISODate iso: String, endOfDay: Bool = false) -> Int? {
        let parts = iso.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4,
              let y = Int(parts[0]), let mo = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(mo), (1...31).contains(d) else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        comps.hour = endOfDay ? 23 : 0
        comps.minute = endOfDay ? 59 : 0
        comps.second = endOfDay ? 59 : 0
        comps.timeZone = TimeZone(identifier: "UTC")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // `date(from:)` is lenient (2026-02-30 rolls forward); reject by round-tripping the
        // y/m/d back out and requiring an exact match.
        guard let date = cal.date(from: comps) else { return nil }
        let check = cal.dateComponents([.year, .month, .day], from: date)
        guard check.year == y, check.month == mo, check.day == d else { return nil }
        return Int(date.timeIntervalSince1970)
    }

    // MARK: Senders / addresses

    /// Render a sender/recipient as MCP B does: `"Display Name <email>"` when a display name
    /// exists, else the bare address. `name`/`address` come from the `addresses` table
    /// (`comment` = display name, `address` = email).
    public static func person(name: String?, address: String?) -> String {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let a = (address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty && !a.isEmpty { return "\(n) <\(a)>" }
        if !a.isEmpty { return a }
        return n
    }

    /// Extract a lowercased domain from an email address (for `--by-domain` analytics).
    public static func domain(ofAddress address: String) -> String? {
        guard let at = address.lastIndex(of: "@") else { return nil }
        let dom = address[address.index(after: at)...].lowercased()
        return dom.isEmpty ? nil : String(dom)
    }

    // MARK: RFC 5322 Message-ID

    /// The Envelope Index stores the RFC-5322 Message-ID header WITH angle brackets
    /// (`<abc@host>`). MCP B strips them for `internet_message_id` and percent-wraps them for
    /// the `message://` deep link. Return the bracket-stripped form.
    public static func stripAngleBrackets(_ header: String?) -> String? {
        guard var h = header?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty else { return nil }
        if h.hasPrefix("<") { h.removeFirst() }
        if h.hasSuffix(">") { h.removeLast() }
        return h.isEmpty ? nil : h
    }

    /// MCP B's `mail_link`: `message://%3C<percent-encoded message-id>%3E`. Mirrors Mail.app's
    /// own deep-link scheme so the value round-trips into `open`/Mail.
    public static func mailLink(internetMessageID: String?) -> String? {
        guard let id = internetMessageID, !id.isEmpty else { return nil }
        // Leave `@` unencoded to match MCP B's `mail_link` byte-for-byte (Mail accepts both).
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~@")
        let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
        return "message://%3C\(encoded)%3E"
    }
}
