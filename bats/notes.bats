#!/usr/bin/env bats
# CLI smoke tests for the `notes` domain — invoke the built binary. No Apple automation and no
# real note data required: every assertion is an error path, a dry-run preview, or the read-only
# sync-status diagnostic, so nothing here depends on (or emits) real PII.

setup() {
  BIN="$(swift build --show-bin-path)/apple"
}

@test "notes --help lists the core subcommands" {
  run "$BIN" notes --help
  [ "$status" -eq 0 ]
  for c in get get-checklist get-metadata list search create update delete move \
           folders accounts attachments save-attachment batch-delete export stats \
           sync-status health doctor; do
    echo "$output" | grep -q "$c"
  done
}

@test "notes get-metadata with a bad id → validation error envelope, exit 64" {
  run "$BIN" notes get-metadata --id "bogus"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"schema_version" : 1'
  echo "$output" | grep -q '"tool" : "notes"'
  echo "$output" | grep -q '"ok" : false'
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "notes get-checklist with a bad id → validation error, exit 64" {
  run "$BIN" notes get-checklist --id "not-a-coredata-id"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "notes get with neither --id nor --title → validation error, exit 64" {
  run "$BIN" notes get
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "notes create defaults to a safe dry-run preview (no --execute)" {
  run "$BIN" notes create "apple-cli-test smoke" --content "body"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"operation" : "create-note"'
}

@test "notes create --execute without APPLE_TEST_MODE is refused" {
  APPLE_TEST_MODE="" run "$BIN" notes create "apple-cli-test smoke" --content "body" --execute
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "notes delete defaults to dry-run (destructive op is never automatic)" {
  run "$BIN" notes delete --id "x-coredata://ABC/ICNote/p1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
}

@test "notes create with an invalid --format → validation error, exit 64" {
  run "$BIN" notes create "apple-cli-test smoke" --content "b" --format xml --execute
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "notes sync-status returns a well-formed success envelope" {
  # SQLite/WAL read — works whenever Full Disk Access is granted; emits only sync flags (no PII).
  run "$BIN" notes sync-status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"schema_version" : 1'
  echo "$output" | grep -q '"tool" : "notes"'
  echo "$output" | grep -q '"sync_detected"'
  echo "$output" | grep -q '"pending_upload"'
}

@test "notes batch-delete with no ids → validation error, exit 64" {
  run "$BIN" notes batch-delete --ids
  [ "$status" -eq 64 ]
}

@test "notes create with an over-length title → validation error, exit 64 (input-bounds parity)" {
  # Bounds are checked before the dry-run/execute gate, mirroring the MCP's zod input validation.
  local long_title="apple-cli-test $(printf 'x%.0s' {1..2001})"
  run "$BIN" notes create "$long_title" --content "b"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "exit-code matrix: usage=64 for bad flags, well-formed envelope on the error path" {
  run "$BIN" notes get-checklist   # missing required --id
  [ "$status" -eq 64 ]
  run "$BIN" notes move --id "x-coredata://A/ICNote/p1"   # missing required --folder
  [ "$status" -eq 64 ]
}

@test "every leaf subcommand --help exits 0 with non-empty output" {
  # Guards against a local @Option/@Flag whose long name collides with GlobalOptions
  # (--text/--dry-run/--execute/--test-mode): ArgumentParser rejects the dupe at PARSE time,
  # so that subcommand's --help exits 1 with empty stdout and the tool is silently 100% dead
  # while build + logic tests stay green. This asserts none of the 35 are dead.
  local subs=(get get-plaintext get-markdown get-by-id get-details get-metadata get-checklist \
    list search selected create update append delete move folders create-folder delete-folder \
    accounts default-location shared attachments save-attachment fetch-attachment show-attachment \
    batch-delete batch-move export stats sync-status health doctor show-note show-folder show-account)
  for s in "${subs[@]}"; do
    run "$BIN" notes "$s" --help
    [ "$status" -eq 0 ] || { echo "DEAD subcommand: notes $s (exit $status)"; false; }
    [ -n "$output" ] || { echo "EMPTY --help: notes $s"; false; }
  done
}

@test "golden: bad-id metadata error envelope is byte-stable" {
  run "$BIN" notes get-metadata --id "bogus"
  expected='{
  "error" : {
    "message" : "Invalid note ID format: \"bogus\". Expected format: x-coredata://UUID/ICNote/pNNN",
    "type" : "validation_error"
  },
  "ok" : false,
  "schema_version" : 1,
  "tool" : "notes"
}'
  [ "$output" = "$expected" ]
}
