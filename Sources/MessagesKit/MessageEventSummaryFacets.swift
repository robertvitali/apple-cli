import CryptoKit
import Foundation

/// The v1 journal fingerprints ep (edited parts), ec (edit history) and rp (retracted parts) independently.
struct MessageEventSummaryFacets {
    struct Facet: Equatable {
        enum Status: String { case available, missingKey = "missing-key", malformed, limited }
        let status: Status
        let digest: Data

        static let missing = Self(status: .missingKey, digest: Data())
        static let malformed = Self(status: .malformed, digest: Data())
        static let limited = Self(status: .limited, digest: Data())
    }

    let editedParts, history, retractedParts: Facet
    private typealias Value = MessageSummaryPlist.Value

    static func read(_ blob: Data, checkCancellation: () throws -> Void) throws -> Self {
        var budget = MessageSummaryPlist.Budget()
        let root: Value
        do {
            root = try MessageSummaryPlist.decode(blob, budget: &budget, forEventCapture: true,
                                                  checkCancellation: checkCancellation)
        } catch MessageSummaryPlist.Failure.resourceLimit, MessageSummaryPlist.Failure.requestLimit {
            return Self(editedParts: .limited, history: .limited, retractedParts: .limited)
        } catch is MessageSummaryPlist.Failure {
            return Self(editedParts: .malformed, history: .malformed, retractedParts: .malformed)
        }
        guard case .dictionary(let fields) = root else {
            return Self(editedParts: .malformed, history: .malformed, retractedParts: .malformed)
        }
        return try Self(editedParts: indexes(fields["ep"], checkCancellation),
                        history: editHistory(fields["ec"], checkCancellation),
                        retractedParts: indexes(fields["rp"], checkCancellation))
    }

    private static func append(_ number: Int64, to hash: inout SHA256) {
        withUnsafeBytes(of: number.bigEndian) { hash.update(bufferPointer: $0) }
    }

    private static func indexes(_ value: Value?, _ check: () throws -> Void) throws -> Facet {
        guard let value else { return .missing }
        guard case .array(let values) = value else { return .malformed }
        var seen = Set<Int64>(), hash = SHA256()
        for item in values {
            try check()
            guard case .integer(let index) = item, (0...Int64(Int32.max)).contains(index),
                  seen.insert(index).inserted else { return .malformed }
            append(index, to: &hash)
        }
        return Facet(status: .available, digest: Data(hash.finalize()))
    }

    private static func editHistory(_ value: Value?, _ check: () throws -> Void) throws -> Facet {
        guard let value else { return .missing }
        guard case .dictionary(let groups) = value else { return .malformed }
        var parts: [(Int32, [Value])] = []
        for (key, value) in groups {
            try check()
            guard let index = Int32(key), index >= 0, String(index).utf8.elementsEqual(key.utf8),
                  case .array(let events) = value else { return .malformed }
            parts.append((index, events))
        }
        var hash = SHA256(), count = 0
        for (index, events) in parts.sorted(by: { $0.0 < $1.0 }) {
            append(Int64(index), to: &hash)
            append(Int64(events.count), to: &hash)
            for event in events {
                try check()
                count += 1
                guard count <= 256 else { return .limited }
                guard case .dictionary(let fields) = event, case .data(let body)? = fields["t"] else { return .malformed }
                switch fields["d"] {
                case .integer(let seconds) where (-63_113_904_000...252_423_993_599).contains(seconds):
                    hash.update(data: Data([0]))
                    append(seconds, to: &hash)
                case .real(let seconds) where seconds >= -63_113_904_000 && seconds < 252_423_993_600:
                    hash.update(data: Data([1]))
                    append(Int64(bitPattern: seconds.bitPattern), to: &hash)
                default: return .malformed
                }
                hash.update(data: Data(SHA256.hash(data: body)))
            }
        }
        return Facet(status: .available, digest: Data(hash.finalize()))
    }
}
