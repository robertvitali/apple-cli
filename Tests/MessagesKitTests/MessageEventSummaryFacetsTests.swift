import Foundation
import Testing
@testable import MessagesKit

struct MessageEventSummaryFacetsTests {
    private func plist(_ fields: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0)
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    @Test func canonicalHistoryOrdersPartNumbersAndPreservesNativeTypes() throws {
        let input = try plist(["ep": [2, 1], "rp": [0], "ec": [
            "10": [["d": -1, "t": Data([0, 255])]], "2": [["d": 1.5, "t": Data()]]],
            "unknown": "private non-key value"])
        let result = try MessageEventSummaryFacets.read(input, checkCancellation: {})
        #expect(hex(result.editedParts.digest) == "705be1047ba534f1c2bbe83fd5640cf0087573349fcda98e67e1d23b4f8d3d38")
        #expect(hex(result.history.digest) == "94e86e0523871df284d223d1495dbde904b6c25a33bba1f599d8527818da409d")
        #expect(hex(result.retractedParts.digest) == "af5570f5a1810b7af78caf4bc70a660f0df51e42baf91d4de5b2328de0e83dfc")
        #expect([result.editedParts, result.history, result.retractedParts].allSatisfy { $0.status == .available })
    }

    @Test func blobViewsRespectInputOffsetAndValidateNonKeyText() throws {
        let bytes = Data((0..<40).map(UInt8.init))
        let input = try plist(["ключ": "秘密", "ascii": "private", "t": bytes])
        let sliced = (Data([1, 2, 3]) + input).dropFirst(3)
        var fullBudget = MessageSummaryPlist.Budget(), eventBudget = fullBudget
        let full = try MessageSummaryPlist.decode(sliced, budget: &fullBudget)
        let event = try MessageSummaryPlist.decode(sliced, budget: &eventBudget, forEventCapture: true)
        guard case .dictionary(let values) = full, case .dictionary(let projected) = event else {
            Issue.record("missing dictionary"); return
        }
        #expect(values["ключ"] == .string("秘密") && values["ascii"] == .string("private"))
        #expect(projected["ключ"] == .omittedString && projected["ascii"] == .omittedString)
        #expect(projected["t"] == .data(bytes))
        #expect(fullBudget.remainingBytes == eventBudget.remainingBytes)
        #expect(fullBudget.remainingVisits == eventBudget.remainingVisits)
        var invalid = input
        let text = try #require(invalid.range(of: Data([0x79, 0xd8, 0x5b, 0xc6])))
        invalid.replaceSubrange(text, with: [0xd8, 0, 0, 0])
        #expect(try MessageEventSummaryFacets.read(invalid, checkCancellation: {}).history == .malformed)
    }

    @Test func missingMalformedAndLimitedRemainSeparate() throws {
        let empty = try MessageEventSummaryFacets.read(plist([:]), checkCancellation: {})
        #expect(empty.history == .missing)
        let input = try plist(["ep": [0, 0], "rp": [], "ec": ["01": []]])
        let result = try MessageEventSummaryFacets.read(input, checkCancellation: {})
        #expect(result.editedParts == .malformed && result.history == .malformed)
        #expect(result.retractedParts.status == .available && result.retractedParts.digest.count == 32)
        let event: [String: Any] = ["d": 1, "t": Data()]
        for count in [256, 257] {
            let many = try plist(["ec": ["0": Array(repeating: event, count: count)]])
            let output = try MessageEventSummaryFacets.read(many, checkCancellation: {})
            #expect(output.history.status == (count == 256 ? .available : .limited))
            #expect(output.editedParts == .missing)
        }
        let huge = try MessageEventSummaryFacets.read(Data(count: 1_048_577), checkCancellation: {})
        #expect(huge.history == .limited && huge.retractedParts == .limited)
    }

    @Test func cancellationAtLastFingerprintPropagates() throws {
        enum Stop: Error { case now }
        let data = try plist(["ep": [1], "ec": ["0": [["d": 1, "t": Data()]]], "rp": [2]])
        var calls = 0
        _ = try MessageEventSummaryFacets.read(data) { calls += 1 }
        var remaining = calls
        #expect(throws: Stop.now) {
            try MessageEventSummaryFacets.read(data) {
                remaining -= 1
                if remaining == 0 { throw Stop.now }
            }
        }
    }
}
