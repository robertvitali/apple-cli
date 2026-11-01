import AppleKit
import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesUndoSendBodyTransitionTests {
    private typealias Run = (Int, Int, Int)

    private func archive(_ text: String, _ runs: [Run]) -> Data {
        let body = NSMutableAttributedString(string: text)
        for (location, length, index) in runs {
            body.addAttribute(NSAttributedString.Key("__kIMMessagePartAttributeName"),
                value: NSNumber(value: index), range: NSRange(location: location, length: length))
        }
        return NSArchiver.archivedData(withRootObject: body)
    }

    private func observation(_ blob: MessagesUndoSendObservation.Field<Data>,
                             text: MessagesUndoSendObservation.Field<Data> = .null)
        -> MessagesUndoSendObservation.Snapshot {
        .init(identity: .init(chatRowid: 3, chatGUID: "synthetic-chat", chatStyle: 45,
            messageRowid: 2, messageGUID: "synthetic-message", sentDateRaw: 800_000_000_000_000_000,
            participantHandles: ["alice@example.com"]),
            isFromMe: .value(1), isSent: .value(1), error: .value(0),
            dateEdited: .value(800_000_001_000_000_000), dateRetracted: .value(0),
            serviceUTF8: .value(Data("iMessage".utf8)), textUTF8: text,
            attributedBody: blob, summaryInfo: .null)
    }

    private func before(_ text: String, _ runs: [Run], selected: Int = 0) throws -> MessagesUndoSendPart.Snapshot {
        try MessagesUndoSendPart.resolve(observation(.value(archive(text, runs))),
            partIndex: selected, deadline: .millisecondsFromNow(5000))
    }

    private func matches(_ before: MessagesUndoSendPart.Snapshot,
                         _ after: MessagesUndoSendObservation.Snapshot) throws -> Bool {
        try MessagesUndoSendBodyTransition.matches(before: before, after: after,
                                                   deadline: .millisecondsFromNow(5000))
    }

    @Test func finalPartRequiresAbsentBodyAndText() throws {
        let pre = try before("hello", [(0, 5, 0)])
        #expect(try matches(pre, observation(.null)))
        #expect(try !matches(pre, observation(.null, text: .value(Data("hello".utf8)))))
        #expect(try !matches(pre, observation(.value(archive("", [])))))
        #expect(try !matches(pre, observation(.wrongType)))
    }

    @Test func removesOnlySelectedSpansAndShiftsSurvivors() throws {
        let pre = try before("ABC", [(0, 1, 0), (1, 1, 1), (2, 1, 2)])
        #expect(try matches(pre, observation(.value(archive("BC", [(0, 1, 1), (1, 1, 2)])))))
        #expect(try !matches(pre, observation(.value(archive("CB", [(0, 1, 2), (1, 1, 1)])))))
        #expect(try !matches(pre, observation(.value(archive("BD", [(0, 1, 1), (1, 1, 2)])))))
    }

    @Test func strippedPartAttributeCannotHideRetainedContent() throws {
        let pre = try before("A B", [(0, 1, 0), (2, 1, 1)])
        #expect(try !matches(pre, observation(.value(archive("A B", [(2, 1, 1)])))))
        #expect(try matches(pre, observation(.value(archive(" B", [(1, 1, 1)])))))
        #expect(try !matches(pre, observation(.value(archive("B", [(0, 1, 1)])))))
        #expect(try !matches(pre, observation(.value(archive("XB", [(1, 1, 1)])))))
    }

    @Test func terminalUnmappedContentCannotDisappearUnaccounted() throws {
        let pre = try before("A ", [(0, 1, 0)])
        #expect(try !matches(pre, observation(.null)))
        #expect(try !matches(pre, observation(.value(archive(" ", [])))))
    }

    @Test func duplicateSurvivorTextIsNotConfusedWithSelectedText() throws {
        let pre = try before("AAA", [(0, 1, 0), (1, 2, 1)])
        #expect(try matches(pre, observation(.value(archive("AA", [(0, 2, 1)])))))
    }

    @Test func handlesSupplementaryUnicodeAndExactBytes() throws {
        let pre = try before("\u{1f680}\u{e9}", [(0, 2, 0), (2, 1, 1)])
        #expect(try matches(pre, observation(.value(archive("\u{e9}", [(0, 1, 1)])))))
        #expect(try !matches(pre, observation(.value(archive("e\u{301}", [(0, 2, 1)])))))
    }

    @Test func adjacentSurvivorCoalescenceRemainsUnverified() throws {
        let pre = try before("aba", [(0, 1, 1), (1, 1, 0), (2, 1, 1)])
        #expect(try !matches(pre, observation(.value(archive("aa", [(0, 2, 1)])))))
    }

    @Test func inconsistentSQLTextAndMalformedArchiveFail() throws {
        let pre = try before("AB", [(0, 1, 0), (1, 1, 1)])
        #expect(try !matches(pre, observation(.value(archive("B", [(0, 1, 1)])), text: .value(Data("X".utf8)))))
        #expect(try !matches(pre, observation(.value(Data([0, 1, 2])))))
        #expect(try !matches(pre, observation(.null)))
    }

    @Test func cancelledOrExpiredTransitionPropagates() throws {
        let pre = try before("A", [(0, 1, 0)])
        #expect(throws: WorkerProtocolError.cancelled) {
            try MessagesUndoSendBodyTransition.matches(before: pre, after: observation(.null),
                deadline: .millisecondsFromNow(5000), isCancelled: { true })
        }
        #expect(throws: MessagesAXNavigationError.deadlineExpired) {
            try MessagesUndoSendBodyTransition.matches(before: pre, after: observation(.null),
                deadline: .millisecondsFromNow(0))
        }
    }
}
