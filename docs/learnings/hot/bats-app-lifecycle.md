---
topic: bats-app-lifecycle
importance: high
last-used: 2026-09-21
uses: 1
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
