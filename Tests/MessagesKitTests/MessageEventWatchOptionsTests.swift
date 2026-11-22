import ArgumentParser
import Foundation
import Testing
@testable import MessagesKit

struct MessageEventWatchOptionsTests {
    private typealias Options = MessageEventWatchOptions
    private let id = "00000000-0000-0000-0000-000000000001"

    private func cursor(_ filter: MessageEventFilter, after sequence: Int64) throws -> MessageEventCursor {
        try MessageEventCursor(stream: MessageEventStreamID(id), filter: filter.digest, sequence: sequence)
    }

    @Test func onlyLostReplayPositionsRequireResynchronization() {
        for failure in [MessageEventCursorFailure.expired, .streamMismatch] {
            let error = failure.watchError
            #expect(error.type == "validation_error")
            #expect(error.exitCode == 64)
            #expect(error.message == String(describing: failure))
            #expect(error.status == "resynchronization_required")
            #expect(error.remediation != nil)
        }
        for failure in [MessageEventCursorFailure.invalidIdentifier, .invalidFilter, .invalidDigest,
                        .invalidStreamID, .invalidCursor, .filterMismatch, .aheadOfHead] {
            let error = failure.watchError
            #expect(error.exitCode == 64)
            #expect(error.status == nil)
            #expect(error.remediation == nil)
        }
        let invalidJournal = MessageEventCursorFailure.invalidRetentionBounds.watchError
        #expect(invalidJournal.exitCode == 69)
        #expect(invalidJournal.status == nil)
    }

    @Test func freshOptionsBindTheExactFilterAndDeadline() throws {
        let now = ContinuousClock.now
        let defaults = try Options.parse([]).request(now: now)
        guard case let .baseline(all) = defaults.start else { Issue.record("Expected baseline"); return }
        #expect(all.conversations == nil)
        #expect(defaults.interval == .seconds(1))
        #expect(defaults.deadline == nil)

        let composed = "\u{00e9}", decomposed = "e\u{0301}"
        let selected = try Options.parse(["--conversation", composed, "--conversation", decomposed,
            "--conversation", composed, "--poll-interval", ".25", "--duration", "1.5"]).request(now: now)
        guard case let .baseline(filter) = selected.start else { Issue.record("Expected selected baseline"); return }
        #expect(filter.conversations?.map(\.bytes) == [Data(decomposed.utf8), Data(composed.utf8)])
        #expect(selected.interval == .milliseconds(250))
        #expect(selected.deadline == now.advanced(by: .milliseconds(1500)))
    }

    @Test func resumeKeepsOneUnambiguousCheckpoint() throws {
        let filter = try MessageEventFilter(conversations: ["selected"])
        let first = try cursor(filter, after: 0), later = try cursor(filter, after: 1)
        for pair in [[first, later], [later, first]] {
            let options = try Options.parse(["--resume", pair[0].rawValue, "--resume", pair[1].rawValue])
            #expect(throws: Options.Failure.conflictingCursors) { try options.request() }
        }
        for flags in [[], ["--conversation", "selected"]] {
            let request = try Options.parse(["--resume", first.rawValue, "--resume", first.rawValue] + flags).request()
            guard case let .resume(checkpoint) = request.start else { Issue.record("Expected resume"); return }
            #expect(checkpoint == first)
        }
        #expect(throws: MessageEventCursorFailure.filterMismatch) {
            try Options.parse(["--resume", first.rawValue, "--conversation", "other"]).request()
        }
    }

    @Test(arguments: ["nan", "inf", "0", "-1", "1e-300", "1e300"])
    func invalidDurationCannotBeOverridden(value: String) throws {
        // Joined spelling also lets ArgumentParser pass negative numbers as values.
        let single = try Options.parse(["--duration=" + value])
        #expect(throws: Options.Failure.invalidDuration) { try single.request() }
        let repeated = try Options.parse(["--duration=" + value, "--duration", "1"])
        #expect(throws: Options.Failure.invalidDuration) { try repeated.request() }
    }

    @Test func pollBoundariesAndRepeatedNumericOptions() throws {
        for invalid in ["nan", "inf", "0", "0.249", "60.001"] {
            let options = try Options.parse(["--poll-interval", invalid, "--poll-interval", "1"])
            #expect(throws: Options.Failure.invalidInterval) { try options.request() }
        }
        #expect(throws: Options.Failure.invalidDuration) {
            try Options.parse(["--duration", "2", "--duration", "1"]).request()
        }
        #expect(throws: Options.Failure.invalidInterval) {
            try Options.parse(["--poll-interval", "60", "--poll-interval", ".25"]).request()
        }
        let now = ContinuousClock.now
        let same = try Options.parse(["--poll-interval", "60", "--poll-interval", "6e1",
                                     "--duration", ".5", "--duration", "5e-1"]).request(now: now)
        #expect(same.interval == .seconds(60))
        #expect(same.deadline == now.advanced(by: .milliseconds(500)))
    }

    @Test func repairedArgumentCannotAliasALiteralReplacementCharacter() throws {
        let literal = "chat-\u{FFFD}"
        let options = try Options.parse(["--conversation", literal])
        func request(_ bytes: [UInt8]) throws -> Options.Request {
            var value = bytes.map { CChar(bitPattern: $0) } + [0]
            return try value.withUnsafeMutableBufferPointer { buffer in
                // argv[0] names the executable and is outside the filter.
                try [nil, buffer.baseAddress].withUnsafeBufferPointer { try options.request(rawArguments: $0) }
            }
        }
        #expect(throws: MessageEventCursorFailure.invalidIdentifier) { try request(Array("chat-".utf8) + [0xff]) }
        guard case let .baseline(filter) = try request(Array(literal.utf8)).start else {
            Issue.record("Expected literal filter"); return
        }
        #expect(filter.conversations?.map(\.bytes) == [Data(literal.utf8)])
    }

    @Test func suppliedFilterLimitPrecedesDeduplication() throws {
        let pair = ["--conversation", "same"]
        let permitted = Array(repeating: pair, count: 256).flatMap { $0 }
        let request = try Options.parse(permitted).request()
        guard case let .baseline(filter) = request.start else { Issue.record("Expected baseline"); return }
        #expect(filter.conversations?.count == 1)
        #expect(throws: MessageEventCursorFailure.invalidFilter) {
            try Options.parse(permitted + pair).request()
        }
    }
}
