import AppleKit
import CryptoKit
import Foundation

/// Fingerprints attachment metadata for each physical (chat, message) membership in one source snapshot.
enum MessageEventAttachmentSource {
    enum Failure: Error { case identity, duplicate, order, field }

    // Field order is part of the v1 journal digest and of the aggregate availability decision.
    private enum Field: String, CaseIterable {
        case guid, transferState = "transfer_state", totalBytes = "total_bytes", mimeType = "mime_type"
        case uti, filename, transferName = "transfer_name", isSticker = "is_sticker", hidden = "hide_attachment"
    }
    static let columns = Set(Field.allCases.map(\.rawValue))

    static func query(in db: SQLiteReadTransaction, filtered: Bool) throws -> String {
        let invalid = MessageEventSourceSchema.Failure.invalidSourceSchema
        for (table, ids) in [("chat_message_join", ["chat_id", "message_id"]),
                             ("message_attachment_join", ["message_id", "attachment_id"])] {
            _ = try MessagesAttachmentSnapshot.storedColumns(in: db, table: table, required: Set(ids),
                usesRowid: false, unsupported: invalid)
        }
        let stored = try MessagesAttachmentSnapshot.storedColumns(in: db, table: "attachment",
            required: [], optional: columns, unsupported: invalid)
        var select = ["c.chat_id AS chat", "c.message_id AS message", "j.message_id AS member",
                      "j.attachment_id AS aid", "a._rowid_ AS actual",
                      NativeAttachmentTransferDecoder.projection(columns: stored),
                      NativeAttachmentFlagsDecoder.projection(columns: stored)]
        for field in [Field.guid, .mimeType, .uti, .filename, .transferName, .totalBytes] {
            let name = field.rawValue
            guard stored.contains(name) else {
                select += ["'missing-schema' AS \(name)_t", "NULL AS \(name)_v"]
                continue
            }
            let column = "a." + name
            select.append("typeof(\(column)) AS \(name)_t")
            if field == .totalBytes {
                select.append("CASE WHEN typeof(\(column))='integer' THEN \(column) END AS \(name)_v")
            } else {
                let bound = field == .guid ? " AND length(CAST(a.guid AS BLOB))<=1024" : ""
                select.append("CASE WHEN typeof(\(column))='text'\(bound) THEN CAST(\(column) AS BLOB) END AS \(name)_v")
            }
        }
        // A single membership usually matches few attachment links. Stale statistics from a
        // nearly empty link table can otherwise cause a full scan for every membership.
        let match = db.allowsUnlikelyHint ? "unlikely(j.message_id=c.message_id)" : "j.message_id=c.message_id"
        let joins = " FROM chat_message_join c CROSS JOIN message_attachment_join j ON \(match) LEFT JOIN attachment a ON a._rowid_=j.attachment_id"
        return "SELECT " + select.joined(separator: ",") + joins
            + (filtered ? " WHERE c.chat_id=CAST(?1 AS INTEGER)" : "") + " ORDER BY c.chat_id,c.message_id"
    }

    private static func integerBytes(_ value: Int64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private struct Observation {
        let status: String
        let bytes: Data
        init(_ status: String, _ bytes: Data = Data()) { self.status = status; self.bytes = bytes }

        func update(_ hash: inout SHA256) {
            let tag = Data(status.utf8)
            hash.update(data: integerBytes(Int64(tag.count)))
            hash.update(data: tag)
            hash.update(data: integerBytes(Int64(bytes.count)))
            hash.update(data: bytes)
        }
    }

    private static func observation(_ field: Field, row: SQLiteReader.Row) throws -> Observation {
        let name = field.rawValue
        switch field {
        case .transferState:
            let transfer = NativeAttachmentTransferDecoder.decode(row)
            return Observation(transfer.status == "unknown-state" ? "invalid-value" : transfer.status,
                               transfer.raw.map(integerBytes) ?? Data())
        case .isSticker, .hidden:
            let flags = NativeAttachmentFlagsDecoder.decode(row)
            let flag = field == .isSticker ? flags.is_sticker : flags.hide_attachment
            if case .integer(let value)? = row.values["native_attachment_" + name + "_value"] {
                return Observation(flag.status == "invalid-boolean" ? "invalid-value" : flag.status, integerBytes(value))
            }
            return Observation(flag.status)
        default: break
        }
        guard case .text(let type)? = row.values[name + "_t"] else { throw Failure.field }
        if type == "missing-schema" || type == "null" { return Observation(type) }
        let value = row.values[name + "_v"]
        if field == .guid {
            // Validate the stored bytes before decoding can consume a leading UTF-8 BOM.
            guard type == "text", case .blob(let bytes)? = value,
                  (try? MessageEventGUID(storedBytes: bytes)) != nil else { throw Failure.identity }
            return Observation("available", bytes)
        }
        if field == .totalBytes {
            guard type == "integer", case .integer(let size)? = value else { return Observation("wrong-type") }
            return Observation(size < 0 ? "invalid-value" : "available", integerBytes(size))
        }
        guard type == "text" else { return Observation("wrong-type") }
        guard case .blob(let bytes)? = value else { throw Failure.field }
        return bytes.isValidEventSourceUTF8 ? Observation("available", bytes) : Observation("malformed")
    }

    private struct Leaf {
        let rowID: Int64
        let guid: Data?
        let digest: SHA256.Digest
        let firstUnavailable: Int
        let status: String

        init(id: Int64, row: SQLiteReader.Row) throws {
            rowID = id
            let identifier = try observation(.guid, row: row)
            guid = identifier.status == "available" ? identifier.bytes : nil
            var hash = SHA256()
            if guid == nil { hash.update(data: integerBytes(id)) }
            var priority = Field.allCases.count
            var availability = "available"
            for (index, field) in Field.allCases.enumerated() {
                let value = field == .guid ? identifier : try observation(field, row: row)
                value.update(&hash)
                if availability == "available" && value.status != "available" {
                    priority = index
                    availability = value.status
                }
            }
            digest = hash.finalize()
            firstUnavailable = priority
            status = availability
        }

        static func before(_ a: Self, _ b: Self) -> Bool {
            switch (a.guid, b.guid) {
            case let (x?, y?) where x != y: return x.lexicographicallyPrecedes(y)
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.rowID < b.rowID
            }
        }
    }

    /// Visits completed groups in source order. The caller rolls back staged visits on any error.
    static func scan(in db: SQLiteReadTransaction, sql: String, pass: MessageEventConversationLookup.Pass,
                     remaining: Int, visit: (Int64, Int64, Data, String) throws -> Void) throws -> Int {
        guard (0...500_000).contains(remaining) else { throw MessageEventCaptureLimit.attachmentAssociations }
        var key: (Int64, Int64)?
        var leaves: [Leaf] = []
        var ids = Set<Int64>()
        var guidBytes = 0
        var total = 0
        func finishMembership() throws {
            guard let key else { return }
            leaves.sort(by: Leaf.before)
            var digest = SHA256()
            var priority = Field.allCases.count
            var status = "available"
            for leaf in leaves {
                digest.update(data: Data(leaf.digest))
                if leaf.firstUnavailable < priority {
                    priority = leaf.firstUnavailable
                    status = leaf.status
                }
            }
            try visit(key.0, key.1, Data(digest.finalize()), status)
            leaves.removeAll(keepingCapacity: true)
            ids.removeAll(keepingCapacity: true)
            guidBytes = 0
        }
        try db.forEachRow(sql, pass.bindings) { row in
            guard case .integer(let chat)? = row.values["chat"], chat > 0, pass.id == nil || pass.id == chat,
                  case .integer(let message)? = row.values["message"], message > 0,
                  row.values["member"] == .integer(message), case .integer(let id)? = row.values["aid"],
                  id > 0, row.values["actual"] == .integer(id) else { throw Failure.identity }
            if let key, key != (chat, message) {
                guard key < (chat, message) else { throw Failure.order }
                try finishMembership()
            }
            key = (chat, message)
            guard total < remaining else { throw MessageEventCaptureLimit.attachmentAssociations }
            guard leaves.count < 1_024 else { throw MessageEventCaptureLimit.attachmentsPerMembership }
            guard ids.insert(id).inserted else { throw Failure.duplicate }
            let leaf = try Leaf(id: id, row: row)
            guidBytes += leaf.guid?.count ?? 0
            guard guidBytes <= 65_536 else { throw MessageEventCaptureLimit.attachmentGUIDBytes }
            leaves.append(leaf)
            total += 1
        }
        try finishMembership()
        return total
    }
}
