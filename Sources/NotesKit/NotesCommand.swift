import ArgumentParser
import Foundation
import AppleKit

/// `apple notes …` — Notes.app.
///
/// Ports `apple-notes-mcp` (@ v2.5.12, 34 tools, MIT) to a strict superset. Mechanism:
/// `AppleScriptRunner` (CRUD/folders/accounts/attachments/export) + `SQLiteReader` over
/// NoteStore.sqlite (checklist protobuf, metadata, sync-status). Hard parts, all ported:
/// gzip+protobuf checklist decode, attachments, HTML↔markdown fidelity, dual id/title
/// addressing. User data always flows to osascript via argv (never interpolated).
///
/// Asana: feat/asana-GID-REDACTED-notes
public struct NotesCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "notes",
        abstract: "Notes — notes/folders/attachments/checklists/export (ports apple-notes-mcp).",
        subcommands: [
            // Notes: read
            GetCmd.self, GetPlaintextCmd.self, GetMarkdownCmd.self, GetByIdCmd.self,
            GetDetailsCmd.self, GetMetadataCmd.self, GetChecklistCmd.self,
            ListCmd.self, SearchCmd.self, SelectedCmd.self,
            // Notes: write
            CreateCmd.self, UpdateCmd.self, AppendCmd.self, DeleteCmd.self, MoveCmd.self,
            // Folders / accounts
            FoldersCmd.self, CreateFolderCmd.self, DeleteFolderCmd.self,
            AccountsCmd.self, DefaultLocationCmd.self, SharedCmd.self,
            // Attachments
            AttachmentsCmd.self, SaveAttachmentCmd.self, FetchAttachmentCmd.self, ShowAttachmentCmd.self,
            // Batch
            BatchDeleteCmd.self, BatchMoveCmd.self,
            // Bulk / diagnostics
            ExportCmd.self, StatsCmd.self, SyncStatusCmd.self, HealthCmd.self, DoctorCmd.self,
            // Reveal in UI
            ShowNoteCmd.self, ShowFolderCmd.self, ShowAccountCmd.self,
        ])
    @OptionGroup public var global: GlobalOptions
    public init() {}
    public func run() throws {
        // Bare `apple notes` prints help (no default operation).
        throw CleanExit.helpRequest(Self.self)
    }
}

// MARK: - Shared command helpers

let notesTool = "notes"

/// Emit either the JSON envelope (default/contract) or a human line (`--text`, not contractual).
func emitNotes<T: Encodable>(_ data: T, json: Bool, human: @autoclosure () -> String) throws {
    if json {
        try Output.emit(tool: notesTool, data: data)
    } else {
        FileHandle.standardOutput.write(Data((human() + "\n").utf8))
    }
}

/// Require exactly one of id/title; return a discriminated selector.
enum NoteSelector { case id(String), title(String) }
func requireIdOrTitle(id: String?, title: String?) throws -> NoteSelector {
    switch (id?.isEmpty == false ? id : nil, title?.isEmpty == false ? title : nil) {
    case let (idVal?, _): return .id(idVal)
    case let (nil, titleVal?): return .title(titleVal)
    default: throw AppleError.validation("Either --id or --title is required.")
    }
}

/// The reference wraps search/list/folders in `withSyncAwareness`, warning when an iCloud sync
/// is in progress (results may be incomplete). apple-cli surfaces the same signal structurally:
/// returns the warning string when sync is active, else nil (the field is then omitted).
func currentSyncWarning() -> String? {
    let status = NotesStore.syncStatus()
    guard status.sync_detected else { return nil }
    return status.warning ?? "iCloud sync is in progress; results may be incomplete or change shortly."
}

/// A generic dry-run preview payload (apple-cli safety extra; not part of MCP parity output).
/// Every write command defaults to dry-run — a real mutation requires `--execute`.
struct DryRunPreview: Encodable {
    let dry_run: Bool
    let operation: String
    let detail: String
    init(_ operation: String, _ detail: String) {
        self.dry_run = true; self.operation = operation; self.detail = detail
    }
}

/// Gate a live write behind test-mode + labeled-target discipline (AGENTS.md Safety). Throws an
/// `AppleError.validation` when the guard is not satisfied, so no mutation reaches Notes.app.
/// `labeledName` is the human name the write targets (a title/folder) when one is available.
func guardLiveWrite(labeledName: String?) throws {
    guard TestMode.isEnabled else {
        throw AppleError.validation("Live write refused: set APPLE_TEST_MODE=1 (and use only labeled "
            + "'\(TestMode.sandboxPrefix)…' test data). Omit --execute to preview safely.")
    }
    if let name = labeledName {
        do { try TestMode.requireLabeledTarget(name) }
        catch let e as TestMode.SandboxError { throw AppleError.validation(e.description) }
        catch { throw AppleError.validation("Target is not a labeled test item.") }
    }
}
