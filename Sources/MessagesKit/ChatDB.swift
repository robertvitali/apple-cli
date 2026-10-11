import Foundation
import AppleKit
import Darwin

/// Read layer over `~/Library/Messages/chat.db` (WAL-aware, via the shared
/// `SQLiteReader` with `copyToTemp` for hot/locked data reads). Ports the SQL +
/// row-shaping of the Messages oracle's `get_recent_messages`, `fuzzy_search_messages`,
/// `get_chats`, `_check_imessage_availability`, `find_handles_by_phone`,
/// `get_contact_name` (chat-fallback half), and `check_messages_db_access`.
public struct ChatDB {
    public static func defaultPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Messages/chat.db"
    }

    private let reader: SQLiteReader
    private let book: AddressBook
    private let homeDirectoryForTilde: String
    // Caches for per-invocation sender resolution.
    private var chatDisplayNameCache: [String: String?] = [:]
    /// Memoized `chatIdentityAvailable()`. The probe is two `PRAGMA table_info` round-trips and
    /// its answer cannot change under a read-only reader, but `shape` ran it on every call —
    /// so a `recent` and its `search` sibling each paid it again after the filter had already
    /// resolved the same fact. One probe per instance now backs both.
    private var chatIdentityAvailableCache: Bool?

    /// Open a reader for a data command. `copyToTemp` snapshots chat.db (+wal/shm)
    /// so a concurrently-writing Messages.app can't corrupt the read.
    ///
    /// PERF NOTE: `copyToTemp: true` copies the whole store (~hundreds of MB) on every
    /// invocation — the CLI pays per call what the long-running oracle paid once. It is a
    /// deliberate WAL-safety tradeoff and is correct; the diagnostic-only commands
    /// (`chats`, `check-availability`) touch tiny tables yet still copy. A future
    /// shared-core optimization (an `immutable=1` URI open, or `copyToTemp:false` for
    /// the light commands) would remove the copy — but that is a cross-domain
    /// `SQLiteReader` decision, tracked separately, not made here.
    public init(path: String = ChatDB.defaultPath(), book: AddressBook, copyToTemp: Bool = true,
                homeDirectoryForTilde: String = FileManager.default.homeDirectoryForCurrentUser.path) throws {
        self.reader = try SQLiteReader(path: path, copyToTemp: copyToTemp)
        self.book = book
        self.homeDirectoryForTilde = homeDirectoryForTilde
    }

    // MARK: - Phone/handle resolution (oracle `_get_phone_formats` / `find_handles_by_phone`)

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

    // MARK: - Group-chat name mapping (oracle `get_chat_mapping`)

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

    // MARK: - Sender resolution (oracle `get_contact_name`)

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

    // MARK: - Recent (oracle `get_recent_messages`)

    /// One received/sent attachment, joined from `message_attachment_join` + `attachment`.
    ///
    /// `has_attachments` alone only tells a caller that something is there; it gives no way
    /// to identify or open it. Everything here is what an agent needs to actually reach the
    /// file: the stored `filename` is often `~`-prefixed and not directly openable, so
    /// `path` carries an absolute, standardized form when one can be derived. `exists` is a
    /// conservative local filesystem probe: `nil` means the path was not probed, while true/false
    /// says only whether a symlink-aware local-root check can see an item at that path right now.
    public struct Attachment: Encodable {
        public let rowid: Int64
        public let guid: String?
        public let filename: String?       // as stored, typically ~-relative
        public let path: String?           // tilde-expanded absolute path
        public let exists: Bool?           // nil when the path was not safe to probe
        public let mime_type: String?
        public let uti: String?
        public let transfer_name: String?  // original name as sent
        public let total_bytes: Int64?
        public let is_sticker: Bool?
        public let hide_attachment: Bool?

        enum CodingKeys: String, CodingKey {
            case rowid, guid, filename, path, exists, mime_type, uti, transfer_name, total_bytes
            case is_sticker, hide_attachment
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(rowid, forKey: .rowid)
            if let guid { try container.encode(guid, forKey: .guid) } else { try container.encodeNil(forKey: .guid) }
            if let filename { try container.encode(filename, forKey: .filename) } else { try container.encodeNil(forKey: .filename) }
            if let path { try container.encode(path, forKey: .path) } else { try container.encodeNil(forKey: .path) }
            if let exists {
                try container.encode(exists, forKey: .exists)
            } else {
                try container.encodeNil(forKey: .exists)
            }
            if let mime_type { try container.encode(mime_type, forKey: .mime_type) } else { try container.encodeNil(forKey: .mime_type) }
            if let uti { try container.encode(uti, forKey: .uti) } else { try container.encodeNil(forKey: .uti) }
            if let transfer_name {
                try container.encode(transfer_name, forKey: .transfer_name)
            } else {
                try container.encodeNil(forKey: .transfer_name)
            }
            if let total_bytes {
                try container.encode(total_bytes, forKey: .total_bytes)
            } else {
                try container.encodeNil(forKey: .total_bytes)
            }
            if let is_sticker {
                try container.encode(is_sticker, forKey: .is_sticker)
            } else {
                try container.encodeNil(forKey: .is_sticker)
            }
            if let hide_attachment {
                try container.encode(hide_attachment, forKey: .hide_attachment)
            } else {
                try container.encodeNil(forKey: .hide_attachment)
            }
        }
    }

    public struct Message: Encodable {
        public let rowid: Int64
        public let date: Date          // ISO-8601 in JSON
        public let date_local: String  // oracle-format local string, for parity
        public let timestamp: Int64     // raw Apple ns
        public let is_from_me: Bool
        public let sender: String
        public let handle: String?      // phone/email address
        public let service: String?
        public let body: String
        public let group_name: String?
        public let chat_identifier: String?  // ALWAYS present (null when no chat row)
        public let chat_guid: String?        // ALWAYS present (null when no chat row)
        public let is_group: Bool            // chat.style == 43
        public let has_attachments: Bool
        public let attachments: [Attachment]

        enum CodingKeys: String, CodingKey {
            case rowid, date, date_local, timestamp, is_from_me, sender, handle, service, body
            case group_name, chat_identifier, chat_guid, is_group, has_attachments, attachments
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(rowid, forKey: .rowid)
            try c.encode(date, forKey: .date)
            try c.encode(date_local, forKey: .date_local)
            try c.encode(timestamp, forKey: .timestamp)
            try c.encode(is_from_me, forKey: .is_from_me)
            try c.encode(sender, forKey: .sender)
            // `handle`, `service` and `group_name` keep the OMIT-WHEN-NIL shape the synthesized
            // encoder gave them before this struct grew a hand-written one. `group_name` in
            // particular is the oracle's two-state absent-or-name field (see `shape`), and turning
            // its absence into an explicit null would hand consumers a third state to misread.
            try c.encodeIfPresent(handle, forKey: .handle)
            try c.encodeIfPresent(service, forKey: .service)
            try c.encode(body, forKey: .body)
            try c.encodeIfPresent(group_name, forKey: .group_name)
            // The chat-identity keys are contract-documented as `string|null` and are ALWAYS
            // present, so that "this message is in no chat" is distinguishable from an older
            // binary that never emitted the key at all.
            try encodeOrNull(&c, chat_identifier, .chat_identifier)
            try encodeOrNull(&c, chat_guid, .chat_guid)
            try c.encode(is_group, forKey: .is_group)
            try c.encode(has_attachments, forKey: .has_attachments)
            try c.encode(attachments, forKey: .attachments)
        }
    }

    private static let messageSelect = """
        SELECT m.ROWID AS rowid, m.date AS date, m.text AS text, m.attributedBody AS attributedBody,
               m.is_from_me AS is_from_me, m.handle_id AS handle_rowid, m.cache_roomnames AS cache_roomnames,
               m.service AS service, m.cache_has_attachments AS cache_has_attachments, h.id AS address
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        """

    // MARK: - Chat identity (`chat_message_join` → `chat`)

    /// `chat.style` for a group chat. Apple's other value (45) is a 1:1 conversation.
    ///
    /// POLICY: any style other than 43 — including an absent or unrecognized one — is reported
    /// and filtered as non-group. So `is_group: false` covers four states: a real 1:1 chat, a
    /// message joined to no chat row, a store that cannot classify chats at all, and a chat row
    /// whose style is NULL or a value Apple does not ship today. The filter uses the same rule,
    /// so it KEEPS rows in all four. Two of the four are separately visible to a caller —
    /// `chat_identifier: null` for the no-chat case, and `direct_only_applied: false` for the
    /// cannot-classify case WHEN `--direct-only` was requested (without the flag that key is
    /// `false` on every store, so a plain read cannot tell the no-chat and cannot-classify
    /// cases apart).
    public static let groupChatStyle: Int64 = 43

    /// Which chat a message belongs to. `identifier`/`guid` are nil when the chat row
    /// carries none; the whole record is absent when the message maps to no chat at all.
    struct ChatIdentity {
        let identifier: String?
        let guid: String?
        let isGroup: Bool
    }

    /// SQL predicate excluding messages whose chat is a group.
    ///
    /// It picks the FIRST chat by chat ROWID — the same row `chat_identifier`, `chat_guid` and
    /// `is_group` are taken from — so the flag can never disagree with the fields it filters on.
    /// That promise is why both are gated on the SAME `chatIdentityAvailable()` check rather
    /// than on whatever each one minimally needs: a schema that could answer the filter but not
    /// the fields would drop rows while reporting every survivor as `is_group: false`.
    /// Applied in SQL rather than after shaping so `--limit N` still returns up to N direct
    /// messages instead of N-minus-the-groups. `COALESCE(..., 0)` keeps a message with no chat
    /// row: it has no style, and a message in no chat is not in a group chat.
    private static let directOnlyPredicate = """
        COALESCE((SELECT c.style FROM chat_message_join cmj JOIN chat c ON c.ROWID = cmj.chat_id \
        WHERE cmj.message_id = m.ROWID ORDER BY c.ROWID LIMIT 1), 0) != \(groupChatStyle)
        """

    /// Split ids into batches small enough for any SQLite build's host-parameter ceiling —
    /// the same defensive bound `attachmentsByMessage` applies, shared by the three id-keyed
    /// lookups below.
    private static func idChunks(_ ids: [Int64]) -> [[Int64]] {
        stride(from: 0, to: ids.count, by: 500).map { Array(ids[$0 ..< min($0 + 500, ids.count)]) }
    }

    private func chatMessageJoinAvailable() -> Bool {
        tableColumns("chat_message_join").isSuperset(of: ["message_id", "chat_id"])
    }

    /// Whether this store can answer "which chat is this message in?". A chat.db old or
    /// pruned enough to lack the join (or the `chat` columns) yields nulls and `is_group:false`
    /// rather than failing the whole read — the same posture the attachment join takes.
    private mutating func chatIdentityAvailable() -> Bool {
        if let cached = chatIdentityAvailableCache { return cached }
        let available = chatMessageJoinAvailable()
            && tableColumns("chat").isSuperset(of: ["chat_identifier", "guid", "style"])
        chatIdentityAvailableCache = available
        return available
    }

    /// Whether this store can honor `directOnly` and populate the chat-identity fields.
    public mutating func canIdentifyChats() -> Bool { chatIdentityAvailable() }

    /// The resolved `--direct-only` posture for ONE invocation: what the caller asked for, and
    /// whether this store can actually deliver it.
    ///
    /// Bound ONCE at the top of `run()` and threaded from there — the same discipline
    /// `MessagesWriteGuard.Gate` applies to the write posture, and for the same reason. The
    /// capability used to be re-probed independently by the filter and by the warning, so the
    /// two could disagree; now the filter, the stderr warning, and the `direct_only_applied`
    /// field are all reading one value decided at one moment.
    public struct DirectOnlyFilter: Sendable, Equatable {
        /// What `--direct-only` was set to.
        public let requested: Bool
        /// Whether the filter was actually applied. False when requested against a store that
        /// cannot say which chat a message belongs to — the fail-open case a machine consumer
        /// has to be able to SEE, because stdout JSON is the only channel it is told to trust.
        public let applied: Bool

        public static let off = DirectOnlyFilter(requested: false, applied: false)

        public init(requested: Bool, available: Bool) {
            self.requested = requested
            self.applied = requested && available
        }

        private init(requested: Bool, applied: Bool) {
            self.requested = requested
            self.applied = applied
        }
    }

    /// Probe the store ONCE and resolve the posture. Call at the top of `run()`.
    public mutating func resolveDirectOnly(requested: Bool) -> DirectOnlyFilter {
        // Short-circuit: an unrequested filter must not pay for two PRAGMA round-trips.
        guard requested else { return .off }
        return DirectOnlyFilter(requested: true, available: chatIdentityAvailable())
    }

    /// Chat identity for a batch of message rowids, keyed by message rowid.
    private mutating func chatIdentities(ids: [Int64]) -> [Int64: ChatIdentity] {
        guard !ids.isEmpty, chatIdentityAvailable() else { return [:] }
        var out: [Int64: ChatIdentity] = [:]
        for chunk in ChatDB.idChunks(ids) {
            let placeholders = chunk.indices.map { "?\($0 + 1)" }.joined(separator: ", ")
            let sql = """
                SELECT cmj.message_id AS message_id, c.chat_identifier AS chat_identifier,
                       c.guid AS chat_guid, c.style AS style
                FROM chat_message_join cmj
                JOIN chat c ON c.ROWID = cmj.chat_id
                WHERE cmj.message_id IN (\(placeholders))
                ORDER BY cmj.message_id, c.ROWID
                """
            for row in (try? reader.rows(sql, chunk.map(String.init))) ?? [] {
                // `ORDER BY … c.ROWID` + first-wins: a message joined to several chats reports
                // the lowest-ROWID one, matching `directOnlyPredicate`'s LIMIT 1.
                guard let mid = row.int("message_id"), out[mid] == nil else { continue }
                out[mid] = ChatIdentity(identifier: row.text("chat_identifier"),
                                        guid: row.text("chat_guid"),
                                        isGroup: row.int("style") == ChatDB.groupChatStyle)
            }
        }
        return out
    }

    /// Fetch recent messages across all chats (optionally filtered to handle rowids),
    /// newest-first, limited. Decodes body from `text` or `attributedBody`; body-less
    /// rows survive only when authoritative attachment rows exist. `directOnly` drops
    /// group-chat messages.
    public mutating func recent(hours: Int, handleRowIds: [Int64]?, limit: Int,
                                directOnly: DirectOnlyFilter = .off) -> [Message] {
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
        if directOnly.applied {
            sql += "AND \(ChatDB.directOnlyPredicate) "
        }
        sql += "ORDER BY m.date DESC LIMIT \(max(0, limit))"
        let rows = (try? reader.rows(sql, binds)) ?? []
        return shape(rows: rows, mapping: chatMapping())
    }

    /// Attachment metadata for a batch of message rowids, keyed by message rowid.
    ///
    /// Chunked defensively: SQLite builds vary in their host-parameter ceiling, and the
    /// search path can hand us far more rows than conservative limits allow.
    private func attachmentsByMessage(ids: [Int64]) -> [Int64: [Attachment]] {
        guard !ids.isEmpty else { return [:] }
        let columns = attachmentColumnNames()
        guard attachmentSchemaSupportsJoins(attachmentColumns: columns) else { return [:] }
        let selectedColumns = [
            "guid", "filename", "mime_type", "uti", "transfer_name", "total_bytes",
            "is_sticker", "hide_attachment"
        ].map { attachmentSelect(column: $0, available: columns) }.joined(separator: ",\n                       ")
        var out: [Int64: [Attachment]] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 500).map({
            Array(ids[$0 ..< min($0 + 500, ids.count)])
        }) {
            let placeholders = chunk.indices.map { "?\($0 + 1)" }.joined(separator: ", ")
            let sql = """
                SELECT maj.message_id AS message_id, a.ROWID AS rowid,
                       \(selectedColumns)
                FROM message_attachment_join maj
                JOIN attachment a ON a.ROWID = maj.attachment_id
                WHERE maj.message_id IN (\(placeholders))
                ORDER BY maj.message_id, a.ROWID
                """
            for row in (try? reader.rows(sql, chunk.map(String.init))) ?? [] {
                guard let mid = row.int("message_id"), let attachmentID = row.int("rowid") else { continue }
                let raw = row.text("filename")
                let resolved = attachmentPath(from: raw)
                out[mid, default: []].append(Attachment(
                    rowid: attachmentID,
                    guid: row.text("guid"),
                    filename: raw,
                    path: resolved.path,
                    exists: resolved.exists,
                    mime_type: row.text("mime_type"),
                    uti: row.text("uti"),
                    transfer_name: row.text("transfer_name"),
                    total_bytes: row.int("total_bytes"),
                    is_sticker: row.int("is_sticker").map { $0 != 0 },
                    hide_attachment: row.int("hide_attachment").map { $0 != 0 }
                ))
            }
        }
        return out
    }

    private func attachmentSelect(column: String, available columns: Set<String>) -> String {
        columns.contains(column) ? "a.\(column) AS \(column)" : "NULL AS \(column)"
    }

    private func attachmentColumnNames() -> Set<String> {
        tableColumns("attachment")
    }

    private func attachmentSchemaSupportsJoins(attachmentColumns: Set<String>) -> Bool {
        guard !attachmentColumns.isEmpty else { return false }
        let joinColumns = tableColumns("message_attachment_join")
        return joinColumns.isSuperset(of: ["message_id", "attachment_id"])
    }

    private func tableColumns(_ table: String) -> Set<String> {
        let rows = (try? reader.rows("PRAGMA table_info(\(table))")) ?? []
        return Set(rows.compactMap { $0.text("name") })
    }

    private func attachmentPath(from raw: String?) -> (path: String?, exists: Bool?) {
        guard let raw, !raw.isEmpty else { return (nil, nil) }
        let expanded: String
        if raw == "~" {
            expanded = homeDirectoryForTilde
        } else if raw.hasPrefix("~/") {
            let suffix = String(raw.dropFirst(2))
            expanded = URL(fileURLWithPath: homeDirectoryForTilde, isDirectory: true)
                .appendingPathComponent(suffix)
                .path
        } else {
            expanded = NSString(string: raw).expandingTildeInPath
        }
        guard expanded.hasPrefix("/") else { return (nil, nil) }
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard shouldProbeAttachmentPath(standardized) else {
            return (standardized, nil)
        }
        return (standardized, safeLocalExists(atPath: probePath(for: standardized)))
    }

    private func shouldProbeAttachmentPath(_ standardized: String) -> Bool {
        let skippedRoots = ["/net", "/home", "/Network/Servers", "/Volumes"]
        if skippedRoots.contains(where: { root in
            standardized == root || standardized.hasPrefix(root + "/")
        }) {
            return false
        }
        let safeRoots = [homeDirectoryForTilde, NSTemporaryDirectory()].flatMap { raw in
            let url = URL(fileURLWithPath: raw, isDirectory: true)
            return [url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path]
        }
        return safeRoots.contains { root in
            standardized == root || standardized.hasPrefix(root + "/")
        }
    }

    private func safeLocalExists(atPath path: String) -> Bool? {
        var current = ""
        for component in path.split(separator: "/") {
            current = current.isEmpty ? "/" + component : current + "/" + component
            var info = stat()
            if lstat(current, &info) != 0 {
                return current == path && errno == ENOENT ? false : nil
            }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                return nil
            }
        }
        return true
    }

    private func probePath(for standardized: String) -> String {
        if standardized == "/var" || standardized.hasPrefix("/var/") {
            return "/private" + standardized
        }
        if standardized == "/tmp" || standardized.hasPrefix("/tmp/") {
            return "/private/tmp" + standardized.dropFirst(4)
        }
        return standardized
    }

    private mutating func shape(rows: [SQLiteReader.Row], mapping: [String: String]) -> [Message] {
        let ids = rows.compactMap { $0.int("rowid") }
        let byMessage = attachmentsByMessage(ids: ids)
        let identities = chatIdentities(ids: ids)
        var out: [Message] = []
        for row in rows {
            guard let rowid = row.int("rowid") else { continue }
            let joined = byMessage[rowid] ?? []
            let hasAttachments = (row.int("cache_has_attachments") ?? 0) != 0 || !joined.isEmpty
            // An attachment-only row can have no `text` AND no decodable `attributedBody`.
            // Skipping it on a nil body drops exactly the messages this feature exists to
            // surface. A U+FFFC object-replacement placeholder is not a contract to depend on.
            // Body-less rows WITHOUT joined attachment evidence are still skipped, as before.
            guard let body = messageBody(row) ?? (joined.isEmpty ? nil : "") else { continue }
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
            let identity = identities[rowid]
            out.append(Message(
                rowid: rowid,
                date: date,
                date_local: MessageTime.localString(from: date),
                timestamp: rawDate,
                is_from_me: isFromMe,
                sender: sender,
                handle: address,
                service: row.text("service"),
                body: body,
                group_name: group,
                chat_identifier: identity?.identifier,
                chat_guid: identity?.guid,
                is_group: identity?.isGroup ?? false,
                has_attachments: hasAttachments,
                attachments: joined
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

    // MARK: - Fuzzy search (oracle `fuzzy_search_messages`)

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
        // Carried on both message shapes deliberately. A caller that finds a message by
        // search and one that reads it from `recent` should not have to know that only
        // one of the two paths can tell it there is a file attached — or which chat it
        // came from.
        public let chat_identifier: String?
        public let chat_guid: String?
        public let is_group: Bool
        public let has_attachments: Bool
        public let attachments: [Attachment]
        public let score: Double

        enum CodingKeys: String, CodingKey {
            case rowid, date, date_local, timestamp, is_from_me, sender, handle, service, body
            case group_name, chat_identifier, chat_guid, is_group, has_attachments, attachments
            case score
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(rowid, forKey: .rowid)
            try c.encode(date, forKey: .date)
            try c.encode(date_local, forKey: .date_local)
            try c.encode(timestamp, forKey: .timestamp)
            try c.encode(is_from_me, forKey: .is_from_me)
            try c.encode(sender, forKey: .sender)
            // Same omit-when-nil preservation as `Message` — see the note there.
            try c.encodeIfPresent(handle, forKey: .handle)
            try c.encodeIfPresent(service, forKey: .service)
            try c.encode(body, forKey: .body)
            try c.encodeIfPresent(group_name, forKey: .group_name)
            try encodeOrNull(&c, chat_identifier, .chat_identifier)
            try encodeOrNull(&c, chat_guid, .chat_guid)
            try c.encode(is_group, forKey: .is_group)
            try c.encode(has_attachments, forKey: .has_attachments)
            try c.encode(attachments, forKey: .attachments)
            try c.encode(score, forKey: .score)
        }
    }

    public struct SearchResult { public let matches: [ScoredMessage]; public let scanned: Int; public let truncated: Bool }

    static let fuzzySoftCap = 10_000

    /// Two-pass search: SQL LIKE pre-filter (+ all attributedBody-only rows) →
    /// exact-substring (score 1.0) or WRatio ≥ threshold. `hours == 0` = all time.
    /// `match`: `.fuzzy` (default, WRatio), `.contains` (substring), `.exact`.
    /// `directOnly` drops group-chat messages, exactly as on the `recent` path.
    public mutating func search(term: String, hours: Int, threshold: Double, match: SearchMatch,
                                directOnly: DirectOnlyFilter = .off) -> SearchResult {
        let likeParam = "%" + escapeLike(term) + "%"
        var where_ = "(m.text LIKE ?1 ESCAPE '\\' OR (m.text IS NULL AND m.attributedBody IS NOT NULL))"
        var binds = [likeParam]
        if hours != 0 {
            // NOT `threshold` — that is this function's Double score parameter, and shadowing it
            // here made the `binds.append` below read like a bug.
            let dateThreshold = MessageTime.thresholdNanos(hoursAgo: hours)
            where_ = "m.date > ?2 AND " + where_
            binds.append(String(dateThreshold))
        }
        // APPENDED, not prepended. SQLite codes non-indexable WHERE terms in source order, so
        // putting this correlated subquery first ran it on every row the scan visited, ahead of
        // the cheap LIKE and date tests: measured 0.905s prepended vs 0.557s appended on a
        // synthetic 600k-message store with Apple's indexes at `--hours 0` (0.394s with no
        // filter at all). Bind numbering is not what decides this — the placeholders above are
        // explicitly numbered ?1/?2, so either position is safe, and `recent` already appends.
        if directOnly.applied {
            where_ += " AND \(ChatDB.directOnlyPredicate)"
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

        // Fetch for the SCORED rows only, not the whole LIKE pre-filter: that set is capped
        // at `fuzzySoftCap` (10,000) and is mostly discarded a few lines above.
        let scoredIds = scored.compactMap { $0.0.int("rowid") }
        let byMessage = attachmentsByMessage(ids: scoredIds)
        let identities = chatIdentities(ids: scoredIds)

        var matches: [ScoredMessage] = []
        for (row, body, score) in scored {
            guard let rowid = row.int("rowid") else { continue }
            let joined = byMessage[rowid] ?? []
            let hasAttachments = (row.int("cache_has_attachments") ?? 0) != 0 || !joined.isEmpty
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
            let identity = identities[rowid]
            matches.append(ScoredMessage(
                rowid: rowid, date: date, date_local: MessageTime.localString(from: date),
                timestamp: rawDate, is_from_me: isFromMe, sender: sender, handle: address,
                service: row.text("service"), body: body, group_name: group,
                chat_identifier: identity?.identifier, chat_guid: identity?.guid,
                is_group: identity?.isGroup ?? false,
                has_attachments: hasAttachments,
                attachments: joined, score: score))
        }
        return SearchResult(matches: matches, scanned: rows.count, truncated: rows.count >= ChatDB.fuzzySoftCap)
    }

    public enum SearchMatch: String { case fuzzy, contains, exact }

    private func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Named group chats (oracle `get_chats`)

    public struct Chat: Encodable {
        public let chat_identifier: String
        public let display_name: String
        public let guid: String?
        public let room_name: String?
        public let service_name: String?
        public let group_id: String?
        public let style: Int64?
        /// Newest message in this chat — ISO-8601 in JSON. ALWAYS present (null when the
        /// chat holds no messages, or the store cannot answer).
        public let last_activity: Date?
        /// The RAW `message.date` value chat.db stores for that message — NOT a fixed unit:
        /// nanoseconds since the Apple epoch on modern rows, SECONDS on legacy ones (the same
        /// greater-than-10-digit heuristic `MessageTime.date(fromRaw:)` applies to a message
        /// `timestamp`). Bigger still means more recent, within a chat and across chats, because
        /// ns values always exceed seconds values and ns rows are always the newer ones — so it
        /// is safe to SORT on. It is not safe to divide by 1e9, subtract, or otherwise treat as
        /// one unit; `last_activity` is the normalized form for that.
        public let last_activity_timestamp: Int64?
        /// Handle ids from `chat_handle_join` → `handle.id`; possibly empty.
        public let participants: [String]

        enum CodingKeys: String, CodingKey {
            case chat_identifier, display_name, guid, room_name, service_name, group_id, style
            case last_activity, last_activity_timestamp, participants
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(chat_identifier, forKey: .chat_identifier)
            try c.encode(display_name, forKey: .display_name)
            // The pre-existing optionals keep their omit-when-nil shape (see `Message`).
            try c.encodeIfPresent(guid, forKey: .guid)
            try c.encodeIfPresent(room_name, forKey: .room_name)
            try c.encodeIfPresent(service_name, forKey: .service_name)
            try c.encodeIfPresent(group_id, forKey: .group_id)
            try c.encodeIfPresent(style, forKey: .style)
            try encodeOrNull(&c, last_activity, .last_activity)
            try encodeOrNull(&c, last_activity_timestamp, .last_activity_timestamp)
            try c.encode(participants, forKey: .participants)
        }
    }

    /// Named chats, oldest chat ROWID first. `nameFilter` keeps only chats whose `display_name`
    /// contains it, case-insensitively; `limit` caps the result. Both default to "no filter",
    /// so the historical call `namedChats()` behaves exactly as it did.
    public func namedChats(nameFilter: String? = nil, limit: Int? = nil) -> [Chat] {
        if let limit, limit <= 0 { return [] }
        // ORDER BY ROWID is stated in SQL, not merely relied upon. A bare SELECT happens to
        // come back in rowid order today, but `--limit` turned the ordering from cosmetic into
        // the thing that decides WHICH chats a caller receives, and the doc, the manual and the
        // port spec all promise it.
        let sql = """
            SELECT ROWID AS rowid, chat_identifier, display_name, guid, room_name, service_name,
                   group_id, style
            FROM chat WHERE display_name IS NOT NULL AND display_name != ''
            ORDER BY ROWID
            """
        let rows = (try? reader.rows(sql)) ?? []

        // TWO PASSES, deliberately: choose the rows FIRST, then look up activity and
        // participants for only those chats. Doing it the other way round made every
        // invocation — `chats --name x --limit 1` included — pay for a GROUP BY across every
        // message row in the store. Measured on a large store, the whole-store grouping was
        // ~28x slower than the same lookup restricted to the named chats, and slower still than
        // a `--limit 5` call.
        //
        // This is a reduction in cost, not a constant: what remains scales with the number of
        // messages held by the chats actually RETURNED, so a selection covering many busy chats
        // is still substantial work. `--limit` is the lever on a large store.
        var selected: [SQLiteReader.Row] = []
        for row in rows {
            guard row.text("chat_identifier") != nil, let name = row.text("display_name") else { continue }
            if let nameFilter, !nameFilter.isEmpty,
               name.range(of: nameFilter, options: .caseInsensitive) == nil { continue }
            if let limit, selected.count >= limit { break }
            selected.append(row)
        }

        let chatIds = selected.compactMap { $0.int("rowid") }
        let activity = chatLastActivity(chatIds: chatIds)
        let participants = chatParticipants(chatIds: chatIds)
        return selected.compactMap { row in
            guard let id = row.text("chat_identifier"), let name = row.text("display_name") else { return nil }
            let last = row.int("rowid").flatMap { activity[$0] }
            return Chat(chat_identifier: id, display_name: name, guid: row.text("guid"),
                        room_name: row.text("room_name"), service_name: row.text("service_name"),
                        group_id: row.text("group_id"), style: row.int("style"),
                        last_activity: last.map(MessageTime.date(fromRaw:)),
                        last_activity_timestamp: last,
                        participants: row.int("rowid").flatMap { participants[$0] } ?? [])
        }
    }

    /// chat ROWID → raw date of its newest message, for the given chats. Chats with no messages
    /// are absent.
    ///
    /// MAX runs on the RAW column, which is bi-modal — seconds since 2001 on legacy rows,
    /// nanoseconds on modern ones. That is exactly why `MessageTime.date(fromRaw:)` exists, and
    /// exactly why taking MAX of it looks wrong at first glance. It is sound, and the reasoning
    /// is worth not re-deriving: a nanosecond value (~7.8e17) always exceeds a seconds value
    /// (~7.8e8), and the ns rows are always the newer ones, so the numeric maximum IS the
    /// chronological maximum. Converting per row before comparing would give the same answer at
    /// much greater cost. The same premise is what makes the emitted
    /// `last_activity_timestamp` safe to ORDER on across chats while remaining unsafe to read
    /// as a fixed unit.
    ///
    /// Like `chatParticipants`, this leans on `try?` to absorb a store that has no
    /// `chat_message_join` at all, rather than pre-checking the schema: one posture for both.
    private func chatLastActivity(chatIds: [Int64]) -> [Int64: Int64] {
        guard !chatIds.isEmpty else { return [:] }
        var out: [Int64: Int64] = [:]
        for chunk in ChatDB.idChunks(chatIds) {
            let placeholders = chunk.indices.map { "?\($0 + 1)" }.joined(separator: ", ")
            let sql = """
                SELECT cmj.chat_id AS chat_id, MAX(m.date) AS last_date
                FROM chat_message_join cmj
                JOIN message m ON m.ROWID = cmj.message_id
                WHERE cmj.chat_id IN (\(placeholders))
                GROUP BY cmj.chat_id
                """
            for row in (try? reader.rows(sql, chunk.map(String.init))) ?? [] {
                guard let chatId = row.int("chat_id"), let last = row.int("last_date") else { continue }
                out[chatId] = last
            }
        }
        return out
    }

    /// chat ROWID → participant handle ids, in handle-ROWID order so the array is stable
    /// across invocations rather than following SQLite's scan order.
    private func chatParticipants(chatIds: [Int64]) -> [Int64: [String]] {
        guard !chatIds.isEmpty else { return [:] }
        var out: [Int64: [String]] = [:]
        for chunk in ChatDB.idChunks(chatIds) {
            let placeholders = chunk.indices.map { "?\($0 + 1)" }.joined(separator: ", ")
            let sql = """
                SELECT chj.chat_id AS chat_id, h.id AS handle
                FROM chat_handle_join chj
                JOIN handle h ON h.ROWID = chj.handle_id
                WHERE chj.chat_id IN (\(placeholders))
                ORDER BY chj.chat_id, h.ROWID
                """
            for row in (try? reader.rows(sql, chunk.map(String.init))) ?? [] {
                guard let chatId = row.int("chat_id"), let handle = row.text("handle") else { continue }
                out[chatId, default: []].append(handle)
            }
        }
        return out
    }

    // MARK: - Exact read APIs

    public enum ExactOrder: String, Sendable { case asc, desc }

    public enum ExactChatSelector: Sendable, Equatable {
        case rowid(Int64)
        case guid(String)
    }

    public enum ExactMessageSelector: Sendable, Equatable {
        case rowid(Int64)
        case guid(String)
    }

    public struct ExactBodyAvailability: Encodable, Equatable, Sendable {
        public let status: String
        public let reason: String?

        enum CodingKeys: String, CodingKey { case status, reason }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(status, forKey: .status)
            try encodeOrNull(&c, reason, .reason)
        }
    }

    public struct ExactNativePart: Encodable, Equatable, Sendable {
        public let index: Int
        public let utf16_ranges: [UTF16Range]
        public let attachment_guid: String?

        public struct UTF16Range: Encodable, Equatable, Sendable {
            public let location: Int
            public let length: Int
        }

        enum CodingKeys: String, CodingKey { case index, utf16_ranges, attachment_guid }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(index, forKey: .index)
            try c.encode(utf16_ranges, forKey: .utf16_ranges)
            try encodeOrNull(&c, attachment_guid, .attachment_guid)
        }
    }

    public struct ExactMessage: Encodable {
        public let rowid: Int64
        public let message_guid: String?
        public let selected_chat_rowid: Int64
        public let chat_guid: String?
        public let chat_identifier: String?
        public let date: Date?
        public let date_local: String?
        public let timestamp: Int64?
        public let normalized_seconds: Int64?
        public let normalized_nanoseconds: Int64?
        public let is_from_me: Bool
        public let sender: String
        public let handle: String?
        public let service: String?
        public let body: String?
        public let body_availability: ExactBodyAvailability
        public let group_name: String?
        public let is_group: Bool
        public let has_attachments: Bool
        public let attachments: [Attachment]
        public let native_parts_available: Bool
        public let native_parts_reason: String
        public let native_parts: [ExactNativePart]?

        enum CodingKeys: String, CodingKey {
            case rowid, message_guid, selected_chat_rowid, chat_guid, chat_identifier
            case date, date_local, timestamp, normalized_seconds, normalized_nanoseconds, is_from_me, sender, handle
            case service, body, body_availability, group_name, is_group, has_attachments
            case attachments, native_parts_available, native_parts_reason, native_parts
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(rowid, forKey: .rowid)
            try encodeOrNull(&c, message_guid, .message_guid)
            try c.encode(selected_chat_rowid, forKey: .selected_chat_rowid)
            try encodeOrNull(&c, chat_guid, .chat_guid)
            try encodeOrNull(&c, chat_identifier, .chat_identifier)
            try encodeOrNull(&c, date, .date)
            try encodeOrNull(&c, date_local, .date_local)
            try encodeOrNull(&c, timestamp, .timestamp)
            try encodeOrNull(&c, normalized_seconds, .normalized_seconds)
            try encodeOrNull(&c, normalized_nanoseconds, .normalized_nanoseconds)
            try c.encode(is_from_me, forKey: .is_from_me)
            try c.encode(sender, forKey: .sender)
            try c.encodeIfPresent(handle, forKey: .handle)
            try c.encodeIfPresent(service, forKey: .service)
            try encodeOrNull(&c, body, .body)
            try c.encode(body_availability, forKey: .body_availability)
            try c.encodeIfPresent(group_name, forKey: .group_name)
            try c.encode(is_group, forKey: .is_group)
            try c.encode(has_attachments, forKey: .has_attachments)
            try c.encode(attachments, forKey: .attachments)
            try c.encode(native_parts_available, forKey: .native_parts_available)
            try c.encode(native_parts_reason, forKey: .native_parts_reason)
            try encodeOrNull(&c, native_parts, .native_parts)
        }
    }

    public struct ExactConversation: Encodable {
        public let chat_rowid: Int64
        public let chat_guid: String?
        public let chat_identifier: String?
        public let display_name: String?
        public let room_name: String?
        public let service_name: String?
        public let group_id: String?
        public let style: Int64?
        public let is_group: Bool
        public let last_activity: Date?
        public let last_activity_timestamp: Int64?
        public let last_activity_normalized_seconds: Int64?
        public let last_activity_normalized_nanoseconds: Int64?
        public let participants: [String]

        enum CodingKeys: String, CodingKey {
            case chat_rowid, chat_guid, chat_identifier, display_name, room_name, service_name
            case group_id, style, is_group, last_activity, last_activity_timestamp
            case last_activity_normalized_seconds, last_activity_normalized_nanoseconds, participants
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(chat_rowid, forKey: .chat_rowid)
            try encodeOrNull(&c, chat_guid, .chat_guid)
            try encodeOrNull(&c, chat_identifier, .chat_identifier)
            try encodeOrNull(&c, display_name, .display_name)
            try encodeOrNull(&c, room_name, .room_name)
            try encodeOrNull(&c, service_name, .service_name)
            try encodeOrNull(&c, group_id, .group_id)
            try encodeOrNull(&c, style, .style)
            try c.encode(is_group, forKey: .is_group)
            try encodeOrNull(&c, last_activity, .last_activity)
            try encodeOrNull(&c, last_activity_timestamp, .last_activity_timestamp)
            try encodeOrNull(&c, last_activity_normalized_seconds, .last_activity_normalized_seconds)
            try encodeOrNull(&c, last_activity_normalized_nanoseconds, .last_activity_normalized_nanoseconds)
            try c.encode(participants, forKey: .participants)
        }
    }

    public struct ExactPage<T: Encodable>: Encodable {
        public let items: [T]
        public let nextCursor: String?
        public let chat: ResolvedExactChat?
    }

    public struct ResolvedExactChat: Encodable, Sendable, Equatable {
        public let rowid: Int64
        public let guid: String?
        public let identifier: String?
        public let displayName: String?
        public let style: Int64?

        enum CodingKeys: String, CodingKey {
            case rowid, guid, identifier, displayName, style
        }
    }

    private struct ExactCursor: Codable {
        let v: Int
        let op: String
        let chatRowid: Int64?
        let chatGuid: String?
        let order: String
        let maxMessageRowid: Int64
        let maxChatRowid: Int64?
        let lastSeconds: Int64?
        let lastNanoseconds: Int64?
        let lastMessageRowid: Int64?
        let lastChatRowid: Int64?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case v, op, chatRowid, chatGuid, order, maxMessageRowid, maxChatRowid
            case lastSeconds, lastNanoseconds, lastMessageRowid, lastChatRowid
        }
    }

    private static let exactCursorVersion = 1
    private static let exactCursorMaxBytes = 4096
    private static let normalizedSecondsSQL = """
        CASE
          WHEN m.date IS NULL THEN NULL
          WHEN m.date BETWEEN -9999999999 AND 9999999999 THEN m.date
          WHEN m.date < 0 AND (m.date % 1000000000) != 0 THEN (m.date / 1000000000) - 1
          ELSE m.date / 1000000000
        END
        """

    private static let normalizedNanosecondsSQL = """
        CASE
          WHEN m.date IS NULL THEN NULL
          WHEN m.date BETWEEN -9999999999 AND 9999999999 THEN 0
          ELSE ((m.date % 1000000000) + 1000000000) % 1000000000
        END
        """

    private static func exactMessageSelect(seconds: String = ChatDB.normalizedSecondsSQL,
                                           nanos: String = ChatDB.normalizedNanosecondsSQL) -> String {
        """
        SELECT m.ROWID AS rowid, m.guid AS message_guid, m.date AS date,
               \(seconds) AS normalized_seconds,
               \(nanos) AS normalized_nanoseconds,
               m.text AS text, m.attributedBody AS attributedBody,
               m.is_from_me AS is_from_me, m.handle_id AS handle_rowid,
               m.cache_roomnames AS cache_roomnames, m.service AS service,
               m.cache_has_attachments AS cache_has_attachments,
               h.id AS address,
               c.ROWID AS selected_chat_rowid, c.chat_identifier AS chat_identifier,
               c.guid AS chat_guid, c.display_name AS selected_display_name,
               c.style AS selected_style
        FROM chat_message_join cmj
        JOIN chat c ON c.ROWID = cmj.chat_id
        JOIN message m ON m.ROWID = cmj.message_id
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        """
    }

    public mutating func exactConversations(limit: Int, order: ExactOrder, cursor: String?) throws -> ExactPage<ExactConversation> {
        try requireExactReadSchema()
        let firstMaxMessage = try maxRowid(table: "message")
        let firstMaxChat = try maxRowid(table: "chat")
        let decoded = try decodeCursor(cursor, op: "conversations", chat: nil, order: order)
        let maxMessage = decoded?.maxMessageRowid ?? firstMaxMessage
        let maxChat = decoded?.maxChatRowid ?? firstMaxChat
        let activitySQL = """
            SELECT cmj.chat_id AS chat_id, m.ROWID AS message_rowid, m.date AS date,
                   \(ChatDB.normalizedSecondsSQL) AS normalized_seconds,
                   \(ChatDB.normalizedNanosecondsSQL) AS normalized_nanoseconds
            FROM chat_message_join cmj
            JOIN message m ON m.ROWID = cmj.message_id
            WHERE m.ROWID <= ?1
            """
        var activity: [Int64: (raw: Int64?, seconds: Int64?, nanos: Int64?, messageRowid: Int64)] = [:]
        for row in try reader.rows(activitySQL, [String(maxMessage)]) {
            guard let chatID = row.int("chat_id"), let mid = row.int("message_rowid") else { continue }
            let candidate = (raw: row.int("date"), seconds: row.int("normalized_seconds"),
                             nanos: row.int("normalized_nanoseconds"), messageRowid: mid)
            if let current = activity[chatID] {
                if exactCompare(candidate.seconds, candidate.nanos, candidate.messageRowid,
                                current.seconds, current.nanos, current.messageRowid, order: .desc) {
                    activity[chatID] = candidate
                }
            } else {
                activity[chatID] = candidate
            }
        }

        let sql = """
            SELECT ROWID AS chat_rowid, chat_identifier, display_name, room_name, guid,
                   service_name, group_id, style
            FROM chat
            WHERE ROWID <= ?1
            """
        let binds = [String(maxChat)]
        let rows = try reader.rows(sql, binds)
        let participantMap = try exactChatParticipants(chatIds: rows.compactMap { $0.int("chat_rowid") })
        var conversations: [ExactConversation] = rows.compactMap { row in
            guard let chatID = row.int("chat_rowid") else { return nil }
            let last = activity[chatID]
            return ExactConversation(
                chat_rowid: chatID,
                chat_guid: row.text("guid"),
                chat_identifier: row.text("chat_identifier"),
                display_name: row.text("display_name"),
                room_name: row.text("room_name"),
                service_name: row.text("service_name"),
                group_id: row.text("group_id"),
                style: row.int("style"),
                is_group: row.int("style") == ChatDB.groupChatStyle,
                last_activity: last?.raw.map(MessageTime.date(fromRaw:)),
                last_activity_timestamp: last?.raw,
                last_activity_normalized_seconds: last?.seconds,
                last_activity_normalized_nanoseconds: last?.nanos,
                participants: participantMap[chatID] ?? []
            )
        }
        conversations.sort { lhs, rhs in
            exactCompare(lhs.last_activity_normalized_seconds, lhs.last_activity_normalized_nanoseconds,
                         lhs.chat_rowid, rhs.last_activity_normalized_seconds,
                         rhs.last_activity_normalized_nanoseconds, rhs.chat_rowid, order: order)
        }
        if let decoded, let lastChat = decoded.lastChatRowid {
            conversations = conversations.filter {
                exactCompare(decoded.lastSeconds, decoded.lastNanoseconds, lastChat,
                             $0.last_activity_normalized_seconds, $0.last_activity_normalized_nanoseconds,
                             $0.chat_rowid, order: order)
            }
        }
        let page = Array(conversations.prefix(limit + 1))
        let visible = Array(page.prefix(limit))
        let next = try page.count > limit ? visible.last.map {
            try encodeCursor(ExactCursor(v: ChatDB.exactCursorVersion, op: "conversations",
                                         chatRowid: nil, chatGuid: nil, order: order.rawValue,
                                         maxMessageRowid: maxMessage, maxChatRowid: maxChat,
                                         lastSeconds: $0.last_activity_normalized_seconds,
                                         lastNanoseconds: $0.last_activity_normalized_nanoseconds,
                                         lastMessageRowid: nil, lastChatRowid: $0.chat_rowid))
        } : nil
        return ExactPage(items: visible, nextCursor: next, chat: nil)
    }

    public mutating func exactHistory(chat selector: ExactChatSelector, limit: Int,
                                      order: ExactOrder, cursor: String?) throws -> ExactPage<ExactMessage> {
        try requireExactReadSchema()
        let chat = try resolveExactChat(selector)
        let decoded = try decodeCursor(cursor, op: "history", chat: chat, order: order)
        let maxMessage: Int64
        if let decoded {
            maxMessage = decoded.maxMessageRowid
        } else {
            maxMessage = try maxRowid(table: "message")
        }
        let orderSQL = order == .desc ? "DESC" : "ASC"
        var sql = ChatDB.exactMessageSelect() + """

        WHERE c.ROWID = ?1 AND m.ROWID <= ?2
        """
        var binds = [String(chat.rowid), String(maxMessage)]
        if let decoded, let lastMessage = decoded.lastMessageRowid {
            let lastSeconds = decoded.lastSeconds
            let lastNanos = decoded.lastNanoseconds
            if order == .desc {
                if let lastSeconds, let lastNanos {
                    sql += " AND (((\(ChatDB.normalizedSecondsSQL)) < CAST(?3 AS INTEGER)) OR ((\(ChatDB.normalizedSecondsSQL)) = CAST(?3 AS INTEGER) AND (\(ChatDB.normalizedNanosecondsSQL)) < CAST(?4 AS INTEGER)) OR ((\(ChatDB.normalizedSecondsSQL)) = CAST(?3 AS INTEGER) AND (\(ChatDB.normalizedNanosecondsSQL)) = CAST(?4 AS INTEGER) AND m.ROWID < ?5) OR ((\(ChatDB.normalizedSecondsSQL)) IS NULL))"
                    binds.append(String(lastSeconds))
                    binds.append(String(lastNanos))
                    binds.append(String(lastMessage))
                } else {
                    sql += " AND (\(ChatDB.normalizedSecondsSQL)) IS NULL AND m.ROWID < ?3"
                    binds.append(String(lastMessage))
                }
            } else {
                if let lastSeconds, let lastNanos {
                    sql += " AND (((\(ChatDB.normalizedSecondsSQL)) > CAST(?3 AS INTEGER)) OR ((\(ChatDB.normalizedSecondsSQL)) = CAST(?3 AS INTEGER) AND (\(ChatDB.normalizedNanosecondsSQL)) > CAST(?4 AS INTEGER)) OR ((\(ChatDB.normalizedSecondsSQL)) = CAST(?3 AS INTEGER) AND (\(ChatDB.normalizedNanosecondsSQL)) = CAST(?4 AS INTEGER) AND m.ROWID > ?5))"
                    binds.append(String(lastSeconds))
                    binds.append(String(lastNanos))
                    binds.append(String(lastMessage))
                } else {
                    sql += " AND (((\(ChatDB.normalizedSecondsSQL)) IS NOT NULL) OR ((\(ChatDB.normalizedSecondsSQL)) IS NULL AND m.ROWID > ?3))"
                    binds.append(String(lastMessage))
                }
            }
        }
        let nullOrder = order == .desc ? "normalized_seconds IS NULL ASC" : "normalized_seconds IS NOT NULL ASC"
        sql += """

        ORDER BY \(nullOrder), normalized_seconds \(orderSQL), normalized_nanoseconds \(orderSQL), m.ROWID \(orderSQL)
        LIMIT \(limit + 1)
        """
        let messages = try shapeExactMessages(rows: reader.rows(sql, binds))
        let visible = Array(messages.prefix(limit))
        let next = try messages.count > limit ? visible.last.map {
            try encodeCursor(ExactCursor(v: ChatDB.exactCursorVersion, op: "history",
                                         chatRowid: chat.rowid, chatGuid: chat.guid,
                                         order: order.rawValue, maxMessageRowid: maxMessage,
                                         maxChatRowid: nil,
                                         lastSeconds: $0.normalized_seconds,
                                         lastNanoseconds: $0.normalized_nanoseconds,
                                         lastMessageRowid: $0.rowid, lastChatRowid: nil))
        } : nil
        return ExactPage(items: visible, nextCursor: next, chat: chat)
    }

    public mutating func exactGet(chat selector: ExactChatSelector,
                                  message messageSelector: ExactMessageSelector) throws -> (ResolvedExactChat, ExactMessage) {
        try requireExactReadSchema()
        let chat = try resolveExactChat(selector)
        let messagePredicate: String
        let bind: String
        switch messageSelector {
        case .rowid(let rowid):
            messagePredicate = "m.ROWID = ?2"
            bind = String(rowid)
        case .guid(let guid):
            let rows = try reader.rows("SELECT ROWID FROM message WHERE guid = ?1", [guid])
            guard !rows.isEmpty else { throw AppleError.notFound("message not found") }
            guard rows.count == 1 else {
                throw AppleError.validation("message guid matches multiple rows; use --message-rowid")
            }
            messagePredicate = "m.ROWID = ?2"
            bind = String(try requiredInt(rows[0], "ROWID"))
        }
        let sql = ChatDB.exactMessageSelect() + """

        WHERE c.ROWID = ?1 AND \(messagePredicate)
        LIMIT 1
        """
        let messages = try shapeExactMessages(rows: reader.rows(sql, [String(chat.rowid), bind]))
        guard let message = messages.first else {
            throw AppleError.notFound("message is not a member of the selected conversation")
        }
        return (chat, message)
    }

    private func exactCompare(_ lhsSeconds: Int64?, _ lhsNanos: Int64?, _ lhsTie: Int64,
                              _ rhsSeconds: Int64?, _ rhsNanos: Int64?, _ rhsTie: Int64,
                              order: ExactOrder) -> Bool {
        switch (lhsSeconds, rhsSeconds) {
        case let (l?, r?) where l != r:
            return order == .desc ? l > r : l < r
        case (nil, _?) where order == .asc:
            return true
        case (_?, nil) where order == .asc:
            return false
        case (nil, _?) where order == .desc:
            return false
        case (_?, nil) where order == .desc:
            return true
        default:
            if let lhsNanos, let rhsNanos, lhsNanos != rhsNanos {
                return order == .desc ? lhsNanos > rhsNanos : lhsNanos < rhsNanos
            }
            return order == .desc ? lhsTie > rhsTie : lhsTie < rhsTie
        }
    }

    private mutating func shapeExactMessages(rows: [SQLiteReader.Row]) throws -> [ExactMessage] {
        let ids = rows.compactMap { $0.int("rowid") }
        let attachments = try strictAttachmentsByMessage(ids: ids)
        var out: [ExactMessage] = []
        for row in rows {
            let rowid = try requiredInt(row, "rowid")
            let selectedChat = try requiredInt(row, "selected_chat_rowid")
            let joined = attachments[rowid] ?? []
            let bodyInfo = exactBody(row, attachments: joined)
            let nativePartsInfo = exactNativeParts(row)
            let rawDate = row.int("date")
            let date = rawDate.map(MessageTime.date(fromRaw:))
            let isFromMe = (row.int("is_from_me") ?? 0) != 0
            let address = row.text("address")
            let sender = senderName(isFromMe: isFromMe, address: address)
            var group: String?
            if let room = row.text("cache_roomnames"),
               let name = try exactDisplayNameForRoom(room), !name.isEmpty {
                group = name
            }
            out.append(ExactMessage(
                rowid: rowid,
                message_guid: row.text("message_guid"),
                selected_chat_rowid: selectedChat,
                chat_guid: row.text("chat_guid"),
                chat_identifier: row.text("chat_identifier"),
                date: date,
                date_local: date.map(MessageTime.localString(from:)),
                timestamp: rawDate,
                normalized_seconds: row.int("normalized_seconds"),
                normalized_nanoseconds: row.int("normalized_nanoseconds"),
                is_from_me: isFromMe,
                sender: sender,
                handle: address,
                service: row.text("service"),
                body: bodyInfo.body,
                body_availability: bodyInfo.availability,
                group_name: group,
                is_group: row.int("selected_style") == ChatDB.groupChatStyle,
                has_attachments: (row.int("cache_has_attachments") ?? 0) != 0 || !joined.isEmpty,
                attachments: joined,
                native_parts_available: nativePartsInfo.available,
                native_parts_reason: nativePartsInfo.reason,
                native_parts: nativePartsInfo.parts
            ))
        }
        return out
    }

    private func exactNativeParts(_ row: SQLiteReader.Row) -> (available: Bool, reason: String, parts: [ExactNativePart]?) {
        let decoded = NativeMessageParts.decode(row.data("attributedBody"))
        let parts = decoded.nativeParts.map { nativeParts in
            nativeParts.map { nativePart in
                ExactNativePart(
                    index: nativePart.index,
                    utf16_ranges: nativePart.utf16Ranges.map {
                        ExactNativePart.UTF16Range(location: $0.location, length: $0.length)
                    },
                    attachment_guid: nativePart.attachmentGUID
                )
            }
        }
        return (decoded.nativePartsAvailable, decoded.nativePartsReason, parts)
    }

    private func exactBody(_ row: SQLiteReader.Row, attachments: [Attachment]) -> (body: String?, availability: ExactBodyAvailability) {
        if let text = row.text("text") {
            return (text, ExactBodyAvailability(status: "available", reason: nil))
        }
        if let blob = row.data("attributedBody") {
            if let decoded = AttributedBody.decode(blob) {
                return (decoded, ExactBodyAvailability(status: "available", reason: nil))
            }
            return (nil, ExactBodyAvailability(status: "unavailable", reason: "attributedBody undecodable"))
        }
        if !attachments.isEmpty {
            return ("", ExactBodyAvailability(status: "empty", reason: "bodyless attachment row"))
        }
        return (nil, ExactBodyAvailability(status: "empty", reason: "no text, attributedBody, or attachments"))
    }

    private func exactDisplayNameForRoom(_ room: String) throws -> String? {
        try reader.rows("SELECT display_name FROM chat WHERE room_name = ?1 LIMIT 1", [room])
            .first?.text("display_name")
    }

    private func strictAttachmentsByMessage(ids: [Int64]) throws -> [Int64: [Attachment]] {
        guard !ids.isEmpty else { return [:] }
        let columns = try requiredColumns("attachment", ["ROWID"])
        _ = try requiredColumns("message_attachment_join", ["message_id", "attachment_id"])
        let selectedColumns = [
            "guid", "filename", "mime_type", "uti", "transfer_name", "total_bytes",
            "is_sticker", "hide_attachment"
        ].map { attachmentSelect(column: $0, available: columns) }.joined(separator: ",\n                       ")
        var out: [Int64: [Attachment]] = [:]
        for chunk in ChatDB.idChunks(ids) {
            let placeholders = chunk.indices.map { "?\($0 + 1)" }.joined(separator: ", ")
            let sql = """
                SELECT maj.message_id AS message_id, a.ROWID AS rowid,
                       \(selectedColumns)
                FROM message_attachment_join maj
                JOIN attachment a ON a.ROWID = maj.attachment_id
                WHERE maj.message_id IN (\(placeholders))
                ORDER BY maj.message_id, a.ROWID
                """
            for row in try reader.rows(sql, chunk.map(String.init)) {
                let raw = row.text("filename")
                let resolved = attachmentPath(from: raw)
                out[try requiredInt(row, "message_id"), default: []].append(Attachment(
                    rowid: try requiredInt(row, "rowid"),
                    guid: row.text("guid"),
                    filename: raw,
                    path: resolved.path,
                    exists: resolved.exists,
                    mime_type: row.text("mime_type"),
                    uti: row.text("uti"),
                    transfer_name: row.text("transfer_name"),
                    total_bytes: row.int("total_bytes"),
                    is_sticker: row.int("is_sticker").map { $0 != 0 },
                    hide_attachment: row.int("hide_attachment").map { $0 != 0 }
                ))
            }
        }
        return out
    }

    private func exactChatParticipants(chatIds: [Int64]) throws -> [Int64: [String]] {
        guard !chatIds.isEmpty else { return [:] }
        var out: [Int64: [String]] = [:]
        for chunk in ChatDB.idChunks(chatIds) {
            let placeholders = chunk.indices.map { "?\($0 + 1)" }.joined(separator: ", ")
            let sql = """
                SELECT chj.chat_id AS chat_id, h.id AS handle
                FROM chat_handle_join chj
                JOIN handle h ON h.ROWID = chj.handle_id
                WHERE chj.chat_id IN (\(placeholders))
                ORDER BY chj.chat_id, h.ROWID
                """
            for row in try reader.rows(sql, chunk.map(String.init)) {
                guard let handle = row.text("handle") else { continue }
                out[try requiredInt(row, "chat_id"), default: []].append(handle)
            }
        }
        return out
    }

    private func resolveExactChat(_ selector: ExactChatSelector) throws -> ResolvedExactChat {
        let rows: [SQLiteReader.Row]
        switch selector {
        case .rowid(let rowid):
            rows = try reader.rows("""
                SELECT ROWID AS rowid, guid, chat_identifier, display_name, style
                FROM chat WHERE ROWID = ?1
                """, [String(rowid)])
        case .guid(let guid):
            rows = try reader.rows("""
                SELECT ROWID AS rowid, guid, chat_identifier, display_name, style
                FROM chat WHERE guid = ?1
                """, [guid])
        }
        guard !rows.isEmpty else { throw AppleError.notFound("conversation not found") }
        guard rows.count == 1 else {
            throw AppleError.validation("chat guid matches multiple rows; use --chat-rowid")
        }
        let row = rows[0]
        return ResolvedExactChat(rowid: try requiredInt(row, "rowid"),
                                 guid: row.text("guid"),
                                 identifier: row.text("chat_identifier"),
                                 displayName: row.text("display_name"),
                                 style: row.int("style"))
    }

    private func requireExactReadSchema() throws {
        _ = try requiredColumns("message", [
            "ROWID", "guid", "text", "attributedBody", "is_from_me", "handle_id",
            "cache_roomnames", "service", "cache_has_attachments", "date",
        ])
        _ = try requiredColumns("chat", [
            "ROWID", "chat_identifier", "display_name", "room_name", "guid",
            "service_name", "group_id", "style",
        ])
        _ = try requiredColumns("chat_message_join", ["chat_id", "message_id"])
        _ = try requiredColumns("chat_handle_join", ["chat_id", "handle_id"])
        _ = try requiredColumns("handle", ["ROWID", "id"])
        _ = try requiredColumns("message_attachment_join", ["message_id", "attachment_id"])
        _ = try requiredColumns("attachment", ["ROWID"])
    }

    private func requiredColumns(_ table: String, _ required: Set<String>) throws -> Set<String> {
        let rows = try reader.rows("PRAGMA table_info(\(table))")
        let columns = Set(rows.compactMap { $0.text("name") })
        guard !columns.isEmpty else { throw AppleError.upstream("Messages database is missing required table '\(table)'") }
        let missing = required.subtracting(columns)
        guard missing.isEmpty else {
            throw AppleError.upstream("Messages database table '\(table)' is missing required column(s): \(missing.sorted().joined(separator: ", "))")
        }
        return columns
    }

    private func maxRowid(table: String) throws -> Int64 {
        try reader.rows("SELECT COALESCE(MAX(ROWID), 0) AS max_rowid FROM \(table)")
            .first?.int("max_rowid") ?? 0
    }

    private func requiredInt(_ row: SQLiteReader.Row, _ column: String) throws -> Int64 {
        guard let value = row.int(column) else {
            throw AppleError.upstream("Messages database query did not return required column '\(column)'")
        }
        return value
    }

    private func decodeCursor(_ cursor: String?, op: String, chat: ResolvedExactChat?,
                              order: ExactOrder) throws -> ExactCursor? {
        guard let cursor else { return nil }
        guard cursor.utf8.count <= ChatDB.exactCursorMaxBytes else {
            throw AppleError.validation("cursor too large (max \(ChatDB.exactCursorMaxBytes) bytes)")
        }
        guard let data = Data(base64Encoded: cursor) else {
            throw AppleError.validation("cursor must be base64-encoded JSON")
        }
        try validateExactCursorJSONShape(data)
        let decoded: ExactCursor
        do {
            decoded = try JSONDecoder().decode(ExactCursor.self, from: data)
        } catch {
            throw AppleError.validation("cursor is malformed")
        }
        guard decoded.v == ChatDB.exactCursorVersion else {
            throw AppleError.validation("cursor version is unsupported")
        }
        guard decoded.op == op else { throw AppleError.validation("cursor is for a different operation") }
        guard decoded.order == order.rawValue else { throw AppleError.validation("cursor is for a different order") }
        guard decoded.maxMessageRowid >= 0, (decoded.maxChatRowid ?? 0) >= 0 else {
            throw AppleError.validation("cursor has an invalid range")
        }
        switch op {
        case "history":
            guard decoded.maxChatRowid == nil, decoded.lastChatRowid == nil else {
                throw AppleError.validation("cursor carries fields for a different operation")
            }
            guard let lastMessage = decoded.lastMessageRowid, lastMessage > 0,
                  lastMessage <= decoded.maxMessageRowid else {
                throw AppleError.validation("cursor has an invalid range")
            }
            guard let chat else { throw AppleError.validation("cursor is missing conversation scope") }
            guard decoded.chatRowid == chat.rowid, decoded.chatGuid == chat.guid else {
                throw AppleError.validation("cursor is for a different conversation")
            }
        case "conversations":
            guard decoded.chatRowid == nil, decoded.chatGuid == nil,
                  decoded.lastMessageRowid == nil else {
                throw AppleError.validation("cursor carries fields for a different operation")
            }
            guard let maxChat = decoded.maxChatRowid, maxChat >= 0,
                  let lastChat = decoded.lastChatRowid, lastChat > 0, lastChat <= maxChat else {
                throw AppleError.validation("cursor has an invalid range")
            }
        default:
            throw AppleError.validation("cursor is for an unsupported operation")
        }
        switch (decoded.lastSeconds, decoded.lastNanoseconds) {
        case (.some, .none), (.none, .some):
            throw AppleError.validation("cursor has an invalid sort key")
        case (_, let nanos?):
            guard nanos >= 0 && nanos < 1_000_000_000 else {
                throw AppleError.validation("cursor has an invalid sort key")
            }
        default:
            break
        }
        return decoded
    }

    private func encodeCursor(_ cursor: ExactCursor) throws -> String {
        let data = try JSONEncoder().encode(cursor)
        let encoded = data.base64EncodedString()
        guard encoded.utf8.count <= ChatDB.exactCursorMaxBytes else {
            throw AppleError.upstream("Messages database identity values produce an oversized pagination cursor")
        }
        return encoded
    }

    private func validateExactCursorJSONShape(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppleError.validation("cursor is malformed")
        }
        let keys = try topLevelJSONKeys(text)
        let allowed = Set(ExactCursor.CodingKeys.allCases.map(\.stringValue))
        var seen: Set<String> = []
        for key in keys {
            guard allowed.contains(key) else {
                throw AppleError.validation("cursor contains an unknown field")
            }
            guard seen.insert(key).inserted else {
                throw AppleError.validation("cursor contains a duplicate field")
            }
        }
    }

    private func topLevelJSONKeys(_ text: String) throws -> [String] {
        let bytes = Array(text.utf8)
        var index = 0
        func skipWhitespace() {
            while index < bytes.count, [UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t")].contains(bytes[index]) {
                index += 1
            }
        }
        func parseString() throws -> String {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                throw AppleError.validation("cursor is malformed")
            }
            index += 1
            var out = Data()
            while index < bytes.count {
                let b = bytes[index]
                index += 1
                if b == UInt8(ascii: "\"") {
                    return String(data: out, encoding: .utf8) ?? ""
                }
                if b == UInt8(ascii: "\\") {
                    guard index < bytes.count else { throw AppleError.validation("cursor is malformed") }
                    let escaped = bytes[index]
                    index += 1
                    switch escaped {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"):
                        out.append(escaped)
                    case UInt8(ascii: "b"):
                        out.append(8)
                    case UInt8(ascii: "f"):
                        out.append(12)
                    case UInt8(ascii: "n"):
                        out.append(10)
                    case UInt8(ascii: "r"):
                        out.append(13)
                    case UInt8(ascii: "t"):
                        out.append(9)
                    case UInt8(ascii: "u"):
                        guard index + 4 <= bytes.count else { throw AppleError.validation("cursor is malformed") }
                        let hex = bytes[index ..< index + 4]
                        index += 4
                        guard let scalar = UInt32(String(decoding: hex, as: UTF8.self), radix: 16),
                              let unicode = UnicodeScalar(scalar) else {
                            throw AppleError.validation("cursor is malformed")
                        }
                        out.append(contentsOf: String(unicode).utf8)
                    default:
                        throw AppleError.validation("cursor is malformed")
                    }
                } else {
                    out.append(b)
                }
            }
            throw AppleError.validation("cursor is malformed")
        }
        func skipValue() throws {
            skipWhitespace()
            guard index < bytes.count else { throw AppleError.validation("cursor is malformed") }
            if bytes[index] == UInt8(ascii: "\"") {
                _ = try parseString()
                return
            }
            var depth = 0
            var inString = false
            var escaped = false
            while index < bytes.count {
                let b = bytes[index]
                if inString {
                    if escaped { escaped = false }
                    else if b == UInt8(ascii: "\\") { escaped = true }
                    else if b == UInt8(ascii: "\"") { inString = false }
                    index += 1
                    continue
                }
                if b == UInt8(ascii: "\"") { inString = true; index += 1; continue }
                if b == UInt8(ascii: "{") || b == UInt8(ascii: "[") { depth += 1; index += 1; continue }
                if b == UInt8(ascii: "}") || b == UInt8(ascii: "]") {
                    if depth == 0 { return }
                    depth -= 1
                    index += 1
                    continue
                }
                if depth == 0 && b == UInt8(ascii: ",") { return }
                index += 1
            }
        }
        skipWhitespace()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else {
            throw AppleError.validation("cursor is malformed")
        }
        index += 1
        var keys: [String] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            skipWhitespace()
            guard index == bytes.count else { throw AppleError.validation("cursor is malformed") }
            return keys
        }
        while true {
            skipWhitespace()
            keys.append(try parseString())
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                throw AppleError.validation("cursor is malformed")
            }
            index += 1
            try skipValue()
            skipWhitespace()
            guard index < bytes.count else { throw AppleError.validation("cursor is malformed") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if bytes[index] == UInt8(ascii: "}") {
                index += 1
                break
            }
            throw AppleError.validation("cursor is malformed")
        }
        skipWhitespace()
        guard index == bytes.count else { throw AppleError.validation("cursor is malformed") }
        return keys
    }

    // MARK: - iMessage availability (oracle `_check_imessage_availability`)

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
        } else if recipient.contains(where: { $0.isASCII && $0.isNumber }) { // oracle uses ASCII isdigit()
            service = "SMS"
            recommendation = "📱 \(recipient) does not have iMessage - messages will automatically fall back to SMS/RCS"
        } else {
            service = "none"
            recommendation = "❌ \(recipient) does not have iMessage and SMS is not available for email addresses"
        }
        return Availability(recipient: recipient, available: hasIMessage, service: service,
                            is_email: isEmail, recommendation: recommendation, handles: handleStats)
    }

    // MARK: - DB access diagnostic (oracle `check_messages_db_access`)

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

    /// Diagnose chat.db access WITHOUT a temp copy (mirrors the oracle's direct open —
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
