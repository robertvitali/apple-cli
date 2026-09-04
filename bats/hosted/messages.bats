#!/usr/bin/env bats

BATS_SUITE_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
REPO_ROOT="$(cd "$BATS_SUITE_ROOT/.." && pwd -P)"
HELPERS="$BATS_SUITE_ROOT/helpers"
# Hosted-safe CLI smoke tests for the `messages` domain. Every case is help, validation,
# or parser behavior that runs without Full Disk Access or live-store reads.

setup() {
  export PATH="$HOME/.swiftly/bin:$PATH"
  BIN="${APPLE_CLI_TEST_BINARY:-$(swift build --show-bin-path)/apple}"
}

# --- help + subcommand surface (no TCC) ---

@test "messages --help lists all ported subcommands" {
  run "$BIN" messages --help
  [ "$status" -eq 0 ]
  for sub in recent send find-contact chats search check-availability check-db check-contacts check-addressbook doctor; do
    echo "$output" | grep -q "$sub"
  done
}

@test "bare 'messages' emits a JSON error envelope, ok=false, non-zero exit" {
  run "$BIN" messages
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '"schema_version"'
  echo "$output" | grep -q '"ok" : false'
  echo "$output" | grep -q '"tool" : "messages"'
}

# --- exit-code matrix (no TCC) ---

@test "empty search term → validation error (exit 64)" {
  run "$BIN" messages search ""
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "out-of-range threshold → validation error (exit 64)" {
  run "$BIN" messages search hi --threshold 2.0
  [ "$status" -eq 64 ]
}

@test "negative hours → validation error (exit 64)" {
  run "$BIN" messages recent --hours -1
  [ "$status" -eq 64 ]
}

@test "invalid match mode → validation error (exit 64)" {
  run "$BIN" messages search hi --match bogus
  [ "$status" -eq 64 ]
}

# --- bounded input validation ---------------------------------------------------------------

@test "search term over 1024 chars → validation error (exit 64, DoS guard)" {
  long=$(printf 'a%.0s' {1..1100})
  run "$BIN" messages search "$long"
  [ "$status" -eq 64 ]
  echo "$output" | grep -qi "too long"
}

@test "search term guard counts CODE POINTS, not grapheme clusters (Q5c)" {
  # 600 grapheme clusters, 2400 code points: "a" + 3 combining acutes, 600 times.
  # The scorer counts code points, so the guard must too — a Character-based guard
  # accepts this (600 < 1024) and hands 2400 scalars to an O(term x body) LCS.
  # A single cluster can hold unboundedly many scalars, so the gap is not bounded.
  long=$(python3 -c "print(('a'+'\u0301'*3)*600)")
  # BOUNDED: if this guard regresses to counting Characters the term is ACCEPTED, and the run
  # does not fail — it HANGS in the O(term x body) LCS, which is the whole point of the guard.
  # Without the timeout a regression stalls the suite instead of reporting; verified by mutation.
  local xtrace_was_on=0
  case "$-" in
    *x*) xtrace_was_on=1; set +x ;;
  esac
  run /usr/bin/python3 "$HELPERS/bounded_exec.py" \
    --timeout 60 --grace 2 -- "$BIN" messages search "$long"
  local guard_status="$status"
  local guard_output="$output"
  output=""
  lines=()
  [ "$guard_status" -eq 64 ]
  printf '%s' "$guard_output" | grep -qi "too long"
  printf '%s' "$guard_output" | grep -qi "code points"
  unset guard_output
  [ "$xtrace_was_on" -eq 0 ] || set -x
}

@test "search term under the cap in BOTH units is still accepted" {
  # Intentionally tests the current validation sequence: the same 200 clusters / 800 code points
  # must pass the term guard before the later invalid --hours value fails. The separate over-cap
  # tests above pin the production guard itself; this control stays hermetic by stopping later.
  ok=$(python3 -c "print(('a'+'\u0301'*3)*200)")
  run "$BIN" messages search "$ok" --hours -1
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
  echo "$output" | grep -qi "hours cannot be negative"
  ! echo "$output" | grep -qi "too long"
}

@test "find-contact query is length-bounded, in code points (Q5d)" {
  # matchContacts runs difflib per token AND per full name, per candidate, so an unbounded
  # query hangs harder here than on search. Measured: 500k jamo scalars vs 200 candidates
  # = 9.95s. Bounded so a regression fails instead of stalling the suite.
  long=$(python3 -c "print('\u1100\u1161'*600)")
  local xtrace_was_on=0
  case "$-" in
    *x*) xtrace_was_on=1; set +x ;;
  esac
  run /usr/bin/python3 "$HELPERS/bounded_exec.py" \
    --timeout 60 --grace 2 -- "$BIN" messages find-contact "$long"
  local guard_status="$status"
  local guard_output="$output"
  output=""
  lines=()
  [ "$guard_status" -eq 64 ]
  printf '%s' "$guard_output" | grep -qi "too long"
  unset guard_output
  [ "$xtrace_was_on" -eq 0 ] || set -x
}

@test "recent --limit out of range → validation error (exit 64)" {
  run "$BIN" messages recent --limit 0
  [ "$status" -eq 64 ]
}
