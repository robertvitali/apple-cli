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

| Domain | Port spec | Replaces (MCP) | Asana parent |
|---|---|---|---|
| Messages | `messages.md` | `mac_messages_mcp` @ 99388d2 | feat/asana-GID-REDACTED-messages |
| Mail | `mail.md` | `apple-mail-mcp` (s-morgan-jeffries@0.6.0 **+** patrickfreyer@3.1.3) | feat/asana-GID-REDACTED-mail |
| Contacts | `contacts.md` | `apple-contacts-mcp` @ 1cd8789 | feat/asana-GID-REDACTED-contacts |
| Notes | `notes.md` | `apple-notes-mcp` @ 2.5.12 | feat/asana-GID-REDACTED-notes |
| Calendar | `calendar-reminders.md` | `mcp-server-apple-events` @ 1.4.0 (calendar half) | feat/asana-GID-REDACTED-calendar |
| Reminders | `calendar-reminders.md` | `mcp-server-apple-events` @ 1.4.0 (reminders half) | feat/asana-GID-REDACTED-reminders |

## Parity is verified against the live MCP (the oracle)

The Apple MCP servers are still installed on the fleet. **Use them as the parity
oracle**: for each capability, run the MCP tool AND the `apple` CLI on the same
input and diff the results. The CLI's JSON must contain every field the MCP
returned (superset — may add more, must not drop any).

- **Read ops** (get/list/search) — compare freely; safe.
- **Write ops** — only as clearly-labeled, tracked, cleaned-up test data on the real
  store (see Safety). Never a dangerous action; never diff a real send/mutation.

## Safety — track-and-cleanup, and never a dangerous action

There is no separate sandbox. Test writes go to the real stores, under strict rules:

1. **Create only clearly-labeled test data**, name-prefixed `apple-cli-test` (reminders,
   events, notes, contacts, lists/calendars, mail drafts).
2. **Log every created item immediately** to `TEST-CLEANUP.md` (gitignored) with enough to
   delete it later: kind, id, name, list/folder/account.
3. **Clean up via the MCP** (the known-good oracle) at the end of each run — delete ONLY the
   tracked ids from `TEST-CLEANUP.md`. Never a bulk or fuzzy delete.
4. **Messages:** send ONLY to the operator's own number (given in the kickoff brief) — never
   anyone else.
5. **Mail:** drafts only, or send only to the operator's own address — never a real recipient.

Gate writes behind `APPLE_TEST_MODE=1` + `--test-mode`; default destructive commands to `--dry-run`.

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
docs/versioning-policy.md SemVer + JSON-schema-as-contract policy
```

**Shared-core coordination:** Calendar and Reminders both depend on `EventKitCore`. Build
the real engine ONCE, first, in the **Calendar** worktree and stabilize it; then start
Reminders by branching/rebasing onto the Calendar branch so it has the core, and build only
the reminders surface. Never edit `EventKitCore` from both worktrees at once. (So the six
lanes are really four parallel + the EventKit pair serialized on the core.)

**Shared helpers live in `AppleKit` — never reinvent per-domain.** Already built: `Output`
(JSON envelope), `runGuarded` + `AppleError` (the error→envelope+exit boundary — throw an
`AppleError`, don't hand-pair emit+exit), `GlobalOptions` (`--json`/`--text`, `--dry-run`/
`--execute`, `--test-mode`), `AppleScriptRunner` (pass user text via `arguments:`/argv —
NEVER string-interpolate it into script source; injection is RCE-class), `SQLiteReader`
(read-only, WAL-aware, parameter-bound), `Permissions` (FDA preflight), and `TestMode`
(fail-closed write guard). Extend these in `AppleKit`. A new shared dependency (Notes needs
protobuf; Messages needs fuzzy-match; SQLite is the system lib) means a coordinated
`Package.swift` edit — the one shared-contention file.

## Toolchain + testing

Swift 6. On a Command-Line-Tools-only Mac, use the swiftly toolchain (it bundles
`swift-testing`; macOS XCTest needs full Xcode, which we avoid):

```sh
export PATH="$HOME/.swiftly/bin:$PATH"
swift build --scratch-path .build-swiftly
swift test  --scratch-path .build-swiftly   # logic tier — swift-testing (import Testing), no TCC
bats -r bats/                               # CLI smoke tier — runs the built binary
```

**Why `--scratch-path`:** `/usr/bin/swift` (Command Line Tools) and the swiftly toolchain are
different Swift versions, and they cannot share a build cache — mixing them fails with
`module compiled with Swift <a> cannot be imported by the Swift <b> compiler`, which looks like
a broken diff but is only a stale cache. Keep the two out of each other's way: swiftly builds go
to `.build-swiftly/` (gitignored), the CLT `swift build` keeps the default `.build/`. `bats` runs
whichever binary was built last, so build before you run it.

Three test tiers: **logic** (swift-testing, pure — CI), **CLI smoke** (bats,
invokes the binary — CI + local), **live** (drives the real Apple frameworks
against the sandbox — real Mac with granted TCC, not CI). Add golden-JSON
snapshot tests + an exit-code matrix per domain, and MCP-diff parity tests.

## Worktrees + branches

Per-domain work happens in an in-repo worktree, one feature branch each:

```
branch:   feat/asana-<parent-gid>-<domain>
worktree: .worktrees/asana-<parent-gid>-<domain>   (gitignored)
```

## Commits + review

- **Conventional Commits.** Commit + push to the **feature branch frequently**;
  **do NOT push to `main`** (domains merge to main only after verified parity).
- **Code review: use the OMC reviewers, skip codex.** Before each commit, fan out
  `oh-my-claudecode:code-reviewer` + `security-reviewer` + `critic`; address
  material findings; record `Reviewed-by:` + AI `Co-Authored-By:` trailers.
- Tests green before any push (`swift test` + `bats`).

## Output contract (agent-facing)

`stdout` = JSON envelope only; `stderr` = human text. Envelope:
`{ "schema_version": <int>, "tool": "<domain>", "ok": <bool>, "data"|"error": … }`.
**JSON is the default** (the machine contract); `--text` (from `GlobalOptions`) is a human
opt-out and is NOT part of the versioned contract. Property names are the wire keys verbatim
(no case conversion — name payload fields in snake_case); dates are ISO-8601. Adding optional
fields = MINOR; removing/renaming/retyping a field, or changing an enum/exit-code, = MAJOR.
See `docs/versioning-policy.md`.
