#!/usr/bin/env bats

BATS_SUITE_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
REPO_ROOT="$(cd "$BATS_SUITE_ROOT/.." && pwd -P)"
HELPERS="$BATS_SUITE_ROOT/helpers"
# Hosted-safe Mail CLI smoke tests. These cases use synthetic fixtures or resolve before
# Envelope Index and Mail automation access.

setup() {
  BIN="${APPLE_CLI_TEST_BINARY:-$(swift build --show-bin-path)/apple}"
  export APPLE_MAIL_MCP_HOME="$BATS_TEST_TMPDIR/template-text"
}

teardown() {
  # Template-fixture hygiene (review I1): a mid-test failure must not strand a fixture in the
  # template store. Only tests that set GAP37_FIXTURE pay the cleanup invocation; the delete
  # is idempotent and best-effort (the happy path already deleted it as an assertion).
  if [ -n "${GAP37_FIXTURE:-}" ]; then
    "$BIN" mail templates delete --execute "$GAP37_FIXTURE" >/dev/null 2>&1 || true
  fi
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

@test "mail send under APPLE_DRY_RUN=1 is a dry-run preview (v2 env brake, no live send)" {
  # v2 executes flagless writes by default; APPLE_DRY_RUN restores dry-run-by-default
  # globally (precedence: --dry-run > --execute > APPLE_DRY_RUN > surface default).
  APPLE_DRY_RUN=1 run "$BIN" mail send --to nobody@example.invalid --subject "apple-cli-test" --body "hi"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"action" : "send"'
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"executed" : false'
  # Unsandboxed envelopes must NOT carry the sandbox key (byte-identical legacy shape).
  ! echo "$output" | grep -q '"sandbox"'
}

# ── Write-model v2 env contract (docs/write-model-v2.md) — CI-safe, pre-Mail ───────────────────
@test "mail: a junk APPLE_TEST_MODE value is a fail-loud validation_error (exit 64), even on dry-run" {
  # `APPLE_TEST_MODE=ture` must refuse the command, not silently run it unsandboxed.
  APPLE_TEST_MODE=ture run "$BIN" mail send --dry-run --to me@self.test --subject "apple-cli-test x" --body y
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
  echo "$output" | grep -q 'APPLE_TEST_MODE'
}

@test "mail: a junk APPLE_DRY_RUN value is a fail-loud validation_error (exit 64), even with --dry-run" {
  # Validation is eager (validateWriteEnvironment) — `off` must not silently mean "not dry-run".
  APPLE_DRY_RUN=off run "$BIN" mail templates save --dry-run apple-cli-test-junkenv --body y
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
  echo "$output" | grep -q 'APPLE_DRY_RUN'
}

@test "mail: a sandboxed envelope carries sandbox:true" {
  # Allowlist the recipient: sandboxed previews now run guardOutbound too (preview honesty).
  APPLE_TEST_MODE=1 APPLE_TEST_RECIPIENTS="me@self.test" \
    run "$BIN" mail send --dry-run --to me@self.test --subject "apple-cli-test x" --body y
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"sandbox" : true'
}

@test "mail: a junk operator env var value fails loud (exit 64, names the var)" {
  # APPLE_ALLOW_PERMANENT_DELETE parses through the shared truthy helper: a typo'd value must
  # refuse the command (validation), never silently read as denied-or-granted.
  APPLE_ALLOW_PERMANENT_DELETE=maybe run "$BIN" mail delete 1 --permanent --execute
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
  echo "$output" | grep -q 'APPLE_ALLOW_PERMANENT_DELETE'
}

@test "mail draft create without a subject is a usage error (exit 64, not a safety refusal)" {
  # v2 split "no subject supplied" out of the label gate: usage error 64, pre-Mail.
  APPLE_TEST_MODE=1 run "$BIN" mail draft create --body y --to me@self.test --execute --test-mode
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

@test "mail draft send/delete with an EMPTY --subject is a usage error (exit 64), unsandboxed too" {
  # The v1 prefix gate rejected "" as a side effect; v2 must refuse it explicitly — unsandboxed,
  # an empty subject would match every UNTITLED draft (send one / delete all). Pre-Mail.
  run "$BIN" mail draft send --draft-subject "" --execute
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
  run "$BIN" mail draft delete --subject "   " --execute
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

@test "mail reads are IDENTICAL with the sandbox on and off (spec: the sandbox affects writes only)" {
  # Deterministic read over a fixture temp store (search results could change between runs).
  export APPLE_MAIL_MCP_HOME="$BATS_TEST_TMPDIR/read-parity"
  run "$BIN" mail templates save --execute apple-cli-test-readparity --body y
  [ "$status" -eq 0 ]
  a=$("$BIN" mail templates list)
  b=$(APPLE_TEST_MODE=1 "$BIN" mail templates list)
  [ "$a" = "$b" ]
  ! echo "$b" | grep -q '"sandbox"'
}

@test "mail send --dry-run --html --out writes no .eml (fixed bucket-2 defect on the send surface)" {
  OUT="$BATS_TEST_TMPDIR/apple-cli-test-send-preview.eml"
  run "$BIN" mail send --dry-run --to me@self.test --subject "apple-cli-test x" --body y --html "<b>x</b>" --out "$OUT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  [ ! -f "$OUT" ]
}

@test "mail send --out refuses a raw final-leaf symlink before Mail access" {
  target="$BATS_TEST_TMPDIR/send-target.eml"
  link="$BATS_TEST_TMPDIR/send-link.eml"
  printf '%s' "synthetic-before" >"$target"
  ln -s "$target" "$link"

  run "$BIN" mail send --dry-run --to alice@example.com --subject "apple-cli-test raw out" \
    --html "<p>synthetic</p>" --out "$link"
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
  echo "$output" | grep -q 'raw destination'
  [ "$(cat "$target")" = "synthetic-before" ]

  run env APPLE_TEST_MODE=1 APPLE_TEST_RECIPIENTS=alice@example.com "$BIN" mail send \
    --execute --test-mode --to alice@example.com --subject "apple-cli-test raw out" \
    --body "synthetic" --mode open --account "apple-cli-test-missing-account" --out "$link"
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
  echo "$output" | grep -q 'raw destination'
  [ "$(cat "$target")" = "synthetic-before" ]

  run "$BIN" mail draft-rich --dry-run --no-open --subject "apple-cli-test raw out" \
    --text-body "synthetic" --out "$link" --no-clobber
  [ "$status" -eq 77 ]
  echo "$output" | grep -q 'raw destination'
  [ "$(cat "$target")" = "synthetic-before" ]
}

@test "mail draft-rich --out refuses a raw final-leaf symlink before Mail access" {
  target="$BATS_TEST_TMPDIR/draft-rich-target.eml"
  link="$BATS_TEST_TMPDIR/draft-rich-link.eml"
  printf '%s' "synthetic-before" >"$target"
  ln -s "$target" "$link"

  run "$BIN" mail draft-rich --dry-run --no-open --subject "apple-cli-test raw out" \
    --text-body "synthetic" --out "$link"
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
  echo "$output" | grep -q 'raw destination'
  [ "$(cat "$target")" = "synthetic-before" ]

  run "$BIN" mail draft-rich --execute --no-open --subject "apple-cli-test raw out" \
    --text-body "synthetic" --out "$link" --account "apple-cli-test-missing-account"
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
  echo "$output" | grep -q 'raw destination'
  [ "$(cat "$target")" = "synthetic-before" ]
}

@test "mail analytics dashboard --out refuses a raw final-leaf symlink before Mail access" {
  target="$BATS_TEST_TMPDIR/dashboard-target.html"
  link="$BATS_TEST_TMPDIR/dashboard-link.html"
  printf '%s' "synthetic-before" >"$target"
  ln -s "$target" "$link"

  run "$BIN" mail analytics dashboard --dry-run --out "$link"
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
  echo "$output" | grep -q 'raw destination'
  [ "$(cat "$target")" = "synthetic-before" ]
}

# A link hidden behind an absent `..` component is the normalized-leaf spelling the raw probe
# alone cannot see. Every Mail --out surface must refuse it before Mail access, preview included.
@test "mail --out surfaces refuse a final-leaf symlink hidden by absent/.. normalization" {
  target="$BATS_TEST_TMPDIR/normalized-target.eml"
  link="$BATS_TEST_TMPDIR/normalized-link.eml"
  printf '%s' "synthetic-before" >"$target"
  ln -s "$target" "$link"
  hidden="$BATS_TEST_TMPDIR/absent/../normalized-link.eml"

  run "$BIN" mail send --dry-run --to alice@example.com --subject "apple-cli-test hidden out" \
    --html "<p>synthetic</p>" --out "$hidden"
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
  echo "$output" | grep -q 'is a symlink'

  run "$BIN" mail draft-rich --dry-run --no-open --subject "apple-cli-test hidden out" \
    --text-body "synthetic" --out "$hidden"
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
  echo "$output" | grep -q 'is a symlink'

  run "$BIN" mail analytics dashboard --dry-run --out "$hidden"
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
  echo "$output" | grep -q 'is a symlink'

  run "$BIN" mail attachments save --dry-run apple-cli-test-missing-message \
    --allow-outside-home --out "$hidden"
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
  echo "$output" | grep -q 'is a symlink'

  [ "$(cat "$target")" = "synthetic-before" ]
}

# The two per-surface DEFAULTS, pinned with deliberately flagless invocations (markers): the
# general surface EXECUTES flagless (temp-store-confined here), the trash surface previews.
# Nothing else in the suite locks the defaultDryRun arguments — every other invocation carries
# an explicit flag or the env brake, so a flipped default would keep the whole suite green
# while changing what flagless invocations do to real data (review-caught gap). The swift tier
# additionally pins the two trash-surface statics.
@test "v2 default: a flagless general write EXECUTES (templates save, temp store)" {
  export APPLE_MAIL_MCP_HOME="$BATS_TEST_TMPDIR/pin-default"
  run "$BIN" mail templates save apple-cli-test-pin --body y  # flagless-on-purpose
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"name" : "apple-cli-test-pin"'
  ! echo "$output" | grep -q '"would_save_template"'
}

@test "mail templates render fills placeholders from a temp store" {
  export APPLE_MAIL_MCP_HOME="$BATS_TEST_TMPDIR/mcp-home"
  run "$BIN" mail templates save --execute greet --body "Hi {name}" --subject "Hello"
  [ "$status" -eq 0 ]
  run "$BIN" mail templates render greet --var name=World
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Hi World"
}

@test "mail templates save --dry-run previews without writing (fixed bucket-2 defect)" {
  # TemplatesSave used to write DESPITE --dry-run (no willExecute branch); pin the fix.
  export APPLE_MAIL_MCP_HOME="$BATS_TEST_TMPDIR/mcp-home-drypreview"
  run "$BIN" mail templates save --dry-run apple-cli-test-drypreview --body y
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"would_save_template"'
  echo "$output" | grep -q '"dry_run" : true'
  run "$BIN" mail templates list
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'apple-cli-test-drypreview'
}

@test "mail delete --permanent --execute without the operator env var is refused (exit 77, pre-Mail)" {
  # v2: the operator-only APPLE_ALLOW_PERMANENT_DELETE gate is UNCONDITIONAL (sandboxed or
  # not) and fires BEFORE any Mail/index access — an autonomous run never sets it.
  run env -u APPLE_ALLOW_PERMANENT_DELETE "$BIN" mail delete --match-subject apple-cli-nonexistent-zzz --permanent --execute --account iCloud
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"safety_violation"'
  echo "$output" | grep -q 'APPLE_ALLOW_PERMANENT_DELETE'
}

@test "mail get with no id is a usage error (exit 64)" {
  run "$BIN" mail get
  [ "$status" -eq 64 ]
}

@test "mail attachments save with neither id nor --subject is a usage error (exit 64)" {
  # Store-independent: arg-presence is validated before the Envelope Index is opened.
  run "$BIN" mail attachments save --dry-run --dir "$BATS_TEST_TMPDIR"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

# Both oracles refuse an out-of-home or credential-directory destination BEFORE touching Mail
# (patrickfreyer manage.py:197-220). This command previously documented the operator path as
# "TRUSTED" and did neither check, so `--out ~/.ssh/authorized_keys --execute` would have
# overwritten an SSH key with attachment bytes. Refusal is exit 77 (safety), not 64 (usage),
# and it MUST fire on the default dry-run path too — a preview that promises a write --execute
# would refuse is the dishonest-preview failure mode.
@test "mail attachments save refuses an outside-home destination before store access" {
  # Deliberately use a nonexistent id: path safety must win before Envelope Index or Mail.app
  # resolution. If message resolution runs first, this returns not_found instead of exit 77.
  run "$BIN" mail attachments save --dry-run apple-cli-test-missing-message --dir /private/etc
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"safety_violation"'
}

@test "mail attachments save refuses a sensitive directory (exit 77, on dry-run)" {
  run "$BIN" mail attachments save --dry-run apple-cli-test-missing-message --dir "$HOME/.ssh"
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"safety_violation"'
  # --out is the sharper edge: it names a FILE, so an unguarded run would clobber a key.
  run "$BIN" mail attachments save --dry-run apple-cli-test-missing-message \
    --indices 0 --out "$HOME/.ssh/authorized_keys"
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"safety_violation"'
}

# The existence / is-a-directory checks used to sit AFTER the dry-run guard, so a preview
# reported success for a destination --execute would reject.
@test "mail attachments save dry-run rejects a nonexistent directory (preview honesty)" {
  missing="$BATS_TEST_TMPDIR/apple-cli-test-definitely-absent"
  [ ! -e "$missing" ]
  run "$BIN" mail attachments save --dry-run apple-cli-test-missing-message \
    --allow-outside-home --dir "$missing"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

@test "mail attachments save dry-run rejects a directory passed to --out before store access" {
  run "$BIN" mail attachments save --dry-run apple-cli-test-missing-message \
    --allow-outside-home --out "$BATS_TEST_TMPDIR"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

@test "mail attachments save dry-run rejects a missing --out parent before store access" {
  missing_parent="$BATS_TEST_TMPDIR/apple-cli-test-missing-parent"
  [ ! -e "$missing_parent" ]
  run "$BIN" mail attachments save --dry-run apple-cli-test-missing-message \
    --allow-outside-home --out "$missing_parent/attachment.txt"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
  echo "$output" | grep -q -- '--out parent directory does not exist'
}

@test "mail attachments save refuses a raw --out symlink before store access" {
  target="$BATS_TEST_TMPDIR/apple-cli-test-target"
  link="$BATS_TEST_TMPDIR/apple-cli-test-link"
  printf 'synthetic' > "$target"
  ln -s "$target" "$link"
  run "$BIN" mail attachments save --dry-run apple-cli-test-missing-message \
    --allow-outside-home --out "$link"
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"safety_violation"'
  echo "$output" | grep -q 'is a symlink'
  # Foundation's symlink check must keep catching equivalent trailing spellings too.
  for suffix in / /. /./; do
    run "$BIN" mail attachments save --dry-run apple-cli-test-missing-message \
      --allow-outside-home --out "$link$suffix"
    [ "$status" -eq 77 ]
    echo "$output" | grep -q '"safety_violation"'
    echo "$output" | grep -q 'is a symlink'
  done
}

# `--dry-run` was advertised in --help and silently ignored: export mkdir -p'd and wrote one file
# per message regardless. On a command that writes message BODIES to disk that is the worst kind
# of ignored parameter.
@test "mail attachments save with both --dir and --out is a usage error (exit 64)" {
  # Store-independent: --dir/--out mutual exclusion is validated before the Envelope Index opens.
  run "$BIN" mail attachments save --dry-run --subject x --dir "$BATS_TEST_TMPDIR" --out "$BATS_TEST_TMPDIR/f"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

@test "mail attachments save with neither --dir nor --out is a usage error (exit 64)" {
  run "$BIN" mail attachments save --dry-run --subject x
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

@test "mail attachments save with both --name and --indices is a usage error (exit 64)" {
  # Store-independent: --name/--indices mutual exclusion is validated before the Envelope Index opens.
  run "$BIN" mail attachments save --dry-run --subject x --dir "$BATS_TEST_TMPDIR" --name foo --indices 0
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

@test "mail thread exposes --references (MCP A header-threading) mode" {
  run "$BIN" mail thread --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '--references'
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

@test "mail send to a NON-self recipient is refused inside the sandbox (env signal alone, exit 77)" {
  APPLE_TEST_MODE=1 APPLE_TEST_RECIPIENTS="me@self.test" \
    run "$BIN" mail send --to someone-else@example.com --subject "apple-cli-test x" --body y --mode send --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
  echo "$output" | grep -q 'sandbox active'
}

@test "mail send to a NON-self recipient is refused inside the sandbox (flag signal alone, exit 77)" {
  # --test-mode with NO env — v2's single-signal contract: the flag alone engages the sandbox.
  APPLE_TEST_RECIPIENTS="me@self.test" \
    run "$BIN" mail send --to someone-else@example.com --subject "apple-cli-test x" --body y --mode send --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
  echo "$output" | grep -q 'sandbox active'
}

@test "mail send inside the sandbox with an EMPTY allowlist is refused (fail-closed, exit 77)" {
  run env -u APPLE_TEST_RECIPIENTS APPLE_TEST_MODE=1 "$BIN" mail send --to me@self.test --subject "apple-cli-test x" --body y --mode send --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail send under APPLE_DRY_RUN=1 previews the send surface (exit 0, dry_run true)" {
  APPLE_DRY_RUN=1 run "$BIN" mail send --to me@self.test --subject "apple-cli-test x" --body y
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"executed" : false'
}

# ── HTML / attachment send: the sandbox gate fires IDENTICALLY (regression-lock) ────────────────
# HTML + attachment live send is wired (via the multipart .eml / make-new-attachment routes), so
# these prove the NEW paths route through the SAME guardOutbound before any AppleScript send — no
# HTML/attachment path bypasses the sandbox's self-only restriction. All fire before any Mail access.

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

@test "mail send --html inside the sandbox with an EMPTY allowlist is refused (exit 77)" {
  run env -u APPLE_TEST_RECIPIENTS APPLE_TEST_MODE=1 "$BIN" mail send --to me@self.test --subject "apple-cli-test x" --body y \
    --html "<b>hi</b>" --mode send --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail send --attach inside the sandbox with an EMPTY allowlist is refused before the attachment read (exit 77)" {
  # guardOutbound fires BEFORE resolveAttachmentPath, so the missing file never turns this
  # refusal into a not_found.
  run env -u APPLE_TEST_RECIPIENTS APPLE_TEST_MODE=1 "$BIN" mail send --to me@self.test --subject "apple-cli-test x" --body y \
    --attach /tmp/apple-cli-test-nonexistent --mode send --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail send --html under APPLE_DRY_RUN=1 previews without sending (has_html true, dry_run)" {
  APPLE_DRY_RUN=1 run "$BIN" mail send --to me@self.test --subject "apple-cli-test x" --body y --html "<b>hi</b>"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"has_html" : true'
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"executed" : false'
}

@test "mail send --attach with a missing file is not_found before any send (exit 65)" {
  # Store-independent: attachment existence is validated before any Mail/AppleScript access.
  run "$BIN" mail send --dry-run --to me@self.test --subject "apple-cli-test x" --body y \
    --attach /tmp/apple-cli-test-definitely-missing-zzz
  [ "$status" -eq 65 ]
  echo "$output" | grep -q '"type" : "not_found"'
}

@test "mail send --attach exceeding the 25 MB cap is refused before any send (validation_error, exit 64)" {
  # 26 MB sparse file — instant, no real bytes written; matches s-morgan's 25 MB send limit.
  BIG="$BATS_TEST_TMPDIR/apple-cli-test-big.bin"
  dd if=/dev/zero of="$BIG" bs=1 count=0 seek=27262976 2>/dev/null
  run "$BIN" mail send --dry-run --to me@self.test --subject "apple-cli-test x" --body y --attach "$BIG"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "mail send --attach with a dangerous executable extension (.sh) is refused (validation_error, exit 64)" {
  # Matches s-morgan validate_attachment_type — executables/scripts are blocked by default.
  SH="$BATS_TEST_TMPDIR/apple-cli-test-payload.sh"
  printf '#!/bin/sh\necho hi\n' > "$SH"
  run "$BIN" mail send --dry-run --to me@self.test --subject "apple-cli-test x" --body y --attach "$SH"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "mail draft-rich --bcc writes a Bcc header into the generated .eml (compose-window safe)" {
  # draft-rich .eml is only opened / saved, never wire-sent, so carrying --bcc is safe + parity.
  # --no-open keeps this a headless local file write (open_in_mail now defaults to true, oracle
  # B parity) — tmpdir-confined here, and this test is about the Bcc header, not opening.
  OUT="$BATS_TEST_TMPDIR/apple-cli-test-draft.eml"
  run "$BIN" mail draft-rich --execute --to me@self.test --bcc secret@self.test \
    --subject "apple-cli-test dr" --html "<b>x</b>" --out "$OUT" --no-open
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
  run "$BIN" mail send --dry-run --to me@self.test --subject "apple-cli-test x" --body y --gui-send --mode send
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "mail send --html --gui-send with --mode draft is a usage error (exit 64, send-only)" {
  run "$BIN" mail send --dry-run --to me@self.test --subject "apple-cli-test x" --body y --html "<b>hi</b>" --gui-send --mode draft
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

@test "mail send --html --gui-send inside the sandbox with an EMPTY allowlist is refused (exit 77)" {
  run env -u APPLE_TEST_RECIPIENTS APPLE_TEST_MODE=1 "$BIN" mail send --to me@self.test --subject "apple-cli-test x" --body y \
    --html "<b>hi</b>" --gui-send --mode send --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail send --html default (no --gui-send) reports opened field in preview (dry_run)" {
  run "$BIN" mail send --dry-run --to me@self.test --subject "apple-cli-test x" --body y --html "<b>hi</b>"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"opened" : false'
  echo "$output" | grep -q '"dry_run" : true'
}

@test "mail rules create with an UNLABELED name is refused under --execute --test-mode (exit 77)" {
  APPLE_TEST_MODE=1 \
    run "$BIN" mail rules create --name "real-inbox-rule" --condition "from:contains:boss@example.com" --action "mark_read=true" --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

# ── rule live-actions move_to/copy_to/flag_color (audit gap B) — CI-safe (pure guards, no Mail) ───
@test "mail rules create previews move_to + flag_color actions (dry-run, exit 0)" {
  run "$BIN" mail rules create --dry-run --name "apple-cli-test-b" --condition "subject:contains:apple-cli-test" --action "move_to=iCloud/Archive" --action "flag_color=red"
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
    run "$BIN" mail rules create --name "apple-cli-test-b" --condition "subject:contains:apple-cli-test" --action "forward_to=a@example.com" --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail rules create DRY-RUN move_to without slash is a validation error (exit 64, preview predicts execute)" {
  # The dry-run now runs liveActionPlan so a bad action shape fails in preview, not only at --execute.
  run "$BIN" mail rules create --dry-run --name "apple-cli-test-b" --condition "subject:contains:apple-cli-test" --action "move_to=Archive"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

# CONTRACT CHANGE (2026-07-31): a dry-run now DESCRIBES a rule the live path would refuse,
# reporting `live_blockers`, instead of failing with exit 77. `forward_to` and `--match any` are
# real oracle capabilities; a preview that cannot represent them drops the capability from the CLI
# surface entirely, which is the very thing strict-superset parity forbids. The live refusal itself
# is unchanged — see the --execute test below.
# UPDATE (gap25, operator-ruled 2026-08-19): `delete` USED to sit in that refused-live list too. It
# no longer does — it is LIVE-WIRED (full oracle-A parity), so it is not a blocker at all; it
# carries an advisory `warnings` entry instead. See the delete preview test below.
@test "mail rules create DRY-RUN describes a forward_to rule and names the live blocker" {
  run "$BIN" mail rules create --dry-run --name "apple-cli-test-b" --condition "subject:contains:apple-cli-test" --action "forward_to=a@example.com"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"live_blockers"'
  echo "$output" | grep -q 'forward_to'
  echo "$output" | grep -q 'would refuse'
}

# gap25 (operator-ruled 2026-08-19): `delete` is LIVE-WIRED, so the preview must report it as an
# advisory WARNING and NOT as a live blocker.
#
# ASSERT ON THE STRUCTURED FIELDS, NOT ON PROSE. The first version of this test grepped the
# substring `auto-trash`, which appears in BOTH the pre-wiring blocker ("delete: a live rule that
# can auto-trash mail is refused …") and the new advisory warning — so it passed identically with
# the wiring present or reverted, i.e. it was not revert-red for the thing it claimed to cover.
# The discriminator is the SHAPE, not the words: on the pre-wiring build `live_blockers` carried
# the delete entry (so `== []` fails) and `warnings` was empty (so `len(w) == 1` fails).
@test "mail rules create DRY-RUN reports delete via warnings with an EMPTY live_blockers (gap25)" {
  run "$BIN" mail rules create --dry-run --name "apple-cli-test-b" --condition "subject:contains:apple-cli-test" --action "delete=true"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json,sys
d = json.load(sys.stdin)['data']
assert d['dry_run'] is True, d
# The previewed rule still CARRIES the action — a preview that silently drops the capability is
# exactly the strict-superset failure this contract exists to prevent.
assert d['rule']['actions']['delete'] is True, d['rule']
# TRUE ONLY WITH DELETE WIRED: not a blocker at all, and the concern rides on warnings instead.
assert d['live_blockers'] == [], d['live_blockers']
w = d['warnings']
assert len(w) == 1, w
assert w[0].startswith('delete:') and 'auto-trash' in w[0], w
note = d['note'] or ''
assert 'advisory' in note, note
assert 'would refuse' not in note, note
"
}

# The same wiring landed on the UPDATE preview, which builds its note independently of
# emitRulePreview — a regression on one surface only would otherwise go unseen. Mail-free: a
# dry-run returns before `requireLabeledRule`, so index 1 is named but never read or touched.
# --enabled is deliberately NOT passed here: the execute-time enable-gate is not modeled by the
# preview, and asserting `live_blockers == []` with --enabled present would lock that divergence in.
@test "mail rules update DRY-RUN reports delete via warnings with an EMPTY live_blockers (gap25)" {
  run "$BIN" mail rules update --dry-run 1 --action "delete=true"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json,sys
d = json.load(sys.stdin)['data']
assert d['dry_run'] is True, d
assert d['patch']['actions']['delete'] is True, d['patch']
assert d['live_blockers'] == [], d['live_blockers']
w = d['warnings']
assert len(w) == 1, w
assert w[0].startswith('delete:') and 'auto-trash' in w[0], w
note = d['note'] or ''
assert 'advisory' in note, note
assert 'would refuse' not in note, note
"
}

@test "mail rules create DRY-RUN describes (sandboxed) --match any as a blocker" {
  # The --match any restriction is the SANDBOX's, so its blocker only appears in a sandboxed preview (v2).
  APPLE_TEST_MODE=1 run "$BIN" mail rules create --dry-run --name "apple-cli-test-b" --condition "subject:contains:apple-cli-test" --action "mark_read=true" --match any --test-mode
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'match any'
  # Unsandboxed, --match any is a plain oracle capability: no blocker.
  run "$BIN" mail rules create --dry-run --name "apple-cli-test-b" --condition "subject:contains:apple-cli-test" --action "mark_read=true" --match any
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'would refuse'
}

# header_name is now wired (Mail.sdef `header key` + the condition's `header` property), so it
# previews with NO blocker where it used to be refused outright.
@test "mail rules create DRY-RUN accepts a header_name condition with no live blocker" {
  run "$BIN" mail rules create --dry-run --name "apple-cli-test-b" --condition "header_name:contains:v:X-Spam" --condition "subject:contains:apple-cli-test" --action "mark_read=true"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"live_blockers" : \['
  ! echo "$output" | grep -q 'would refuse'
}

# The LIVE refusal is unchanged: describing a rule in a preview must never soften execute.
@test "mail rules create --execute with forward_to is still refused (exit 77)" {
  APPLE_TEST_MODE=1 run "$BIN" mail rules create --name "apple-cli-test-b" --condition "subject:contains:apple-cli-test" --action "forward_to=a@example.com" --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail rules update --execute with --match any is still refused (exit 77)" {
  APPLE_TEST_MODE=1 run "$BIN" mail rules update 1 --match any --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail rules update: a sandboxed rename must keep the test label (exit 77, before any Mail access)" {
  # v2: the label restriction is the sandbox's. requireLabeledName fires on the unlabeled
  # rename BEFORE requireLabeledRule ever reads Mail's rules.
  APPLE_TEST_MODE=1 run "$BIN" mail rules update 1 --name "real-inbox-rule" --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

# gap25 sandbox gate, asserted in the ONLY shape that is safe to run. TWO independent properties
# make it impossible for this test to arm a delete rule, so its failure mode is a red test and
# never a mutation:
#   1. the refusal fires in the sandbox block, BEFORE `liveActionPlan` and before
#      `requireLabeledRule` touches Mail at all (non-self-scoped --condition);
#   2. the target index is one that cannot exist, so even if (1) ever regressed the run dies at
#      `requireLabeledRule` with rule_not_found (exit 65) having mutated nothing.
#
# WHAT THIS DOES NOT COVER, DELIBERATELY: the in-place enable-gate itself (RuleTemplateCommands
# "wiring move_to/copy_to/delete on an in-place update cannot also ENABLE the rule in the same
# command"). Reaching that gate requires a REAL `apple-cli-test`-labeled rule in the live store,
# because `requireLabeledRule` reads Mail's rule list first — and if the gate ever regressed, the
# act of running such a test would ARM an auto-trash rule on the operator's machine. A
# refusal-asserting test whose failure mode is "does the dangerous thing it was written to forbid"
# is not a safe test, and docs/port-specs/mail.md (op 27) already rules that no agent may
# live-verify a delete rule — the first live exercise is the operator's. That gate is covered
# where it can be exercised without a live store: the Swift logic tier under Tests/MailKitTests
# (the in-place enable-gate predicate + its refusal wording), not here.
@test "mail rules update wiring delete + --enabled is refused pre-Mail when conditions are not self-scoped (exit 77)" {
  APPLE_TEST_MODE=1 run "$BIN" mail rules update 999999 --action "delete=true" --enabled \
    --condition "from:contains:someone@example.com" --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
  # Name WHICH gate fired — a bare 77 could be any sandbox refusal, which would make this vacuous.
  echo "$output" | grep -q 'subject condition'
  # Nothing was applied: no success envelope, no executed flag.
  echo "$output" | grep -q '"ok" : false'
  ! echo "$output" | grep -q '"executed" : true'
}

@test "mail rules update with an invalid --match is a validation_error (exit 64)" {
  run "$BIN" mail rules update 1 --match sideways --execute
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"validation_error"'
}

@test "mail rules update --dry-run previews the patch without touching Mail (exit 0)" {
  run "$BIN" mail rules update --dry-run 3 --name "apple-cli-test-renamed"
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
  # CI-safe (--dry-run → preview, no Mail access; v2 executes flagless). Locks that `draft create` ACCEPTS the
  # sender-identity + cc/bcc flags: a regression dropping --cc/--bcc from the parser, or --account,
  # would fail here. The live create→send behaviour (draft stored with the --account sender + cc, then
  # delivered From that address to the cc) is validated on-device per CHANGELOG.
  run "$BIN" mail draft --dry-run create --subject "apple-cli-test draftsend-cc" --body hi \
    --to me@self.test --cc alias@self.test --bcc hidden@self.test --account "Some Account"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"executed" : false'
  echo "$output" | grep -q '"account" : "Some Account"'
}

@test "mail delete <id> --permanent --execute without the operator env var is refused before any erase (exit 77)" {
  # v2: unconditional operator gate, sandboxed or not — fires before the id is even resolved.
  run env -u APPLE_ALLOW_PERMANENT_DELETE "$BIN" mail delete 1 --permanent --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"safety_violation"'
  echo "$output" | grep -q 'APPLE_ALLOW_PERMANENT_DELETE'
}

@test "mail delete --permanent --execute --test-mode without the operator env var is refused (exit 77)" {
  # The subject label is spoofable (anyone can mail the operator an "apple-cli-test ..." subject),
  # so it must never be the SOLE gate on an irreversible erase — the operator-only env var is the
  # required second factor IN BOTH MODES, and an autonomous run never sets it. Fires before the
  # Envelope Index opens (store-independent).
  run env -u APPLE_ALLOW_PERMANENT_DELETE APPLE_TEST_MODE=1 "$BIN" mail delete --match-subject apple-cli-nonexistent-zzz --permanent --execute --test-mode --account iCloud
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"safety_violation"'
  echo "$output" | grep -q 'APPLE_ALLOW_PERMANENT_DELETE'
}

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

# ── Non-sending draft/open modes (gap 4) — all CI-safe: dry-run previews + gate refusals ─────────
# send --mode open / --mode draft, draft open, and draft-rich --open/--save-as-draft (--open is now
# ALSO the default — oracle B `open_in_mail=True` parity, `--no-open` opts out) are NON-sending
# (they never reach an AppleScript `send`). These lock the dry-run + safety-gate surface WITHOUT any
# real Mail access: every assertion is a dry-run preview or a refusal that fires before Mail is touched.
# draft-rich tests below that DO `--execute` a headless write pass `--no-open` explicitly so the
# suite never launches a live Mail.app compose window.

@test "mail send --mode open --dry-run is a preview (exit 0, opened/drafted false)" {
  run "$BIN" mail send --dry-run --to me@self.test --subject "apple-cli-test open" --body hi --mode open
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"opened" : false'
  echo "$output" | grep -q '"drafted" : false'
}

@test "mail send --mode draft under APPLE_DRY_RUN=1 previews without persisting (exit 0)" {
  # v2: an unsandboxed `--mode draft` REALLY saves a Drafts item (oracle parity), so the
  # CI-safe assertion is the env brake; the sandbox label gate is covered just below.
  APPLE_DRY_RUN=1 run "$BIN" mail send --to me@self.test --subject "apple-cli-test draft" --body y --mode draft
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"drafted" : false'
}

@test "mail send --mode draft with an UNLABELED subject is refused under --execute --test-mode (exit 77)" {
  # The label half of the draft gate fires before any Mail access.
  APPLE_TEST_MODE=1 \
    run "$BIN" mail send --to me@self.test --subject "Quarterly report" --body y --mode draft --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail draft open inside the sandbox without a labeled subject is refused (exit 77, before any Mail access)" {
  # v2: the label restriction is the sandbox's; it fires before Mail is opened.
  APPLE_TEST_MODE=1 run "$BIN" mail draft open --draft-subject "not-a-test-draft" --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail draft send under APPLE_DRY_RUN=1 previews without touching Mail (exit 0)" {
  # v2: an unsandboxed `draft send` REALLY delivers the named Drafts item (oracle parity), so
  # the CI-safe assertion is the env brake; the sandbox label gate is covered just below.
  APPLE_DRY_RUN=1 run "$BIN" mail draft send --draft-subject "apple-cli-test x"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"executed" : false'
}

@test "mail draft send with an UNLABELED subject is refused under the test gate (exit 77)" {
  # The label half fires before the draft is even looked up; the draft's own stored recipients
  # are additionally verified against the self-only allowlist inside the send script itself.
  APPLE_TEST_MODE=1 \
    run "$BIN" mail draft send --draft-subject "Quarterly report" --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "mail draft-rich --save-as-draft inside the sandbox with an EMPTY allowlist is refused even in preview (exit 77)" {
  # Opening the compose window is guardOutbound-gated UNCONDITIONALLY (dry-run included) —
  # the sandbox's self-only restriction fires before any Mail access or .eml write.
  OUT="$BATS_TEST_TMPDIR/apple-cli-test-dr.eml"
  run env -u APPLE_TEST_RECIPIENTS APPLE_TEST_MODE=1 "$BIN" mail draft-rich --dry-run --to me@self.test --subject "apple-cli-test dr" --html "<b>x</b>" --save-as-draft --out "$OUT" --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
  [ ! -f "$OUT" ]
}

@test "mail draft-rich --open inside the sandbox with an EMPTY allowlist is refused even in preview (exit 77)" {
  # --open opens a live compose window → same sandbox self-only guardOutbound as `send --mode open`.
  OUT="$BATS_TEST_TMPDIR/apple-cli-test-dr.eml"
  run env -u APPLE_TEST_RECIPIENTS APPLE_TEST_MODE=1 "$BIN" mail draft-rich --dry-run --to me@self.test --subject "apple-cli-test dr" --html "<b>x</b>" --open --out "$OUT" --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
  [ ! -f "$OUT" ]
}

@test "mail draft-rich with NEITHER --open NOR --no-open hits the same live-open gate as --open (open_in_mail defaults true, oracle B parity)" {
  # Operator-ruled (2026-08-19): open_in_mail now defaults to true, matching oracle B's
  # create_rich_email_draft signature. A bare invocation (no --open/--no-open) must therefore be
  # refused by the SAME sandbox self-only guardOutbound gate as an explicit --open — proven here
  # without ever touching Mail (dry-run refuses before any Mail access, same as the --open test
  # immediately above).
  OUT="$BATS_TEST_TMPDIR/apple-cli-test-dr-default.eml"
  run env -u APPLE_TEST_RECIPIENTS APPLE_TEST_MODE=1 "$BIN" mail draft-rich --dry-run --to me@self.test --subject "apple-cli-test dr" --html "<b>x</b>" --out "$OUT" --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
  [ ! -f "$OUT" ]
}

@test "mail draft-rich --no-open bypasses the live-open gate even with an EMPTY sandbox allowlist (headless write, exit 0)" {
  # The converse of the test above: --no-open reverts to the pre-2026-08-19 headless-write path,
  # which never calls guardOutbound, so an empty recipient allowlist does not block it.
  OUT="$BATS_TEST_TMPDIR/apple-cli-test-dr-noopen.eml"
  run env -u APPLE_TEST_RECIPIENTS APPLE_TEST_MODE=1 "$BIN" mail draft-rich --execute --to me@self.test --subject "apple-cli-test dr" --html "<b>x</b>" --out "$OUT" --no-open --test-mode
  [ "$status" -eq 0 ]
  [ -f "$OUT" ]
  echo "$output" | grep -q '"opened" : false'
}

@test "mail draft-rich --no-open (no save flag) writes the .eml and reports opened false (exit 0)" {
  # --no-open is required here: since open_in_mail now defaults to true (oracle B parity), a bare
  # invocation would try to launch a live Mail.app compose window — --no-open keeps this test's
  # actual subject (headless write + the `opened` field + the written artifact) CI-safe.
  OUT="$BATS_TEST_TMPDIR/apple-cli-test-dr.eml"
  run "$BIN" mail draft-rich --execute --to me@self.test --subject "apple-cli-test dr" --html "<b>x</b>" --out "$OUT" --no-open
  [ "$status" -eq 0 ]
  [ -f "$OUT" ]
  echo "$output" | grep -q '"opened" : false'
  # An operator-chosen --out is THEIRS: we write where they said and do not re-mode it. Only the
  # no---out temp gets relocated into the owned 0700 directory and chmodded 0600 (Q4f). Without
  # this line, dropping the `if out == nil` guard would silently start chmodding operator files
  # to 0600 with the whole suite green.
  [ "$(stat -f '%Lp' "$OUT")" != "600" ]
}

@test "mail draft-rich with no --out writes 0600 into the validated 0700 cache dirs" {
  # The POSITIVE counterpart to the --out test above. Without it, deleting every
  # `restrictToOwner` call left the suite green: the --out test only asserts a file is NOT
  # 600, which stays true when nothing is chmodded at all. gap20 moved the default from the
  # apple-cli-eml temp dir to the DETERMINISTIC rich-drafts cache path, created through the
  # OwnedTempDir.make 0700/lstat primitive (review: a pre-planted symlink must not redirect
  # drafts) — assert the new contract end to end. --no-open keeps this headless (see the test
  # above — open_in_mail now defaults to true).
  run "$BIN" mail draft-rich --execute --to me@self.test --subject "apple-cli-test dr" --html "<b>x</b>" --no-open
  [ "$status" -eq 0 ]
  EML="$(echo "$output" | sed -n 's/.*"eml_path" : "\(.*\)".*/\1/p')"
  [ -n "$EML" ]
  [ -f "$EML" ]
  [ "$(stat -f '%Lp' "$EML")" = "600" ]
  DIR="$(dirname "$EML")"
  [ "$(basename "$DIR")" = "rich-drafts" ]
  [ "$(stat -f '%Lp' "$DIR")" = "700" ]
  [ "$(basename "$(dirname "$DIR")")" = "apple-cli" ]
  [ "$(stat -f '%Lp' "$(dirname "$DIR")")" = "700" ]
  rm -f "$EML"                      # ours, created by this test — remove only this file
}

@test "mail draft-rich --dry-run writes nothing (fixed bucket-2 defect)" {
  # DraftRichCommand used to write the .eml DESPITE --dry-run (no willExecute branch); pin the fix.
  OUT="$BATS_TEST_TMPDIR/apple-cli-test-dr-preview.eml"
  run "$BIN" mail draft-rich --dry-run --to me@self.test --subject "apple-cli-test dr" --html "<b>x</b>" --out "$OUT"
  [ "$status" -eq 0 ]
  [ ! -f "$OUT" ]
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q 'nothing written'
}

# --- Oracle-parity: flag_color="none" IS the unflag spelling -------------------
# Oracle A's flag_message derives `flagged_status = flag_color != "none"` and maps "none" to
# flag index -1, so a caller porting `flag_message(ids, flag_color="none")` expects an UNFLAG.
# The CLI previously treated `--color none` as a colorless FLAG, inverting that intent.
@test "mail templates render raises missing_template_variable naming all unresolved (exit 64)" {
  export APPLE_MAIL_MCP_HOME="$BATS_TEST_TMPDIR/tpl-missing"
  run "$BIN" mail templates save --execute apple-cli-test-miss --body 'Hi {zeta}, re {alpha}.'
  [ "$status" -eq 0 ]
  run "$BIN" mail templates render apple-cli-test-miss
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" *: *"missing_template_variable"'
  # sorted + de-duplicated
  echo "$output" | grep -q 'missing placeholder(s): alpha, zeta'
}

@test "mail templates render succeeds once every placeholder is supplied" {
  export APPLE_MAIL_MCP_HOME="$BATS_TEST_TMPDIR/tpl-ok"
  run "$BIN" mail templates save --execute apple-cli-test-ok --body 'Hi {who}.' --subject 'S {who}'
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
  run "$BIN" mail templates save --execute apple-cli-test-today --body 'Sent {today}.'
  [ "$status" -eq 0 ]
  run "$BIN" mail templates render apple-cli-test-today
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '"body" *: *"Sent [0-9]{4}-[0-9]{2}-[0-9]{2}'
  echo "$output" | grep -q "$(date +%Y-%m-%d)"
}

# An unresolvable --message-id is an ERROR (oracle A's auto_template_vars calls get_message,
# which raises MailMessageNotFoundError → error_type message_not_found), not a silent
# render-with-only-today.
@test "AppleScript syntax checker materializes integers and rejects unresolved interpolation" {
  run python3 - "$HELPERS/applescript_syntax_check.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("applescript_syntax_check", sys.argv[1])
module = importlib.util.module_from_spec(spec)
# The helper's __main__ guard keeps this import from running the full osacompile sweep.
spec.loader.exec_module(module)

def expect_equal(label, actual, expected):
    if actual != expected:
        raise SystemExit(f"FAIL - {label}")

source = "    static let timeoutSeconds = 180\n"
body = r"with timeout of \(MailScript.timeoutSeconds) seconds"
materialized = module.materialize_integer_interpolations(source, body)
expect_equal("integer", materialized, "with timeout of 180 seconds")
expect_equal(
    "idempotence",
    module.materialize_integer_interpolations(source, materialized),
    materialized,
)
expect_equal(
    "unknown",
    module.materialize_integer_interpolations(
        source, r"\(MailScript.unknownValue)"
    ),
    r"\(MailScript.unknownValue)",
)
expect_equal(
    "escaped",
    module.materialize_integer_interpolations(
        source, r"\\(MailScript.timeoutSeconds)"
    ),
    r"\\(MailScript.timeoutSeconds)",
)
expect_equal(
    "escaped-then-interpolated",
    module.materialize_integer_interpolations(
        source, r"\\\(MailScript.timeoutSeconds)"
    ),
    r"\\180",
)
expect_equal(
    "string-constant",
    module.materialize_integer_interpolations(
        '    static let timeoutSeconds = "180"\n',
        r"\(MailScript.timeoutSeconds)",
    ),
    r"\(MailScript.timeoutSeconds)",
)
expect_equal(
    "typed-constant",
    module.materialize_integer_interpolations(
        "    static let timeoutSeconds: Int = 180\n",
        r"\(MailScript.timeoutSeconds)",
    ),
    r"\(MailScript.timeoutSeconds)",
)
expect_equal(
    "ambiguous-constant",
    module.materialize_integer_interpolations(
        "    static let timeoutSeconds = 180\n"
        "    static let timeoutSeconds = 181\n",
        r"\(MailScript.timeoutSeconds)",
    ),
    r"\(MailScript.timeoutSeconds)",
)

if not module.check("synthetic-escaped", r'return "a\\(b)"'):
    raise SystemExit("FAIL - escaped backslash was rejected")
if module.check("synthetic-unresolved", r'return "\(MailScript.unknownValue)"'):
    raise SystemExit("FAIL - unresolved interpolation was accepted")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAIL - synthetic-unresolved: unresolved Swift interpolation"* ]]
}

# --- Oracle-parity: reads (batch 4) --------------------------------------------
# MCP B names the indexed preview `content_preview`; this repo's own dual-key rule
# (Sources/MailKit/Support/MailModels.swift header) requires carrying BOTH names, and it was
# carrying only `snippet` — so a consumer ported from B found nothing.
@test "mail rules create refuses a header name containing a US/RS delimiter (exit 64)" {
  ctl=$(printf '\037')
  run "$BIN" mail rules create --dry-run --name "apple-cli-test-b" \
      --condition "header_name:contains:v:X-Bad${ctl}injected" \
      --condition "subject:contains:apple-cli-test" --action "mark_read=true"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q 'control characters'
}

@test "mail rules update sandboxed DRY-RUN reports the self-scoping blocker instead of claiming clean" {
  # v2: self-scoping is the SANDBOX's restriction, so the blocker appears in a sandboxed preview.
  APPLE_TEST_MODE=1 run "$BIN" mail rules update --dry-run 1 --condition "from:contains:boss@example.com" --action "mark_read=true" --test-mode
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'subject condition bound to'
}

@test "mail rules create sandboxed DRY-RUN reports unlabeled-name and self-scoping blockers" {
  APPLE_TEST_MODE=1 run "$BIN" mail rules create --dry-run --name "quarterly-report-rule" --condition "from:contains:boss@example.com" --action "mark_read=true" --test-mode
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'must start with'
  echo "$output" | grep -q 'subject condition bound to'
}

@test "mail rules create DRY-RUN reports no blockers for a properly labeled self-scoped rule" {
  # Sandboxed so the assertion is non-vacuous (the unsandboxed preview has no sandbox blockers
  # to report anyway). 'would refuse' is the JSON note substring; the earlier 'would be refused
  # live' only exists in --text mode, so that assertion could never fail (review-caught).
  APPLE_TEST_MODE=1 run "$BIN" mail rules create --dry-run --name "apple-cli-test-ok" --condition "subject:contains:apple-cli-test" --action "mark_read=true" --test-mode
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'would refuse'
  echo "$output" | grep -q '"live_blockers" : \['
}

# Oracle A rejects an empty condition value; an empty `contains` matches EVERY message. The
# header_name grammar only produces the empty value AFTER the header is split off.
@test "mail rules create refuses an empty condition value (exit 64)" {
  run "$BIN" mail rules create --dry-run --name "apple-cli-test-b" --condition "subject:contains:" --action "mark_read=true"
  [ "$status" -eq 64 ]
  run "$BIN" mail rules create --dry-run --name "apple-cli-test-b" --condition "header_name:contains::X-Foo" --action "mark_read=true"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q 'must not be empty'
}

# --- Oracle A bulk cap ------------------------------------------------------------------------
#
# Scope is the whole game here. Oracle A caps exactly two ops — `mark_as_read` (via
# `validate_bulk_operation`, server.py:995) and `delete_messages` (inline, server.py:1719) — and
# caps NOTHING else. Capping `move`/`flag` too would refuse input the oracle accepts, i.e. drop
# capability, which AGENTS.md calls a failure just as loudly as missing a gate. So this block pins
# BOTH directions: the two capped verbs refuse 101, and an uncapped verb ACCEPTS 101.
@test "mail bulk cap is wired to exactly the two ops oracle A caps (mark, delete)" {
  local src="$REPO_ROOT/Sources/MailKit/Commands/WriteManageCommands.swift"
  [ -f "$src" ]

  # Positive control: the symbol must exist, or every assertion below passes vacuously against a
  # renamed function.
  grep -q 'func enforceBulkCap' "$src"

  # Exactly two CALL sites. Anchored on the function name alone (not on an argument list that a
  # line-wrap would split across two lines, and not on the literal constant, so a hand-rolled
  # `enforceBulkCap(ids, verb: "move")` still trips this).
  local calls
  calls="$(grep -c 'try enforceBulkCap(' "$src")"
  [ "$calls" -eq 2 ]

  grep -q 'try enforceBulkCap(ids, verb: "mark")' "$src"
  grep -q 'try enforceBulkCap(ids, verb: "delete")' "$src"

  # NEGATIVE: no third verb may be capped.
  run bash -c "grep -o 'enforceBulkCap(ids, verb: \"[a-z]*\")' '$src' | sort -u | wc -l | tr -d ' '"
  [ "$output" -eq 2 ]

  # The cap must be enforced BEFORE the mail context is built, or it is unreachable on a machine
  # with no configured Mail account (EnvelopeIndex.init throws exit 69 first) — which is exactly
  # the CI runner. Assert the ordering per command rather than trusting a comment. The context is
  # built either directly (`try MailContext()`) or through the injected seam
  # (`try contextFactory()`); both spellings count, and the enclosing body is whichever `run(`
  # overload holds the cap (the public `run()` only forwards a lazy factory closure).
  run python3 - "$src" <<'PYEOF'
import sys, re
src = open(sys.argv[1]).read()
ok = True
builds = ("try MailContext()", "try contextFactory()")
for verb in ("mark", "delete"):
    cap = src.index('try enforceBulkCap(ids, verb: "%s")' % verb)
    # The enclosing overload is the last `func run(` before the cap; the command ends at the
    # next `struct` declaration, so every search below is bounded to THIS command's body.
    run_start = src.rindex("func run(", 0, cap)
    body_end = src.find("\nstruct ", cap)
    body_end = len(src) if body_end == -1 else body_end
    # the context build that belongs to this command is the first one after the cap check
    after = [i for i in (src.find(b, cap, body_end) for b in builds) if i != -1]
    if not after:
        print("FAIL: %s never builds a mail context after the cap check" % verb); ok = False
    # ...and there must be no context build between the start of the enclosing run(...) and the cap.
    if any(b in src[run_start:cap] for b in builds):
        print("FAIL: %s builds the mail context before the cap check" % verb); ok = False
    # ...and the zero-argument forwarder above the overload must be a PURE forward: its body is
    # exactly one `try run(` call, so nothing (not even an eager MailContext()) runs before the cap.
    fwd = src.rindex("func run() throws {", 0, run_start)
    fwd_body = src[fwd + len("func run() throws {"):run_start]
    stmts = [line.strip() for line in fwd_body.splitlines() if line.strip() and line.strip() != "}"]
    if not (len(stmts) == 1 and stmts[0].startswith("try run(")):
        print("FAIL: %s forwarder is not a pure `try run(` forward: %r" % (verb, stmts)); ok = False
print("OK" if ok else "BAD")
PYEOF
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^OK$'
}

# The cap bounds the INPUT id count and now runs before any Mail access, so it is assertable on a
# runner with no Mail account at all. (It previously sat one line AFTER `MailContext()`, which made
# this test pass locally and fail in CI — the reason the ordering is pinned above.)
@test "mail mark refuses 101 ids with the oracle's validate_bulk_operation wording" {
  local ids=()
  for i in $(seq 1 101); do ids+=("$i"); done
  run "$BIN" mail mark --dry-run --read "${ids[@]}"
  echo "$output" | grep -q 'Too many items (101), maximum is 100'
  [ "$status" -eq 64 ]
}

@test "mail delete refuses 101 ids with delete_messages' own wording" {
  local ids=()
  for i in $(seq 1 101); do ids+=("$i"); done
  run "$BIN" mail delete --dry-run "${ids[@]}"
  echo "$output" | grep -q 'Cannot delete 101 messages at once (max: 100)'
  [ "$status" -eq 64 ]
}

# POSITIVE control, not just "no cap message": 100 must get PAST the cap and fail later, at message
# resolution. Asserting only the absence of the cap string would pass if $BIN were unset, if the
# binary crashed, or if the cap were deleted outright.
@test "mail attachment metadata instance path uses the timed runner" {
  run /usr/bin/python3 -c '
from pathlib import Path
import re
import sys
src = Path(sys.argv[1]).read_text()
start = src.index("public func listAttachments(")
end = src.index("static func listAttachments(", start)
instance = src[start:end]
assert re.search(r"runner\.run\(\s*script,\s*arguments:\s*arguments,\s*timeout:\s*timeout\s*\)", instance)

read_src = Path(sys.argv[2]).read_text()
rows_start = read_src.index("private func attachmentRows(")
rows_end = read_src.index("func run()", rows_start)
assert "Self.liveAttachmentMetadataOrNil" in read_src[rows_start:rows_end]

write_src = Path(sys.argv[3]).read_text()
save_start = write_src.index("struct AttachmentsSave:")
save_run = write_src.index("func run()", save_start)
assert "try Self.requireLiveAttachmentMasterForExecute(" in write_src[save_run:]
' "$REPO_ROOT/Sources/MailKit/Support/MailScript.swift" \
  "$REPO_ROOT/Sources/MailKit/Commands/MessageReadCommands.swift" \
  "$REPO_ROOT/Sources/MailKit/Commands/WriteManageCommands.swift"
  [ "$status" -eq 0 ]
}

@test "mail rules update with no fields stays a validation_error (gap32 lock)" {
  run "$BIN" mail rules update --dry-run 0
  [ "$status" -eq 64 ]
  echo "$output" | grep -q 'nothing to update'
}

# gap26: forward_to entries are validated with oracle A's email regex at parse time.
@test "mail rules create rejects forward_to=notanemail at parse (gap26)" {
  run "$BIN" mail rules create --dry-run --name apple-cli-test-fwd \
    --condition subject:contains:apple-cli-test --action forward_to=notanemail
  [ "$status" -eq 64 ]
  echo "$output" | grep -q 'valid email addresses'
}

# extra25: malformed move_to fails the PREVIEW even when a sandbox blocker is also present
# (the shape check used to be skipped whenever blockers were non-empty).
@test "mail rules create preview validates move_to shape even alongside a blocker (extra25)" {
  APPLE_TEST_MODE=1 run "$BIN" mail rules create --dry-run --test-mode --name not-labeled \
    --condition subject:contains:whatever --action move_to=NoSlashHere
  [ "$status" -eq 64 ]
  echo "$output" | grep -q "move_to must be 'Account/Mailbox'"
}

# extra26: template errors carry oracle A's TYPED strings (exit codes unchanged).
@test "mail templates get on a missing name is template_not_found (extra26)" {
  run "$BIN" mail templates get no-such-template-xyz
  [ "$status" -eq 65 ]
  echo "$output" | grep -q '"type" : "template_not_found"'
}

@test "mail templates get on a malformed name is invalid_template_name (extra26)" {
  run "$BIN" mail templates get 'bad name!'
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "invalid_template_name"'
}

# extra27: --text is honored (was declared and silently ignored on all five subcommands).
@test "mail templates list --text prints text, not the JSON envelope (extra27)" {
  run "$BIN" mail templates list --text
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q '"schema_version"'
}

# gap37 E2E: a spec-bearing token renders through the Python-parity formatter; a missing
# spec-bearing variable raises missing_template_variable instead of leaking the token.
@test "mail templates render applies the format mini-language (gap37)" {
  GAP37_FIXTURE=apple-cli-test-gap37
  run "$BIN" mail templates save --execute apple-cli-test-gap37 --body 'W:{w:*>6}!'
  [ "$status" -eq 0 ]
  run "$BIN" mail templates render apple-cli-test-gap37 --var w=hi
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'W:\*\*\*\*hi!'
  run "$BIN" mail templates render apple-cli-test-gap37
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "missing_template_variable"'
  run "$BIN" mail templates delete --execute apple-cli-test-gap37
  [ "$status" -eq 0 ]
}

@test "mail templates render maps a bad format spec to oracle A's unknown class (gap37)" {
  GAP37_FIXTURE=apple-cli-test-gap37b
  run "$BIN" mail templates save --execute apple-cli-test-gap37b --body 'X:{w:d}'
  [ "$status" -eq 0 ]
  run "$BIN" mail templates render apple-cli-test-gap37b --var w=hi
  [ "$status" -eq 70 ]
  echo "$output" | grep -q "Unknown format code 'd' for object of type 'str'"
  run "$BIN" mail templates delete --execute apple-cli-test-gap37b
  [ "$status" -eq 0 ]
}

# --- Q11 batch-2 review-round pins ------------------------------------------------------------

# review H1: an empty/whitespace message id used to fall through resolveMessageRow's numeric
# parse into a store query that matched nothing helpful; it is a usage error, refused typed.
@test "mail templates get/save/render/delete honor --text with real content (review M3)" {
  GAP37_FIXTURE=apple-cli-test-gap37
  run "$BIN" mail templates save --execute --text apple-cli-test-gap37 --body 'Hello {name}'
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q '"schema_version"'
  echo "$output" | grep -q "saved template 'apple-cli-test-gap37'"
  run "$BIN" mail templates get --text apple-cli-test-gap37
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q '"schema_version"'
  echo "$output" | grep -q 'Hello {name}'
  run "$BIN" mail templates render --text apple-cli-test-gap37 --var name=Sam
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q '"schema_version"'
  echo "$output" | grep -q 'Hello Sam'
  run "$BIN" mail templates delete --execute --text apple-cli-test-gap37
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q '"schema_version"'
  echo "$output" | grep -q "deleted template 'apple-cli-test-gap37'"
}

# --- Q11 batch-3 analytics parity pins --------------------------------------------------------

# review H4 (measured): an unknown --mailbox returned a confident ok:true/zero, indistinguishable
# from an empty mailbox; the oracle raises "Mailbox not found" (smart_inbox.py:260-268, :485-493).
@test "mail search --body-live-timeout without --body-live is validation/64" {
  run "$BIN" mail search --body-live-timeout 30
  [ "$status" -eq 64 ]
  echo "$output" | python3 -c '
import json,sys
doc=json.load(sys.stdin)
assert doc["ok"] is False
assert doc["error"]["type"] == "validation_error"
assert "requires --body-live" in doc["error"]["message"]'
}

@test "mail search --body-live-timeout rejects malformed values as validation/64" {
  run "$BIN" mail search --body needle --body-live --body-live-timeout not-a-number
  [ "$status" -eq 64 ]
  echo "$output" | python3 -c '
import json,sys
doc=json.load(sys.stdin)
assert doc["ok"] is False
assert doc["error"]["type"] == "validation_error"
assert "must be 0 or a finite number" in doc["error"]["message"]'
}

# Negative-limit class: a negative --limit was clamped to LIMIT 0 at the query boundary and
# returned an EMPTY SUCCESS echoing the negative value — indistinguishable from an empty store
# (git-verified; the first draft misattributed it to SQL LIMIT -n). Typed 64 now.
@test "mail search/list reject a negative --limit; list rejects negative --limit-per-account" {
  run "$BIN" mail search --limit=-1
  [ "$status" -eq 64 ]
  run "$BIN" mail list --limit=-1
  [ "$status" -eq 64 ]
  run "$BIN" mail list --limit-per-account=-1
  [ "$status" -eq 64 ]
}

# gap9: oracle B's max_emails caps PER ACCOUNT; the merged result echoes the cap.
@test "mail reply --mailbox subject-scope defaults to INBOX (extra16)" {
  run "$BIN" mail reply --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '--mailbox'
  echo "$output" | grep -qi 'default INBOX'
  echo "$output" | grep -q -- '--mode'
}

# extra16 BEHAVIOR pin (review M5: the help-text grep alone would stay green if the lookup
# reverted to the old hardwired "All"): a subject that lives ONLY outside INBOX must be
# not_found under the default scope and resolve under --mailbox All.
@test "mail draft-rich --dry-run reports oracle missing_details (gap19)" {
  run "$BIN" mail draft-rich --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json,sys;d=json.load(sys.stdin)['data']
assert d['missing_details'] == ['subject', 'to', 'body'], d['missing_details']
assert d['dry_run'] is True"
}

# gap20: the default destination is DETERMINISTIC and subject-named — preview and execute
# name the SAME path (the old per-run temp UUID broke preview/execute identity).
@test "mail draft-rich default eml_path is deterministic and subject-named (gap20)" {
  a=$("$BIN" mail draft-rich --dry-run --subject "apple-cli-test det" --to me@self.test --html "<b>x</b>" | python3 -c "
import json,sys;print(json.load(sys.stdin)['data']['eml_path'])")
  b=$("$BIN" mail draft-rich --dry-run --subject "apple-cli-test det" --to me@self.test --html "<b>x</b>" | python3 -c "
import json,sys;print(json.load(sys.stdin)['data']['eml_path'])")
  [ "$a" = "$b" ]
  echo "$a" | grep -q 'rich-drafts'
  echo "$a" | grep -q 'apple-cli-test-det.eml'
}

# --no-clobber refuses an existing destination (the deterministic default overwrites, and
# DIFFERENT subjects can sanitize to the SAME filename — review-added guard). --no-open on both
# calls keeps this headless (open_in_mail now defaults to true, oracle B parity); the first call
# below would otherwise launch a live Mail.app compose window before the second call even runs.
@test "mail draft-rich --no-clobber refuses an existing destination (exit 77)" {
  OUT="$BATS_TEST_TMPDIR/apple-cli-test-clobber.eml"
  run "$BIN" mail draft-rich --execute --to me@self.test --subject "apple-cli-test clobber" --html "<b>x</b>" --out "$OUT" --no-open
  [ "$status" -eq 0 ]
  run "$BIN" mail draft-rich --execute --to me@self.test --subject "apple-cli-test clobber" --html "<b>x</b>" --out "$OUT" --no-clobber --no-open
  [ "$status" -eq 77 ]
  echo "$output" | grep -q 'no-clobber'
}

# Q12 [17] (review): the Mail READ --text renderers (printMessageText / templates get / rules /
# accounts) print store-derived strings. An ESC in a stored template body must be neutralized to
# caret notation, never reach the terminal raw. Uses the file-based template store (CI-safe).
@test "mail templates get --text neutralizes terminal control sequences (Q12 [17])" {
  export APPLE_MAIL_MCP_HOME="$BATS_TEST_TMPDIR/text-neutralize"
  body=$(printf 'line1\033[31mRED\033[0m line2')
  run "$BIN" mail templates save apple-cli-test-esc --body "$body" --execute
  [ "$status" -eq 0 ]
  run "$BIN" mail templates get apple-cli-test-esc --text
  [ "$status" -eq 0 ]
  # the ESC (0x1B) must be gone; the caret form present
  ! printf '%s' "$output" | grep -q "$(printf '\033')"
  echo "$output" | grep -q '\^\[\[31mRED'
}

# Q12 [10]/[17] (critic finding #1+#2): the Mail WRITE surface honors --text AND neutralizes.
# (a) mail send --dry-run echoes the operator subject through the neutralizer; (b) mail trash
# empty --text -- the exact dry-run preview branch finding #1 caught silently emitting JSON --
# now renders human text (revert-red for the WriteManageCommands fix).
@test "mail send --dry-run --text neutralizes ANSI in echoed subject (Q12 [10]/[17])" {
  subj=$(printf 'apple-cli-test \033[31mRED\033[0m')
  run "$BIN" mail send --to "apple-cli-test@example.com" --subject "$subj" --body b --dry-run --text
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '\^\[\[31mRED'
  ! printf '%s' "$output" | grep -q "$(printf '\033')"
}
