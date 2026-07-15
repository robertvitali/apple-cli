import Foundation
import AppleKit

/// Per-invocation glue: opens the Envelope Index once and lazily resolves the account
/// directory (so pure-UUID paths don't pay for a Mail.app round-trip). Read commands build a
/// `MailContext`, run their query, and decode rows through it so mailbox-path + account-name
/// enrichment is uniform.
public final class MailContext {
    public let index: EnvelopeIndex
    private var _accounts: AccountDirectory?

    public init(explicitPath: String? = nil) throws {
        index = try EnvelopeIndex(explicitPath: explicitPath)
    }

    /// Lazy account directory (loads account names/UUIDs from Mail.app on first use).
    public func accounts() -> AccountDirectory {
        if let a = _accounts { return a }
        let a = AccountDirectory()
        _accounts = a
        return a
    }

    /// Resolve an account selector (name or UUID) to a UUID, or throw a clear validation
    /// error listing what's available.
    public func requireAccountUUID(_ selector: String) throws -> String {
        if let uuid = accounts().resolveUUID(selector) { return uuid }
        // Fall back to matching a UUID that actually appears in the mailbox store.
        if index.accountUUIDs().contains(selector) { return selector }
        let names = accounts().accounts.map(\.name)
        let hint = names.isEmpty ? "" : " Known accounts: \(names.joined(separator: ", "))."
        throw AppleError.notFound("unknown account '\(selector)'.\(hint)")
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
}
