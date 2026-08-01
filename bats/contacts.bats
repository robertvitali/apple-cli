#!/usr/bin/env bats
# CLI smoke tests for `apple contacts` — logic tier, no Contacts TCC required. Every
# case here resolves BEFORE the authorization gate (help / auth-status / input
# validation / the write-safety gate / dry-run), so it runs on a Command-Line-Tools-only
# machine and in CI without prompting. Live data-command parity is covered separately
# (see the run report), not here.

setup() {
  BIN="$(swift build --show-bin-path)/apple"
}

@test "contacts --help lists all subcommands" {
  run "$BIN" contacts --help
  [ "$status" -eq 0 ]
  for c in auth list get search create update delete note photo groups vcard containers; do
    echo "$output" | grep -q "$c"
  done
}

@test "contacts auth emits a JSON envelope with a status (never prompts)" {
  run "$BIN" contacts auth
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"schema_version" : 1'
  echo "$output" | grep -q '"tool" : "contacts"'
  echo "$output" | grep -q '"ok" : true'
  echo "$output" | grep -q '"status"'
}

@test "search with no field → validation_error (exit 64)" {
  run "$BIN" contacts search
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
  echo "$output" | grep -q '"ok" : false'
}

@test "list --limit 0 → validation_error (exit 64)" {
  run "$BIN" contacts list --limit 0
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"message" : "limit must be >= 1"'
}

@test "get with whitespace identifier → validation_error (exit 64)" {
  run "$BIN" contacts get "   "
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "vcard export with no ids → validation_error (exit 64)" {
  run "$BIN" contacts vcard export
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "destructive create --execute without test-mode → safety_violation (exit 77)" {
  run "$BIN" contacts create --first "apple-cli-test Ada" --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
  echo "$output" | grep -q '"ok" : false'
}

@test "delete --execute without test-mode → safety_violation (exit 77)" {
  run "$BIN" contacts delete "SOME-ID" --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "groups create --execute without test-mode → safety_violation (exit 77)" {
  run "$BIN" contacts groups create "apple-cli-test-group" --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

# Golden-ish snapshot — synthetic labeled data only, no real PII. The default
# (no --execute) create is a dry-run preview that mutates nothing.
@test "create dry-run (default) previews planned fields, mutates nothing" {
  run "$BIN" contacts create --first "apple-cli-test Ada" --org "Acme"  # flagless-on-purpose
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"ok" : true'
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"operation" : "create_contact"'
  echo "$output" | grep -q '"given_name" : "apple-cli-test Ada"'
  echo "$output" | grep -q '"organization" : "Acme"'
}

@test "update dry-run (default) previews, requires a field" {
  run "$BIN" contacts update "SOME-ID" --set given_name=apple-cli-test  # flagless-on-purpose
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"operation" : "update_contact"'
}

@test "update with no fields → validation_error (exit 64)" {
  run "$BIN" contacts update --dry-run "SOME-ID"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "photo set with two sources → validation_error (exit 64)" {
  run "$BIN" contacts photo set --dry-run "SOME-ID" --clear --base64 "AAAA"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "--text mode emits non-JSON human output for auth" {
  run "$BIN" contacts auth --text
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'status:'
  # must NOT be the JSON envelope
  ! echo "$output" | grep -q '"schema_version"'
}

# Regression guard for the whole "duplicate flag name" class of bug (a local --text
# colliding with the global --text made two commands 100% dead and shipped green).
# EVERY leaf subcommand must parse its argument set — asserted via --help exit 0.
@test "every leaf subcommand --help parses (no flag collisions)" {
  local leaves=(
    "auth" "list" "get" "search" "create" "update" "delete"
    "note get" "note set" "photo get" "photo set"
    "groups list" "groups members" "groups create" "groups rename"
    "groups delete" "groups add" "groups remove"
    "vcard export" "vcard import" "containers list"
  )
  for leaf in "${leaves[@]}"; do
    run $BIN contacts $leaf --help
    [ "$status" -eq 0 ] || { echo "FAIL: contacts $leaf --help exited $status"; echo "$output"; return 1; }
  done
}

# Write-safety gate — EVERY destructive op must refuse a live write without the full
# test-mode arming, returning safety_violation (exit 77). (create/delete/groups-create
# covered above; here are the rest.)
@test "update --execute without test-mode → safety_violation (exit 77)" {
  run "$BIN" contacts update "SOME-ID" --set given_name=apple-cli-test --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "note set --execute without test-mode → safety_violation (exit 77)" {
  run "$BIN" contacts note set "SOME-ID" --note "apple-cli-test" --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "photo set --execute without test-mode → safety_violation (exit 77)" {
  run "$BIN" contacts photo set "SOME-ID" --clear --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "groups rename --execute without test-mode → safety_violation (exit 77)" {
  run "$BIN" contacts groups rename "GID" "apple-cli-test-renamed" --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "groups delete --execute without test-mode → safety_violation (exit 77)" {
  run "$BIN" contacts groups delete "GID" --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "groups add --execute without test-mode → safety_violation (exit 77)" {
  run "$BIN" contacts groups add "CID" "GID" --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "groups remove --execute without test-mode → safety_violation (exit 77)" {
  run "$BIN" contacts groups remove "CID" "GID" --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "vcard import --execute without test-mode → safety_violation (exit 77)" {
  run "$BIN" contacts vcard import --vcard "BEGIN:VCARD
VERSION:3.0
N:Test;A;;;
FN:A Test
END:VCARD" --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

# note set / vcard import were the two dead commands — assert they run (dry-run) now.
@test "note set dry-run previews (was dead before the --text-collision fix)" {
  run "$BIN" contacts note set --dry-run "SOME-ID" --note "apple-cli-test note"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"operation" : "write_note"'
  echo "$output" | grep -q '"dry_run" : true'
}

@test "vcard import dry-run validates the payload (was dead before the fix)" {
  run "$BIN" contacts vcard import --dry-run --vcard "BEGIN:VCARD
VERSION:3.0
N:Test;A;;;
FN:A Test
END:VCARD"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"operation" : "import_vcard"'
  echo "$output" | grep -q '"parsed_count" : 1'
}

@test "vcard import dry-run rejects malformed vCard (exit 64)" {
  run "$BIN" contacts vcard import --dry-run --vcard "definitely not a vcard"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "note set with no source → validation_error (exit 64)" {
  run "$BIN" contacts note set --dry-run "SOME-ID"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"message" : "exactly one of --note, --file, or --clear is required"'
}

@test "groups members with whitespace id → validation_error (exit 64)" {
  run "$BIN" contacts groups members "   "
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "groups add dry-run previews membership" {
  run "$BIN" contacts groups add --dry-run "CID" "GID"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"operation" : "add_contact_to_group"'
  echo "$output" | grep -q '"dry_run" : true'
}
