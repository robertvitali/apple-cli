import AppleKit
import CryptoKit
import EventJournal
import Foundation
import SQLite3

enum Failure: Error {
  case args, invalid, cap, plan
  case sqlite(Int32)
}

func membership(_ row: Row, _ pass: MessageEventConversationLookup.Pass) throws
  -> MessageEventMessageSource.Membership
{
  do { return try MessageEventMessageSource.Membership(row, pass: pass) } catch {
    throw Failure.invalid
  }
}

func evidence(_ row: Row, _ field: MessageEventMessageSource.Field) throws -> Observation {
  do {
    let observation = try MessageEventMessageSource.Observation(field, row: row)
    return Observation(observation.status.rawValue, observation.bytes)
  } catch { throw Failure.invalid }
}

func qualified(_ db: SQLiteReadTransaction, _ sql: String, _ bindings: [String] = []) throws
  -> [String]
{
  try MessageEventSourcePlan.requireStreaming(sql, bindings: bindings, in: db)
}
func code(_ s: String) throws -> UInt8 {
  let statuses = [
    "available", "missing-schema", "null", "wrong-type", "invalid-value", "malformed", "limited",
    "missing-key",
  ]
  guard let i = statuses.firstIndex(of: s) else { throw Failure.invalid }
  return UInt8(i)
}
func safeGUID(_ b: Data) -> Bool {
  (try? MessageEventGUID(storedBytes: b)) != nil
}
