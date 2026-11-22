import AppleKit
import CryptoKit
import Darwin
import EventJournal
import Foundation
import SQLite3

typealias StateWitness = MessageEventJournalSchema.StateWitness
extension Journal {
  // This writer owns all cached statements and no statement is executing here.
  func closeForRecovery() throws {
    guard !closed else { return }
    clearGuard()
    for s in cache.values { sqlite3_finalize(s) }
    cache.removeAll()
    try session.close()
    closed = true
  }

  func pageIntegrityBudget(_ phase: String) throws -> MessageEventJournalSchema.IntegrityBudget {
    try check()
    return integrityBudget(phase, until: deadline, restore: installDeadlineGuard)
  }
  func verifyIntegrity(phase: String = "writer") throws {
    try checkedSchema(db).verifyPageIntegrity(budget: pageIntegrityBudget(phase))
  }
  func finishBarrier(_ lease: RecoveryLease) throws {
    try lease.validate()
    try self.check()
    let mainRC = barrier_sync_main(self.db)
    guard mainRC == SQLITE_OK else { throw Failure.sqlite(mainRC) }
    try lease.syncRecoveryPaths()
    try self.check()
    try lease.validate()
    try self.exec("ROLLBACK")
    try self.closeForRecovery()
    try lease.validate()
  }

  func classifyRecovery(path: String, lease: RecoveryLease) -> String {
    do {
      try closeForRecovery()
      try lease.validate()
      let fresh = try Journal(path, .now.advanced(by: .seconds(5)), lease, recovering: true)
      try fresh.begin()
      guard let actual = fresh.before else { throw Bad.store }
      try fresh.verifyIntegrity(phase: "recovery")
      let outcome: String
      if actual == before {
        outcome = "old-consistent"
      } else if actual == intended {
        outcome = "new-consistent"
      } else {
        throw Bad.store
      }
      guard
        fresh.meta.stream.rawValue
          == URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
      else { throw Bad.store }
      try fresh.finishBarrier(lease)
      return outcome
    } catch {
      return "recovery-required"
    }
  }
}
