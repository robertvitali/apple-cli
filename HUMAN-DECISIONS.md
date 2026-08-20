# HUMAN-DECISIONS.md — things only Robert can decide

**APPEND-ONLY.** Entries are never edited in place except to flip `Status:` and append a
`Resolution:` line with the date. Never delete an entry; a resolved decision is the audit record of
why the code looks the way it does.

**Why this file exists.** The autonomous driver (see `docs/COMPLETION-LOOP.md`) runs every task it
can to completion without asking. When it hits something that is genuinely the operator's call —
irreversible actions, product-posture deviations, anything needing a human physically present, or
money/account changes — it files an entry HERE, keeps going on everything else, and never blocks
the whole queue on one answer.

**What belongs here** (the driver's own test, so it does not over-ask):
1. **Irreversible / outward-facing actions** — retiring a server, tagging a release, sending to a
   non-self recipient, permanent deletion, anything touching real data the run did not create.
2. **Product-posture deviations** — where strict MCP parity and safety genuinely conflict, and the
   answer is a preference, not a fact.
3. **Operator-present verification** — anything needing a human at the machine (GUI windows, a
   real group chat, a TCC prompt on a fresh grant).
4. **Scope calls** — where "done" is a judgement about how far to take something, not a
   measurable criterion.

**What does NOT belong here:** anything the driver can settle by reading the oracle, running an
experiment, or applying a rule already written down. If it is knowable, the driver goes and knows
it instead of asking.

**Status values:** `OPEN` (waiting on Robert) · `ANSWERED` (decided, being applied) ·
`APPLIED` (decision is in the code/repo) · `RATIFIED` (decided, no code change needed) ·
`WITHDRAWN` (should not have been asked) · `SUPERSEDED`.

---

## LEDGER — every decision at a glance (updated 2026-08-19)

**Still needs you: D2, D3, D4, and the pending half of D9.** Everything else is settled.

| # | Topic | Status | Ruling |
|---|---|---|---|
| D1 | `notes delete-folder` previews by default | **RATIFIED** | Keep the preview default — `--execute` stays required on the only irreversible-and-unrecoverable write |
| D2 | Tag 1.0.0 + retire the six MCP servers | **OPEN** | **Terminal gate. Yours alone.** The loop stops here by design; go/no-go package is D13 |
| D3 | Live-validate `mail send --gui-send` | **OPEN (task)** | Not a decision — needs ~10 min with you at the machine, self-addressed |
| D4 | Live-validate iMessage group-chat send | **OPEN (task)** | Not a decision — no self-addressed shape exists, so only you can verify it |
| D5 | Chasing the Messages fuzzy-search recall gap | WITHDRAWN | Should not have been asked; became ordinary queue work |
| D6 | Eight parity posture calls | **APPLIED** | CONTACTS-L4 delete claim · NOTES-M1 restore 4 keys · NOTES-L4 structural divergence · gap10 keep opt-in body · **gap25 wire delete-rules live** · extra20 open by default |
| D7 | Committed phone number in public history | **ANSWERED** | "B then A" — superseded by D9, which covers the same number plus more |
| D8 | Which Mail oracle wins on a safety limit | RESOLVED | **Safety wins** — stricter limit wins on A/B conflicts; landed in `86728f4` |
| D9 | Personal data published to a public repo | **ANSWERED, HALF PENDING** | Repo made **private** 2026-08-19 (step B done) · **history rewrite + `main` redaction still TODO** |
| D10 | Search/find-contact length caps | WITHDRAWN | Should not have been filed |
| D11 | What `schema_version` tracks | **APPLIED** | **Shape only** — value breaks ride the MAJOR + CHANGELOG; both policy lines rewritten to agree |
| D12 | `notes save-attachment` can write to `~/.ssh` | **RATIFIED** | Keep strict Notes-oracle parity; residual documented, fleet stays intentionally inconsistent |
| D13 | Strict-superset go/no-go package | **APPLIED** | All items landed + live-verified; only D2 itself remains |

---

## D1 — `notes delete-folder` previews by default instead of executing

- **Status:** **RATIFIED 2026-08-19** — keep the preview-by-default deviation (option (a)).
- **Resolution:** Robert ruled to keep `--execute` required. `delete-folder` is the CLI's only irreversible-AND-unrecoverable write (measured: it cascades, and cascaded notes do NOT reach Recently Deleted), so the one-command divergence from the oracle stands as a documented safety posture, same class as the `APPLE_ALLOW_EMPTY_TRASH` precedent. No code change.
- **Filed:** 2026-08-02 (Notes write-model v2 flip, commit `ac0a7d0`)
- **Category:** product-posture deviation
- **One-line:** The only write that previews by default **without an oracle counterpart doing the
  same**. (Corrected after review: the first draft said "the only write in the whole CLI that
  deliberately does NOT behave exactly like the MCP", which over-claimed — Mail's trash surface
  also previews by default, but that IS parity, because oracle B's `manage_trash` defaults
  `dry_run=True`. `delete-folder` is the one with no such backing.)

**The conflict.** Your standing instruction is *"it should behave exactly like the mcp just as a
cli."* `apple-notes-mcp`'s `delete-folder` executes on call. Ours previews unless `--execute` is
passed. That is a knowing deviation, taken under the spec's own `APPLE_ALLOW_EMPTY_TRASH`
precedent (an operator affordance an agent cannot self-grant).

**Why I deviated — two inherited claims turned out to be false, and I measured both.**
1. *"delete-folder fails if the folder still contains notes"* — **FALSE. It cascades.** The
   oracle's own source only ever hedged ("may fail if the folder contains notes"); its tool
   description upgraded that hedge to an assertion, and this port copied the assertion.
2. *"Notes deletes are recoverable"* — **TRUE for `delete`/`batch-delete`, FALSE here.** With a
   labeled folder containing a labeled note: the folder went, the note went, and a store-wide
   search returned zero hits — while a control note deleted via `notes delete` in the same run was
   still sitting in Recently Deleted.

So it is an irreversible wholesale erase that was, as first written, both execute-by-default and
unsandboxed-by-default.

**Your options.**
- **(a) Keep the deviation** (current state). Safer; one command in the CLI does not match the MCP.
- **(b) Revert to strict parity.** `apple notes delete-folder X` then irreversibly destroys folder X
  and every note in it, with no preview. **Costing corrected after review: this is NOT the one-line
  change I first called it.** The flag itself is one line
  (`DeleteFolderCmd.surfaceDefaultDryRun`, `Sources/NotesKit/NotesOrgCommands.swift`), but three
  sites pin the current default and would fail: the permanent `# flagless-on-purpose` marker at
  `bats/notes.bats:188`, the marker-count assertion in `bats/smoke.bats`, and the Notes posture
  suite. Worse, that bats probe is deliberately flagless — post-revert it stops being a probe and
  becomes a **live folder delete** on every suite run. Choosing (b) means migrating all three in the
  same commit, exactly as the Calendar and Messages flips had to.

**My recommendation:** (a). It is the only irreversible-and-unrecoverable write in the CLI, and
`--execute` is a small tax to pay once. But it is your product, and (b) is a one-line change I will
make without argument if you prefer strict parity.

**Blocking?** No. Everything else proceeds either way.

---

## D2 — Tag 1.0.0 and retire the six MCP servers

- **Status:** OPEN — **HARD STOP. The driver will never do this autonomously.**
- **Filed:** 2026-08-02 (standing instruction from an earlier session, recorded here so it is not
  lost to context)
- **Category:** irreversible / outward-facing

**Your standing instruction, verbatim:** *"approved. do 1-5 now and then when you get to 6 stop for
my explicit approval."* Step 6 is tag `1.0.0` + retire the MCP servers.

**Why it stays yours.** Retiring the servers removes the parity ORACLE. Every claim in this repo is
verified by diffing against the live MCPs; once they are gone, that verification is no longer
reproducible. It is also the point of no return for the whole project.

**What the driver will do instead:** run every other task to completion, re-run the strict-superset
audit, and present a single go/no-go package — per-domain parity evidence, the remaining accepted
divergences, and anything still open in this file — for you to approve or reject.

**Blocking?** It is the terminal gate. The loop STOPS here by design; that is the stopping
condition you asked for.

---

## D3 — Operator-present live validation: `mail send --gui-send`

- **Status:** OPEN — **not a decision; a task needing you at the machine.** Nothing blocks on it.
- **Filed:** 2026-08-02 (carried from task #34)
- **Category:** operator-present verification

`--gui-send` composes in Mail.app's UI and drives the send through the GUI window. It is wired and
its gate code has been inspected, but validating it end-to-end means watching a real compose window
appear and send. An agent cannot confirm that, and the failure mode of getting it wrong is a real
outbound email.

**What I need:** ten minutes with you at the machine. I will drive it self-addressed only
(the address in `APPLE_TEST_RECIPIENTS`), you confirm the window behaves and the mail arrives.

**Blocking?** No — it is the last unverified Mail surface, but nothing else depends on it. It does
mean Mail's parity claim carries one "wired, not live-validated" asterisk until it is done.

---

## D4 — Operator-present live validation: iMessage group-chat send

- **Status:** OPEN — **not a decision; a task needing you at the machine.** Nothing blocks on it.
- **Filed:** 2026-08-02
- **Category:** operator-present verification

Group-chat send has **no self-addressed shape** — there is no group containing only you — so unlike
every other send surface it cannot be verified safely by an agent. Inside the sandbox the recipient
allowlist refuses group-chat ids outright; outside it, sending would message real people, which the
standing rules forbid absolutely.

**What I need:** either (a) you create a throwaway group containing only your own devices and I
send to it while you watch, or (b) you accept it as "wired + code-inspected, never live-validated"
and I record that asterisk in the port spec.

**Blocking?** No.

---

## D5 — How hard to chase the Messages fuzzy-search recall gap

- **Status:** **WITHDRAWN — do not answer this.** I should not have asked.
- **Filed:** 2026-08-02 · **Withdrawn:** 2026-08-02, hours later
- **Resolution:** Queued as ordinary engineering work (`COMPLETION-LOOP.md` Q5). No decision needed.

**Why it was withdrawn.** I filed this as a scope call on the premise that closing the gap meant
*"reimplementing rapidfuzz's partial-ratio alignment (an optimal-substring-alignment search) in
Swift … plausibly the largest single item left."* **That premise was false, and I had not checked
it before asking you.** The reconciliation pass read rapidfuzz's actual implementation on disk
(`~/.cache/uv/archive-v0/…/rapidfuzz/fuzz_py.py:116-160`, `_partial_ratio_impl`) and it is three
bounded loops over the *same* normalized-Indel kernel the CLI already has in `ratioChars`:
growing prefixes, full-length windows, then suffixes. Our `Fuzzy.swift:236` implements only the
middle loop and caps it at 1200 chars. That is a contained fix, not a research project.

This file's own rule is *"if it is knowable, the driver goes and knows it instead of asking."*
I broke it, so the entry is withdrawn rather than left sitting in your queue.

**Two corrections to the original text, for the record:** the gap is WORSE than I reported
(re-measured live 2026-08-02: `the probe-term search --hours 72` → oracle **14**, CLI **1**, i.e. 7% recall,
not the 16→2 I cited), and `docs/port-specs/messages.md` §8 still understates it as affecting only
"low-relevance matches at the threshold floor" citing 25→21 — Q5 must fix that text too.

<details><summary>Original entry, preserved (append-only)</summary>

- **Category:** scope call

**The finding.** Our `WRatio` port's `partialRatio` slides a fixed `len(shorter)` window;
rapidfuzz maximizes over variable-length substring alignments. Measured at the default 0.6
threshold: `the probe-term search --hours 72` → oracle 16 hits, CLI 2. Aggregate over 10 terms × 1500 real
messages: oracle 293, CLI 231 — **78.8% recall, 21% of fuzzy matches dropped.** The port spec
currently calls this an "accepted behavioral-parity boundary" affecting only "low-relevance matches
at the threshold floor" and cites 25→21; the measured worst case is 16→2, so **the spec materially
understates it** and should not be cited as evidence of parity.

**Why this is a scope call, not a bug I can just fix.** Closing it properly means reimplementing
rapidfuzz's partial-ratio alignment (an optimal-substring-alignment search) in Swift and proving it
byte-equivalent across a large corpus. That is real work — plausibly the largest single item left —
for a search-quality improvement on one command.

**Your options.**
- **(a) Fix it properly.** Port the real alignment algorithm, prove equivalence on the 1500-message
  corpus. Highest fidelity; largest remaining task.
- **(b) Correct the documentation only.** Replace the understated claim with the measured 16→2 /
  78.8% numbers and record it as a known, quantified divergence. Cheap and honest, but Messages is
  then **not** a strict superset, so the "100% parity" claim gating MCP retirement fails for this
  domain.
- **(c) Middle:** raise recall with a cheaper heuristic (e.g. multi-window scan) and measure the
  new recall, accepting <100%.

**My recommendation:** (a), because the whole project's acceptance criterion is strict superset and
(b) knowingly forfeits it for one domain. But it is a genuine cost/benefit call and (a) is a
meaningful chunk of work, so I am not making it unilaterally.

**Blocking?** No — the driver will do everything else first and leave this until last, so your
answer arrives before it matters.

</details>

---

## D6 — Eight parity gaps that are posture calls, not engineering

- **Status:** **APPLIED 2026-08-19** — all eight ruled (CAL-08 + REM-11 on 2026-08-18; the other six one-at-a-time on 2026-08-19).
- **Resolution:** CONTACTS-L4 → **delete the claim** (`contacts mcp serve` was never built and is now explicitly out of scope; an MCP server inside the MCP replacement defeats D2). NOTES-M1 → **restore all four wire keys** (`content`/`tags`/`created`/`modified`), accepting the per-hit round-trip: strict parity. NOTES-L4 → **accepted structural divergence** (measured: the 4 resources are URI aliases for commands the CLI already has, the 3 prompts are LLM-client menu text; no capability missing). mail/gap10 → **keep the body opt-in** (the `content` key is always emitted, `""` when suppressed, so a ported caller never KeyErrors; Mail has no body index and the fetch is a slow scan). mail/gap25 → **wire the rule delete action LIVE** (full parity; the CLI can now install standing rules that permanently delete matching mail unattended — preview still warns). mail/extra20 → **open by default** (matches oracle B; `--no-open` suppresses; the command still cannot send anything).
- **Filed:** 2026-08-02, from the HEAD reconciliation (`the D9 live-audit dump`)
- **Category:** product-posture deviations

Eight of the 92 open gaps came back classified as needing you rather than me, because each is a
"how should the product behave" question where strict parity and something else genuinely conflict.
None is blocking; the driver works around all of them. Answer at leisure, in any order.

| id | Domain | The question |
|---|---|---|
| `CONTACTS-L4` | contacts | The port spec claims a `contacts mcp serve` dual CLI+MCP frontend that was never implemented. **Build it, or delete the claim?** |
| `NOTES-M1` | notes | `search-notes` drops four oracle wire keys (`content`, `tags`, `created`, `modified`). Restoring them costs a per-hit AppleScript round-trip. **Parity or speed?** |
| `NOTES-L4` | notes | The oracle exposes 4 MCP *resources* and 3 *prompts* with no CLI counterpart. Resources/prompts are an MCP-protocol concept. **In scope for a CLI, or an accepted structural divergence?** |
| `CAL-08` | calendar | `--account` validates against event-owning sources only; the oracle validates against ALL EKSources. Matching it means accepting an account that can never yield events. **Match the oracle, or keep the friendlier error?** |
| `REM-11` | reminders | The oracle mirrors a reminder's URL into the notes body (`URLs:\n- <url>`); we keep it structured and never pollute notes. **Byte-parity, or the cleaner model?** (This one is already a documented deliberate deviation — confirming it is enough.) |
| `mail/gap10` | mail | `get_message` `include_content` defaults True in the oracle, off here. Flipping it makes every fetch heavier. **Match, or keep opt-in?** |
| `mail/gap25` | mail | Rule action `delete: true` is previewed but refused live. **Wire it, or accept as divergence?** — it is the one rule action that destroys mail automatically, forever, without a further prompt. |
| `mail/extra20` | mail | `draft-rich` flips `open_in_mail` True → opt-in, unrecorded in the parity ledger. **Restore the default, or record the divergence?** |

**My recommendation if you want one answer for all eight:** take strict parity on `NOTES-M1`,
`CAL-08`, `mail/gap10`, `mail/extra20` (they are cheap and the acceptance criterion is parity),
record `REM-11` and `NOTES-L4` as accepted divergences, delete the unimplemented claim for
`CONTACTS-L4`, and **leave `mail/gap25` refused** — auto-deleting mail with no confirmation is the
one place I would rather fail the parity bar than ship the capability. Say "your call" and I will
apply exactly that.

---

## D7 — Committed PII: a real phone number is in this PUBLIC repo's git history

**Status:** **ANSWERED 2026-08-19 — "B then A", plus redact `main`.** · **Filed:** 2026-08-02 · Superseded in practice by [D9](#d9), which covers the same phone number plus two larger leaks; track the remediation there.

**What I found.** A real phone number is committed in a tracked port spec and in
`Tests/MessagesKitTests/MessagesKitTests.swift`. It predates the completion loop — I did not
introduce it — but it is in the repository's history, and this repository is public.

**Why I am not just fixing it.** Deleting the number from HEAD does not remove it. Git retains
every historical blob, so the value stays reachable via `git log -p`, any existing clone, and any
fork or mirror. Genuinely removing it requires rewriting history (`git filter-repo` or
equivalent), which force-pushes every branch, breaks every outstanding clone, and — if the repo
has ever been forked or cached by a third party — still does not guarantee removal. That is a
destructive, outward-facing operation on your published history. It is your call, not mine.

**The options, honestly stated:**

| Option | What it costs | What it actually achieves |
|---|---|---|
| **A. Scrub history** (`git filter-repo`, force-push all refs) | Rewrites every SHA; invalidates clones/forks; any commit SHA cited in Asana or docs goes stale | Removes it from *this* repo. Cannot remove it from forks, caches, or anything already scraped |
| **B. Redact at HEAD only** | Cheap, one commit, no history rewrite | Stops it appearing in the current tree; the history remains readable. Honest half-measure |
| **C. Accept and move on** | Nothing | Appropriate only if you consider the number non-sensitive (e.g. already public) |

**My recommendation:** **B now, and decide on A separately.** Redacting HEAD is strictly an
improvement, costs nothing, and does not foreclose A. Treat A as a deliberate, scheduled operation
rather than something folded into a parity commit — force-pushing rewritten history during an
active multi-worktree effort is how work gets lost.

**What I need from you:** just "B", or "A and B", or "leave it". I will not rewrite history without
you saying so explicitly.

---

## D8 — When the two Mail oracles disagree about a limit, which one wins?

**Status:** RESOLVED 2026-08-18 — **SAFETY WINS.** Robert's ruling: add oracle A's `expensive_ops`
(20/60s) rate limit to `reply`, cap `draft send` (recipient cap + send-budget consumption), and
adopt the **scoped standing rule**: *on an A-vs-B disagreement about a SAFETY limit (send rate,
recipient caps, bulk caps on destructive ops), the stricter limit wins.* This knowingly makes the
CLI stricter than oracle B on those paths — accepted as a deliberate safety posture for an
agent-driven tool where a runaway mass-send is irreversible. **LANDED 2026-08-19** in `86728f4`
(ReplyRateLimiter 20/60s consumed once per live reply; draft-send consumes the sends budget +
100-recipient in-script cap; dry-run never consumes; review-hardened with a cross-process flock
and a corrupt-state degraded signal); the stricter-than-B posture is documented in
`docs/port-specs/mail.md` (rate-limit table + rows 15/16). · **Filed:** 2026-08-02 ·
**Blocks:** nothing — the mail-parent close gate is satisfied on this decision.

Mail is the one domain replacing TWO servers (`AGENTS.md`): oracle A
(s-morgan-jeffries@0.6.0) and oracle B (patrickfreyer@3.1.3). I verified they disagree about
safety limits, and the repo has no written rule for that case — so Q3 had to pick one, and I want
the pick on the record rather than buried per-site.

**Ground truth.** Oracle A has a rate limiter (`sends` 3/60s, `expensive_ops` 20/60s, `cheap_reads`
60/60s), a 100-recipient cap, and 100-item bulk caps on `mark_as_read`/`delete_messages`. Oracle B
has **none of these** — a grep for `max_recipients|rate_limit|TIER_LIMITS|max_items` across the
whole package returns zero hits.

**Why it is genuinely ambiguous.** `AGENTS.md` says added capability is welcome and dropped
capability is a failure. Read strictly over the UNION of both oracles, *any* limit the CLI enforces
drops a capability oracle B grants — which would make Q3's whole rate limiter a parity violation.
Read as "match each oracle's own gates where that oracle owns the operation", Q3 is correct. Both
readings are defensible from the text; they prescribe opposite code.

**What I shipped, so you can veto it:** the second reading. A surface caps only if the oracle that
owns that operation caps it. Concretely — `send` caps recipients (oracle A `send_email`);
`reply`/`forward`/`draft-rich` do not (A's `forward_message` checks only `if not to:`,
`reply_to_message` validates nothing, B caps nothing); `send`+`forward` consume send budget
(A's `sends` tier); `mark`/`delete` cap at 100 items, `move`/`flag` do not.

**Two live consequences of that choice:**

| # | Consequence | Why it is uncomfortable |
|---|---|---|
| 1 | `reply` has NO rate limit (oracle A allows 20/60s via `expensive_ops`, which this port does not carry) | A runaway loop can just use `reply` instead of `send` and send without bound. The threat Q3 exists to bound is routed around. |
| 2 | `draft send` delivers real mail with no recipient cap and no rate-limit consumption | It maps to oracle-B-only `manage_drafts`, so under the shipped reading adding a gate there would itself be a violation. Both reviewers flagged it; I left it, deliberately. |

Neither is a *parity* defect under the shipped reading — both are **safety** gaps. That distinction
is the whole reason this is your call: parity I can settle by reading the oracle, safety posture I
cannot.

**My recommendation:** port `expensive_ops` (20/60s) for `reply` only, and extend the send budget to
`draft send`. Rationale: 20 replies/60s burdens no legitimate use, no test replies twice, and the
runaway-loop hole in row 1 is real. I did NOT do it unilaterally because it knowingly makes the CLI
stricter than oracle B, which is precisely the direction `AGENTS.md` calls a failure — I am not
willing to spend your parity bar on my own safety preference without you saying so.

**What I need from you:** either "safety wins — add the reply limit and cap draft send", or
"parity wins — leave it, record the gaps", or a general rule for A-vs-B conflicts that I apply
everywhere instead of asking again.

---
## D9 — I published your personal data to this PUBLIC repo, twice, and one leak is bigger than the one I set out to fix

**Status:** **ANSWERED 2026-08-19 — "B then A", plus redact `main`.** · **Filed:** 2026-08-03 · **Step B is DONE:** the repo was made **private** on 2026-08-19 (containment). **Step A (history rewrite + force-push, including the commit-message rewrite) and the `main` HEAD redaction are still PENDING** and are the only outstanding items in this file besides D2/D3/D4. A same-day value-free rescan of `integration` HEAD found three MORE live leaks the earlier pass missed — the phone "redaction" had been partial rather than complete, alongside two further address leaks; all fixed in `a-fix-commit`, and a standing no-personal-data rule was added to `AGENTS.md`. ·
**Severity:** the highest-severity entry in this file. I caused both leaks.

### What is exposed

**(1) Verbatim iMessage bodies.** A golden table generated from live oracle output over a real store was committed and pushed. Some of that content originated with third parties, so the disclosure was not the operator's alone to forgive. The carrying artifact is deliberately not named here.

**(2) A live account dump — worse, and I did not notice it until a reviewer swept for it.**
A live-audit artifact was tracked and pushed. It was generated by running the CLI against real accounts. It carried substantial personal data of the operator and of third parties. The value classes are deliberately not enumerated here. It had been only partially redacted, which means the data was seen at authoring time and the pass was not finished -- partial redaction is not redaction.

**(3) Smaller, also live at HEAD until this commit:** several further real literals across a number of files and spellings, one of them sitting under a comment that declared it synthetic -- the false label being the actual hazard, since that is what a future audit trusts and skips. The specific artifacts are deliberately not enumerated here.

**(4) A commit message itself** carried real content that no file-level rewrite reaches.
This matters for the remediation: a file-level history rewrite (`filter-repo --path`) does **not**
touch commit messages, so an operator who ran the obvious fix would verify a clean file and still
be publishing the value. Commit messages render on the commit page and in every clone.

### What this commit fixes (all at HEAD only)

Every fixture implicated was regenerated as wholly synthetic and re-verified against the
oracle at identical value; live-audit artifacts were untracked; `.gitignore` switched from
enumerating known filenames to matching by class; every real literal was replaced with a
reserved-range or otherwise standard placeholder in every spelling; and the false "synthetic"
label that had hidden one of them was corrected. The specific artifacts and value classes are
deliberately not enumerated here.

### What only you can decide

Everything above is HEAD. **Both leaks remain in the pushed history**, and removing them means
rewriting published history and force-pushing — destructive and outward-facing, so I stop here.

**Step zero, and it expires.** Before choosing, capture
`the repo traffic page` (clones + unique cloners for Aug 2-3)
and `the repo forks page`. GitHub retains traffic data for
**14 days only**, so the evidence that decides whether this needs escalation is being deleted on a
rolling clock while this entry sits open. If a fork exists, note that going private **detaches**
forks rather than deleting them.

**Verified blast radius** (I checked rather than assumed, because my first draft of this entry
overstated it): both leak commits were confined to a single branch that nothing else tracked -- not `main`, and none of the domain worktrees. Rewriting is a small operation, not a multi-worktree hazard.

| Option | What it costs | What it actually achieves |
|---|---|---|
| **A. Rewrite history** (`filter-repo`, force-push `integration`) | SHAs from the earliest bad commit forward change; ~3 doc references go stale | Removes both leaks from this repo. Must ALSO rewrite commit messages, or the leak survives there. Old commits stay viewable at their URL until the host purges cached views, which is a request rather than something automatic |
| **B. Make the repo private first, rewrite at leisure** | Loses public visibility while private | Closes the window now and makes A unhurried. Does **not** reach an existing fork |
| **C. Accept it** | Nothing | Not defensible -- the second leak carries third-party data, which is not the operator's alone to accept |

**My recommendation: B, then A.** Going private is instant and reversible; the rewrite is then
scheduled rather than an emergency. I would not have said this before checking the blast radius —
A alone is genuinely small here — but (2) is severe enough that stopping the exposure beats
sequencing elegance.

**One thing I got wrong and should own:** my first draft of this entry said "HEAD is already
scrubbed" while the scrub was still uncommitted, and gave the push date as 2026-08-02. Both were
wrong in the direction of making this look more handled than it was. Corrected above.

**A note on this entry's own risk:** it named coordinates, in a tracked file, on the public
repo, while the rewrite is pending — which signposts the data. I judged actionability worth more
than obscurity, since the leak commit was one `git log` from the branch tip either way. Say the word and
I will land a redacted version and keep the detail out-of-band.

**Related:** **D7** is the same phone number. I mischaracterised it above as "the same history
problem" — it was not; it was live at HEAD in several places (and still is on `main`, which this
worktree cannot reach). D7's own recommendation was "B now" — redact at HEAD — and that had never
been done, in the same file I was editing nearby. This commit does it for `integration`;
**`main` still carries it**.

**What I need from you:** "B then A", "A now", or "leave it" — and separately, whether to redact
`main`. I will not rewrite or force-push anything until you answer.

---
## D10 — Parity says drop the search/find-contact length caps; measurement says they stop a hang

**Status:** WITHDRAWN (2026-08-03, same day) — **I should not have filed this.** ·
**Resolution:** MSG-5's premise is a misclassification, and I had already decided the identical
question myself, the same week, without asking. Kept the caps; see below.

**Why it was withdrawn, recorded because the error is more useful than the entry:**

1. **The bucket was wrong.** `docs/write-model-v2.md` bucket 3 is about CONSENT gates — its
   stated members are label guards and self-only recipient allowlists. A resource bound is
   **bucket 1**, which says in as many words: *"refusing an attack path the oracle is merely
   vulnerable to is not a capability drop."* Under the correct bucket the caps are KEPT and
   always apply, and there was never a conflict to escalate. I classified a DoS bound as an
   authorization gate and then escalated the contradiction my own misclassification created.
2. **I had already made this call unilaterally.** Q5b replaced `windowScanCap` with
   `maxScanWindows = 20_000` — a documented deviation past ~20k, shipped, marked DONE, no
   decision filed. This entry's own option C described itself as "the same shape as the
   `maxScanWindows` bound already shipped". Same shape, same domain, same week, opposite
   handling. That inconsistency is the tell.
3. **Filed decisions rot, so filing a spurious one has a real cost.** D7 sat OPEN while the
   phone number it describes stayed live at HEAD — 23 lines from code I was editing. A fourth
   open entry dilutes D9, which has a 14-day GitHub-traffic clock on it.

**Nothing is required from you on this entry.** It is left in place, withdrawn rather than
deleted, because the file is append-only and because "the driver escalated instead of deciding"
is worth keeping. D7, D8 and D9 remain genuinely open.

**Original entry follows, unedited.**

**Why you and not me (AS FILED — the reasoning that was wrong):** the project's own taxonomy and
its own security review point opposite ways,
and the tie-breaker is a risk appetite, not a fact I can measure.

**The parity side.** `MSG-5` is correct on the facts: the oracle validates only empty-term,
`hours < 0`, `hours > 87600`, and threshold outside `[0,1]`. It imposes **no length limit**. Our
1024 cap is a CLI-only restriction with no oracle counterpart — `docs/write-model-v2.md` bucket 3 —
and bucket-3 restrictions are supposed to apply only inside the opt-in sandbox. Under a strict
reading, `apple messages search` should accept any term the oracle accepts, and today it does not.

**The safety side.** The cap exists because unbounded input hangs the process, and I have measured
it twice this week:

| path | input | measured |
|---|---|---|
| `messages search` | 1024-code-point term vs a 10,000-char body | ~3s per `partialRatio`, and `wRatio` runs 5 per candidate over up to 10k rows |
| `messages find-contact` | 500,000 conjoining-jamo code points vs **200** candidates | **9.95s** — and a real address book is an order of magnitude larger |

Neither number is theoretical and neither path is bounded by anything else. A message body is
attacker-influenceable (anyone who can iMessage you), and the term is agent-supplied, so a
prompt-injected agent reaches this.

**Why the obvious compromise is not obviously right.** "Make the cap sandbox-scoped" is what the
gap record recommends, and it satisfies the taxonomy — but the sandbox is opt-in, so the DEFAULT
path is exactly the one that would hang. That inverts the usual reason for a bucket-3 rule, which
assumes the restriction is a nuisance rather than a guard.

| Option | Parity | Risk |
|---|---|---|
| **A. Keep the caps as they are (current state)** | Deviates from the oracle for terms > 1024 code points — inputs no human types | Hang is closed on both paths |
| **B. Sandbox-scope the caps** (what MSG-5 recommends) | Exact parity outside the sandbox | Re-opens both measured hangs in the DEFAULT path |
| **C. Raise the caps far above human use and keep them always** (e.g. 64k code points) | Deviates only for inputs that are already pathological | Bounded tail; same shape as the `maxScanWindows` bound already shipped |

**My recommendation: C**, and I have left the code at **A** in the meantime because leaving a guard
up is the reversible choice — if C or B is what you want, that is a small follow-up, whereas
shipping B and discovering a hang is not.

**What I need from you:** "A", "B", or "C" (with a number if you want a different ceiling). Until
then MSG-5 stays open and Q6 is closed on its other two gaps.

---

## D11 — `schema_version` and a value-changed/shape-unchanged breaking change: the policy contradicts itself

**Status:** **APPLIED 2026-08-19 — option A (shape only).** · **Filed:** 2026-08-03 ·
**Resolution:** `schema_version` tracks STRUCTURE only — key added-as-required/removed/renamed/retyped, or an enum/exit-code change. A value-level break with unchanged shape rides the MAJOR + CHANGELOG instead. Rationale: the field answers exactly one question, *"can my parser still read this?"*, so it must not churn on value fixes. Both contradicting lines in `docs/versioning-policy.md` were rewritten to agree (that edit, not the one commit, was the deliverable). No amend needed — the shipped commit already took this branch.
documented it; the queue routes around this) · **Severity:** low blast radius today, but it decides
how every future output-value break is versioned.

### The situation

Q7-L3(a) changes the ERROR envelope's `tool` field from always `"apple"` to the domain named by
`argv[1]` on pre-dispatch parse failures. The envelope's STRUCTURE is untouched — same keys, same
types, same nesting. Only the VALUE of one existing field changes, and it changes from a wrong
value to a right one.

`docs/versioning-policy.md` has two rules for that, and they give opposite answers:

- **`:342-344`** — "`schema_version` is an **integer**, incremented **only** on a breaking output
  change (i.e. it steps in lockstep with the CLI **MAJOR** for output-affecting MAJORs)."
  The `:244` table classifies "change status/enum string value" as a `break` in the **JSON output**
  column → MAJOR. So this IS an output-affecting MAJOR, and under this rule `schema_version` steps.
- **`:492`** — "if the JSON output changed **shape** incompatibly, bump the integer."
  The shape did not change, so under this rule it does not step.

`docs/DESIGN.md:33` does not break the tie: "steps only on a breaking output change" is the
`:342-344` phrasing.

### What I did, and why I am not treating it as settled

I followed `:492` — `schema_version` stays at 1 — and said so explicitly in the CHANGELOG along
with both citations. The reasoning: `:345` invites agents to "hard-assert `schema_version == N` and
fail fast/loudly", so stepping it breaks EVERY consumer, including ones that never read `tool`, in
order to signal a change that only affects consumers routing on `tool`. Not stepping leaves a
hard-asserting agent unaware of a change that would not have broken it anyway. The conservative
branch looked like the smaller harm.

I want to be straight that this is a judgement call I made inside a code change, not a policy
reading that follows. A reviewer caught me stating it as settled — the earlier draft attributed the
word "SHAPE" to `DESIGN.md:33`, which does not contain it, and did not cite `:342-344` at all. That
is the failure mode this file exists to prevent: resolving an open policy question silently, inside
a commit, by paraphrase.

### What I need from you

Which rule governs a value-changed/shape-unchanged break?

- **A** — `:492` wins (shape). `schema_version` tracks STRUCTURE only; value breaks are carried by
  the MAJOR and the CHANGELOG. I then reword `:342-344` to say "shape" so the two agree. This is
  what the current commit does.
- **B** — `:342-344` wins (output). `schema_version` steps to 2 on this change, and in general
  steps with every output-affecting MAJOR. I then reword `:492` and amend this change.
- **C** — Something in between: e.g. structure-only for `schema_version`, plus a separate additive
  `output_revision` (or similar) for value-level breaks, so a hard-asserting agent has something to
  watch without every value fix breaking it.

Whichever you pick, one of the two policy lines needs editing so this cannot recur — that edit is
the actual deliverable here, not the choice for this one commit.

---

## D12 — Notes `save-attachment` can write to `~/.ssh` etc. (matches its oracle); Mail/Contacts refuse

- **Status:** **RATIFIED 2026-08-19** — keep option (b), strict Notes-oracle parity.
- **Resolution:** Robert ruled to keep `notes save-attachment` matching its oracle verbatim, so it can still target `~/.ssh` and friends; the fleet stays intentionally inconsistent (Mail and Contacts block credential dirs because THEIR oracles do). The residual stays documented in `PathConfinement.swift` + the Q13 CHANGELOG entry. No code change.
- **Filed:** 2026-08-18 (Q13 review — critic finding on the shared write-confinement promotion)
- **Category:** parity-vs-safety posture call
- **One-line:** `apple notes save-attachment --path ~/.ssh/authorized_keys --execute` is **accepted**
  and overwrites the SSH key with attachment bytes, because Notes' guard (`NotesKit.AttachmentFS`)
  is a verbatim port of `apple-notes-mcp@2.5.12` `attachmentFs.ts` — it confines writes to
  home / temp / `/Volumes` but has **no credential-directory blocklist**. Mail's attachment-save and
  Contacts' `--out` DO block credential dirs (`.ssh`/`.gnupg`/`.aws`/`.config`/`.claude`/Keychains/
  LaunchAgents/LaunchDaemons), because the **Mail** oracle (patrickfreyer) blocks them and Contacts
  has no oracle output-path at all. So the fleet is inconsistent by ORACLE, not by code drift.

- **Why it's your call:** adding the blocklist to Notes would make the CLI *stricter* than the Notes
  oracle — i.e. it would DROP a write the oracle permits (writing an attachment into a dir under
  home that happens to be `~/.ssh`). Under the strict-superset rule "capabilities it drops are
  failures," that is a deliberate parity divergence, not obviously correct. But the capability being
  "dropped" is *overwriting your own credentials with attachment bytes*, which no real workflow
  wants and an attacker who controls a note's attachment + the path very much does.

- **(a) Add the credential blocklist to Notes too** (route `AttachmentFS.assertSafeSavePath` through
  the shared `sensitiveWriteDir`). Fleet-consistent, closes the hole; a documented, safety-only
  superset *narrowing* vs the Notes oracle. Recommended.
- **(b) Keep strict Notes-oracle parity** (current state). `notes save-attachment` can still target
  `~/.ssh`; the residual is documented in `PathConfinement.swift` + the Q13 CHANGELOG entry.

Q13 shipped option (b) as the status quo (it did not touch Notes) and documented the residual
honestly rather than silently claiming universal coverage. This entry is the decision to promote to
(a) or ratify (b).

---

## D13 — Strict-superset GO/NO-GO package (the D2 gate)

- **Status:** **APPLIED 2026-08-19** — every item in the package is landed and live-verified; only [D2](#d2--tag-100-and-retire-the-six-mcp-servers) itself remains.
  promised. The loop has run every autonomous task to completion and STOPS here.
- **Filed:** 2026-08-18, after the Q17 re-audit (`a gitignored local re-audit artifact`, a gitignored
  local artifact; the tracked summary is the Q17 row in `docs/COMPLETION-LOOP.md`).
- **Category:** the terminal go/no-go — decisions here gate closing the domain Asana parents and,
  ultimately, D2 (tag 1.0.0 + retire the MCPs).

### Where each domain stands (Q17 re-audit, HEAD after this commit)

The write-model-v2 migration (your 2026-08-01 "behave exactly like the mcp" decision) plus the
Q1–Q16 gap-closure work closed the vast majority of the 2026-07-31 audit's 111 gaps: **every HIGH
write-drop is lifted** (writes execute by default, sandbox opt-in) and **every silent-corruption
defect is fixed**. No domain has a blocker.

| Domain | Verdict | Gate before its parent closes / MCP retires |
|---|---|---|
| **contacts** | **STRICT_SUPERSET** | none — clear to close now |
| **mail** | **STRICT_SUPERSET** at op+param (55/55) | ratify the plain-reply divergence (decision 5 below) + resolve the OPEN **D8** (which Mail oracle wins a limit disagreement) |
| messages | GAPS_REMAIN (3 LOW) | D10 (length cap, already yours) + the cheap fixes below |
| reminders | GAPS_REMAIN (1 LOW) | **REM-11** below (+ record REM-08) |
| calendar | GAPS_REMAIN (1 LOW + verify) | **CAL-08** below + a safe live read-diff (CAL-07/CAL-10) |
| notes | GAPS_REMAIN (2 MED + 3 doc'd) | **notes-#8** below + the cheap #9 fix; D12 already yours |

### New divergence decisions I need from you (each is CLI-arguably-better or safety-motivated)

1. **REM-11 — reminders stores a URL in the structured `url` field, not appended to the notes
   body.** The oracle appends `\n\nURLs:\n- <url>` to notes; the CLI keeps the URL as a first-class
   field and preserves url-search parity. Read-parity of oracle-authored data is intact.
   **Recommend: RATIFY the CLI behavior** as a documented, strictly-cleaner divergence (or I
   implement the notes-append for byte-parity — a small change).
2. **REM-08 — an unparseable `--due` is REJECTED (exit 64) where the oracle silently clears the
   date.** The clear capability is preserved via explicit `--clear-due`/`--clear-start`.
   **Recommend: RATIFY** as a fail-closed divergence and record it in the port spec.
3. **CAL-08 — `calendar events --account` is validated against event-owning sources only; the
   oracle accepts an event-less source but then data-leaks the full window.** The CLI deliberately
   refuses to replicate the leak (exit 65). **Recommend: KEEP fail-loud**, documented as an
   intentional stricter-than-oracle divergence.
4. **notes-#8 — the oracle retries transient AppleScript failures (−1712 timeout, "not responding",
   "lost connection", "busy", mid-listing mutation) up to 2×; the CLI fails hard on first error
   (clean exit 69, no corruption).** This is a real behavior-granularity gap on a large/syncing
   store. **Choose: PORT the 2× retry/backoff wrapper (a MED behavior change I can do), or BLESS it
   as an accepted robustness divergence.**
5. **mail gap17/extra15 — a *plain-text* reply/forward prepends the quote via `set content`,
   flattening the HTML quote layer the oracle preserves.** The HTML path (`--html`/`--mode
   draft|open`) has full parity via the NSPasteboard flow; this is the ONE sub-path where mail's
   behavior is *worse* than the oracle. **Choose: ACCEPT as a disclosed plain-text-reply divergence,
   or route plain replies through the pasteboard flow too (a MED fix I can do).** Mail is otherwise
   a full op+param strict superset (55/55).

Already-filed Bucket-C decisions that still apply: **D5** (messages fuzzy recall), **D6** (eight
posture calls), **D8** (which Mail oracle wins a limit disagreement — gates mail closure), **D10**
(messages length caps = the term-cap gap), **D12** (notes `save-attachment` path reach).

### Cheap fast-follows — greenlight to execute, or accept as carve-outs (no blocker either way)

- **messages gap6** — negative `--hours -1` (space form) gives a generic parser error where
  `--hours=-1` gives the specific one; mechanical fix via the existing `ArgvPreprocess` seam.
- **messages gap4** — `check_contacts` "first 10" sample uses an alphabetical sort instead of the
  oracle's dict-insertion order (the `count` contract matches). Matching the oracle's insertion-order
  quirk in a diagnostic sample is non-trivial for negligible value — **recommend accept as cosmetic**.
- **notes-#9** — richer entity-specific error-mapping table (oracle's 11 buckets vs the CLI's 5);
  diagnostic-quality only, no wrong output or missing op.
- **mail port-spec notes** — add the op-27/28 divergence notes (live forward_to/delete-action rule
  refusal; `--match any`) and the row-18 `open_in_mail` note to `docs/port-specs/mail.md`. Code is
  oracle-correct; only the notes are missing. (Deferred here rather than guessed, to avoid a doc
  inaccuracy.)
- **calendar doc-comment** — DONE in this commit (the `CalendarCommand.swift` header still carried
  the v1 "dry-run by default" wording Q16 missed).

### Safe live-verification I can run on your TCC-granted machine (read-only, no writes)

- **calendar CAL-07** (empty `--calendar` → default) and **CAL-10** (EventKit-native ordering) —
  code-correct but not yet live-diffed against the oracle.
- **notes** — a live MCP-diff of the three fixed silent-corruption defects (folder / modified-since
  rollover / ordered-list) to convert code-verified → runtime-verified.
- **mail** — spot live `size`/`downloaded` bytes on 2–3 attachment-bearing messages + one HTML reply.

Say the word and I'll run these read-only diffs; they need no decision, only your go to spend the
time against real accounts.

### My recommendation

1. **Close the contacts Asana domain parent now** — it is a verified strict superset with no
   residual. Mail is a full op+param strict superset (55/55) and is close behind, but its parent
   should close only after you ratify decision 5 (the plain-text-reply divergence) and D8 (the
   oracle-limit disagreement). (I did NOT close any parent autonomously: declaring a domain
   shippable is adjacent to the D2 milestone you reserved, and the prior audit said "do not close
   parents until settled." Confirm and I'll close them under the closure protocol.)
2. **Rule on the five new divergences (1–5 above)** — my recommendations are ratify/keep for REM-11,
   REM-08, CAL-08; a genuine port-or-bless choice for notes-#8; and accept-or-fix for mail's
   plain-reply divergence (5). Plus the already-open D8 for mail.
3. **Greenlight (or wave off) the cheap fast-follows** — I can land them behind the usual gates.
4. **Then, and only then, D2** — tag 1.0.0 + retire the MCPs. Still yours alone; the loop stops here.

### RULINGS (Robert, 2026-08-18 — one at a time)

1. **REM-11 → RATIFY** structured `url` field (documented in `docs/port-specs/calendar-reminders.md`).
2. **REM-08 → RATIFY** fail-closed `--due` reject (documented).
3. **CAL-08 → KEEP fail-loud** `--account` reject; do not port the oracle's data-leak (documented).
4. **notes-#8 → PORT** the oracle's 2× transient-retry, scoped to the Notes AppleScript path.
5. **mail plain-reply → FIX** — route plain reply/forward through the pasteboard (preserve the HTML
   quote), removing mail's last behavior-inferior sub-path.
6. **D8 → SAFETY WINS** — add oracle A's 20/60s `expensive_ops` limit to `reply`, cap `draft send`,
   and adopt the scoped rule: on an A-vs-B SAFETY-limit disagreement, the stricter limit wins.

Items 1–3 are doc-only (landed with this ruling). Items 4–6 are code, each landing behind the usual
gates. After they land + the read-only live-verifications pass, contacts/reminders/calendar/notes/
mail are all clear to close, and I bring you D2.

**LANDED (2026-08-19):** items 4–6 are implemented, double-fan-out-reviewed (two full OMC
code/security/critic rounds, both APPROVE; the round-2 hardening added an flock cross-process
lock + corrupt-state degraded signal to the D8 limiters), gate-tested (886 swift-testing +
420 bats, all green), and pushed to `integration`:
- `e67bb8c` fix(messages): space-form negative `--hours`/`--threshold` (gap6 fast-follow)
- `39e6d4a` feat(notes): transient-retry + error-map ported from installed 2.7.5 (item 4 + #9)
- `86728f4` feat(mail): plain-reply via pasteboard + D8 reply/draft-send rate caps (items 5–6)
Remaining before the close recommendations: the read-only live-verifications (next loop step).

**LIVE-VERIFIED (2026-08-19, #39 read-only sweep) — all Bucket-B obligations discharged:**
- **CAL-10 PASS** — calendars byte-identical in EventKit-native order + IDs, CLI vs oracle.
- **CAL-07 PASS** — empty `--calendar` resolves to the DEFAULT calendar on BOTH sides (same 3
  events, same default calendar); create-half verified dry-run (empty echoes through; resolution
  is execute-time, code-audited).
- **notes triple-fix PASS + a NEW defect found and fixed** — checklist note normalized-identical
  (12/12 `- [ ]` byte-match); the 166-item ordered-list note exposed real corruption: Notes.app
  serialized an unterminated `&amp ` which the oracle's DOM decoded and the CLI left verbatim.
  Fixed as NOTES-L1 (`e88cadf`, legacy-entity optional-semicolon decode + nbsp→U+00A0 on the
  markdown path), re-diffed live: both notes normalized-identical. Residual divergence is
  trailing-whitespace cosmetics only (CLI right-trims; turndown preserves) — documented.
- **mail attachments PASS (CLI-superset)** — reported `size` byte-exact vs the saved file
  (37164 == on-disk), `downloaded` verified by a real save; the ORACLE returned an EMPTY
  attachment list for the same message on both its paths (its deficiency, not ours).
- **Process disclosure:** the sweep also caught a stale bats harness expectation left red by the
  decision-5 script deletion — and with it a tests-green breach at the `86728f4` push (the bats
  run before that push was tail-masked). Fixed + disclosed in `11a63df`; suites now counted
  strictly (swift 889/889, bats 420/420).

**Close recommendations (operator's call — nothing auto-closed):** contacts and mail were
already clear; calendar's Bucket-B is now discharged (CAL-08 ratified) → clear; reminders'
ratifications landed → clear; notes' #8/#9 + NOTES-L1 landed and live-verified → clear;
messages' gap6 landed → clear. All six domain parents are now closable on the D13 evidence,
pending your review. D2 (tag 1.0.0 + retire the MCPs) remains yours alone — the loop STOPS here.

---
