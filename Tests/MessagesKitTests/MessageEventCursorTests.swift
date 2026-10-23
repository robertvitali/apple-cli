import Foundation
import Testing
@testable import MessagesKit

struct MessageEventCursorTests {
    private typealias Failure = MessageEventCursorFailure
    private let streamText = "01234567-89ab-cdef-0123-456789abcdef"
    private let otherStreamText = "00000000-0000-0000-0000-000000000000"
    private let digestText = String(repeating: "a", count: 64)
    private let otherDigestText = String(repeating: "b", count: 64)

    private func cursor(_ sequence: Int64) throws -> MessageEventCursor {
        try MessageEventCursor(stream: MessageEventStreamID(streamText),
                               filter: MessageEventFilterDigest(digestText), sequence: sequence)
    }

    @Test func independentGoldenFilterVectors() throws {
        // Python hashlib/struct vectors, synthesized independently of this encoder.
        let vectors: [([String]?, String, String)] = [
            (nil, "010000000000", "36c159d76b52e03e496363607c5940227f62f4e048df344b050159bc97bba3d7"),
            (["synthetic-chat-a"], "0101000000010000001073796e7468657469632d636861742d61", "5af2760b553eee0e5666326a2fdcd79aed83c12ff2d8921fc04afd2405c72cf1"),
            (["synthetic-chat-b", "synthetic-chat-a"], "0101000000020000001073796e7468657469632d636861742d610000001073796e7468657469632d636861742d62", "5f2eb30191345b75722f227f5093454a2928e6a39a381ba5e2913b9039df2d39"),
            (["synthetic-chat-a", "synthetic-chat-a"], "0101000000010000001073796e7468657469632d636861742d61", "5af2760b553eee0e5666326a2fdcd79aed83c12ff2d8921fc04afd2405c72cf1"),
            (["é", "é"], "0101000000020000000365cc8100000002c3a9", "ce46b65c8cc4e9de1bb8755c1af6d988daa7011f5b53b4b8e8d46d1c0ba6df2c"),
            (["a,b", "c"], "01010000000200000003612c620000000163", "5a94c1c07f7a349886473f2383245377d52c26b592ce6f3cbcbba20283a932db"),
            (["a", "b,c"], "010100000002000000016100000003622c63", "78f9ef89be8ff3957c7f431946f6beebcc0dde9c13e1e01d0ec5e2d478cfbc9c"),
            (["ab", "a"], "0101000000020000000161000000026162", "6513502a55c46e1c36130b024ddda3340929cedbfeda82d5dfdeb043859b6bc9")
        ]
        for (inputs, preimage, digest) in vectors {
            let filter = try MessageEventFilter(conversations: inputs)
            #expect(filter.canonicalBytes.map { String(format: "%02x", $0) }.joined() == preimage)
            #expect(filter.digest.rawValue == digest)
        }
    }

    @Test func identifiersPreserveExactBytesAndSpelling() throws {
        let composed = try MessageEventGUID("\u{e9}")
        let decomposed = try MessageEventGUID("e\u{301}")
        #expect(composed != decomposed)
        #expect(Set([composed, decomposed]).count == 2)
        #expect(try MessageEventGUID(" A ").rawValue == " A ")
        #expect(try MessageEventGUID("A") != MessageEventGUID("a"))
        let filter = try MessageEventFilter(conversations: ["\u{e9}", "e\u{301}", "\u{e9}"])
        #expect(filter.conversations?.map(\.bytes) == [Data([0x65, 0xcc, 0x81]), Data([0xc3, 0xa9])])
        #expect(filter.conversations?.last?.rawValue.utf8.elementsEqual("\u{e9}".utf8) == true)
    }

    @Test func identifierByteLimits() throws {
        #expect(try MessageEventGUID(String(repeating: "a", count: 1_024)).bytes.count == 1_024)
        #expect(try MessageEventGUID(String(repeating: "é", count: 512)).bytes.count == 1_024)
        for value in ["", String(repeating: "a", count: 1_025), String(repeating: "é", count: 513)] {
            #expect(throws: Failure.invalidIdentifier) { try MessageEventGUID(value) }
        }
    }

    @Test(arguments: ["\0", "\n", "\r", "\t", "\u{7f}", "\u{85}", "\u{200b}",
                      "\u{202e}", "\u{feff}", "\u{2028}", "\u{2029}"])
    func forbiddenIdentifierCategories(_ character: String) {
        #expect(throws: Failure.invalidIdentifier) { try MessageEventGUID("synthetic" + character) }
    }

    @Test func filterCountPrecedesMemberValidationAndDeduplication() throws {
        #expect(throws: Failure.invalidFilter) { try MessageEventFilter(conversations: []) }
        #expect(try MessageEventFilter(conversations: Array(repeating: "a", count: 256)).conversations?.count == 1)
        #expect(try MessageEventFilter(conversations: (0..<256).map { "synthetic-\($0)" }).conversations?.count == 256)
        #expect(throws: Failure.invalidFilter) {
            try MessageEventFilter(conversations: ["\n"] + Array(repeating: "a", count: 256))
        }
        #expect(throws: Failure.invalidIdentifier) { try MessageEventFilter(conversations: ["a", "\n"]) }
        #expect(try MessageEventFilter(conversations: ["a"]) != MessageEventFilter(conversations: nil))
        #expect(try MessageEventFilter(conversations: ["b", "a", "b"]) == MessageEventFilter(conversations: ["a", "b"]))
    }

    @Test func streamAndDigestConstructorsAreStrict() throws {
        #expect(try MessageEventStreamID(streamText).rawValue == streamText)
        #expect(try MessageEventStreamID(otherStreamText).rawValue == otherStreamText)
        #expect(try MessageEventStreamID("ffffffff-ffff-ffff-ffff-ffffffffffff").rawValue.hasPrefix("ffff"))
        for value in [streamText.uppercased(), " " + streamText, streamText + " ",
                      streamText.replacingOccurrences(of: "-", with: ""), String(repeating: "g", count: 36)] {
            #expect(throws: Failure.invalidStreamID) { try MessageEventStreamID(value) }
        }
        #expect(try MessageEventFilterDigest(digestText).rawValue == digestText)
        for value in [digestText.uppercased(), String(repeating: "0", count: 63),
                      String(repeating: "0", count: 65), String(repeating: "g", count: 64),
                      String(repeating: "é", count: 32)] {
            #expect(throws: Failure.invalidDigest) { try MessageEventFilterDigest(value) }
        }
    }

    @Test(arguments: [Int64(0), 1, Int64.max])
    func cursorRoundTrip(_ sequence: Int64) throws {
        let value = try cursor(sequence)
        #expect(value.rawValue == "v1.\(streamText).\(digestText).\(sequence)")
        #expect(try MessageEventCursor(value.rawValue) == value)
        #expect(value.rawValue.utf8.count <= 160)
    }

    @Test(arguments: ["", "+0", "-0", "-1", "00", "01", " 1", "1 ", "١", "１",
                      "1.0", "1e0", "9223372036854775808"])
    func malformedSequence(_ sequence: String) {
        #expect(throws: Failure.invalidCursor) { try MessageEventCursor("v1.\(streamText).\(digestText).\(sequence)") }
    }

    @Test func cursorRejectsOtherNoncanonicalForms() throws {
        let valid = try cursor(0).rawValue
        for value in ["", "v2" + valid.dropFirst(2), valid + ".", valid + "\0", " " + valid,
                      valid + "\n", valid.replacingOccurrences(of: "-", with: "%2d"),
                      "v1..\(digestText).0", "v1.\(streamText)..0", "v1.\(streamText.uppercased()).\(digestText).0",
                      "v1.\(streamText).\(digestText.uppercased()).0", String(repeating: "a", count: 161)] {
            #expect(throws: Failure.invalidCursor) { try MessageEventCursor(value) }
        }
        #expect(throws: Failure.invalidCursor) { try cursor(-1) }
    }

    @Test func replayBoundariesAndPrunedState() throws {
        let stream = try MessageEventStreamID(streamText), filter = try MessageEventFilterDigest(digestText)
        try cursor(0).validateReplay(stream: stream, filter: filter, head: 0, oldestRetained: nil)
        try cursor(0).validateReplay(stream: stream, filter: filter, head: 3, oldestRetained: 1)
        try cursor(4).validateReplay(stream: stream, filter: filter, head: 10, oldestRetained: 5)
        try cursor(10).validateReplay(stream: stream, filter: filter, head: 10, oldestRetained: 5)
        try cursor(10).validateReplay(stream: stream, filter: filter, head: 10, oldestRetained: nil)
        try cursor(Int64.max - 1).validateReplay(stream: stream, filter: filter, head: .max, oldestRetained: .max)
        try cursor(.max).validateReplay(stream: stream, filter: filter, head: .max, oldestRetained: nil)
        for (sequence, head, oldest, failure): (Int64, Int64, Int64?, Failure) in [
            (3, 10, 5, .expired), (9, 10, nil, .expired), (11, 10, nil, .aheadOfHead),
            (11, 10, 5, .aheadOfHead), (1, 0, nil, .aheadOfHead), (0, -1, nil, .invalidRetentionBounds),
            (0, 0, 1, .invalidRetentionBounds), (0, 1, 0, .invalidRetentionBounds),
            (0, 1, -1, .invalidRetentionBounds), (0, 1, 2, .invalidRetentionBounds),
            (0, 0, Int64.min, .invalidRetentionBounds)
        ] {
            #expect(throws: failure) { try cursor(sequence).validateReplay(stream: stream, filter: filter, head: head, oldestRetained: oldest) }
        }
    }

    @Test func replayErrorPrecedence() throws {
        let stream = try MessageEventStreamID(streamText), otherStream = try MessageEventStreamID(otherStreamText)
        let filter = try MessageEventFilterDigest(digestText), otherFilter = try MessageEventFilterDigest(otherDigestText)
        #expect(throws: Failure.invalidRetentionBounds) {
            try cursor(10).validateReplay(stream: otherStream, filter: otherFilter, head: -1, oldestRetained: nil)
        }
        #expect(throws: Failure.invalidRetentionBounds) {
            try cursor(0).validateReplay(stream: otherStream, filter: otherFilter, head: 5, oldestRetained: 6)
        }
        for sequence: Int64 in [0, 10] {
            #expect(throws: Failure.streamMismatch) {
                try cursor(sequence).validateReplay(stream: otherStream, filter: otherFilter, head: 5, oldestRetained: 4)
            }
            #expect(throws: Failure.filterMismatch) {
                try cursor(sequence).validateReplay(stream: stream, filter: otherFilter, head: 5, oldestRetained: 4)
            }
        }
        #expect(throws: Failure.aheadOfHead) {
            try cursor(10).validateReplay(stream: stream, filter: filter, head: 5, oldestRetained: 4)
        }
        #expect(throws: Failure.invalidCursor) {
            try MessageEventCursor("invalid").validateReplay(stream: otherStream, filter: otherFilter, head: -1, oldestRetained: nil)
        }
    }
}
