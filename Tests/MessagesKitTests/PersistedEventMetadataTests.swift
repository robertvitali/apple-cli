import CryptoKit
import Foundation
import Testing
@testable import MessagesKit

@Suite struct PersistedEventMetadataTests {
    private func digest(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }
    private func decode(_ bytes: Data) throws -> MessageEventFilter {
        try MessageEventFilter(canonicalBytes: bytes, expectedDigest: digest(bytes))
    }

    @Test func canonicalRoundTripsIncludeSlicedDataAndMaximumSize() throws {
        let cases: [[String]?] = [nil, ["synthetic"], ["é", "e\u{301}"],
            (0..<256).map { String(format: "%03d", $0) + String(repeating: "x", count: 1_021) }]
        for values in cases {
            let filter = try MessageEventFilter(conversations: values)
            let bytes = filter.canonicalBytes
            #expect(try decode(bytes) == filter)
            var padded = Data([99, 98]); padded.append(bytes)
            let slice = padded.dropFirst(2)
            #expect(slice.startIndex != 0)
            #expect(try decode(slice) == filter)
            let truncations = bytes.count < 100 ? Array(bytes.indices) : [0, 1, 2, 5, 6, 9, 10, bytes.count - 1]
            for end in truncations {
                #expect(throws: PersistedEventMetadataFailure.invalidFilter) { try decode(Data(bytes.prefix(end))) }
            }
        }
    }

    @Test func malformedEncodingsAreRejectedWithoutNormalization() throws {
        let malformed: [[UInt8]] = [
            [2,0,0,0,0,0], [1,2,0,0,0,0], [1,0,0,0,0,1], [1,1,0,0,0,0],
            [1,1,255,255,255,255], [1,0,0,0,0,0,0],
            [1,1,0,0,0,1,0,0,0,0], [1,1,0,0,0,1,255,255,255,255],
            [1,1,0,0,0,1,0,0,0,1,255], [1,1,0,0,0,1,0,0,0,1,0],
            [1,1,0,0,0,2,0,0,0,1,97,0,0,0,1,97],
            [1,1,0,0,0,2,0,0,0,1,98,0,0,0,1,97]
        ]
        for bytes in malformed { #expect(throws: PersistedEventMetadataFailure.invalidFilter) { try decode(Data(bytes)) } }
        #expect(throws: PersistedEventMetadataFailure.invalidFilter) { try decode(Data(repeating: 0, count: 263_175)) }
        let bytes = try MessageEventFilter(conversations: nil).canonicalBytes
        for bad in [Data(), Data(repeating: 0, count: 31), Data(repeating: 0, count: 32), Data(repeating: 0, count: 33), Data(repeating: 97, count: 64)] {
            #expect(throws: PersistedEventMetadataFailure.digestMismatch) { try MessageEventFilter(canonicalBytes: bytes, expectedDigest: bad) }
        }
    }

    private func metadata(format: Int64 = 1, initialized: Int64 = 1,
                          generation: Int64 = 1, head: Int64 = 0,
                          stream: Data = Data("00000000-0000-0000-0000-000000000001".utf8),
                          source: Data = Data("00000000-0000-0000-0000-000000000002".utf8),
                          filterBytes: Data? = nil, filterDigest: Data? = nil) throws -> PersistedEventMetadata {
        let filter = try filterBytes ?? MessageEventFilter(conversations: nil).canonicalBytes
        return try PersistedEventMetadata(format: format, initialized: initialized,
            stream: stream, source: source,
            filterBytes: filter, filterDigest: filterDigest ?? digest(filter), generation: generation, head: head)
    }

    @Test func metadataCrossFieldBoundaries() throws {
        #expect(try metadata(initialized: 0, generation: 0).initialized == false)
        #expect(try metadata(generation: Int64.max, head: Int64.max).head == Int64.max)
        #expect(try metadata(generation: 1, head: 100).generation == 1)
        #expect(try metadata(generation: 100, head: 0).head == 0)
        for (initialized, generation, head) in [(0,1,0), (0,0,1), (1,0,0), (1,-1,0), (1,1,-1), (2,1,0), (-1,0,0)] {
            #expect(throws: PersistedEventMetadataFailure.invalidMetadata) {
                try metadata(initialized: Int64(initialized), generation: Int64(generation), head: Int64(head))
            }
        }
        for format: Int64 in [0, 2, Int64.min, Int64.max] {
            #expect(throws: PersistedEventMetadataFailure.invalidMetadata) { try metadata(format: format) }
        }
        for stream in [Data(), Data(repeating: 255, count: 36), Data("00000000-0000-0000-0000-00000000000A".utf8)] {
            #expect(throws: PersistedEventMetadataFailure.invalidMetadata) { try metadata(stream: stream) }
            #expect(throws: PersistedEventMetadataFailure.invalidMetadata) { try metadata(source: stream) }
        }
    }

    @Test func payloadPresentBoundariesAndInvalidUnicode() throws {
        func encoded(_ members: [Data]) -> Data {
            func count(_ value: Int) -> [UInt8] {
                [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: UInt32(value) >> $0) }
            }
            var bytes = Data([1, 1] + count(members.count))
            for member in members { bytes.append(contentsOf: count(member.count)); bytes.append(member) }
            return bytes
        }
        let invalidMembers: [Data] = [
            Data(repeating: 97, count: 1_025), Data([0xC0, 0xAF]),
            Data([0xED, 0xA0, 0x80]), Data([0xE2, 0x82]),
            Data([0xEF, 0xBB, 0xBF]), Data("\u{202E}".utf8), Data("\u{2028}".utf8)
        ]
        for member in invalidMembers {
            #expect(throws: PersistedEventMetadataFailure.invalidFilter) { try decode(encoded([member])) }
        }
        let tooMany = encoded((0..<257).map { Data(String(format: "%03d", $0).utf8) })
        #expect(throws: PersistedEventMetadataFailure.invalidFilter) { try decode(tooMany) }
        var trailing = encoded([Data("synthetic".utf8)])
        trailing.append(0)
        #expect(throws: PersistedEventMetadataFailure.invalidFilter) { try decode(trailing) }
    }

    @Test func metadataRetainsFieldsAndPropagatesFilterFailures() throws {
        let filter = try MessageEventFilter(conversations: ["synthetic"])
        let value = try metadata(generation: 2, head: 3, filterBytes: filter.canonicalBytes)
        #expect(value.initialized)
        #expect(value.stream.rawValue == "00000000-0000-0000-0000-000000000001")
        #expect(value.source.rawValue == "00000000-0000-0000-0000-000000000002")
        #expect(value.filter == filter)
        #expect(value.generation == 2)
        #expect(value.head == 3)
        #expect(throws: PersistedEventMetadataFailure.invalidFilter) { try metadata(filterBytes: Data()) }
        #expect(throws: PersistedEventMetadataFailure.digestMismatch) {
            try metadata(filterDigest: Data(repeating: 0, count: 32))
        }
        #expect(throws: PersistedEventMetadataFailure.digestMismatch) { try metadata(filterDigest: Data()) }
    }
}
