import AppleKit
import Darwin
import EventJournal
import Foundation

typealias WatchFailure = MessageEventWatchLoop.Failure

enum Watch {
  static func follow(
    storage: MessageEventWatchStorage, initial: MessageEventCursor, lease: RecoveryLease,
    interval: Duration,
    output: Int32, stop: ContinuousClock.Instant?, resuming: Bool, baselineTime: Duration = .zero
  ) throws {
    defer { withExtendedLifetime(lease) {} }

    func emit(_ control: MessageEventWatchControl) throws {
      try lease.validate()
      let writer = try RecordWriter(borrowing: output)
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      try writer.writeRecord(
        Output.encodeCompactSuccess(tool: "messages", data: control),
        deadline: min(stop ?? deadline, deadline))
      try writer.close()
    }
    let outputWait = try MessageEventPollWait(output: output)
    do {
      try MessageEventWatchLoop.follow(
        after: initial, start: resuming ? .resume : .baseline(cost: baselineTime),
        interval: interval, shouldContinue: { stop.map { .now < $0 } ?? true },
        capture: { mode in
          let budget = MessageEventWatchDeadline(stop: stop, maximum: 30_000)
          return try budget.run(duringObservation: true) { milliseconds in
            let status = try Capture.run(
              storage: storage, stream: initial.stream, milliseconds: milliseconds, lease: lease,
              mode: mode)
            if let limit = MessageEventCaptureLimit(rawValue: status) { throw limit }
            switch status {
            case "deadline":
              guard budget.endsObservation(true) else { throw WatchFailure.captureFailed }
              throw MessageEventWatchDeadline.End.requestedDuration
            case "success": return .committed
            case "observationGap", "sourceUnavailable": return .observationGap
            case "schemaChanged": return .schemaChanged
            case "capacity": return .capacityExceeded
            case "sourceReset": throw WatchFailure.sourceReset
            case "recovery-required", "old-consistent", "new-consistent":
              throw WatchFailure.recoveryRequired
            default: throw WatchFailure.captureFailed
            }
          }
        },
        deliver: { cursor, mode, onValidated in
          let budget = MessageEventWatchDeadline(stop: stop, maximum: 120_000)
          // Initial cursor validation and replay must finish before observing.
          return try budget.run(duringObservation: mode == .live) { milliseconds in
            try Replay.deliver(
              registry: storage.registry, cursor: cursor, mode: mode, output: output,
              milliseconds: milliseconds, lease: lease, onValidated: onValidated)
          }
        }, emit: emit,
        wait: { delay in
          let desired = ContinuousClock.now.advanced(by: delay)
          try outputWait.wait(until: stop.map { min($0, desired) } ?? desired)
        })
    } catch MessageEventWatchDeadline.End.requestedDuration {
      return
    }
  }
}
