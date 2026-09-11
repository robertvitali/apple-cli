# Opt-in AppleScript capture limit

Status: accepted specification. Implementation and verification are pending.

## Decision and scope

Add an opt-in configurable byte limit to the existing shared AppleScript runner. Preserve the current unlimited default and all four delivery forms. Reuse OwnedScriptProcess; do not introduce another subprocess engine or change successful background-descendant behavior.

The approved choice explicitly defers mandatory default memory protection. Frozen-oracle research found differing policies: configurable 64 MiB in Notes 2.5.12, 10 MiB in the Events helper, and no application capture-byte bound at the inspected Python Messages, Contacts and Mail subprocess calls. The Events native implementation does not use this runner. These findings do not establish a universal mandatory default. This feature adds a caller choice; it does not claim exact parity with every historical runtime or transport buffer policy.

The limit covers retained raw stdout plus stderr for one invocation. It is not a total RSS limit, an input-script limit, an aggregate command budget across several invocations, a hard disk quota, or a cap on successful descendants' later output.

## Configuration and API

Public spelling:

```swift
public init(maximumOutputBytes: Int? = nil)
```

Existing `AppleScriptRunner()` calls remain source-compatible. No run-method or AppleScriptRunning protocol signature changes are needed.

Resolution at each invocation:

1. For timed forms, perform the existing timeout validation first, preserving its existing precedence.
2. A non-nil explicit `maximumOutputBytes` value takes precedence over the environment. It must be positive. It is validated before invoking the launcher, including through internal test construction. Do not inspect the environment when an explicit value was supplied.
3. Otherwise read `APPLE_SCRIPT_MAX_OUTPUT_BYTES` once for this invocation. Absence means unlimited.
4. A present environment value must contain one or more ASCII digits and represent an integer in `1...Int.max`. Leading zeros are accepted if the represented value is positive. Empty values, zero, signs, whitespace, non-ASCII numerals, decimals, unit suffixes and integer overflow are invalid. Never trim, fall back silently, or echo the value.
5. Store the resolved optional limit in `ScriptInvocation.maximumOutputBytes`, defaulting to nil for existing internal construction. Every inline, timed-inline, stdin and timed-stdin public entry point passes the resolved value.

Nil means consult the environment, not override it to unlimited. Unlimited operation is selected by leaving the environment variable unset. No separate explicit-unlimited mode is added in this unit.

The public initializer remains nonthrowing: bad configuration fails when a throwing run method is invoked, before any child for that invocation starts. The setting is read at call time, not startup or runner construction; a reused default runner can observe an intentional later environment change.

## Deterministic configuration tests

Separate resolution into a pure function accepting an explicit optional Int and an optional environment string. Give the internal runner test initializer an injectable environment-value reader; production binds the real lookup, tests bind immutable synthetic values or a recording reader. Existing recording-launcher tests should default this test-only reader to absence.

Test explicit precedence with an injected reader that records or rejects invocation. Test repeated invocation resolution with an injected deterministic value sequence. Do not mutate `APPLE_SCRIPT_MAX_OUTPUT_BYTES` in concurrent Swift tests, and do not add this variable to the unrelated write-posture pin. End-to-end environment wiring, if covered, uses a subprocess-specific `Process.environment` dictionary with its own synthetic child, never controller-global mutation. Pure parser and injected wiring tests provide the minimum required configuration coverage.

## Byte accounting and outcomes

The configured value N is a combined raw-byte allowance for stdout and stderr before UTF-8 decoding or whitespace trimming. Exactly N bytes succeeds, subject to the existing status/error/deadline behavior. The first observed byte or capture size beyond that allowance fails the invocation. A stream cannot consume N independently of the other stream.

On overflow, return no partial outcome or truncated success. Discard accumulated output through normal stack cleanup. An otherwise nonzero child status does not turn overflow into scriptFailed: only a complete under-limit outcome reaches the existing nonzero-status mapper. Preserve normal stdout decoding, stderr classification, exit-status representation and command envelopes below the limit or with no limit.

Retained raw payload is limited to N bytes. A bounded scratch read may observe excess bytes solely to detect overflow; it must not append them. Data capacity, allocator overhead, existing input data, temporary copies and later UTF-8/String conversion mean total process memory can exceed N. Do not advertise an exact RSS ceiling.

## Error contract

Invalid environment configuration throws:

```swift
AppleError.validation("APPLE_SCRIPT_MAX_OUTPUT_BYTES must be a positive decimal byte count")
```

Invalid explicit API configuration throws:

```swift
AppleError.validation("maximumOutputBytes must be a positive byte count")
```

Both use the existing `validation_error` type and exit 64, and carry the non-wire origin marker specified below. Do not retain the invalid environment contents in another field, nested error, diagnostic, log or test failure message.

The process layer throws one module-internal typed `ScriptOutputLimitExceeded` error containing only the positive configured limit. The public runner's shared launch/result boundary translates it to:

```text
osascript output exceeded the configured limit of N bytes; no partial result returned. The operation may have completed; verify its state before retrying.
```

Use `AppleError.upstream`: existing `upstream_error` type, exit 69, unchanged schema version, no new envelope fields and no captured stdout/stderr. N is the configured decimal limit, not a claim about the exact total generated. Do not emit a partial result, caller script, arguments, paths or child diagnostic.

Keep this failure distinct from RunError.scriptFailed and RunError.launchFailed. In particular, do not feed it into Notes diagnostic matching or retry classification. A plain AppleError conversion alone is insufficient: existing broad catches and nonthrowing caches would erase or suppress the new policy failure.

### Non-wire provenance and narrow pass-through

Add an internal stored origin discriminator to AppleError, identifying output-limit configuration and output-limit overflow errors. The existing public initializer and ordinary validation/upstream factories always leave it absent. Only dedicated module-internal AppleKit factories for these two output-limit errors may set it. No public initializer argument, mutable property, serialized field, or heuristic may synthesize the marker.

Expose a public read-only predicate:

```swift
public static func isOutputLimitError(_ error: any Error) -> Bool
```

on AppleScriptRunner. It checks the discriminator on an AppleError; it never matches message text, type, exit code, NSError description, or arbitrary nested text. It recognizes both invalid output-limit configuration and overflow. The internal raw process overflow is mapped to the marked AppleError before crossing the public runner boundary.

Preserve the discriminator when `AppleError.addingBulkContext` copies an error, alongside its existing metadata. Output emission continues to select only the existing public envelope fields; the discriminator is never part of JSON/stdout/stderr. Existing unmarked AppleErrors, including errors whose type, exit and complete message exactly match a limit error, remain unmarked and retain their old handling.

At each affected domain fallback, catch a marked error and rethrow the same value before the legacy catch/fallback. Do not rethrow all validation or upstream errors, and do not replace a marked error with a new ordinary AppleError. Throwing signature propagation is required where a currently nonthrowing helper would otherwise prevent this. Bulk wrappers may add their existing uncertain-outcome context while retaining the marker.

### Confirmed suppression paths and required changes

The following source locations were inspected for this design; line numbers identify the baseline rather than a stable interface.

- `Sources/NotesKit/NotesScript.swift:1038`: folder existence lookup currently uses try?; any failure becomes absence and can trigger `make new folder`. Marked configuration/overflow must escape before any make, next segment or retry. Preserve the current absence/failure fallback for unmarked errors.
- `NotesScript.swift:1061`: final folder-ID readback currently substitutes an empty ID. Rethrow marked errors instead of reporting success with an empty ID; prior mutations remain uncertain.
- `NotesScript.swift:1207`: shared-note enumeration currently skips an account on any error. Rethrow marked errors instead of returning an incomplete successful listing; do not process later accounts.
- `Sources/MailKit/Commands/MessageReadCommands.swift:668`: make `liveAttachmentMetadataOrNil` throwing, rethrow marked errors, and propagate try at its command caller. Unmarked live lookup failures still use the disclosed index fallback.
- `Sources/MailKit/Commands/ExportCommands.swift:190`: full-body enrichment currently uses try?; marked errors must abort rather than produce a successful reduced-body export. Preserve ordinary enrichment fallback.
- `Sources/MailKit/Support/MailScript.swift`, `saveOpenDraft`: this public nonthrowing method converts a runner error directly to false; it does not retry that error. Add a public `saveOpenDraftChecked(subject:retries:delaySeconds:) throws -> Bool` with marked pass-through and the same ordinary polling/false behavior. Keep the old nonthrowing method as a source-compatible legacy wrapper. Migrate `DraftRichCommand.run` to the checked method at its existing call point, after the existing EML write/open sequence. A marked error stops there without a successful saved:false result, extra polling, or an assertion that the EML/window operation did not happen.
- `MailScript.swift:3304`: supported-rule-action verification currently reclassifies any error as a safety refusal. Pass marked errors through before that legacy mapping.
- `Sources/MailKit/Commands/RuleTemplateCommands.swift`: list/readback, condition-count fallback, match-logic catches, best-effort deletion and final index readback can suppress or rewrap policy failures. Marked primary failures must escape before any further enable, mutation, candidate lookup or cleanup invocation. Only verification failures observed BEFORE the existing enable step carry the guarantee that the newly created/recreated rule remains disabled. Enable itself can mutate before failing, and final-index readback currently occurs AFTER enable (RuleTemplateCommands.swift:182/188 and :512/514); marked failures during enable or that later readback therefore propagate with uncertain state, with no claim that the rule is still disabled and no further operations. Preserve the existing enable/readback order; do not add or reorder cleanup mutations to manufacture a stronger state guarantee. Report uncertainty rather than claiming rollback. When cleanup is already attempted for an ordinary mismatch/failure and cleanup itself throws a marked error, propagate that marked error instead of claiming the rule was removed. Preserve the existing behavior for unmarked cleanup errors; this unit does not generally rewrite legacy rollback wording. Any contextual wrapper must preserve provenance.

The bounded production call-chain audit additionally confirms these required families:

- `NotesScript+Extra.swift`: `batchDeleteNotes` and `batchMoveNotes` currently stamp whole-script errors into per-item strings; `healthCheck` substitutes failed/empty/successful-zero diagnostic checks; `getRecentlyModifiedCounts` substitutes zero counts plus an error string. These helpers are internal. Add throws, pass marked errors before existing fallback conversion, and propagate try through `NotesBatchCommands.swift`, Health/Doctor commands in `NotesDiagCommands.swift`, and the `getNotesStats` caller. No public compatibility wrapper is needed for these internal methods.
- `NotesScript+Extra.swift`: `getNotesStats` converts per-account errors to coverage warnings; `exportNotesAsJson` substitutes empty folders/titles/body or skips details; `getNoteMarkdown` suppresses optional AppleScript detail enrichment. Pass marked errors through each existing boundary before continuing traversal, enrichment or emission. Unmarked partial-coverage/export/enrichment semantics remain unchanged.
- `NotesReadCommands.swift`: internal `GetNoteLinkCmd.resolveLink` gains throws for marked AppleScript-fallback errors; both CLI callers propagate try. Keep SQLite-first behavior and avoid AppleScript entirely when the store already provides the link. `NotesDiagCommands.swift` Doctor's separate optional account lookup also passes marked errors before diagnostic fallback.
- `MailKit/Commands/AccountCommands.swift` unread-count and `MessageReadCommands.swift` selected-message broad error wrappers must preserve marked errors before reconstructing ordinary upstream messages.
- `MailKit/Commands/AnalyticsCommands.swift` AnalyticsOverview unread enrichment and `ExportCommands.swift` AnalyticsDashboard unread enrichment must not convert a marked failure into successful reduced counters or HTML output. Their ordinary unread fallback remains.
- `MailKit/Commands/WriteManageCommands.swift`: DeleteCommand and TrashEmpty preview-only trash enumeration must pass marked errors before the empty-list fallback. Preserve all execute/irreversible-operation gates; no live deletion is needed for verification. Internal `AttachmentsSave.resolveLiveAttachmentNames` gains throws and marked pass-through before its names/failure-text conversion, with try propagated through the actual command.
- `MessageReadCommands.swift` Get/AttachmentsList and `WriteManageCommands.swift` resolveTargets have optional account UUID-resolution fallbacks. These must not suppress a marked error from the checked directory path described below. Preserve the ordinary empty-scope fallback for unmarked failures.
- `RuleTemplateCommands.swift` RulesList's broad wrapper and RulesUpdate's replacement-create catch also preserve marked errors. A failed replacement create can have changed state; do not apply the legacy definite-gone wording to a marked uncertain failure.

Contacts' only three shared-runner sites (`ContactsStore.readNote`, `writeNote`, `removeContactFromGroup`) catch RunError specifically, so a marked AppleError already passes unchanged. Messages `Send.perform` and its command caller directly throw runner errors; the nearby broad catch handles earlier recipient validation only. Add command-boundary controls, without speculative catch rewrites in these domains.

This inventory bounds the required propagation changes. Record the changed call chains and matching regression evidence; do not claim universal propagation based on a single helper test.

### Checked Mail account-directory path

`Sources/MailKit/Support/AccountDirectory.swift` has a source-compatible nonthrowing initializer that catches fetch failures into `loadError`. The class is actually named `AccountDirectory`. `MailContext.accounts()` is also nonthrowing; account UUID fallback and row-label decoding can therefore succeed after a marked fetch failure.

Keep the existing nonthrowing public initializer/API for source compatibility, but add an explicitly named throwing checked path used by every CLI consumer:

- `AccountDirectory.checkOutputLimitFailure() throws`: inspect stored loadError and rethrow it unchanged only when the predicate recognizes its marker; otherwise return normally.
- `MailContext.checkedAccounts() throws -> AccountDirectory`: obtain the existing cached directory, call the check, and return it. It must inspect a cached marked failure on every checked access, not silently accept an already-created failed directory.
- `requireAccountUUID` obtains checkedAccounts BEFORE either directory resolution or index UUID fallback. An index-known UUID cannot bypass an already-observed marked directory failure.
- Add checked throwing label/summary decoding paths (for example `checkedLabels(forMailboxRowid:)` and `checkedDecodeSummary(_:)`) for CLI callers. Acquire/check the directory before fallback labels are chosen. Keep legacy nonthrowing public accessors source-compatible if needed, but migrate CLI call sites to the checked variants.
- CLI consumers receiving AccountDirectory directly from a factory must call its check before consuming accounts, names, sender addresses, display names or fallback values. Preserve injection seams. Do not depend on callers reading loadError manually by convention alone.

Migrate actual CLI access in AccountCommands (accounts/mailboxes/unread/doctor), MessageReadCommands (search/list/get/selected/thread/attachments), WriteManageCommands (target resolution/attachment save), ExportCommands (dashboard/export), AnalyticsCommands (overview), WriteComposeCommands (send/reply/forward/rich draft/draft), and RuleTemplateCommands (template save). These families consume direct directory factories, ctx.accounts or ctx.decodeSummary. Use throwing maps/loops where necessary, preserving previous lazy evaluation and command ordering.

Do not eagerly load a directory for a path that never previously used it. For example, a missing mailbox row still produces the existing empty labels without fetching a directory, and a dry-run branch that previously avoided Mail must continue to do so. Once an existing operation requests the directory, its recorded marked failure must propagate before UUID/name fallback or row enrichment. Unmarked directory failures continue the existing headless UUID-label/index-resolution behavior. Tests must cover both the throwing path and actual CLI wiring; adding an unused checked accessor does not satisfy this requirement.

### Compatibility limits and exclusions

Source compatibility retains the old nonthrowing `AccountDirectory` initializer/accessors, `MailContext.accounts/labels/decodeSummary`, and `MailScript.saveOpenDraft`. Direct callers choosing those legacy APIs can still receive cached error state, empty/UUID fallback or false after an output-policy error. The new guarantee applies to the runner's throwing boundary and the migrated checked CLI paths. Document these limits; do not claim universal suppression prevention through every retained best-effort API.

Do not broaden unrelated optional behavior: Contacts native framework operations, Messages SQLite/AddressBook reads, Notes store/AttachmentFS/regex/HTML conversion, Mail index counts/queries, local EML/export/template/attachment filesystem work, and shared snapshot/permissions/rate-limit/output-sink housekeeping do not catch this runner's policy errors. Notes Doctor's codesign Process and Mail LaunchServices `/usr/bin/open` are separate subprocesses. Mail's optional contextFactory creation currently initializes the index without loading lazy accounts; retain that SQLite fallback and check the directory at its actual later use. Script-level AppleScript on-error blocks cannot catch a host capture limit and need no rewriting. Calendar/Reminders native EventKit paths have no shared-runner invocation in this audit.

Existing timeout-only or RunError-only catches, and Mail locator loops whose runner calls already throw directly, already pass marked AppleErrors. Verify these with controls rather than introducing redundant catches. The shared runGuarded AppleError branch already preserves the public classification; only marker-preserving copy behavior is needed in addingBulkContext.

## Enforcement in OwnedScriptProcess

### Pipe delivery forms

For inline, stdin and timed-stdin, enforce the allowance in the existing synchronous nonblocking loop. Maintain aggregate retained bytes across both streams. Before each read, request at most the existing chunk size and at most remaining allowance plus one detection byte. Compute that bound without evaluating `Int.max + 1`; use a branch or checked arithmetic. When no allowance remains, a one-byte read distinguishes EOF from overflow.

After a successful read, check its count against the remaining allowance before appending. Overflow must escape as its typed error; put this check outside the catch that maps POSIX read failures, or explicitly preserve its type. Keep existing EOF, EINTR, EAGAIN, chunk fairness, stdin progress and deadline checks.

### Timed-inline regular captures

Retain the existing unlinked private regular files. Switching this form to EOF-based pipes would alter its root-exit completion contract and is excluded.

When a limit is enabled, add a throwing capture-size operation to ScriptProcessIO. In each existing owner-loop turn, after child observation and the existing deadline check but before the completion break, inspect stdout and stderr sizes. Compare against the aggregate allowance using subtraction or checked arithmetic rather than an overflowing sum. Capture-size syscall errors use the existing Cocoa capture-read family with the actual POSIX cause. Do not perform these additional size observations in unlimited mode.

Extend captureSnapshot with an optional maximum byte allowance. Its own fstat establishes a fixed snapshot length, as today. Reject a length above the allowance before reading or allocating its payload. Read only that fixed snapshot with explicit-offset reads; do not seek the shared open-file description or chase later appends. Read stdout within N, then stderr within N minus the actual stdout bytes captured. A second snapshot can validly receive zero allowance; empty succeeds and any positive size fails. Keep the original configured limit in the overflow error even when enforcing a smaller remaining allowance.

Size monitoring catches observed overflow while the root still runs. The snapshot check independently covers growth after a prior observation and prevents unbounded materialization. Keep existing handling of short reads and genuine capture-read failures. No Data-returning unbounded snapshot may be called first and checked afterward.

Sampling two growing files is not an atomic combined snapshot. Children can write between samples and after the successful snapshots. The feature detects observed overflow and bounds the returned/retained capture payload; it does not enforce an exact instantaneous disk maximum. On successful capture, including nonzero root exit, do not signal the group solely because a background descendant may keep writing later.

## Failure order and lifecycle

Existing invalid-timeout validation precedes new output-limit validation in timed public forms. During execution, retain the current child-observation and deadline checks. An elapsed deadline detected at its existing check takes precedence over a subsequent size/read check in that turn. Otherwise, the first actually observed error wins; do not claim globally timestamped ordering across concurrent child events. Do not add a second timer, or change the existing final snapshot deadline semantics as a side effect of this feature.

Typed overflow follows the existing failure catch and `cancel(timeout: false)` path. Preserve TERM/grace/KILL behavior, descriptor closure, ECHILD authority revocation, exclusive reap and bounded transfer to the eventual reaper. Cleanup failures do not replace the triggering overflow.

Retain WNOWAIT root authority through both capture snapshots. Overflow discovered after root exit still cancels inheriting descendants before final reap. Once successful capture is complete, preserve the existing no-signal successful path. Output limits do not strengthen the ownership guarantee for detached process groups or uninterruptible kernel work.

A child may already have mutated application data before output overflow is observed. Failure never means the action did not occur; the shared message explicitly states uncertainty, and existing bulk context remains authoritative for earlier confirmed items.

## Implementation file map

- `Sources/AppleKit/AppleScriptRunner.swift`: initializer/configuration seam, pure resolution, invocation field, internal typed overflow and shared public mapping; four run forms.
- `Sources/AppleKit/AppleError.swift`: internal non-wire origin, dedicated internal factories and provenance-preserving bulk copies; public constructor/wire fields unchanged.
- `Sources/AppleKit/OwnedScriptProcess.swift`: aggregate pipe accounting, opt-in capture-size observation, bounded fixed snapshots, preservation through existing cleanup.
- `Tests/AppleKitTests/ScriptLauncherTests.swift`: pure configuration/wiring and actual launcher boundary cases.
- `Tests/AppleKitTests/ProcessResourceTests.swift`: adapt recording IO to the narrow protocol additions; allocation/read ordering, errors and resource lifecycle.
- `Tests/AppleKitTests/OwnedProcessCleanupTests.swift`: overflow cleanup using established synthetic fixtures.
- `Sources/NotesKit/NotesScript.swift`, `NotesScript+Extra.swift`, `NotesBatchCommands.swift`, `NotesDiagCommands.swift`, `NotesReadCommands.swift`: confirmed narrow fallbacks and internal throwing propagation, with their existing script/command injection suites.
- `Sources/MailKit/Support/AccountDirectory.swift`, `MailContext.swift`, `MailScript.swift` and the Account/MessageRead/WriteManage/Analytics/Export/WriteCompose/RuleTemplate command families: checked throwing public alternatives, actual CLI migration and narrow fallback changes; existing Mail injection suites provide context/script/directory factories.
- Contacts/Messages command injection suites: already-propagating boundary controls. No production change is planned there without a demonstrated counterexample.
- README configuration section, this reviewed discovery specification and CHANGELOG Unreleased entry: public opt-in behavior and precise limits. Do not hand-edit the generated documentation index.

Package.swift and the isolated descriptor fixture do not need changes for this feature. Preserve unrelated work and existing tests.

## Acceptance matrix

1. Pure resolver: absent, valid one, leading zeros, Int.max, explicit override of invalid environment without reading it; empty, zero, negative/sign, whitespace, fraction, suffix, non-ASCII and overflowing values. Invalid configuration produces exact sanitized classification and no launch.
2. Wiring: all four forms preserve arguments/delivery and carry the same resolved limit. Default/unlimited remains nil. A reused environment-based runner resolves once per invocation. Timed invalid-timeout precedence remains unchanged.
3. Real synthetic output: parameterize all four forms over stdout-only, stderr-only and combined totals at N-1, N and N+1. Include multibyte UTF-8 and binary raw-byte boundaries. Check exact bytes under the limit and typed failure over it; the public boundary maps sanitized upstream. An unlimited control emits more than the small test limit successfully. Under-limit nonzero exit preserves scriptFailed behavior.
4. Pipe progress: overflow while stdin delivery remains pending, empty-but-open sibling stream, and output continuing after root exit. Keep bounded fixtures and prove no deadlock, no partial success and unchanged subsequent-launch usability.
5. Capture boundaries: oversize snapshot rejected before payload read; second-stream aggregate excess; growth after a prior size observation; zero remaining allowance with empty/nonempty stderr; size/read syscall errors retain their genuine original classification. Retain existing fixed-offset/snapshot tests and unlimited behavior.
6. Lifecycle: overflow during a live root and after observed root exit signals the owned group before reap, closes every owned descriptor and preserves the original overflow through cleanup. Include meaningful real inheriting-descendant cessation and existing successful/nonzero background-descendant controls. Synthetic rare authority/reap cases use the existing resource seams and never signal invented PIDs.
7. Provenance: both marked error families satisfy the predicate before and after addingBulkContext; original type, exit, status, remediation, applied and sandbox behavior remains unchanged. Wire output has no marker or additional field. An ordinary AppleError with identical type, exit and complete message is a negative control: predicate false and legacy fallback unchanged. Invalid environment values never appear in any emitted channel.
8. Domain boundaries: cover EVERY changed fallback family above with both marked invalid configuration and marked overflow, plus an unmarked error with identical public type/exit/message retaining its former fallback. Use phase-specific fake handlers, not fixture exhaustion. Include Notes batch, health/doctor, stats/recent activity, link and JSON/Markdown export; Mail unread/selected wrappers, analytics/dashboard/export, trash previews, attachment list/save, scope resolution, draft and rules. Assert exact public classification/no added fields and call ordering/counts, stopping subsequent domain runner calls and success emission after marked failure while retaining local resource cleanup. Notes existence failure makes no folder; final-ID failure produces no success; shared-note failure skips neither silently nor onward to later accounts. Mail metadata/body enrichment does not emit successful degraded output. Draft/rule catches preserve marked identity and stop later mutation/enable/lookup; marked cleanup failure never produces a removal-success claim. Pin rule verification failure before enable with no enable call, then separately inject failure during enable and at final-index readback after a successful enable: preserve existing call order, propagate uncertainty, perform no further operation, and never assert the rule remains disabled in either later case. Assert invocation counts and order plus exact envelopes/metadata, and pair each altered fallback with unmarked errors (including identical-message errors) preserving prior behavior. Notes retry and Mail candidate loops must not retry a marked policy failure.
9. Account directory: inject marked loadError and prove checked access rethrows the same error before UUID fallback, even for an index-known UUID, and before account-label/summary decoding. Exercise actual CLI consumers and a cached failed directory. Pair with unmarked fetch errors retaining headless index UUID resolution and UUID labels. Verify direct factory consumers check before selection/enrichment. No new eager directory fetch for paths that never used it.
10. Run the focused Swift suites, existing structural Python checks and canonical two-toolchain/Swift/Python/Bats gate through the controller's coordinated slots. Independent code, security and critic review are required for this subprocess/spec change before commits. Record exact evidence; do not claim a test result from source inspection.

All fixture content is synthetic and uses reserved placeholders. Temporary files belong to ScratchDirs; raw probe output stays outside the repository. No live Apple operations or personal data are needed to test this feature.

## Engineering choices resolved

- Combined rather than independent per-stream budget: one intuitive numeric allowance bounds retained raw payload and avoids a hidden 2N interpretation.
- Invocation-time environment lookup rather than a process snapshot: explicit, testable semantics and no new first-touch dependency.
- Nil inherits environment; absence selects unlimited: minimal compatible API without a new public policy enum.
- Preserve timed captures rather than introduce transport changes: maintains root-exit/background-descendant compatibility while bounding materialization.
- Internal typed overflow mapped to existing AppleError upstream with non-wire provenance: enables narrow propagation through confirmed broad fallbacks without changing unrelated errors or public envelope types.
- Source-compatible AccountDirectory accessors plus checked throwing CLI paths: prevents cached policy failures becoming successful UUID fallbacks while preserving ordinary headless behavior.

No product question remains. The additional audited fallback scope and checked interfaces are implementation details of the approved opt-in policy. Mandatory default protection and hard disk/process-memory quotas are expressly outside the approved unit.
