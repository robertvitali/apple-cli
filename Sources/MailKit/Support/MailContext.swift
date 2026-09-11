import Foundation
import AppleKit

/// Per-invocation glue: opens the Envelope Index once and lazily resolves the account
/// directory (so pure-UUID paths don't pay for a Mail.app round-trip). Read commands build a
/// `MailContext`, run their query, and decode rows through it so mailbox-path + account-name
/// enrichment is uniform.
public final class MailContext {
    public let index: EnvelopeIndex
    private var _accounts: AccountDirectory?

    public init(explicitPath: String? = nil, accountDirectory: AccountDirectory? = nil) throws {
        index = try EnvelopeIndex(explicitPath: explicitPath)
        _accounts = accountDirectory
    }

    /// Lazy account directory (loads account names/UUIDs from Mail.app on first use).
    public func accounts() -> AccountDirectory {
        if let a = _accounts { return a }
        let a = AccountDirectory()
        _accounts = a
        return a
    }

    public func checkedAccounts() throws -> AccountDirectory {
        let directory = accounts()
        try directory.checkOutputLimitFailure()
        return directory
    }

    /// Resolve an account selector (name or UUID) to a UUID, or throw a clear validation
    /// error listing what's available.
    public func requireAccountUUID(_ selector: String) throws -> String {
        let directory = try checkedAccounts()
        if let uuid = directory.resolveUUID(selector) { return uuid }
        // Fall back to matching a UUID that actually appears in the mailbox store.
        if index.accountUUIDs().contains(selector) { return selector }
        throw MailContext.accountResolutionError(selector: selector,
                                                 directoryLoadError: directory.loadError,
                                                 knownNames: directory.accounts.map(\.name))
    }

    /// extra31 pure core (pinned): which error a FAILED account resolution reports. When the
    /// name→UUID directory itself failed to load (Mail stalled on the AppleScript, automation
    /// denied, timeout), "unknown account" is a lie — the account may exist and the CLI just
    /// couldn't ask; report upstream_error (exit 69) with the failure CLASS and the headless
    /// escape hatch. The interpolated error is `AppleScriptRunner.RunError`, whose description
    /// deliberately suppresses osascript stderr (info-leak posture) — so the message
    /// distinguishes launch-failed vs exited-N, NOT stall vs automation-denied. A directory
    /// that loaded FINE and simply has no such account keeps the honest not_found.
    static func accountResolutionError(selector: String, directoryLoadError: Error?,
                                       knownNames: [String]) -> AppleError {
        if let err = directoryLoadError {
            return AppleError.upstream("cannot resolve account '\(selector)': the Mail account directory could not be read (\(err)). Mail may be stalled or automation denied — retry, or pass the account UUID directly (it resolves from the index without Mail).")
        }
        let hint = knownNames.isEmpty ? "" : " Known accounts: \(knownNames.joined(separator: ", "))."
        return AppleError.notFound("unknown account '\(selector)'.\(hint)")
    }

    /// (mailbox path, account label) for a message's mailbox ROWID.
    public func labels(forMailboxRowid rowid: Int) -> (path: String, account: String) {
        guard let mb = index.mailbox(forRowid: rowid) else { return ("", "") }
        let acctLabel = accounts().name(forUUID: mb.url.accountID)
        return (mb.url.path, acctLabel)
    }

    /// Decode a message summary row with mailbox/account enrichment.
    public func decodeSummary(_ row: [String: String?]) -> MailMessage {
        let mbRowid = intVal(row["mailbox_rowid"]) ?? 0
        let (path, account) = labels(forMailboxRowid: mbRowid)
        return MailDecode.message(row: row, mailboxPath: path, accountLabel: account)
    }

    public func checkedLabels(forMailboxRowid rowid: Int) throws -> (path: String, account: String) {
        guard let mb = index.mailbox(forRowid: rowid) else { return ("", "") }
        return (mb.url.path, try checkedAccounts().name(forUUID: mb.url.accountID))
    }

    public func checkedDecodeSummary(_ row: [String: String?]) throws -> MailMessage {
        let mbRowid = intVal(row["mailbox_rowid"]) ?? 0
        let (path, account) = try checkedLabels(forMailboxRowid: mbRowid)
        return MailDecode.message(row: row, mailboxPath: path, accountLabel: account)
    }
}
