import AppleKit
import Foundation

/// Shared persisted identity rules for creation's before/after readers. Every
/// helper uses the caller's bounded transaction; none opens a second snapshot.
enum MessagesConversationStore {
    enum Failure: Error { case invalidRequest, unsupportedSchema, invalidObservation, limitExceeded }
    enum WatermarkTable: String { case chat, message }

    struct Header {
        let rowid: Int64
        let style: Int64
        let guidBytes: Data?
    }

    struct Conversation: Sendable {
        let rowid: Int64
        let guid: String
        let style: Int64
        let recipients: [MessagesConversationAddress]

        func hasSameIdentity(as other: Conversation) -> Bool {
            rowid == other.rowid && style == other.style && guid.utf8.elementsEqual(other.guid.utf8)
                && recipients == other.recipients
        }
    }

    /// Validate both baseline and known post-send field prerequisites before any
    /// handoff. Additional verifier-specific requirements must also be preflighted.
    static func validateSchema(in scope: SQLiteReadTransaction) throws {
        let requirements: [(String, Set<String>)] = [
            ("chat", ["guid", "style", "service_name"]),
            ("message", ["guid", "text", "attributedbody", "is_from_me", "is_sent", "error", "service"]),
            ("handle", ["id"]),
            ("chat_handle_join", ["chat_id", "handle_id"]),
            ("chat_message_join", ["chat_id", "message_id"]),
            ("message_attachment_join", ["message_id", "attachment_id"]),
        ]
        for (table, required) in requirements {
            var objects = 0
            try scope.forEachRow("SELECT type,rootpage FROM sqlite_schema WHERE name=?1 COLLATE NOCASE", [table]) { row in
                guard objects == 0, case .text("table")? = row.values["type"],
                      case .integer(let root)? = row.values["rootpage"], root > 0 else {
                    throw Failure.unsupportedSchema
                }
                objects += 1
            }
            guard objects == 1 else { throw Failure.unsupportedSchema }
            var columns = Set<String>()
            try scope.forEachTableColumn(table) { row in
                guard case .text(let rawName)? = row.values["column_name"],
                      case .integer(let hidden)? = row.values["hidden_kind"] else {
                    throw Failure.unsupportedSchema
                }
                let name = rawName.lowercased()
                guard name != "_rowid_", !required.contains(name) || hidden == 0 else {
                    throw Failure.unsupportedSchema
                }
                columns.insert(name)
            }
            guard required.isSubset(of: columns) else { throw Failure.unsupportedSchema }
        }
    }

    static func greatestRowid(in table: WatermarkTable, scope: SQLiteReadTransaction) throws -> Int64 {
        var maximum: Int64?
        // The table name comes exclusively from the fixed enum, never caller text.
        try scope.forEachRow("SELECT _rowid_ AS id FROM \(table.rawValue) ORDER BY _rowid_ DESC LIMIT 1") { row in
            guard maximum == nil, case .integer(let id)? = row.values["id"], id > 0 else {
                throw Failure.invalidObservation
            }
            maximum = id
        }
        return maximum ?? 0
    }

    static func headers(group: Bool, in scope: SQLiteReadTransaction) throws -> [Header] {
        var headers: [Header] = []
        try scope.forEachRow("""
            SELECT _rowid_ AS id,style,service_name,
                   CASE WHEN typeof(guid)='text' THEN CAST(guid AS BLOB) END AS guid
            FROM chat WHERE CAST(service_name AS BLOB)=CAST('iMessage' AS BLOB)
            ORDER BY _rowid_
            """) { row in
            guard case .integer(let id)? = row.values["id"], id > 0,
                  case .integer(let style)? = row.values["style"], [43, 45].contains(style),
                  case .text("iMessage")? = row.values["service_name"] else {
                throw Failure.invalidObservation
            }
            guard style == (group ? 43 : 45) else { return }
            guard headers.count < 4096 else { throw Failure.limitExceeded }
            let guid: Data?
            if case .blob(let bytes)? = row.values["guid"] { guid = bytes } else { guid = nil }
            headers.append(Header(rowid: id, style: style, guidBytes: guid))
        }
        return headers
    }

    static func members(chatRowid: Int64, in scope: SQLiteReadTransaction) throws -> [MessagesConversationAddress] {
        guard chatRowid > 0 else { throw Failure.invalidRequest }
        var members: [MessagesConversationAddress] = []
        var seen = Set<MessagesConversationAddress>()
        try scope.forEachRow("""
            SELECT j.chat_id,j.handle_id,h._rowid_ AS actual_handle,
                   CASE WHEN typeof(h.id)='text' THEN CAST(h.id AS BLOB) END AS address
            FROM chat_handle_join j LEFT JOIN handle h ON h._rowid_=CAST(j.handle_id AS INTEGER)
            WHERE CAST(j.chat_id AS INTEGER)=CAST(?1 AS INTEGER) LIMIT 33
            """, [String(chatRowid)]) { row in
            guard members.count < 32 else { throw Failure.limitExceeded }
            guard case .integer(let chat)? = row.values["chat_id"], chat == chatRowid,
                  case .integer(let joined)? = row.values["handle_id"], joined > 0,
                  case .integer(let actual)? = row.values["actual_handle"], actual == joined,
                  case .blob(let bytes)? = row.values["address"], bytes.count <= 512,
                  let raw = String(data: bytes, encoding: .utf8) else { throw Failure.invalidObservation }
            let address: MessagesConversationAddress
            do { address = try MessagesConversationAddress.parse(raw) }
            catch { throw Failure.invalidObservation }
            guard seen.insert(address).inserted else { throw Failure.invalidObservation }
            members.append(address)
        }
        return members.sorted { $0.canonical < $1.canonical }
    }

    static func verifiedConversation(header: Header, members: [MessagesConversationAddress],
                                     in scope: SQLiteReadTransaction) throws -> Conversation {
        guard !members.isEmpty, let bytes = header.guidBytes, !bytes.isEmpty, bytes.count <= 512,
              let guid = String(data: bytes, encoding: .utf8),
              !guid.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw Failure.invalidObservation
        }
        var owner: Int64?
        try scope.forEachRow("""
            SELECT _rowid_ AS id FROM chat WHERE CAST(guid AS BLOB)=CAST(?1 AS BLOB) LIMIT 2
            """, [guid]) { row in
            guard owner == nil, case .integer(let id)? = row.values["id"], id == header.rowid else {
                throw Failure.invalidObservation
            }
            owner = id
        }
        guard owner == header.rowid else { throw Failure.invalidObservation }
        return Conversation(rowid: header.rowid, guid: guid, style: header.style, recipients: members)
    }
}
