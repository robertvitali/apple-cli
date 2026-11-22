import AppleKit
import ArgumentParser
import Foundation

/// Resolve the complete request before choosing a source path or opening a stream.
struct MessageEventWatchOptions: ParsableArguments {
    @Option(name: .customLong("conversation"), help: "Exact conversation GUID. Repeat for each conversation.")
    private var conversations: [String] = []

    // ArgumentParser's scalar options keep only the last occurrence. Two
    // different checkpoints would silently choose which events to replay.
    @Option(name: .customLong("resume"), help: "Resume strictly after this event cursor.")
    private var cursors: [String] = []

    @Option(name: .customLong("poll-interval"), help: "Minimum wait between polls in seconds, from 0.25 to 60 (default 1). Slow cycles increase the wait.")
    private var intervals: [Double] = []

    @Option(name: .customLong("duration"), help: "Stop observing after this many seconds. Omit to keep watching.")
    private var durations: [Double] = []

    enum Failure: Error, Equatable {
        case conflictingCursors, invalidInterval, invalidDuration
    }

    struct Request {
        enum Start {
            case baseline(MessageEventFilter)
            case resume(MessageEventCursor)
        }

        let start: Start
        let interval: Duration
        let deadline: ContinuousClock.Instant?
    }

    func request(now: ContinuousClock.Instant = .now,
                 rawArguments: UnsafeBufferPointer<UnsafeMutablePointer<CChar>?> = .init(
                    start: CommandLine.unsafeArgv, count: Int(CommandLine.argc))) throws -> Request {
        let seconds = intervals.first ?? 1
        guard (0.25...60).contains(seconds), intervals.dropFirst().allSatisfy({ $0 == seconds }) else {
            throw Failure.invalidInterval
        }
        var deadline: ContinuousClock.Instant?
        if let seconds = durations.first {
            guard seconds.isFinite, seconds > 0, seconds < Double(Int64.max) / 2,
                  durations.dropFirst().allSatisfy({ $0 == seconds }) else { throw Failure.invalidDuration }
            let duration = Duration.seconds(seconds)
            guard duration > .zero else { throw Failure.invalidDuration }
            deadline = now.advanced(by: duration)
        }

        // CommandLine.arguments repairs malformed UTF-8 before ArgumentParser
        // receives it. Only a replacement scalar can be mistaken for a valid
        // filter byte sequence this way. Keep genuinely supplied U+FFFD valid.
        if conversations.contains(where: { $0.unicodeScalars.contains("\u{FFFD}") }) {
            guard rawArguments.dropFirst().allSatisfy({ argument in
                guard let argument else { return false }
                return String(validatingCString: argument) != nil
            }) else { throw MessageEventCursorFailure.invalidIdentifier }
        }
        let filter = try MessageEventFilter(conversations: conversations.isEmpty ? nil : conversations)
        let start: Request.Start
        if let first = cursors.first {
            let cursor = try MessageEventCursor(first)
            guard cursors.dropFirst().allSatisfy({ $0.utf8.elementsEqual(first.utf8) }) else {
                throw Failure.conflictingCursors
            }
            if !conversations.isEmpty && filter.digest != cursor.filter { throw MessageEventCursorFailure.filterMismatch }
            start = .resume(cursor)
        } else {
            start = .baseline(filter)
        }
        return Request(start: start, interval: .seconds(seconds), deadline: deadline)
    }
}

extension MessageEventCursorFailure {
    /// The watch command reports a lost replay position separately from a bad request.
    var watchError: AppleError {
        let reason = String(describing: self)
        switch self {
        case .expired, .streamMismatch:
            return AppleError(type: AppleErrorType.validation, message: reason, exitCode: AppleExit.usage,
                              status: "resynchronization_required",
                              remediation: "Reconcile current state before starting a new stream for this filter.")
        case .invalidRetentionBounds:
            return .upstream(reason)
        case .invalidIdentifier, .invalidFilter, .invalidStreamID, .invalidDigest,
             .invalidCursor, .filterMismatch, .aheadOfHead:
            return .validation(reason)
        }
    }
}
