import Foundation
import AppleKit

/// Read layer over `~/Library/Messages/chat.db` (WAL-aware, via the shared
/// `SQLiteReader` with `copyToTemp` for hot/locked data reads). Ports the SQL +
/// row-shaping of `mac_messages_mcp`'s `get_recent_messages`, `fuzzy_search_messages`,
/// `get_chats`, `_check_imessage_availability`, `find_handles_by_phone`,
/// `get_contact_name` (chat-fallback half), and `check_messages_db_access`.
public struct ChatDB {
    public static func defaultPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Messages/chat.db"
    }

    private let reader: SQLiteReader
    private let book: AddressBook
    // Caches for per-invocation sender resolution.
    private var chatDisplayNameCache: [String: String?] = [:]

    /// Open a reader for a data command. `copyToTemp` snapshots chat.db (+wal/shm)
    /// so a concurrently-writing Messages.app can't corrupt the read.
    ///
    /// PERF NOTE: `copyToTemp: true` copies the whole store (~hundreds of MB) on every
    /// invocation — the CLI pays per call what the long-running MCP paid once. It is a
    /// deliberate WAL-safety tradeoff and is correct; the diagnostic-only commands
    /// (`chats`, `check-availability`) touch tiny tables yet still copy. A future
    /// shared-core optimization (an `immutable=1` URI open, or `copyToTemp:false` for
    /// the light commands) would remove the copy — but that is a cross-domain
    /// `SQLiteReader` decision, tracked separately, not made here.
    public init(path: String = ChatDB.defaultPath(), book: AddressBook, copyToTemp: Bool = true) throws {
        self.reader = try SQLiteReader(path: path, copyToTemp: copyToTemp)
        self.book = book
    }

    // MARK: - Phone/handle resolution (MCP `_get_phone_formats` / `find_handles_by_phone`)

    /// US-number format variants tried against `handle.id`.
    public static func phoneFormats(_ normalized: String) -> [String] {
        var formats = [normalized]
        if normalized.hasPrefix("1") && normalized.count > 10 {
            formats.append(String(normalized.dropFirst()))
            formats.append("+" + normalized)
        } else if normalized.count == 10 {
            formats.append("1" + normalized)
            formats.append("+1" + normalized)
        }
        return formats
    }

    /// All handle ROWIDs for a phone number (multi-protocol: iMessage/SMS/RCS).
    public func handleRowIds(forPhone phone: String) -> [Int64] {
        let normalized = Fuzzy.normalizePhone(phone)
        if normalized.isEmpty { return [] }
        let formats = ChatDB.phoneFormats(normalized)
        let placeholders = formats.enumerated().map { "?\($0.offset + 1)" }.joined(separator: ", ")
        let sql = "SELECT ROWID FROM handle WHERE id IN (\(placeholders))"
        let rows = (try? reader.rows(sql, formats)) ?? []
        return rows.compactMap { $0.int("ROWID") }
    }

    public func handleRowIds(forEmail email: String) -> [Int64] {
        let rows = (try? reader.rows("SELECT ROWID FROM handle WHERE id = ?1", [email])) ?? []
        return rows.compactMap { $0.int("ROWID") }
    }

    // MARK: - Group-chat name mapping (MCP `get_chat_mapping`)

    /// room_name → display_name, for annotating group messages.
    public func chatMapping() -> [String: String] {
        var map: [String: String] = [:]
        let rows = (try? reader.rows("SELECT room_name, display_name FROM chat")) ?? []
        for row in rows {
            guard let room = row.text("room_name"), let display = row.text("display_name") else { continue }
            map[room] = display
        }
        return map
    }

    // MARK: - Sender resolution (MCP `get_contact_name`)

    /// Chat-table display-name fallback (second stage of `get_contact_name`).
    private mutating func chatDisplayName(forAddress address: String) -> String? {
        if let cached = chatDisplayNameCache[address] { return cached }
        let sql = """
            SELECT c.display_name AS display_name
            FROM handle h
            JOIN chat_handle_join chj ON h.ROWID = chj.handle_id
            JOIN chat c ON chj.chat_id = c.ROWID
            WHERE h.id = ?1 LIMIT 1
            """
        let rows = (try? reader.rows(sql, [address])) ?? []
        let name = rows.first?.text("display_name")
        let resolved: String? = (name?.isEmpty == false) ? name : nil
        chatDisplayNameCache[address] = resolved
        return resolved
    }

    /// Full sender resolution: AddressBook → chat display name → raw address.
    private mutating func senderName(isFromMe: Bool, address: String?) -> String {
        if isFromMe { return "You" }
        guard let address, !address.isEmpty else { return "Unknown" }
        if let abName = book.nameForHandle(address) { return abName }
        if let chatName = chatDisplayName(forAddress: address) { return chatName }
        return address
    }

    // MARK: - Recent (MCP `get_recent_messages`)

    public struct Message: Encodable {
        public let rowid: Int64
        public let date: Date          // ISO-8601 in JSON
        public let date_local: String  // MCP-format local string, for parity
        public let timestamp: Int64     // raw Apple ns
        public let is_from_me: Bool
        public let sender: String
        public let handle: String?      // phone/email address
        public let service: String?
        public let body: String
        public let group_name: String?
        public let has_attachments: Bool
    }

    private static let messageSelect = """
        SELECT m.ROWID AS rowid, m.date AS date, m.text AS text, m.attributedBody AS attributedBody,
               m.is_from_me AS is_from_me, m.handle_id AS handle_rowid, m.cache_roomnames AS cache_roomnames,
               m.service AS service, m.cache_has_attachments AS cache_has_attachments, h.id AS address
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        """

    /// Fetch recent messages across all chats (optionally filtered to handle rowids),
    /// newest-first, limited. Decodes body from `text` or `attributedBody`; skips
    /// content-less rows (MCP parity).
    public mutating func recent(hours: Int, handleRowIds: [Int64]?, limit: Int) -> [Message] {
        // Filter semantics are load-bearing for privacy: `nil` = NO filter requested
        // (return all recent messages), but a non-nil EMPTY array = a filter WAS
        // requested and matched zero handles → return NOTHING. Without this guard the
        // empty-array case would skip the `handle_id IN (...)` clause below and leak
        // every recent conversation for a never-messaged contact/handle.
        if let ids = handleRowIds, ids.isEmpty { return [] }
        let threshold = MessageTime.thresholdNanos(hoursAgo: hours)
        var sql = ChatDB.messageSelect + "\nWHERE m.date > ?1 "
        var binds = [String(threshold)]
        if let ids = handleRowIds, !ids.isEmpty {
            let placeholders = ids.enumerated().map { "?\($0.offset + 2)" }.joined(separator: ", ")
            sql += "AND m.handle_id IN (\(placeholders)) "
            binds.append(contentsOf: ids.map(String.init))
        }
        sql += "ORDER BY m.date DESC LIMIT \(max(0, limit))"
        let rows = (try? reader.rows(sql, binds)) ?? []
        return shape(rows: rows, mapping: chatMapping())
    }

    private mutating func shape(rows: [SQLiteReader.Row], mapping: [String: String]) -> [Message] {
        var out: [Message] = []
        for row in rows {
            guard let body = messageBody(row) else { continue }
            let rawDate = row.int("date") ?? 0
            let date = MessageTime.date(fromRaw: rawDate)
            let isFromMe = (row.int("is_from_me") ?? 0) != 0
            let address = row.text("address")
            let sender = senderName(isFromMe: isFromMe, address: address)
            var group: String? = nil
            // Python truthiness, deliberately: the oracle keeps '' in chat_mapping and filters
            // at USE (`if group_chat_name:`), so an empty display_name yields NO annotation.
            // Binding the Optional("") straight through gave the wire a THREE-state group_name
            // (absent / "" / "Name") against the oracle's two, so a consumer testing
            // `group_name is not None` misclassified 1:1 messages as group messages — and
            // `--text` printed a bare "[] ". Measured: 4 of 52 messages in a 6-hour window.
            if let room = row.text("cache_roomnames"), let name = mapping[room], !name.isEmpty {
                group = name
            }
            out.append(Message(
                rowid: row.int("rowid") ?? 0,
                date: date,
                date_local: MessageTime.localString(from: date),
                timestamp: rawDate,
                is_from_me: isFromMe,
                sender: sender,
                handle: address,
                service: row.text("service"),
                body: body,
                group_name: group,
                has_attachments: (row.int("cache_has_attachments") ?? 0) != 0
            ))
        }
        return out
    }

    /// Body from `text`, else decoded `attributedBody`, else nil (skip).
    private func messageBody(_ row: SQLiteReader.Row) -> String? {
        if let text = row.text("text"), !text.isEmpty { return text }
        if let blob = row.data("attributedBody"), let decoded = AttributedBody.decode(blob),
           !decoded.isEmpty { return decoded }
        return nil
    }

    // MARK: - Fuzzy search (MCP `fuzzy_search_messages`)

    public struct ScoredMessage: Encodable {
        public let rowid: Int64
        public let date: Date
        public let date_local: String
        public let timestamp: Int64
        public let is_from_me: Bool
        public let sender: String
        public let handle: String?
        public let service: String?
        public let body: String
        public let group_name: String?
        public let score: Double
    }

    public struct SearchResult { public let matches: [ScoredMessage]; public let scanned: Int; public let truncated: Bool }

    static let fuzzySoftCap = 10_000

    /// Two-pass search: SQL LIKE pre-filter (+ all attributedBody-only rows) →
    /// exact-substring (score 1.0) or WRatio ≥ threshold. `hours == 0` = all time.
    /// `match`: `.fuzzy` (default, WRatio), `.contains` (substring), `.exact`.
    public mutating func search(term: String, hours: Int, threshold: Double, match: SearchMatch) -> SearchResult {
        let likeParam = "%" + escapeLike(term) + "%"
        var where_ = "(m.text LIKE ?1 ESCAPE '\\' OR (m.text IS NULL AND m.attributedBody IS NOT NULL))"
        var binds = [likeParam]
        if hours != 0 {
            let threshold = MessageTime.thresholdNanos(hoursAgo: hours)
            where_ = "m.date > ?2 AND " + where_
            binds.append(String(threshold))
        }
        let sql = ChatDB.messageSelect + "\nWHERE \(where_)\nORDER BY m.date DESC LIMIT \(ChatDB.fuzzySoftCap)"
        let rows = (try? reader.rows(sql, binds)) ?? []
        let mapping = chatMapping()

        let cleanedTerm = Fuzzy.cleanText(term).lowercased()
        let scaledThreshold = threshold * 100.0
        var scored: [(SQLiteReader.Row, String, Double)] = []
        for row in rows {
            guard let body = messageBody(row) else { continue }
            let candidate = Fuzzy.cleanText(body).lowercased()
            let score: Double
            switch match {
            case .exact:
                score = (candidate == cleanedTerm) ? 1.0 : 0.0
                if score == 0 { continue }
            case .contains:
                score = candidate.contains(cleanedTerm) ? 1.0 : 0.0
                if score == 0 { continue }
            case .fuzzy:
                if candidate.contains(cleanedTerm) {
                    score = 1.0
                } else {
                    let w = Fuzzy.wRatio(cleanedTerm, candidate)
                    if w < scaledThreshold { continue }
                    score = w / 100.0
                }
            }
            scored.append((row, body, score))
        }
        // Score desc; deterministic tiebreak by timestamp desc (newest first).
        scored.sort { $0.2 != $1.2 ? $0.2 > $1.2 : (($0.0.int("date") ?? 0) > ($1.0.int("date") ?? 0)) }

        var matches: [ScoredMessage] = []
        for (row, body, score) in scored {
            let rawDate = row.int("date") ?? 0
            let date = MessageTime.date(fromRaw: rawDate)
            let isFromMe = (row.int("is_from_me") ?? 0) != 0
            let address = row.text("address")
            let sender = senderName(isFromMe: isFromMe, address: address)
            var group: String? = nil
            // Python truthiness, deliberately: the oracle keeps '' in chat_mapping and filters
            // at USE (`if group_chat_name:`), so an empty display_name yields NO annotation.
            // Binding the Optional("") straight through gave the wire a THREE-state group_name
            // (absent / "" / "Name") against the oracle's two, so a consumer testing
            // `group_name is not None` misclassified 1:1 messages as group messages — and
            // `--text` printed a bare "[] ". Measured: 4 of 52 messages in a 6-hour window.
            if let room = row.text("cache_roomnames"), let name = mapping[room], !name.isEmpty {
                group = name
            }
            matches.append(ScoredMessage(
                rowid: row.int("rowid") ?? 0, date: date, date_local: MessageTime.localString(from: date),
                timestamp: rawDate, is_from_me: isFromMe, sender: sender, handle: address,
                service: row.text("service"), body: body, group_name: group, score: score))
        }
        return SearchResult(matches: matches, scanned: rows.count, truncated: rows.count >= ChatDB.fuzzySoftCap)
    }

    public enum SearchMatch: String { case fuzzy, contains, exact }

    private func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Named group chats (MCP `get_chats`)

    public struct Chat: Encodable {
        public let chat_identifier: String
        public let display_name: String
        public let guid: String?
        public let room_name: String?
        public let service_name: String?
        public let group_id: String?
        public let style: Int64?
    }

    public func namedChats() -> [Chat] {
        let sql = """
            SELECT chat_identifier, display_name, guid, room_name, service_name, group_id, style
            FROM chat WHERE display_name IS NOT NULL AND display_name != ''
            """
        let rows = (try? reader.rows(sql)) ?? []
        return rows.compactMap { row in
            guard let id = row.text("chat_identifier"), let name = row.text("display_name") else { return nil }
            return Chat(chat_identifier: id, display_name: name, guid: row.text("guid"),
                        room_name: row.text("room_name"), service_name: row.text("service_name"),
                        group_id: row.text("group_id"), style: row.int("style"))
        }
    }

    // MARK: - iMessage availability (MCP `_check_imessage_availability`)

    public struct Availability: Encodable {
        public let recipient: String
        public let available: Bool
        public let service: String    // "iMessage" | "SMS" | "none"
        public let is_email: Bool
        public let recommendation: String
        public let handles: [HandleStat]
        public struct HandleStat: Encodable {
            public let service: String?
            public let text_count: Int
            public let errors: Int
        }
    }

    public func availability(recipient: String) -> Availability {
        let isEmail = recipient.contains("@")
        var binds: [String]
        if isEmail {
            binds = [recipient]
        } else {
            let normalized = Fuzzy.normalizePhone(recipient)
            binds = normalized.isEmpty ? [] : ChatDB.phoneFormats(normalized)
        }

        var handleStats: [Availability.HandleStat] = []
        var hasIMessage = false
        if !binds.isEmpty {
            let placeholders = binds.enumerated().map { "?\($0.offset + 1)" }.joined(separator: ", ")
            let sql = """
                SELECT h.ROWID AS rowid, h.service AS service,
                       COUNT(m.guid) AS text_count,
                       COUNT(CASE WHEN m.error != 0 THEN 1 END) AS errors
                FROM handle h
                LEFT JOIN message m ON h.ROWID = m.handle_id
                WHERE h.id IN (\(placeholders))
                GROUP BY h.ROWID, h.service
                """
            let rows = (try? reader.rows(sql, binds)) ?? []
            for row in rows {
                let service = row.text("service")
                let textCount = Int(row.int("text_count") ?? 0)
                let errors = Int(row.int("errors") ?? 0)
                handleStats.append(.init(service: service, text_count: textCount, errors: errors))
                if errors < textCount, service == "iMessage" || service == "iMessageLite" {
                    hasIMessage = true
                }
            }
        }

        let service: String
        let recommendation: String
        if hasIMessage {
            service = "iMessage"
            recommendation = "✅ \(recipient) has iMessage available - messages will be sent via iMessage"
        } else if recipient.contains(where: { $0.isASCII && $0.isNumber }) { // MCP uses ASCII isdigit()
            service = "SMS"
            recommendation = "📱 \(recipient) does not have iMessage - messages will automatically fall back to SMS/RCS"
        } else {
            service = "none"
            recommendation = "❌ \(recipient) does not have iMessage and SMS is not available for email addresses"
        }
        return Availability(recipient: recipient, available: hasIMessage, service: service,
                            is_email: isEmail, recommendation: recommendation, handles: handleStats)
    }

    // MARK: - DB access diagnostic (MCP `check_messages_db_access`)

    public struct DBCheck: Encodable {
        public let path: String
        public let exists: Bool
        public let readable: Bool
        public let connected: Bool
        public let table_count: Int?
        public let has_message_table: Bool
        public let has_handle_table: Bool
        public let has_chat_table: Bool
        public let message_count: Int?
    }

    /// Diagnose chat.db access WITHOUT a temp copy (mirrors the MCP's direct open —
    /// the point is whether direct access works).
    public static func diagnose(path: String = ChatDB.defaultPath()) -> DBCheck {
        let exists = FileManager.default.fileExists(atPath: path)
        var readable = false, connected = false
        var tableCount: Int? = nil, msgCount: Int? = nil
        var hasMsg = false, hasHandle = false, hasChat = false
        if exists, let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) {
            readable = true
            try? h.close()
        }
        if exists, let db = try? SQLiteReader(path: path, copyToTemp: false) {
            connected = true
            if let r = try? db.query("SELECT count(*) AS c FROM sqlite_master"), let c = r.first?["c"] ?? nil {
                tableCount = Int(c)
            }
            if let t = try? db.query("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('message','handle','chat')") {
                let names = Set(t.compactMap { $0["name"] ?? nil })
                hasMsg = names.contains("message"); hasHandle = names.contains("handle"); hasChat = names.contains("chat")
            }
            if let c = try? db.query("SELECT COUNT(*) AS c FROM message"), let v = c.first?["c"] ?? nil {
                msgCount = Int(v)
            }
        }
        return DBCheck(path: path, exists: exists, readable: readable, connected: connected,
                       table_count: tableCount, has_message_table: hasMsg, has_handle_table: hasHandle,
                       has_chat_table: hasChat, message_count: msgCount)
    }
}
