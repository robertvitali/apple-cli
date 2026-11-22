import AppleKit
import CryptoKit
import Darwin
import EventJournal
import Foundation
import SQLite3

enum Creator {
  static func initialize(
    path: String, stream: ExistingEventJournalLease.ProvisionedStream, filter: MessageEventFilter,
    identity: Data, schema: Data, deadline: ContinuousClock.Instant
  ) throws -> RecoveryLease {
    guard identity.count == 29, schema.count == 32 else { throw Bad.store }
    let id = stream.id
    let lease = try stream.initializationLease()
    let journal = try Journal(path, deadline, lease, role: EVENT_INITIALIZE)
    defer { try? journal.closeForRecovery() }
    var committed = false
    defer {
      if !committed, sqlite3_get_autocommit(journal.db) == 0 { try? journal.exec("ROLLBACK") }
    }
    try journal.withCatalog {
      guard policy_protect(journal.db) == SQLITE_OK, leased_configure(journal.db) == SQLITE_OK
      else { throw Bad.store }
      try journal.exec("BEGIN EXCLUSIVE")
      for sql in MessageEventJournalFormat.createMain { try journal.exec(sql) }
    }
    let fresh = UUID().uuidString.lowercased()
    let filterBytes = filter.canonicalBytes
    try journal.write(
      "INSERT INTO meta VALUES(1,1,0,?,?,?,?,?,?,0,0,?)",
      [
        .b(Data(id.uuidString.lowercased().utf8)), .b(Data(fresh.utf8)), .b(filterBytes),
        .b(Data(SHA256.hash(data: filterBytes))), .b(identity), .b(schema),
        .b(Data(repeating: 0, count: 32)),
      ])
    let hash = try digest(journal.db, journal.check)
    try journal.write("UPDATE meta SET state_digest=? WHERE id=1", [.b(hash)])
    try lease.validate()
    try journal.check()
    try journal.exec("COMMIT")
    committed = true
    try journal.closeForRecovery()
    try lease.validate()
    return lease
  }
}
