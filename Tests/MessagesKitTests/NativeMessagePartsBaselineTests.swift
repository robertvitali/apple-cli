import Foundation
import Testing
@testable import MessagesKit

private let partKey = NSAttributedString.Key("__kIMMessagePartAttributeName")
private let fileKey = NSAttributedString.Key("__kIMFileTransferGUIDAttributeName")
private let mentionKey = NSAttributedString.Key("__kIMMentionConfirmedMention")
private let linkKey = NSAttributedString.Key("__kIMLinkAttributeName")

private func archive(_ attributed: NSAttributedString) -> Data {
    NSArchiver.archivedData(withRootObject: attributed)
}

private func attributed(_ text: String, _ attributes: [(String, Any, NSRange)]) -> Data {
    let value = NSMutableAttributedString(string: text)
    for (key, object, range) in attributes {
        value.addAttribute(NSAttributedString.Key(key), value: object, range: range)
    }
    return archive(value)
}

private func utf16Range(_ text: String, _ needle: String) -> NSRange {
    let ns = text as NSString
    let range = ns.range(of: needle)
    precondition(range.location != NSNotFound)
    return range
}

private func assert(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(message) }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func expectAvailable(_ data: Data, _ label: String) throws -> NativeMessageParts.Decoded {
    let decoded = NativeMessageParts.decode(data)
    try assert(decoded.nativePartsAvailable, "\(label): expected available, got \(decoded.nativePartsReason)")
    guard let value = decoded.text else { throw TestFailure("\(label): expected text") }
    try assert(!value.isEmpty || decoded.nativePartsReason == "empty-known",
               "\(label): empty text should carry empty-known reason")
    return decoded
}

private func expectUnavailable(_ data: Data, _ reasonContains: String, _ label: String,
                               status: NativeMessageParts.Status = .corrupt,
                               limits: NativeMessageParts.Limits = .default) throws {
    let decoded = NativeMessageParts.decode(data, limits: limits)
    try assert(!decoded.nativePartsAvailable, "\(label): expected unavailable")
    try assert(decoded.status == status,
               "\(label): expected status \(status), got \(decoded.status) reason \(decoded.nativePartsReason)")
    try assert(decoded.nativeParts == nil, "\(label): unavailable result must not carry partial parts")
    try assert(decoded.nativePartsReason.contains(reasonContains),
               "\(label): reason \(decoded.nativePartsReason) did not contain \(reasonContains)")
}

private func oneRunArchive() -> Data {
    attributed("A", [(partKey.rawValue, NSNumber(value: 1), NSRange(location: 0, length: 1))])
}

private func replacingFirst(_ data: Data, pattern: [UInt8], with replacement: [UInt8]) throws -> Data {
    var bytes = Array(data)
    guard pattern.count == replacement.count else { throw TestFailure("replacement length mismatch") }
    guard let start = bytes.indices.first(where: { index in
        index + pattern.count <= bytes.count && Array(bytes[index..<(index + pattern.count)]) == pattern
    }) else {
        throw TestFailure("pattern not found")
    }
    bytes.replaceSubrange(start..<(start + pattern.count), with: replacement)
    return Data(bytes)
}

private func testSinglePartZero() throws {
    let data = attributed("Alice", [(partKey.rawValue, NSNumber(value: 0), NSRange(location: 0, length: 5))])
    let decoded = try expectAvailable(data, "single part")
    try assert(decoded.status == .decoded, "single part: status")
    try assert(decoded.text == "Alice", "single part: decoded text")
    try assert(decoded.nativeParts == [
        NativeMessageParts.NativePart(index: 0, utf16Ranges: [.init(location: 0, length: 5)], attachmentGUID: nil)
    ], "single part: native part shape")
}

private func testObjectReplacementAttachment() throws {
    let text = "Look \u{fffc} now"
    let range = utf16Range(text, "\u{fffc}")
    let guid = "00000000-0000-4000-8000-000000000201"
    let data = attributed(text, [
        (partKey.rawValue, NSNumber(value: 1), range),
        (fileKey.rawValue, guid, range)
    ])
    let decoded = try expectAvailable(data, "attachment")
    try assert(decoded.nativeParts == [
        NativeMessageParts.NativePart(index: 1, utf16Ranges: [.init(location: 5, length: 1)], attachmentGUID: guid)
    ], "attachment: part and guid")
}

private func testEmojiUTF16Ranges() throws {
    let text = "Hi 👋🏽 Bob"
    let range = utf16Range(text, "👋🏽")
    let data = attributed(text, [(partKey.rawValue, NSNumber(value: 2), range)])
    let decoded = try expectAvailable(data, "emoji")
    try assert(decoded.nativeParts?.first?.utf16Ranges == [.init(location: 3, length: 4)],
               "emoji: range must be UTF-16")
}

private func testMultipartAndRepeatedRuns() throws {
    let text = "Alice plain Alice"
    let left = utf16Range(text, "Alice")
    let right = NSRange(location: 12, length: 5)
    let data = attributed(text, [
        (partKey.rawValue, NSNumber(value: Int16(5)), left),
        (partKey.rawValue, NSNumber(value: Int32(6)), NSRange(location: 6, length: 5)),
        (partKey.rawValue, NSNumber(value: Int(5)), right)
    ])
    let decoded = try expectAvailable(data, "multipart")
    try assert(decoded.nativeParts == [
        NativeMessageParts.NativePart(index: 5, utf16Ranges: [.init(location: 0, length: 5), .init(location: 12, length: 5)], attachmentGUID: nil),
        NativeMessageParts.NativePart(index: 6, utf16Ranges: [.init(location: 6, length: 5)], attachmentGUID: nil)
    ], "multipart: grouped runs")
}

private func testSameIndexDifferentGUIDsFailClosed() throws {
    let text = "\u{fffc} \u{fffc}"
    let first = NSRange(location: 0, length: 1)
    let second = NSRange(location: 2, length: 1)
    let data = attributed(text, [
        (partKey.rawValue, NSNumber(value: 7), first),
        (fileKey.rawValue, "00000000-0000-4000-8000-000000000301", first),
        (partKey.rawValue, NSNumber(value: 7), second),
        (fileKey.rawValue, "00000000-0000-4000-8000-000000000302", second)
    ])
    try expectUnavailable(data, "conflicting-attachment-guid", "same index guid conflict")
}

private func testLongRunAndNonTargetAttributes() throws {
    let text = String(repeating: "A", count: 40_000)
    let data = attributed(text, [
        (partKey.rawValue, NSNumber(value: 3), NSRange(location: 0, length: 40_000)),
        (mentionKey.rawValue, "alice@example.com", NSRange(location: 0, length: 5)),
        (linkKey.rawValue, URL(string: "https://example.com/item")!, NSRange(location: 6, length: 5))
    ])
    let decoded = try expectAvailable(data, "long/non-target")
    try assert(decoded.nativeParts == [
        NativeMessageParts.NativePart(index: 3, utf16Ranges: [.init(location: 0, length: 40_000)], attachmentGUID: nil)
    ], "long/non-target: target part survives; got \(String(describing: decoded.nativeParts))")
}

private func testNoTargetMetadataIsEmptyKnown() throws {
    let decoded = NativeMessageParts.decode(archive(NSAttributedString(string: "plain")))
    try assert(decoded.nativePartsAvailable, "plain: should be available, got \(decoded.nativePartsReason)")
    try assert(decoded.status == .noNativeKeys, "plain: status")
    try assert(decoded.nativeParts == [], "plain: no parts")
    try assert(decoded.nativePartsReason == "empty-known", "plain: reason")
}

private func testUnsupportedKeyedArchive() throws {
    let data = try NSKeyedArchiver.archivedData(withRootObject: NSAttributedString(string: "plain"),
                                                requiringSecureCoding: false)
    try expectUnavailable(data, "unsupported-header", "keyed archive", status: .unsupported)
}

private func testAbsentBlob() throws {
    let decoded = NativeMessageParts.decode(nil)
    try assert(!decoded.nativePartsAvailable, "absent: unavailable")
    try assert(decoded.status == .absentBlob, "absent: status")
    try assert(decoded.nativePartsReason == "absent-blob", "absent: reason")
    try assert(decoded.nativeParts == nil, "absent: no parts")
}

private func testMalformedInputsFailClosed() throws {
    try expectUnavailable(Data([0x04, 0x0b, 0x73]), "truncated", "truncated header")
    try expectUnavailable(Data(repeating: 0, count: 2 * 1024 * 1024), "blob-too-large", "oversized")
    try expectUnavailable(oneRunArchive(), "text-too-large", "text limit",
                          limits: NativeMessageParts.Limits(maxTextUTF16Units: 0))
    let negative = attributed("bad", [(partKey.rawValue, NSNumber(value: -1), NSRange(location: 0, length: 3))])
    try expectUnavailable(negative, "negative-part-index", "negative part")
    var truncated = attributed("ok", [(partKey.rawValue, NSNumber(value: 1), NSRange(location: 0, length: 2))])
    truncated.removeLast(3)
    try expectUnavailable(truncated, "truncated", "truncated body")
    let lowLimits = NativeMessageParts.Limits(maxRuns: 0)
    let oneRun = oneRunArchive()
    try expectUnavailable(oneRun, "run-limit", "run limit", limits: lowLimits)
    try expectUnavailable(oneRun, "dictionary-entry-limit", "dictionary entry limit",
                          limits: NativeMessageParts.Limits(maxDictEntries: 0))
    try expectUnavailable(oneRun, "dictionary-total-entry-limit", "dictionary total entry limit",
                          limits: NativeMessageParts.Limits(maxTotalDictEntries: 0))
    try expectUnavailable(oneRun, "object-limit", "object reference limit",
                          limits: NativeMessageParts.Limits(maxObjects: 1))
    let keyBytes = Array("__kIMMessagePartAttributeName".utf8)
    let dangling = try replacingFirst(oneRun, pattern: [0x92, 0x84, 0x98, 0x98, UInt8(keyBytes.count)] + keyBytes,
                                      with: [0x92, 0xfe, 0x98, 0x98, UInt8(keyBytes.count)] + keyBytes)
    try expectUnavailable(dangling, "dangling-reference", "dangling reference")
    var truncatedTail = oneRun
    truncatedTail.removeLast(64)
    try expectUnavailable(truncatedTail, "truncated-string", "truncated tail")
}

private func testHighReferenceIndicesDecodeStructurally() throws {
    let text = "A"
    var attributes: [(String, Any, NSRange)] = []
    for index in 0..<320 {
        attributes.append(("IgnoredSyntheticKey\(index)", "ignoredSyntheticValue\(index)", NSRange(location: 0, length: 1)))
    }
    attributes.append((partKey.rawValue, NSNumber(value: 9), NSRange(location: 0, length: 1)))
    let decoded = try expectAvailable(attributed(text, attributes), "high refs")
    try assert(decoded.nativeParts == [
        NativeMessageParts.NativePart(index: 9, utf16Ranges: [.init(location: 0, length: 1)], attachmentGUID: nil)
    ], "high refs: target part survives")
}

private func testOrphanGUIDFailsClosed() throws {
    let data = attributed("A", [(fileKey.rawValue, "00000000-0000-4000-8000-000000000401", NSRange(location: 0, length: 1))])
    try expectUnavailable(data, "orphan-attachment-guid", "orphan guid")
}

private func testWrongSuperclassFailsClosed() throws {
    let data = oneRunArchive()
    var pattern: [UInt8] = [0x84, 0x84, 0x08]
    pattern += Array("NSString".utf8)
    pattern += [0x01, 0x95, 0x84, 0x01, 0x2b]
    var replacement = pattern
    replacement[replacement.count - 4] = 0x94
    let mutated = try replacingFirst(data, pattern: pattern, with: replacement)
    try expectUnavailable(mutated, "unsupported-string-class", "wrong NSString superclass", status: .unsupported)
}

private func testMixedNilAndNonNilGUIDFailsClosed() throws {
    let text = "A B"
    let data = attributed(text, [
        (partKey.rawValue, NSNumber(value: 10), NSRange(location: 0, length: 1)),
        (partKey.rawValue, NSNumber(value: 10), NSRange(location: 2, length: 1)),
        (fileKey.rawValue, "00000000-0000-4000-8000-000000000402", NSRange(location: 2, length: 1))
    ])
    try expectUnavailable(data, "conflicting-attachment-guid", "mixed nil and nonnil guid")
}

private func testEveryRunRequiresTypedGroup() throws {
    let text = "A B"
    let data = attributed(text, [
        (partKey.rawValue, NSNumber(value: 1), NSRange(location: 0, length: 1)),
        (partKey.rawValue, NSNumber(value: 2), NSRange(location: 2, length: 1))
    ])
    let mutated = try replacingFirst(data, pattern: [0x99, 0x02, 0x01], with: [0x01, 0x02, 0x01])
    try expectUnavailable(mutated, "dangling-string-reference", "missing second run typegroup")
}

private func replacingFirstByteAfter(_ data: Data, pattern: [UInt8], byteOffset: Int, with replacement: UInt8) throws -> Data {
    var bytes = Array(data)
    guard let start = bytes.indices.first(where: { index in
        index + pattern.count <= bytes.count && Array(bytes[index..<(index + pattern.count)]) == pattern
    }) else {
        throw TestFailure("pattern not found")
    }
    let target = start + byteOffset
    guard target < bytes.count else { throw TestFailure("replacement target out of bounds") }
    bytes[target] = replacement
    return Data(bytes)
}

private func testAcceptedClassVersionMutationsFailClosed() throws {
    let part = oneRunArchive()
    var nsStringPattern: [UInt8] = [0x84, 0x84, 0x08]
    nsStringPattern += Array("NSString".utf8)
    nsStringPattern += [0x01]
    try expectUnavailable(try replacingFirstByteAfter(part, pattern: nsStringPattern, byteOffset: nsStringPattern.count - 1, with: 0x02),
                          "unsupported-string-class", "NSString version", status: .unsupported)

    var dictionaryPattern: [UInt8] = [0x84, 0x84, 0x0c]
    dictionaryPattern += Array("NSDictionary".utf8)
    dictionaryPattern += [0x00]
    try expectUnavailable(try replacingFirstByteAfter(part, pattern: dictionaryPattern, byteOffset: dictionaryPattern.count - 1, with: 0x01),
                          "unknown-unskippable-object", "NSDictionary version", status: .unsupported)

    var numberPattern: [UInt8] = [0x84, 0x84, 0x08]
    numberPattern += Array("NSNumber".utf8)
    numberPattern += [0x00]
    try expectUnavailable(try replacingFirstByteAfter(part, pattern: numberPattern, byteOffset: numberPattern.count - 1, with: 0x01),
                          "unknown-unskippable-object", "NSNumber version", status: .unsupported)

    var valuePattern: [UInt8] = [0x84, 0x84, 0x07]
    valuePattern += Array("NSValue".utf8)
    valuePattern += [0x00]
    try expectUnavailable(try replacingFirstByteAfter(part, pattern: valuePattern, byteOffset: valuePattern.count - 1, with: 0x01),
                          "unknown-unskippable-object", "NSValue version", status: .unsupported)

    let linked = attributed("A", [
        (partKey.rawValue, NSNumber(value: 1), NSRange(location: 0, length: 1)),
        (linkKey.rawValue, URL(string: "https://example.com/item")!, NSRange(location: 0, length: 1))
    ])
    var urlPattern: [UInt8] = [0x84, 0x84, 0x05]
    urlPattern += Array("NSURL".utf8)
    urlPattern += [0x00]
    try expectUnavailable(try replacingFirstByteAfter(linked, pattern: urlPattern, byteOffset: urlPattern.count - 1, with: 0x01),
                          "unknown-unskippable-object", "NSURL version", status: .unsupported)
}

private func testIgnoredAttributeCannotReferenceRootObject() throws {
    let data = attributed("A", [
        (partKey.rawValue, NSNumber(value: 1), NSRange(location: 0, length: 1)),
        ("IgnoredRootReference", "safe", NSRange(location: 0, length: 1))
    ])
    let mutated = try replacingFirst(data, pattern: [0x92, 0x84, 0x98, 0x98, 0x04] + Array("safe".utf8),
                                     with: [0x92, 0x92, 0x98, 0x98, 0x04] + Array("safe".utf8))
    try expectUnavailable(mutated, "reference-cycle", "ignored attr root ref")
}


private func testZeroLengthPartRunFailsClosed() throws {
    let data = attributed("AB", [
        (partKey.rawValue, NSNumber(value: 11), NSRange(location: 0, length: 1)),
        (partKey.rawValue, NSNumber(value: 11), NSRange(location: 1, length: 1)),
        ("IgnoredSplitter", "x", NSRange(location: 1, length: 1))
    ])
    let zeroFirstRun = try replacingFirst(data,
                                          pattern: [0x84, 0x02, 0x69, 0x49, 0x01, 0x01, 0x92],
                                          with: [0x84, 0x02, 0x69, 0x49, 0x01, 0x00, 0x92])
    let laterCoveringRun = try replacingFirst(zeroFirstRun,
                                              pattern: [0x99, 0x02, 0x01, 0x92, 0x84],
                                              with: [0x99, 0x02, 0x02, 0x92, 0x84])
    try expectUnavailable(laterCoveringRun, "zero-length-part-run", "zero-length part with later covering run")
}

private func testEmptyAttachmentGUIDFailsClosed() throws {
    let data = attributed("A", [
        (partKey.rawValue, NSNumber(value: 12), NSRange(location: 0, length: 1)),
        (fileKey.rawValue, "", NSRange(location: 0, length: 1))
    ])
    try expectUnavailable(data, "empty-attachment-guid", "empty attachment guid")
}

@Suite("Native message parts baseline")
struct Nativemessagepartsbaseline {
    @Test func case01() throws { try testSinglePartZero() }
    @Test func case02() throws { try testObjectReplacementAttachment() }
    @Test func case03() throws { try testEmojiUTF16Ranges() }
    @Test func case04() throws { try testMultipartAndRepeatedRuns() }
    @Test func case05() throws { try testSameIndexDifferentGUIDsFailClosed() }
    @Test func case06() throws { try testLongRunAndNonTargetAttributes() }
    @Test func case07() throws { try testNoTargetMetadataIsEmptyKnown() }
    @Test func case08() throws { try testUnsupportedKeyedArchive() }
    @Test func case09() throws { try testAbsentBlob() }
    @Test func case10() throws { try testMalformedInputsFailClosed() }
    @Test func case11() throws { try testHighReferenceIndicesDecodeStructurally() }
    @Test func case12() throws { try testOrphanGUIDFailsClosed() }
    @Test func case13() throws { try testWrongSuperclassFailsClosed() }
    @Test func case14() throws { try testMixedNilAndNonNilGUIDFailsClosed() }
    @Test func case15() throws { try testEveryRunRequiresTypedGroup() }
    @Test func case16() throws { try testAcceptedClassVersionMutationsFailClosed() }
    @Test func case17() throws { try testIgnoredAttributeCannotReferenceRootObject() }
    @Test func case18() throws { try testZeroLengthPartRunFailsClosed() }
    @Test func case19() throws { try testEmptyAttachmentGUIDFailsClosed() }
}
