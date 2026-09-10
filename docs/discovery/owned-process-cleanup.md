# Owned process cleanup and deterministic I/O completion

Date: 2026-09-10. Status: accepted implementation plan; implementation and its
verification remain pending. Scope is internal to
`Sources/AppleKit/AppleScriptRunner.swift`, with focused coverage in
`Tests/AppleKitTests/ScriptLauncherTests.swift`.

## Problem and compatibility contract

The current launcher signals only its direct child. Blocking stdin and output
workers can remain alive after timeout or delivery failure when a descendant
inherits the opposite pipe ends. A timed stdin invocation whose root exits while
output EOF remains pending also lacks descendant cleanup. Its current regression
waits for the descendant's natural exit rather than establishing owned cleanup.

Preserve public delivery APIs, argv, inherited environment and current directory,
error types and precedence, output decoding, signal-number status representation,
and intentional successful background work. Existing cancellation triggers remain
deadline expiry, stdin delivery failure, and output read failure, including errors
discovered after root exit. A diagnosed timeout remains `TimeoutError` despite
cleanup-induced EPIPE; a diagnosed delivery failure remains `launchFailed`.
Timed-inline capture read failures currently propagate the underlying `FileHandle`
error. Preserve that error through cleanup without wrapping it in
`RunError.launchFailed`; piped output read failures retain their existing
`launchFailed` classification.

A completed nonzero `ScriptOutcome` still returns from the launcher for
`result(of:)` to interpret. Its status alone does not authorize group cancellation.
This plan makes no new output-cap decision and does not add an output limit.

## Implementation sequence

1. Introduce one internal launch-session owner using Darwin `posix_spawn`.
   Before launch, set `POSIX_SPAWN_SETPGROUP` with pgroup zero, establishing a child
   group whose PGID equals its PID. Set `POSIX_SPAWN_CLOEXEC_DEFAULT`; configure
   explicit stdin/stdout/stderr dup/open actions and close-on-exec parent
   descriptors. Keep source descriptors above 2 so initially closed standard
   streams cannot make action ordering overwrite another source. Close child-side
   copies in the parent immediately after spawn, and roll back every descriptor,
   action and attribute on setup or spawn failure. Preserve argv, environment and
   current directory. Set `POSIX_SPAWN_SETSIGMASK` with an empty signal mask and
   `POSIX_SPAWN_SETSIGDEF` with a full default-signal set: these preserve the
   measured local Foundation child behavior described below. Diagnose
   `posix_spawn` from its returned error number, not `errno`.

2. Give the owner exclusive child-observation and reaping responsibility. Observe
   termination with zero-initialized `siginfo_t` and
   `waitid(P_PID, pid, WEXITED | WNOHANG | WNOWAIT)`. Cache the exact exit or signal
   status while retaining the waitable root until no further group signals are
   possible. Retain the PGID established before child execution; Darwin may return
   ESRCH from `getpgid` for the unreaped zombie. Signal only the session-owned PGID
   greater than 1 and distinct from the caller's group. Never signal using zero,
   minus one, a saved Foundation PID, or a group number after reaping. Do not mix
   Foundation termination callbacks with raw waits for the same child. Hold this
   authority through timed-inline capture reads, since a capture read failure
   still requires owned cleanup. Reap exactly once after complete outcome/capture
   success or the final cleanup signal. Preserve signal-number outcomes rather
   than changing them to shell-style `128 + signal` values.

3. Replace the feeder and both drains with one synchronous nonblocking `poll`
   loop. The calling thread owns all pipe descriptors; create no per-invocation
   I/O workers. Set `O_NONBLOCK` only on parent pipe ends, keep child ends blocking,
   and retain `F_SETNOSIGPIPE` on the parent stdin writer. Handle partial reads and
   writes, EINTR, EAGAIN, EPIPE, EOF, and POLLHUP/ERR/NVAL explicitly. Process finite
   chunks per ready descriptor and revisit the absolute monotonic deadline between
   chunks, so sustained output cannot starve another stream or the deadline.
   Close stdin immediately after script delivery. Use short bounded poll slices
   for child observation. Timed stdin has one deadline spanning delivery,
   execution and EOF; untimed success paths gain no deadline.

4. On an existing cancellation trigger, latch the original error, stop delivery,
   and enter bounded group TERM/grace/KILL cleanup while root identity remains
   reserved. Root exit after TERM does not prove descendant exit and must not
   suppress escalation. A zombie root also makes `kill(-pgid, 0)` unsuitable as
   proof that all live descendants stopped. After the final permitted signal,
   reap the root if waitable and close every launcher-owned pipe and capture
   descriptor before returning. Cleanup must not replace the original error.
   Timed stdin with root exit but EOF pending beyond its deadline follows this
   same timeout cleanup sequence.

5. Preserve mode-specific completion. Inline and stdin paths retain their existing
   EOF requirements; untimed paths may intentionally wait indefinitely for
   successful descendant output. Timed inline retains unlinked regular-file
   capture and completes on root exit, allowing successful background work to
   continue. Successful capture, including capture after a nonzero root exit,
   must not cause group signalling. Read capture through an explicit-offset,
   fixed observed-length snapshot: do not change an inherited shared file offset
   or chase later background appends indefinitely. Preserve immediate unlink,
   private permissions and capture-directory injection. Snapshot capture never
   guarantees future descendant output, and this design does not claim a hard
   realtime bound for disk I/O.

6. Remove obsolete workers and comments only after focused lifecycle tests pass.
   Keep public seams stable; add narrow internal seams only for deterministic
   read-error injection, descriptor closure, wait behavior and signal-before-reap
   ordering. Then run the full canonical repository gate on the integrated change.
   This plan does not authorize concurrent test execution.

## Ownership limits

`WNOWAIT` reserves the root only while the launcher owns reaping. SIGCHLD
auto-reap (`SIG_IGN` or `SA_NOCLDWAIT` where applicable), foreign `waitpid(-1)`
consumers and other process-global reaping can invalidate that authority. Source
inspection found no custom child waits or SIGCHLD manipulation in the current
production sources. Preflight known unsupported dispositions without changing
global signal policy. ECHILD revokes signalling authority. A check immediately
before signalling is not atomic protection against a concurrent foreign reaper;
this is a library precondition, not a Darwin pidfd-equivalent guarantee.

Groups cover inheriting descendants; a process can escape through `setsid` or
`setpgid`. Do not expand cancellation into process-tree scans or termination of
Apple applications reached through AppleEvents. Parent resources must still close
if a descendant escapes.

An uninterruptible kernel task can outlive SIGKILL. Bounded return, immediate
reaping and zero outstanding lifecycle work cannot all be guaranteed in that
case. If final bounded observation cannot reap the root, transfer only its PID
and reap obligation to one module-owned nonblocking eventual-reaper registry.
Transfer no descriptors or signalling authority, and do not create an indefinitely
blocked reap thread per call. Test this transfer through an injected wait seam;
actual uninterruptible kernel behavior is outside deterministic test control.

## Required verification

- Preserve existing output, argv, status and error tests, large bidirectional
  traffic, early EPIPE, TERM handling, TERM-ignoring children, and absence of named
  capture files.
- Verify that ready-marked roots and grandchildren ignoring TERM are stopped on
  timeout. Also cover root exit before a descendant releases inherited pipe ends;
  the drain deadline must cause bounded group cleanup rather than natural-exit
  waiting.
- Verify delivery and injected read failures close every launcher-owned descriptor
  even while descendants hold opposite pipe ends. Repeat invocations to expose
  accumulation, preferably with explicit owner instrumentation rather than
  ambient descriptor counts. No I/O-worker lifetime can remain because no such
  worker is created.
- Preserve timed-inline background survival for both zero and nonzero completed
  root statuses. Also cover successful pipe invocations whose background children
  close output. Fixtures must safely clean up their own tracked background
  processes; production success must leave them alive.
- Pin `observe WNOWAIT -> injected capture read failure -> owned group signals ->
  final reap`. Assert that the injected timed-inline capture error retains its
  identity and classification through cleanup, all capture descriptors close,
  and owned group cleanup precedes reaping. Test rejection of invalid/caller group
  IDs, lost authority and the eventual-reaper transfer. Never deliberately target
  a reused real PID. A
  PPID-plus-numeric-PID watchdog is insufficient proof against PID reuse.
- Cover initially closed standard descriptors, unrelated inherited descriptors,
  setup/spawn failures, output after root exit, sustained-output deadlines,
  malformed wait/error paths, and exact signal-status mapping. Compile the actual
  Swift imported C calls under both toolchains; local API documentation alone
  does not establish interoperability.
- Run the repository's complete canonical build/test gate after focused tests
  pass, with no overlapping process-test runs.

## Feasibility evidence and its boundaries

Standalone synthetic C/Swift probes on arm64 macOS 26 produced identical results
under CLT Swift 6.3.2 and swiftly Swift 6.3.3. A C child inspected signal state at
entry, before an interpreter could change it. Under representative inherited
ignored, caught and blocked signals, Foundation children had empty masks and no
ignored signals. Raw spawn defaults retained blocked and ignored signals;
explicit empty-mask/full-default attributes matched Foundation. These are
observations of the tested runtime/toolchain combinations, not future guarantees.

All 12 final raw children passed repeated matching WNOWAIT observations, selective
reaping with the expected exit status, and ECHILD after reap. All 12 concurrent
Foundation children completed with their expected exit status and termination
reason; no cross-reaping was observed. Live raw PGIDs equalled their PIDs.
Postexit `getpgid` returned ESRCH for unreaped roots, confirming that group
creation and retained wait authority must be tracked separately. The probe's
initial contrary expectation was corrected, and all synthetic children were
reaped. Foundation children also formed separate groups locally, which does not
provide control over Foundation's earlier reaping or a portable grouping promise.

Those probes did not exercise descriptor actions, `CLOEXEC_DEFAULT`, failure group
signalling, descriptor cleanup or I/O cancellation. They do not establish immunity
to arbitrary foreign reapers, detached descendants or uninterruptible tasks.
The required focused regressions above remain necessary.

Local primary references are the SDK's `spawn.h`, `sys/wait.h`, `sys/fcntl.h`, and
manual pages for `posix_spawn`, its attribute setters, `sigaction`, `kill`,
`setpgid`, `setsid`, `fcntl`, `poll`, `read` and `write`. They document pre-exec
attributes/actions, default-close behavior, retained waitability, special signal
targets, parent-side grouping races, nonblocking I/O and `F_SETNOSIGPIPE`.

## Alternatives excluded from this scope

Calling `setpgid` after Foundation launch races exec. Killing only the root leaves
inherited pipe holders. Closing a handle under another thread's blocking read
does not establish a deterministic join. Three cancellable workers add lifecycle
coordination that one poll loop avoids. Kqueue or process-tree discovery adds
complexity without removing the ownership limits above.
