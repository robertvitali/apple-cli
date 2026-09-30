---
topic: hosted-ci
importance: high
last-used: 2026-09-30
uses: 9
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
use the same helpers and are a follow-up, as are the scan parser's own paths outside block
scalars (flow sequences and sequence entries), which no differential has covered yet. The same review found the structural cousin: block
scalars read with a different indentation rule than YAML's hid a line from the scan. Check a
parser's structural rules against a real YAML loader (libyaml via Ruby's Psych was on hand),
not only its character handling: a seeded differential over generated block scalars found 983
differences in 4,000 documents before the fix, including trimmed values that had slipped past
exact comparisons. Widen the generator before trusting a zero: the first run's 0 in 12,000 never
produced a tab or an unterminated final line, and adding both found a comment-looking line with
a tab that YAML refuses and the parser skipped; with both in, 0 in 32,000 (15,161 accepted by
both, the rest refused by at least one).

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
     observed then; the package floor is macOS 14, so 14 stays unverified; macOS 26 later
     substituted the home too, through `URL(fileURLWithPath:)`, item 6). A guard that relied on
     the "unchanged" behaviour to refuse the form let `~nosuchuser/x.bin` resolve to
     `$HOME/x.bin` there. The Notes attachment guard now refuses any `~user` form other than the
     current account's own name before expanding, checked on unicode scalars (a combining mark
     after the tilde is one grapheme to Swift but still a tilde to Foundation).
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

6. **`build-test` (`macos-26`) — the first run on the new image, 2026-09-30** (image
   `macos-26-arm64` 20260907.0351.1, macOS 26.6.2). One logic-tier test failed on a Foundation
   difference: on macOS 26, `URL(fileURLWithPath:)` turns a leading foreign `~user` spelling
   (another account, an unknown one, or a tilde plus a combining mark) into the PROCESS home, as
   `expandingTildeInPath` did for an unknown user on macOS 15; macOS 27 leaves it as a
   cwd-relative spelling, and on macOS 15 it kept the tilde (the follow-up's table below). Mail's
   `normalizeDestinationPath` routed such a spelling through `URL(fileURLWithPath:)`, so it no
   longer kept the tilde its test demands. No command was affected, because every production
   caller confines before normalizing and the confinement refusals passed on the same run. The
   helper now returns a foreign spelling unchanged, and the test asserts exact equality, which
   the old helper fails on macOS 27 too; its "still contains a tilde" check could only fail on a
   release that substitutes. Lesson: when a test pins a release-dependent behaviour, assert the
   exact value, so every release, the local one included, can fail it.

7. **`build-test` (`macos-26`) — every test green, job red: a read-only filesystem inside the
   isolated HOME, 2026-09-30** (same image). On attempt 1 of one CI run, all 1968 Swift tests
   passed, then `scripts/ci/quality.py` failed to delete its temporary root: `OSError: [Errno
   30] Read-only file system` under
   `hosted-build/home/Library/Developer/DVTDownloads/MetalToolchain/mounts/`. The cause is
   inferred, not observed: SwiftPM runs `xcrun --find metal` whenever it sets up its toolchain
   on Darwin (swiftlang/swift-package-manager#9434, so in `swift test` as well as `swift build`),
   and public reports describe Xcode 26 mounting its downloadable Metal toolchain on demand, so
   the most likely reading is that this lookup mounted the toolchain's image under the stage's
   isolated HOME, which sits inside the tree the driver deletes. Whether Xcode 26.6's bundled
   SwiftPM carries that change, and who owns the mount, were not established. It is
   intermittent: the same attempt's `hosted-bats-build` job ran the same isolated-HOME build
   through the driver and cleaned up; the previous commit's run on the same image version
   cleaned up; and the re-run of the failed jobs failed on an unrelated timing flake and also
   cleaned up. "Cleaned up" is all those runs show; the driver did not log mounts then.

   Prevention was rejected: SwiftPM's lookup has no switch; dropping HOME isolation for the
   build stages gives up the isolation to fix a flake; pre-running the lookup with the real
   HOME assumes Xcode reuses that mount; and redirecting `DVTDownloads` hard-codes an Xcode
   path. The driver now tolerates the mount instead. It creates its root with `mkdtemp` and
   records the root's identity, and it walks and deletes the tree by descriptor from that
   root: a replaced root is refused, no symlink is followed, each directory gets owner access
   so nothing unreadable hides a mount, and the delete never crosses onto another filesystem.
   It detaches only an attached disk image, matched by device number through `hdiutil info`
   and detached by the image's whole-disk node (for APFS, the image rather than the container
   macOS synthesizes for it), never by a path a stage could redirect, and not at all unless
   `hdiutil` records a volume of that image mounted at the scanned path and none outside the
   root; it forces a detach only when a rescan still finds the mount. It logs the mount-table
   device, type and flags and whether the runner user mounted it (not the name), so the next
   occurrence settles who mounted the filesystem and what it is. Anything that stays mounted
   is reported and the rest of the tree is left in place.
   On a hosted runner, which is discarded after the job, that report is a warning annotation
   and the stage verdict stands; in local mode it fails the run. Verified on the local macOS
   27 host, by calling the functions directly against read-only images this session attached
   as the same user: HFS+ and APFS images (GUID and flat layouts) were detached from inside the
   root, and an APFS image from under a mode-000 directory; a root swapped for a symlink to a
   directory holding a mount was refused with that mount left alone. Not verified: detaching
   the mount Xcode itself makes on `macos-26`. macOS 27 prints a deprecation warning for
   `hdiutil detach` and suggests `diskutil eject`; it still works, and a removed verb would
   surface as a reported cleanup failure, not a silent skip. Known gap:
   `scripts/ci/capability_policy.py` also runs `swift build` and `swift test` under a HOME
   inside a `TemporaryDirectory`; no workflow runs it today, but on an Xcode 26 host it can hit
   the same failure. Lesson: an isolated HOME keeps a tool's writes out of the runner's real
   home, but a tool can also mount there, so cleanup must handle filesystems it did not
   create, and must do so without trusting paths the code under test can change.

8. **`build-test` (`macos-26`) — a stopwatch bound equal to the deadline it guards,
   2026-09-30** (same image). The re-run of item 7's failed jobs failed one logic-tier test,
   "overflow aborts while stdin is pending and the empty sibling stream remains open": it took
   3.35 s against a 3 s bound, with the overflow correctly reported. The bound was the same
   number as the stdin delivery deadline, and the stopwatch starts before the spawn while the
   deadline starts after it, so interpreter start-up on a loaded runner could cross the bound
   with no behaviour change at all. The test now uses a 30 s deadline, a 20 s alarm in the
   fixture and a 10 s bound. Checked red against a launcher that stops reading output while
   stdin is pending: the test fails after about 20 s with the wrong error. Lesson: a
   wall-clock bound needs headroom below the deadline it stands in for; when the two are the
   same number, the test measures the runner, not the code.

**Follow-up 2026-09-26 — the order check flaked too, and the residual in item 5 was incomplete.**
Hosted CI failed the same test again, on a commit that changed no Swift code, now at the order
check: the descendant recorded the root's exit 52 ms after cleanup's first signal. Two
corrections to item 5. Start-up latency does not move every stamp together: the launcher starts
its deadline when `spawn` returns, so the root's interpreter start-up sits inside the deadline.
And a runner too slow for the deadline fails in one of three shapes, not one. A root still in
interpreter start-up when SIGTERM arrives has not yet ignored it (spawn resets every signal to
its default), dies, and leaves no `root-observed-exited` file, as item 5 predicted. A root that
has armed its handlers and finishes within cleanup's one-second pause before SIGKILL exits on its
own and the descendant records it: the order-check failure seen on 2026-09-26. A root still
running at SIGKILL again leaves no observation file. The signature also cannot tell a slow root
from a late observation, since the descendant polls every 10 ms and can be starved. The test now
holds the launcher's deadline in its stamping decorator until the root has published its
identity, reads the launcher's own first observation of the exit for the order check, checks that
the root leads its own process group and that the kernel's membership of that group is empty
after cleanup (survivors seen whether or not they published), publishes fixture files by
write-then-rename, and re-runs an attempt that still misses the scenario at most twice, printing
why; any failed product check fails the test. The sibling tests in the file
(`timeoutStopsOwnedGroup`, the two completed-capture tests, and all three phases of the
output-limit test) also run Python start-up inside a two- or three-second deadline and share the
start-up exposure; the decorator's readiness gate would apply to them directly, but they call the
plain launcher and do not use it yet. General lesson: an event-order assertion is only as good as
the observer that stamps the event. Stamp it where the product sees it, and keep what the
scenario needs before the product's own deadline starts outside that deadline.

**Follow-up — the tilde-expansion sites.** Landed 2026-09-22 as ONE shared helper,
`AppleKit.TildeSpelling.ownHome`, applied by the attachment resolver (`AttachmentSource.resolve`,
which Mail `--attach` and Messages `--file` share) and by `PathConfinement`
(`confineWriteDestination`, `refuseFinalLeafSymlink`, `rawFinalLeafPath`); the Notes save-path
guard delegates to it. Mail's `save-attachments` destination helpers
(`WriteManageCommands.swift`) expand through the same policy so a foreign spelling reaches
confinement unexpanded and is refused there. The complete list of remaining raw
`expandingTildeInPath` calls: `Sources/NotesKit/AttachmentFS.swift` `resolvedPath` (internal;
every caller has already passed the guard or supplies an allowed-root constant), and the
lowest-consequence site that takes no command-line argument, `Sources/MessagesKit/ChatDB.swift`
(store-sourced existence probe). `Sources/AppleKit/RateLimiter.swift` (state paths from
environment variables the operator sets) was also on this list until 2026-09-30, when it moved
under the shared policy (see the follow-up below).

**Follow-up 2026-09-30 — the audit after the first `macos-26` run.** A read-only audit asked,
for every site under `Sources/` (outside `TestSupport`) that calls `URL(fileURLWithPath:)`,
`expandingTildeInPath`, `standardizingPath`, `standardizedFileURL` or `resolvingSymlinksInPath`,
whether an operator-supplied value can still start with a tilde when Foundation sees it; every
exposure it reported went through an adversarial check. At `1f8f3ab`, `git grep -nE
'URL\(fileURLWithPath:|expandingTildeInPath|standardizingPath|standardizedFileURL|resolvingSymlinksInPath'
1f8f3ab -- Sources ':!Sources/TestSupport'` matches 43 code lines (55 with comments) in 19 files;
the audit assessed them as 41 sites, counting related calls (a chain, or one helper's several
calls) as one. What each API does with a foreign `~user` spelling, by release:

| API | macOS 15 | macOS 26 | macOS 27 |
|---|---|---|---|
| `expandingTildeInPath` | unknown user: the process home (observed, item 4) | not observed | unknown user: unchanged (observed, item 4) |
| `URL(fileURLWithPath:)` | tilde kept: the old "still contains a tilde" assertion passed on every hosted `macos-15` build from `8e9be32` through `e011d83` (observed) | another account, an unknown one, or a tilde plus a combining mark: the process home (observed, item 6) | a cwd-relative spelling that keeps the tilde (observed locally) |

Four surfaces, in three places, take such a value outside the shared policy. Each is LOW: only the operator can
supply the spelling, and every outcome is a read or write the operator's own account could make
directly.
- `Sources/ContactsKit/ContactsOutput.swift` `readBoundedFile`: the `contacts` `--file`
  argument goes to `URL(fileURLWithPath:)`. On macOS 26 that reads a file in the operator's home
  (inferred from the table); on macOS 15 and 27 a path relative to the working directory. The
  25 MB size check runs `attributesOfItem(atPath:)` on the raw spelling, which never expands a
  tilde, so for a foreign spelling it finds nothing and the cap is skipped before the read
  resolves elsewhere. The same held for `~/…` and for a trailing slash, which the read still
  resolved (observed on macOS 27 when the change below landed), so an oversized file there was
  read in full. Attachment sources refuse the foreign spelling (validation, 64).
- `Sources/MailKit/Support/TemplateStore.swift`: `APPLE_MAIL_MCP_HOME`, the template root that
  list, get, render, save and delete all use, also goes to `URL(fileURLWithPath:)`, with the
  same per-release outcomes.
- `Sources/AppleKit/RateLimiter.swift`: `APPLE_SEND_RATELIMIT_STATE` and
  `APPLE_REPLY_RATELIMIT_STATE`, the two state paths listed above as deliberate exceptions, go to
  `expandingTildeInPath` first: an unknown user became the home on macOS 15 (observed), a known
  other account becomes that account's home (observed on macOS 27 when the change below landed:
  `~root/x` gave `/var/root/x`), and macOS 26 is not observed.
  The result then goes to `URL(fileURLWithPath:)`, so a tilde that survives the first step becomes
  the process home on macOS 26 (inferred from item 6) and a cwd-relative path on macOS 27.
Every other site was judged safe (confined or refused first, or only ever handed an absolute
path) or not operator input (store-owned values, constants). Bringing the four under the shared
policy changes what those commands accept, so it is its own change with its own release note.
That change landed on 2026-09-30 for three of the four. `contacts` `--file` and the two
rate-limit variables resolve through `TildeSpelling.expandedOwnHome` and refuse another user's
`~user`, or a tilde followed by a combining mark, as a `validation_error`; `mail send`,
`forward`, `draft send` and `reply` resolve their variable on the dry-run path too, so a preview
refuses what `--execute` refuses. The rate limiters fail closed because a malformed variable is a
deterministic configuration error (like a malformed `APPLE_SCRIPT_MAX_OUTPUT_BYTES`); their
degraded fail-open path is for runtime I/O failures. The `--file` reader measures its size limit
on the path it reads (a trailing slash is handled because `expandingTildeInPath` drops it); a
final symbolic link is still measured as the link, not its target, and devices, FIFOs and growth
between the check and the read are open follow-ups. The fourth, `APPLE_MAIL_MCP_HOME`, went the
other way (operator ruling D39): oracle A never expanded a tilde there, so the value is read
literally, a relative value joined to the working directory before Foundation sees it (or, when
the working directory has been deleted and `currentDirectoryPath` is empty, kept relative behind
`./` so its I/O fails as the oracle's did), and an empty value treated as unset. The first draft
of that release note claimed the oracles expanded `~alice` to that account's home; the critic
read oracle A's source and found no expansion at all. State an oracle's behaviour only from its
source. Later the same day D40 replaced `APPLE_MAIL_MCP_HOME` with `APPLE_MAIL_TEMPLATES_DIR`,
which follows the shared policy, and moved the default folder to `~/.apple-cli/mail-templates/`;
D39's literal reading lapsed with the variable.

**Lessons.**

- Hosted CI is Ubuntu plus `macos-26` (`macos-15` until 2026-09-29); local development tracks
  the current macOS. A green local run is not evidence for the hosted lanes, and vice versa
  (recorded in AGENTS.md "Toolchain + testing").
- Reproduce hosted Python failures locally in a Linux container before pushing a fix: Colima and
  `docker run --rm -v <copy>:/work -w /work ubuntu:24.04` with `apt-get install python3` gives
  the same 3.12 interpreter. Mount a copy under `$HOME` (Colima shares only home paths; a mount
  under `/private/tmp` appears empty inside the VM). `python:3.12-slim` lacks `/usr/bin/python3`
  and is the wrong image for tests that pin that path.
- After a long private stretch, expect hosted-image drift (npm behaviour, toolchain versions) on
  the first public run; budget one fix-and-rerun cycle rather than treating the red as a code
  regression.
