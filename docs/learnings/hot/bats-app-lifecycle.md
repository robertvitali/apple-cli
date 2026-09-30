---
topic: bats-app-lifecycle
importance: high
last-used: 2026-09-30
uses: 2
---

# Local Bats app-lifecycle harness

## 2026-09-21 — macOS 27 changed `lsappinfo info -only` rendering; teardown refused with `info-line-shape`

**Symptom.** After the host moved to macOS 27, every local Bats file whose teardown observed a
running Mail or Notes failed with `app lifecycle operation failed: info-line-shape`, while files
that observed no running candidate passed. It first appeared during a period of genuine host load
and was misread as LaunchServices degradation; the load was real but not the cause.

**Cause.** On macOS 27 `lsappinfo info -only <key> … -app <ASN>` no longer prints the compact
`"key"=value` lines the parser expected. It prints the block layout (`"Name" ASN:…:` header,
`bundleID=…`, `pid = N token=[…]`, `checkin time = YYYY/MM/DD HH:MM:SS ( … ago )`), and the
`-only` variant omitted the check-in line for a hidden Mail instance on this host (2026-09-21)
while printing it for Finder, so the plain form is the reliable one. An unknown ASN now prints
nothing at all (exit 0) instead of four `[ NULL ]` fields — and so does every malformed
invocation (bad flag, non-ASN argument, no argument): empty-plus-exit-0 is not a reliable
"process gone" signal on its own. The observe loop therefore fails after three consecutive
rounds in which `find` names a live ASN but `info` reports nothing (`find-info-disagree`).

**Fix.** The helper queries the plain block form (`info -app ASN`) and the parser accepts both
layouts: the header must carry the requested ASN (a new instance-binding check), the bundle id,
pid and absolute check-in timestamp are read from their lines, every other line is ignored, and
empty output maps to `STOPPED`, and the real rendering's trailing blank line is tolerated (the
first cut of the fix rejected it — the reviewers' live re-run caught that). The stability digest continues to hash only the absolute timestamp (the legacy path already
stripped the relative age), so the
relative "ago" part cannot make the same instance look different between reads.

**Second lesson, same day.** The Python tier's watchdog-signal test times out whenever INT, QUIT or
HUP are already ignored when bash starts, because bash `trap` is a silent no-op for signals
ignored at entry. Async jobs of a non-interactive shell inherit exactly that (nohup adds HUP), so a
suite launched in the background fails that test while a foreground run passes. Launch the
canonical suite through a wrapper that resets those dispositions to default before exec.

## 2026-09-30 — a recent check-in prints a relative-age prefix; teardown refused with `info-fields-missing`

**Symptom.** After the host restarted, a local Bats file whose tests launched Notes or Messages
failed its `teardown_file` with `info-fields-missing` while all its cases passed, and the
launched app was left running. Later files failed the same way while that leftover app stayed
inside the window below, because teardown parses the info block of every running app of the six,
not only the ones it will terminate (3, 5 and 3 teardown failures in three canonical runs).
`bats bats/local/notes.bats` alone reproduced it from a clean state. Before the restart the suite
was green because Notes and Messages had been open for hours and the tests reused them.

**Cause.** For a check-in in its first five minutes or so, macOS 27.0 prints the check-in line
with a relative age before the absolute timestamp: `checkin time = 90 seconds ago, YYYY/MM/DD
HH:MM:SS ( 1 minutes, 29.98 seconds ago )`; afterwards the plain form returns. The block recorded
here also carried a `launch time = …` line, which the parser ignores. Observed on this host: the
prefix counts in seconds only (seen at 90 and 161 seconds, and during review, value-free, through
240 seconds on two processes), and it switched to the plain form at about 300 seconds with the
same absolute timestamp as before. The compact-layout pattern has accepted this prefix since
2026-09-07; the 2026-09-21 port to the block layout dropped it, and its fixtures, taken from
long-running apps, never showed it. Lesson: when porting a parser to a new layout, carry every
accepted variant forward. Diagnosis detour worth remembering: querying with `-only` keys printed
`[ NULL ]` placeholders for the fields it did not select, which looked like a half-registered
app; the helper's own `info -app ASN` output was complete (see the entry above on why `-only` is
unreliable here).

**Fix.** Both patterns now share one optional prefix, `CHECKIN_AGE_PREFIX_PATTERN` (`N second(s)
ago, `), and capture only the absolute timestamp, so one process yields the same identity on both
sides of the switch (a test pins three renderings to one exact identity). Any other unit, a
missing count or separator, or an age after the timestamp is still refused, and those tests pin
the refusal to `info-fields-missing`. The helper's digest in `scripts/ci/bats_inventory.py`'s
hosted-helper catalog moves with it. Until the fix landed, the workaround was to open Notes and
Messages before a run and wait for the plain form.
