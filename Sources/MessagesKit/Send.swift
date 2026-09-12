import Foundation
import AppleKit

/// The send path — the one WRITE capability. Ports `mac_messages_mcp.send_message`
/// (recipient resolution: phone | email | contact-name fuzzy | group chat id) and
/// `_send_message_direct` (iMessage-first with automatic SMS/RCS fallback).
///
/// Two CLI extras ride on the same path (port-spec §5, both listed there as
/// WORTH-INCLUDING): explicit service control (`--service auto|imessage|sms`,
/// where `auto` IS the ported behaviour, nesting included) and file attachments
/// (`--file`, repeatable; the MCP is text-only, so nothing it could do is dropped).
/// Attachment paths are vetted by the SHARED `AppleKit.AttachmentSource.resolve` —
/// the same guard Mail's `--attach` uses — so the two outbound surfaces cannot drift
/// into two containment policies.
///
/// SECURITY: recipient, body AND every attachment path are passed to osascript as
/// `on run argv` arguments, NEVER interpolated into the script source (the MCP
/// interpolates-with-escaping; argv is the injection-proof port per AppleKit's
/// AppleScriptRunner contract). Only the SHAPE of a send — does it carry a body,
/// which service — varies the emitted source, and that shape comes from the CLI's
/// own flags, never from operator text.
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
        case notAllowed(String)
        case groupChatInSandbox
        public var description: String {
            switch self {
            case .notAllowed(let h):
                return "Sandbox is engaged: recipient '\(h)' is not in the test allowlist "
                    + "(APPLE_TEST_RECIPIENTS)"
            case .groupChatInSandbox:
                return "Sandbox is engaged: group-chat send is unavailable — a group has no "
                    + "self-addressed shape, so every other participant would receive the message"
            }
        }
    }

    /// SANDBOX-ONLY recipient allowlist. Normalizes BOTH the resolved handle AND the operator's
    /// `APPLE_TEST_RECIPIENTS` entries before comparing, so a `+1 555…` allowlist entry matches a
    /// digits-normalized handle. (A naive exact-string allowlist compare would be a footgun
    /// here, given `resolve()` digit-normalizes phones.)
    ///
    /// WRITE-MODEL v2: outside the sandbox this is a NO-OP, because
    /// `mac_messages_mcp`'s `tool_send_message` sends to any recipient on call — it goes straight
    /// to `send_message(recipient, message, group_chat)` (server.py:58-77) with no gate, no
    /// confirmation and no environment check; the only `os.environ` read in the whole non-test
    /// source is `USE_TEST_DATA` (messages.py:375), a fixture switch, not a write gate. So the
    /// allowlist is a CLI-only restriction (bucket 3).
    ///
    /// The `APPLE_TEST_MODE` check that used to live HERE is gone deliberately: under v2 the
    /// sandbox is a single signal (`APPLE_TEST_MODE` truthy OR `--test-mode`) resolved ONCE by
    /// `MessagesWriteGuard.resolve`, and re-reading the env inside a guard would mean
    /// `--test-mode` alone engaged the sandbox without engaging this allowlist — the one
    /// restriction that matters most on a send surface.
    ///
    /// Still fail-closed inside the sandbox: an EMPTY or unset `APPLE_TEST_RECIPIENTS` matches
    /// nothing, so every recipient is refused rather than every recipient being allowed.
    ///
    /// GROUP CHATS ARE REFUSED OUTRIGHT, not left to the allowlist compare. AGENTS.md makes
    /// group-chat send operator-verify-only precisely because a group has no self-addressed
    /// shape — the operator cannot be the only recipient. Relying on "a chat id never matches a
    /// phone/email entry" was WRONG: `resolve` preserves a group id verbatim (see above),
    /// `normalizeForAllowlist` strips it to digits, and `phonesEquivalent` returns true for two
    /// equal strings BEFORE it checks they are digits — so an operator who pasted a chat id into
    /// `APPLE_TEST_RECIPIENTS` would have had a sandboxed group send go through to real people.
    /// The refusal is now structural, so no allowlist content can reach that path.
    ///
    /// `allowedRecipients` is a REQUIRED seam, not a policy knob. It used to default to `nil`
    /// (read `APPLE_TEST_RECIPIENTS` here); that default went dead once `MessagesWriteGuard.Gate`
    /// captured the list, and leaving it in place left two sources of truth on the one surface
    /// that reaches a real human — a future caller omitting the argument would silently get
    /// different semantics with no compile error. Making it required also keeps the logic tier
    /// off the process-wide variable that swift-testing's parallel suites share.
    public static func assertAllowedRecipient(_ handle: String, groupChat: Bool, sandboxActive: Bool,
                                              allowedRecipients: [String]) throws {
        guard sandboxActive else { return }
        guard !groupChat else { throw AllowError.groupChatInSandbox }
        let target = normalizeForAllowlist(handle)
        let allowed = allowedRecipients.map(normalizeForAllowlist)
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

    // MARK: - Service selection

    /// Which Messages service a 1:1 send is allowed to use.
    ///
    /// `auto` is the ported `mac_messages_mcp` behaviour and stays the default: iMessage first,
    /// with the automatic SMS fallback for phone-shaped recipients. `imessage` and `sms` are the
    /// CLI's own explicit override (port-spec §5 "Explicit service control" — the MCP's routing
    /// is implicit and uncontrollable), so neither narrows the parity floor: `auto` still reaches
    /// exactly what the oracle reached.
    ///
    /// A RAW-VALUE enum rather than three branches: the flag's accepted values, the validation
    /// message, and the `service_requested` wire value all derive from `allCases`, so a fourth
    /// service is a case here and nothing else.
    public enum Service: String, CaseIterable, Sendable, Equatable {
        case auto
        case imessage
        case sms

        /// The `service_plan` wire value — what the preview promises the execute path will do.
        public var plan: String {
            switch self {
            case .auto: return "iMessage→SMS auto"
            case .imessage: return "iMessage only"
            case .sms: return "SMS only"
            }
        }

        /// The accepted values, rendered for a validation message / help string.
        public static var allNames: String {
            allCases.map(\.rawValue).joined(separator: ", ")
        }
    }

    // MARK: - SMS reachability

    /// The digit characters the ported `_send_message_direct` fallback tests for. SINGLE SOURCE:
    /// the emitted AppleScript clause and the CLI's own `--service sms` pre-validation are both
    /// built from this, so the two can never disagree about what "phone-shaped" means. ASCII
    /// digits only, deliberately — `Character.isNumber` would also match e.g. Devanagari digits,
    /// which AppleScript's `contains "0"` does not.
    static let smsDigits: [Character] = (0...9).map { Character("\($0)") }

    /// Whether the SMS service could reach this handle at all. The oracle applies exactly this
    /// test before it lets `auto` fall back, and refuses an email address outright; `--service sms`
    /// reuses it as a PRE-validation so `--service sms jane.doe@example.com` is a named
    /// `validation_error` at exit 64 rather than an opaque `upstream_error` after Messages has
    /// been asked to do something knowably impossible.
    public static func smsReachable(_ handle: String) -> Bool {
        handle.contains(where: { smsDigits.contains($0) })
    }

    // MARK: - Attachment resolution
    //
    // There is none here, deliberately. An outbound attachment is vetted by the SHARED
    // `AppleKit.AttachmentSource.resolve` — the same guard Mail's `--attach` uses — so the two
    // outbound surfaces cannot drift into two containment policies. See its doc comment for the
    // refusal classes and why the credential blocklist is the containment under write-model v2.

    // MARK: - Request / outcome

    /// One fully-resolved send: the handle `resolve` produced, the optional body, the attachments
    /// (already absolute and validated by `resolveAttachment`), and which service was asked for.
    ///
    /// A struct rather than five positional parameters because this is also the injected
    /// `performSend` seam's argument — a five-tuple of `String, String?, [String], Bool, Service`
    /// is exactly the shape where a caller silently swaps two arguments of the same type on the
    /// one surface that reaches a real human.
    public struct Request: Equatable, Sendable {
        public let handle: String
        /// `nil` when the send carries no body at all (a file-only send). Distinct from `""`,
        /// which is an empty body the caller explicitly asked to send.
        public let message: String?
        /// Absolute, symlink-resolved paths (see `AppleKit.AttachmentSource`), sent in this
        /// order AFTER the body.
        public let files: [String]
        public let groupChat: Bool
        public let service: Service

        public init(handle: String, message: String?, files: [String],
                    groupChat: Bool, service: Service) {
            self.handle = handle
            self.message = message
            self.files = files
            self.groupChat = groupChat
            self.service = service
        }
    }

    /// What one osascript run reported back.
    public struct Outcome: Equatable, Sendable {
        public let ok: Bool
        /// The service that actually carried the send (`iMessage` / `SMS`), or nil for a group
        /// chat, whose service is the chat's own and is not reported by Messages.
        public let service: String?
        /// How many attachments were actually delivered. On a failure this is what a retry must
        /// EXCLUDE: a resend is a second message, not an update.
        public let filesSent: Int
        /// 1-based index into `Request.files` of the attachment that was in flight when the run
        /// failed; nil when the failure was not during a file send.
        public let failedFile: Int?
        /// Whether the MESSAGE BODY reached the recipient. `filesSent` does not count it, so
        /// without this a "body delivered, attachment 1 failed" run reported nothing delivered —
        /// and a caller following the retry advice re-sent the body to a real person, the exact
        /// duplicate the fallback latch exists to prevent. Meaningless (and `true`) on a success,
        /// where everything asked for was delivered.
        public let bodyDelivered: Bool
        public let error: String?

        public init(ok: Bool, service: String?, filesSent: Int, failedFile: Int?,
                    bodyDelivered: Bool, error: String?) {
            self.ok = ok
            self.service = service
            self.filesSent = filesSent
            self.failedFile = failedFile
            self.bodyDelivered = bodyDelivered
            self.error = error
        }
    }

    // MARK: - AppleScript builders (pure — argv-driven, unit-testable)

    /// The MCP's phone-shaped test, reproduced character-for-character (it is what decides whether
    /// the `auto` fallback may try SMS at all). Built from `smsDigits`, the same list
    /// `smsReachable` uses, so the script and the CLI pre-validation cannot drift.
    private static let recipientHasDigit = smsDigits
        .map { "targetRecipient contains \"\($0)\"" }
        .joined(separator: " or ")

    /// argv, and how the script reads it. Item 1 is the target; item 2 is the body WHEN there is
    /// one; every remaining item is an attachment path. Nothing operator-supplied is interpolated
    /// into the source — only the SHAPE of the send (does it have a body, which service) decides
    /// which lines are emitted, and that shape comes from the CLI's own flags.
    ///
    /// `POSIX file` is coerced OUT here, before the `tell application "Messages"` block: inside a
    /// tell, `POSIX file` can be resolved against the target application's terminology instead of
    /// AppleScript's own.
    ///
    /// THE THREE COUNTERS the result grammar carries out. `filesSent` is what was actually
    /// delivered, `currentFile` is the attachment in flight (0 when none is), and `bodyDelivered`
    /// is 1 once the message body has gone out. They are integers rather than booleans so the
    /// returned line stays a plain colon-delimited record.
    private static func preamble(target: String, includeMessage: Bool) -> [String] {
        var lines = ["on run argv", "\tset \(target) to item 1 of argv"]
        if includeMessage { lines.append("\tset messageText to item 2 of argv") }
        lines.append("\tset fileList to {}")
        lines.append("\trepeat with fileIndex from \(includeMessage ? 3 : 2) to (count of argv)")
        lines.append("\t\tset end of fileList to POSIX file (item fileIndex of argv)")
        lines.append("\tend repeat")
        lines.append("\tset filesSent to 0")
        lines.append("\tset currentFile to 0")
        lines.append("\tset bodyDelivered to 0")
        return lines
    }

    /// The ordered delivery against one already-resolved target: body first (when there is one),
    /// then each attachment in order.
    ///
    /// The counters are what make a partial failure describable. `filesSent` counts what actually
    /// went out; `currentFile` names the attachment in flight so a mid-batch failure can report
    /// WHICH file failed; `bodyDelivered` records that the body itself went out, which is the one
    /// fact a caller needs in order to retry WITHOUT duplicating it (the body is not counted by
    /// `filesSent`, so without this bit a "body delivered, attachment 1 failed" run reported
    /// nothing delivered at all).
    ///
    /// Together they also gate the `auto` SMS fallback: it may only re-run a batch of which
    /// NOTHING was delivered. Without that, an iMessage run that delivered the body and one file
    /// before failing would be replayed whole over SMS and the recipient would receive both twice.
    private static func deliveryBlock(target: String, includeMessage: Bool, indent: String) -> [String] {
        var lines = ["set currentFile to 0"]
        if includeMessage {
            lines.append("send messageText to \(target)")
            lines.append("set bodyDelivered to 1")
        }
        lines.append("repeat with fileIndex from 1 to (count of fileList)")
        lines.append("\tset currentFile to fileIndex")
        lines.append("\tsend (item fileIndex of fileList) to \(target)")
        lines.append("\tset filesSent to filesSent + 1")
        lines.append("end repeat")
        lines.append("set currentFile to 0")
        return lines.map { indent + $0 }
    }

    /// "Has anything at all actually reached the recipient?" — derived from the two counters
    /// rather than kept as a third latch that could disagree with them.
    private static let nothingDeliveredYet = "bodyDelivered is 0 and filesSent is 0"

    /// `error:<filesSent>:<currentFile>:<bodyDelivered>:<text>` — the failure half of the result
    /// grammar `interpret` parses. The three leading fields are integers, so the free-form error
    /// text can hold colons of its own without making the line ambiguous.
    private static func errorReturn(_ errorVariable: String, note: String = "") -> String {
        "return \"error:\" & filesSent & \":\" & currentFile & \":\" & bodyDelivered"
            + " & \":\(note)\" & \(errorVariable)"
    }

    /// Individual (1:1) send. `service` picks the routing; `includeMessage` says whether argv
    /// carries a body at all.
    ///
    /// `auto` keeps the MCP's `_send_message_direct` routing verbatim, INCLUDING ITS NESTING: the
    /// iMessage SERVICE lookup sits in an outer `try` whose handler returns an error and attempts
    /// no SMS, and only the participant lookup and the delivery sit in the inner `try` that falls
    /// back. That distinction is behavioural, not cosmetic — flattening the two makes a Mac signed
    /// out of iMessage send a real SMS where the oracle sent nothing. `imessage` and `sms` are
    /// single-service: a failure is a failure, which is the whole point of asking for one, so they
    /// need only one `try`.
    public static func directScript(service: Service, includeMessage: Bool) -> String {
        var lines = preamble(target: "targetRecipient", includeMessage: includeMessage)
        lines.append("\ttell application \"Messages\"")
        lines.append("\t\ttry")
        switch service {
        case .imessage:
            lines.append(contentsOf: resolveIMessageService(indent: "\t\t\t"))
            lines.append(contentsOf: resolveIMessageBuddy(indent: "\t\t\t"))
            lines.append(contentsOf: deliveryBlock(target: "targetBuddy",
                                                   includeMessage: includeMessage, indent: "\t\t\t"))
            lines.append("\t\t\treturn \"success:iMessage:\" & filesSent")
            lines.append("\t\ton error iMessageErr")
            lines.append("\t\t\t" + errorReturn("iMessageErr"))
        case .sms:
            lines.append(contentsOf: resolveSMSBuddy(indent: "\t\t\t"))
            lines.append(contentsOf: deliveryBlock(target: "smsBuddy",
                                                   includeMessage: includeMessage, indent: "\t\t\t"))
            lines.append("\t\t\treturn \"success:SMS:\" & filesSent")
            lines.append("\t\ton error smsErr")
            lines.append("\t\t\t" + errorReturn("smsErr"))
        case .auto:
            // OUTER try — the service lookup only. Its handler returns an error and attempts NO
            // SMS, exactly as the ported script did: "there is no iMessage service on this Mac"
            // is not a reason to reroute a message to a phone number over the carrier.
            lines.append(contentsOf: resolveIMessageService(indent: "\t\t\t"))
            // INNER try — participant lookup + delivery. Only failures from HERE reach the
            // fallback.
            lines.append("\t\t\ttry")
            lines.append(contentsOf: resolveIMessageBuddy(indent: "\t\t\t\t"))
            lines.append(contentsOf: deliveryBlock(target: "targetBuddy",
                                                   includeMessage: includeMessage, indent: "\t\t\t\t"))
            lines.append("\t\t\t\treturn \"success:iMessage:\" & filesSent")
            lines.append("\t\t\ton error iMessageErr")
            // Anything already delivered forecloses the fallback: replaying the batch over SMS
            // would deliver it a second time.
            lines.append("\t\t\t\tif not (\(nothingDeliveredYet)) then")
            lines.append("\t\t\t\t\t" + errorReturn("iMessageErr",
                note: "iMessage send failed after part of it was already delivered - "))
            lines.append("\t\t\t\tend if")
            // Nothing was delivered, so nothing is in flight. Reset BEFORE the SMS account
            // lookup: that lookup can fail on its own (no enabled SMS account), and its error
            // handler reads `currentFile` — which still names the attachment the iMessage half
            // died on. Without this the caller is told "send failed on attachment 1" for a run
            // that transferred nothing at all.
            lines.append("\t\t\t\tset currentFile to 0")
            lines.append("\t\t\t\ttry")
            lines.append("\t\t\t\t\tif \(recipientHasDigit) then")
            lines.append(contentsOf: resolveSMSBuddy(indent: "\t\t\t\t\t\t"))
            lines.append(contentsOf: deliveryBlock(target: "smsBuddy",
                                                   includeMessage: includeMessage, indent: "\t\t\t\t\t\t"))
            lines.append("\t\t\t\t\t\treturn \"success:SMS:\" & filesSent")
            lines.append("\t\t\t\t\telse")
            lines.append("\t\t\t\t\t\treturn \"error:0:0:0:iMessage failed and SMS not available for email addresses - \" & iMessageErr")
            lines.append("\t\t\t\t\tend if")
            lines.append("\t\t\t\ton error smsErr")
            lines.append("\t\t\t\t\treturn \"error:\" & filesSent & \":\" & currentFile & \":\" & bodyDelivered & \":Both iMessage and SMS failed - iMessage: \" & iMessageErr & \" SMS: \" & smsErr")
            lines.append("\t\t\t\tend try")
            lines.append("\t\t\tend try")
            lines.append("\t\ton error generalErr")
            lines.append("\t\t\t" + errorReturn("generalErr"))
        }
        lines.append("\t\tend try")
        lines.append("\tend tell")
        lines.append("end run")
        return lines.joined(separator: "\n")
    }

    private static func resolveIMessageService(indent: String) -> [String] {
        [indent + "set targetService to 1st service whose service type = iMessage"]
    }

    private static func resolveIMessageBuddy(indent: String) -> [String] {
        [indent + "set targetBuddy to participant targetRecipient of targetService"]
    }

    /// The SMS half addresses an ACCOUNT (`first account whose service type = SMS and enabled is
    /// true`), not a service — the spelling the ported `_send_message_direct` fallback used, kept
    /// so `--service sms` and the `auto` fallback resolve the same way.
    private static func resolveSMSBuddy(indent: String) -> [String] {
        ["set smsService to first account whose service type = SMS and enabled is true",
         "set smsBuddy to participant targetRecipient of smsService"].map { indent + $0 }
    }

    /// Group-chat send by chat id (`chat id "…"`, not display-name lookup). No service selection:
    /// a chat id already names the chat's own service, and Messages does not offer a choice.
    /// Attachments work here exactly as they do 1:1 — every participant in the chat receives each
    /// file — which is why the sandbox refuses group sends outright.
    public static func groupScript(includeMessage: Bool) -> String {
        var lines = preamble(target: "chatId", includeMessage: includeMessage)
        lines.append("\ttell application \"Messages\"")
        lines.append("\t\ttry")
        lines.append("\t\t\tset targetChat to chat id chatId")
        lines.append(contentsOf: deliveryBlock(target: "targetChat",
                                               includeMessage: includeMessage, indent: "\t\t\t"))
        // The service field is EMPTY, not a name: a group send never reported one before this
        // change either, and inventing "chat" here would retype `service_used` from null.
        lines.append("\t\t\treturn \"success::\" & filesSent")
        lines.append("\t\ton error errMsg")
        lines.append("\t\t\t" + errorReturn("errMsg"))
        lines.append("\t\tend try")
        lines.append("\tend tell")
        lines.append("end run")
        return lines.joined(separator: "\n")
    }

    /// Parse the one result line the scripts above return.
    ///
    /// Grammar, and nothing else is a success:
    ///   `success:<service>:<filesSent>`                             — service empty for a group
    ///   `error:<filesSent>:<failedFile>:<bodyDelivered>:<text>`     — 0 means "none"/"no"
    ///
    /// The leading fields are integers and are parsed as such, so an unrecognized line — including
    /// anything osascript itself printed instead of a return value — reads as a failure rather
    /// than as a silent success on a surface that reaches a real human.
    public static func interpret(_ result: String) -> Outcome {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", maxSplits: 4,
                                  omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3, parts[0] == "success", let sent = Int(parts[2]) {
            return Outcome(ok: true, service: parts[1].isEmpty ? nil : parts[1],
                           filesSent: sent, failedFile: nil, bodyDelivered: true, error: nil)
        }
        if parts.count == 5, parts[0] == "error", let sent = Int(parts[1]),
           let failed = Int(parts[2]), let body = Int(parts[3]) {
            return Outcome(ok: false, service: nil, filesSent: sent,
                           failedFile: failed == 0 ? nil : failed, bodyDelivered: body != 0,
                           error: parts[4])
        }
        return Outcome(ok: false, service: nil, filesSent: 0, failedFile: nil,
                       bodyDelivered: false, error: "Unknown result: \(trimmed)")
    }

    /// Perform the actual send (only reached on `--execute` after the write guard).
    ///
    /// ONE osascript run carries the body and every attachment. Splitting them across runs would
    /// mean a second Messages automation prompt mid-batch, and a partial batch whose already-sent
    /// half no single result line could describe.
    public static func perform(_ request: Request) throws -> Outcome {
        let script = request.groupChat
            ? groupScript(includeMessage: request.message != nil)
            : directScript(service: request.service, includeMessage: request.message != nil)
        var argv = [request.handle]
        if let message = request.message { argv.append(message) }
        argv.append(contentsOf: request.files)
        return interpret(try AppleScriptRunner().run(script, arguments: argv))
    }
}
