#!/usr/bin/env bats
# CLI smoke tests — logic tier, no Apple permissions required. Runs on a
# Command-Line-Tools-only machine (no full Xcode needed) because it only invokes
# the built binary.

setup() {
  BIN="$(swift build --show-bin-path)/apple"
}

@test "apple --version prints a version" {
  run "$BIN" --version
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "apple --help lists all six domains" {
  run "$BIN" --help
  [ "$status" -eq 0 ]
  for d in messages mail contacts notes calendar reminders; do
    echo "$output" | grep -q "$d"
  done
}

@test "stub domains emit a JSON envelope with schema_version and ok=false" {
  run "$BIN" messages
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '"schema_version"'
  echo "$output" | grep -q '"ok" : false'
  echo "$output" | grep -q '"tool" : "messages"'
}

# --- parser-level error path (Apple.swift main() catch) ------------------------------------
# These exercise ArgumentParser errors that fail in parseAsRoot() and never reach a command
# body — the ONLY path with no in-body runGuarded envelope. They are the regression guard for
# the double-emit/exit-code-clobber bug and the argv-echo-onto-stdout security fix, neither of
# which any swift test can reach (main() calls Foundation.exit).

@test "root-level parse error emits a tool:apple validation envelope (exit 64)" {
  run "$BIN" --nonexistent-flag
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"tool" : "apple"'
  echo "$output" | grep -q '"type" : "validation_error"'
  echo "$output" | grep -q '"ok" : false'
}

@test "unknown subcommand emits a tool:apple validation envelope (exit 64)" {
  run "$BIN" nosuchdomain
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"tool" : "apple"'
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "parse error emits EXACTLY ONE envelope on stdout (no double-emit regression)" {
  # The double-emit bug printed two envelopes and clobbered the exit code (77/65 → 64).
  # Capture stdout ONLY, count envelopes, and require a single valid JSON object.
  # `|| true` so the exit-64 command substitution doesn't itself fail the bats test.
  local out; out="$("$BIN" --nonexistent-flag 2>/dev/null || true)"
  [ "$(printf '%s' "$out" | grep -c '"schema_version"')" -eq 1 ]
  printf '%s' "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['tool']=='apple' and d['ok'] is False and d['error']['type']=='validation_error'"
}

@test "parse-error detail (may echo argv) stays on stderr, NOT the stdout machine envelope" {
  # `version` takes no positional args, so an extra token is 'Unexpected argument <token>' —
  # a parse error whose ArgumentParser message echoes the token. The token must NOT land on
  # stdout (the agent-captured channel); the generic message must, with detail on stderr.
  local out
  out="$("$BIN" version SENTINEL_SECRET_XYZ 2>/tmp/apple_perr.$$ || true)"
  ! echo "$out" | grep -q "SENTINEL_SECRET_XYZ"        # generic on stdout
  echo "$out" | grep -q '"tool" : "apple"'
  echo "$out" | grep -q 'see stderr for details'
  grep -q "SENTINEL_SECRET_XYZ" "/tmp/apple_perr.$$"   # detail on stderr
  rm -f "/tmp/apple_perr.$$"
}

# ── Write-model v2 sweep invariant (docs/write-model-v2.md, rollout step 2) ─────────────────────
# v2 flips writes to execute-by-default, so a flagless write invocation in this suite — a safe
# preview under v1 — would become a LIVE MUTATION of the operator's real data at the core flip.
# The sandbox does not save it: fixtures are apple-cli-test-labeled and pass the label gate.
# Every write-verb invocation must carry an explicit --dry-run or --execute (or a truthy
# APPLE_DRY_RUN= env brake, or a `# flagless-on-purpose` marker). Two marker populations exist:
# PRE-FLIP markers pin a not-yet-flipped domain's v1 dry-run default (its flip commit migrates
# them), and PERMANENT default-pin markers lock a flipped domain's v2 per-surface defaults —
# those STAY (deleting them would silently unpin the trash-surface dry-run default). Enforced
# here so a flagless write is a suite FAILURE from the sweep commit onward.
#
# The fixture lines below assemble the `$BIN` token at runtime ('$BI' + 'N') so this file never
# contains a literal write invocation — otherwise the lint would count these fixtures as suite
# invocations and diff-mode would flag this very file's addition.

@test "lint: every bats write invocation carries an explicit flag (fail-closed floors)" {
  run python3 "$BATS_TEST_DIRNAME/helpers/no_flagless_writes.py" "$BATS_TEST_DIRNAME"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^OK: 0 flagless"
  # The lint self-checks logical-vs-physical coverage (a joiner regression fails closed);
  # here we additionally require a sane absolute volume so "scanned nothing" can't pass.
  local checked
  checked="$(echo "$output" | sed -n 's/.* checked \([0-9]*\) write invocation(s).*/\1/p')"
  [ -n "$checked" ] && [ "$checked" -ge 100 ]
  # PIN the marker count. flagless-on-purpose is the one sanctioned path to a flagless write
  # (besides the APPLE_DRY_RUN env-brake prefix, tested below), so its population is CAPPED
  # here: adding a marker requires editing this assertion — a reviewable event. (A net-neutral
  # marker SWAP holds the count without touching this line, but both halves of a swap are
  # visible line edits in the same diff; the cap's job is to stop growth.) Composition today:
  # **ZERO pre-flip markers — all six domains are now flipped** — plus 3 PERMANENT default-pin
  # markers (mail.bats ×2, notes.bats ×1) which lock the v2 per-surface defaults with deliberately
  # flagless invocations. 3 is therefore the FINAL count, and it should not change again unless a
  # domain adds a per-surface default-pin of its own.
  #
  # Messages shed the last pre-flip marker at its flip (2026-08-02), and did NOT replace it with a
  # permanent one — deliberately. `messages send` has no dry-run-by-default surface to pin, so a
  # flagless invocation there would attempt a REAL send to a real handle. Its posture is pinned in
  # the LOGIC tier instead ("Messages write-model v2 posture" in
  # Tests/MessagesKitTests/MessagesKitTests.swift), which needs no Messages.app access at all.
  # Two v1 send tests were DELETED rather than migrated for the same reason — see the safety
  # header in bats/messages.bats.
  #
  # Contacts (2) and Notes (2) shed their pre-flip markers at their own flips. Contacts added no
  # permanent default-pin, on purpose: a flagless write in either domain is a LIVE
  # mutation of the operator's real address book or notes under v2, so pinning the
  # execute-by-default posture with a deliberately flagless invocation is not safe the way it
  # is for Mail's trash surface (whose default IS dry-run). Contacts pins that posture in the
  # LOGIC tier instead — see the "Contacts write-model v2 posture" suite in
  # Tests/ContactsKitTests/WriteSafetyTests.swift, which asserts the same property with no
  # store access at all. Notes DID add one, for `delete-folder` alone: it is the single Notes
  # surface that previews by default (it destroys every note in the folder irreversibly), so the
  # flagless invocation that pins it is safe precisely because that default holds.
  local markers
  markers="$(echo "$output" | sed -n 's/.*, \([0-9]*\) marker(s)$/\1/p')"
  [ "$markers" -eq 3 ]
}

@test "lint: a truthy APPLE_DRY_RUN env-brake prefix exempts a flagless write; junk or a later command does not" {
  # v2 brake-behavior tests are DELIBERATELY flagless under `APPLE_DRY_RUN=1 …` — precedence
  # makes them dry-runs. The exemption must be exactly as narrow as the runtime semantics:
  # only the binary's truthy spellings, and only for the invocation the assignment prefixes.
  local T='$BI'; T="${T}N"
  mkdir -p "$BATS_TEST_TMPDIR/lintcase3"
  printf '%s\n' "APPLE_DRY_RUN=1 run \"$T\" mail send --to me@self.test --subject x --body y" \
    > "$BATS_TEST_TMPDIR/lintcase3/brake.bats"
  run python3 "$BATS_TEST_DIRNAME/helpers/no_flagless_writes.py" "$BATS_TEST_TMPDIR/lintcase3"
  [ "$status" -eq 0 ]
  # A junk value is a runtime validation_error, NOT a brake — still a violation.
  printf '%s\n' "APPLE_DRY_RUN=off run \"$T\" mail send --to me@self.test --subject x --body y" \
    > "$BATS_TEST_TMPDIR/lintcase3/brake.bats"
  run python3 "$BATS_TEST_DIRNAME/helpers/no_flagless_writes.py" "$BATS_TEST_TMPDIR/lintcase3"
  [ "$status" -eq 1 ]
  # `VAR=1 cmd1 && cmd2` does not export to cmd2 — the brake never exempts a later command.
  printf '%s\n' "APPLE_DRY_RUN=1 true && run \"$T\" mail send --to me@self.test --subject x --body y" \
    > "$BATS_TEST_TMPDIR/lintcase3/brake.bats"
  run python3 "$BATS_TEST_DIRNAME/helpers/no_flagless_writes.py" "$BATS_TEST_TMPDIR/lintcase3"
  [ "$status" -eq 1 ]
}

@test "lint: a dynamic-verb write invocation without an explicit flag is a violation" {
  # `"$BIN" mail $sub` builds its verb at runtime — unclassifiable statically, so the lint
  # demands an explicit flag on the logical line. This shape hid four flagless bulk writes
  # from an earlier lint revision whose regex required a literal verb.
  local T='$BI'; T="${T}N"
  mkdir -p "$BATS_TEST_TMPDIR/lintcase"
  printf '%s\n' "run \"$T\" mail \$sub" > "$BATS_TEST_TMPDIR/lintcase/dyn.bats"
  run python3 "$BATS_TEST_DIRNAME/helpers/no_flagless_writes.py" "$BATS_TEST_TMPDIR/lintcase"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "dynamic verb"
  # Flagged form passes.
  printf '%s\n' "run \"$T\" mail \$sub --dry-run" > "$BATS_TEST_TMPDIR/lintcase/dyn.bats"
  run python3 "$BATS_TEST_DIRNAME/helpers/no_flagless_writes.py" "$BATS_TEST_TMPDIR/lintcase"
  [ "$status" -eq 0 ]
}

@test "lint --diff-mode catches an added --execute on a continuation line" {
  local T='$BI'; T="${T}N"
  run bash -c 'printf "%s\n" \
    "+++ b/bats/mail.bats" \
    "+  run \"$1\" mail send --to victim@example.com --subject x --body y \\" \
    "+    --mode send --execute --test-mode" \
    | python3 "$0/helpers/no_flagless_writes.py" --diff-mode' "$BATS_TEST_DIRNAME" "$T"
  [ "$status" -eq 1 ]
}

@test "lint --diff-mode catches --execute added on a continuation under an UNCHANGED head line" {
  local T='$BI'; T="${T}N"
  run bash -c 'printf "%s\n" \
    "+++ b/bats/mail.bats" \
    "@@ -1,2 +1,3 @@" \
    "   run \"$1\" mail send --to victim@example.com --subject x --body y \\" \
    "+    --mode send --execute --test-mode" \
    | python3 "$0/helpers/no_flagless_writes.py" --diff-mode' "$BATS_TEST_DIRNAME" "$T"
  [ "$status" -eq 1 ]
}

@test "lint --diff-mode catches an added --execute with unquoted \$BIN" {
  local T='$BI'; T="${T}N"
  run bash -c 'printf "%s\n" \
    "+++ b/bats/calendar.bats" \
    "+  run $1 calendar events create --title x --start 2026-07-20 --end 2026-07-20 --execute" \
    | python3 "$0/helpers/no_flagless_writes.py" --diff-mode' "$BATS_TEST_DIRNAME" "$T"
  [ "$status" -eq 1 ]
}

@test "lint --diff-mode catches an added --execute on contacts vcard import" {
  local T='$BI'; T="${T}N"
  run bash -c 'printf "%s\n" \
    "+++ b/bats/contacts.bats" \
    "+  run \"$1\" contacts vcard import --vcard \"BEGIN:VCARD\" --execute" \
    | python3 "$0/helpers/no_flagless_writes.py" --diff-mode' "$BATS_TEST_DIRNAME" "$T"
  [ "$status" -eq 1 ]
}

@test "lint --diff-mode is not masked by a preceding unbalanced-quote line" {
  local T='$BI'; T="${T}N"
  run bash -c 'printf "%s\n" \
    "+++ b/bats/mail.bats" \
    "+  run \"$1\" mail search --subject \"unbalanced" \
    "+  run \"$1\" mail mailboxes create --account iCloud --name X --execute" \
    | python3 "$0/helpers/no_flagless_writes.py" --diff-mode' "$BATS_TEST_DIRNAME" "$T"
  [ "$status" -eq 1 ]
}

@test "lint: a pre-verb-option write invocation without an explicit flag is a violation" {
  # `"$BIN" mail --text send …` is a WORKING ArgumentParser form whose verb hides from the
  # literal-verb matcher — an earlier revision skipped it entirely (round-4 review HIGH).
  # It is treated as dynamic: flag required.
  local T='$BI'; T="${T}N"
  mkdir -p "$BATS_TEST_TMPDIR/lintcase2"
  printf '%s\n' "run \"$T\" mail --text send --to victim@example.com --subject x --body y" \
    > "$BATS_TEST_TMPDIR/lintcase2/opt.bats"
  run python3 "$BATS_TEST_DIRNAME/helpers/no_flagless_writes.py" "$BATS_TEST_TMPDIR/lintcase2"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "dynamic verb"
  # Flagged form passes.
  printf '%s\n' "run \"$T\" mail --text --dry-run send --to me@self.test --subject x --body y" \
    > "$BATS_TEST_TMPDIR/lintcase2/opt.bats"
  run python3 "$BATS_TEST_DIRNAME/helpers/no_flagless_writes.py" "$BATS_TEST_TMPDIR/lintcase2"
  [ "$status" -eq 0 ]
}

@test "lint --diff-mode catches --execute smuggled as a pre-verb option" {
  local T='$BI'; T="${T}N"
  run bash -c 'printf "%s\n" \
    "+++ b/bats/mail.bats" \
    "+  run \"$1\" mail --execute send --to victim@example.com --subject x --body y" \
    | python3 "$0/helpers/no_flagless_writes.py" --diff-mode' "$BATS_TEST_DIRNAME" "$T"
  [ "$status" -eq 1 ]
}

@test "lint --diff-mode passes a clean --dry-run addition (control)" {
  local T='$BI'; T="${T}N"
  run bash -c 'printf "%s\n" \
    "+++ b/bats/mail.bats" \
    "+  run \"$1\" mail send --dry-run --to me@self.test --subject x --body y" \
    | python3 "$0/helpers/no_flagless_writes.py" --diff-mode' "$BATS_TEST_DIRNAME" "$T"
  [ "$status" -eq 0 ]
}

# --- snapshot lifetime: the process must leave nothing behind -----------------------------
# THE regression gate for the temp-snapshot leak (COMPLETION-LOOP Q4d). Every other test of this
# feature exercises components in-process; only a real invocation reaches the `atexit` handler that
# replaces the never-running `deinit`, and only a real invocation reaches the reaper call site in
# `SnapshotSession.directory()`. Both lines are red-proofed: delete either and this test fails.
#
# TWO RULES THIS TEST OBEYS, both learned the hard way inside this same change:
#
# 1. IT NEVER DELETES SHARED STATE. An earlier draft ran `rm -rf "$TMPDIR/apple-cli-snapshots"`,
#    which would destroy the LIVE, LOCKED session directory of any concurrent `apple` — a developer
#    in another terminal, a parallel agent lane, a live-tier run. The entire point of the flock
#    design is that nothing can delete a live session; a test must not bypass it with a filesystem
#    remove. So this test only PLANTS uniquely-named entries and removes its own.
#    ($TMPDIR cannot be redirected to dodge this: `FileManager.temporaryDirectory` reads
#    `confstr(_CS_DARWIN_USER_TEMP_DIR)` and IGNORES the environment variable — verified directly.)
#
# 2. ITS LEAK PREDICATE IS THE LOCK, NOT A COUNT. Counting `s-` directories races a concurrent
#    `apple` in both directions. Instead: after a successful run, no session directory may exist
#    whose `.lock` is ACQUIRABLE. An acquirable lock means the owner is dead, so the directory is an
#    orphan — ours (atexit failed) or a stranger's (the reaper failed). A live process holds its
#    lock and is correctly ignored.

@test "a snapshot-backed run cleans up after itself and reaps dead sessions" {
  BIN="$(swift build --show-bin-path)/apple"
  ROOT="${TMPDIR%/}/apple-cli-snapshots"
  TAG="batstest-$$-$RANDOM"

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
  orphans="$(/usr/bin/python3 "$BATS_TEST_DIRNAME/helpers/unlocked_sessions.py" "$ROOT")"
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
    "$BIN" messages chats >/dev/null 2>&1 \
      || skip "\`messages chats\` cannot run on this machine (Full Disk Access?), so no snapshot appears"
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
      || skip "\`messages chats\` cannot run on this machine (Full Disk Access?), so no snapshot appears"
    echo "the command runs here, yet no leg ever became observable"; false
  fi
}
