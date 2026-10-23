import Foundation
import Testing
@testable import MessagesKit

@Suite struct NativeMentionDecoderTests {
    private let mention = NSAttributedString.Key("__kIMMentionConfirmedMention")
    private let part = NSAttributedString.Key("__kIMMessagePartAttributeName")

    private func archive(_ value: NSAttributedString) -> Data {
        NSArchiver.archivedData(withRootObject: value)
    }

    private func blob(_ text: String, value: Any?, range: NSRange? = nil,
                      withPart: Bool = true) -> Data {
        let a = NSMutableAttributedString(string: text)
        let full = NSRange(location: 0, length: a.length)
        if withPart { a.addAttribute(part, value: NSNumber(value: 0), range: full) }
        if let value { a.addAttribute(mention, value: value, range: range ?? full) }
        return archive(a)
    }

    private func decode(_ data: Data) -> NativeMessageParts.Decoded {
        NativeMessageParts.decode(data, collectMentions: true)
    }

    private func expectPartsUnchanged(_ data: Data) {
        let old = NativeMessageParts.decode(data)
        let new = decode(data)
        #expect(old.text == new.text)
        #expect(old.status == new.status)
        #expect(old.nativePartsAvailable == new.nativePartsAvailable)
        #expect(old.nativePartsReason == new.nativePartsReason)
        #expect(old.nativeParts == new.nativeParts)
        #expect(old.mentions == nil)
    }

    @Test func optInKeepsOriginalTextAndNativeParts() throws {
        let data = blob("Hi 👋 Alice", value: "alice@example.com", range: .init(location: 6, length: 5))
        expectPartsUnchanged(data)
        let result = decode(data)
        let entity = try #require(result.mentions?.entries?.first)
        #expect(result.text == "Hi 👋 Alice")
        #expect(entity.identifier == "alice@example.com")
        #expect(entity.utf16Range == .init(location: 6, length: 5))
        #expect(result.mentions?.reason == nil)
    }

    @Test func mentionsWithoutPartsAndKnownEmptyAreAvailable() {
        let withMention = decode(blob("Alice", value: "alice@example.com", withPart: false))
        #expect(withMention.status == .noNativeKeys)
        #expect(withMention.mentions?.entries?.count == 1)
        for text in ["plain", ""] {
            let empty = decode(archive(NSAttributedString(string: text)))
            #expect(empty.nativePartsAvailable)
            #expect(empty.mentions?.entries == [])
            #expect(empty.mentions?.reason == nil)
        }
    }

    @Test func optionalPrimitiveFailuresDoNotChangeParts() {
        let cases: [(Any, String)] = [
            (NSNumber(value: 3), "invalid-mention-identifier"),
            (URL(string: "https://example.com/")!, "invalid-mention-identifier"),
            ("", "invalid-mention-identifier"),
            ("a\u{0}b", "invalid-mention-identifier"),
            ("a\nb", "invalid-mention-identifier"),
            ("a\u{200D}b", "invalid-mention-identifier"),
            ("\u{FEFF}alice@example.com", "invalid-mention-identifier"),
            ("alice\u{FEFF}@example.com", "invalid-mention-identifier"),
            (String(repeating: "é", count: 513), "mention-identifier-limit")
        ]
        for (value, reason) in cases {
            let data = blob("Alice", value: value)
            expectPartsUnchanged(data)
            #expect(decode(data).mentions?.entries == nil)
            #expect(decode(data).mentions?.reason == reason)
        }
        let bounded = decode(blob("Alice", value: String(repeating: "é", count: 512)))
        #expect(bounded.mentions?.entries?.first?.identifier.utf8.count == 1024)
    }

    @Test func unknownObjectsStillFailTheWholeStream() {
        let data = blob("Alice", value: Date(timeIntervalSince1970: 0))
        expectPartsUnchanged(data)
        #expect(decode(data).status == .unsupported)
        #expect(decode(data).mentions == nil)
        #expect(decode(data).nativeParts == nil)
    }

    @Test func duplicateMentionKeysRejectOnlyMentionContext() throws {
        let a = NSMutableAttributedString(string: "A")
        let other = NSAttributedString.Key("__kIMMentionConfirmedMentioX")
        a.addAttributes([mention: "alice@example.com", other: "bob@example.com", part: NSNumber(value: 0)],
                        range: .init(location: 0, length: 1))
        var data = archive(a)
        let range = try #require(data.range(of: Data(other.rawValue.utf8)))
        data.replaceSubrange(range, with: Data(mention.rawValue.utf8))
        expectPartsUnchanged(data)
        #expect(decode(data).nativePartsAvailable)
        #expect(decode(data).mentions?.entries == nil)
        #expect(decode(data).mentions?.reason == "duplicate-mention-key")
    }

    @Test func surrogateSplitsRejectOnlyMentionContext() {
        for range in [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1)] {
            let data = blob("👋", value: "alice@example.com", range: range)
            expectPartsUnchanged(data)
            #expect(decode(data).nativePartsAvailable)
            #expect(decode(data).mentions?.reason == "invalid-mention-range")
        }
        let full = decode(blob("👋e\u{301}\u{fffc}", value: "alice@example.com"))
        #expect(full.mentions?.entries?.first?.utf16Range == .init(location: 0, length: 5))
        #expect(full.text == "👋e\u{301}\u{fffc}")
    }

    @Test func zeroLengthMentionFailsEvenWhenFullTextCoverageIsValid() throws {
        var data = blob("Alice", value: "alice@example.com", withPart: false)
        let pattern = Data([0x84, 2, 0x69, 0x49, 1, 5])
        let range = try #require(data.range(of: pattern))
        data.replaceSubrange(range, with: Data([0x84, 2, 0x69, 0x49, 1, 0]))
        data.insert(contentsOf: [0x84, 2, 0x69, 0x49, 0, 5], at: data.count - 1)
        expectPartsUnchanged(data)
        #expect(decode(data).nativePartsAvailable)
        #expect(decode(data).mentions?.reason == "invalid-mention-range")
    }

    @Test func attributedRunsRemainSeparateAndCountLimitIsAtomic() {
        for count in [2, 256, 257] {
            let a = NSMutableAttributedString(string: String(repeating: "A", count: count))
            a.addAttribute(mention, value: "alice@example.com", range: .init(location: 0, length: count))
            for i in 0..<count {
                a.addAttribute(part, value: NSNumber(value: i % 2), range: .init(location: i, length: 1))
            }
            let data = archive(a)
            expectPartsUnchanged(data)
            let result = decode(data)
            #expect(result.nativePartsAvailable)
            if count <= 256 {
                #expect(result.mentions?.entries?.count == count)
                #expect(result.mentions?.entries?.map(\.utf16Range.location) == Array(0..<count))
            } else {
                #expect(result.mentions?.entries == nil)
                #expect(result.mentions?.reason == "mention-count-limit")
            }
        }
    }

    @Test func malformedLaterRunClearsEntitiesAndKeepsAttachmentIdentity() {
        let a = NSMutableAttributedString(string: "A\u{fffc}")
        a.addAttribute(part, value: NSNumber(value: 0), range: .init(location: 0, length: 1))
        a.addAttribute(part, value: NSNumber(value: 1), range: .init(location: 1, length: 1))
        a.addAttribute(NSAttributedString.Key("__kIMFileTransferGUIDAttributeName"),
                       value: "00000000-0000-4000-8000-000000000401", range: .init(location: 1, length: 1))
        a.addAttribute(mention, value: "alice@example.com", range: .init(location: 0, length: 1))
        a.addAttribute(mention, value: NSNumber(value: 3), range: .init(location: 1, length: 1))
        let data = archive(a)
        expectPartsUnchanged(data)
        #expect(decode(data).nativeParts?.last?.attachmentGUID == "00000000-0000-4000-8000-000000000401")
        #expect(decode(data).mentions?.entries == nil)
        #expect(decode(data).mentions?.reason == "invalid-mention-identifier")
    }

    @Test func identifiersRetainExactUTF8WithoutNormalization() throws {
        for identifier in ["e\u{301}@example.com", "é@example.com", "ALICE@example.com"] {
            let entry = try #require(decode(blob("Alice", value: identifier)).mentions?.entries?.first)
            #expect(entry.identifier.utf8.elementsEqual(identifier.utf8))
        }
    }

    @Test func cachedAttributeReferenceEmitsEachOriginalRange() throws {
        var data = blob("Alice", value: "alice@example.com", range: .init(location: 0, length: 5))
        let initialRun = Data([0x84, 2, 0x69, 0x49, 1, 5])
        let range = try #require(data.range(of: initialRun))
        data.replaceSubrange(range, with: Data([0x84, 2, 0x69, 0x49, 1, 2]))
        // The second run reuses attrRef 1 without another dictionary object.
        data.insert(contentsOf: [0x84, 2, 0x69, 0x49, 1, 3], at: data.count - 1)
        let parsed = decode(data)
        let result = try #require(parsed.mentions)
        expectPartsUnchanged(data)
        #expect(result.reason == nil && parsed.text == "Alice")
        #expect(result.entries?.map(\.identifier) == ["alice@example.com", "alice@example.com"])
        #expect(result.entries?.map(\.utf16Range) == [.init(location: 0, length: 2), .init(location: 2, length: 3)])
    }

    @Test func alteredMentionKeyDoesNotMatchNativeKey() {
        let value = NSMutableAttributedString(string: "Alice")
        value.addAttribute(NSAttributedString.Key("\u{FEFF}__kIMMentionConfirmedMention"),
                           value: "alice@example.com", range: .init(location: 0, length: 5))
        let data = archive(value)
        expectPartsUnchanged(data)
        #expect(decode(data).mentions?.entries == [])
    }

    @Test func malformedStreamNeverExposesPartialMentions() {
        var data = blob("Alice", value: "alice@example.com")
        data.removeLast()
        expectPartsUnchanged(data)
        #expect(!decode(data).nativePartsAvailable)
        #expect(decode(data).mentions == nil)
        #expect(NativeMessageParts.decode(nil, collectMentions: true).mentions == nil)
        let valid = blob("Alice", value: "alice@example.com")
        let limited = NativeMessageParts.decode(valid, limits: .init(maxRuns: 0), collectMentions: true)
        #expect(limited.status == .corrupt && limited.mentions == nil)
    }
}
