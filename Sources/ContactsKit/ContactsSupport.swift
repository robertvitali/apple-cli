import Foundation
import AppleKit

// Pure, TCC-free helpers ported 1:1 from apple-contacts-mcp @ 1cd8789 (v0.3.0):
// utils.py (label translation, image-format sniffing, AppleScript escaping) and
// security.py (test-mode safety gate). Kept free of Contacts.framework so they are
// unit-testable in CI without a Contacts TCC grant.

// MARK: - AppleScript string escaping (utils.escape_applescript_string)

/// Escape `s` for safe interpolation inside an AppleScript `"..."` literal.
/// Backslash-first ordering matters — escaping `"` before `\` would double-escape
/// the inserted backslashes. Mirrors the MCP's `escape_applescript_string`.
///
/// NOTE: the shipping AppleScript paths (readNote / writeNote / removeContactFromGroup in
/// ContactsStore) bind CN identifiers + note text via osascript ARGV (`on run argv`) and do
/// NOT call this — argv binding is strictly safer (no interpolation at all). This is a
/// ported-for-parity utility (the MCP interpolates an escaped id) kept for tests/reference;
/// it is not on the shipping path.
public func escapeAppleScriptString(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

/// True when osascript stderr indicates the referenced person/group doesn't exist.
/// Mirrors the MCP's `_APPLESCRIPT_NOT_FOUND_PATTERN` (`Can(?:'|’)t get|Invalid index`,
/// case-insensitive) — the curly apostrophe is what AppleScript actually emits.
public func isAppleScriptNotFound(_ stderr: String) -> Bool {
    let s = stderr.lowercased()
    return s.contains("invalid index") || s.contains("can't get") || s.contains("can’t get")
}

// MARK: - Label translation (utils.label_to_apple_token)

/// Apple's built-in label tokens, keyed by the lowercase human form that
/// `CNLabeledValue.localizedString(forLabel:)` returns in en_US. Verbatim from the
/// MCP's `_HUMAN_LABEL_TO_APPLE_TOKEN` (probed against macOS 26.3.1, MCP issue #22).
let humanLabelToAppleToken: [String: String] = [
    "mobile": "_$!<Mobile>!$_",
    "work": "_$!<Work>!$_",
    "home": "_$!<Home>!$_",
    "other": "_$!<Other>!$_",
    "iphone": "_$!<iPhone>!$_",
    "main": "_$!<Main>!$_",
    "home fax": "_$!<HomeFAX>!$_",
    "work fax": "_$!<WorkFAX>!$_",
    "other fax": "_$!<OtherFAX>!$_",
    "pager": "_$!<Pager>!$_",
    "school": "_$!<School>!$_",
    "homepage": "_$!<HomePage>!$_",
]

/// Translate a label input to the form Contacts.framework expects. Three cases,
/// mirroring the MCP's `label_to_apple_token`:
/// - Human form (case-insensitive, whitespace-trimmed): `"mobile"` → `_$!<Mobile>!$_`.
/// - Apple token (`_$!<Mobile>!$_`): passed through unchanged.
/// - Custom string (`"Spotify"`): passed through unchanged (stored as a custom label).
/// The empty string returns `""` (no label).
public func labelToAppleToken(_ label: String) -> String {
    if label.isEmpty { return label }
    let key = label.trimmingCharacters(in: .whitespaces).lowercased()
    return humanLabelToAppleToken[key] ?? label
}

// MARK: - Image-format detection (utils.detect_image_format)

/// HEIF-family ISOBMFF `ftyp` brands Apple emits — all reported as "heic".
private let heicFtypBrands: Set<[UInt8]> = [
    Array("heic".utf8), Array("heix".utf8), Array("heif".utf8), Array("hevc".utf8),
    Array("hevx".utf8), Array("mif1".utf8), Array("msf1".utf8),
]

/// Identify an image format from its leading magic bytes. Returns one of
/// `"jpeg"`, `"png"`, `"gif"`, `"heic"`, or `"unknown"`. Pure; robust against
/// short/empty input (never traps). Mirrors the MCP's `detect_image_format`.
public func detectImageFormat(_ data: [UInt8]) -> String {
    if data.count >= 3, Array(data[0..<3]) == [0xFF, 0xD8, 0xFF] { return "jpeg" }
    if data.count >= 8, Array(data[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return "png" }
    if data.count >= 4, Array(data[0..<4]) == Array("GIF8".utf8) { return "gif" }
    if data.count >= 12, Array(data[4..<8]) == Array("ftyp".utf8), heicFtypBrands.contains(Array(data[8..<12])) {
        return "heic"
    }
    return "unknown"
}

public func detectImageFormat(_ data: Data) -> String { detectImageFormat([UInt8](data)) }

// MARK: - Contact label selection (test-data sandbox prefix) — single source of truth

/// The name a contact/group is labeled by for the test-data gate. The create-side label
/// check AND the fetched-target write guard both route through this, so the two can never
/// drift. Pure + CI-testable (no Contacts.framework, no TCC) — see ContactsKitTests.
public enum ContactsLabel {
    /// First non-empty (trimmed) of given → family → organization — how a contact is labeled.
    public static func primaryName(given: String?, family: String?, organization: String?) -> String {
        for v in [given, family, organization] {
            if let v, !v.trimmingCharacters(in: .whitespaces).isEmpty { return v }
        }
        return ""
    }

    /// A name is a labeled test item iff it carries the sandbox prefix (strict prefix, not
    /// substring). `prefix` comes from `TestMode.sandboxPrefix`, which normalizes empty/
    /// whitespace to "apple-cli-test" so the gate can't be vacated via `hasPrefix("")`.
    public static func isLabeled(_ name: String, prefix: String) -> Bool {
        name.hasPrefix(prefix)
    }
}

// MARK: - Domain errors + error-type parity

/// `error.type` strings the MCP emits. AppleKit's `AppleErrorType` covers most;
/// `safety_violation` is contacts-specific (the MCP's test-mode refusal signal),
/// preserved verbatim so an agent matching on `error.type` sees the same value.
public enum ContactsErrorType {
    public static let safetyViolation = "safety_violation"
}

extension AppleError {
    /// A test-mode / write-guard refusal. Preserves the MCP's `safety_violation`
    /// `error.type`. Mapped to exit 77 (EX_NOPERM) — a policy-based refusal, the
    /// closest contractual code; the exit code is additive (the MCP has none).
    public static func safetyViolation(_ m: String) -> AppleError {
        .init(type: ContactsErrorType.safetyViolation, message: m, exitCode: AppleExit.permissionDenied)
    }
}
