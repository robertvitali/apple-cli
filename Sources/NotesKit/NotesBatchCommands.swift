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
private func verifyBatchTargetsLabeled(_ ids: [String], _ script: NotesScript, sandboxActive: Bool,
                                       prefix: String? = nil) throws {
    guard sandboxActive else { return }
    for id in ids {
        guard let note = try script.getNoteById(id: id) else {
            throw AppleError.notFound("Batch aborted: note id \"\(id)\" not found (cannot verify it is test data).")
        }
        try guardLiveWrite(labeledName: note.title, sandboxActive: sandboxActive, prefix: prefix)
    }
}

/// A batch in which NOTHING succeeded is an error, not a success carrying `ok: false` (NOTES-L3).
///
/// The oracle's two batch tools both end (`build/index.js`, `batch-delete-notes` and
/// `batch-move-notes` handlers):
///
/// ```js
/// return succeeded > 0
///   ? successResponse(lines.join("\n"), { ok: failed === 0, succeeded, failed, results })
///   : errorResponse(lines.join("\n"));
/// ```
///
/// so its behaviour is three-way, not two-way: all-succeeded is a success with `ok:true`, PARTIAL
/// is a success with `ok:false`, and **zero-succeeded is an error response**. We already matched
/// the first two — the payload's `ok` was correctly `failed == 0`. What we got wrong was the third:
/// a batch where every single id failed still emitted a success envelope and exit 0. An agent
/// checking the envelope's `ok` (the documented way to test whether a command worked) was told the
/// delete succeeded when nothing had been deleted. That is worse than a plain bug: it is a lie in
/// the field the contract designates for exactly this question.
///
/// NOTE the gap was filed as "still exits 0 with ok:true", which is half right. `data.ok` was
/// already `false`; the defect was the ENVELOPE ok and the exit code.
///
/// ERROR TYPE — ONE type, matching the oracle, after a first attempt got this badly wrong.
///
/// That attempt classified: `not_found` when every per-item message said "not found", else
/// `unknown`. Three reviewers took it apart and the decisive objection was not the one I expected.
/// It is not that the split invents a distinction the oracle lacks (though it does) — it is that
/// **the correct type was already computed twenty lines earlier and thrown away.**
/// `batchDeleteNotes` / `batchMoveNotes` catch a properly-typed `AppleError` on a whole-script
/// failure and flatten it to a bare `String` stamped onto every item, so re-deriving a type from
/// that string is guessing at something we already knew. And the guess inverted almost everywhere
/// it mattered:
///
/// - a TCC denial became `unknown`/70, DROPPING the `status` + `remediation` keys that `b6230ed`
///   had just added to the error envelope for exactly this case;
/// - a timeout, correctly `upstream`/69 upstream, became 70;
/// - a batch of entirely malformed ids became 70 — an internal-error signal for what is
///   unambiguously caller-side, and the signal most likely to send an agent into a retry loop;
/// - a genuine AppleScript not-found became 70, because its message is
///   "Notes could not find the requested item…" (`NotesScript.swift:83`) — no literal "not found".
///
/// So `not_found` fired for exactly one condition (per-item status `missing`) and mis-fired for the
/// rest. Substring-sniffing a wire contract out of prose was the error; `localizedCaseInsensitive`
/// then let the operator's locale vote on it.
///
/// `upstream` is the single type: it is what six sibling sites in NotesKit already throw for an
/// operation that ran and failed, and it never claims more than is known. Every per-item reason
/// survives verbatim in the message, which is exactly what the oracle's `errorResponse` carries and
/// all it carries — it has no `structured` parameter at all (`build/index.js:42088`), so nothing it
/// returns is lost.
///
/// The flattening itself — a typed `AppleError` reduced to a string, losing TCC status/remediation
/// on this path — is a real, PRE-EXISTING defect this change surfaced rather than caused. It is
/// filed separately rather than fixed here.
func requireAnyBatchSuccess(_ results: [BatchItemResult], verb: String, folder: String? = nil) throws {
    guard !results.isEmpty, results.allSatisfy({ !$0.success }) else { return }
    // The oracle's `lines`, shape-for-shape — and note the move variant names the destination:
    // `Batch move to "${folder}": ${succeeded} succeeded, ${failed} failed`.
    let scope = folder.map { " to \"\($0)\"" } ?? ""
    let failures = results.map { "  - \($0.id): \($0.error ?? "unknown error")" }.joined(separator: "\n")
    throw AppleError.upstream(
        "Batch \(verb)\(scope): 0 succeeded, \(results.count) failed\n\nFailures:\n\(failures)")
}

// MARK: batch-delete

struct BatchDeleteCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "batch-delete",
        abstract: "Delete multiple notes by id to Recently Deleted, ≤500 (EXECUTES; --dry-run previews).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, parsing: .upToNextOption, help: "Note ids to delete.") var ids: [String]

    func run() throws {
        try run(scriptFactory: { NotesScript(store: LiveNotesStore()) })
    }

    /// Dependency-injection seam. `run()` above binds the live boundaries and is the ONLY
    /// binding production uses — no flag or environment variable can select another. See
    /// `NotesStoreReading` for why the seam exists.
    func run(scriptFactory: () -> NotesScript,
             env: NotesWriteEnv = .live) throws {
        try runGuarded(tool: notesTool) {
            guard !ids.isEmpty else { throw AppleError.validation("No note ids provided (--ids).") }
            guard ids.count <= maxBatchIds else { throw AppleError.validation("Too many ids (max \(maxBatchIds)).") }
            let gate = try resolveNotesWrite(global, defaultDryRun: false, env: env)
            guard gate.willExecute else {
                let extra = gate.sandboxActive ? sandboxTargetUncheckedDetail(prefix: env.sandboxPrefix) : ""
                try emitNotesWrite(DryRunPreview("batch-delete-notes", "Would delete \(ids.count) note(s) (Notes.app moves them to Recently Deleted, where they stay recoverable). Re-run without --dry-run.\(extra)"),
                                   json: global.json, sandboxActive: gate.sandboxActive,
                                   human: "[dry-run] would delete \(ids.count) note(s).")
                return
            }
            let script = scriptFactory()
            try verifyBatchTargetsLabeled(ids, script, sandboxActive: gate.sandboxActive, prefix: env.sandboxPrefix)
            let results = try script.batchDeleteNotes(ids: ids)
            try requireAnyBatchSuccess(results, verb: "delete")
            let succeeded = results.filter { $0.success }.count
            let failed = results.count - succeeded
            try emitNotesExecutedWrite(BatchDeleteResult(ok: failed == 0, succeeded: succeeded, failed: failed, results: results),
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
        try run(scriptFactory: { NotesScript(store: LiveNotesStore()) })
    }

    /// Dependency-injection seam. `run()` above binds the live boundaries and is the ONLY
    /// binding production uses — no flag or environment variable can select another. See
    /// `NotesStoreReading` for why the seam exists.
    func run(scriptFactory: () -> NotesScript,
             env: NotesWriteEnv = .live) throws {
        try runGuarded(tool: notesTool) {
            guard !ids.isEmpty else { throw AppleError.validation("No note ids provided (--ids).") }
            guard ids.count <= maxBatchIds else { throw AppleError.validation("Too many ids (max \(maxBatchIds)).") }
            try requireNonEmptyFolderName(folder)
            let gate = try resolveNotesWrite(global, defaultDryRun: false, env: env)
            // The destination folder comes from argv, so its label check is computable here and
            // runs on BOTH paths — a sandboxed preview refuses a real destination exactly as
            // execute would, without touching Notes.app.
            // Per COMPONENT: `apple-cli-test parent/Real Folder` names an unlabeled destination.
            try guardLiveFolderPath(folder, sandboxActive: gate.sandboxActive, prefix: env.sandboxPrefix)
            guard gate.willExecute else {
                let extra = gate.sandboxActive ? sandboxTargetUncheckedDetail(prefix: env.sandboxPrefix) : ""
                try emitNotesWrite(DryRunPreview("batch-move-notes", "Would move \(ids.count) note(s) to \"\(folder)\". Re-run without --dry-run.\(extra)"),
                                   json: global.json, sandboxActive: gate.sandboxActive,
                                   human: "[dry-run] would move \(ids.count) note(s) to \(folder).")
                return
            }
            let script = scriptFactory()
            try verifyBatchTargetsLabeled(ids, script, sandboxActive: gate.sandboxActive, prefix: env.sandboxPrefix)
            let results = try script.batchMoveNotes(ids: ids, folder: folder, account: account)
            try requireAnyBatchSuccess(results, verb: "move", folder: folder)
            let succeeded = results.filter { $0.success }.count
            let failed = results.count - succeeded
            try emitNotesExecutedWrite(BatchMoveResult(ok: failed == 0, folder: folder, succeeded: succeeded, failed: failed, results: results),
                               json: global.json, sandboxActive: gate.sandboxActive,
                               human: "Batch move to \"\(folder)\": \(succeeded) succeeded, \(failed) failed.")
        }
    }
}
