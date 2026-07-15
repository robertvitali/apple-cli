import ArgumentParser
import AppleKit

/// `apple notes …` — Notes.app.
///
/// Ports `apple-notes-mcp` (@ v2.5.12, 34 tools, MIT) to a strict superset. Mechanism:
/// `AppleScriptRunner` (CRUD/folders/accounts/attachments/export) + `SQLiteReader` over
/// NoteStore.sqlite (checklist protobuf, metadata, sync-status). Hard parts: gzip+protobuf
/// checklist decode, attachments, HTML↔markdown fidelity, dual id/title addressing.
///
/// Asana: feat/asana-GID-REDACTED-notes
public struct NotesCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "notes",
        abstract: "Notes — notes/folders/attachments/checklists/export (ports apple-notes-mcp).",
        subcommands: []
    )
    @OptionGroup public var global: GlobalOptions
    public init() {}
    public func run() throws {
        try runGuarded(tool: "notes") {
            throw AppleError.notImplemented("notes domain not yet implemented — see feat/asana-GID-REDACTED-notes")
        }
    }
}
