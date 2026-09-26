---
topic: hosted-ci
importance: high
last-used: 2026-09-26
uses: 3
---

# Hosted CI (public, free GitHub-hosted runners)

## 2026-09-26 — Python's idea of whitespace is not YAML's: a no-break space hid a write from the workflow scan

**Symptom.** Codex, reviewing an unrelated commit, found that `scripts/ci/workflow_policy.py`
passed `run: echo ok<NBSP># ; gh release create v1` with no violation. The parser ended the
comment at the no-break space; YAML and bash do not, so the runner would have run the release
command (with a read-only token, so no release would have been published).
Review of the first fix then found the escaped form (`runs-on: "ubuntu-latest\_"` decoded to a
no-break space and `strip()` made it an admitted label), and the same character had let an
`@<sha><NBSP>#<NBSP>v7.0.1` pin read as approved in both scanners.

**Cause.** `str.isspace`, `str.strip` and regex `\s` accept 29 code points (`str.splitlines`
breaks on 10 of them);
YAML separates tokens only at space and tab and (1.2) breaks lines only at line feed and
carriage return. Every hand-written YAML reader built on those helpers inherits the gap.

The shell adds one more: bash and dash silently drop a NUL, so a decoded `\0` splits a command
name for a regex but not for the shell (`g\0h` runs `gh`).

**Fix.** Refuse, before parsing and again after decoding escapes, any whitespace other than
space, tab and line feed and any character outside YAML's printable set; compare allowlisted
values exactly, never after `strip()`; keep the rule in one predicate per scanner with a test
that the copies agree for every code point.

**Lesson.** A parser-based check is only as faithful as the parser. When a scan's verdict
matters, refuse input the parser might read differently instead of trying to interpret it,
and say in the record that the refusals narrow the residual rather than remove it. Other
hand-rolled readers in `scripts/ci/` (`pr_metadata.py`'s trailer split, `dependency_policy.py`)
use the same helpers and are a follow-up.

## 2026-09-21 — first public CI runs after 19 days private: hosted-only defects, none reproducible locally

**Symptom.** The repository went public on 2026-09-21 (its hosted minutes were exhausted while
private) and the first `CI` run on `main` went red in three jobs while `Docs` stayed green. Every
red step had been unexercised since the last hosted run on 2026-09-02; the local canonical suite
(both Swift toolchains, `swift test`, `bats -r bats/`) was green on the same commit throughout.

**Causes and fixes.**

1. **`hosted-bats` — pinned Bats install.** `npm install` of the integrity-pinned `bats@1.13.0`
   tarball did not create the `node_modules/.bin/bats` link on the current hosted image (the
   package declares its executables through `directories.bin`, which npm does not universally
   link). The step now checks `node_modules/bats/bin/bats` is executable and hands that absolute
   path to the policy through `BATS_EXECUTABLE` instead of widening `PATH`.
2. **`Supply-chain policy` (Ubuntu, Python 3.12) — the only job that runs `Tests/automation`.**
   - `scripts/ci/coverage_policy.py` hard-coded `/private/tmp` as the snapshot root; Linux has
     no `/private`. The root is now the first existing entry of a fixed list
     (`/private/tmp`, `/tmp`), with the platform default only as a last resort.
   - A runtime-bindings test read the macOS-only `time.CLOCK_UPTIME_RAW` through the real
     clock/reset guard. The accessor fixture now supplies the pinned constant on every host and a
     separate darwin-only test checks the real host value. **A `skipUnless(darwin)` in this
     suite is a test no CI job runs** — do not use it to make Linux green.
   - An app-lifecycle timing test used a 40 ms setup window that a loaded hosted runner expired
     before the first observation started; timeout and sleeps were widened 10x (poll left as is).
3. **`build-test` (`macos-15`, older Swift than the local toolchain).** A six-way string
   concatenation literal in `PathConfinementTests` exceeded the hosted type-checker's expression
   budget ("the compiler is unable to type-check this expression in reasonable time"). Split into
   typed `let`s. The local toolchain accepts the original, so this class of failure is only
   visible hosted.

4. **`build-test` (`macos-15`) — second run, after the type-check fix.** Two logic-tier tests
   failed on Foundation behaviour that differs between macOS 15 and the current release:
   - `URL.resolvingSymlinksInPath()` through a symlink whose final target is a DIRECTORY came back
     with a different directory flag (trailing slash) than the URL built by
     `appendingPathComponent`, so a URL `==` failed while the paths were equal. Compare `.path`
     when the assertion is about where a write lands, not about the URL's directory-ness.
   - `NSString.expandingTildeInPath` on an unknown `~user/…` returns the spelling unchanged on
     macOS 27 but substitutes the PROCESS HOME on macOS 15 (only those two releases were
     observed; the package floor is macOS 14, so 14, 16 and 26 are unverified either way). A
     guard that relied on the "unchanged" behaviour to refuse the form let `~nosuchuser/x.bin`
     resolve to `$HOME/x.bin` there. The Notes attachment guard now refuses any `~user` form
     other than the current account's own name before expanding, checked on unicode scalars
     (a combining mark after the tilde is one grapheme to Swift but still a tilde to Foundation).
   - Diagnostic method worth reusing: the parameterised test's failure line named the one
     argument combination that failed (`dirlink`, the only directory target), which is what
     isolated the directory-flag difference without a macOS 15 host. A throwing expression
     inside `#expect` prints no operand values on failure; bind it to a `let` first.

5. **`build-test` (`macos-15`) — a later run, on a docs-only commit: a timing-margin flake on
   unchanged code.** `OwnedProcessCleanupTests` "drain timeout stops the descendant after the
   root has exited" asserted the root's exit was observed within 1.5 s of the test's start.
   On the loaded runner (fewer cores than the local host, the whole suite in flight) process
   startup through the descendant's first observation took longer than that, on code that had
   passed the identical test one run earlier. The stopwatch assertion is gone: a test-only
   decorator over the real child operations stamps, on the same `CLOCK_MONOTONIC` the fixture
   uses, when `spawn` returned and when cleanup first signalled the group, and the test
   asserts event order — spawn ≤ observed exit < first cleanup signal, and first signal ≥
   spawn + the 2 s deadline. Start-up latency on a slow runner moves every stamp together.
   Residual, stated: the root must still exit inside the same 2 s drain deadline the
   production path uses; a runner too slow for that fails as a missing
   `root-observed-exited` read, not as a timing assertion, and the `root-exiting` marker
   (written only on the voluntary branch) says whether the root ever got that far. A hosted
   failure on unchanged code is a timing margin: replace the stopwatch with the event order
   it was standing in for.

**Follow-up — the tilde-expansion sites.** Landed 2026-09-22 as ONE shared helper,
`AppleKit.TildeSpelling.ownHome`, applied by the attachment resolver (`AttachmentSource.resolve`,
which Mail `--attach` and Messages `--file` share) and by `PathConfinement`
(`confineWriteDestination`, `refuseFinalLeafSymlink`, `rawFinalLeafPath`); the Notes save-path
guard delegates to it. Mail's `save-attachments` destination helpers
(`WriteManageCommands.swift`) expand through the same policy so a foreign spelling reaches
confinement unexpanded and is refused there. The complete list of remaining raw
`expandingTildeInPath` calls: `Sources/NotesKit/AttachmentFS.swift` `resolvedPath` (internal;
every caller has already passed the guard or supplies an allowed-root constant), and the two
lowest-consequence sites that take no operator argument — `Sources/MessagesKit/ChatDB.swift`
(store-sourced existence probe) and `Sources/AppleKit/RateLimiter.swift` (env-supplied state
paths).

**Lessons.**

- Hosted CI is Ubuntu plus `macos-15`; local development tracks the current macOS. A green local
  run is not evidence for the hosted lanes, and vice versa (recorded in AGENTS.md
  "Toolchain + testing").
- Reproduce hosted Python failures locally in a Linux container before pushing a fix: Colima and
  `docker run --rm -v <copy>:/work -w /work ubuntu:24.04` with `apt-get install python3` gives
  the same 3.12 interpreter. Mount a copy under `$HOME` (Colima shares only home paths; a mount
  under `/private/tmp` appears empty inside the VM). `python:3.12-slim` lacks `/usr/bin/python3`
  and is the wrong image for tests that pin that path.
- After a long private stretch, expect hosted-image drift (npm behaviour, toolchain versions) on
  the first public run; budget one fix-and-rerun cycle rather than treating the red as a code
  regression.
