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

@test "mail delete --permanent --execute WITHOUT --test-mode is refused (exit 77)" {
  # --permanent is now wired, but routes through the same all-or-nothing label gate as every
  # other mutation, so it cannot run outside test-mode.
  require_index
  run "$BIN" mail delete --match-subject apple-cli-nonexistent-zzz --permanent --execute --account iCloud
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"safety_violation"'
}

@test "mail move with a filter previews (dry-run, filter_based)" {
  require_index
  run "$BIN" mail move --match-subject apple-cli-nonexistent-zzz --to Archive --account iCloud
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"filter_based" : true'
  echo "$output" | grep -q '"dry_run" : true'
}

# ── subject_keywords OR-match (audit gap C) + apply_to_all (gap D) — CI-safe ─────────────────────
@test "mail search accepts repeatable --subject (OR-match; MCP B subject_keywords) and previews (exit 0)" {
  require_index
  run "$BIN" mail search --account iCloud --mailbox All --subject apple-cli-nope-a --subject apple-cli-nope-b --limit 1 --no-content
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"tool" : "mail"'
}

@test "mail move accepts repeatable --match-subject (OR-match) and previews filter_based (exit 0)" {
  require_index
  run "$BIN" mail move --match-subject apple-cli-nope-a --match-subject apple-cli-nope-b --to Archive --account iCloud
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"filter_based" : true'
}

@test "mail mark --all (apply_to_all) is accepted and previews without ids/filter (dry-run, exit 0)" {
  require_index
  run "$BIN" mail mark --all --read --mailbox INBOX --account iCloud --max 3
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"filter_based" : true'
}

@test "mail mark with no ids, no --match, no --all is a usage error (exit 64)" {
  require_index
  run "$BIN" mail mark --read --account iCloud --execute --test-mode
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
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

# ── get_thread References-mode (audit gap A) — CI-safe ───────────────────────────────────────────
@test "mail thread exposes --references (MCP A header-threading) mode" {
  run "$BIN" mail thread --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '--references'
}

@test "mail thread <id> --references reports matched_by references (exit 0)" {
  require_index
  # grab any real message id, then thread it by References
  rid="$("$BIN" mail search --account iCloud --mailbox INBOX --limit 1 --no-content 2>/dev/null | grep -o '"id" : "[0-9]*"' | head -1 | grep -o '[0-9]*')"
  [ -n "$rid" ] || skip "no iCloud INBOX message to thread"
  run "$BIN" mail thread "$rid" --references --limit 5
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"matched_by" : "references"'
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

# ── rule live-actions move_to/copy_to/flag_color (audit gap B) — CI-safe (pure guards, no Mail) ───
@test "mail rules create previews move_to + flag_color actions (dry-run, exit 0)" {
  run "$BIN" mail rules create --name "apple-cli-test-b" --condition "subject:contains:apple-cli-test" --action "move_to=iCloud/Archive" --action "flag_color=red"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"move_to" : "iCloud/Archive"'
  echo "$output" | grep -q '"flag_color" : "red"'
}

@test "mail rules create with move_to lacking an Account/Mailbox path is a validation error (exit 64)" {
  APPLE_TEST_MODE=1 \
    run "$BIN" mail rules create --name "apple-cli-test-b" --condition "subject:contains:apple-cli-test" --action "move_to=Archive" --execute --test-mode
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

@test "mail rules create with forward_to remains refused at --execute (exit 77, latent auto-send)" {
  APPLE_TEST_MODE=1 \
    run "$BIN" mail rules create --name "apple-cli-test-b" --condition "subject:contains:apple-cli-test" --action "forward_to=a@x.io" --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail rules create DRY-RUN move_to without slash is a validation error (exit 64, preview predicts execute)" {
  # The dry-run now runs liveActionPlan so a bad action shape fails in preview, not only at --execute.
  run "$BIN" mail rules create --name "apple-cli-test-b" --condition "subject:contains:apple-cli-test" --action "move_to=Archive"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

# CONTRACT CHANGE (2026-07-31): a dry-run now DESCRIBES a rule the live path would refuse,
# reporting `live_blockers`, instead of failing with exit 77. `forward_to`, `delete` and
# `--match any` are real oracle capabilities; a preview that cannot represent them drops the
# capability from the CLI surface entirely, which is the very thing strict-superset parity
# forbids. The live refusal itself is unchanged — see the --execute test below.
@test "mail rules create DRY-RUN describes a forward_to rule and names the live blocker" {
  run "$BIN" mail rules create --name "apple-cli-test-b" --condition "subject:contains:apple-cli-test" --action "forward_to=a@x.io"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"live_blockers"'
  echo "$output" | grep -q 'forward_to'
  echo "$output" | grep -q 'would refuse'
}

@test "mail rules create DRY-RUN describes delete and --match any blockers too" {
  run "$BIN" mail rules create --name "apple-cli-test-b" --condition "subject:contains:apple-cli-test" --action "delete=true"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'auto-trash'
  run "$BIN" mail rules create --name "apple-cli-test-b" --condition "subject:contains:apple-cli-test" --action "mark_read=true" --match any
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'match any'
}

# header_name is now wired (Mail.sdef `header key` + the condition's `header` property), so it
# previews with NO blocker where it used to be refused outright.
@test "mail rules create DRY-RUN accepts a header_name condition with no live blocker" {
  run "$BIN" mail rules create --name "apple-cli-test-b" --condition "header_name:contains:v:X-Spam" --condition "subject:contains:apple-cli-test" --action "mark_read=true"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"live_blockers" : \[' 
  ! echo "$output" | grep -q 'would refuse'
}

# The LIVE refusal is unchanged: describing a rule in a preview must never soften execute.
@test "mail rules create --execute with forward_to is still refused (exit 77)" {
  APPLE_TEST_MODE=1 run "$BIN" mail rules create --name "apple-cli-test-b" --condition "subject:contains:apple-cli-test" --action "forward_to=a@x.io" --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail rules update --execute with --match any is still refused (exit 77)" {
  APPLE_TEST_MODE=1 run "$BIN" mail rules update 1 --match any --execute --test-mode
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

@test "mail delete --permanent --execute without --test-mode is refused before any erase (exit 77)" {
  run "$BIN" mail delete 1 --permanent --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"safety_violation"'
}

@test "mail delete --permanent --execute --test-mode without the operator env var is refused (exit 77)" {
  # The subject label is spoofable (anyone can mail the operator an "apple-cli-test ..." subject),
  # so it must never be the SOLE gate on an irreversible erase — an operator-only env var is the
  # required second factor, and an autonomous run never sets it.
  require_index
  run env -u APPLE_ALLOW_PERMANENT_DELETE APPLE_TEST_MODE=1 "$BIN" mail delete --match-subject apple-cli-nonexistent-zzz --permanent --execute --test-mode --account iCloud
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"safety_violation"'
  echo "$output" | grep -q 'APPLE_ALLOW_PERMANENT_DELETE'
}

@test "mail delete --permanent dry-run previews and warns it only erases already-trashed mail" {
  require_index
  run "$BIN" mail delete 1 --permanent
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"action" : "delete_permanent"'
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q 'ALREADY in Trash'
}

# ── empty-trash: wired, but operator-gated (audit gap I) ──────────────────────────────────────
@test "mail trash empty --execute WITHOUT --confirm is a validation error (exit 64)" {
  run "$BIN" mail trash empty --account "Any" --execute
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

@test "mail trash empty --execute --confirm without the operator env var is refused (exit 77)" {
  # The env var is the ONLY gate that can guard empty-trash (it cannot be scoped to test data),
  # so an autonomous run — which never sets it — can never reach the destructive path.
  run env -u APPLE_ALLOW_EMPTY_TRASH "$BIN" mail trash empty --account "Any" --execute --confirm
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"safety_violation"'
  echo "$output" | grep -q 'APPLE_ALLOW_EMPTY_TRASH'
}

@test "mail trash empty --max 0 is a validation error (exit 64)" {
  run "$BIN" mail trash empty --account "Any" --execute --confirm --max 0
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

@test "mail trash empty dry-run previews without touching Mail (exit 0)" {
  run "$BIN" mail trash empty --account "Any"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"action" : "empty_trash"'
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"executed" : false'
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

# --- Oracle-parity: flag_color="none" IS the unflag spelling -------------------
# Oracle A's flag_message derives `flagged_status = flag_color != "none"` and maps "none" to
# flag index -1, so a caller porting `flag_message(ids, flag_color="none")` expects an UNFLAG.
# The CLI previously treated `--color none` as a colorless FLAG, inverting that intent.
@test "mail flag --color none previews as unflag (oracle flag_color=none parity)" {
  require_index
  run "$BIN" mail flag 12345 --color none
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"action" *: *"unflag"'
}

# `flag_color` is oracle A's wire name for the color; `color` is this CLI's original key. Both
# are emitted (additive), so an oracle-shaped consumer finds the key it expects.
@test "mail flag emits both color and flag_color in detail" {
  require_index
  run "$BIN" mail flag 12345 --color red
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"flag_color" *: *"red"'
  echo "$output" | grep -q '"color" *: *"red"'
  echo "$output" | grep -q '"action" *: *"flag"'
}

# `--unflag` keeps working unchanged (it is the same clearing path as --color none).
@test "mail flag --unflag still previews as unflag" {
  require_index
  run "$BIN" mail flag 12345 --unflag
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"action" *: *"unflag"'
}

# --- Oracle-parity: templates render error surface -----------------------------
# Oracle A's `_substitute` raises MailTemplateMissingVariableError naming every unresolved
# placeholder (sorted); the CLI used to leave `{token}` literal, so an un-substituted
# `{recipient_name}` could flow straight into outbound subject/body text.
@test "mail templates render raises missing_template_variable naming all unresolved (exit 64)" {
  export APPLE_MAIL_MCP_HOME="$BATS_TEST_TMPDIR/tpl-missing"
  run "$BIN" mail templates save apple-cli-test-miss --body 'Hi {zeta}, re {alpha}.'
  [ "$status" -eq 0 ]
  run "$BIN" mail templates render apple-cli-test-miss
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" *: *"missing_template_variable"'
  # sorted + de-duplicated
  echo "$output" | grep -q 'missing placeholder(s): alpha, zeta'
}

@test "mail templates render succeeds once every placeholder is supplied" {
  export APPLE_MAIL_MCP_HOME="$BATS_TEST_TMPDIR/tpl-ok"
  run "$BIN" mail templates save apple-cli-test-ok --body 'Hi {who}.' --subject 'S {who}'
  [ "$status" -eq 0 ]
  run "$BIN" mail templates render apple-cli-test-ok --var who=Ada
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"subject" *: *"S Ada"'
  echo "$output" | grep -q '"used_vars"'
}

# `{today}` is auto-filled, so it must NOT be reported missing — and it must be the LOCAL
# calendar date (oracle A uses Python's local `date.today()`, not UTC).
@test "mail templates render auto-fills today without reporting it missing" {
  export APPLE_MAIL_MCP_HOME="$BATS_TEST_TMPDIR/tpl-today"
  run "$BIN" mail templates save apple-cli-test-today --body 'Sent {today}.'
  [ "$status" -eq 0 ]
  run "$BIN" mail templates render apple-cli-test-today
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '"body" *: *"Sent [0-9]{4}-[0-9]{2}-[0-9]{2}'
  echo "$output" | grep -q "$(date +%Y-%m-%d)"
}

# An unresolvable --message-id is an ERROR (oracle A's auto_template_vars calls get_message,
# which raises MailMessageNotFoundError → error_type message_not_found), not a silent
# render-with-only-today.
@test "mail templates render with an unresolvable --message-id is message_not_found (exit 65)" {
  require_index
  export APPLE_MAIL_MCP_HOME="$BATS_TEST_TMPDIR/tpl-mnf"
  run "$BIN" mail templates save apple-cli-test-mnf --body 'Body {today}.'
  [ "$status" -eq 0 ]
  run "$BIN" mail templates render apple-cli-test-mnf --message-id 999999999
  [ "$status" -eq 65 ]
  echo "$output" | grep -q '"type" *: *"message_not_found"'
}

# --- Oracle-parity: input validation the CLI used to accept silently ------------
# Oracle B raises "Invalid sort. Use: date_desc, date_asc" (tools/search.py). The CLI used to
# accept any token, silently sort date_desc, AND echo the bogus token back as `sort` — telling
# the caller their sort was honoured when it was not.
@test "mail search rejects an invalid --sort (exit 64)" {
  require_index
  run "$BIN" mail search --subject test --sort bogus --limit 1
  [ "$status" -eq 64 ]
  echo "$output" | grep -q 'date_desc, date_asc'
}

@test "mail search still accepts both valid --sort values" {
  require_index
  run "$BIN" mail search --subject test --sort date_desc --limit 1
  [ "$status" -eq 0 ]
  run "$BIN" mail search --subject test --sort date_asc --limit 1
  [ "$status" -eq 0 ]
}

# Oracle A returns validation_error "Mailbox name cannot be empty"; oracle B rejects its
# _INVALID_MAILBOX_CHARS set. `--name ""` used to return ok:true with an empty `path`.
@test "mail mailboxes create rejects an empty --name (exit 64)" {
  require_index
  run "$BIN" mail mailboxes create --account iCloud --name ""
  [ "$status" -eq 64 ]
  echo "$output" | grep -q 'cannot be empty'
}

@test "mail mailboxes create rejects a name with an AppleScript-hostile character (exit 64)" {
  require_index
  run "$BIN" mail mailboxes create --account iCloud --name 'bad:name'
  [ "$status" -eq 64 ]
}

# '/' is the documented nesting separator, so it must stay legal in --name.
@test "mail mailboxes create still accepts a nested '/' path" {
  require_index
  run "$BIN" mail mailboxes create --account iCloud --name 'Projects/2024'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"path" *: *"Projects/2024"'
}

@test "mail mailboxes create rejects an empty path segment (exit 64)" {
  require_index
  run "$BIN" mail mailboxes create --account iCloud --name 'Projects//2024'
  [ "$status" -eq 64 ]
}

# --- AppleScript compile coverage ----------------------------------------------
# The AppleScript bodies in MailScript.swift are Swift string literals, so neither `swift build`
# nor the logic tier can see them — a syntax error surfaces only at runtime, on a LIVE Mail
# mutation, i.e. the one path CI cannot exercise. `osacompile` parses without executing, so this
# is the only automated coverage that tier has. It found two real defects on introduction:
# `repeat with it in …` (`it` is reserved) and `set before to …` in the already-committed
# emptyTrashScript (`before` is reserved — that script could never have run).
@test "every AppleScript embedded in MailScript.swift compiles (osacompile)" {
  run python3 "$BATS_TEST_DIRNAME/helpers/applescript_syntax_check.py"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok - nativeReplyScript"
  echo "$output" | grep -q "ok - emptyTrashScript"
  ! echo "$output" | grep -q "^FAIL"
}

# --- Oracle-parity: reads (batch 4) --------------------------------------------
# MCP B names the indexed preview `content_preview`; this repo's own dual-key rule
# (Sources/MailKit/Support/MailModels.swift header) requires carrying BOTH names, and it was
# carrying only `snippet` — so a consumer ported from B found nothing.
@test "mail search emits content_preview alongside snippet (MCP B dual key)" {
  require_index
  # Both keys are omitted when a message has no indexed preview, so assert on a message that
  # actually has one, and assert the two carry the SAME text.
  run python3 -c "
import json,subprocess,sys
out=subprocess.run(['$BIN','mail','search','--mailbox','All','--limit','60'],capture_output=True,text=True).stdout
for m in json.loads(out)['data']['messages']:
    if m.get('snippet'):
        assert m.get('content_preview') == m['snippet'], 'dual keys disagree'
        print('OK'); sys.exit(0)
print('SKIP')
"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ] || skip "no message with an indexed preview in this store"
}

# The two keys are ONE value; --no-content must clear BOTH or the text stays exposed under the
# other name.
@test "mail search --no-content clears both snippet and content_preview" {
  require_index
  run "$BIN" mail search --mailbox All --limit 20 --no-content
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q '"snippet"'
  ! echo "$output" | grep -q '"content_preview"'
}

# Oracle A's get_thread is uncapped. `--limit 0` reached the query as a literal 0, returned no
# rows, and fell through to the singleton fallback — so asking for the WHOLE thread returned one.
@test "mail thread --limit 0 returns the complete thread, not a singleton" {
  require_index
  # A conversation with >1 member, else the assertion proves nothing.
  id=$("$BIN" mail search --mailbox All --limit 400 2>/dev/null | python3 -c "
import json,sys,collections
d=json.load(sys.stdin)['data']['messages']
c=collections.Counter(m.get('conversation_id') for m in d if m.get('conversation_id'))
multi=[k for k,n in c.items() if n>1]
print(next((m['id'] for m in d if m.get('conversation_id') in multi), ''))")
  [ -n "$id" ] || skip "no multi-message conversation in this store"
  n_all=$("$BIN" mail thread "$id" --limit 0 | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['count'])")
  n_one=$("$BIN" mail thread "$id" --limit 1 | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['count'])")
  [ "$n_one" -eq 1 ]
  [ "$n_all" -gt 1 ]
}

# Oracle A create_mailbox returns `mailbox` + `parent`; the joined `path` alone cannot recover the
# name-vs-parent boundary when the name itself contains a '/'.
@test "mail mailboxes create emits mailbox and parent alongside path" {
  require_index
  run "$BIN" mail mailboxes create --account iCloud --name apple-cli-test-box --parent Projects
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"mailbox" *: *"apple-cli-test-box"'
  echo "$output" | grep -q '"parent" *: *"Projects"'
  echo "$output" | grep -q '"path" *: *"Projects/apple-cli-test-box"'
}

# --- Oracle-parity: analytics stats --------------------------------------------
# Oracle B returns "Error: Invalid scope '<s>'. Use: …" and "Error: 'sender' parameter required
# for sender_stats scope" (tools/analytics.py). The CLI silently accepted both: an unknown scope
# returned an account_overview-shaped payload, and sender_stats with no --sender reported
# whole-account numbers as though they were that sender's.
@test "mail analytics stats rejects an invalid --scope (exit 64)" {
  require_index
  run "$BIN" mail analytics stats --account iCloud --scope bogus
  [ "$status" -eq 64 ]
  echo "$output" | grep -q 'account_overview, sender_stats, mailbox_breakdown'
}

@test "mail analytics stats requires --sender for sender_stats (exit 64)" {
  require_index
  run "$BIN" mail analytics stats --account iCloud --scope sender_stats
  [ "$status" -eq 64 ]
  echo "$output" | grep -q 'sender_stats'
}

# SKIP_FOLDERS exclusion: verified against the LIVE oracle on 2026-07-30 — over a 7-day window
# the oracle and the CLI disagreed counting Trash/Sent/etc, and 17 with the
# exclusion. This asserts the exclusion is actually applied (totals must differ once the account
# has any system-folder mail in the window).
@test "mail analytics stats excludes SKIP_FOLDERS unless --include-system-folders" {
  require_index
  a=$("$BIN" mail analytics stats --account iCloud --scope account_overview --days 0 | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['total'])")
  b=$("$BIN" mail analytics stats --account iCloud --scope account_overview --days 0 --include-system-folders | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['total'])")
  [ "$b" -ge "$a" ]
  [ "$b" -gt "$a" ] || skip "account has no mail in system folders to exclude"
}

# --- Regression: prefix-only thread keyword must not become a full-store dump ----
# `stripThreadPrefixes("Re:")` is "", and an empty subjectContains makes EnvelopeIndex append NO
# WHERE clause — so `thread --subject "Re:"` returned arbitrary unrelated messages, and with
# `--limit 0` the ENTIRE live store reported as ok:true. "Re: " is
# exactly what gets copy-pasted off a subject line. Caught in review; locked here at the CALLER
# level, because the pure-function tests actually ASSERT the degenerate "" return value.
@test "mail thread --subject with only reply/forward prefixes is refused (exit 64)" {
  require_index
  for k in "Re:" "RE:" "Fwd:" "FW:" "Fw:" "Re: Fwd:"; do
    run "$BIN" mail thread --subject "$k" --limit 5
    [ "$status" -eq 64 ] || { echo "keyword '$k' was not refused (status $status)"; return 1; }
  done
}

@test "mail thread --subject 'Re: <real keyword>' still matches the whole thread" {
  require_index
  subj=$("$BIN" mail search --mailbox All --limit 1 | python3 -c "
import json,sys; print(json.load(sys.stdin)['data']['messages'][0]['subject'][:20])")
  [ -n "$subj" ] || skip "no messages in store"
  run "$BIN" mail thread --subject "Re: $subj" --limit 5
  [ "$status" -eq 0 ]
}

# --headers-only documents "skip … preview"; decodeSummary populates BOTH preview keys, and the
# old code only re-assigned `snippet` to itself, so neither was ever cleared.
@test "mail get --headers-only emits neither snippet nor content_preview" {
  require_index
  id=$("$BIN" mail search --mailbox All --limit 1 | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['messages'][0]['id'])")
  run "$BIN" mail get "$id" --headers-only
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q '"snippet"'
  ! echo "$output" | grep -q '"content_preview"'
}

# header_name is serialized as the 4th US-delimited field of each RS-delimited condition record,
# so a header name carrying US/RS would shift every following field by one and build a
# differently-typed condition on attacker-chosen text. parseCondition takes the header from the
# FINAL colon-segment of user input, so this is reachable straight from the command line. The
# unit test covers the guard; this covers the CALLER actually invoking it (the create preview
# initially did not).
@test "mail rules create refuses a header name containing a US/RS delimiter (exit 64)" {
  ctl=$(printf '\037')
  run "$BIN" mail rules create --name "apple-cli-test-b" \
      --condition "header_name:contains:v:X-Bad${ctl}injected" \
      --condition "subject:contains:apple-cli-test" --action "mark_read=true"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q 'control characters'
}

# Count result rows whose mailbox LEAF is one of MCP B's SKIP_FOLDERS. Reads a JSON envelope on
# stdin. File-scope so every exclusion test asserts against the same definition of "system
# folder" instead of hand-copying the list per test.
count_sys_folder_rows() {
  python3 -c "
import json,sys
SKIP={'trash','junk','junk email','deleted items','sent','sent items','sent messages',
      'drafts','spam','deleted messages'}
msgs=json.load(sys.stdin)['data']['messages']
print(sum(1 for m in msgs if (m.get('mailbox') or '').split('/')[-1].lower() in SKIP))"
}

# Guard against a malformed probe silently becoming a skip: `[ "$x" -gt 0 ]` on non-numeric
# input exits 2, and on the left of `||` that takes the skip branch instead of failing.
assert_numeric() {
  [[ "$1" =~ ^[0-9]+$ ]] || {
    echo "probe returned non-numeric: '$1'" >&2
    return 1
  }
}

# MCP B excludes SKIP_FOLDERS from a broad "All" sweep (search.py:236, All-branch only), so an
# All-search used to return Trash/Sent/Junk hits the oracle never would. The exclusion changes
# only what "All" MEANS — naming a system mailbox explicitly must still search it.
#
# Assert from DATA, not from counts. A count comparison (`b > a`) degrades to a skip when the
# store has no system mail, and `system_folders_excluded` is computed from the CLI FLAG rather
# than from the query, so a flag-echo assertion cannot detect the exclusion silently ceasing to
# apply. Counting actual system-folder rows in the payload can.
@test "mail search --mailbox All excludes SKIP_FOLDERS unless --include-system-folders" {
  require_index
  # Store-capability probe: are there any system-folder rows to exclude in the first place?
  with_sys=$("$BIN" mail search --mailbox All --limit 0 --include-system-folders | count_sys_folder_rows)
  assert_numeric "$with_sys"
  [ "$with_sys" -gt 0 ] || skip "store has no mail in system folders"
  # With the exclusion ON, none of them may survive.
  without_sys=$("$BIN" mail search --mailbox All --limit 0 | count_sys_folder_rows)
  assert_numeric "$without_sys"
  [ "$without_sys" -eq 0 ]
}

# The exclusion redefines what "All" means; it must NOT make a system mailbox unsearchable.
@test "mail search --mailbox Drafts still returns Drafts despite the All-sweep exclusion" {
  require_index
  n=$("$BIN" mail search --mailbox Drafts --limit 0 | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['count'])")
  assert_numeric "$n"
  [ "$n" -gt 0 ] || skip "store has no Drafts"
}

# The exclusion is invisible in the payload unless it is stated. A caller that sees N results
# for `--mailbox All` has no way to know N was filtered; `system_folders_excluded` puts it in
# the machine contract. Only meaningful for an "All" sweep — null for a named mailbox.
@test "mail search discloses system_folders_excluded on an All sweep only" {
  require_index
  a=$("$BIN" mail search --mailbox All --limit 1 | python3 -c "import json,sys;print(json.load(sys.stdin)['data'].get('system_folders_excluded'))")
  [ "$a" = "True" ]
  b=$("$BIN" mail search --mailbox All --limit 1 --include-system-folders | python3 -c "import json,sys;print(json.load(sys.stdin)['data'].get('system_folders_excluded'))")
  [ "$b" = "False" ]
  c=$("$BIN" mail search --mailbox INBOX --limit 1 | python3 -c "import json,sys;print(json.load(sys.stdin)['data'].get('system_folders_excluded'))")
  [ "$c" = "None" ]
}

# MCP B applies SKIP_FOLDERS in `_search_mail_records` (tools/search.py:167, skip literal at
# :236, All-only) and in tools/analytics.py:139 — NOT in get_email_thread, which lives in the
# SAME module at tools/search.py:595 and builds its own mailbox script with no skip. Excluding
# there dropped the account's own Sent replies out of their own conversation: a silent
# correctness loss, not parity.
#
# Assert the BEHAVIOR, not a --help proxy, and establish a CONTROL first.
#
# Two earlier versions of this test both passed while the bug was live:
#   1. `status -eq 0` + "--help lacks the flag" — vacuous, since a nonexistent subject also
#      exits 0 with count 0.
#   2. "require >=1 system-folder member, else skip" — the filter being ON produces zero such
#      members, which is indistinguishable from a store that genuinely has none, so it SKIPPED
#      instead of failing. Verified by reintroducing `f.includeSystemFolders = false`.
#
# The fix is a control: ask `search --include-system-folders` (a DIFFERENT code path) whether
# the store contains system-folder messages for this subject. Only skip when the control says
# there are none; otherwise `thread` MUST surface them too.
@test "mail thread does NOT exclude system folders (oracle B applies SKIP_FOLDERS only to search)" {
  require_index
  # CONTROL: does this store have system-folder mail for the subject at all?
  control=$("$BIN" mail search --mailbox All --subject "Congratulations" --limit 0 \
              --include-system-folders | count_sys_folder_rows)
  assert_numeric "$control"
  [ "$control" -gt 0 ] || skip "store has no 'Congratulations' mail in system folders"

  run "$BIN" mail thread --subject "Congratulations" --limit 0
  [ "$status" -eq 0 ]
  actual=$(echo "$output" | count_sys_folder_rows)
  assert_numeric "$actual"
  # The control proved they exist; thread excluding them is the regression.
  [ "$actual" -gt 0 ]
}

# scope_note describes a MAILBOX SWEEP. The explicit-ids path never consults the mailbox
# (resolveTargets returns before f.mailboxName is set), so a note there would contradict
# `filter_based: false` in the same envelope. Nothing else in the suite covers the gating —
# the swift-testing cases exercise mailboxScopeNote(_:) in isolation, which knows nothing
# about filterBased.
@test "mail bulk scope_note is suppressed on the explicit-ids path" {
  require_index
  id=$("$BIN" mail search --mailbox INBOX --limit 1 \
        | python3 -c "import json,sys;m=json.load(sys.stdin)['data']['messages'];print(m[0]['id'] if m else '')")
  [ -n "$id" ] || skip "store has no INBOX mail to address by id"
  # --source All would produce a note on the filter-based path; by id it must not.
  run "$BIN" mail move "$id" --source All --to Archive
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"filter_based" *: *false'
  ! echo "$output" | grep -q '"scope_note"'
}

# Reads and mutations disagree about what "All" means: search excludes system folders by default,
# a bulk mutation deliberately does not (a `delete --permanent` target is in Trash by definition).
# The divergence is real and load-bearing, so every bulk envelope states it rather than leaving
# the operator to infer scope from a preview that showed fewer messages.
@test "mail bulk previews disclose the All-scope divergence via scope_note" {
  require_index
  for sub in "move --match-subject apple-cli-test-zzz --source All --to Archive" \
             "mark --read --match-subject apple-cli-test-zzz --mailbox All" \
             "flag --match-subject apple-cli-test-zzz --mailbox All" \
             "delete --match-subject apple-cli-test-zzz --mailbox All"; do
    run "$BIN" mail $sub
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"scope_note"'
    echo "$output" | grep -q 'INCLUDES Trash/Junk/Sent/Drafts/Spam'
  done
  # A named mailbox has no divergence to report.
  run "$BIN" mail move --match-subject apple-cli-test-zzz --source INBOX --to Archive
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q '"scope_note"'
}

@test "mail search --mailbox Trash still searches Trash explicitly" {
  require_index
  run "$BIN" mail search --mailbox Trash --limit 3
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"mailbox" *: *"Trash"'
}

# A preview must report EVERY live refusal. The update preview once dropped self-scoping
# entirely, printing `live_blockers: []` — an affirmative claim that --execute would accept a
# rule it refuses with 77. Reproduced by review; locked here.
@test "mail rules update DRY-RUN reports the self-scoping blocker instead of claiming clean" {
  run "$BIN" mail rules update 1 --condition "from:contains:boss@example.com" --action "mark_read=true"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'subject condition bound to'
}

@test "mail rules create DRY-RUN reports unlabeled-name and self-scoping blockers" {
  run "$BIN" mail rules create --name "quarterly-report-rule" --condition "from:contains:boss@x.io" --action "mark_read=true"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'must start with'
  echo "$output" | grep -q 'subject condition bound to'
}

@test "mail rules create DRY-RUN reports no blockers for a properly labeled self-scoped rule" {
  run "$BIN" mail rules create --name "apple-cli-test-ok" --condition "subject:contains:apple-cli-test" --action "mark_read=true"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'would be refused live'
}

# Oracle A rejects an empty condition value; an empty `contains` matches EVERY message. The
# header_name grammar only produces the empty value AFTER the header is split off.
@test "mail rules create refuses an empty condition value (exit 64)" {
  run "$BIN" mail rules create --name "apple-cli-test-b" --condition "subject:contains:" --action "mark_read=true"
  [ "$status" -eq 64 ]
  run "$BIN" mail rules create --name "apple-cli-test-b" --condition "header_name:contains::X-Foo" --action "mark_read=true"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q 'must not be empty'
}
