import AppleKit
import CoreFoundation
import CryptoKit
import Darwin
import EventJournal
import Foundation
import SQLite3

struct FilterMembership {
  let members: Set<Data>?
  let reader: MessageEventDelivery.Reader
  init(_ meta: PersistedEventMetadata) {
    reader = .init(metadata: meta)
    members = meta.filter.conversations.map { Set($0.map(\.bytes)) }
  }
  func accepts(_ bytes: Data) -> Bool { members?.contains(bytes) ?? true }

}

enum Bad: Error { case args, store, payload, gap }
let components = [
  "content", "native_context", "edit", "undo_send", "reaction", "delivery", "read", "attachment",
]
let order = [
  "appeared", "content", "native_context", "edit", "reaction", "attachment", "delivery", "read",
  "undo_send", "membership_disappeared",
]
let statuses = [
  "available", "missing-schema", "null", "wrong-type", "invalid-value", "malformed", "limited",
]
func blob(_ stmt: OpaquePointer, _ col: Int32, _ max: Int) throws -> Data {
  guard sqlite3_column_type(stmt, col) == SQLITE_BLOB else { throw Bad.store }
  let n = Int(sqlite3_column_bytes(stmt, col))
  guard n > 0, n <= max, let p = sqlite3_column_blob(stmt, col) else { throw Bad.store }
  return Data(bytes: p, count: n)
}
func integer(_ stmt: OpaquePointer, _ n: Int32) throws -> Int64 {
  guard sqlite3_column_type(stmt, n) == SQLITE_INTEGER else { throw Bad.store }
  return sqlite3_column_int64(stmt, n)
}
func statement<T>(_ db: OpaquePointer, _ sql: String, _ body: (OpaquePointer) throws -> T) throws
  -> T
{
  var s: OpaquePointer?
  guard policy_prepare(db, sql, &s) == SQLITE_OK, let s else { throw Bad.store }
  defer { sqlite3_finalize(s) }
  return try body(s)
}
func digest(
  _ db: OpaquePointer, _ check: () throws -> Void, allowMissingWitness: Bool = false,
  observe: ((StateWitness) -> Void)? = nil
) throws -> Data {
  // This domain is part of the persisted v1 journal digest.
  let witness = try checkedSchema(db).stateWitness(
    domain: "fixture-state-v1", allowMissingWitness: allowMissingWitness, checkpoint: check)
  observe?(witness)
  return witness.digest
}
