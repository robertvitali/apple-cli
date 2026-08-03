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
    /// What subset of the matching rows to return, and in what order.
    ///
    /// These are ONE parameter on purpose. The first cut exposed `order:` and `limit:` separately,
    /// which left `limit: 200, order: .unordered` — precisely the shipped bug — still compiling
    /// silently. Bounding and ordering are not independent choices: the moment a caller keeps only
    /// some of the rows it is choosing WHICH rows, so an unordered bound is an arbitrary sample
    /// dressed as a selection. Folding them into one enum makes that combination unrepresentable
    /// rather than merely discouraged. (Review-caught; a defaulted parameter had already produced
    /// one real defect in this repo, so "discouraged" is not good enough here.)
    public enum RowSlice {
        /// Every matching row, in whatever order the query plan yields — in practice ROWID
        /// (insertion) order. Correct for callers that only COUNT rows (`stats`, `top-senders`);
        /// forcing a sort across a six-figure store would cost a sort for nothing.
        case all
        /// Newest first by effective send date, unbounded. For callers that must see every row in
        /// order because their own bound is applied AFTER filtering — `awaiting-reply` keeps the
        /// newest N messages still awaiting a reply, which is not the same as the newest N sent.
        case newestFirst
        /// The newest N by effective send date. The only way to bound the result.
        case newest(Int)
    }

    /// Whether this store exposes indexed body previews: a `summaries` table AND the `messages.summary`
    /// foreign key into it.
    ///
    /// Probed rather than assumed. The Envelope Index schema is Apple's private format and varies by
    /// Mail version (this is `V10`); a hard-coded join would turn every analytics query into an error
    /// on a store that lacks it, which is a far worse failure than the degraded question-detection it
    /// is there to improve. Computed once — `analyticsRows` is called per command, but the schema
    /// cannot change under a snapshot.
    private lazy var summariesAvailable: Bool = {
        let hasTable = (try? reader.query(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='summaries' LIMIT 1"))?.isEmpty == false
        guard hasTable else { return false }
        let cols = (try? reader.query("PRAGMA table_info(messages)")) ?? []
        return cols.contains { ($0["name"] ?? nil) == "summary" }
    }()

    /// All non-deleted messages matching the account/mailbox selector, decoded for the analytics
    /// commands.
    ///
    /// - Parameter slice: see `RowSlice`. `needs-response` previously took `.prefix(200)` of an
    ///   unordered scan, so it kept an arbitrary 200 rather than the newest 200 the oracle reads.
    ///   Measured on the populated `Sent Messages` (populated): unordered-first-200 spans
    ///   a much wider window, the correct newest-200 is far narrower.
    public func analyticsRows(accountUUID: String?, mailboxName: String, sinceUnix: Int?,
                              slice: RowSlice = .all) throws -> [[String: String?]] {
        let resolved = resolveMailboxes(accountUUID: accountUUID, mailboxName: mailboxName)
        var where_ = ["m.deleted = 0", EnvelopeIndex.mailboxPredicate(direct: resolved.direct, label: resolved.label)]
        var binds: [String] = []
        if let since = sinceUnix { where_.append("m.date_received >= ?"); binds.append(String(since)) }
        // Oracle B decides "contains a question" from the subject OR the first 500 characters of
        // the message CONTENT (smart_inbox.py: `text 1 thru 500 of msgContent`). `summaries` is the
        // only body text the Envelope Index holds, so it is what stands in for that scan; without
        // this join `Row.snippet` was nil for every row and the body half of the test was dead.
        // SUBSTR bounds what is read to the same 500 characters the oracle looks at.
        let snippetSelect = summariesAvailable ? ", SUBSTR(sm.summary, 1, 500) AS snippet" : ""
        let snippetJoin = summariesAvailable ? "\n        LEFT JOIN summaries sm ON sm.ROWID = m.summary" : ""
        let sql = """
        SELECT m.ROWID AS rowid, sa.address AS sender_address, sa.comment AS sender_name,
               COALESCE(m.subject_prefix,'') || COALESCE(s.subject,'') AS subject,
               m.date_received AS date_received, m.date_sent AS date_sent, m.read AS read, m.flagged AS flagged,
               m.mailbox AS mailbox_rowid,
               (SELECT COUNT(*) FROM attachments at WHERE at.message = m.ROWID) AS attachment_count\(snippetSelect)
        FROM messages m
        LEFT JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN addresses sa ON sa.ROWID = m.sender\(snippetJoin)
        WHERE \(where_.joined(separator: " AND "))
        """
        var tail = ""
        if case .newestFirst = slice {
            tail += " ORDER BY COALESCE(NULLIF(m.date_sent, 0), m.date_received) DESC, m.ROWID DESC"
        }
        if case .newest(let raw) = slice {
            // Clamp rather than fall through. An earlier shape used `if let limit, limit > 0`, so
            // `limit: 0` silently meant UNLIMITED — the exact opposite of what a caller passing 0
            // asks for, and the more dangerous direction to be wrong in.
            let n = max(0, raw)
            // Sent messages are the motivating case and their `date_received` can be 0 or the time
            // the copy landed, so prefer `date_sent` when it is populated. ROWID breaks ties
            // deterministically — without it, equal timestamps make the bound non-deterministic
            // across runs, which would produce a flaky suppression set.
            //
            // NOTE, latent today: `sinceUnix` filters on `date_received` while this orders on the
            // COALESCEd date. Every current `.newest` caller passes `sinceUnix: nil`, so the two
            // never disagree — but a future caller combining a window with a bound would filter on
            // one clock and rank on another. Window on the same expression if that day comes.
            //
            // Mail's own `every message of mailbox` enumeration order is not a documented
            // guarantee. It is measured newest-first here (checked at both ends), and the ORACLE ITSELF depends on that — `if messageDate < cutoffDate
            // then exit repeat` is only correct on a newest-first walk. So mirroring it mirrors the
            // oracle's own assumption rather than inventing one.
            tail += " ORDER BY COALESCE(NULLIF(m.date_sent, 0), m.date_received) DESC, m.ROWID DESC"
            // Interpolated from an Int, never from user text: `String(Int)` can only emit
            // `-?[0-9]+`, so no quote, semicolon or comment can appear here.
            tail += " LIMIT \(n)"
        }
        return try reader.query(sql + tail, binds)
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
