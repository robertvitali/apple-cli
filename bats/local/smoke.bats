#!/usr/bin/env bats

BATS_SUITE_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
REPO_ROOT="$(cd "$BATS_SUITE_ROOT/.." && pwd -P)"
HELPERS="$BATS_SUITE_ROOT/helpers"
# Local process-lifecycle tests. They exercise snapshot cleanup through read-only Messages
# commands and therefore stay out of hosted and fork-reachable CI.

setup() {
  BIN="$(swift build --show-bin-path)/apple"
}

# These lifecycle checks require chat.db snapshots. Probe the database independently of the CLI
# under test: only a missing database or an explicit permission denial may skip.
require_messages_database() {
  local xtrace_was_on=0 probe_status
  case "$-" in
    *x*) xtrace_was_on=1; set +x ;;
  esac

  run /usr/bin/python3 "$HELPERS/messages_db_probe.py"
  probe_status="$status"
  output=""
  lines=()

  if [ "$probe_status" -eq 77 ]; then
    [ "$xtrace_was_on" -eq 0 ] || set -x
    skip "Messages database is missing or unreadable; Full Disk Access may be required"
  fi
  if [ "$probe_status" -ne 0 ]; then
    [ "$xtrace_was_on" -eq 0 ] || set -x
    echo "Messages database preflight failed unexpectedly" >&2
    return 1
  fi
  [ "$xtrace_was_on" -eq 0 ] || set -x
}

@test "a snapshot-backed run cleans up after itself and reaps dead sessions" {
  BIN="$(swift build --show-bin-path)/apple"
  ROOT="${TMPDIR%/}/apple-cli-snapshots"
  TAG="batstest-$$-$RANDOM"

  require_messages_database

  # Plant a DEAD session (a .lock nobody holds) and a foreign directory that must survive.
  mkdir -p "$ROOT/s-999999-$TAG" "$ROOT/keepme-$TAG"
  : > "$ROOT/s-999999-$TAG/.lock"
  : > "$ROOT/s-999999-$TAG/payload.sqlite"

  run "$BIN" messages chats
  [ "$status" -eq 0 ]

  # Positive control: the root exists, so the copy path really executed. Without it every assertion
  # below passes vacuously on a machine where the command never got that far.
  [ -d "$ROOT" ]

  # The reaper call site ran: the dead session is gone, the foreign directory untouched.
  [ ! -d "$ROOT/s-999999-$TAG" ]
  [ -d "$ROOT/keepme-$TAG" ]
  rmdir "$ROOT/keepme-$TAG"

  # No orphans anywhere: every surviving session directory must still be LOCKED by a live process.
  # This is what catches a deleted `atexit` — our own directory would outlive the exit with its lock
  # released by the kernel, and so be acquirable here.
  orphans="$(/usr/bin/python3 "$HELPERS/unlocked_sessions.py" "$ROOT")"
  [ -z "$orphans" ] || { echo "orphaned session directories left behind: $orphans"; false; }
}

# --- signal teardown: SIGINT/QUIT/TERM/HUP must not strand a snapshot -------------------------
# `atexit` does not run on a signal death, so before this the operator pressing Ctrl-C during a
# slow read left a session directory behind — holding copies of their mail at 0600 — until some
# later run's liveness sweep reaped it. Measured before the fix: SIGTERM exit 143, one directory
# stranded; SIGHUP and SIGQUIT the same.
#
# This has to live in bats, not the logic tier: the property only exists in a real process that
# really dies of a real signal. (The one part that does NOT need a signal — that the tracked set
# covers every file in the directory, which is what actually broke first time round — is a logic
# test, in Tests/AppleKitTests/SignalCleanupRegistryTests.swift.)
#
# THE PREDICATE IS THE CHILD'S OWN DIRECTORY, NOT A COUNT. The first version of this test counted
# `s-*` directories before and after, which is exactly what rule 2 above forbids, and review
# reproduced both failure directions: a pre-existing orphan that the child's own reaper legitimately
# removed drove the count BELOW the baseline and failed deterministically, and under one concurrent
# `apple` the detector was defeated so the test `skip`ped — reported by bats as `ok` — citing a
# reason ("finished early") that was false. Session directories are named `s-<pid>-<uuid>`, so
# asserting on the child's own pid is race-free in both directions and needs no baseline.
#
# It also asserts the child really died OF THE SIGNAL (128+signum). Without that, a run that
# completed before the signal landed would satisfy the leak check vacuously — and that assertion is
# the only coverage of the "re-raise so the shell sees the conventional status" property.

# Wait, FORK-FREE, until the child's own session directory appears, then signal it.
#
# Fork-free matters. The first version ran `find | wc | tr` per poll — three processes each pass,
# competing for CPU with the ~40ms process it was timing — and by the time it noticed the directory
# the command had usually finished normally, so `wait` returned 0 and the signal never landed. Shell
# globbing is a builtin: it keeps up. Sets `SIG_PID_DIR` to the directory, or returns 1 if the run
# completed before it could be caught (a raced leg, which the caller declines to count).
signal_midflight() {   # $1 = pid, $2 = signal name; sets SIG_PID_DIR
  local g spins=0
  SIG_PID_DIR=""        # never carry a previous leg's directory into this one
  # BOUNDED. The first version was `while :;` with no cap, which wedges the whole suite if the
  # child hangs — a TCC prompt, a blocked SQLite read, a stalled $TMPDIR — and bats has no
  # per-test timeout. That is strictly worse than the fork-heavy loop it replaced, which at least
  # terminated. ~200k fork-free spins is far longer than the ~40ms the child needs and still
  # finite; exhaustion is reported as a raced leg, not a pass.
  while [ "$spins" -lt 200000 ]; do
    spins=$((spins + 1))
    for g in "$ROOT"/s-"$1"-*; do
      if [ -d "$g" ]; then SIG_PID_DIR="$g"; kill -"$2" "$1" 2>/dev/null || return 1; return 0; fi
    done
    kill -0 "$1" 2>/dev/null || return 1
  done
  return 1
}

# Refuse to race pre-existing residue for this pid. The glob matches on pid ALONE, so a stale
# `s-<pid>-*` left by an earlier crash — and the docstring for the declined fatal-fault signals says
# those leave exactly that — would be latched instead of the child's own directory. The reaper then
# removes the stale one and the assertion passes having tested nothing. Review reproduced this.
require_no_stale_session_for() {
  local g
  for g in "$ROOT"/s-"$1"-*; do
    [ -e "$g" ] || continue
    echo "pid $1 was reused and stale residue exists at $g — cannot attribute the result"; return 1
  done
  return 0
}

# NOTE ON `wait`: it must be called in the test body, never inside `$( )`. A command substitution
# is a subshell, the job is not ITS child, and `wait` then reports a status unrelated to the process
# — measured `-1`, which silently satisfied the nohup test's `!=` comparison and made it survive
# having its guard deleted. The `|| st=$?` shape is also required: under bats' `set -e` a bare
# `wait` on a signal-killed child aborts the test before the status can be read.

@test "a signalled run leaves no session directory behind" {
  BIN="$(swift build --show-bin-path)/apple"
  ROOT="${TMPDIR%/}/apple-cli-snapshots"
  ran=0

  # JOB CONTROL ON. Without it a POSIX shell starts a background job with SIGINT and SIGQUIT set to
  # SIG_IGN, the arm guard then correctly declines to install those two handlers, and the child runs
  # to completion — `st=0`, a failure that looks like a broken handler but is the guard doing its
  # job. `set -m` puts the child in its own process group with default dispositions, which is the
  # posture an operator pressing Ctrl-C at a terminal actually has. (The inherited-ignore posture is
  # the NEXT test, which asserts the opposite outcome for the same signals.)
  set -m

  # INT=2 QUIT=3 TERM=15 HUP=1 — the four the handler installs.
  for pair in INT:2 QUIT:3 TERM:15 HUP:1; do
    sig="${pair%%:*}"; num="${pair##*:}"

    "$BIN" messages chats >/dev/null 2>&1 &
    pid=$!
    require_no_stale_session_for "$pid" || false

    if ! signal_midflight "$pid" "$sig"; then
      wait "$pid" 2>/dev/null || true
      continue          # never `skip`: skip aborts the whole test, so one raced leg would
                        # silently retire the other three. Just don't count this leg.
    fi

    st=0; wait "$pid" 2>/dev/null || st=$?
    [ "$st" -eq $((128 + num)) ] || {
      echo "expected death by SIG$sig ($((128 + num))), got $st — the handler may not have run"; false; }

    # The handler unlinks the snapshot and its sidecars, then `.lock` LAST, then rmdirs. `.lock`
    # goes last on purpose: it is what the liveness reaper keys on, so removing it first made a
    # partial failure slower to clean up than having no handler at all.
    [ ! -d "$SIG_PID_DIR" ] || { echo "SIG$sig stranded $SIG_PID_DIR"; false; }
    ran=$((ran + 1))
  done

  set +m
  # Non-vacuity, with an HONEST reason. A raced leg is tolerated per-leg above so one hiccup does not
  # retire the other three, but zero legs means nothing was asserted — and the two ways that happens
  # need telling apart. The version this replaced conflated them and printed a cause that was false.
  if [ "$ran" -eq 0 ]; then
    require_messages_database
    "$BIN" messages chats >/dev/null 2>&1 \
      || { echo "messages chats failed despite a readable Messages database"; false; }
    echo "the command runs here, yet no leg ever became observable"; false
  fi
  [ "$ran" -eq 4 ] || { echo "only $ran/4 signal legs ran; the rest never became observable"; false; }
}

# --- inherited SIG_IGN must survive -----------------------------------------------------------
# POSIX: a program must not catch a signal it inherited as ignored. `nohup` and a POSIX shell's
# background-job setup both hand a child SIG_IGN precisely so it survives, and installing over it
# took that away — measured 3/3, `nohup apple …` died at 129 where it previously ran to completion.
# A truncated export on terminal logout is a silent failure, which is why this is pinned here.
#
# Signalled mid-flight through the same fork-free wait, so the child is provably still running when
# the signal arrives; a run that finished first proves nothing and is not counted.

@test "a run in the nohup posture is not killed by the signal it was told to ignore" {
  BIN="$(swift build --show-bin-path)/apple"
  ROOT="${TMPDIR%/}/apple-cli-snapshots"
  ran=0

  require_messages_database

  for pair in INT:2 HUP:1; do
    sig="${pair%%:*}"; num="${pair##*:}"
    sh -c "trap '' $sig; exec '$BIN' messages chats >/dev/null 2>&1" &
    pid=$!
    require_no_stale_session_for "$pid" || false

    signal_midflight "$pid" "$sig" || { wait "$pid" 2>/dev/null || true; continue; }
    st=0; wait "$pid" 2>/dev/null || st=$?
    # `-eq 0` is the strongest claim available and these runs do complete normally. `-ne
    # $((128+num))` would pass on ANY other outcome including a 134 crash; even `-lt 128` would
    # accept a nonzero error exit. Survival means a clean exit.
    [ "$st" -eq 0 ] || {
      echo "SIG$sig killed a process that inherited SIG_IGN (status $st) — the arm guard is gone"; false; }
    ran=$((ran + 1))
  done

  if [ "$ran" -eq 0 ]; then
    "$BIN" messages chats >/dev/null 2>&1 \
      || { echo "messages chats failed after a successful database preflight"; false; }
    echo "the command runs here, yet no leg ever became observable"; false
  fi
}
