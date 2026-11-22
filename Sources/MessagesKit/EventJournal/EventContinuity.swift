import AppleKit
import CryptoKit
import Darwin
import EventJournal
import Foundation

enum ContinuityFailure: String, Error {
  case observationGap, sourceReset, sourceUnavailable, schemaChanged, schemaCapacity,
    invalidSourceSchema
}
// Recheck the source and journal locations before each filesystem observation.
struct SourceAnchor {
  private let storage: MessageEventWatchStorage
  private let anchor: MessageEventSourceAnchor
  var value: Data { anchor.identity }

  init(_ storage: MessageEventWatchStorage) throws {
    try storage.checkSource()
    self.storage = storage
    anchor = try translated { try MessageEventSourceAnchor(path: storage.source) }
  }

  func verify() throws {
    try storage.checkSource()
    try translated { try anchor.verify() }
  }

  func verifyReadReady() throws {
    try storage.checkSource()
    try translated { try anchor.verifyReadReady() }
  }
}
private func translated<T>(_ operation: () throws -> T) throws -> T {
  do { return try operation() } catch let error as MessageEventSourceAnchor.Failure {
    switch error {
    case .sourceReset: throw ContinuityFailure.sourceReset
    case .sourceUnavailable: throw ContinuityFailure.sourceUnavailable
    case .observationGap: throw ContinuityFailure.observationGap
    }
  }
}
func validIdentity(_ data: Data) -> Bool { MessageEventSourceAnchor.isValidStoredIdentity(data) }

typealias SourceSchema = MessageEventSourceSchema
func captureQueries(_ db: SQLiteReadTransaction, _ schema: SourceSchema, scoped: Bool) throws -> (
  String, String?
) {
  let bindings = scoped ? ["1"] : []
  let messages = try MessageEventMessageSource.query(in: db, filtered: scoped)
  let attachments =
    try schema.canReadAttachments
    ? MessageEventAttachmentSource.query(in: db, filtered: scoped) : nil
  _ = try qualified(db, messages, bindings)
  if let attachments { _ = try qualified(db, attachments, bindings) }
  return (messages, attachments)
}
func qualifySource(_ db: SQLiteReadTransaction, _ schema: SourceSchema, scoped: Bool) throws {
  do {
    try schema.validatePartialPair(db, attachmentFields: MessageEventAttachmentSource.columns)
    _ = try captureQueries(db, schema, scoped: scoped)
    if scoped { try MessageEventConversationLookup.requireIndex(in: db) }
  } catch Failure.invalid {
    throw SourceSchema.Failure.invalidSourceSchema
  } catch MessageEventSourcePlan.Failure.unsupportedPlan {
    throw SourceSchema.Failure.invalidSourceSchema
  }
}
