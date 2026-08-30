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

| Domain | Port spec | Replaces (MCP) | Asana parent GID |
|---|---|---|---|
| Messages | `messages.md` | `mac_messages_mcp` @ 99388d2 | `GID-REDACTED` |
| Mail | `mail.md` | `apple-mail-mcp` (s-morgan-jeffries@0.6.0 **+** patrickfreyer@3.1.3) | `GID-REDACTED` |
| Contacts | `contacts.md` | `apple-contacts-mcp` @ 1cd8789 | `GID-REDACTED` |
| Notes | `notes.md` | `apple-notes-mcp` @ 2.5.12 | `GID-REDACTED` |
| Calendar | `calendar-reminders.md` | `mcp-server-apple-events` @ 1.4.0 (calendar half) | `GID-REDACTED` |
| Reminders | `calendar-reminders.md` | `mcp-server-apple-events` @ 1.4.0 (reminders half) | `GID-REDACTED` |

## Parity is verified against the live MCP (the oracle)

**RETIRED 2026-08-30:** the six Apple MCPs were retired after `v26.0.0` shipped
(private fleet-config repo `REVISION-REDACTED`); hosts converge on their next whole-tree apply, so the
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

This repo is published. **Every committed byte is public**: source, tests, fixtures, comments,
docs, JSON artifacts, AND commit messages. Nothing that identifies a real person may be committed —
not the operator's, and especially not a third party's (theirs is not ours to disclose).

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
byte-lengths in write-ups — not values. `.gitignore` matches audit dumps BY CLASS (not by known
filename) because the 2026-08-03 leak was a dump whose name matched none of the enumerated
patterns.

**Before every `git add`, check the diff for personal data**, and re-check the commit message
separately — a file-path history rewrite (`filter-repo --path`) does NOT touch commit messages, so
a leak there survives the obvious fix.

**If you find personal data already committed: STOP and tell the operator immediately.** Redact at
HEAD right away (cheap, always correct, forecloses nothing), and treat history rewriting as the
operator's decision alone — it force-pushes published history and never reaches forks, caches, or
existing clones. Never rewrite or force-push without an explicit instruction. The standing record
of such incidents is `HUMAN-DECISIONS.md` (D7, D9). The repo was made private on 2026-08-19
(containment); D9 remediation was applied 2026-08-23, and on 2026-08-29 the operator authorized
three further targeted `filter-repo` passes that removed the residual leaks the pre-1.0 audit
surfaced (see the D9 entry's 2026-08-29 amendment). The pre-1.0 PII gate (Asana
`GID-REDACTED`) is CLOSED with zero residual hits; no rollback artifacts remain. The default
posture is restored: no history rewrite or force-push is authorized without a fresh explicit
operator instruction. Private status is temporary containment, NOT a licence to relax this rule.

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
on any conflict, and it may never authorize a destructive or outward-facing action. (The D9
handoff copy was removed 2026-08-29 as the final step of the now-closed PII gate, Asana
`GID-REDACTED`; no retained artifacts remain.)

## Commits + review

- **Conventional Commits.** Commit + push directly to `main` frequently, after the review and
  test gates below pass. Do not recreate the retired integration or domain branches.
- **Code review: use the OMC reviewers, skip codex.** Before each commit, fan out
  `oh-my-claudecode:code-reviewer` + `security-reviewer` + `critic`; address
  material findings; record `Reviewed-by:` + AI `Co-Authored-By:` trailers.
- **Re-scan the staged diff and the proposed commit message for personal data immediately before
  every commit.** On the main-only workflow, the commit is the publication event.
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
