import ArgumentParser
import Foundation
import AppleKit

// Attachment commands. `save`/`fetch` export bytes (read-side); `show` reveals in the UI. None
// mutate note data, so they don't require --execute (save is path-guarded to home/temp/Volumes).

// MARK: attachments (list)

struct AttachmentsCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "attachments",
        abstract: "List a note's attachments (name, content type, id), by --id or --title.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Note id (preferred).") var id: String?
    @Option(name: .long, help: "Note title.") var title: String?
    @Option(name: .long, help: "Account (title path only).") var account: String?

    func run() throws {
        try runGuarded(tool: notesTool) {
            let script = NotesScript()
            let selector = try requireIdOrTitle(id: id, title: title)
            let attachments: [Attachment]
            switch selector {
            case .id(let noteId):
                guard (try script.getNoteById(id: noteId)) != nil else { throw AppleError.notFound("Note with id \"\(noteId)\" not found.") }
                attachments = try script.listAttachmentsById(id: noteId)
            case .title(let noteTitle):
                guard (try script.getNoteDetails(title: noteTitle, account: account)) != nil else { throw AppleError.notFound("Note \"\(noteTitle)\" not found.") }
                attachments = try script.listAttachments(title: noteTitle, account: account)
            }
            try emitNotes(AttachmentList(attachments: attachments, count: attachments.count), json: global.json,
                human: attachments.isEmpty ? "No attachments." : attachments.map { "  - \($0.name) (\($0.content_type))" }.joined(separator: "\n"))
        }
    }
}

// MARK: save-attachment (bytes → disk, path-guarded)

struct SaveAttachmentCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "save-attachment",
        abstract: "Write one attachment to disk (path must be under home, temp, or /Volumes).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .customLong("note-id"), help: "CoreData note id.") var noteId: String
    @Option(name: .customLong("attachment-id"), help: "Attachment id (from `attachments`).") var attachmentId: String
    @Option(name: .long, help: "Absolute destination path.") var path: String

    func run() throws {
        try runGuarded(tool: notesTool) {
            let r = try NotesScript().saveAttachmentById(noteId: noteId, attachmentId: attachmentId, savePath: path)
            guard r.ok, let savedPath = r.savedPath else {
                throw AppleError.upstream("Failed to save attachment: \(r.error ?? "unknown error")")
            }
            try emitNotes(SavedAttachment(saved_path: savedPath, name: r.name, content_type: r.contentType),
                          json: global.json, human: "Saved \"\(r.name ?? "attachment")\" to \(savedPath).")
        }
    }
}

// MARK: fetch-attachment (base64 inline)

struct FetchAttachmentCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "fetch-attachment",
        abstract: "Return one attachment's bytes inline as base64 (25 MB cap).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .customLong("note-id"), help: "CoreData note id.") var noteId: String
    @Option(name: .customLong("attachment-id"), help: "Attachment id (from `attachments`).") var attachmentId: String

    func run() throws {
        try runGuarded(tool: notesTool) {
            let r = try NotesScript().fetchAttachmentBase64(noteId: noteId, attachmentId: attachmentId)
            guard r.ok, let base64 = r.base64 else {
                throw AppleError.upstream("Failed to fetch attachment: \(r.error ?? "unknown error")")
            }
            try emitNotes(FetchedAttachment(name: r.name, content_type: r.contentType, bytes: r.bytes, base64: base64),
                          json: global.json, human: "Fetched \"\(r.name ?? "attachment")\" (\(r.bytes ?? 0) bytes).")
        }
    }
}

// MARK: show-attachment (reveal in UI)

struct ShowAttachmentCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show-attachment",
        abstract: "Reveal an attachment in the Notes.app UI.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .customLong("note-id"), help: "CoreData note id.") var noteId: String
    @Option(name: .customLong("attachment-id"), help: "Attachment id.") var attachmentId: String
    @Flag(name: .long, help: "Open in a separate window.") var separately = false

    func run() throws {
        try runGuarded(tool: notesTool) {
            try NotesScript().showAttachment(noteId: noteId, attachmentId: attachmentId, separately: separately)
            try emitNotes(ShownAttachment(note_id: noteId, attachment_id: attachmentId, separately: separately),
                          json: global.json, human: "Shown attachment \"\(attachmentId)\".")
        }
    }
}
