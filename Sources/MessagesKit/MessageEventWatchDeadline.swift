import AppleKit

/// Keep the caller's observation duration distinct from the budget for one journal operation.
struct MessageEventWatchDeadline {
    enum End: Error { case requestedDuration }

    let milliseconds: Int
    private let requestedEnd: ContinuousClock.Instant?

    init(stop: ContinuousClock.Instant?, maximum: Int, now: ContinuousClock.Instant = .now) {
        guard let stop, stop <= now.advanced(by: .milliseconds(maximum)) else {
            requestedEnd = nil
            milliseconds = maximum
            return
        }
        requestedEnd = stop
        guard stop > now else {
            milliseconds = 0
            return
        }
        let parts = now.duration(to: stop).components
        // Round up so the SQLite timer cannot fire before the caller's deadline.
        let perMillisecond: Int64 = 1_000_000_000_000_000
        milliseconds = Int(parts.seconds * 1000 + (parts.attoseconds + perMillisecond - 1) / perMillisecond)
    }

    func endsObservation(_ observing: Bool) -> Bool {
        guard observing, let requestedEnd else { return false }
        return ContinuousClock.now >= requestedEnd
    }

    func run<T>(duringObservation: Bool, _ body: (Int) throws -> T) throws -> T {
        do {
            guard milliseconds > 0 else { throw ReadFailure.deadline }
            return try body(milliseconds)
        } catch {
            guard endsObservation(duringObservation) else { throw error }
            switch error {
            case ReadFailure.deadline, SQLiteReadTransaction.Failure.deadline,
                 MessageEventCatalogBudget.Failure.deadline, MessageEventJournalSchema.IntegrityBudgetFailure.deadline:
                throw End.requestedDuration
            default:
                throw error
            }
        }
    }
}
