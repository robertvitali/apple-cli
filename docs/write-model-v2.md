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
- **Visible engagement.** Every write SUCCESS envelope gains `"sandbox": true` when the sandbox
  is active (key absent otherwise — additive, MINOR). SUCCESS only: `Output.encodeError` has no
  such field, so a sandboxed REFUSAL is today indistinguishable from an unsandboxed one to a
  machine consumer — a real gap (a machine cannot tell which policy produced a 77), tracked as
  its own commit because adding the key to the shared error envelope changes all six domains at
  once. This bullet previously said "every write envelope", which was an overclaim.
  Mechanism AS LANDED (core review tightened
  the first sketch's `sandbox: Bool? = nil`, which let a plain `false` auto-promote and emit a
  meaningless `"sandbox": false` tri-state): `SuccessEnvelope` gains `let sandbox: Bool?`, but
  the public API takes a NON-optional — `Output.encodeSuccess(tool:data:sandboxActive: Bool =
  false)` / `Output.emit(tool:data:sandboxActive: Bool = false)` — normalized INSIDE to
  `active ? true : nil`, so the wrong envelope is inexpressible and every read path compiles
  unchanged (byte-identical envelope, asserted). Write commands pass
  `sandboxActive: sandboxActive` — never a ternary. KNOWN RESIDUAL (flip-commit checklist):
  the parameter is defaulted, so a sandboxed write that FORGETS to pass it under-reports as
  unsandboxed — each domain flip must pass it at every write-emit site; the per-domain
  sandbox test (below) is what catches an omission.
- **Writes only.** The sandbox affects write paths exclusively; read commands return identical
  output with it on or off (per-domain test required).
- **`APPLE_DRY_RUN`** (new, additive, orthogonal): an operator-level persistent preview
  default. When truthy, writes default to dry-run again; an explicit `--execute` overrides it.
  This restores a durable "safe posture" for anyone who wants v1 ergonomics. **Identical
  fail-loud contract to `APPLE_TEST_MODE`**: accepts `1`/`true`/`yes` (case-insensitive);
  `""`/unset = off; any OTHER non-empty value is a `validation_error` (exit 64) at the start of
  any write command — never silently "no dry-run". Both variables parse through ONE shared
  helper (`TestMode.truthyEnv(_ name: String) throws -> Bool`) so their contracts cannot
  drift, with a swift-tier case asserting the rejection for each. AS LANDED (core review
  rejected this section's first rationale, which leaned on preamble call-order):
  `TestMode.isTruthyEnv` is the non-throwing accessor, used ONLY where `false` is the
  REFUSING direction (`TestMode.isEnabled`; the contacts-delete hard gate, whose `false`
  refuses the delete). Every v2 gate whose `false` would be PERMISSIVE uses the THROWING
  readers (`truthyEnv`, `sandboxActive(flag:)`, `willExecute(defaultDryRun:)`) — the
  fail-loud contract is carried by the type system. The preamble
  (`validateWriteEnvironment()`, called INSIDE `runGuarded`) is belt-and-braces — it fails
  before partial work — not the safety mechanism.
- Precedence: `--dry-run` > `--execute` > `APPLE_DRY_RUN` > v2 default (execute, except the
  trash surface).

## Core implementation (AppleKit)

- `GlobalOptions.willExecute` becomes a METHOD, not a property:
  `willExecute(defaultDryRun: Bool) throws -> Bool` — `dryRun` wins over everything; otherwise
  `execute` forces true; otherwise `APPLE_DRY_RUN` truthy makes it false; otherwise
  `!defaultDryRun`. Trash-surface commands pass `defaultDryRun: true`. AS LANDED (core review,
  round 1, three tightenings over this section's first sketch): `defaultDryRun` has NO default
  value — every surface states its own; the method (and `sandboxActive(flag:)`) THROWS, reading
  the fail-loud parser directly, so an unparseable `APPLE_DRY_RUN`/`APPLE_TEST_MODE` refuses the
  command via the type system rather than via a promise that the preamble ran first (the
  preamble stays as belt-and-braces, called INSIDE `runGuarded` so its error envelopes
  correctly); and the v1 property is `@available(*, deprecated)` during the staged flips —
  every un-migrated (or label-dropped `global.willExecute`) site carries a per-line compiler
  warning, the FINAL flip deletes the property, and "zero deprecation warnings" is the
  mechanical completion criterion. **Per-command discipline, enforced at review**: every
  mutating command's `run()` binds the result ONCE at the top
  (`let willExecute = try global.willExecute(defaultDryRun: Self.defaultsToDryRun)`) and
  uses only that local thereafter. This matters because DeleteCommand reads the old property at
  four sites (:265, :285, :313, :323) and TrashEmpty at three (:405, :414, :424) — seven
  independent reads each making its own decision; a partial conversion would either regress
  `--permanent` to a hard refusal or silently trash real mail by default. Bind-once plus the
  deprecation warning makes a missed site VISIBLE, not a latent divergence.
- **Guards change signature — this is explicit, not "unchanged".** Sandbox state becomes a
  parameter and the internal `TestMode.isEnabled` re-checks are REMOVED (they would defeat the
  flag-only path): `requireLabeledTarget(_:sandboxActive:)`, recipient checks likewise.
  `TestMode.sandboxActive(flag:)` — AS LANDED it THROWS and validates the env EAGERLY
  (`let env = try truthyEnv(testModeVar); return flag || env`), so a malformed
  `APPLE_TEST_MODE` refuses even when `--test-mode` is passed — is computed once per command
  and threaded down. This also gives the swift logic tier both branches as pure calls — no
  env mutation in tests.
- Help strings land with the flip. AS LANDED (Mail flip; wording adjusted from the draft below
  to stay truthful during the STAGED rollout, where un-flipped domains still enforce v1 —
  the shared GlobalOptions help must describe both):
  - `--dry-run`: "Preview a write/destructive operation without performing it (always wins —
    over --execute, APPLE_DRY_RUN, and any surface default)."
  - `--execute`: "Explicitly perform the write (write-model-v2 domains execute by default;
    this also overrides APPLE_DRY_RUN and any remaining dry-run defaults)."
  - `--test-mode`: "Engage the opt-in SANDBOX: writes restricted to apple-cli-test-labeled
    items and self-only allowlisted recipients (APPLE_TEST_RECIPIENTS). Domains not yet on
    write-model v2 additionally require it (with APPLE_TEST_MODE=1) for live writes."
  The final flip commit may tighten these to the shorter single-model wording once no v1
  domain remains.

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

## Rollout status

- 2026-08-01 — steps 1–3 landed (spec 2dfbf53; AppleKit core 3188cc5; sweep + suite lint
  b48322c). **Mail flip landed** (step 4, first domain): all Mail write commands on the v2
  preamble, per-surface defaults per the table (trash surface keeps dry-run), help/doc sweep
  included, `mail.bats` migrated (sandbox-refusal / env-brake / operator-gate shapes; two
  permanent marker tests pin the per-surface defaults). Bucket-2 closed for Mail: TemplatesSave,
  DraftRich, `send --out`, and `analytics dashboard` (which also gained `confineWriteDestination`
  on `--out`) all honor `--dry-run`. ONE documented bucket-2 exception: `templates save
  --execute` keeps its pre-v2 envelope (the bare template object, the shape `templates get`
  shares) and so carries no explicit `dry_run: false` key — its preview's `would_save_template`
  + `dry_run: true` is the discriminator (also noted in the CHANGELOG contract bullet).
  The OMC review rounds (a three-reviewer fan-out per round, each round's fixes re-verified green)
  additionally hardened the lifted-gate paths: duplicate-name `rules create` refusal, match-logic
  preservation on rule recreate, `--match any` honored in-place, the `"*"` allowlist sentinel made
  underivable from `APPLE_TEST_RECIPIENTS`, `draft send`'s recipient-set-equality locator,
  empty/blank-keyword refusals on every subject/sender/account-matching write surface (an
  empty value used to bind the newest message / whole mailbox / every account),
  control-character rejection/scrubbing on all FOUR channels that feed the US/RS-delimited
  AppleScript argv — attachment paths and sandboxed recipient allowlists (operator data), plus
  the two REMOTE-data channels: the sender-supplied MIME filename (scrubbed) and `reply --all`'s
  index-sourced recipients (reduced to the bare addr-spec, discarding the decoded display name)
  — the `--gui-send` window locator re-bound to a per-call nonce instead of the subject, and
  PREVIEW HONESTY
  across the domain — dry-runs run every gate computable from flags + already-resolved data
  (incl. the sandboxed bulk per-target label gate), with the disclosed divergences being the
  two rules checks that need a fresh Mail read (duplicate-name; target-rule label) and
  `delete --permanent`'s preview, which renders the plan but names each unmet operator gate
  in its note.
- 2026-08-02 — **Contacts flip landed** (step 4, second domain). All 11 write ops on the v2
  chokepoint (`resolveWrite` now returns a `WriteGate {willExecute, sandboxActive}` instead of
  the v1 `.dryRun`/`.execute` enum, and validates the v2 env in one place). Re-verified against
  oracle source on disk before implementing: `require_test_mode_for` (security.py:161) is
  called at EXACTLY two sites — `delete_contact` server.py:965 and `delete_group` server.py:1715
  — and `check_test_mode_safety` (security.py:56) returns `None` when test mode is off, which
  confirms the spec's classification (the former is bucket 1 and stays unconditional +
  ENV-keyed; the latter is a test-mode-only restriction, i.e. the oracle's own analogue of our
  sandbox, so the CLI's label confinement maps onto it as bucket 3).
  Beyond the mechanical flip: `groups rename`'s new-name check and `vcard import`'s per-card
  check were hoisted above the store so previews refuse what execute refuses; the fetched-target
  checks (which need TCC) are disclosed in a new `gate_note` preview field rather than silently
  skipped; every executed envelope states `dry_run: false`; and a sandbox-coherence gap was
  closed — `create --group` now label-checks its group target, as `import --group` already did.
  `emitContactsWrite` takes a NON-defaulted `sandboxActive`, which closes this spec's "KNOWN
  RESIDUAL" for this domain by making an omitted sandbox key a compile error rather than a test
  responsibility. ContactsKit is at zero deprecation warnings (the mechanical per-domain
  completion criterion).

  **Test migration (exact accounting).** HEAD carried **11** v1 "`--execute` without test-mode
  → 77" cases, one per write op. Reclassified per the spec's class (b): **2** survive as the
  same refusal (`delete`, `groups delete` — the oracle-mirrored env gate; both were retitled and
  gained an assertion on the `APPLE_TEST_MODE=1` message), **4** became sandbox label refusals
  that still resolve before the store (`create`, `groups create`, `groups rename`,
  `vcard import`), and **5** became positive `gate_note` preview-honesty assertions (`update`,
  `note set`, `photo set`, `groups add`, `groups remove` — the gate they pinned no longer
  exists, and their sandbox check now needs a store read a preview does not take). Two further
  removals were the v1 dry-run-default previews, rewritten with an explicit `--dry-run`. The
  domain's 2 pre-flip lint markers migrated (suite marker cap 7 → 5). Because a flagless
  contacts write is a LIVE address-book mutation, the execute-by-default posture is pinned in
  the LOGIC tier ("Contacts write-model v2 posture") rather than with a bats default-pin marker.

  Live once-per-flip verification (conduct rule 1, shape (a)) done and logged: flagless
  unsandboxed create executed, confirmed present by the MCP oracle, the flag-alone delete
  refused 77 against the real id, `APPLE_TEST_MODE=1` delete removed it, oracle then reported
  not_found. No residue.

  **Review round 1 (3 lenses, 19 findings, 19 adversarial verifiers; 2 confirmed).** Both
  confirmed findings were fixed: (i) HIGH — the new posture suite made `swift test`
  intermittently red at a reproduced **6-in-12** rate, because `resolveWrite` made ContactsKit
  the first domain reader of `APPLE_DRY_RUN` while `WriteModelV2CoreTests` still `setenv`'d the
  real variable on a comment asserting "nothing else in the swift tier reads it (domains are
  pre-flip)". Fixed at the source by giving `GlobalOptions.willExecute` the same `envVar:` seam
  `TestMode.sandboxActive` already had, repointing that test at a unique variable, and adding a
  pin that the DEFAULT still reads the real `APPLE_DRY_RUN`; 0-in-12 red after. A second race of
  the same class (ContactsKit's older label suite read the live `APPLE_TEST_SANDBOX`, which
  MailKit's suite sets to "qa-fixture") was found while fixing it and closed by reading the
  canonical constant. **Every future domain flip adds another env reader — use the seams.**
  (ii) LOW — this note's own migration accounting was wrong, now restated above from the diff.

  Several unconfirmed-but-correct findings were fixed too, because being unfalsifiable is not
  the same as being wrong: INTEGRATION-STATUS.md's stale safety posture; the port-spec's
  overclaim that the sandbox checks "the fetched target of any id-addressed write" (the CONTACT
  side of `groups remove` is not checked, and the spec now enumerates exactly what is);
  `--text` write output silently dropping the sandbox indication; the inert `--group` option's
  help text claiming enforcement; and two precedence tests whose only protection was the
  behavior under test — a regression would have written a real contact before the assertion
  failed, so they now use a nonexistent-id `update`, which dies on not_found instead. The
  unlabeled-refusal cases likewise gained post-refusal absence assertions and synthetic
  "Zz … Probe" names, so a regressed label gate fails loudly rather than leaving residue that
  prefix-based recognition could never find.

  **Rejected, three times over.** Three lenses independently proposed pinning the two deletes to
  `canonicalSandboxPrefix` instead of the redefinable `sandboxPrefix`, by analogy with Mail's
  `requireCanonicalLabels`. All three were refuted, and the full argument now lives beside the
  code in `ContactsOutput.swift` so it is not re-litigated: it would buy zero confinement
  (a contact's name is writable by the ungated `update`, unlike a message's subject), it would
  drop a capability the oracle has, the oracle's own key is an env var of the same class, and
  Contacts delete is single-id rather than filter-based like the Mail op the constant was built
  for. A related correction landed with it: the "an agent can self-grant a flag but not an env
  var" rationale that first justified the delete gate is FALSE for a CLI — anything that can
  pass argv can set the environment too. The gate is keyed to the environment for PARITY, and
  the docs now say so.

  Remaining flips: Notes → Calendar + Reminders → Messages.
- 2026-08-02 — **Notes flip landed** (step 4, third domain). The simplest mapping of the six:
  the oracle ENFORCES no write gate of any kind. **Evidence (re-derived — the first
  version of this note cited a grep of `dist/` and `src/`, directories the shipped package does
  not contain, so it matched nothing *vacuously* and proved nothing; reviewers caught it):** the
  package ships one bundle, `apple-notes-mcp/build/index.js`; the only `process.env` reads in it
  are `DEBUG` and `VERBOSE`, so there is no test-mode variable to mirror; every `elicit*` hit is
  bundled MCP-SDK protocol schema rather than server code; and `delete-note`'s handler runs
  `getNoteById` → `deleteNoteById` with no gate. Its description does say "Safety: requires
  explicit user confirmation before deleting", but that is advisory prose aimed at the calling
  model, not server-side enforcement.
  All 9 write ops are therefore bucket 3, with no bucket-1 gate to keep — unlike Contacts,
  which keeps two. **Process lesson: an evidence grep must be shown to match a path that
  EXISTS.** A `grep -r … dir/ 2>/dev/null` over a missing directory exits 0 with no output,
  which is indistinguishable from a real negative. The conclusion here survived re-derivation,
  but only by luck.

  **PARALLEL-SUITE ENV RACES — the standing hazard for every remaining flip.** swift-testing
  links all test targets into ONE process and runs suites in PARALLEL, so any test that
  `setenv`s a real v2 variable races every domain that reads it, and each flip adds readers.
  Two distinct instances have now bitten, both caught only by REPEATED full runs (one green run
  proves nothing):
  1. `APPLE_DRY_RUN` — `WriteModelV2CoreTests` owned it globally on the premise that "nothing
     else in the swift tier reads it (domains are pre-flip)". The Contacts flip falsified that:
     6-in-12 red. Fixed with an `envVar:` seam on `GlobalOptions.willExecute`.
  2. `APPLE_TEST_SANDBOX` — `MailKitTests` setenv()s it to `qa-fixture`, and both new posture
     suites called gate functions that read `TestMode.sandboxPrefix` internally: 1-in-6 red.
     Fixed with a `prefix:` seam on Contacts' `resolveWrite` and Notes' `guardLiveWrite` /
     `applyArgvSelectorGuard`; 0-in-14 after.

  **Rule for the Calendar / Reminders / Messages flips:** a logic-tier test must never inherit an
  env-backed value it has hard-coded expectations about — read the pinned constant
  (`TestMode.canonicalSandboxPrefix`) or pass a seam, never `TestMode.sandboxPrefix`. Validate a
  new posture suite with **>= 12 consecutive full runs**, not one.
  The open question this file left for the Notes flip (whether the deletes warrant an
  `APPLE_ALLOW_*`-style operator affordance) resolves NO: Notes.app's AppleScript `delete` moves
  the note to Recently Deleted, where it stays recoverable, so none of these ops is the
  irreversible erase that rule exists for; the previews were corrected to stop saying
  "PERMANENTLY delete".
  Mechanics: `resolveNotesWrite` is the new chokepoint (validates the v2 env, binds
  willExecute + sandboxActive once); `guardLiveWrite` takes `sandboxActive` as a PARAMETER and
  its internal `TestMode.isEnabled` re-check is gone — that re-check would have silently skipped
  the confinement on the flag-only path; `emitNotesWrite` takes a NON-defaulted `sandboxActive`
  (the Contacts precedent) and surfaces the sandbox in `--text` too. Preview honesty: every
  argv-computable label check was hoisted to run on both paths (`create` title,
  `update --new-title`, both folder names, `batch-move`'s destination), and the fetched-target
  checks are disclosed rather than skipped silently. NotesKit is at zero deprecation warnings.
  Test migration: notes.bats' 2 pre-flip markers migrated and its one genuinely dangerous case
  was rewritten — `APPLE_TEST_MODE="" notes create … --execute` was a v1 REFUSAL that under v2
  would CREATE A REAL NOTE. Suite marker cap 5 → 3 (only messages' 1 pre-flip marker plus
  mail's 2 permanent default-pins remain).
  **Review round (security lens, re-run after the first fan-out died on API limits — 12 of 14
  agents errored, so that run's `confirmed: 0` was an artefact and the gate had NOT run).** It
  returned one CRITICAL and three MEDIUMs, all real:
  - CRITICAL — `notes delete-folder ""` (or any all-separator name) collapsed to ZERO path
    components, so `folderRefExpr([])` produced an empty specifier and the script was a bare
    `delete` inside `tell account …`, binding to the ACCOUNT CONTAINER. v1 refused it only
    incidentally via the label gate; the lift removed that accident. The oracle is NOT vulnerable
    (`folderNameSchema.min(1)`), so this was a **dropped oracle-mirrored input bound**, not
    parity with a vulnerable oracle. Guarded at the command layer AND at the `deleteFolder` sink,
    matching the guard `createFolder` already had.
  - MEDIUM — `create --folder` was never label-checked, the same gap fixed for `move` one round
    earlier; `save-attachment --dry-run` skipped its path confinement (the only check it has),
    reporting clean for a destination execute refuses.
  - MEDIUM — two load-bearing claims were asserted and never verified. **Both turned out false
    for `delete-folder`.** Measured with labeled data: it does NOT refuse a non-empty folder, it
    CASCADES, and the cascade is PERMANENT — the contained note did not reach Recently Deleted,
    while the control note deleted via `notes delete` in the same run did. `delete-folder`
    therefore takes a **per-surface dry-run default** (the Mail trash-surface shape), a knowing
    deviation from strict parity under this file's own `APPLE_ALLOW_EMPTY_TRASH` rule.

  **Process lesson, second of two this flip: do not generalise a measurement across an op class.**
  "Notes deletes are recoverable" was verified once, for `delete`, and then written as though it
  covered `delete-folder`, which is the one op where it is false — and that generalisation was
  the entire stated reason for withholding an operator affordance.

  Remaining flips: Calendar + Reminders (two coordinated edits on the shared EventKitCore) →
  Messages. Deprecation warnings left: CalendarKit 4, MessagesKit 3, RemindersKit 2 — the
  mechanical completion criterion for the rollout is zero.

  **Bucket-2 exceptions taken for Contacts (per this file's "fixed or explicitly excepted with
  rationale" clause).** (a) `vcard export --out` and `photo get --out` write caller-named paths
  with no confinement and no `--dry-run` branch. Real, but PRE-EXISTING and on READ commands,
  and the shared `confineWriteDestination` helper currently lives in MailKit — using it here
  means promoting it to AppleKit and updating its five MailKit call sites, a cross-domain
  refactor that deserves its own commit. (b) Refusal envelopes carry no `sandbox` key, because
  `Output.encodeError` has no such field; this file's "every write envelope" wording was an
  overclaim and now reads "every write SUCCESS envelope". Adding the key to the shared error
  envelope would change all six domains mid-rollout, so it is likewise deferred to its own
  commit. Both are tracked as follow-ups, not silently absorbed.
