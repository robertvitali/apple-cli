import ArgumentParser
import Foundation
import AppleKit

// Write commands. ALL default to dry-run (a preview, zero side effects); a real mutation
// requires `--execute` AND passes `guardLiveWrite` (APPLE_TEST_MODE + labeled test target).

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
        abstract: "Create a note (title prepended as <h1>). Dry-run unless --execute.")
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
            guard global.willExecute else {
                let folderInfo = folder.map { " in \($0)" } ?? ""
                try emitNotes(DryRunPreview("create-note", "Would create \"\(title)\"\(folderInfo) (format: \(format)). Re-run with --execute."),
                              json: global.json, human: "[dry-run] would create \"\(title)\".")
                return
            }
            try guardLiveWrite(labeledName: title)
            let id = try NotesScript().createNote(title: title, content: content, folder: folder, account: account, html: html)
            try emitNotes(CreatedNote(ok: true, id: id, title: title, folder: folder, account: account),
                          json: global.json, human: "Created \"\(title)\" [\(id)].")
        }
    }
}

// MARK: update

struct UpdateCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update",
        abstract: "REPLACE a note's body (and optional title), by --id or --title. Dry-run unless --execute.")
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
            guard global.willExecute else {
                try emitNotes(DryRunPreview("update-note", "Would REPLACE the body of the target note (format: \(format)). Re-run with --execute."),
                              json: global.json, human: "[dry-run] would replace body.")
                return
            }
            let script = NotesScript()
            switch selector {
            case .id(let noteId):
                guard let note = try script.getNoteById(id: noteId) else { throw AppleError.notFound("Note with id \"\(noteId)\" not found.") }
                if note.passwordProtected { throw AppleError.validation("Note is password-protected. Unlock it in Notes.app first.") }
                try guardLiveWrite(labeledName: note.title)
                try script.updateNoteById(id: noteId, newTitle: newTitle, newContent: newContent, html: html)
                let displayTitle = (newTitle?.isEmpty == false) ? newTitle! : note.title
                try emitNotes(UpdatedNote(ok: true, id: noteId, title: displayTitle, shared: note.shared),
                              json: global.json, human: "Updated \"\(displayTitle)\".")
            case .title(let noteTitle):
                guard let note = try script.getNoteDetails(title: noteTitle, account: account) else { throw AppleError.notFound("Note \"\(noteTitle)\" not found.") }
                if note.passwordProtected { throw AppleError.validation("Note is password-protected. Unlock it in Notes.app first.") }
                try guardLiveWrite(labeledName: noteTitle)
                try script.updateNote(title: noteTitle, newTitle: newTitle, newContent: newContent, account: account, html: html)
                let finalTitle = (newTitle?.isEmpty == false) ? newTitle! : noteTitle
                try emitNotes(UpdatedNote(ok: true, id: nil, title: finalTitle, shared: note.shared),
                              json: global.json, human: "Updated \"\(finalTitle)\".")
            }
        }
    }
}

// MARK: append (curated extra — non-replace edit)

struct AppendCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "append",
        abstract: "Append content to a note WITHOUT replacing its body (apple-cli extra). Dry-run unless --execute.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Note id (preferred).") var id: String?
    @Option(name: .long, help: "Note title.") var title: String?
    @Option(name: .long, help: "Content to append.") var content: String
    @Option(name: .long, help: "Content format: plaintext|html.") var format: String = "plaintext"
    @Option(name: .long, help: "Account (title path only).") var account: String?

    func run() throws {
        try runGuarded(tool: notesTool) {
            let html = try validateFormat(format)
            try validateBounds(content: content, account: account)
            let selector = try requireIdOrTitle(id: id, title: title)
            guard global.willExecute else {
                try emitNotes(DryRunPreview("append", "Would append content to the target note (existing body preserved). Re-run with --execute."),
                              json: global.json, human: "[dry-run] would append.")
                return
            }
            let script = NotesScript()
            // Fragment appended: raw HTML in html mode, else escaped in a <div>.
            let appendFragment = html ? content : "<div>\(NotesText.updateEscape(content))</div>"
            switch selector {
            case .id(let noteId):
                guard let note = try script.getNoteById(id: noteId) else { throw AppleError.notFound("Note with id \"\(noteId)\" not found.") }
                if note.passwordProtected { throw AppleError.validation("Note is password-protected. Unlock it in Notes.app first.") }
                try guardLiveWrite(labeledName: note.title)
                let current = try script.getNoteContentById(id: noteId)
                try script.updateNoteById(id: noteId, newTitle: nil, newContent: current + appendFragment, html: true)
                try emitNotes(UpdatedNote(ok: true, id: noteId, title: note.title, shared: note.shared),
                              json: global.json, human: "Appended to \"\(note.title)\".")
            case .title(let noteTitle):
                guard let note = try script.getNoteDetails(title: noteTitle, account: account) else { throw AppleError.notFound("Note \"\(noteTitle)\" not found.") }
                if note.passwordProtected { throw AppleError.validation("Note is password-protected. Unlock it in Notes.app first.") }
                try guardLiveWrite(labeledName: noteTitle)
                let current = try script.getNoteContent(title: noteTitle, account: account)
                try script.updateNote(title: noteTitle, newTitle: nil, newContent: current + appendFragment, account: account, html: true)
                try emitNotes(UpdatedNote(ok: true, id: nil, title: noteTitle, shared: note.shared),
                              json: global.json, human: "Appended to \"\(noteTitle)\".")
            }
        }
    }
}

// MARK: delete

struct DeleteCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete",
        abstract: "Permanently delete ONE note, by --id or --title. Dry-run unless --execute.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Note id (preferred).") var id: String?
    @Option(name: .long, help: "Note title.") var title: String?
    @Option(name: .long, help: "Account (title path only).") var account: String?

    func run() throws {
        try runGuarded(tool: notesTool) {
            let selector = try requireIdOrTitle(id: id, title: title)
            guard global.willExecute else {
                try emitNotes(DryRunPreview("delete-note", "Would PERMANENTLY delete the target note. Re-run with --execute."),
                              json: global.json, human: "[dry-run] would delete.")
                return
            }
            let script = NotesScript()
            switch selector {
            case .id(let noteId):
                guard let note = try script.getNoteById(id: noteId) else { throw AppleError.notFound("Note with id \"\(noteId)\" not found.") }
                try guardLiveWrite(labeledName: note.title)
                try script.deleteNoteById(id: noteId)
                try emitNotes(DeletedNote(ok: true, id: noteId, title: note.title, was_shared: note.shared),
                              json: global.json, human: "Deleted \"\(note.title)\".")
            case .title(let noteTitle):
                guard let note = try script.getNoteDetails(title: noteTitle, account: account) else { throw AppleError.notFound("Note \"\(noteTitle)\" not found.") }
                try guardLiveWrite(labeledName: noteTitle)
                try script.deleteNote(title: noteTitle, account: account)
                try emitNotes(DeletedNote(ok: true, id: nil, title: noteTitle, was_shared: note.shared),
                              json: global.json, human: "Deleted \"\(noteTitle)\".")
            }
        }
    }
}

// MARK: move

struct MoveCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "move",
        abstract: "Move ONE note to a folder, by --id or --title. Dry-run unless --execute.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Note id (preferred).") var id: String?
    @Option(name: .long, help: "Note title.") var title: String?
    @Option(name: .long, help: "Destination folder (must exist).") var folder: String
    @Option(name: .long, help: "Account (title path only).") var account: String?

    func run() throws {
        try runGuarded(tool: notesTool) {
            let selector = try requireIdOrTitle(id: id, title: title)
            guard global.willExecute else {
                try emitNotes(DryRunPreview("move-note", "Would move the target note to \"\(folder)\". Re-run with --execute."),
                              json: global.json, human: "[dry-run] would move to \(folder).")
                return
            }
            let script = NotesScript()
            switch selector {
            case .id(let noteId):
                guard let note = try script.getNoteById(id: noteId) else { throw AppleError.notFound("Note with id \"\(noteId)\" not found.") }
                try guardLiveWrite(labeledName: note.title)
                try script.moveNoteById(id: noteId, folder: folder, account: account)
                try emitNotes(MovedNote(ok: true, id: noteId, title: note.title, folder: folder),
                              json: global.json, human: "Moved \"\(note.title)\" -> \(folder).")
            case .title(let noteTitle):
                guard let note = try script.getNoteDetails(title: noteTitle, account: account) else { throw AppleError.notFound("Note \"\(noteTitle)\" not found.") }
                try guardLiveWrite(labeledName: noteTitle)
                try script.moveNoteById(id: note.id, folder: folder, account: account)
                try emitNotes(MovedNote(ok: true, id: nil, title: noteTitle, folder: folder),
                              json: global.json, human: "Moved \"\(noteTitle)\" -> \(folder).")
            }
        }
    }
}
