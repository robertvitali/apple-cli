import AppleKit
import Foundation
import Testing
@testable import MessagesKit

@Suite("Conversation creation worker request")
struct MessagesConversationRequestTests {
    private func fixture() throws -> ChatFixture {
        let fx = try ChatFixture()
        try fx.exec("ALTER TABLE message ADD COLUMN is_sent INTEGER;")
        return fx
    }
    private func plan(_ inputs: [String] = ["+12125550100"], text: String = "apple-cli-test initial",
                      sandbox: Bool = false) throws -> MessagesConversationPlan.Plan {
        let result = try MessagesConversationPlan.build(inputs: inputs, message: text, service: "imessage",
            gate: .init(willExecute: true, sandboxActive: sandbox, sandboxPrefix: "apple-cli-test",
                        allowedRecipients: ["+12125550100"]), deadline: .millisecondsFromNow(5000), loadContacts: { [] })
        guard case .ready(let plan) = result else { throw MessagesConversationStore.Failure.invalidRequest }
        return plan
    }
    private func baseline(_ fx: ChatFixture, _ recipients: [String] = ["+12125550100"]) throws -> MessagesConversationBaseline.Snapshot {
        try MessagesConversationBaseline.read(databasePath: fx.path,
            recipients: recipients.map(MessagesConversationAddress.parse), deadline: .millisecondsFromNow(5000))
    }

    @Test func roundTripBindsExactTextRecipientsAndBaseline() throws {
        let fx = try fixture(), before = try baseline(fx)
        let text = "apple-cli-test line\nsecond e\u{301}"
        let request = try MessagesConversationRequest(plan: plan(text: text), baseline: before)
        let bytes = try request.workerPayloadData()
        let decoded = try MessagesConversationRequest.decodeWorkerPayload(bytes)
        #expect(decoded.initialText.utf8.elementsEqual(text.utf8))
        #expect(decoded.recipients == ["+12125550100"])
        #expect(decoded.service == "iMessage")
        #expect(try decoded.matches(before))
        #expect(try decoded.workerPayloadData() == bytes)
        #expect(bytes.count <= 4096)
    }

    @Test func watermarksBindUnrelatedConcurrentChangesBeforeSend() throws {
        let fx = try fixture(), before = try baseline(fx)
        let request = try MessagesConversationRequest(plan: plan(), baseline: before)
        try fx.exec("INSERT INTO message(ROWID,guid) VALUES(100,'synthetic-concurrent');")
        #expect(try !request.matches(baseline(fx)))
        #expect(try request.matches(before))
    }

    @Test func GUIDFingerprintPreservesUnicodeBytes() throws {
        let fx = try fixture()
        try fx.exec("UPDATE chat SET guid=CAST(X'c3a9' AS TEXT) WHERE ROWID=3;")
        let before = try baseline(fx)
        let request = try MessagesConversationRequest(plan: plan(), baseline: before)
        try fx.exec("UPDATE chat SET guid=CAST(X'65cc81' AS TEXT) WHERE ROWID=3;")
        #expect(try !request.matches(baseline(fx)))
        #expect(try request.matches(before))
    }

    @Test func entireMatchingSetIsBoundNotOnlyFirstDM() throws {
        let fx = try fixture()
        try fx.exec("""
            INSERT INTO chat(ROWID,guid,style,service_name) VALUES(50,'synthetic-second',45,'iMessage');
            INSERT INTO chat_handle_join VALUES(50,1);
            """)
        let request = try MessagesConversationRequest(plan: plan(), baseline: baseline(fx))
        try fx.exec("UPDATE chat SET guid='synthetic-replaced-second' WHERE ROWID=50;")
        #expect(try !request.matches(baseline(fx)))
    }

    @Test func mismatchedPlanAndBaselineRefuse() throws {
        let fx = try fixture()
        #expect(throws: (any Error).self) {
            try MessagesConversationRequest(plan: plan(), baseline: baseline(fx, ["+12125550199"]))
        }
    }

    @Test func groupAddressesHaveOneCanonicalOrdering() throws {
        let fx = try fixture()
        let recipients = ["+12125550102", "+12125550101"]
        let request = try MessagesConversationRequest(plan: plan(recipients), baseline: baseline(fx, recipients))
        #expect(request.recipients == recipients.sorted())
        #expect(try request.matches(baseline(fx, Array(recipients.reversed()))))
    }

    @Test func sandboxLabelIsRetainedWithoutContactProvenance() throws {
        let fx = try fixture()
        let request = try MessagesConversationRequest(plan: plan(sandbox: true), baseline: baseline(fx))
        #expect(request.sandboxPrefix == "apple-cli-test")
        let bytes = try request.workerPayloadData()
        let object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(object.keys) == ["recipients", "initialText", "service", "baselineSHA256", "sandboxPrefix"])
        #expect(!String(decoding: bytes, as: UTF8.self).contains("iMessage;-;"))
    }

    @Test func decoderRevalidatesEveryUntrustedField() throws {
        let fx = try fixture()
        let bytes = try MessagesConversationRequest(plan: plan(), baseline: baseline(fx)).workerPayloadData()
        let original = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let invalid: [(String, Any)] = [
            ("recipients", [] as [String]), ("recipients", ["+12125550100", "+12125550100"]),
            ("recipients", ["+1 (212) 555-0100"]), ("recipients", ["2125550100"]),
            ("recipients", ["Alice@EXAMPLE.COM"]), ("recipients", ["+12125550102", "+12125550101"]),
            ("initialText", ""), ("initialText", " \n\t "), ("initialText", "x\0y"),
            ("initialText", String(repeating: "x", count: 2049)),
            ("service", "SMS"), ("service", 1),
            ("baselineSHA256", String(repeating: "A", count: 64)), ("baselineSHA256", "abc"),
            ("sandboxPrefix", ""), ("sandboxPrefix", "unmatched"), ("sandboxPrefix", "apple-cli-test\n"),
            ("unexpected", "value"),
        ]
        for (key, value) in invalid {
            var object = original; object[key] = value
            let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            #expect(throws: (any Error).self) { try JSONDecoder().decode(MessagesConversationRequest.self, from: changed) }
        }
    }

    @Test func sandboxGroupPayloadCannotBeConstructedByDecoder() throws {
        let fx = try fixture(), recipients = ["+12125550101", "+12125550102"]
        let request = try MessagesConversationRequest(plan: plan(recipients), baseline: baseline(fx, recipients))
        var object = try #require(try JSONSerialization.jsonObject(with: request.workerPayloadData()) as? [String: Any])
        object["sandboxPrefix"] = "apple-cli-test"
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MessagesConversationRequest.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func escapedPayloadLimitAppliesBeforeWorkerHandoff() throws {
        let fx = try fixture()
        #expect(throws: (any Error).self) {
            try MessagesConversationRequest(plan: plan(text: String(repeating: "\\", count: 2048)), baseline: baseline(fx))
        }
        #expect(throws: (any Error).self) {
            try MessagesConversationRequest.decodeWorkerPayload(Data(repeating: 32, count: 4097))
        }
    }

    @Test func wireDecoderRequiresCanonicalBytesAndRejectsDuplicateKeys() throws {
        let fx = try fixture()
        let bytes = try MessagesConversationRequest(plan: plan(), baseline: baseline(fx)).workerPayloadData()
        #expect(throws: (any Error).self) { try MessagesConversationRequest.decodeWorkerPayload(Data([32]) + bytes) }
        var duplicate = Data("{\"service\":\"SMS\",".utf8)
        duplicate.append(bytes.dropFirst())
        #expect(throws: (any Error).self) { try MessagesConversationRequest.decodeWorkerPayload(duplicate) }
        #expect(try MessagesConversationRequest.decodeWorkerPayload(bytes).workerPayloadData() == bytes)
    }
}
