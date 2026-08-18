#!/usr/bin/env bats
# Calendar CLI smoke tests — logic tier, NO TCC. Only exercises paths that never touch the
# EventKit store: --help, arg-validation error envelopes, DRY-RUN writes (which build the preview
# without an EKEventStore), and sandbox refusals (the write gate runs before `EventStore()`, so a
# refusal never reaches the store either). Live read/create-execute paths need granted Calendar
# TCC and run in the live tier, not here.
#
# UNDER WRITE-MODEL v2 THE `--dry-run` IS LOAD-BEARING, not decorative: writes EXECUTE by default,
# so a flagless write invocation added to this file would create a real event in the operator's
# calendar. The v1 test that ran `... --execute` expecting a refusal was DELETED for exactly this
# reason, not migrated. `bats/smoke.bats`'s flagless-write lint enforces it — do not add one.

setup() {
  BIN="$(swift build --show-bin-path)/apple"
}

# --- QC gate: EVERY leaf subcommand --help must exit 0 -----------------------------------
# A local @Option/@Flag colliding with a GlobalOptions long name (--text/--json/--dry-run/
# --execute/--test-mode) makes ArgumentParser reject the subcommand at parse time, so --help
# exits 1 with empty stdout and the tool is silently dead. This asserts that never happens.

@test "every calendar leaf --help exits 0" {
  for leaf in \
    "calendar" \
    "calendar calendars" \
    "calendar calendars list" \
    "calendar events" \
    "calendar events read" \
    "calendar events create" \
    "calendar events update" \
    "calendar events delete" \
    "calendar doctor"; do
    run $BIN $leaf --help
    [ "$status" -eq 0 ] || { echo "FAIL: '$leaf --help' exited $status"; return 1; }
    [ -n "$output" ]
  done
}

@test "calendar --help lists the subcommands" {
  run $BIN calendar --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "calendars"
  echo "$output" | grep -q "events"
  echo "$output" | grep -q "doctor"
}

# --- Dry-run create golden (deterministic: UTC dates, no PII) -----------------------------

@test "dry-run create emits a valid preview envelope with parsed alarm + recurrence" {
  run $BIN calendar events create --dry-run \
    --title "apple-cli-test standup" \
    --start "2026-07-20T09:00:00Z" \
    --end "2026-07-20T09:30:00Z" \
    --alarm 15m \
    --recurrence "freq=weekly;interval=1;byday=2,4;count=6" \
    --availability busy
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"schema_version" : 1'
  echo "$output" | grep -q '"tool" : "calendar"'
  echo "$output" | grep -q '"ok" : true'
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"action" : "create"'
  echo "$output" | grep -q '"relative_offset" : -900'
  echo "$output" | grep -q '"frequency" : "weekly"'
  echo "$output" | grep -q '"start_date" : "2026-07-20T09:00:00Z"'
}

@test "dry-run delete emits a delete preview" {
  run $BIN calendar events delete --dry-run --id SOME-ID --span all
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"action" : "delete"'
  echo "$output" | grep -q '"span" : "all"'
}

@test "all-day is NOT inferred from bare dates (MCP parity)" {
  run $BIN calendar events create --dry-run --title "apple-cli-test x" --start 2026-07-15 --end 2026-07-16
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"is_all_day" : false'
}

@test "title-only structured location is accepted (MCP parity)" {
  run $BIN calendar events create --dry-run --title "apple-cli-test y" \
    --start 2026-07-15T09:00:00Z --end 2026-07-15T10:00:00Z --geo-title "Conference Room B"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"title" : "Conference Room B"'
}

@test "end before start is rejected (validation_error)" {
  run $BIN calendar events create --dry-run --title "apple-cli-test w" \
    --start 2026-07-15T10:00:00Z --end 2026-07-15T09:00:00Z
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "contradictory --clear-alarms + --alarm is rejected" {
  run $BIN calendar events update --dry-run --id X --clear-alarms --alarm 15m
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

# --- Error envelopes + exit-code matrix ---------------------------------------------------

@test "bad recurrence weekday yields validation_error / exit 64" {
  run $BIN calendar events create --dry-run --title "apple-cli-test x" --start 2026-07-20 --end 2026-07-20 --recurrence "freq=weekly;byday=8"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
  echo "$output" | grep -q '"ok" : false'
}

@test "bad date yields validation_error / exit 64" {
  run $BIN calendar events create --dry-run --title "apple-cli-test x" --start "2026-13-45" --end "2026-07-20"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "bad availability yields validation_error / exit 64" {
  run $BIN calendar events create --dry-run --title "apple-cli-test x" --start 2026-07-20 --end 2026-07-20 --availability wat
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "missing required --title exits 64 (usage)" {
  run $BIN calendar events create --dry-run --start 2026-07-20 --end 2026-07-20
  [ "$status" -eq 64 ]
}

# --- write-model v2 posture (docs/write-model-v2.md) -----------------------------------------
# The v1 test that lived here ran `... --execute` and asserted a refusal. Post-flip that command
# CREATES A REAL EVENT in the operator's default calendar, which would break this suite's own
# safety contract (see the header: nothing here may touch the live store). It is replaced by pins
# that exercise the sandbox refusal instead — every one of them throws inside the write gate,
# which runs BEFORE `EventStore()` / `requestAccess`, so no TCC prompt and no store access.

@test "sandbox refuses an unlabeled create before touching the store (validation_error)" {
  run $BIN calendar events create --test-mode --execute \
    --title "Real Meeting" --start 2026-07-20 --end 2026-07-20
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
  # The refusal must name the sandbox, not the old test-mode gate.
  echo "$output" | grep -qi 'sandbox'
}

@test "sandbox label check also runs on the PREVIEW path (no dishonest dry-run)" {
  run $BIN calendar events create --test-mode --dry-run \
    --title "Real Meeting" --start 2026-07-20 --end 2026-07-20
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "a labeled create is accepted by the sandbox gate (previews, does not write)" {
  run $BIN calendar events create --test-mode --dry-run \
    --title "apple-cli-test x" --start 2026-07-20 --end 2026-07-20
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"sandbox" : true'
}

@test "APPLE_DRY_RUN=1 restores dry-run-by-default for a flagless write" {
  APPLE_DRY_RUN=1 run $BIN calendar events create \
    --title "apple-cli-test x" --start 2026-07-20 --end 2026-07-20
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
}

@test "an id-addressed preview discloses that the sandbox check was deferred" {
  run $BIN calendar events delete --test-mode --dry-run --id SOME-ID
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"sandbox_target_unchecked" : true'
}

# Q12 [17]/CAL-05: --text honors the flag AND neutralizes terminal control sequences in
# store-derived strings (an ESC in an event title must not reach the terminal raw).
@test "calendar events create --dry-run --text renders text and neutralizes ANSI (Q12)" {
  title=$(printf 'apple-cli-test \033[31mRED\033[0m')
  run "$BIN" calendar events create --title "$title" --start 2030-01-01 --end 2030-01-01 --dry-run --text
  [ "$status" -eq 0 ]
  # text mode, not JSON (no envelope braces on line 1)
  echo "${lines[0]}" | grep -q "^action: create"
  # the ESC (0x1B) must be neutralized to caret notation, never emitted raw
  echo "$output" | grep -q '\^\[\[31mRED'
  ! printf '%s' "$output" | grep -q "$(printf '\033')"
}

# CAL-11: the natural space-separated negative-value form parses for structured-location geo
# (argv preprocessing merges `--geo-lon -122.4`). Revert-red: without it ArgumentParser fails
# "Missing value for '--geo-lon'".
@test "calendar events create accepts space-separated negative geo (CAL-11)" {
  run "$BIN" calendar events create --title apple-cli-test --start 2030-01-01 --end 2030-01-01 --geo-lon -122.4 --geo-lat 37.7 --dry-run --text
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"longitude":-122'
}

# Q14: a sandbox-policy refusal (unlabeled title in --test-mode) carries error.sandbox=true.
@test "calendar events create unlabeled in --test-mode marks error.sandbox (Q14)" {
  run "$BIN" calendar events create --title notlabeled --start 2030-01-01 --end 2030-01-01 --test-mode --execute
  # The unlabeled-title guard is a PURE check that fires BEFORE any EventKit auth, so this refuses
  # (exit 64) identically on a TCC-less CI runner; assert the code so a guard that ever moved
  # post-auth fails loudly here instead of silently going red on authorization_denied output.
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"sandbox" : true'
}
