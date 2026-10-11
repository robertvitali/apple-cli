import Foundation
import Testing
@testable import MessagesKit

private let partKey = NSAttributedString.Key("__kIMMessagePartAttributeName")
private let fileKey = NSAttributedString.Key("__kIMFileTransferGUIDAttributeName")
private let mentionKey = NSAttributedString.Key("__kIMMentionConfirmedMention")
private let linkKey = NSAttributedString.Key("__kIMLinkAttributeName")

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func fail(_ message: String) throws -> Never {
    throw TestFailure(message)
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(message) }
}

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

private func oneRun(_ value: Any = NSNumber(value: 1)) -> Data {
    attributed("A", [(partKey.rawValue, value, NSRange(location: 0, length: 1))])
}

private func decoded(_ data: Data,
                     limits: NativeMessageParts.Limits = .default) -> NativeMessageParts.Decoded {
    NativeMessageParts.decode(data, limits: limits)
}

private func expectUnavailable(_ data: Data,
                               reasonContains: String,
                               _ label: String,
                               status: NativeMessageParts.Status = .corrupt,
                               limits: NativeMessageParts.Limits = .default) throws {
    let result = decoded(data, limits: limits)
    try expect(!result.nativePartsAvailable, "\(label): expected unavailable, got available")
    try expect(result.status == status, "\(label): expected \(status), got \(result.status) \(result.nativePartsReason)")
    try expect(result.nativeParts == nil, "\(label): unavailable result carried partial parts")
    try expect(result.nativePartsReason.contains(reasonContains),
               "\(label): reason \(result.nativePartsReason) did not contain \(reasonContains)")
}

private func expectDecoded(_ data: Data, _ label: String) throws -> NativeMessageParts.Decoded {
    let result = decoded(data)
    try expect(result.status == .decoded, "\(label): expected decoded, got \(result.status) \(result.nativePartsReason)")
    try expect(result.nativePartsAvailable, "\(label): expected native parts available")
    try expect(result.nativeParts?.isEmpty == false, "\(label): expected at least one native part")
    return result
}

private func findAll(_ data: Data, pattern: [UInt8]) -> [Int] {
    let bytes = Array(data)
    guard !pattern.isEmpty, bytes.count >= pattern.count else { return [] }
    var out: [Int] = []
    var index = 0
    while index + pattern.count <= bytes.count {
        if Array(bytes[index..<(index + pattern.count)]) == pattern {
            out.append(index)
        }
        index += 1
    }
    return out
}

private func replacingFirst(_ data: Data, pattern: [UInt8], with replacement: [UInt8]) throws -> Data {
    var bytes = Array(data)
    guard pattern.count == replacement.count else { throw TestFailure("replacement length mismatch") }
    guard let start = findAll(data, pattern: pattern).first else {
        throw TestFailure("pattern not found: \(pattern)")
    }
    bytes.replaceSubrange(start..<(start + pattern.count), with: replacement)
    return Data(bytes)
}

private func replacingLast(_ data: Data, pattern: [UInt8], with replacement: [UInt8]) throws -> Data {
    var bytes = Array(data)
    guard pattern.count == replacement.count else { throw TestFailure("replacement length mismatch") }
    guard let start = findAll(data, pattern: pattern).last else {
        throw TestFailure("pattern not found: \(pattern)")
    }
    bytes.replaceSubrange(start..<(start + pattern.count), with: replacement)
    return Data(bytes)
}

private func dumpBytes(_ data: Data, limit: Int = 320) -> String {
    Array(data.prefix(limit)).map { String(format: "%02x", $0) }.joined(separator: " ")
}

private func testRejectsTrailingBytesAfterValidArchive() throws {
    var junk = oneRun()
    junk.append(contentsOf: [0x00])
    let junkResult = decoded(junk)
    try expect(!junkResult.nativePartsAvailable, "trailing junk byte: expected fail closed")

    var data = oneRun()
    data.append(contentsOf: [0x86])
    try expectUnavailable(data, reasonContains: "trailing-bytes", "trailing object end")
}

private func testRejectsNSNumberOutsideSigned32RangeOrUnsupportedEncoding() throws {
    let huge = oneRun(NSNumber(value: UInt64(Int32.max) + 1))
    let hugeResult = decoded(huge)
    try expect(!hugeResult.nativePartsAvailable, "uint64 part index: expected fail closed")

    let negative64 = oneRun(NSNumber(value: Int64(Int32.min) - 1))
    let negativeResult = decoded(negative64)
    try expect(!negativeResult.nativePartsAvailable, "int64 negative part index: expected fail closed")
}

private func testRejectsWrongKindPartIndexValue() throws {
    let data = oneRun("1")
    try expectUnavailable(data, reasonContains: "wrong-kind-part-index", "string part index")
}

private func testRejectsRangeOverflowWhenRunLengthIsTooLarge() throws {
    let data = oneRun()
    let mutated = try replacingFirst(data,
                                     pattern: [0x84, 0x02, 0x69, 0x49, 0x01, 0x01],
                                     with: [0x84, 0x02, 0x69, 0x49, 0x01, 0x02])
    try expectUnavailable(mutated, reasonContains: "range-overflow", "run length larger than text")
}

private func testRejectsRangeUnderflowWhenRunLengthIsZero() throws {
    let data = oneRun()
    let mutated = try replacingFirst(data,
                                     pattern: [0x84, 0x02, 0x69, 0x49, 0x01, 0x01],
                                     with: [0x84, 0x02, 0x69, 0x49, 0x01, 0x00])
    try expectUnavailable(mutated, reasonContains: "zero-length-part-run", "run length zero")
}

private func testEnforcesGuidLimit() throws {
    let text = "\u{fffc}"
    let guid = String(repeating: "G", count: 1_025)
    let data = attributed(text, [
        (partKey.rawValue, NSNumber(value: 1), NSRange(location: 0, length: 1)),
        (fileKey.rawValue, guid, NSRange(location: 0, length: 1))
    ])
    try expectUnavailable(data, reasonContains: "guid-too-large", "guid too large")
}

private func testSkipsSupportedOptionalURLObjectWithEmbeddedTargetText() throws {
    let url = URL(string: "https://example.com/__kIMMessagePartAttributeName")!
    let data = attributed("A", [
        (partKey.rawValue, NSNumber(value: 1), NSRange(location: 0, length: 1)),
        (linkKey.rawValue, url, NSRange(location: 0, length: 1))
    ])
    let result = try expectDecoded(data, "url optional embedded target")
    try expect(result.nativeParts == [
        NativeMessageParts.NativePart(index: 1, utf16Ranges: [.init(location: 0, length: 1)], attachmentGUID: nil)
    ], "url optional embedded target: target-like bytes must not become metadata")
}

private func testRejectsUnsupportedOptionalObjectWithEmbeddedTargetText() throws {
    let data = attributed("A", [
        (partKey.rawValue, NSNumber(value: 1), NSRange(location: 0, length: 1)),
        (mentionKey.rawValue, Date(timeIntervalSince1970: 0), NSRange(location: 0, length: 1))
    ])
    try expectUnavailable(data, reasonContains: "unknown-unskippable-object", "unsupported optional object",
                          status: .unsupported)
}

private func testSharedStringLimitIsEnforced() throws {
    try expectUnavailable(oneRun(), reasonContains: "shared-string-limit", "shared string limit",
                          limits: NativeMessageParts.Limits(maxSharedStrings: 0))
}

private func testTypeGroupLimitRejectsBeforeDecode() throws {
    try expectUnavailable(oneRun(), reasonContains: "typed-group-limit", "typed group limit",
                          limits: NativeMessageParts.Limits(maxTypedGroups: 0))
}

private func testRejectsInvalidReferencedNumberTypeCode() throws {
    let data = oneRun()
    let mutated = try replacingFirst(data, pattern: [0x84, 0x84, 0x01, 0x71], with: [0x84, 0x84, 0x9f, 0x01])
    let result = decoded(mutated)
    try expect(!result.nativePartsAvailable, "dangling number typecode reference: expected fail closed")
}

private func testRejectsInvalidObjectReferenceTagBeforeDictionary() throws {
    let data = oneRun()
    let mutated = try replacingFirst(data,
                                     pattern: [0x84, 0x02, 0x69, 0x49, 0x01, 0x01, 0x92, 0x84],
                                     with: [0x84, 0x02, 0x69, 0x49, 0x01, 0x01, 0xfe, 0x84])
    try expectUnavailable(mutated, reasonContains: "reference", "invalid object reference tag before dictionary")
}

private func testArchiveGeneratedByFoundationStillDecodesAfterManySharedStringsBelowOverflow() throws {
    let attrs = NSMutableAttributedString(string: String(repeating: "A", count: 20))
    for index in 0..<20 {
        attrs.addAttribute(NSAttributedString.Key("IgnoredKey\(index)"),
                           value: "ignored\(index)",
                           range: NSRange(location: index, length: 1))
    }
    attrs.addAttribute(partKey, value: NSNumber(value: 4), range: NSRange(location: 0, length: 20))
    let result = try expectDecoded(archive(attrs), "many ignored strings")
    try expect(result.nativeParts == [
        NativeMessageParts.NativePart(index: 4, utf16Ranges: [.init(location: 0, length: 20)], attachmentGUID: nil)
    ], "many ignored strings: target part shape")
}

private func testTextUTF16LimitUsesUTF16Units() throws {
    let text = "👋🏽"
    let data = attributed(text, [(partKey.rawValue, NSNumber(value: 1), NSRange(location: 0, length: 4))])
    try expectUnavailable(data, reasonContains: "text-too-large", "text UTF16 limit",
                          limits: NativeMessageParts.Limits(maxTextUTF16Units: 3))
}

private func testRejectsIncompleteCoverageAfterNonPartZeroLengthRun() throws {
    let data = attributed("AB", [(partKey.rawValue, NSNumber(value: 1), NSRange(location: 0, length: 1))])
    let mutated = try replacingLast(data,
                                    pattern: [0x99, 0x02, 0x01, 0x92, 0x84],
                                    with: [0x99, 0x02, 0x00, 0x92, 0x84])
    try expectUnavailable(mutated, reasonContains: "range-underflow", "non-part zero-length run leaves text uncovered")
}

@Suite("Native message parts adversarial")
struct Nativemessagepartsadversarial {
    @Test func case01() throws { try testRejectsTrailingBytesAfterValidArchive() }
    @Test func case02() throws { try testRejectsNSNumberOutsideSigned32RangeOrUnsupportedEncoding() }
    @Test func case03() throws { try testRejectsWrongKindPartIndexValue() }
    @Test func case04() throws { try testRejectsRangeOverflowWhenRunLengthIsTooLarge() }
    @Test func case05() throws { try testRejectsRangeUnderflowWhenRunLengthIsZero() }
    @Test func case06() throws { try testEnforcesGuidLimit() }
    @Test func case07() throws { try testSkipsSupportedOptionalURLObjectWithEmbeddedTargetText() }
    @Test func case08() throws { try testRejectsUnsupportedOptionalObjectWithEmbeddedTargetText() }
    @Test func case09() throws { try testSharedStringLimitIsEnforced() }
    @Test func case10() throws { try testTypeGroupLimitRejectsBeforeDecode() }
    @Test func case11() throws { try testRejectsInvalidReferencedNumberTypeCode() }
    @Test func case12() throws { try testRejectsInvalidObjectReferenceTagBeforeDictionary() }
    @Test func case13() throws { try testArchiveGeneratedByFoundationStillDecodesAfterManySharedStringsBelowOverflow() }
    @Test func case14() throws { try testTextUTF16LimitUsesUTF16Units() }
    @Test func case15() throws { try testRejectsIncompleteCoverageAfterNonPartZeroLengthRun() }
}
