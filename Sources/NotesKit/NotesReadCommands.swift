import ArgumentParser
import Foundation
import AppleKit

// Read commands. The SQLite/FDA-backed ones (get-checklist, get-metadata) are live-testable
// without Notes.app automation; the AppleScript-backed ones require Notes automation.

// MARK: get-checklist (SQLite protobuf — live)

struct GetChecklistCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get-checklist",
        abstract: "Read a note's checklist items + done-state from NoteStore.sqlite (needs Full Disk Access).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Note id (x-coredata://…/ICNote/pNNN).") var id: String

    func run() throws {
        try runGuarded(tool: notesTool) {
            // SQLite-only path (a strict-superset improvement over the reference, which first
            // does an AppleScript existence guard that fails on trashed/slow notes). We still
            // honor the password-protected refusal, resolved from SQLite metadata.
            let meta = NotesStore.metadata(noteId: id)
            if meta.metadata?.password_protected == true {
                throw AppleError.validation("Note is password-protected and cannot be read. Unlock it in Notes.app first.")
            }
            let outcome = NotesStore.checklistItems(noteId: id)
            guard let items = outcome.items else {
                switch outcome.error {
                case .invalidId: throw AppleError.validation(outcome.message ?? "Invalid note id.")
                case .noFDA: throw AppleError.permissionDenied(outcome.message ?? NotesStore.fdaChecklistMessage)
                case .noChecklists: throw AppleError.notFound(outcome.message ?? "This note has no checklist items.")
                default: throw AppleError.upstream(outcome.message ?? "Failed to read checklist state.")
                }
            }
            let checked = items.filter { $0.done }.count
            let state = ChecklistState(items: items, checked: checked, total: items.count)
            try emitNotes(state, json: global.json,
                human: "Checklist (\(checked)/\(items.count) done):\n"
                    + items.map { "\($0.done ? "[x]" : "[ ]") \($0.text)" }.joined(separator: "\n"))
        }
    }
}

// MARK: get-metadata (SQLite scalar cols — live)

struct GetMetadataCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get-metadata",
        abstract: "[BETA] Read note metadata AppleScript can't expose (pinned, snippet, flags) from NoteStore.sqlite.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Note id (x-coredata://…/ICNote/pNNN).") var id: String

    func run() throws {
        try runGuarded(tool: notesTool) {
            let outcome = NotesStore.metadata(noteId: id)
            guard let metadata = outcome.metadata else {
                switch outcome.error {
                case .invalidId: throw AppleError.validation(outcome.message ?? "Invalid note id.")
                case .noFDA: throw AppleError.permissionDenied(outcome.message ?? NotesStore.fdaMetadataMessage)
                case .notFound: throw AppleError.notFound(outcome.message ?? "Note not found.")
                default: throw AppleError.upstream(outcome.message ?? "Failed to read note metadata.")
                }
            }
            try emitNotes(metadata, json: global.json, human: "Metadata read for \(id).")
        }
    }
}

// MARK: get-by-id / get-details (AppleScript metadata)

struct GetByIdCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get-by-id",
        abstract: "Note metadata by id (id, title, dates, shared, password_protected).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Note id.") var id: String

    func run() throws {
        try runGuarded(tool: notesTool) {
            guard let note = try NotesScript().getNoteById(id: id) else {
                throw AppleError.notFound("Note with id \"\(id)\" not found.")
            }
            let data = NoteMetaByLookup(id: note.id, title: note.title, created: note.created,
                modified: note.modified, shared: note.shared, password_protected: note.passwordProtected, account: nil)
            try emitNotes(data, json: global.json, human: "\(note.title) [\(note.id)]")
        }
    }
}

/// `get-note-link` — the last unmapped oracle tool (NOTES-H1). SQLite first, AppleScript
/// `note link` as the macOS 12-15 fallback, exactly as the oracle orders them.
struct GetNoteLinkCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get-link",
        abstract: "notes:// deep link for a note, by id (preferred) or title. → get-note-link")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Note id (preferred - more reliable than title).") var id: String?
    @Option(name: .long, help: "Note title (use id instead when available).") var title: String?
    @Option(name: .long, help: "Account containing the note (ignored if id is provided).") var account: String?

    /// Verbatim from the oracle's title-path miss.
    static func titleNotFound(_ title: String) -> String {
        "Note \"\(title)\" not found. Use search-notes to find notes, then use the note's ID "
        + "for reliable operations."
    }

    /// Verbatim from the oracle, including the trailing macOS-12-15 parenthetical.
    static func linkFailure(_ name: String) -> String {
        "Failed to get note link for \"\(name)\". The Notes database may not be accessible — grant "
        + "Full Disk Access to the app that launches the server, fully quit and relaunch, then run "
        + "the doctor tool. See: \(NotesStore.fdaGuideURL). (On macOS 12–15 this also falls back to "
        + "the AppleScript note link property.)"
    }

    /// The message tells the operator to grant Full Disk Access, so the TYPE has to agree:
    /// `unknown`/70 is documented as "unexpected internal error" and an agent branching on
    /// error.type could not route it to the FDA remediation path. Sibling commands in this file
    /// already classify a missing store as authorization_denied/77 and other store failures as
    /// upstream/69; match them rather than inventing a third answer.
    static func linkFailureError(_ name: String) -> AppleError {
        NotesStore.dbExists ? .upstream(linkFailure(name)) : .permissionDenied(linkFailure(name))
    }

    /// Oracle `getNoteLinkById`: SQLite, then AppleScript. Returns nil rather than throwing so
    /// the caller emits the oracle's single "Failed to get note link" message for either miss.
    ///
    /// MEASURED on macOS 26.5.1: `note link` is GONE from the Notes SDEF — the fallback returns
    /// `execution error: The variable link is not defined. (-2753)` — so on macOS 26+ the SQLite
    /// read is the only path that can succeed and this branch is dead. It is kept because the
    /// oracle keeps it for macOS 12–15, where it IS reachable; without FDA on macOS 26 the only
    /// outcome is the link-failure error, which is why its classification (authorization_denied
    /// when the store is unreadable, not `unknown`) matters more here than the prose suggests.
    static func resolveLink(_ script: NotesScript, id: String) -> String? {
        if let fromDB = NotesStore.noteLink(noteId: id) { return fromDB }
        guard let out = try? script.noteLinkById(id: id) else { return nil }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The oracle uses JS truthiness (`if (id)` / `if (!title)`), so exact `""` is absent;
    /// `{id:"", title:"…"}` is a common, reachable tool-call shape. This mirrors shared
    /// `requireIdOrTitle` (NotesCommand.swift:173), but the oracle's `getNoteById` runs
    /// `sanitizeId` first (index.js:39751): any other id, including whitespace, wins over title
    /// and is validation-tested rather than flattened into not_found.
    static func requireSelector(id: String?, title: String?) throws -> NoteSelector {
        switch (id?.isEmpty == false ? id : nil, title?.isEmpty == false ? title : nil) {
        case let (id?, _):
            // Oracle `getNoteById` runs `sanitizeId` first, so malformed ids fail before lookup
            // and never fall through to a simultaneously supplied title.
            guard NotesScript.isValidNoteId(id) else {
                throw AppleError.validation(
                    "Invalid note ID format: \"\(id)\". Expected CoreData URL (x-coredata://...) or temp ID.")
            }
            return .id(id)
        case let (nil, title?): return .title(title)
        default: throw AppleError.validation("Either 'id' or 'title' is required")
        }
    }

    func run() throws {
        try runGuarded(tool: notesTool) {
            let script = NotesScript()
            switch try Self.requireSelector(id: id, title: title) {
            case .id(let id):
                // The lookup THROWS a generic not_found rather than returning nil (AppleScript
                // errors on a bad specifier; see NotesScript.mapError), so the oracle's specific
                // wording has to be restored here — a bare `guard let` never fires.
                let found: NotesScript.ParsedNote?
                do { found = try script.getNoteById(id: id) }
                catch let e as AppleError where e.type == AppleErrorType.notFound { found = nil }
                guard let note = found else {
                    throw AppleError.notFound("Note with ID \"\(id)\" not found")
                }
                if note.passwordProtected {
                    throw AppleError.validation("Note \"\(note.title)\" is password-protected. Unlock it in Notes.app first.")
                }
                guard let url = Self.resolveLink(script, id: id) else {
                    throw Self.linkFailureError(note.title)
                }
                try emitNotes(NoteLinkResult(id: id, title: note.title, url: url),
                              json: global.json, human: url)
            case .title(let title):
                let foundByTitle: NotesScript.ParsedNote?
                do { foundByTitle = try script.getNoteDetails(title: title, account: account) }
                catch let e as AppleError where e.type == AppleErrorType.notFound { foundByTitle = nil }
                guard let note = foundByTitle else {
                    throw AppleError.notFound(Self.titleNotFound(title))
                }
                if note.passwordProtected {
                    throw AppleError.validation("Note \"\(title)\" is password-protected. Unlock it in Notes.app first.")
                }
                guard let url = Self.resolveLink(script, id: note.id) else {
                    throw Self.linkFailureError(title)
                }
                // No `id` key on this path — the oracle omits it here.
                try emitNotes(NoteLinkResult(id: nil, title: title, url: url),
                              json: global.json, human: url)
            }
        }
    }
}

struct GetDetailsCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get-details",
        abstract: "Note metadata by title (adds account).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Exact note title.") var title: String
    @Option(name: .long, help: "Account (defaults to iCloud).") var account: String?

    func run() throws {
        try runGuarded(tool: notesTool) {
            guard let note = try NotesScript().getNoteDetails(title: title, account: account) else {
                throw AppleError.notFound("Note \"\(title)\" not found.")
            }
            let data = NoteMetaByLookup(id: note.id, title: note.title, created: note.created,
                modified: note.modified, shared: note.shared, password_protected: note.passwordProtected,
                account: NotesScript().resolveAccount(account))
            try emitNotes(data, json: global.json, human: "\(note.title) [\(note.id)]")
        }
    }
}

// MARK: get (content + hashtags)

struct GetCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get",
        abstract: "Full HTML body of a note (by --id or --title) plus parsed hashtags.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Note id (preferred).") var id: String?
    @Option(name: .long, help: "Note title.") var title: String?
    @Option(name: .long, help: "Account (title path only).") var account: String?

    func run() throws {
        try runGuarded(tool: notesTool) {
            let script = NotesScript()
            let selector = try requireIdOrTitle(id: id, title: title)
            let (resolvedTitle, rawContent) = try resolveContent(script, selector)
            let stripped = NotesText.stripLargeInlineImages(rawContent)
            let hashtags = NotesText.parseHashtags(stripped.html)
            let data = NoteContent(title: resolvedTitle, content: stripped.html, hashtags: hashtags)
            try emitNotes(data, json: global.json, human: stripped.html)
        }
    }

    private func resolveContent(_ script: NotesScript, _ selector: NoteSelector) throws -> (String, String) {
        switch selector {
        case .id(let noteId):
            guard let note = try script.getNoteById(id: noteId) else { throw AppleError.notFound("Note with id \"\(noteId)\" not found.") }
            if note.passwordProtected { throw AppleError.validation("Note \"\(note.title)\" is password-protected. Unlock it in Notes.app first.") }
            let content = try script.getNoteContentById(id: noteId)
            if content.isEmpty { throw AppleError.notFound("Failed to read content of note \"\(note.title)\".") }
            return (note.title, content)
        case .title(let noteTitle):
            guard let note = try script.getNoteDetails(title: noteTitle, account: account) else { throw AppleError.notFound("Note \"\(noteTitle)\" not found.") }
            if note.passwordProtected { throw AppleError.validation("Note \"\(noteTitle)\" is password-protected. Unlock it in Notes.app first.") }
            let content = try script.getNoteContent(title: noteTitle, account: account)
            if content.isEmpty { throw AppleError.notFound("Failed to read content of note \"\(noteTitle)\".") }
            return (noteTitle, content)
        }
    }
}

// MARK: get-plaintext

struct GetPlaintextCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get-plaintext",
        abstract: "Native plaintext body of a note (by --id or --title).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Note id (preferred).") var id: String?
    @Option(name: .long, help: "Note title.") var title: String?
    @Option(name: .long, help: "Account (title path only).") var account: String?

    func run() throws {
        try runGuarded(tool: notesTool) {
            let script = NotesScript()
            let selector = try requireIdOrTitle(id: id, title: title)
            let resolvedTitle: String
            let plaintext: String
            switch selector {
            case .id(let noteId):
                guard let note = try script.getNoteById(id: noteId) else { throw AppleError.notFound("Note with id \"\(noteId)\" not found.") }
                if note.passwordProtected { throw AppleError.validation("Note \"\(note.title)\" is password-protected. Unlock it in Notes.app first.") }
                resolvedTitle = note.title
                plaintext = try script.getNotePlaintextById(id: noteId)
            case .title(let noteTitle):
                guard let note = try script.getNoteDetails(title: noteTitle, account: account) else { throw AppleError.notFound("Note \"\(noteTitle)\" not found.") }
                if note.passwordProtected { throw AppleError.validation("Note \"\(noteTitle)\" is password-protected. Unlock it in Notes.app first.") }
                resolvedTitle = noteTitle
                plaintext = try script.getNotePlaintext(title: noteTitle, account: account)
            }
            if plaintext.isEmpty { throw AppleError.notFound("Failed to read plaintext of note \"\(resolvedTitle)\".") }
            try emitNotes(NotePlaintext(title: resolvedTitle, plaintext: plaintext), json: global.json, human: plaintext)
        }
    }
}

// MARK: get-markdown

struct GetMarkdownCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get-markdown",
        abstract: "Note as Markdown, checklist items annotated [x]/[ ] when Full Disk Access is granted.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Note id (preferred).") var id: String?
    @Option(name: .long, help: "Note title.") var title: String?
    @Option(name: .long, help: "Account (title path only).") var account: String?

    func run() throws {
        try runGuarded(tool: notesTool) {
            let script = NotesScript()
            let selector = try requireIdOrTitle(id: id, title: title)
            let markdown: String
            switch selector {
            case .id(let noteId): markdown = try script.getNoteMarkdownById(id: noteId)
            case .title(let noteTitle): markdown = try script.getNoteMarkdown(title: noteTitle, account: account)
            }
            if markdown.isEmpty { throw AppleError.notFound("Note not found or has no content.") }
            try emitNotes(NoteMarkdown(markdown: markdown), json: global.json, human: markdown)
        }
    }
}

// MARK: list

struct ListCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list",
        abstract: "List note titles in an account/folder (supports --modified-since, --limit).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Account to list from.") var account: String?
    @Option(name: .long, help: "Filter to a folder (nested paths ok).") var folder: String?
    @Option(name: .customLong("modified-since"), help: "ISO-8601 date; only notes modified on/after.") var modifiedSince: String?
    @Option(name: .long, help: "Max results.") var limit: Int?

    func run() throws {
        try runGuarded(tool: notesTool) {
            // exclusiveMinimum 0, same as search. NO default here: verified `resolveSearchLimit`
            // is absent from the oracle's list-notes handler, so unbounded list IS the parity.
            try validateSearchLimit(limit)
            let since = try parseISODateOrThrow(modifiedSince)
            let titles = try NotesScript().listNotes(account: account, folder: folder, modifiedSince: since, limit: limit)
            try emitNotes(NoteTitleList(notes: titles, count: titles.count, sync_warning: currentSyncWarning(),
                                        applied_limit: limit),
                json: global.json,
                // Oracle list-notes renders ` (limit: N)` when a limit was passed. Appended only
                // on the non-empty branch, matching what `search` does above.
                human: titles.isEmpty ? "No notes found."
                    : titles.map { "  - \($0)" }.joined(separator: "\n")
                        + (limit.map { " (limit: \($0))" } ?? ""))
        }
    }
}

// MARK: search

struct SearchCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "search",
        abstract: "Search notes by title (or body with --content); returns id/title/folder.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Search query.") var query: String
    @Flag(name: .long, help: "Search note bodies instead of titles.") var content = false
    @Option(name: .long, help: "Account to search.") var account: String?
    @Option(name: .long, help: "Limit search to a folder.") var folder: String?
    @Option(name: .customLong("modified-since"), help: "ISO-8601 date filter.") var modifiedSince: String?
    @Option(name: .long, help: "Max results (default 50, like the MCP).") var limit: Int?
    @Flag(name: .long, help: "Return every match, no limit. CLI-only superset — the MCP always caps.")
    var all = false

    func run() throws {
        try runGuarded(tool: notesTool) {
            // Oracle schema: query is minLength 1 AND maxLength 2000; limit is exclusiveMinimum 0.
            if query.isEmpty { throw AppleError.validation("Search query is required.") }
            if query.count > NotesLimits.query {
                throw AppleError.validation("Search query exceeds maximum length of \(NotesLimits.query) characters.")
            }
            if all && limit != nil {
                throw AppleError.validation("--all and --limit are mutually exclusive.")
            }
            try validateSearchLimit(limit)
            let since = try parseISODateOrThrow(modifiedSince)
            // Oracle: `const effectiveLimit = resolveSearchLimit(limit)` — absent means 50, not
            // unbounded. Measured before this change: a bare `notes search e` returned 245 here
            // and would return 50 from the oracle; an unbounded search also reads several
            // properties per match over AppleScript and can time out, which is the reason the
            // oracle's own schema gives for the default.
            let (effective, wasDefault) = SearchLimit.resolve(limit, all: all)
            let notes = try NotesScript().searchNotes(query: query, searchContent: content, account: account,
                folder: folder, modifiedSince: since, limit: effective)
            let note = SearchLimit.truncationNote(count: notes.count, effective: effective, wasDefault: wasDefault)
            // The oracle renders ` (limit: N[, default])` on EVERY non-empty response, not only
            // when it truncated; emitting it only on truncation dropped a disclosure it always makes.
            // The oracle emits its limit info on every NON-EMPTY response and returns early on
            // the empty branch before rendering it, so a zero-match search carries none.
            let limitInfo = notes.isEmpty ? ""
                : (effective.map { " (limit: \($0)\(wasDefault ? ", default" : ""))" } ?? " (no limit)")
            let suffix = limitInfo + (note.map { "\n  … " + $0 } ?? "")
            try emitNotes(NoteList(notes: notes, count: notes.count, sync_warning: currentSyncWarning(),
                                   applied_limit: effective, limit_reached: note != nil,
                                   limit_was_default: wasDefault),
                json: global.json,
                human: (notes.isEmpty ? "No matches." : notes.map { "  - \($0.title) [\($0.id)]" }.joined(separator: "\n")) + suffix)
        }
    }
}

// MARK: selected

struct SelectedCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "selected",
        abstract: "Notes currently selected in the Notes.app UI.")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        try runGuarded(tool: notesTool) {
            let notes = try NotesScript().getSelectedNotes()
            try emitNotes(SelectedNoteList(notes: notes, count: notes.count), json: global.json,
                human: notes.isEmpty ? "No notes selected." : notes.map { "  - \($0.title) [\($0.id)]" }.joined(separator: "\n"))
        }
    }
}

/// Parse an ISO-8601 (or `yyyy-MM-dd`) date filter; nil passes through. Throws validation on a
/// malformed value (the reference silently ignores bad dates — apple-cli surfaces the error).
func parseISODateOrThrow(_ raw: String?) throws -> Date? {
    guard let raw, !raw.isEmpty else { return nil }
    let iso = ISO8601DateFormatter()
    if let d = iso.date(from: raw) { return d }
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
        df.dateFormat = fmt
        if let d = df.date(from: raw) { return d }
    }
    throw AppleError.validation("Invalid date \"\(raw)\" — use ISO-8601 (e.g. 2025-01-01).")
}
