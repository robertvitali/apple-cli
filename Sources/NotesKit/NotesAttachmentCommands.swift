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
        try run(scriptFactory: { NotesScript(store: LiveNotesStore()) })
    }

    /// Dependency-injection seam. `run()` above binds the live boundaries and is the ONLY
    /// binding production uses — no flag or environment variable can select another. See
    /// `NotesStoreReading` for why the seam exists.
    func run(scriptFactory: () -> NotesScript) throws {
        try runGuarded(tool: notesTool) {
            let script = scriptFactory()
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
        abstract: "Write one attachment to disk, path must be under home/temp/Volumes (EXECUTES; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .customLong("note-id"), help: "CoreData note id.") var noteId: String
    @Option(name: .customLong("attachment-id"), help: "Attachment id (from `attachments`).") var attachmentId: String
    @Option(name: .long, help: "Absolute destination path.") var path: String

    func run() throws {
        try run(scriptFactory: { NotesScript(store: LiveNotesStore()) })
    }

    /// Dependency-injection seam. `run()` above binds the live boundaries and is the ONLY
    /// binding production uses — no flag or environment variable can select another. See
    /// `NotesStoreReading` for why the seam exists.
    func run(scriptFactory: () -> NotesScript,
             env: NotesWriteEnv = .live) throws {
        try runGuarded(tool: notesTool) {
            // Bucket-2 obligation (docs/write-model-v2.md): `--dry-run` must actually work on
            // every mutating subcommand. This one mutates the FILESYSTEM rather than Notes.app —
            // it writes attachment bytes to an operator-named path — and it shipped with no
            // willExecute branch at all, so `--dry-run` silently wrote the file anyway. Review
            // of the Notes flip caught it. Routing through `resolveNotesWrite` also gives it the
            // fail-loud env contract (a typo'd APPLE_TEST_MODE now refuses instead of being
            // ignored). No sandbox LABEL check applies: the destination is a path, not a Notes
            // item, and `saveAttachmentById` already confines it to home/temp/Volumes.
            // The home/temp/Volumes confinement is pure string math over argv — no store read,
            // no filesystem access — so it belongs on BOTH paths, and it is the ONLY safety check
            // this command has. Leaving it behind the execute branch made `--dry-run` report
            // clean for a destination the execute path refuses: the exact false-clean signal the
            // rest of this flip works to eliminate.
            // Converted to `validation_error`: an out-of-roots destination is bad INPUT, not an
            // upstream failure, and `FSError` is not an `AppleError` so it would otherwise land
            // as the catch-all `unknown`. Running it here also makes preview and execute agree
            // on the class — the inner call in `saveAttachmentById` stays as defense in depth
            // for the post-mkdir symlink re-check.
            //
            // ORDER: the gate resolves FIRST. `resolveNotesWrite`'s contract is that BOTH v2
            // variables are validated eagerly before any work, so a typo'd `APPLE_TEST_MODE`
            // refuses the command whatever else is wrong with the invocation. Running the path
            // check ahead of it made this the one write surface where a malformed environment
            // could be masked by a second problem in the same command line.
            let gate = try resolveNotesWrite(global, defaultDryRun: false, env: env)
            // The path the write will actually land on: `assertSafeSavePath` returns the
            // normalized spelling (tilde expanded, `.`/`..` resolved, `/private` aliases folded)
            // and `saveAttachmentById` writes THAT, so it is what the preview shows and what the
            // final-leaf symlink check inspects — alongside the raw spelling, because the two can
            // name different leaves (`dir/absent/../leaf` is ENOENT raw, `dir/leaf` normalized)
            // and a symlink planted at either would redirect the bytes.
            let abs: String
            do {
                abs = try AttachmentFS.assertSafeSavePath(path)
                try refuseRawFinalLeafSymlink(path, action: "write the attachment to")
                try refuseRawFinalLeafSymlink(abs, action: "write the attachment to")
            } catch let e as AttachmentFS.FSError {
                throw AppleError.validation(e.description)
            }
            guard gate.willExecute else {
                try emitNotesWrite(DryRunPreview("save-attachment", "Would write attachment \"\(attachmentId)\" of note \"\(noteId)\" to \"\(abs)\". Re-run without --dry-run."),
                                   json: global.json, sandboxActive: gate.sandboxActive,
                                   human: "[dry-run] would save attachment to \(abs).")
                return
            }
            let r = try scriptFactory().saveAttachmentById(noteId: noteId, attachmentId: attachmentId, savePath: path)
            guard r.ok, let savedPath = r.savedPath else {
                throw AppleError.upstream("Failed to save attachment: \(r.error ?? "unknown error")")
            }
            try emitNotesExecutedWrite(SavedAttachment(saved_path: savedPath, name: r.name, content_type: r.contentType),
                               json: global.json, sandboxActive: gate.sandboxActive,
                               human: "Saved \"\(r.name ?? "attachment")\" to \(savedPath).")
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
        try run(scriptFactory: { NotesScript(store: LiveNotesStore()) })
    }

    /// Dependency-injection seam. `run()` above binds the live boundaries and is the ONLY
    /// binding production uses — no flag or environment variable can select another. See
    /// `NotesStoreReading` for why the seam exists.
    func run(scriptFactory: () -> NotesScript) throws {
        try runGuarded(tool: notesTool) {
            let r = try scriptFactory().fetchAttachmentBase64(noteId: noteId, attachmentId: attachmentId)
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
        try run(scriptFactory: { NotesScript(store: LiveNotesStore()) })
    }

    /// Dependency-injection seam. `run()` above binds the live boundaries and is the ONLY
    /// binding production uses — no flag or environment variable can select another. See
    /// `NotesStoreReading` for why the seam exists.
    func run(scriptFactory: () -> NotesScript) throws {
        try runGuarded(tool: notesTool) {
            try scriptFactory().showAttachment(noteId: noteId, attachmentId: attachmentId, separately: separately)
            try emitNotes(ShownAttachment(note_id: noteId, attachment_id: attachmentId, separately: separately),
                          json: global.json, human: "Shown attachment \"\(attachmentId)\".")
        }
    }
}
