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
    "accounts list" "mailboxes list" "mailboxes create" unread-counts search list get selected
    thread "attachments list" "attachments save" doctor
    "rules list" "rules create" "rules update" "rules delete" "rules enable" "rules disable"
    "templates list" "templates get" "templates save" "templates delete" "templates render"
    "analytics overview" "analytics needs-response" "analytics awaiting-reply"
    "analytics top-senders" "analytics stats" "analytics dashboard" export
    send reply forward draft draft-rich move mark flag delete "trash empty"
  )
  run "$BIN" mail --help
  [ "$status" -eq 0 ]
  for c in "${leaves[@]}"; do
    run "$BIN" mail $c --help
    [ "$status" -eq 0 ] || { echo "FAIL: 'mail $c --help' exited $status"; return 1; }
  done
}

@test "mail send defaults to a dry-run preview (no live send)" {
  run "$BIN" mail send --to nobody@example.invalid --subject "apple-cli-test" --body "hi"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"action" : "send"'
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"executed" : false'
}

@test "mail templates render fills placeholders from a temp store" {
  export APPLE_MAIL_MCP_HOME="$BATS_TEST_TMPDIR/mcp-home"
  run "$BIN" mail templates save greet --body "Hi {name}" --subject "Hello"
  [ "$status" -eq 0 ]
  run "$BIN" mail templates render greet --var name=World
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Hi World"
}

@test "mail delete --permanent --execute is refused (dangerous)" {
  require_index
  run "$BIN" mail delete --match-subject apple-cli-nonexistent-zzz --permanent --execute --account iCloud
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

@test "mail move with a filter previews (dry-run, filter_based)" {
  require_index
  run "$BIN" mail move --match-subject apple-cli-nonexistent-zzz --to Archive --account iCloud
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"filter_based" : true'
  echo "$output" | grep -q '"dry_run" : true'
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

@test "mail attachments save with neither id nor --subject is a usage error (exit 64)" {
  # Store-independent: arg-presence is validated before the Envelope Index is opened.
  run "$BIN" mail attachments save --dir "$BATS_TEST_TMPDIR"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

@test "mail attachments save with both --dir and --out is a usage error (exit 64)" {
  # Store-independent: --dir/--out mutual exclusion is validated before the Envelope Index opens.
  run "$BIN" mail attachments save --subject x --dir "$BATS_TEST_TMPDIR" --out "$BATS_TEST_TMPDIR/f"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

@test "mail attachments save with neither --dir nor --out is a usage error (exit 64)" {
  run "$BIN" mail attachments save --subject x
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

@test "mail attachments save with both --name and --indices is a usage error (exit 64)" {
  # Store-independent: --name/--indices mutual exclusion is validated before the Envelope Index opens.
  run "$BIN" mail attachments save --subject x --dir "$BATS_TEST_TMPDIR" --name foo --indices 0
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
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

# ── Write-safety gates ─────────────────────────────────────────────────────────
# These fire BEFORE any Mail/Envelope-Index access, so they run anywhere (no FDA /
# no Mail needed). They regression-lock the refusals verified in the live e2e run.

@test "mail send to a NON-self recipient is refused (safety_violation, exit 77)" {
  APPLE_TEST_MODE=1 APPLE_TEST_RECIPIENTS="me@self.test" \
    run "$BIN" mail send --to someone-else@example.com --subject "apple-cli-test x" --body y --mode send --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail send with --execute but WITHOUT --test-mode is refused (exit 77)" {
  # No APPLE_TEST_MODE, no --test-mode → two-factor outbound gate refuses.
  run "$BIN" mail send --to me@self.test --subject "apple-cli-test x" --body y --mode send --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail send default (no --execute) is a dry-run preview (exit 0, dry_run true)" {
  run "$BIN" mail send --to me@self.test --subject "apple-cli-test x" --body y
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"executed" : false'
}

@test "mail rules create with an UNLABELED name is refused under --execute --test-mode (exit 77)" {
  APPLE_TEST_MODE=1 \
    run "$BIN" mail rules create --name "real-inbox-rule" --condition "from:contains:boss@x.io" --action "mark_read=true" --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail rules update --execute WITHOUT --test-mode is refused (exit 77, before any Mail access)" {
  # requireLabeledRule fail-closes on the test-mode gate before it ever reads Mail's rules.
  run "$BIN" mail rules update 1 --name "apple-cli-test-x" --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail rules update with an invalid --match is a validation_error (exit 64)" {
  run "$BIN" mail rules update 1 --match sideways --execute
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

@test "mail rules update dry-run (no --execute) previews the patch without touching Mail (exit 0)" {
  run "$BIN" mail rules update 3 --name "apple-cli-test-renamed"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
}

@test "mail draft create with an UNLABELED subject is refused under --execute --test-mode (exit 77)" {
  APPLE_TEST_MODE=1 \
    run "$BIN" mail draft create --subject "Quarterly report" --body y --to me@self.test --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail delete --permanent --execute is a hard-refused dangerous action (exit 64)" {
  run "$BIN" mail delete 1 --permanent --execute
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

@test "mail trash empty --execute is a hard-refused dangerous action (exit 64)" {
  run "$BIN" mail trash empty --account "Any" --execute
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}
