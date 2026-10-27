import CryptoKit
import Foundation

/// Compact identity-set commitment for the bounded worker protocol. This is not
/// authentication or evidence of file availability. Exact message binding and
/// complete snapshot validation remain the caller's responsibility.
struct MessagesAttachmentMembership: Equatable, Sendable {
    let count: Int
    let sha256: String

    init?(_ identities: [MessagesAttachmentRetrievalState.Identity]) {
        guard !identities.isEmpty,
              identities.count <= MessagesAttachmentRetrievalState.maximumAttachments,
              Set(identities.map(\.rowid)).count == identities.count,
              Set(identities.map(\.guid)).count == identities.count else { return nil }
        var hash = SHA256()
        hash.update(data: Data("apple-cli-attachment-membership-v1\0".utf8))
        func appendInteger(_ value: UInt64) {
            var encoded = value.bigEndian
            withUnsafeBytes(of: &encoded) { hash.update(data: Data($0)) }
        }
        appendInteger(UInt64(identities.count))
        for identity in identities.sorted(by: { $0.rowid < $1.rowid }) {
            appendInteger(UInt64(identity.rowid))
            appendInteger(UInt64(identity.guid.count))
            hash.update(data: identity.guid)
        }
        count = identities.count
        sha256 = hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
