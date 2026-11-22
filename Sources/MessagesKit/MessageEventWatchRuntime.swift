import AppleKit
import Foundation

enum MessageEventWatchRuntime {
  static func run(
    _ request: MessageEventWatchOptions.Request, storage: MessageEventWatchStorage, output: Int32
  ) throws {
    switch request.start {
    case .baseline(let filter):
      try Start.run(storage: storage, filter: filter, output: output, deadline: request.deadline) {
        lease, cursor, cost in
        try Watch.follow(
          storage: storage, initial: cursor, lease: lease, interval: request.interval,
          output: output, stop: request.deadline, resuming: false, baselineTime: cost)
      }
    case .resume(let cursor):
      guard let id = UUID(uuidString: cursor.stream.rawValue) else { throw Bad.args }
      let lease = try RecoveryLease.acquire(root: storage.registry.path, streamID: id)
      try Watch.follow(
        storage: storage, initial: cursor, lease: lease, interval: request.interval,
        output: output, stop: request.deadline, resuming: true)
    }
  }

  static func emitWatchFailure(output: Int32, _ action: () throws -> Void) throws {
    do {
      try action()
    } catch {
      if error is RecordWriterError { throw error }
      if let failure = error as? MessageEventPollWait.Failure, failure == .outputClosed {
        throw failure
      }
      let issue: AppleError
      switch error {
      case ExistingEventJournalLease.ProvisionFailure.full:
        issue = AppleError(
          type: AppleErrorType.upstream, message: "streamRegistryFull", exitCode: AppleExit.upstream,
          remediation: "List event streams and preview retirement of an unused stream before starting another.")
      case let failure as StreamInitializationFailure: issue = .upstream(failure.message)
      case let limit as MessageEventCaptureLimit: issue = .upstream(limit.rawValue)
      case let failure as MessageEventJournalSchema.IntegrityBudgetFailure:
        issue = .upstream(failure.rawValue)
      case let failure as WatchFailure: issue = .upstream(failure.rawValue)
      case let failure as MessageEventCursorFailure: issue = failure.watchError
      case MessageEventJournalSchema.IntegrityFailure.invalidPages:
        issue = .upstream("invalidJournalPages")
      case MessageEventJournalSchema.IntegrityFailure.invalidDigest:
        issue = .upstream("invalidJournalDigest")
      case MessageEventCatalogBudget.Failure.workLimit:
        issue = .upstream("catalog-validation-capacity")
      case MessageEventCatalogBudget.Failure.deadline: issue = .upstream("deadline")
      case SourceSchema.Failure.schemaCapacity: issue = .upstream("schemaCapacity")
      case SourceSchema.Failure.invalidSourceSchema: issue = .upstream("unsupportedSourceSchema")
      case is MessageEventWatchOptions.Failure, Bad.args:
        issue = .validation("Invalid Messages watch options.")
      case ContinuityFailure.observationGap: issue = .upstream("observationGap")
      case ContinuityFailure.sourceReset: issue = .upstream("sourceReset")
      default: issue = .upstream("watchUnavailable")
      }
      let writer = try RecordWriter(borrowing: output)
      try writer.writeRecord(
        Output.encodeCompactError(tool: "messages", from: issue),
        deadline: .now.advanced(by: .seconds(2)))
      try writer.close()
      throw issue
    }
  }
}
