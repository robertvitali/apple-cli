import Foundation
import AppleKit

/// Fast read/search/analytics engine over Apple Mail's `Envelope Index` SQLite store
/// (`~/Library/Mail/V<N>/MailData/Envelope Index`). Opened read-only via `SQLiteReader`
/// with `copyToTemp` (WAL-aware snapshot) so we never touch the live DB. This is the P1/P3
/// hot path — no Mail.app scripting required for reads.
///
/// PERF NOTE: `copyToTemp` snapshots the whole Envelope Index (+ `-wal`/`-shm`) once PER
/// `MailContext`/command (not per query — all queries reuse this one reader). On a large
/// store the copy dominates a single read's latency; a future optimization is a
/// `?immutable=1` read-only open (no copy) accepting a slightly-relaxed consistency view.
/// The copy is the correctness-first choice (a consistent snapshot while Mail writes live).
public final class EnvelopeIndex {

    public struct MailboxRef: Sendable {
        public let rowid: Int
        public let url: MailboxURL
        public let total: Int
        public let unread: Int
        public let deleted: Int
        public let isLabel: Bool     // Gmail label: membership via `labels`, not `m.mailbox`
    }

    private let reader: SQLiteReader
    public let dbPath: String
    public private(set) var mailboxes: [MailboxRef] = []
    private var mailboxByRowid: [Int: MailboxRef] = [:]

    /// Locate the newest `V<N>` Mail data dir and open its Envelope Index.
    public init(explicitPath: String? = nil) throws {
        let path = explicitPath ?? EnvelopeIndex.locateDB()
        guard let path else {
            throw AppleError.upstream("Envelope Index not found under ~/Library/Mail/V*/MailData/ — is Mail configured?")
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw AppleError.permissionDenied(
                "cannot read the Mail Envelope Index — grant Full Disk Access to your terminal "
                + "in System Settings › Privacy & Security › Full Disk Access.")
        }
        self.dbPath = path
        do {
            self.reader = try SQLiteReader(path: path, copyToTemp: true)
        } catch {
            throw AppleError.upstream("failed to open Envelope Index: \(error)")
        }
        try loadMailboxes()
    }

    /// Newest `~/Library/Mail/V<N>/MailData/Envelope Index` (highest N).
    public static func locateDB() -> String? {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return nil }
        let candidates = entries
            .filter { $0.hasPrefix("V") && Int($0.dropFirst()) != nil }
            .sorted { (Int($0.dropFirst()) ?? 0) > (Int($1.dropFirst()) ?? 0) }
        for v in candidates {
            let p = base.appendingPathComponent("\(v)/MailData/Envelope Index").path
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    // MARK: Mailbox directory

    private func loadMailboxes() throws {
        let rows = try reader.query(
            "SELECT ROWID, url, total_count, unread_count, deleted_count, source FROM mailboxes")
        var refs: [MailboxRef] = []
        for row in rows {
            guard let rowid = intVal(row["ROWID"]), let rawURL = strVal(row["url"]),
                  let parsed = MailboxURL(rawURL) else { continue }
            let ref = MailboxRef(
                rowid: rowid, url: parsed,
                total: intVal(row["total_count"]) ?? 0,
                unread: intVal(row["unread_count"]) ?? 0,
                deleted: intVal(row["deleted_count"]) ?? 0,
                isLabel: (strVal(row["source"]) != nil))
            refs.append(ref)
        }
        mailboxes = refs
        mailboxByRowid = Dictionary(uniqueKeysWithValues: refs.map { ($0.rowid, $0) })
    }

    public func mailbox(forRowid rowid: Int) -> MailboxRef? { mailboxByRowid[rowid] }

    /// All distinct account UUIDs present in the mailbox table.
    public func accountUUIDs() -> [String] {
        var seen = Set<String>(); var order: [String] = []
        for m in mailboxes where !seen.contains(m.url.accountID) {
            seen.insert(m.url.accountID); order.append(m.url.accountID)
        }
        return order
    }

    // MARK: Mailbox resolution → message predicate

    /// The ONE spelling of the "every mailbox" wildcard. `resolveMailboxes` is the authority on
    /// what "All" selects, and the two disclosure fields that describe that selection
    /// (`search`'s `system_folders_excluded`, bulk's `scope_note`) are only trustworthy while
    /// they agree with it — so all three ask this function rather than re-testing the string.
    /// A second accepted spelling added here can no longer desync them.
    public static func isAllWildcard(_ mailboxName: String) -> Bool {
        mailboxName.caseInsensitiveCompare("All") == .orderedSame
    }

    /// Resolve an (account, mailbox-name) selector into direct + label ROWID sets.
    /// `mailboxName == "All"` (case-insensitive) → every real (source-NULL) mailbox of the
    /// account(s), so each message is counted exactly once. A specific name matches on the
    /// full path or the leaf (case-insensitive), across all accounts when `accountUUID` nil.
    /// `includeSystemFolders` applies ONLY to the "All" wildcard: MCP B excludes its
    /// `SKIP_FOLDERS` (Trash/Junk/Sent*/Drafts/Spam/Deleted*) from broad scans, so an "All"
    /// search that swept them returned hits the oracle never would. Naming a system mailbox
    /// EXPLICITLY (`--mailbox Trash`) is unaffected — the exclusion is about what "everything"
    /// means, not about making those mailboxes unsearchable.
    public func resolveMailboxes(accountUUID: String?, mailboxName: String,
                                 includeSystemFolders: Bool = true) -> (direct: [Int], label: [Int]) {
        let wantAll = EnvelopeIndex.isAllWildcard(mailboxName)
        var direct: [Int] = [], label: [Int] = []
        for m in mailboxes {
            if let uuid = accountUUID, m.url.accountID != uuid { continue }
            if wantAll {
                if !includeSystemFolders && Analytics.isSkippedSystemFolder(m.url.path) { continue }
                if !m.isLabel { direct.append(m.rowid) }   // real stores only → no dup
            } else {
                let matches = m.url.path.caseInsensitiveCompare(mailboxName) == .orderedSame
                    || m.url.leaf.caseInsensitiveCompare(mailboxName) == .orderedSame
                if matches {
                    if m.isLabel { label.append(m.rowid) } else { direct.append(m.rowid) }
                }
            }
        }
        // Wildcard "All" across ALL accounts when no account is specified.
        if wantAll && accountUUID == nil { /* already collected all real mailboxes */ }
        return (direct, label)
    }

    /// SQL predicate (no user text — ROWIDs are internal validated ints) for a resolved set.
    /// Empty resolution → `0` (matches nothing) so an unknown mailbox yields an empty result.
    public static func mailboxPredicate(direct: [Int], label: [Int]) -> String {
        var parts: [String] = []
        if !direct.isEmpty { parts.append("m.mailbox IN (\(direct.map(String.init).joined(separator: ",")))") }
        if !label.isEmpty {
            parts.append("m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id IN (\(label.map(String.init).joined(separator: ","))))")
        }
        return parts.isEmpty ? "0" : "(" + parts.joined(separator: " OR ") + ")"
    }

    // MARK: Message query

    public struct MessageFilters {
        public var accountUUID: String?
        public var mailboxName: String = "INBOX"
        /// Applies only when `mailboxName == "All"`. Default true preserves every caller that
        /// does not opt in; the search/thread commands set it from `--include-system-folders`.
        public var includeSystemFolders: Bool = true
        public var subjectContains: String?
        public var subjectContainsAny: [String] = []   // OR-match list (MCP B subject_keywords); ANY matches
        public var senderContains: String?
        public var bodyContains: String?     // matches the Envelope Index summary/preview
        public var conversationID: Int?      // Apple thread id (for `thread <id>`)
        public var dateFromUnix: Int?
        public var dateToUnix: Int?
        public var readStatus: Bool?          // nil = any
        public var flagged: Bool?             // nil = any
        public var hasAttachment: Bool?       // nil = any
        public var includeDeleted: Bool = false
        public var sortAscending: Bool = false
        public var limit: Int = 50
        public var offset: Int = 0
        public init() {}
    }

    /// Build the shared WHERE clause + ordered binds for both `queryMessages` and
    /// `countMessages`. User text is parameter-bound; ROWIDs/booleans are inlined from
    /// validated non-user values only.
    private func buildFilter(_ f: MessageFilters) -> (where: String, binds: [String]) {
        var where_: [String] = []
        var binds: [String] = []
        if !f.includeDeleted { where_.append("m.deleted = 0") }
        let resolved = resolveMailboxes(accountUUID: f.accountUUID, mailboxName: f.mailboxName,
                                        includeSystemFolders: f.includeSystemFolders)
        where_.append(EnvelopeIndex.mailboxPredicate(direct: resolved.direct, label: resolved.label))
        // subject_keywords OR-match (MCP B): match ANY of the keywords. Non-empty list takes
        // precedence over the single `subjectContains`; each keyword is a parameter-bound LIKE.
        let subjKeywords = f.subjectContainsAny.filter { !$0.isEmpty }
        if !subjKeywords.isEmpty {
            let ors = subjKeywords.map { _ in "(COALESCE(m.subject_prefix,'') || COALESCE(s.subject,'')) LIKE ? ESCAPE '\\'" }
            where_.append("(" + ors.joined(separator: " OR ") + ")")
            for kw in subjKeywords { binds.append("%\(likeEscape(kw))%") }
        } else if let s = f.subjectContains, !s.isEmpty {
            where_.append("(COALESCE(m.subject_prefix,'') || COALESCE(s.subject,'')) LIKE ? ESCAPE '\\'")
            binds.append("%\(likeEscape(s))%")
        }
        if let s = f.senderContains, !s.isEmpty {
            where_.append("(sa.address LIKE ? ESCAPE '\\' OR sa.comment LIKE ? ESCAPE '\\')")
            binds.append("%\(likeEscape(s))%"); binds.append("%\(likeEscape(s))%")
        }
        if let b = f.bodyContains, !b.isEmpty {
            where_.append("su.summary LIKE ? ESCAPE '\\'")
            binds.append("%\(likeEscape(b))%")
        }
        if let cid = f.conversationID { where_.append("m.conversation_id = \(cid)") } // validated Int, not user text
        if let from = f.dateFromUnix { where_.append("m.date_received >= ?"); binds.append(String(from)) }
        if let to = f.dateToUnix { where_.append("m.date_received <= ?"); binds.append(String(to)) }
        if let r = f.readStatus { where_.append("m.read = \(r ? 1 : 0)") }
        if let fl = f.flagged { where_.append("m.flagged = \(fl ? 1 : 0)") }
        if let att = f.hasAttachment {
            where_.append(att ? "EXISTS (SELECT 1 FROM attachments at WHERE at.message = m.ROWID)"
                              : "NOT EXISTS (SELECT 1 FROM attachments at WHERE at.message = m.ROWID)")
        }
        return (where_.joined(separator: " AND "), binds)
    }

    private static let baseSelect = """
    SELECT
      m.ROWID AS rowid,
      m.message_id AS mail_message_id,
      COALESCE(m.subject_prefix,'') || COALESCE(s.subject,'') AS subject,
      sa.address AS sender_address,
      sa.comment AS sender_name,
      m.date_received AS date_received,
      m.date_sent AS date_sent,
      m.read AS read,
      m.flagged AS flagged,
      m.flag_color AS flag_color,
      m.size AS size,
      m.conversation_id AS conversation_id,
      mgd.message_id_header AS message_id_header,
      m.mailbox AS mailbox_rowid,
      (SELECT COUNT(*) FROM attachments at WHERE at.message = m.ROWID) AS attachment_count,
      su.summary AS snippet
    FROM messages m
    LEFT JOIN subjects s ON s.ROWID = m.subject
    LEFT JOIN addresses sa ON sa.ROWID = m.sender
    LEFT JOIN message_global_data mgd ON mgd.ROWID = m.global_message_id
    LEFT JOIN summaries su ON su.ROWID = m.summary
    """

    /// Run the filtered message query. User text is parameter-bound; structural ints
    /// (ROWIDs, limit/offset) are inlined from validated integers only.
    public func queryMessages(_ f: MessageFilters) throws -> [[String: String?]] {
        let filter = buildFilter(f)
        let order = f.sortAscending ? "ASC" : "DESC"
        let limit = max(0, f.limit), offset = max(0, f.offset)
        let sql = """
        \(EnvelopeIndex.baseSelect)
        WHERE \(filter.where)
        ORDER BY m.date_received \(order), m.ROWID \(order)
        LIMIT \(limit) OFFSET \(offset)
        """
        return try reader.query(sql, filter.binds)
    }

    /// Messages sharing a References/In-Reply-To chain with `rowid` (MCP A get_thread's
    /// header-threading), via the Envelope Index `message_references` table: gather the message's
    /// own reference set (its originator global-id + referenced ancestors), then every message whose
    /// reference set intersects it. Chronological. This differs from `conversationID` grouping (Apple
    /// also folds in subject/participants) — it is the RFC References-chain membership MCP A returns.
    /// Empty if the message has no `message_references` rows (caller falls back to the singleton).
    /// `rowid`/`limit` are validated Ints, inlined — no user text reaches the SQL.
    public func referencesThread(rowid: Int, limit: Int) throws -> [[String: String?]] {
        let lim = max(1, limit)
        let sql = """
        \(EnvelopeIndex.baseSelect)
        WHERE m.deleted = 0 AND m.ROWID IN (
            SELECT DISTINCT mr2.message FROM message_references mr2
            WHERE mr2.reference IN (
                SELECT mr1.reference FROM message_references mr1 WHERE mr1.message = \(rowid)
            )
        )
        ORDER BY m.date_received ASC, m.ROWID ASC
        LIMIT \(lim)
        """
        return try reader.query(sql, [])
    }

    /// Total count matching the same filters (for pagination `has_more`) — cheap COUNT(*).
    public func countMessages(_ f: EnvelopeIndex.MessageFilters) throws -> Int {
        let filter = buildFilter(f)
        // Include the same joins the filter may reference (sender, summary for body search).
        let sql = """
        SELECT COUNT(*) AS n
        FROM messages m
        LEFT JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN addresses sa ON sa.ROWID = m.sender
        LEFT JOIN summaries su ON su.ROWID = m.summary
        WHERE \(filter.where)
        """
        let rows = try reader.query(sql, filter.binds)
        guard let first = rows.first, let cell = first["n"], let text = cell, let n = Int(text) else { return 0 }
        return n
    }

    /// Fetch one message by Envelope Index ROWID (used by `get`, `thread`, `attachments`).
    public func message(rowid: Int) throws -> [String: String?]? {
        let sql = """
        \(EnvelopeIndex.baseSelect)
        WHERE m.ROWID = \(rowid)
        LIMIT 1
        """
        return try reader.query(sql).first
    }

    /// Fetch one message by RFC-5322 Internet Message-ID (bracket-stripped or not).
    public func message(internetMessageID id: String) throws -> [String: String?]? {
        let bare = MailFormat.stripAngleBrackets(id) ?? id
        let sql = """
        \(EnvelopeIndex.baseSelect)
        WHERE mgd.message_id_header = ? OR mgd.message_id_header = ?
        ORDER BY m.date_received DESC LIMIT 1
        """
        return try reader.query(sql, ["<\(bare)>", bare]).first
    }

    // MARK: Recipients / attachments

    public func recipients(messageRowid: Int) throws -> (to: [String], cc: [String], bcc: [String]) {
        let rows = try reader.query("""
        SELECT r.type AS type, a.address AS address, a.comment AS comment
        FROM recipients r JOIN addresses a ON a.ROWID = r.address
        WHERE r.message = \(messageRowid)
        ORDER BY r.type, r.position
        """)
        var to: [String] = [], cc: [String] = [], bcc: [String] = []
        for row in rows {
            let person = MailFormat.person(name: strVal(row["comment"]), address: strVal(row["address"]))
            switch intVal(row["type"]) {
            case 0: to.append(person)
            case 1: cc.append(person)
            case 2: bcc.append(person)
            default: to.append(person)
            }
        }
        return (to, cc, bcc)
    }

    public func attachments(messageRowid: Int) throws -> [(name: String, attachmentID: String?)] {
        let rows = try reader.query("""
        SELECT attachment_id, name FROM attachments WHERE message = \(messageRowid) ORDER BY name
        """)
        return rows.compactMap { row in
            guard let name = strVal(row["name"]) else { return nil }
            return (name, strVal(row["attachment_id"]))
        }
    }

    /// All non-deleted messages for cross-referencing analytics (sender/subject/date only,
    /// cheap columns) within a mailbox selector and time window.
    public func analyticsRows(accountUUID: String?, mailboxName: String, sinceUnix: Int?) throws -> [[String: String?]] {
        let resolved = resolveMailboxes(accountUUID: accountUUID, mailboxName: mailboxName)
        var where_ = ["m.deleted = 0", EnvelopeIndex.mailboxPredicate(direct: resolved.direct, label: resolved.label)]
        var binds: [String] = []
        if let since = sinceUnix { where_.append("m.date_received >= ?"); binds.append(String(since)) }
        let sql = """
        SELECT m.ROWID AS rowid, sa.address AS sender_address, sa.comment AS sender_name,
               COALESCE(m.subject_prefix,'') || COALESCE(s.subject,'') AS subject,
               m.date_received AS date_received, m.date_sent AS date_sent, m.read AS read, m.flagged AS flagged,
               m.mailbox AS mailbox_rowid,
               (SELECT COUNT(*) FROM attachments at WHERE at.message = m.ROWID) AS attachment_count
        FROM messages m
        LEFT JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN addresses sa ON sa.ROWID = m.sender
        WHERE \(where_.joined(separator: " AND "))
        """
        return try reader.query(sql, binds)
    }
}

// MARK: - Row helpers (module-internal, pure)

func intVal(_ v: String??) -> Int? {
    guard let inner = v, let s = inner else { return nil }
    return Int(s)
}
func strVal(_ v: String??) -> String? {
    guard let inner = v, let s = inner, !s.isEmpty else { return nil }
    return s
}
/// Escape LIKE metacharacters in user input so a search term with `%`/`_` is literal.
func likeEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "%", with: "\\%")
     .replacingOccurrences(of: "_", with: "\\_")
}
