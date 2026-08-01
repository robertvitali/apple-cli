# Write-model v2 — the CLI behaves exactly like the MCPs

**Operator decision (Robert, 2026-08-01, verbatim):** *"the apple cli should be a replacement
for the mcp. it should behave exactly like the mcp just as a cli. read, write etc."*

Asana: task GID-REDACTED ("Write-model v2"), resolving the write-gate HIGH findings of
[parity-audit-2026-07-31.md](parity-audit-2026-07-31.md). Revised after a full 3-reviewer
fan-out (REQUEST CHANGES ×3); every oracle claim below was re-verified against oracle source
on disk after review found three of the first draft's rows factually wrong.

## The principle

**A CLI invocation behaves like the equivalent MCP tool call.** When an MCP client calls
`update_contact`, the contact is updated. The CLI is a replacement for those servers, so
`apple contacts update …` does the same. The invocation is the consent, as the tool call is.

Every gate-shaped behavior in the CLI is classified into exactly one of FOUR buckets. An
implementer must never have to guess a bucket — unclassified gate code is a spec bug:

1. **Oracle-mirrored gates — KEPT, always apply.** The oracle itself performs them, so they are
   part of the behavior being replicated. Where this repo hardened one (case-insensitive
   blocklist, control-character rejection in `confineWriteDestination`), the hardening stays:
   refusing an attack path the oracle is merely *vulnerable* to is not a capability drop.
2. **Additive extras — KEPT.** `--dry-run` availability, structured refusal envelopes, honest
   `expunge_unsupported` reporting. Supersets, not gates.
3. **CLI-only gates — become SANDBOX-ONLY.** Label guards, self-only recipient allowlists, and
   similar restrictions with no oracle counterpart apply only inside the opt-in sandbox.
4. **Oracle-side gates with no CLI channel — documented divergence.** Oracle A wraps exactly
   six tools in MCP *elicitation* (`_elicit_confirmation`, server.py:105-123; call sites
   verified at :340 delete_rule, :516 update_rule, :909 send_email, :1105
   send_email_with_attachments, :1884 forward_message, :2095 delete_template).
   `reply_to_message` is NOT elicited — it is a synchronous `def` (server.py:1767); what oracle
   A does instead is BLOCK it inside test mode (security.py:392-398, "recipients cannot be
   verified without fetching the original message") — a test-mode restriction, not elicitation.
   Elicitation is an out-of-band human accept with a `{"error_type": "cancelled"}` decline
   path. A CLI has no elicitation channel; the deliberate mapping is: **the explicit invocation
   is the accept**, and `--dry-run` is the decline-equivalent preview. This is a real
   divergence from oracle A (oracle B has no elicitation and executes immediately, so it is
   exact parity with B), and it is recorded here rather than silently absorbed. Note the
   overlap with the bucket-2 obligation: `mail templates delete` is BOTH an elicited oracle
   tool AND a command whose execute path omits `dry_run: false` — it needs the explicit key and
   the divergence callout together.

### Oracle-mirrored gates the first draft missed (bucket 1, now enumerated)

From oracle A `security.py` — all three are PORTED, because dropping them is a parity gap:

- **Rate limiter** (`TIER_LIMITS`, security.py:116-120; `check_rate_limit`, :180-194): sends
  capped at 3/60s sliding window, expensive ops at 20/60s.
- **Bulk-delete cap**: 100 messages per call (server.py:1718-1724).
- **Recipient cap**: 100 recipients per send (security.py:89-91).

### Bucket-2 obligation, not assertion

`--dry-run` must actually work on every mutating subcommand. It does not today:
`mail templates save` has NO `willExecute` branch and writes unconditionally
(RuleTemplateCommands.swift:436-448). The rollout includes an audit of every mutating
subcommand for a `willExecute` branch; any without one is fixed or explicitly excepted with
rationale in this file. Every execute-path envelope must emit `dry_run: false` explicitly
(TemplatesDelete currently omits it), because under v2 that key is how a caller distinguishes
"previewed" from "done".

## Defaults are mapped per oracle surface — NOT a blanket flip

| Surface | v1 default | v2 default | Why |
|---|---|---|---|
| General write ops (create/update/move/flag/mark/rules/templates/notes/contacts/events/reminders/sends/export/attachments save) | dry-run; `--execute` opts in | **execute**; `--dry-run` opts out | The oracle executes on call. Oracle B's `move_email` exposes `dry_run=False` (tools/manage.py:32); `manage_trash` at :513 is the deliberate exception, which the trash row below preserves. |
| `mail delete` (trash surface) + `mail trash empty` | dry-run | **dry-run** (unchanged) | **Oracle B's `manage_trash` defaults `dry_run=True`** (tools/manage.py:513). Keeping dry-run-by-default here IS parity; flipping it would diverge on the most destructive surface. |
| `mail trash empty` confirmation | `--confirm` + `APPLE_ALLOW_EMPTY_TRASH=1` | `--confirm` (oracle B `confirm_empty=True`, manage.py:510) **and `APPLE_ALLOW_EMPTY_TRASH=1` stays UNCONDITIONAL** | The env var is an *operator affordance an agent cannot self-grant* — the only agent-proof control on the one op that destroys unlabeled real data wholesale. Not a test gate; not lifted. |
| `mail delete --permanent` | THREE factors: `--test-mode` + `APPLE_TEST_MODE=1` (WriteManageCommands.swift:266), `APPLE_ALLOW_PERMANENT_DELETE=1` (:257), per-target `requireCanonicalLabels` (:316) | test-mode factor lifts (bucket 3); **`requireCanonicalLabels` and the operator env var stay UNCONDITIONAL** | **There is no oracle contract to defer to**: oracle A's `delete_messages(permanent=True)` is a documented no-op ("Reserved; currently a no-op", server.py:1670-1685), and oracle B's permanent path silently fails on IMAP. Permanent erase is a CLI-only capability; parity cannot justify ungating it. Like `APPLE_ALLOW_EMPTY_TRASH`, the env var is an operator affordance an agent cannot self-grant. |
| `contacts delete`, `contacts groups delete` | two-factor + label | **hard gate stays, and it reads the ENV signal ONLY** (`TestMode.isTruthyEnv`, NOT the threaded `sandboxActive`) | **Oracle-mirrored**: `require_test_mode_for("delete_contact"/"delete_group")` refuses outside `CONTACTS_TEST_MODE=true` (apple_contacts_mcp security.py:161-179; server.py:965, :1715 — "only safe to expose in test mode until v0.4.0 ships the confirmation flow"). The oracle keys this gate to an ENVIRONMENT VARIABLE, so the CLI mirror does too — a `--test-mode` flag must NOT satisfy it, or an agent could self-grant the very gate the oracle reserves to the operator (the same reasoning as the `APPLE_ALLOW_*` rows). Bucket 1, not bucket 3. |
| The other 9 Contacts write ops | two-factor + fetched-target label | sandbox-only | Oracle default-permissive for these; the CLI gate is bucket 3. |

### Corrected v1 baseline (the first draft called it uniformly two-factor — wrong)

- Mail, Contacts, Calendar, Reminders: `--test-mode` flag AND `APPLE_TEST_MODE=1` (two-factor).
- Notes: env-only (`guardLiveWrite` checks `TestMode.isEnabled` alone, NotesCommand.swift:92).
- Messages: the two factors live in two separate guards (MessagesCommand.swift:182 checks the
  flag; Send.swift:60 `assertAllowedRecipient` checks the env).

The migration therefore classifies tests per-test, not per-class (see Migration below).

## The sandbox

`APPLE_TEST_MODE` truthy (see below) **or** `--test-mode` engages the opt-in sandbox: label-
gated targets, self-only sends — today's exact restriction set. Either signal alone engages it:
in v2 the sandbox is a *restriction*, and a restriction should be the easy thing to turn on
(v1's two-factor guarded against accidental *writes*; v2's single-signal guards against
accidental *unsandboxed* writes — each fails safe for its own model).

- **The sandbox is a POLICY MODE, not an isolated store.** Every write still lands in the real
  Apple databases; "sandbox" restricts *which items* may be touched (labeled ones) and *who*
  can be reached (the operator's own addresses). Sends inside it are REAL, deliverable mail and
  iMessages — unlike oracle A's test mode, which confines recipients to undeliverable RFC-2606
  reserved domains (security.py:429-437).
- **Fail-loud activation.** `APPLE_TEST_MODE` accepts `1`/`true`/`yes` (case-insensitive).
  Any OTHER non-empty value is a `validation_error` (exit 64) at the start of any write
  command — never silently "no sandbox". (`""`/unset = off, as today.)
- **Visible engagement.** Every write envelope gains `"sandbox": true` when the sandbox is
  active (key absent otherwise — additive, MINOR). Mechanism, so no one threads a flag through
  94 emit sites: `SuccessEnvelope` (Output.swift:91-96) gains `let sandbox: Bool?`;
  `Output.encodeSuccess(tool:data:sandbox:)` / `Output.emit(tool:data:sandbox:)` take
  `sandbox: Bool? = nil` so every read path compiles unchanged; the five domain emit wrappers
  gain the same defaulted pass-through; only write commands pass `sandboxActive ? true : nil`.
  `Sources/AppleKit/Output.swift` + the five wrappers are part of the core change set.
- **Writes only.** The sandbox affects write paths exclusively; read commands return identical
  output with it on or off (per-domain test required).
- **`APPLE_DRY_RUN`** (new, additive, orthogonal): an operator-level persistent preview
  default. When truthy, writes default to dry-run again; an explicit `--execute` overrides it.
  This restores a durable "safe posture" for anyone who wants v1 ergonomics. **Identical
  fail-loud contract to `APPLE_TEST_MODE`**: accepts `1`/`true`/`yes` (case-insensitive);
  `""`/unset = off; any OTHER non-empty value is a `validation_error` (exit 64) at the start of
  any write command — never silently "no dry-run". Both variables parse through ONE shared
  helper (`TestMode.truthyEnv(_ name: String) throws -> Bool`) so their contracts cannot
  drift, with a swift-tier case asserting the rejection for each. `TestMode.isTruthyEnv` (used
  by `sandboxActive` and the contacts-delete gate) is the non-throwing accessor over
  `truthyEnv("APPLE_TEST_MODE")` — safe because the throwing validation for BOTH variables runs
  in the write-command preamble before any gate reads it.
- Precedence: `--dry-run` > `--execute` > `APPLE_DRY_RUN` > v2 default (execute, except the
  trash surface).

## Core implementation (AppleKit)

- `GlobalOptions.willExecute` becomes a METHOD, not a property:
  `willExecute(defaultDryRun: Bool = false)` — `dryRun` wins over everything; otherwise
  `execute` forces true; otherwise `APPLE_DRY_RUN` truthy makes it false; otherwise
  `!defaultDryRun`. Trash-surface commands pass `defaultDryRun: true`. **Per-command
  discipline, enforced at review**: every mutating command's `run()` binds the result ONCE at
  the top (`let willExecute = global.willExecute(defaultDryRun: Self.defaultsToDryRun)`) and
  uses only that local thereafter. This matters because DeleteCommand reads the old property at
  four sites (:265, :285, :313, :323) and TrashEmpty at three (:405, :414, :424) — seven
  independent reads each making its own decision; a partial conversion would either regress
  `--permanent` to a hard refusal or silently trash real mail by default. Bind-once makes a
  missed site a compile error, not a latent divergence.
- **Guards change signature — this is explicit, not "unchanged".** Sandbox state becomes a
  parameter and the internal `TestMode.isEnabled` re-checks are REMOVED (they would defeat the
  flag-only path): `requireLabeledTarget(_:sandboxActive:)`, recipient checks likewise.
  `TestMode.sandboxActive(flag:) = flag || isTruthyEnv` is computed once per command and
  threaded down. This also gives the swift logic tier both branches as pure calls — no env
  mutation in tests.
- Help strings land with the flip, specified here verbatim:
  - `--dry-run`: "Preview without performing the write (writes execute by default; --dry-run
    always wins)."
  - `--execute`: "Perform the write (the default; kept for explicitness and to override
    APPLE_DRY_RUN=1)."
  - `--test-mode`: "Engage the test sandbox: writes restricted to apple-cli-test-labeled items,
    sends to APPLE_TEST_RECIPIENTS only. Equivalent to APPLE_TEST_MODE=1."

## Gate-site inventory (exhaustive, from a mechanical sweep — 109 references, 22 files)

Chokepoints (where the `sandboxActive` parameter actually lands). Counts AND line numbers are
sweep output from 2026-08-01 against oracle A @0.6.0 / oracle B @3.1.3 and this tree —
**re-grep at implementation time, never trust a citation in this file without re-verifying it**
(the same caveat applies to every file:line in this document, including the baseline and
bucket-1 sections):

| Domain | Chokepoint(s) | Files (refs) |
|---|---|---|
| Contacts | `resolveWrite` (ContactsOutput.swift:106-121): `willExecute` branch stays; two-factor + `labeledName` checks become sandbox-only. Hard oracle gate stays on the two deletes. | ContactsWriteCommands (21), ContactsOutput (2), ContactsStore (2) |
| Mail compose | `guardOutbound` (WriteComposeCommands.swift:21) | WriteComposeCommands (14) |
| Mail manage | `requireLiveMessageMutation` + `executeMessageMutation` label phase + `requireCanonicalLabels` (CommandHelpers.swift:25,42 — canonical stays UNCONDITIONAL per the table) | WriteManageCommands (6), CommandHelpers (2), MailScript (2) |
| Mail rules/templates | `liveActionBlockers` — ALL FOUR blocker sources (self-scoping, unlabeled name, `match any`, delete/forward_to refusals; RuleTemplateCommands.swift:63-76): oracle-less ones sandbox-only; the preview MUST compute blockers under the SAME `sandboxActive` the execute path will use, or the preview lies. `TemplatesSave` gains its missing `willExecute` branch. | RuleTemplateCommands (9), RuleSchema (1) |
| Notes | `guardLiveWrite` (NotesCommand.swift:91-101) + its 15 call sites | NotesWriteCommands (9), NotesCommand (3), NotesBatch (3), NotesOrg (2) |
| Calendar | `CalendarSupport.swift:355-380` guard enum (NOT EventKitCore — **EventKitCore contains no write guards**; EventStore.swift:170 documents that callers gate) | CalendarSupport (3), EventsCommand (3) |
| Reminders | `shouldExecute` (RemindersSupport.swift:518) + `requireLabeledReminder` (:581) | RemindersSupport (4), Tasks (5), Subtasks (10), Lists (3) |
| Messages | `Send.assertAllowedRecipient` (Send.swift:59-65) + the flag check at MessagesCommand.swift:182 — the two factors merge into one `sandboxActive`. Group-chat send is currently unreachable because **the recipient ALLOWLIST refuses a group-chat id** (Send.swift:59-65) — resolution at MessagesCommand.swift:152-153 already precedes both gates, so the ordering is not the blocker. It becomes reachable outside the sandbox: a restored capability, called out in the CHANGELOG — and because it stays unreachable INSIDE the sandbox, no agent can verify it without messaging a real group. It is therefore **operator-verify-only**, recorded exactly like `--gui-send`: wired, gate-code-inspected, live-validated only with the operator present. Ambiguous-name resolution refusals are pre-gate and unchanged. | Send (3), MessagesCommand (1) |
| Mail export | `willExecute` gate at ExportCommands.swift:110 (landed 2026-07-31). Oracle B's `export_emails` executes on call → bucket 3, execute-by-default under v2; the `resolveExportDirectory` path confinement stays bucket 1. `export` and `attachments save` are in the sweep's write-verb list. | ExportCommands (1) |

Calendar + Reminders are **two coordinated edits in two modules**, not one core edit.

## Test-contract migration — three classes plus the sweep

**Rollout step 2 — BEFORE any semantic change: the mechanical sweep.** The rule is an
INVARIANT, not a choice: **a currently-flagless write invocation gains `--dry-run`, always** —
that is the v1-equivalent no-op — and the sweep NEVER adds `--execute` (only invocations that
already carried it keep it). "Green under v1" alone cannot police this: two suites
already run write invocations with `APPLE_TEST_MODE=1` set (bats/live/mail-writes.sh exports it
at :15; bats/mail.bats sets it per-invocation), where a wrongly-added `--execute` would pass v1
green while arming a live write for v2. So `no_flagless_writes.py` gains a second mode that runs against
the sweep COMMIT's diff and fails if any line gained an `--execute` token it did not have.
Scope: every write-verb invocation in `bats/`, `docs/`, `README.md` and scripts.
~87–149 flagless write-shaped invocations exist today; after the sweep, a flagless write
invocation in the test suite is a review error, enforced by a lint helper
(`bats/helpers/no_flagless_writes.py`) run in CI. Without this step, the core flip converts
those invocations into live mutations of the operator's real data — the single worst failure
mode this spec could cause. Note that engaging the sandbox suite-wide does NOT substitute for
the sweep: the test fixtures are already `apple-cli-test`-labeled, so they pass the sandbox's
label gate and the writes still execute — unlogged, uncleaned. Only explicit flags make the
suite safe under v2 semantics.

Then, per test:

- **(a) Refusal tests whose refusal came from a label/recipient check**: engage the sandbox
  explicitly, keep asserting the same refusal.
- **(b) Refusal tests whose refusal WAS the lifted gate itself** (e.g. bare "no test mode →
  77"): rewritten against a labeled target or deleted with a rationale comment — the behavior
  they pinned no longer exists.
- **(c) Swift logic tier (~50 cases across WriteSafetyTests + TestModeTests)**: guards take
  `sandboxActive` as a parameter, so both branches are pure calls; no process-env mutation.

**Per-domain refusal contract** (replaces the first draft's incorrect blanket "exit 77"):

| Domain | Sandbox-refusal type / exit |
|---|---|
| Mail | `safety_violation` / 77 |
| Contacts | `safety_violation` / 77 |
| Calendar | `validation_error` / 64 |
| Reminders | `validation_error` / 64 |
| Notes | `validation_error` / 64 |
| Messages | `validation_error` / 64 |

(Unifying these on 77 is a candidate follow-up, but it is a separate breaking change and NOT
part of v2.)

New v2 tests per domain: (1) a non-sandbox write against a **labeled** item executes;
(2) `--dry-run` writes nothing; (3) the sandbox still refuses an unlabeled target / non-self
recipient per the table above; (4) red-then-green proof for each flipped guard.

## Agent conduct (AGENTS.md) — the contradiction, resolved

Default posture: every write an agent runs is sandboxed (`APPLE_TEST_MODE=1`). **One sanctioned
exception**, narrow, auditable, and in exactly two shapes — because "a labeled item, cleaned up
after" has no meaning on a send:

- **(a) Item surfaces** (Contacts, Notes, Calendar, Reminders, mail drafts/templates/rules/
  moves): the per-domain-flip verification that a LABELED `apple-cli-test` item writes
  successfully *without* the sandbox engaged — once per domain flip, against an item this run
  created, logged in TEST-CLEANUP.md before the write, cleaned up immediately after.
- **(b) Send surfaces** (Mail send, Messages send): the unsandboxed verification is a single
  SELF-ADDRESSED send — to the operator's own address/number ONLY — logged to TEST-CLEANUP.md
  as a record (a delivered send cannot be "cleaned up"; the log entry notes the received item
  to delete). Group-chat send has no self-addressed shape and is operator-verify-only (see the
  Messages inventory row).

Nothing else ever runs unsandboxed by an agent.

## Versioning + operator migration

BREAKING (behavior), flagged in the CHANGELOG per pre-1.0 policy:

- The execute-by-default flip (per the defaults table) and the gate lift.
- **Envelope KEY-SET changes**: commands whose default path previously emitted preview shapes
  (`would_*` keys) now emit executed shapes by default — enumerated per command in the
  CHANGELOG at flip time.
- An operator-facing migration note: any script/shell-history invocation that relied on
  dry-run-by-default now executes; `APPLE_DRY_RUN=1` restores the old posture globally.

Doc/help sweep in the same commits as the flips: every `@Flag`/`@Option` help string and
emitted `note:` field asserting v1 semantics (e.g. the `--all` help's "on a real INBOX this
refuses"), the TestMode.swift and WriteComposeCommands.swift file headers **and the
`guardOutbound`/`resolveAttachmentPath` doc comments in that file** — the latter must be
rewritten to state the post-v2 truth: outside the sandbox the recipient allowlist does not
apply, so the sensitive-directory refusal and the executable-extension blocklist are the SOLE
containment for attachment content, and they must never be relaxed or made
sandbox-conditional. Plus docs/DESIGN.md:57, the three port-specs that state the v1 gate, and
INTEGRATION-STATUS.

## Rollback

Each domain flip is a single revertable commit. If a flip proves wrong for one operation,
**re-gate that operation** (a one-line `sandboxActive` → `true` pin with a comment) rather than
reverting the model. The sandbox itself is the operator's per-invocation rollback.

## Rollout order

1. This spec (reviewed — round 1 REQUEST CHANGES ×3, findings folded in — then committed).
2. **Mechanical test/doc sweep** (explicit `--dry-run`/`--execute` everywhere; lint helper;
   green under v1).
3. AppleKit core (`willExecute` precedence chain, `sandboxActive(flag:)`, fail-loud env,
   `sandbox: true` envelope key) + AGENTS.md conduct rules.
4. Domain flips, each with its migrated tests + help/doc sweep in the same commit:
   Mail → Contacts → Notes → Calendar + Reminders (two coordinated edits) → Messages.
5. Oracle-A safety ports that are now load-bearing: rate limiter, bulk-delete cap,
   recipient cap.
6. Documentation pass: DESIGN.md, port-specs, INTEGRATION-STATUS, parity-audit addendum.
7. Re-run the 2026-07-31 audit — the write-gate HIGHs must flip to closed; 1.0.0 remains
   separately gated on explicit operator approval.
