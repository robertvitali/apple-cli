import CryptoKit
import Foundation

/// Verifies the edit and retraction comparisons persisted with a baseline membership.
enum MessageEventSummaryRecord {
    enum Failure: Error, Equatable { case invalidRecord, witnessUnavailable }
    enum Component {
        case edit, retraction

        fileprivate var slots: Range<Int> { self == .edit ? 0..<2 : 2..<3 }
    }

    struct Observation {
        let status: String
        let bytes: Data

        func append(to hash: inout SHA256) {
            for field in [Data(status.utf8), bytes] {
                withUnsafeBytes(of: Int64(field.count).bigEndian) { hash.update(bufferPointer: $0) }
                hash.update(data: field)
            }
        }

        var fingerprint: Data {
            var hash = SHA256()
            append(to: &hash)
            return Data(hash.finalize())
        }
    }

    private static let statuses = ["available", "missing-schema", "null", "wrong-type",
                                   "invalid-value", "malformed", "limited", "missing-key"]
    private static let noValue = statuses.map { Observation(status: $0, bytes: Data()).fingerprint }
    private static let empty = Observation(status: "available", bytes: Data(SHA256.hash(data: Data())))
    static let emptyContainerFingerprint = empty.fingerprint

    private static func fingerprint(_ slot: Int, in record: Data) -> Data {
        let start = record.startIndex + 4 + 32 * slot
        return record[start..<start + 32]
    }

    private static func validateFacets(_ record: Data, source: Int) throws {
        guard record.count == 100, source < 4, record.first == 1 || record.first == 2 else {
            throw Failure.invalidRecord
        }
        for slot in 0..<3 {
            let status = Int(record[record.startIndex + 1 + slot])
            guard status < statuses.count,
                  source == 0 ? (status == 0 || status >= 5) : status == source else { throw Failure.invalidRecord }
            if status != 0, fingerprint(slot, in: record) != noValue[status] { throw Failure.invalidRecord }
        }
    }

    static func encode(_ facets: [Observation], sourceStatus: UInt8) throws -> Data {
        guard facets.count == 3 else { throw Failure.invalidRecord }
        var record = Data([2])
        for facet in facets {
            guard let index = statuses.firstIndex(of: facet.status),
                  index == 0 ? facet.bytes.count == 32 : facet.bytes.isEmpty else { throw Failure.invalidRecord }
            record.append(UInt8(index))
        }
        for facet in facets { record.append(facet.fingerprint) }
        try validateFacets(record, source: Int(sourceStatus))
        return record
    }

    static func component(_ component: Component, date: Observation, record: Data) throws -> (digest: Data, availability: UInt8) {
        guard record.count == 100, let code = statuses.firstIndex(of: date.status), code <= 3,
              code == 0 ? date.bytes.count == 8 : date.bytes.isEmpty else { throw Failure.invalidRecord }
        var hash = SHA256()
        hash.update(data: Data("summary-component-v2".utf8))
        date.append(to: &hash)
        var status = UInt8(code)
        for slot in component.slots {
            hash.update(data: fingerprint(slot, in: record))
            if status == 0 { status = record[record.startIndex + 1 + slot] }
        }
        return (Data(hash.finalize()), status == 7 ? 2 : status)
    }

    private struct Inputs: Equatable {
        let projection, record, hashes, availability: Data

        init(projection: Data, hashes: Data, availability: Data, record: Data) throws {
            guard hashes.count == 256, availability.count == 8, (1...65_536).contains(projection.count) else {
                throw Failure.invalidRecord
            }
            let source = Int(availability[availability.startIndex + 1])
            try validateFacets(record, source: source)
            let base = hashes.startIndex
            if source != 0, hashes[base + 32..<base + 64] != noValue[source] {
                throw Failure.invalidRecord
            }
            self.hashes = hashes.subdata(in: base + 64..<base + 128)
            let index = availability.startIndex + 2
            self.availability = availability.subdata(in: index..<index + 2)
            self.record = record
            self.projection = projection
        }

        func components(evidence: [Observation]?, allowMissingWitness: Bool) throws -> Data {
            let dates = try MessageEventDelivery.retainedDates(in: projection)
            var replacement = Data()
            for (i, item) in [Component.edit, .retraction].enumerated() {
                let status = Int(availability[i])
                let encoded = i == 0 ? dates.edited : dates.retracted
                let date: Observation
                if let encoded {
                    guard encoded.utf8.count == 12, let bytes = Data(base64Encoded: encoded),
                          bytes.count == 8, bytes.base64EncodedString() == encoded else { throw Failure.invalidRecord }
                    date = Observation(status: "available", bytes: bytes)
                } else {
                    guard (1...3).contains(status) else { throw Failure.invalidRecord }
                    date = Observation(status: statuses[status], bytes: Data())
                }
                let current = try component(item, date: date, record: record)
                guard current.availability == status else { throw Failure.invalidRecord }
                let expected = hashes[32 * i..<32 * (i + 1)]
                if record.first == 1 {
                    do {
                        var hash = SHA256()
                        date.append(to: &hash)
                        for slot in item.slots { try legacyFacet(slot, evidence: evidence).append(to: &hash) }
                        guard expected.elementsEqual(hash.finalize()) else { throw Failure.invalidRecord }
                    } catch Failure.witnessUnavailable where allowMissingWitness {
                        // Upgrade checks this component again against the source before committing.
                    }
                } else if current.digest != expected { throw Failure.invalidRecord }
                replacement.append(current.digest)
            }
            return replacement
        }

        private func legacyFacet(_ slot: Int, evidence: [Observation]?) throws -> Observation {
            let status = Int(record[record.startIndex + 1 + slot])
            if status != 0 { return Observation(status: statuses[status], bytes: Data()) }
            let expected = fingerprint(slot, in: record)
            if expected == emptyContainerFingerprint { return empty }
            guard let evidence, evidence.count == 3, evidence[slot].status == "available",
                  evidence[slot].bytes.count == 32, evidence[slot].fingerprint == expected else {
                throw Failure.witnessUnavailable
            }
            return evidence[slot]
        }
    }

    struct Validator {
        let allowMissingWitness: Bool
        private var last: Inputs?

        init(allowMissingWitness: Bool = false) { self.allowMissingWitness = allowMissingWitness }

        mutating func validate(projection: Data, hashes: Data, availability: Data, record: Data) throws {
            let inputs = try Inputs(projection: projection, hashes: hashes, availability: availability, record: record)
            guard inputs != last else { return }
            _ = try autoreleasepool { try inputs.components(evidence: nil, allowMissingWitness: allowMissingWitness) }
            last = inputs
        }
    }

    static func convertedLegacyComponents(projection: Data, hashes: Data, availability: Data,
                                          record: Data, evidence: [Observation]?) throws -> Data {
        guard record.first == 1 else { throw Failure.invalidRecord }
        let inputs = try Inputs(projection: projection, hashes: hashes, availability: availability, record: record)
        return try inputs.components(evidence: evidence, allowMissingWitness: false)
    }
}
