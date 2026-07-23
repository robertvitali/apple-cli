import Foundation

/// Mail flag colors — reconciles MCP A's 8-token palette (`none/orange/red/yellow/blue/
/// green/purple/gray`) with MCP B's binary flag/unflag into one model.
///
/// The Envelope Index `flag_color` integer and AppleScript's `set flag index` use macOS
/// Mail's ACTUAL (non-obvious) index order: orange=0, red=1, yellow=2, blue=3, green=4,
/// purple=5, gray=6 — NOT the intuitive rainbow order (the naive red=0 guess is wrong, and
/// red↔orange / green↔blue are the two swaps people miss). This matches the MCP parity
/// oracle's `get_flag_index` (apple-mail-mcp `utils.py`), the source of truth for the port:
/// a drop-in replacement MUST set the SAME index the oracle would for a given color name.
/// `none` maps to "unflag" (no color). Both the write path (`flag --color <name>` and rule
/// `flag_color` → `set flag index`) and the read path (`flag_color` int → name) share this
/// one table, so the two directions stay consistent with the oracle.
public enum MailFlagColor: Int, CaseIterable, Sendable {
    case orange = 0, red = 1, yellow = 2, blue = 3, green = 4, purple = 5, gray = 6

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
