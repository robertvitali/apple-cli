# Beeper-backed Messages capability port

## Contract and integration

Adapt selected MIT-licensed Beeper platform-imessage source into the existing
MessagesKit backend. Preserve its copyright and permission notice with adapted
source. Inventory dependency licenses before importing their code. Do not install
or shell out to a second messaging binary. Keep the existing runtime, AppleKit
permission/output/error/path controls, command defaults and schema version.
Existing commands remain compatible; new fields and commands are additive.
No Messages database writes, injection or system protection changes are permitted.
No version bump or release is part of this work.

## Exact reads and identity

Add bounded all-conversation discovery, per-conversation history and single-message
lookup. Existing named-group chats behavior remains the default. Message mutations and replies require explicit conversation/message identities and
applicable native parts; validate membership in a read-only database snapshot.
Conversation operations require exact conversation identity. Creation requires
resolved recipients and service. Preserve existing recipient/contact send semantics. Never select by body text, latest message, contact
name or apparent UI activity. A message belonging to several conversations must
retain the caller-selected membership.

Use persistent GUIDs where available, retaining local ROWIDs as local selectors.
Expose native part identifiers only when decoded from attributed-body metadata;
never pretend an attachment position or text offset is a native part. Preserve
bodyless records and distinguish missing messages from undecodable bodies. Missing
required schema and failed queries are errors, not empty pages. Treat every archived
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
a held lock. Use one end-to-end deadline, capped retries and explicit permission,
unsupported-platform, target-mismatch and uncertain-outcome errors. Cancellation or
timeout must quiesce all queued/in-flight AX work before releasing the lock; no
background action may write after another caller acquires it. An advisory lock
cannot exclude the user or unrelated automation. Bind process/window/conversation/
message identity and revalidate immediately before every side effect; abort on drift.

Select a conversation by its exact native identity and resolve message/part through
GUID-bearing UI identifiers. Database membership alone does not prove the selected
UI conversation. Require independent exact UI identity evidence; when unavailable,
fail closed. Evaluate a secondary Messages instance in isolated manual validation;
never assume it preserves correctness or desktop state. Do not adopt upstream
same-contact, focus-change or sleep-based targeting fallbacks.

Every write uses AppleKit execution and sandbox policy once at command entry.
Dry-run returns a resolved preview without driving AX or changing state. Execute
returns dry_run false and only claims success after observing the postcondition.
Uncertain writes are reconciled before any retry; sends are never blindly retried.
Absence in a delayed database snapshot is not proof that a send failed. Refuse
pre-existing composer content unless an operation explicitly supports preserving it;
never send or clear unknown drafts. Cleanup only state created by this operation
that is still provably owned and unchanged by the user.
Agent live validation uses only newly created, labeled, privately tracked disposable
self-addressed fixtures. Non-self/group operations require operator participation.

## Feature behavior

1. Exact targeting and bounded reads establish the identity contract above.
2. The shared automation backend establishes locking, deadlines and diagnostics.
3. Reaction inspect/set/replace/remove supports standard and supported custom emoji.
   Read the current outgoing reaction; already-desired/absent is idempotent. Preserve
   exact grapheme identity, toggle once and verify the observed final reaction.
   Investigate picker identifiers and selected state for custom removal. Do not
   copy upstream skin-tone stripping or treat UI action completion as success.
4. Text and attachment replies require exact quoted message/part identity and verify
   the persisted reply relationship. Preserve existing attachment path controls.
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
Use one bounded-lock writer per consumer journal. Persist appended events, prior
normalized observation state/fingerprints and scan progress in one transaction before
emitting them. Filters are immutable within a generation; reject incompatible reuse
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
duplicate bodies, multi-chat membership, absent metadata, permissions, lock contention,
timeouts, pre-existing drafts, user interference and verification failures. Include
malformed/cyclic/oversized archives, unexpected classes, stale AX elements, delayed
action completion, cancellation and an immediately competing invocation. Independent code/security/critic review covers
sensitive changes. Before each push run canonical Swiftly build/tests, CLT build and
recursive Bats on the committed SHA. Record source-supported versus runtime-proven
behavior and unresolved manual checks privately; incomplete live proof does not
satisfy final feature acceptance. No private tracker IDs or live identities belong
in this document, fixtures or commit metadata.
