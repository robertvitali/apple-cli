#!/usr/bin/env bats

BATS_SUITE_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
REPO_ROOT="$(cd "$BATS_SUITE_ROOT/.." && pwd -P)"
HELPERS="$BATS_SUITE_ROOT/helpers"
# Local read-only capability tests for the `messages` domain. These checks need the operator's
# existing Full Disk Access but assert only schema, booleans, and counts; no live values are emitted.

setup() {
  export PATH="$HOME/.swiftly/bin:$PATH"
  BIN="$(swift build --show-bin-path)/apple"
}

# --- send safety -----------------------------------------------------------------------------
#
# These commands cannot send, but Messages resolves the synthetic handle through the local
# AddressBook before it selects the preview or sandbox-refusal path. They therefore belong in
# the local tier even though the assertions themselves are deterministic.

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

@test "sandbox via --test-mode alone refuses a non-allowlisted recipient (exit 64, nothing sent)" {
  unset APPLE_TEST_MODE
  run "$BIN" messages send 2125550100 --message "must not send" --test-mode --execute
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"ok" : false'
  echo "$output" | grep -qi "not in the test allowlist"
  echo "$output" | grep -q '"sandbox" : true'
}

@test "sandbox via APPLE_TEST_MODE env alone refuses a non-allowlisted recipient (exit 64)" {
  APPLE_TEST_MODE=1 run "$BIN" messages send 2125550100 --message "must not send" --execute
  [ "$status" -eq 64 ]
  echo "$output" | grep -qi "not in the test allowlist"
  echo "$output" | grep -q '"sandbox" : true'
}

@test "sandboxed --dry-run refuses the same recipient an execute would (no dishonest preview)" {
  run "$BIN" messages send 2125550100 --message "must not send" --test-mode --dry-run
  [ "$status" -eq 64 ]
  echo "$output" | grep -qi "not in the test allowlist"
}

# The refusal is STRUCTURAL, not an allowlist miss: the allowlist is seeded with the very chat id
# being sent to (scoped to this one invocation, so no APPLE_* variable is set for the suite), and
# the send is still refused. Asserting the group-specific wording — and the absence of the
# allowlist wording — is what proves the structural guard ran rather than a lucky mismatch.
@test "sandboxed group send is refused structurally even when the chat id is itself allowlisted" {
  APPLE_TEST_RECIPIENTS="iMessage;-;chat123456789" run "$BIN" messages send "iMessage;-;chat123456789" --message "must not send" --group --test-mode --dry-run
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"ok" : false'
  echo "$output" | grep -q '"sandbox" : true'
  echo "$output" | grep -qi "group-chat send is unavailable"
  ! echo "$output" | grep -qi "not in the test allowlist"
}

# --- help + subcommand surface (no TCC) ---

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

@test "search term under the cap in BOTH units is still accepted" {
  # Control for the test above: same shape, 200 clusters / 800 code points, under
  # 1024 either way. Without this, the guard could reject everything and still pass.
  ok=$(python3 -c "print(('a'+'\u0301'*3)*200)")
  run "$BIN" messages search "$ok" --hours 1
  [ "$status" -eq 0 ]
}

@test "messages send --dry-run --text neutralizes ANSI (Q12 [17])" {
  msg=$(printf 'apple-cli-test \033[31mRED\033[0m')
  run "$BIN" messages send "+15555550123" --message "$msg" --dry-run --text
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '\^\[\[31mRED'
  ! printf '%s' "$output" | grep -q "$(printf '\033')"
}
