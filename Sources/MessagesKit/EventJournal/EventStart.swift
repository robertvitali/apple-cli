import AppleKit
import Darwin
import EventJournal
import Foundation
import SQLite3

private enum InitialCaptureFailure: String, Error {
  case observationGap, sourceReset, sourceUnavailable, schemaChanged, invalidSourceSchema
  case capacity, deadline, invalid, captureFailed

}
struct StreamInitializationFailure: Error {
  let id: UUID
  let reason: String
  var message: String { "stream_id=" + id.uuidString.lowercased() + " " + reason }
}
enum Start {
  typealias Follow = (RecoveryLease, MessageEventCursor, Duration) throws -> Void
  static func run(
    storage: MessageEventWatchStorage, filter: MessageEventFilter, output: Int32,
    deadline: ContinuousClock.Instant?,
    then: Follow
  ) throws {
    var assigned: UUID?
    do {
      try start(storage: storage, filter: filter, output: output, deadline: deadline, then: then) {
        assigned = $0
      }
    } catch {
      if let assigned, !(error is RecordWriterError) {
        let reason: String
        switch error {
        case let limit as MessageEventCaptureLimit: reason = limit.rawValue
        case let failure as InitialCaptureFailure: reason = failure.rawValue
        case let failure as MessageEventJournalSchema.IntegrityBudgetFailure:
          reason = failure.rawValue
        case let failure as ContinuityFailure: reason = failure.rawValue
        case Failure.sqlite(let code): reason = "sqlite(" + String(code) + ")"
        case MessageEventCatalogBudget.Failure.workLimit: reason = "catalog-validation-capacity"
        case MessageEventCatalogBudget.Failure.deadline: reason = "deadline"
        case Failure.cap: reason = "capacity"
        case ReadFailure.deadline: reason = "deadline"
        default: reason = "initializationFailed"
        }
        throw StreamInitializationFailure(id: assigned, reason: reason)
      }
      throw error
    }
  }
  private static func start(
    storage: MessageEventWatchStorage, filter: MessageEventFilter, output: Int32,
    deadline: ContinuousClock.Instant?, then: Follow, assigned: (UUID?) -> Void
  ) throws {
    let deadlineLimit = ContinuousClock.now.advanced(by: .seconds(30))
    let clock = ReplayClock(until: min(deadline ?? deadlineLimit, deadlineLimit))
    try clock.check()
    let writer = try RecordWriter(borrowing: output)
    let consumer = try MessageEventPollWait(output: output)
    try consumer.checkConnection()
    let source = storage.source
    let anchor = try SourceAnchor(storage)
    try anchor.verifyReadReady()
    let schema = try SourceSchema.preflight(
      path: source, isCancelled: { ContinuousClock.now >= clock.end }
    ) { db, schema in
      try qualifySource(db, schema, scoped: filter.conversations != nil)
    }
    try clock.check()
    try anchor.verify()
    try consumer.checkConnection()
    let stream = try ExistingEventJournalLease.provision(
      parent: storage.registry.parent, registry: storage.registry.name, assigned: { assigned($0) }
    ) { _ in
      try clock.check()
    }
    let id = try MessageEventStreamID(stream.id.uuidString.lowercased())
    let path = storage.registry.journal(id)
    let lease = try Creator.initialize(
      path: path, stream: stream, filter: filter, identity: anchor.value,
      schema: schema.digest, deadline: clock.end)
    defer { withExtendedLifetime(lease) {} }
    let cursor = try MessageEventCursor(stream: id, filter: filter.digest, sequence: 0)
    func remaining() throws -> Int {
      try clock.check()
      let left = ContinuousClock.now.duration(to: clock.end).components
      let ms = left.seconds * 1000 + left.attoseconds / 1_000_000_000_000_000
      guard ms > 0 else { throw ReadFailure.deadline }
      return Int(min(ms, 30000))
    }
    let baselineStart = ContinuousClock.now
    let status = try Capture.run(
      storage: storage, stream: id, milliseconds: remaining(), lease: lease, mode: .reconcile)
    if let limit = MessageEventCaptureLimit(rawValue: status) { throw limit }
    guard status == "success" else {
      throw InitialCaptureFailure(rawValue: status) ?? .captureFailed
    }
    let baselineTime = baselineStart.duration(to: .now)
    let state = try syncBeforeReplay(path, lease, cursor, clock)
    guard state.head == 0, state.events == 0, state.generation == 1 else { throw Bad.store }
    try lease.validate()
    try clock.check()
    let frame = MessageEventWatchControl.started(cursor)
    try writer.writeRecord(
      Output.encodeCompactSuccess(tool: "messages", data: frame),
      deadline: min(clock.end, .now.advanced(by: .seconds(2))))
    try writer.close()
    assigned(nil)
    try then(lease, cursor, baselineTime)
  }
}
