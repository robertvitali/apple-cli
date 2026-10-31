import Foundation

/// One necessary Undo Send precondition, not mutation authorization. Ownership,
/// exact native-part identity, action availability and retraction verification
/// remain independent requirements.
enum MessagesUndoSendTimeWindow {
    enum Assessment: Equatable {
        case withinWindow, expired, invalidTimestamp
    }

    static func assess(sentDateRaw: Int64, now: Date) -> Assessment {
        // Accept only the modern Apple-epoch nanosecond representation. Legacy
        // seconds must not be guessed into eligibility by a display heuristic.
        let nowApple = now.timeIntervalSinceReferenceDate
        guard sentDateRaw > 9_999_999_999, nowApple.isFinite else {
            return .invalidTimestamp
        }
        let wholeSeconds = sentDateRaw / 1_000_000_000
        let remainder = sentDateRaw % 1_000_000_000
        let ceilingSeconds = wholeSeconds + (remainder == 0 ? 0 : 1)
        // Do not convert the original nanosecond integer to Double: doing so
        // could round a future timestamp down to the current instant. Waiting
        // until its ceiling second may refuse a valid subsecond-old message.
        guard nowApple >= Double(ceilingSeconds) else { return .invalidTimestamp }
        // Upper-bound the age rather than rounding it down. This intentionally
        // expires less than two seconds early, never after the two-minute limit.
        return ceil(nowApple) - Double(wholeSeconds) < 120 ? .withinWindow : .expired
    }
}
