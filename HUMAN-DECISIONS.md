# HUMAN-DECISIONS.md — things only the operator can decide

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

**Status values:** `OPEN` (waiting on the operator) · `ANSWERED` (decided, being applied) ·
`APPLIED` (decision is in the code/repo) · `RATIFIED` (decided, no code change needed) ·
`WITHDRAWN` (should not have been asked) · `SUPERSEDED` · `CLOSED` (an incident gate closed on
recorded, scoped evidence).

---

## LEDGER — every decision at a glance (updated 2026-09-07)

**Still needs you: D2.** D9 was reopened 2026-08-31 and finally closed the same day (recorded
CLOSED — see D9). D15 and D16 were ratified 2026-09-07. D3 and D14 were live-validated
operator-present on 2026-08-27 (evidence on their Asana tasks; the Mail parent closed the
same day under the closure-verification protocol). Publication remains blocked — independently
of D9 — until every readiness gate passes and a separate fresh pre-publication privacy audit over
the then-current tree, history, commit messages, objects, refs, and artifacts records zero
findings for its stated scope; the repo stays private until then.

| # | Topic | Status | Ruling |
|---|---|---|---|
| D1 | `notes delete-folder` previews by default | **RATIFIED** | Keep the preview default — `--execute` stays required on the only irreversible-and-unrecoverable write |
| D2 | Cut the first release + retire the six MCP servers | **2 of 3 parts APPLIED 2026-08-30** | **Terminal gate. Yours alone.** Release DONE: `v26.0.0` cut, tagged, GitHub Release published (notes-length recovery was manual; workflow fixed after). Retirement DONE: all six MCPs moved to `retiredServers` in the private fleet-config repo; hosts converge on their next whole-tree apply. REMAINING: fleet deployment of the binary — and the operator ruled 2026-08-30 that this is Homebrew-ONLY (a tap; the previously-scoped install script and self-update subcommand are CANCELLED), and that a RELEASE FREEZE holds until that tap actually serves `brew install apple-cli`: version stays pinned at `v26.0.0`, work lands UNRELEASED under `[Unreleased]`, do not dispatch release.yml or edit the version constant. Completing this part lifts the freeze; an explicit operator release instruction also lifts it for that release. D2 closes then |
| D3 | Live-validate `mail send --gui-send` | **APPLIED 2026-08-27** | Live-validated operator-present: one self-addressed send executed and delivered (oracle-verified both sides), test items cleaned by exact id |
| D4 | Live-validate iMessage group-chat send | **APPLIED 2026-08-23** | Option (b): record "wired + code-inspected, never live-validated" as a port-spec asterisk |
| D5 | Chasing the Messages fuzzy-search recall gap | WITHDRAWN | Should not have been asked; became ordinary queue work |
| D6 | Eight parity posture calls | **APPLIED** | CONTACTS-L4 delete claim · NOTES-M1 restore 4 keys · NOTES-L4 structural divergence · gap10 keep opt-in body · **gap25 wire delete-rules live** · extra20 open by default |
| D7 | Committed phone number in public history | **ANSWERED** | "B then A" — superseded by D9, which covers the same number plus more |
| D8 | Which Mail oracle wins on a safety limit | RESOLVED | **Safety wins** — stricter limit wins on A/B conflicts; landed in `415709c` |
| D9 | Personal data published to a public repo | **CLOSED 2026-08-31** (APPLIED 2026-08-23, amended 2026-08-29, REOPENED 2026-08-31, then finally closed the same day) | Repo private. Prior rewrite passes were verified against the classes then known; a 2026-08-31 round found further history and current-tree defects and the gate was reopened. The approved scoped remediation was completed the same day — history rewrite in a fresh clone, fresh-clone verification, rollback/audit scratch removed and absent-verified — and one complete, independently challenged, value-free audit round returned zero findings for its stated scope (an earlier same-day closure attempt was recorded invalid and reversed first). Rewritten main `c794d7e` is an ancestor of current main; `v26.0.0` peels to `0f617eb`. This closure covers its stated scope only and does NOT authorize publication: the repo stays private until every readiness gate passes and a separate fresh pre-publication privacy audit records zero findings for the then-current tree, history, commit messages, objects, refs, and artifacts |
| D10 | Search/find-contact length caps | WITHDRAWN | Should not have been filed |
| D11 | What `schema_version` tracks | **APPLIED** | **Shape only** — value breaks ride the MAJOR + CHANGELOG; both policy lines rewritten to agree |
| D12 | `notes save-attachment` can write to `~/.ssh` | **RATIFIED** | Keep strict Notes-oracle parity; residual documented, fleet stays intentionally inconsistent |
| D13 | Strict-superset go/no-go package | **APPLIED** | All scoped items landed; D4 keeps its permanent never-live-exercised asterisk; D3 and D14 were live-validated 2026-08-27 |
| D14 | Live-exercise `mail rules` delete | **APPLIED 2026-08-27** | First live exercise done operator-present: labeled disabled test rule deleted by index, readback matched, 3 real rules untouched |
| D15 | Extend the public-attribution exception to `.github/CODEOWNERS` | **RATIFIED 2026-09-07** | The operator's exact GitHub user may appear in `.github/CODEOWNERS` for every enforcement-control-plane path, as deliberate public attribution alongside LICENSE, README, and git author metadata. Sequence is fixed: the `AGENTS.md` exception extension lands first as its own reviewed commit, the CODEOWNERS commit lands second with its own fresh privacy scan, then GitHub's code-owners errors API confirms it parses. Trade-off recorded per the design: from that step until public launch no release can be cut; the release freeze's urgent-fix clause is satisfiable only by a reviewed, operator-authorized, temporary restoration of a write-capable release workflow, recorded as an explicit exception and removed again afterwards |
| D16 | Narrow main-only reversal for disposable rehearsal refs | **RATIFIED 2026-09-07** | Three disposable ref classes, and only these, may be created for the publication-automation rehearsals (design §18 steps 8–14, removal at step 18): the uniquely named disposable target ref, the proposal head refs of the validation PRs (which target that ref, never `main`), and the Dependabot-created head refs of step 13; never for feature work; never merged into `main`; deleted after the rehearsal, including on abort; does not reverse the ruling for ordinary work. The `AGENTS.md` reversal commit lands under the private main-only gate when the rehearsal step begins, after an in-session re-confirmation and before the first branch is cut. The later full reversal that activates the `main` ruleset is a SEPARATE future operator instruction and is not granted here |
| D17 | Early visibility flip to restore hosted Actions; pre-flip privacy audit round 1; disposition of its findings | **ANSWERED 2026-09-20; APPLIED 2026-09-21** (flip 14:31Z; hosted CI and Docs green the same day) | Operator ordered: fresh audit first, flip on zero findings, end-of-roadmap audit still required. Round 1's zero-findings condition was NOT met: seven findings — five operator-dispositioned (D17–D20), the fixture fix pending, and the hosted-log deletion OPEN in D21 — both closed 2026-09-21 (fixture fix landed, D21 applied); D19 later superseded; for the binary the operator chose rebuild + re-cut (as `v27.0.0`) rather than accept, and, because the design forbids a private publisher and hosted runs are billing-blocked, ordered the `v26.0.0` Release converted to a draft first, the flip second, the re-cut after hosted validation |
| D18 | macOS 27 adoption release `v27.0.0` | **OPEN** | Operator instruction 2026-09-20: bump to `27.0.0` once all tests pass on macOS 27. Waits on the D17 flip, hosted validation, the design's publisher path, a §4.1 adoption-matrix amendment, and verified removal of every R1-F1 to R1-F3 carrier from the rebuilt binary and archive |
| D19 | GitHub still serves pre-rewrite commits by id | **SUPERSEDED 2026-09-21** (ANSWERED 2026-09-20) | Verified: seven pre-rewrite commit ids formerly cited in this file return HTTP 200 from the API and still carry pre-redaction tracker identifiers. Operator reversed the 2026-08-23 no-Support posture: request a purge of unreachable objects and cached views from GitHub Support while the repo is still private; the D17 flip waits on that confirmation. Stale id citations in this file were re-pointed to their rewritten counterparts the same day. Superseded 2026-09-21: request withdrawn by the operator, no purge filed; residual by-id reachability accepted; D9's no-Support posture stands |
| D20 | Outside contributor's plaintext git identity on open PRs 3–5 | **RATIFIED 2026-09-20; APPLIED 2026-09-22** (PRs 3–5 squash-merged locally as `7fc4a49`, `6f8b852`, `57984cf`; follow-ups `9a86125`, `8e9be32`) | Accepted as that contributor's own public attribution for now; the PRs were squash-merged with the squash author identity read back first; the reachable `refs/pull/*` copies are outside the D19 purge and remain resolvable after the PRs closed — their retention is GitHub's, not this repository's |
| D21 | Delete 18 hosted workflow runs' logs that echo pre-redaction tracker identifiers | **APPLIED 2026-09-21** | Post-round scan of all 305 run logs: no personal data; 18 runs' logs contain 16-digit tracker identifiers inside historical branch names. Deleting run logs is destructive and outward-facing, so it waited for the operator's instruction; authorized and executed 2026-09-21 (18 log archives deleted, 18 × 204, read back 18 × 404); removed from D17's blocker list |

---

**Amendment 2026-09-20 (D17).** The preamble's and D9's "repo stays private until every readiness gate passes and a fresh pre-publication privacy audit records zero findings" condition was advanced by operator ruling: the operator authorized the visibility change ahead of the remaining readiness gates, on a fresh audit round whose zero-findings condition was NOT met: findings 1–5 received the operator's own dispositions (D17–D20), while the fixture fix (6) and the hosted-log deletion (7, D21 OPEN) remained pre-flip blockers — both completed 2026-09-21. The end-of-roadmap audit and every other readiness gate still stand as written; publication actions beyond visibility remain gated. See D17 and `docs/discovery/prelaunch-readiness-evidence.md`.

---

## D1 — `notes delete-folder` previews by default instead of executing

- **Status:** **RATIFIED 2026-08-19** — keep the preview-by-default deviation (option (a)).
- **Resolution:** The operator ruled to keep `--execute` required. `delete-folder` is the CLI's only irreversible-AND-unrecoverable write (measured: it cascades, and cascaded notes do NOT reach Recently Deleted), so the one-command divergence from the oracle stands as a documented safety posture, same class as the `APPLE_ALLOW_EMPTY_TRASH` precedent. No code change.
- **Filed:** 2026-08-02 (Notes write-model v2 flip, commit `8cc21f3`)
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

- **Status:** 2 of 3 parts APPLIED 2026-08-30 — **the hard stop held: both parts ran on
  explicit, live operator instruction in the 2026-08-30 session.**
- **Progress (2026-08-30):** (1) First release CUT as `v26.0.0` (platform-keyed scheme
  superseded the "1.0.0" name; operator: "let's deploy this as 26.0.0") via release.yml —
  tag + release commit pushed atomically; the Release object needed a manual re-create after
  a notes-length 422, and the workflow was fixed. (2) The six MCPs RETIRED (operator: "you
  can sunset the apple MCPs") — the private fleet-config repo moves them to `retiredServers`;
  hosts converge on their next whole-tree apply. (3) REMAINING: fleet deployment of the
  binary via a Homebrew tap ONLY — operator ruling 2026-08-30: the previously-scoped install
  script and `apple upgrade` self-update are CANCELLED; `brew install` / `brew upgrade` is the
  whole story. The tap requires the repo to be public, so it waits on the publication gates
  below, and a RELEASE FREEZE holds until the tap actually serves `brew install apple-cli`. D2
  and the execution parent close after that lands.
- **Blocked by:** publication readiness, not D9. D9/Q30 was closed 2026-08-29 for the classes
  then known, reopened 2026-08-31, and finally closed the same day (see D9). Publication — and
  therefore the Homebrew tap that completes this entry — remains blocked until every readiness
  gate passes and a separate fresh pre-publication privacy audit records zero findings for its
  stated scope. This entry's own operator-present hard stop also remains.
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

**Amended 2026-09-20 (D17 ruling 2):** the release freeze is lifted for exactly one release, `v27.0.0`, when it is cut under D18's preconditions; all other freeze terms stand, and D2's remaining Homebrew part is unchanged.

---

## D3 — Operator-present live validation: `mail send --gui-send`

- **Status:** **APPLIED 2026-08-27** — live-validated operator-present.
- **Resolution:** After a first failed attempt (2026-08-26, exit 70) and a second failed
  attempt (2026-08-27, exit 69 upstream_error, body paste never occurred), the automation
  fix landed (`5ebbf39`, bounded nonce-window poll) and a no-send diagnostic passed the full
  flow. The operator authorized attempt 3, watched the compose auto-send, and delivery was
  oracle-verified on both the sent and inbox sides (one self-addressed message, sandbox
  engaged). Test items were cleaned by exact id. Evidence: Asana `GID-REDACTED`.
  The original request below is retained verbatim for append-only provenance; it is not a live
  instruction or authorization, and D3 is closed.
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

- **Status:** **APPLIED 2026-08-23** — option (b), record the validation-evidence asterisk.
- **Resolution:** The operator chose option (b): accept the group-send surface as "wired +
  code-inspected, never live-validated." No operator action remains for D4. The Messages port spec
  now records that `--group` accepts the oracle group-chat identifier and dispatches by chat id,
  but that no live group was created or messaged and no live group send is authorized. This limits
  validation evidence; it does not mark the capability missing. The original request below is
  retained verbatim for append-only provenance; it is not a live instruction or authorization,
  and D4 is closed.
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
(re-measured live 2026-08-02: the fixed probe-term search over `--hours 72` → oracle **14**, CLI **1**, i.e. 7% recall,
not the 16→2 I cited), and `docs/port-specs/messages.md` §8 still understates it as affecting only
"low-relevance matches at the threshold floor" citing 25→21 — Q5 must fix that text too.

<details><summary>Original entry, preserved (append-only)</summary>

- **Category:** scope call

**The finding.** Our `WRatio` port's `partialRatio` slides a fixed `len(shorter)` window;
rapidfuzz maximizes over variable-length substring alignments. Measured at the default 0.6
threshold: the fixed probe-term search over `--hours 72` → oracle 16 hits, CLI 2. Aggregate over 10 terms × 1500 real
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
- **Filed:** 2026-08-02, from the HEAD reconciliation (live-audit dump, since purged)
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

**What I found.** A real phone number is committed in a tracked port spec and a tracked test
file. It predates the completion loop — I did not
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

**Status:** RESOLVED 2026-08-18 — **SAFETY WINS.** The operator's ruling: add oracle A's `expensive_ops`
(20/60s) rate limit to `reply`, cap `draft send` (recipient cap + send-budget consumption), and
adopt the **scoped standing rule**: *on an A-vs-B disagreement about a SAFETY limit (send rate,
recipient caps, bulk caps on destructive ops), the stricter limit wins.* This knowingly makes the
CLI stricter than oracle B on those paths — accepted as a deliberate safety posture for an
agent-driven tool where a runaway mass-send is irreversible. **LANDED 2026-08-19** in `415709c`
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

**Current status:** **CLOSED 2026-08-31** — reopened earlier that day (amendment below), then
finally closed on scoped remediation, fresh value-free verification, independent review, and
cleanup (final-closure amendment below). Publication remains blocked by a separate gate: the repo
stays private until every readiness gate passes and a fresh pre-publication privacy audit records
zero findings for its stated scope. ·
**Historical status (2026-08-23):** **APPLIED — "B then A", including rewritten `main`.** ·
**Filed:** 2026-08-03 · **Step B was DONE:** the repo was made **private** on 2026-08-19
(containment). **Step A was DONE for the classes then known:** the verified rewrite was published
to `main`; the superseded branches were deleted locally and remotely. A same-day value-free
rescan found further live leaks the earlier pass had missed — one earlier "redaction" had been
partial rather than complete, so the literal was still effectively real in a number of places;
those findings were fixed, and a standing no-personal-data rule was added to `AGENTS.md`. ·
**Severity:** the highest-severity entry in this file. I caused both leaks.

**Amendment (2026-08-29):** the pre-1.0 PII gate (Asana `GID-REDACTED`) surfaced residuals the
2026-08-23 rewrite had missed — some in tracked content, some history-only, and one in a
published commit message. This entry does not re-enumerate their classes or locations, per the
note below. The
operator explicitly authorized targeted remediation ("option 2; don't defer any
PII cleanup"), amending the earlier no-further-rewrite posture for that session only. Targeted
`git filter-repo` passes ran in fresh clones; each verified all
commits preserved, HEAD tree byte-identical to the suite-tested tree, zero residual hits; `main`
was force-pushed after each pass. Local repo reset, codex checkpoint refs deleted, reflogs
expired, pruned; the fresh backup bundle, clones, and replacement maps were destroyed after
verification, and the gitignored D9 handoff file was removed last. Final scan across every
reachable blob and commit message: 0 hits **for the literal classes those passes remediated** —
which is a narrower claim than it first read as, and the distinction turned out to matter.

**Amendment (2026-08-31) — the gate was REOPENED, and the closure claim above was wrong.**
Further audit rounds after it was written found more real personal data, so treat any unqualified
"zero hits" in this entry as scoped to the classes known at the time. One round found
ancestor-only residuals, including hybrid clauses left behind by earlier exact-match rules. A
later round found a value that existed only in a commit message, with no copy in any blob, plus a
tracked current-tree value. An earlier rewrite did cover commit messages, but its exact-match
rules did not include the newly discovered value classes; the defect was incomplete rule coverage,
not an all-blob-only rewrite history.

The durable correction is about the SHAPE of the claim, not the count: "zero hits" is only ever
true relative to the patterns you searched for, and a closure statement that omits that scope
reads as a guarantee to the next auditor and invites them to skip. State the scope or state
nothing. The gate was REOPENED 2026-08-31. Current-tree remediation remains under audit; the gate
remains open pending completion and recheck of those corrections, the approved history remediation,
fresh-clone verification, and one fresh, complete, value-free audit round. That round must cover
the corrected current tree and remediated history; document searched classes, engines,
commit-message coverage, object/ref/artifact surfaces, and independent cross-checks; and record
zero findings for its stated scope. Publication remains blocked until that evidence exists.
[Superseded by the 2026-08-31 final-closure amendment immediately below.]

**Amendment (2026-08-31, final closure) — the gate was closed the same day it was reopened**
(dates per the tracker's UTC timestamps: reopened 04:18, finally closed 19:12).
After the reopening above, the remaining historical private-locator content within the
already-authorized rule family was remediated in a fresh clone and the rewritten history was
force-pushed to `origin` under the existing authorization (a rewrite never reaches existing
clones, forks, or caches), the primary local-history cleanup completed, and retained
rewrite/rollback/audit scratch was removed and absent-verified. An earlier same-day
closure attempt was recorded INVALID and reversed: a verification pass had exceeded its read-only
assignment and closed the gate while that round was not yet clean. The final closure superseded
it after one complete, independently challenged, value-free audit round — covering the current
tree, all reachable historical blobs, commit messages, refs, tag payloads, local artifact
surfaces, and fresh-clone verification — returned zero findings for its stated scope, with
independent code, security, critic, and adversarial-verifier review recording no material
findings. Evidence: rewritten main `c794d7e` is an ancestor of `origin/main` and of the local
main; `v26.0.0` remains annotated and peels to `0f617eb`; the full canonical suite passed on the
rewritten SHA (982 Swift
tests / 162 suites; Bats 445/445). The scope rule above stands unchanged: this closure proves
zero findings for the classes and surfaces it searched, not the absence of unsearched classes —
which is exactly why a separate fresh pre-publication privacy audit over the then-current tree,
history, commit messages, objects, refs, and artifacts remains a mandatory launch gate, and the
repo stays private until it and every readiness gate pass.

### What is exposed

Two incidents put personal data — the operator's and third parties' — into tracked files and
into a commit message. Both were remediated at HEAD and, under separate operator authorization,
in history. Later audit rounds found further residuals beyond those two incidents (see the
2026-08-31 amendment above); the broader current-tree remediation remains under audit, while the
authorized history remediation and verification remain open. [Superseded by the 2026-08-31
final-closure amendment above: those within the already-authorized rule family were remediated
and verified for that closure's stated scope; the separate fresh pre-publication audit remains the
pending gate for everything outside it.]

**This entry no longer re-enumerates the full inventory of what was exposed, where, and in
which artifacts.** Assembling classes and artifacts into one list turns this record into a
search plan for anyone holding a clone taken from before the rewrites — and a rewrite reaches
neither clones nor forks, which is precisely that population. So the consolidated list is not
reproduced here.

**What that claim does NOT mean, because a label that overstates its protection is exactly
lesson 1 below.** This is a reduction, not a guarantee. Class-level detail still exists
elsewhere in this repo, deliberately: D7 is an open record of a phone-number leak, and the
fixture docstrings in `PartialRatioParityTests.swift` and `MailDecodeTests.swift` state plainly
what the original rows were. Those docstrings are a control, not an oversight — they exist to
stop a future maintainer regenerating those fixtures from live data, which is the mistake that
caused this entry. Removing their specificity would trade a real engineering safeguard for
cosmetic tidiness. Read the withholding above as "this entry declines to assemble the map",
never as "the map cannot be assembled".

The lessons below are the durable part and cost nothing to publish:

1. **A "synthetic" label on real data is worse than no label.** One leak sat under a comment
   asserting it was invented. The label is what the next audit trusts and skips, so a false one
   converts a finding into a permanent blind spot.
2. **A partial redaction is not a redaction.** One value had been "redacted" by an incomplete
   transform, leaving it effectively real while *looking* handled — the same blind-spot shape as
   the false label.
3. **A file-path history rewrite does NOT touch commit messages.** An operator who ran the
   obvious fix would verify a clean file and still be publishing the value, because messages
   render on the commit page and live in every clone. Rewrites must cover messages explicitly.
4. **Ignore artifacts by CLASS, not by known filename.** One dump was committed precisely
   because its name matched none of the enumerated patterns.
5. **Live oracle output is the vector.** Parity work requires running against real accounts, and
   that output is dense with personal data; it belongs in session scratch and nowhere else.

### What this commit fixes (all at HEAD only)

Every fixture implicated was regenerated as wholly synthetic and re-verified against the oracle at
identical value; live-audit artifacts were untracked; `.gitignore` switched from enumerating known
filenames to matching by class; every real literal was replaced with a reserved-range or otherwise
standard placeholder in every spelling; and the false "synthetic" label that had hidden one of
them was corrected. Per the note above, the specific artifacts and value classes are not
enumerated here.

**Historical status note (superseded 2026-08-23):** Everything from the heading below through the
"What I need from you" paragraph describes the pre-resolution state. `main` was redacted and
republished; nothing in that block remains live or grants authorization for another rewrite.

### What only you can decide

Everything above is HEAD. **Both leaks remain in the pushed history**, and removing them means
rewriting published history and force-pushing — destructive and outward-facing, so I stop here.

**Step zero, and it expires.** Before choosing, capture the repository's traffic and forks
pages. The host retains that data on a short rolling clock, so the evidence that decides whether
this needs escalation is being deleted while this entry sits open. If a fork exists, note that
going private **detaches** forks rather than deleting them.

**Verified blast radius** (I checked rather than assumed, because my first draft of this entry
overstated it): both leak commits were confined to a single branch that nothing else tracked —
not `main`, and none of the domain worktrees. Rewriting is a small operation, not a
multi-worktree hazard.

| Option | What it costs | What it actually achieves |
|---|---|---|
| **A. Rewrite history** (`filter-repo`, force-push) | SHAs from the earliest bad commit forward change; a few doc references go stale | Removes both leaks from this repo. Must ALSO rewrite commit messages, or the leak survives there — lesson 3 above. Old commits stay viewable at their URL until the host purges cached views, which is a request rather than something automatic |
| **B. Make the repo private first, rewrite at leisure** | Loses public visibility while private | Closes the window now and makes A unhurried. Does **not** reach an existing fork |
| **C. Accept it** | Nothing | Not defensible — the second leak carries third-party data, which is not the operator's alone to accept |

**My recommendation: B, then A.** Going private is instant and reversible; the rewrite is then
scheduled rather than an emergency. I would not have said this before checking the blast radius —
A alone is genuinely small here — but the second leak is severe enough that stopping the exposure beats
sequencing elegance.

**One thing I got wrong and should own:** my first draft of this entry said "HEAD is already
scrubbed" while the scrub was still uncommitted, and gave the push date as 2026-08-02. Both were
wrong in the direction of making this look more handled than it was. Corrected above.

**A note on this entry's own risk (historical):** as first written it named SHAs and paths, in a
tracked file, on the public repo, while the rewrite was pending — which signposted the data
(those coordinates were condensed out on 2026-08-30). I judged actionability worth more
than obscurity, since the leak commit was one `git log` from the branch tip either way. Say the word and
I will land a redacted version and keep the detail out-of-band.

**Related:** **D7** is the same phone number. I mischaracterised it above as "the same history
problem" — it was not; it was live at HEAD in several places (and still was on `main`, which that
worktree could not reach). D7's own recommendation was "B now" — redact at HEAD — and that had never
been done, in the very file I was editing. This commit did it for `integration`;
**`main` still carried it at the time of writing** — redacted there on 2026-08-23, and
re-synthesized to a reserved-range literal in the 2026-08-30 passes (see Resolution below).

**What I need from you:** "B then A", "A now", or "leave it" — and separately, whether to redact
`main`. I will not rewrite or force-push anything until you answer.

**Resolution (2026-08-23):** The operator chose B then A and separately approved the `main`
redaction. The rewrite was re-verified, published, and consolidated; only `main` remains locally
and remotely, and no further rewrite or force-push is authorized. The operator declined a GitHub
Support/cache-purge escalation; do not contact Support. The pre-rewrite rollback bundle and
PII-bearing D9 scratchpad are temporarily retained, then must be re-audited and removed under
Asana `GID-REDACTED` before D2. The historical investigation and option analysis above are
preserved as the audit record but are superseded by this resolution. A history rewrite is
containment, not erasure: it cannot reach existing clones, forks, or caches.
Pre-rewrite commit references in the preserved narrative were condensed to generic
descriptions on 2026-08-30; the underlying commits are unreachable from current `main`.
(2026-08-29: this paragraph's no-further-rewrite posture and retained-artifact description are
superseded by the dated Amendment below — Q30 completed, artifacts removed, and the no-rewrite
default was restored after three further operator-authorized targeted passes.)

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
is worth keeping. D7, D8 and D9 were genuinely open when this paragraph was written; D8 was later
resolved, and D9 was historically applied on 2026-08-23 for the classes then known. D9 was
REOPENED 2026-08-31 and remains open pending the approved remediation and scoped verification.
[Superseded: D9 was finally closed 2026-08-31 after scoped remediation and verification; the repo
stays private pending readiness and a separate fresh pre-publication audit.]

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
| `messages find-contact` | 500,000 conjoining-jamo code points vs **200** candidates | **9.95s** — and a real address book is thousands of candidates |

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
- **Resolution:** The operator ruled to keep `notes save-attachment` matching its oracle verbatim, so it can still target `~/.ssh` and friends; the fleet stays intentionally inconsistent (Mail and Contacts block credential dirs because THEIR oracles do). The residual stays documented in `PathConfinement.swift` + the Q13 CHANGELOG entry. No code change.
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
- **Evidence amendment (2026-08-23):** The status sentence above is superseded as to live evidence
  and remaining tasks. D4 is closed with a permanent never-live-exercised asterisk; D3 and D14
  remain open operator-present tasks; D2 remains the operator-only terminal gate.
- **Evidence amendment (2026-08-27):** The 2026-08-23 amendment above is superseded as to D3 and
  D14: both were live-validated operator-present on 2026-08-27 (Asana `GID-REDACTED` and
  `GID-REDACTED`); the 2026-08-19 parenthetical at the end of the "Items 1–3 are doc-only"
  paragraph below is likewise superseded — the D14 asterisk is discharged. D4's permanent
  never-live-exercised asterisk and D2's operator-only terminal gate are unchanged.
- **Filed:** 2026-08-18, after the Q17 re-audit (a gitignored local artifact; the tracked summary is the Q17 row in `docs/COMPLETION-LOOP.md`).
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

### RULINGS (operator, 2026-08-18 — one at a time)

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
mail are all clear to close, and I bring you D2. (Amended 2026-08-19: mail's close now carries the D14 asterisk — its delete action is wired but never live-exercised.)

**LANDED (2026-08-19):** items 4–6 are implemented, double-fan-out-reviewed (two full OMC
code/security/critic rounds, both APPROVE; the round-2 hardening added an flock cross-process
lock + corrupt-state degraded signal to the D8 limiters), gate-tested (886 swift-testing +
420 bats, all green), and pushed to `integration`:
- `f4d5814` fix(messages): space-form negative `--hours`/`--threshold` (gap6 fast-follow)
- `708a1c0` feat(notes): transient-retry + error-map ported from installed 2.7.5 (item 4 + #9)
- `415709c` feat(mail): plain-reply via pasteboard + D8 reply/draft-send rate caps (items 5–6)
Remaining before the close recommendations: the read-only live-verifications (next loop step).

**LIVE-VERIFIED (2026-08-19, #39 read-only sweep) — all Bucket-B obligations discharged:**
- **CAL-10 PASS** — calendars byte-identical in EventKit-native order + IDs, CLI vs oracle.
- **CAL-07 PASS** — empty `--calendar` resolves to the DEFAULT calendar on BOTH sides (same 3
  events, same default calendar); create-half verified dry-run (empty echoes through; resolution
  is execute-time, code-audited).
- **notes triple-fix PASS + a NEW defect found and fixed** — checklist note normalized-identical
  (12/12 `- [ ]` byte-match); the 166-item ordered-list note exposed real corruption: Notes.app
  serialized an unterminated `&amp ` which the oracle's DOM decoded and the CLI left verbatim.
  Fixed as NOTES-L1 (`50c30f0`, legacy-entity optional-semicolon decode + nbsp→U+00A0 on the
  markdown path), re-diffed live: both notes normalized-identical. Residual divergence is
  trailing-whitespace cosmetics only (CLI right-trims; turndown preserves) — documented.
- **mail attachments PASS (CLI-superset)** — reported `size` byte-exact vs the saved file
  (37164 == on-disk), `downloaded` verified by a real save; the ORACLE returned an EMPTY
  attachment list for the same message on both its paths (its deficiency, not ours).
- **Process disclosure:** the sweep also caught a stale bats harness expectation left red by the
  decision-5 script deletion — and with it a tests-green breach at the `415709c` push (the bats
  run before that push was tail-masked). Fixed + disclosed in `252498c`; suites now counted
  strictly (swift 889/889, bats 420/420).

**Close recommendations (operator's call — nothing auto-closed):** contacts and mail were
already clear; calendar's Bucket-B is now discharged (CAL-08 ratified) → clear; reminders'
ratifications landed → clear; notes' #8/#9 + NOTES-L1 landed and live-verified → clear;
messages' gap6 landed → clear. All six domain parents are now closable on the D13 evidence,
pending your review. D2 (tag 1.0.0 + retire the MCPs) remains yours alone — the loop STOPS here.

**D4 EVIDENCE AMENDMENT (2026-08-23):** "Messages is clear" means capability-complete with the
D4 validation-evidence asterisk: group send is wired and code-inspected but was never exercised
against a live group. No live group was created or messaged, and no live group send is authorized.

---

## D14 — Operator-present first exercise of `mail rules` delete

- **Status:** **APPLIED 2026-08-27** — first live exercise done operator-present.
- **Resolution:** The agent prepared a DISABLED, uniquely-tokened `apple-cli-test` rule
  (created at index 4; the 3 pre-existing real rules untouched) plus one inert labeled
  draft, verified targeting with a delete dry-run, and stopped. The operator, present and
  watching, explicitly directed the execution of `mail rules delete 4` in real time
  (amending the who-presses-the-key step while retaining supervision and per-command
  consent). The envelope's fail-loud readback matched the test rule verbatim; the post-
  delete list showed exactly the 3 original real rules. All created test items were cleaned
  by exact identifier via the MCP oracle. Evidence: Asana `GID-REDACTED`. The in-session
  amendment was specific to that one supervised command and is NOT a standing authorization for
  agent-executed destructive Mail operations — AGENTS.md's DANGEROUS ACTIONS list still governs.
  The original text below is retained verbatim for append-only provenance; it is not a live
  instruction or authorization, and D14 is closed.
- **Filed:** 2026-08-19
- **Category:** operator-present verification

The rule-delete surface is wired, reviewed, and hardened, but has never been exercised against
real Mail. Prepare only newly created, clearly labeled `apple-cli-test` mail plus a narrowly scoped
test rule, and log every created ID to `TEST-CLEANUP.md`. The agent must stop before activating or
exercising the delete action; the operator performs that step. Afterwards, verify the outcome and
clean up only the precisely logged test IDs through the known-good MCP oracle.

Never target existing real mail, use bulk or fuzzy deletion, empty trash, or perform permanent
deletion. D14 evidence is required before the Mail parent and Q30 can close. (Both closed:
Mail parent 2026-08-27, Q30 2026-08-29.)

---

## D15 — Extend the public-attribution exception to `.github/CODEOWNERS`

- **Status:** **RATIFIED 2026-09-07** — the operator authorized the extension in-session.
- **Resolution:** The operator's exact GitHub user may appear in `.github/CODEOWNERS`, naming
  the operator for every enforcement-control-plane path of the publication-automation design,
  as deliberate public attribution alongside LICENSE, README, git author metadata, and
  authorship prose. The marginal disclosure is nil (the handle is already public in those
  places), but the no-personal-data rule is bright-line, so the exception is recorded here
  before the identifier lands anywhere new. Sequence is fixed: (1) a distinct reviewed commit
  extends the exception in `AGENTS.md` first; (2) the CODEOWNERS commit lands second with its
  own fresh privacy scan; (3) GitHub's code-owners errors API confirms the file parses. Until
  that `AGENTS.md` commit lands, `AGENTS.md`'s bright-line text governs and the handle goes
  nowhere new.
- **Filed:** 2026-09-07 (raised by the design's step 5, which says an agent cannot make the
  design compliant by a policy PR alone)
- **Category:** public attribution / control-plane governance

**Why it needed you.** CODEOWNERS is how control-plane changes (workflows, actions, the PR
template, dependabot, the Actions allowlist, the coverage policy, and the manifests) merge only
on your code-owner approval or your sole bypass. GitHub CODEOWNERS requires a user or team, so
the design cannot work without an identifier in a tracked file, and only you can ratify that.

**Trade-off recorded, per the design:** from this step until public launch **no release can be
cut** — the legacy publisher is already removed — so the release freeze's urgent-fix clause is
satisfiable only by a reviewed, operator-authorized, TEMPORARY restoration of a write-capable
release workflow, recorded as an explicit exception and removed again afterwards. Control-plane
changes likewise merge only on your code-owner approval or sole bypass.

**Blocking?** It unblocks the governance step. Nothing else waits on it.

---

## D16 — Narrow main-only reversal for disposable rehearsal refs

- **Status:** **RATIFIED 2026-09-07** — narrow reversal authorized; the `AGENTS.md` commit
  that records it lands when the rehearsal step begins.
- **Resolution:** Three classes of DISPOSABLE ref, and only these, may be created for the
  publication-automation rehearsals (design §18 steps 8–14; removal at step 18): (1) the
  uniquely named disposable target ref; (2) the proposal head refs the validation pull requests
  need — every such PR targets the disposable ref, never `main`; (3) the Dependabot-created head
  refs of the design's step 13. Scope limits: never for feature work; never merged into `main`;
  never `main` itself; deleted after the rehearsal, including when a rehearsal aborts. This does
  not reverse the ruling for ordinary work. The
  `AGENTS.md` reversal commit lands under the private main-only gate when the rehearsal step
  actually begins, after an in-session re-confirmation and before the first branch is cut,
  because a policy pull request cannot carry the reversal (it would need the head branch the
  ruling forbids). Until that commit lands, the standing main-only ruling of 2026-08-23 governs
  in full.
- **Explicitly NOT granted here:** the later full reversal that activates the `main` ruleset
  and native-squashes one real policy pull request. That is a separate, operator-gated,
  in-session instruction at that step; nothing in this entry pre-authorizes it.
- **Filed:** 2026-09-07 (raised by the design's rehearsal steps, which require a disposable
  branch the main-only ruling forbids)
- **Category:** branch topology / rehearsal authorization

**Why it needed you.** The main-only ruling is yours and repo-local; only you can carve out
an exception, and the design insists the carve-out be narrow and explicitly recorded before any
branch exists.

**Blocking?** It unblocks the rehearsal steps when they are reached. Nothing else waits on it.

---

## D17 — Flip to public early to restore hosted Actions; pre-flip privacy audit; its findings

- **Status:** **ANSWERED 2026-09-20; APPLIED 2026-09-21** — three in-session operator rulings,
  recorded here in order; the visibility change landed 2026-09-21 14:31Z (see "Applied" below).
- **Context.** Hosted GitHub Actions stopped allocating runners for this private repository:
  every job of the last five `CI` and `Docs` runs finished in under fifteen seconds with zero
  steps and the annotation "not started because recent account payments have failed or your
  spending limit needs to be increased". Public repositories get hosted runners without that
  allotment, and the publication design already sequences hosted validation AFTER visibility
  (design §18 phase 2–3, amended 2026-09-10). The operator directed: flip the repository to
  public now so Actions and checks go green again.
- **Ruling 1 (audit first).** Before any flip, run a fresh independent privacy audit over the
  tree, history, commit messages, objects, refs, GitHub-side text and release artifacts, with
  two regex engines plus an independent cross-check, and flip only on zero findings for that
  scope. The operator added, explicitly, that this pre-flip round does NOT replace the
  end-of-roadmap pre-publication audit the repository rules require; that later round still
  runs after the remaining readiness items complete. Round 1 is recorded, value-free, in
  `docs/discovery/prelaunch-readiness-evidence.md`.
- **Round 1 result.** Seven findings: the primary pass found R1-F1; the independent challenge added R1-F2 to R1-F6 (two further release-packaging carriers of the same account token, an outside contributor's plaintext identity on pull refs, host-side reachability of pre-rewrite objects, and a fixture pairing a fictional street with a real locality); the post-round scan of all 305 hosted run logs added R1-F7 (tracker identifiers inside historical branch names in 18 runs' logs; no personal data). Dispositions: D17 ruling 2 / D18 (F1–F3), D20 (F4), D19 (F5), fix pending before the flip (F6), D21 (F7). Both closed 2026-09-21. R1-F1: the `v26.0.0` release asset's binary embeds 270
  build-time source and build-directory paths whose user segment is the operator's macOS
  account short name (the same string as the public GitHub handle covered by the attribution
  exception; no third party). Every other raw hit of the primary pass resolved to a reserved
  placeholder, a synthetic fixture, an integer constant, a GitHub object id, a redaction marker,
  or the recorded attribution exception. The independent challenge is recorded in the evidence
  file. **Ruling 1's zero-findings condition was therefore NOT met.** Seven findings were returned; the
  operator dispositioned R1-F1 to R1-F5 (D17–D20) and named the R1-F6 fixture fix and the R1-F7
  log deletion (D21, OPEN — not yet authorized) as pre-flip blockers, advancing the flip on that
  basis. Both closed 2026-09-21 (fixture fix landed; D21 applied). The round does not satisfy the design's §18 phase 1
  zero-findings gate; the end-of-roadmap audit must, for its own scope.
- **Ruling 2 (disposition of R1-F1).** Offered: (A) accept under the attribution exception;
  (B) rebuild with compiler path remapping and re-cut the release; (C) accept now, fix forward.
  **Operator chose B.** In the same turn the operator added that the re-cut release is to be
  `v27.0.0`, because the host platform is now macOS 27 (see D18). B therefore lifts the release
  freeze for exactly that one release, when it is cut; nothing else in the freeze changes.
- **Ruling 3 (order).** B before the flip would contradict the locked design in two ways: no
  write-capable publisher may exist while the repository is private (§3, §18 step 5), and the
  hosted runs a release needs are exactly what is billing-blocked until the flip. Offered:
  (A) convert the `v26.0.0` GitHub Release to a draft (collaborators-only, reversible, tag and
  assets retained), flip, run hosted validation, then cut `v27.0.0` with path remapping through
  the design's publisher path; (B) fix billing, restore a temporary private publisher, re-cut,
  then flip; (C) delete the asset, flip, then re-cut. **Operator chose A.** The Release was
  converted to a draft on 2026-09-20 immediately after that ruling; the `v26.0.0` tag, its clean
  commit, and both assets (now collaborator-visible only) are unchanged. This is the explicit
  instruction the design requires before an agent edits a published Release. **Consequence,
  accepted:** from the drafting until the version-publication path of design §18 phase 3 lands
  and `v27.0.0` is cut, the project has no downloadable release, and D2's Homebrew part cannot
  progress in that window.
- **Residual risk of advancing ahead of design steps 4 and 17, and the rollback plan.**
  Repository-level read-backs on 2026-09-20: default workflow token permission is read and
  workflow approval of pull-request reviews is off; the external-Action allowlist is NOT yet
  configured (all actions allowed) and the step-17 static scan has not run; fork-PR contributor
  approval cannot be read while private and is read back immediately after the flip, before any
  outside pull request may run. The allowlist is set before the flip (configured and read back 2026-09-21: `selected`, GitHub-owned
  actions plus one third-party pattern with a wildcard ref — the SHA pins live in the workflow files
  and `sha_pinning_required` is false; the unused wiki flag was disabled the same day). Rollback: if a finding
  surfaces after the flip, re-flip to private at once (mechanically reversible; clones, caches
  and indexes are not), redact at HEAD, record the incident here, and re-run the audit round.
- **Amendments landed with this entry (D15 precedent, adapted).** The design's Status header,
  §3, §18 and §21 carry dated amendments recording the advanced visibility step, `AGENTS.md`'s
  privacy paragraph gains the same clause (and its "remains private" lead sentence is dated),
  this ledger's preamble is amended, and D2 records the one-release freeze lift. D15 required
  the policy commit to land first because its second commit would itself have published an
  identifier; here the amendments and the record land in one reviewed commit and the act they
  authorize (the flip) is a separate later operation with its own blocking list, so no hazard
  window exists between them.
- **What this advances, stated plainly.** The design's §18 phase 1 says the visibility step
  follows completion of its pre-visibility items. The operator advanced the visibility step
  ahead of the items not yet evidenced in the readiness file, on the audit condition above. The
  evidence file lists each pre-visibility item as evidenced or PENDING; nothing is relabelled.
  Public visibility grants no publisher, deployment, release, Pages, Homebrew, or bypass
  authority (design §3); those remain separately gated.
- **Filed:** 2026-09-20 · **Category:** publication / privacy / outward-facing action

**Why it needed you.** Visibility is an outward-facing, effectively irreversible publication
event; editing a published Release is on the design's forbidden list absent your instruction;
and the finding's disposition is a posture call between an already-public string and a re-cut
release.

**Blocking?** The flip waits on exactly: the written GitHub Support purge confirmation of D19 (request prepared; operator filing PENDING; confirmation PENDING); the R1-F6 fixture fix; the R1-F7 log deletion authorized and executed (D21, OPEN); the repository-level external-Action allowlist configured; the pre-push re-scan of every commit added after `053b56e`; and the local canonical suite green on the exact pushed commit. (as recorded 2026-09-20)
**Amended 2026-09-21:** the flip waits on exactly: the pre-push re-scan of the commit that records this revision and the local canonical suite green on that exact pushed commit (the D19 Support gate was withdrawn by the operator on 2026-09-21; the R1-F6 fixture fix, the R1-F7 log deletion under D21 and the repository-level external-Action allowlist were completed the same day).
`v27.0.0` waits on D18.

**Applied (2026-09-21).** The blocker list closed the same day: the R1-F6 fixture fix landed in
the visibility-step commit, the R1-F7 hosted-log deletion was executed and read back under D21,
the repository-level external-Action allowlist was configured, and the operator withdrew the D19
Support gate. The controller changed the visibility at 14:31Z through the API and read back
public visibility, wiki disabled, zero forks, the `v26.0.0` Release still a draft, and fork-PR
contributor approval set to all external contributors. The first hosted runs exposed five
hosted-only defects that local runs never exercise (recorded in
`docs/learnings/hot/hosted-ci.md`); after two reviewed fix commits, CI and Docs were green on
`main` the same day, which satisfies design §18 step 6 for the push-triggered jobs. Evidence:
`docs/discovery/prelaunch-readiness-evidence.md` Sections 3 and 4. No other publication action is
unlocked by this: D18 (`v27.0.0`) and the end-of-roadmap audit remain open.

---

## D18 — macOS 27 adoption release: bump to `v27.0.0` once all tests pass

- **Status:** **OPEN** — instruction received 2026-09-20; execution gated as below.
- **Instruction.** "We also need to version bump to 27.0.0 because we are on macOS 27. If all of
  our tests pass we should bump to v27." The host now reports macOS 27.0. Under the
  platform-keyed scheme (AGENTS.md "Versioning + releases"), MAJOR names the newest macOS the
  release is built and validated against, so a macOS 27 adoption release is `27.0.0`; the
  deployment minimum in `Package.swift` does not move.
- **What has to be true first, in order.** (1) The D17 visibility flip and at least one green
  hosted run. (2) The full local canonical suite green on macOS 27 for the exact commit to be
  released — this is the operator's stated condition — plus the hosted logic-tier gate. (3) The
  design's §4.1 platform-support text ("macOS 26 is the current tested and supported baseline;
  a newer major joins only after its adoption matrix passes") amended by a reviewed commit that
  records the macOS 27 adoption matrix and result, with `[Unreleased]` notes stating the new
  baseline and the unchanged macOS 14 technical floor. (4) The release build and packaging remove every R1-F1 to R1-F3 carrier, stated as a
  **verified outcome, not a flag list**: the shipped binary contains no `N_OSO` debug-map entry
  (`nm -ap` shows none) and no home-directory path anywhere in its bytes; the archive's member
  headers show uid 0, gid 0 and empty owner/group names, and no AppleDouble member. Means that
  are known to work on this toolchain: suppress the debug map (`-Xswiftc -gnone`) or remap the
  object paths at link time (`-Xlinker -oso_prefix`) or `strip -S` the artifact — compiler
  `-file-prefix-map`/`-debug-prefix-map` alone do NOT remove the debug-map entries (verified
  empirically by the security reviewer) and are kept only for the DWARF side; package with
  `COPYFILE_DISABLE=1 tar --uid 0 --gid 0 --uname '' --gname ''` (GNU tar equivalents if the
  packaging host changes). The check is recorded in the evidence file before publication.
  (4a) A published-release path exists (design §18 phase 3 publisher) and the §18/§3 amendments
  of D17 are in place. (5) The release itself goes
  through the design's separately authorized version-publication path (bot publisher,
  operator-reviewed environment); no hand edit of `AppleVersion.current`, no local manual
  release. The freeze lifts for this one release only, per D17 ruling 2.
- **Not decided here:** whether hosted macOS 27 runners exist yet for the adoption matrix, and
  whether `v26.0.0` stays a draft or is deleted once `v27.0.0` ships. Both are raised when
  reached.
- **Filed:** 2026-09-20 · **Category:** release / platform adoption

**Why it needed you.** A version bump is a release, and releases are yours to call.

**Blocking?** D2's remaining Homebrew part waits on it (no downloadable release exists until it ships); nothing else in the current roadmap does.

---

## D19 — GitHub still serves pre-rewrite commits by id; purge before the flip

- **Status:** **SUPERSEDED 2026-09-21** — operator withdrew the Support request: no purge is
  filed, and residual by-id reachability of orphaned pre-rewrite objects is accepted provided
  every published surface is clean or operator-dispositioned: trees, messages, GitHub-side text
  and run logs are clean; the pull refs carry the D20-accepted contributor identity; the release
  asset carries F1–F3 behind a draft pending the D18 rebuild. Surfaces round 1 could not cover
  are accepted as out of scope for the stated reasons: GitHub Projects (token lacks the scope; no
  project known), traffic and insights pages, the one private third-party fork, and third-party
  clones or caches (not this repository's to audit). The D9 no-Support posture therefore stands
  unchanged. (Was ANSWERED 2026-09-20 as purge-before-flip.)
- **Finding (independent challenger, verified by the controller).** `git clone --mirror`
  fetches only objects reachable from advertised refs, so a local mirror cannot see what the
  host still holds. Seven pre-rewrite commit ids that this file cited (the summary table, D1, D3,
  D8 and D13) are absent from the mirror — the four authorized rewrites replaced them — yet the
  commits API returned HTTP 200 for all seven on 2026-09-20, and their payloads still carry the
  pre-redaction 16-digit tracker identifiers and the tracker URL that the 2026-08-30 rewrite
  removed. The D9 personal-data commits are held by the same mechanism; their ids are not
  retained anywhere this project controls. Orphaned objects are reachable only by exact id
  (never listed, searched, or cloned), but ids survive in pull-request timelines,
  notification mail, and any fork or cached page.
- **Ruling.** The 2026-08-23 D9 resolution declined a GitHub Support escalation while the
  repository was private. The operator reversed that for the visibility change: file a GitHub
  Support request to remove unreachable objects and cached views for the repository **while it
  is still private**, and flip only after written confirmation. The request text (value-free, listing the known served ids as examples — the seven from this
  file plus three more found among 38 orphaned ids referenced by pull-request timelines, of
  which 35 already return not-found — and asking for a purge across the repository AND its
  fork network, since fork networks share object storage and the one existing fork is a third
  party's) is prepared outside the repository (account-level, outward-facing): request prepared; operator
  filing PENDING; written confirmation PENDING. Reachable refs such as `refs/pull/*` are not covered by an
  unreachable-object purge (see D20).
- **Same-day hygiene.** Ten stale id citations covering seven distinct pre-rewrite ids in this file, and fourteen more in `docs/port-specs/mail.md`, `docs/INTEGRATION-STATUS.md`, `docs/COMPLETION-LOOP.md` and two source comments — 24 citation occurrences (one id four times, one twice, eighteen once), 20 distinct pre-rewrite ids, one of them cited in both the ledger and a port spec, every one probed and served by the host — were re-pointed to their
  rewritten counterparts on `main` (matched by commit subject), so tracked files no longer
  advertise orphaned ids — except three citations inside the released `v26.0.0` CHANGELOG body,
  which the release-notes rule forbids editing; those become dead references once the purge
  lands, and are recorded here rather than edited. **Amended 2026-09-21:** with the purge
  withdrawn those three citations stay live pointers to served pre-rewrite objects (which carry
  pre-redaction tracker identifiers, no personal data); accepted under the same residual-reachability
  ruling, and correctable later only through the release-notes follow-up-entry mechanism. This is the same class of edit as the 2026-08-30 condensing and is
  recorded here rather than made silently.
- **Filed:** 2026-09-20 · **Category:** privacy / publication / outward-facing action

**Why it needed you.** Contacting Support is an account-level action you declined once; only
you can reverse that, and the flip's timing is yours.

**Blocking?** The D17 flip waits on Support's confirmation. Nothing else waits. (as recorded 2026-09-20)
**Resolution (2026-09-21):** withdrawn by the operator; no request filed; no longer blocks the flip.

---

## D20 — Outside contributor's plaintext git identity on open pull requests 3–5

- **Status:** **RATIFIED 2026-09-20** — accepted as public attribution for now, with a
  follow-up.
- **Finding (independent challenger).** Fifteen commits on the open PRs 3, 4 and 5 (the
  contributor's fork branch tips, served by GitHub as `refs/pull/N/head` and `/merge`) carry the
  contributor's display name and a plaintext personal mailbox address as author and committer;
  three other commits by the same person use GitHub's private no-reply address. None is
  reachable from `main`. Rewriting `main` cannot touch them; only the contributor (force-push
  of their branch) or a Support purge can.
- **Ruling.** The operator ruled: accept as the contributor's own public attribution — the
  identity is the one they configured and submitted with their pull requests — and fix it after
  the PRs are merged. Because `AGENTS.md` named the operator's attribution as the sole
  exception, this ruling is recorded there as a second, narrow one (an outside contributor's own
  git identity on their own pull-request commits) in the same commit. The PRs are to be squash-merged when convenient (each under the
  outside-PR review workflow: independent review, the contribution-model comment, the
  metadata gate); a squash merge drops the branch commits from `main`'s history but may carry the
  contributor's configured author email into the squash commit; before merging each PR the
  proposed squash author identity is read back and the merge proceeds only if it is the
  no-reply form — otherwise the contributor is asked to re-push with the no-reply identity, or
  an explicit operator exception is recorded here. The `refs/pull/*` copies are reachable refs,
  outside D19's unreachable-object purge; they persist until the PRs are closed or the branch
  is rewritten by the contributor.
- **Filed:** 2026-09-20 · **Category:** third-party data / contribution handling

**Why it needed you.** It is a third party's data and the repo rule says it is not ours to
disclose or to redact unilaterally; the posture call is the operator's.

**Blocking?** Not blocking the flip. Adds "squash-merge PRs 3–5" to the queue.

**Applied (2026-09-22).** The operator refined the ruling on 2026-09-21: merge now, and fix
whatever the reviewers found ourselves rather than asking the contributor to reword. PRs 3, 4
and 5 were squash-merged locally onto `main` as `7fc4a49`, `6f8b852` and `57984cf` (each PR head
fetched under a forced refspec and asserted equal to the API's head before review; each squash
reviewed by the full gate and run through the local canonical suite before its push; the
contributor's own git author identity read back and kept as the squash author; each PR closed by
GitHub on push). Two maintainer follow-ups landed the accepted findings: `9a86125` (documentation
and comment corrections) and `8e9be32` (one shared tilde-spelling policy for every operator-
supplied path, the Notes `recent` retry on live osascript output with validated second reads,
and the `search`/`list` empty-`--folder` refusal, recorded as BREAKING with `schema_version`
unchanged). Hosted CI is green on every merge and on `8e9be32` (`9a86125`'s CI was red on
commit-lint only, a comma in the header scope; see §4); the run commitments are in
`docs/discovery/prelaunch-readiness-evidence.md` §4. The residual follow-ups still open are
tracked outside the repository.

---

## D21 — Delete the 18 hosted workflow-run logs that echo pre-redaction tracker identifiers

- **Status:** **APPLIED 2026-09-21** — the operator authorized the deletion in-session; the 18
  runs' log archives were deleted through the Actions API (18 × HTTP 204) and read back as absent
  (18 × HTTP 404) at 13:19 UTC. Run status records remain.
- **Finding (R1-F7).** After the independent challenge, the controller downloaded and scanned
  all 305 hosted workflow runs' logs (484 files, 245 MB) value-free, deleting each archive
  after scanning. No email, phone, non-runner home path, tracker URL or secret shape; the
  operator's handle appears only inside repository URLs (attribution exception). Eighteen runs
  from the pre-consolidation period echo the names of historical `asana-<id>` branches in their
  checkout steps: 144 occurrences of 16-digit tracker identifiers, the class the 2026-08-30
  history rewrite removed from the repository. Run logs become world-readable on the flip.
- **Ask.** Authorize deleting those 18 runs' logs (the log archives only, via the Actions API;
  the runs' status records remain) before the flip. The run ids are held outside the repository
  with the audit evidence; nothing else in Actions history is touched. Alternative: delete the
  18 runs entirely. Either is destructive and outward-facing, so it is not done autonomously.
- **Filed:** 2026-09-21 · **Category:** privacy / outward-facing destructive action

**Why it needed you.** Deleting hosted history is irreversible.

**Blocking?** Named in D17's pre-flip blocker list; nothing else waits on it. (as recorded 2026-09-21 at filing)
**Resolution (2026-09-21):** authorized in-session and executed the same day; removed from D17's blocker list.

---
