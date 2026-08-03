import Foundation
import AppleKit

/// Reads the macOS AddressBook `*.abcddb` SQLite stores directly (Full Disk Access,
/// no Contacts TCC prompt) — the SAME mechanism as `mac_messages_mcp`. Builds the
/// normalized `handle → name` map and the fuzzy contact index. Ports
/// `get_addressbook_contacts` / `process_contacts` / `find_contact_by_name` /
/// `get_contact_name` (AddressBook half) / `check_addressbook_access`.
public struct AddressBook {

    public struct Details {
        public let firstName: String
        public let lastName: String
        public let nickname: String
        public let fullName: String
        public init(firstName: String, lastName: String, nickname: String, fullName: String) {
            self.firstName = firstName; self.lastName = lastName
            self.nickname = nickname; self.fullName = fullName
        }
    }

    /// normalized-phone / lowercased-email  →  full name
    public private(set) var contacts: [String: String] = [:]
    /// normalized-phone / lowercased-email  →  name details (for nickname search)
    public private(set) var details: [String: Details] = [:]

    /// Empty book (used by `load()` and by tests that need a book without I/O).
    public init() {}

    /// Seed a book directly (test/reuse helper) — bypasses AddressBook I/O.
    public init(contacts: [String: String], details: [String: Details] = [:]) {
        self.contacts = contacts
        self.details = details
    }

    // MARK: Paths

    public static func databasePaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sourcesDir = home + "/Library/Application Support/AddressBook/Sources"
        var paths: [String] = []
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: sourcesDir) {
            for entry in entries.sorted() {
                let candidate = sourcesDir + "/" + entry + "/AddressBook-v22.abcddb"
                if FileManager.default.fileExists(atPath: candidate) { paths.append(candidate) }
            }
        }
        let toplevel = home + "/Library/Application Support/AddressBook/AddressBook-v22.abcddb"
        if FileManager.default.fileExists(atPath: toplevel) { paths.append(toplevel) }
        return paths
    }

    // MARK: Load

    private static let phoneQuery = """
        SELECT r.ZFIRSTNAME AS first_name, r.ZLASTNAME AS last_name,
               r.ZNICKNAME AS nickname, p.ZFULLNUMBER AS phone
        FROM ZABCDRECORD r
        LEFT JOIN ZABCDPHONENUMBER p ON r.Z_PK = p.ZOWNER
        WHERE p.ZFULLNUMBER IS NOT NULL
        ORDER BY r.ZLASTNAME, r.ZFIRSTNAME, p.ZORDERINGINDEX ASC
        """

    private static let emailQuery = """
        SELECT r.ZFIRSTNAME AS first_name, r.ZLASTNAME AS last_name,
               r.ZNICKNAME AS nickname, e.ZADDRESS AS email
        FROM ZABCDRECORD r
        LEFT JOIN ZABCDEMAILADDRESS e ON r.Z_PK = e.ZOWNER
        WHERE e.ZADDRESS IS NOT NULL
        ORDER BY r.ZLASTNAME, r.ZFIRSTNAME
        """

    /// Load + merge every accessible AddressBook source. Inaccessible sources are
    /// skipped (mirrors the MCP's per-source try/except), never fatal.
    public static func load() -> AddressBook {
        var book = AddressBook()
        for path in databasePaths() {
            // FALL BACK, never drop. `.walAware` (mode=ro) is the accurate read — it applies the
            // -wal, which `immutable=1` skips — but it must write the -shm wal-index, so it FAILS
            // where an immutable open succeeded (missing -shm on a non-writable dir, lock
            // contention). That is the very failure `3316a92` adopted `immutable=1` to avoid.
            //
            // `load()` is the HOT path — seven command paths call it — and its reads are `try?`,
            // so skipping a source silently deletes every contact in it and degrades every sender
            // to a raw phone number. On this machine one source holds the majority of contacts:
            // dropping it to gain the +30 the WAL adds would be a catastrophic trade. So prefer
            // accuracy, but degrade to the stale-but-present read rather than to nothing, and say
            // so on stderr (stdout is the JSON contract). Only a failure of BOTH modes skips —
            // which is where the oracle also gives up ("Warning: Cannot access …", messages.py:319).
            let db: SQLiteReader
            do {
                db = try SQLiteReader(path: path, copyToTemp: false, directOpen: .walAware)
            } catch {
                do {
                    db = try SQLiteReader(path: path, copyToTemp: false, directOpen: .immutable)
                    FileHandle.standardError.write(Data(
                        "Warning: \(path) not readable WAL-aware (\(error)); fell back to immutable=1 — counts may be stale\n".utf8))
                } catch {
                    FileHandle.standardError.write(
                        Data("Warning: Cannot access \(path): \(error)\n".utf8))
                    continue
                }
            }
            let phones = (try? db.rows(phoneQuery)) ?? []
            let emails = (try? db.rows(emailQuery)) ?? []
            book.ingest(phones)
            book.ingest(emails)
        }
        return book
    }

    private mutating func ingest(_ rows: [SQLiteReader.Row]) {
        for row in rows {
            let first = row.text("first_name") ?? ""
            let last = row.text("last_name") ?? ""
            let nickname = row.text("nickname") ?? ""
            var phone = row.text("phone") ?? ""
            let email = row.text("email") ?? ""

            let fullName = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
            if fullName.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            // Email-based contact (iMessage handles can be emails) — only when no phone.
            if !email.isEmpty && phone.isEmpty {
                let key = email.trimmingCharacters(in: .whitespaces).lowercased()
                contacts[key] = fullName
                details[key] = Details(firstName: first.trimmingCharacters(in: .whitespaces),
                                       lastName: last.trimmingCharacters(in: .whitespaces),
                                       nickname: nickname.trimmingCharacters(in: .whitespaces),
                                       fullName: fullName)
                continue
            }
            if phone.isEmpty { continue }
            if let range = phone.range(of: "X-IMAGETYPE") { phone = String(phone[..<range.lowerBound]) }
            let normalized = Fuzzy.normalizePhone(phone)
            if normalized.isEmpty { continue }
            contacts[normalized] = fullName
            details[normalized] = Details(firstName: first.trimmingCharacters(in: .whitespaces),
                                          lastName: last.trimmingCharacters(in: .whitespaces),
                                          nickname: nickname.trimmingCharacters(in: .whitespaces),
                                          fullName: fullName)
        }
    }

    // MARK: Fuzzy find (MCP `find_contact_by_name`)

    public struct Match { public let name: String; public let phone: String; public let score: Double; public let matchedOn: String }

    /// Fuzzy-match a name/nickname to contacts, dedup by phone (highest score),
    /// sorted desc. Exact port of `find_contact_by_name`.
    public func findByName(_ name: String) -> [Match] {
        var candidates: [Fuzzy.ContactCandidate] = []
        for (phone, contactName) in contacts {
            candidates.append(.init(name: contactName, value: phone))
            if let nick = details[phone]?.nickname, !nick.isEmpty {
                candidates.append(.init(name: nick, value: phone))
            }
        }
        let matches = Fuzzy.matchContacts(query: name, candidates: candidates)

        // Dedup by phone, keeping the highest score.
        struct Best { var name: String; var phone: String; var score: Double; var matchedOn: String }
        var seen: [String: Best] = [:]
        for m in matches {
            let phone = m.value
            if let existing = seen[phone], existing.score >= m.score { continue }
            let display = contacts[phone] ?? m.name
            seen[phone] = Best(name: display, phone: phone, score: m.score, matchedOn: m.name)
        }
        return seen.values
            // Score desc; deterministic tiebreak by phone so equal-score results
            // (e.g. many exact-token matches all at 0.95) are stable across runs.
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.phone < $1.phone }
            .map { Match(name: $0.name, phone: $0.phone, score: $0.score, matchedOn: $0.matchedOn) }
    }

    // MARK: Handle → name (MCP `get_contact_name`, AddressBook portion)

    /// Resolve a handle id (phone or email) to a contact name via AddressBook only,
    /// trying US country-code variants. Returns nil if not found (caller falls back
    /// to chat display name, then the raw handle).
    public func nameForHandle(_ handleId: String) -> String? {
        if handleId.contains("@") {
            let key = handleId.trimmingCharacters(in: .whitespaces).lowercased()
            return contacts[key]
        }
        let normalized = Fuzzy.normalizePhone(handleId)
        if let hit = contacts[normalized] { return hit }
        if normalized.hasPrefix("1") && normalized.count > 10 {
            let without = String(normalized.dropFirst())
            if let hit = contacts[without] { return hit }
        } else if normalized.count == 10 {
            if let hit = contacts["1" + normalized] { return hit }
        }
        return nil
    }

    // MARK: Diagnostics

    public struct SourceReport: Encodable {
        public let path: String
        public let readable: Bool
        public let connected: Bool
        public let table_count: Int?
        public let has_zabcdrecord: Bool
        public let has_zabcdphonenumber: Bool
        public let contact_count: Int?
    }

    public struct Diagnostic: Encodable {
        public let sources_dir: String
        public let sources_dir_exists: Bool
        public let database_count: Int
        public let databases: [SourceReport]
        public let contacts_with_handles: Int
    }

    /// Port of `check_addressbook_access` as structured data.
    public static func diagnose() -> Diagnostic {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sourcesDir = home + "/Library/Application Support/AddressBook/Sources"
        let dirExists = FileManager.default.fileExists(atPath: sourcesDir)
        var reports: [SourceReport] = []
        for path in databasePaths() {
            let readable = (try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)))
                .map { try? $0.close(); return true } ?? false
            var connected = false, tableCount: Int? = nil
            var hasRecord = false, hasPhone = false, contactCount: Int? = nil
            if let db = try? SQLiteReader(path: path, copyToTemp: false, directOpen: .walAware) {
                connected = true
                if let r = try? db.query("SELECT count(*) AS c FROM sqlite_master"), let c = r.first?["c"] ?? nil {
                    tableCount = Int(c)
                }
                if let t = try? db.query("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('ZABCDRECORD','ZABCDPHONENUMBER')") {
                    let names = Set(t.compactMap { $0["name"] ?? nil })
                    hasRecord = names.contains("ZABCDRECORD")
                    hasPhone = names.contains("ZABCDPHONENUMBER")
                }
                if let c = try? db.query("SELECT COUNT(*) AS c FROM ZABCDRECORD"), let v = c.first?["c"] ?? nil {
                    contactCount = Int(v)
                }
            }
            reports.append(SourceReport(path: path, readable: readable, connected: connected,
                                        table_count: tableCount, has_zabcdrecord: hasRecord,
                                        has_zabcdphonenumber: hasPhone, contact_count: contactCount))
        }
        let book = load()
        return Diagnostic(sources_dir: sourcesDir, sources_dir_exists: dirExists,
                          database_count: reports.count, databases: reports,
                          contacts_with_handles: book.contacts.count)
    }
}
