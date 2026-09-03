import Foundation
import AppleKit

/// Direct read-only access to `NoteStore.sqlite` — the Full-Disk-Access bridge that backs
/// the four capabilities AppleScript cannot serve: `get-checklist` (gzip+protobuf done-state),
/// `get-metadata` (scalar columns AppleScript never exposes), `sync-status` (WAL + pending
/// count), and the checklist enrichment inside `get-markdown`. Ported from
/// `apple-notes-mcp@2.5.12` (`checklistParser.ts`, `noteMetadata.ts`, `syncDetection.ts`),
/// using AppleKit's `SQLiteReader` (read-only, WAL-aware, snapshot-to-temp) instead of the
/// reference's `sqlite3 -readonly` subprocess.
public enum NotesStore {

    /// `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite`.
    static var dbPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite").path
    }
    static var walPath: String { dbPath + "-wal" }

    static var dbExists: Bool { exists(at: dbPath) }

    /// The WAL sidecar SQLite maintains next to `path`. Same rule at any path, so the live
    /// `walPath` above and a fixture store both derive it the same way.
    static func walPath(for path: String) -> String { path + "-wal" }

    /// Whether a store file is present at `path`. Split out from `dbExists` so the
    /// path-parameterized read cores below can ask the question about the store they were
    /// handed rather than about the operator's live one.
    static func exists(at path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// Extract the Core Data primary key from a note id. Notes ids are
    /// `x-coredata://<store-uuid>/ICNote/p<PK>`; only the trailing `p<PK>` is load-bearing
    /// for a SQLite read (the store UUID is irrelevant here — `Z_PK` is the join key), which
    /// is why these reads resolve notes AppleScript's `note id` can't (e.g. trashed notes).
    static func primaryKey(from id: String) -> Int? {
        guard let range = id.range(of: #"/p(\d+)$"#, options: .regularExpression) else { return nil }
        let match = String(id[range]).dropFirst(2) // drop "/p"
        return Int(match)
    }

    // MARK: - Note deep link (get-note-link)

    /// Port of the oracle's `getNoteLinkFromDB`: `SELECT ZIDENTIFIER FROM ZICCLOUDSYNCINGOBJECT
    /// WHERE Z_PK = ?`, wrapped as `notes://showNote?identifier=<uuid>`.
    ///
    /// Returns nil — never throws — for every failure the oracle also swallows: an id with no
    /// trailing `/pNNN`, a missing database (no Full Disk Access), a row with no ZIDENTIFIER,
    /// or any SQLite error. The oracle logs and returns null there, and the caller falls back to
    /// AppleScript, so a throw here would turn a recoverable miss into a hard failure.
    public static func noteLink(noteId: String) -> String? {
        noteLink(noteId: noteId, dbPath: dbPath)
    }

    /// Path-parameterized core of `noteLink`. Production reads the live store through the
    /// wrapper above; the `dbPath` argument exists so the logic tier can drive this exact query
    /// against a synthetic fixture store instead of the operator's real Notes database.
    static func noteLink(noteId: String, dbPath: String) -> String? {
        guard let pk = primaryKey(from: noteId), exists(at: dbPath) else { return nil }
        do {
            let reader = try SQLiteReader(path: dbPath, copyToTemp: true)
            let rows = try reader.query(
                "SELECT ZIDENTIFIER AS z FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = ?1;", [String(pk)])
            guard let first = rows.first, let ident = first["z"] ?? nil, !ident.isEmpty else { return nil }
            return "notes://showNote?identifier=\(ident)"
        } catch {
            return nil
        }
    }

    // MARK: - Checklist state (gzip + protobuf)

    public struct ChecklistItem: Encodable, Equatable {
        public let text: String
        public let done: Bool
    }

    public enum ChecklistError: String {
        case invalidId = "invalid_id"
        case noFDA = "no_fda"
        case noChecklists = "no_checklists"
        case parseError = "parse_error"
    }

    public struct ChecklistOutcome {
        public let items: [ChecklistItem]?
        public let error: ChecklistError?
        public let message: String?
    }

    static let fdaGuideURL = "https://github.com/sweetrb/apple-notes-mcp/blob/main/docs/FULL-DISK-ACCESS.md"
    static var fdaChecklistMessage: String {
        "Full Disk Access is required to read checklist state. In System Settings > Privacy & "
            + "Security > Full Disk Access, grant access to your terminal, then fully quit and relaunch "
            + "it. Setup guide: \(fdaGuideURL) — run the doctor tool to verify."
    }
    static var fdaMetadataMessage: String {
        "Full Disk Access is required to read note metadata. In System Settings > Privacy & "
            + "Security > Full Disk Access, grant access to your terminal, then fully quit and relaunch "
            + "it. Setup guide: \(fdaGuideURL) — run the doctor tool to verify."
    }

    /// Read a note's checklist done-state from `ZICNOTEDATA.ZDATA` (gzipped protobuf).
    /// Mirrors the reference `getChecklistItems`: query → gunzip → protobuf-walk. Errors are
    /// returned (never thrown) so the command layer can map them to the right envelope.
    public static func checklistItems(noteId: String) -> ChecklistOutcome {
        checklistItems(noteId: noteId, dbPath: dbPath)
    }

    /// Path-parameterized core of `checklistItems` — see `noteLink(noteId:dbPath:)` for why the
    /// seam exists.
    static func checklistItems(noteId: String, dbPath: String) -> ChecklistOutcome {
        guard let pk = primaryKey(from: noteId) else {
            return ChecklistOutcome(items: nil, error: .invalidId,
                message: "Invalid note ID format: \"\(noteId)\". Expected format: x-coredata://UUID/ICNote/pNNN")
        }
        guard exists(at: dbPath) else {
            return ChecklistOutcome(items: nil, error: .noFDA, message: fdaChecklistMessage)
        }
        let hex: String
        do {
            let reader = try SQLiteReader(path: dbPath, copyToTemp: true)
            // pk is a validated Int (from the /pNNN regex), but bind it positionally per
            // SQLiteReader's param-bind contract rather than interpolate.
            let rows = try reader.query(
                "SELECT hex(nd.ZDATA) AS h FROM ZICNOTEDATA nd "
                + "JOIN ZICCLOUDSYNCINGOBJECT n ON nd.ZNOTE = n.Z_PK WHERE n.Z_PK = ?1;", [String(pk)])
            guard let first = rows.first, let value = first["h"] ?? nil, !value.isEmpty else {
                return ChecklistOutcome(items: nil, error: .noChecklists,
                    message: "No data found for this note in the database.")
            }
            hex = value
        } catch {
            let msg = String(describing: error).lowercased()
            if msg.contains("authorization denied") || msg.contains("unable to open") {
                return ChecklistOutcome(items: nil, error: .noFDA, message: fdaChecklistMessage)
            }
            return ChecklistOutcome(items: nil, error: .parseError, message: "Failed to query NoteStore database.")
        }

        let compressed = hexToBytes(hex)
        let decompressed: [UInt8]
        do {
            decompressed = try Gzip.inflate(compressed)
        } catch {
            return ChecklistOutcome(items: nil, error: .parseError, message: "Failed to decompress note data.")
        }
        guard let items = parseChecklist(decompressed), !items.isEmpty else {
            return ChecklistOutcome(items: nil, error: .noChecklists,
                message: "This note does not contain any checklist items.")
        }
        return ChecklistOutcome(items: items, error: nil, message: nil)
    }

    static let checklistStyleType: UInt64 = 103

    /// Walk the decoded Notes protobuf and pair each checklist attribute-run with its text
    /// line + done flag. Direct port of `parseChecklistFromProtobuf`: doc.field(2) → note
    /// wrapper, .field(3) → note body, body.field(2) → text, body.field(5, repeated) →
    /// attribute runs; a run whose paragraph_style.style_type == 103 is a checklist item and
    /// its checklist.done (field 2) is 0/1. `charPos` maps each run to a text line.
    static func parseChecklist(_ data: [UInt8]) -> [ChecklistItem]? {
        let docFields = Protobuf.decodeMessage(data)
        guard let noteWrapper = Protobuf.embeddedMessage(Protobuf.field(docFields, 2)),
              let noteBody = Protobuf.embeddedMessage(Protobuf.field(noteWrapper, 3)),
              let noteText = Protobuf.stringValue(Protobuf.field(noteBody, 2))
        else { return nil }
        let runs = Protobuf.fields(noteBody, 5)
        if runs.isEmpty { return nil }

        let lines = noteText.components(separatedBy: "\n")
        // Attribute-run lengths (and Apple's text storage) count UTF-16 code units, and the
        // reference compares against JS `String.length` (also UTF-16). Swift `.count` is grapheme
        // clusters, which diverges for emoji / non-BMP / combining marks and would misalign
        // charPos — so measure each line in UTF-16 units to keep the mapping exact.
        let lineLengths = lines.map { $0.utf16.count }
        var items: [ChecklistItem] = []
        var charPos = 0
        var seenLines = Set<Int>()

        for run in runs {
            guard let runFields = Protobuf.embeddedMessage(run) else { continue }
            let runLength = Int(Protobuf.varintValue(Protobuf.field(runFields, 1)) ?? 0)
            if let styleFields = Protobuf.embeddedMessage(Protobuf.field(runFields, 2)) {
                let styleType = Protobuf.varintValue(Protobuf.field(styleFields, 1))
                if styleType == checklistStyleType {
                    let checklistFields = Protobuf.embeddedMessage(Protobuf.field(styleFields, 5))
                    let done = checklistFields.flatMap { Protobuf.varintValue(Protobuf.field($0, 2)) } ?? 0
                    var lineStart = 0
                    for lineIdx in 0..<lines.count {
                        let lineEnd = lineStart + lineLengths[lineIdx]
                        if charPos >= lineStart && charPos < lineEnd + 1 && !seenLines.contains(lineIdx) {
                            seenLines.insert(lineIdx)
                            items.append(ChecklistItem(text: lines[lineIdx], done: done == 1))
                            break
                        }
                        lineStart = lineEnd + 1
                    }
                }
            }
            charPos += runLength
        }
        return items
    }

    static func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[idx..<next], radix: 16) { bytes.append(byte) }
            idx = next
        }
        return bytes
    }

    // MARK: - Note metadata (scalar columns; schema-guarded)

    /// (jsonKey, column, isBool) — the reference's COLUMN_MAP, ordered. `hasChecklist` etc.
    /// map to camelCase in the MCP; apple-cli emits snake_case per docs/DESIGN.md, so the
    /// keys here are the apple-cli wire keys (semantic 1:1 with the MCP fields).
    static let metadataColumns: [(key: String, column: String, isBool: Bool)] = [
        ("pinned", "ZISPINNED", true),
        ("has_checklist", "ZHASCHECKLIST", true),
        ("has_checklist_in_progress", "ZHASCHECKLISTINPROGRESS", true),
        ("recovering_from_trash", "ZISRECOVERINGFROMTRASH", true),
        ("password_protected", "ZISPASSWORDPROTECTED", true),
        ("password_hint", "ZPASSWORDHINT", false),
        ("snippet", "ZSNIPPET", false),
        ("widget_snippet", "ZWIDGETSNIPPET", false),
        ("smart_folder_query", "ZSMARTFOLDERQUERYJSON", false),
    ]

    public enum MetadataError: String { case invalidId = "invalid_id", noFDA = "no_fda", notFound = "not_found", queryError = "query_error" }

    public struct MetadataOutcome {
        public let metadata: NotesMetadata?
        public let error: MetadataError?
        public let message: String?
    }

    /// Read scalar metadata columns, guarding against schema drift (columns vary by macOS
    /// release) via `PRAGMA table_info`. Only present, non-null columns are returned — a
    /// missing column is silently skipped, matching the reference's BETA contract.
    public static func metadata(noteId: String) -> MetadataOutcome {
        metadata(noteId: noteId, dbPath: dbPath)
    }

    /// Path-parameterized core of `metadata` — see `noteLink(noteId:dbPath:)` for why the seam
    /// exists.
    static func metadata(noteId: String, dbPath: String) -> MetadataOutcome {
        guard let pk = primaryKey(from: noteId) else {
            return MetadataOutcome(metadata: nil, error: .invalidId,
                message: "Invalid note ID format: \"\(noteId)\". Expected format: x-coredata://UUID/ICNote/pNNN")
        }
        guard exists(at: dbPath) else {
            return MetadataOutcome(metadata: nil, error: .noFDA, message: fdaMetadataMessage)
        }
        do {
            let reader = try SQLiteReader(path: dbPath, copyToTemp: true)
            let present = try presentColumns(reader)
            let selected = metadataColumns.filter { present.contains($0.column) }
            if selected.isEmpty { return MetadataOutcome(metadata: NotesMetadata(), error: nil, message: nil) }
            // Column names come only from the hardcoded `metadataColumns` allowlist filtered
            // against live PRAGMA table_info — SQL identifiers can't be bound, so they are
            // interpolated (safe: no user string reaches them). The pk IS bound positionally.
            let colSQL = selected.map { $0.column }.joined(separator: ", ")
            let rows = try reader.query("SELECT \(colSQL) FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = ?1;", [String(pk)])
            guard let row = rows.first else {
                return MetadataOutcome(metadata: nil, error: .notFound,
                    message: "No note found in the database for ID \"\(noteId)\".")
            }
            var md = NotesMetadata()
            for col in selected {
                guard let raw = row[col.column] ?? nil else { continue } // null → skip
                if col.isBool {
                    md.set(col.key, bool: raw == "1")
                } else {
                    md.set(col.key, text: raw)
                }
            }
            return MetadataOutcome(metadata: md, error: nil, message: nil)
        } catch {
            let msg = String(describing: error).lowercased()
            if msg.contains("authorization denied") || msg.contains("unable to open") {
                return MetadataOutcome(metadata: nil, error: .noFDA, message: fdaMetadataMessage)
            }
            return MetadataOutcome(metadata: nil, error: .queryError, message: "Failed to read note metadata.")
        }
    }

    static func presentColumns(_ reader: SQLiteReader) throws -> Set<String> {
        let rows = try reader.query("PRAGMA table_info(ZICCLOUDSYNCINGOBJECT);")
        var cols = Set<String>()
        for row in rows { if let name = row["name"] ?? nil { cols.insert(name) } }
        return cols
    }

    // MARK: - Sync status (WAL mtime + pending count)

    static let recentActivityThresholdSeconds = 5.0

    /// Read-only sync snapshot: WAL-file mtime → seconds-since-change + recent-activity flag,
    /// and a `ZICCLOUDSTATE` pending-upload count. Port of `getSyncStatus`. Never throws; a
    /// query failure degrades to `pendingUpload = 0` while still reporting WAL activity.
    public static func syncStatus() -> NotesSyncStatus {
        syncStatus(dbPath: dbPath)
    }

    /// Path-parameterized core of `syncStatus` — see `noteLink(noteId:dbPath:)` for why the seam
    /// exists.
    static func syncStatus(dbPath: String) -> NotesSyncStatus {
        var status = NotesSyncStatus()
        guard exists(at: dbPath) else {
            status.error = "Notes database not found"
            return status
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: walPath(for: dbPath)),
           let mtime = attrs[.modificationDate] as? Date {
            let secondsAgo = Date().timeIntervalSince(mtime)
            status.seconds_since_last_change = Int(secondsAgo.rounded())
            status.recent_activity = secondsAgo < recentActivityThresholdSeconds
        }
        do {
            let reader = try SQLiteReader(path: dbPath, copyToTemp: true)
            let rows = try reader.query(
                "SELECT COUNT(*) AS c FROM ZICCLOUDSTATE state "
                + "WHERE state.ZCURRENTLOCALVERSION > state.ZLATESTVERSIONSYNCEDTOCLOUD "
                + "AND state.ZLATESTVERSIONSYNCEDTOCLOUD IS NOT NULL "
                + "AND EXISTS (SELECT 1 FROM ZICCLOUDSYNCINGOBJECT object WHERE object.ZCLOUDSTATE = state.Z_PK);")
            status.pending_upload = Int((rows.first?["c"] ?? nil) ?? "0") ?? 0
        } catch {
            // Leave pending_upload at 0; WAL-derived recent_activity still stands.
        }
        status.sync_detected = status.pending_upload > 0 || status.recent_activity
        if status.sync_detected {
            var reasons: [String] = []
            if status.pending_upload > 0 { reasons.append("\(status.pending_upload) item(s) pending upload") }
            if status.recent_activity, let s = status.seconds_since_last_change { reasons.append("database modified \(s)s ago") }
            status.warning = "iCloud sync in progress: \(reasons.joined(separator: ", ")). Results may be incomplete or change shortly."
        }
        return status
    }
}

// MARK: - Store-read seam

/// The `NotesStore` surface the Notes command layer actually depends on.
///
/// `NotesStore`'s reads are static and resolve the operator's live `NoteStore.sqlite` from
/// `homeDirectoryForCurrentUser`, so a command that called them directly could only be exercised
/// against real personal data. This protocol is the seam that removes that coupling — the same
/// role `AppleScriptRunning` already plays for the Notes.app boundary. Production always binds
/// `LiveNotesStore()`; nothing in the CLI can select a different implementation, because the only
/// way to supply one is the internal `run(…)` overloads' `storeFactory` argument, which no flag
/// or environment variable reaches.
///
/// That claim is STRUCTURAL, not conventional: neither `currentSyncWarning` nor `NotesScript.init`
/// defaults this parameter, so `LiveNotesStore()` appears nowhere but a production `run()` shim
/// and code that omits it does not compile. (`NotesScript` did carry such a default; it was the
/// one remaining place a live store could be constructed outside a shim, and every bare
/// `NotesScript()` reached it.)
protocol NotesStoreReading {
    func metadata(noteId: String) -> NotesStore.MetadataOutcome
    func checklistItems(noteId: String) -> NotesStore.ChecklistOutcome
    func noteLink(noteId: String) -> String?
    func syncStatus() -> NotesSyncStatus
    /// Whether the store file is present at all — `get-link` classifies its failure by this
    /// (absent ⇒ authorization_denied, present ⇒ upstream).
    var dbExists: Bool { get }
    /// Whether the store is present AND readable, i.e. Full Disk Access is effectively granted.
    func hasFDA() -> Bool
}

/// The production binding: every call forwards to the `NotesStore` static of the same name.
///
/// `dbPath` defaults to the live store and is a parameter only so the logic tier can point the
/// REAL query code at a synthetic fixture database. It is not reachable from argv or the
/// environment.
struct LiveNotesStore: NotesStoreReading {
    let dbPath: String

    init(dbPath: String = NotesStore.dbPath) { self.dbPath = dbPath }

    func metadata(noteId: String) -> NotesStore.MetadataOutcome {
        NotesStore.metadata(noteId: noteId, dbPath: dbPath)
    }
    func checklistItems(noteId: String) -> NotesStore.ChecklistOutcome {
        NotesStore.checklistItems(noteId: noteId, dbPath: dbPath)
    }
    func noteLink(noteId: String) -> String? {
        NotesStore.noteLink(noteId: noteId, dbPath: dbPath)
    }
    func syncStatus() -> NotesSyncStatus {
        NotesStore.syncStatus(dbPath: dbPath)
    }
    var dbExists: Bool { NotesStore.exists(at: dbPath) }
    func hasFDA() -> Bool { NotesStore.hasFDA(dbPath: dbPath) }
}
