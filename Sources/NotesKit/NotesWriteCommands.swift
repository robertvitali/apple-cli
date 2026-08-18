import ArgumentParser
import Foundation
import AppleKit

// Write commands. Under write-model v2 (docs/write-model-v2.md) each behaves like the
// equivalent apple-notes-mcp tool: invoking it MUTATES Notes.app. `--dry-run` previews;
// `APPLE_DRY_RUN` truthy restores dry-run-by-default.
//
// `resolveNotesWrite` is the single chokepoint (validates the v2 environment, resolves
// willExecute + sandboxActive, bound once per run()). `guardLiveWrite` confines the target to
// `apple-cli-test…` items ONLY inside the opt-in sandbox — the oracle has no such gate, so it
// is a CLI-only restriction, not part of the behavior being replicated.

func validateFormat(_ format: String) throws -> Bool {
    switch format.lowercased() {
    case "plaintext": return false
    case "html": return true
    default: throw AppleError.validation("Invalid --format \"\(format)\" (expected plaintext|html).")
    }
}

/// Mirror the MCP's zod input bounds so oversized input yields the same validation-error class
/// (not a downstream AppleScript failure). Lengths are character counts, matching the reference.
enum NotesLimits {
    static let title = 2000
    static let content = 5 * 1024 * 1024
    static let folder = 1000
    static let account = 200
    /// Oracle `DEFAULT_SEARCH_LIMIT = 50`. SEARCH ONLY — verified `resolveSearchLimit` is not
    /// called from the oracle's list-notes handler, so the CLI's unbounded `list` is correct.
    static let defaultSearchLimit = 50
    /// Oracle `MAX.QUERY: 2e3` on `search-notes`. The `.min(1)` half of that same zod line was
    /// ported and the `.max()` half was not — exactly the case this enum's header exists for.
    static let query = 2000
}

/// Oracle schema for search-notes AND list-notes carries `"limit": {"exclusiveMinimum": 0}`, so a
/// non-positive limit is refused at the MCP boundary before any handler runs. Mirroring that here
/// is what makes `--limit 0` a validation error instead of the 1 result the AppleScript guard
/// happened to yield (the `exit repeat` check sits after the append, so 0 behaved as 1).
enum SearchLimit {
    /// Oracle `resolveSearchLimit` + `limitWasDefault`. Absent means the default, NOT unbounded.
    /// nil `effective` means UNBOUNDED — reachable only via the CLI-only `--all`, which restores
    /// the total query the default would otherwise retire with no replacement.
    static func resolve(_ limit: Int?, all: Bool = false) -> (effective: Int?, wasDefault: Bool) {
        if all { return (nil, false) }
        return (limit ?? NotesLimits.defaultSearchLimit, limit == nil)
    }
    /// Oracle `describeSearchLimit`: the note fires when `resultCount >= effectiveLimit`, and
    /// says "(default limit)" only when the limit was not explicitly passed.
    static func truncationNote(count: Int, effective: Int?, wasDefault: Bool) -> String? {
        guard let effective, count >= effective else { return nil }
        return "showing the first \(effective)\(wasDefault ? " (default limit)" : ""); there may be more. "
            + "Narrow the query, filter with --folder/--modified-since, or pass a higher --limit."
    }
}

func validateSearchLimit(_ limit: Int?) throws {
    if let limit, limit <= 0 {
        throw AppleError.validation("Invalid limit \(limit). Expected an integer greater than 0.")
    }
}

/// Mirror of the oracle's `folderNameSchema.min(1, "Folder name is required")`, which this port
/// dropped while keeping its `.max()`. Under v1 an empty name was refused incidentally (the
/// label gate rejected `""`); v2 removed that accident, so the bound has to be explicit. Applies
/// to any name that becomes an AppleScript folder specifier — an all-separator string collapses
/// to zero components and is therefore just as empty as `""`.
func requireNonEmptyFolderName(_ name: String, _ what: String = "Folder name") throws {
    if NotesScript.splitFolderPath(name).isEmpty {
        throw AppleError.validation("\(what) must be a non-empty string.")
    }
}

func validateBounds(title: String? = nil, content: String? = nil, folder: String? = nil, account: String? = nil) throws {
    if let title, title.count > NotesLimits.title {
        throw AppleError.validation("Note title exceeds maximum length of \(NotesLimits.title) characters.")
    }
    if let content, content.count > NotesLimits.content {
        throw AppleError.validation("Note content exceeds maximum length of \(NotesLimits.content) characters.")
    }
    if let folder, folder.count > NotesLimits.folder {
        throw AppleError.validation("Folder path exceeds maximum length of \(NotesLimits.folder) characters.")
    }
    if let account, account.count > NotesLimits.account {
        throw AppleError.validation("Account name exceeds maximum length of \(NotesLimits.account) characters.")
    }
}

// MARK: create

struct CreateCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create",
        abstract: "Create a note, title prepended as <h1> (EXECUTES; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Note title.") var title: String
    @Option(name: .long, help: "Note body.") var content: String
    @Option(name: .long, help: "Content format: plaintext|html.") var format: String = "plaintext"
    @Option(name: .long, help: "Folder (nested paths ok).") var folder: String?
    @Option(name: .long, help: "Account (defaults to iCloud).") var account: String?
    @Option(name: .long, help: "Echo-only tags (NOT persisted by Notes).") var tags: [String] = []

    func run() throws {
        try runGuarded(tool: notesTool) {
            let html = try validateFormat(format)
            try validateBounds(title: title, content: content, folder: folder, account: account)
            if let folder { try requireNonEmptyFolderName(folder) }
            let gate = try resolveNotesWrite(global, defaultDryRun: false)
            // The new note's title comes from argv, so the sandbox label check is computable
            // here and runs on BOTH paths — a sandboxed preview refuses exactly what execute
            // refuses, at the same exit code, without touching Notes.app.
            try guardLiveWrite(labeledName: title, sandboxActive: gate.sandboxActive)
            // ...and so does the DESTINATION. move/batch-move gained this check in the previous
            // review round and create was missed, so a sandboxed create still wrote into a REAL
            // folder while the identical move was refused.
            if let folder { try guardLiveWrite(labeledName: folder, sandboxActive: gate.sandboxActive) }
            guard gate.willExecute else {
                let folderInfo = folder.map { " in \($0)" } ?? ""
                try emitNotesWrite(DryRunPreview("create-note", "Would create \"\(title)\"\(folderInfo) (format: \(format)). Re-run without --dry-run."),
                                   json: global.json, sandboxActive: gate.sandboxActive,
                                   human: "[dry-run] would create \"\(title)\".")
                return
            }
            let id = try NotesScript().createNote(title: title, content: content, folder: folder, account: account, html: html)
            // Oracle appends a checklist warning to the response on create and both update paths. A
            // checklist cannot be made via AppleScript, so without it the caller gets ok:true and a
            // note that silently is not a checklist. Built in NotesText so the wiring is testable.
            let r = NotesText.createResponse(id: id, title: title, folder: folder,
                                             account: account, content: content)
            try emitNotesExecutedWrite(r.note, json: global.json, sandboxActive: gate.sandboxActive,
                               human: r.human)
        }
    }
}

// MARK: update

struct UpdateCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update",
        abstract: "REPLACE a note's body (and optional title), by --id or --title (EXECUTES; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Note id (preferred).") var id: String?
    @Option(name: .long, help: "Current note title.") var title: String?
    @Option(name: .customLong("new-title"), help: "New title (plaintext format only).") var newTitle: String?
    @Option(name: .customLong("new-content"), help: "New body (REPLACES the whole body).") var newContent: String
    @Option(name: .long, help: "Content format: plaintext|html.") var format: String = "plaintext"
    @Option(name: .long, help: "Account (title path only).") var account: String?

    func run() throws {
        try runGuarded(tool: notesTool) {
            let html = try validateFormat(format)
            try validateBounds(title: newTitle, content: newContent, account: account)
            let selector = try requireIdOrTitle(id: id, title: title)
            let gate = try resolveNotesWrite(global, defaultDryRun: false)
            // A rename must land on a labeled name too, and --new-title is argv-computable, so
            // that half of the check runs on both paths.
            if let newTitle, !newTitle.isEmpty {
                try guardLiveWrite(labeledName: newTitle, sandboxActive: gate.sandboxActive)
            }
            let undisclosed = try applyArgvSelectorGuard(selector, sandboxActive: gate.sandboxActive)
            guard gate.willExecute else {
                let extra = undisclosed ? sandboxTargetUncheckedDetail() : ""
                try emitNotesWrite(DryRunPreview("update-note", "Would REPLACE the body of the target note (format: \(format)). Re-run without --dry-run.\(extra)"),
                                   json: global.json, sandboxActive: gate.sandboxActive,
                                   human: "[dry-run] would replace body.")
                return
            }
            let script = NotesScript()
            switch selector {
            case .id(let noteId):
                guard let note = try script.getNoteById(id: noteId) else { throw AppleError.notFound("Note with id \"\(noteId)\" not found.") }
                if note.passwordProtected { throw AppleError.validation("Note is password-protected. Unlock it in Notes.app first.") }
                try guardLiveWrite(labeledName: note.title, sandboxActive: gate.sandboxActive)
                try script.updateNoteById(id: noteId, newTitle: newTitle, newContent: newContent, html: html)
                // Oracle `resolveUpdateResponseTitle`: in html format the reported title is DERIVED
                // from the new body (first visible line) and newTitle is ignored; plaintext keeps
                // JS truthiness. Returning newTitle unconditionally reported a title Notes would
                // not show, because Notes takes a note's title from its first rendered line.
                let displayTitle = NotesText.resolveUpdateResponseTitle(
                    current: note.title, newTitle: newTitle, html: html, newContent: newContent)
                let r = NotesText.updateResponse(id: noteId, title: displayTitle,
                                                 shared: note.shared, newContent: newContent)
                try emitNotesExecutedWrite(r.note, json: global.json, sandboxActive: gate.sandboxActive,
                                   human: r.human)
            case .title(let noteTitle):
                guard let note = try script.getNoteDetails(title: noteTitle, account: account) else { throw AppleError.notFound("Note \"\(noteTitle)\" not found.") }
                if note.passwordProtected { throw AppleError.validation("Note is password-protected. Unlock it in Notes.app first.") }
                try guardLiveWrite(labeledName: noteTitle, sandboxActive: gate.sandboxActive)
                try script.updateNote(title: noteTitle, newTitle: newTitle, newContent: newContent, account: account, html: html)
                // The FETCHED title, not the user's --title argument: AppleScript's by-name
                // lookup is case-insensitive, so `--title "hello"` against a note named "Hello"
                // reported "hello" where the oracle reports "Hello". Same class as 644ffdb.
                let finalTitle = NotesText.resolveUpdateResponseTitle(
                    current: note.title, newTitle: newTitle, html: html, newContent: newContent)
                let r = NotesText.updateResponse(id: nil, title: finalTitle,
                                                 shared: note.shared, newContent: newContent)
                try emitNotesExecutedWrite(r.note, json: global.json, sandboxActive: gate.sandboxActive,
                                   human: r.human)
            }
        }
    }
}

// MARK: append (curated extra — non-replace edit)

struct AppendCmd: ParsableCommand {
    /// Oracle: position is enum(["after","before"]).default("after"). Anything else is a
    /// validation error, not a silent fallback to "after".
    static func validatePosition(_ p: String) throws -> Bool {
        switch p {
        case "after": return false
        case "before": return true
        default: throw AppleError.validation("Invalid position \"\(p)\". Expected after|before.")
        }
    }

    static let configuration = CommandConfiguration(commandName: "append",
        abstract: """
            Add to a note's body without replacing it. → append-to-note (EXECUTES; --dry-run previews).
            Safety: reads the existing body, concatenates, then writes the WHOLE body back; that rewrite can drop embedded attachments, so run `notes attachments list` first if unsure.
            """)
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Note id (preferred).") var id: String?
    @Option(name: .long, help: "Note title.") var title: String?
    @Option(name: .long, help: "Content to append.") var content: String
    @Option(name: .long, help: "Content format: plaintext|html.") var format: String = "plaintext"
    @Option(name: .long, help: "Where to insert: after (default) appends, before prepends.")
    var position: String = "after"
    @Option(name: .long, help: "String placed between existing and new content (default: two newlines).")
    var separator: String = "\n\n"
    @Option(name: .long, help: "Account (title path only).") var account: String?

    func run() throws {
        try runGuarded(tool: notesTool) {
            let html = try validateFormat(format)
            let prepend = try Self.validatePosition(position)
            // The oracle declares content as .min(1, "Content to append is required");
            // validateBounds only checks the max, so "" was silently accepted here.
            if content.isEmpty { throw AppleError.validation("Content to append is required.") }
            // zod .max(20) measures JS string length — UTF-16 code units, not graphemes.
            if separator.utf16.count > 20 {
                throw AppleError.validation("Separator exceeds maximum length of 20 characters.")
            }
            try validateBounds(content: content, account: account)
            let selector = try requireIdOrTitle(id: id, title: title)
            let gate = try resolveNotesWrite(global, defaultDryRun: false)
            let undisclosed = try applyArgvSelectorGuard(selector, sandboxActive: gate.sandboxActive)
            guard gate.willExecute else {
                let extra = undisclosed ? sandboxTargetUncheckedDetail() : ""
                // Disclose position + separator: a preview that says only "would append" cannot
                // tell the caller that --position before is about to PREPEND instead.
                let where_ = prepend ? "prepend before" : "append after"
                let sepDesc = separator == "\n\n" ? "a blank line" : "\"\(separator)\""
                try emitNotesWrite(DryRunPreview("append", "Would \(where_) the existing body, separated by \(sepDesc). This rewrites the WHOLE body, which can drop embedded attachments — run `notes attachments list` first if unsure. Re-run without --dry-run.\(extra)"),
                                   json: global.json, sandboxActive: gate.sandboxActive,
                                   human: "[dry-run] would append.")
                return
            }
            let script = NotesScript()
            switch selector {
            case .id(let noteId):
                guard let note = try script.getNoteById(id: noteId) else { throw AppleError.notFound("Note with id \"\(noteId)\" not found.") }
                if note.passwordProtected { throw AppleError.validation("Note is password-protected. Unlock it in Notes.app first.") }
                try guardLiveWrite(labeledName: note.title, sandboxActive: gate.sandboxActive)
                let current = try script.getNoteContentById(id: noteId)
                let combined = NotesText.assembleAppend(existingHtml: current, content: content,
                                                        separator: separator, prepend: prepend, html: html)
                try script.updateNoteById(id: noteId, newTitle: nil, newContent: combined, html: true)
                try emitNotesExecutedWrite(UpdatedNote(ok: true, id: noteId, title: note.title, shared: note.shared, warning: nil),
                              json: global.json, sandboxActive: gate.sandboxActive,
                              human: "Appended to \"\(note.title)\".")
            case .title(let noteTitle):
                guard let note = try script.getNoteDetails(title: noteTitle, account: account) else { throw AppleError.notFound("Note \"\(noteTitle)\" not found.") }
                if note.passwordProtected { throw AppleError.validation("Note is password-protected. Unlock it in Notes.app first.") }
                try guardLiveWrite(labeledName: noteTitle, sandboxActive: gate.sandboxActive)
                let current = try script.getNoteContent(title: noteTitle, account: account)
                let combined = NotesText.assembleAppend(existingHtml: current, content: content,
                                                        separator: separator, prepend: prepend, html: html)
                try script.updateNote(title: noteTitle, newTitle: nil, newContent: combined, account: account, html: true)
                try emitNotesExecutedWrite(UpdatedNote(ok: true, id: nil, title: noteTitle, shared: note.shared, warning: nil),
                              json: global.json, sandboxActive: gate.sandboxActive,
                              human: "Appended to \"\(noteTitle)\".")
            }
        }
    }
}

// MARK: delete

struct DeleteCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete",
        abstract: "Delete ONE note to Recently Deleted, by --id or --title (EXECUTES; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Note id (preferred).") var id: String?
    @Option(name: .long, help: "Note title.") var title: String?
    @Option(name: .long, help: "Account (title path only).") var account: String?

    func run() throws {
        try runGuarded(tool: notesTool) {
            let selector = try requireIdOrTitle(id: id, title: title)
            let gate = try resolveNotesWrite(global, defaultDryRun: false)
            let undisclosed = try applyArgvSelectorGuard(selector, sandboxActive: gate.sandboxActive)
            guard gate.willExecute else {
                let extra = undisclosed ? sandboxTargetUncheckedDetail() : ""
                try emitNotesWrite(DryRunPreview("delete-note", "Would delete the target note (Notes.app moves it to Recently Deleted, where it stays recoverable). Re-run without --dry-run.\(extra)"),
                                   json: global.json, sandboxActive: gate.sandboxActive,
                                   human: "[dry-run] would delete.")
                return
            }
            let script = NotesScript()
            switch selector {
            case .id(let noteId):
                guard let note = try script.getNoteById(id: noteId) else { throw AppleError.notFound("Note with id \"\(noteId)\" not found.") }
                try guardLiveWrite(labeledName: note.title, sandboxActive: gate.sandboxActive)
                try script.deleteNoteById(id: noteId)
                try emitNotesExecutedWrite(DeletedNote(ok: true, id: noteId, title: note.title, was_shared: note.shared),
                              json: global.json, sandboxActive: gate.sandboxActive,
                              human: "Deleted \"\(note.title)\".")
            case .title(let noteTitle):
                guard let note = try script.getNoteDetails(title: noteTitle, account: account) else { throw AppleError.notFound("Note \"\(noteTitle)\" not found.") }
                try guardLiveWrite(labeledName: noteTitle, sandboxActive: gate.sandboxActive)
                try script.deleteNote(title: noteTitle, account: account)
                try emitNotesExecutedWrite(DeletedNote(ok: true, id: nil, title: noteTitle, was_shared: note.shared),
                              json: global.json, sandboxActive: gate.sandboxActive,
                              human: "Deleted \"\(noteTitle)\".")
            }
        }
    }
}

// MARK: move

struct MoveCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "move",
        abstract: "Move ONE note to a folder, by --id or --title (EXECUTES; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Note id (preferred).") var id: String?
    @Option(name: .long, help: "Note title.") var title: String?
    @Option(name: .long, help: "Destination folder (must exist).") var folder: String
    @Option(name: .long, help: "Account (title path only).") var account: String?

    func run() throws {
        try runGuarded(tool: notesTool) {
            let selector = try requireIdOrTitle(id: id, title: title)
            let gate = try resolveNotesWrite(global, defaultDryRun: false)
            try requireNonEmptyFolderName(folder)
            // The DESTINATION is argv-supplied, so it is checked on both paths — batch-move
            // already did this and single move did not, which let a sandboxed move drop a
            // labeled test note into a REAL folder.
            try guardLiveWrite(labeledName: folder, sandboxActive: gate.sandboxActive)
            let undisclosed = try applyArgvSelectorGuard(selector, sandboxActive: gate.sandboxActive)
            guard gate.willExecute else {
                let extra = undisclosed ? sandboxTargetUncheckedDetail() : ""
                try emitNotesWrite(DryRunPreview("move-note", "Would move the target note to \"\(folder)\". Re-run without --dry-run.\(extra)"),
                                   json: global.json, sandboxActive: gate.sandboxActive,
                                   human: "[dry-run] would move to \(folder).")
                return
            }
            let script = NotesScript()
            switch selector {
            case .id(let noteId):
                guard let note = try script.getNoteById(id: noteId) else { throw AppleError.notFound("Note with id \"\(noteId)\" not found.") }
                try guardLiveWrite(labeledName: note.title, sandboxActive: gate.sandboxActive)
                try script.moveNoteById(id: noteId, folder: folder, account: account)
                try emitNotesExecutedWrite(MovedNote(ok: true, id: noteId, title: note.title, folder: folder),
                              json: global.json, sandboxActive: gate.sandboxActive,
                              human: "Moved \"\(note.title)\" -> \(folder).")
            case .title(let noteTitle):
                guard let note = try script.getNoteDetails(title: noteTitle, account: account) else { throw AppleError.notFound("Note \"\(noteTitle)\" not found.") }
                try guardLiveWrite(labeledName: noteTitle, sandboxActive: gate.sandboxActive)
                try script.moveNoteById(id: note.id, folder: folder, account: account)
                try emitNotesExecutedWrite(MovedNote(ok: true, id: nil, title: noteTitle, folder: folder),
                              json: global.json, sandboxActive: gate.sandboxActive,
                              human: "Moved \"\(noteTitle)\" -> \(folder).")
            }
        }
    }
}
