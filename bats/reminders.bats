#!/usr/bin/env bats
# CLI smoke tests for the Reminders domain — logic tier, NO Apple permissions required.
#
# SAFETY: every test here either (a) invokes `--help` (never runs the body), (b) exercises a
# dry-run write preview (default when --execute is absent — never touches the store), (c) runs
# `doctor` (non-prompting status only), or (d) triggers a validation error that fires BEFORE the
# command reaches `store.requestAccess`. NONE of these prompt for TCC or read the live store, so
# the suite is safe on CI and on an unattended machine. Live reads/writes are the live tier.

setup() {
  BIN="$(swift build --show-bin-path)/apple"
}

# --- Flag-collision guard: every leaf subcommand's --help must exit 0 -------------------------
# A local @Option/@Flag whose long name collides with a GlobalOptions flag (--text/--dry-run/
# --execute/--test-mode) makes ArgumentParser fail at parse-time; --help would then not exit 0.

@test "reminders --help exits 0 and lists the subcommands" {
  run "$BIN" reminders --help
  [ "$status" -eq 0 ]
  for sub in tasks lists subtasks doctor; do echo "$output" | grep -q "$sub"; done
}

@test "flag-collision guard: every leaf --help exits 0" {
  local leaves=(
    "tasks read" "tasks create" "tasks update" "tasks delete"
    "lists read" "lists create" "lists update" "lists delete"
    "subtasks read" "subtasks create" "subtasks update" "subtasks delete"
    "subtasks toggle" "subtasks reorder"
  )
  for leaf in "${leaves[@]}"; do
    run "$BIN" reminders $leaf --help
    [ "$status" -eq 0 ] || { echo "FAILED --help for: reminders $leaf (status=$status)"; echo "$output"; return 1; }
  done
  run "$BIN" reminders doctor --help
  [ "$status" -eq 0 ]
}

# --- Dry-run write previews (no store, no TCC) -----------------------------------------------

@test "tasks create dry-run emits a preview envelope (ok, dry_run, no store access)" {
  run "$BIN" reminders tasks create --title apple-cli-test-x --priority high
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"schema_version" : 1'
  echo "$output" | grep -q '"tool" : "reminders"'
  echo "$output" | grep -q '"ok" : true'
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"action" : "create"'
  echo "$output" | grep -q '"priority" : 1'
}

@test "tasks update dry-run echoes the parsed intent" {
  run "$BIN" reminders tasks update --id ABC --title apple-cli-test-y --add-tag work --clear-alarms
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"action" : "update"'
  echo "$output" | grep -q '"clear_alarms" : true'
}

@test "tasks delete dry-run previews without deleting" {
  run "$BIN" reminders tasks delete --id ABC
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"action" : "delete"'
  echo "$output" | grep -q '"dry_run" : true'
}

@test "lists create/update/delete dry-run previews" {
  run "$BIN" reminders lists create --name apple-cli-test-list --color '#FF5733'
  [ "$status" -eq 0 ]; echo "$output" | grep -q '"action" : "create"'
  run "$BIN" reminders lists update --name apple-cli-test-list --new-name apple-cli-test-list2
  [ "$status" -eq 0 ]; echo "$output" | grep -q '"action" : "update"'
  run "$BIN" reminders lists delete --name apple-cli-test-list
  [ "$status" -eq 0 ]; echo "$output" | grep -q '"action" : "delete"'
}

@test "subtasks create/update/delete/toggle/reorder dry-run previews" {
  run "$BIN" reminders subtasks create --reminder-id R1 --title apple-cli-test-sub
  [ "$status" -eq 0 ]; echo "$output" | grep -q '"action" : "create"'
  run "$BIN" reminders subtasks update --reminder-id R1 --subtask-id aaaa1111 --completed
  [ "$status" -eq 0 ]; echo "$output" | grep -q '"action" : "update"'
  run "$BIN" reminders subtasks delete --reminder-id R1 --subtask-id aaaa1111
  [ "$status" -eq 0 ]; echo "$output" | grep -q '"action" : "delete"'
  run "$BIN" reminders subtasks toggle --reminder-id R1 --subtask-id aaaa1111
  [ "$status" -eq 0 ]; echo "$output" | grep -q '"action" : "toggle"'
  run "$BIN" reminders subtasks reorder --reminder-id R1 --order bbbb2222 --order aaaa1111
  [ "$status" -eq 0 ]; echo "$output" | grep -q '"action" : "reorder"'
}

# --- Error envelopes + exit-code matrix (all fire before any store access) --------------------

@test "bad --due-within is a validation_error (exit 64)" {
  run "$BIN" reminders tasks read --due-within someday
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"ok" : false'
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "bad --filter-priority is a validation_error (exit 64)" {
  run "$BIN" reminders tasks read --filter-priority urgent
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "bad --priority is a validation_error (exit 64)" {
  run "$BIN" reminders tasks create --title apple-cli-test-x --priority 11
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "bad --color is a validation_error (exit 64)" {
  run "$BIN" reminders lists create --name apple-cli-test-list --color notacolor
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "bad recurrence (missing freq) is a validation_error (exit 64)" {
  run "$BIN" reminders tasks create --title apple-cli-test-x --recurrence "interval=2"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "non-hex subtask id is a validation_error (exit 64)" {
  run "$BIN" reminders subtasks update --reminder-id R1 --subtask-id NOTHEX --completed
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "reorder with no --order is a validation_error (exit 64)" {
  run "$BIN" reminders subtasks reorder --reminder-id R1
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "geo location trigger needs both lat and lon (exit 64)" {
  run "$BIN" reminders tasks create --title apple-cli-test-x --geo-lat 37.3
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "empty reminder title is rejected (exit 64)" {
  run "$BIN" reminders tasks create --title ""
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "empty subtask title in create is rejected (exit 64)" {
  run "$BIN" reminders tasks create --title apple-cli-test-x --subtask ""
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "--clear-tags conflicts with --tag (exit 64)" {
  run "$BIN" reminders tasks update --id ABC --clear-tags --tag work
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "--clear-tags alone dry-run previews with empty tags (exit 0)" {
  run "$BIN" reminders tasks update --id ABC --clear-tags
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"action" : "update"'
  # present-but-empty tags array signals "clear all"; assert whitespace-insensitively
  echo "$output" | tr -d ' \n' | grep -q '"tags":\[\]'
}

# --- doctor (read-only, non-prompting) -------------------------------------------------------

@test "reminders doctor reports authorization without prompting (exit 0)" {
  run "$BIN" reminders doctor
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"reminders_authorization"'
  echo "$output" | grep -q '"full_disk_access"'
  echo "$output" | grep -q '"tool" : "reminders"'
}

# --- Golden JSON snapshot (synthetic, deterministic — no dates, no PII, no store) -------------

@test "golden: deterministic dry-run create matches the canonical envelope" {
  run "$BIN" reminders tasks create \
    --title apple-cli-test-golden --priority high --note hello \
    --tag work --tag urgent --subtask a --subtask b
  [ "$status" -eq 0 ]
  # Whitespace-insensitive full-content golden (values are space-free by construction).
  local got expected
  got="$(echo "$output" | tr -d ' \n')"
  expected='{"data":{"action":"create","dry_run":true,"note":"hello","priority":1,"subtasks":["a","b"],"tags":["work","urgent"],"title":"apple-cli-test-golden"},"ok":true,"schema_version":1,"tool":"reminders"}'
  [ "$got" = "$expected" ] || { echo "GOT:      $got"; echo "EXPECTED: $expected"; return 1; }
}
