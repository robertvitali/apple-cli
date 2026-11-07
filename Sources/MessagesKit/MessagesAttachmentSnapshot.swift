import AppleKit
import Foundation

/// Reads attachment membership inside the caller's pinned transaction. The
/// caller must verify exact conversation/message identity in that same scope.
enum MessagesAttachmentSnapshot {
    enum Failure: Error, Equatable {
        case invalidTarget, unsupportedSchema, incompleteIdentity, duplicateIdentity, tooManyAttachments
    }

    struct Item: Sendable {
        let identity: MessagesAttachmentRetrievalState.Identity
        let filename: String?
        let transfer: ChatDB.NativeAttachmentTransfer
    }

    static func read(in scope: SQLiteReadTransaction, messageRowid: Int64) throws -> [Item] {
        guard messageRowid > 0 else { throw Failure.invalidTarget }
        let attachmentColumns = try storedColumns(in: scope, table: "attachment", required: ["guid"],
            optional: ["filename", "transfer_state"], unsupported: Failure.unsupportedSchema)
        _ = try storedColumns(in: scope, table: "message_attachment_join", required: ["message_id", "attachment_id"],
            usesRowid: false, unsupported: Failure.unsupportedSchema)
        let filename = attachmentColumns.contains("filename")
            ? "CASE WHEN typeof(a.filename)='text' AND length(CAST(a.filename AS BLOB)) BETWEEN 1 AND 4096 THEN CAST(a.filename AS BLOB) END"
            : "NULL"
        // LEFT JOIN preserves dangling membership. The integer guard prevents
        // SQLite numeric coercion from manufacturing an attachment identity.
        // Keep the usual integer index lookup bounded while also inspecting
        // malformed keys that SQLite can coerce to this message. Nonnegative
        // REALs truncate toward zero. TEXT and BLOB sort at or after empty
        // TEXT. At Int64.max that same sentinel covers saturating REALs.
        let numericCeiling = messageRowid == .max ? "''" : "(CAST(?1 AS INTEGER)+1)"
        let sql = """
            SELECT typeof(maj.message_id) AS message_type,
                   typeof(maj.attachment_id) AS edge_type,
                   CASE WHEN typeof(maj.attachment_id)='integer' THEN maj.attachment_id END AS edge_id,
                   a._rowid_ AS attachment_rowid,
                   CASE WHEN typeof(a.guid)='text' AND length(CAST(a.guid AS BLOB)) BETWEEN 1 AND 4096
                        THEN CAST(a.guid AS BLOB) END AS attachment_guid,
                   \(filename) AS filename,
                   \(NativeAttachmentTransferDecoder.projection(columns: attachmentColumns))
            FROM message_attachment_join AS maj
            LEFT JOIN attachment AS a ON typeof(maj.attachment_id)='integer' AND a._rowid_=maj.attachment_id
            WHERE (maj.message_id BETWEEN CAST(?1 AS INTEGER) AND \(numericCeiling) OR maj.message_id>='')
              AND (maj.message_id=CAST(?1 AS INTEGER) OR CAST(maj.message_id AS INTEGER)=CAST(?1 AS INTEGER))
            LIMIT 1025
            """
        var items: [Item] = []
        var rowids = Set<Int64>()
        var guids = Set<Data>()
        try scope.forEachRow(sql, [String(messageRowid)]) { row in
            guard items.count < MessagesAttachmentRetrievalState.maximumAttachments else { throw Failure.tooManyAttachments }
            guard case .text("integer")? = row.values["message_type"],
                  case .text("integer")? = row.values["edge_type"],
                  case .integer(let edge)? = row.values["edge_id"],
                  case .integer(let rowid)? = row.values["attachment_rowid"], rowid == edge,
                  let guid = try exactText(row.values["attachment_guid"]),
                  let identity = MessagesAttachmentRetrievalState.Identity(rowid: rowid, guid: guid)
            else { throw Failure.incompleteIdentity }
            guard rowids.insert(rowid).inserted, guids.insert(identity.guid).inserted else { throw Failure.duplicateIdentity }
            let path: String?
            path = try exactText(row.values["filename"])
            items.append(Item(identity: identity, filename: path, transfer: NativeAttachmentTransferDecoder.decode(row)))
        }
        return items
    }

    /// Callers project TEXT as BLOB after a storage-class check, retaining bytes
    /// that Foundation may otherwise remove during display-oriented decoding.
    static func exactText(_ value: SQLiteReader.Row.Value?) throws -> String? {
        guard case .blob(let bytes)? = value else { return nil }
        guard let text = String(data: bytes, encoding: .utf8), text.utf8.elementsEqual(bytes) else {
            throw SQLiteReadTransaction.Failure.invalidText
        }
        return text
    }

    /// Require physical columns for every observation used by this reader.
    /// Table metadata and values come from the same pinned snapshot.
    static func storedColumns(in scope: SQLiteReadTransaction, table: String,
                              required: Set<String>, optional: Set<String> = [],
                              usesRowid: Bool = true, unsupported: any Error) throws -> Set<String> {
        var ordinary = false
        try scope.forEachRow("SELECT type, rootpage FROM sqlite_schema WHERE name=?1 COLLATE NOCASE", [table]) { row in
            guard !ordinary, case .text("table")? = row.values["type"],
                  case .integer(let root)? = row.values["rootpage"], root > 0 else { throw unsupported }
            ordinary = true
        }
        guard ordinary else { throw unsupported }
        let used = required.union(optional)
        var stored = Set<String>()
        try scope.forEachTableColumn(table) { row in
            guard case .text(let name)? = row.values["column_name"],
                  case .integer(let hidden)? = row.values["hidden_kind"] else { throw unsupported }
            let key = name.lowercased()
            guard !(usesRowid && key == "_rowid_"), hidden == 0 || !used.contains(key) else { throw unsupported }
            if hidden == 0 { stored.insert(key) }
        }
        guard required.isSubset(of: stored) else { throw unsupported }
        return stored
    }
}
