import Foundation
import Testing
@testable import MessagesKit

struct MessageEventWatchLoopTests {
    private func cursor(_ sequence: Int64) throws -> MessageEventCursor {
        try MessageEventCursor(stream: MessageEventStreamID("00000000-0000-4000-8000-000000000012"),
                               filter: MessageEventFilter(conversations: nil).digest, sequence: sequence)
    }

    @Test func resumeReplaysBeforeCaptureAndAnnouncesEachGapOnce() throws {
        let initial = try cursor(2)
        var observations: [MessageEventWatchLoop.Outcome] = [.observationGap, .observationGap, .committed, .committed]
        var trace: [String] = []
        try MessageEventWatchLoop.follow(after: initial, start: .resume, interval: .seconds(1),
            shouldContinue: { !observations.isEmpty },
            capture: { mode in trace.append(mode.rawValue); return observations.removeFirst() },
            deliver: { after, mode, validated in
                let head = after.sequence + 1
                try validated(head, 1)
                trace.append("\(mode.rawValue) \(after.sequence)->\(head)")
                return head
            },
            emit: { control in
                switch control {
                case .resumed(let after, let head, _): trace.append("resumed \(after.sequence) at \(head)")
                case .gap(let last): trace.append("gap \(last.sequence)")
                case .restored(let last): trace.append("restored \(last.sequence)")
                default: Issue.record("unexpected control")
                }
            }, wait: { _ in })
        #expect(trace == ["resumed 2 at 3", "replay 2->3", "reconcile", "gap 3", "reconcile",
                          "reconcile", "restored 4", "live 3->4", "poll", "live 4->5"])
    }

    @Test(arguments: [true, false])
    func terminalCaptureEmitsLastDeliveredCursorAndStops(capacity: Bool) throws {
        let initial = try cursor(2)
        var seen: [Int64] = []
        var waits: [Duration] = []
        let expected: MessageEventWatchLoop.Failure = capacity ? .capacityExceeded : .schemaChanged
        #expect(throws: expected) {
            try MessageEventWatchLoop.follow(after: initial, start: .baseline(cost: .seconds(2)), interval: .seconds(1),
                shouldContinue: { seen.isEmpty }, capture: { mode in
                    #expect(mode == .poll)
                    return capacity ? .capacityExceeded : .schemaChanged
                }, deliver: { _, _, _ in Issue.record("terminal capture was delivered"); return 0 },
                emit: { control in
                    switch (capacity, control) {
                    case (true, .capacityExceeded(let last, nil)), (false, .schemaChanged(let last)): seen.append(last.sequence)
                    default: Issue.record("unexpected terminal control")
                    }
                }, wait: { waits.append($0) })
        }
        #expect(seen == [2])
        #expect(waits == [.seconds(8)])
    }

    @Test(arguments: MessageEventCaptureLimit.allCases)
    func namedCaptureLimitStopsAtTheLastDeliveredCursor(_ limit: MessageEventCaptureLimit) throws {
        let initial = try cursor(2)
        var seen: [Int64] = []
        var captures = 0
        #expect(throws: limit) {
            try MessageEventWatchLoop.follow(after: initial, start: .resume, interval: .seconds(1),
                shouldContinue: { captures == 0 }, capture: { mode in
                    #expect(mode == .reconcile)
                    captures += 1
                    throw limit
                }, deliver: { _, mode, validate in
                    #expect(mode == .replay)
                    try validate(4, 1)
                    return 4
                }, emit: { control in
                    switch control {
                    case .resumed: break
                    case .capacityExceeded(let last, let reported):
                        #expect(reported == limit)
                        seen.append(last.sequence)
                    default: Issue.record("unexpected control")
                    }
                }, wait: { _ in Issue.record("terminal limit did not stop capture") })
        }
        #expect(captures == 1)
        #expect(seen == [4])
    }

    @Test func pollDelayIncludesDeliveryWork() throws {
        let initial = try cursor(0)
        var waits: [Duration] = []
        try MessageEventWatchLoop.follow(after: initial, start: .baseline(cost: .zero), interval: .milliseconds(1),
            shouldContinue: { waits.count < 2 }, capture: { _ in .committed },
            deliver: { after, _, validated in
                try validated(after.sequence, nil)
                let end = ContinuousClock.now.advanced(by: .milliseconds(10))
                while ContinuousClock.now < end { Thread.sleep(forTimeInterval: 0.01) }
                return after.sequence
            }, emit: { _ in Issue.record("unexpected control") }, wait: { waits.append($0) })
        try #require(waits.count == 2)
        #expect(waits[0] == .milliseconds(1))
        #expect(waits[1] >= .milliseconds(40))
    }

    @Test func failedInitialDeliveryNeverStartsCapture() throws {
        let initial = try cursor(0)
        var captures = 0
        #expect(throws: MessageEventWatchLoop.Failure.startupValidationCapacity) {
            try MessageEventWatchLoop.follow(after: initial, start: .resume, interval: .seconds(1),
                shouldContinue: { captures == 0 }, capture: { _ in captures += 1; return .committed },
                deliver: { _, _, _ in throw MessageEventStateDigest.Failure.limitExceeded },
                emit: { _ in Issue.record("unvalidated control") }, wait: { _ in })
        }
        #expect(captures == 0)
    }
}
