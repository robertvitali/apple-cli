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
        let attachmentColumns = try columns(in: scope, table: "attachment")
        let joinColumns = try columns(in: scope, table: "message_attachment_join")
        guard attachmentColumns.contains("guid"), !attachmentColumns.contains("_rowid_"),
              joinColumns.isSuperset(of: ["message_id", "attachment_id"]) else { throw Failure.unsupportedSchema }
        let filename = attachmentColumns.contains("filename")
            ? "CASE WHEN typeof(a.filename)='text' AND length(CAST(a.filename AS BLOB)) BETWEEN 1 AND 4096 THEN CAST(a.filename AS BLOB) END"
            : "NULL"
        // LEFT JOIN preserves dangling membership. The integer guard prevents
        // SQLite numeric coercion from manufacturing an attachment identity.
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
            WHERE maj.message_id=CAST(?1 AS INTEGER)
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

    private static func columns(in scope: SQLiteReadTransaction, table: String) throws -> Set<String> {
        var ordinaryTables = 0
        try scope.forEachRow("SELECT type, rootpage FROM sqlite_schema WHERE name=?1 COLLATE NOCASE", [table]) { row in
            guard case .text("table")? = row.values["type"],
                  case .integer(let root)? = row.values["rootpage"], root > 0 else { throw Failure.unsupportedSchema }
            ordinaryTables += 1
        }
        guard ordinaryTables == 1 else { throw Failure.unsupportedSchema }
        var names = Set<String>()
        try scope.forEachTableColumn(table) { row in
            guard case .text(let name)? = row.values["column_name"] else { throw Failure.unsupportedSchema }
            names.insert(name.lowercased())
        }
        return names
    }
}
