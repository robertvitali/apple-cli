import AppleKit
import Darwin
import EventJournal
import Foundation

typealias RecoveryLease = ExistingEventJournalLease.Recovery

extension RecoveryLease {
  func witness(_ operation: Int32) throws -> Int32 {
    let event: JournalEvent
    switch Int(operation) {
    case L_CHECK: event = .check
    case L_CREATED: event = .created
    case L_DELETED: event = .deleted
    default: throw ExistingEventJournalLease.Failure.changed
    }
    return try observe(event) ? 1 : 0
  }

  func syncRecoveryPaths() throws {
    try synchronize()
  }
}
