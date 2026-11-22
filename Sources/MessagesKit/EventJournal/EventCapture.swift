import AppleKit
import CryptoKit
import Darwin
import EventJournal
import Foundation
import SQLite3

enum Capture {
  static func run(
    storage: MessageEventWatchStorage, stream: MessageEventStreamID,
    milliseconds ms: Int, lease: RecoveryLease, mode: MessageEventWatchLoop.CaptureMode
  ) throws -> String {
    guard (1...30000).contains(ms) else { throw Bad.args }
    try storage.checkSource()
    let src = storage.source
    let dst = storage.registry.journal(stream)
    defer { withExtendedLifetime(lease) {} }
    try lease.validate()
    guard src != dst else { throw Bad.args }
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(ms))
    let byteLimit = 256 << 20
    let journal = try Journal(dst, deadline, lease)
    journal.captureMode = mode.rawValue
    var initialAnchor: SourceAnchor?
    var status = "success"
    var associations = 0
    do {
      try journal.begin()
      try lease.validate()
      guard journal.meta.stream == stream else { throw Bad.store }

      guard
        let expected = try journal.one("SELECT source_identity,schema_digest FROM meta WHERE id=1"),
        try validIdentity(expected[0].bytes(29))
      else { throw Bad.store }
      let anchor = try SourceAnchor(storage)
      initialAnchor = anchor
      guard try expected[0].bytes(29) == anchor.value else { throw ContinuityFailure.sourceReset }
      let expectedSchema = try expected[1].bytes(32)
      try anchor.verifyReadReady()
      let reserve = min(byteLimit / 4, 3 << 20)

      try MessageEventSourceSchema.withSnapshot(
        path: src,
        limits: .init(
          timeout: Double(ms) / 1000, rows: 995903, bytes: byteLimit - reserve,
          valueBytes: min(8 << 20, byteLimit - reserve)),
        isCancelled: { ContinuousClock.now >= deadline }
      ) { db in
        try anchor.verify()
        let schema = try SourceSchema.read(db)
        guard schema.digest == expectedSchema else { throw ContinuityFailure.schemaChanged }
        try schema.validatePartialPair(db, attachmentFields: MessageEventAttachmentSource.columns)
        journal.attachmentsAvailable = schema.canReadAttachments
        let scoped = journal.meta.filter.conversations != nil
        let (msg, att) = try captureQueries(db, schema, scoped: scoped)
        let passes = try MessageEventConversationLookup.passes(for: journal.meta.filter, in: db)

        for pass in passes {
          try db.forEachRow(msg, pass.bindings) { r in
            try autoreleasepool {
              try journal.check()
              let member = try membership(r, pass)
              let (c, m) = (member.chatRowID, member.messageRowID)
              let (cg, mg) = (member.chatGUID, member.messageGUID)
              let fields = MessageEventMessageSource.Field.allCases
              let inputs = try fields.map { try MessageEventMessageSource.Observation($0, row: r) }
              let v = inputs.map { Observation($0.status.rawValue, $0.bytes) }
              let old = try journal.priorMembership(cg, mg)
              let rawDigest = v[4].fingerprint
              let projected = try MessageEventReactionProjection.encode(
                Dictionary(uniqueKeysWithValues: zip(fields, inputs)))
              let record = try journal.summaryRecord(
                v[4], digest: rawDigest, old: old, projection: projected, dates: v[5...6])
              var hashes = Data()
              var av = Data()
              let parts = [
                Array(v[0..<4]), [v[4]], [v[5]], [v[6]], Array(v[7...12]), Array(v[13...15]),
                Array(v[16...17]),
              ]
              for (index, sub) in parts.enumerated() {
                if index == 2 || index == 3 {
                  if record[0] == 1, let old {
                    let oldHashes = try old[3].bytes(256)
                    let oldAvailability = try old[4].bytes(8)
                    hashes.append(oldHashes[32 * index..<32 * (index + 1)])
                    av.append(oldAvailability[index])
                    continue
                  }
                  let (digest, status) = try MessageEventSummaryRecord.component(
                    index == 2 ? .edit : .retraction, date: sub[0], record: record)
                  hashes.append(digest)
                  av.append(status)
                } else {
                  if index == 1 {
                    hashes.append(rawDigest)
                  } else {
                    var h = SHA256()
                    for obs in sub { obs.append(to: &h) }
                    hashes.append(Data(h.finalize()))
                  }
                  av.append(
                    try code(sub.first(where: { $0.status != "available" })?.status ?? "available"))
                }
              }
              try journal.add(c, m, cg, mg, hashes, av, record, projected, old)
            }
          }
        }
        try journal.check()

        if let att {
          for pass in passes {
            let count = try MessageEventAttachmentSource.scan(
              in: db, sql: att, pass: pass,
              remaining: 500_000 - associations
            ) { chat, message, digest, status in
              try journal.attachment(chat, message, digest, status)
            }
            associations += count
          }
        }
        try journal.check()
        try anchor.verify()
      }

      let verifySource: () throws -> Void = {
        try lease.validate()
        try journal.check()
        try anchor.verifyReadReady()
        // Fresh read observes DDL committed while the first snapshot was pinned.
        try MessageEventSourceSchema.withSnapshot(
          path: src,
          limits: .init(
            timeout: Double(ms) / 1000, rows: 4097, bytes: reserve,
            valueBytes: min(1 << 20, reserve)), isCancelled: { ContinuousClock.now >= deadline }
        ) { latest in
          guard try SourceSchema.read(latest).digest == expectedSchema else {
            throw ContinuityFailure.schemaChanged
          }
        }
        try anchor.verify()
        try journal.check()
      }
      try journal.finish(verifySource)
      try lease.validate()
    } catch {
      journal.clearGuard()
      var rollbackFailure: Error?
      if sqlite3_get_autocommit(journal.db) == 0 {
        do { try journal.exec("ROLLBACK") } catch { rollbackFailure = error }
      }
      if journal.committing || rollbackFailure != nil {
        return journal.classifyRecovery(path: dst, lease: lease)
      }
      switch error {
      case SQLiteReadTransaction.Failure.deadline: status = "deadline"
      case SQLiteReadTransaction.Failure.cancelled where ContinuousClock.now >= deadline:
        status = "deadline"
      case SQLiteReadTransaction.Failure.byteLimit:
        status = MessageEventCaptureLimit.byteLimit.rawValue
      case SQLiteReadTransaction.Failure.valueLimit:
        status = MessageEventCaptureLimit.valueLimit.rawValue
      case SQLiteReadTransaction.Failure.rowLimit:
        status = MessageEventCaptureLimit.rowLimit.rawValue
      case SourceSchema.Failure.schemaCapacity:
        status = MessageEventCaptureLimit.schemaCapacity.rawValue
      case SQLiteReadTransaction.Failure.database, SQLiteReadTransaction.Failure.couldNotOpen:
        status = "observationGap"
      case let limit as MessageEventCaptureLimit: status = limit.rawValue
      case MessageEventCatalogBudget.Failure.deadline: status = "deadline"
      case MessageEventCatalogBudget.Failure.workLimit, Failure.cap,
        MessageEventStateDigest.Failure.limitExceeded:
        status = "capacity"
      case Failure.sqlite(let code) where code & 255 == SQLITE_FULL: status = "journalCapacity"
      default: status = journal.vmInterrupted ? "deadline" : String(describing: error)
      }
      if let anchor = initialAnchor {
        do { try anchor.verify() } catch ContinuityFailure.sourceReset {
          status = "sourceReset"
        } catch {}
      }
    }
    return status
  }
}
