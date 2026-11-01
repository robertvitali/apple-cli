import Foundation
import Testing
@testable import MessagesKit

@Suite struct NativeMessageAttributeObservationTests {
    private let part = NSAttributedString.Key("__kIMMessagePartAttributeName")

    private func archive(_ extra: [NSAttributedString.Key: Any], text: String = "AB") -> Data {
        let value = NSMutableAttributedString(string: text)
        if !text.isEmpty { value.addAttribute(part, value: NSNumber(value: 0), range: NSRange(location: 0, length: value.length)) }
        for (key, data) in extra { value.addAttribute(key, value: data, range: NSRange(location: 0, length: value.length)) }
        return NSArchiver.archivedData(withRootObject: value)
    }

    @Test func strictObservationPreservesOrdinaryReadResults() throws {
        let data = archive([.init("NSLink"): URL(string: "https://example.com/synthetic")!,
                            .init("opaque"): Data([0, 1, 255]),
                            .init("__kIMMentionConfirmedMention"): "alice@example.com"])
        let ordinary = NativeMessageParts.decode(data, requireExactText: true)
        let exact = NativeMessageParts.decodeWithAttributes(data)
        #expect(exact.body == ordinary)
        #expect(exact.body.status == .decoded)
        let run = try #require(exact.runs?.first)
        #expect(run.range == .init(location: 0, length: 2))
        #expect(run.values[Data("opaque".utf8)] == .data(Data([0, 1, 255])))
        #expect(run.values[Data("__kIMMentionConfirmedMention".utf8)] == .string(Data("alice@example.com".utf8)))
        #expect(run.values[Data(part.rawValue.utf8)] == .integer(0))
        guard case .url? = run.values[Data("NSLink".utf8)] else {
            Issue.record("URL record must be retained as a typed value")
            return
        }
    }

    @Test func nestedUnknownDictionaryFieldsRemainObservable() throws {
        let nested: NSDictionary = ["nested": "synthetic", "count": NSNumber(value: 7), "bytes": Data([4, 5])]
        let exact = NativeMessageParts.decodeWithAttributes(archive([.init("unknown"): nested]))
        let values = try #require(exact.runs?.first?.values)
        guard case .dictionary(let fields)? = values[Data("unknown".utf8)] else {
            Issue.record("Nested attributes must retain typed fields")
            return
        }
        #expect(fields[Data("nested".utf8)] == .string(Data("synthetic".utf8)))
        #expect(fields[Data("count".utf8)] == .integer(7))
        #expect(fields[Data("bytes".utf8)] == .data(Data([4, 5])))
    }

    @Test func byteDistinctStringsAndKeysRemainDistinct() throws {
        let a = NativeMessageParts.decodeWithAttributes(archive([.init("\u{e9}"): "\u{e9}"]))
        let b = NativeMessageParts.decodeWithAttributes(archive([.init("e\u{301}"): "e\u{301}"]))
        let av = try #require(a.runs?.first?.values)
        let bv = try #require(b.runs?.first?.values)
        #expect(av != bv)
        #expect(av[Data("\u{e9}".utf8)] == .string(Data("\u{e9}".utf8)))
        #expect(bv[Data("e\u{301}".utf8)] == .string(Data("e\u{301}".utf8)))
    }

    @Test func includesUnindexedSpansAndEmptyAttributes() throws {
        let value = NSMutableAttributedString(string: "A B")
        value.addAttribute(part, value: NSNumber(value: 0), range: .init(location: 0, length: 1))
        value.addAttribute(part, value: NSNumber(value: 1), range: .init(location: 2, length: 1))
        let exact = NativeMessageParts.decodeWithAttributes(NSArchiver.archivedData(withRootObject: value))
        let runs = try #require(exact.runs)
        #expect(runs.map(\.range) == [.init(location: 0, length: 1), .init(location: 1, length: 1), .init(location: 2, length: 1)])
        #expect(runs[1].values.isEmpty)
    }

    @Test func unsupportedAttributeCannotBecomeEmptyObservation() {
        let exact = NativeMessageParts.decodeWithAttributes(archive([.init("unsupported"): Date(timeIntervalSinceReferenceDate: 0)]))
        #expect(exact.runs == nil)
        #expect(exact.body.status == .unsupported)
    }

    @Test func truncatedAndOversizedArchivesFailClosed() {
        let data = archive([.init("opaque"): Data([0, 1])])
        #expect(NativeMessageParts.decodeWithAttributes(Data(data.dropLast())).runs == nil)
        #expect(NativeMessageParts.decodeWithAttributes(data, limits: .init(maxBlobBytes: 2)).runs == nil)
        #expect(NativeMessageParts.decodeWithAttributes(data, limits: .init(maxDictEntries: 1)).runs == nil)
    }

    @Test func sharedLargeStringsCannotExpandAttributeRetentionWithoutBound() {
        let shared = NSString(string: String(repeating: "x", count: 200_000))
        var attributes: [NSAttributedString.Key: Any] = [:]
        for index in 0..<24 { attributes[.init("synthetic-\(index)")] = shared }
        let data = archive(attributes)
        #expect(data.count < 1_048_576)
        #expect(NativeMessageParts.decode(data).status == .decoded)
        let exact = NativeMessageParts.decodeWithAttributes(data)
        #expect(exact.runs == nil)
        #expect(exact.body.nativePartsReason == "attribute-byte-limit")
    }

    @Test(arguments: [false, true])
    func duplicateUnknownAttributeKeysRejectStrictObservationOnly(nested: Bool) throws {
        let first = NSAttributedString.Key("synthetic-opaque-a")
        let second = NSAttributedString.Key("synthetic-opaque-b")
        let fields: [NSAttributedString.Key: Any] = nested
            ? [.init("nested"): [first.rawValue: "first", second.rawValue: "second"] as NSDictionary]
            : [first: "first", second: "second"]
        var data = archive(fields)
        let range = try #require(data.range(of: Data(second.rawValue.utf8)))
        #expect(first.rawValue.utf8.count == second.rawValue.utf8.count)
        data.replaceSubrange(range, with: Data(first.rawValue.utf8))
        let ordinary = NativeMessageParts.decode(data, requireExactText: true)
        #expect(ordinary.status == .decoded)
        #expect(ordinary.nativePartsAvailable)
        #expect(ordinary.text == "AB")
        let strict = NativeMessageParts.decodeWithAttributes(data)
        #expect(strict.runs == nil)
        #expect(strict.body.status == .corrupt)
        #expect(strict.body.nativePartsReason == "duplicate-attribute-key")
    }
}
