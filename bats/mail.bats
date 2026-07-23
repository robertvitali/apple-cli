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

# ── Missing MCP read/scoping params (audit gaps E/F/G) — CI-safe ─────────────────────────────────
@test "mail search --max-content-length rejects a negative value (exit 64)" {
  require_index
  run "$BIN" mail search --max-content-length -1
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

@test "mail search accepts --max-content-length (MCP B max_content_length) and previews (exit 0)" {
  require_index
  run "$BIN" mail search --account iCloud --limit 1 --max-content-length 20
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"tool" : "mail"'
}

@test "mail get exposes --account/--mailbox scoping params (MCP A get_message params)" {
  run "$BIN" mail get --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '--account'
  echo "$output" | grep -q -- '--mailbox'
}

@test "mail forward exposes --mailbox subject-scope param (MCP B forward_email mailbox)" {
  run "$BIN" mail forward --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '--mailbox'
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

# ── HTML / attachment send: the self-only gate fires IDENTICALLY (regression-lock) ──────────────
# HTML + attachment live send is wired (via the multipart .eml / make-new-attachment routes), so
# these prove the NEW paths route through the SAME guardOutbound before any AppleScript send — no
# HTML/attachment path bypasses the self-only + two-factor gate. All fire before any Mail access.

@test "mail send --html to a NON-self recipient is refused (safety_violation, exit 77)" {
  APPLE_TEST_MODE=1 APPLE_TEST_RECIPIENTS="me@self.test" \
    run "$BIN" mail send --to someone-else@example.com --subject "apple-cli-test x" --body y \
      --html "<b>hi</b>" --mode send --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail send --attach to a NON-self recipient is refused (safety_violation, exit 77)" {
  APPLE_TEST_MODE=1 APPLE_TEST_RECIPIENTS="me@self.test" \
    run "$BIN" mail send --to someone-else@example.com --subject "apple-cli-test x" --body y \
      --attach /tmp/apple-cli-test-nonexistent --mode send --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail send --html with --execute but WITHOUT --test-mode is refused (exit 77)" {
  run "$BIN" mail send --to me@self.test --subject "apple-cli-test x" --body y \
    --html "<b>hi</b>" --mode send --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail send --attach with --execute but WITHOUT --test-mode is refused (exit 77)" {
  run "$BIN" mail send --to me@self.test --subject "apple-cli-test x" --body y \
    --attach /tmp/apple-cli-test-nonexistent --mode send --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail send --html default (no --execute) previews without sending (has_html true, dry_run)" {
  run "$BIN" mail send --to me@self.test --subject "apple-cli-test x" --body y --html "<b>hi</b>"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"has_html" : true'
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"executed" : false'
}

@test "mail send --attach with a missing file is not_found before any send (exit 65)" {
  # Store-independent: attachment existence is validated before any Mail/AppleScript access.
  run "$BIN" mail send --to me@self.test --subject "apple-cli-test x" --body y \
    --attach /tmp/apple-cli-test-definitely-missing-zzz
  [ "$status" -eq 65 ]
  echo "$output" | grep -q '"type" : "not_found"'
}

@test "mail send --attach exceeding the 25 MB cap is refused before any send (validation_error, exit 64)" {
  # 26 MB sparse file — instant, no real bytes written; matches s-morgan's 25 MB send limit.
  BIG="$BATS_TEST_TMPDIR/apple-cli-test-big.bin"
  dd if=/dev/zero of="$BIG" bs=1 count=0 seek=27262976 2>/dev/null
  run "$BIN" mail send --to me@self.test --subject "apple-cli-test x" --body y --attach "$BIG"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "mail send --attach with a dangerous executable extension (.sh) is refused (validation_error, exit 64)" {
  # Matches s-morgan validate_attachment_type — executables/scripts are blocked by default.
  SH="$BATS_TEST_TMPDIR/apple-cli-test-payload.sh"
  printf '#!/bin/sh\necho hi\n' > "$SH"
  run "$BIN" mail send --to me@self.test --subject "apple-cli-test x" --body y --attach "$SH"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "mail send --account with an unknown account is not_found before any send (exit 65)" {
  # --account resolves to a From address before dispatch; an unknown account fails fast.
  APPLE_TEST_MODE=1 APPLE_TEST_RECIPIENTS="me@self.test" \
    run "$BIN" mail send --to me@self.test --account "apple-cli-test-nonexistent-acct" \
      --subject "apple-cli-test x" --body y --mode send --execute --test-mode
  [ "$status" -eq 65 ]
  echo "$output" | grep -q '"type" : "not_found"'
}

@test "mail draft-rich --bcc writes a Bcc header into the generated .eml (compose-window safe)" {
  # draft-rich .eml is only opened / saved, never wire-sent, so carrying --bcc is safe + parity.
  OUT="$BATS_TEST_TMPDIR/apple-cli-test-draft.eml"
  run "$BIN" mail draft-rich --to me@self.test --bcc secret@self.test \
    --subject "apple-cli-test dr" --html "<b>x</b>" --out "$OUT"
  [ "$status" -eq 0 ]
  grep -q "^Bcc: secret@self.test" "$OUT"
}

@test "mail send --html with an empty --subject is refused before any send (validation_error, exit 64)" {
  # --subject defaults to "" when omitted; a live --html send must refuse it (empty subject is
  # never a sensible delivered message) — fires AFTER the self-only gate (recipient is self,
  # test-mode is on) but BEFORE any .eml write or AppleScript send.
  APPLE_TEST_MODE=1 APPLE_TEST_RECIPIENTS="me@self.test" \
    run "$BIN" mail send --to me@self.test --body y --html "<b>hi</b>" --mode send --execute --test-mode
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "mail send --html with a whitespace-only --subject is refused (validation_error, exit 64)" {
  APPLE_TEST_MODE=1 APPLE_TEST_RECIPIENTS="me@self.test" \
    run "$BIN" mail send --to me@self.test --subject "   " --body y --html "<b>hi</b>" --mode send --execute --test-mode
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

# ── HTML auto-send is opt-in (--gui-send); the flag is validated before any Mail access ──────────
# Option A: --html without --gui-send OPENS a rendered compose window (reliable); --gui-send is the
# explicit opt-in for the GUI-keystroke auto-send. These lock the flag's validity + self-only gate.

@test "mail send --gui-send WITHOUT --html is a usage error (exit 64)" {
  run "$BIN" mail send --to me@self.test --subject "apple-cli-test x" --body y --gui-send --mode send
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "mail send --html --gui-send with --mode draft is a usage error (exit 64, send-only)" {
  run "$BIN" mail send --to me@self.test --subject "apple-cli-test x" --body y --html "<b>hi</b>" --gui-send --mode draft
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "mail send --html --gui-send to a NON-self recipient is refused (safety_violation, exit 77)" {
  # The GUI-keystroke auto-send routes through the SAME self-only guardOutbound before any window opens.
  APPLE_TEST_MODE=1 APPLE_TEST_RECIPIENTS="me@self.test" \
    run "$BIN" mail send --to someone-else@example.com --subject "apple-cli-test x" --body y \
      --html "<b>hi</b>" --gui-send --mode send --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail send --html --gui-send with --execute but WITHOUT --test-mode is refused (exit 77)" {
  run "$BIN" mail send --to me@self.test --subject "apple-cli-test x" --body y \
    --html "<b>hi</b>" --gui-send --mode send --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail send --html default (no --gui-send) reports opened field in preview (dry_run)" {
  run "$BIN" mail send --to me@self.test --subject "apple-cli-test x" --body y --html "<b>hi</b>"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"opened" : false'
  echo "$output" | grep -q '"dry_run" : true'
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

@test "mail draft create --cc/--bcc/--account are accepted and preview as a dry-run (exit 0, account echoed)" {
  # CI-safe (no --execute → dry-run preview, no Mail access). Locks that `draft create` ACCEPTS the
  # sender-identity + cc/bcc flags: a regression dropping --cc/--bcc from the parser, or --account,
  # would fail here. The live create→send behaviour (draft stored with the --account sender + cc, then
  # delivered From that address to the cc) is validated on-device per CHANGELOG.
  run "$BIN" mail draft create --subject "apple-cli-test draftsend-cc" --body hi \
    --to me@self.test --cc alias@self.test --bcc hidden@self.test --account "Some Account"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"executed" : false'
  echo "$output" | grep -q '"account" : "Some Account"'
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

# ── Non-sending draft/open modes (gap 4) — all CI-safe: dry-run previews + gate refusals ─────────
# send --mode open / --mode draft, draft open, and draft-rich --open/--save-as-draft are NON-sending
# (they never reach an AppleScript `send`). These lock the dry-run + safety-gate surface WITHOUT any
# real Mail access: every assertion is a dry-run preview or a refusal that fires before Mail is touched.

@test "mail send --mode open without --execute is a dry-run preview (exit 0, opened/drafted false)" {
  run "$BIN" mail send --to me@self.test --subject "apple-cli-test open" --body hi --mode open
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"opened" : false'
  echo "$output" | grep -q '"drafted" : false'
}

@test "mail send --mode draft with --execute but WITHOUT --test-mode is refused (exit 77)" {
  # A draft is non-sending, but persists a Drafts item → same test-mode gate as `draft create`.
  run "$BIN" mail send --to me@self.test --subject "apple-cli-test draft" --body y --mode draft --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail send --mode draft with an UNLABELED subject is refused under --execute --test-mode (exit 77)" {
  # The label half of the draft gate fires before any Mail access.
  APPLE_TEST_MODE=1 \
    run "$BIN" mail send --to me@self.test --subject "Quarterly report" --body y --mode draft --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail draft open without a labeled subject is refused (exit 77, before any Mail access)" {
  # openDraft requires a labeled subject; the label check fires before Mail is opened.
  run "$BIN" mail draft open --draft-subject "not-a-test-draft" --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail draft send with --execute but WITHOUT --test-mode is refused (exit 77)" {
  # Sending an EXISTING draft fires the same two-factor gate as every outbound op; fires before
  # any Mail access.
  run "$BIN" mail draft send --draft-subject "apple-cli-test x" --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail draft send with an UNLABELED subject is refused under the test gate (exit 77)" {
  # The label half fires before the draft is even looked up; the draft's own stored recipients
  # are additionally verified against the self-only allowlist inside the send script itself.
  APPLE_TEST_MODE=1 \
    run "$BIN" mail draft send --draft-subject "Quarterly report" --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail draft-rich --save-as-draft WITHOUT --test-mode is refused before any Mail access (exit 77)" {
  # Opening the compose window is self-only guardOutbound-gated (test-mode + allowlist), same as
  # `send --mode open`; the gate fires before the .eml write.
  OUT="$BATS_TEST_TMPDIR/apple-cli-test-dr.eml"
  run "$BIN" mail draft-rich --to me@self.test --subject "apple-cli-test dr" --html "<b>x</b>" --save-as-draft --out "$OUT"
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail draft-rich --open WITHOUT --test-mode is refused before any Mail access (exit 77)" {
  # --open opens a live compose window → same self-only guardOutbound as `send --mode open`.
  OUT="$BATS_TEST_TMPDIR/apple-cli-test-dr.eml"
  run "$BIN" mail draft-rich --to me@self.test --subject "apple-cli-test dr" --html "<b>x</b>" --open --out "$OUT"
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail forward --account with an unknown account is not_found before the index opens (exit 65)" {
  # --account resolves to a send-from address on the live path, BEFORE MailContext — so an unknown
  # account fails fast with not_found even where the Envelope Index is unreadable (CI-safe).
  APPLE_TEST_MODE=1 APPLE_TEST_RECIPIENTS="me@self.test" \
    run "$BIN" mail forward 12345 --to me@self.test --account "apple-cli-test-nonexistent-acct" --execute --test-mode
  [ "$status" -eq 65 ]
  echo "$output" | grep -q '"type" : "not_found"'
}

@test "mail draft-rich --open with an unknown --account is not_found before any window opens (exit 65)" {
  # The live-open path resolves --account to a real From address (a raw name would be a malformed
  # From: Mail ignores); unknown account → 65 before the .eml write or any Mail access.
  OUT="$BATS_TEST_TMPDIR/apple-cli-test-dr.eml"
  APPLE_TEST_MODE=1 APPLE_TEST_RECIPIENTS="me@self.test" \
    run "$BIN" mail draft-rich --to me@self.test --subject "apple-cli-test dr" --html "<b>x</b>" \
      --account "apple-cli-test-nonexistent-acct" --open --out "$OUT" --test-mode
  [ "$status" -eq 65 ]
  echo "$output" | grep -q '"type" : "not_found"'
  [ ! -f "$OUT" ]
}

@test "mail draft-rich (no open/save flags) writes the .eml and reports opened false (exit 0)" {
  # Default path — no Mail access, ungated; asserts the opened field + the written artifact.
  OUT="$BATS_TEST_TMPDIR/apple-cli-test-dr.eml"
  run "$BIN" mail draft-rich --to me@self.test --subject "apple-cli-test dr" --html "<b>x</b>" --out "$OUT"
  [ "$status" -eq 0 ]
  [ -f "$OUT" ]
  echo "$output" | grep -q '"opened" : false'
}
