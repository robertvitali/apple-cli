import CryptoKit
import Foundation

/// Pure identities for observed events; no native-store, output or journal access.
/// Cursors contain identifier-derived data and are not anonymized or authorization tokens.
enum MessageEventCursorFailure: Error, Equatable {
    case invalidIdentifier, invalidFilter, invalidStreamID, invalidDigest, invalidCursor
    case invalidRetentionBounds, streamMismatch, filterMismatch, aheadOfHead, expired
}

/// Equality is exact UTF-8 identity, not Swift String canonical equivalence.
struct MessageEventGUID: Hashable, Sendable {
    let rawValue: String
    let bytes: Data

    init(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 1_024,
              !value.unicodeScalars.contains(where: {
                  switch $0.properties.generalCategory {
                  case .control, .format, .lineSeparator, .paragraphSeparator: return true
                  default: return false
                  }
              }) else { throw MessageEventCursorFailure.invalidIdentifier }
        rawValue = value
        bytes = Data(value.utf8)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.bytes == rhs.bytes }
    func hash(into hasher: inout Hasher) { hasher.combine(bytes) }
}

struct MessageEventFilterDigest: Hashable, Sendable {
    let rawValue: String

    init(_ value: String) throws {
        guard value.utf8.count == 64, value.utf8.allSatisfy(isLowerHex)
        else { throw MessageEventCursorFailure.invalidDigest }
        rawValue = value
    }

    fileprivate init(hashing data: Data) {
        rawValue = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct MessageEventFilter: Equatable, Sendable {
    /// nil means all conversations; a selected scope is always nonempty and byte-sorted.
    let conversations: [MessageEventGUID]?

    init(conversations values: [String]?) throws {
        guard let values else { conversations = nil; return }
        // Count precedes member validation; duplicates do not bypass the input budget.
        guard (1...256).contains(values.count) else { throw MessageEventCursorFailure.invalidFilter }
        let validated = try values.map(MessageEventGUID.init)
        conversations = Set(validated).sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
    }

    var digest: MessageEventFilterDigest { MessageEventFilterDigest(hashing: canonicalBytes) }

    /// Version, scope, BE32 count, then BE32 byte length and exact UTF-8 per member.
    var canonicalBytes: Data {
        var result = Data([1, conversations == nil ? 0 : 1])
        func appendCount(_ count: Int) {
            let value = UInt32(count)
            result.append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) })
        }
        appendCount(conversations?.count ?? 0)
        for conversation in conversations ?? [] {
            appendCount(conversation.bytes.count)
            result.append(conversation.bytes)
        }
        return result
    }
}

struct MessageEventStreamID: Hashable, Sendable {
    let rawValue: String

    init(_ value: String) throws {
        guard value.utf8.count == 36 else { throw MessageEventCursorFailure.invalidStreamID }
        for (index, byte) in value.utf8.enumerated() {
            let valid = [8, 13, 18, 23].contains(index) ? byte == 45 : isLowerHex(byte)
            guard valid else { throw MessageEventCursorFailure.invalidStreamID }
        }
        // Preserve spelling; Foundation UUID formatting would uppercase hex digits.
        rawValue = value
    }
}

struct MessageEventCursor: Equatable, Sendable {
    let stream: MessageEventStreamID
    let filter: MessageEventFilterDigest
    /// Local delivery through this sequence, not acknowledgment of consumer processing.
    let sequence: Int64

    init(stream: MessageEventStreamID, filter: MessageEventFilterDigest, sequence: Int64) throws {
        guard sequence >= 0 else { throw MessageEventCursorFailure.invalidCursor }
        self.stream = stream
        self.filter = filter
        self.sequence = sequence
    }

    init(_ value: String) throws {
        guard value.utf8.count <= 160 else { throw MessageEventCursorFailure.invalidCursor }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "v1",
              !parts[3].isEmpty, parts[3].utf8.allSatisfy({ (48...57).contains($0) }),
              parts[3] == "0" || parts[3].first != "0",
              let sequence = Int64(parts[3]), sequence >= 0 else {
            throw MessageEventCursorFailure.invalidCursor
        }
        do {
            try self.init(stream: MessageEventStreamID(String(parts[1])),
                          filter: MessageEventFilterDigest(String(parts[2])), sequence: sequence)
        } catch { throw MessageEventCursorFailure.invalidCursor }
    }

    var rawValue: String { "v1.\(stream.rawValue).\(filter.rawValue).\(sequence)" }

    /// Replay starts strictly after sequence. Validate journal bounds before subtracting.
    /// A positive head with no retained events permits only the current head cursor.
    func validateReplay(stream expectedStream: MessageEventStreamID,
                        filter expectedFilter: MessageEventFilterDigest,
                        head: Int64, oldestRetained: Int64?) throws {
        guard head >= 0 else { throw MessageEventCursorFailure.invalidRetentionBounds }
        if let oldestRetained {
            guard oldestRetained > 0, oldestRetained <= head else {
                throw MessageEventCursorFailure.invalidRetentionBounds
            }
        }
        guard stream == expectedStream else { throw MessageEventCursorFailure.streamMismatch }
        guard filter == expectedFilter else { throw MessageEventCursorFailure.filterMismatch }
        guard sequence <= head else { throw MessageEventCursorFailure.aheadOfHead }
        if let oldestRetained {
            guard sequence >= oldestRetained - 1 else { throw MessageEventCursorFailure.expired }
        } else {
            guard sequence == head else { throw MessageEventCursorFailure.expired }
        }
    }
}

private func isLowerHex(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (97...102).contains(byte)
}
