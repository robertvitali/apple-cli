# apple-cli — integration status (overnight build, 2026-07-15/16)

> **HISTORICAL SNAPSHOT (2026-07-15/16 overnight run) — SUPERSEDED for ALL six domains by
> write-model v2 (`docs/write-model-v2.md`).** This file records where the integration tree
> stood that night; do NOT read its present-tense safety-posture, test-count, or `main`-status
> claims as the current state. Since then **all six domains flipped to write-model v2** (rollout
> order Mail → Contacts → Notes → Calendar+Reminders → Messages, completed 2026-08; the last
> `@available(*, deprecated)` v1 remnants were deleted in Q15, integration HEAD `a-prior-head`).
> Under v2, writes EXECUTE when invoked, `--dry-run`/`APPLE_DRY_RUN=1` preview, and
> `APPLE_TEST_MODE`/`--test-mode` is an opt-in SANDBOX policy (a label/self-recipient restriction
> on the real store, `sandbox: true` in the success envelope and `error.sandbox: true` on a
> sandbox refusal), NOT a write prerequisite. Every "v1 two-factor gate" and "zero live writes"
> statement below is therefore historical for ALL domains; `main` has since advanced with the
> live-write wiring and perf work (see `git log main`). For the current model read
> `docs/write-model-v2.md`; for current status read `docs/COMPLETION-LOOP.md`. On 2026-08-23,
> the verified domain/integration histories were consolidated onto rewritten `main`; all other
> local and remote branches and all worktrees were retired by operator direction. Future work is
> main-only unless the operator explicitly reverses that ruling.
> The rewrite is containment, not erasure: it cannot reach existing clones, forks, or caches.
> PII-bearing D9 rollback artifacts remain temporarily retained, and the pre-1.0 re-audit and
> cleanup gate (Asana `GID-REDACTED`) remains OPEN and blocks item 4 below.

**TL;DR (2026-07-16 snapshot).** All six domains are implemented to strict-superset MCP parity, each
independently reviewed (3-pass OMC) and verified green, then aggregated onto the
`integration` branch with a shared-core hardening pass. The combined tree built
clean and passed **341 swift-testing tests (76 suites) + 117 bats tests** *at that time* —
the suites have grown substantially since (run `swift test` / `bats -r bats/` on the current
HEAD for live counts). **Zero live writes** occurred *that night* — but write-model v2 has since
made writes execute by default, and tracked/labeled/cleaned-up live writes have happened under
the AGENTS.md conduct rules. The live-write paths have since been **wired** (write-model v2, all
domains). What remains **operator-gated**: live end-to-end verification against the MCP oracles
(TCC grants), and the `1.0.0` tag + MCP retirement.

At this snapshot the tree was on `origin/integration` commit `a-prior-commit`; that branch later advanced
through the write-model-v2 work (pre-rewrite HEAD `a-prior-head`), and `main` later took the live-write
wiring + perf commits. Both SHAs predate the 2026-08-23 rewrite and are unreachable from current
`main`; they remain here only as historical snapshot identifiers.

---

## Verification state (2026-07-16 snapshot — counts have since grown; see current HEAD)

| Check | Result (as of 2026-07-16) |
|---|---|
| `swift build` (all 6 domains + shared core) | ✅ clean |
| `swift test` (logic tier, no TCC) | ✅ 341 tests / 76 suites *(snapshot; far higher now)* |
| `bats -r bats/` (CLI smoke tier) | ✅ 117 tests *(snapshot; far higher now)* |
| Live writes this session | ✅ none (TEST-CLEANUP.md empty) |
| `main` pushed | ✅ never *(true as of this snapshot; main has since advanced)* |

Reproduce:

```sh
git status --porcelain   # must be empty before proceeding
git fetch origin && git switch main && git pull --ff-only
(
  export PATH="$HOME/.swiftly/bin:$PATH"
  swift build --scratch-path .build-swiftly &&
  swift test --scratch-path .build-swiftly
) &&
/usr/bin/swift build &&
env PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" bats -r bats/
```

---

## Per-domain status

All six are **implemented + reviewed + verified green + safety-cleared**. Each
replaces its MCP server(s) at operation+parameter+behavior granularity; each
extends beyond the MCP where useful. Full per-capability matrices live in
`docs/port-specs/`.

| Domain | Branch tip | Tests (swift / bats) | Review verdict | Notes |
|---|---|---|---|---|
| Messages | `b394913` | 54 / 19 | APPROVE | Live read-parity vs `mac_messages_mcp` (chat.db, FDA). DoS/limit guards, allowlist-normalize. Additive typed-`Row` SQLiteReader extension (adopted as canonical). |
| Mail | `6a8e77d` | 64 / 17 | APPROVE (≈25 findings fixed) | Union of two MCPs. Live read-parity vs both oracles. **No live-mutation path reachable** (rule/draft mutators defined-but-never-called; all writes emit `executed:false` preview). CRLF/MIME header-injection fixed. |
| Contacts | `84daa08` | 51 / 32 | APPROVE (1 CRITICAL fixed) | 21/21 live read-parity. Fixed `--text` flag collision that had silently killed `note set` + `vcard import` at parse time; added all-21-leaf `--help` guard. |
| Notes | `88a42f2` | 52 / 17 | APPROVE | SQLite reads live-parity. gzip-bomb clamp, protobuf+path-guard tested, golden-JSON + exit-code matrix. |
| Calendar | `23be5d7` | 71 / 16 | APPROVE | Built the shared **EventKitCore** engine first (frozen `8d30189`). Enum wire-strings verified verbatim vs MCP source (oracle hangs on TCC). Fixed a real `EKWeekday(rawValue:8)` NSException. |
| Reminders | `eabc31b` | 94 / 24 | APPROVE (1 CRITICAL fixed) | Built on frozen EventKitCore (additive `Subtask`/`subtask_progress` fields only). Subtask/tag notes byte-compatible with MCP source. Write-safety CRITICAL fixed (see below). |

Shared core (`AppleKit`) + `EventKitCore` merged cleanly (only additive
`Package.swift` test-target lines conflicted; resolved to the full 8-target set).

---

## Safety posture (held all night — HISTORICAL, superseded by write-model v2)

> The mechanism described here is the v1 two-factor gate as it stood on 2026-07-16.
> It no longer describes the tree: under write-model v2 writes EXECUTE by default and
> the `APPLE_TEST_MODE=1 + --test-mode` prerequisite is gone (see the banner + `docs/write-model-v2.md`).

- **Zero live writes** *(that night)*. `TEST-CLEANUP.md` was empty — nothing was created on any
  real store. At that time every domain's write/delete/send path was implemented as a
  **preview/guard** and executed nothing; the default was `--dry-run`, and
  `--execute` without the full `APPLE_TEST_MODE=1 + --test-mode` gate was refused
  (exit 77/64 depending on domain).
- **No dangerous actions.** No mail sent, no iMessage sent, no existing real data
  modified or deleted, no permanent-delete/empty-trash.
- **A write-safety class-bug was caught in review before it could ever run.**
  Three domains (Reminders CRITICAL, Calendar HIGH, Contacts MEDIUM) had
  id-addressed writes that checked the *passed* name rather than the *fetched*
  target — so e.g. `tasks delete --id <any real id> --execute --test-mode` would
  have deleted an arbitrary real reminder. All three were fixed to fail-closed on
  the fetched target's label. Crucially, the guard was **never reached this
  session** (the three-flag gate was never all-set), so no real data was touched.
  This is the standing rule for 1.0: **every id-addressed write/delete must
  fail-closed on the fetched target's label** — audit the whole fleet before
  enabling live writes.

---

## Shared-core hardening (task #7, commit `a-prior-commit`)

Three fixes to `AppleKit` + the `apple` entry point, reviewed by the full OMC
fan-out (all APPROVE, no P1), with all findings addressed:

1. **Parse errors now honor the output contract.** ArgumentParser parse failures
   (bad flag, missing arg, unknown subcommand) previously printed plain text to
   stderr with nothing on stdout — violating "stdout = JSON envelope only". They
   now emit a JSON error envelope (`validation_error`, exit 64) whose `tool` names
   the domain from `argv[1]` when it resolves one, else `"apple"` (Q7-L3(a)).
   The human-readable detail (which can echo argv) stays on stderr; the stdout
   envelope carries a **generic** message so an operator-supplied secret can't
   leak onto the agent-captured channel. A latent double-emit bug (the entry
   point re-printing runGuarded's already-emitted envelope and clobbering the
   77/65 exit code to 64) was caught by bats and fixed by catching `ExitCode`
   first.
2. **Test-mode label gate can't be vacated.** An empty/whitespace
   `APPLE_TEST_SANDBOX` no longer collapses the fail-closed prefix guard
   (`hasPrefix("")` is always true). Extracted a pure `normalizedPrefix(from:)`
   so the security property is unit-tested without mutating process env.
3. **The error-fallback can't emit malformed JSON.** `Output.emitError`'s
   last-ditch path now RFC-8259-escapes every interpolated string.

Locked with 5 new swift-testing tests + 4 new bats parse-error tests (the
double-emit bug was reachable only through the binary, not swift tests).

---

## Deferred parity gaps (documented, for 1.0 — all minor)

- **Mail — needs-response ranking:** the "direct-To-you" ranking boost is dropped
  (needs a per-message recipient join); documented in code. Also a read-state
  caveat on `needs_response` counts.
- **Mail — `entire_mailbox` export:** exports snippet, not full body, for the
  whole-mailbox case (single-email export has full body).
- **Notes — sync-awareness:** three read ops don't surface iCloud sync state
  (the MCP warns on a text channel); documented.
- **Reminders — `--text` no-op + a timezone-offset edge case;** documented.

None block parity; each is noted in the relevant `docs/port-specs/` file and/or
in code.

---

## Operator next-steps (gated — need you + granted TCC)

Ordered. Nothing here is safe to do unattended, which is why it waited.

1. **Live e2e / MCP-oracle diff.** Run the `main` binary against the live
   MCP servers for read ops across all six domains and diff (CLI JSON must be a
   superset of each MCP field). Calendar/Reminders/Contacts use frameworks that
   will prompt for TCC on first run — grant them. (Messages/Mail/Notes read
   parity was already verified per-branch under the existing FDA/AppleScript
   grants.)
2. **Wire the deferred live-write paths.** All domains currently preview/guard
   and execute nothing. Wire the real writes behind the existing
   `APPLE_TEST_MODE=1 + --test-mode` gate, and **audit every id-addressed
   write/delete to fail-closed on the fetched target's label** (the class-bug
   above) before enabling.
3. **Consolidate on `main`.** Completed 2026-08-23 after a verified history rewrite. The
   integration and six domain branches/worktrees were then retired; `main` is the sole branch.
4. **HARD STOP — D2, operator-present only.** No agent may tag `1.0.0` or unregister any MCP
   server. This is additionally blocked by the pre-1.0 PII re-audit gate (Asana
   `GID-REDACTED`). After both gates clear, follow the retirement gate in `docs/DESIGN.md`.
5. **`SQLiteReader immutable=1` (M2).** A Messages-specific perf/PII hardening
   (the current `copyToTemp` of chat.db leaves a full copy in `$TMPDIR` if the
   process dies). Left for its own review because it touches the shared reader's
   WAL-read path used by Messages/Mail/Notes/Contacts — verify live reads with
   TCC when you land it.

---

*Generated by the overnight orchestration run. Continuity log:
`scratchpad/ORCHESTRATION-STATUS.md`.*
