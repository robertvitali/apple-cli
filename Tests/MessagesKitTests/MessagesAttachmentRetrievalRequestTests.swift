import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesAttachmentRetrievalRequestTests {
    private func request() throws -> MessagesAttachmentRetrievalRequest {
        try .init(chatRowid: 1, chatGUID: "synthetic-chat", messageRowid: 2, messageGUID: "synthetic-message",
            nativePartIndex: 0, nativePartGUID: nil, selectedAttachmentGUID: "a10", participantHandles: ["person@example.com"], isFromMe: false,
            membershipCount: 1, membershipSHA256: String(repeating: "a", count: 64))
    }
    @Test func roundTripAndMalformedPayloads() throws {
        let data = try request().workerPayloadData()
        #expect(data.count <= 4096)
        #expect(try JSONDecoder().decode(MessagesAttachmentRetrievalRequest.self, from: data).workerPayloadData() == data)
        let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let mutations: [(String, Any)] = [("chatRowid", 0), ("messageRowid", -1), ("chatGUID", "bad\nvalue"),
            ("membershipCount", 0), ("membershipCount", 1025), ("membershipSHA256", String(repeating: "A", count: 64)),
            ("participantHandles", []), ("participantHandles", ["same@example.com", "same@example.com"]),
            ("participantHandles", (0..<32).map { String(repeating: "x", count: 480) + String($0) }),
            ("sandboxPrefix", ""), ("sandboxPrefix", "bad\nlabel"), ("sandboxPrefix", String(repeating: "x", count: 513)),
            ("nativePartIndex", -1), ("selectedAttachmentGUID", ""), ("selectedAttachmentGUID", "bad\nvalue")]
        for (key, value) in mutations {
            var object = original
            object[key] = value
            let malformed = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(MessagesAttachmentRetrievalRequest.self, from: malformed) }
        }
    }
}
