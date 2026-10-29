import Foundation
import Testing
@testable import MessagesKit

@Suite("Native message parts opaque data")
struct NativeMessagePartsDataTests {
    private func fixture(_ count: Int, mutable: Bool, nativeKey: String? = nil) -> Data {
        let text = NSMutableAttributedString(string: "Synthetic")
        let payload = Data((0..<count).map { UInt8($0 % 256) })
        let value: NSData = mutable ? NSMutableData(data: payload) : NSData(data: payload)
        let range = NSRange(location: 0, length: 9)
        text.addAttribute(NSAttributedString.Key("__kIMMessagePartAttributeName"),
                          value: NSNumber(value: 0), range: range)
        text.addAttribute(NSAttributedString.Key(nativeKey ?? "SyntheticOpaqueMetadata"),
                          value: value, range: range)
        return NSArchiver.archivedData(withRootObject: text)
    }

    private func offset(of token: [UInt8], in bytes: [UInt8]) throws -> Int {
        try #require(bytes.indices.first {
            $0 + token.count <= bytes.count && Array(bytes[$0..<($0 + token.count)]) == token
        })
    }

    private func expectRefusal(_ data: Data) {
        let result = NativeMessageParts.decode(data, requireExactText: true)
        #expect(!result.nativePartsAvailable)
        #expect(result.nativeParts == nil)
    }

    @Test(arguments: [0, 1, 3, 127, 128, 256, 32768, 262145], [false, true])
    func opaqueDataPreservesExactParts(count: Int, mutable: Bool) {
        let result = NativeMessageParts.decode(fixture(count, mutable: mutable), requireExactText: true)
        #expect(result.status == .decoded)
        #expect(result.nativePartsAvailable)
        #expect(result.text == "Synthetic")
        #expect(result.nativeParts == [.init(index: 0,
            utf16Ranges: [.init(location: 0, length: 9)], attachmentGUID: nil)])
    }

    @Test(arguments: ["__kIMMessagePartAttributeName", "__kIMFileTransferGUIDAttributeName"], [false, true])
    func dataCannotSupplyNativeIdentity(key: String, mutable: Bool) {
        expectRefusal(fixture(3, mutable: mutable, nativeKey: key))
    }

    @Test(arguments: ["[2c]", "[4c]", "[3i]"])
    func mismatchedArrayTypeRefuses(replacement: String) throws {
        var bytes = Array(fixture(3, mutable: true))
        let start = try offset(of: Array("[3c]".utf8), in: bytes)
        bytes.replaceSubrange(start..<(start + 4), with: replacement.utf8)
        expectRefusal(Data(bytes))
    }

    @Test func truncatedPayloadRefuses() throws {
        let bytes = Array(fixture(3, mutable: true))
        let start = try offset(of: Array("[3c]".utf8), in: bytes)
        for length in start..<(start + 8) { expectRefusal(Data(bytes.prefix(length))) }
    }

    @Test(arguments: ["NSData", "NSMutableData"])
    func unknownClassVersionRefuses(className: String) throws {
        var bytes = Array(fixture(3, mutable: true))
        let token = Array(className.utf8)
        let start = try offset(of: token, in: bytes)
        #expect(bytes[start + token.count] == 0)
        bytes[start + token.count] = 1
        expectRefusal(Data(bytes))
    }

    @Test func sharedOpaqueDataReferencesPreserveParts() {
        let text = NSMutableAttributedString(string: "Synthetic")
        let range = NSRange(location: 0, length: 9)
        let data = NSMutableData(data: Data([1, 2, 3]))
        text.addAttribute(NSAttributedString.Key("__kIMMessagePartAttributeName"),
                          value: NSNumber(value: 0), range: range)
        text.addAttribute(NSAttributedString.Key("SyntheticOpaqueOne"), value: data, range: range)
        text.addAttribute(NSAttributedString.Key("SyntheticOpaqueTwo"), value: data, range: range)
        let result = NativeMessageParts.decode(NSArchiver.archivedData(withRootObject: text),
                                               requireExactText: true)
        #expect(result.nativePartsAvailable)
        #expect(result.text == "Synthetic")
        #expect(result.nativeParts?.map(\.index) == [0])
    }

    @Test func declaredDataLengthRemainsBounded() throws {
        let original = Array(fixture(3, mutable: true))
        let start = try offset(of: Array("[3c]".utf8), in: original)
        // A newly declared four-byte type string is preceded by its marker and
        // length, then the encoded data byte count.
        #expect(Array(original[(start - 3)..<start]) == [3, 0x84, 4])
        for count in [UInt8(0), 4, 127] {
            var bytes = original
            bytes[start - 3] = count
            expectRefusal(Data(bytes))
        }
        var huge = original
        huge.replaceSubrange((start - 3)..<(start - 2), with: [0x82, 0xff, 0xff, 0xff, 0x7f])
        expectRefusal(Data(huge))
    }

}
