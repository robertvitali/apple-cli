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
    private static let directChatStyle: Int64 = 45

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

    public struct ExactThreadOriginator: Encodable, Equatable, Sendable {
        public let available: Bool
        public let reason: String
        public let message_guid: String?
        public let raw_part: String?
        public let native_part: Int?

        enum CodingKeys: String, CodingKey { case available, reason, message_guid, raw_part, native_part }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(available, forKey: .available)
            try c.encode(reason, forKey: .reason)
            try encodeOrNull(&c, message_guid, .message_guid)
            try encodeOrNull(&c, raw_part, .raw_part)
            try encodeOrNull(&c, native_part, .native_part)
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
        public let thread_originator: ExactThreadOriginator

        enum CodingKeys: String, CodingKey {
            case rowid, message_guid, selected_chat_rowid, chat_guid, chat_identifier
            case date, date_local, timestamp, normalized_seconds, normalized_nanoseconds, is_from_me, sender, handle
            case service, body, body_availability, group_name, is_group, has_attachments
            case attachments, native_parts_available, native_parts_reason, native_parts, thread_originator
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
            try c.encode(thread_originator, forKey: .thread_originator)
        }
    }

    struct ExactReplyTarget {
        let chat_rowid: Int64
        let chat_guid: String?
        let message_rowid: Int64
        let message_guid: String
        let native_part: Int
        let part_guid: String?
        let participant_handle: String
        let root_is_from_me: Bool
    }

    struct ExactReplyRow {
        let rowid: Int64
        let message_guid: String?
        let messageGUIDMalformed: Bool
        let selected_chat_rowid: Int64
        let ownershipKnown: Bool
        let is_from_me: Bool
        let bodyKnown: Bool
        let body: String?
        let thread_originator: ExactThreadOriginator
    }

    struct ExactReplyRowScan {
        static let rowLimit = 129

        let chat_rowid: Int64
        let after_highwater: Int64
        let row_limit: Int
        let rows_examined: Int
        let overflow: Bool
        let rows: [ExactReplyRow]
    }

    struct ExactReplyCorrespondence: Encodable, Equatable, Sendable {
        let status: String
        let reason: String?
        let message_rowid: Int64?
        let message_guid: String?
        let parent_message_guid: String?
        let parent_native_part: Int?

        enum CodingKeys: String, CodingKey {
            case status, reason, message_rowid, message_guid, parent_message_guid, parent_native_part
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(status, forKey: .status)
            try encodeOrNull(&c, reason, .reason)
            try encodeOrNull(&c, message_rowid, .message_rowid)
            try encodeOrNull(&c, message_guid, .message_guid)
            try encodeOrNull(&c, parent_message_guid, .parent_message_guid)
            try encodeOrNull(&c, parent_native_part, .parent_native_part)
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

    private struct ExactReadSchema {
        let threadOriginatorColumnsAvailable: Bool
    }

    private static func exactMessageSelect(seconds: String = ChatDB.normalizedSecondsSQL,
                                           nanos: String = ChatDB.normalizedNanosecondsSQL,
                                           schema: ExactReadSchema) -> String {
        let originatorSelect = schema.threadOriginatorColumnsAvailable
            ? "m.thread_originator_guid AS thread_originator_guid, m.thread_originator_part AS thread_originator_part"
            : "NULL AS thread_originator_guid, NULL AS thread_originator_part"
        return """
        SELECT m.ROWID AS rowid, m.guid AS message_guid, m.date AS date,
               \(seconds) AS normalized_seconds,
               \(nanos) AS normalized_nanoseconds,
               m.text AS text, m.attributedBody AS attributedBody,
               m.is_from_me AS is_from_me, m.handle_id AS handle_rowid,
               m.cache_roomnames AS cache_roomnames, m.service AS service,
               m.cache_has_attachments AS cache_has_attachments,
               \(originatorSelect),
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
        _ = try requireExactReadSchema()
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
        let schema = try requireExactReadSchema()
        let chat = try resolveExactChat(selector)
        let decoded = try decodeCursor(cursor, op: "history", chat: chat, order: order)
        let maxMessage: Int64
        if let decoded {
            maxMessage = decoded.maxMessageRowid
        } else {
            maxMessage = try maxRowid(table: "message")
        }
        let orderSQL = order == .desc ? "DESC" : "ASC"
        var sql = ChatDB.exactMessageSelect(schema: schema) + """

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
        let messages = try shapeExactMessages(rows: reader.rows(sql, binds), schema: schema)
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
        let schema = try requireExactReadSchema()
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
        let sql = ChatDB.exactMessageSelect(schema: schema) + """

        WHERE c.ROWID = ?1 AND \(messagePredicate)
        LIMIT 1
        """
        let messages = try shapeExactMessages(rows: reader.rows(sql, [String(chat.rowid), bind]), schema: schema)
        guard let message = messages.first else {
            throw AppleError.notFound("message is not a member of the selected conversation")
        }
        return (chat, message)
    }

    mutating func exactReplyTarget(chat selector: ExactChatSelector,
                                           message messageSelector: ExactMessageSelector,
                                           partIndex: Int? = nil) throws -> ExactReplyTarget {
        let (chat, message) = try exactGet(chat: selector, message: messageSelector)
        guard message.selected_chat_rowid == chat.rowid else {
            throw AppleError.validation("reply target message is not in the selected conversation")
        }
        let strictTarget = try exactReplyTargetEvidence(chatRowid: chat.rowid, messageRowid: message.rowid)
        let participants = try exactParticipantHandles(chatRowid: chat.rowid)
        guard participants.count == 1 else {
            throw AppleError.validation("reply target direct conversation must have exactly one participant")
        }
        guard message.thread_originator.available, message.thread_originator.reason == "no-linkage" else {
            throw AppleError.validation("reply target must be a root message")
        }
        let nativePart = try resolveExactReplyPart(message, requested: partIndex)
        let partGUID = message.native_parts?.first(where: { $0.index == nativePart })?.attachment_guid
        return ExactReplyTarget(chat_rowid: chat.rowid,
                                chat_guid: strictTarget.chatGUID,
                                message_rowid: message.rowid,
                                message_guid: strictTarget.messageGUID,
                                native_part: nativePart,
                                part_guid: partGUID,
                                participant_handle: participants[0],
                                root_is_from_me: strictTarget.isFromMe)
    }

    func exactReplyHighwater(chatRowid: Int64) throws -> Int64 {
        guard chatRowid > 0 else { throw AppleError.validation("chatRowid must be > 0") }
        try validateExactReplyMembershipEvidence(chatRowid: chatRowid)
        let rows = try reader.rows("""
            SELECT COALESCE(MAX(m.ROWID), 0) AS max_rowid
            FROM chat_message_join cmj
            JOIN message m ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id = CAST(?1 AS INTEGER)
            """, [String(chatRowid)])
        guard let row = rows.first, case .integer(let highwater)? = row.values["max_rowid"] else {
            throw AppleError.upstream("Messages database reply highwater query returned an invalid rowid")
        }
        return highwater
    }

    mutating func exactReplyRows(chatRowid: Int64, afterHighwater: Int64) throws -> ExactReplyRowScan {
        guard chatRowid > 0 else { throw AppleError.validation("chatRowid must be > 0") }
        guard afterHighwater >= 0 else { throw AppleError.validation("afterHighwater must be >= 0") }
        try validateExactReplyMembershipEvidence(chatRowid: chatRowid)
        let schema = try requireExactReadSchema()
        let originatorSelect = schema.threadOriginatorColumnsAvailable
            ? "m.thread_originator_guid AS thread_originator_guid, m.thread_originator_part AS thread_originator_part"
            : "NULL AS thread_originator_guid, NULL AS thread_originator_part"
        let rows = try reader.rows("""
            SELECT m.ROWID AS rowid, m.guid AS message_guid, m.text AS text,
                   m.attributedBody AS attributedBody, m.is_from_me AS is_from_me,
                   \(originatorSelect), cmj.chat_id AS join_chat_id,
                   cmj.message_id AS join_message_id, c.ROWID AS selected_chat_rowid
            FROM chat_message_join cmj
            JOIN chat c ON c.ROWID = cmj.chat_id
            JOIN message m ON m.ROWID = cmj.message_id
            WHERE c.ROWID = ?1 AND m.ROWID > CAST(?2 AS INTEGER)
            ORDER BY m.ROWID ASC
            LIMIT \(ExactReplyRowScan.rowLimit)
            """, [String(chatRowid), String(afterHighwater)])
        let shaped = try shapeExactReplyRows(rows, chatRowid: chatRowid, schema: schema)
        return ExactReplyRowScan(chat_rowid: chatRowid,
                                 after_highwater: afterHighwater,
                                 row_limit: ExactReplyRowScan.rowLimit,
                                 rows_examined: shaped.count,
                                 overflow: shaped.count >= ExactReplyRowScan.rowLimit,
                                 rows: shaped)
    }

    static func judgeExactReplyCorrespondence(scan: ExactReplyRowScan,
                                                     target: ExactReplyTarget,
                                                     expectedText: String) throws -> ExactReplyCorrespondence {
        if scan.overflow {
            return replyUncertain("row-limit-exceeded")
        }
        var matches: [ExactReplyRow] = []
        for row in scan.rows {
            guard row.ownershipKnown else { return replyUncertain("unknown-ownership") }
            guard row.is_from_me else { continue }
            guard row.bodyKnown else { return replyUncertain("unknown-outgoing-body") }
            guard let body = row.body, body.utf8.elementsEqual(expectedText.utf8) else { continue }
            guard row.rowid > scan.after_highwater, row.rowid > 0 else {
                return replyUncertain("matching-row-malformed")
            }
            guard row.selected_chat_rowid == target.chat_rowid else {
                return replyUncertain("matching-row-wrong-chat")
            }
            guard !row.messageGUIDMalformed, let guid = row.message_guid, !guid.isEmpty else {
                return replyUncertain("matching-row-missing-guid")
            }
            let originator = row.thread_originator
            guard originator.available else {
                switch originator.reason {
                case "partial" where originator.message_guid == nil:
                    return replyUncertain("matching-row-missing-parent-guid")
                case "partial" where originator.raw_part == nil:
                    return replyUncertain("matching-row-missing-parent-part")
                case "malformed", "unsupported-part-marker":
                    return replyUncertain("matching-row-malformed-parent")
                default:
                    return replyUncertain("matching-row-malformed-parent")
                }
            }
            guard originator.reason == "available",
                  let parentGUID = originator.message_guid,
                  parentGUID.utf8.elementsEqual(target.message_guid.utf8),
                  originator.native_part == target.native_part else {
                return replyUncertain("matching-row-wrong-parent")
            }
            matches.append(row)
        }
        guard let match = matches.first else {
            return ExactReplyCorrespondence(status: "waiting", reason: nil, message_rowid: nil,
                                            message_guid: nil, parent_message_guid: nil, parent_native_part: nil)
        }
        guard matches.count == 1 else {
            return replyUncertain("duplicate-matching-replies")
        }
        return ExactReplyCorrespondence(status: "verified", reason: nil, message_rowid: match.rowid,
                                        message_guid: match.message_guid,
                                        parent_message_guid: match.thread_originator.message_guid,
                                        parent_native_part: match.thread_originator.native_part)
    }

    public mutating func exactReactionInspect(chat selector: ExactChatSelector,
                                              message messageSelector: ExactMessageSelector,
                                              partIndex: Int? = nil,
                                              rowLimit: Int = 512) throws -> ExactReactionInspect {
        guard (1...10_000).contains(rowLimit) else {
            throw AppleError.validation("rowLimit must be between 1 and 10000")
        }
        // The shared legacy binder uses C-string lengths. Refuse unsafe selectors
        // before exactGet so an embedded NUL cannot resolve a different GUID.
        if case .guid(let guid) = selector, !safeReactionTargetGUID(guid) {
            throw AppleError.validation("reaction chat GUID is empty or contains unsafe controls")
        }
        if case .guid(let guid) = messageSelector, !safeReactionTargetGUID(guid) {
            throw AppleError.validation("reaction message GUID is empty or contains unsafe controls")
        }
        let (chat, message) = try exactGet(chat: selector, message: messageSelector)
        let chatTarget = ExactReactionChatTarget(rowid: chat.rowid, guid: chat.guid)
        let messageTarget = ExactReactionMessageTarget(rowid: message.rowid, guid: message.message_guid)
        var unknownReasons: [String] = []
        // ROWID selection bypasses selector validation; the stored identity still
        // has to be safe before either an outgoing state or mutation is authoritative.
        let chatGUIDSafe = chat.guid.map(safeReactionTargetGUID) ?? false
        if !chatGUIDSafe {
            unknownReasons.append(chat.guid == nil ? "missing-target-chat-guid" : "unsafe-target-chat-guid")
        }
        let chatGUIDUnique: Bool
        if chatGUIDSafe, let guid = chat.guid {
            chatGUIDUnique = try reactionChatGUIDIdentifiesSelectedChat(guid, chatRowid: chat.rowid)
            if !chatGUIDUnique { unknownReasons.append("target-chat-guid-not-globally-unique") }
        } else {
            chatGUIDUnique = false
        }

        let reactionSchema = try reactionColumns()
        guard reactionSchema.available else {
            unknownReasons.append(contentsOf: reactionSchema.missing.map { "missing-reaction-column:\($0)" })
            return ExactReactionInspect(
                status: "unavailable",
                chat: chatTarget,
                message: messageTarget,
                target: ExactReactionTarget(chat_rowid: chat.rowid, chat_guid: chat.guid,
                                            message_rowid: message.rowid, message_guid: message.message_guid,
                                            part_index: nil, mutation_eligible: false),
                current_outgoing: ExactCurrentOutgoingReaction(status: "unknown", key: nil, reaction: nil),
                reactions_by_author: [],
                evidence: ExactReactionEvidence(row_limit: rowLimit, rows_examined: 0,
                                                rows_capped: false, unknown_reasons: unknownReasons)
            )
        }

        let provenPart = try resolveExactReactionPart(message, requested: partIndex, unknownReasons: &unknownReasons)
        guard let messageGUID = message.message_guid, safeReactionTargetGUID(messageGUID) else {
            unknownReasons.append(message.message_guid == nil ? "missing-target-guid" : "unsafe-target-guid")
            return ExactReactionInspect(
                status: message.message_guid == nil ? "unavailable" : "ambiguous",
                chat: chatTarget,
                message: messageTarget,
                target: ExactReactionTarget(chat_rowid: chat.rowid, chat_guid: chat.guid,
                                            message_rowid: message.rowid, message_guid: message.message_guid,
                                            part_index: provenPart, mutation_eligible: false),
                current_outgoing: ExactCurrentOutgoingReaction(status: "unknown", key: nil, reaction: nil),
                reactions_by_author: [],
                evidence: ExactReactionEvidence(row_limit: rowLimit, rows_examined: 0,
                                                rows_capped: false, unknown_reasons: unknownReasons)
            )
        }

        let aliases = reactionAliases(messageGUID: messageGUID, parts: reactionAliasParts(message, selected: provenPart))
        let rows = try reactionRows(chatRowid: chat.rowid, aliases: aliases.all, rowLimit: rowLimit,
                                    hasCustomEmoji: reactionSchema.hasCustomEmoji)
        var capped = false
        let visibleRows: [SQLiteReader.Row]
        if rows.count > rowLimit {
            capped = true
            unknownReasons.append("reaction-row-limit-exceeded")
            visibleRows = Array(rows.prefix(rowLimit))
        } else {
            visibleRows = rows
        }

        let guidUnique = try messageGUIDIsGloballyUnique(messageGUID)
        if !guidUnique { unknownReasons.append("target-guid-not-globally-unique") }
        let aliasOwnershipUnique = try reactionAliasesHaveSingleOwner(aliases.all, messageRowid: message.rowid)
        if !aliasOwnershipUnique { unknownReasons.append("ambiguous-reaction-alias-ownership") }
        let membership = try exactSingleChatMembership(messageRowid: message.rowid, chatRowid: chat.rowid)
        if membership.capped {
            unknownReasons.append("target-chat-membership-limit-exceeded")
        } else if !membership.single {
            unknownReasons.append("target-message-not-distinct-single-chat-member")
        }
        let targetUncertain = !chatGUIDSafe || !chatGUIDUnique || !guidUnique || !aliasOwnershipUnique || !membership.single || membership.capped
            || provenPart == nil || capped
        let authorStates = foldReactions(rows: visibleRows, selectedAliases: aliases.selected,
                                         bareAliases: aliases.bare, targetUncertain: targetUncertain,
                                         hasCustomEmoji: reactionSchema.hasCustomEmoji,
                                         unknownReasons: &unknownReasons)
        if provenPart == nil {
            unknownReasons.append("unknown-part")
        }
        let currentOutgoing: ExactCurrentOutgoingReaction
        if targetUncertain || authorStates.contains(where: { $0.author.kind == "unknown" || ($0.author.kind == "self" && $0.status == "unknown") }) {
            currentOutgoing = ExactCurrentOutgoingReaction(status: "unknown", key: nil, reaction: nil)
        } else if let mine = authorStates.first(where: { $0.author.kind == "self" })?.current {
            currentOutgoing = ExactCurrentOutgoingReaction(status: "present", key: mine.key, reaction: mine)
        } else {
            currentOutgoing = ExactCurrentOutgoingReaction(status: "absent", key: nil, reaction: nil)
        }

        let mutationEligible = chatGUIDSafe
            && chatGUIDUnique
            && guidUnique
            && aliasOwnershipUnique
            && membership.single
            && !membership.capped
            && provenPart != nil
            && !capped
            && currentOutgoing.status != "unknown"
            && unknownReasons.isEmpty
        let status = unknownReasons.isEmpty ? "ok" : "ambiguous"

        return ExactReactionInspect(
            status: status,
            chat: chatTarget,
            message: messageTarget,
            target: ExactReactionTarget(chat_rowid: chat.rowid, chat_guid: chat.guid,
                                        message_rowid: message.rowid, message_guid: message.message_guid,
                                        part_index: provenPart, mutation_eligible: mutationEligible),
            current_outgoing: currentOutgoing,
            reactions_by_author: authorStates,
            evidence: ExactReactionEvidence(row_limit: rowLimit, rows_examined: visibleRows.count,
                                            rows_capped: capped,
                                            unknown_reasons: Array(Set(unknownReasons)).sorted())
        )
    }

    public func exactParticipantHandles(chatRowid: Int64) throws -> [String] {
        _ = try requiredColumns("chat_handle_join", ["chat_id", "handle_id"])
        _ = try requiredColumns("handle", ["ROWID", "id"])
        let rows = try reader.rows("""
            SELECT chj.chat_id AS join_chat_rowid, chj.handle_id AS handle_rowid, h.id AS handle
            FROM chat_handle_join chj
            LEFT JOIN handle h ON h.ROWID = chj.handle_id
            WHERE chj.chat_id = CAST(?1 AS INTEGER)
            ORDER BY chj.handle_id
            LIMIT 10001
            """, [String(chatRowid)])
        guard !rows.isEmpty, rows.count <= 10_000 else {
            throw AppleError.upstream("Messages database chat participants are missing or exceed the inspection limit")
        }
        var handles: [String] = []
        for row in rows {
            guard case .integer(let joinedChatRowid)? = row.values["join_chat_rowid"],
                  joinedChatRowid == chatRowid else {
                throw AppleError.upstream("Messages database chat participant references an invalid chat id")
            }
            guard case .integer(let handleRowid)? = row.values["handle_rowid"], handleRowid > 0 else {
                throw AppleError.upstream("Messages database returned a chat participant without a handle id")
            }
            guard case .text(let handle)? = row.values["handle"], !handle.isEmpty else {
                throw AppleError.upstream("Messages database chat participant references a missing or unknown handle")
            }
            handles.append(handle)
        }
        return handles
    }

    private func exactReplyTargetEvidence(chatRowid: Int64, messageRowid: Int64) throws -> (chatGUID: String, messageGUID: String, isFromMe: Bool) {
        let rows = try reader.rows("""
            SELECT c.guid AS chat_guid, c.style AS chat_style,
                   m.guid AS message_guid, m.is_from_me AS is_from_me,
                   cmj.chat_id AS join_chat_id, cmj.message_id AS join_message_id
            FROM chat_message_join cmj
            JOIN chat c ON c.ROWID = cmj.chat_id
            JOIN message m ON m.ROWID = cmj.message_id
            WHERE c.ROWID = ?1 AND m.ROWID = ?2
            LIMIT 2
            """, [String(chatRowid), String(messageRowid)])
        guard rows.count == 1 else {
            throw AppleError.validation("reply target message is not a distinct member of the selected conversation")
        }
        let row = rows[0]
        guard case .integer(let joinedChat)? = row.values["join_chat_id"], joinedChat == chatRowid,
              case .integer(let joinedMessage)? = row.values["join_message_id"], joinedMessage == messageRowid else {
            throw AppleError.validation("reply target chat membership is malformed")
        }
        guard case .text(let chatGUID)? = row.values["chat_guid"], !chatGUID.isEmpty else {
            throw AppleError.validation("reply target chat is missing a strict GUID")
        }
        guard case .integer(let style)? = row.values["chat_style"], style == ChatDB.directChatStyle else {
            throw AppleError.validation("reply target must be in a supported direct conversation")
        }
        guard case .text(let messageGUID)? = row.values["message_guid"], !messageGUID.isEmpty else {
            throw AppleError.validation("reply target message is missing a strict GUID")
        }
        guard case .integer(let fromMeRaw)? = row.values["is_from_me"], fromMeRaw == 0 || fromMeRaw == 1 else {
            throw AppleError.validation("reply target ownership is malformed")
        }
        return (chatGUID, messageGUID, fromMeRaw != 0)
    }

    private func validateExactReplyMembershipEvidence(chatRowid: Int64) throws {
        _ = try requiredColumns("chat_message_join", ["chat_id", "message_id"])
        _ = try requiredColumns("message", ["ROWID"])
        let malformed = try reader.rows("""
            SELECT cmj.chat_id AS join_chat_id, cmj.message_id AS join_message_id, m.ROWID AS rowid
            FROM chat_message_join cmj
            LEFT JOIN message m ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id = CAST(?1 AS INTEGER)
              AND (typeof(cmj.chat_id) != 'integer'
                   OR typeof(cmj.message_id) != 'integer'
                   OR m.ROWID IS NULL)
            LIMIT 1
            """, [String(chatRowid)])
        guard malformed.isEmpty else {
            throw AppleError.upstream("Messages database reply chat membership evidence is malformed")
        }
    }

    private mutating func shapeExactReplyRows(_ rows: [SQLiteReader.Row], chatRowid: Int64,
                                              schema: ExactReadSchema) throws -> [ExactReplyRow] {
        try rows.map { row in
            let rowid = try requiredStrictInteger(row, "rowid")
            guard case .integer(let joinedChat)? = row.values["join_chat_id"], joinedChat == chatRowid,
                  case .integer(let joinedMessage)? = row.values["join_message_id"], joinedMessage == rowid else {
                throw AppleError.upstream("Messages database reply row membership evidence is malformed")
            }
            guard case .integer(let selectedChat)? = row.values["selected_chat_rowid"], selectedChat == chatRowid else {
                throw AppleError.upstream("Messages database reply row selected chat evidence is malformed")
            }
            let guidInfo = strictOptionalText(row.values["message_guid"])
            let ownership = strictReplyOwnership(row.values["is_from_me"])
            let body = strictReplyBody(row)
            return ExactReplyRow(rowid: rowid,
                                 message_guid: guidInfo.text,
                                 messageGUIDMalformed: guidInfo.malformed,
                                 selected_chat_rowid: selectedChat,
                                 ownershipKnown: ownership.known,
                                 is_from_me: ownership.isFromMe,
                                 bodyKnown: body.known,
                                 body: body.body,
                                 thread_originator: exactThreadOriginator(row, schema: schema))
        }
    }

    private func requiredStrictInteger(_ row: SQLiteReader.Row, _ column: String) throws -> Int64 {
        guard case .integer(let value)? = row.values[column] else {
            throw AppleError.upstream("Messages database query did not return strict integer column '\(column)'")
        }
        return value
    }

    private func strictOptionalText(_ value: SQLiteReader.Row.Value?) -> (text: String?, malformed: Bool) {
        switch value {
        case .text(let text)?: return (text, false)
        case .null?, nil: return (nil, false)
        default: return (nil, true)
        }
    }

    private func strictReplyOwnership(_ value: SQLiteReader.Row.Value?) -> (known: Bool, isFromMe: Bool) {
        guard case .integer(let raw)? = value, raw == 0 || raw == 1 else { return (false, false) }
        return (true, raw != 0)
    }

    private func strictReplyBody(_ row: SQLiteReader.Row) -> (known: Bool, body: String?) {
        switch row.values["text"] {
        case .text(let text)?: return (true, text)
        case .null?, nil: break
        default: return (false, nil)
        }
        switch row.values["attributedBody"] {
        case .blob(let data)?:
            guard let decoded = AttributedBody.decode(data) else { return (false, nil) }
            return (true, decoded)
        case .null?, nil:
            return (true, nil)
        default:
            return (false, nil)
        }
    }

    private static func replyUncertain(_ reason: String) -> ExactReplyCorrespondence {
        ExactReplyCorrespondence(status: "uncertain", reason: reason, message_rowid: nil,
                                 message_guid: nil, parent_message_guid: nil, parent_native_part: nil)
    }

    private func resolveExactReplyPart(_ message: ExactMessage, requested: Int?) throws -> Int {
        if let requested {
            guard requested >= 0 else { throw AppleError.validation("partIndex must be >= 0") }
            guard message.native_parts_available, let parts = message.native_parts,
                  parts.contains(where: { $0.index == requested }) else {
                throw AppleError.validation("reply target native part is not proven")
            }
            return requested
        }
        guard message.native_parts_available, let parts = message.native_parts else {
            throw AppleError.validation("reply target native parts are unavailable: \(message.native_parts_reason)")
        }
        let indexes = Set(parts.map(\.index))
        guard indexes.count == 1, let only = indexes.first else {
            throw AppleError.validation("reply target requires an explicit native part")
        }
        return only
    }

    private func reactionColumns() throws -> (available: Bool, missing: [String], hasCustomEmoji: Bool) {
        let columns = try requiredColumns("message", ["ROWID"])
        let required: Set<String> = ["associated_message_guid", "associated_message_type", "is_from_me", "handle_id", "date"]
        let missing = required.subtracting(columns).sorted()
        return (missing.isEmpty, missing, columns.contains("associated_message_emoji"))
    }

    private func resolveExactReactionPart(_ message: ExactMessage, requested: Int?,
                                          unknownReasons: inout [String]) throws -> Int? {
        if let requested {
            guard requested >= 0 else { throw AppleError.validation("partIndex must be >= 0") }
            if message.native_parts_available,
               let parts = message.native_parts,
               parts.contains(where: { $0.index == requested }) {
                return requested
            }
            unknownReasons.append("part-not-proven")
            return nil
        }
        guard message.native_parts_available, let parts = message.native_parts else {
            unknownReasons.append("native-parts-unavailable:\(message.native_parts_reason)")
            return nil
        }
        let indexes = Set(parts.map(\.index))
        if indexes.count == 1 { return indexes.first }
        if indexes.count > 1 {
            unknownReasons.append("multiple-native-parts-require-explicit-part")
            return nil
        }
        unknownReasons.append("empty-native-parts")
        return nil
    }

    private func reactionAliasParts(_ message: ExactMessage, selected: Int?) -> [Int] {
        if let selected { return [selected] }
        guard message.native_parts_available, let parts = message.native_parts else { return [] }
        return Array(Set(parts.map(\.index))).sorted()
    }

    private func reactionAliases(messageGUID: String, parts: [Int]) -> (selected: Set<String>, bare: Set<String>, all: [String]) {
        let bare = Set([messageGUID, "bp:\(messageGUID)"])
        var selected = bare
        for part in parts {
            selected.insert("p:\(part)/\(messageGUID)")
            selected.insert("p:\(part)/bp:\(messageGUID)")
        }
        return (selected, bare, Array(selected).sorted())
    }

    private func reactionAliasesHaveSingleOwner(_ aliases: [String], messageRowid: Int64) throws -> Bool {
        // Invert EVERY accepted alias form: H, bp:H, p:N/H, p:N/bp:H.
        // A literal-GUID uniqueness check misses G versus bp:G, and checking only
        // those two misses a message whose literal GUID is p:N/G. Check globally,
        // including possible parts of other messages without assuming their bodies
        // prove absence. One additional possible owner is sufficient to refuse.
        var owners = Set(aliases)
        for alias in aliases {
            if alias.hasPrefix("bp:") { owners.insert(String(alias.dropFirst(3))) }
            if alias.hasPrefix("p:"), let slash = alias.firstIndex(of: "/") {
                let part = String(alias[alias.index(alias.startIndex, offsetBy: 2)..<slash])
                if let index = Int(part), index >= 0, String(index) == part {
                    let suffix = String(alias[alias.index(after: slash)...])
                    owners.insert(suffix)
                    if suffix.hasPrefix("bp:") { owners.insert(String(suffix.dropFirst(3))) }
                }
            }
        }
        let candidates = owners.sorted()
        let placeholders = candidates.indices.map { "?\($0 + 1)" }.joined(separator: ", ")
        let rows = try reader.rows("""
            SELECT ROWID AS rowid FROM message
            WHERE guid COLLATE BINARY IN (\(placeholders))
            LIMIT 2
            """, candidates)
        return rows.count == 1 && rows[0].int("rowid") == messageRowid
    }

    private func reactionRows(chatRowid: Int64, aliases: [String], rowLimit: Int,
                              hasCustomEmoji: Bool) throws -> [SQLiteReader.Row] {
        guard !aliases.isEmpty else { return [] }
        let placeholders = aliases.indices.map { "?\($0 + 2)" }.joined(separator: ", ")
        let customEmojiSQL = hasCustomEmoji ? "m.associated_message_emoji" : "NULL"
        let sql = """
            SELECT m.ROWID AS rowid, m.guid AS message_guid,
                   m.associated_message_guid AS associated_message_guid,
                   m.associated_message_type AS associated_message_type,
                   \(customEmojiSQL) AS associated_message_emoji,
                   m.is_from_me AS is_from_me, m.handle_id AS handle_id, m.date AS raw_date,
                   \(ChatDB.normalizedSecondsSQL) AS normalized_seconds,
                   \(ChatDB.normalizedNanosecondsSQL) AS normalized_nanoseconds
            FROM chat_message_join cmj
            JOIN message m ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id = CAST(?1 AS INTEGER)
              AND m.associated_message_guid IN (\(placeholders))
            ORDER BY normalized_seconds, normalized_nanoseconds, m.ROWID
            LIMIT \(rowLimit + 1)
            """
        return try reader.rows(sql, [String(chatRowid)] + aliases)
    }

    private func foldReactions(rows: [SQLiteReader.Row], selectedAliases: Set<String>, bareAliases: Set<String>,
                               targetUncertain: Bool, hasCustomEmoji: Bool,
                               unknownReasons: inout [String]) -> [ExactReactionAuthorState] {
        struct Accumulator {
            var author: ExactReactionAuthor
            var current: ExactReactionValue?
            var events: [ExactReactionEvent] = []
            var unknown = false
        }
        var states: [String: Accumulator] = [:]
        var order: [String] = []

        for row in rows {
            guard let associatedGUID = row.text("associated_message_guid"),
                  selectedAliases.contains(associatedGUID) else { continue }
            // No recorded contract proves any exact-associated type is irrelevant.
            // Retain future/NULL types as evidence; never guess their add/remove action.
            let rawType: Int64?
            if case .integer(let value)? = row.values["associated_message_type"] {
                rawType = value
            } else {
                rawType = nil
            }
            let customEmoji: String?
            if case .text(let value)? = row.values["associated_message_emoji"] {
                customEmoji = value
            } else {
                customEmoji = nil
            }
            let mapped = rawType.flatMap {
                reactionValue(type: $0, emoji: customEmoji, hasCustomEmoji: hasCustomEmoji)
            } ?? (action: "unknown", value: ExactReactionValue(
                key: "unsupported:type:\(rawType.map(String.init) ?? "unknown")",
                name: "unknown", emoji: customEmoji, supported: false))
            var uncertain = targetUncertain || !mapped.value.supported
            if !mapped.value.supported { unknownReasons.append("unknown-reaction-type") }
            if rawType == 2006 || rawType == 3006, mapped.value.emoji == nil {
                unknownReasons.append("missing-custom-emoji")
            }
            // Even a sole decoded native part does not prove that a bare GUID or
            // bp:GUID event refers to it. The contract permits default part selection,
            // not alias remapping. Keep the evidence but refuse an authoritative fold.
            if bareAliases.contains(associatedGUID) {
                uncertain = true
                unknownReasons.append("bare-associated-message-guid-for-part-target")
            }

            let author = reactionAuthor(row)
            let authorKey = reactionAuthorKey(author)
            if author.kind == "unknown" {
                uncertain = true
                unknownReasons.append("unknown-author")
            }
            // SQL arithmetic can coerce malformed TEXT/REAL into plausible dates.
            // Only integer storage and integer normalization may establish ordering.
            let seconds: Int64?
            let nanos: Int64?
            if case .integer? = row.values["raw_date"],
               case .integer(let s)? = row.values["normalized_seconds"],
               case .integer(let n)? = row.values["normalized_nanoseconds"],
               (0..<1_000_000_000).contains(n) {
                seconds = s
                nanos = n
            } else {
                seconds = nil
                nanos = nil
                uncertain = true
                if case .null? = row.values["raw_date"] {
                    unknownReasons.append("null-reaction-timestamp")
                } else {
                    unknownReasons.append("invalid-reaction-timestamp")
                }
            }
            if states[authorKey] == nil {
                states[authorKey] = Accumulator(author: author)
                order.append(authorKey)
            }
            let event = ExactReactionEvent(
                rowid: row.int("rowid") ?? 0,
                message_guid: row.text("message_guid"),
                action: mapped.action,
                associated_message_guid: associatedGUID,
                reaction: mapped.value,
                normalized_seconds: seconds,
                normalized_nanoseconds: nanos
            )
            states[authorKey]?.events.append(event)
            // Uncertainty is sticky across this author's entire fold: a later known
            // event cannot establish ordering against an undated or unsupported event.
            if uncertain { states[authorKey]?.unknown = true }
            if mapped.action == "add" {
                states[authorKey]?.current = mapped.value
            } else if let current = states[authorKey]?.current,
                      current.key.utf8.elementsEqual(mapped.value.key.utf8) {
                // Swift String equality normalizes Unicode; reaction identity must
                // retain byte-distinct custom graphemes, including variation selectors.
                states[authorKey]?.current = nil
            }
        }
        return order.compactMap { key in
            guard let state = states[key] else { return nil }
            return ExactReactionAuthorState(author: state.author,
                                           current: state.unknown ? nil : state.current, events: state.events,
                                           status: state.unknown ? "unknown" : (state.current == nil ? "absent" : "present"))
        }
    }

    private func reactionAuthor(_ row: SQLiteReader.Row) -> ExactReactionAuthor {
        // Row.int intentionally coerces REAL/TEXT elsewhere. Author identity cannot
        // use that coercion: 0.5, NULL, or a future flag value is not a known sender.
        switch row.values["is_from_me"] {
        case .integer(1)?:
            return ExactReactionAuthor(kind: "self", handle_id: nil, is_from_me: true)
        case .integer(0)?:
            guard case .integer(let handleID)? = row.values["handle_id"], handleID > 0 else {
                return ExactReactionAuthor(kind: "unknown", handle_id: nil, is_from_me: false)
            }
            return ExactReactionAuthor(kind: "other", handle_id: handleID, is_from_me: false)
        default:
            return ExactReactionAuthor(kind: "unknown", handle_id: nil, is_from_me: nil)
        }
    }

    private func reactionAuthorKey(_ author: ExactReactionAuthor) -> String {
        switch author.kind {
        case "self": return "self"
        case "other": return "handle:\(author.handle_id ?? -1)"
        default: return "unknown"
        }
    }

    private func reactionValue(type: Int64, emoji: String?, hasCustomEmoji: Bool) -> (action: String, value: ExactReactionValue)? {
        guard (2000...2007).contains(type) || (3000...3007).contains(type) else { return nil }
        let add = (2000...2007).contains(type)
        let normalized = add ? type : type - 1000
        let action = add ? "add" : "remove"
        switch normalized {
        case 2000: return (action, ExactReactionValue(key: "heart", name: "heart", emoji: nil, supported: true))
        case 2001: return (action, ExactReactionValue(key: "like", name: "like", emoji: nil, supported: true))
        case 2002: return (action, ExactReactionValue(key: "dislike", name: "dislike", emoji: nil, supported: true))
        case 2003: return (action, ExactReactionValue(key: "laugh", name: "laugh", emoji: nil, supported: true))
        case 2004: return (action, ExactReactionValue(key: "emphasize", name: "emphasize", emoji: nil, supported: true))
        case 2005: return (action, ExactReactionValue(key: "question", name: "question", emoji: nil, supported: true))
        case 2006:
            let value = hasCustomEmoji ? emoji.flatMap { validCustomReactionEmoji($0) ? $0 : nil } : nil
            return (action, ExactReactionValue(key: value.map { "custom:\($0)" } ?? "custom:unknown",
                                               name: value == nil ? "unknown" : "custom",
                                               emoji: value, supported: value != nil))
        case 2007:
            return (action, ExactReactionValue(key: "unsupported:sticker", name: "unknown", emoji: nil, supported: false))
        default:
            return nil
        }
    }

    private func safeReactionTargetGUID(_ guid: String) -> Bool {
        !guid.isEmpty && !guid.unicodeScalars.contains {
            switch $0.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }

    private func validCustomReactionEmoji(_ value: String) -> Bool {
        // Deliberately bounded grammar, not a claim to support every Unicode emoji:
        // * keycap: [0-9#*] FE0F? 20E3;
        // * standalone non-component emoji scalar, optionally FE0F for a text-
        //   presentation base OR one modifier for an Emoji_Modifier_Base;
        // * technologist ZWJ: [woman|man|person] modifier? 200D laptop.
        // Flags, tags, other ZWJ sequences and all unconsumed suffixes are unknown.
        // Validate scalars only; never normalize, strip or re-encode the value.
        let scalars = Array(value.unicodeScalars)
        guard let first = scalars.first else { return false }
        let codes = scalars.map(\.value)
        if (0x30...0x39).contains(first.value) || first.value == 0x23 || first.value == 0x2A {
            return codes == [first.value, 0x20E3] || codes == [first.value, 0xFE0F, 0x20E3]
        }
        if codes.contains(0x200D) {
            guard [UInt32(0x1F469), 0x1F468, 0x1F9D1].contains(first.value) else { return false }
            if codes.count == 3 { return codes[1...] == [0x200D, 0x1F4BB] }
            return codes.count == 4 && scalars[1].properties.isEmojiModifier
                && codes[2...] == [0x200D, 0x1F4BB]
        }
        guard first.value > 0x7F, first.properties.isEmoji,
              !first.properties.isEmojiModifier,
              !(0x1F1E6...0x1F1FF).contains(first.value), // regional-indicator components
              !(0x1F9B0...0x1F9B3).contains(first.value) // hair components
        else { return false }
        if codes.count == 1 { return true }
        guard codes.count == 2 else { return false }
        return (codes[1] == 0xFE0F && !first.properties.isEmojiPresentation)
            || (first.properties.isEmojiModifierBase && scalars[1].properties.isEmojiModifier)
    }

    private func messageGUIDIsGloballyUnique(_ guid: String) throws -> Bool {
        let rows = try reader.rows("SELECT COUNT(*) AS count FROM message WHERE guid = ?1", [guid])
        return rows.first?.int("count") == 1
    }

    private func reactionChatGUIDIdentifiesSelectedChat(_ guid: String, chatRowid: Int64) throws -> Bool {
        let rows = try reader.rows("""
            SELECT ROWID AS rowid FROM chat
            WHERE guid COLLATE BINARY = ?1
            LIMIT 2
            """, [guid])
        return rows.count == 1 && rows[0].int("rowid") == chatRowid
    }

    private func exactSingleChatMembership(messageRowid: Int64, chatRowid: Int64) throws -> (single: Bool, capped: Bool) {
        // Numeric parameter casts preserve matches even without column affinity;
        // leave stored membership values untouched for the validation below.
        let rows = try reader.rows("""
            SELECT chat_id, message_id
            FROM chat_message_join
            WHERE message_id = CAST(?1 AS INTEGER)
            LIMIT 10001
            """, [String(messageRowid)])
        if rows.count > 10_000 { return (false, true) }
        // Validate storage before deduplication; neither Row.int nor SQLite DISTINCT
        // may collapse malformed REAL membership evidence into an integer identity.
        var chatIDs: Set<Int64> = []
        for row in rows {
            guard case .integer(let id)? = row.values["chat_id"],
                  case .integer(let storedMessageID)? = row.values["message_id"],
                  storedMessageID == messageRowid else { return (false, false) }
            chatIDs.insert(id)
        }
        return (chatIDs.count == 1 && chatIDs.contains(chatRowid), false)
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

    private mutating func shapeExactMessages(rows: [SQLiteReader.Row], schema: ExactReadSchema) throws -> [ExactMessage] {
        let ids = rows.compactMap { $0.int("rowid") }
        let attachments = try strictAttachmentsByMessage(ids: ids)
        var out: [ExactMessage] = []
        for row in rows {
            let rowid = try requiredInt(row, "rowid")
            let selectedChat = try requiredInt(row, "selected_chat_rowid")
            let joined = attachments[rowid] ?? []
            let bodyInfo = exactBody(row, attachments: joined)
            let nativePartsInfo = exactNativeParts(row)
            let threadOriginator = exactThreadOriginator(row, schema: schema)
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
                native_parts: nativePartsInfo.parts,
                thread_originator: threadOriginator
            ))
        }
        return out
    }

    private func exactThreadOriginator(_ row: SQLiteReader.Row, schema: ExactReadSchema) -> ExactThreadOriginator {
        guard schema.threadOriginatorColumnsAvailable else {
            return ExactThreadOriginator(available: false, reason: "missing-schema",
                                         message_guid: nil, raw_part: nil, native_part: nil)
        }
        let guid = originatorText(row.values["thread_originator_guid"])
        let part = originatorText(row.values["thread_originator_part"])
        let hasGUID = guid.text?.isEmpty == false
        let hasPart = part.text?.isEmpty == false
        if guid.wrongType || part.wrongType {
            return ExactThreadOriginator(available: false, reason: "malformed",
                                         message_guid: hasGUID ? guid.text : nil,
                                         raw_part: hasPart ? part.text : nil,
                                         native_part: nil)
        }
        guard hasGUID || hasPart else {
            return ExactThreadOriginator(available: true, reason: "no-linkage",
                                         message_guid: nil, raw_part: nil, native_part: nil)
        }
        guard let guidText = guid.text, hasGUID, let rawPart = part.text, hasPart else {
            return ExactThreadOriginator(available: false, reason: "partial",
                                         message_guid: hasGUID ? guid.text : nil,
                                         raw_part: hasPart ? part.text : nil,
                                         native_part: nil)
        }
        let parsed = parseThreadOriginatorPart(rawPart)
        return ExactThreadOriginator(available: parsed.available, reason: parsed.reason,
                                     message_guid: guidText, raw_part: rawPart,
                                     native_part: parsed.nativePart)
    }

    private func originatorText(_ value: SQLiteReader.Row.Value?) -> (text: String?, wrongType: Bool) {
        switch value {
        case .text(let text)?: return (text, false)
        case .null?: return (nil, false)
        default: return (nil, true)
        }
    }

    private func parseThreadOriginatorPart(_ raw: String) -> (available: Bool, reason: String, nativePart: Int?) {
        let prefix = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard !prefix.isEmpty else { return (false, "malformed", nil) }
        let bytes = prefix.utf8
        guard bytes.allSatisfy({ (48...57).contains($0) }) else {
            return (false, "malformed", nil)
        }
        guard prefix == "0" || !prefix.hasPrefix("0") else {
            return (false, "malformed", nil)
        }
        if prefix == String(UInt64.max) {
            return (false, "unsupported-part-marker", nil)
        }
        var value = 0
        for byte in bytes {
            let digit = Int(byte - 48)
            guard value <= (Int.max - digit) / 10 else {
                return (false, "malformed", nil)
            }
            value = value * 10 + digit
        }
        return (true, "available", value)
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

    private func requireExactReadSchema() throws -> ExactReadSchema {
        let messageColumns = try requiredColumns("message", [
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
        return ExactReadSchema(
            threadOriginatorColumnsAvailable: messageColumns.isSuperset(of: [
                "thread_originator_guid", "thread_originator_part",
            ])
        )
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
