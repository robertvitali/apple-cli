import Foundation

/// Mail flag colors — reconciles MCP A's 8-token palette (`none/orange/red/yellow/blue/
/// green/purple/gray`) with MCP B's binary flag/unflag into one model.
///
/// The Envelope Index `flag_color` integer and AppleScript's `set flag index` use the
/// canonical macOS Mail mapping below (red=0 … gray=6). `none` maps to "unflag" (no color).
///
/// NOTE (write path, unverified live): the CLI's `flag --color <name>` sets `flag index`
/// via AppleScript; this mapping is the documented macOS standard. The read path
/// (`flag_color` int → name) uses the same table. If a future live test shows Mail's index
/// order differs, adjust here only — both paths share this one source of truth.
public enum MailFlagColor: Int, CaseIterable, Sendable {
    case red = 0, orange = 1, yellow = 2, green = 3, blue = 4, purple = 5, gray = 6

    public var name: String {
        switch self {
        case .red: return "red"
        case .orange: return "orange"
        case .yellow: return "yellow"
        case .green: return "green"
        case .blue: return "blue"
        case .purple: return "purple"
        case .gray: return "gray"
        }
    }

    /// The 8 tokens MCP A accepts on `flag_message`, `none` included (== unflag).
    public static let acceptedTokens = ["none", "orange", "red", "yellow", "blue", "green", "purple", "gray"]

    /// Parse a `--color` token. Returns `nil` for `none`/`unflag` (caller unflags instead).
    /// Throws-style validation is done by the caller via `acceptedTokens`.
    public static func fromToken(_ token: String) -> MailFlagColor? {
        switch token.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "gray", "grey": return .gray
        default: return nil // includes "none"
        }
    }

    /// Read-path helper: given the DB `flagged` bit + `flag_color` int, produce the color
    /// name (nil when the message is not flagged, since `flag_color` is meaningless then).
    public static func readName(flagged: Bool, flagColor: Int?) -> String? {
        guard flagged, let raw = flagColor, let c = MailFlagColor(rawValue: raw) else { return nil }
        return c.name
    }
}
