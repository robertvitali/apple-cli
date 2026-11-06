import Foundation
import Testing
@testable import MessagesKit

@Suite("Conversation native recipient, service and text consistency")
struct MessagesConversationNativeEnvelopeTests {
    private func request(_ recipients: [String] = ["+12125550100"],
                         text: String = "apple-cli-test création") throws -> MessagesConversationRequest {
        let bytes = try JSONSerialization.data(withJSONObject: [
            "recipients": recipients.sorted(), "initialText": text, "service": "iMessage",
            "baselineSHA256": String(repeating: "a", count: 64)
        ])
        return try JSONDecoder().decode(MessagesConversationRequest.self, from: bytes)
    }

    private func envelope(_ recipients: [String?] = ["+12125550100"], service: String? = "iMessage",
                          text: String? = "apple-cli-test création") throws -> MessagesConversationNativeEnvelope {
        try .init(recipientAddresses: recipients, service: service,
                  body: text.map { try MessagesAXBodyTextSnapshot(text: $0, characterCount: $0.utf16.count) })
    }

    @Test func completeMatchingEnvelopePasses() throws {
        try envelope().validate(request: request())
    }

    @Test func tokenOrderAndSupportedAddressFormattingDoNotChangeIdentity() throws {
        try envelope(["Alice@EXAMPLE.COM", "+1 (212) 555-0100"])
            .validate(request: request(["+12125550100", "Alice@example.com"]))
    }

    @Test(arguments: [[], [nil], ["Synthetic Display Name"], ["+12125550199"],
                      ["+12125550100", "+12125550199"],
                      ["+12125550100", "+1 (212) 555-0100"],
                      ["+12125550100", nil]] as [[String?]])
    func incompleteAmbiguousOrChangedRecipientsFail(_ addresses: [String?]) throws {
        #expect(throws: MessagesAXNavigationError.targetDrift) {
            try envelope(addresses).validate(request: request())
        }
    }

    @Test(arguments: ["2125550100", "0012125550100", "+12125550100 ext 42", "+12125550100\n",
                      "+１２１２５５５０１００", String(repeating: "a", count: 513)])
    func malformedRawAddressCannotBeNormalizedIntoAuthority(_ address: String) throws {
        #expect(throws: MessagesAXNavigationError.targetDrift) {
            try envelope([address]).validate(request: request())
        }
    }

    @Test(arguments: ["alice@example.com", "Alice+tag@example.com", "A.lice@example.com"])
    func emailAliasesAndLocalPartCaseAreNotRecipientIdentity(_ address: String) throws {
        #expect(throws: MessagesAXNavigationError.targetDrift) {
            try envelope([address]).validate(request: request(["Alice@example.com"]))
        }
    }

    @Test func duplicateTokensCannotHideAnOmittedGroupMember() throws {
        #expect(throws: MessagesAXNavigationError.targetDrift) {
            try envelope(["+12125550100", "+1 (212) 555-0100"])
                .validate(request: request(["+12125550100", "+12125550199"]))
        }
    }

    @Test(arguments: [nil, "", "SMS", "RCS", "imessage", "iMessage\n"] as [String?])
    func missingOrChangedServiceFails(_ service: String?) throws {
        #expect(throws: MessagesAXNavigationError.targetDrift) {
            try envelope(service: service).validate(request: request())
        }
    }

    @Test(arguments: [nil, "", "apple-cli-test different", "apple-cli-test cre\u{301}ation",
                      "apple-cli-test création\n"] as [String?])
    func missingChangedOrCanonicallyEquivalentTextFails(_ text: String?) throws {
        #expect(throws: MessagesAXNavigationError.targetDrift) {
            try envelope(text: text).validate(request: request())
        }
    }

    @Test func allThirtyTwoDistinctRecipientsAreSupported() throws {
        let values = (100..<132).map { "+1212555" + String(format: "%04d", $0) }
        try envelope(values.reversed().map(Optional.some)).validate(request: request(values))
    }

    @Test func oversizedRecipientObservationFails() throws {
        #expect(throws: MessagesAXNavigationError.targetDrift) {
            try envelope(Array(repeating: "+12125550100", count: 33)).validate(request: request())
        }
    }
}
