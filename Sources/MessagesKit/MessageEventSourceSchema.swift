import AppleKit
import CryptoKit
import Foundation

/// The v1 source fingerprint covers the stored schema, independently of its physical layout.
struct MessageEventSourceSchema {
    enum Failure: Error { case schemaCapacity, invalidSourceSchema }

    let digest: Data
    let hasAttachment: Bool
    let hasEdge: Bool
    var canReadAttachments: Bool { hasAttachment && hasEdge }

    /// Allow the 4,096 catalog objects plus room for planner statistics and the pin query.
    /// Apply this to every new source connection, including the final schema recheck.
    static func withSnapshot<T>(path: String, limits: SQLiteReadTransaction.Limits,
                                isCancelled: @escaping () -> Bool,
                                _ body: (SQLiteReadTransaction) throws -> T) throws -> T {
        var bounded = limits
        // SQLite parses the source catalog before our 2 MiB serialized-catalog check.
        // Sampling its parsed schema also covers wide definitions below the setup row limit.
        bounded.snapshotSchemaBytes = min(limits.snapshotSchemaBytes ?? 128 << 20, 128 << 20)
        // The source file header can request a much larger cache for the membership scans.
        // SQLite can load planner statistics before it applies the connection's cache target.
        bounded.snapshotCacheBytes = min(limits.snapshotCacheBytes ?? 16 << 20, 16 << 20)
        bounded.pageCacheKiB = min(limits.pageCacheKiB ?? 2048, 2048)
        bounded.allowsUnlikelyHint = true
        bounded.snapshotSetupRows = min(limits.snapshotSetupRows ?? 8192, 8192)
        // Two unfiltered passes may each walk 250,000 memberships. Count actual
        // full scans across the snapshot, including repeated inner join scans
        // chosen from stale statistics. Indexed lookups do not spend this budget.
        bounded.fullScanSteps = min(limits.fullScanSteps ?? 2_000_000, 2_000_000)
        do {
            return try SQLiteReader.withBoundedReadTransaction(path: path, limits: bounded,
                                                               isCancelled: isCancelled, body)
        } catch SQLiteReadTransaction.Failure.snapshotSetupLimit {
            throw Failure.schemaCapacity
        } catch SQLiteReadTransaction.Failure.fullScanLimit {
            throw MessageEventCaptureLimit.sourceScanSteps
        }
    }

    /// Qualify the actual read plans in the same snapshot before reserving a stream slot.
    static func preflight(path: String, isCancelled: @escaping () -> Bool,
                          qualify: (SQLiteReadTransaction, Self) throws -> Void) throws -> Self {
        // The catalog has at most 4,096 rows. The remaining allowance is shared by
        // physical-column and query-plan checks. No source messages are fetched here.
        try withSnapshot(path: path, limits: .init(
            timeout: 5, rows: 8192, bytes: 3 << 20, valueBytes: 1 << 20), isCancelled: isCancelled) { db in
            let schema = try read(db)
            try qualify(db, schema)
            return schema
        }
    }

    static func read(_ db: SQLiteReadTransaction) throws -> Self {
        let sql = """
            SELECT CASE WHEN typeof(type)='text' AND length(CAST(type AS BLOB)) BETWEEN 1 AND 7 THEN CAST(type AS BLOB) END AS kind,
                   CASE WHEN typeof(name)='text' AND length(CAST(name AS BLOB)) BETWEEN 1 AND 1024 THEN CAST(name AS BLOB) END AS name,
                   CASE WHEN typeof(tbl_name)='text' AND length(CAST(tbl_name AS BLOB)) BETWEEN 1 AND 1024 THEN CAST(tbl_name AS BLOB) END AS owner,
                   typeof(sql) AS ddl_kind,
                   CASE WHEN typeof(sql)='text' AND length(CAST(sql AS BLOB))<=32768 THEN CAST(sql AS BLOB) END AS ddl,
                   CASE WHEN type IN ('table','view') THEN CASE name COLLATE NOCASE
                       WHEN 'attachment' THEN 1 WHEN 'message_attachment_join' THEN 2 ELSE 0 END ELSE 0 END AS attachment_object
            FROM main.sqlite_schema
            """
        let kinds = Set(["table", "view", "index", "trigger"].map { Data($0.utf8) })
        var leaves: [Data] = []
        var byteCount = 0
        var attachment = false
        var edge = false
        try db.forEachRow(sql) { row in
            guard leaves.count < 4096, case .blob(let kind)? = row.values["kind"], kinds.contains(kind),
                  case .blob(let name)? = row.values["name"], case .blob(let owner)? = row.values["owner"],
                  case .integer(let object)? = row.values["attachment_object"] else { throw Failure.schemaCapacity }
            var leaf = SHA256()
            func append(_ tag: UInt8, _ bytes: Data) throws {
                byteCount += 9 + bytes.count
                guard byteCount <= 2 << 20 else { throw Failure.schemaCapacity }
                leaf.update(data: [tag])
                withUnsafeBytes(of: Int64(bytes.count).bigEndian) { leaf.update(bufferPointer: $0) }
                leaf.update(data: bytes)
            }
            try append(1, kind)
            try append(2, name)
            try append(3, owner)
            switch (row.values["ddl_kind"], row.values["ddl"]) {
            case (.text("text")?, .blob(let ddl)?): try append(4, ddl)
            case (.text("null")?, .null?): try append(5, Data())
            default: throw Failure.schemaCapacity
            }
            leaves.append(Data(leaf.finalize()))
            attachment = attachment || object == 1
            edge = edge || object == 2
        }
        var digest = SHA256()
        digest.update(data: Data("messages-source-schema-v1".utf8))
        withUnsafeBytes(of: Int64(leaves.count).bigEndian) { digest.update(bufferPointer: $0) }
        for leaf in leaves.sorted(by: { $0.lexicographicallyPrecedes($1) }) { digest.update(data: leaf) }
        return Self(digest: Data(digest.finalize()), hasAttachment: attachment, hasEdge: edge)
    }

    /// If either attachment table is missing, validate the surviving object before
    /// reporting missing-schema availability. A full pair is validated by the capture query.
    func validatePartialPair(_ db: SQLiteReadTransaction, attachmentFields: Set<String>) throws {
        guard !canReadAttachments else { return }
        if hasAttachment {
            _ = try MessagesAttachmentSnapshot.storedColumns(in: db, table: "attachment", required: [],
                optional: attachmentFields, unsupported: Failure.invalidSourceSchema)
        }
        if hasEdge {
            _ = try MessagesAttachmentSnapshot.storedColumns(in: db, table: "message_attachment_join",
                required: ["message_id", "attachment_id"], usesRowid: false, unsupported: Failure.invalidSourceSchema)
        }
    }
}
