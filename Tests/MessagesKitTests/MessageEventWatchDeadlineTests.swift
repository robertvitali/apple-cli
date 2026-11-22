import AppleKit
import Testing
@testable import MessagesKit

struct MessageEventWatchDeadlineTests {
    @Test func distinguishesEndOfObservationFromStartupAndIndependentBudgets() {
        let now = ContinuousClock.now
        let expired = MessageEventWatchDeadline(stop: now, maximum: 100, now: now.advanced(by: .milliseconds(-1)))
        #expect(expired.endsObservation(true))
        #expect(!expired.endsObservation(false))
        #expect(throws: MessageEventWatchDeadline.End.requestedDuration) {
            try expired.run(duringObservation: true) { _ in throw SQLiteReadTransaction.Failure.deadline }
        }
        #expect(throws: ReadFailure.deadline) {
            try expired.run(duringObservation: false) { _ in throw ReadFailure.deadline }
        }
        let independent = MessageEventWatchDeadline(stop: now.advanced(by: .seconds(5)), maximum: 10, now: now)
        #expect(!independent.endsObservation(true))
        #expect(throws: ReadFailure.deadline) {
            try independent.run(duringObservation: true) { _ in throw ReadFailure.deadline }
        }
        #expect(throws: WatchFailure.recoveryRequired) {
            try expired.run(duringObservation: true) { _ in throw WatchFailure.recoveryRequired }
        }
        #expect(throws: MessageEventCursorFailure.expired) {
            try expired.run(duringObservation: true) { _ in throw MessageEventCursorFailure.expired }
        }
    }

    @Test func roundsFractionalMillisecondsUpAndPreservesAnElapsedBoundary() {
        let now = ContinuousClock.now
        #expect(MessageEventWatchDeadline(stop: now.advanced(by: .microseconds(1)), maximum: 10, now: now).milliseconds == 1)
        #expect(MessageEventWatchDeadline(stop: now, maximum: 10, now: now).milliseconds == 0)
        #expect(MessageEventWatchDeadline(stop: nil, maximum: 10, now: now).milliseconds == 10)
    }
}
