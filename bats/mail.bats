#!/usr/bin/env bats
# Mail CLI smoke tests. Help/usage/error-envelope checks run anywhere; live reads
# (Envelope Index + Mail automation) are guarded and skip when unavailable (CI).

setup() {
  BIN="$(swift build --show-bin-path)/apple"
}

# Skip a test when the Mail Envelope Index isn't readable (no Full Disk Access / no Mail).
require_index() {
  local found=""
  for d in "$HOME"/Library/Mail/V*/MailData/"Envelope Index"; do
    [ -r "$d" ] && found=1
  done
  [ -n "$found" ] || skip "Mail Envelope Index not readable (no FDA / no Mail)"
}

@test "mail --help lists the P1 subcommands" {
  run "$BIN" mail --help
  [ "$status" -eq 0 ]
  for c in accounts mailboxes search list get selected thread attachments unread-counts doctor; do
    echo "$output" | grep -q "$c"
  done
}

# Assert EVERY leaf subcommand renders --help with exit 0. A local @Option/@Flag whose long
# name collides with GlobalOptions (--text/--dry-run/--execute/--test-mode) makes
# ArgumentParser reject the command at parse time: --help then exits 1 with empty stdout and
# the subcommand is silently dead while build+tests stay green. This test catches that class.
# Keep this list in sync with MailCommand's registered subcommands.
@test "every mail subcommand --help exits 0 (guards GlobalOptions flag collisions)" {
  local leaves=(
    "accounts list" "mailboxes list" unread-counts search list get selected thread
    "attachments list" doctor
  )
  run "$BIN" mail --help
  [ "$status" -eq 0 ]
  for c in "${leaves[@]}"; do
    run "$BIN" mail $c --help
    [ "$status" -eq 0 ] || { echo "FAIL: 'mail $c --help' exited $status"; return 1; }
  done
}

@test "mail search --limit 0 does not report has_more with next_offset 0 (no pagination loop)" {
  require_index
  run "$BIN" mail search --account iCloud --limit 0
  [ "$status" -eq 0 ]
  # With limit 0 (= all), an empty or complete page must not claim more at offset 0.
  echo "$output" | grep -q '"has_more" : false' || ! echo "$output" | grep -q '"next_offset" : 0'
}

@test "mail get with no id is a usage error (exit 64)" {
  run "$BIN" mail get
  [ "$status" -eq 64 ]
}

@test "mail doctor emits a JSON envelope" {
  run "$BIN" mail doctor
  echo "$output" | grep -q '"schema_version" : 1'
  echo "$output" | grep -q '"tool" : "mail"'
  echo "$output" | grep -q '"full_disk_access"'
}

@test "mail thread with neither id nor subject is a validation error envelope (exit 64)" {
  require_index
  run "$BIN" mail thread
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
  echo "$output" | grep -q '"ok" : false'
}

@test "mail search rejects mutually-exclusive --read --unread (exit 64)" {
  require_index
  run "$BIN" mail search --read --unread
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

@test "mail search rejects a malformed --from-date (exit 64)" {
  require_index
  run "$BIN" mail search --from-date "julyish"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

@test "mail get with an unknown ROWID is a not_found envelope (exit 65)" {
  require_index
  run "$BIN" mail get 999999999
  [ "$status" -eq 65 ]
  echo "$output" | grep -q '"type" : "not_found"'
}

@test "mail search emits a well-formed envelope with union fields" {
  require_index
  run "$BIN" mail search --limit 1
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"schema_version" : 1'
  echo "$output" | grep -q '"tool" : "mail"'
  echo "$output" | grep -q '"messages"'
}
