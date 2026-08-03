#!/usr/bin/env bats
# CLI smoke tests for the `messages` domain. Invokes the built binary. The read
# commands need Full Disk Access (chat.db + AddressBook); the help / validation /
# exit-code / send-guard tests do NOT and always run. No real PII is asserted.

setup() {
  export PATH="$HOME/.swiftly/bin:$PATH"
  BIN="$(swift build --show-bin-path)/apple"
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

# --- send safety (NOTHING is ever sent here) -------------------------------------------------
#
# WRITE-MODEL v2 MADE THIS SECTION DANGEROUS TO GET WRONG. `messages send` now SENDS WHEN INVOKED,
# exactly as the oracle's tool_send_message does. Two tests that lived here were DELETED rather
# than migrated, because post-flip they would have attempted a REAL send to 555-0100:
#   - "send defaults to dry-run" ran the command FLAGLESS (it carried a pre-flip
#     `# flagless-on-purpose` marker, which is exactly the marker the flip is supposed to retire);
#   - "send --execute WITHOUT --test-mode is refused" asserted a refusal that v2 removes.
# Both are replaced below by shapes that cannot send: an explicit `--dry-run`, or a sandbox
# refusal. The sandbox allowlist check runs BEFORE the willExecute branch and before
# `Send.perform`, so a refusal never reaches Messages.app.
#
# NEVER add a flagless `messages send` to this file. It would message a real handle.

@test "send --dry-run previews: executed=false, dry_run=true, ok=true, nothing sent" {
  run "$BIN" messages send 2125550100 --message "smoke test" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"executed" : false'
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"ok" : true'
}

@test "APPLE_DRY_RUN=1 restores dry-run-by-default for a flagless send" {
  APPLE_DRY_RUN=1 run "$BIN" messages send 2125550100 --message "smoke test"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"executed" : false'
}

# The sandbox engages on EITHER signal alone under v2. With APPLE_TEST_RECIPIENTS empty/unset (the
# state here) the allowlist matches nothing, so every recipient is refused — fail-closed, and the
# refusal happens before any send is attempted.
@test "sandbox via --test-mode alone refuses a non-allowlisted recipient (exit 64, nothing sent)" {
  unset APPLE_TEST_MODE
  run "$BIN" messages send 2125550100 --message "must not send" --test-mode --execute
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"ok" : false'
  echo "$output" | grep -qi "not in the test allowlist"
}

@test "sandbox via APPLE_TEST_MODE env alone refuses a non-allowlisted recipient (exit 64)" {
  APPLE_TEST_MODE=1 run "$BIN" messages send 2125550100 --message "must not send" --execute
  [ "$status" -eq 64 ]
  echo "$output" | grep -qi "not in the test allowlist"
}

# Preview honesty: the recipient is argv-derived, so a sandboxed --dry-run must refuse EXACTLY what
# an execute would. A preview that said "would send" for a recipient the execute path refuses is
# the most consequential possible lie on a send surface.
@test "sandboxed --dry-run refuses the same recipient an execute would (no dishonest preview)" {
  run "$BIN" messages send 2125550100 --message "must not send" --test-mode --dry-run
  [ "$status" -eq 64 ]
  echo "$output" | grep -qi "not in the test allowlist"
}

@test "a sandboxed group-chat id can never match the allowlist (D4: unreachable in sandbox)" {
  run "$BIN" messages send "iMessage;-;chat123456789" --message "must not send" --group --test-mode --dry-run
  [ "$status" -eq 64 ]
  echo "$output" | grep -qi "not in the test allowlist"
}

# --- golden structural snapshot for a read (needs FDA; skips if absent) ---

@test "check-db emits the documented JSON shape" {
  run "$BIN" messages check-db
  # Skip only if FDA is missing on this machine (connected=false path).
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"tool" : "messages"'
  echo "$output" | grep -q '"ok" : true'
  for field in exists readable connected has_message_table has_handle_table has_chat_table path; do
    echo "$output" | grep -q "\"$field\""
  done
}

@test "find-contact with no matches still returns ok=true, count 0" {
  run "$BIN" messages find-contact "zzzznonexistentzzzz9999"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"ok" : true'
  echo "$output" | grep -q '"count" : 0'
}

@test "check-availability returns available boolean + service" {
  run "$BIN" messages check-availability 2125550100
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"available"'
  echo "$output" | grep -q '"service"'
  echo "$output" | grep -q '"recommendation"'
}

@test "text mode (--text) emits non-JSON on stdout" {
  run "$BIN" messages check-db --text
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "path:"
  ! echo "$output" | grep -q '"schema_version"'
}

# --- flagless read leaves must actually be invoked (a GlobalOptions collision
#     would otherwise never surface). FDA is granted so these run. ---

@test "chats runs and emits ok=true with a count" {
  run "$BIN" messages chats
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"ok" : true'
  echo "$output" | grep -q '"count"'
}

@test "check-contacts runs and emits ok=true with a count" {
  run "$BIN" messages check-contacts
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"ok" : true'
  echo "$output" | grep -q '"count"'
}

@test "check-addressbook runs and emits ok=true with database_count" {
  run "$BIN" messages check-addressbook
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"ok" : true'
  echo "$output" | grep -q '"database_count"'
}

@test "doctor runs and emits ok=true with full_disk_access" {
  run "$BIN" messages doctor
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"ok" : true'
  echo "$output" | grep -q '"full_disk_access"'
}

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
  run timeout 60 "$BIN" messages search "$long"
  [ "$status" -eq 64 ]
  echo "$output" | grep -qi "too long"
  echo "$output" | grep -qi "code points"
}

@test "search term under the cap in BOTH units is still accepted" {
  # Control for the test above: same shape, 200 clusters / 800 code points, under
  # 1024 either way. Without this, the guard could reject everything and still pass.
  ok=$(python3 -c "print(('a'+'\u0301'*3)*200)")
  run "$BIN" messages search "$ok" --hours 1
  [ "$status" -eq 0 ]
}

@test "recent --limit out of range → validation error (exit 64)" {
  run "$BIN" messages recent --limit 0
  [ "$status" -eq 64 ]
}
