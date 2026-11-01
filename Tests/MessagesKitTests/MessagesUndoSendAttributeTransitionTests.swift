import AppleKit
import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesUndoSendAttributeTransitionTests {
    private typealias Run = (Int, Int, Int)
    private typealias Extras = [(NSRange, [String: Any])]

    private func blob(_ text: String, runs: [Run], extras: Extras = []) -> Data {
        let value = NSMutableAttributedString(string: text)
        for (location, length, index) in runs {
            value.addAttribute(.init("__kIMMessagePartAttributeName"), value: NSNumber(value: index),
                               range: .init(location: location, length: length))
        }
        for (range, fields) in extras {
            for (key, field) in fields { value.addAttribute(.init(key), value: field, range: range) }
        }
        return NSArchiver.archivedData(withRootObject: value)
    }

    private func observation(_ body: MessagesUndoSendObservation.Field<Data>,
                             text: MessagesUndoSendObservation.Field<Data> = .null)
        -> MessagesUndoSendObservation.Snapshot {
        .init(identity: .init(chatRowid: 3, chatGUID: "synthetic-chat", chatStyle: 45,
            messageRowid: 2, messageGUID: "synthetic-message", sentDateRaw: 800_000_000_000_000_000,
            participantHandles: ["alice@example.com"]),
            isFromMe: .value(1), isSent: .value(1), error: .value(0),
            dateEdited: .value(800_000_001_000_000_000), dateRetracted: .value(0),
            serviceUTF8: .value(Data("iMessage".utf8)), textUTF8: text,
            attributedBody: body, summaryInfo: .null)
    }

    private func pre(_ data: Data) throws -> MessagesUndoSendPart.Snapshot {
        try MessagesUndoSendPart.resolve(observation(.value(data)), partIndex: 0,
                                         deadline: .millisecondsFromNow(5000))
    }

    private func matches(_ before: MessagesUndoSendPart.Snapshot,
                         _ after: MessagesUndoSendObservation.Snapshot) throws -> Bool {
        var budget = MessageSummaryPlist.Budget()
        return try MessagesUndoSendAttributeTransition.matches(before: before, after: after,
            deadline: .millisecondsFromNow(5000), budget: &budget)
    }

    private var fields: [String: Any] {
        ["NSLink": URL(string: "https://example.com/synthetic")!,
         "__kIMMentionConfirmedMention": "alice@example.com", "opaque": Data([0, 255]),
         "nested": ["label": "synthetic", "count": NSNumber(value: 7)] as NSDictionary]
    }

    @Test func retainsAllSupportedSurvivorAttributesAtShiftedRanges() throws {
        let before = try pre(blob("AB", runs: [(0, 1, 0), (1, 1, 1)], extras: [(.init(location: 1, length: 1), fields)]))
        let after = observation(.value(blob("B", runs: [(0, 1, 1)], extras: [(.init(location: 0, length: 1), fields)])))
        #expect(try matches(before, after))
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func collateralAttributeChangesFail(_ change: Int) throws {
        let before = try pre(blob("AB", runs: [(0, 1, 0), (1, 1, 1)], extras: [(.init(location: 1, length: 1), fields)]))
        var changed = fields
        switch change {
        case 0: changed["NSLink"] = URL(string: "https://example.org/changed")!
        case 1: changed.removeValue(forKey: "__kIMMentionConfirmedMention")
        case 2: changed["opaque"] = Data([0, 254])
        case 3: changed["added"] = "unexpected"
        default: changed["nested"] = ["label": "changed", "count": NSNumber(value: 7)] as NSDictionary
        }
        #expect(try !matches(before, observation(.value(blob("B", runs: [(0, 1, 1)],
            extras: [(.init(location: 0, length: 1), changed)])))))
    }

    @Test func unindexedSpanAttributesCannotChange() throws {
        let before = try pre(blob("A B", runs: [(0, 1, 0), (2, 1, 1)],
            extras: [(.init(location: 1, length: 1), ["opaque": Data([1])])]))
        let good = observation(.value(blob(" B", runs: [(1, 1, 1)],
            extras: [(.init(location: 0, length: 1), ["opaque": Data([1])])])))
        let bad = observation(.value(blob(" B", runs: [(1, 1, 1)],
            extras: [(.init(location: 0, length: 1), ["opaque": Data([2])])])))
        #expect(try matches(before, good))
        #expect(try !matches(before, bad))
    }

    @Test func attributeCoalescingDoesNotWaiveNativePartRangeRule() throws {
        let before = try pre(blob("BAB", runs: [(0, 1, 1), (1, 1, 0), (2, 1, 1)]))
        let after = observation(.value(blob("BB", runs: [(0, 2, 1)])))
        #expect(try matches(before, after))
        #expect(try !MessagesUndoSendBodyTransition.matches(before: before, after: after,
                                                           deadline: .millisecondsFromNow(5000)))
    }

    @Test func selectedAttributesMayDisappearOnlyWithTerminalBody() throws {
        let before = try pre(blob("A", runs: [(0, 1, 0)], extras: [(.init(location: 0, length: 1), fields)]))
        #expect(try matches(before, observation(.null)))
        #expect(try !matches(before, observation(.null, text: .value(Data("A".utf8)))))
        #expect(try !matches(before, observation(.value(blob("", runs: [])))))
    }

    @Test func canonicallyEquivalentAttributeTextStillCountsAsChanged() throws {
        let before = try pre(blob("AB", runs: [(0, 1, 0), (1, 1, 1)],
            extras: [(.init(location: 1, length: 1), ["unknown": "\u{e9}"])]))
        let after = observation(.value(blob("B", runs: [(0, 1, 1)],
            extras: [(.init(location: 0, length: 1), ["unknown": "e\u{301}"])])))
        #expect(try !matches(before, after))
    }

    @Test func unavailableOrMalformedPostAttributesDoNotPass() throws {
        let before = try pre(blob("AB", runs: [(0, 1, 0), (1, 1, 1)]))
        #expect(try !matches(before, observation(.value(Data([0, 1, 2])))))
        #expect(try !matches(before, observation(.null)))
        #expect(try !matches(before, observation(.value(blob("B", runs: [(0, 1, 1)],
            extras: [(.init(location: 0, length: 1), ["unknown": Date(timeIntervalSinceReferenceDate: 0)])])))))
    }

    @Test func sharedComparisonBudgetCancellationAndDeadlineAreEnforced() throws {
        let before = try pre(blob("AB", runs: [(0, 1, 0), (1, 1, 1)]))
        let after = observation(.value(blob("B", runs: [(0, 1, 1)])))
        var exhausted = MessageSummaryPlist.Budget()
        exhausted.remainingVisits = 0
        #expect(throws: MessageSummaryPlist.Failure.requestLimit) {
            try MessagesUndoSendAttributeTransition.matches(before: before, after: after,
                deadline: .millisecondsFromNow(5000), budget: &exhausted)
        }
        var budget = MessageSummaryPlist.Budget()
        #expect(throws: WorkerProtocolError.cancelled) {
            try MessagesUndoSendAttributeTransition.matches(before: before, after: after,
                deadline: .millisecondsFromNow(5000), budget: &budget, isCancelled: { true })
        }
        #expect(throws: MessagesAXNavigationError.deadlineExpired) {
            try MessagesUndoSendAttributeTransition.matches(before: before, after: after,
                deadline: .millisecondsFromNow(0), budget: &budget)
        }
    }
}
