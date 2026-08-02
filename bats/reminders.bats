#!/usr/bin/env bats
# CLI smoke tests for the Reminders domain — logic tier, NO Apple permissions required.
#
# SAFETY: every test here either (a) invokes `--help` (never runs the body), (b) exercises a
# write preview via an EXPLICIT `--dry-run` (or an `APPLE_DRY_RUN=1` prefix — verified to
# propagate through bats' `run`), (c) runs `doctor` (non-prompting status only), or (d) triggers a
# validation error that fires BEFORE the command reaches `store.requestAccess` — including every
# sandbox refusal, since the write gate runs before `EventStore()`. NONE of these prompt for TCC
# or touch the live store, so the suite is safe on CI and on an unattended machine.
#
# UNDER WRITE-MODEL v2 THE `--dry-run` IS LOAD-BEARING, not decorative: writes EXECUTE by default,
# so a flagless write invocation added to this file would mutate the operator's real Reminders
# store. That is what `bats/smoke.bats`'s flagless-write lint exists to prevent — do not add one.
# Live reads/writes are the live tier.

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
  run "$BIN" reminders tasks create --dry-run --title apple-cli-test-x --priority high
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"schema_version" : 1'
  echo "$output" | grep -q '"tool" : "reminders"'
  echo "$output" | grep -q '"ok" : true'
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"action" : "create"'
  echo "$output" | grep -q '"priority" : 1'
}

@test "tasks update dry-run echoes the parsed intent" {
  run "$BIN" reminders tasks update --dry-run --id ABC --title apple-cli-test-y --add-tag work --clear-alarms
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"action" : "update"'
  echo "$output" | grep -q '"clear_alarms" : true'
}

@test "tasks delete dry-run previews without deleting" {
  run "$BIN" reminders tasks delete --dry-run --id ABC
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"action" : "delete"'
  echo "$output" | grep -q '"dry_run" : true'
}

@test "lists create/update/delete dry-run previews" {
  run "$BIN" reminders lists create --dry-run --name apple-cli-test-list --color '#FF5733'
  [ "$status" -eq 0 ]; echo "$output" | grep -q '"action" : "create"'
  run "$BIN" reminders lists update --dry-run --name apple-cli-test-list --new-name apple-cli-test-list2
  [ "$status" -eq 0 ]; echo "$output" | grep -q '"action" : "update"'
  run "$BIN" reminders lists delete --dry-run --name apple-cli-test-list
  [ "$status" -eq 0 ]; echo "$output" | grep -q '"action" : "delete"'
}

@test "subtasks create/update/delete/toggle/reorder dry-run previews" {
  run "$BIN" reminders subtasks create --dry-run --reminder-id R1 --title apple-cli-test-sub
  [ "$status" -eq 0 ]; echo "$output" | grep -q '"action" : "create"'
  run "$BIN" reminders subtasks update --dry-run --reminder-id R1 --subtask-id aaaa1111 --completed
  [ "$status" -eq 0 ]; echo "$output" | grep -q '"action" : "update"'
  run "$BIN" reminders subtasks delete --dry-run --reminder-id R1 --subtask-id aaaa1111
  [ "$status" -eq 0 ]; echo "$output" | grep -q '"action" : "delete"'
  run "$BIN" reminders subtasks toggle --dry-run --reminder-id R1 --subtask-id aaaa1111
  [ "$status" -eq 0 ]; echo "$output" | grep -q '"action" : "toggle"'
  run "$BIN" reminders subtasks reorder --dry-run --reminder-id R1 --order bbbb2222 --order aaaa1111
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
  run "$BIN" reminders tasks create --dry-run --title apple-cli-test-x --priority 11
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "bad --color is a validation_error (exit 64)" {
  run "$BIN" reminders lists create --dry-run --name apple-cli-test-list --color notacolor
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "bad recurrence (missing freq) is a validation_error (exit 64)" {
  run "$BIN" reminders tasks create --dry-run --title apple-cli-test-x --recurrence "interval=2"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "non-hex subtask id is a validation_error (exit 64)" {
  run "$BIN" reminders subtasks update --dry-run --reminder-id R1 --subtask-id NOTHEX --completed
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "reorder with no --order is a validation_error (exit 64)" {
  run "$BIN" reminders subtasks reorder --dry-run --reminder-id R1
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "geo location trigger needs both lat and lon (exit 64)" {
  run "$BIN" reminders tasks create --dry-run --title apple-cli-test-x --geo-lat 37.3
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "empty reminder title is rejected (exit 64)" {
  run "$BIN" reminders tasks create --dry-run --title ""
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "empty subtask title in create is rejected (exit 64)" {
  run "$BIN" reminders tasks create --dry-run --title apple-cli-test-x --subtask ""
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "--clear-tags conflicts with --tag (exit 64)" {
  run "$BIN" reminders tasks update --dry-run --id ABC --clear-tags --tag work
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "--clear-tags alone dry-run previews with empty tags (exit 0)" {
  run "$BIN" reminders tasks update --dry-run --id ABC --clear-tags
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
  run "$BIN" reminders tasks create --dry-run \
    --title apple-cli-test-golden --priority high --note hello \
    --tag work --tag urgent --subtask a --subtask b
  [ "$status" -eq 0 ]
  # Whitespace-insensitive full-content golden (values are space-free by construction).
  local got expected
  got="$(echo "$output" | tr -d ' \n')"
  expected='{"data":{"action":"create","dry_run":true,"note":"hello","priority":1,"subtasks":["a","b"],"tags":["work","urgent"],"title":"apple-cli-test-golden"},"ok":true,"schema_version":1,"tool":"reminders"}'
  [ "$got" = "$expected" ] || { echo "GOT:      $got"; echo "EXPECTED: $expected"; return 1; }
}

# --- write-model v2 posture (docs/write-model-v2.md) -----------------------------------------
# Every pin below refuses inside the write gate, which runs BEFORE `EventStore()` /
# `requestAccess` — so none of them touches the live store or prompts for TCC, keeping this
# suite's header safety contract intact under execute-by-default.

@test "sandbox refuses an unlabeled reminder title before touching the store" {
  run "$BIN" reminders tasks create --test-mode --execute --title "Real Reminder"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
  echo "$output" | grep -qi 'sandbox'
}

# `--target-list` takes a name OR an opaque id, so an unlabeled-LOOKING value cannot be refused
# from argv (a labeled list's id carries no prefix). It DEFERS to the resolved list's title on the
# execute path, which means the refusal is post-store and therefore cannot be asserted from this
# tier without touching the operator's Reminders. What this tier CAN pin is the honesty half: the
# preview must disclose that the check was deferred rather than implying approval. The refusal
# itself is pinned in the logic tier — "the post-resolution destination check refuses an unlabeled
# resolved list" in Tests/RemindersKitTests/WriteSafetyTests.swift.
@test "an unlabeled-looking destination defers rather than silently passing (preview discloses)" {
  run "$BIN" reminders tasks create --test-mode --dry-run \
    --title apple-cli-test-x --target-list "Real List"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"sandbox_target_unchecked" : true'
  echo "$output" | grep -q '"sandbox" : true'
}

@test "a LABELED destination name is settled from argv — no deferral claimed" {
  run "$BIN" reminders tasks create --test-mode --dry-run \
    --title apple-cli-test-x --target-list apple-cli-test-list
  [ "$status" -eq 0 ]
  run bash -c "echo '$output' | grep -c sandbox_target_unchecked || true"
  [ "$output" -eq 0 ]
}

@test "sandbox refuses renaming a labeled list to an unlabeled name" {
  run "$BIN" reminders lists update --test-mode --execute \
    --name apple-cli-test-list --new-name "Real List"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q 'new list name'
}

@test "sandbox label check also runs on the PREVIEW path (no dishonest dry-run)" {
  run "$BIN" reminders tasks create --test-mode --dry-run --title "Real Reminder"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "a labeled create previews cleanly and is tagged as sandboxed" {
  run "$BIN" reminders tasks create --test-mode --dry-run --title apple-cli-test-x
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"sandbox" : true'
}

@test "APPLE_DRY_RUN=1 restores dry-run-by-default for a flagless write" {
  APPLE_DRY_RUN=1 run "$BIN" reminders tasks create --title apple-cli-test-x
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
}

@test "an id-addressed preview discloses that the sandbox check was deferred" {
  run "$BIN" reminders tasks delete --test-mode --dry-run --id ABC
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"sandbox_target_unchecked" : true'
}

@test "every subtask preview discloses the deferred parent check inside the sandbox" {
  run "$BIN" reminders subtasks create --test-mode --dry-run --reminder-id R1 --title apple-cli-test-sub
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"sandbox_target_unchecked" : true'
}
