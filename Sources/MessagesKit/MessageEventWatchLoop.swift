import Foundation

/// Follows one leased journal. The caller holds the lease through capture, delivery and idle waits.
enum MessageEventWatchLoop {
    enum Start { case baseline(cost: Duration), resume }
    enum CaptureMode: String { case poll, reconcile }
    enum Outcome { case committed, observationGap, schemaChanged, capacityExceeded }
    enum Failure: String, Error {
        case schemaChanged, capacityExceeded, sourceReset, recoveryRequired, captureFailed
        case startupValidationCapacity = "startup-validation-capacity"
    }

    /// The journal calls the observer after validating the replay window and before its first frame.
    /// A successful delivery returns the last sequence written, including the incoming cursor for an empty window.
    typealias Deliver = (MessageEventCursor, MessageEventDelivery.Mode,
                         @escaping (Int64, Int64?) throws -> Void) throws -> Int64

    static func follow(after initial: MessageEventCursor, start: Start, interval: Duration,
                       shouldContinue: () -> Bool,
                       capture: (CaptureMode) throws -> Outcome, deliver: Deliver,
                       emit: @escaping (MessageEventWatchControl) throws -> Void,
                       wait: (Duration) throws -> Void) throws {
        var cursor = initial
        func drain(_ mode: MessageEventDelivery.Mode,
                   onValidated: @escaping (Int64, Int64?) throws -> Void) throws {
            let sequence = try deliver(cursor, mode, onValidated)
            cursor = try MessageEventCursor(stream: cursor.stream, filter: cursor.filter, sequence: sequence)
        }

        var nextCapture: CaptureMode
        switch start {
        case .baseline(let cost):
            try wait(max(interval, cost * 4))
            nextCapture = .poll
        case .resume:
            do {
                try drain(.replay) { head, oldest in
                    try emit(.resumed(after: initial, head: head, oldest: oldest))
                }
            } catch MessageEventStateDigest.Failure.limitExceeded {
                throw Failure.startupValidationCapacity
            }
            nextCapture = .reconcile
        }

        var inGap = false
        while shouldContinue() {
            let began = ContinuousClock.now
            let outcome: Outcome
            do {
                outcome = try capture(nextCapture)
            } catch let limit as MessageEventCaptureLimit {
                try emit(.capacityExceeded(cursor, limit: limit))
                throw limit
            }
            switch outcome {
            case .committed:
                let restoring = inGap
                let previous = cursor
                try drain(.live) { head, _ in
                    if restoring {
                        let committed = try MessageEventCursor(stream: previous.stream, filter: previous.filter,
                                                               sequence: head)
                        try emit(.restored(committed))
                    }
                }
                inGap = false
                nextCapture = .poll
            case .observationGap:
                if !inGap { try emit(.gap(cursor)) }
                inGap = true
                nextCapture = .reconcile
            case .schemaChanged:
                try emit(.schemaChanged(cursor))
                throw Failure.schemaChanged
            case .capacityExceeded:
                try emit(.capacityExceeded(cursor))
                throw Failure.capacityExceeded
            }
            if shouldContinue() {
                // Validation, replay and writes can cost more than capture itself.
                try wait(max(interval, began.duration(to: .now) * 4))
            }
        }
    }
}
