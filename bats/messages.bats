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

# --- send safety (no TCC, NOTHING is ever sent here) ---

@test "send defaults to dry-run: executed=false, ok=true, exit 0, no send" {
  run "$BIN" messages send 2125550100 --message "smoke test"  # flagless-on-purpose
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"executed" : false'
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"ok" : true'
}

@test "send --execute WITHOUT --test-mode is refused (fail-closed, exit 64, nothing sent)" {
  unset APPLE_TEST_MODE
  run "$BIN" messages send 2125550100 --message "must not send" --execute
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"ok" : false'
  echo "$output" | grep -qi "refusing live send"
}

@test "send --execute --test-mode WITHOUT APPLE_TEST_MODE env is still refused (layered guard)" {
  unset APPLE_TEST_MODE
  run "$BIN" messages send 2125550100 --message "must not send" --execute --test-mode
  [ "$status" -eq 64 ]
  echo "$output" | grep -qi "refusing live send"
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

@test "recent --limit out of range → validation error (exit 64)" {
  run "$BIN" messages recent --limit 0
  [ "$status" -eq 64 ]
}
