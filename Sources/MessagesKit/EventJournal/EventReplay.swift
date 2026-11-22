import AppleKit
import CoreFoundation
import CryptoKit
import Darwin
import EventJournal
import Foundation
import SQLite3

enum ReadFailure: Error { case deadline, replaced, changed, page }

final class ReplayClock {
  var interrupted = false
  let end: ContinuousClock.Instant
  init(milliseconds: Int) { end = .now.advanced(by: .milliseconds(milliseconds)) }
  init(until deadline: ContinuousClock.Instant) { end = deadline }
  func check() throws { if ContinuousClock.now >= end { throw ReadFailure.deadline } }
}

func sql(_ db: OpaquePointer, _ text: String) throws {
  guard policy_exec(db, text) == SQLITE_OK else { throw Bad.store }
}

extension ReplayClock {
  func install(on db: OpaquePointer) {
    sqlite3_progress_handler(
      db, 500,
      { context in
        guard let context else { return 1 }
        let clock = Unmanaged<ReplayClock>.fromOpaque(context).takeUnretainedValue()
        guard ContinuousClock.now < clock.end else {
          clock.interrupted = true
          return 1
        }
        return 0
      }, Unmanaged.passUnretained(self).toOpaque())
  }

  func startSnapshot(_ db: OpaquePointer, configure: Bool) throws {
    defer { install(on: db) }
    try MessageEventCatalogBudget.run(on: db, until: end) {
      if configure {
        guard sqlite3_db_readonly(db, "main") == 1, policy_protect(db) == SQLITE_OK else {
          throw Bad.store
        }
        try sql(db, "PRAGMA query_only=ON")
        try sql(db, "PRAGMA trusted_schema=OFF")
        try statement(db, "PRAGMA query_only") { s in
          guard policy_step(s) == SQLITE_ROW, try integer(s, 0) == 1, policy_step(s) == SQLITE_DONE
          else { throw Bad.store }
        }
      }
      try beginSnapshot(db)
    }
  }
}
func beginSnapshot(_ db: OpaquePointer) throws {
  try sql(db, "BEGIN")
  try checkedSchema(db).validateMain()
  guard sqlite3_txn_state(db, "main") == SQLITE_TXN_READ else { throw ReadFailure.page }
}

func syncBeforeReplay(
  _ path: String, _ lease: RecoveryLease, _ cursor: MessageEventCursor,
  _ clock: ReplayClock
) throws -> StateWitness {
  try clock.check()
  try lease.validate()
  let gate = try Journal(path, clock.end, lease, recovering: true)
  try gate.begin()
  guard let witness = gate.before, gate.meta.initialized else { throw Bad.store }
  var lostPosition: MessageEventCursorFailure?
  do {
    try checkedSchema(gate.db).validateReplayCursor(
      cursor, metadata: gate.meta, budget: gate.pageIntegrityBudget("writer"))
  } catch let failure as MessageEventCursorFailure
    where failure == .expired || failure == .streamMismatch
  {
    // A recovered window must be durable before advising the consumer to replace its checkpoint.
    lostPosition = failure
  }
  try gate.finishBarrier(lease)
  if let lostPosition { throw lostPosition }
  return witness
}

enum Replay {
  static func deliver(
    registry: MessageEventWatchRegistry, cursor: MessageEventCursor,
    mode: MessageEventDelivery.Mode, output: Int32,
    milliseconds limit: Int, lease: RecoveryLease,
    onValidated: ((Int64, Int64?) throws -> Void)? = nil
  ) throws -> Int64 {
    defer { withExtendedLifetime(lease) {} }
    let path = registry.journal(cursor.stream)
    let clock = ReplayClock(milliseconds: limit)
    let writer = try RecordWriter(borrowing: output)
    try MessageEventPollWait(output: output).checkConnection()
    let synced = try syncBeforeReplay(path, lease, cursor, clock)
    try lease.validate()
    try clock.check()
    let connection = try LeasedConnection(path: path, role: EVENT_INSPECT, lease: lease)
    let db = connection.database
    func deliver() throws -> Int64 {
      defer {
        sqlite3_progress_handler(db, 0, nil, nil)
        withExtendedLifetime(clock) {}
      }
      do {
        try clock.startSnapshot(db, configure: true)
        try lease.validate()
        let reader = try MessageEventReplayReader(journal: checkedSchema(db))
        let actual = try checkedSchema(db).verifiedStateDigest(
          budget: integrityBudget("reader", until: clock.end, restore: { clock.install(on: db) })
        ) {
          try digest(db, clock.check)
        }
        guard actual == synced.digest else { throw ReadFailure.changed }
        try statement(db, "SELECT source_identity,schema_digest FROM meta WHERE id=1") { s in
          guard policy_step(s) == SQLITE_ROW, try validIdentity(blob(s, 0, 29)),
            try blob(s, 1, 32).count == 32
          else { throw Bad.store }
        }
        let meta = try statement(
          db,
          "SELECT format,initialized,stream_id,source_epoch,filter_bytes,filter_digest,generation,head FROM meta WHERE id=1"
        ) { s in
          guard policy_step(s) == SQLITE_ROW else { throw Bad.store }
          return try PersistedEventMetadata(
            format: integer(s, 0), initialized: integer(s, 1), stream: blob(s, 2, 36),
            source: blob(s, 3, 36), filterBytes: blob(s, 4, 263174), filterDigest: blob(s, 5, 32),
            generation: integer(s, 6), head: integer(s, 7))
        }
        guard meta.initialized, meta.generation == synced.generation, meta.head == synced.head
        else { throw Bad.store }
        let selection = FilterMembership(meta)
        try checkedSchema(db).validateBaselineMemberships(
          filter: meta.filter, expectedCount: synced.memberships, checkpoint: clock.check)
        let oldest = try checkedSchema(db).validatedOldestSequence(
          metadata: meta, checkpoint: clock.check)
        try cursor.validateReplay(
          stream: meta.stream, filter: meta.filter.digest, head: meta.head, oldestRetained: oldest)
        let last = try reader.replay(
          after: cursor.sequence, through: meta.head,
          checkpoint: clock.check, validateLease: lease.validate,
          beginSnapshot: {
            try lease.validate()
            try clock.startSnapshot(db, configure: false)
          },
          releaseSnapshot: {
            try sql(db, "COMMIT")
          }, onReady: onValidated.map { callback in { try callback(meta.head, oldest) } },
          write: { row in
            try autoreleasepool {
              let delivery = try selection.reader.decode(
                row.payload, sequence: row.sequence, mode: mode)
              let bytes = try Output.encodeCompactSuccess(tool: "messages", data: delivery)
              try writer.writeRecord(
                bytes, deadline: min(clock.end, .now.advanced(by: .seconds(2))))
            }
          })
        try writer.close()
        return last
      } catch {
        if !(error is RecordWriterError), clock.interrupted { throw ReadFailure.deadline }
        throw error
      }
    }
    let last = try deliver()
    try connection.close()
    return last
  }
}
