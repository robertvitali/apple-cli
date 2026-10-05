---
topic: coverage
importance: high
last-used: 2026-10-05
uses: 1
---

# Coverage measurement

## 2026-10-05 — A line reached only by timing flips coverage totals: force the ordering in a test

**Symptom.** The launcher's per-descriptor deadline throw (`OwnedScriptProcess.swift:496`) was
covered in 3 of 8 serial coverage builds and in none of four baseline runs. That one line moved
AppleKit's coverage total, so two serial runs of one commit could disagree, and PR 5, which touched
no AppleKit file, read as a per-target regression in one run and not in the other.

**Fix (`4494e1d`, tests only).** `ProcessResourceTests` "a deadline that passes while one descriptor
is served ends that turn" runs over the synthetic backend. On the first poll stdout and stderr are
at end of file and the stdin write end, whose reader is closed, reports an event. The recording I/O
stalls the first read for longer than the two-second deadline, which the launcher set before that
read, so the deadline passes inside the turn and the next descriptor's check throws. The test
requires one read and no write; with the check removed, stderr is read, the stdin write meets EPIPE
and the launch reports a delivery failure, so the test fails. A serial two-run re-measurement on
`4494e1d` gave identical totals and line sets, with the line covered in both runs.

**Residual.** An attempt that served no descriptor is re-run, at most twice, only when the timeout's
SIGTERM came no sooner than the deadline could have passed. Three runner stalls of two seconds or
more before the first read, in a row, fail a correct launcher; on hosted runners that is the process
withholding recorded in `hosted-ci.md` (2026-10-05).

**Lesson.** A baseline that requires identical totals and line sets across runs needs every line's
covered status to be stable from run to run. Find unstable lines by comparing per-line covered sets
across serial builds, and compare sets, not only totals, since flips can cancel in a total. Then
reach each such line with a test that forces the ordering the line needs, here a stall that outlasts
a deadline set before it, instead of relying on when the scheduler happens to run things.
