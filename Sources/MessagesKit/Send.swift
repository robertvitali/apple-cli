import Foundation
import AppleKit

/// The send path — the one WRITE capability. Ports `mac_messages_mcp.send_message`
/// (recipient resolution: phone | email | contact-name fuzzy | group chat id) and
/// `_send_message_direct` (iMessage-first with automatic SMS/RCS fallback).
///
/// SECURITY: recipient + body are passed to osascript as `on run argv` arguments,
/// NEVER interpolated into the script source (the MCP interpolates-with-escaping;
/// argv is the injection-proof port per AppleKit's AppleScriptRunner contract).
/// The MCP's stateful `"contact:N"` selector is replaced by stateless ranked
/// candidates + an explicit `--handle`.
public enum Send {

    /// Outcome of resolving a recipient string to a concrete send target.
    public enum Resolution {
        case resolved(handle: String, displayName: String?)
        case ambiguous([AddressBook.Match])
        case notFound(String)
    }

    /// Classify + resolve a recipient exactly as the MCP does (minus contact:N):
    /// group chat id (verbatim), phone (`[0-9 +\-()]`), email (`@`), else fuzzy name.
    public static func resolve(recipient raw: String, groupChat: Bool, book: AddressBook) -> Resolution {
        let recipient = raw.trimmingCharacters(in: .whitespaces)
        if groupChat { return .resolved(handle: recipient, displayName: nil) }

        // Phone-shaped: only digits and + - ( ) space.
        if !recipient.isEmpty && recipient.allSatisfy({ $0.isNumber || "+- ()".contains($0) }) {
            return .resolved(handle: Fuzzy.normalizePhone(recipient), displayName: nil)
        }
        if recipient.contains("@") { return .resolved(handle: recipient, displayName: nil) }

        let matches = book.findByName(recipient)
        if matches.isEmpty { return .notFound(recipient) }
        if matches.count == 1 { return .resolved(handle: matches[0].phone, displayName: matches[0].name) }
        return .ambiguous(matches)
    }

    // MARK: - Fail-closed allowlist check (normalized on BOTH sides)

    public enum AllowError: Error, CustomStringConvertible {
        case notTestMode
        case notAllowed(String)
        public var description: String {
            switch self {
            case .notTestMode: return "APPLE_TEST_MODE is not set — refusing a live write"
            case .notAllowed(let h): return "recipient '\(h)' is not in the test allowlist (APPLE_TEST_RECIPIENTS)"
            }
        }
    }

    /// Fail-closed allowlist gate that normalizes BOTH the resolved handle AND the
    /// operator's `APPLE_TEST_RECIPIENTS` entries before comparing — so a `+1 555…`
    /// allowlist entry matches a digits-normalized handle. The shared
    /// `TestMode.requireAllowedRecipient` does an EXACT string compare, which is a
    /// footgun given `resolve()` digit-normalizes phones. Still fail-closed: requires
    /// `APPLE_TEST_MODE=1` AND a normalized match (a group id / unknown handle → refused).
    public static func assertAllowedRecipient(_ handle: String) throws {
        guard TestMode.isEnabled else { throw AllowError.notTestMode }
        let target = normalizeForAllowlist(handle)
        let allowed = TestMode.allowedRecipients.map(normalizeForAllowlist)
        guard allowed.contains(where: { phonesEquivalent($0, target) }) else {
            throw AllowError.notAllowed(handle)
        }
    }

    /// Emails → trimmed/lowercased; everything else (phones) → digits only.
    static func normalizeForAllowlist(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.contains("@") ? t.lowercased() : Fuzzy.normalizePhone(t)
    }

    /// Equal, or (for all-digit phone forms) equal after dropping a leading US "1".
    static func phonesEquivalent(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard !a.isEmpty, !b.isEmpty, a.allSatisfy(\.isNumber), b.allSatisfy(\.isNumber) else { return false }
        func stripCC(_ x: String) -> String { (x.count == 11 && x.hasPrefix("1")) ? String(x.dropFirst()) : x }
        return stripCC(a) == stripCC(b)
    }

    // MARK: - AppleScript builders (pure — argv-driven, unit-testable)

    /// Individual send with iMessage→SMS fallback. Reads recipient/body from argv.
    public static func directScript() -> String {
        """
        on run argv
            set targetRecipient to item 1 of argv
            set messageText to item 2 of argv
            tell application "Messages"
                try
                    set targetService to 1st service whose service type = iMessage
                    try
                        set targetBuddy to participant targetRecipient of targetService
                        send messageText to targetBuddy
                        return "success:iMessage"
                    on error iMessageErr
                        try
                            if targetRecipient contains "0" or targetRecipient contains "1" or targetRecipient contains "2" or targetRecipient contains "3" or targetRecipient contains "4" or targetRecipient contains "5" or targetRecipient contains "6" or targetRecipient contains "7" or targetRecipient contains "8" or targetRecipient contains "9" then
                                set smsService to first account whose service type = SMS and enabled is true
                                send messageText to participant targetRecipient of smsService
                                return "success:SMS"
                            else
                                return "error:iMessage failed and SMS not available for email addresses - " & iMessageErr
                            end if
                        on error smsErr
                            return "error:Both iMessage and SMS failed - iMessage: " & iMessageErr & " SMS: " & smsErr
                        end try
                    end try
                on error generalErr
                    return "error:" & generalErr
                end try
            end tell
        end run
        """
    }

    /// Group-chat send by chat id (`chat id "…"`, not display-name lookup).
    public static func groupScript() -> String {
        """
        on run argv
            set chatId to item 1 of argv
            set messageText to item 2 of argv
            tell application "Messages"
                try
                    set targetChat to chat id chatId
                    send messageText to targetChat
                    return "success"
                on error errMsg
                    return "error:" & errMsg
                end try
            end tell
        end run
        """
    }

    /// Interpret an osascript result line into (ok, serviceUsed, errorText).
    public static func interpret(_ result: String) -> (ok: Bool, service: String?, error: String?) {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "success:iMessage" { return (true, "iMessage", nil) }
        if trimmed == "success:SMS" { return (true, "SMS", nil) }
        if trimmed == "success" { return (true, nil, nil) }
        if trimmed.hasPrefix("error:") { return (false, nil, String(trimmed.dropFirst(6))) }
        return (false, nil, "Unknown result: \(trimmed)")
    }

    /// Perform the actual send (only reached on `--execute` after the TestMode guard).
    public static func perform(handle: String, message: String, groupChat: Bool) throws -> (ok: Bool, service: String?, error: String?) {
        let script = groupChat ? groupScript() : directScript()
        let out = try AppleScriptRunner().run(script, arguments: [handle, message])
        return interpret(out)
    }
}
