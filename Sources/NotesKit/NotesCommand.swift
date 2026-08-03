import ArgumentParser
import Foundation
import AppleKit

/// `apple notes …` — Notes.app.
///
/// Ports `apple-notes-mcp` to a strict superset. The spec was written against v2.5.12 (34
/// tools); the oracle INSTALLED on this fleet is v2.6.12 (36 tools, +append-to-note
/// +get-note-link), and nothing pins or drift-checks the two — see COMPLETION-LOOP Q20.
/// MIT. Mechanism:
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
            GetNoteLinkCmd.self,
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

/// Write-path emit. `sandboxActive` is REQUIRED — no default — so a write can never silently
/// under-report the sandbox in its envelope. (`Output.emit` defaults the parameter for the read
/// path's benefit, which would let an omission here compile; docs/write-model-v2.md names that
/// as the flip-commit residual risk, and a required label is what removes it.) `--text` shows
/// the sandbox too: a human has the same need to know the write was confined as a machine does.
func emitNotesWrite<T: Encodable>(_ data: T, json: Bool, sandboxActive: Bool,
                                  human: @autoclosure () -> String) throws {
    if json {
        try Output.emit(tool: notesTool, data: data, sandboxActive: sandboxActive)
    } else {
        let line = (sandboxActive ? "[sandbox] " : "") + human()
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

// MARK: - Write-model v2 gate (docs/write-model-v2.md)

/// The resolved write posture for one notes command. Bound ONCE at the top of every write
/// `run()` and threaded from there — never re-derived mid-command.
struct NotesWriteGate {
    let willExecute: Bool
    let sandboxActive: Bool
}

/// Resolve a notes write under write-model v2: **it executes by default**, exactly as calling
/// the equivalent apple-notes-mcp tool does. `--dry-run` previews; `APPLE_DRY_RUN` truthy
/// restores dry-run-by-default.
///
/// Notes is the simplest of the six mappings: the oracle ENFORCES no write gate of any kind, so
/// every Notes write op is bucket 3 (CLI-only restriction → sandbox-only) with no bucket-1 hard
/// gate to keep — unlike Contacts, which keeps two.
///
/// EVIDENCE (re-derived; the first version of this comment cited a grep of `dist/` and `src/`,
/// directories the shipped package does not contain — that grep matched nothing *vacuously* and
/// proved nothing. Reviewers caught it. The real package ships a single bundle,
/// `apple-notes-mcp/build/index.js`):
///   - the ONLY `process.env` reads in the whole bundle are `DEBUG` and `VERBOSE`, so no
///     test-mode/confirmation environment variable exists to mirror;
///   - every `elicit*` hit is bundled MCP-SDK protocol schema, not server code — the Notes
///     server never issues an elicitation (contrast Mail's oracle A, which wraps six tools in
///     `_elicit_confirmation`);
///   - `delete-note`'s handler goes straight from `getNoteById` to `deleteNoteById` with no
///     gate. Its description does say "Safety: requires explicit user confirmation before
///     deleting", but that is ADVISORY PROSE aimed at the calling model, not server-side
///     enforcement — nothing checks it.
///
/// RECOVERABILITY IS PER-OP, not domain-wide — the first version of this comment generalised a
/// single note-delete observation across every delete here, and that was wrong. Measured live:
///   - `delete` / `batch-delete` use `delete <noteRef>`; the note lands in Recently Deleted and
///     is still findable there afterwards. RECOVERABLE.
///   - `delete-folder` CASCADES and the cascade is PERMANENT. A labeled folder containing a
///     labeled note was deleted; the folder went, the note went, and a store-wide search found
///     ZERO hits — while the control note deleted the other way was still sitting in Recently
///     Deleted in the same run. It also does NOT refuse a non-empty folder, contrary to what
///     this port's own help text and port-spec claimed (both inherited an assertion the
///     oracle's source only ever HEDGED as "may fail").
/// So `delete-folder` is an irreversible wholesale erase of real data, and it gets the
/// per-surface dry-run default described on `DeleteFolderCmd`.
/// `defaultDryRun` is per-SURFACE and has no default value — every caller states its own, the
/// same discipline the Mail trash surface established. General Notes writes pass `false`
/// (execute-by-default, oracle parity); `delete-folder` passes `true`, see
/// `DeleteFolderCmd.surfaceDefaultDryRun`.
func resolveNotesWrite(_ global: GlobalOptions, defaultDryRun: Bool = false) throws -> NotesWriteGate {
    try TestMode.validateWriteEnvironment()
    let sandboxActive = try TestMode.sandboxActive(flag: global.testMode)
    let willExecute = try global.willExecute(defaultDryRun: defaultDryRun)
    return NotesWriteGate(willExecute: willExecute, sandboxActive: sandboxActive)
}

/// Apply the sandbox label check for the part of a selector that is argv-computable, and report
/// whether a store-read check still remains.
///
/// `--title` addressing supplies the target's name in argv, and the execute path checks exactly
/// that string — so the check belongs on BOTH paths and a preview has no excuse to skip it.
/// Only `--id` addressing needs Notes.app to learn the title. Getting this wrong in the first
/// cut of the flip meant a sandboxed `--title` preview reported clean for a write the execute
/// path refuses, AND explained itself with a reason that did not apply.
///
/// Returns true when the preview must disclose an unchecked fetched-target gate.
func applyArgvSelectorGuard(_ selector: NoteSelector, sandboxActive: Bool,
                            prefix: String? = nil) throws -> Bool {
    switch selector {
    case .title(let t):
        try guardLiveWrite(labeledName: t, sandboxActive: sandboxActive, prefix: prefix)
        return false // fully checked from argv — nothing left to disclose
    case .id:
        return sandboxActive // the title lives in Notes.app; only the execute path can check it
    }
}

/// The `detail` suffix a SANDBOXED preview adds when the label check it would face on the
/// execute path cannot run here — the target's title comes from a store read, and a preview
/// deliberately does not touch Notes.app. Says so rather than implying the check passed.
func sandboxTargetUncheckedDetail() -> String {
    " Sandbox is engaged: the execute path additionally requires the target to be a labeled "
    + "'\(TestMode.sandboxPrefix)…' item. That check reads Notes.app, so this preview did not run it."
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

/// SANDBOX target confinement (write-model v2). Outside the sandbox this is a NO-OP — the
/// oracle has no counterpart gate (see `resolveNotesWrite`), so under v2 a Notes write reaches
/// whatever the caller named, exactly as the MCP tool does. Inside the sandbox the target must
/// be a labeled `apple-cli-test…` item.
///
/// `sandboxActive` is a PARAMETER, never re-read from the environment here: the flag-only path
/// (`--test-mode` with no env var) must engage the same confinement, and an internal
/// `TestMode.isEnabled` re-check — which is what v1 did — would silently skip it.
/// Refusals stay `AppleError.validation` (exit 64), the per-domain refusal type for Notes.
///
/// `prefix` is a logic-tier seam: `TestMode.sandboxPrefix` reads `APPLE_TEST_SANDBOX` from the
/// PROCESS environment, and swift-testing runs every suite in one process — `MailKitTests`
/// setenv()s that variable mid-run. A test with hard-coded expectations must pin the prefix
/// instead of inheriting whatever another suite last wrote. Production callers never pass it.
func guardLiveWrite(labeledName: String?, sandboxActive: Bool, prefix: String? = nil) throws {
    guard sandboxActive, let name = labeledName else { return }
    let required = prefix ?? TestMode.sandboxPrefix
    guard name.hasPrefix(required) else {
        throw AppleError.validation(
            "Sandbox is engaged: refusing to write to \"\(name)\" — the target must be a labeled "
            + "'\(required)…' test item.")
    }
}
