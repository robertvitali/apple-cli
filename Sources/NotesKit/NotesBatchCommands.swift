import ArgumentParser
import Foundation
import AppleKit

// Batch commands. Under write-model v2 both EXECUTE when invoked (--dry-run previews), matching
// the oracle. INSIDE the opt-in sandbox each target id is resolved first and every title must be
// a labeled `apple-cli-test…` item, so a sandboxed batch can never touch real data; outside it
// the confinement does not apply, because the oracle has no counterpart gate.

private let maxBatchIds = 500

/// In execute mode, resolve every id and confirm its title is a labeled test target. Any real
/// (unlabeled) or unresolvable target aborts the whole batch before a single mutation runs.
private func verifyBatchTargetsLabeled(_ ids: [String], _ script: NotesScript, sandboxActive: Bool) throws {
    guard sandboxActive else { return }
    for id in ids {
        guard let note = try script.getNoteById(id: id) else {
            throw AppleError.notFound("Batch aborted: note id \"\(id)\" not found (cannot verify it is test data).")
        }
        try guardLiveWrite(labeledName: note.title, sandboxActive: sandboxActive)
    }
}

// MARK: batch-delete

struct BatchDeleteCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "batch-delete",
        abstract: "Delete multiple notes by id to Recently Deleted, ≤500 (EXECUTES; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, parsing: .upToNextOption, help: "Note ids to delete.") var ids: [String]

    func run() throws {
        try runGuarded(tool: notesTool) {
            guard !ids.isEmpty else { throw AppleError.validation("No note ids provided (--ids).") }
            guard ids.count <= maxBatchIds else { throw AppleError.validation("Too many ids (max \(maxBatchIds)).") }
            let gate = try resolveNotesWrite(global)
            guard gate.willExecute else {
                let extra = gate.sandboxActive ? sandboxTargetUncheckedDetail() : ""
                try emitNotesWrite(DryRunPreview("batch-delete-notes", "Would delete \(ids.count) note(s) (Notes.app moves them to Recently Deleted, where they stay recoverable). Re-run without --dry-run.\(extra)"),
                                   json: global.json, sandboxActive: gate.sandboxActive,
                                   human: "[dry-run] would delete \(ids.count) note(s).")
                return
            }
            let script = NotesScript()
            try verifyBatchTargetsLabeled(ids, script, sandboxActive: gate.sandboxActive)
            let results = script.batchDeleteNotes(ids: ids)
            let succeeded = results.filter { $0.success }.count
            let failed = results.count - succeeded
            try emitNotesWrite(BatchDeleteResult(ok: failed == 0, succeeded: succeeded, failed: failed, results: results),
                               json: global.json, sandboxActive: gate.sandboxActive,
                               human: "Batch delete: \(succeeded) succeeded, \(failed) failed.")
        }
    }
}

// MARK: batch-move

struct BatchMoveCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "batch-move",
        abstract: "Move multiple notes by id to one folder, ≤500 (EXECUTES; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, parsing: .upToNextOption, help: "Note ids to move.") var ids: [String]
    @Option(name: .long, help: "Destination folder (must exist).") var folder: String
    @Option(name: .long, help: "Account (defaults to iCloud).") var account: String?

    func run() throws {
        try runGuarded(tool: notesTool) {
            guard !ids.isEmpty else { throw AppleError.validation("No note ids provided (--ids).") }
            guard ids.count <= maxBatchIds else { throw AppleError.validation("Too many ids (max \(maxBatchIds)).") }
            try requireNonEmptyFolderName(folder)
            let gate = try resolveNotesWrite(global)
            // The destination folder comes from argv, so its label check is computable here and
            // runs on BOTH paths — a sandboxed preview refuses a real destination exactly as
            // execute would, without touching Notes.app.
            try guardLiveWrite(labeledName: folder, sandboxActive: gate.sandboxActive)
            guard gate.willExecute else {
                let extra = gate.sandboxActive ? sandboxTargetUncheckedDetail() : ""
                try emitNotesWrite(DryRunPreview("batch-move-notes", "Would move \(ids.count) note(s) to \"\(folder)\". Re-run without --dry-run.\(extra)"),
                                   json: global.json, sandboxActive: gate.sandboxActive,
                                   human: "[dry-run] would move \(ids.count) note(s) to \(folder).")
                return
            }
            let script = NotesScript()
            try verifyBatchTargetsLabeled(ids, script, sandboxActive: gate.sandboxActive)
            let results = script.batchMoveNotes(ids: ids, folder: folder, account: account)
            let succeeded = results.filter { $0.success }.count
            let failed = results.count - succeeded
            try emitNotesWrite(BatchMoveResult(ok: failed == 0, folder: folder, succeeded: succeeded, failed: failed, results: results),
                               json: global.json, sandboxActive: gate.sandboxActive,
                               human: "Batch move to \"\(folder)\": \(succeeded) succeeded, \(failed) failed.")
        }
    }
}
