import AppleKit
import Foundation

/// Shared persisted identity rules for creation's before/after readers. Every
/// helper uses the caller's bounded transaction; none opens a second snapshot.
enum MessagesConversationStore {
    enum Failure: Error { case invalidRequest, unsupportedSchema, invalidObservation, limitExceeded }
    struct Schema {
        let hasStoredHandleCountry: Bool
    }

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
    @discardableResult
    static func validateSchema(in scope: SQLiteReadTransaction) throws -> Schema {
        var hasStoredHandleCountry = false
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
                if table == "handle", name == "country", hidden == 0 { hasStoredHandleCountry = true }
                columns.insert(name)
            }
            guard required.isSubset(of: columns) else { throw Failure.unsupportedSchema }
        }
        return Schema(hasStoredHandleCountry: hasStoredHandleCountry)
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

    private struct StoredMember {
        let raw: String
        let hasUSCountry: Bool

        /// Negative evidence only for a complete one-member DM. A local number
        /// never identifies a recipient, even when its seven digits match.
        func excludes(_ recipient: MessagesConversationAddress) -> Bool {
            if raw.hasPrefix("urn:biz:") {
                let suffix = raw.dropFirst(8)
                guard suffix.utf8.count == 36, suffix.utf8.allSatisfy({ $0 < 128 }),
                      let id = UUID(uuidString: String(suffix)) else { return false }
                return id.uuidString.lowercased().utf8.elementsEqual(suffix.lowercased().utf8)
            }
            let local = Array(raw.utf8)
            guard hasUSCountry, local.count == 7, (50...57).contains(local[0]),
                  local.allSatisfy({ (48...57).contains($0) }) else { return false }
            if recipient.kind == .email { return true }
            let phone = Array(recipient.canonical.utf8)
            guard phone.count == 12, phone.starts(with: "+1".utf8),
                  (50...57).contains(phone[2]), (50...57).contains(phone[5]) else { return false }
            return !phone.suffix(7).elementsEqual(local)
        }
    }

    private static func storedMembers(chatRowid: Int64, hasStoredHandleCountry: Bool,
                                      in scope: SQLiteReadTransaction) throws -> [StoredMember] {
        guard chatRowid > 0 else { throw Failure.invalidRequest }
        var members: [StoredMember] = []
        // Select only a boolean from an ordinary optional column. Byte equality
        // prevents SQLite affinity, collation or a generated column supplying it.
        let usCountry = hasStoredHandleCountry
            ? "CASE WHEN typeof(h.country)='text' AND CAST(h.country AS BLOB) IN (X'5553',X'7573') THEN 1 ELSE 0 END"
            : "0"
        try scope.forEachRow("""
            SELECT j.chat_id,j.handle_id,h._rowid_ AS actual_handle,\(usCountry) AS us_country,
                   CASE WHEN typeof(h.id)='text' THEN CAST(h.id AS BLOB) END AS address
            FROM chat_handle_join j LEFT JOIN handle h ON h._rowid_=CAST(j.handle_id AS INTEGER)
            WHERE CAST(j.chat_id AS INTEGER)=CAST(?1 AS INTEGER) LIMIT 33
            """, [String(chatRowid)]) { row in
            guard members.count < 32 else { throw Failure.limitExceeded }
            guard case .integer(let chat)? = row.values["chat_id"], chat == chatRowid,
                  case .integer(let joined)? = row.values["handle_id"], joined > 0,
                  case .integer(let actual)? = row.values["actual_handle"], actual == joined,
                  case .integer(let usCountry)? = row.values["us_country"],
                  case .blob(let bytes)? = row.values["address"], bytes.count <= 512,
                  let raw = String(data: bytes, encoding: .utf8) else { throw Failure.invalidObservation }
            members.append(.init(raw: raw, hasUSCountry: usCountry == 1))
        }
        return members
    }

    private static func addresses(_ stored: [StoredMember]) throws -> [MessagesConversationAddress] {
        var seen = Set<MessagesConversationAddress>()
        for member in stored {
            guard let address = try? MessagesConversationAddress.parse(member.raw),
                  seen.insert(address).inserted else { throw Failure.invalidObservation }
        }
        return seen.sorted { $0.canonical < $1.canonical }
    }

    static func members(chatRowid: Int64, in scope: SQLiteReadTransaction) throws -> [MessagesConversationAddress] {
        try addresses(storedMembers(chatRowid: chatRowid, hasStoredHandleCountry: false, in: scope))
    }

    static func matches(header: Header, requested: [MessagesConversationAddress], schema: Schema,
                        in scope: SQLiteReadTransaction) throws -> Bool {
        let dm = header.style == 45 && requested.count == 1
        let stored = try storedMembers(chatRowid: header.rowid, hasStoredHandleCountry: dm && schema.hasStoredHandleCountry,
                                       in: scope)
        if dm, stored.count == 1, stored[0].excludes(requested[0]) { return false }
        return try addresses(stored) == requested
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
