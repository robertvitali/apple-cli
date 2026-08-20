import Foundation

// Encodable payloads for the `data` field of the apple-cli envelope. Each mirrors the
// corresponding `apple-notes-mcp` tool's `structuredContent`, with camelCase MCP keys
// mapped to apple-cli snake_case (docs/DESIGN.md: "name payload fields in snake_case").
// The camelCase→snake_case map is 1:1 and information-preserving (a strict superset):
//   passwordProtected→password_protected, wasShared→was_shared, savedPath→saved_path,
//   contentType→content_type, secondsSinceLastChange→seconds_since_last_change,
//   totalNotes→total_notes, last24h→last_24h, hasChecklist→has_checklist, etc.
// Optional (`?`) fields are OMITTED by JSONEncoder when nil, matching the reference's
// "field absent when unavailable" behavior (metadata, attachment url, etc.).

// MARK: Notes

struct CreatedNote: Encodable {
    let ok: Bool
    let id: String
    let title: String
    let folder: String?
    let account: String?
    /// Present only when the body looked like a checklist — see `NotesText.detectChecklistAttempt`.
    /// Optional, so the synthesized `Encodable` omits the key entirely on the normal path.
    let warning: String?
}

/// A search hit. The MCP's `searchNotes()` pushes exactly `{id, title, content:"", tags:[],
/// created, modified, folder, account}` per match (build/index.js ~39810: `content: "", // Not
/// fetched in search` and `tags: []` — both hardcoded, never populated, on every hit, permanently
/// — while `created`/`modified` ARE the note's real dates, read per-hit in the same single search
/// loop via `asDatePartsExpr`, `new Date()` only its unreadable-date fallback). Operator-ruled
/// STRICT PARITY (NOTES-M1): apple-cli now emits all eight keys, `content`/`tags` included, so the
/// wire shape matches byte-for-byte — including the oracle's own placeholder-ness of those two
/// fields. This costs NO extra AppleScript round trip: the oracle itself never fetches real
/// content/tags for a search hit, so mirroring it exactly means emitting the same literal `""`/
/// `[]`, not a per-hit content fetch. (An earlier revision dropped created/modified too, on the
/// mistaken belief the MCP fabricated them at response time — review disproved that against the
/// oracle source, so they were ported. A later revision dropped content/tags as "useless
/// placeholders"; the operator has since ruled that strict parity outweighs that rationale.)
struct NoteSummary: Encodable {
    let id: String
    let title: String
    let content: String
    let tags: [String]
    let folder: String?
    let account: String?
    let created: Date
    let modified: Date
}

/// `sync_warning` is apple-cli's structured equivalent of the MCP's `withSyncAwareness` text
/// warning: populated (else omitted) when an iCloud sync is in progress and results may be
/// incomplete. Present on the three MCP tools the reference wraps: search / list / folders.
struct NoteList: Encodable {
    let notes: [NoteSummary]
    let count: Int
    let sync_warning: String?
    /// The limit actually applied. The oracle discloses this only in its PROSE response
    /// (` (limit: 50, default)`); on a JSON-first contract it belongs in the payload, so these
    /// two are additive optional fields — MINOR per docs/versioning-policy.md — and stay absent
    /// on surfaces that apply no limit (e.g. `list`, which the oracle also leaves unbounded).
    var applied_limit: Int? = nil
    /// True when the result set REACHED the limit, so more matches may exist. Named
    /// `limit_reached` rather than `truncated`: at count == limit we cannot know whether a 51st
    /// match exists, so "truncated" asserts more than the data supports. Renaming later would be
    /// a MAJOR wire break; it is free now.
    var limit_reached: Bool? = nil
    /// True when `applied_limit` came from the default rather than an explicit --limit.
    var limit_was_default: Bool? = nil
}

struct NoteTitleList: Encodable {
    let notes: [String]
    let count: Int
    let sync_warning: String?
    /// Present only when --limit was passed. `list` has no default (the oracle's list-notes
    /// handler applies none), but a caller-requested cut is still a cut and the oracle discloses
    /// it too (` (limit: N)`), so silence here would be the same defect the search fields fix.
    var applied_limit: Int? = nil
}

struct NoteContent: Encodable {
    let title: String
    let content: String
    let hashtags: [String]
}

struct NotePlaintext: Encodable {
    let title: String
    let plaintext: String
}

struct NoteMarkdown: Encodable {
    let markdown: String
}

/// Note metadata (get-by-id / get-details). Dates are `Date` so the shared encoder renders
/// ISO-8601 (docs/DESIGN.md). `account` is present only for the by-title `get-details` path.
struct NoteMetaByLookup: Encodable {
    let id: String
    let title: String
    let created: Date
    let modified: Date
    let shared: Bool
    let password_protected: Bool
    let account: String?
}

/// `get-selected-notes`. The MCP's `getSelectedNotes()` pushes `{id, title, content:"", tags:[],
/// created, modified, shared, passwordProtected, folder, account}` per selected note
/// (build/index.js:40717-40728: `content: "",` / `tags: [],` — both hardcoded, never fetched, same
/// as search — while `created`/`modified`/`shared`/`passwordProtected`/`folder`/`account` are all
/// real, read in the same single AppleScript call). Operator-ruled STRICT PARITY (NOTES-M1
/// follow-up): apple-cli emits all ten keys, `content`/`tags` included — byte-for-byte, zero extra
/// AppleScript round trips (see NoteSummary's doc comment for the same reasoning). See
/// docs/port-specs/notes.md.
struct SelectedNote: Encodable {
    let id: String
    let title: String
    let content: String
    let tags: [String]
    let created: Date
    let modified: Date
    let shared: Bool
    let password_protected: Bool
    let folder: String?
    let account: String?
}

struct SelectedNoteList: Encodable {
    let notes: [SelectedNote]
    let count: Int
}

/// `list-shared-notes`. The MCP's `listSharedNotes()` pushes `{id, title, content:"", tags:[],
/// created, modified, account, shared, passwordProtected}` per shared note (build/index.js:
/// 40371-40381: `content: "",` / `tags: [],` — both hardcoded, never fetched, same as search —
/// while `created`/`modified`/`account`/`shared`/`passwordProtected` are all real). Note the
/// absence of a `folder` key here — that is a REAL divergence from `search`/`selected`, not a gap:
/// the oracle's shared-notes AppleScript loop (index.js:40341-40347) never reads `container of n`
/// at all, so `folder` genuinely does not exist on this endpoint's wire shape; apple-cli's omission
/// of `folder` on `SharedNote` already matched this before NOTES-M1. Operator-ruled STRICT PARITY
/// (NOTES-M1 follow-up): apple-cli emits all nine of the oracle's keys, `content`/`tags` included —
/// byte-for-byte, zero extra AppleScript round trips. See docs/port-specs/notes.md.
struct SharedNote: Encodable {
    let id: String
    let title: String
    let content: String
    let tags: [String]
    let account: String?
    let created: Date
    let modified: Date
    let shared: Bool
    let password_protected: Bool
}

struct SharedNoteList: Encodable {
    let notes: [SharedNote]
    let count: Int
}

struct UpdatedNote: Encodable {
    let ok: Bool
    let id: String?
    let title: String
    let shared: Bool
    /// See `CreatedNote.warning`. `append` never sets it: the oracle calls
    /// `detectChecklistAttempt` in create-note and the two update-note paths ONLY, and this type is
    /// shared with append.
    let warning: String?
}

struct DeletedNote: Encodable {
    let ok: Bool
    let id: String?
    let title: String
    let was_shared: Bool
}

struct MovedNote: Encodable {
    let ok: Bool
    let id: String?
    let title: String
    let folder: String
}

struct ShownEntity: Encodable {
    let id: String
    let separately: Bool
}

// MARK: Folders / accounts

struct Folder: Encodable {
    let id: String
    let name: String
    let account: String
    let shared: Bool
}

struct FolderList: Encodable {
    let folders: [Folder]
    let count: Int
    let sync_warning: String?
}

struct CreatedFolder: Encodable {
    let ok: Bool
    let folder: String
}

struct Account: Encodable {
    let id: String?
    let name: String
    let upgraded: Bool?
    let default_folder_id: String?
    let default_folder: String?
}

struct AccountList: Encodable {
    let accounts: [Account]
    let count: Int
}

struct DefaultLocation: Encodable {
    let account: Account
    let folder: Folder
}

// MARK: Attachments

struct Attachment: Encodable {
    let id: String
    let name: String
    let content_type: String
    let content_id: String?
    let url: String?
    let created: Date?
    let modified: Date?
    let shared: Bool?
}

struct AttachmentList: Encodable {
    let attachments: [Attachment]
    let count: Int
}

struct SavedAttachment: Encodable {
    let saved_path: String
    let name: String?
    let content_type: String?
}

struct FetchedAttachment: Encodable {
    let name: String?
    let content_type: String?
    let bytes: Int?
    let base64: String
}

struct ShownAttachment: Encodable {
    let note_id: String
    let attachment_id: String
    let separately: Bool
}

// MARK: Batch

struct BatchItemResult: Encodable {
    let id: String
    let success: Bool
    let error: String?
}

struct BatchDeleteResult: Encodable {
    let ok: Bool
    let succeeded: Int
    let failed: Int
    let results: [BatchItemResult]
}

struct BatchMoveResult: Encodable {
    let ok: Bool
    let folder: String
    let succeeded: Int
    let failed: Int
    let results: [BatchItemResult]
}

// MARK: Diagnostics

struct HealthCheckItem: Encodable {
    let name: String
    let passed: Bool
    let message: String
}

struct HealthResult: Encodable {
    let healthy: Bool
    let checks: [HealthCheckItem]
    let full_disk_access: Bool
}

struct DoctorCheck: Encodable {
    let name: String
    let status: String // "ok" | "warn" | "fail"
    let detail: String
}

struct DoctorResult: Encodable {
    let healthy: Bool
    let checks: [DoctorCheck]
}

/// get-sync-status. `seconds_since_last_change` is Int? (nil when no WAL file — the reference
/// uses Infinity there, which JSON renders as null); it is populated whenever a WAL exists,
/// which is the normal case for a live Notes store.
public struct NotesSyncStatus: Encodable {
    public var sync_detected = false
    public var pending_upload = 0
    public var seconds_since_last_change: Int?
    public var recent_activity = false
    public var warning: String?
    public var error: String?
    public init() {}
}

struct FolderStat: Encodable {
    let name: String
    let note_count: Int
}

struct AccountStat: Encodable {
    let name: String
    let total_notes: Int
    let folder_count: Int
    let folders: [FolderStat]
}

struct RecentlyModified: Encodable {
    let last_24h: Int
    let last_7d: Int
    let last_30d: Int
}

struct CoverageWarning: Encodable {
    let scope: String
    let reason: String
}

struct Coverage: Encodable {
    let complete: Bool
    let scanned: Int
    let covered: Int
    let warnings: [CoverageWarning]
}

struct NotesStats: Encodable {
    let total_notes: Int
    let accounts: [AccountStat]
    let recently_modified: RecentlyModified
    let coverage: Coverage
}

// MARK: Checklist / metadata (SQLite/FDA)

struct ChecklistState: Encodable {
    let items: [NotesStore.ChecklistItem]
    let checked: Int
    let total: Int
}

/// BETA note metadata read from NoteStore.sqlite. All fields optional so absent columns
/// (schema drift across macOS releases) and null values are simply omitted from the output.
public struct NotesMetadata: Encodable {
    public var pinned: Bool?
    public var has_checklist: Bool?
    public var has_checklist_in_progress: Bool?
    public var recovering_from_trash: Bool?
    public var password_protected: Bool?
    public var password_hint: String?
    public var snippet: String?
    public var widget_snippet: String?
    public var smart_folder_query: String?
    public init() {}

    mutating func set(_ key: String, bool value: Bool) {
        switch key {
        case "pinned": pinned = value
        case "has_checklist": has_checklist = value
        case "has_checklist_in_progress": has_checklist_in_progress = value
        case "recovering_from_trash": recovering_from_trash = value
        case "password_protected": password_protected = value
        default: break
        }
    }
    mutating func set(_ key: String, text value: String) {
        switch key {
        case "password_hint": password_hint = value
        case "snippet": snippet = value
        case "widget_snippet": widget_snippet = value
        case "smart_folder_query": smart_folder_query = value
        default: break
        }
    }
}

// MARK: Export

struct ExportNote: Encodable {
    let id: String
    let title: String
    let content: String
    let plaintext: String
    let folder: String
    let account: String
    let created: Date
    let modified: Date
    let shared: Bool
    let password_protected: Bool
}

struct ExportFolder: Encodable {
    let name: String
    let notes: [ExportNote]
}

struct ExportAccount: Encodable {
    let name: String
    let folders: [ExportFolder]
}

struct ExportSummary: Encodable {
    let total_notes: Int
    let total_folders: Int
    let total_accounts: Int
}

struct NotesExport: Encodable {
    let export_date: Date
    let version: String
    let accounts: [ExportAccount]
    let summary: ExportSummary
}

/// `get-note-link` payload. The oracle's two paths emit DIFFERENT key sets — the id path
/// returns {id, title, url}, the title path returns {title, url} with NO id (server.py-equivalent
/// index.js:42469 vs :42489) — so `id` is optional and omitted (synthesized encodeIfPresent)
/// rather than emitted as null, matching the oracle's payload shape on each path.
struct NoteLinkResult: Encodable {
    let id: String?
    let title: String
    let url: String
}
