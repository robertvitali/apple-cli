import Foundation

/// Live tests + MCP-parity comparisons write to the REAL Apple stores (there is no
/// separate sandbox), under a track-and-cleanup discipline: create only clearly-labeled
/// test items (name-prefixed `sandboxPrefix`), log each to TEST-CLEANUP.md, and delete
/// only those tracked items via the MCP afterward. This type provides the FAIL-CLOSED
/// guard that turns that discipline into enforcement — call it before any live write.
public enum TestMode {
    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["APPLE_TEST_MODE"] == "1"
    }

    /// Prefix every test item's name carries so it's recognizable + cleanable.
    public static var sandboxPrefix: String {
        normalizedPrefix(from: ProcessInfo.processInfo.environment["APPLE_TEST_SANDBOX"])
    }

    /// Pure normalization (unit-testable without mutating process env): an empty or
    /// whitespace-only `APPLE_TEST_SANDBOX` is treated as ABSENT and falls back to the
    /// default prefix — otherwise the override would vacate the label gate
    /// (`name.hasPrefix("")` is always true), letting ANY name pass `requireLabeledTarget`.
    static func normalizedPrefix(from raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "apple-cli-test" : trimmed
    }

    /// Allowlisted recipients for Messages/Mail test SENDS (operator self only). Comma-sep
    /// in `APPLE_TEST_RECIPIENTS`. A send to anything not on this list is a dangerous action.
    public static var allowedRecipients: [String] {
        (ProcessInfo.processInfo.environment["APPLE_TEST_RECIPIENTS"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public enum SandboxError: Error, CustomStringConvertible {
        case notTestMode
        case notLabeled(String)
        case recipientNotAllowed(String)
        public var description: String {
            switch self {
            case .notTestMode: return "APPLE_TEST_MODE is not set — refusing a live write"
            case .notLabeled(let n): return "target '\(n)' is not a labeled test item (must start with the test prefix)"
            case .recipientNotAllowed(let r): return "recipient '\(r)' is not in the test allowlist"
            }
        }
    }

    /// Fail-closed: refuse a create/mutate unless test mode is on AND the target name is a
    /// labeled test item. Throw `AppleError.validation(...)` in callers if this throws.
    public static func requireLabeledTarget(_ name: String) throws {
        guard isEnabled else { throw SandboxError.notTestMode }
        guard name.hasPrefix(sandboxPrefix) else { throw SandboxError.notLabeled(name) }
    }

    /// Fail-closed: refuse a send to any recipient not on the operator's test allowlist.
    public static func requireAllowedRecipient(_ recipient: String) throws {
        guard isEnabled else { throw SandboxError.notTestMode }
        guard allowedRecipients.contains(recipient) else { throw SandboxError.recipientNotAllowed(recipient) }
    }
}
