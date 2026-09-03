import ArgumentParser
import Foundation
import AppleKit

/// `apple notes …` — Notes.app.
///
/// Ports `apple-notes-mcp` to a strict superset. The spec was written against v2.5.12 (34
/// tools); the oracle INSTALLED on this fleet is v2.7.5 (verified against the npx cache
/// 2026-08-18 — earlier drafts of this comment said 2.6.12, itself stale), and nothing pins
/// or drift-checks the two — see COMPLETION-LOOP Q20. The transient-retry wrapper and the
/// error-mapping table in `NotesScript` are ported byte/value-exact against 2.7.5.
/// MIT. Mechanism:
/// `AppleScriptRunner` (CRUD/folders/accounts/attachments/export) + `SQLiteReader` over
/// NoteStore.sqlite (checklist protobuf, metadata, sync-status). Hard parts, all ported:
/// gzip+protobuf checklist decode, attachments, HTML↔markdown fidelity, dual id/title
/// addressing. User data always flows to osascript via argv (never interpolated).
///
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
        Output.printText(human())
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
        Output.printText(line)
    }
}

/// Execute-path write emit (Q12 [4]): stamps `dry_run: false` flat into the payload via
/// AppleKit.ExecutedWrite, satisfying write-model v2's "every execute-path envelope emits
/// dry_run:false explicitly" — the preview path keeps plain emitNotesWrite (DryRunPreview
/// already self-carries dry_run:true).
func emitNotesExecutedWrite<T: Encodable>(_ data: T, json: Bool, sandboxActive: Bool,
                                          human: @autoclosure () -> String) throws {
    try emitNotesWrite(ExecutedWrite(data), json: json, sandboxActive: sandboxActive, human: human())
}

// MARK: - Write-model v2 gate (docs/write-model-v2.md)

/// The resolved write posture for one notes command. Bound ONCE at the top of every write
/// `run()` and threaded from there — never re-derived mid-command.
/// `Equatable` so a test can pin the PRODUCTION binding by resolving the same options through the
/// default `env:` argument and through `.live` explicitly and comparing — proving the default is
/// `.live` without reading or mutating any environment variable of its own.
struct NotesWriteGate: Equatable {
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
///
/// `env` is the logic-tier seam, and it exists for the reason AppleKit already documents on
/// `TestMode.sandboxActive(flag:envVar:)` and `GlobalOptions.willExecute(defaultDryRun:envVar:)`:
/// swift-testing runs suites in PARALLEL against ONE process environment, so a Notes test that
/// needed the env-set branch of `APPLE_TEST_MODE` / `APPLE_DRY_RUN` — or a pinned
/// `APPLE_TEST_SANDBOX` label — would race every other suite that writes them. Pointing the gate
/// at test-owned variable names removes the shared state instead of locking around it.
/// Production always passes `.live`, which is the previous behavior byte-for-byte: the two
/// `truthyEnv` calls below ARE `TestMode.validateWriteEnvironment()` inlined over the configured
/// names, keeping its "validate both, eagerly, before any work" property.
func resolveNotesWrite(_ global: GlobalOptions, defaultDryRun: Bool,
                       env: NotesWriteEnv = .live) throws -> NotesWriteGate {
    _ = try TestMode.truthyEnv(env.testModeVar)
    _ = try TestMode.truthyEnv(env.dryRunVar)
    let sandboxActive = try TestMode.sandboxActive(flag: global.testMode, envVar: env.testModeVar)
    let willExecute = try global.willExecute(defaultDryRun: defaultDryRun, envVar: env.dryRunVar)
    return NotesWriteGate(willExecute: willExecute, sandboxActive: sandboxActive)
}

/// Which environment names the write gate reads, and which sandbox label it enforces.
///
/// `.live` is the ONLY value production constructs — the internal `run(…)` overloads default to
/// it and no flag or environment variable can select another. `sandboxPrefix: nil` means "ask
/// `TestMode.sandboxPrefix`", i.e. `APPLE_TEST_SANDBOX` or the built-in `apple-cli-test`, exactly
/// as before this seam existed.
/// `Equatable` for the same reason `NotesWriteGate` is: the constant below is the single place
/// naming the variables the shipped CLI honors, so it is pinned field-by-field by test.
struct NotesWriteEnv: Equatable {
    let testModeVar: String
    let dryRunVar: String
    /// Forwarded to `guardLiveWrite(prefix:)`; nil keeps the process-environment lookup.
    let sandboxPrefix: String?

    static let live = NotesWriteEnv(testModeVar: TestMode.testModeVar,
                                    dryRunVar: TestMode.dryRunVar,
                                    sandboxPrefix: nil)
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
///
/// ONLY `--id` does. It carries no argv-computable name at all, so the label check genuinely
/// cannot run without reading Notes.app and the preview says so.
///
/// `--title` does NOT disclose: the target name IS in argv, the check runs here on both paths, and
/// a preview of a labeled title has no skipped check to excuse. Claiming one would be a FALSE
/// excuse on the one selector that settles the gate from argv — pinned by
/// `bats/hosted/notes.bats` ("a sandboxed --title preview of a LABELED target claims no unchecked
/// gate"). The execute path still re-checks the FETCHED title, because AppleScript's by-name
/// lookup is CASE-INSENSITIVE and a typed `apple-cli-test x` can resolve a real note actually
/// named `Apple-CLI-Test X`; that safety half is unconditional and independent of what the
/// preview says.
func applyArgvSelectorGuard(_ selector: NoteSelector, sandboxActive: Bool,
                            prefix: String? = nil) throws -> Bool {
    switch selector {
    case .title(let t):
        // Refuses an unlabeled name outright, on both paths — so a preview that gets past this
        // line has had the gate RUN, not skipped, and must not claim otherwise.
        try guardLiveWrite(labeledName: t, sandboxActive: sandboxActive, prefix: prefix)
        return false
    case .id:
        return sandboxActive // the title lives in Notes.app; only the execute path can check it
    }
}

/// The `detail` suffix a SANDBOXED preview adds when the label check it would face on the
/// execute path cannot run here — the target's title comes from a store read, and a preview
/// deliberately does not touch Notes.app. Says so rather than implying the check passed.
/// `prefix` is the same seam `guardLiveWrite` carries, so the disclosed label matches the label
/// the execute path would actually enforce. Production passes nil.
func sandboxTargetUncheckedDetail(prefix: String? = nil) -> String {
    " Sandbox is engaged: the execute path additionally requires the target to be a labeled "
    + "'\(resolvedSandboxPrefix(prefix))…' item. That check reads Notes.app, so this preview did not run it."
}

/// The label a sandboxed Notes write actually enforces, for both the gate and the disclosure above
/// (they must never name different prefixes).
///
/// `TestMode.sandboxPrefix` already normalizes the ENVIRONMENT path — an empty or whitespace-only
/// `APPLE_TEST_SANDBOX` falls back to the canonical label, because `name.hasPrefix("")` is always
/// true and would vacate the gate for every name. The injected `prefix` seam bypassed that
/// normalization, so the same rule is applied here to whichever source supplied the value.
/// (`TestMode.normalizedPrefix` is internal to AppleKit and not callable from this module; this is
/// the same rule, not a different one.) Production passes nil, so the value is
/// `TestMode.sandboxPrefix` — already non-empty and trimmed — and the result is unchanged.
func resolvedSandboxPrefix(_ prefix: String?) -> String {
    let raw = (prefix ?? TestMode.sandboxPrefix).trimmingCharacters(in: .whitespacesAndNewlines)
    return raw.isEmpty ? TestMode.canonicalSandboxPrefix : raw
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
/// `store` is the seam described on `NotesStoreReading`; production callers bind the live store
/// through their command's `storeFactory`.
/// The store has NO default: every caller passes the one its command bound. Together with
/// `NotesScript.init`'s equally non-defaulted `store:` (the other place a live store used to be
/// constructible), that makes `NotesStoreReading`'s "storeFactory is the only way a live store is
/// constructed" invariant structural rather than conventional — omitting it does not compile.
func currentSyncWarning(_ store: any NotesStoreReading) -> String? {
    let status = store.syncStatus()
    guard status.sync_detected else { return nil }
    return status.warning ?? "iCloud sync is in progress; results may be incomplete or change shortly."
}

/// A generic dry-run preview payload (apple-cli safety extra; not part of MCP parity output).
/// Write-model v2: writes EXECUTE by default — this payload is emitted only when the run is
/// a preview: the caller opted into `--dry-run` (or `APPLE_DRY_RUN=1`), or the surface is
/// `folders delete`, whose per-surface `surfaceDefaultDryRun = true` makes preview the
/// default (the ONE irreversible Notes op — see DeleteFolderCmd). `dry_run` is hardwired
/// true because every emit of this type IS a preview (Q12 [6]).
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
/// (`--test-mode` with no env var) must engage the same confinement, and re-reading the
/// environment here (as v1 did) would silently skip it.
/// Refusals stay `AppleError.validation` (exit 64), the per-domain refusal type for Notes.
///
/// `prefix` is a logic-tier seam: `TestMode.sandboxPrefix` reads `APPLE_TEST_SANDBOX` from the
/// PROCESS environment, and swift-testing runs every suite in one process — `MailKitTests`
/// setenv()s that variable mid-run. A test with hard-coded expectations must pin the prefix
/// instead of inheriting whatever another suite last wrote. Production callers never pass it.
func guardLiveWrite(labeledName: String?, sandboxActive: Bool, prefix: String? = nil) throws {
    guard sandboxActive, let name = labeledName else { return }
    let required = resolvedSandboxPrefix(prefix)
    guard name.hasPrefix(required) else {
        // A sandbox refusal, so it carries `error.sandbox` like the Mail/Contacts ones (Q14). It
        // keeps `validation` / exit 64 (unchanged) rather than the exit-77 `safety_violation` the
        // other domains' sandbox refusals use — that exit-code inconsistency is pre-existing and
        // aligning it is a separate breaking change, out of scope here.
        throw AppleError(type: AppleErrorType.validation,
            message: "Sandbox is engaged: refusing to write to \"\(name)\" — the target must be a labeled "
                   + "'\(required)…' test item.",
            exitCode: AppleExit.usage, sandbox: true)
    }
}

/// SANDBOX confinement for a value that is a folder PATH rather than a single name.
///
/// A path is not one label. `NotesScript.splitFolderPath` is what actually resolves the AppleScript
/// specifier, so `apple-cli-test parent/Real Folder` names an UNLABELED child — and a single
/// `hasPrefix` over the whole string sees only the first component and passes it. Inside the
/// sandbox EVERY component must carry the label, or the confinement stops at the first slash.
///
/// This was reachable and destructive: `folders delete` CASCADES and the cascade is PERMANENT (see
/// `resolveNotesWrite`), so a sandboxed `folders delete "apple-cli-test parent/Real Folder"`
/// erased real notes irrecoverably while reporting itself confined. Outside the sandbox this is a
/// no-op, exactly like `guardLiveWrite` — the oracle has no counterpart gate.
func guardLiveFolderPath(_ path: String, sandboxActive: Bool, prefix: String? = nil) throws {
    guard sandboxActive else { return }
    for component in NotesScript.splitFolderPath(path) {
        try guardLiveWrite(labeledName: component, sandboxActive: sandboxActive, prefix: prefix)
    }
}

/// SANDBOX confinement for the CASCADE `delete-folder` performs — every descendant folder and
/// every note the erase would take with it, not just the path the caller typed.
///
/// `guardLiveFolderPath` alone checks only the REQUESTED components, and that is not what the
/// operation destroys: `NotesScript.deleteFolder` emits a bare `delete <folderRef>`, which Notes
/// cascades over the whole subtree with no enumeration and no per-item check. So a fully-labeled
/// `apple-cli-test parent/apple-cli-test child` passed the gate while the child still held real,
/// unlabeled notes — or an unlabeled sub-folder — and the cascade erased them PERMANENTLY (the
/// cascaded notes do not reach Recently Deleted). A gate that clears the container but never looks
/// inside it is not confinement; the sandbox promise is about what gets destroyed, not about what
/// was typed.
///
/// So inside the sandbox the complete cascade set is enumerated first and every member must carry
/// the label:
///   1. the target path, component by component (the `guardLiveFolderPath` rule) — a cheap
///      fail-fast on an obviously-unlabeled TYPED name, before anything reaches Notes.app;
///   2. the RESOLVED target — every fetched folder whose components case-INSENSITIVELY equal the
///      typed ones. AppleScript resolves a folder name case-insensitively, so a sandboxed
///      `delete-folder "apple-cli-test x"` can resolve a real folder actually named
///      `Apple-CLI-Test x`, whose fetched name fails the case-SENSITIVE label check while the
///      typed spelling sailed through step 1. Same defect class as the by-title note writes.
///      If SEVERAL fetched folders fold to the typed name (`apple-cli-test x` and
///      `APPLE-CLI-TEST X` as siblings), ALL of them are checked: the gate over-refuses rather
///      than guess which one the specifier will bind;
///   3. every DESCENDANT folder — matched by comparing resolved components under the same
///      case-insensitive fold, so the account's folder list and the typed path are compared the
///      way `splitFolderPath` resolves them rather than by raw-string prefix. Without the fold a
///      descendant of `Apple-CLI-Test x` did not match the typed `apple-cli-test x` at all and
///      was never checked — the cascade destroyed it unexamined;
///   4. every NOTE in the resolved target and in each descendant.
/// One precision note on steps 2–3: `buildFolderPaths` renders each fetched component through
/// `.trimmingCharacters(in: .whitespaces)`, so the "fetched name" these steps check is the TRIMMED
/// string Notes.app holds. A folder literally named `" apple-cli-test x"` (leading space) is not
/// labeled by `hasPrefix` but passes after trimming. Reachable only as a descendant — the typed
/// target would not resolve to it — and pre-existing in the rendering every folder-path surface
/// shares, not introduced here.
/// Steps 2–4 label-check the FETCHED name, never the typed one: the fetched name is what
/// Notes.app actually holds and what the erase actually destroys. The first unlabeled member
/// refuses through `guardLiveWrite`, so the refusal is the SAME envelope the other sandbox gates
/// emit (`validation`, exit 64, `sandbox: true`) and names the offending item.
///
/// BEST-EFFORT ENUMERATION (accepted, disclosed): the set enumerated here is the set Notes.app
/// REPORTS, which is not provably the set the erase takes. `listNotes` wraps each note in a bare
/// `try … end try` and the Swift side drops a row whose title trims to empty, so a note whose name
/// or id Notes.app cannot report produces no row at all — it is never label-checked, and the
/// cascade still destroys it. Folder-path reconstruction (`buildFolderPaths`) shares the property:
/// a folder whose parent is absent from the same account listing is rendered by its bare name with
/// ancestry stripped, so it can fail the component-wise descendant match here and go unchecked
/// while the erase still reaches it. That is strictly narrower than the pre-gate state (which
/// enumerated nothing) but it is why this gate claims "the cascade set Notes.app will report"
/// rather than "the complete cascade set". The CHANGELOG entry carries the same wording.
///
/// UNRESOLVED TARGET: if nothing fetched matches the typed path EXACTLY under the fold, the gate
/// does not fall through to a typed-path-only check — that dropped every descendant while still
/// reporting the subtree clean. It re-asks the same folder list under a LOOSER fold (case,
/// diacritic and width insensitive): a loose hit means Notes.app may bind the specifier to a folder
/// this gate cannot name exactly, so the cascade set is unknowable and the delete is REFUSED
/// (`validation`, exit 64, `sandbox: true`). Only when nothing matches even loosely does it fall
/// back to the typed path — the folder is genuinely absent, and the delete fails upstream as
/// `not_found` instead.
///
/// Enumeration reaches Notes.app, which is why it is a `NotesScript` parameter rather than a
/// live binding, and why the caller supplies an already-bound script: the check runs on the
/// PREVIEW path too (a preview that reports clean for a cascade execute would refuse is the same
/// false-clean signal one invocation earlier), so the preview's "reaches nothing" property holds
/// only OUTSIDE the sandbox, where this returns before touching anything.
///
/// KNOWN WINDOW (TOCTOU, accepted — reviewed and kept, not overlooked): this validation and the
/// erase are two separate AppleScript calls, so the check is a SNAPSHOT taken immediately before
/// the delete, and an iCloud sync landing in between could add an unlabeled note or sub-folder that
/// the cascade then destroys. Notes.app exposes no transactional delete and no way to hold a
/// subtree, so the window cannot be closed from here — the only "fix" available is refusing
/// sandboxed `delete-folder` outright, which would remove the operator's only sandboxed cleanup
/// path for a folder tree AND drop a capability the MCP oracle has (parity is a strict superset,
/// so a refusal is a parity break, not a hardening). The snapshot is taken immediately before the
/// erase, which narrows the exposure from "anything in the subtree" to "whatever arrived in the
/// last few hundred milliseconds"; that residual race is accepted.
///
/// PATH AMBIGUITY (pre-existing, sandbox-only): `buildFolderPaths` renders the parent chain by
/// joining names with `/` and escaping a literal `/` inside a name as `\/`, which
/// `splitFolderPath` reverses — so a folder whose own name contains a slash round-trips only
/// while that escaping holds. A name the escape misses would be indistinguishable from a nesting
/// level here, and the fold above would compare the wrong components. This is the rendering
/// semantics every folder-path surface already shares (`folders`, `create-folder`, `--folder`
/// filters), not something this gate introduces; it is noted because this gate is the one place
/// where a mis-split decides what an irreversible erase may touch.
///
/// Both wrappers are read-only and pass every user value as argv (see `listFolders`/`listNotes`),
/// so widening the gate does not widen the injection surface.
func guardLiveFolderCascade(_ path: String, account: String?, script: NotesScript,
                            sandboxActive: Bool, prefix: String? = nil) throws {
    guard sandboxActive else { return }
    try guardLiveFolderPath(path, sandboxActive: sandboxActive, prefix: prefix)
    let targetComponents = NotesScript.splitFolderPath(path)
    guard !targetComponents.isEmpty else { return }
    // The fold AppleScript itself applies when it resolves the specifier. Compared component-wise,
    // not as one string, for the same reason step 1 checks components: `splitFolderPath` is what
    // decides which folder the specifier names.
    //
    // `folding(options: [.caseInsensitive])` rather than `lowercased()`: it is the analogue of
    // Foundation's `caseInsensitiveCompare` and folds strictly MORE than simple lowercasing
    // (ß/ss-class expansions, some final-sigma and titlecase forms), so the only direction it can
    // move the checked set is wider — more folders enter the cascade, more label checks run.
    // Locale is nil deliberately: a locale-sensitive fold would make the gate's verdict depend on
    // the operator's region (the Turkish dotless-i trap), and AppleScript's own `ignoring case` is
    // not locale-keyed either.
    let exactFold = { (component: String) in component.folding(options: [.caseInsensitive], locale: nil) }
    let foldedTarget = targetComponents.map(exactFold)

    // ONE folder listing for the whole gate: the exact pass below and the loose ambiguity re-check
    // both read it, so a sandboxed `delete-folder` enumerates the account's folders once.
    let fetchedFolders = try script.listFolders(account: account)

    // Folders first: an unlabeled resolved target or sub-folder is refused before any note
    // enumeration runs.
    var cascade: [String] = []
    var resolvedTheTarget = false
    for folder in fetchedFolders {
        let folded = NotesScript.splitFolderPath(folder.name).map(exactFold)
        guard folded.count >= foldedTarget.count,
              Array(folded.prefix(foldedTarget.count)) == foldedTarget else { continue }
        // The FETCHED name — the string Notes.app holds, which is what the erase destroys.
        try guardLiveFolderPath(folder.name, sandboxActive: sandboxActive, prefix: prefix)
        if folded.count == foldedTarget.count { resolvedTheTarget = true }
        cascade.append(folder.name)
    }
    if !resolvedTheTarget {
        // Nothing fetched matched the typed path EXACTLY. Falling through to a typed-path-only
        // check here is what the gate used to do, and it fails OPEN: no descendant folder is
        // label-checked at all, while `deleteFolder` still emits a bare `delete <folderRef>` that
        // Notes cascades over whatever the specifier does bind. So separate the two reasons the
        // exact match can miss.
        //
        // A LOOSER fold — case, diacritics and width — is the set of names Notes.app might
        // plausibly bind to the typed specifier but this gate cannot name exactly. If one exists,
        // the cascade set is unknowable, so REFUSE rather than silently drop descendant coverage.
        let looseFold = { (component: String) in
            component.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                              locale: nil)
        }
        let looseTarget = targetComponents.map(looseFold)
        let ambiguous = fetchedFolders.first { folder in
            let folded = NotesScript.splitFolderPath(folder.name).map(looseFold)
            return folded.count >= looseTarget.count
                && Array(folded.prefix(looseTarget.count)) == looseTarget
        }
        if let ambiguous {
            throw AppleError(type: AppleErrorType.validation,
                message: "Sandbox is engaged: refusing to delete \"\(path)\" — it does not match any "
                       + "folder exactly, but \"\(ambiguous.name)\" resolves ambiguously against it, so "
                       + "the cascade this erase would take cannot be verified.",
                exitCode: AppleExit.usage, sandbox: true)
        }
        // Nothing matched even loosely: the folder is genuinely absent (the delete fails upstream
        // as `not_found`) or the account's listing was empty. Fall back to the typed path so the
        // note enumeration below still runs.
        cascade.append(path)
    }

    // …then every note the erase would take with those folders. `listNotes` returns the titles
    // Notes.app actually holds, so this is the FETCHED name, not a caller-supplied string.
    for folderPath in cascade {
        for title in try script.listNotes(account: account, folder: folderPath,
                                          modifiedSince: nil, limit: nil) {
            try guardLiveWrite(labeledName: title, sandboxActive: sandboxActive, prefix: prefix)
        }
    }
}
