---
topic: hosted-ci
importance: high
last-used: 2026-09-21
uses: 1
---

# Hosted CI (public, free GitHub-hosted runners)

## 2026-09-21 — first public CI run after 19 days private: three hosted-only defects, none reproducible locally

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
