import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesUndoSendRevalidationTests {
    private func snapshot(change: String = "", text: String = "hello", guid: String = "attachment-a") throws -> MessagesUndoSendTargetSnapshot.Snapshot {
        let identity = MessagesUndoSendIdentity.Snapshot(chatRowid: 3, chatGUID: "synthetic-chat",
            chatStyle: 45, messageRowid: change == "message" ? 61 : 60,
            messageGUID: "synthetic-message", sentDateRaw: 800_000_000_000_000_000,
            participantHandles: [change == "participant" ? "other@example.com" : "test@example.com"])
        let observation = MessagesUndoSendObservation.Snapshot(identity: identity,
            isFromMe: .value(1), isSent: .value(1), error: .value(0),
            dateEdited: .value(change == "edited" ? 1 : 0), dateRetracted: .value(0),
            serviceUTF8: .value(Data("iMessage".utf8)), textUTF8: .value(Data(text.utf8)),
            attributedBody: .value(Data(change == "body" ? [2] : [1])),
            summaryInfo: change == "summary" ? .value(Data()) : .null)
        let part = NativeMessageParts.NativePart(index: change == "index" ? 2 : 1,
            utf16Ranges: [.init(location: change == "range" ? 1 : 0, length: 1)],
            attachmentGUID: change == "part-guid" ? "other" : guid)
        let other = NativeMessageParts.NativePart(index: 3,
            utf16Ranges: [.init(location: 2, length: 1)], attachmentGUID: nil)
        let mapping = change == "mapping" ? [part, other] : [part]
        let resolved = MessagesUndoSendPart.Snapshot(observation: observation, fullText: text,
            nativeParts: mapping, selectedPart: part,
            selectedTextFragments: [change == "fragment" ? "other" : text])
        let attachment = try #require(MessagesAttachmentRetrievalState.Identity(rowid: change == "attachment" ? 11 : 10, guid: guid))
        return .init(part: resolved, attachments: change == "membership" ? [] : [attachment],
                     selectedAttachment: change == "selected-attachment" ? nil : attachment)
    }

    @Test func identicalEvidenceMatches() throws {
        #expect(MessagesUndoSendRevalidation.matches(try snapshot(), try snapshot()))
    }

    @Test(arguments: ["message", "participant", "edited", "body", "summary", "index", "range",
                      "part-guid", "mapping", "fragment", "attachment", "membership", "selected-attachment"])
    func refusesChangedEvidence(_ change: String) throws {
        #expect(!MessagesUndoSendRevalidation.matches(try snapshot(), try snapshot(change: change)))
    }

    @Test func textComparisonUsesExactBytes() throws {
        #expect(!MessagesUndoSendRevalidation.matches(try snapshot(text: "é"), try snapshot(text: "e\u{301}")))
    }

    @Test func attachmentGUIDComparisonUsesExactBytes() throws {
        #expect(!MessagesUndoSendRevalidation.matches(try snapshot(guid: "é"), try snapshot(guid: "e\u{301}")))
    }
}
