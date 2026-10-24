import CryptoKit
import Foundation

/// Invalid persisted input; intentionally carries no identifier or stored bytes.
enum PersistedEventMetadataFailure: Error, Equatable {
    case invalidFilter, digestMismatch, invalidMetadata
}

extension MessageEventFilter {
    /// Decode the existing format without sorting, deduplicating or repairing stored input.
    /// The unkeyed digest detects corruption; it does not authenticate stored state.
    init(canonicalBytes data: Data, expectedDigest: Data) throws {
        guard (6...263_174).contains(data.count) else {
            throw PersistedEventMetadataFailure.invalidFilter
        }
        // One bounded copy makes offsets independent of a Data slice's startIndex.
        let bytes = Array(data)
        guard bytes[0] == 1, bytes[1] <= 1 else { throw PersistedEventMetadataFailure.invalidFilter }
        var offset = 2
        func readCount() throws -> Int {
            guard bytes.count - offset >= 4 else { throw PersistedEventMetadataFailure.invalidFilter }
            var value: UInt32 = 0
            for byte in bytes[offset..<(offset + 4)] { value = (value << 8) | UInt32(byte) }
            offset += 4
            return Int(value)
        }
        let count = try readCount()
        var values: [String] = []
        if bytes[1] == 0 {
            guard count == 0 else { throw PersistedEventMetadataFailure.invalidFilter }
        } else {
            guard (1...256).contains(count) else { throw PersistedEventMetadataFailure.invalidFilter }
            var previous: Data?
            for _ in 0..<count {
                let length = try readCount()
                guard (1...1_024).contains(length), bytes.count - offset >= length else {
                    throw PersistedEventMetadataFailure.invalidFilter
                }
                let member = Data(bytes[offset..<(offset + length)])
                offset += length
                guard let value = String(data: member, encoding: .utf8),
                      let identifier = try? MessageEventGUID(value), identifier.bytes == member,
                      previous.map({ $0.lexicographicallyPrecedes(member) }) ?? true else {
                    throw PersistedEventMetadataFailure.invalidFilter
                }
                values.append(value)
                previous = member
            }
        }
        guard offset == bytes.count else { throw PersistedEventMetadataFailure.invalidFilter }
        do {
            try self.init(conversations: bytes[1] == 0 ? nil : values)
        } catch {
            throw PersistedEventMetadataFailure.invalidFilter
        }
        guard canonicalBytes == data else { throw PersistedEventMetadataFailure.invalidFilter }
        guard expectedDigest.count == 32, Data(SHA256.hash(data: data)) == expectedDigest else {
            throw PersistedEventMetadataFailure.digestMismatch
        }
    }
}

/// Pure validation of extracted fields, not SQL storage classes or journal integrity.
/// The database validator must additionally check relational invariants and state digests.
struct PersistedEventMetadata: Sendable {
    let initialized: Bool
    let stream: MessageEventStreamID
    let source: MessageEventStreamID
    let filter: MessageEventFilter
    let generation: Int64
    let head: Int64

    init(format: Int64, initialized: Int64, stream: Data, source: Data,
         filterBytes: Data, filterDigest: Data, generation: Int64, head: Int64) throws {
        guard format == 1, initialized == 0 || initialized == 1,
              generation >= 0, head >= 0,
              initialized == 0 ? (generation == 0 && head == 0) : generation >= 1 else {
            throw PersistedEventMetadataFailure.invalidMetadata
        }
        func identifier(_ bytes: Data) throws -> MessageEventStreamID {
            guard bytes.count == 36, let text = String(data: bytes, encoding: .utf8),
                  Data(text.utf8) == bytes, let value = try? MessageEventStreamID(text) else {
                throw PersistedEventMetadataFailure.invalidMetadata
            }
            return value
        }
        self.initialized = initialized == 1
        self.stream = try identifier(stream)
        self.source = try identifier(source)
        self.filter = try MessageEventFilter(canonicalBytes: filterBytes, expectedDigest: filterDigest)
        self.generation = generation
        self.head = head
    }
}
