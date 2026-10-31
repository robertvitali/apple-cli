import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesUndoSendTimeWindowTests {
    private let seconds: Int64 = 800_000_000
    private let nanos: Int64 = 1_000_000_000

    @Test(arguments: [119.0, 120.0, 121.0])
    func twoMinuteBoundary(age: Double) {
        let result = MessagesUndoSendTimeWindow.assess(sentDateRaw: seconds * nanos,
            now: Date(timeIntervalSinceReferenceDate: Double(seconds) + age))
        #expect(result == (age < 120 ? .withinWindow : .expired))
    }

    @Test(arguments: [Int64.min, -1, 0, 800_000_000, 9_999_999_999])
    func refusesUnsupportedRawTimestamps(raw: Int64) {
        #expect(MessagesUndoSendTimeWindow.assess(sentDateRaw: raw,
            now: Date(timeIntervalSinceReferenceDate: Double(seconds) + 1)) == .invalidTimestamp)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
    func refusesNonfiniteClock(value: Double) {
        #expect(MessagesUndoSendTimeWindow.assess(sentDateRaw: seconds * nanos,
            now: Date(timeIntervalSinceReferenceDate: value)) == .invalidTimestamp)
    }

    @Test func refusesFutureEvenOneNanosecondAhead() {
        for raw in [seconds * nanos + 1, (seconds + 1) * nanos, Int64.max] {
            #expect(MessagesUndoSendTimeWindow.assess(sentDateRaw: raw,
                now: Date(timeIntervalSinceReferenceDate: Double(seconds))) == .invalidTimestamp)
        }
    }

    @Test func fractionalTimestampCanPassAfterItsCeilingSecond() {
        #expect(MessagesUndoSendTimeWindow.assess(sentDateRaw: seconds * nanos + 900_000_000,
            now: Date(timeIntervalSinceReferenceDate: Double(seconds) + 1)) == .withinWindow)
    }

    @Test func fractionalBoundaryExpiresConservatively() {
        let raw = seconds * nanos + 900_000_000
        #expect(MessagesUndoSendTimeWindow.assess(sentDateRaw: raw,
            now: Date(timeIntervalSinceReferenceDate: Double(seconds) + 119.5)) == .expired)
        #expect(MessagesUndoSendTimeWindow.assess(sentDateRaw: raw,
            now: Date(timeIntervalSinceReferenceDate: Double(seconds) + 120.9)) == .expired)
    }

    @Test func doesNotOverflowAtLargestStoredTimestamp() {
        let after = Double(Int64.max / nanos) + 121
        #expect(MessagesUndoSendTimeWindow.assess(sentDateRaw: Int64.max,
            now: Date(timeIntervalSinceReferenceDate: after)) == .expired)
        #expect(MessagesUndoSendTimeWindow.assess(sentDateRaw: seconds * nanos,
            now: Date(timeIntervalSinceReferenceDate: Double.greatestFiniteMagnitude)) == .expired)
    }

    @Test func wholeSecondStartAndConservativeFractionalFuture() {
        let now = Date(timeIntervalSinceReferenceDate: Double(seconds))
        #expect(MessagesUndoSendTimeWindow.assess(sentDateRaw: seconds * nanos, now: now) == .withinWindow)
        #expect(MessagesUndoSendTimeWindow.assess(sentDateRaw: seconds * nanos + 1,
            now: Date(timeIntervalSinceReferenceDate: Double(seconds) + 0.5)) == .invalidTimestamp)
    }
}
