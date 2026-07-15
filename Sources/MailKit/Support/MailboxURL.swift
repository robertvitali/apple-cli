import Foundation

/// Parses an Envelope Index `mailboxes.url` into its account UUID + human path.
///
/// Form shapes observed on live stores (example paths are illustrative):
///   `imap://<ACCOUNT-UUID>/INBOX`
///   `imap://<ACCOUNT-UUID>/%5BGmail%5D/All%20Mail`   (percent-encoded, `/`-nested)
///   `local://<UUID>/Recovered%20Messages%20(On%20My%20Mac)`
///
/// The account is the URL host (a stable UUID matching `list_accounts[].id`); the path is
/// the percent-decoded mailbox path (`Vendor/Receipts` for a nested folder). Parsing is manual
/// (not `URLComponents`) because Mail's URLs contain characters URLComponents rejects.
public struct MailboxURL: Sendable, Equatable {
    public let scheme: String
    public let accountID: String   // UUID (host)
    public let path: String        // decoded, e.g. "Vendor/Receipts" or "INBOX"
    public let raw: String

    /// Leaf mailbox name (last path component), e.g. "Receipts" for "Vendor/Receipts".
    public var leaf: String { path.split(separator: "/").last.map(String.init) ?? path }

    public init?(_ url: String) {
        raw = url
        guard let range = url.range(of: "://") else { return nil }
        scheme = String(url[url.startIndex..<range.lowerBound])
        let rest = String(url[range.upperBound...])
        guard let slash = rest.firstIndex(of: "/") else {
            // Host with no path (rare — an account root); treat path as empty.
            accountID = rest
            path = ""
            return
        }
        accountID = String(rest[rest.startIndex..<slash])
        let rawPath = String(rest[rest.index(after: slash)...])
        path = rawPath.removingPercentEncoding ?? rawPath
    }
}
