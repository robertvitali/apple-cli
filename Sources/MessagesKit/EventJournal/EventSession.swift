import EventJournal
import Foundation
import SQLite3

final class LeasedConnection {
  private var ticket = EventConnection()
  let database: OpaquePointer

  init(path: String, role: EventRole, lease: RecoveryLease, journalLimit: Int64 = 768 << 20) throws
  {
    let witness = EventWitness(
      context: Unmanaged.passUnretained(lease).toOpaque(),
      check: { context, operation in
        guard let context else { return -1 }
        let lease = Unmanaged<RecoveryLease>.fromOpaque(context).takeUnretainedValue()
        return (try? lease.witness(operation)) ?? -1
      },
      retain: { context in
        if let context { _ = Unmanaged<RecoveryLease>.fromOpaque(context).retain() }
      },
      release: { context in
        if let context { Unmanaged<RecoveryLease>.fromOpaque(context).release() }
      }
    )
    let rc = event_open(&ticket, role, path, witness, 512 << 20, journalLimit)
    guard rc == SQLITE_OK, let raw = ticket.database else { throw Failure.sqlite(rc) }
    do {
      try MessageEventJournalLimits.configure(raw)
    } catch {
      guard event_close(&ticket) == SQLITE_OK else { throw Failure.sqlite(SQLITE_INTERNAL) }
      throw error
    }
    database = raw
  }

  func close() throws {
    guard ticket.database != nil else { return }
    let rc = event_close(&ticket)
    guard rc == SQLITE_OK else { throw Failure.sqlite(rc) }
  }
  deinit { if ticket.database != nil { _ = event_close(&ticket) } }
}
