import Foundation
import Testing
@testable import MessagesKit

struct MessageSummaryPlistTests {
    @Test func nativeShapedSyntheticDictionaryPreservesTypes() throws {
        let fixture: [String: Any] = [
            "ep": [0, 2], "rp": [1], "otr": ["0": ["lo": 0, "le": 4]],
            "ec": ["0": [["d": -1, "t": Data([1, 2, 3])]]],
            "label": "Synthetic 🐝", "flag": true, "fraction": 1.5,
            "date": Date(timeIntervalSinceReferenceDate: 42)
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)
        var budget = MessageSummaryPlist.Budget()
        let value = try MessageSummaryPlist.decode(data, budget: &budget)
        #expect(value == .dictionary([
            "ep": .array([.integer(0), .integer(2)]), "rp": .array([.integer(1)]),
            "otr": .dictionary(["0": .dictionary(["lo": .integer(0), "le": .integer(4)])]),
            "ec": .dictionary(["0": .array([.dictionary(["d": .integer(-1), "t": .data(Data([1, 2, 3]))])])]),
            "label": .string("Synthetic 🐝"), "flag": .boolean(true), "fraction": .real(1.5),
            "date": .date(42)
        ]))
        #expect(budget.remainingVisits < 65_536)
        #expect(budget.remainingBytes < 4 * 1_024 * 1_024)
    }

    /// Independent byte-level fixtures; no production encoder participates.
    private func plist(_ objects: [[UInt8]], root: Int = 0, offsets: [Int]? = nil) -> Data {
        var bytes = Array("bplist00".utf8)
        var positions: [Int] = []
        for object in objects { positions.append(bytes.count); bytes += object }
        let table = bytes.count
        for offset in offsets ?? positions { bytes += bigEndian(UInt64(offset)) }
        bytes += [0, 0, 0, 0, 0, 0, 8, 2]
        bytes += bigEndian(UInt64(objects.count)) + bigEndian(UInt64(root)) + bigEndian(UInt64(table))
        return Data(bytes)
    }

    private func bigEndian(_ value: UInt64) -> [UInt8] {
        (0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    private func decode(_ data: Data) throws -> MessageSummaryPlist.Value {
        var budget = MessageSummaryPlist.Budget()
        return try MessageSummaryPlist.decode(data, budget: &budget)
    }

    @Test func integerWidthsAreNotSignExtendedUntilEightBytes() throws {
        #expect(try decode(plist([[0x10, 255]])) == .integer(255))
        #expect(try decode(plist([[0x11, 255, 255]])) == .integer(65_535))
        #expect(try decode(plist([[0x12, 255, 255, 255, 255]])) == .integer(4_294_967_295))
        #expect(try decode(plist([[0x13] + bigEndian(UInt64.max)])) == .integer(-1))
        #expect(try decode(plist([[0x13] + bigEndian(UInt64(Int64.max))])) == .integer(Int64.max))
        #expect(try decode(plist([[0x13] + bigEndian(1 << 63)])) == .integer(Int64.min))
    }

    @Test func primitiveKindsAndEmptyCollectionsRemainDistinct() throws {
        #expect(try decode(plist([[0x00]])) == .null)
        #expect(try decode(plist([[0x08]])) == .boolean(false))
        #expect(try decode(plist([[0x09]])) == .boolean(true))
        #expect(try decode(plist([[0x22, 0x3f, 0xc0, 0, 0]])) == .real(1.5))
        #expect(try decode(plist([[0x40]])) == .data(Data()))
        #expect(try decode(plist([[0x50]])) == .string(""))
        #expect(try decode(plist([[0xa0]])) == .array([]))
        #expect(try decode(plist([[0xd0]])) == .dictionary([:]))
    }

    @Test func unsupportedEncodingsAreNotCoerced() {
        for object: [UInt8] in [[0x14] + Array(repeating: 0, count: 16), [0x80, 0], [0xc0], [0x0f]] {
            #expect(throws: MessageSummaryPlist.Failure.unsupportedFormat) { try decode(plist([object])) }
        }
        #expect(throws: MessageSummaryPlist.Failure.unsupportedFormat) { try decode(Data("<?xml version='1.0'?>".utf8)) }
    }

    @Test func truncatedStorageAndInvalidTableFieldsAreRejected() {
        let good = plist([[0x10, 7]])
        for count in 0..<good.count {
            #expect(throws: (any Error).self) { try decode(good.prefix(count)) }
        }
        for trailerByte in [6, 7] {
            var bad = good
            bad[bad.count - 32 + trailerByte] = 0
            #expect(throws: MessageSummaryPlist.Failure.corrupt) { try decode(bad) }
        }
        #expect(throws: MessageSummaryPlist.Failure.corrupt) { try decode(plist([[0x00]], root: 1)) }
        #expect(throws: MessageSummaryPlist.Failure.corrupt) { try decode(plist([[0x00]], offsets: [0])) }
        #expect(throws: MessageSummaryPlist.Failure.corrupt) { try decode(plist([[0x00]], offsets: [9])) }
        #expect(throws: MessageSummaryPlist.Failure.corrupt) { try decode(plist([[0x43, 1]])) }
        #expect(throws: MessageSummaryPlist.Failure.corrupt) { try decode(plist([[0xaf, 0x13] + bigEndian(UInt64.max)])) }
    }

    @Test func allObjectSpansAndReferencesAreValidatedEvenWhenUnreachable() {
        #expect(throws: MessageSummaryPlist.Failure.corrupt) { try decode(plist([[0x00], [0x00]], offsets: [8, 8])) }
        #expect(throws: MessageSummaryPlist.Failure.corrupt) { try decode(plist([[0x42, 0, 0], [0x00]], offsets: [8, 9])) }
        #expect(throws: MessageSummaryPlist.Failure.corrupt) { try decode(plist([[0x00], [0xa1, 0, 9]])) }
        #expect(throws: MessageSummaryPlist.Failure.corrupt) { try decode(plist([[0xa1, 0, 0]])) }
    }

    @Test func strictStringsAndDictionaryKeys() throws {
        #expect(try decode(plist([[0x62, 0xd8, 0x3d, 0xde, 0x00]])) == .string("😀"))
        for bad in [[UInt8(0x51), 0xff], [0x61, 0xd8, 0x00], [0x61, 0xdc, 0x00], [0x62, 0xd8, 0, 0, 65]] {
            #expect(throws: MessageSummaryPlist.Failure.corrupt) { try decode(plist([bad])) }
        }
        #expect(throws: MessageSummaryPlist.Failure.corrupt) {
            try decode(plist([[0xd2, 0, 1, 0, 2, 0, 3, 0, 3], [0x51, 65], [0x51, 65], [0x00]]))
        }
        #expect(throws: MessageSummaryPlist.Failure.corrupt) {
            try decode(plist([[0xd1, 0, 1, 0, 2], [0x10, 1], [0x00]]))
        }
    }

    @Test func repeatedReferencesAreValidButExpansionIsBounded() throws {
        #expect(try decode(plist([[0xa2, 0, 1, 0, 1], [0x51, 65]])) == .array([.string("A"), .string("A")]))
        var objects: [[UInt8]] = (0..<15).map { i in [0xa2, 0, UInt8(i + 1), 0, UInt8(i + 1)] }
        objects.append([0x00])
        #expect(throws: MessageSummaryPlist.Failure.resourceLimit) { try decode(plist(objects)) }
        let chain = (0..<32).map { i in [UInt8(0xa1), 0, UInt8(i + 1)] } + [[0x00]]
        #expect(throws: MessageSummaryPlist.Failure.resourceLimit) { try decode(plist(chain)) }
    }

    @Test func serializedObjectCollectionAndStringLimits() {
        #expect(throws: MessageSummaryPlist.Failure.resourceLimit) { try decode(Data(repeating: 0, count: 1_048_577)) }
        #expect(throws: MessageSummaryPlist.Failure.resourceLimit) { try decode(plist(Array(repeating: [0x00], count: 16_385))) }
        #expect(throws: MessageSummaryPlist.Failure.resourceLimit) {
            try decode(plist([[0xaf, 0x11, 0x10, 0x01] + Array(repeating: 0, count: 8_194)]))
        }
        #expect(throws: MessageSummaryPlist.Failure.resourceLimit) {
            try decode(plist([[0x5f, 0x12, 0, 4, 0, 1] + Array(repeating: 65, count: 262_145)]))
        }
    }

    @Test func sharedRequestBudgetIsChargedWithoutRefundOnFailure() throws {
        var budget = MessageSummaryPlist.Budget(remainingVisits: 100, remainingBytes: 3)
        let a = plist([[0x52, 65, 66]])
        #expect(try MessageSummaryPlist.decode(a, budget: &budget) == .string("AB"))
        #expect(budget.remainingBytes == 1)
        #expect(throws: MessageSummaryPlist.Failure.requestLimit) { try MessageSummaryPlist.decode(a, budget: &budget) }
        #expect(budget.remainingVisits < 98)
        var noVisits = MessageSummaryPlist.Budget(remainingVisits: 0, remainingBytes: 100)
        #expect(throws: MessageSummaryPlist.Failure.requestLimit) { try MessageSummaryPlist.decode(a, budget: &noVisits) }
        var corruptBudget = MessageSummaryPlist.Budget()
        #expect(throws: MessageSummaryPlist.Failure.corrupt) {
            try MessageSummaryPlist.decode(plist([[0x51, 255]]), budget: &corruptBudget)
        }
        #expect(corruptBudget.remainingBytes == 4 * 1_024 * 1_024 - 1)
    }

    @Test func exactByteLimitsAllowSuccessAndRejectRepeatedExpansion() throws {
        let text = [UInt8(0x5f), 0x12, 0, 4, 0, 0] + Array(repeating: UInt8(65), count: 262_144)
        #expect(try decode(plist([text])) == .string(String(repeating: "A", count: 262_144)))
        let data = [UInt8(0x4f), 0x12, 0, 4, 0, 0] + Array(repeating: UInt8(7), count: 262_144)
        let four = plist([[0xa4, 0, 1, 0, 1, 0, 1, 0, 1], data])
        #expect(try decode(four) == .array(Array(repeating: .data(Data(repeating: 7, count: 262_144)), count: 4)))
        #expect(throws: MessageSummaryPlist.Failure.resourceLimit) {
            try decode(plist([[0xa5, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1], data]))
        }
        var budget = MessageSummaryPlist.Budget()
        for _ in 0..<4 { _ = try MessageSummaryPlist.decode(four, budget: &budget) }
        #expect(budget.remainingBytes == 0)
        #expect(throws: MessageSummaryPlist.Failure.requestLimit) {
            try MessageSummaryPlist.decode(four, budget: &budget)
        }
    }

    @Test func offsetsMayBeUnsortedAndDataSlicesNeedNoZeroStartIndex() throws {
        #expect(try decode(plist([[0x00], [0x08]], offsets: [9, 8])) == .boolean(false))
        var data = Data([255, 255])
        data.append(plist([[0x10, 42]]))
        #expect(try decode(data.dropFirst(2)) == .integer(42))
    }

    @Test func cancellationPropagatesBeforeValidationAndDuringTraversal() throws {
        for stopAt in [1, 5, 9] {
            var budget = MessageSummaryPlist.Budget()
            var calls = 0
            #expect(throws: CancellationError.self) {
                try MessageSummaryPlist.decode(plist([[0xa2, 0, 1, 0, 1], [0x51, 65]]), budget: &budget,
                                               checkCancellation: {
                    calls += 1
                    if calls == stopAt { throw CancellationError() }
                })
            }
            #expect(calls == stopAt)
        }
    }
}
