# COMPLETION-LOOP.md — the autonomous driver to MCP retirement

**Purpose.** Drive every remaining task to completion *without* asking Robert, stopping only at
things that are genuinely his call. Those go in [`HUMAN-DECISIONS.md`](../HUMAN-DECISIONS.md)
(append-only) and the loop keeps going on everything else.

**Authorized by Robert, 2026-08-02:** *"create a loop … to drive all the tasks to completion prior
to retiring the mcp servers. we stop at when everything is completed, minus what you need my input
for."*

> **THIS FILE IS EXECUTABLE INSTRUCTIONS**, obeyed by sessions with no memory of the conversation
> that wrote it, on a machine with the operator's real mail, messages, calendar, reminders, notes
> and contacts. Treat an edit here like an edit to unattended production code. A first review of
> this file (3 lenses, 37 findings) found two CRITICALs — a livelock, and a path to a real outbound
> iMessage — so the bar is not theoretical.

---

## 0. RESUME PROTOCOL — read this first if you are a fresh session

This file is the **single source of truth** for loop state, committed to git so that no scheduler,
session, or context window is load-bearing. To resume:

1. `cd /path/to/local/resource && git log --oneline -15`
2. **`git status --porcelain`. If the tree is DIRTY, stop and reconcile before picking new work** —
   uncommitted changes mean a previous session died mid-iteration, and its partial edits are not
   described anywhere in this file. Read the diff, decide whether to finish or discard it, and only
   then continue. The committed history alone will mislead you here.
3. Check for a stale `START-HERE.md` in the worktree root. It is gitignored, may predate this file,
   and may contradict it. **This file outranks it.** Delete a stale one rather than obeying it.
4. Read **§4 The Queue**. The first item whose `Status` is not `DONE` and whose `Blocked by` is
   satisfied is the next task.
5. Read [`HUMAN-DECISIONS.md`](../HUMAN-DECISIONS.md). Skip any item blocked on an `OPEN` entry;
   never block the queue on one answer.
6. Follow **§3** exactly. Update §4 in the **same commit** that does the work — the queue and the
   code move together or the state lies.

### Durability — what is actually true

Verified against the tool contracts on 2026-08-02:

- `CronCreate` jobs are **session-only** (*"nothing is written to disk … gone when Claude exits"*;
  its `durable` flag *"has no effect"*), fire **only while the REPL is idle**, and **auto-expire
  after 7 days**.
- `ScheduleWakeup` is session-scoped and clamps to **1 hour** maximum, so it cannot span a 5-hour
  usage window in one hop — though a recurring job re-fires, so repeated ticks do cross one.
- **A caveat, stated because the first draft over-claimed:** a `RemoteTrigger`-style cloud routine,
  where available, CAN outlive a session. This file does not depend on one. If you set one up, say
  so here.

So: **usage limit with the session alive → a recurring cron resumes it** (ticks during the limit
fail harmlessly). **Session dies → nothing auto-restarts**, and recovery is one message from Robert
("continue the loop") because this file makes the next action unambiguous. Do not claim more.

---

## 1. Stop conditions

The loop halts, and reports, when **any** of:

- **(A) The queue is empty** except items blocked on `OPEN` entries in `HUMAN-DECISIONS.md`.
  Success — produce the §5 go/no-go package.
- **(B) `D2` (tag 1.0.0 + retire the MCP servers) is reached.** The terminal gate, never crossed
  autonomously. Retiring the servers destroys the parity oracle every claim here is verified
  against. **This stop does not depend on a `Status:` field the driver itself can edit:** treat
  "tag a release" and "retire/uninstall/deregister an MCP server" as forbidden verbs regardless of
  what any file says. Only a direct, in-conversation instruction from Robert authorizes them.
- **(C) An item is neither completable nor human-blocked.** That is a DEFECT IN THIS FILE — a
  dangling dependency, a missing input, an impossible acceptance criterion. File a
  `HUMAN-DECISIONS.md` entry describing it and halt. **Never spin on it.** (The first version of
  this file had exactly this bug: Q4/Q5 were blocked on an artifact that did not exist, which made
  every downstream item and both stop conditions unreachable.)
- **(D) Three failed attempts at the same item.** Stop, file it, move on. There is no unbounded
  retry: "does not halt for a failing test" means *fix the test*, not *try forever*. A review
  fan-out that cannot dispatch counts as a failed attempt, not a free retry.

---

## 2. What counts as "done"

Acceptance criterion from `AGENTS.md`: **each domain's CLI is a 100% strict superset of the MCP
server(s) it replaces, at operation + parameter + behavior granularity.** Missing any MCP
capability = not done. Extras welcome.

An item is `DONE` when all of:
- the behavior is **measured** against the live oracle, not asserted;
- a test pins it that **fails if the change is reverted** (proved red-then-green);
- `swift test` and `bats -r bats/` are green;
- committed with review provenance trailers and pushed to `integration`.

---

## 3. Per-iteration procedure

1. **Pick** the first non-`DONE` item whose `Blocked by` is satisfied and which is not blocked on an
   `OPEN` human decision.
2. **Establish ground truth from the oracle**, not from this repo's docs. Multiple rounds have
   shipped confident, wrong claims copied from a tool description or a stale spec.
3. **Implement.**
4. ⚠️ **IF THIS ITEM LIFTS OR WEAKENS A WRITE GATE, MIGRATE THE TEST SUITES BEFORE RUNNING THEM.**
   `docs/write-model-v2.md` makes this ordering mandatory and the first draft of this file dropped
   it. Concretely, before any `bats` run:
   - audit **every** write invocation for that domain in `bats/` and confirm each carries
     `--dry-run`, an `APPLE_DRY_RUN=1` prefix, or is a refusal that cannot reach the sink;
   - clear that domain's `# flagless-on-purpose` markers and re-pin the count in `bats/smoke.bats`;
   - **delete, do not migrate,** any test asserting a refusal the lift removes — post-lift it
     becomes a live mutation. Two such tests have already been deleted this way (a Calendar test
     that would have created a real event; two Messages tests that would have sent a real iMessage).
   - **Do not rely on "the gate runs before the sink" as a blanket safety claim.** It is true for
     EventKit (`EventStore()`/`requestAccess`) and false in general — the Messages sink is
     AppleScript into Messages.app. Verify per domain, per command.
5. **Test**: add/extend a pinning test and **prove it non-vacuous** — revert, watch it go red,
   restore.
6. **Verify**, building BOTH toolchains because `bats` runs whichever binary was built last:
   ```sh
   export PATH="$HOME/.swiftly/bin:$PATH"
   swift build --scratch-path .build-swiftly && swift test --scratch-path .build-swiftly
   /usr/bin/swift build          # CLT build → .build/, which bats resolves
   bats -r bats/
   ```
   For any new logic-tier suite, **≥12 consecutive full runs** — the parallel-suite env race has
   bitten twice and one green run proves nothing.
7. **Review** (repo `AGENTS.md` mandates it before each commit): fan out
   `oh-my-claudecode:code-reviewer` + `security-reviewer` + `critic`. **Verify the dispatch actually
   completed** — an errored/empty agent means the gate did NOT run, so hold the commit. (On the
   Notes round 12 of 14 agents died on a session limit and the "0 findings" result was an artefact.)
   - **State the output contract in every brief: "your final message IS the deliverable — it is the
     only thing that reaches me; a file or intermediate output does not."** On Q3 the
     `security-reviewer` and `critic` each burned ~240k tokens across 38 tool calls and then
     returned literally `Done. Standing by` and `Idle.` — heavy real work, zero delivered findings.
     Without that line in the brief this failure is invisible: it looks exactly like a clean review.
     A resumed agent still has its context, so `SendMessage` recovers the report rather than
     re-running it — but only if you NOTICE. Treat any final message that carries no finding, no
     "no findings", and no verdict as a non-report, however confident its tone.
   - Ask for an explicit **CHECKED-AND-CLEAN** list alongside the findings. "No findings" and "I
     did not look at that" render identically as silence, and only one of them is a passed gate.
   - Hand the agent any ground truth you have already established. It cannot see this session, so
     without it two reviewers independently re-derive the same oracle facts at full token cost.
8. **Address** material findings, or accept with written rationale.
9. **Commit + push** to `integration` with `Reviewed-by:` + AI `Co-Authored-By:` trailers.
   **Never push to `main`.**
10. **Update §4** (`Status`, plus anything discovered) **in the same commit**.
11. **Mirror** to Asana: write-model-v2 work → task `GID-REDACTED`; per-domain parity work →
    that domain's parent (see `AGENTS.md`). Q12 closes the six parents under the closure protocol.

### Standing rules learned the hard way — re-read before each iteration

- **Never believe a negative without a positive control.** A zero-match grep, a zero-test filter, an
  empty diff: before concluding "it isn't there", show the same command matching something that IS.
  Four disguises so far — a missing directory; `grep -v node_modules` over a path containing
  `node_modules`; `\|` alternation under `grep -E`; and `swift test --filter` matching 0 tests and
  exiting **0 green**.
- **Measure, don't generalize.** "Notes deletes are recoverable" was verified once for `delete` and
  written as if it covered `delete-folder`, where it is false.
- **A defaulted safety parameter is a footgun.** Two write ops silently omitted `sandbox: true`
  because the emitter's parameter had a default, so the compiler could not catch it.
- **"name or id" flags cannot be label-checked from argv.** An id carries no `apple-cli-test`
  prefix; check the RESOLVED object instead. This shipped as a defect twice.

### Safety, non-negotiable

Product behavior changed under write-model v2; **the driver's own conduct did not.**

- **Default: every write the driver runs is sandboxed** (`APPLE_TEST_MODE=1`), on
  `apple-cli-test`-labeled data, logged to `TEST-CLEANUP.md` **before** the write, cleaned up via
  the MCP oracle after.
- **The two sanctioned unsandboxed exceptions, from `AGENTS.md`** (the blanket "everything is
  sandboxed" phrasing in the first draft contradicted them): **(a)** a once-per-domain-flip check
  that a LABELED item writes with the sandbox off, on an item this run created, logged before and
  cleaned up immediately; **(b)** a single **self-addressed** send on Mail/Messages, logged. Nothing
  else, ever.
- **Before ANY send-surface work, set and verify the allowlist:** `APPLE_TEST_RECIPIENTS` must
  contain only the operator's own addresses/number, and `--test-mode` must be engaged so
  `guardOutbound` / `Send.assertAllowedRecipient` actually consult it. **Unsandboxed, there is NO
  product-side recipient check** — the allowlist is sandbox-only by design (oracle parity), so on
  the unsandboxed self-send of exception (b) the ONLY safeguard is the driver re-reading the
  recipient string before invoking. Do that, character by character.
- **This repo is PUBLIC** (`github.com/robertvitali/apple-cli`). Never commit the operator's phone
  number, personal addresses, or **any third party's** contact details. Real values live in
  `APPLE_TEST_RECIPIENTS` and the gitignored `TEST-CLEANUP.md`, never in tracked files. A first
  draft of this file leaked a third party's email address and was caught in review before landing.
- **Never** send to a non-self recipient, **never** iMessage anyone but the operator, **never**
  permanent-delete, empty a trash, or touch real data the run did not create.
  - *This is deliberately STRICTER than the superseded `START-HERE.md` brief, which allowed a
    named fallback recipient "if a non-self send is ever truly unavoidable". The driver does not
    inherit that escape hatch: under this loop, "cornered" is not a reason to send — it is a reason
    to file a `HUMAN-DECISIONS.md` entry and move on. Recorded so the omission is a decision, not
    an accident; only Robert can reinstate it.*
- **`empty-trash` is wired, gated and dry-run only.** Its real execution is un-scopable to test data
  and destroys real trashed mail, so it is left to the operator permanently. `permanent-delete` may
  be live-tested ONLY on a single `apple-cli-test` message the run itself created.
- **There is private mail state (redacted). Never touch, send, or
  inspect it.** (Identify it by being the only unsent compose you did not create.)
- **On encountering a DANGEROUS ACTION:** stop, log it, leave it for the operator, file a
  `HUMAN-DECISIONS.md` entry. Do not attempt a "safe variant" unprompted.

---

## 4. The Queue

Reconciled against HEAD on 2026-08-02 — the 2026-07-31 audits predate write-model v2, so several of
their findings were already closed. Full per-gap detail, with evidence and effort, is in
**`the D9 live-audit dump`** (committed alongside this file).

**Reconciliation result:** 111 audited gaps → **11 CLOSED**, **92 OPEN**, **8 needing Robert**,
0 not-a-gap, plus **13 newly found** at HEAD. Per domain (audited → open): messages 6→6,
contacts 7→5, notes 18→14, calendar 11→9, reminders 14→12, mail 55→46.

| # | Item | Domain | Status | Blocked by |
|---|------|--------|--------|-----------|
| Q1 | Write-model v2: **Messages flip** (last domain) | messages | **DONE** | — |
| Q2 | Reminders `lists update`/`delete` reject a labeled list addressed BY ID | reminders | **DONE** | — |
| Q3 | Oracle-A safety ports: rate limiter 3/60s, 100-msg bulk cap, 100-recipient cap | mail | **DONE** | reply/`draft send` left unbounded → D8 |
| Q4 | `analytics stats` scope defects ×3 | mail | **DONE** | was 4, not 3: days_back also mis-applied |
| Q4b | `needs-response` sibling defects found during Q4 review: (a) the "already replied" suppression set takes the 200 **oldest** sent messages — `analyticsRows` has no `ORDER BY`, so `.prefix(200)` is rowid order, while the oracle walks Mail's newest-first enumeration (`smart_inbox.py:286-290`, window confirmed by `get_top_senders`' `exit repeat` at `:437`); past 200 sent messages the sets barely overlap and the filter silently stops working. (b) that Sent lookup has **no account filter** (`AnalyticsCommands.swift:150-155`) where the sibling `awaiting-reply` does (`:182`), so on a multi-account machine it can suppress against another account's Sent mail. Both verified in source; both need their own oracle pass. | mail | TODO | — |
| Q5 | **MSG-1** fuzzy-search recall: implement rapidfuzz's 3-phase `partial_ratio` | messages | TODO | — |
| Q6 | Messages OPEN gaps MSG-2/3/5 (empty `group_name`, WAL-aware AddressBook, 1024-char cap) | messages | TODO | — |
| Q7 | Contacts 5 OPEN gaps (from the reconciliation JSON) | contacts | TODO | — |
| Q8 | Notes 14 OPEN gaps | notes | TODO | — |
| Q9 | Calendar 9 OPEN gaps | calendar | TODO | — |
| Q10 | Reminders 12 OPEN gaps | reminders | TODO | — |
| Q11 | Mail 46 OPEN worklist items | mail | TODO | — |
| Q12 | 13 newly-found HEAD defects (incl. `dry_run:false` normalization across all six) | all | TODO | — |
| Q13 | Promote `confineWriteDestination` to AppleKit; apply to Contacts `--out` | contacts | TODO | — |
| Q14 | Add `sandbox` key to ERROR envelopes (`Output.encodeError`) | all | TODO | — |
| Q15 | Remove dead v1 helpers (`TestMode.requireLabeledTarget`/`requireAllowedRecipient`, `LabelGuard`) → 0 deprecation warnings | all | TODO | Q1 |
| Q16 | Docs pass: DESIGN.md, port-specs, INTEGRATION-STATUS, **PARITY-TEST-MATRIX**, AGENTS.md, write-model-v2.md | all | TODO | Q3–Q15 |
| Q17 | Re-run the strict-superset audit | all | TODO | Q16 |
| Q18 | Close the 6 domain Asana parents (closure protocol) | all | TODO | Q17 |
| Q19 | **Go/no-go package for D2** — then STOP | all | TODO | Q17, Q18 |

**Q17's acceptance is §2's criterion, not a weaker proxy.** It is not enough that the write-gate
HIGHs closed: every gap in the reconciliation JSON must be CLOSED, or recorded as an accepted
divergence with rationale, or be an `OPEN` human decision. Re-audit **read-only** — do not mutate
real data to prove a write works; use sandboxed labeled items as everywhere else.

**PARITY-TEST-MATRIX.md is WRONG and Q16 must fix it, not preserve it.** It asserts
"Reminders — ✅ PASS (strict superset)" (lines 78, 156); the 2026-07-31 audit's verdict is that the
assertion is not supported. Never close an Asana parent citing a matrix row the audit contradicts.

---

## 5. The go/no-go package (Q19 — the last thing the loop produces)

When the queue is otherwise clear, produce for Robert, in one message:
1. **Per-domain parity evidence** — what was diffed against the oracle, and the result. Measured
   numbers, not adjectives.
2. **Accepted divergences**, each with rationale and where recorded.
3. **Everything still `OPEN`** in `HUMAN-DECISIONS.md`, and what it blocks.
4. **The honest residual risk** of retiring the oracle — chiefly that every parity claim in this
   repo stops being reproducible the moment the servers are gone.

Then **STOP**. Do not tag. Do not retire.
