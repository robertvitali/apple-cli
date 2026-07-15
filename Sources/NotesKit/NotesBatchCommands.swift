import ArgumentParser
import Foundation
import AppleKit

// Batch commands. Both default to dry-run. Live execution additionally verifies EACH target note
// resolves to a labeled `apple-cli-test…` title (test-mode), so a batch can never touch real data.

private let maxBatchIds = 500

/// In execute mode, resolve every id and confirm its title is a labeled test target. Any real
/// (unlabeled) or unresolvable target aborts the whole batch before a single mutation runs.
private func verifyBatchTargetsLabeled(_ ids: [String], _ script: NotesScript) throws {
    try guardLiveWrite(labeledName: nil) // require APPLE_TEST_MODE
    for id in ids {
        guard let note = try script.getNoteById(id: id) else {
            throw AppleError.notFound("Batch aborted: note id \"\(id)\" not found (cannot verify it is test data).")
        }
        try guardLiveWrite(labeledName: note.title)
    }
}

// MARK: batch-delete

struct BatchDeleteCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "batch-delete",
        abstract: "Permanently delete multiple notes by id (≤500). Dry-run unless --execute.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, parsing: .upToNextOption, help: "Note ids to delete.") var ids: [String]

    func run() throws {
        try runGuarded(tool: notesTool) {
            guard !ids.isEmpty else { throw AppleError.validation("No note ids provided (--ids).") }
            guard ids.count <= maxBatchIds else { throw AppleError.validation("Too many ids (max \(maxBatchIds)).") }
            guard global.willExecute else {
                try emitNotes(DryRunPreview("batch-delete-notes", "Would PERMANENTLY delete \(ids.count) note(s). Re-run with --execute."),
                              json: global.json, human: "[dry-run] would delete \(ids.count) note(s).")
                return
            }
            let script = NotesScript()
            try verifyBatchTargetsLabeled(ids, script)
            let results = script.batchDeleteNotes(ids: ids)
            let succeeded = results.filter { $0.success }.count
            let failed = results.count - succeeded
            try emitNotes(BatchDeleteResult(ok: failed == 0, succeeded: succeeded, failed: failed, results: results),
                          json: global.json, human: "Batch delete: \(succeeded) succeeded, \(failed) failed.")
        }
    }
}

// MARK: batch-move

struct BatchMoveCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "batch-move",
        abstract: "Move multiple notes by id to one folder (≤500). Dry-run unless --execute.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, parsing: .upToNextOption, help: "Note ids to move.") var ids: [String]
    @Option(name: .long, help: "Destination folder (must exist).") var folder: String
    @Option(name: .long, help: "Account (defaults to iCloud).") var account: String?

    func run() throws {
        try runGuarded(tool: notesTool) {
            guard !ids.isEmpty else { throw AppleError.validation("No note ids provided (--ids).") }
            guard ids.count <= maxBatchIds else { throw AppleError.validation("Too many ids (max \(maxBatchIds)).") }
            guard global.willExecute else {
                try emitNotes(DryRunPreview("batch-move-notes", "Would move \(ids.count) note(s) to \"\(folder)\". Re-run with --execute."),
                              json: global.json, human: "[dry-run] would move \(ids.count) note(s) to \(folder).")
                return
            }
            let script = NotesScript()
            try verifyBatchTargetsLabeled(ids, script)
            try guardLiveWrite(labeledName: folder) // destination must also be a labeled test folder
            let results = script.batchMoveNotes(ids: ids, folder: folder, account: account)
            let succeeded = results.filter { $0.success }.count
            let failed = results.count - succeeded
            try emitNotes(BatchMoveResult(ok: failed == 0, folder: folder, succeeded: succeeded, failed: failed, results: results),
                          json: global.json, human: "Batch move to \"\(folder)\": \(succeeded) succeeded, \(failed) failed.")
        }
    }
}
