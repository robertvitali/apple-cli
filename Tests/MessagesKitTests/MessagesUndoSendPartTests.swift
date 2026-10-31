import AppleKit
import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesUndoSendPartTests {
    private func archive(_ text: String, runs: [(Int, Int, Int, String?)]) -> Data {
        let body = NSMutableAttributedString(string: text)
        for (location, length, index, guid) in runs {
            let range = NSRange(location: location, length: length)
            body.addAttribute(NSAttributedString.Key("__kIMMessagePartAttributeName"),
                              value: NSNumber(value: index), range: range)
            if let guid {
                body.addAttribute(NSAttributedString.Key("__kIMFileTransferGUIDAttributeName"),
                                  value: guid, range: range)
            }
        }
        return NSArchiver.archivedData(withRootObject: body)
    }

    private func observation(_ body: MessagesUndoSendObservation.Field<Data>,
                             text: MessagesUndoSendObservation.Field<Data> = .null)
        -> MessagesUndoSendObservation.Snapshot {
        .init(identity: .init(chatRowid: 3, chatGUID: "synthetic-chat", chatStyle: 45,
            messageRowid: 2, messageGUID: "synthetic-message", sentDateRaw: 800_000_000_000_000_000,
            participantHandles: ["alice@example.com"]),
            isFromMe: .value(1), isSent: .value(1), error: .value(0),
            dateEdited: .value(0), dateRetracted: .value(0), serviceUTF8: .value(Data("iMessage".utf8)),
            textUTF8: text, attributedBody: body, summaryInfo: .null)
    }

    private func resolve(_ value: MessagesUndoSendObservation.Snapshot, index: Int = 0)
        throws -> MessagesUndoSendPart.Snapshot {
        try MessagesUndoSendPart.resolve(value, partIndex: index, deadline: .millisecondsFromNow(5000))
    }

    @Test func resolvesTextAndAttachmentByOriginalIndex() throws {
        let text = "hello \u{fffc}"
        let value = observation(.value(archive(text, runs: [(0, 5, 2, nil), (6, 1, 7, "synthetic-file")])) ,
                                text: .value(Data(text.utf8)))
        let textPart = try resolve(value, index: 2)
        #expect(textPart.selectedPart.index == 2)
        #expect(textPart.selectedPart.attachmentGUID == nil)
        #expect(textPart.selectedTextFragments == ["hello"])
        let attachmentPart = try resolve(value, index: 7)
        #expect(attachmentPart.selectedPart.attachmentGUID == "synthetic-file")
        #expect(attachmentPart.selectedPart.utf16Ranges == [.init(location: 6, length: 1)])
        #expect(attachmentPart.nativeParts.count == 2)
        #expect(attachmentPart.fullText.utf8.elementsEqual(text.utf8))
        #expect(attachmentPart.observation.identity.matches(value.identity))
    }

    @Test func preservesDisjointRangesWithoutInventingContiguousText() throws {
        let value = observation(.value(archive("a b", runs: [(0, 1, 0, nil), (2, 1, 0, nil)])))
        let part = try resolve(value)
        #expect(part.selectedTextFragments == ["a", "b"])
        #expect(part.selectedPart.utf16Ranges.count == 2)
    }

    @Test(arguments: [-1, 1, Int(Int32.max) + 1, Int.max])
    func rejectsMissingOrInvalidRequestedIndex(_ index: Int) throws {
        let value = observation(.value(archive("hello", runs: [(0, 5, 0, nil)])))
        #expect(throws: (any Error).self) { try resolve(value, index: index) }
    }

    @Test func refusesAbsentMalformedOrUnmappedBody() throws {
        let bodies: [MessagesUndoSendObservation.Field<Data>] = [
            .null, .wrongType, .value(Data()), .value(Data([0, 1, 2])),
            .value(archive("plain text", runs: [])), .value(Data(repeating: 0, count: 1_048_577))
        ]
        for body in bodies {
            #expect(throws: (any Error).self) { try resolve(observation(body, text: .value(Data("plain text".utf8)))) }
        }
    }

    @Test func rejectsPlainTextDriftIncludingCanonicalEquivalence() throws {
        let composed = "\u{e9}"
        let decomposed = "e\u{301}"
        #expect(composed == decomposed)
        let body = archive(composed, runs: [(0, 1, 0, nil)])
        for text: MessagesUndoSendObservation.Field<Data> in [
            .wrongType, .value(Data("different".utf8)), .value(Data(decomposed.utf8)), .value(Data([255]))
        ] {
            #expect(throws: (any Error).self) { try resolve(observation(.value(body), text: text)) }
        }
        let exact = try resolve(observation(.value(body), text: .value(Data(composed.utf8))))
        #expect(exact.selectedTextFragments[0].utf8.elementsEqual(composed.utf8))
    }

    @Test func rejectsConflictingAttachmentGUIDBytes() throws {
        let body = archive("\u{fffc} \u{fffc}", runs: [(0, 1, 0, "\u{e9}"), (2, 1, 0, "e\u{301}")])
        #expect(throws: (any Error).self) { try resolve(observation(.value(body))) }
    }

    @Test func rejectsInvalidIndexElsewhereInMapping() throws {
        let body = archive("a b", runs: [(0, 1, 0, nil), (2, 1, Int(Int32.max) + 1, nil)])
        #expect(throws: (any Error).self) { try resolve(observation(.value(body))) }
    }

    @Test func preservesSupplementaryUnicodeRanges() throws {
        let body = archive("\u{1f680}", runs: [(0, 2, 0, nil)])
        let part = try resolve(observation(.value(body)))
        #expect(part.selectedTextFragments == ["\u{1f680}"])
        #expect(part.selectedPart.utf16Ranges == [.init(location: 0, length: 2)])
    }

    @Test func cancelledOrExpiredResolutionRefuses() throws {
        let value = observation(.null)
        #expect(throws: WorkerProtocolError.cancelled) {
            try MessagesUndoSendPart.resolve(value, partIndex: 0,
                deadline: .millisecondsFromNow(5000), isCancelled: { true })
        }
        #expect(throws: (any Error).self) {
            try MessagesUndoSendPart.resolve(value, partIndex: 0, deadline: .millisecondsFromNow(0))
        }
    }
}
