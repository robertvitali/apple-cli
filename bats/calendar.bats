#!/usr/bin/env bats
# Calendar CLI smoke tests — logic tier, NO TCC. Only exercises paths that never touch the
# EventKit store: --help, arg-validation error envelopes, and DRY-RUN writes (which build the
# preview without an EKEventStore). Live read/create-execute paths need granted Calendar TCC
# and run in the live tier, not here.

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

@test "--execute without the test-mode gate is refused (validation_error)" {
  run $BIN calendar events create --title "apple-cli-test x" --start 2026-07-20 --end 2026-07-20 --execute
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}
