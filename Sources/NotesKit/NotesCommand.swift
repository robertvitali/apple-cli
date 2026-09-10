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
///   2. the RESOLVED target — every fetched folder whose chain ENDS with components that
///      case-INSENSITIVELY equal the typed ones (a typed `x` can bind a nested `p/x`; see WHERE
///      THE TYPED PATH BINDS below). AppleScript resolves a folder name case-insensitively, so a sandboxed
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
///   4. every NOTE in the resolved target and in each descendant;
///   5. every ANCESTOR above a nested resolved target. It is not erased, but a typed name that
///      binds somewhere under an unlabeled real folder is the shape the sandbox exists to refuse.
/// Steps 2–4 label-check the FETCHED name, never the typed one — and the fetched name UNTRIMMED,
/// exactly as Notes.app holds it. The listing surfaces (`folders`, `listNotes`) trim names for
/// display; a gate that trimmed would pass a folder or note literally named `" apple-cli-test x"`
/// (leading space) that `hasPrefix` rightly refuses. Whether Notes.app ever preserves such a
/// title is deliberately NOT relied on: the check is on the exact string either way. The first
/// unlabeled member refuses through `guardLiveWrite`, so the refusal is the SAME envelope the
/// other sandbox gates emit (`validation`, exit 64, `sandbox: true`) and names the offending item.
///
/// FAIL-CLOSED ENUMERATION: every member Notes.app REPORTS is label-checked, and any member it
/// reports but cannot read — or reports in a shape this gate cannot parse — is a refusal, never a
/// gap. What the gate cannot do is see a member Notes.app never reports at all (a `notes of` or
/// `every folder` that omits an item); that residual is stated in the CHANGELOG rather than
/// papered over. The ways the tolerant listing surfaces fell short, and what replaces them:
///   * `listNotes` wraps each note in a bare `try … end try` and drops blank titles, so a note
///     whose name or id Notes.app cannot report simply vanished from the list. `listCascadeNotes`
///     COUNTS those, keeps blank titles (unlabeled, so refused by the label check), cross-checks
///     its rows against Notes.app's own `count of notes`, checks EVERY reported title (no folding
///     by id), and refuses a row that does not carry exactly a name and an id — a title carrying an
///     RS/US byte would otherwise re-parse as rows of its own, one of which could start with the
///     label. This gate refuses when the unreadable count is non-zero.
///   * `buildFolderPaths` renders a folder whose parent is absent from the same listing by its
///     bare name, ancestry stripped, so it fell out of the descendant match. Worse, a rendered
///     `a/b` path cannot be trusted for matching at all: a name ending in a backslash defeats the
///     `\/` escape on the way back. `listFoldersForCascade` returns COMPONENT CHAINS built from
///     parent ids instead, reports folders whose ancestry cannot be resolved (a parent id that is
///     missing from the listing, or a looping chain), and refuses a malformed row; this gate
///     refuses when any such folder exists in the account, because a folder that cannot be placed
///     in the tree cannot be proven OUTSIDE the cascade either. A folder whose `container`
///     Notes.app itself cannot resolve (error -1728 only) is different: it has no live parent,
///     so it is the ROOT of its own chain — no live folder's cascade reaches it, so it does not
///     block a delete elsewhere, and when it is the target its whole subtree is matched and
///     enumerated by id like any other (measured 2026-09-09: the product's own cascade delete
///     leaves such a ghost child behind, still bindable by name).
/// The cost is a refusal of a legitimate, fully-labeled cleanup on the rare occasion Notes.app
/// misreports a member; the operator then deletes in Notes.app by hand. That is the right side to
/// err on for the one Notes op that destroys unbounded data irreversibly. (Operator decision
/// 2026-09-09, superseding the earlier accepted-as-disclosed best-effort posture.)
///
/// WHERE THE TYPED PATH BINDS (measured 2026-09-09): Notes.app resolves the FIRST typed component
/// against every folder in the account at any depth, and each further component against direct
/// children only. So the typed chain is matched as an END-ANCHORED window against each folder's
/// chain — a typed `child` can be `parent/child`, and a typed `a/b` can be `p/a/b` — and every
/// folder whose chain ends that way is a possible root: the gate checks all of them and all
/// their descendants, since it cannot know which one the delete's specifier will bind.
///
/// LOOSE NAMESAKES: the same folder list is also matched under a LOOSER fold (surrounding
/// whitespace, case, diacritic and width insensitive). A folder that matches only loosely and is
/// not already in the cascade means Notes.app may bind the specifier to a folder this gate cannot
/// name exactly — whether or not an exact root exists too — so the cascade set is unknowable and
/// the delete is REFUSED (`validation`, exit 64, `sandbox: true`).
///
/// UNRESOLVED TARGET: if nothing fetched ends with the typed path EXACTLY under the fold, the gate
/// does not fall through to a typed-path-only check — that dropped every descendant while still
/// reporting the subtree clean. When nothing matches even loosely,
/// the gate asks Notes.app for the typed specifier's notes once: a genuinely absent folder fails
/// there as `not_found` (what the delete itself would have said), and a folder Notes.app binds
/// but does not list — a deleted folder lingering under its name, measured — is refused, because
/// its sub-folders are not in the listing and the cascade set is unknowable.
///
/// Enumeration reaches Notes.app, which is why it is a `NotesScript` parameter rather than a
/// live binding, and why the caller supplies an already-bound script: the check runs on the
/// PREVIEW path too (a preview that reports clean for a cascade execute would refuse is the same
/// false-clean signal one invocation earlier), so the preview's "reaches nothing" property holds
/// only OUTSIDE the sandbox, where this returns before touching anything.
///
/// KNOWN WINDOW (TOCTOU, accepted — reviewed and kept, not overlooked): this validation and the
/// erase span separate AppleScript calls, so the check is a SNAPSHOT. An iCloud sync landing
/// between enumeration and deletion could add an unlabeled note or sub-folder that
/// the cascade then destroys. Notes.app exposes no transactional delete and no way to hold a
/// subtree, so the window cannot be closed from here — the only "fix" available is refusing
/// sandboxed `delete-folder` outright, which would remove the operator's only sandboxed cleanup
/// path for a folder tree AND drop a capability the MCP oracle has (parity is a strict superset,
/// so a refusal is a parity break, not a hardening). Enumeration, selected-ID resolution, and
/// deletion are separate calls with no transactional boundary or fixed timing bound. Members can
/// change during that interval; verifying the selected ID does not close that accepted race.
///
/// FRAMING, NOT PATHS: this gate never matches on a rendered `a/b` path. `folders` renders the
/// parent chain by joining names with `/` and escaping a literal `/` inside a name as `\/`, which
/// `splitFolderPath` reverses — a round trip a name ending in a backslash defeats (`x\` + `/child`
/// reads back as the single component `x/child`), which is exactly a descendant dropping out of
/// the match. `listFoldersForCascade` therefore hands this gate component CHAINS built from the
/// parent ids Notes.app reports, and the RS/US bytes that frame the listing itself are guarded in
/// the script (a name carrying one is withheld and refused) and cross-checked against Notes.app's
/// own counts, so no name can forge a row. The typed path is still split by `splitFolderPath`,
/// because that is what builds the delete's own specifier — gate and sink agree on what a typed
/// `a/b` names.
///
/// After every candidate cascade is verified, resolve the actual by-name selection and require
/// its opaque ID to belong to the verified ROOT set. The folded candidate search need not be a
/// universal superset of Notes' Unicode lookup: an unexpected selection fails membership rather
/// than reaching an unchecked delete. Descendants are checked but are not automatically roots.
/// Return the selected ID for the sandboxed mutation; nil means the sandbox is inactive. Preview
/// performs the same read-only membership check. Every user value remains an argv argument.
@discardableResult
func guardLiveFolderCascade(_ path: String, account: String?, script: NotesScript,
                            sandboxActive: Bool, prefix: String? = nil) throws -> String? {
    guard sandboxActive else { return nil }
    try guardLiveFolderPath(path, sandboxActive: sandboxActive, prefix: prefix)
    let targetComponents = NotesScript.splitFolderPath(path)
    // A path with no components (`""`, `/`) names nothing this gate can enumerate. `deleteFolder`'s
    // sink guard refuses it too; refusing HERE keeps the gate fail-closed in its own right rather
    // than returning clean and relying on the sink.
    guard !targetComponents.isEmpty else {
        throw AppleError(type: AppleErrorType.validation, message: "Invalid folder name: \"\(path)\"",
                         exitCode: AppleExit.usage, sandbox: true)
    }
    // A conservative candidate fold, compared component-wise. It need not model every Notes
    // lookup rule: the actual selected ID must pass root membership after cascade verification.
    // `splitFolderPath` also builds the read-only by-name specifier used for that selection.
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
    let listing = try script.listFoldersForCascade(account: account)
    if let unplaced = listing.unresolvedAncestry.first {
        throw AppleError(type: AppleErrorType.validation,
            message: "Sandbox is engaged: refusing to delete \"\(path)\" — folder \"\(unplaced)\" could not "
                   + "be placed in the account's folder tree (Notes.app did not report its parent), so "
                   + "the cascade this erase would take cannot be verified.",
            exitCode: AppleExit.usage, sandbox: true)
    }
    /// A chain rendered for a MESSAGE only — never re-split.
    func rendered(_ components: [String]) -> String { components.joined(separator: "/") }

    // WHERE A TYPED PATH CAN BIND (measured 2026-09-09 on a three-deep labeled tree p/c/g, the
    // bare names of both c and g binding their nested folders, ids compared): under
    // `tell account`, a bare `folder "x"` binds a folder named x at ANY depth — the account's
    // folder set is flat, and by-name lookup searches all of it — while `folder "y" of folder "x"`
    // binds only a DIRECT child of x (skipping a level is -1728). So the typed components can
    // land as a contiguous window at any offset in a folder's chain, anchored at its END: a typed
    // `child` binds `parent/child`, and a typed `a/b` binds `p/a/b` but never `a/q/b`. Every
    // folder whose chain ends with the typed chain is therefore a possible root of the erase; the
    // gate cannot know which one Notes.app will pick, so it checks ALL of them and every
    // descendant of each. Matching from the account root only would leave a nested root's
    // subtree unchecked, or check a top-level namesake while the delete bound the nested one.
    func endsWith(_ chain: [String], _ tail: [String]) -> Bool {
        chain.count >= tail.count && Array(chain.suffix(tail.count)) == tail
    }
    func startsWith(_ chain: [String], _ head: [String]) -> Bool {
        chain.count >= head.count && Array(chain.prefix(head.count)) == head
    }

    // Folders first: an unlabeled resolved target or sub-folder is refused before any note
    // enumeration runs. Matching is chain-against-chain, component by component. Every folder
    // that enters the cascade is enumerated later BY ID (`CascadeTarget.id`), never by its name
    // chain: two sibling folders whose names differ only in case fold to the same chain, and a
    // name-bound specifier would enumerate one of them twice and the other never.
    let rootFolders = listing.folders.filter { endsWith($0.components.map(exactFold), foldedTarget) }
    let roots = rootFolders.map { $0.components.map(exactFold) }
    // Opaque IDs are compared by bytes, never by the name folds or Unicode equivalence. Keep
    // this set separate from cascadeIds: a checked descendant is not necessarily a valid root.
    let rootIDs = Set(rootFolders.map { Array($0.id.utf8) })
    var cascade: [(target: NotesScript.CascadeTarget, label: String)] = []
    // Ids are unique by construction (`buildCascadeFolders` refuses a repeated id), so a folder
    // enters the cascade once even when several roots' chains prefix it.
    var cascadeIds = Set<String>()
    for folder in listing.folders {
        let folded = folder.components.map(exactFold)
        // A descendant of ANY possible root. Descent is decided on the folded chain, so a folder
        // under a case-variant namesake root is taken too — wider, never narrower.
        guard roots.contains(where: { startsWith(folded, $0) }) else { continue }
        cascadeIds.insert(folder.id)
        // The FETCHED names — the strings Notes.app holds, which is what the erase destroys.
        // Every component, the target's own ancestors included: the typed path already had to
        // be labeled component-wise (step 1), so an ancestor that fails here is one Notes.app
        // holds under a spelling the typed one only folds to — the same over-refusal the
        // case-differing resolved target gets, deliberately. Ancestors ABOVE a nested root are
        // checked too: they are not erased, but a typed name binding somewhere under an
        // unlabeled real folder is exactly the shape the sandbox exists to refuse.
        for component in folder.components {
            try guardLiveWrite(labeledName: component, sandboxActive: sandboxActive, prefix: prefix)
        }
        cascade.append((.id(folder.id), rendered(folder.components)))
    }
    // A LOOSER fold — surrounding whitespace, case, diacritics and width — is the set of names
    // Notes.app might plausibly bind to the typed specifier but this gate cannot name exactly.
    // Whitespace is in it because the fetched names are UNTRIMMED here: a folder Notes.app holds
    // as `" apple-cli-test x"` must not slip past both folds and drop its descendants from the
    // check. A folder that matches ONLY loosely and is not already in the cascade makes the
    // cascade set unknowable — whether or not an exact root was also found, since the gate
    // cannot tell which of the two the specifier binds — so REFUSE rather than silently drop
    // descendant coverage. Same end-anchored window as the exact pass: a loose namesake nested
    // anywhere is as bindable as a top-level one.
    let looseFold = { (component: String) in
        component.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: nil)
    }
    let looseTarget = targetComponents.map(looseFold)
    let looseOnly = listing.folders.first {
        !cascadeIds.contains($0.id) && endsWith($0.components.map(looseFold), looseTarget)
    }
    if let looseOnly {
        throw AppleError(type: AppleErrorType.validation,
            message: "Sandbox is engaged: refusing to delete \"\(path)\" — \"\(rendered(looseOnly.components))\" "
                   + "matches it only loosely, so which folder the erase would bind, and the cascade it "
                   + "would take, cannot be verified.",
            exitCode: AppleExit.usage, sandbox: true)
    }
    if roots.isEmpty {
        // Nothing fetched matched the typed path, even loosely. Falling through to a typed-path
        // check here is what the gate used to do, and it fails OPEN: no descendant folder is
        // label-checked at all, while `deleteFolder` still emits a bare `delete <folderRef>` that
        // Notes cascades over whatever the specifier does bind. So separate the two reasons the
        // match can miss.
        // Nothing matched even loosely, at any depth. Two very different folders can be behind
        // that, and the only way to tell them apart is to ask Notes.app for the typed
        // specifier's notes:
        //   * a folder that does not exist — the enumeration fails as `not_found`, which is the
        //     right answer and exactly what the delete itself would have said;
        //   * a folder Notes.app BINDS to the name but does not report in `every folder`.
        //     Measured 2026-09-09: a deleted folder lingers hidden, still bindable by its name,
        //     and even shadows a live folder of the same name (a `delete folder "x"` removed the
        //     hidden one and left the visible one). Its sub-folders are not in the listing, so
        //     the cascade set is unknowable — REFUSE, whatever its own notes look like.
        _ = try script.listCascadeNotes(account: account, target: .components(targetComponents))
        throw AppleError(type: AppleErrorType.validation,
            message: "Sandbox is engaged: refusing to delete \"\(path)\" — Notes.app binds that name to a "
                   + "folder the account's folder listing does not report (a deleted folder can linger "
                   + "under its name), so the cascade this erase would take cannot be verified.",
            exitCode: AppleExit.usage, sandbox: true)
    }

    // …then every note the erase would take with those folders. `listCascadeNotes` returns the
    // titles Notes.app actually holds — untrimmed, blanks kept — so this is the FETCHED name, not
    // a caller-supplied string, and it counts the notes it could not read.
    for entry in cascade {
        let notes = try script.listCascadeNotes(account: account, target: entry.target)
        if notes.unreadable > 0 {
            throw AppleError(type: AppleErrorType.validation,
                message: "Sandbox is engaged: refusing to delete \"\(path)\" — \(notes.unreadable) note(s) in "
                       + "\"\(entry.label)\" could not be read from Notes.app, so the cascade this "
                       + "erase would take cannot be verified.",
                exitCode: AppleExit.usage, sandbox: true)
        }
        for title in notes.titles {
            try guardLiveWrite(labeledName: title, sandboxActive: sandboxActive, prefix: prefix)
        }
    }

    let selectedID = try script.resolveFolderID(name: path, account: account)
    guard rootIDs.contains(Array(selectedID.utf8)) else {
        throw AppleError(type: AppleErrorType.validation,
            message: "Sandbox is engaged: refusing to delete \"\(path)\" — Notes.app selected a folder "
                   + "outside the verified deletion roots, so the cascade this erase would take "
                   + "cannot be verified.",
            exitCode: AppleExit.usage, sandbox: true)
    }
    return selectedID
}
