import AppleKit
import CryptoKit
import EventJournal
import Foundation
import SQLite3

enum V: Equatable {
  case i(Int64)
  case b(Data)
  func int() throws -> Int64 {
    guard case .i(let n) = self else { throw Bad.store }
    return n
  }
  func bytes(_ count: Int? = nil) throws -> Data {
    guard case .b(let d) = self, count == nil || d.count == count else { throw Bad.store }
    return d
  }
}
final class Journal {
  var closed = false, committing = false
  var before: StateWitness?, intended: StateWitness?
  let session: LeasedConnection
  let db: OpaquePointer
  let deadline: ContinuousClock.Instant
  let recovering: Bool
  var cache: [String: OpaquePointer] = [:]
  var vmInterrupted = false
  func installDeadlineGuard() {
    sqlite3_progress_handler(
      db, 256,
      { raw in
        guard let raw else { return 1 }
        let j = Unmanaged<Journal>.fromOpaque(raw).takeUnretainedValue()
        if ContinuousClock.now >= j.deadline { j.vmInterrupted = true }
        return j.vmInterrupted ? 1 : 0
      }, Unmanaged.passUnretained(self).toOpaque())
  }
  func withCatalog<T>(_ operation: () throws -> T) throws -> T {
    defer { installDeadlineGuard() }
    return try MessageEventCatalogBudget.run(on: db, until: deadline, operation)
  }
  func clearGuard() { sqlite3_progress_handler(db, 0, nil, nil) }
  var meta: PersistedEventMetadata!
  var selection: FilterMembership!
  var head: Int64 = 0, writes = 0, seen = 0
  var window = MessageEventJournalLimits.CaptureWindow()
  var events: Int { window.eventCount }
  let empty = Data(SHA256.hash(data: Data()))
  let stamp = Date().ISO8601Format(
    .iso8601(timeZone: .gmt).year().month().day().time(includingFractionalSeconds: true).timeZone(
      separator: .colon))
  var captureMode = "reconcile"
  let retainedLease: RecoveryLease
  init(
    _ path: String, _ deadline: ContinuousClock.Instant, _ lease: RecoveryLease,
    recovering: Bool = false, role: EventRole = EVENT_WRITE
  ) throws {
    retainedLease = lease
    self.deadline = deadline
    self.recovering = recovering
    session = try LeasedConnection(path: path, role: role, lease: lease, journalLimit: 768 << 20)
    db = session.database
  }
  deinit { if !closed { try? closeForRecovery() } }
  func clearStaging() throws {
    try exec("DELETE FROM seen")
    guard try one("SELECT 1 FROM seen LIMIT 1") == nil else { throw Bad.store }
  }
  func check() throws {
    guard ContinuousClock.now < deadline else { throw SQLiteReadTransaction.Failure.deadline }
  }
  func exec(_ sql: String) throws {
    let rc = policy_exec(db, sql)
    guard rc == SQLITE_OK else { throw Failure.sqlite(rc) }
  }
  func run<T>(_ sql: String, _ args: [V], _ body: (OpaquePointer) throws -> T) throws -> T {
    try check()
    let s: OpaquePointer
    if let existing = cache[sql] {
      s = existing
    } else {
      var tmp: OpaquePointer?
      let rc = policy_prepare(db, sql, &tmp)
      guard rc == SQLITE_OK, let tmp else { throw Failure.sqlite(rc) }
      cache[sql] = tmp
      s = tmp
    }
    defer {
      sqlite3_reset(s)
      sqlite3_clear_bindings(s)
    }
    guard sqlite3_bind_parameter_count(s) == args.count else { throw Bad.args }
    for (j, v) in args.enumerated() {
      let i = Int32(j + 1)
      let rc: Int32
      switch v {
      case .i(let n): rc = sqlite3_bind_int64(s, i, n)
      case .b(let d):
        rc = d.withUnsafeBytes {
          sqlite3_bind_blob(
            s, i, $0.baseAddress, Int32($0.count),
            unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
      }
      guard rc == SQLITE_OK else { throw Failure.sqlite(rc) }
    }
    return try body(s)
  }
  func one(_ sql: String, _ args: [V] = []) throws -> [V]? {
    try run(sql, args) { s in
      let rc = policy_step(s)
      if rc == SQLITE_DONE { return nil }
      guard rc == SQLITE_ROW else { throw Failure.sqlite(rc) }
      let row = try (0..<sqlite3_column_count(s)).map { i -> V in
        switch sqlite3_column_type(s, i) {
        case SQLITE_INTEGER: return .i(try integer(s, i))
        case SQLITE_BLOB: return .b(try blob(s, i, 263174))
        default: throw Bad.store
        }
      }
      guard policy_step(s) == SQLITE_DONE else { throw Bad.store }
      return row
    }
  }
  func write(_ sql: String, _ args: [V]) throws {
    try run(sql, args) { s in
      let rc = policy_step(s)
      guard rc == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw Failure.sqlite(rc) }
    }
  }
  func begin() throws {
    try withCatalog {
      try WriterSchema.begin(db, exclusive: recovering)
    }
    guard
      let r = try one(
        "SELECT format,initialized,stream_id,source_epoch,filter_bytes,filter_digest,generation,head,state_digest FROM meta WHERE id=1"
      ),
      try r[8].bytes(32) == digest(db, check, observe: { self.before = $0 })
    else { throw Bad.store }
    meta = try PersistedEventMetadata(
      format: r[0].int(), initialized: r[1].int(), stream: r[2].bytes(), source: r[3].bytes(),
      filterBytes: r[4].bytes(), filterDigest: r[5].bytes(), generation: r[6].int(),
      head: r[7].int())
    selection = FilterMembership(meta)
    guard let before else { throw Bad.store }
    try checkedSchema(db).validateBaselineMemberships(
      filter: meta.filter, expectedCount: before.memberships, checkpoint: check)
    head = meta.head
    let oldest = try checkedSchema(db).validatedOldestSequence(metadata: meta, checkpoint: check)
    if !meta.initialized {
      guard try one("SELECT id FROM baseline LIMIT 1") == nil, oldest == nil else {
        throw Bad.store
      }
    }
  }
  func add(
    _ c: Int64, _ m: Int64, _ cg: Data, _ mg: Data, _ h: Data, _ a: Data, _ f: Data, _ p: Data,
    _ old: [V]?
  ) throws {
    guard selection.accepts(cg) else { throw Bad.store }
    guard seen < MessageEventJournalLimits.memberships else {
      throw MessageEventCaptureLimit.memberships
    }
    guard h.count == 224, a.count == 7, a.allSatisfy({ $0 < 7 }), f.count == 100 else {
      throw Bad.store
    }
    var mask: Int64 = 0
    let id: Int64
    if let old {
      id = try old[0].int()
      let oh = try old[3].bytes(256)
      let oa = try old[4].bytes(8)
      let of = try old[5].bytes(100)
      let op = try old[6].bytes()
      for i in 0..<7 {
        let range = i * 32..<(i + 1) * 32
        guard h[range] != oh[range] || a[i] != oa[i] else { continue }
        if i == 2 || i == 3 {
          let facets = i == 2 ? [0, 1] : [2]
          let known = facets.contains { j in
            let r = 4 + 32 * j..<36 + 32 * j
            if f[1 + j] == 0 && of[1 + j] == 0 { return f[r] != of[r] }
            // A decoded dictionary lacked rp and now contains a validated,
            // nonempty list. This observes the first explicit marker.
            return i == 3 && j == 2 && of[3] == 7 && f[3] == 0
              && !f[r].elementsEqual(MessageEventSummaryRecord.emptyContainerFingerprint)
          }
          if !known {
            let key = i == 2 ? "date_edited" : "date_retracted"
            let date: (Data) throws -> String? = { data in
              guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Bad.store
              }
              return o[key] as? String
            }
            let before = try date(op)
            let after = try date(p)
            guard before != nil && after != nil && before != after else { continue }
          }
        }
        mask |= 1 << i
      }
      if old[1] != .i(m) || old[2] != .i(c) || h != oh.prefix(224) || a != oa.prefix(7) || f != of
        || p != op
      {
        try write(
          "UPDATE OR ROLLBACK baseline SET message_rowid=?,chat_rowid=?,component_hashes=?,availability=?,summary_facets=?,projection=? WHERE id=?",
          [.i(m), .i(c), .b(h + oh.suffix(32)), .b(a + oa.suffix(1)), .b(f), .b(p), .i(id)])
        writes += 1
      }
    } else {
      try write(
        "INSERT OR ROLLBACK INTO baseline(chat_guid,message_guid,message_rowid,chat_rowid,component_hashes,availability,summary_facets,projection) VALUES(?,?,?,?,?,?,?,?)",
        [
          .b(cg), .b(mg), .i(m), .i(c), .b(h + Data(repeating: 0, count: 32)), .b(a + Data([2])),
          .b(f), .b(p),
        ])
      id = sqlite3_last_insert_rowid(db)
      mask = 256
      writes += 1
    }
    try write("INSERT OR ROLLBACK INTO seen VALUES(?,?,0)", [.i(id), .i(mask)])
    seen += 1
  }
  func applyAttachment(_ row: [V], _ h: Data, _ status: UInt8) throws {
    let id = row[0]
    let oh = try row[1].bytes(256)
    let oa = try row[2].bytes(8)
    let changed = oh.suffix(32) != h || oa.last != status
    if changed {
      try write(
        "UPDATE OR ROLLBACK baseline SET component_hashes=?,availability=? WHERE id=?",
        [.b(oh.prefix(224) + h), .b(oa.prefix(7) + Data([status])), id])
      writes += 1
    }
    try write(
      "UPDATE OR ROLLBACK seen SET changes=changes|?,attachment_seen=1 WHERE id=?",
      [.i(changed ? 128 : 0), id])
  }
  func attachment(_ c: Int64, _ m: Int64, _ h: Data, _ s: String) throws {
    guard
      let r = try one(
        "SELECT b.id,b.component_hashes,b.availability FROM baseline b JOIN seen s ON s.id=b.id WHERE b.message_rowid=? AND b.chat_rowid=? LIMIT 2",
        [.i(m), .i(c)])
    else { throw Bad.store }
    try applyAttachment(r, h, code(s))
  }
  func emit(_ row: [V], _ changes: [String]) throws {
    guard head < Int64.max else { throw Failure.cap }
    guard !changes.isEmpty else { throw Bad.store }
    let seq = head + 1
    let id = changes == ["membership_disappeared"] ? nil : try row[3].int()
    let payload = try selection.reader.encode(
      sequence: seq, observedAt: stamp, captureMode: captureMode,
      conversation: MessageEventGUID(storedBytes: row[1].bytes()),
      message: MessageEventGUID(storedBytes: row[2].bytes()),
      rowID: id, changes: changes, availability: row[4].bytes(8), projection: row[5].bytes())
    let next = try window.appending(payloadSize: payload.count)
    try write("INSERT OR ROLLBACK INTO events VALUES(?,?)", [.i(seq), .b(payload)])
    window = next
    head = seq
    try check()
  }
  var attachmentsAvailable = true
  func finish(_ verifySource: () throws -> Void) throws {
    var last: Int64 = 0
    while let r = try one(
      "SELECT s.id,b.component_hashes,b.availability FROM seen s JOIN baseline b ON b.id=s.id WHERE s.id>? AND s.attachment_seen=0 ORDER BY s.id LIMIT 1",
      [.i(last)])
    {
      last = try r[0].int()
      try applyAttachment(
        r,
        attachmentsAvailable
          ? empty : Data(SHA256.hash(data: Data("missing-attachment-schema-v1".utf8))),
        attachmentsAvailable ? 0 : 1)
    }
    let cols = "b.id,b.chat_guid,b.message_guid,b.message_rowid,b.availability,b.projection"
    last = 0
    if meta.initialized {
      while let r = try one(
        "SELECT " + cols
          + ",s.changes FROM seen s JOIN baseline b ON b.id=s.id WHERE s.id>? AND s.changes!=0 ORDER BY s.id LIMIT 1",
        [.i(last)])
      {
        last = try r[0].int()
        let mask = try r[6].int()
        try autoreleasepool {
          try emit(
            r,
            mask & 256 != 0
              ? ["appeared"]
              : order.filter { name in
                components.firstIndex(of: name).map { mask & (1 << $0) != 0 } ?? false
              })
        }
      }
    }
    last = 0
    while let r = try one(
      "SELECT " + cols
        + " FROM baseline b WHERE b.id>? AND NOT EXISTS(SELECT 1 FROM seen s WHERE s.id=b.id) ORDER BY b.id LIMIT 1",
      [.i(last)])
    {
      last = try r[0].int()
      try autoreleasepool { try emit(r, ["membership_disappeared"]) }
      try write("DELETE FROM baseline WHERE id=?", [r[0]])
      writes += 1
    }
    if meta.initialized && writes == 0 {
      try verifySource()
      try exec("ROLLBACK")
      return
    }
    guard meta.generation < Int64.max,
      let totals = try one("SELECT count(*),coalesce(sum(length(payload)),0) FROM events")
    else { throw Failure.cap }
    var count = try totals[0].int()
    var bytes = try totals[1].int()
    while count > MessageEventJournalLimits.events || bytes > MessageEventJournalLimits.eventBytes {
      guard
        let first = try one(
          "SELECT sequence,length(payload) FROM events WHERE sequence<=? ORDER BY sequence LIMIT 1",
          [.i(meta.head)])
      else { throw Failure.cap }
      try write("DELETE FROM events WHERE sequence=?", [first[0]])
      count -= 1
      bytes -= try first[1].int()
    }
    try write(
      "UPDATE meta SET initialized=1,generation=?,head=? WHERE id=1",
      [.i(meta.generation + 1), .i(head)])
    let hash = try digest(db, check, observe: { self.intended = $0 })
    guard let intended else { throw Bad.store }
    try checkedSchema(db).validateBaselineMemberships(
      filter: meta.filter, expectedCount: intended.memberships, checkpoint: check)
    try write("UPDATE meta SET state_digest=? WHERE id=1", [.b(hash)])
    try check()
    try verifySource()
    try clearStaging()
    committing = true
    try exec("COMMIT")
    committing = false
  }
}
