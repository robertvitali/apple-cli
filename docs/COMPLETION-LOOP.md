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
   - **CHECK THE CLT BUILD'S EXIT, not just the bats total.** If anything runs `swift build` with
     swiftly on PATH and no `--scratch-path`, it writes 6.3.x modules into `.build/` and the CLT
     build then dies with `module compiled with Swift 6.3.3 cannot be imported by the Swift 6.2.4
     compiler`. `bats` happily runs the PREVIOUS binary and reports a full green — a verification
     that tested code you did not write. Recovery is `rm -rf .build && /usr/bin/swift build`.
     Caught on Q4b: a 314/314 bats pass was measuring a stale binary.
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
- **NEVER generate a committed test fixture from the operator's real data — not messages, mail,
  notes, contacts, events or reminders.** This is the rule most likely to be broken *for a good
  reason*: real data is the fastest way to get a fixture that provably discriminates between a
  correct implementation and a broken one, so the pull toward it is strongest exactly when the
  test matters most. Resist it. **Synthesize the inputs, then run the oracle over the synthetic
  inputs** — a golden table is only as good as the oracle values in it, and the oracle does not
  care whether its input was real. To keep the discriminating power, select synthetic rows by
  computing *both* the oracle and the implementation you are replacing and keeping only pairs
  where they disagree; then red-proof the table by mutation. Real data may be read freely for
  *measurement* (recall harnesses, A/B counts) — the line is at anything that lands **in the
  repository**. Not "in a tracked file": that phrasing was the first draft of this very rule and it
  is already too narrow, because the same incident put a real message body and a real first name in
  a **commit message**, which no file scrub can reach and which a `filter-repo --path` rewrite
  leaves untouched. The line covers tracked files, commit messages, branch and tag names, and any
  artifact a `git push` carries.
- **A live-run output file is PII by default — never `git add` one.** Anything produced by running
  the CLI or an MCP against real accounts (parity dumps, reconciliation JSON, inbox snapshots) is
  full of real contacts, addresses, subjects and account structure whether or not you looked. Route
  them to a gitignored path; `.gitignore` matches these **by class** (`docs/parity-*`,
  `*-AUDIT-*.json`, `*-RECONCILIATION-*`, `live-dumps/`) rather than by listing known filenames,
  because `the D9 live-audit dump` — which carried third-party personal data — was committed and
  pushed for exactly the reason that it matched none of the by-name patterns then in the file.
- **A comment asserting a fixture is synthetic is worthless unless you verified it.** A false "NO
  real mail" label is worse than no label: it is what the next audit trusts and skips. One shipped
  in `MailDecodeTests.swift` over a real vendor email.
- Both violations happened on 2026-08-02/03 in the same session; see **D9** for what is still in
  the published history and pending an operator decision.
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
| Q4b | `needs-response` sibling defects found during Q4 review: (a) the "already replied" suppression set takes the 200 **oldest** sent messages — `analyticsRows` has no `ORDER BY`, so `.prefix(200)` is rowid order, while the oracle walks Mail's newest-first enumeration (`smart_inbox.py:286-290`, window confirmed by `get_top_senders`' `exit repeat` at `:437`); past 200 sent messages the sets barely overlap and the filter silently stops working. (b) that Sent lookup has **no account filter** (`AnalyticsCommands.swift:150-155`) where the sibling `awaiting-reply` does (`:182`), so on a multi-account machine it can suppress against another account's Sent mail. Both verified in source; both need their own oracle pass. | mail | **DONE** | also fixed: Sent choice ignored the oracle's fallback PRIORITY |
| Q4d | **SQLiteReader leaves PII snapshots in `$TMPDIR`.** `copyToTemp` copies the Envelope Index / `chat.db` / NoteStore and relied on `deinit`, which never runs because ArgumentParser exits via `exit()`. Measured: >150 snapshot files totalling multiple GB, mode 0644 — real subjects/senders/recipients. **FIXED on the FOURTH attempt; the first three are recorded here so nobody re-derives them.** (a) *unlink right after `sqlite3_open_v2`* — FAILS with `disk I/O error`: the read-only open needs the copied `-wal`, which SQLite opens lazily. (b) *checkpoint the copy → `immutable=1` → unlink* — FAILS in C: `wal_checkpoint(TRUNCATE)` works and a warm read works, but SQLite faults pages in as later queries touch them, so `sqlite3_step` fails once the file is gone. A Python probe suggested otherwise only because `sqlite3.connect()` reads eagerly where `sqlite3_open_v2` does not — it was measuring something the code does not do. (c) *atexit registry + age-gated sweep* — SHIPPED AND REVERTED: `copyItem` preserves the source mtime, so a snapshot of a store idle for an hour is born sweep-eligible and a concurrent `apple` deletes a live reader's files. Re-stamping the copy fresh repairs that case but not the predicate, and all three reviewers flagged that age only ESTIMATES liveness — a laptop asleep mid-command reopens the same hole. **(d) SHIPPED: liveness, not age.** Each process owns `$TMPDIR/apple-cli-snapshots/s-<pid>-<uuid>/` (0700, snapshots 0600), holds `flock(LOCK_EX|LOCK_NB)` on a `.lock` inside it for its lifetime, and `atexit` removes the directory wholesale; the reaper asks the KERNEL whether each sibling's owner is alive — lock acquired ⇒ dead ⇒ remove, `EWOULDBLOCK` ⇒ alive ⇒ skip. Measured before building on it: owner alive → EWOULDBLOCK, owner SIGKILLed → ACQUIRED, second `flock` from the same process → EWOULDBLOCK (so a process cannot reap itself). Deleted with the old design: mtime stamping, the threshold, the name/suffix filter, the `.typeRegular` guard, the live-basename registry. **Coverage lesson, twice over:** under (c) deleting the single `atexit` line — the entire fix — left all 604 logic + 314 bats tests GREEN, and after the redesign the same was true of the reaper CALL SITE. Both are now covered by one bats test that runs the real binary, plants a dead session plus a foreign directory, and asserts no session directory survives whose `.lock` is still ACQUIRABLE (an acquirable lock means a dead owner, so it is an orphan). That predicate is used instead of counting directories because a count races a concurrent `apple` in both directions. **The test plants, it never deletes:** an earlier draft `rm -rf`'d the shared snapshots root, which two reviewers independently reproduced killing a concurrent reader with `disk I/O error` — the very failure that got (c) reverted, reintroduced by the test written to prove it could not happen. `$TMPDIR` cannot be redirected to sidestep this: `FileManager.temporaryDirectory` reads `confstr(_CS_DARWIN_USER_TEMP_DIR)` and ignores the env var (verified). Three review-caught vacuous tests were also repaired here; the symlink test in particular passed against an `lstat`→`stat` mutation until an unheld `.lock` was planted inside the target to make it discriminating. | all | DONE | 605 logic green 12/12; 315 bats green; red-proofs: `atexit`, reaper call site, `lstat` guard |
| Q4e | **`hasQuestion` was dead for message bodies.** `analyticsRows` never SELECTed a snippet column (no `summaries` join) while `analyticsRow` read `row["snippet"]`, so it was nil for every row and `Analytics.hasQuestion` collapsed to a subject-only `?` test — `"MEDIUM (contains question)"` could not fire on a body-only question and `priorityScore` permanently lost its 2-point body term. **FIXED** by joining `summaries` (`messages.summary` is an INTEGER FK into it) and selecting `SUBSTR(sm.summary,1,500)`, the same window the oracle reads. Gated behind a `summariesAvailable` probe (table + column present) because the Envelope Index is Apple's private schema and varies by Mail version — hard-coding the join makes every analytics query fail with `no such table: summaries` on a store without it, verified by red-proof. **Residual divergence, documented not hidden:** the oracle reads `content of aMessage` live over AppleScript so it has a body for 100% of scored messages; we read Mail's cached preview. Measured: only a small fraction of the store overall, but a substantially higher share of recent windows and well over half of the newest 200 — the oracle's own bound — because coverage concentrates in the window these commands actually score. Under-scores where absent, and can also OVER-score: `summaries` is a preview Mail GENERATES (whitespace-normalised, boilerplate collapsed), not a body substring, so a `?` at preview char 480 may sit past raw char 500. The first version of this row claimed over-scoring was impossible — review falsified it. Closing the rest = per-message AppleScript fetch, filed as Q4j. | mail | DONE | real-store A/B `needs-response --days 90 --max 200`: same 43 rows, 7 question-scored vs 3, 4 body-only vs 0; 608 logic green 12/12; 315 bats; red-proofs on join + probe |
| Q4f | **`emlDestURL` leaked full RFC-822 messages.** Generated `.eml` files went loose into the shared temp root at 0644 and were never deleted — measured 244 files, 976 KB, oldest 11 days, complete headers AND bodies. They cannot be deleted at command end: `openEml` runs `open -a Mail` and returns immediately, leaving Mail to read the file after the process exits. **FIXED, with a different answer per call site** (that split was the queue item's actual question): `--out` is operator-facing OUTPUT — path honoured exactly, mode left at their umask, never deleted; no `--out` is an internal temp — owned 0700 directory, file 0600, reaped after 24h by a later run. The `--gui-send` HTML temps moved in too (they were `defer`-deleted but survived any crash, in the shared root where nothing would collect them). Age is the weaker predicate rejected for snapshots, deliberately: there the owner is our own process and `flock` answers exactly, here it is Mail.app which cannot be locked, the hand-off takes seconds, and the worst case is a visible compose window rather than a corrupted read. Owned-directory logic extracted to a shared `AppleKit/OwnedTempDir` (validated on BOTH the exists and create paths — directory, uid, 0700 verified-not-hoped, symlinks refused), with pure path computation split from materialisation so `--dry-run` creates nothing, deletes nothing, and cannot newly fail. **The 244 legacy files are NOT deleted** — out of bounds for an autonomous run; operator command in the CHANGELOG. | mail | DONE | 623 logic green 15/15; 316 bats; red-proofs: temp-in-shared-root, dir re-tighten, regular-file guard, reaper wiring, `out == nil` split, every `restrictToOwner` call |
| Q4g | **Was the pre-fix flat-name leak inherited by other machines?** **NO — closed on evidence**, per this item's own escape clause: `which apple` empty (never installed), zero git tags (never released), and all 8 worktrees under `/path/to/local/resource` on this one machine, which shares a single per-user `$TMPDIR`. Nothing to inherit elsewhere. **An automatic legacy sweep was considered and REJECTED on measurement:** 12 distinct `apple-cli-*` fixture prefixes are live in the test suite right now, so a sweep of that glob in the shared root would delete a concurrently-running suite's fixtures — the same defect class reviewers caught three times this session. **What the measurement DID find:** the test suite was the bigger leaker — ~14,000 files, +25 per `swift test`, from per-suite hand-rolled temp helpers that never deleted. Fixed with a test-only `TestSupport`/`ScratchDirs` target (tracks exact URLs, reclaims in `deinit`); 3 suites migrated; growth now 0. Review caught that migrating the rate limiter's state path silently dropped coverage of its own mkdir-p — removing that made the limiter report `degraded: true` and ALLOW sends past the cap — so the invariant is now a `precondition` at the point of use, and the API that caused it was deleted. Convention recorded in AGENTS.md so the next suite does not reinvent a leaking helper. **The ~14,000 existing files are NOT deleted** (files this run did not create, in a directory shared with other apps); operator command in the CHANGELOG. | all | DONE | leak delta +25 -> 0 per run; 626 logic green 12/12; 316 bats; red-proofs: `ScratchDirs.deinit` no-op, limiter mkdir-p, the parent-absent precondition |
| Q4h | **Snapshot coherence.** The main DB and its `-wal` were copied at different instants, so a checkpoint RESETTING the WAL between them would pair a pre-checkpoint main file with a foreign-generation WAL. **MEASURED AND DECIDED** (real ~200 MB Envelope Index / ~300 MB chat.db, warm end-to-end command baseline 42/63 ms): unpinned clone 1.0/1.4 ms but incoherent; **read-pinned clone — chosen — no measurable cost** (warm A/B 42 vs 41, 63 vs 63; under a writer + TRUNCATE checkpoints, median 0.3 ms / p90 0.5 / max 0.7); `sqlite3_backup`+`journal_mode=DELETE` 337/493 ms; `VACUUM INTO` 692/747 ms. The last two are coherent but 13–26x the whole command, and raw `sqlite3_backup` output is additionally UNREADABLE by our read-only open (it inherits WAL mode; a read-only connection cannot create the `-shm`). **Two layers, and the order of trust is the point:** the GUARANTEE is a salt check — `-wal` bytes 16..32 change on every reset, read before and after, discard-and-retry on mismatch, two 32-byte reads, zero SQLite internals; the PIN (a held read transaction) is an optimization that makes mismatch vanishingly rare. That order exists because review FALSIFIED the first version of the pin's rationale: a read mark does NOT always block a TRUNCATE checkpoint — with the WAL fully backfilled the reader lands in slot 0 and one reset is permitted (harmlessly; the main file already has every frame), while a second is blocked because backfilling needs read-lock 0 exclusively. Also: the pin is gated on a `-shm` already existing, since opening a live store CREATES one in `~/Library/Mail/` that a read-only connection cannot remove; and the `-shm` copy was measured INERT and dropped. **Failure asymmetry, the reason verification is not optional:** WAL recovery validates the salt against the WAL's own frames, never against the main file, so an incoherent pair is ACCEPTED and returns a silently wrong answer rather than an error. | all | DONE | 635 logic green 25/25 (a 2-in-12 flake was found and fixed: the diagnostics were a mutable static that swift-testing parallel suites raced); 316 bats; red-proofs: the `SELECT` read mark, the pin, the `-shm` gate, and the whole coherent-copy call being deleted from `init` |
| Q4i | **`atexit` does not run on a signal death.** Ctrl-C during a slow read is the most likely abnormal exit this tool will see, and it stranded a session directory holding the operator's mail at 0600 until a later run reaped it. **FIXED** for SIGINT/SIGQUIT/SIGTERM/SIGHUP; re-raises with `SIG_DFL` so the shell still sees 130/131/143/129. **Three defects review found in the first version, each measured not argued:** (1) the handler was NOT async-signal-safe — reading a Swift `Array` static emits `swift_beginAccess` plus retain/release reaching `free()`, and `track`'s append holds a `Modify` access across a `malloc`, so a signal in that window aborted at exit 134 before any cleanup; all handler state now sits behind one immutable pointer, disassembly-verified in BOTH configs: no exclusivity check, no refcounting, no allocation. (Precisely: the debug handler emits nine `bl`s — the six libc calls, two of them via thin Swift overlay shims, plus the addressor for `cell`, whose fast path is branch-only and whose `swift_once` slow path is unreachable because `arm` resolves the token before installing. Said exactly, because the next auditor will disassemble it.) (2) unconditional `signal()` clobbered an inherited `SIG_IGN`, killing `nohup apple …` at 129 where it previously completed. (3) arming AFTER the mkdir left a reachable window — 12/12 stranded when signalled on first sight of the directory; arming first closes it. Also: `.lock` is unlinked LAST and RESTORED if `rmdir` fails, because the reaper keys on it — removing it first made a partial failure slower to clean up than no handler at all. **My own new test then found a fourth:** the registry was a fixed 64 slots and silently dropped everything past it (1-in-12 red, three untracked `.sqlite` files), so it now grows by publishing a whole new registry through the single pointer the handler reads. DECLINED, recorded not overlooked: `SIGKILL`/`SIGSTOP` (uncatchable) and the fatal-fault signals — each leaves a directory that keeps its `.lock`, the reapable state. `apple-cli-eml` is NOT covered — filed as Q4k. | all | DONE | 639 logic green 12/12 (incl. 4 new registry tests); 318 bats ×2, 0 failures, the 1 skip is a pre-existing data-dependent mail test; CLT build 0. Red-proofs, each an orthogonal mutation: no-handler → signal test red / nohup green; `SIG_IGN` guard removed → nohup red / signal green; `.lock` untracked → signal red; arm-after-mkdir → 12/12 stranded; fixed-capacity → growth test red. Behaviour A/B: 4 signals × 3 runs stranded=0 with rc 130/131/143/129; nohup posture survived 3/3 vs killed 3/3 unguarded |
| Q4j | **Body-question detection still misses messages Mail has not cached a preview for.** Q4e took `hasQuestion` from 0% body coverage to roughly a third of the recent window (well over half of the newest 200 on this store); the oracle reads `content of aMessage` over AppleScript and so scores 100%. The row said the measurement IS the decision — cheap, take full parity; seconds, keep the divergence. **MEASURED, and it is not seconds: ~1.5 s PER MESSAGE.** Per-message `content of m` in a repeat loop costs 2.14-2.22 ms×10³ each (N=20: 42.8 s; N=50: 110.8 s), and the obvious optimization does not rescue it — `content of messages 1 thru N` fetches every body in ONE Apple event and is only ~1.4x better (N=20: 28.6 s / 1431 ms per message; N=50: 80.7 s / 1614 ms), with byte-identical output (identical char counts both ways) confirming the bulk form skips no work. Closing the gap means fetching for the a sizable share of a 200-row window with no cached preview — dozens of messages, so **~107 s added to a command whose warm end-to-end baseline is 42 ms**, a ~2500x regression to recover a 2-point term in one heuristic. **DECISION: keep the documented divergence.** It is recorded in the Q4e row, in `Analytics.hasQuestion`'s docstring and in the CHANGELOG, and it under- or over-scores only `hasQuestion`, never correctness of the returned set. Revisit only if Apple exposes bodies through the Envelope Index or another non-AppleScript path. | mail | DONE | AppleScript A/B on the live store, Mail.app already running: loop 8.3 s / 12.8 s / 42.8 s / 110.8 s at N=1/5/20/50; bulk single-event 28.6 s / 80.7 s at N=20/50; identical char counts across both shapes as the positive control that neither skips work. No code change, so no test delta |
| Q4k | **The `.eml` temp directory — and the premise this row was filed on was HALF WRONG, which was the finding.** Filed after Q4i as "the same hole"; ground truth says only one of the two file classes is. (1) The `--out`-less `.eml` temps are a DELIBERATE HAND-OFF — `openEml` runs `open -a Mail`, which returns immediately and leaves Mail to read the file *after we exit*; the surface even tells the operator it is kept there. Signal-unlinking one destroys a live hand-off, so they are deliberately NOT registered, and that negative is pinned by a test. (2) The `--gui-send` HTML temps ARE registered: `sendHtmlViaGui` is synchronous, nothing reads them after the call. **DONE.** `SignalSafeCleanup` is now a top-level public AppleKit type (a second client in another module settled the "does it belong in SQLiteReader" question), and "paths to unlink" is split from "the one directory to remove": `registerRoot` adds a containment root WITHOUT making it removable, so the shared eml directory can never be the `rmdir` target — security confirmed that as structurally enforced, not merely unreached. The registry can now be armed with no removable directory at all, because a `mail send --gui-send` opens no snapshot and nothing else would install the handlers. **Two HIGH review findings fixed before landing, both from the shared-counter/shared-registry seam this change created:** `arm` was dropping the containment root along with the removable directory (every subsequent `track` refused, and in a debug build the refusal's `assertionFailure` raised SIGTRAP — a signal the handler deliberately does not install — so the process died with NO cleanup, stranding the directory the guard existed to protect); and `disarmForRetry`'s `count == 0` guard stopped being a valid proxy once two clients shared the counter, re-admitting the exact N1 regression it was written to prevent. Adoption now stores `dir` before `lockFile`, matching the handler's own liveness-marker-last rule. **Not pinned by a red-proof, stated rather than implied:** the disarm scoping fix — the discriminating case needs the shared session's directory actually cleared, which every other suite in the process depends on, and reverting the guard leaves the test green. Residual MEDIUM/LOW findings filed as Q4l. | mail | DONE | 643 logic green 12/12; release + CLT clean; bats 318 ok, 0 failures. Red-proofs, each rebuilt and compile-checked first: tracking the hand-off `.eml` fails the negative test naming that exact path; making `registerRoot` set the removable directory fails it on `removableDirectory`. Also DELETED a test of my own that was vacuous — it checked an unrooted path was absent from the tracked set without ever calling `track`, so it would have passed with the containment guard removed entirely |
| Q4l | **Residual Q4k review findings — and the critic was right twice more.** **DONE.** The corrected Q4k premise was STILL over-general, in two rounds. Round one: `send --html --gui-send` writes a complete RFC-822 `.eml` and then takes the `sendHtmlViaGui` branch, which never calls `openEml` — nothing reads it, and Q4k had excluded every `.eml` by extension. Round two, after I fixed that and wrote a comment claiming the enumeration was now closed: `willAutoSend` with attachments and a plain `willDraft` with attachments do the same, and strand base64 attachment payloads too — strictly MORE content than the file round one rescued. The lesson is the shape, not the branch list: the criterion is never "is it a `.eml`", it is "will anything read this after we exit". Both the disposability rule and the hand-off decision are now named pure predicates with exhaustive tables, and the negation is deliberate so an unrecognized future branch defaults to keep-the-file, never delete. `--out` always refuses. Also: `track` and `registerRoot` both lexically standardize now (comparing a normalized value against an unnormalized one refused every legitimate path and, in debug, raised the no-cleanup SIGTRAP); the shared-root and monotonic-`roots` findings are documented; and the `resolvingSymlinksInPath` rationale was BACKWARDS in the first draft — review measured that resolution closes the TOCTOU rather than opening it, so the real reason for lexical is that resolution silently no-ops on paths that do not exist yet, and the dominant caller tracks before creating. **One more vacuous test of mine deleted** — the Q4k "negative" asserted a path was absent from the tracked set after calling only the URL factory, which never tracks, so it passed with the predicate, the call site AND the containment guard all removed. Second one this arc. | mail | DONE | 645 logic green 12/12; release + CLT clean; bats 318 ok, 0 failures. Red-proofs, rebuilt and compile-checked: narrowing the hand-off decision back to gui-send-only fails the two newly-covered routes by name; inverting its default to delete fails all four hand-off cases; predicate always-disposable fails 3 of 4; dropping the standardize line stores `sub/../x.html` verbatim |
| Q5 | **MSG-1 fuzzy-search recall: port rapidfuzz's real 3-phase `partial_ratio`.** **DONE (with one measured residual, below).** `Fuzzy.partialRatio` was a single fixed-length sliding window; rapidfuzz's `_partial_ratio_impl` is three loops over the same Indel kernel — growing prefixes, full-length windows, shrinking suffixes. The cause of the gap is structural, not scoring noise: `ratio` is `2*LCS/(|a|+|b|)`, so a window SHORTER than the needle can outscore every full-length one because the denominator shrinks — `partial_ratio("golf","a quiet symbol")` is 66.7 via the 2-char suffix `"ol"` against 50.0 for the best 4-char window, which one fixed length cannot see at all. **Before: 768 real bodies x 10 terms at threshold 0.6 -> oracle 276, port 204 = 73.9% recall.** **Both reviewers then independently caught the same defect in my own fix:** an `if len1 == len2 { return ratioChars(...) }` shortcut bypassed the two loops the commit exists to add — the very bug Q5 is about, surviving in the one branch the fix skipped (`("thanks","thanka")` oracle 90.91, mine 83.33). Removed, plus rapidfuzz's swapped second pass for equal lengths. The 60-pair generated golden table contained NO equal-length pair, which is exactly why it stayed green — 10 equal-length rows added. | messages | DONE | 648 logic green 12/12; release + CLT clean; bats 318 ok. Golden table verified against rapidfuzz row-by-row. **The table as first committed was generated from live oracle output over a real store and should never have been — see D9; it has since been replaced with wholly-synthetic rows, each SELECTED by computing both rapidfuzz and the old single-window port and keeping only pairs where they disagree, so discriminating power is preserved and re-proven.** Red-proofs: disabling the prefix+suffix loops fails all 3 tests (deltas 16.67 / 7.58 / 16.67); restoring the equal-length shortcut fails the equal-length rows. End-to-end vs the live MCP oracle: a fixed probe term over `--hours 72` **12 vs 12, identical bodies, scores and order**; a second probe term **19 vs 18 — NOT exact**, CLI over-inclusive by one. Residual filed as Q5b |
| Q5b | **Q5 residuals — the after-evidence is weaker than the before-evidence, and one term still diverges.** Reviewers' remaining findings after the three-loop port landed. **(1) The headline recall number was never re-measured at the level it was measured at.** The 73.9% came from 768 bodies x 10 terms of WRatio comparisons; the fix is verified by 60 `partial_ratio` unit pairs plus one end-to-end term. Re-run that harness and publish the after-recall. **(2) `meeting --hours 72` returns 19 against the oracle's 18** — measured at commit time, direction is over-inclusive rather than dropped, cause unidentified; candidates are the equal-length swapped pass, the `r > 99.5 -> return 100.0` promotion (reachable via `tokenSetRatio`'s long combinations), or a `wRatio` branch. **(3) `windowScanCap = 1200` is now the only remaining structural divergence** — loop 2 is capped while loops 1 and 3 are bounded by the query length, so in a 5000-char body with a 6-char needle offsets 1195..4993 are examined by nothing. Two of 768 bodies exceed it on a 72-hour corpus; `--hours 8760` is unmeasured, and it likely interacts with the 1024-char cap in Q6/MSG-5. **(4) ~~The golden table uses RAW bodies~~ — CLOSED 2026-08-03 as a side effect of the D9 scrub.** It used raw bodies, where production feeds `partialRatio` only `fullProcess`ed lowercase ASCII (`ChatDB.swift:239-243`); 58 of the 60 rows were a shape production never sees, and 26 carried non-ASCII, making them oracle-fragile (Swift `Array(String)` yields graphemes, Python yields code points). The synthetic replacement is **0 of 63 rows outside `fullProcess` shape and 0 non-ASCII**, so the table is now strictly more production-representative than the one it replaced and the grapheme/code-point fragility is gone with it. **Still open in this row: (1) the recall re-measure, (2) the 19-vs-18 divergence, (3) the `windowScanCap` tail** — reviewer confirmed the cap is unreachable by either table (longest haystack 56 chars vs the 1200 cap) and that `ChatDB` applies no truncation on this path, so the tail hole is real in production and untested. | messages | TODO | — |
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
