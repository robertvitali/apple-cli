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

## LEDGER — every decision at a glance (updated 2026-10-07)

**Still needs you: D2 (the Homebrew tap), D18 (the `v27.0.0` release, which waits on the phase-3
publisher) and D22 (two parity narrowings).** D9 was reopened 2026-08-31 and finally closed the
same day (recorded CLOSED — see D9). D15 and D16 were ratified 2026-09-07. D3 and D14 were
live-validated operator-present on 2026-08-27 (evidence on their Asana tasks; the Mail parent
closed the same day under the closure-verification protocol). Publication remains blocked —
independently of D9 — until every readiness gate passes and a separate fresh pre-publication
privacy audit over at least the then-current surfaces D34 names (tree, history, commit messages,
objects, refs, GitHub-side text, workflow logs and artifacts, workflow-run, check-suite and
check-run objects, Actions caches, repository metadata and Releases) records zero findings for its
stated scope. The repository itself has been public since 2026-09-21: D17 advanced the visibility
step ahead of those gates (see the amendment below the table), and visibility unlocks no other
publication action.

| # | Topic | Status | Ruling |
|---|---|---|---|
| D1 | `notes delete-folder` previews by default | **RATIFIED** | Keep the preview default — `--execute` stays required on the only irreversible-and-unrecoverable write |
| D2 | Cut the first release + retire the six MCP servers | **2 of 3 parts APPLIED 2026-08-30** | **Terminal gate. Yours alone.** Release DONE: `v26.0.0` cut, tagged, GitHub Release published (notes-length recovery was manual; workflow fixed after); the Release was converted to a draft on 2026-09-20 under D17 ruling 3 and deleted on 2026-09-27 under D34, the `v26.0.0` tag kept; `v27.0.0` is planned to replace it (D17 ruling 2, D18). Retirement DONE: all six MCPs moved to `retiredServers` in the private fleet-config repo; hosts converge on their next whole-tree apply. REMAINING: fleet deployment of the binary — and the operator ruled 2026-08-30 that this is Homebrew-ONLY (a tap; the previously-scoped install script and self-update subcommand are CANCELLED), and that a RELEASE FREEZE holds until that tap actually serves `brew install apple-cli`: version stays pinned at `v26.0.0`, work lands UNRELEASED under `[Unreleased]`, do not dispatch release.yml or edit the version constant. Completing this part lifts the freeze; an explicit operator release instruction also lifts it for that release, and until the design's publisher exists such a release takes `docs/runbooks/urgent-release.md` (amended 2026-09-26; `release.yml` no longer exists). D2 closes then |
| D3 | Live-validate `mail send --gui-send` | **APPLIED 2026-08-27** | Live-validated operator-present: one self-addressed send executed and delivered (oracle-verified both sides), test items cleaned by exact id |
| D4 | Live-validate iMessage group-chat send | **APPLIED 2026-08-23** | Option (b): record "wired + code-inspected, never live-validated" as a port-spec asterisk |
| D5 | Chasing the Messages fuzzy-search recall gap | WITHDRAWN | Should not have been asked; became ordinary queue work |
| D6 | Eight parity posture calls | **APPLIED** | CONTACTS-L4 delete claim · NOTES-M1 restore 4 keys · NOTES-L4 structural divergence · gap10 keep opt-in body · **gap25 wire delete-rules live** · extra20 open by default |
| D7 | Committed phone number in public history | **ANSWERED** | "B then A" — superseded by D9, which covers the same number plus more |
| D8 | Which Mail oracle wins on a safety limit | RESOLVED | **Safety wins** — stricter limit wins on A/B conflicts; landed in `415709c` |
| D9 | Personal data published to a public repo | **CLOSED 2026-08-31** (APPLIED 2026-08-23, amended 2026-08-29, REOPENED 2026-08-31, then finally closed the same day) | Repo private (public since 2026-09-21 under D17). Prior rewrite passes were verified against the classes then known; a 2026-08-31 round found further history and current-tree defects and the gate was reopened. The approved scoped remediation was completed the same day — history rewrite in a fresh clone, fresh-clone verification, rollback/audit scratch removed and absent-verified — and one complete, independently challenged, value-free audit round returned zero findings for its stated scope (an earlier same-day closure attempt was recorded invalid and reversed first). Rewritten main `c794d7e` is an ancestor of current main; `v26.0.0` peels to `0f617eb`. This closure covers its stated scope only and does NOT authorize publication: the repo stays private until every readiness gate passes and a separate fresh pre-publication privacy audit records zero findings for the then-current tree, history, commit messages, objects, refs, and artifacts |
| D10 | Search/find-contact length caps | WITHDRAWN | Should not have been filed |
| D11 | What `schema_version` tracks | **APPLIED** | **Shape only** — value breaks ride the MAJOR + CHANGELOG; both policy lines rewritten to agree |
| D12 | `notes save-attachment` can write to `~/.ssh` | **RATIFIED** | Keep strict Notes-oracle parity; residual documented, fleet stays intentionally inconsistent |
| D13 | Strict-superset go/no-go package | **APPLIED** | All scoped items landed; D4 keeps its permanent never-live-exercised asterisk; D3 and D14 were live-validated 2026-08-27 |
| D14 | Live-exercise `mail rules` delete | **APPLIED 2026-08-27** | First live exercise done operator-present: labeled disabled test rule deleted by index, readback matched, 3 real rules untouched |
| D15 | Extend the public-attribution exception to `.github/CODEOWNERS` | **RATIFIED 2026-09-07** | The operator's exact GitHub user may appear in `.github/CODEOWNERS` for every enforcement-control-plane path, as deliberate public attribution alongside LICENSE, README, and git author metadata. Sequence is fixed: the `AGENTS.md` exception extension lands first as its own reviewed commit, the CODEOWNERS commit lands second with its own fresh privacy scan, then GitHub's code-owners errors API confirms it parses. Trade-off recorded per the design: from that step until public launch no release can be cut; the release freeze's urgent-fix clause is satisfiable only by a reviewed, operator-authorized, temporary restoration of a write-capable release workflow, recorded as an explicit exception and removed again afterwards |
| D16 | Narrow main-only reversal for disposable rehearsal refs | **RATIFIED 2026-09-07** | Three disposable ref classes, and only these, may be created for the publication-automation rehearsals (design §18 steps 8–14, removal at step 18): the uniquely named disposable target ref, the proposal head refs of the validation PRs (which target that ref, never `main`), and the Dependabot-created head refs of step 13; never for feature work; never merged into `main`; deleted after the rehearsal, including on abort; does not reverse the ruling for ordinary work. The `AGENTS.md` reversal commit lands under the private main-only gate when the rehearsal step begins, after an in-session re-confirmation and before the first branch is cut. The later full reversal that activates the `main` ruleset is a SEPARATE future operator instruction and is not granted here |
| D17 | Early visibility flip to restore hosted Actions; pre-flip privacy audit round 1; disposition of its findings | **ANSWERED 2026-09-20; APPLIED 2026-09-21** (flip 14:31Z; hosted CI and Docs green the same day; end-of-roadmap audit round 2 run 2026-09-22: zero new findings, gate not yet closed — R1-F1 recurred in the unchanged draft asset; the draft was deleted 2026-09-27 under D34, and the gate will close on a fresh round with zero findings, not yet run) | Operator ordered: fresh audit first, flip on zero findings, end-of-roadmap audit still required. Round 1's zero-findings condition was NOT met: seven findings — five operator-dispositioned (D17–D20), the fixture fix pending, and the hosted-log deletion OPEN in D21 — both closed 2026-09-21 (fixture fix landed, D21 applied); D19 later superseded; for the binary the operator chose rebuild + re-cut (as `v27.0.0`) rather than accept, and, because the design forbids a private publisher and hosted runs are billing-blocked, ordered the `v26.0.0` Release converted to a draft first, the flip second, the re-cut after hosted validation |
| D18 | macOS 27 adoption release `v27.0.0` | **OPEN — steps (1) and (3) satisfied 2026-09-22; (2) and (4) demonstrated on `3e46e82` in rehearsal; (4a)/(5) gated on the phase-3 publisher** | Operator instruction 2026-09-20: bump to `27.0.0` once all tests pass on macOS 27. Satisfied: the D17 flip and green hosted runs (1); the §4.1 adoption-matrix amendment and `[Unreleased]` baseline note, this commit (3). Demonstrated on `3e46e82`, to be re-established on the exact release commit and its shipped artifact when the publisher runs: the local canonical suite green on macOS 27 plus the hosted logic gate (2); the path-free rebuild rehearsal PASS on every gate — zero debug-map entries, zero home paths in binary or archive, clean tar headers, zero network fetches (4, D23/D24), with the local run accepted as the §12 hardened alternative (D25). Still waiting: a publisher path (4a, design §18 phase 3, unbuilt) and the release through it (5). The `v26.0.0` draft was deleted under D34, settling this entry's draft-or-delete question |
| D19 | GitHub still serves pre-rewrite commits by id | **SUPERSEDED 2026-09-21** (ANSWERED 2026-09-20) | Verified: seven pre-rewrite commit ids formerly cited in this file return HTTP 200 from the API and still carry pre-redaction tracker identifiers. Operator reversed the 2026-08-23 no-Support posture: request a purge of unreachable objects and cached views from GitHub Support while the repo is still private; the D17 flip waits on that confirmation. Stale id citations in this file were re-pointed to their rewritten counterparts the same day. Superseded 2026-09-21: request withdrawn by the operator, no purge filed; residual by-id reachability accepted; D9's no-Support posture stands |
| D20 | Outside contributor's plaintext git identity on open PRs 3–5 | **RATIFIED 2026-09-20; APPLIED 2026-09-22** (PRs 3–5 squash-merged locally as `7fc4a49`, `6f8b852`, `57984cf`; follow-ups `9a86125`, `8e9be32`, `4f8776a`; two further proposals filed as D22) | Accepted as that contributor's own public attribution for now; the PRs were squash-merged with the squash author identity read back first; the reachable `refs/pull/*` copies are outside the D19 purge and remain resolvable after the PRs closed — their retention is GitHub's, not this repository's |
| D21 | Delete 18 hosted workflow runs' logs that echo pre-redaction tracker identifiers | **APPLIED 2026-09-21** | Post-round scan of all 305 run logs: no personal data; 18 runs' logs contain 16-digit tracker identifiers inside historical branch names. Deleting run logs is destructive and outward-facing, so it waited for the operator's instruction; authorized and executed 2026-09-21 (18 log archives deleted, 18 × 204, read back 18 × 404); removed from D17's blocker list |
| D22 | Two parity-vs-safety narrowings proposed by the PR 4/5 reviewers: (a) a read-side credential-file denylist for attachments; (b) the Notes search script's outer per-hit handler tolerating only "not found" | **OPEN 2026-09-22** | Both were implemented, reviewed, and then PULLED from the follow-up commit because each drops something the retired oracle permits: (a) narrows Mail's `--attach` surface; (b) turns a per-note read error into a whole-command failure without an enumeration of what a locked note raises. Awaiting the operator's ruling (D12 precedent) |
| D23 | Grant the D18 step (4) path-free rebuild rehearsal (native build on the operator's host) | **GRANTED 2026-09-22** | Operator chose "grant the rebuild now": controller prepares a frozen invocation + controller packet for review, then runs the build and the asset re-scan. Packet went through six review rounds (codex, security reviewer, critic) before the exact command was put to the operator as D24 |
| D24 | Run the frozen revision-7 rebuild packet (exact command, digest-pinned) | **GRANTED 2026-09-22; APPLIED 15:44–15:46Z** | Operator confirmed the exact `controller.sh` invocation at the frozen digests (README `46cf8018ae95eb9a`, invocation `aec133cdf3e01715`, controller `793841dde16545c5`); one-shot run-01 returned `REBUILD_EXIT=0 PASS`, as-run digests identical to the reviewed ones. Value-free results are in the readiness evidence §3 |
| D25 | Does the local macOS 27 canonical run plus the reviewed rebuild satisfy design §12's "separately reviewed, hardened alternative" to a stable hosted macOS 27 image? | **ANSWERED 2026-09-22: accepted** | Operator accepted; design §4.1 and §12 amended in this commit to record the matrix as run and its evidence basis (one operator-owned host; hosted lanes unchanged on `macos-15`). macOS 27 joins macOS 26 as a tested and supported baseline; the technical macOS 14 floor is unchanged |
| D26 | Next work item after the D18 rehearsal: the design's phase-3 publisher (D18 step 4a) | **ANSWERED 2026-09-22: build the publisher** | Operator chose the publisher over ruling on D22 first or stopping; D22 stays open and non-blocking. No release, tag, version, Pages or Homebrew action is authorized by this choice |
| D27 | Publisher sequencing: start with the design's read-only release-preparation rehearsal (§14.1, §18 step 15) or author the write-capable publisher now | **ANSWERED 2026-09-22: read-only tooling first** | Design §15 forbids installing any publisher-side control before the active `main` ruleset, the closed privacy gate and a reviewed launch specification, and the repository's tests refuse write-capable workflows; `scripts/ci/release_prep.py` (version computation, drift gate, scratch-only rendering, value-free report) lands first with `Tests/automation` coverage; the write-capable half waits for the §15 preconditions |
| D28 | Order of the remaining pre-launch tooling: parsed-YAML workflow scan (design §18 step 17) before the site-assembly rehearsal (step 16), or the reverse | **ANSWERED 2026-09-22: steps 17 then 16** | The scan is the guard every later workflow change (including step 16's own job) is checked against, so it lands first, wired into the `Supply-chain policy` job with `Tests/automation` coverage; the site-assembly rehearsal follows as its own reviewed commit; §18 steps 8–14 and 20 remain operator-involved and are not started by this ruling |
| D29 | Design §16 archive route: `/version/` collides with the generated `apple version` manual page | **ANSWERED 2026-09-23: amend to `/versions/`** | The site assembler refuses an archive root that a current-manual page occupies; the plural root is a route no command can render to, needs no manual special case, keeps `/version-manifest.json`, and already passed the local assembly rehearsal end to end |
| D30 | Author `.github/CODEOWNERS` now under the D15 exception (design §18 step 5, CODEOWNERS half) | **ANSWERED 2026-09-24: author it now (option A)** | The step 17 read-back recorded CODEOWNERS absent (NOT SATISFIED) and every later bootstrap item waits on it; D15 already carries the attribution exception, so D30 settles only WHEN — now, rather than after the launch specification — and confirms the D15 sequence (AGENTS.md extension first, CODEOWNERS second with a fresh privacy scan and the control-plane manifest, errors API read-back third) |
| D31 | Outside collaborators with read access (step 17 read-back found two) | **ANSWERED 2026-09-25: remove one, keep one** | The operator named the account to remove after seeing the list; the controller removed it through the API (HTTP 204) and read the list back: collaborators 2 — admin 1, read 1, of which outside 1. The kept read grant meets every collaborator expectation the design states (only administrator, only environment reviewer, no other write-capable actor), so it is a conforming state, kept on the operator's ruling with no reason recorded and no adverse finding against either account; identities stay out of the repository |
| D32 | Repository merge method and Actions SHA-pinning settings (design §18 steps 7 and 4) | **ANSWERED 2026-09-25: apply all (option A)** | Applied 2026-09-26T01:40Z and read back: merge commits and rebase merges disabled, squash kept, squash title from the PR title and body from the PR body, delete-branch-on-merge on, `sha_pinning_required` on; selected-actions allowlist unchanged. Reversible settings; nothing in the tree, no branch, tag or release touched |
| D33 | Dependabot security settings and the Swift ecosystem (design §17) | **ANSWERED 2026-09-26: security on, keep Swift (option A)** | Applied 2026-09-26T20:03Z and read back: vulnerability alerts on; automated security fixes (Dependabot security updates) on and not paused; zero open alerts. Enabling alerts also registered a GitHub-managed "Dependency Graph" workflow. The dependency graph, read at 2026-09-27T01:43Z, holds no Swift package, so the alerts and security updates do not yet cover the product's SwiftPM dependency. The Swift version-update ecosystem stays on ahead of §17's order, a recorded deviation the controller intends to settle in the step 13 Dependabot rehearsal. Reversible settings; nothing in the tree touched |
| D34 | The end-of-roadmap privacy gate and the publisher (design §15): delete the `v26.0.0` draft Release | **ANSWERED 2026-09-26: delete the draft (option A); APPLIED 2026-09-27T01:32Z** | As written, the end-of-roadmap gate closed only on a scan of the published rebuilt asset, which needs the publisher, while design §15 makes a closed gate a precondition of the launch that adds it. After a private copy of both assets was kept, the draft Release was deleted through the API and read back: its id and both asset download URLs answer 404, zero Releases are listed, the `v26.0.0` tag is kept. The gate will close on a fresh round over at least Round 1's surfaces plus those the entry names, with zero findings; that round has not run. Before publication the exact rebuilt `v27.0.0` artifact must pass D18 step (4) and a value-free scan under the round's classes and denylist over the binary, archive, checksum file and Release notes body, both recorded first (entry below). Irreversible on GitHub |
| D35 | Claude session links in eight historical commit messages | **RATIFIED 2026-09-26: accept as a recorded class (option A)** | Eight operator commit messages on `main` (2026-09-07 to 09-14) carry `Claude-Session` links to two sessions. Accepted as a class for the fresh round, scoped exactly to those commit messages; no history rewrite; new ones stay refused |
| D36 | The outside contributor's own session link in the descriptions of PRs 3–5 | **RATIFIED 2026-09-26: accept as the contributor's own disclosure (option A)** | One session link of the contributor's, in those three descriptions and their edit histories only; never copied into a tracked file, commit or prose; the same link elsewhere is a finding, among them two commit messages on pull request 3's own branch, found after the ruling |
| D37 | Workflow-run objects served pre-rewrite commit messages | **ANSWERED 2026-09-27; APPLIED 2026-09-27T04:43Z (option A)** | A scan of the public run listing found one run storing a pre-rewrite message with personal data and 90 with tracker identifiers or session links. All 168 runs whose head commit is not on `main` were deleted and read back (205 remain, none off-main, each deleted id answers 404); a re-scan of the listing found no personal data, denylist term or tracker identifier, and copies of the eight D35 messages remain for the fresh round. The commits themselves stay fetchable by id (D38); at least 29 off-main commit ids stay listed in the public Events feed until they age out (about 2026-12-13 at the latest), and third-party check suites keep copies of their messages by commit id. Irreversible |
| D38 | A pre-rewrite commit with personal data stays fetchable by id | **RATIFIED 2026-09-28: accept under D19 (option C), re-confirmed on corrected facts** | The 2026-07-23 pre-rewrite commit D37 found still answers by id with two denylist terms, a provider mailbox and two personal email addresses in its message. It was public 2026-07-23 to 2026-08-19 (the D9 period), and its message was readable in the run listing 2026-09-21 to 2026-09-27. Accepted as a residual scoped to that one commit object and the stored copies of its message by commit id; no Support purge filed; any other personal-data object is a finding |
| D39 | How APPLE_MAIL_MCP_HOME reads a tilde | **SUPERSEDED 2026-09-30 by D40** (RATIFIED 2026-09-30: read it as the retired Mail MCP did (option A); APPLIED 2026-09-30) | No tilde expansion: a relative value, `~/…` and `~name/…` included, names a folder under the working directory on every macOS release, and an empty value means unset. This replaces the CLI's release-dependent reading (macOS 26 and 27 sent `~/…` to the home folder). Recorded as BREAKING with `schema_version` unchanged |
| D40 | The two public names that still say "mcp" | **RATIFIED 2026-09-30: rename both outright (option A)** | `APPLE_MAIL_MCP_HOME` is replaced by `APPLE_MAIL_TEMPLATES_DIR` (the template folder itself; the shared tilde policy applies) and the default folder moves from `~/.apple_mail_mcp/templates/` to `~/.apple-cli/mail-templates/`. Neither old name is read any more. A recorded narrowing of the retired Mail MCP (its variable and folder); D39 lapses with the variable it governed. BREAKING with `schema_version` unchanged; the release note gives the move command |
| D41 | Two message texts and a search term from a live oracle run in a Messages test | **RATIFIED 2026-09-30: redact at HEAD, accept history (option A)** | `Tests/MessagesKitTests/MessagesKitTests.swift` carried two message texts and a search term sampled from the operator's Messages store during a live oracle run (committed 2026-07-15 in `23c9afc`, public in the periods D9 and D17 record). Replaced at HEAD with synthetic text; history keeps the originals as an accepted residual, as D38 did for its commit |
| D42 | A note fragment from a live run in a Notes test | **RATIFIED 2026-09-30: redact at HEAD, accept history (option A)** | `Tests/NotesKitTests/NotesTextTests.swift` quoted a three-word fragment of one of the operator's notes, measured live on 2026-08-19 (NOTES-L1) and committed that day in `50c30f0`; public since the visibility change D17 records. Replaced at HEAD with synthetic text; history keeps the original as an accepted residual, as D41 did for the Messages test |
| D43 | CI job logs print the removed Messages test's name, which carried D41's search term | **RATIFIED 2026-09-30: leave the logs to expire (option A), re-confirmed on corrected facts** (amended 2026-10-04: one later copy, the last now about 2027-01-01) | Hosted build-test job logs print every test name: 61 job logs in 57 CI runs (2026-09-01 to 2026-09-30) carry the removed test's name, two lines each; a scan of all 322 retrievable logs found neither the message texts nor D42's note fragment. Accepted as a residual until GitHub's 90-day log retention removes them (the last about 2026-12-29, later if a run from before the D41 commit is re-run or a pull request on an older head runs) |
| D44 | Narrow main-only reversal for a parallel session's worktree | **RATIFIED 2026-10-01** (amended 2026-10-03: the branch reached `origin` once and was deleted on the operator's word) | One local git worktree, `~/workspace/apple-cli-governance` on the local branch `26/governance`, for a second agent session working the supply-chain and governance queue in parallel. The branch is never pushed and never merged: each change is rebased onto the current `main`, passes the same review, scan and canonical gates, and lands by a fast-forward push to `main`, one landing at a time. Removed when that queue is done. Ordinary work otherwise stays main-only; D16 is unchanged |
| D45 | Open Dependabot pull requests 7 and 8 while the Dependabot governance path is built | **ANSWERED 2026-10-02: supersede both on main (option A); APPLIED 2026-10-03** (resolved 2026-10-03: Dependabot closed both; its edits started two CI runs on pull request 7's pre-D41 head, one of which ran the Swift suite and added a log copy under D43) | Two reviewed commits on `main` take the same updates: urllib3 2.7.0 → 2.8.0 in `docs/requirements.txt`, which clears the three open alerts, and astral-sh/setup-uv 10.1.0 → 10.2.0, with its new SHA added to the reviewed Action allowlist. Dependabot then closes both pull requests itself. No agent action on either pull request, and no new CI run on pull request 7's pre-D41 head (D43) |
| D46 | Interim protection for `main` before the design's ruleset | **APPLIED 2026-10-02T05:04Z on the operator's instruction; no-bypass shape RATIFIED 2026-10-02 (option A)** | One active ruleset on `main` only, with two rules, block force pushes and restrict deletion, and no bypass actor: while it is active nothing, the operator's credentials included, can force-update or delete `main`, and an authorized history rewrite needs the operator to disable it first. It guards against mistakes, not a misused admin credential, which can disable it. Neither rule applies to fast-forward pushes, pull requests, Dependabot's branches or the current read-only CI workflows; the first push under it (`9cd2260`) passed. At design §18 step 20 the operator decides whether it is deleted or kept; keeping it needs design amendments |
| D47 | The public Activity view lists commits no advertised ref holds, whose parents reach the replaced history | **RATIFIED 2026-10-07 (UTC): leave them (option B of the later briefs), re-confirmed after the reach was measured** | The repository's public Activity view lists 128 commits that no advertised ref holds; with their parents they make 1,550 such commits, holding phone-number-like strings, email addresses and two commit messages with a denylist term no file or commit message on `main` carries. Accepted as a residual scoped to the 128 commits the view listed on 2026-10-06 and everything reachable from them that no advertised ref holds: 1,550 commits (the 128 among them) and their trees and file contents that no advertised ref holds, pinned by the SHA-256 of two private id lists. Anything the round's classes detect in a commit outside the two pinned lists, or in an object no listed commit reaches, is outside this residual and stays a finding unless another entry accepts it, whenever the view lists it or however it is found; the six branch names in the view that carry tracker identifiers are D50 |
| D50 | Deleted branch names in the public Activity view carry tracker identifiers | **RATIFIED 2026-10-07 (UTC): accept them as a recorded residual (option B)** | Six deleted branch names, in 24 creation, push and deletion events dated 2026-07-15 to 2026-08-23, carry tracker identifiers that also occur in commit messages D47 accepts. Accepted as a residual scoped to those six names in those 24 events; the same names in any other event or on any other surface, and any other tracker identifier the view shows, stay findings unless another entry accepts them |

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

**Amended 2026-09-26 (urgent-release runbook):** an explicit operator release instruction still lifts the freeze for that release, but until the design's publisher exists such a release has exactly one path, `docs/runbooks/urgent-release.md`, under a ledger entry of its own. `v27.0.0` (D17 ruling 2) does not take it: D18 routes that release through the publisher. The `AGENTS.md` freeze paragraph, whose "never blocked" sentence predated the publisher's removal, is corrected in the same change.

---

**Amended 2026-09-26 (Progress line overtaken):** the Progress line's "The tap requires the repo to be public" no longer describes what the tap waits on. The repository has been public since 2026-09-21 (D17). The tap still needs a downloadable published release: `v26.0.0` has been a draft since 2026-09-20 (D17 ruling 3), and its replacement, `v27.0.0` (D17 ruling 2), waits on the phase-3 publisher (D18). Design §15 also forbids any distribution writer (a tap-updating workflow, token or App) in this repository or its workflows until the launch specification is approved; that specification defines the tap's writer. The Blocked-by line stands as written.

---

**Amended 2026-09-26 (draft deleted, D34):** the `v26.0.0` Release, a draft since 2026-09-20 (D17 ruling 3), was deleted through the API on 2026-09-27T01:32Z under D34; the tag is kept. No `v26.0.0` Release exists any longer, draft or published, so the tap's first downloadable release is whichever release is next published, planned as `v27.0.0` (D17 ruling 2, D18). The Progress-line amendment above otherwise stands, and D2's remaining Homebrew part is unchanged.

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

**Amendment 2026-09-24 (D30):** the operator's go-ahead to execute this sequence now, rather
than after the launch specification, is recorded as D30; D30 adds the control-plane manifest to
step (2) and changes nothing else here.

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

**Amended 2026-09-26 (D34):** a broader form of the deletion that ruling 3's option (C) offered (there the asset; under D34 the whole Release and both assets), which the operator set aside then for the reversible draft, was taken on 2026-09-27T01:32Z under D34, after the flip: keeping the draft, under the end-of-roadmap closure condition as then written, left that gate unclosable. The tag is kept, and `v27.0.0` remains the planned re-cut (ruling 2, D18).

---

## D18 — macOS 27 adoption release: bump to `v27.0.0` once all tests pass

- **Status:** **OPEN** — instruction received 2026-09-20; execution gated as below.
  **Update 2026-09-22:** steps (1) and (3) are satisfied — (1) flip and green hosted runs
  2026-09-21; (3) the §4.1 amendment and the `[Unreleased]` baseline note land in the commit
  that records this update. Steps (2) and (4) are demonstrated on `3e46e82`, not yet on the
  release commit their wording names: (2) canonical suite green on macOS 27.0 for `3e46e82`
  (run 2, 10:02Z) and the hosted logic gate green on the same commit; (4) the path-free
  rebuild rehearsal (D23 grant, D24 exact command) returned PASS on every gate, recorded
  value-free in the readiness evidence §3a, and the operator accepted the local run as the §12
  hardened alternative (D25). Both are re-established on the exact commit the publisher
  releases and on its shipped artifact. Steps (4a) and (5) remain: no publisher path exists
  (`release.yml` was removed and the design's phase 3 bot publisher is unbuilt), so `v27.0.0`
  cannot be cut yet.
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

**Amended 2026-09-26 (D34):** the draft-or-delete question under "Not decided here" was raised early and is settled: the `v26.0.0` draft Release was deleted on 2026-09-27T01:32Z under D34, and the tag is kept. The end-of-roadmap privacy gate no longer waits on this entry; it will close when a fresh round records zero findings, before the launch that adds the publisher, and that round has not run. Before publication, the exact artifact to be published must pass step (4)'s verified-outcome check and a value-free scan under that round's classes and denylist covering the binary, the archive, the checksum file and the Release notes body, both recorded in the evidence file (D34). The denylist scan stays operator-local, never inside a hosted environment, recorded value-free against the sha256 digest of each covered item, the Release notes body as it will be published included. The design's §15.1 read-only preflight lists neither check today; the controller will propose adding step (4) and a check that a passing record matches those digests in the launch specification, and D34 requires both until an approved specification adds them, and continues to if it does not.

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

**Amended 2026-09-28 (D38):** this entry accepted by-id reachability of pre-rewrite objects, the D9 personal-data commits included, on the premises that their ids were retained nowhere this project controls and every published surface was clean or operator-dispositioned. Neither held for one of them: a 2026-07-23 pre-rewrite commit whose message carries personal data had its message and id served by the public workflow-run listing from 2026-09-21 to 2026-09-27 (D37), and a third-party check suite keeps a copy of the message by commit id. The operator accepted it as a recorded residual (D38) and filed no Support purge.

**Amended 2026-10-07 (D47):** the repository's public Activity view, public since 2026-09-21, lists 128 commit ids that no advertised ref holds, and with their parents they make 1,550 such commits, so neither premise holds for those commits. This entry's finding that orphaned objects are reachable only by exact id and never listed does not hold either: the Activity view lists such ids, and fetching one returns every ancestor. The operator accepted those commits and their objects that no advertised ref holds as a recorded residual (D47) and filed no Support purge. For orphaned objects outside that set this entry's acceptance still rests on both premises. Anything the round's classes detect in a commit outside the two pinned lists, or in an object no listed commit reaches, is outside this residual and stays a finding unless another entry accepts it, whenever the view lists it or however it is found.

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
GitHub on push). Three maintainer follow-ups landed the accepted findings: `9a86125` (documentation
and comment corrections), `8e9be32` (one shared tilde-spelling policy for every operator-
supplied path, the Notes `recent` retry on live osascript output with validated second reads,
and the `search`/`list` empty-`--folder` refusal, recorded as BREAKING with `schema_version`
unchanged) and `4f8776a` (the `recent --text` unreadable-date marker and the Messages
unknown-delivery state); two further proposals were pulled as parity narrowings and filed as
D22. Hosted CI is green on every merge and on `8e9be32` (`9a86125`'s CI was red on
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

## D22 — Two parity narrowings proposed by the outside-PR reviewers (attachment denylist; Notes per-hit error handling)

- **Status:** **OPEN 2026-09-22** — filed by the controller; nothing applied.
- **Context.** Reviewing the maintainer follow-ups to PRs 4 and 5, the reviewers proposed two
  changes that the controller implemented, put through the full review gate, and then removed
  from the commit before it landed, because the critic's parity read (against the oracle source
  still on disk in the npx cache — apple-notes-mcp 2.8.1 at review time; the port itself was
  mapped against 2.6.12 per `docs/port-specs/notes.md` §8, and the search loop's shape is the
  same in both — and the Mail oracle's `sensitive_dirs`) showed that each
  drops a capability the oracle grants — the class AGENTS.md's one rule calls a failure and the
  class D12 reserved to the operator.
- **(a) Read-side attachment denylist.** Proposal: on top of the inherited credential-directory
  list (`sensitive_dirs`, byte-faithful for Mail), refuse as an ATTACHMENT SOURCE `~/.netrc`,
  `~/.git-credentials`, `~/.npmrc`, `~/.pypirc`, `~/.kube`, `~/.docker` (`safety_violation`,
  exit 77), for `mail send --attach`, `mail reply --attach` and `messages send --file`; write
  destinations untouched. Cost: Mail's attach surface becomes narrower than the oracle's; a
  legitimately shareable file under `~/.docker` or `~/.kube` needs copying first. Benefit: the
  denylist is the containment for attachment content under write-model v2 (an unsandboxed send
  reaches any recipient), and these are the credential files most often exfiltrated by a
  prompt-injected command. If accepted: re-land the reviewed patch (held with the controller's
  private evidence outside the repository; small enough to redo from this description if that
  copy is gone), record the deviation in `docs/port-specs/mail.md`, and update the resolver's
  parity comment.
- **(b) Notes search per-hit error handling.** Proposal: the generated search script's OUTER
  per-hit handler (a bare `try … end try` in the oracle, verified) tolerates only error -1728
  (note vanished mid-traversal) and re-raises everything else, so a timeout, lost connection or
  refused automation fails `notes search` / `notes recent` loudly instead of returning a shorter
  list under `ok: true`. Cost: parity deviation, and an unenumerated risk — if a password-locked
  note raises a different code on `name`/`id`/date/container reads, one such note makes every
  search fail. Precondition before any ruling to accept: a live-store enumeration of what those
  five reads raise on a locked note (needs an `apple-cli-test` note locked by the operator; the
  controller will not create one). If accepted: re-land the reviewed patch (held outside the
  repository as above; two hunks, redoable from this description), record the deviation in
  `docs/port-specs/notes.md` §8, and correct the code comment that attributes only the inner
  handlers to the oracle.
- **Ask.** Rule on (a) and (b) separately: accept (with the recorded deviation), reject, or
  defer. For (b), also whether to grant the live locked-note enumeration.
- **Filed:** 2026-09-22 · **Category:** parity vs safety (D12 class)

**Why it needed you.** Each drops something the oracle permits on a shipped surface; the parity
claim is frozen and no longer re-runnable, so a narrowing that lands without a ruling cannot be
recovered into the record later.

**Blocking?** No. The rest of the follow-ups landed without them.

---

## D23 — Grant the D18 step (4) rebuild rehearsal

- **Status:** **GRANTED 2026-09-22** (answered "grant the rebuild now").
- **Ask.** D18 step (4) requires the release build and packaging to be shown free of every
  R1-F1 to R1-F3 carrier as a verified outcome. That needs a native build on the operator's
  macOS 27 host, which under the standing rules is a fresh, concrete, reviewed grant.
- **Ruling.** Prepare a frozen invocation and controller packet for the operator's review, then
  run the path-free build and the asset re-scan. The packet: PATH pinned to system directories,
  SwiftPM resolution disabled with the pinned dependency pre-checked in the local cache, the
  build under `-gnone`, source and scratch prefix maps and `-oso_prefix`, `strip -S` then ad-hoc
  re-signing, `COPYFILE_DISABLE=1 bsdtar` with numeric-zero ownership and empty names, and a
  scanner whose gated classes are home-directory paths, denylist terms and runtime identity
  terms; a one-shot controller re-hashes the copy it runs and bounds it with a timeout.
- **Filed:** 2026-09-22 · **Category:** native run grant (D18 step 4)

**Why it needed you.** Every native build or inspection on the operator's host is a grant.

**Blocking?** D18 step (4) waited on it; nothing else.

---

## D24 — Run the frozen revision-7 packet (exact command)

- **Status:** **GRANTED 2026-09-22; APPLIED** (run-01, 15:44:05Z–15:46:08Z).
- **What was confirmed.** The exact `controller.sh` invocation at the frozen sha256 prefixes
  README `46cf8018ae95eb9a`, invocation `aec133cdf3e01715`, controller `793841dde16545c5`, after
  six review rounds (codex PASS on revisions 6 and 7; security reviewer and critic APPROVE on
  revision 6, their minors folded into revision 7). The brief stated what a PASS does not
  settle: steps (4a) and (5), and the §12 call, which became D25.
- **Outcome.** `REBUILD_EXIT=0 PASS`, controller exit 0; the as-run digests equal the reviewed
  ones; HEAD and the working tree unchanged. Value-free record in the readiness evidence §3a.
- **Filed:** 2026-09-22 · **Category:** native run grant (D18 step 4)

**Why it needed you.** The grant in D23 was in principle; the command that runs is the grant.

**Blocking?** No further step waits on it.

---

## D25 — Accept the local macOS 27 run as design §12's hardened alternative

- **Status:** **ANSWERED 2026-09-22: accepted.**
- **Question.** Design §12 admits macOS 27 only on a stable hosted macOS 27 image or a
  "separately reviewed, hardened alternative". No hosted `macos-26`/`macos-27` image exists.
  Available instead: the full local canonical suite green on the operator's macOS 27.0 host
  for `3e46e82` (logic tier 1968 swift-testing tests in 261 suites, Python automation tier 767
  tests, local Bats tier 452 cases, both toolchains, the §12 path-confinement canary included;
  the live tier is not part of that suite) and the D24 rebuild rehearsal PASS.
- **Ruling.** Accepted. Design §4.1 and §12 are amended to record the matrix as run and its
  evidence basis; the `[Unreleased]` note states the new baseline and the unchanged macOS 14
  floor. The trade the operator accepted: the baseline claim rests on one operator-owned host
  rather than a neutral hosted runner; the amendment says so in its own sentence.
- **Filed:** 2026-09-22 · **Category:** platform adoption (D18 step 3)

**Why it needed you.** It writes a public support claim on the strength of a host you own.

**Blocking?** No; it unblocked D18 step (3).

---

## D26 — Next work item: the phase-3 publisher

- **Status:** **ANSWERED 2026-09-22: build the publisher** (D18 step 4a).
- **Question.** With D18 steps (1)–(4) recorded and `ec28b26` green, what comes next: the
  publisher, the open D22 parity ruling, or a stop for operator re-planning?
- **Ruling.** The publisher. D22 remains open and non-blocking and is presented separately.
  This choice authorizes design-conformant implementation under the standing review, exact-SHA
  canonical-suite and privacy gates only; it does not authorize a release, a tag, a version
  change, a Pages deployment or any Homebrew action. The first `v27.0.0` publication still
  requires the design's own operator approval step once the publisher exists.
- **Filed:** 2026-09-22 · **Category:** roadmap sequencing

**Why it needed you.** Multi-session scope; the order of the remaining roadmap is yours.

**Blocking?** No.

---

## D27 — Publisher sequencing: read-only release preparation first

- **Status:** **ANSWERED 2026-09-22: read-only tooling first.**
- **Finding that framed the question.** Design §15 says nothing publisher-side (bot identity,
  listener, write-capable workflow, tag rulesets, protected environment) is installed until the
  §18 step 20 `main` ruleset is active and read back, the privacy gate is closed and a
  separately reviewed launch specification exists; `Tests/automation/test_action_pins.py`
  enforces that today by refusing any workflow with `workflow_dispatch`, a write permission, an
  environment or a release/tag command. Design §14.1 does permit a read-only exact-SHA
  release-preparation rehearsal now, and none of its logic existed as a script — it lived inline
  in the removed `release.yml`, untested.
- **Ruling.** Build the read-only half first: `scripts/ci/release_prep.py` (version computation
  from branch-reachable Conventional Commit subjects, `--macos-major` as the only MAJOR mover,
  fail-closed `--declared-version`, the `AppleVersion.current` and CHANGELOG renderings into a
  caller-named scratch directory, the constant == changelog == tag drift gate, a value-free
  report that never carries the version) with `Tests/automation` coverage; then continue with
  the remaining §18 steps and the launch specification; the write-capable half only after the
  §15 preconditions hold.
- **Filed:** 2026-09-22 · **Category:** roadmap sequencing (D26 follow-on)

**Why it needed you.** The alternative — authoring the write-capable publisher now — would
have meant redesigning the guard tests or parking untestable workflow files.

**Blocking?** No.

---
## D28 — Remaining pre-launch tooling order: workflow scan, then site assembly

- **Status:** **ANSWERED 2026-09-22: steps 17 then 16.**
- **Finding that framed the question.** With the read-only release-preparation rehearsal in
  place (D27), two design items remained that need no operator grant: the §18 step 17 static
  workflow scan and the step 16 site-assembly rehearsal. `Tests/automation/test_action_pins.py`
  already refused the worst shapes (`workflow_dispatch`, write permissions, environments, Pages
  actions, release and tag commands, `github.token`) by text search; step 17 asks for the check
  to run on parsed YAML, to require an explicit `permissions` block on every workflow and job,
  and to pin each required check's recorded trigger set and the `pull_request_target` invariants.
- **Ruling.** Build the scanner first — `scripts/ci/workflow_policy.py`, a dependency-free
  block-YAML subset parser plus the step 17 checks, run by the `Supply-chain policy` job and
  covered by `Tests/automation/test_workflow_policy.py` — so that the step 16 job, and every
  later workflow change, is admitted through it; then the site-assembly rehearsal (Pages stays
  disabled) as a separate reviewed commit. The recorded trigger set names today's
  `metadata / required` check and moves to `governance / required` when step 5's fold lands.
  Settings and API read-backs of step 17 stay pending as value-free expected sets.
- **Filed:** 2026-09-22 · **Category:** roadmap sequencing (D27 follow-on)

**Why it needed you.** Both orders are defensible; the scan-first order means the site job is
born under the guard rather than grandfathered past it.

**Blocking?** No.

**Amendment (2026-09-25).** Step 5's fold landed on this date, so the recorded trigger set
now names `governance / required`; the check still runs only the metadata validator
(readiness evidence rows 5 and 17, design §10.5 amendment of this date).

---

## D29 — Design §16 archive route amended to `/versions/`

- **Status:** **ANSWERED 2026-09-23: amend to `/versions/`.**
- **Finding that framed the question.** Design §16 placed the prior-series archive index at
  `/version/` and each archive at `/version/MAJOR.MINOR/`. The manual generator renders one
  page per command, and `apple version` renders to `/version/` exactly. The first local run
  of the step 16 assembler (`scripts/ci/site_assembly.py`) found the collision: the archive
  index would overwrite or shadow a command page, a route the design never classified, so the
  assembler refuses it and the rehearsal could not pass on the real tree.
- **Options considered.** (A) amend the design's archive root to the plural `versions`; (B)
  keep `/version/` and special-case the `apple version` page path in the generator; (C) nest
  the archives under the command page. (B) breaks the one-page-per-command scheme for one
  command; (C) shares a MkDocs-regenerated directory between a page and the archive.
- **Ruling.** (A). Routes are `/versions/` and `/versions/MAJOR.MINOR/`; the manifest stays
  `/version-manifest.json`; selection rules are unchanged; the assembler's default archive
  root is `versions` and its collision refusal stays in force for any future command name.
- **Filed:** 2026-09-23 · **Category:** design amendment (public route)

**Why it needed you.** A public route is an outward-facing contract; moving it later breaks
links and the manifest.

**Blocking?** No.

---

## D30 — Author `.github/CODEOWNERS` now, under the D15 exception

- **Status:** **ANSWERED 2026-09-24: A — record the go-ahead and author it.**
- **Finding that framed the question.** The design §18 step 17 API read-backs (recorded
  2026-09-24) found `.github/CODEOWNERS` absent and the code-owners errors endpoint answering
  404, so that read-back is NOT SATISFIED, and the design's step 5, step 8, step 11, step 17 and
  step 20 items all wait on the file. The design's step 5 text says the file may be authored only once the
  operator has recorded the extension of the attribution exception to it.
- **Correction recorded here.** The controller's brief that asked this question (2026-09-24)
  presented that extension as not yet recorded. It was: D15 (RATIFIED 2026-09-07) already extends
  the exception to
  `.github/CODEOWNERS` and fixes the landing sequence. The evidence file's two sentences that
  called the step "gated on a not-yet-recorded operator decision" were wrong on the same point
  and are corrected in the commit that records this entry. No recorded verdict changes:
  `.github/CODEOWNERS` was and is absent, so step 17's NOT SATISFIED stands; only the stated reason for its absence was wrong.
  D30 changes no policy: it is the operator's go-ahead to execute D15 now rather than after the
  launch specification, with one addition to D15's sequence named in the Ruling.
- **Options considered.** (A) author CODEOWNERS now under D15, in the D15 sequence; (B) hold
  until the launch specification exists.
- **Ruling.** (A). Sequence as fixed by D15, with the one addition noted in (2): (1) the
  `AGENTS.md` extension lands in its own reviewed commit (the commit recording this entry);
  (2) `.github/CODEOWNERS` lands second, naming the operator's GitHub user as code owner of every
  enforcement-control-plane path of design §10.5, with a fresh privacy scan of that commit. One
  addition beyond D15's three steps: that same commit carries the committed control-plane
  manifest the path list is checked against, because §10.5 resolves owner coverage against the
  manifest and step 17's coverage read-back has nothing to check without it. D15 did not name the
  manifest; this is the only respect in which D30 goes beyond it. The manifest arrives with its
  checker, `Tests/automation/test_control_plane.py` (itself in the plane under the
  `Tests/automation/**` deny-by-default tree), since a manifest the path list is checked against
  is inert without one; that test is part of this addition, not a further one; (3) the code-owners errors API
  is read back as part of the step 17 set once the file is on `main`. Still open from step 5 and
  not scheduled by this entry: the urgent-fix runbook under `docs/runbooks/` and its `AGENTS.md`
  policy exception (the release-freeze sentence that says an operator instruction alone lifts the
  freeze predates the publisher's removal and is corrected when that runbook lands).
- **Trade-off this activates (recorded in D15, restated here because the go-ahead makes it
  current).** From this step until public launch no release can be cut: the legacy publisher is
  already removed, so the release freeze's urgent-fix clause is satisfiable only by a reviewed,
  operator-authorized, temporary restoration of a write-capable release workflow, recorded as an
  explicit exception and removed again afterwards. Control-plane changes merge only on the
  operator's code-owner approval or sole bypass once the `main` ruleset of step 20 is active.
- **Filed:** 2026-09-24 · **Category:** control-plane governance / timing under a standing ruling

**Why it needed you.** The timing of the first tracked occurrence of the handle beyond the
D15 set, and whether to wait for the launch specification, is the operator's call.

**Blocking?** No.

---

**Amended 2026-09-26:** the item this entry left open from step 5 has landed: the urgent-fix runbook `docs/runbooks/urgent-release.md`, its `AGENTS.md` policy exception, and the corrected release-freeze sentence, in one reviewed change. The workflow it restores builds and verifies only, and its one write is its own run's verification artifact; the tag and the Release stay the operator's, by hand. It cannot cut a release from current `main` until the operator decides how a release relates to the macOS 27 adoption (its step 2 names the options).

---

## D31 — Outside collaborators: remove one, keep one

- **Status:** **ANSWERED 2026-09-25: remove one, keep one.**
- **Finding that framed the question.** The step 17 API read-backs (2026-09-24) recorded three
  collaborators — admin 1, read 2 — of which outside collaborators 2. The design's stated
  collaborator expectations are narrower than "the operator alone": it requires the operator to
  be the only administrator and only environment reviewer, and the solo-model evidence claims
  require that no other write-capable actor exists; step 17 records counts and roles only. A read
  grant satisfies all three. The brief that asked this question stated the stricter reading ("the
  design expects the collaborator list to be you alone"); that reading was the controller's, not
  the design's, and is withdrawn here.
- **Options considered.** (A) remove both read grants; (B) keep both and record the reason;
  (C) defer to the rehearsal check-in (the D16 re-confirmation). The operator asked to see the two
  accounts (shown in-session only; never written to the repository) and ruled per account instead:
  remove one, keep one.
- **Ruling.** Remove one named account; keep the other. The controller removed it through the
  API (`DELETE` on the collaborator, HTTP 204, issued interactively on the operator's in-session
  instruction naming the account — the only mutating call in the step 17 set) and read the list
  back: collaborators 2 by count, roles admin 1 and read 1, of which outside collaborators 1. The
  remaining read grant meets every collaborator expectation the design states (not an
  administrator, not an environment reviewer, not write-capable), so it is recorded as a
  conforming state, not a deviation; what the operator declined was the controller's stricter
  reading, which is not a design requirement. The expected set is, from 2026-09-25 until the operator rules
  again, collaborators 2 by count, roles admin 1 and read 1, of which outside collaborators 1. No
  reason for keeping the second grant was recorded; the operator may add one. The removal records
  no finding about the account or its holder; it narrows the access surface to what the design's
  expectations require and no more. Identities stay out of the repository, so the expected set
  alone cannot distinguish the kept account from a substitute: a salted SHA-256 commitment over the
  kept account's numeric GitHub id (stable across login renames; prefix `63f2fa71001a79ca`) is
  recorded under a dedicated collaborator salt kept outside the repository — distinct from the
  run-ID and denylist salts, because run ids are public plaintexts — whose own SHA-256 commitment
  is `ebeae5033cdfe5a2`; a later read-back checks identity as well as count. On a user-owned
  repository `read` is the whole grant (no team or organisation path can widen it) and no
  environment exists to review, which is why the role string suffices today; re-checked when the
  `main` ruleset introduces bypass actors. D31 is re-opened if that grant becomes
  write-capable, if the account is ever named in CODEOWNERS, or when the step 20 `main` ruleset
  activates (collaborator status then interacts with bypass and required-review resolution).
- **Filed:** 2026-09-25 · **Category:** repository access / step 17 expected set

**Why it needed you.** Collaborator grants are yours to give and withdraw; the design can only
read them back.

**Blocking?** No.

---

## D32 — Repository merge method and Actions SHA-pinning settings

- **Status:** **ANSWERED 2026-09-25: apply all (option A).**
- **Finding that framed the question.** Design §18 step 7 asks for squash-only merging with the
  pull request's title and body as the squash commit's header and body, merge commits and rebase
  merges disabled; step 4 names the repository-level `sha_pinning_required` setting among the
  Actions settings. The step 17 read-backs (2026-09-24) found merge commits, squash and rebase
  all allowed, the squash title and body taken from the branch commits, and `sha_pinning_required`
  off (pinning enforced only by the committed `action_pins.py` policy and its tests).
- **Options considered.** (A) apply the five step-7 merge fields, the pinning switch, and
  `delete_branch_on_merge` now; (B) merge settings only, pinning later; (C) hold.
- **Ruling.** (A). Applied by the controller through the API at 2026-09-26T01:40Z — the evening
  of 2026-09-25 in the operator's local zone, the same day the answer was given — and read back
  the same minute: `allow_merge_commit` true → false; `allow_rebase_merge` true → false;
  `allow_squash_merge` true (kept); `squash_merge_commit_title` COMMIT_OR_PR_TITLE → PR_TITLE;
  `squash_merge_commit_message` COMMIT_MESSAGES → PR_BODY; `delete_branch_on_merge` false → true
  (housekeeping beyond design §18 step 7, offered and accepted as part of option A; not cosmetic:
  a squash merge discards the head's commits and this setting then deletes the proposal head ref
  at merge, before the step 18 evidence capture, so the rehearsal steps 9–14 capture their
  evidence — head SHA, check runs, review state — BEFORE each merge, step 12's normalisation
  record is taken from the squash commit itself and must not depend on the head ref surviving,
  or the setting is turned off for the rehearsal window); Actions `sha_pinning_required` false →
  true with `enabled` true and `allowed_actions` selected unchanged (HTTP 204); the
  selected-actions allowlist read back unchanged (GitHub-owned allowed, verified-creator not
  allowed, one pattern); `allow_auto_merge`, `allow_update_branch` and
  `web_commit_signoff_required` read back unchanged (all false). The calls were made interactively
  through the CLI, as D31's removal was; the `PATCH` sent exactly the six merge keys. All are
  reversible repository settings; nothing in the tree and no branch, tag or release was touched.
  Step 17's expected set is amended accordingly. Departure named: step 4 wants these settings read
  back before the first hosted run of step 6; the D17 visibility advance overtook that ordering,
  so every hosted run to date ran with the repository-level switch off and pinning enforced only
  by the committed `action_pins.py` policy — the switch is prospective and no earlier run is
  evidence of server-side enforcement. Ledger dates are the operator's local date and read-back
  timestamps are UTC throughout, which is why `Filed` and the applied timestamp name different
  calendar days here.
- **Filed:** 2026-09-25 · **Category:** repository settings / design §18 steps 4 and 7

**Why it needed you.** Repository settings are outward-facing state only the operator may
authorize changing; the design lists the values, the operator decides when.

**Blocking?** No for current work; it is a prerequisite for step 12 of the rehearsal
(squash-merge normalisation), which could not have run without it.

---

## D33 — Dependabot security settings and the Swift ecosystem (design §17)

- **Status:** **ANSWERED 2026-09-26: security on, keep Swift (option A).**
- **Finding that framed the question.** Design §17's "Before activation" list has four items:
  every third-party Action pinned to a full SHA (met); a committed `.github/actions-allowlist.json`
  replacing the list embedded in `scripts/ci/action_pins.py`, with trusted-base rejection of any
  unlisted `uses:` and of `docker://` (PENDING, readiness evidence row 4); `sha_pinning_required`
  on (D32); and the dependency graph, vulnerability alerts and security updates enabled. Read
  2026-09-26: the vulnerability-alerts endpoint answered 404 (off), automated security fixes
  reported `enabled` false. Separately, §17 enables SwiftPM updates only after an empirical Swift
  tools-version 6 update check succeeds during the post-visibility hosted rehearsals (§20 item 3),
  yet `.github/dependabot.yml` (since 2026-09-01) enables `github-actions`, `pip` and `swift`, all
  targeting `main`, and Dependabot version updates have run weekly since then for all three,
  ahead of §17's list. The Swift update job has succeeded every week but has never opened a pull
  request, so the §20 item 3 check is only half shown.
- **Options considered.** (A) turn on vulnerability alerts and security updates now, keep the
  Swift ecosystem on and record the deviation; (B) the same two switches, and remove the Swift
  ecosystem until its check passes; (C) change nothing until ruleset activation.
- **Ruling.** (A). Applied by the controller through the API at 2026-09-26T20:03Z and read back
  the same minute: vulnerability alerts off → on (`PUT` 204; the read-back `GET` answers 204,
  meaning enabled); automated security fixes, which is Dependabot security updates read through a
  second endpoint, `enabled` false → true and `paused` false, reported enabled in
  `security_and_analysis` too; the Dependabot alerts listing answers with zero open alerts. The
  dependency graph's SBOM export answered 500 at that read-back; a re-read at 2026-09-27T01:43Z
  answered 200 with 36 packages (29 pip, 5 GitHub Actions, 1 npm, and the repository itself) and
  no Swift package, so the alerts and security updates cover the three workflows' Actions, the
  documentation toolchain's `docs/requirements.txt` and a test fixture's npm manifest
  (`Tests/NotesKitTests/fixtures/notes-markdown-oracle/package.json`, neither in §17's list nor
  configured in `.github/dependabot.yml`), but not the product's SwiftPM dependency. Enabling
  alerts also registered a GitHub-managed "Dependency Graph" workflow outside `.github/workflows/`
  (first run 20:03Z); its job token, like that of the "Dependabot Updates" workflow, carries only
  contents, metadata and packages read, with no secrets (read from each workflow's job log), while
  Dependabot's branches and pull requests are created by Dependabot's own GitHub App identity, not
  that token. Both workflows run a GitHub-owned action at the floating ref `@main`, admitted by
  the selected-actions policy's GitHub-owned allowance; the Dependency Graph run fetched it at
  20:03Z, after D32 had turned `sha_pinning_required` on at 01:40Z, so that requirement did not
  stop it. Both switches are reversible repository settings; nothing in the tree and no branch,
  tag or release was touched. Departures named: the Swift ecosystem stays on ahead of §17's order,
  and the controller intends to settle §20 item 3 during the step 13 hosted Dependabot rehearsal;
  with the single Swift dependency current, showing a Swift 6 update there may need a deliberately
  down-pinned disposable branch; §17's read-only freshness fallback applies only if native Swift 6
  updates fail empirically. Because `target-branch` names the default branch, GitHub documents
  that each configured ecosystem's commit-message pattern also governs its security-update pull
  requests; that stops holding once step 13 points `target-branch` at the disposable ref. It does
  not reach the unconfigured npm fixture, whose security-update pull requests would carry
  Dependabot's default title. Until governance / required has a Dependabot path, a Dependabot pull
  request fails its title/body check, which binds no merge while no ruleset exists.
- **Filed:** 2026-09-26 · **Category:** repository settings / design §17

**Why it needed you.** Repository settings are outward-facing state only the operator may
authorize changing, and keeping Swift on is a deviation from the design's stated order.

**Blocking?** No. §17's list precedes Dependabot activation; the design does not say whether
that means step 13's governed activation or the step 20 ruleset, and the controller reads it as
gating both.

---

## D34 — The end-of-roadmap privacy gate and the publisher (design §15): delete the `v26.0.0` draft Release

- **Status:** **ANSWERED 2026-09-26: delete the draft (option A); APPLIED 2026-09-27T01:32Z.**
- **Finding that framed the question.** The readiness evidence (§2, Round 2 verdict and the
  rehearsal note) closed the end-of-roadmap privacy gate only on a scan of the PUBLISHED rebuilt
  asset, which needs the phase-3 publisher (D18 step 4a). Design §15 adds the bot identity,
  listener, write-capable publisher, tag rulesets and protected environment together at launch,
  with a closed privacy gate among its three hard preconditions, and `AGENTS.md` bars adding the
  publisher until all three hold. As written, the gate could never close. The reason it named
  the rebuilt asset: the `v26.0.0` draft Release's archive still carried the build paths Round 1
  flagged (R1-F1), and D17 ruling 2 chose rebuild and re-cut over acceptance. D18 left open
  whether the draft stays or is deleted.
- **Options considered.** (A) delete the `v26.0.0` draft Release and its two assets, keep the tag,
  and close the gate on the then-current surfaces; (B) keep the draft and amend the closure
  condition to current surfaces plus the D23/D24 rebuild-rehearsal scan; (C) amend §15 so
  publisher credentials may exist before the gate closes.
- **Ruling.** (A). Before deleting, the controller read the Release back (draft true, prerelease
  false, tag `v26.0.0`, 2 assets, recorded by name and size only) and kept a private copy of the
  two assets outside the repository, the archive verified against its published checksum. The
  Release object was then deleted through the API at 2026-09-27T01:32Z (the evening of 2026-09-26
  in the operator's local zone): `DELETE` 204; the Release id then answers 404; the repository
  lists zero Releases; both assets' public download URLs answered 404 when read at 04:16Z; the
  `v26.0.0` tag is kept on `origin` and still peels to `0f617eb`. Asset ids were not captured
  before deletion, so no asset was read back by id; removal rests on GitHub deleting a Release's
  assets with it and on those download reads. **The gate will close** when a fresh round records
  zero findings for its stated scope, before the launch that adds the publisher, so design §15's
  order stands. That round has not run. Its scope is at least every surface Round 1 and its
  addendum scanned (among them pull-request text and timelines, issue events and comments, and
  commit comments), plus the tree, history, commit messages, objects, refs, workflow logs and
  artifacts, workflow-run, check-suite and check-run objects (head branch, head-commit message and
  author, display title, annotations and job summaries, not only their logs), Actions caches,
  repository metadata and Releases; a surface it cannot read is recorded NOT READ, not clean, and
  a NOT READ surface inside that minimum keeps the gate open until it is read or the operator
  rules on it in this ledger. **The rebuilt `v27.0.0` asset leaves that round's scope and keeps
  the full check the old condition gave it.** Before publication, the exact artifact to be
  published must pass both D18 step (4)'s verified-outcome check as that step states it (no
  `N_OSO` entry and no home-directory path anywhere in the binary's bytes; archive member headers
  with user and group ids of 0 and empty owner and group names; no AppleDouble member) and a
  value-free scan under the round's classes and denylist. That scan covers the binary, the
  archive, the checksum file and the Release notes body. Both results are recorded in the evidence
  file before publication. The denylist scan stays operator-local, never inside a hosted
  environment, and is recorded value-free against the sha256 digest of each item it covers (the
  archive, the binary, the checksum file, and the Release notes body exactly as it will be
  published). The §15.1 read-only preflight lists neither check today; the controller will propose
  that the launch specification add step (4) and a check that a passing scan record matches all
  four digests. This entry requires both checks until an approved launch specification adds them,
  and continues to require them if it does not. Irreversible on GitHub: the `v26.0.0` archive and
  checksum file survive byte-for-byte only in the private copy. The Release notes body was not
  preserved; its nearest source is the CHANGELOG section at `0f617eb`, which may differ from the
  published body (D2 records a manual re-create after a notes-length rejection). A rebuild from
  the tag would be a different artifact.
- **Filed:** 2026-09-26 · **Category:** irreversible / outward-facing; privacy gate

**Why it needed you.** Deleting a Release is irreversible and outward-facing, and the choice
between deleting, accepting a carrier and weakening §15 is a posture call.

**Blocking?** It unblocked the end-of-roadmap audit's closure path; nothing else waits on it.

---

## D35 — Claude session links in eight historical commit messages: accept as a recorded class

- **Status:** **RATIFIED 2026-09-26: accept as a recorded class (option A).**
- **Finding that framed the question.** Eight commit messages on `main`, dated 2026-09-07 to
  2026-09-14, end with a `Claude-Session` line carrying a claude.ai coding-session link. The links
  name two distinct sessions, both the operator's. The tracked tree carries none. The repository
  bans account identifiers in commit messages, so the fresh end-of-roadmap round (D34) would
  detect them. A session link opens only for the signed-in account that owns it: what is public is
  an opaque session identifier, not the session's content. Removing the lines needs a history
  rewrite. That would change the id of every commit from the first of them to the tip (76 through
  `8ba43b1` when the question was framed), including every commit this ledger and the readiness
  evidence cite. It would still not remove them from GitHub: five of the six pull-request refs
  contain some of them, and only a GitHub Support purge could clear them.
- **Options considered.** (A) accept the eight historical lines as a recorded class, and keep
  refusing new ones; (B) rewrite history to drop them, force-push, file a Support purge and
  re-cite every changed commit id; (C) defer to the fresh round.
- **Ruling.** (A). The fresh end-of-roadmap round records this class as ACCEPTED, not as a
  finding, in the same shape as D20. The class is scoped exactly: the `Claude-Session` lines, and
  the same two links, in the commit messages of those eight commits, wherever those commit objects
  are served. The copies of those same messages that GitHub stores on the workflow-run and
  check-suite objects for those commits are not covered by this ruling as asked; the fresh round
  dispositions them, as it does D36's surfaces found after that ruling. It covers no other surface
  and no later commit. Any occurrence elsewhere is a finding: a new commit, the tree,
  repository-side text, a Release. The controller's pre-push scan refuses the class in every
  pushed diff and commit message, and the controller omits the session trailer its harness
  suggests for commits. This entry authorizes no history rewrite.
- **Filed:** 2026-09-26 · **Category:** privacy disposition / public history

**Why it needed you.** Whether an identifier stays in public history, or history is rewritten, is
yours alone to decide (D9 precedent).

**Blocking?** No; it settles one class before the fresh round runs.

---

## D36 — The outside contributor's own Claude session link in the descriptions of PRs 3–5: accept

- **Status:** **RATIFIED 2026-09-26: accept as the contributor's own disclosure (option A).**
- **Finding that framed the question.** The descriptions of pull requests 3, 4 and 5 each contain
  a claude.ai coding-session link. All three name one session, which is not one of the operator's;
  it is the outside contributor's own. When those pull requests were squash-merged, the link was
  stripped from the squash commit messages on `main` (readiness evidence §4, "Outside pull
  requests 3–5"), so it is in no tracked file and no commit on `main`. The review of this record
  found, after the operator ruled, that it also sits in two of the five commit messages on pull
  request 3's own branch, served through that pull request's ref, commit list and timeline and by
  id, and in copies of the descriptions embedded in nine comment events in the public Events feed;
  the ruling below does not cover those, and the fresh round dispositions them. D20 accepts the
  contributor's own git author identity, but not this identifier. Editing a contributor's
  pull-request text is outward-facing, and GitHub keeps the prior text in each description's edit
  history unless that revision is deleted too.
- **Options considered.** (A) accept it as the contributor's own disclosure, scoped to those three
  descriptions; (B) edit the descriptions and delete the prior revisions; (C) ask the contributor
  to remove it.
- **Ruling.** (A). The fresh end-of-roadmap round records this class as ACCEPTED, not as a
  finding. The class is scoped exactly: that one link in the descriptions, and their edit
  histories, of pull requests 3, 4 and 5. The identifier is never copied into a tracked file, a
  commit message or project prose. The same link on any other surface, or another contributor's
  link, is a finding for the round to disposition.
- **Filed:** 2026-09-26 · **Category:** privacy disposition / third-party text

**Why it needed you.** It concerns a third party's text on a public surface, and the choice
between leaving it and editing someone else's words is a posture call.

**Blocking?** No; it settles one class before the fresh round runs.

---

## D37 — Workflow-run objects served pre-rewrite commit messages: delete every run whose head commit is not on `main`

- **Status:** **ANSWERED 2026-09-27: delete all off-main runs (option A); APPLIED
  2026-09-27T04:43Z.**
- **Finding that framed the question.** The D34 security reviewer found a public surface neither
  privacy round had scanned: every Actions run stores its head commit's message and its head
  branch, and on a public repository anyone can page the run listing without knowing a commit id.
  The controller scanned that surface with both engines, the full class set and the denylist. Of
  373 runs, 168 ran on commits no longer on `main` (pre-rewrite history, retired branches,
  pull-request heads). One of those, from 2026-07-23, carried a pre-rewrite commit message with
  two denylist terms, a provider mailbox and two personal email addresses. A further 90 carried
  tracker identifiers (18 of them in branch names, a count matching the 18 runs whose logs D21
  deleted) or Claude session links (three distinct sessions: the contributor's of D36, and two of
  the operator's that D35 does not cover, in July and August pre-rewrite messages). The phone and
  coordinate detections were a number in the fictional 555 area code, an RFC-reserved placeholder
  and a ratio list. None of the 168 runs is cited in the readiness evidence. The deleted set
  included the legacy 2026-08-30 Release run that cut `v26.0.0`, whose head commit was rewritten
  off `main`. The underlying pre-rewrite commits stay fetchable by id; the run listing was one
  public surface that listed their ids.
- **Options considered.** (A) delete all 168 off-main runs; (B) delete only the 91 carrying a
  detection; (C) delete only the run carrying personal data.
- **Ruling.** (A). Before deleting, the controller re-read the listing and confirmed that the set
  of off-main runs was exactly the 168 approved. It kept a private manifest outside the
  repository, then deleted each run through the API, re-checking before each call that its head
  commit was not on `main`: 168 `DELETE` calls, each answering 204. Read back: 205 runs listed,
  none off-main, and each deleted id answers 404. A re-scan of the remaining listing under the
  same classes and denylist found no personal data, no denylist term and no tracker identifier.
  What remains mirrors commit messages already on `main`: AI co-author addresses, the path
  literals Round 2 recorded, copies of the eight D35 messages (for the fresh round to disposition,
  see D35), and a Unix group-id false positive. The 205 runs on `main` commits, which the hosted
  evidence cites, are untouched. Irreversible: the 168 runs and their logs are gone. The ruling
  reached workflow runs only. It removed the listing, not the commits: the personal-data commit
  stays fetchable by id (D38), at least 29 off-main commit ids stay listed in the public Events
  feed (21 through push events dated 2026-08-29 to 2026-09-08, 20 of them deleted-run heads, and 8
  more, all deleted-run heads, only through pull-request and review events dated 2026-09-07 to
  2026-09-14) until they age out, about 2026-12-13 at the latest under GitHub's 90-day window and
  sooner if the feed's 300-event cap displaces them (the feed lists these commits by id only, not
  their messages; of the 21 push-listed commits' messages, served by id, nine carry tracker
  identifiers, and those messages' email detections are AI co-author addresses and Dependabot's
  sign-off address); and check-suite objects, which are not Actions runs, survive. A third-party
  GitHub App (Cursor) left a check suite on 129 of the 135 distinct head commits of the deleted
  runs, three of them the head commits of the closed Dependabot pull requests 1, 2 and 6, and the
  personal-data commit among them, each keeping a copy of its commit message by commit id. The
  fresh round reads all of these (D34 names run and check-suite objects; the readiness evidence §2
  lists the Events feed, added with this record); the App is also a lead for the installed-App
  read-back that readiness row 17 records as not performed.
- **Filed:** 2026-09-27 · **Category:** irreversible / outward-facing; privacy incident on a
  GitHub-side surface

**Why it needed you.** Deleting workflow runs is irreversible and outward-facing, and choosing how
much history to drop is a posture call.

**Blocking?** No. It removed the public listing before the fresh round runs, and that round now
scans run and check-suite objects (D34) and the Events feed (readiness evidence §2); the carriers
left by id are D38's and the round's.

---

## D38 — A pre-rewrite commit with personal data stays fetchable by id: accept under an amended D19

- **Status:** **RATIFIED 2026-09-28: accept under D19 (option C), re-confirmed the same day on
  corrected facts.**
- **Finding that framed the question.** D37 deleted the run that pointed at the 2026-07-23
  pre-rewrite commit, but not the commit: GitHub still serves it to anyone who asks for its exact
  id (HTTP 200 when read on 2026-09-28), and its message still carries two denylist terms, a
  provider mailbox and two personal email addresses. It was public from its push on 2026-07-23
  until the repository was made private on 2026-08-19 (the D9 period), and from the 2026-09-21
  visibility flip until the D37 deletion on 2026-09-27 the run listing served its full message and
  its id to anyone paging it, with no id needed. A third-party check suite keeps a copy of the
  same message by commit id. D19 accepted by-id reachability of pre-rewrite objects, the D9
  personal-data commits included, on the premises that their ids were retained nowhere this
  project controls and every published surface was clean or operator-dispositioned; neither held
  for this commit during the six days from 2026-09-21 to 2026-09-27. Only GitHub Support can purge
  such objects. The first brief for this question gave only that six-day window, leaving out the
  2026-07-23 to 2026-08-19 public period, and misstated D19's premise as no personal data; the
  operator re-confirmed the ruling on the corrected facts before this record landed.
- **Options considered.** (A) the operator files a Support purge of all unreachable objects; (B)
  the operator files a targeted purge of this one commit; (C) accept it under an amended D19.
- **Ruling.** (C). The commit stays fetchable by id and is accepted as a recorded residual under
  D19, scoped exactly to that one commit object and the stored copies of its message by commit id.
  The fresh round records it as ACCEPTED, not as a finding, with both exposure windows above
  stated. Any other object found carrying personal data is a finding. No Support request was
  filed; the operator may still file one later, and this entry does not prevent it.
- **Filed:** 2026-09-28 · **Category:** privacy disposition / residual on a GitHub-side surface

**Why it needed you.** Leaving personal data retrievable, or contacting GitHub Support to remove
it, is yours alone to decide (D9, D19).

**Blocking?** No; it settles one residual before the fresh round runs.

**Amended 2026-10-07 (D47):** this commit is one of the 128 the public Activity view has listed since the 2026-09-21 visibility change, an exposure window not recorded above, and a second commit message carrying a denylist term is reachable through the listed commits' parents. Both, with every other object reachable from the 128 listed commits that no advertised ref holds (D47's 1,550 commits and their objects), now sit inside D47's accepted residual. Anything the round's classes detect in a commit outside the two pinned lists, or in an object no listed commit reaches, is outside this residual and stays a finding unless another entry accepts it, whenever the view lists it or however it is found.

---

## D39 — How APPLE_MAIL_MCP_HOME reads a tilde: as the retired Mail MCP read it

- **Status:** **SUPERSEDED 2026-09-30 by D40** (was RATIFIED 2026-09-30: read it as the retired
  Mail MCP did (option A); APPLIED 2026-09-30 in the commit that recorded this entry).
- **Context.** Bringing four operator-supplied paths under the shared tilde policy
  (`TildeSpelling`), the controller's first version also refused another account's `~name/…` in
  `APPLE_MAIL_MCP_HOME`, the Mail template root. The critic's read of oracle A (apple-mail-mcp
  0.6.0, `templates.py`: `base = Path(home_override) if home_override else Path.home() /
  ".apple_mail_mcp"`) showed that the oracle never expanded a tilde there: `~alice/tpl`, `~/tpl`
  and a bare `~` each named a folder literally so called, under the working directory, and an
  empty value counted as unset. Refusing a spelling the oracle accepted is the D12/D22 class, so
  the controller asked before landing it. Before this ruling the CLI's reading depended on the
  macOS release: `~/…` meant the home folder on macOS 26 and 27; another account's `~name/…`
  became the running user's home on macOS 26 and a folder under the working directory on macOS
  15 and 27; an empty value named the working directory. (macOS 27 was observed directly; macOS
  26 and 15 are inferred from Foundation behaviour observed on those releases, recorded in the
  hosted-CI learnings.)
- **Options considered.** (A) read the value as the oracle did; (B) the shared tilde policy
  (refuse another account's `~name/…`, expand `~` and `~/…` to the home folder), recorded as a
  narrowing; (C) leave it unchanged and hold this surface open.
- **Ruling.** (A). No tilde expansion: a relative value, `~`, `~/…` and `~name/…` included,
  names a folder under the working directory on every macOS release, and an empty value means
  unset. Scope: the VALUE of `APPLE_MAIL_MCP_HOME` only. The default location when the variable
  is unset is unchanged (the account's home directory, where the oracle's `Path.home()` followed
  `$HOME`; a pre-existing difference this ruling does not address). The other three surfaces of
  the same change (`contacts … --file`, `APPLE_SEND_RATELIMIT_STATE`,
  `APPLE_REPLY_RATELIMIT_STATE`) have no oracle counterpart, follow the shared policy, and were
  not part of this question.
- **Applied (2026-09-30).** `TemplateStore.init` joins a relative value to the working directory
  before Foundation sees it and treats an empty value as unset; `TemplateStoreTests` pins the
  exact path for every spelling above. Recorded in CHANGELOG `[Unreleased]` as BREAKING with
  `schema_version` unchanged.
- **Filed:** 2026-09-30 · **Category:** parity vs consistency (D12 class)

**Why it needed you.** Both non-oracle options drop or reinterpret a spelling the retired oracle
accepted on a shipped surface, the class D12 reserves to you.

**Blocking?** No; it settled the one surface of the tilde change that had an oracle counterpart.

**Resolution (2026-09-30):** superseded by D40 the same day. `APPLE_MAIL_MCP_HOME` is no longer
read, so the reading ruled here no longer applies; this entry stands as the record of it.

---

## D40 — The two public names that still say "mcp": rename both outright

- **Status:** **RATIFIED 2026-09-30: rename both outright (option A).** Applied by the commit
  that records this entry.
- **Context.** On 2026-09-30 the operator asked that the CLI's code stop mentioning MCP,
  comments included. Two mentions are public names that callers depend on: the
  `APPLE_MAIL_MCP_HOME` environment variable and the default template folder
  `~/.apple_mail_mcp/templates/`, both oracle A's own names (so the CLI and oracle A shared one
  template store). Renaming either one breaks existing configurations or hides saved templates
  until they are moved, and dropping oracle A's variable and folder is the D12 class, so the
  controller asked. The release freeze keeps the CLI at `v26.0.0`, so few installs exist.
- **Options considered.** (A) rename both outright; (B) rename both but keep reading the old
  names while the new ones are absent, with a stderr notice, until a later ruling ends the
  transition; (C) keep both names as the only recorded MCP mentions.
- **Ruling.** (A). `APPLE_MAIL_TEMPLATES_DIR` names the template folder itself and follows the
  shared tilde policy (another account's `~name`, or a tilde with a combining mark, refused as a
  `validation_error`; `~`, `~/…` and the account's own `~name/…` expand to its home; an empty
  value counts as unset). The default folder is `~/.apple-cli/mail-templates/`. Neither
  `APPLE_MAIL_MCP_HOME` nor `~/.apple_mail_mcp/` is read any more. This is a recorded narrowing
  of the retired Mail oracle: the CLI no longer shares oracle A's template store or honours its
  variable; the on-disk template format is unchanged. D39, which governed how
  `APPLE_MAIL_MCP_HOME` read a tilde, lapses with the variable (its entry stands as the record).
- **Applied (2026-09-30).** `TemplateStore.init` reads the new variable and default; every
  `mail templates` command, `save --dry-run` and `render --message-id` included, refuses a
  refused spelling before any store or Mail access. The deviation is recorded in
  `docs/port-specs/mail.md`, the hosted and local Bats templates use the new variable (both
  inventory digests and the trusted hosted pin updated), and CHANGELOG `[Unreleased]` records it
  as BREAKING with `schema_version` unchanged and the move command.
- **Filed:** 2026-09-30 · **Category:** parity vs cleanup (D12 class)

**Why it needed you.** It drops oracle A's variable and folder, a narrowing on a shipped
surface, and it breaks existing setups.

**Blocking?** No; it settles the one part of the MCP cleanup that is caller-visible.

---

## D41 — Two message texts and a search term from a live oracle run in a Messages test: redact at HEAD, accept history

- **Status:** **RATIFIED 2026-09-30: redact at HEAD, accept history (option A).** The redaction is
  applied by the commit that records this entry.
- **Finding.** While rewording test comments on 2026-09-30, the controller found that the WRatio
  tests in `Tests/MessagesKitTests/MessagesKitTests.swift` pinned two message texts, and used as
  their query a search term, that a comment attributed to a live oracle run: the texts were results
  the Messages oracle returned from the operator's real store, and the term was also part of one
  test's name. They were committed on 2026-07-15 in `23c9afc` (the original Messages port) and were
  public from its first push until the 2026-08-19 containment (D9), and publicly in the default
  branch's tree from the 2026-09-21 visibility change (D17) until this commit. They are the class
  of the D9 fixture in `PartialRatioParityTests.swift` (text taken from a live store into a
  fixture); neither the D9 passes nor any later audit round had recorded them. The operator
  confirmed that they are real. The values are not repeated in this file or in any commit message.
- **Options considered.** (A) replace them at HEAD and accept history as a recorded residual; (B)
  replace them at HEAD and remove them from history with a targeted rewrite and force-push (which
  reaches neither forks, existing clones nor GitHub's stored objects); (C) record them as synthetic
  if the operator did not recognise them.
- **Ruling.** (A). The test now uses a placeholder query and invented texts. The replacements keep
  its property: the oracle's WRatio (thefuzz 0.22.1) scores the two borderline texts 68 and 72 and
  the unrelated control 36, and the port passes the same assertions, with the two borderline scores
  now pinned exactly. History keeps the originals as an accepted residual, scoped to every version
  of that one test file that carries them (including any pre-rewrite version GitHub serves by
  commit id) and to the removed side of this commit's own diff; no history rewrite. The fresh
  privacy round records them as ACCEPTED, not as a finding, and still reads the test tree for other
  samples of the class (text taken from a live store into a fixture). Any other such sample is a
  finding.
- **Filed:** 2026-09-30 · **Category:** privacy disposition / residual in history

**Why it needed you.** Leaving personal data in public history, or rewriting that history, is yours
alone to decide (D9, D19, D38).

**Blocking?** No; the HEAD redaction does not wait on it.

---

## D42 — A note fragment from a live run in a Notes test: redact at HEAD, accept history

- **Status:** **RATIFIED 2026-09-30: redact at HEAD, accept history (option A).** The redaction is
  applied by the commit that records this entry.
- **Finding.** The independent review of D41's redaction found a second sample of the class D41
  names. The NOTES-L1 test in `Tests/NotesKitTests/NotesTextTests.swift` quoted a three-word
  fragment of one of the operator's real notes, in its doc comment and in an assertion (four
  lines, the fragment in its original, decoded and corrupted forms). The comment said it was
  measured in a real note on 2026-08-19. It was committed that day in `50c30f0`, the day the
  repository was made private (D9); whether it reached GitHub before that day's containment is not
  established, and if it did, it was also public for part of that day. It has been public in the
  default branch's tree since the 2026-09-21 visibility change (D17). It is in no commit message.
  The value is not repeated in this file or in any commit message.
- **Options considered.** (A) replace it at HEAD and accept history as a recorded residual; (B)
  replace it at HEAD and remove it from history with a targeted rewrite and force-push (which
  reaches neither forks, existing clones nor GitHub's stored objects); (C) record it as not
  personal data, had the operator identified the note as test data.
- **Ruling.** (A). The assertion now uses invented words and the comment no longer quotes the
  note; the behaviour the test pins (an unterminated `&amp ` mid-sentence decodes to `& `, as the
  oracle's DOM does) does not depend on the words. History keeps the original as an accepted
  residual, scoped to every version of that one test file that carries it (including any
  pre-rewrite version GitHub serves by commit id) and to the removed side of this commit's own
  diff; no history rewrite. The fresh privacy round records it as ACCEPTED, not as a finding. Any
  other such sample is still a finding.
- **Filed:** 2026-09-30 · **Category:** privacy disposition / residual in history

**Why it needed you.** Leaving personal data in public history, or rewriting that history, is yours
alone to decide (D9, D19, D38, D41).

**Blocking?** No; the HEAD redaction does not wait on it.

---

## D43 — CI job logs print the removed Messages test's name, which carried D41's search term: leave the logs to expire

- **Status:** **RATIFIED 2026-09-30: leave the logs to expire (option A), re-confirmed on corrected
  facts.** Nothing is applied; the copies age out on their own.
- **Finding.** The critic lane of D41's review noticed that the removed test's name contained the
  search term D41 redacts, and hosted `build-test` job logs print every test name. A value-free
  scan of the job logs of every retained CI run (2026-09-30, 18:09 to 18:31Z: 104 runs and 589
  jobs, whose 322 logs were all retrieved; counts only, no value printed) searched each log for the
  old test name, the term, both message texts and the note fragment's original, decoded and
  corrupted forms. It found the name in 61 job logs across 57 runs, from 2026-09-01 to 2026-09-30,
  on two lines of each, and the term nowhere outside those lines; none of the texts and none of the
  fragment's forms appeared in any log. The other 267 jobs never started (no steps; failed or
  skipped), so they have no log. Docs, Governance and dependency-update runs were not scanned: none
  of them runs the test suite.
- **Correction before ratification.** The operator first approved this row with 60 logs, from an
  earlier scan that searched only the name and the term and ran while one run's third attempt was
  finishing; that attempt's log carries the name too. The rescan above corrected the count and
  tested the texts directly, and the operator re-confirmed the ruling on those facts the same day,
  as D38 was re-confirmed.
- **Options considered.** (A) leave the logs to expire under GitHub's 90-day log retention; (B)
  delete the 57 runs' log archives through the API and read them back, as D21 did, which would also
  remove the runner-image facts the readiness evidence (Section 4) read from some of those logs.
- **Ruling.** (A). D41 already keeps the term in public git history for good, so deleting the logs
  would remove only a temporary extra copy, at the cost of evidence. The copies are an accepted
  residual until retention removes them, the last about 2026-12-29. A later log can carry the name
  again: a re-run of a CI run made before D41's commit (GitHub allows re-runs for 30 days) or a
  pull-request run on a head that predates it (the open pull request 7's head does) prints the old
  test name with a fresh 90-day clock. Such logs fall under this ruling and push the date later;
  not re-running pre-D41 runs, and no new run on a pre-D41 pull-request head, keeps it. Runs on
  D41's commit and later print the new name. The fresh privacy round records these logs as
  ACCEPTED, not as a finding.
- **Filed:** 2026-09-30 · **Category:** privacy disposition / residual in workflow logs

**Why it needed you.** Deleting run logs is destructive and outward-facing (D21), and leaving
personal data public is yours alone to decide (D38, D41).

**Blocking?** No.

**Amended 2026-10-04 (one later copy, from a 2026-10-03 run):** as Dependabot closed pull request 7
on 2026-10-03, its edits started two CI runs on that pull request's pre-D41 head `af46d81` (D45's
resolution). The first (10:21:27Z) was cancelled before any Swift test ran, 57 seconds into its
hosted-quality step while it was still building (its Python policy tests had passed, printing no
test names); the second (10:22:30Z) ran the full Swift suite. A count-only check of all eleven job
logs the two runs left, which printed nothing, found the old name on two lines of the second run's
`build-test` log and in no other, the term nowhere outside those lines, and neither D41's message
texts nor D42's note fragment, as those commits removed them, in any of them. That log falls under
this ruling and moves the last copy's expiry to about 2027-01-01. Every other CI run since this
entry's scan, re-runs included, built a head that contains D41's commit. No pull request remains
open, but another copy could still come from a re-run of a CI run on a head that predates D41's
commit (the runs made before that commit until about 2026-10-30, and the two 2026-10-03 runs until
about 2026-11-02), from an edit of the title or body of a closed pull request whose head predates it
(pull requests 1 to 7 all do, and `ci.yml` runs on `edited` whether or not the pull request is
open), or from a new or reopened pull request whose head predates it.

---

## D44 — Narrow main-only reversal for a parallel session's worktree

- **Status:** **RATIFIED 2026-10-01: the narrow reversal (option A).** Ledger dates are the
  operator's local date (D32): the operator chose this option on 2026-10-01, shortly before the
  worktree and its local branch were created at 23:57 local (2026-10-02T03:57Z). The row as first
  drafted carried the UTC date 2026-10-02; its substance is unchanged. Unlike D16 and design §18
  step 8, the reversal was not recorded on `main` before the branch was cut: this entry's commit,
  made from the worktree, is the first landing under it.
- **Context.** The operator asked to run two agent sessions in parallel: one in the primary
  checkout, and one in a second local worktree working the supply-chain and governance queue. That
  queue is the Dependabot governance path, the CI readers' handling of non-ASCII whitespace, the
  committed Action allowlist, the release runbook's toolchain record and the launch
  specification (design §8, §10.5, §15, §17 and §18).
- **Options considered.** (A) This narrow reversal, with `AGENTS.md` unchanged. (B) A general
  relaxation letting any future parallel session work in its own worktree, with an `AGENTS.md`
  amendment. Not put to the operator: serial work in the primary checkout alone; a second clone on
  `main`; a detached-HEAD worktree; (A) with a one-line `AGENTS.md` pointer to this ledger.
- **Ruling.** (A), as the ledger row states: one local git worktree,
  `~/workspace/apple-cli-governance`, on the local branch `26/governance`, removed when that queue
  is done. Ordinary work otherwise stays main-only; D16 is unchanged.
- **Working rules.** Recorded by the two sessions to carry out the ruling. They only narrow it and
  are not part of the operator's ratified text; both sessions are bound by them, and only the
  operator may relax them.
  - Scope: only that queue's changes land from the worktree; product changes land from the primary
    checkout. The worktree grants nothing a session in the primary checkout lacks, and nothing
    toward D16: D16's disposable refs are never created from this branch.
  - Users: the agent session the operator assigns to that queue, or a successor the operator
    assigns after it ends, one at a time. The operator may also work there.
  - The branch has no upstream, and no ref of its name is ever pushed. It takes `main` only by
    rebase, so no merge commit is created in either direction. Its commits reach `main` only by
    `git push origin <gated commit ID>:refs/heads/main`, a fast-forward of the exact gated commit;
    never a push that names the branch, `--all`, `--mirror`, a force push or a tag.
  - Each change is first rebased onto the current `main`. The review, the personal-data scan and the
    full local canonical suite then run on that exact rebased commit. If `main` moves before the
    push, the change is rebased again and the scan and the suite re-run on the new commit. A rebase
    that changes the diff, a conflict resolved in this file included, is reviewed again. After each
    rebase, the ledger number, CHANGELOG `[Unreleased]` and the readiness-evidence tallies are
    re-checked. The session in the primary checkout follows the same rule, since `main` can now move
    under it too.
  - One landing at a time: a session pushes to `main` only after the latest push there, by either
    session, has finished its hosted CI and Docs runs. Both workflows cancel an in-progress `main`
    run when a new push arrives, so an overlapping push would leave the earlier commit without one.
  - The two sessions never overlap a local Bats run (a single file included) or the canonical
    suite. While either session runs Bats, the other runs nothing that opens Mail, Notes, Messages,
    Contacts, Calendar or Reminders. Each Bats file snapshots those six apps and quits the ones it
    launched, so overlapping runs race (`AGENTS.md`, Toolchain + testing), and timing-sensitive
    tests can flake under load. The sessions serialize these runs with one lock directory outside
    the repository, taken with `mkdir` before the run, with the session, purpose and start time
    written inside, and removed after it; a lock whose owner process is gone is removed only after
    that is confirmed, and the removal is reported.
  - The arrangement ends when the operator says the queue is done, or earlier on the operator's
    word. Commits not yet landed are then either landed under these rules or discarded on the
    operator's word. The worktree is removed with `git worktree remove` and the branch is deleted.
    The Status then flips to CLOSED with a dated `Resolution:` line naming the last commit landed
    from the worktree and the read-backs showing that `git worktree list` lists only the primary
    checkout, that `git branch --list 26/governance` is empty and that `origin` has no
    `26/governance` ref; the ledger row's status cell is updated to match. If the branch ever
    reaches `origin`, the session stops and reports it to the operator, and the remote ref is
    deleted only on the operator's go-ahead, then read back as absent and recorded here.
- **Why `AGENTS.md` is not amended.** Its "Main-only workflow" section lets the operator reverse
  the ruling explicitly, and this entry records that reversal. The operator chose (A), which leaves
  `AGENTS.md` unchanged. That departs from the practice D16 and design §18 step 8 set, where a
  reversal is recorded in `AGENTS.md` by a reviewed commit on `main` before the first branch exists.
  While the worktree exists, `AGENTS.md`'s statements that all work happens in the primary checkout
  and that the repository has exactly one branch do not describe the local repository. The second
  is already untrue on the remote, which holds Dependabot's head branches. For work in or alongside
  the worktree, this entry governs.
- **Filed:** 2026-10-01 (raised when the operator asked to run two agent sessions in parallel) ·
  **Category:** branch topology / parallel sessions

**Why it needed you.** The main-only ruling is yours and repo-local; only you can carve out an
exception.

**Blocking?** No. It records the authority under which the second session lands its work.

**Amended 2026-10-03 (the branch reached `origin`, and was deleted on the operator's word):** from
about 01:36Z to 01:43:34Z on 2026-10-04 (21:36 to 21:43 local on 2026-10-03), a subagent of the
worktree's session, briefed to read files only and only in a scratch copy outside the repository,
ran its commands in the worktree, the session's working directory, instead. It edited six CI scripts
and `CHANGELOG.md` there, staged everything and then unstaged everything, which also unstaged a
change the session had staged, and committed `8e6af13`, which held its own unreviewed edits to those
seven files and part of that change. At 01:43:34Z it ran `git push -u origin 26/governance`. No
Actions workflow ran on the branch, no pull request or tag was created, `main` stayed at `1cebd1f`,
and each session found the pushed diff and message clean under the personal-data pattern scan, the
pinned denylist scan and a Unicode-category scan. The worktree's session stopped its two running
workflows, held its landings and removed the branch's upstream. At 02:02:27Z it moved the local
branch back to `1cebd1f`, then returned the five scripts that held only the subagent's edits to
their `1cebd1f` content and staged its own change again, checked against its copy outside the
repository, with none of the subagent's edits in it. No edit of the subagent's is in the worktree's
files or index; unreviewed, they survive in a patch outside the repository and in `8e6af13` itself,
which the worktree's reflog still names. The worktree's session then reported to the operator
through the primary checkout's session. The operator ruled that the branch be deleted, to the
primary checkout's session at about 02:24Z and to the worktree's session at 02:26:55Z. The primary
checkout's session ran `git push origin --delete 26/governance` at 02:24:27Z, and
`git ls-remote --heads origin` read back only `refs/heads/main` at `1cebd1f`, at 02:24:32Z in that
session and at 02:27:29Z in the worktree's session. Like the commits D37 and D38 record, `8e6af13`
stays fetchable by its id, and a third-party App's check suite, created on it at 01:43:37Z, keeps a
copy of its message; the public Events feed lists the branch's creation and deletion by name only,
but the repository's public activity listing, readable without a token, names `8e6af13` in both, so
its id can be found without being known. Its diff and message passed the scans above, and its author
and committer are the operator's usual git identity. Every later agent brief in the worktree's
session requires every command either to change into the scratch copy first or to name its
repository with `git -C` (the worktree only for named read-only commands) and names the forbidden
write commands, and the session follows each later workflow with a read-back of the worktree's
reflog and status and of the remote's branches. These controls are procedural and detective only:
each shell command a subagent runs still starts in the worktree, whatever an earlier command's `cd`,
and the operator's credentials can push from there to a new branch or tag or, since D46 does not
block a fast-forward, to `main`.

---

## D45 — Open Dependabot pull requests 7 and 8 while the Dependabot governance path is built: supersede both on main

- **Status:** **ANSWERED 2026-10-02: supersede both on main (option A); APPLIED 2026-10-03
  (urllib3 on `main` 2026-10-02, setup-uv 2026-10-03); both pull requests closed by Dependabot by
  2026-10-03 (see Resolution).** This commit takes the urllib3 update; the setup-uv update follows
  in its own commit.
- **Finding.** Two Dependabot pull requests were open against `main`, and both failed CI. Pull
  request 8 is a Dependabot security update, urllib3 2.7.0 → 2.8.0 in `docs/requirements.txt`, for
  three Dependabot alerts opened at 2026-10-02T02:08Z: GHSA-8988-9cw3-xx77 and GHSA-vxq7-64xx-v4gw
  (high) and GHSA-gh4c-6fx4-qh6g (medium), each first patched in 2.8.0. urllib3 serves only the
  documentation toolchain in CI and is not part of the shipped CLI. Pull request 8 failed two
  checks: `governance / required`, because the description after its title's type starts with a
  capital letter and its body carries no template section; and `Supply-chain policy`, whose
  lock-regeneration check found a single differing comment line, because Dependabot regenerates the
  lock from inside `docs/`, so its `# via` comment names `requirements.in` where CI's, run from the
  repository root, names `docs/requirements.in`. The version resolution matched; the same comment
  difference recurs on every Dependabot update of that lock until the Dependabot governance path
  accounts for it. Pull request 7 is a version update, astral-sh/setup-uv 10.1.0 → 10.2.0. Its
  `Supply-chain policy` job ran the new Action, which the server-side Actions allowlist admits at
  any ref, and failed because the repository's tests pin the reviewed Action commits and the new one
  is not among them; that is expected until the design §10.5 Dependabot pin exception exists. It
  failed `governance / required` for the same two reasons as pull request 8 and also because its
  title is longer than 72 characters. On both pull requests the `quality / required` rollup, which
  aggregates the CI jobs, failed only because `Supply-chain policy` did. Pull request 7's head
  predates D41's commit, so a new CI run on it would print D41's search term again and, under D43,
  push that residual's expiry later; because `ci.yml` also runs on the `edited` event and builds the
  pull request's head commit, even an edit of its title or body would start one. No ruleset requires
  a status check, so neither failure blocked a merge, but merging either pull request as it stood
  would have turned `main`'s own `Supply-chain policy` red.
- **Correction to D33's record.** D33 says that, because `target-branch` names the default branch,
  each configured ecosystem's commit-message pattern also governs its security-update pull requests.
  Pull request 8, the first security update since D33, carries Dependabot's default `build(deps)`
  prefix and default labels, not the `build(docs)` prefix and the labels configured for `/docs`, so
  the configuration did not govern it. GitHub's "Dependabot options reference" disagrees with itself
  here: its `commit-message` and `labels` sections say they apply to security updates unless
  `target-branch` names a non-default branch, which is the reading D33 relied on, while its
  `target-branch` section says that once `target-branch` is defined, the ecosystem's options no
  longer apply to security updates. Pull request 8 behaves as the `target-branch` section says, and
  `scripts/ci/dependency_policy.py` requires `target-branch: "main"`, so security-update pull
  requests keep Dependabot's default title and labels in every ecosystem. D33's ruling does not
  depend on that statement; the readiness evidence carries the same correction.
- **Options considered.** (A) take both updates in reviewed commits on `main` and let Dependabot
  close the pull requests itself; (B) the same for urllib3 only, leaving pull request 7 open and
  untouched until the §10.5 pin exception exists; (C) leave both open and untouched until the
  Dependabot governance path lands, with the three alerts open meanwhile.
- **Ruling.** (A), as the ledger row states.
- **Applied.** The urllib3 lock is regenerated with the repository's own lock command at the uv
  version CI pins, adding `--upgrade-package urllib3==2.8.0`; the plain command then reproduces the
  result byte for byte. Only the urllib3 lines change, and the new hashes match PyPI's and those in
  pull request 8. The setup-uv commit that follows checks the new Action commit against the upstream
  `v10.2.0` release tag before adding it to the reviewed Action allowlist; no repository setting
  changes.
- **Resolution (2026-10-03):** `0d0b40d` took urllib3 2.8.0 and reached `main` at 2026-10-02T10:57Z;
  `a26a19a` took setup-uv 10.2.0 and reached it at 2026-10-03T10:20Z. GitHub marked the three
  urllib3 alerts fixed at 2026-10-02T10:58Z. Dependabot closed pull request 8 at 10:59:59Z that day
  and pull request 7 at 2026-10-03T10:22:27Z, each about two minutes after its update reached
  `main`, and deleted each head branch within seconds. No agent acted on either pull request; the
  project did not edit, re-run, review or merge either. The ledger row's other expectation did not
  hold. Dependabot edited each pull request about a minute before closing it and again as it closed
  it (each second run started two to three seconds after the close), and `ci.yml` and
  `governance.yml` both run on the `edited` event; no other trigger they list fired (neither head
  changed, and neither pull request was reopened or a draft), each run's triggering actor is
  Dependabot, and Docs, which does not run on `edited`, did not run. Those edits started CI and
  Governance runs on each head: pull request 8's, which contains D41's commit, and pull request 7's
  `af46d81`, which predates it. On pull request 7 the first CI run (2026-10-03T10:21:27Z) was
  cancelled 57 seconds into its hosted-quality step, in the build stage, before the test stage
  started; the second (10:22:30Z) ran the full Swift suite. A count-only check of all eleven job
  logs the two runs left found the removed test's old name on two lines of the second run's
  `build-test` log, as in each log D43 counted, and in no other, D41's search term nowhere outside
  those lines, and neither D41's message texts nor D42's note fragment, as those commits removed
  them, in any of them. That log falls under D43's ruling (its 2026-10-04 amendment). The finding
  above noted that an edit would start such a run, but not that Dependabot's own close makes one.
- **Filed:** 2026-10-02 · **Category:** dependency updates / Dependabot

**Why it needed you.** Acting on a pull request is outward-facing, and overtaking Dependabot's
pull requests on `main` instead of waiting for the governance path was a choice of scope.

**Blocking?** No.

---

## D46 — Interim protection for `main` before the design's ruleset

- **Status:** **APPLIED 2026-10-02T05:04Z** on the operator's instruction; the no-bypass shape,
  chosen by the controller, **RATIFIED in session the same day (option A)**, after it was applied.
- **Instruction.** The operator asked, in session: "let's protect the main branch but lets make
  sure it doesn't affect us". The rule shape was the controller's choice within that instruction.
  Review then flagged that the no-bypass choice limits the operator's own emergency path, and the
  operator ratified it in session the same day.
- **Options considered.** (A) two rules, block force pushes and restrict deletion, on `main` only,
  with no bypass actor. (B) The same rules with the operator's exact user as bypass actor, the
  step 20 bypass shape: both agent sessions (D44) push with the operator's credentials, so that
  bypass would be theirs too, and as only the operator's credentials can push to `main` today
  (D31) the rule would stop nothing. (C) Nothing until design §18 step 20, the design's order,
  which does not meet the instruction. Only (A), recommended, and (B) were put to the operator;
  (C) was not.
- **Ruling.** (A). Applied through the API 2026-10-02T05:04:58Z and read back 05:05Z (readiness
  evidence §4): one ruleset, "main: block force-push and deletion (interim, D46)", enforcement
  active, target exactly `refs/heads/main`, rules `deletion` and `non_fast_forward`, no bypass
  actor, `current_user_can_bypass` never; the rules GitHub reports for `main` are exactly those
  two; rulesets 0 before, 1 after. It requires no pull request, review, status check, linear
  history or code-owner approval.
- **What it stops and what it does not.** While it is active nothing, the operator's credentials
  included, can force-update or delete `main`. GitHub's ruleset documentation adds that an
  administrator without bypass also cannot rename the default branch or change it while force
  pushes are blocked; that was not exercised here, so it is recorded as documented, not observed.
  Fast-forward pushes, pull requests and their squash merges, Dependabot's branches and the
  current read-only CI workflows are untouched: the first push under it, `9cd2260` at 05:19:37Z
  (D44's commit), passed its rule evaluation. Any credential with repository administration, the
  operator's token that both agent sessions use included, can still disable or delete the
  ruleset, so it guards against mistakes, not against a misused credential (design §6.2 says the
  same of the owner). Its history records each update while it
  exists; a deletion removes it with its history and shows only as a divergence from the
  readiness evidence's expected set, which records its creation time and history length. Agents
  change a ruleset only on the operator's own explicit instruction in session (`AGENTS.md`,
  Branch model, which states that posture for every repository setting).
- **History repair.** A rewrite the operator authorizes (D9's kind) runs in this order: (1) both
  agent sessions pause; (2) the operator sets the ruleset's enforcement to disabled, not deleted,
  so its history stays; (3) the rewrite pushes with `--force-with-lease` against the expected
  object; (4) the operator re-enables it and the controller reads back the values above and the
  new history version, recorded in the readiness evidence; (5) each session keeps any unpushed
  work aside, then fetches and resets to `origin/main`. D44's take-`main`-by-rebase rule does not
  apply here: a session re-applies only its own commits, with `git rebase --onto origin/main` and
  the pre-rewrite tip as the old base, after checking they carry none of the purged content.
  Rebasing or merging old local commits onto the rewritten tip would bring purged commits back
  as a fast-forward this rule cannot stop.
- **Departures named.** Design §7.2 activates `main` protection only after the steps 8–14
  rehearsal, in the reviewed shape with the operator's exact-user bypass (§6.2). D46 puts a
  two-rule subset on `main` first, with no bypass, so while it is active the operator's
  force-push authority on `main` is exercised only by disabling it. It is not the step 20
  activation that D16 reserves for a separate instruction, does not satisfy §15's precondition of
  an active step 20 `main` ruleset (D27), and engages no required check. The catch-all branch
  ruleset of §7.3 excludes `main` and the step 8 rehearsal ruleset targets a disposable ref, so
  neither overlaps it. The design carries dated amendments at §7.2, steps 18 and 20, and its
  history-repair row.
- **At step 20.** The reviewed `main` ruleset contains both rules but exempts the operator's exact
  user, as whom the agent sessions push, so deleting this ruleset then restores force push for
  them. Whether to delete it (accepting that, or first moving the agent sessions to an identity
  without bypass) or keep it beside the reviewed ruleset as a standing no-bypass layer is the
  operator's decision at that step. If it is deleted: activate the reviewed ruleset, read it back,
  delete this one, read back that only the designed rulesets remain, then run step 20's
  force-push confirmation. Keeping it is a design change: §7.3 gives `main` one ruleset with the
  operator as sole bypass actor and §15.1's launch read-back compares against that, so a kept
  ruleset makes the launch preflight refuse until the change recording that ruling amends design
  §§4.2, 5, 6.2, 7.2, 7.3, 15.1 and 19 and the step 17 expected set; step 20's force-push
  confirmation would then read each ruleset's verdict from the rule-suite evaluation.
- **Other entries.** D31's re-open triggers do not fire: no bypass actor is added and this is not
  step 20. D33's remark that a failing Dependabot title/body check "binds no merge while no
  ruleset exists" still holds in substance: no ruleset requires a check.
- **Filed:** 2026-10-02 · **Category:** repository settings / branch protection

**Why it needed you.** Repository settings are outward-facing state only the operator may
authorize changing, the design schedules `main` protection for §18 step 20, and the no-bypass
shape constrains the operator's own emergency path.

**Blocking?** No.

---

## D47 — The public Activity view lists commits no advertised ref holds, whose parents reach the replaced history: leave them

- **Status:** **RATIFIED 2026-10-07 (UTC; 2026-10-06 local): leave them (option B of the second and
  third briefs), re-confirmed after the reach was measured; a recount after the ruling lowered two
  figures in the brief it answered.**
- **Finding (controller, read-only, 2026-10-07T02:25Z to 04:31Z UTC; the view's newest event was
  2026-10-06T08:44Z).** The repository's public Activity view listed 291 events (249 pushes, 15
  force pushes, 14 branch creations, 13 branch deletions) naming 269 distinct commits, 133 of them
  not on `main`. A fresh mirror of every ref GitHub advertises (`main`, the tag and the eight
  pull-request refs) holds 5 of the 133, each the head of one of Dependabot's pull requests 1, 2,
  6, 7 and 8, held by that pull request's ref and outside this entry. The other 128 are absent from
  every advertised ref. 127 of them first appear in the view between 2026-07-15 and 2026-09-03; the
  remaining one, first listed 2026-10-04, is the `26/governance` tip D44 records. GitHub still
  served all 128 by full id on 2026-10-07. With their parents they make 1,550 commits in all, the
  128 included, that no advertised ref holds (none is an ancestor of `main` or of a pull-request
  ref), carrying 1,194 distinct file contents found in no commit of `main`'s history. A value-free
  count over those objects, keeping only values that occur in no file or commit message in `main`'s
  history and without reading them, found 14 distinct phone-number-like strings (4 of them bare
  digit runs that may be constants) and 11 email addresses (AI co-author, GitHub and reserved
  example addresses excluded, and reserved test numbers); no file content holds five or more such
  addresses. Two commit messages carry a denylist term that no file or commit message on `main`
  carries: one is D38's commit, itself one of the 128; the other is reachable only through parents
  and was not recorded before. Three other denylist terms also occur in today's public files; their
  matches were not classified. Counted per message and not filtered against `main`, 953 of the
  1,550 messages carry tracker identifiers and 485 carry session links, the latter from the two
  operator sessions D37 named. The view also shows six deleted branch names that carry tracker
  identifiers; this ruling does not cover them (D50). The private lists of the 128 and of the 1,550
  commit ids (full lowercase ids, sorted bytewise, one per line, each line ending in a line feed)
  have SHA-256 `fec96da60ce0818cd031508a22fb5c6dfa47cddc7a03efd4fa6a53e3085a79b4` and
  `0a66c433158bb5f92902df168fad7c3c7aa474bf51b1706ebcb86da75a0f0c3d`.
- **What this changes in earlier entries.** D19 accepted by-id reachability on two premises, as D38
  restates them: that the ids were retained nowhere this project controls, and that every published
  surface was clean or operator-dispositioned. D37 (the run listing and the Events feed) and D44
  (whose 2026-10-03 amendment noted that the view names its commit) had already broken them in
  part. The Activity view, public since the 2026-09-21 visibility change, breaks them for the
  replaced history reachable from these commits, and has listed D38's commit since then, an
  exposure window D38 does not record. D19 also saw 35 of 38 orphaned ids referenced by
  pull-request timelines stop answering; none of these 128 has. D38 made any other personal-data
  object a finding; this ruling accepts the second message above with the rest of the 1,550. Of the
  135 head commits of the runs D37 deleted, 126 are among the 1,550 and are accepted here as
  commits, 6 are held by pull-request refs, and 3 lie outside both: the outside contributor's
  earlier pull-request heads, which the Events feed still names through review events. With their
  parents those 3 make 6 commits that no advertised ref holds and neither list contains; their two
  session-link messages are copies of messages a pull-request ref holds (D36's known item); these
  six commits are a separate surface and stay a known item for the round. Copies of commit messages
  stored outside git by commit id, such as third-party check suites, are not covered and stay
  findings or known items.
- **Options put to the operator.** First brief, before the parent-link reach was measured: (A) the
  operator files a GitHub Support request to purge the unreachable commits (recommended); (B) make
  the repository private, then (A); (C) delete and recreate the repository; (D) accept it as a
  recorded risk. Second and third briefs, after the reach was measured: (A) a Support purge,
  recommended in both; (B) leave them, scoped to everything reachable from the 128 commits the view
  listed on 2026-10-06; deleting and recreating the repository was named only as a step the
  operator could take personally, which the controller would not prepare, and making the repository
  private was not offered again. Support takes such requests only through its web form; no
  pull-request ref holds any of the 1,550, so a purge would have left the pull requests in place.
  The third-party fork D19 noted, made on 2026-09-10 while the repository was private, answers
  not-found to the owner's token: deleted, or detached at the visibility change as a standalone
  private repository, which the controller cannot tell. Its refs held none of the 1,550 when it was
  made; whether a detached copy keeps the network's unreachable objects is not known, and no option
  reaches it.
- **Ruling and how it was reached.** To the first brief the operator answered, for this item, "2A
  if you can submit it autmatically through the cli, if i have to do anything manual besides
  reading and approving, 2C". The controller found no command-line route to Support and, treating
  the conditional "2C" as enough, started on deleting and recreating the repository, an
  irreversible step it should have confirmed with the operator first. It took a private read-only
  snapshot of the settings and pull-request record; an automatic safety check stopped it before any
  deletion step was written. The operator asked "wait why are we deleting the repo???", then asked
  for the commit list, whether the commits expire and what a fresh visitor can reach, began the
  Support form without submitting it, and decided "actually let's just let these commits be." That
  decision rested on the controller's description of 128 commits, each reachable only by its id,
  which was wrong: each commit's parent links make the history behind it retrievable too. The
  second brief, on the measured reach, also wrongly said that 482 old file versions held the
  operator's private terms, "the material D9's rewrite removed"; those matches were terms that also
  occur in today's public files. A third brief corrected that, kept both options and their scope,
  still recommended (A), called (B) a reasonable choice, and gave 51 email addresses and 9 file
  versions holding five or more each, which it said looked like data dumps. The operator answered
  "B". A recount after the ruling, against `main`'s whole history instead of its current files,
  found 11 addresses and no such file, so that brief overstated what the operator accepted; the
  operator was told at about 04:11Z. The 1,550 commits and their objects that no advertised ref
  holds, which include D38's commit, are a recorded residual: the end-of-roadmap privacy round
  records them as ACCEPTED with these measurements. Anything the round's classes detect in a commit
  outside the two pinned lists, or in an object no listed commit reaches, is outside this residual
  and stays a finding unless another entry accepts it, whenever the view lists it or however it is
  found. No Support request was filed and nothing changed on GitHub; the operator may still file
  one, and this entry does not prevent it.
- **Private scratch.** For the measurement the controller fetched the 1,550 commits into a private
  directory outside the repository. On 2026-10-07, after recording the counts and before committing
  this entry, it deleted that copy, the snapshot of the settings and pull-request record, the fresh
  mirror, the copies of commit messages and the unsent Support drafts, and read back their absence.
  It keeps privately, for the privacy round, the four id lists (the 128, the 1,550, the 133 and the
  three review-event commits), the raw Activity and Events listings, the counting scripts (the
  per-object count and the distinct-value recount that produced the figures above), and its notes
  and review records, some of which quote commit ids from those lists.
- **Filed:** 2026-10-07 (UTC) · **Category:** privacy disposition / residual on a GitHub-side
  surface

**Why it needed you.** Leaving personal data retrievable, contacting GitHub Support or deleting the
repository is yours alone to decide (D9, D19, D38).

**Blocking?** No; it settles the 128 commits the view listed on 2026-10-06 and their history before
the fresh round runs. The branch names in it are D50, still open.

**Amended 2026-10-07 (D50):** the branch names were ruled the same day: accepted as a recorded residual scoped to those six names in the 24 events D50 describes (option B).

---

## D50 — Deleted branch names in the public Activity view carry tracker identifiers

- **Status:** **RATIFIED 2026-10-07 (UTC): accept them as a recorded residual (option B)** — filed
  by the controller with D47. D48 and D49 are reserved for entries another session files.
- **Finding.** The repository's public Activity view (D47) shows six deleted branch names that
  carry tracker identifiers, in 24 events (branch creations, pushes and deletions) dated 2026-07-15
  to 2026-08-23. The public Events feed does not list them. All six identifiers also occur in
  commit messages D47 accepts, and each branch's last tip is among D47's 1,550 commits. The
  repository bans tracker identifiers in its files, commits and docs (`AGENTS.md`, Commits +
  review); this is a GitHub-side surface the repository cannot edit, and D47 does not cover the
  names.
- **Options.** (A) the operator asks GitHub Support, through its web form, to remove those Activity
  entries, alone or together with the purge D47 declined (which would reopen D47); whether Support
  removes Activity entries is not established; (B) accept them as a recorded residual scoped to
  those six names in those 24 events, as D47 accepted the same identifiers in the messages it
  covers. Whether Activity entries ever age out is not known. Controller's recommendation: (B),
  since (A) alone leaves the same identifiers retrievable through the commits D47 accepts.
- **Filed:** 2026-10-07 (UTC) · **Category:** privacy / tracker identifiers on a GitHub-side
  surface

**Why it needed you.** Contacting GitHub Support, or leaving tracker identifiers public, is yours
to decide (D37 precedent for tracker identifiers in branch names on GitHub-side surfaces).

**Blocking?** It is a finding for the end-of-roadmap privacy round until ruled.
**Resolution (2026-10-07):** the operator answered "B" to a plain-language brief that gave both
options and the deciding fact, that the same identifiers already sit in commit messages D47
accepts, so removing the Activity entries alone would leave them public; this followed the
controller's recommendation. The six branch names, in the 24 branch-creation, push and deletion
events dated 2026-07-15 to 2026-08-23 that this entry describes, are a recorded residual; the
end-of-roadmap privacy round records them as ACCEPTED. The same names in any other event or on any
other surface, and any other tracker identifier the view shows, stay findings unless another entry
accepts them. No Support request was filed and nothing changed on GitHub; the operator may still
file one, and this entry does not prevent it.

---
