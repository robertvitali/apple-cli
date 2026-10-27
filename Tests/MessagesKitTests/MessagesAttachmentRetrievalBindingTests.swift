import AppleKit
import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesAttachmentRetrievalBindingTests {
    private func request(message: String = "synthetic-message", participant: String = "+12125550100",
                         membership: String = String(repeating: "a", count: 64)) throws -> MessagesAttachmentRetrievalRequest {
        try .init(chatRowid: 1, chatGUID: "synthetic-chat", messageRowid: 2, messageGUID: message,
                  nativePartIndex: 0, nativePartGUID: nil, selectedAttachmentGUID: "a10", participantHandles: [participant], isFromMe: false,
                  membershipCount: 1, membershipSHA256: membership)
    }

    @Test func commandAndJournalShareExactPayload() throws {
        let request = try request()
        let binding = try MessagesAttachmentRetrievalBinding(request)
        let action = try binding.resolvedAction()
        let payload = try request.workerPayloadData()
        #expect(action.command.name == "messages.attachment.retrieve")
        #expect(action.command.payload == payload)
        #expect(binding.target.operationType == .attachmentRetrieve)
        #expect(binding.target.minimumEvidence.targetLength == payload.count)
        #expect(binding.target.minimumEvidence.targetHash ==
                (try AppleAutomationJournal.targetDigest(forOpaqueIdentifier: String(decoding: payload, as: UTF8.self))))
    }

    @Test func changedIdentityOrMembershipChangesIntent() throws {
        let original = try MessagesAttachmentRetrievalBinding(request())
        for changed in [try request(message: "other-message"),
                        try request(participant: "+12125550101"),
                        try request(membership: String(repeating: "b", count: 64))] {
            let binding = try MessagesAttachmentRetrievalBinding(changed)
            #expect(binding.target.minimumEvidence.targetHash != original.target.minimumEvidence.targetHash)
        }
        let repeated = try MessagesAttachmentRetrievalBinding(request())
        #expect(repeated.target.minimumEvidence == original.target.minimumEvidence)
    }
}
