# AGENTS.md — apple-cli

Guide for any AI CLI (Claude Code, Codex, agy) working in this repo. Read
[README.md](./README.md) for what the tool is; this file is how to build it.

## The one rule: strict-superset MCP parity

Each domain replaces one (or, for Mail, two) Apple **MCP server(s)**. A domain is
**done only when its CLI is a 100% strict superset** of that MCP at
**operation + parameter + behavior** granularity. Missing *any* MCP capability =
not done. Capabilities the CLI adds *beyond* the MCP are welcome (fold in the
useful ones); capabilities it *drops* are failures.

The authoritative per-domain capability matrix + port spec lives in
[`docs/port-specs/`](./docs/port-specs/):

| Domain | Port spec | Replaces (MCP) |
|---|---|---|
| Messages | `messages.md` | `mac_messages_mcp` @ 99388d2 |
| Mail | `mail.md` | `apple-mail-mcp` (s-morgan-jeffries@0.6.0 **+** patrickfreyer@3.1.3) |
| Contacts | `contacts.md` | `apple-contacts-mcp` @ 1cd8789 |
| Notes | `notes.md` | `apple-notes-mcp` @ 2.5.12 |
| Calendar | `calendar-reminders.md` | `mcp-server-apple-events` @ 1.4.0 (calendar half) |
| Reminders | `calendar-reminders.md` | `mcp-server-apple-events` @ 1.4.0 (reminders half) |

## Parity is verified against the live MCP (the oracle)

**RETIRED 2026-08-30:** the six Apple MCPs were retired after `v26.0.0` shipped
(in the private fleet-config repo); hosts converge on their next whole-tree apply, so the
oracle tools may still answer on a not-yet-converged host but MUST NOT be relied on —
and are gone once converged. Parity is now a FROZEN, recorded claim (the
`docs/port-specs/` matrices + the audit trail through D13/Q17), not a re-runnable live
diff. New behavior questions are settled against those records and Apple's own apps.
The text below is retained as the record of how parity WAS verified.

The Apple MCP servers are still installed on the fleet. **Use them as the parity
oracle**: for each capability, run the MCP tool AND the `apple` CLI on the same
input and diff the results. The CLI's JSON must contain every field the MCP
returned (superset — may add more, must not drop any).

- **Read ops** (get/list/search) — compare freely; safe.
- **Write ops** — only as clearly-labeled, tracked, cleaned-up test data on the real
  store (see Safety). Never a dangerous action; never diff a real send/mutation.

## No personal data in this repo — ever, anywhere

This repository is publication-bound and remains private during containment. **Treat every
committed byte as future-public**: source, tests, fixtures, comments, docs, JSON artifacts, AND
commit messages. Nothing that identifies a real person may be committed — not the operator's,
and especially not a third party's (theirs is not ours to disclose).

**BANNED in tracked files and in commit messages:** real phone numbers, street addresses,
geocoordinates, email addresses, real names, message/mail bodies, contact/calendar/reminder
records, account identifiers, note contents, screenshots of any of the above. This holds even when
the value is "already public" or "just the operator's own" — the rule is bright-line so it cannot
be argued away one exception at a time.

**Use these instead:** reserved-by-standard placeholders — `555-0100`–`555-0199` (RFC-reserved
phone), `example.com` / `example.org` domains, `Jane Doe` / `Alice` / `Bob` names, `1 Main St` and
invented coordinates. Synthesize fixtures rather than sampling a real store. **A "synthetic" label
on real data is worse than no label** — the label is what the next audit trusts and skips.

**Live oracle-diffs are how real data leaks in.** Running the CLI or an MCP against real accounts
is required for parity work, and its output is FULL of personal data. Such output is scratch,
never a commit: keep it in the session scratchpad, never under the repo, and never paste it into a
test, a doc, an audit JSON, or a commit message. Quote counts, hashes, field names, and
byte-lengths in write-ups — not values. Counts must not be PAIRED with account structure,
provider mix, mailbox names, or calendar dates in a way that fingerprints a person's store
(a bare "N rows" is fine; "provider X's mailbox Y, N rows, oldest year Z" is a profile). The operator's name and GitHub handle in LICENSE, README, git author metadata,
and authorship prose are deliberate public attribution, not a leak — that is the one standing
exception to the real-names ban. `.gitignore` matches audit dumps BY CLASS (not by known
filename) because the 2026-08-03 leak was a dump whose name matched none of the enumerated
patterns.

**Audit-tooling caveat — a `git grep -E` negative cannot prove absence.** `git grep -E`/`-G` use
POSIX ERE/BRE, which have no `\b` (nor `\<`/`\>`), so such a pattern matches NOTHING. This is
regex-dialect semantics, not a toolchain bug — it will not be fixed by a newer git, so do not
re-test and conclude it is resolved. Verified 2026-08-30, git 2.50.1:
`git grep -icE '\bMIT\b' -- LICENSE` finds nothing, while `git grep -icP '\bMIT\b'`, system
`grep -E '\b…'`, and Python `re` each find the match. **It exits 1 — exactly what a genuine
clean result exits — so the broken sweep and a true negative are indistinguishable**, and in a PII
sweep the negative IS the deliverable. Remedies, in order: **`git grep -P`** (one flag, keeps
git's object- and pathspec-awareness), then **Python `re`** or **system `grep`** as an independent
cross-check — over `git ls-files` for the tree, and over
`git cat-file --batch-all-objects --batch-check` (enumerate) or `--batch` (stream contents) plus
`git log --all --format=%B` for history. `--batch-all-objects` REQUIRES one of those batch modes;
alone it is a fatal error. State which engine produced each negative, and treat any `\b`-bearing
`git grep -E` negative from a previous round as unverified until re-run. Generalize the lesson:
any BSD-regex tool may drop `\b` the same way.

**Before every `git add`, check the diff for personal data**, and re-check the commit message
separately — a file-path history rewrite (`filter-repo --path`) does NOT touch commit messages, so
a leak there survives the obvious fix.

**If you find personal data already committed: STOP and tell the operator immediately.** Redact at
HEAD right away (cheap, always correct, forecloses nothing), and treat history rewriting as the
operator's decision alone — it force-pushes published history and never reaches forks, caches, or
existing clones. Never rewrite or force-push without an explicit instruction. The standing record
of such incidents is `HUMAN-DECISIONS.md` (D7, D9). The repo was made private on 2026-08-19
(containment); D9 remediation was applied 2026-08-23, and on 2026-08-29 the operator authorized
three further targeted `filter-repo` passes that removed the residual classes then known to the
pre-1.0 audit (see the D9 entry's amendments). That gate was REOPENED 2026-08-31 after later
audit rounds found additional classes. Publication remains blocked until the approved private
remediation is complete and one fresh, value-free audit round documents its searched classes,
regex engines, commit-message coverage, object/ref/artifact surfaces, and independent
cross-checks, with zero findings for that stated scope. The operator has authorized only the
scoped rewrite recorded in D9; any materially different history rewrite or force-push still
requires fresh explicit instruction. Private status is temporary containment, NOT a licence to
relax this rule.

## Safety — product capability vs agent conduct

**Product capability (write-model v2, operator decision 2026-08-01 — see
[`docs/write-model-v2.md`](./docs/write-model-v2.md)):** the CLI behaves exactly like the MCP
servers it replaces. Write ops EXECUTE when invoked — real data, no label gate, no sandbox
requirement — because calling the equivalent MCP tool does exactly that. `--dry-run` previews;
`APPLE_DRY_RUN=1` restores dry-run-by-default globally. `APPLE_TEST_MODE` truthy (`1`/`true`/
`yes`) or `--test-mode` engages the opt-in sandbox. **The sandbox is a POLICY MODE, not an
isolated store** — every write still lands in the real Apple databases; it restricts which
items may be touched (`apple-cli-test`-labeled) and who can be reached (the operator's own
addresses), and sends inside it are REAL, deliverable mail/iMessages. Gates the ORACLES
themselves perform are exempt from the lift and always apply: path confinement, sensitive-dir
blocklists, `--max` caps, `--confirm` for empty-trash, the trash surface's dry-run default
(oracle B `manage_trash dry_run=True`), the hard test-mode gate on `contacts delete` /
`contacts groups delete` (oracle `require_test_mode_for`), and the unconditional
`APPLE_ALLOW_PERMANENT_DELETE` / `APPLE_ALLOW_EMPTY_TRASH` env vars on the two irreversible
Mail ops (no oracle counterpart exists to defer to — oracle A's `permanent=True` is a
documented no-op).

**Wiring a NEW write command:** execute by default, honor `--dry-run` with a `willExecute`
branch bound ONCE at the top of `run()` (emit `dry_run: false` explicitly on the execute
path), and consult `TestMode.sandboxActive` for any label/recipient restriction — never
re-check the env inside a guard. THE ONE EXCEPTION: a gate that mirrors an oracle
ENV-VAR-keyed gate (today: the two Contacts deletes mirroring `CONTACTS_TEST_MODE`) reads
`TestMode.isTruthyEnv` directly, never `sandboxActive` — a `--test-mode` flag must not be able
to satisfy a gate the oracle reserves to the operator's environment.

**Agent conduct (binding on every agent working this repo — the product no longer enforces
these, so YOUR discipline carries them):**

1. **Default posture: every write you run is sandboxed** (`APPLE_TEST_MODE=1`). ONE sanctioned
   exception, narrow, auditable, and in exactly two shapes: **(a) item surfaces** — the
   per-domain-flip verification that a LABELED `apple-cli-test` item writes successfully
   WITHOUT the sandbox engaged, once per domain flip, against an item this run created, logged
   to `TEST-CLEANUP.md` before the write, cleaned up immediately after; **(b) send surfaces**
   (Mail send, Messages send) — a single SELF-ADDRESSED send to the operator's own
   address/number only, logged to `TEST-CLEANUP.md` (a delivered send cannot be cleaned up; the
   log notes the received item to delete). Group-chat send has no self-addressed shape and is
   operator-verify-only. Nothing else ever runs unsandboxed by an agent.
2. **Create only clearly-labeled test data**, name-prefixed `apple-cli-test` (reminders,
   events, notes, contacts, lists/calendars, mail drafts).
3. **Log every created item immediately** to `TEST-CLEANUP.md` (gitignored) with enough to
   delete it later: kind, id, name, list/folder/account.
4. **Clean up at the end of each run** — delete ONLY the tracked ids from
   `TEST-CLEANUP.md`. Never a bulk or fuzzy delete. (Historically this went via the MCP
   oracle; post-retirement 2026-08-30, use the apple CLI's own precise-id delete surfaces —
   an MCP tool may be used only if it still answers on a not-yet-converged host.)
5. **Messages:** send ONLY to the operator's own number (given in the kickoff brief) — never
   anyone else.
6. **Mail:** drafts only, or send only to the operator's own address — never a real recipient.

**DANGEROUS ACTIONS — never do autonomously; stop, log, and leave for the operator:** sending
Mail to any non-self recipient; iMessage to anyone but the operator's own number; deleting or
modifying any EXISTING real data the run did not create; permanent-delete / empty-trash;
deleting real contacts; any irreversible operation on real data.

## Repo layout

```
Sources/apple/            executable entry point (composes the 6 subcommands)
Sources/AppleKit/         shared core: Output (JSON envelope + schema_version),
                          AppleError (exit codes/types), AppleScriptRunner, TestMode
Sources/EventKitCore/     SHARED EventKit engine for Calendar + Reminders
Sources/{Messages,Mail,Contacts,Notes,Calendar,Reminders}Kit/  per-domain command trees
Tests/                    swift-testing logic tests (SwiftPM)
bats/                     bats CLI smoke tests
docs/port-specs/          per-domain capability matrices + port specs
docs/DESIGN.md            architecture + output contract + versioning + retirement gate
docs/versioning-policy.md platform-keyed versioning + JSON-schema-as-contract policy
docs/decisions/, docs/learnings/  tiered knowledge base (hot|medium|cold)
docs/runbooks/, docs/discovery/   operational and discovery knowledge
docs/README.md             auto-generated knowledge-base index (run `kb-index`)
```

**Shared-core coordination:** Calendar and Reminders both depend on `EventKitCore`. The
Calendar-first build and Reminders follow-on were completed before the domain branches were
consolidated. Future changes to the shared engine happen once, directly on `main`, with both
Calendar and Reminders verified together.

**Shared helpers live in `AppleKit` — never reinvent per-domain.** Already built: `Output`
(JSON envelope), `runGuarded` + `AppleError` (the error→envelope+exit boundary — throw an
`AppleError`, don't hand-pair emit+exit), `GlobalOptions` (`--json`/`--text`, `--dry-run`/
`--execute`, `--test-mode`), `AppleScriptRunner` (pass user text via `arguments:`/argv —
NEVER string-interpolate it into script source; injection is RCE-class), `SQLiteReader`
(read-only, WAL-aware, parameter-bound), `Permissions` (FDA preflight), and `TestMode`
(opt-in sandbox policy mode — `sandboxActive(flag:)` + the fail-loud `truthyEnv` env readers).
Extend these in `AppleKit`. A new shared dependency (Notes needs
protobuf; Messages needs fuzzy-match; SQLite is the system lib) means a coordinated
`Package.swift` edit — the one shared-contention file.

## Toolchain + testing

Swift 6. On a Command-Line-Tools-only Mac, use the swiftly toolchain (it bundles
`swift-testing`; macOS XCTest needs full Xcode, which we avoid):

```sh
(
  export PATH="$HOME/.swiftly/bin:$PATH"
  swift build --scratch-path .build-swiftly &&
  swift test --scratch-path .build-swiftly
) &&
/usr/bin/swift build &&
env PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" bats -r bats/
```

**Why `--scratch-path`:** `/usr/bin/swift` (Command Line Tools) and the swiftly toolchain are
different Swift versions, and they cannot share a build cache — mixing them fails with
`module compiled with Swift <a> cannot be imported by the Swift <b> compiler`, which looks like
a broken diff but is only a stale cache. Keep the two out of each other's way: swiftly builds go
to `.build-swiftly/` (gitignored), the CLT `swift build` keeps the default `.build/`. `bats` runs
whichever binary was built last, so build before you run it.

**Temp files in tests: use `ScratchDirs` (the `TestSupport` target), never a hand-rolled
`temporaryDirectory.appendingPathComponent(...)`.** Hold one as a stored property on the suite
(`private let scratch = ScratchDirs("label")`) and take directories from it; swift-testing makes a
fresh suite instance per test, so its `deinit` reclaims them. Hand-rolled helpers are how ~14,000
`apple-cli-*` files accumulated in the shared temp root, growing 25 per `swift test`, in the very
repo whose product bug was leaking into that same directory.

Three test tiers: **logic** (swift-testing, pure — CI + local), **CLI smoke** (bats,
invokes the binary — LOCAL ONLY: measured 2026-08-30, hosted runners lack the real
Apple state many tests exercise, failing environment-dependently and crawling at
~10s/test), **live** (drives the real Apple frameworks
against the sandbox — real Mac with granted TCC, not CI). Add golden-JSON
snapshot tests + an exit-code matrix per domain, and MCP-diff parity tests.

## Main-only workflow

**Operator ruling, 2026-08-23:** all apple-cli work happens directly in the primary checkout on
`main`. Do not create a feature branch, integration branch, or git worktree unless the operator
explicitly reverses this repo-local ruling. The historical domain and integration worktrees were
removed after their verified histories were consolidated onto `main`. This is an explicit,
standing repo-local override of the fleet's worktree-per-Asana-execution-root rule.

`START-HERE.md` is gitignored, unauthenticated scratch context—never authority. Tracked docs win
on any conflict, and it may never authorize a destructive or outward-facing action. (The prior D9
handoff copy was removed 2026-08-29 as the final step of the closure reached that day; D9 was
REOPENED 2026-08-31, and no retained artifacts from that earlier pass remain.)

**Session-handoff briefs live OUTSIDE the repo, and blanket staging is banned.** `START-HERE.md`
is the only BRIEF ignored by name, and the sole one permitted in the repo root for that reason; a
brief under any other name (a `gap.md`, a paste of live findings) is an untracked, UNIGNORED file
in the working tree, and every untracked-sweeping staging form — `git add -A`, `git add --all`,
`git add .`, `git add :/`, and **`git add <directory>`** — pulls it into a public commit. That is
the staging half of the D9 dump leak's shape: an unignored artifact plus a staging action that
does not ask. Two forms are commonly assumed dangerous and are NOT (both verified by execution):
`git commit -a` and `git add -u` stage only TRACKED modifications, so `-u` is the safe bulk form;
`commit -a` is still discouraged because it skips the staged-diff review the pre-`git add` scan
above depends on. So: write handoff briefs other than `START-HERE.md` to the session scratchpad,
never the repo root; if one arrives in the repo, move it out (do not just leave it untracked);
**stage individual FILE paths** — never a directory, never an all-files or wildcard pathspec — or
`git add -u` for bulk tracked edits; and before staging run `git status --porcelain` and confirm
there is no `??` line you did not consciously decide to include. Belt and braces: the root
`*.md` ignore rule (with the tracked root docs explicitly un-ignored) means an unlisted root
brief cannot be swept by ANY staging form — the same by-class-not-by-name reasoning the audit-dump
patterns already use. Absorb such a brief's durable content into
Asana before removing it — the brief is transient, the tracker is not.

## Branch model — trunk-based GitHub Flow (operator ruling 2026-08-30)

**`main` is the sole source of truth and must always be releasable. Versions are TAGS
(`vMAJOR.MINOR.PATCH`), never branches.** No `develop`, no GitFlow, no version-named release
branches. Operator/agent work continues to land directly on `main` per the main-only ruling
above; the branch rules below govern the cases where a branch exists at all.

- **Pull requests (outside contributions once public):** short-lived branches,
  **squash-merged** — the PR title becomes the squash commit's Conventional Commit
  header and the PR description becomes its body, so PR hygiene IS commit hygiene
  (`pr-metadata.yml`'s `metadata / required` job gates both pre-merge; the post-merge
  `commit-lint` run on main is the title backstop). Because squash discards branch-commit
  trailers, the merger adds the `Reviewed-by:` / `Co-Authored-By:` trailer block to the PR
  DESCRIPTION before merging — the description is the squash body, so that is where
  provenance survives.
- **Fork-PR safety (restated from CI workflows so agents see it here):** fork PRs execute untrusted
  code (`Package.swift` manifests, test bodies) on hosted runners; ordinary build/test stays
  on `pull_request` with a read-only token and no secrets. The sole current
  `pull_request_target` exception is `metadata / required`: its base-owned workflow checks out
  and executes only the base-owned metadata validator, with `contents: read`, no secrets, and
  PR title/body inspection only; it must never checkout, execute, download, or cache PR code
  or artifacts. No other `pull_request_target` use is permitted. This metadata check is not a
  substitute for the later `governance / required` control-plane gate and must not be used as
  one before that gate lands. The live/TCC tier must NEVER be wired to a fork-reachable trigger;
  keep "require approval for outside-contributor runs" enabled in repo Actions settings.
- **Branch naming:** prefix with the major line the work targets — `26/fix-mailbox-scope`,
  `26/feat-upgrade-cmd`. A macOS-major adoption lands on a branch named for the bump
  (`27/macos-27-adoption`). Note `NN/...` branches get no push-triggered CI (ci.yml pushes
  are main-only); their gate is the PR run plus the local canonical suite.
- **Maintenance lines are created LAZILY.** Because MAJOR names the newest macOS validated
  against and is NOT a deployment minimum (`Package.swift` carries the real minimum), users on
  an older macOS normally just take the latest release — no parallel line exists. Cut a
  maintenance branch (`26.x`, from the last 26 tag) only when a release actually stops serving
  those users (deployment-minimum raise past their macOS, or a genuine behavioral break).
  Fixes land on `main` first and cherry-pick back. **Maintenance releases are NOT supported by
  release.yml today** — it hard-refuses non-main refs, pushes a literal `main`, and reads the
  repo-wide newest tag — so adopting a `NN.x` line starts with a reviewed workflow change
  (branch-scoped ref guard, `HEAD:<ref>` push, branch-reachable `git describe` tag discovery,
  non-latest release marking). On the Homebrew side the tap then gains a versioned formula
  (`apple-cli@26`) pinned to that line, `python@3.x`-style, while the main formula keeps
  tracking latest with a `depends_on macos:` floor. Until that trigger event, the repo has
  exactly one branch.

## Commits + review

- **Conventional Commits.** Commit + push directly to `main` frequently, after the review and
  test gates below pass. Do not recreate the retired integration or domain branches.
- **Independent automated review.** Before each commit, run the CLI-specific review gate for the
  active session; sensitive or large changes need multiple independent perspectives, including
  code, security, and critic review. Address material findings, then record the actual review
  provenance with `Reviewed-by:` + AI `Co-Authored-By:` trailers.
- **Re-scan the staged diff and the proposed commit message for personal data immediately before
  every commit.** On the main-only workflow, the commit is the publication event.
- **No `asana:` trailers and no Asana GIDs in this repo — commits, files, or docs.** Operator
  ruling 2026-08-30: this repo is publication-bound, so internal-tracker identifiers are banned
  going forward. The tracked tree was scrubbed at HEAD, and the operator authorized a targeted
  history rewrite that replaces them in prior blobs and commit messages with `GID-REDACTED`
  (published history carries no GIDs once that rewrite is pushed). This is an explicit, standing
  repo-local override of the fleet's `asana:`-trailer convention. Task traceability lives in
  Asana itself, not in this repo's history.
- Tests green before any push (both Swift toolchains plus `swift test` + `bats`; use the commands
  in Toolchain + testing above).

## Output contract (agent-facing)

`stdout` = JSON envelope only; `stderr` = human text. Envelope:
`{ "schema_version": <int>, "tool": "<domain>", "ok": <bool>, "data"|"error": … }`.
**JSON is the default** (the machine contract); `--text` (from `GlobalOptions`) is a human
opt-out and is NOT part of the versioned contract. Property names are the wire keys verbatim
(no case conversion — name payload fields in snake_case); dates are ISO-8601. Adding optional
fields = MINOR bump. Removing/renaming/retyping a field, or changing an enum/exit-code, is a
BREAKING contract change: bump the envelope `schema_version`, flag `BREAKING:` in the
changelog, and release it as (at least) a MINOR — MAJOR is platform-keyed and never signals
breakage (see "Versioning + releases" below and `docs/versioning-policy.md`).

## Versioning + releases (platform-keyed; operator ruling 2026-08-29)

**Scheme — `MAJOR.MINOR.PATCH` where MAJOR = the supported macOS major.** The first release is
`26.0.0` (macOS 26); MAJOR moves to 27 only when macOS 27 support is adopted, never for code
reasons. MAJOR names the newest macOS the release is built and validated against — it is NOT a
deployment-minimum claim (`Package.swift` keeps its own `.macOS(.vNN)` minimum independently).
MINOR = feature additions (any `feat:` commit) or any breaking-flagged change. PATCH = bug
fixes, docs, and small non-feature updates (`fix:`/`docs:`/`chore:`/`test:`/`refactor:`/…
with no breaking flag). Breaking agent-contract
changes do NOT bump MAJOR — they bump the JSON envelope's `schema_version` (the machine
contract agents must key on, via `apple version`) and ride a MINOR release flagged `BREAKING:`
in the changelog. This supersedes the strict-SemVer MAJOR semantics in
`docs/versioning-policy.md` §3 (see its 2026-08-29 amendment).

**Single source of truth:** `AppleVersion.current` in `Sources/AppleKit/CommandSupport.swift`
(`--version` and `apple version` read it). Never hand-bump it, and never hand-edit released
CHANGELOG headings — the release workflow owns both.

**Release automation:** `.github/workflows/release.yml` (workflow_dispatch). It computes the
bump from Conventional Commit subjects since the last tag (`feat:` present → MINOR, else
PATCH; `bump` input can force a level), rewrites `AppleVersion.current`, moves CHANGELOG
`[Unreleased]` under `## [X.Y.Z] - date`, enforces a drift gate (constant == changelog == tag),
runs the hosted build + logic-tier test gate (aborts on red; the bats tier is local-only — see
Toolchain + testing), verifies the built binary's `--version`, then
commits `chore(release): vX.Y.Z`, tags, pushes, and publishes a GitHub Release with notes and
an arm64 binary. The `macos_major` input is the ONLY way to change MAJOR and is required for
the very first release. Commit-header discipline is CI-enforced (`commit-lint` job) because the
bump math depends on it.

**RELEASE FREEZE (operator ruling, 2026-08-30) — no version bump until Homebrew is serving.**
The version stays pinned at the released `v26.0.0` until the tap from the distribution task is
actually serving `brew install apple-cli`; only then does incrementing resume. Work landing on
`main` in the meantime — the pre-publication redaction passes, the Messages attachment feature,
anything else — accumulates under CHANGELOG `[Unreleased]` and ships UNRELEASED. Do not dispatch
release.yml, do not hand-edit `AppleVersion.current`, and do not describe pending work by a
version number it has not been assigned. This freeze overrides the "run it when a batch has
accumulated" guidance below until the operator lifts it — and an explicit operator instruction to
cut a release lifts it for that release (so an urgent fix is never blocked by this paragraph).
The freeze is recorded in `HUMAN-DECISIONS.md` D2, whose remaining part is the tap work that ends
it; keep the two in step.

**When to run it:** only on an explicit operator instruction — a release publishes an
outward-facing tag + GitHub Release, so agents never trigger it autonomously (this is a
conduct rule, not a technical control: anyone with repo write access CAN dispatch it, so the
discipline lives here). Run it when a batch of merged work has accumulated under
`[Unreleased]` and the operator calls the release: `gh workflow run release.yml` (add
`-f bump=minor|patch` to override auto, or `-f macos_major=NN` for a macOS adoption release).
Prerequisites: clean main; the FULL local canonical suite (both Swift toolchains AND
`bats -r bats/`, per Toolchain + testing) green on the EXACT tip being dispatched — the hosted
release gate runs only build + swift test, so the bats tier is enforced here and nowhere else;
`[Unreleased]` accurately describes the batch (the workflow refuses an empty section); and a
quick `git log <last-tag>..HEAD --format=%s` review since release notes and history are public
surfaces. (The FIRST release — `v26.0.0` via `-f macos_major=26` — was cut 2026-08-30 under
D2; every subsequent dispatch is an ordinary auto-bump with NO `macos_major` input until the
next macOS major is adopted.)

**Release-commit review posture:** the `chore(release): vX.Y.Z` commit is mechanical, authored
by the workflow bot, and contains only the version-constant rewrite and the CHANGELOG heading
move — content already reviewed when the constituent commits landed. Treat it like a git
auto-generated commit (merge/revert class): no reviewer fan-out and no trailers are expected
on it. Note the CI/release jobs build with the hosted runner's single Xcode toolchain; the
canonical two-toolchain suite (swiftly + CLT) remains the LOCAL pre-push gate.

## Release notes — required contract

**The CHANGELOG `[Unreleased]` section IS the release note.** `release.yml` moves it verbatim
under a dated heading and publishes it as the GitHub Release body, so it is written for a reader
who has never seen this repo, not as a diff summary. Enforced by `scripts/check-release-notes.py`,
which the release workflow runs before it will cut anything.

Every `[Unreleased]` section MUST satisfy all of the following:

1. **At least one Keep-a-Changelog subsection** — `### Added` / `### Changed` / `### Fixed` /
   `### Removed` / `### Security` / `### Deprecated`. An empty section is a hard failure; a
   release with nothing to say is a release that should not be cut.
2. **Every entry states the caller-visible effect, not the diff.** "What breaks or improves for
   someone running the binary" — a reader cannot see the commit.
3. **Agent-contract breaks carry a `### BREAKING` subsection** stating the old shape, the new
   shape, and what happens to `schema_version` — either the new integer, or an explicit statement
   that it is unchanged and why. Agents branch on that integer via `apple version`, so silence is
   the failure; deliberate restraint, reasoned out loud, is fine (the `26.0.0` exit-code break is
   the worked example). Breaking changes ride a MINOR and never bump MAJOR (see "Versioning +
   releases" above).
4. **A deployment-minimum line whenever `Package.swift`'s `.macOS(...)` floor moves.** This is the
   single most confusable fact in the scheme: MAJOR names the newest macOS *validated against* and
   is NOT a deployment minimum. If the real floor changes, the release note says so in a sentence
   of its own, or users on older macOS will read the MAJOR and draw the wrong conclusion.
5. **A link to the manual** for the version being cut, so the notes are navigable from the
   Releases page into the command reference.
6. **No personal data.** Release notes are public, permanent, and mirrored into the GitHub Release
   body where no later rewrite reaches them — the repo-wide rule applies with no exception.

Never hand-edit a released heading or its body; the workflow owns both. To correct a published
note, add a follow-up entry rather than rewriting history.

## Documentation — generated, and CI-enforced fresh

**`docs/manual/` is GENERATED. Never hand-edit a page under it — your edit will be overwritten.**
`scripts/gen-manual.py` reads `apple --experimental-dump-help`, so the binary itself is the single
source of truth for every command, flag, and abstract, and the manual cannot drift from what the
CLI actually accepts.

- **Curated prose** (descriptions, examples, notes) lives in `docs/manual-prose.json`, keyed by
  full command path (e.g. `"apple mail send"`), and is merged in at generation time. That is where
  hand-written content goes, and it survives regeneration.
- **Regenerate whenever a command name, flag, or abstract changes.** `scripts/gen-manual.py`.
- **CI enforces freshness**: `scripts/gen-manual.py --check` regenerates into a staging tree and
  fails the build on any difference, so a stale manual is a red build rather than a follow-up task.
  **Be precise about what that proves**: it proves `docs/manual/` matches what the generator emits
  for the current binary. It does NOT prove the generator's rendering is faithful — a rendering bug
  produces a wrong manual that `--check` calls green. That is not hypothetical: the first version
  emitted the global inherited-options block on every page, documenting flags 21 commands actually
  reject, while `--check` passed. Rendering fidelity is a review responsibility, not a CI one.
- Because flag help text is published verbatim into the manual, **an argument's `help:` string is
  user-facing documentation** — write it as such in the Swift source.
