# apple-cli — integration status (overnight build, 2026-07-15/16)

> **SUPERSEDED IN PART (2026-08-01, write-model v2 — docs/write-model-v2.md).** This file is a
> dated snapshot of the 2026-07-15/16 overnight run; its safety-posture claims describe THAT
> NIGHT, not the current tree. Since then: the live write paths were wired (2026-07-2x), and
> the **Mail domain flipped to write-model v2** — Mail writes now EXECUTE when invoked
> (`--dry-run` previews; `APPLE_TEST_MODE`/`--test-mode` is an opt-in sandbox restriction, not
> a write prerequisite; the trash surface keeps dry-run as its default). Read the "v1
> two-factor gate" statements below as historical. Remaining domains flip per the spec's
> rollout order.

**TL;DR.** All six domains are implemented to strict-superset MCP parity, each
independently reviewed (3-pass OMC) and verified green, then aggregated onto the
`integration` branch with a shared-core hardening pass. The combined tree builds
clean and passes **341 swift-testing tests (76 suites) + 117 bats tests**. **Zero
live writes** occurred — every write path ships as a preview/guard and executes
nothing. What remains is **operator-gated** and could not be done unattended:
live end-to-end verification against the MCP oracles (needs TCC grants),
wiring the deferred live-write paths, merging to `main`, and the `1.0.0` tag +
MCP retirement.

The complete, verified tree is on **`origin/integration`** (commit `a-prior-commit`).
`main` was never touched.

---

## Verification state

| Check | Result |
|---|---|
| `swift build` (all 6 domains + shared core) | ✅ clean |
| `swift test` (logic tier, no TCC) | ✅ 341 tests / 76 suites |
| `bats -r bats/` (CLI smoke tier) | ✅ 117 tests |
| Live writes this session | ✅ none (TEST-CLEANUP.md empty) |
| `main` pushed | ✅ never (operator-gated) |

Reproduce:

```sh
git fetch && git checkout integration      # or: cd .worktrees/integration
export PATH="$HOME/.swiftly/bin:$PATH"
swift build && swift test && bats -r bats/
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

## Safety posture (held all night)

- **Zero live writes.** `TEST-CLEANUP.md` is empty — nothing was created on any
  real store. Every domain's write/delete/send path is implemented as a
  **preview/guard** and executes nothing; the default is `--dry-run`, and
  `--execute` without the full `APPLE_TEST_MODE=1 + --test-mode` gate is refused
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
   now emit a JSON error envelope (`tool:"apple"`, `validation_error`, exit 64).
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

1. **Live e2e / MCP-oracle diff.** Run the `integration` binary against the live
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
3. **Merge to `main`.** `origin/integration` (`a-prior-commit`) is the complete, verified
   tree — merge it (not the six feature branches individually, or the shared-core
   fixes are lost). Re-run `swift test` + `bats` on `main` after.
4. **Tag `1.0.0` + retire the MCPs** once live e2e passes, per the retirement gate
   in `docs/DESIGN.md`.
5. **`SQLiteReader immutable=1` (M2).** A Messages-specific perf/PII hardening
   (the current `copyToTemp` of chat.db leaves a full copy in `$TMPDIR` if the
   process dies). Left for its own review because it touches the shared reader's
   WAL-read path used by Messages/Mail/Notes/Contacts — verify live reads with
   TCC when you land it.

---

*Generated by the overnight orchestration run. Continuity log:
`scratchpad/ORCHESTRATION-STATUS.md`.*
