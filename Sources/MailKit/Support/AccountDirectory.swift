import Foundation
import AppleKit

/// Resolves Apple Mail account identity: name ↔ UUID ↔ email addresses ↔ type ↔ enabled.
///
/// The Envelope Index only stores account UUIDs (in mailbox URLs); the human name / email
/// addresses / type / enabled live in Mail.app, reachable via AppleScript. This directory
/// fetches them once (lazily, cached) so SQLite reads can be labeled with account names and
/// user-supplied account NAMES can be mapped to UUIDs for filtering.
///
/// Best-effort + fail-soft: if Mail automation is unavailable, callers fall back to the raw
/// UUID as the account label (reads still work headless from SQLite alone).
public final class AccountDirectory {
    public private(set) var accounts: [MailAccount] = []
    private var nameByUUID: [String: String] = [:]
    private var uuidByLowerName: [String: String] = [:]
    private let loaded: Bool
    /// Why the AppleScript fetch failed, when it did (extra31). The `try?` this replaces
    /// conflated "Mail unavailable — fall back to UUID labels" (fine for reads) with a stalled
    /// or automation-denied Mail.app; callers that REQUIRE name→UUID resolution use this to
    /// report the real upstream cause instead of a misleading "unknown account" not_found.
    public private(set) var loadError: Error?

    public init(runner: any AppleScriptRunning = AppleScriptRunner()) {
        do {
            let fetched = try AccountDirectory.fetch(runner: runner)
            accounts = fetched
            for a in fetched {
                nameByUUID[a.id] = a.name
                uuidByLowerName[a.name.lowercased()] = a.id
            }
            loaded = true
        } catch {
            loadError = error
            loaded = false
        }
    }

    public var isLoaded: Bool { loaded }

    /// Keep ordinary headless fallbacks, but never consume a cached output-policy failure.
    public func checkOutputLimitFailure() throws {
        if let error = loadError, AppleScriptRunner.isOutputLimitError(error) { throw error }
    }

    /// Human name for a UUID, or the UUID itself when Mail is unavailable.
    public func name(forUUID uuid: String) -> String { nameByUUID[uuid] ?? uuid }

    /// Map an account selector (a display name OR a UUID) to a UUID. Returns nil for anything
    /// the directory doesn't recognize — the caller (MailContext.requireAccountUUID) validates
    /// an unrecognized-but-real UUID against the mailbox store instead of blindly passing
    /// UUID-shaped strings through (which silently returned empty results for typos).
    public func resolveUUID(_ selector: String) -> String? {
        if nameByUUID[selector] != nil { return selector }              // already a known UUID
        if let uuid = uuidByLowerName[selector.lowercased()] { return uuid }
        return nil
    }

    /// Display name for a selector that is either a UUID or a name. Returns nil if unknown to
    /// the directory (Mail unavailable / typo). Used to feed AppleScript, which matches by name.
    public func displayName(for selector: String) -> String? {
        if let name = nameByUUID[selector] { return name }             // selector is a known UUID
        if uuidByLowerName[selector.lowercased()] != nil { return selector } // selector is a known name
        return nil
    }

    /// Primary send (From) email address for an account selector (name or UUID), or nil if the
    /// selector is unknown to the directory (Mail unavailable / typo) or the account has no
    /// address on file. Callers set this as the outgoing message `sender` / the `.eml` `From:`
    /// so `--account` selects the sending identity — matching the reference MCPs, which set the
    /// sender to the account's first email address. A BARE address (never "Name <addr>") so it
    /// matches a configured account for Mail's account selection.
    public func sendAddress(for selector: String) -> String? {
        guard let uuid = resolveUUID(selector) else { return nil }
        return accounts.first(where: { $0.id == uuid })?.email_addresses.first
    }

    // MARK: AppleScript fetch

    private static let listScript = """
    set RS to (ASCII character 30)
    set US to (ASCII character 31)
    tell application "Mail"
        set out to ""
        repeat with a in accounts
            set em to ""
            try
                -- `email addresses` is an `emad` list; per-element `as text` throws -1700,
                -- and a bare list→text coercion uses empty delimiters (concatenates). Set a
                -- comma delimiter so Swift can split cleanly.
                set AppleScript's text item delimiters to ","
                set em to ((email addresses of a) as text)
                set AppleScript's text item delimiters to ""
            end try
            set aType to ""
            try
                set aType to (account type of a) as text
            end try
            set out to out & (id of a) & US & (name of a) & US & aType & US & (enabled of a) & US & em & RS
        end repeat
        return out
    end tell
    """

    static func fetch(runner: any AppleScriptRunning) throws -> [MailAccount] {
        let raw = try runner.run(listScript)
        let rs = String(UnicodeScalar(30)!), us = String(UnicodeScalar(31)!)
        var result: [MailAccount] = []
        for record in raw.components(separatedBy: rs) where !record.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fields = record.components(separatedBy: us)
            guard fields.count >= 5 else { continue }
            let emails = fields[4].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            result.append(MailAccount(
                id: fields[0].trimmingCharacters(in: .whitespacesAndNewlines),
                name: fields[1].trimmingCharacters(in: .whitespacesAndNewlines),
                email_addresses: emails,
                account_type: normalizeType(fields[2]),
                enabled: fields[3].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"))
        }
        return result
    }

    static func normalizeType(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.contains("icloud") { return "iCloud" }
        if t.contains("imap") { return "imap" }
        if t.contains("pop") { return "pop" }
        if t.contains("exchange") || t.contains("ews") { return "exchange" }
        return t.isEmpty ? "unknown" : t
    }
}
