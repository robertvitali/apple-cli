import AppleKit
import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesEditRequestTests {
    private func request(replacement: String = "new text", hash: String = String(repeating: "a", count: 64)) throws -> MessagesEditRequest {
        try MessagesEditRequest(chatRowid: 3, chatGUID: "synthetic-chat", messageRowid: 60,
            messageGUID: "synthetic-message", nativePartIndex: 0, baselineSHA256: hash,
            replacement: replacement, sandboxPrefix: "apple-cli-test")
    }

    @Test func roundTripPreservesReplacementBytesAndBinding() throws {
        let value = try request(replacement: "line one\nline two e\u{301}")
        let payload = try value.workerPayloadData()
        let decoded = try JSONDecoder().decode(MessagesEditRequest.self, from: payload)
        #expect(decoded.replacement.utf8.elementsEqual(value.replacement.utf8))
        #expect(try decoded.workerPayloadData() == payload)
        let binding = try MessagesEditBinding(value)
        #expect(binding.target.operationType == .editMessage)
        #expect(binding.target.minimumEvidence.targetLength == payload.count)
        #expect(try MessagesEditBinding(decoded).target.minimumEvidence == binding.target.minimumEvidence)
    }

    @Test func replacementAndBaselineBothChangeJournalEvidence() throws {
        let a = try MessagesEditBinding(request())
        let b = try MessagesEditBinding(request(replacement: "different"))
        let c = try MessagesEditBinding(request(hash: String(repeating: "b", count: 64)))
        #expect(a.target.minimumEvidence != b.target.minimumEvidence)
        #expect(a.target.minimumEvidence != c.target.minimumEvidence)
    }

    @Test func decoderRevalidatesUntrustedPayload() throws {
        let data = try request().workerPayloadData()
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["messageRowid"] = -1
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MessagesEditRequest.self, from: JSONSerialization.data(withJSONObject: object))
        }
        #expect(throws: (any Error).self) { try request(hash: String(repeating: "A", count: 64)) }
        #expect(throws: (any Error).self) { try request(replacement: "") }
        #expect(throws: (any Error).self) { try request(replacement: String(repeating: "x", count: 4096)) }
    }
}
