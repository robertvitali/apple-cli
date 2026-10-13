# Experimental Beeper-backed Messages capability port

## Contract and integration

Adapt selected MIT-licensed Beeper platform-imessage source into the existing
MessagesKit backend. Preserve its copyright and permission notice with adapted
source. Inventory dependency licenses before importing their code. Do not install
or shell out to a second messaging binary. Keep the existing runtime, AppleKit
permission/output/error/path controls, command defaults and schema version.
Existing commands remain compatible; new fields and commands are additive.
No Messages database writes, injection or system protection changes are permitted.
This is an experimental UI-backed backend contract, not a release or readiness
claim. The current design does not establish strict GUID-bearing independent AX
identity or causal completion; it uses bounded UI identity checks and observed
database postconditions. UI drift can affect the wrong message, and observed
postconditions cannot prove that no queued late action remains. Mutation result
envelopes must report the experimental status and verification string.
The approved unpublished source state adopts `27.0.0` for the macOS 27 source
baseline only. It does not cut a release, tag, GitHub Release, Homebrew update,
repository-setting change, publication infrastructure deployment, deployment-minimum
change or JSON `schema_version` change.

## Unpublished version state

Adopt the unpublished source version with one explicit marker in `CHANGELOG.md`:

```md
## [Unreleased]
<!-- apple-cli-unpublished-version: 27.0.0 -->
```

The marker appears exactly once, immediately after the sole `## [Unreleased]`
heading. Its value is strict `MAJOR.MINOR.PATCH`. It is valid only when
`Sources/AppleKit/CommandSupport.swift` declares the same
`AppleVersion.current`, no tag anywhere in the repository and no released
changelog heading already names that version, and the version's major is greater
than the highest reachable released major with `.0.0` for minor and patch. With
the retained release baseline, source adoption now declares `27.0.0`, and
`v26.0.0` remains the historical tag. `27.0.0` is an unpublished source version;
no local or remote tag or Release should exist for it during this step.

`scripts/ci/release_prep.py` provides an explicit `--source-adoption` mode
that renders the version constant and the marker into scratch only, preserving
the existing `[Unreleased]` body and main-branch manual links. The normal
release-preparation path should parse the same shared version state, treat
pending `27.0.0` as the next release version instead of recomputing a `26.x`
bump from later `feat:` or `fix:` commits, and remove the marker only in its
scratch-rendered release commit while promoting `27.0.0`. Keep the existing
explicit release-prep override semantics: a caller-supplied `--macos-major NN`
is still the way to request an intentional MAJOR move, and `--bump minor|patch`
still states an intentional release bump when no pending source-adoption marker
owns the candidate version. When a valid pending marker owns the candidate
version, incompatible `--bump` or `--macos-major` requests fail closed instead
of silently overriding it. Shared parsing must make those request inputs visible
to every caller so legitimate override overlays are compared against the version
that request asked for, not rejected against a default derivation.

`scripts/ci/site_assembly.py --derive-candidate-version` already calls release
preparation's version computation. Keep that route on the shared version-state
parser so the site rehearsal derives pending `27.0.0` without learning a
separate rule. It must retain its existing privacy property: the derived
candidate version is routing input only and is not printed or written to the
value-free report.

The parser fails closed on malformed, multiple or misplaced markers; marker and
constant mismatch; a source constant ahead of the latest release without the
marker, except for an explicitly detected fully prepared release commit awaiting
its tag; marker plus matching tag or released heading; a declared version that
does not match the shared version state; and a non-empty `[Unreleased]` section
after an awaiting-tag release commit. Re-running source adoption for the same
valid marker/constant pair is an explicit no-op.

`scripts/ci/release_artifact.py` should add optional `--bump minor|patch` and
`--macos-major NN` inputs matching release preparation, keep the current default
when neither is passed, and feed those values into the same shared version-state
computation without printing or reporting the derived version. It must compare
the overlay against that requested candidate state rather than accepting only
scratch release-prep output. It must reject stale overlays, overlays that still
carry the unpublished marker, and overlays whose version matches neither the
default shared state nor a compatible explicit `--bump` or `--macos-major`
request.
The source exception also needs matching policy text in `AGENTS.md`,
`README.md`, `docs/versioning-policy.md` and `HUMAN-DECISIONS.md`; those edits
belong to the implementation, not this discovery note. The `README.md` change
must make source `27.0.0` visibly unpublished while retaining the real
compatibility caveats for supported macOS versions.

## Exact reads and identity

Add bounded all-conversation discovery, per-conversation history and
single-message lookup. Existing named-group chats behavior remains the default.
Message mutations and replies require explicit conversation/message identities
and applicable native parts; validate exact database chat/message/native-part
membership in a read-only snapshot. Conversation operations require exact
conversation identity. Creation requires resolved recipients and service.
Preserve existing recipient/contact send semantics. Never select by body text,
latest message, contact name, apparent UI activity or geometry offsets. A message
belonging to several conversations must retain the caller-selected membership.

Use persistent database GUIDs where available, retaining local ROWIDs as local
selectors. Expose native part identifiers only when decoded from attributed-body
metadata; never pretend an attachment position or text offset is a native part.
Default reaction targeting may select the sole proven native part; it must never
fabricate part `0` or any other implicit part, and must require explicit part
selection when several native parts are possible.
The experimental UI route may use GUID/native-part deep links, but only with the
strict UI identity checks below. Preserve bodyless records and distinguish
missing messages from undecodable bodies. Missing required schema and failed
queries are errors, not empty pages. Treat every archived
body as untrusted: prohibit unrestricted NSUnarchiver/NSKeyedUnarchiver object
instantiation; use a constrained parser or explicit secure class allowlist. Bound
blob size, depth, object count and reference traversal; detect cycles. Unsupported
encodings remain undecodable rather than invoking an unsafe fallback.

Pagination uses deterministic keysets with a tie-breaking ROWID, versioned cursors
bound to operation, selected conversation, filters and ordering. Validate cursor
size, shape and scope. Capture an insertion upper bound on the first page and use
it on later pages. Each invocation reads a fresh snapshot: edits/deletions are
visible and snapshot cost is not bounded by the output limit. Normalize supported
Apple timestamp encodings before ordering, with synthetic mixed-encoding tests.

## Automation and mutation safety

A shared AX backend serializes the complete resolution/action/verification cycle
across processes using a per-user advisory lock in a protected application-state
directory. Validate directory/file ownership, permissions and symlink refusal;
lock acquisition has a deadline and descriptors close on every path. Do not unlink
a held lock. The same lock spans pre-read/no-op checks, worker handoff, post-read
verification and receipt update. Use one end-to-end deadline and cap retries to
read-only phases or cases with proof no mutating request was delivered. Return
explicit permission, unsupported-platform, target-mismatch and uncertain-outcome
errors. Run mutating AX calls in a bounded, hidden worker mode of the same
executable, with a private bounded request/response channel. Keep the lock and
operation-state ownership in the parent; the worker must not independently start
operations or clear their records. Worker mode accepts no targets or actions from
arguments, environment variables or standard input. It requires a parent-created
inherited anonymous channel, verified parent identity and a fresh one-operation
nonce bound to the pending record. Reject
standalone invocation and mismatched/replayed requests; exit after one bounded
request. The worker acknowledgement must carry the nonce-bound operation outcome;
the existing normal/refused/failed outcome enum is sufficient when bound to the
nonce. The parent independently verifies state under the lock before resolving
anything, and an ACK alone is insufficient. These checks prevent a separate
command path from bypassing the parent policy, lock and pending-state gate; they
do not claim isolation from a hostile process with the same user privileges. This
avoids a separately installed messaging binary or companion executable.

Before issuing any potentially mutating request, durably record the operation in
the protected state directory using atomic replacement and file/directory sync.
The record contains a versioned operation identity, exact targets, action and
verification state, with strict size/shape validation and private permissions.
Persist only opaque conversation/message/part identifiers, operation type and the
minimum verification evidence. Use bounded hashes and lengths instead of message
bodies or attachment paths where comparison is needed; omit contact names and
recipient addresses. Any operation that requires additional sensitive persistent
state needs an explicit reviewed justification. Never put target values or payloads
in diagnostics. Observed-state resolution or explicit operator recovery must
atomically remove the sensitive pending payload while recording only the
operation identifier and disposition in a bounded local receipt. Recovery must
name the unresolved operation, explain possible late effects and require
explicit acknowledgement; ordinary reset, cleanup or no-op handling cannot
silently remove the write gate. Define and test receipt retention and
interrupted cleanup before adding that storage.
Cancellation or timeout must stop and reap owned helper processes before releasing
the lock, but helper termination does not cancel requests already delivered to
Messages. Preserve an unresolved record on timeout, crash, cancellation, failure,
identity mismatch or uncertain delivery after any possible handoff to Messages.
Every later caller checks this record under the same lock and refuses new
Messages UI writes while it remains unresolved. Read-only status and
reconciliation may run.
Malformed, inaccessible, foreign-owned or unsafe operation state also blocks writes.

Resolve the record automatically only when no mutating request was issued, or
after a normal nonce-bound worker outcome plus the operation-specific observed
postcondition while the operation still holds the lock. Persisted message and
reaction mutations require exact database verification. Non-persisted operations
such as typing require bounded UI/AX observation and evidence of their owned
lifetime and cleanup; their verification string must name that evidence rather
than imply a database check. That resolution has
`observedState` disposition and an explicit result verification string; it is
not causal completion and does not prove that no late queued action remains
inside Messages. A matching current snapshot alone never clears a failed or
uncertain operation: another actor may have produced it while this operation's
toggle or keyboard action is still queued. Idempotence alone is insufficient too,
because a late request could overturn a later conflicting operation. Prior
failed or uncertain operations require explicit operator recovery that explains
possible late effects; never automatically clear them after a delay. The backend
promises termination of owned helpers and durable gating of later writes, not
cancellation or quiescence inside Messages. Tests cover crashes before request
delivery, after delivery, after verification but before record cleanup,
cancellation, worker failure, identity mismatch and a competing process
attempting a new write at each boundary.

An advisory lock cannot exclude the user or unrelated automation. Bind exact
database conversation/message/part identifiers plus process/window/route objects
and revalidate immediately before every side effect; abort on drift. Reaction
writes additionally bind the parent ACK to the pending operation and require a
fresh database read proving target identity and mutation eligibility before the
parent records observed state.

Select a conversation by its exact native identity and resolve message/part
through experimental GUID/native-part UI deep links. Database membership alone
does not prove the selected UI conversation. Require strict stable
process/window/transcript identity and a unique selected route before every side
effect; when unavailable, fail closed. Forbid body/latest-message, same-contact,
geometry-offset, focus-change and sleep-based targeting fallbacks. Evaluate a
secondary Messages instance in isolated manual validation; never assume it
preserves correctness or desktop state.

Application-window membership uses the canonical process root's bounded, typed
`AXWindows` list. Require one window, stable enumeration, the expected process
owner and exact retained identity where one has already been captured. Unknown or
unsupported membership is a refusal. Window validation does not traverse child
controls; transcript/message and detached chooser ownership are checked separately.

Reaction set/remove use the native Tapback picker as the local reaction-state
oracle. Strict mode is the default. `--experimental-ui-handoff` only opts into
the native picker transition that can temporarily hide the transcript; it does
not choose the post-press verification branch. In either strict or experimental
mode, the preferred `.present` branch presses at most one reaction button,
observes the requested selected state on the same retained picker/button, then
cancels only that owned picker and verifies dismissal before ACK. The parent
still requires fresh database target identity and eligibility before recording
observed state.

If the picker disappears before selected-state proof, the same `.absent` fallback
can be used after either mode only by restoring the exact original
process/root/window/transcript/message identity route. When the disappearance
comes from a hidden-transcript picker transition, `--experimental-ui-handoff`
must have been supplied on that invocation. The fallback does not deep-link,
navigate to another message or require a selected-message flag. It waits for the
original AX objects to be uniquely reachable under the same process/root and
ownership, confirms the picker is absent immediately before opening the
canonical menu from that retained message, then verifies the requested selected
state and owned cleanup. Continuity depends on exact retained object identity
and membership. Replacement objects, foreign ownership, duplicate candidates,
missing canonical actions, failed readiness checks, unknown selected state or
cleanup failure leave the operation uncertain. No mode or branch ever presses a
second reaction button.

The experimental handoff cannot prove original-message continuity during the
modal transcript replacement, cancellation quiescence inside Messages, or durable
sync completion. The user must leave Messages untouched during execution, and
post-verification cannot undo a reaction redirected by desktop interference.
Custom emoji set/replace verifies an already-selected exact picker button as an
unchanged result. An unselected or absent button uses the owned detached chooser
route below; unknown selected state is refused. Explicit custom
removal uses the existing exact picker-button route with byte-for-byte matching.
Before pressing a selected custom button, it waits a bounded 750 ms for picker
animation, then revalidates the retained route, picker, button and selected state. Implicit custom removal is refused on execution. A
missing button never proves absence; if the exact button disappears after a
press, verification fails and the operation remains pending. Repeat removal is
a verified no-op only when the exact button remains exposed and unselected.

Every write uses AppleKit execution and sandbox policy once at command entry.
Dry-run returns a resolved preview without driving AX, launching UI workers or
changing state. Execute returns dry_run false. For database-only operations with authoritative
pre-read evidence, a no-op found under the lock may return distinct
`already_in_desired_state`, creates no observed-state receipt when no operation
record was written, and cannot bypass a pending record. Reaction writes use the
UI picker state as the local oracle instead: already-desired or already-absent
performs no reaction press but still passes the pending-operation gate and worker
verification. A mutating handoff reports experimental `observedState` only after
observing its documented operation-specific postcondition.
Uncertain writes are reconciled before any retry; sends are never blindly retried.
Absence in a delayed database snapshot is not proof that a send failed. Refuse
pre-existing composer content unless an operation explicitly supports preserving it;
never send or clear unknown drafts. Cleanup only state created by this operation
that is still provably owned and unchanged by the user.
Agent live validation uses only newly created, labeled, privately tracked disposable
self-addressed fixtures. Non-self/group operations require operator participation.

## Custom emoji chooser ownership and verification

The custom chooser is a separate native surface. Retain the exact message route
and Tapback picker before opening it. Discover its launcher only as the uniquely
owned sibling of that picker, with the native custom-reaction description and
an enabled press action. Launcher recognition currently requires the observed
English Accessibility description; other UI languages are unvalidated and may
refuse. Generic emoji controls elsewhere in the window do not qualify. Strict mode retains its original route requirements; experimental modal
handoff does not authorize arbitrary window or message replacement.

The detached chooser may be absent from the application root's ordinary AX tree.
Bounded on-screen window metadata and an AX hit test locate a candidate search
field; geometry is discovery only, never message identity or selection evidence.
Verify actual AX process ownership, search-field role/subrole and parent popover,
then require one unique retained search/popover pair under the same process launch.
Before pressing the launcher, require verified chooser absence; ambiguity or a
read failure is not absence. Never adopt an already-open chooser. The search
must initially be empty, enabled and writable. Search-field discovery inspects only
that popover's direct navigation children, or direct ordinary children when the
navigation relation is explicitly unavailable. Require one matching search field
with the retained popover as its actual parent; do not walk emoji-result subtrees
or recursively adopt a nested field to locate the search control.

An optional guarded CharacterPicker framework lookup derives a bounded localized
search term and its native result index, following the upstream CharacterPickerSearch
sequence. Refuse unavailable classes/selectors, incompatible method signatures,
malformed results, duplicate exact matches and indexes outside the 256-result cap.
Require the requested emoji's exact UTF-8 bytes; a normalized base emoji is not a
match. Refuse requests that require a separate skin-tone picker rather than accepting
its default variant. Write the chosen query once, read back, and allow bounded
read-only readiness under the shared deadline. Cleanup before keyboard navigation
clears only the retained field while its current value still equals this operation's
query. Preserve user edits; never restore the query after starting navigation.

After writing the query, traverse the entire uniquely owned popover for candidates,
preferring navigation children and
falling back to ordinary children only when the navigation attribute is known
absent or unsupported. Enforce complete bounded traversal, actual process ownership
and strict AX types. Read ordinary `AXChildren` as a full array after checking its
count against the cap: the indexed API can return fewer children despite an
unchanged reported count. Require the full array and recount to match the initial
count, with every entry an AX element. Other relationships retain their existing
readers. Compare description, text value and title with the original
emoji's exact UTF-8 bytes. Known non-text scalar values are not emoji candidates;
unknown types, read errors, incomplete traversal and duplicate pressable matches
refuse selection. A matching static-text child is not a second pressable match.
The candidate's action and glyph attributes establish result identity, not proof
that invoking `AXPress` commits a reaction. The observed native result item
has role `AXUnknown`, no subrole or enabled value, and only `AXPress`.
Accept that specific shape only when its description matches the exact emoji
and it has one directly owned, enabled `AXStaticText` child with the same exact
text value. Revalidate that proof before keyboard selection. Explicitly disabled candidates,
missing or ambiguous glyph children, foreign ownership and malformed attributes
remain refusals; passive container states never supply enabled proof.
No variation-selector removal, skin-tone substitution, clipboard or default emoji
fallback is permitted.

Custom selection follows Beeper's complete native sequence: settle the query for
0.75 seconds, send Down to enter the result matrix, then navigate the mapped index
in the six-column grid with Down/Right and short bounded pauses, followed by one
Return. This explicitly replaces the earlier direct candidate-AXPress design.
Use a non-null HID event source and post only to the retained Messages PID, with
the upstream main-thread and macOS key-up handling. Revalidate process/frontmost
identity, retained popover/search ownership and unchanged query before every key.
When focused-element evidence is available, contradictory ownership refuses the
operation; an unavailable focused/selected result-cell attribute is not a new
requirement. Revalidate complete exact candidate identity immediately before Return.
All pauses and keys share the existing deadline. Never repeat Return, fall back to
AXPress or post global keys. A failed sequence stays uncertain.

Native result order and the six-column layout are private macOS behavior. Validate
their correspondence on the supported host before claiming live support; do not
infer every locale, result index or emoji variant from a small fixture exercise.
After selection, restore and verify
the original retained message route without another deep link. Reopen its canonical
picker and require the exact reaction to be selected before owned cleanup and ACK.
A zero-exit UI action or an unselected returned button never proves success.
Any uncertain post-selection result remains pending for reconciliation.

Before opening the custom chooser, native-picker readiness may discard and retry
an inconsistent child-count snapshot within its existing bounded read window.
Each retry revalidates the retained route. Identity, type, transport and traversal
failures still stop the operation; opening the picker is never repeated.

Automation failure details use a fixed, privacy-safe vocabulary. Target drift
reports the execution phase and, where known, whether the UI relationships,
retained window, picker, button or selected state changed. Verification failures
also distinguish the existing-button and custom-chooser paths and identify route
discovery, picker validation or a mismatched final selected state. Retained-route
discovery distinguishes a missing transcript, missing retained message, replaced
transcript, missing reaction action and a still-present native Tapback picker.
Absence reasons retain the existing bounded read-only wait; they do not prove
that a custom chooser dismissed or that a reaction was applied. These diagnostics
do not expose native UI values, relax identity checks or authorize an automatic retry.
Custom-chooser transport failures and unavailable-control refusals identify the
same finite execution phases, while preserving their distinct failed and refused
outcomes. Readiness polling retains the last phase without extending its deadline
or repeating a write.

## Approved feature behavior

The following list defines the full approved delivery scope. It is not a claim
that every capability is implemented or verified in the current candidate. The
approved product scope includes standard and custom reaction set, replace and
remove. The reaction candidate includes standard reactions, explicit custom removal and
custom set/replace. The scope below does not establish general emoji-variant
support or live reliability.

1. Exact targeting and bounded reads establish the identity contract above.
2. The shared automation backend establishes locking, deadlines and diagnostics.
3. Reaction inspect plus set/replace/remove supports the approved standard and
   custom reaction scope. Read database reaction evidence without reclassifying
   raw authorship; database outgoing absence alone never proves local UI absence,
   especially in self-chat echo cases. For set/remove, read native picker
   selected state, press at most once, verify the requested selected state
   through the `.present` or `.absent` route above, then verify fresh database
   target identity and eligibility before reporting
   `verification_source: ui_selected_state_and_database_identity`.
   Already-selected set and unselected explicit remove are verified no-change
   results with `reaction_changed: false`; unresolved pending operations still
   block new writes. Implicit remove refuses when the database cannot resolve one
   reaction and requires explicit `--reaction` or `--emoji`. Custom removal
   requires explicit `--emoji` even if database evidence identifies one outgoing
   custom reaction. Custom set/replace follows the owned chooser contract above
   when its exact picker button is unselected or absent. An already-selected
   exact button is a verified no-op; unknown selected state is refused. Do not copy upstream skin-tone
   stripping or treat UI action completion as success.
4. Text and attachment replies require exact quoted message/part identity and verify
   the persisted reply relationship through the same observed-state contract.
   Preserve existing attachment path controls.
5. Rich reads expose supported reply relationships, authors, edits, delivery/error/
   read metadata, unsend markers, mentions and stickers. Missing/unsupported fields
   remain distinguishable; sticker reaction writes are unsupported.
6. Events follow the explicit restart contract below.
7. Attachment retrieval distinguishes pending, downloaded, missing and failed; it
   validates existing output/path controls and verifies the resulting readable file.
8. Typing on/off uses a bounded lifetime and ownership-checked cleanup; activity observation reports
   unknown distinctly. Document platform limits, including group typing support.
9. Edit requires an eligible own sent message, preview, runtime eligibility check
   and persisted content/history verification.
10. Undo Send is explicitly named and requires own-message and time/eligibility
    checks plus observed unsend state. It is never described as delete-for-me.
11. Read/unread and mute/unmute verify final state. History reads do not drive AX
    or silently mark a conversation read.
12. DM/group creation previews resolved recipients and initial content; upstream
    requires an initial send, so the command documents that side effect. Return
    the verified conversation identity, never a boolean when resolution fails.
13. Focus observation and Notify Anyway are separate explicit operations. No send
    or reply automatically invokes Notify Anyway.

## Event restart and replay contract

Expose newline-delimited versioned JSON envelopes and explicit bounded filters.
Use a durable, private per-consumer journal with monotonically increasing sequence
numbers and an opaque checkpoint bound to journal generation and filter signature.
Use one cross-process bounded-lock writer per consumer journal. Persist appended
events, prior normalized observation state/fingerprints and scan progress in one
transaction before emitting them. Filters are immutable within a generation; reject incompatible reuse
and require explicit new-generation initialization. Resume replays journal records after the supplied checkpoint;
consumers persist the checkpoint after handling an event and tolerate duplicates.
A crash before consumer checkpoint persistence can replay an event. Initial start
captures a baseline; historical backfill is explicit. Polling observes snapshots,
not every intermediate state: coalesced or unobservable transitions are not promised.

Track new records and observed changes to edits/reactions/attachments/read/delivery
state, including pending hydration. Rescan the full subscribed scope in bounded-memory
pages, retaining durable comparison state independently of journal retention. Snapshot
boundaries define each scan; insertion cursors alone cannot detect older-row changes.
Retention bounds journal disk usage; comparison-state storage scales with subscribed
scope and must be documented. Do not silently substitute a recent-message window. Reject an
expired/generation-mismatched cursor with a resynchronization-required error, never
silently jump ahead. Tests cover crash boundaries, duplicate replay, filter mismatch,
retention gaps, simultaneous consumer starts, observation-state/append crash points
and state changes without newly inserted message rows. Sensitive
journal payloads stay local with restrictive permissions and explicit reset behavior.

## Verification and delivery

Deliver targeting/AX/reactions first, then replies/context/events/attachments, then
remaining operations. These are validation boundaries, not new authorization gates.
Keep each feature in a focused reviewed commit and update generated manuals and
Unreleased notes. Use synthetic database/UI fixtures for malformed selectors,
duplicate bodies, multi-chat membership, absent metadata, permissions, lock
contention, timeouts, pre-existing drafts, user interference and verification
failures. Include malformed/cyclic/oversized archives, unexpected classes, stale
AX elements, delayed action completion, cancellation and an immediately competing
invocation. Independent code/security/critic review covers sensitive changes.
Before each push run canonical Swiftly build/tests, CLT build and recursive Bats
on the committed SHA. Record source-supported versus runtime-proven behavior and
unresolved manual checks privately; incomplete live proof does not satisfy final
feature acceptance. No private tracker IDs or live identities belong in this
document, fixtures or commit metadata.

For the unpublished version-state implementation, add meaningful red/green tests
around `Tests/automation/test_release_prep.py`, `Tests/automation/test_release_artifact.py`
and any shared parser helpers introduced under `scripts/ci/`. Cover valid
source adoption, repeated adoption as a no-op, every marker/constant/tag/heading
failure above, pending `27.0.0` overriding later default bump math, normal prep
removing the marker only in scratch, and artifact overlay rejection for stale or
marker-bearing overlays. Existing local compatibility evidence from commit
`826d9c2` is limited to 2001 Swift tests passing and 482 recursive Bats tests
with 3 skips on macOS 27.0 build 26A428, SDK 26.4.1, CLT Swift 6.3.1 and
Swiftly 6.4; it supports the current baseline but is not proof that every live
Messages capability in this plan works.
