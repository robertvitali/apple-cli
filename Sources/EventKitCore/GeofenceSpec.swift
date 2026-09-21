import Foundation

/// The ONE `geo:` alarm-spec parser, shared by Calendar and Reminders (CAL-04 / REM-05: the two
/// per-domain copies both truncated a comma-bearing title to a single fragment, and disagreed
/// with each other about radius/validation).
///
/// Grammar, after the `geo:` prefix has been stripped:
///
///     <lat>,<lon>[,<radius>][,enter|leave|depart|exit][,<title — MAY contain commas>]
///
/// `radius` (numeric) and the proximity keyword may appear in either order, each at most once,
/// immediately after `lon`. The title is everything from the first fragment that is neither —
/// rejoined VERBATIM (original spacing, original commas), so `…,enter,742 Evergreen Terrace,
/// Exampleton, ZZ 00000` yields that whole address as the title instead of its last fragment.
/// Consequences, documented rather than accidental:
///   - a purely-numeric title is expressible after an explicit radius (`…,100,enter,500` →
///     title "500"), because a second numeric fragment no longer overwrites the radius;
///   - a bare numeric in the first slot IS the radius (`…,500` cannot be a title — supply a
///     radius first);
///   - a proximity keyword AFTER the title has started is part of the title (`…,Home,leave` →
///     title "Home,leave"), the price of comma-bearing titles.
public enum GeofenceSpec {

    public enum SpecError: Error, CustomStringConvertible {
        case needsLatLon(String)
        case latLonOutOfRange
        case badRadius
        public var description: String {
            switch self {
            case .needsLatLon(let body):
                return "geofence alarm needs at least lat,lon (got '\(body)')"
            case .latLonOutOfRange:
                return "geofence lat/lon out of range (lat -90…90, lon -180…180, finite)"
            case .badRadius:
                return "geofence radius must be finite and >= 0"
            }
        }
    }

    public struct Parsed: Equatable, Sendable {
        public let latitude: Double
        public let longitude: Double
        public let radius: Double
        public let proximity: String
        public let title: String?
    }

    public static func parse(_ body: String) throws -> Parsed {
        // Keep the UNTRIMMED fragments: the title is rebuilt from them verbatim, so the
        // original spacing after each comma survives.
        let rawParts = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let parts = rawParts.map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else {
            throw SpecError.needsLatLon(body)
        }
        guard lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else {
            throw SpecError.latLonOutOfRange
        }

        var radius: Double? = nil
        var proximity: String? = nil
        var i = 2
        // Consume radius / proximity in either order, each at most once; the first fragment
        // that is neither starts the title. Empty fragments before the title are skipped (the
        // old parser ignored them too), so `1,2,,Home` yields title "Home", not ",Home".
        scan: while i < parts.count {
            if parts[i].isEmpty { i += 1; continue }
            let low = parts[i].lowercased()
            if radius == nil, let r = Double(parts[i]) {
                guard r.isFinite, r >= 0 else { throw SpecError.badRadius }
                radius = r
            } else if proximity == nil, ["enter", "leave", "depart", "exit"].contains(low) {
                proximity = low
            } else {
                break scan
            }
            i += 1
        }

        var title: String? = nil
        if i < rawParts.count {
            let joined = rawParts[i...].joined(separator: ",")
                .trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { title = joined }
        }
        return Parsed(latitude: lat, longitude: lon, radius: radius ?? 100.0,
                      proximity: proximity ?? "enter", title: title)
    }
}
