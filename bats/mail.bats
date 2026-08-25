#!/usr/bin/env bats
# Mail CLI smoke tests. Help/usage/error-envelope checks run anywhere; live reads
# (Envelope Index + Mail automation) are guarded and skip when unavailable (CI).

setup() {
  BIN="$(swift build --show-bin-path)/apple"
}

teardown() {
  # Template-fixture hygiene (review I1): a mid-test failure must not strand a fixture in the
  # template store. Only tests that set GAP37_FIXTURE pay the cleanup invocation; the delete
  # is idempotent and best-effort (the happy path already deleted it as an assertion).
  if [ -n "${GAP37_FIXTURE:-}" ]; then
    "$BIN" mail templates delete --execute "$GAP37_FIXTURE" >/dev/null 2>&1 || true
  fi
}

# Skip a test when the Mail Envelope Index isn't readable (no Full Disk Access / no Mail).
require_index() {
  local found=""
  for d in "$HOME"/Library/Mail/V*/MailData/"Envelope Index"; do
    [ -r "$d" ] && found=1
  done
  [ -n "$found" ] || skip "Mail Envelope Index not readable (no FDA / no Mail)"
}

# Probe the Apple Events client used by the fixture itself. This must not route through the CLI
# under test: a CLI regression may fail, but it must never green-skip its own live wiring pin.
require_osascript_mail_automation() {
  case "$-" in *x*) set +x ;; esac
  local timeout_policy="${1:-skip}"
  local probe_status probe_output
  run /usr/bin/python3 "$BATS_TEST_DIRNAME/helpers/bounded_exec.py" \
    --timeout 30 --grace 2 -- /usr/bin/osascript \
    -e 'tell application "Mail" to count of accounts'
  probe_status="$status"
  probe_output="$output"
  output=""
  lines=()
  BATS_RUN_COMMAND=""
  case "$probe_status" in
    0) unset probe_output ;;
    124)
      unset probe_output
      if [ "$timeout_policy" = strict ]; then
        printf '%s\n' "Mail automation remained unresponsive after the CLI host timeout" >&2
        return 1
      fi
      skip "Mail automation authorization probe timed out"
      ;;
    *)
      case "$probe_output" in
        *-1743*|*"Not authorized to send Apple events"*)
          unset probe_output
          skip "Mail automation is not authorized for the test runner"
          ;;
        *)
          unset probe_output
          printf '%s\n' "Mail automation authorization probe failed unexpectedly" >&2
          false
          ;;
      esac
      ;;
  esac
}

# Select the oldest indexed INBOX attachment as a private hint, then make Mail.app independently
# confirm that exact RFC Message-ID and report its live count. The product may nominate a fixture;
# only the oracle validates it. No broad live mailbox scan, no age-out window, and no cached PII.
select_live_attachment_fixture() {
  case "$-" in *x*) set +x ;; esac
  local hint_status hint_output hint_parse_status=0 hint_tuple hint_account hint_id
  local fixture_status fixture_output fixture_rest
  local fixture_script='on run argv
set targetID to item 1 of argv
set accountSelector to item 2 of argv
set RS to character id 30
tell application "Mail"
  set searchAccounts to accounts whose name is accountSelector
  if (count of searchAccounts) is 0 then set searchAccounts to accounts whose id is accountSelector
  repeat with a in searchAccounts
    try
      set hits to messages of mailbox "INBOX" of a whose message id is targetID
      if (count of hits) > 0 then
        set m to item 1 of hits
        set attachmentCount to count of mail attachments of m
        if attachmentCount > 0 then
          return ((id of a) as string) & RS & ((message id of m) as string) & RS & (attachmentCount as string)
        end if
      end if
    end try
  end repeat
end tell
return ""
end run'

  require_osascript_mail_automation
  run /usr/bin/python3 "$BATS_TEST_DIRNAME/helpers/bounded_exec.py" \
    --timeout 30 --grace 2 -- "$BIN" mail search --mailbox INBOX \
    --has-attachment --sort date_asc --limit 1 --no-content
  hint_status="$status"
  hint_output="$output"
  output=""
  lines=()
  BATS_RUN_COMMAND=""
  if [ "$hint_status" -ne 0 ]; then
    unset hint_output
    printf '%s\n' "attachment fixture index hint failed" >&2
    false
  fi
  hint_tuple=$(printf '%s' "$hint_output" | /usr/bin/python3 -c '
import json,sys
messages=json.load(sys.stdin)["data"]["messages"]
if not messages:
    raise SystemExit(12)
message=messages[0]
account=message.get("account") or ""
internet_id=message.get("internet_message_id") or ""
if not account or not internet_id:
    raise SystemExit(13)
sys.stdout.write(account + "\x1e" + internet_id)
' 2>/dev/null) || hint_parse_status=$?
  unset hint_output
  case "$hint_parse_status" in
    0) ;;
    12) unset hint_tuple; skip "store has no indexed INBOX attachment fixture" ;;
    *) unset hint_tuple; printf '%s\n' "attachment fixture index hint was invalid" >&2; false ;;
  esac
  case "$hint_tuple" in
    *$'\n'*|*$'\r'*)
      unset hint_tuple
      printf '%s\n' "attachment fixture index hint contained an invalid identifier" >&2
      false
      ;;
    *$'\036'*) ;;
    *)
      unset hint_tuple
      printf '%s\n' "attachment fixture index hint omitted its account" >&2
      false
      ;;
  esac
  hint_account="${hint_tuple%%$'\036'*}"
  hint_id="${hint_tuple#*$'\036'}"
  unset hint_tuple
  case "$hint_id" in
    ""|*$'\036'*)
      unset hint_account hint_id
      printf '%s\n' "attachment fixture index hint contained an invalid message identifier" >&2
      false
      ;;
  esac

  run /usr/bin/python3 "$BATS_TEST_DIRNAME/helpers/bounded_exec.py" \
    --timeout 60 --grace 2 -- /usr/bin/osascript -e "$fixture_script" -- "$hint_id" "$hint_account"
  fixture_status="$status"
  fixture_output="$output"
  output=""
  lines=()
  BATS_RUN_COMMAND=""
  unset hint_account hint_id
  case "$fixture_status" in
    0) ;;
    124) unset fixture_output; skip "Mail.app fixture confirmation exceeded its bound" ;;
    *) unset fixture_output; printf '%s\n' "Mail.app fixture confirmation failed" >&2; false ;;
  esac
  [ -n "$fixture_output" ] || skip "indexed attachment fixture is not live-locatable in Mail.app"
  case "$fixture_output" in
    *$'\n'*|*$'\r'*)
      unset fixture_output
      printf '%s\n' "live attachment fixture returned an invalid identifier tuple" >&2
      false
      ;;
    *$'\036'*) ;;
    *)
      unset fixture_output
      printf '%s\n' "live attachment fixture omitted its account scope" >&2
      false
      ;;
  esac
  LIVE_ATTACHMENT_ACCOUNT_ID="${fixture_output%%$'\036'*}"
  fixture_rest="${fixture_output#*$'\036'}"
  case "$fixture_rest" in
    *$'\036'*) ;;
    *)
      unset fixture_output fixture_rest LIVE_ATTACHMENT_ACCOUNT_ID
      printf '%s\n' "live attachment fixture omitted its attachment count" >&2
      false
      ;;
  esac
  LIVE_ATTACHMENT_ID="${fixture_rest%%$'\036'*}"
  LIVE_ATTACHMENT_ORACLE_COUNT="${fixture_rest#*$'\036'}"
  case "$LIVE_ATTACHMENT_ORACLE_COUNT" in
    ""|*[!0-9]*|*$'\036'*)
      unset fixture_output fixture_rest LIVE_ATTACHMENT_ACCOUNT_ID \
        LIVE_ATTACHMENT_ID LIVE_ATTACHMENT_ORACLE_COUNT
      printf '%s\n' "live attachment fixture returned an invalid attachment count" >&2
      false
      ;;
  esac
  unset fixture_output fixture_rest
  if [ -z "$LIVE_ATTACHMENT_ACCOUNT_ID" ] || [ -z "$LIVE_ATTACHMENT_ID" ]; then
    unset LIVE_ATTACHMENT_ACCOUNT_ID LIVE_ATTACHMENT_ID LIVE_ATTACHMENT_ORACLE_COUNT
    printf '%s\n' "live attachment fixture returned an empty account or message identifier" >&2
    false
  fi
}

# Capture the CLI's live list response for the selected fixture. This is separate from fixture
# selection so the oracle setup does not decide whether the product response is acceptable.
load_live_attachment_list() {
  case "$-" in *x*) set +x ;; esac
  local live_status
  if [ -z "${LIVE_ATTACHMENT_ACCOUNT_ID:-}" ] || [ -z "${LIVE_ATTACHMENT_ID:-}" ] \
    || [ -z "${LIVE_ATTACHMENT_ORACLE_COUNT:-}" ]; then
    unset LIVE_ATTACHMENT_ACCOUNT_ID LIVE_ATTACHMENT_ID LIVE_ATTACHMENT_ORACLE_COUNT
    printf '%s\n' "live attachment fixture must be selected before it is loaded" >&2
    false
  fi
  # 90 seconds sits outside the 2x30-second per-spelling maximum, leaving 30 seconds
  # for process startup, index reads, JSON encoding, and bounded cleanup.
  run /usr/bin/python3 "$BATS_TEST_DIRNAME/helpers/bounded_exec.py" \
    --timeout 90 --grace 2 -- "$BIN" mail attachments list \
    --account "$LIVE_ATTACHMENT_ACCOUNT_ID" -- "$LIVE_ATTACHMENT_ID"
  live_status="$status"
  LIVE_ATTACHMENT_LIST_JSON="$output"
  output=""
  lines=()
  BATS_RUN_COMMAND=""
  if [ "$live_status" -eq 124 ]; then
    unset LIVE_ATTACHMENT_LIST_JSON
    unset LIVE_ATTACHMENT_ACCOUNT_ID LIVE_ATTACHMENT_ID LIVE_ATTACHMENT_ORACLE_COUNT
    require_osascript_mail_automation strict
    printf '%s\n' "in-CLI attachment list deadline did not fire before its host backstop" >&2
    false
  fi
  if [ "$live_status" -eq 69 ] || [ "$live_status" -eq 77 ]; then
    unset LIVE_ATTACHMENT_ACCOUNT_ID LIVE_ATTACHMENT_ID LIVE_ATTACHMENT_ORACLE_COUNT \
      LIVE_ATTACHMENT_LIST_JSON
    require_osascript_mail_automation strict
    printf '%s\n' "apple CLI reported Mail automation unavailable while the oracle was healthy" >&2
    false
  fi
  if [ "$live_status" -ne 0 ]; then
    unset LIVE_ATTACHMENT_ACCOUNT_ID LIVE_ATTACHMENT_ID LIVE_ATTACHMENT_ORACLE_COUNT \
      LIVE_ATTACHMENT_LIST_JSON
    printf '%s\n' "live attachment list command failed" >&2
    false
  fi
}

# Require product enrichment independently from selecting/loading the live fixture. Parse JSON
# rather than depending on pretty-printer whitespace, and emit only fixed diagnostics.
assert_live_attachment_enriched() {
  case "$-" in *x*) set +x ;; esac
  local assertion_status=0
  printf '%s' "$LIVE_ATTACHMENT_LIST_JSON" | /usr/bin/python3 -c '
import json, sys

try:
    envelope = json.load(sys.stdin)
except (TypeError, ValueError):
    raise SystemExit(20)
if envelope.get("ok") is not True or envelope.get("tool") != "mail" or "schema_version" not in envelope:
    raise SystemExit(23)
try:
    data = envelope["data"]
    attachments = data["attachments"]
except (KeyError, TypeError):
    raise SystemExit(21)
if not isinstance(attachments, list) or any(not isinstance(a, dict) for a in attachments):
    raise SystemExit(22)
if not attachments:
    raise SystemExit(12)
if any("size" not in attachment for attachment in attachments):
    raise SystemExit(10)
# MessageReadCommands emits the degraded disclosure as Result.note -> data.note. Keep this
# assertion exact so a future unrelated nested note field does not become a false regression.
if "note" in data:
    raise SystemExit(11)
if len(attachments) != int(sys.argv[1]):
    raise SystemExit(13)
' "$LIVE_ATTACHMENT_ORACLE_COUNT" 2>/dev/null || assertion_status=$?
  case "$assertion_status" in
    0) ;;
    10)
      unset LIVE_ATTACHMENT_ACCOUNT_ID LIVE_ATTACHMENT_ID LIVE_ATTACHMENT_ORACLE_COUNT \
        LIVE_ATTACHMENT_LIST_JSON
      printf '%s\n' "live attachment metadata size is missing from a successful response" >&2
      false
      ;;
    11)
      unset LIVE_ATTACHMENT_ACCOUNT_ID LIVE_ATTACHMENT_ID LIVE_ATTACHMENT_ORACLE_COUNT \
        LIVE_ATTACHMENT_LIST_JSON
      printf '%s\n' "live attachment lookup returned the degraded fallback note" >&2
      false
      ;;
    12)
      unset LIVE_ATTACHMENT_ACCOUNT_ID LIVE_ATTACHMENT_ID LIVE_ATTACHMENT_ORACLE_COUNT \
        LIVE_ATTACHMENT_LIST_JSON
      printf '%s\n' "live attachment fixture resolved with no attachment rows" >&2
      false
      ;;
    13)
      unset LIVE_ATTACHMENT_ACCOUNT_ID LIVE_ATTACHMENT_ID LIVE_ATTACHMENT_ORACLE_COUNT \
        LIVE_ATTACHMENT_LIST_JSON
      printf '%s\n' "live attachment row count disagreed with the Mail.app oracle" >&2
      false
      ;;
    20)
      unset LIVE_ATTACHMENT_ACCOUNT_ID LIVE_ATTACHMENT_ID LIVE_ATTACHMENT_ORACLE_COUNT \
        LIVE_ATTACHMENT_LIST_JSON
      printf '%s\n' "live attachment response was not valid JSON" >&2
      false
      ;;
    21)
      unset LIVE_ATTACHMENT_ACCOUNT_ID LIVE_ATTACHMENT_ID LIVE_ATTACHMENT_ORACLE_COUNT \
        LIVE_ATTACHMENT_LIST_JSON
      printf '%s\n' "live attachment response omitted its data or attachments field" >&2
      false
      ;;
    22)
      unset LIVE_ATTACHMENT_ACCOUNT_ID LIVE_ATTACHMENT_ID LIVE_ATTACHMENT_ORACLE_COUNT \
        LIVE_ATTACHMENT_LIST_JSON
      printf '%s\n' "live attachment response used an invalid attachments shape" >&2
      false
      ;;
    23)
      unset LIVE_ATTACHMENT_ACCOUNT_ID LIVE_ATTACHMENT_ID LIVE_ATTACHMENT_ORACLE_COUNT \
        LIVE_ATTACHMENT_LIST_JSON
      printf '%s\n' "live attachment response violated the JSON envelope contract" >&2
      false
      ;;
    *)
      unset LIVE_ATTACHMENT_ACCOUNT_ID LIVE_ATTACHMENT_ID LIVE_ATTACHMENT_ORACLE_COUNT \
        LIVE_ATTACHMENT_LIST_JSON
      printf '%s\n' "live attachment assertion failed unexpectedly" >&2
      false
      ;;
  esac
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

@test "mail previews refuse exactly what execute would (sandboxed non-self send, unlabeled draft, empty subjects)" {
  # Preview honesty (v2): these gates are mode-keyed, not execute-keyed — all pre-Mail.
  # (require_index only for the --match-sender case below, which resolves via the index.)
  require_index
  APPLE_TEST_MODE=1 APPLE_TEST_RECIPIENTS="me@self.test" \
    run "$BIN" mail send --dry-run --to someone-else@example.com --subject "apple-cli-test x" --body y --mode send
  [ "$status" -eq 77 ]
  APPLE_TEST_MODE=1 run "$BIN" mail send --dry-run --to me@self.test --subject "Quarterly report" --body y --mode draft --test-mode
  [ "$status" -eq 77 ]
  APPLE_TEST_MODE=1 run "$BIN" mail draft delete --dry-run --subject "Quarterly report" --test-mode
  [ "$status" -eq 77 ]
  run "$BIN" mail draft send --dry-run --draft-subject ""
  [ "$status" -eq 64 ]
  run "$BIN" mail reply --dry-run --subject "" --body x
  [ "$status" -eq 64 ]
  run "$BIN" mail forward --dry-run --subject "   " --to me@self.test
  [ "$status" -eq 64 ]
  run "$BIN" mail attachments save --dry-run --subject "" --dir "$BATS_TEST_TMPDIR"
  [ "$status" -eq 64 ]
  # Round-4 additions: the same principle on the surfaces the first hoist missed.
  APPLE_TEST_MODE=1 run "$BIN" mail mailboxes create --dry-run --account iCloud --name "Quarterly Reports" --test-mode
  [ "$status" -eq 77 ]
  # gap17 landed: --mode draft/open are now real delivery modes; the hoisted validation
  # guard still refuses an UNKNOWN mode in preview exactly as --execute would.
  run "$BIN" mail reply 1 --body x --mode bogus --dry-run
  [ "$status" -eq 64 ]
  echo "$output" | grep -q 'mode'
  run "$BIN" mail mark --dry-run --match-sender "" --read --account iCloud
  [ "$status" -eq 64 ]
  echo "$output" | grep -q 'match-sender'
  # The subject twin (round 5): a blank keyword alongside another active filter used to
  # contribute NO predicate — the mutation silently widened to the other filter's whole set.
  run "$BIN" mail flag --dry-run --match-subject "" --only-read --account iCloud
  [ "$status" -eq 64 ]
  echo "$output" | grep -q 'match-subject'
  run "$BIN" mail move --dry-run --match-subject "   " --only-read --to Archive --account iCloud
  [ "$status" -eq 64 ]
  # Blank --account widenings (round 5): "" must never silently mean "every account".
  run "$BIN" mail draft delete --dry-run --subject "apple-cli-test x" --account ""
  [ "$status" -eq 64 ]
  echo "$output" | grep -q 'account'
  run "$BIN" mail trash empty --dry-run --account ""
  [ "$status" -eq 64 ]
  run env -u APPLE_ALLOW_PERMANENT_DELETE "$BIN" mail delete 1 --permanent --dry-run --account " "
  [ "$status" -eq 64 ]
  # Sandboxed bulk preview refuses an unlabeled target exactly as execute would (round 5).
  APPLE_TEST_MODE=1 run "$BIN" mail flag --dry-run 12345 --color red --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q 'sandbox active'
  # templates save: the preview runs the same pure validations the write does (round 7).
  export APPLE_MAIL_MCP_HOME="$BATS_TEST_TMPDIR/preview-validate"
  run "$BIN" mail templates save --dry-run "../evil" --body x
  [ "$status" -eq 64 ]
  run "$BIN" mail templates save --dry-run goodname --body "   "
  [ "$status" -eq 64 ]
  # reply --attach: path validation (existence/type/size/sensitive-dir) fires in preview AND
  # before the store opens. Assert the MESSAGE, not just the code — a nonexistent --subject
  # target is also 65, which made an earlier version of this line pass vacuously.
  run "$BIN" mail reply --dry-run --subject "apple-cli-test x" --body y --attach /tmp/apple-cli-test-definitely-missing-zzz
  [ "$status" -eq 65 ]
  echo "$output" | grep -q 'attachment not found'
  # A REGULAR FILE under a blocklisted credential dir → 77. Must not use the directory itself
  # (~/.ssh): the existence/is-regular-file check fires first and returns 65, which would prove
  # nothing about the sensitive-dir blocklist — under v2 that blocklist is the sole containment
  # for unsandboxed attachment content.
  sens=""
  for c in "$HOME/.claude/settings.json" "$HOME/.ssh/config" "$HOME/.gnupg/gpg.conf" "$HOME/.aws/config"; do
    [ -f "$c" ] && { sens="$c"; break; }
  done
  if [ -n "$sens" ]; then
    run "$BIN" mail reply --dry-run --subject "apple-cli-test x" --body y --attach "$sens"
    [ "$status" -eq 77 ]
    echo "$output" | grep -q 'sensitive directory'
  fi
  # Control characters never reach the US-delimited AppleScript argv (round 6/7).
  run "$BIN" mail send --dry-run --to "$(printf 'a@x.test\037evil@y.test')" --subject "apple-cli-test x" --body y
  [ "$status" -eq 64 ]
  echo "$output" | grep -q 'control character'
  run "$BIN" mail send --dry-run --to me@self.test --subject "apple-cli-test x" --body y --attach "$(printf '/tmp/a\037/etc/passwd')"
  [ "$status" -eq 77 ]
  run "$BIN" mail export --dry-run --account iCloud --scope single_email --subject "   " --dir "$BATS_TEST_TMPDIR"
  [ "$status" -eq 64 ]
  run "$BIN" mail send --dry-run --to me@self.test --subject "apple-cli-test x" --body y --mode open --out "$HOME/.ssh/apple-cli-test-x.eml"
  [ "$status" -eq 77 ]
}

@test "mail: sandbox:true is carried by rules-preview and trash-empty envelopes too (no forgotten emit site)" {
  # Output.emit's sandboxActive parameter is DEFAULTED, so a forgotten call site silently
  # under-reports as unsandboxed — review round 1 caught exactly that on these two surfaces.
  APPLE_TEST_MODE=1 run "$BIN" mail rules create --dry-run --name "apple-cli-test-x" --condition "subject:contains:apple-cli-test" --action "mark_read=true" --test-mode
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"sandbox" : true'
  # The sandboxed preview also predicts the force-disable execute performs (preview honesty).
  echo "$output" | grep -q '"enabled" : false'
  APPLE_TEST_MODE=1 run "$BIN" mail trash empty --dry-run --account "Any" --test-mode
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

@test "mail analytics dashboard --dry-run writes nothing; a credential-dir --out refuses even in preview (77)" {
  require_index
  OUT="$BATS_TEST_TMPDIR/apple-cli-test-dash.html"
  run "$BIN" mail analytics dashboard --dry-run --out "$OUT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  [ ! -f "$OUT" ]
  run "$BIN" mail analytics dashboard --dry-run --out "$HOME/.ssh/apple-cli-test-dash.html"
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"safety_violation"'
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

@test "v2 default: the flagless trash surface stays a dry-run preview (trash empty)" {
  run "$BIN" mail trash empty --account "Any"  # flagless-on-purpose
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"executed" : false'
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

@test "mail move with a filter previews (dry-run, filter_based)" {
  require_index
  run "$BIN" mail move --dry-run --match-subject apple-cli-nonexistent-zzz --to Archive --account iCloud
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
  run "$BIN" mail move --dry-run --match-subject apple-cli-nope-a --match-subject apple-cli-nope-b --to Archive --account iCloud
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"filter_based" : true'
}

@test "mail mark --all (apply_to_all) is accepted and previews without ids/filter (dry-run, exit 0)" {
  require_index
  run "$BIN" mail mark --dry-run --all --read --mailbox INBOX --account iCloud --max 3
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
@test "mail export --dry-run writes nothing and reports the cap" {
  require_index
  target="$HOME/apple-cli-test-export-drynothing"
  rm -rf "$target"
  run "$BIN" mail export --dry-run --account iCloud --scope entire_mailbox --mailbox INBOX --dir "$target" --max 2
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" *: *true'
  echo "$output" | grep -q '"exported" *: *0'
  # Oracle B reports the mailbox total alongside the exported count (analytics.py:627-628).
  echo "$output" | grep -q '"total_in_mailbox"'
  echo "$output" | grep -q '"capped"'
  [ ! -d "$target" ]
}

@test "mail export refuses a sensitive directory and one outside \$HOME (exit 77)" {
  require_index
  run "$BIN" mail export --dry-run --account iCloud --scope entire_mailbox --dir "$HOME/.ssh/mail" --max 1
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"safety_violation"'
  run "$BIN" mail export --dry-run --account iCloud --scope entire_mailbox --dir /private/etc/apple-cli --max 1
  [ "$status" -eq 77 ]
  [ ! -d /private/etc/apple-cli ]
}

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

# ── Sandbox write-safety gates (write-model v2) ────────────────────────────────
# These fire BEFORE any Mail/Envelope-Index access, so they run anywhere (no FDA /
# no Mail needed). v2: the sandbox is an opt-in RESTRICTION — APPLE_TEST_MODE truthy
# OR --test-mode, EITHER signal alone engages it — and inside it every recipient must
# be on the self-only APPLE_TEST_RECIPIENTS allowlist (empty allowlist = fail-closed).

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
    run "$BIN" mail rules create --name "real-inbox-rule" --condition "from:contains:boss@x.io" --action "mark_read=true" --execute --test-mode
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
    run "$BIN" mail rules create --name "apple-cli-test-b" --condition "subject:contains:apple-cli-test" --action "forward_to=a@x.io" --execute --test-mode
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
  run "$BIN" mail rules create --dry-run --name "apple-cli-test-b" --condition "subject:contains:apple-cli-test" --action "forward_to=a@x.io"
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
  APPLE_TEST_MODE=1 run "$BIN" mail rules create --name "apple-cli-test-b" --condition "subject:contains:apple-cli-test" --action "forward_to=a@x.io" --execute --test-mode
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

@test "mail delete --permanent dry-run previews and warns it only erases already-trashed mail" {
  require_index
  run "$BIN" mail delete --dry-run 1 --permanent
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
  run "$BIN" mail trash empty --dry-run --account "Any"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"action" : "empty_trash"'
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"executed" : false'
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
    run "$BIN" mail draft-rich --dry-run --to me@self.test --subject "apple-cli-test dr" --html "<b>x</b>" \
      --account "apple-cli-test-nonexistent-acct" --open --out "$OUT" --test-mode
  [ "$status" -eq 65 ]
  echo "$output" | grep -q '"type" : "not_found"'
  [ ! -f "$OUT" ]
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
@test "mail flag --color none previews as unflag (oracle flag_color=none parity)" {
  require_index
  run "$BIN" mail flag --dry-run 12345 --color none
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"action" *: *"unflag"'
}

# `flag_color` is oracle A's wire name for the color; `color` is this CLI's original key. Both
# are emitted (additive), so an oracle-shaped consumer finds the key it expects.
@test "mail flag emits both color and flag_color in detail" {
  require_index
  run "$BIN" mail flag --dry-run 12345 --color red
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"flag_color" *: *"red"'
  echo "$output" | grep -q '"color" *: *"red"'
  echo "$output" | grep -q '"action" *: *"flag"'
}

# `--unflag` keeps working unchanged (it is the same clearing path as --color none).
@test "mail flag --unflag still previews as unflag" {
  require_index
  run "$BIN" mail flag --dry-run 12345 --unflag
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"action" *: *"unflag"'
}

# --- Oracle-parity: templates render error surface -----------------------------
# Oracle A's `_substitute` raises MailTemplateMissingVariableError naming every unresolved
# placeholder (sorted); the CLI used to leave `{token}` literal, so an un-substituted
# `{recipient_name}` could flow straight into outbound subject/body text.
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
@test "mail templates render with an unresolvable --message-id is message_not_found (exit 65)" {
  require_index
  export APPLE_MAIL_MCP_HOME="$BATS_TEST_TMPDIR/tpl-mnf"
  run "$BIN" mail templates save --execute apple-cli-test-mnf --body 'Body {today}.'
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
  run "$BIN" mail mailboxes create --dry-run --account iCloud --name ""
  [ "$status" -eq 64 ]
  echo "$output" | grep -q 'cannot be empty'
}

@test "mail mailboxes create rejects a name with an AppleScript-hostile character (exit 64)" {
  require_index
  run "$BIN" mail mailboxes create --dry-run --account iCloud --name 'bad:name'
  [ "$status" -eq 64 ]
}

# '/' is the documented nesting separator, so it must stay legal in --name.
@test "mail mailboxes create still accepts a nested '/' path" {
  require_index
  run "$BIN" mail mailboxes create --dry-run --account iCloud --name 'Projects/2024'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"path" *: *"Projects/2024"'
}

# Oracle B NORMALIZES the path (manage.py create_mailbox: trim each segment, DROP empties) —
# the CLI used to reject 'A//B' (validation_error) and pass ' A / B ' through RAW, creating
# literal whitespace-named folders the oracle never would (extra8).
@test "mail mailboxes create drops empty path segments like oracle B (extra8)" {
  require_index
  run "$BIN" mail mailboxes create --dry-run --account iCloud --name 'Projects//2024'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"path" *: *"Projects/2024"'
}

@test "mail mailboxes create trims segment whitespace like oracle B (extra8)" {
  require_index
  run "$BIN" mail mailboxes create --dry-run --account iCloud --name ' Projects / 2024 '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"path" *: *"Projects/2024"'
}

@test "mail mailboxes create normalizes --parent too and joins it into path (extra8)" {
  require_index
  run "$BIN" mail mailboxes create --dry-run --account iCloud --name '2024' --parent ' Projects /'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"path" *: *"Projects/2024"'
}

@test "mail mailboxes create with a name that normalizes to nothing is empty-name (exit 64)" {
  require_index
  run "$BIN" mail mailboxes create --dry-run --account iCloud --name ' / / '
  [ "$status" -eq 64 ]
}

@test "sandboxed mailboxes create gates on the normalized FIRST segment, not the raw name (extra8)" {
  require_index
  APPLE_TEST_MODE=1 run "$BIN" mail mailboxes create --dry-run --test-mode --account iCloud \
    --name 'apple-cli-test-sub' --parent 'Projects'
  [ "$status" -eq 77 ]
  echo "$output" | grep -q 'first segment'
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
  # Sentinels proving the helper really ran over the compose + mutation script sets. The plain
  # nativeReplyScript was DELETED by decision-5 (2026-08-19) — plain replies route through
  # nativeReplyHtmlScript now — so that is the reply-side sentinel.
  echo "$output" | grep -q "ok - nativeReplyHtmlScript"
  echo "$output" | grep -q "ok - emptyTrashScript"
  # The RULE scripts are the least exercisable of the lot: `delete` went live-wired on 2026-08-19
  # (gap25), so a syntax slip in either of these now surfaces as a botched LIVE rule mutation —
  # and no agent may live-verify a delete rule (docs/port-specs/mail.md op 27), which makes
  # osacompile the only automated coverage they will ever get. Pin both by name so a helper change
  # that stops assembling them cannot pass silently.
  echo "$output" | grep -q "ok - createRuleScript"
  echo "$output" | grep -q "ok - updateRuleMetaScript"
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
  run "$BIN" mail mailboxes create --dry-run --account iCloud --name apple-cli-test-box --parent Projects
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

# The three scopes scan DIFFERENTLY (oracle tools/analytics.py) and the shipped code had a single
# inverted ternary that got all three wrong at once. Logic-tier coverage is in AnalyticsScopeTests;
# these pin the same rules end-to-end, through the real Envelope Index, where a wiring mistake
# between the command and Analytics.scopePlan would still show up.
@test "mail analytics stats: mailbox_breakdown honors --mailbox (oracle scopes to one mailbox)" {
  require_index
  # Two DIFFERENT named mailboxes. Under the fix each reports only its own; under the bug both
  # resolved to "All" and returned identical payloads.
  #
  # An earlier version of this test asserted only that a single INBOX run contained no non-INBOX
  # paths — and passed against the BUG, because on this account the all-mailbox scan happened to
  # return just INBOX once the 30-day window and skip-filter were applied. Shape of the operator's
  # mail must not decide whether a parity test can fail.
  local a b
  a=$("$BIN" mail analytics stats --account iCloud --scope mailbox_breakdown --mailbox INBOX)
  b=$("$BIN" mail analytics stats --account iCloud --scope mailbox_breakdown --mailbox Archive)

  local pa pb
  pa=$(echo "$a" | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; mb=d.get("mailbox_breakdown") or []; print(",".join(sorted(e["path"] for e in mb)))')
  pb=$(echo "$b" | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; mb=d.get("mailbox_breakdown") or []; print(",".join(sorted(e["path"] for e in mb)))')

  # POSITIVE CONTROL ON BOTH SIDES. `pa != pb` is satisfied by an empty pb, so on a machine with
  # no Archive mailbox this test would pass without ever exercising the scoping — the same
  # account-shape vacuity that made its first version pass against the bug. Skip loudly instead.
  [ -n "$pa" ]
  echo "$pa" | grep -qi 'inbox'
  [ -n "$pb" ] || skip "no Archive mailbox on this account — discriminator needs two real mailboxes"

  # THE DISCRIMINATOR: scoping to different mailboxes must produce different answers.
  [ "$pa" != "$pb" ]

  # And neither may leak the other's mailbox.
  ! echo "$pa" | grep -q 'Archive'
}

@test "mail analytics stats: mailbox_breakdown reports days_back 0 (oracle applies no date filter)" {
  require_index
  # --days 30 is requested; the oracle counts `every message of targetMailbox` with no whose
  # clause, so the response must report what was ACTUALLY applied rather than echoing the request.
  run "$BIN" mail analytics stats --account iCloud --scope mailbox_breakdown --mailbox INBOX --days 30
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"days_back" : 0'
  # Control: a broad scope with the same flag DOES honor it, so the assertion above is about
  # scope semantics and not about days_back being hardcoded everywhere.
  run "$BIN" mail analytics stats --account iCloud --scope account_overview --days 30
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"days_back" : 30'
}

@test "mail analytics stats: a named system folder is not filtered to nothing" {
  require_index
  # Target a system folder that actually HAS mail. iCloud has both `Trash` (0 messages) and
  # `Deleted Messages` (non-empty); the first version of this test used Trash and asserted only
  # `system_folders_excluded: false` — a constant for every named breakdown — so it could not
  # distinguish "rows survived the filter" from "the mailbox was empty anyway".
  run "$BIN" mail analytics stats --account iCloud --scope mailbox_breakdown --mailbox "Deleted Messages"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
d = json.load(sys.stdin)["data"]
assert d.get("system_folders_excluded") is False, "named scope must not filter"
# THE discriminator: rows must actually have survived. Under the old unconditional filter this
# was 0, because "Deleted Messages" matches SKIP_FOLDERS.
assert d["total"] > 0, "expected surviving messages in Deleted Messages, got %r" % d["total"]
mb = d.get("mailbox_breakdown") or []
assert len(mb) == 1, "a named breakdown is one entry, got %d" % len(mb)
assert mb[0]["path"] == "Deleted Messages", "entry must name the REQUESTED mailbox, got %r" % mb[0]["path"]
assert d.get("mailbox") == "Deleted Messages"
print("OK", d["total"])
'
}

# The oracle raises `error "Mailbox not found"` (analytics.py:362-370). Returning ok:true/total:0
# for a typo is the worst answer available: indistinguishable from a genuinely empty mailbox.
@test "mail analytics stats: an unknown mailbox errors instead of reporting zero" {
  require_index
  run "$BIN" mail analytics stats --account iCloud --scope mailbox_breakdown --mailbox ZzzNotAMailbox
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '"type" : "not_found"'
  # CONTROL: a real-but-possibly-empty mailbox must still SUCCEED — the check is on existence,
  # not on row count, so this must not have become "empty means error".
  run "$BIN" mail analytics stats --account iCloud --scope mailbox_breakdown --mailbox Trash
  [ "$status" -eq 0 ]
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
  run "$BIN" mail rules create --dry-run --name "apple-cli-test-b" \
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
  run "$BIN" mail move --dry-run "$id" --source All --to Archive
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
    run "$BIN" mail $sub --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"scope_note"'
    echo "$output" | grep -q 'INCLUDES Trash/Junk/Sent/Drafts/Spam'
  done
  # A named mailbox has no divergence to report.
  run "$BIN" mail move --dry-run --match-subject apple-cli-test-zzz --source INBOX --to Archive
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
@test "mail rules update sandboxed DRY-RUN reports the self-scoping blocker instead of claiming clean" {
  # v2: self-scoping is the SANDBOX's restriction, so the blocker appears in a sandboxed preview.
  APPLE_TEST_MODE=1 run "$BIN" mail rules update --dry-run 1 --condition "from:contains:boss@example.com" --action "mark_read=true" --test-mode
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'subject condition bound to'
}

@test "mail rules create sandboxed DRY-RUN reports unlabeled-name and self-scoping blockers" {
  APPLE_TEST_MODE=1 run "$BIN" mail rules create --dry-run --name "quarterly-report-rule" --condition "from:contains:boss@x.io" --action "mark_read=true" --test-mode
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
  local src="$BATS_TEST_DIRNAME/../Sources/MailKit/Commands/WriteManageCommands.swift"
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

  # The cap must be enforced BEFORE MailContext() is built, or it is unreachable on a machine with
  # no configured Mail account (EnvelopeIndex.init throws exit 69 first) — which is exactly the CI
  # runner. Assert the ordering per command rather than trusting a comment.
  run python3 - "$src" <<'PYEOF'
import sys, re
src = open(sys.argv[1]).read()
ok = True
for verb in ("mark", "delete"):
    cap = src.index('try enforceBulkCap(ids, verb: "%s")' % verb)
    # the MailContext() that belongs to this command is the first one after the cap check
    ctx = src.index("try MailContext()", cap)
    # ...and there must be no MailContext() between the start of the enclosing run() and the cap.
    run_start = src.rindex("func run()", 0, cap)
    if "try MailContext()" in src[run_start:cap]:
        print("FAIL: %s builds MailContext before the cap check" % verb); ok = False
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
@test "mail mark accepts 100 ids and fails later at resolution (boundary is inclusive)" {
  require_index
  local ids=()
  for i in $(seq 1 100); do ids+=("$i"); done
  run "$BIN" mail mark --dry-run --read "${ids[@]}"
  ! echo "$output" | grep -q 'maximum is 100'
  echo "$output" | grep -q '"type" : "not_found"'
}

# SUPERSET control: `move` is uncapped in the oracle, so 101 ids must clear the cap layer entirely
# and fail at resolution like any other id list. If someone "helpfully" caps move, this fails.
@test "mail move ACCEPTS 101 ids — the oracle does not cap it" {
  require_index
  local ids=()
  for i in $(seq 1 101); do ids+=("$i"); done
  run "$BIN" mail move --dry-run --to "Archive" "${ids[@]}"
  # POSITIVE CONTROL FIRST. Without it this test is vacuous: the first draft passed `--to-mailbox`,
  # which is not a real flag, so the binary exited at argument parsing and the two negative greps
  # below "passed" against a usage error that never reached the cap. Asserting the command got as
  # far as message RESOLUTION is what proves it cleared the cap layer rather than dying before it.
  echo "$output" | grep -q '"type" : "not_found"'
  ! echo "$output" | grep -qi 'too many items'
  ! echo "$output" | grep -q 'at once (max: 100)'
}

# --- Q11-A read-surface parity pins ----------------------------------------------------------

@test "mail search with an unknown --mailbox is not_found, NOT an empty success (extra5)" {
  require_index
  run "$BIN" mail search --mailbox NoSuchMailboxXYZ --limit 1 --no-content
  [ "$status" -eq 65 ]
  echo "$output" | grep -q '"type" : "not_found"'
  echo "$output" | grep -q "unknown mailbox 'NoSuchMailboxXYZ'"
}

@test "mail thread --subject with an unknown --mailbox is not_found (extra5)" {
  require_index
  run "$BIN" mail thread --subject anything --mailbox NoSuchMailboxXYZ
  [ "$status" -eq 65 ]
  echo "$output" | grep -q '"type" : "not_found"'
}

@test "mail search rejects a negative --offset instead of clamping and echoing it (extra6)" {
  require_index
  run "$BIN" mail search --account iCloud --limit 1 --offset=-1 --no-content
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "mail get always emits the content key — empty string when suppressed (extra11)" {
  require_index
  id=$("$BIN" mail search --account iCloud --limit 1 --no-content 2>/dev/null \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['messages'][0]['id'])")
  [ -n "$id" ]
  run "$BIN" mail get "$id" --headers-only
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"content" : ""'
}

@test "mail thread by id reports the truncation signal when --limit caps it (gap5)" {
  require_index
  # A conversation with >1 member — a singleton exercises only the hardcoded total=1 fallback
  # branch, so the pin would stay green if the countMessages-based signal broke (review-caught).
  id=$("$BIN" mail search --mailbox All --limit 400 2>/dev/null | python3 -c "
import json,sys,collections
d=json.load(sys.stdin)['data']['messages']
c=collections.Counter(m.get('conversation_id') for m in d if m.get('conversation_id'))
multi=[k for k,n in c.items() if n>1]
print(next((m['id'] for m in d if m.get('conversation_id') in multi), ''))")
  [ -n "$id" ] || skip "no multi-message conversation in this store"
  run "$BIN" mail thread "$id" --limit 1
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"has_more" : true'
  total=$(echo "$output" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['total'])")
  [ "$total" -gt 1 ]
}

@test "mail thread rejects a negative --limit instead of treating it as unlimited" {
  require_index
  run "$BIN" mail thread --subject anything --limit=-5
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "mail attachments list <id> rejects a nonexistent --account instead of ignoring it (extra2)" {
  require_index
  run "$BIN" mail attachments list 1 --account NoSuchAccountXYZ
  [ "$status" -eq 65 ]
  echo "$output" | grep -q '"type" : "not_found"'
}

# --- Q11 batch-1 review-round pins (wiring + fix-delta) --------------------------------------

# gap1 WIRING: the live enrichment must actually reach the wire — deleting the enrichment call
# in attachmentRows leaves the parser/model suites green (critic B1), so this is the pin that
# goes red. `size` is the safe key on this store (MIME type throws in Mail.app itself).
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
' "$BATS_TEST_DIRNAME/../Sources/MailKit/Support/MailScript.swift" \
  "$BATS_TEST_DIRNAME/../Sources/MailKit/Commands/MessageReadCommands.swift" \
  "$BATS_TEST_DIRNAME/../Sources/MailKit/Commands/WriteManageCommands.swift"
  [ "$status" -eq 0 ]
}

@test "mail attachments list <id> carries live metadata on the wire (gap1 wiring)" {
  local xtrace_was_on=0
  case "$-" in
    *x*) xtrace_was_on=1; set +x ;;
  esac
  require_index
  select_live_attachment_fixture
  load_live_attachment_list
  assert_live_attachment_enriched
  unset LIVE_ATTACHMENT_ACCOUNT_ID LIVE_ATTACHMENT_ID LIVE_ATTACHMENT_ORACLE_COUNT \
    LIVE_ATTACHMENT_LIST_JSON
  # Skips/failures exit this isolated Bats test process, so xtrace cannot leak to another test.
  [ "$xtrace_was_on" -eq 0 ] || set -x
}

# gap6 WIRING: the grouped oracle-B shape must reach the wire, including a ZERO-attachment
# match (the old forced hasAttachment=true made that row structurally unreachable). --no-live
# keeps it fast; the grouping is independent of enrichment.
@test "mail attachments list --subject emits grouped emails with zero-attachment rows (gap6 wiring)" {
  require_index
  subj=$("$BIN" mail search --mailbox All --no-attachment --limit 1 --no-content 2>/dev/null \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)['data']['messages']
s=(d[0].get('subject') or '') if d else ''
print(s[:40])")
  [ -n "$subj" ] || skip "no attachment-less message with a subject in this store"
  run "$BIN" mail attachments list --subject "$subj" --mailbox All --no-live --max-results 5
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"matched_email_count" :'
  echo "$output" | grep -q '"emails" :'
  echo "$output" | grep -q '"attachment_count" : 0'
}

@test "mail attachments list --subject with an unknown --mailbox is not_found (review M2)" {
  require_index
  run "$BIN" mail attachments list --subject anything --mailbox NoSuchMailboxXYZ
  [ "$status" -eq 65 ]
  echo "$output" | grep -q '"type" : "not_found"'
}

@test "mail attachments list <id> --mailbox All is the wildcard, not a literal assertion (review H1)" {
  require_index
  id=$("$BIN" mail search --account iCloud --limit 1 --no-content 2>/dev/null \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['messages'][0]['id'])")
  [ -n "$id" ]
  run "$BIN" mail attachments list "$id" --mailbox All --no-live
  [ "$status" -eq 0 ]
}

@test "mail get <id> --mailbox All is the wildcard, not a literal assertion (review H1)" {
  require_index
  id=$("$BIN" mail search --account iCloud --limit 1 --no-content 2>/dev/null \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['messages'][0]['id'])")
  [ -n "$id" ]
  run "$BIN" mail get "$id" --headers-only --mailbox All
  [ "$status" -eq 0 ]
}

# Oracle B checks NAME emptiness before prepending the parent — checking after let
# `--name '/' --parent Projects` "succeed" by creating the PARENT (review M1).
@test "mail mailboxes create with a name that normalizes empty is rejected even with --parent" {
  require_index
  run "$BIN" mail mailboxes create --dry-run --account iCloud --name '/' --parent 'Projects'
  [ "$status" -eq 64 ]
  echo "$output" | grep -q 'cannot be empty'
}

# mailbox/parent echo the NORMALIZED components (path must equal parent + "/" + mailbox);
# raw inputs stay under *_raw (review M4).
@test "mail mailboxes create echoes normalized mailbox/parent with raw preserved" {
  require_index
  run "$BIN" mail mailboxes create --dry-run --account iCloud --name ' Projects / 2024 '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"mailbox" *: *"2024"'
  echo "$output" | grep -q '"parent" *: *"Projects"'
  echo "$output" | grep -q '"mailbox_raw" *: *" Projects \/ 2024 "'
  echo "$output" | grep -q '"path" *: *"Projects\/2024"'
}

# --- Q11-D bulk-targeting parity pins ---------------------------------------------------------

# gap23: the filter path seeds the ACTION-INVERSE (oracle B manage.py:419-427), so mark --read
# matches only UNREAD messages and --max budgets CHANGES, not matches.
@test "mail mark --read --all targets only unread messages (gap23 inverse seed)" {
  require_index
  run "$BIN" mail mark --read --dry-run --all --account iCloud --mailbox All
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q '"is_read" : true'
  echo "$output" | grep -q '"is_read" : false'
  # Anchored (a bare '"matched" : 1' would prefix-match 10/50 — that false-green shipped once
  # in this very batch's red-proof round for the delete pin below).
  echo "$output" | grep -qE '"matched" : 10(,|$)'
}

@test "mail mark --unread --all targets only read messages (gap23 inverse seed)" {
  require_index
  run "$BIN" mail mark --unread --dry-run --all --account iCloud --mailbox All
  [ "$status" -eq 0 ]
  # Positive control first — an empty match would pass the negation vacuously.
  echo "$output" | grep -q '"is_read" : true'
  ! echo "$output" | grep -q '"is_read" : false'
}

@test "mail flag --all targets only unflagged messages (gap23 inverse seed)" {
  require_index
  run "$BIN" mail flag --dry-run --all --account iCloud --mailbox All
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"flagged" : false'
  ! echo "$output" | grep -q '"flagged" : true'
  echo "$output" | grep -qE '"matched" : 10(,|$)'
}

# extra22: per-op --max defaults mirror oracle B (max_updates=10, max_deletes=5; move keeps 50).
# The store has far more candidates than the caps, so matched == the default cap.
@test "mail mark --all defaults --max to oracle B's 10 (extra22)" {
  require_index
  run "$BIN" mail mark --read --dry-run --all --account iCloud --mailbox All
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '"matched" : 10(,|$)'
}

@test "mail delete --all defaults --max to oracle B's 5 (extra22)" {
  require_index
  run "$BIN" mail delete --dry-run --all --account iCloud --mailbox INBOX
  [ "$status" -eq 0 ]
  # ANCHORED: the unanchored grep '"matched" : 5' prefix-matched the old code's
  # '"matched" : 50' and shipped a false-green red-proof (caught same session).
  echo "$output" | grep -qE '"matched" : 5(,|$)'
}

# extra21: on the explicit-ids path, --account scopes the ids (oracle A's narrow loop) — an id
# outside the scope is SKIPPED with a disclosure note and counted 0, never silently accepted.
@test "mail mark <id> with a mismatched --account skips the id with a note (extra21)" {
  require_index
  id=$("$BIN" mail search --account iCloud --limit 1 --no-content 2>/dev/null \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['messages'][0]['id'])")
  other=$("$BIN" mail accounts list 2>/dev/null | python3 -c "
import json,sys;a=json.load(sys.stdin)['data']['accounts']
print(next((x['name'] for x in a if x['name']!='iCloud'), ''))")
  [ -n "$id" ] && [ -n "$other" ] || skip "store lacks a second account"
  run "$BIN" mail mark --read --dry-run "$id" --account "$other" --mailbox All
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"matched" : 0'
  echo "$output" | grep -q 'outside the --account/mailbox scope'
}

@test "mail mark <id> with no --account keeps the legacy unscoped resolution (extra21)" {
  require_index
  id=$("$BIN" mail search --account iCloud --limit 1 --no-content 2>/dev/null \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['messages'][0]['id'])")
  [ -n "$id" ]
  run "$BIN" mail mark --read --dry-run "$id"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"matched" : 1'
}

# --- Q11-E rules/templates parity pins --------------------------------------------------------

# gap32 (deliberate divergence, bats-locked): no-field update stays a fail-loud 64 where
# oracle A returns a no-op success — see docs/port-specs/mail.md row 28.
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
@test "mail get with an empty message id is a validation error (review H1)" {
  require_index
  run "$BIN" mail get ""
  [ "$status" -eq 64 ]
  echo "$output" | grep -q "message id must not be empty"
}

# review M1: move's explicit-ids path honors --account scoping exactly like mark/flag/delete
# (oracle A's _bulk_repeat_block scoped loop) — an out-of-scope id is skipped with a note and
# counted 0, never resolved cross-account.
@test "mail move <id> with a mismatched --account skips the id with a note (review M1)" {
  require_index
  id=$("$BIN" mail search --account iCloud --limit 1 --no-content 2>/dev/null \
    | python3 -c "import json,sys;d=json.load(sys.stdin)['data']['messages'];print(d[0]['id'] if d else '')")
  other=$("$BIN" mail accounts list 2>/dev/null | python3 -c "
import json,sys;a=json.load(sys.stdin)['data']['accounts']
print(next((x['name'] for x in a if x['name']!='iCloud'), ''))")
  [ -n "$id" ] && [ -n "$other" ] || skip "store lacks a second account"
  run "$BIN" mail move --dry-run "$id" --to INBOX --account "$other"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"matched" : 0'
  echo "$output" | grep -q 'outside the --account/mailbox scope'
}

# review M4: on the explicit-ids path the mailbox narrows the scope ONLY when TYPED — the
# silent "INBOX" default must not narrow (that would skip every non-INBOX id the moment
# --account is given). Typed-and-wrong skips; typed-and-right matches.
@test "mail mark <id> --mailbox narrows the ids path only when typed (review M4)" {
  require_index
  id=$("$BIN" mail search --account iCloud --mailbox INBOX --limit 1 --no-content 2>/dev/null \
    | python3 -c "import json,sys;d=json.load(sys.stdin)['data']['messages'];print(d[0]['id'] if d else '')")
  wrong=$("$BIN" mail mailboxes list --account iCloud 2>/dev/null | python3 -c "
import json,sys;d=json.load(sys.stdin)['data'];rows=d.get('mailboxes',d)
print(next((r['name'] for r in rows if r['name'] not in ('INBOX','All')), ''))")
  [ -n "$id" ] && [ -n "$wrong" ] || skip "store lacks an iCloud INBOX message or a second mailbox"
  run "$BIN" mail mark --read --dry-run "$id" --account iCloud --mailbox "$wrong"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"matched" : 0'
  echo "$output" | grep -q 'outside the --account/mailbox scope'
  # Positive control: the typed CORRECT mailbox (and the correct account) still matches.
  run "$BIN" mail mark --read --dry-run "$id" --account iCloud --mailbox INBOX
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"matched" : 1'
}

# extra32: the save preview's positional master IS the live Mail.app enumeration — the same
# list (same order) `attachments list` reports live — and a live-resolved message carries no
# degraded note. Dry-run only: nothing is written.
@test "mail attachments save --dry-run previews the LIVE attachment order (extra32)" {
  local xtrace_was_on=0
  local live_hash preview_hash dest
  case "$-" in
    *x*) xtrace_was_on=1; set +x ;;
  esac
  require_index
  select_live_attachment_fixture
  load_live_attachment_list
  assert_live_attachment_enriched
  local live_parse_status=0
  live_hash=$(printf '%s' "$LIVE_ATTACHMENT_LIST_JSON" | /usr/bin/python3 -c '
import hashlib,json,sys
d=json.load(sys.stdin)["data"]
names=[a["name"] for a in d["attachments"]]
blob=json.dumps(names,ensure_ascii=True,separators=(",",":")).encode()
print(hashlib.sha256(blob).hexdigest())
' 2>/dev/null) || live_parse_status=$?
  unset LIVE_ATTACHMENT_LIST_JSON LIVE_ATTACHMENT_ORACLE_COUNT
  if [ "$live_parse_status" -ne 0 ]; then
    unset LIVE_ATTACHMENT_ACCOUNT_ID LIVE_ATTACHMENT_ID live_hash
    printf '%s\n' "live attachment order could not be hashed" >&2
    false
  fi
  dest=$(mktemp -d "$HOME/.cache/apple-cli-bats.XXXXXX")
  run /usr/bin/python3 "$BATS_TEST_DIRNAME/helpers/bounded_exec.py" \
    --timeout 90 --grace 2 -- "$BIN" mail attachments save \
    --account "$LIVE_ATTACHMENT_ACCOUNT_ID" --dir "$dest" --dry-run -- "$LIVE_ATTACHMENT_ID"
  local save_status="$status"
  local save_output="$output"
  output=""
  lines=()
  BATS_RUN_COMMAND=""
  local cleanup_status=0
  local dest_hint="${dest#"$HOME"/}"
  rmdir "$dest" 2>/dev/null || cleanup_status=$?
  if [ "$cleanup_status" -ne 0 ]; then
    unset LIVE_ATTACHMENT_ACCOUNT_ID LIVE_ATTACHMENT_ID live_hash save_output
    local cleanup_log_status=0
    printf '%s\n' "retained local artifact: \$HOME/$dest_hint (possible real attachment bytes; manual cleanup required)" \
      >> "$BATS_TEST_DIRNAME/../TEST-CLEANUP.md" || cleanup_log_status=$?
    printf '%s\n' "attachment save dry-run left content under \$HOME/$dest_hint" >&2
    printf '%s\n' "manual cleanup is required because it may contain real attachment bytes" >&2
    if [ "$cleanup_log_status" -ne 0 ]; then
      printf '%s\n' "the retained artifact could not be recorded in TEST-CLEANUP.md" >&2
    fi
    unset dest dest_hint
    false
  fi
  unset dest dest_hint
  if [ "$save_status" -eq 124 ]; then
    unset LIVE_ATTACHMENT_ACCOUNT_ID LIVE_ATTACHMENT_ID live_hash save_output
    require_osascript_mail_automation strict
    printf '%s\n' "in-CLI attachment save deadline did not fire before its host backstop" >&2
    false
  fi
  if [ "$save_status" -eq 69 ] || [ "$save_status" -eq 77 ]; then
    unset LIVE_ATTACHMENT_ACCOUNT_ID LIVE_ATTACHMENT_ID live_hash save_output
    require_osascript_mail_automation strict
    printf '%s\n' "attachment save reported Mail automation unavailable while the oracle was healthy" >&2
    false
  fi
  if [ "$save_status" -ne 0 ]; then
    unset LIVE_ATTACHMENT_ACCOUNT_ID LIVE_ATTACHMENT_ID live_hash save_output
    printf '%s\n' "attachment save dry-run command failed" >&2
    false
  fi
  unset LIVE_ATTACHMENT_ACCOUNT_ID LIVE_ATTACHMENT_ID
  # STRICT: a live-resolved message must NOT carry the degraded index-order note.
  local note_status=0
  printf '%s' "$save_output" | /usr/bin/python3 -c '
import json,sys
try:
    envelope=json.load(sys.stdin)
except (TypeError, ValueError):
    raise SystemExit(20)
if envelope.get("ok") is not True or envelope.get("tool") != "mail" or "schema_version" not in envelope:
    raise SystemExit(23)
try:
    data=envelope["data"]
except (KeyError, TypeError):
    raise SystemExit(21)
if data.get("dry_run") is not True:
    raise SystemExit(24)
raise SystemExit(11 if "note" in data else 0)
' 2>/dev/null || note_status=$?
  case "$note_status" in
    0) ;;
    11) unset live_hash save_output; printf '%s\n' "attachment save preview returned the degraded fallback note" >&2; false ;;
    20) unset live_hash save_output; printf '%s\n' "attachment save preview was not valid JSON" >&2; false ;;
    21) unset live_hash save_output; printf '%s\n' "attachment save preview omitted its data field" >&2; false ;;
    23) unset live_hash save_output; printf '%s\n' "attachment save preview violated the JSON envelope contract" >&2; false ;;
    24) unset live_hash save_output; printf '%s\n' "attachment save preview did not confirm dry-run mode" >&2; false ;;
    *) unset live_hash save_output; printf '%s\n' "attachment save preview assertion failed unexpectedly" >&2; false ;;
  esac
  local preview_parse_status=0
  preview_hash=$(printf '%s' "$save_output" | /usr/bin/python3 -c '
import hashlib,json,sys
d=json.load(sys.stdin)["data"]
blob=json.dumps(d["attachments"],ensure_ascii=True,separators=(",",":")).encode()
print(hashlib.sha256(blob).hexdigest())
' 2>/dev/null) || preview_parse_status=$?
  unset save_output
  if [ "$preview_parse_status" -ne 0 ]; then
    unset live_hash preview_hash
    printf '%s\n' "attachment save preview order could not be hashed" >&2
    false
  fi
  if [ "$preview_hash" != "$live_hash" ]; then
    unset live_hash preview_hash
    printf '%s\n' "attachment save preview order disagreed with the live list" >&2
    false
  fi
  unset live_hash preview_hash
  # Skips/failures exit this isolated Bats test process, so xtrace cannot leak to another test.
  [ "$xtrace_was_on" -eq 0 ] || set -x
}

# extra27 follow-up (review M3): --text on get/save/delete/render prints the text rendering —
# POSITIVE assertions on the content, not just the absence of the JSON envelope.
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
@test "mail analytics needs-response with an unknown --mailbox is not_found (review H4)" {
  require_index
  run "$BIN" mail analytics needs-response --account iCloud --mailbox NoSuchMailbox-xyz --days 3
  [ "$status" -eq 65 ]
  echo "$output" | grep -q '"type" : "not_found"'
}

@test "mail analytics top-senders with an unknown --mailbox is not_found (review H4)" {
  require_index
  run "$BIN" mail analytics top-senders --account iCloud --mailbox NoSuchMailbox-xyz --days 3
  [ "$status" -eq 65 ]
  echo "$output" | grep -q '"type" : "not_found"'
}

# review H5 (measured): a negative bound reached Swift's .prefix and TRAPPED — exit 133, empty
# stdout, violating the JSON-envelope contract. Typed 64 mirrors extra6's negative --offset.
@test "mail analytics needs-response/awaiting-reply/top-senders reject a negative bound (review H5)" {
  require_index
  run "$BIN" mail analytics needs-response --account iCloud --max=-1 --days 3
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
  run "$BIN" mail analytics awaiting-reply --account iCloud --max=-1 --days 3
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
  run "$BIN" mail analytics top-senders --account iCloud --top-n=-1 --days 3
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

# e2e wiring (review missing-pin list): the two commands actually reach the new code paths and
# carry the sent_mailbox disclosure. The key is OMITTED (not null) when no Sent mailbox
# resolved — this store resolves one, so its presence is the wiring signal here.
@test "mail analytics needs-response e2e emits items + sent_mailbox disclosure" {
  require_index
  run "$BIN" mail analytics needs-response --account iCloud --days 7 --max 5
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"count" :'
  echo "$output" | grep -q '"sent_mailbox" :'
}

@test "mail analytics awaiting-reply e2e emits items + sent_mailbox disclosure" {
  require_index
  run "$BIN" mail analytics awaiting-reply --account iCloud --days 7 --max 5
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"count" :'
  echo "$output" | grep -q '"sent_mailbox" :'
}

# --- Q11 batch-4 search/list/export parity pins -----------------------------------------------

# gap2: --body-live runs oracle B's live full-content scan (early-exit-bounded, so a common
# needle in a small scope returns fast). A live wiring pin, not a semantics pin — the per-message
# condition set is pinned at the logic tier against the script source.
@test "mail search --body --body-live returns live matches from Mail.app (gap2)" {
  require_index
  run "$BIN" mail search --account iCloud --mailbox INBOX --body the --body-live --limit 2 --no-content
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json,sys;d=json.load(sys.stdin)['data']
assert d['count'] <= 2, d['count']
assert all('id' in m for m in d['messages'])"
}

@test "mail search --body-live without --body is a validation error (gap2)" {
  require_index
  run "$BIN" mail search --body-live
  [ "$status" -eq 64 ]
  echo "$output" | grep -q -- "--body-live requires"
}

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
@test "mail list --limit-per-account caps each account and echoes the cap (gap9)" {
  require_index
  run "$BIN" mail list --limit-per-account 1 --no-content
  [ "$status" -eq 0 ]
  naccounts=$("$BIN" mail accounts list 2>/dev/null | python3 -c "import json,sys;print(len(json.load(sys.stdin)['data']['accounts']))")
  echo "$output" | python3 -c "
import json,sys
n=int('$naccounts')
d=json.load(sys.stdin)['data']
assert d['limit_per_account'] == 1, d.get('limit_per_account')
assert d['count'] <= n, (d['count'], n)
# per-account cap: no account contributes more than one row
from collections import Counter
c=Counter(m['account'] for m in d['messages'])
assert all(v == 1 for v in c.values()), c"
}

# gap45: export layouts, dry-run only (no writes). Oracle layout is the default.
@test "mail export dry-run plans the oracle mailbox layout by default (gap45)" {
  require_index
  run "$BIN" mail export --account iCloud --scope entire_mailbox --mailbox INBOX --max 2 --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json,sys;d=json.load(sys.stdin)['data']
assert d['dry_run'] is True
assert all('INBOX_export/' in f for f in d['files']), d['files']
assert any('/1_' in f for f in d['files']), d['files']"
}

@test "mail export dry-run single_email plans a subject-named file, no id prefix (gap45)" {
  require_index
  subj=$("$BIN" mail search --account iCloud --mailbox INBOX --limit 1 --no-content 2>/dev/null \
    | python3 -c "import json,sys;d=json.load(sys.stdin)['data']['messages'];print(d[0]['subject'][:12] if d else '')")
  [ -n "$subj" ] || skip "no INBOX message"
  run "$BIN" mail export --account iCloud --scope single_email --subject "$subj" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json,sys,os;d=json.load(sys.stdin)['data']
name=os.path.basename(d['files'][0])
assert not name.split('.')[0].split('-')[0].isdigit() or '-' not in name, name  # no <id>- prefix shape
assert '_export/' not in d['files'][0], d['files'][0]"
}

@test "mail export --layout flat keeps the legacy id-prefixed names; bogus layout is 64 (gap45)" {
  require_index
  run "$BIN" mail export --account iCloud --scope entire_mailbox --mailbox INBOX --max 1 --layout flat --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json,sys,os;d=json.load(sys.stdin)['data']
name=os.path.basename(d['files'][0])
assert name.split('-')[0].isdigit(), name
assert '_export/' not in d['files'][0]"
  run "$BIN" mail export --account iCloud --layout bogus --dry-run
  [ "$status" -eq 64 ]
}

# review H1 (measured): a FULL nested mailbox path silently returned an empty success on the
# live path (leaf-only `whose` filter); the leaf reduction must make it match.
@test "mail search --body-live accepts a full nested mailbox path (review H1)" {
  require_index
  acct="${APPLE_TEST_NESTED_ACCOUNT:-}"
  "$BIN" mail mailboxes list --account "$acct" >/dev/null 2>&1 || skip "store lacks the configured test account"
  run "$BIN" mail search --account "$acct" --mailbox "[Gmail]/Important" --body a --body-live --limit 2 --no-content
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json,sys;d=json.load(sys.stdin)['data']
assert d['count'] >= 1, d
assert d['sort'] == 'date_desc', d['sort']"
}

# review B2 (measured): the oracle SORTS the collected body-search window then slices
# (_build_search_response, search.py:146-149) — the live path must honor --sort, and the
# envelope must echo what was applied.
@test "mail search --body-live honors --sort date_asc (review B2)" {
  require_index
  run "$BIN" mail search --account iCloud --mailbox INBOX --body the --body-live --limit 3 --sort date_asc --no-content
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json,sys;d=json.load(sys.stdin)['data']
assert d['sort'] == 'date_asc', d['sort']
dates=[m['date_received'] for m in d['messages']]
assert dates == sorted(dates), dates"
}

# Differential pin (critic missing-pin list): inside one subject-scoped candidate set, a needle
# taken from a message's own indexed preview must be found by BOTH --body paths. Subject/body
# predicates AND together in both engines (pinned by the logic tier); one `--subject` value is one
# literal full-subject substring (not word-tokenized), keeping this live oracle probe narrow
# without changing which body predicate must match.
@test "mail search --body indexed vs --body-live agree for a subject-scoped preview needle" {
  local xtrace_was_on=0
  local bats_trace_level_was="${BATS_TRACE_LEVEL:-0}"
  local bats_verbose_run_was="${BATS_VERBOSE_RUN:-}"
  local probe probe_rest id needle subject
  case "$-" in
    *x*) xtrace_was_on=1; set +x ;;
  esac
  # `bats --trace` uses a DEBUG trap independent of shell xtrace. Disable both before any
  # mailbox-derived value reaches argv; this test process is isolated, so early exits cannot
  # carry either setting into a later test.
  BATS_TRACE_LEVEL=0
  # `--verbose-run` prints `$output` from inside `run`, before post-run scrubbing can happen.
  BATS_VERBOSE_RUN=
  require_index
  # bounded_exec intentionally combines its child's stdout/stderr. Discard only the CLI's human
  # stderr inside the same process group so the parser receives JSON stdout alone. Dynamic values
  # stay in argv (`$@`), never in shell source. Losing human diagnostics is deliberate: they can
  # contain mailbox text and must not escape into a test log.
  run /usr/bin/python3 "$BATS_TEST_DIRNAME/helpers/bounded_exec.py" \
    --timeout 30 --grace 2 -- /bin/sh -c 'exec "$@" 2>/dev/null' apple-json \
    "$BIN" mail search \
    --account iCloud --mailbox INBOX --limit 10
  local probe_status="$status"
  local probe_output="$output"
  output=""
  lines=()
  BATS_RUN_COMMAND=""
  case "$probe_status" in
    0) ;;
    69|77) unset probe_output; skip "preview fixture search unavailable" ;;
    124) unset probe_output; printf '%s\n' "indexed preview fixture search exceeded its outer bound" >&2; false ;;
    *) unset probe_output; printf '%s\n' "preview fixture search failed" >&2; false ;;
  esac
  local probe_parse_status=0
  probe=$(printf '%s' "$probe_output" | /usr/bin/python3 -c '
import json,sys
messages=json.load(sys.stdin)["data"]["messages"]
for message in messages:
    message_id=message.get("id") or ""
    snippet=message.get("snippet") or ""
    subject=message.get("subject") or ""
    if (not message_id or any(ord(c) < 32 or ord(c) == 127 for c in message_id)
            or not subject or subject.startswith("-")
            or any(ord(c) < 32 or ord(c) == 127 for c in subject)):
        continue
    words=[word for word in snippet.split()
           if word.isascii() and word.isalpha() and len(word) >= 6]
    if words:
        sys.stdout.write(message_id + "\x1e" + words[0] + "\x1e" + subject)
        break
' 2>/dev/null) || probe_parse_status=$?
  unset probe_output
  if [ "$probe_parse_status" -ne 0 ]; then
    unset probe
    printf '%s\n' "preview fixture response was invalid" >&2
    false
  fi
  [ -n "$probe" ] || skip "no preview-bearing message with a safe subject to probe"
  case "$probe" in
    *$'\n'*|*$'\r'*) unset probe; printf '%s\n' "preview fixture tuple was invalid" >&2; false ;;
    *$'\036'*) ;;
    *) unset probe; printf '%s\n' "preview fixture tuple omitted its needle" >&2; false ;;
  esac
  id="${probe%%$'\036'*}"
  probe_rest="${probe#*$'\036'}"
  case "$probe_rest" in
    *$'\036'*) ;;
    *) unset probe probe_rest id; printf '%s\n' "preview fixture tuple omitted its subject" >&2; false ;;
  esac
  needle="${probe_rest%%$'\036'*}"
  subject="${probe_rest#*$'\036'}"
  unset probe probe_rest
  if [ -z "$id" ] || [ -z "$needle" ] || [ -z "$subject" ]; then
    unset id needle subject
    printf '%s\n' "preview fixture tuple contained an empty field" >&2
    false
  fi

  run /usr/bin/python3 "$BATS_TEST_DIRNAME/helpers/bounded_exec.py" \
    --timeout 30 --grace 2 -- /bin/sh -c 'exec "$@" 2>/dev/null' apple-json \
    "$BIN" mail search --account iCloud --mailbox INBOX \
    --subject "$subject" --body "$needle" --limit 50 --no-content
  local indexed_status="$status"
  local indexed_output="$output"
  output=""
  lines=()
  BATS_RUN_COMMAND=""
  if [ "$indexed_status" -ne 0 ]; then
    unset id needle subject indexed_output
    printf '%s\n' "indexed preview parity query failed" >&2
    false
  fi
  local indexed_assert_status=0
  printf '%s' "$indexed_output" | /usr/bin/python3 -c '
import json,sys
try:
    expected=sys.argv[1]
    messages=json.load(sys.stdin)["data"]["messages"]
except Exception:
    raise SystemExit(2)
raise SystemExit(0 if any(message["id"] == expected for message in messages) else 1)
' "$id" 2>/dev/null || indexed_assert_status=$?
  unset indexed_output
  case "$indexed_assert_status" in
    0) ;;
    1)
      unset id needle subject
      printf '%s\n' "indexed preview query omitted its source message" >&2
      false
      ;;
    *)
      unset id needle subject
      printf '%s\n' "indexed preview response was invalid" >&2
      false
      ;;
  esac

  # Establish the uncapped subject-only baseline before the negative control. Search defines
  # --limit 0 as all results; these two calls are otherwise identical, so the body's synthetic
  # token is the only variable governing the required present -> absent transition.
  run /usr/bin/python3 "$BATS_TEST_DIRNAME/helpers/bounded_exec.py" \
    --timeout 30 --grace 2 -- /bin/sh -c 'exec "$@" 2>/dev/null' apple-json \
    "$BIN" mail search --account iCloud --mailbox INBOX \
    --subject "$subject" --limit 0 --no-content
  local baseline_status="$status"
  local baseline_output="$output"
  output=""
  lines=()
  BATS_RUN_COMMAND=""
  if [ "$baseline_status" -ne 0 ]; then
    unset id needle subject baseline_output
    printf '%s\n' "indexed subject-only baseline query failed" >&2
    false
  fi
  local baseline_assert_status=0
  printf '%s' "$baseline_output" | /usr/bin/python3 -c '
import json,sys
try:
    expected=sys.argv[1]
    messages=json.load(sys.stdin)["data"]["messages"]
except Exception:
    raise SystemExit(2)
raise SystemExit(0 if any(message["id"] == expected for message in messages) else 1)
' "$id" 2>/dev/null || baseline_assert_status=$?
  unset baseline_output
  case "$baseline_assert_status" in
    0) ;;
    1)
      unset id needle subject
      printf '%s\n' "indexed subject-only baseline omitted its source message" >&2
      false
      ;;
    *)
      unset id needle subject
      printf '%s\n' "indexed subject-only baseline response was invalid" >&2
      false
      ;;
  esac

  # Cheap negative control: with the same literal subject and uncapped result set, the source id
  # must disappear for a reserved synthetic body token. This makes --body load-bearing
  # independently of the live engine's static AND-semantics pin, without a second Mail.app scan.
  local negative_needle="apple-cli-test-body-negative-control-9f4a7c2e"
  run /usr/bin/python3 "$BATS_TEST_DIRNAME/helpers/bounded_exec.py" \
    --timeout 30 --grace 2 -- /bin/sh -c 'exec "$@" 2>/dev/null' apple-json \
    "$BIN" mail search --account iCloud --mailbox INBOX \
    --subject "$subject" --body "$negative_needle" --limit 0 --no-content
  local negative_status="$status"
  local negative_output="$output"
  output=""
  lines=()
  BATS_RUN_COMMAND=""
  unset negative_needle
  if [ "$negative_status" -ne 0 ]; then
    unset id needle subject negative_output
    printf '%s\n' "indexed body negative-control query failed" >&2
    false
  fi
  local negative_assert_status=0
  printf '%s' "$negative_output" | /usr/bin/python3 -c '
import json,sys
try:
    expected=sys.argv[1]
    messages=json.load(sys.stdin)["data"]["messages"]
except Exception:
    raise SystemExit(2)
raise SystemExit(1 if any(message["id"] == expected for message in messages) else 0)
' "$id" 2>/dev/null || negative_assert_status=$?
  unset negative_output
  case "$negative_assert_status" in
    0) ;;
    1)
      unset id needle subject
      printf '%s\n' "indexed body negative control still included its source message" >&2
      false
      ;;
    *)
      unset id needle subject
      printf '%s\n' "indexed body negative-control response was invalid" >&2
      false
      ;;
  esac

  # 195 < 210: the CLI host deadline must fire before the outer process-group backstop.
  run /usr/bin/python3 "$BATS_TEST_DIRNAME/helpers/bounded_exec.py" \
    --timeout 210 --grace 2 -- /bin/sh -c 'exec "$@" 2>/dev/null' apple-json \
    "$BIN" mail search --account iCloud --mailbox INBOX \
    --subject "$subject" --body "$needle" --body-live --body-live-timeout 195 \
    --limit 50 --no-content
  local live_status="$status"
  local live_output="$output"
  output=""
  lines=()
  BATS_RUN_COMMAND=""
  case "$live_status" in
    0) ;;
    69|77)
      unset id needle subject live_output
      skip "live body-search parity query unavailable within its host bound"
      ;;
    124)
      unset id needle subject live_output
      printf '%s\n' "outer live body-search bound fired before the CLI host deadline completed" >&2
      false
      ;;
    *)
      unset id needle subject live_output
      printf '%s\n' "live body-search parity query failed" >&2
      false
      ;;
  esac
  local live_assert_status=0
  printf '%s' "$live_output" | /usr/bin/python3 -c '
import json,sys
try:
    expected=sys.argv[1]
    messages=json.load(sys.stdin)["data"]["messages"]
except Exception:
    raise SystemExit(2)
raise SystemExit(0 if any(message["id"] == expected for message in messages) else 1)
' "$id" 2>/dev/null || live_assert_status=$?
  unset id needle subject live_output
  case "$live_assert_status" in
    0) ;;
    1) printf '%s\n' "live body query omitted the preview source message" >&2; false ;;
    *) printf '%s\n' "live body response was invalid" >&2; false ;;
  esac
  # Skips/failures exit this isolated Bats test process, so trace state cannot leak to another.
  [ "$xtrace_was_on" -eq 0 ] || set -x
  BATS_TRACE_LEVEL="$bats_trace_level_was"
  BATS_VERBOSE_RUN="$bats_verbose_run_was"
}

# review M9: export --max sign guard + the oracle's zero-success for --max 0.
@test "mail export --max validates sign and treats 0 as the oracle's empty success (review M9)" {
  require_index
  run "$BIN" mail export --account iCloud --scope entire_mailbox --mailbox INBOX --max=-1 --dry-run
  [ "$status" -eq 64 ]
  run "$BIN" mail export --account iCloud --scope entire_mailbox --mailbox INBOX --max 0 --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json,sys;d=json.load(sys.stdin)['data']
assert d['files'] == [], d['files']"
}

# ---- Q11-C batch 5: reply modes + rich-draft oracle echoes (gap17/19/20, extra14/16) ----

# gap17: a dry-run previews --mode draft/open honestly (mode echoed, nothing executed).
@test "mail reply --mode draft --dry-run previews the mode without executing (gap17)" {
  require_index
  id=$("$BIN" mail search --mailbox INBOX --limit 1 --no-content | python3 -c "
import json,sys;m=json.load(sys.stdin)['data']['messages'];print(m[0]['id'] if m else '')")
  [ -n "$id" ] || skip "no INBOX message to target"
  run "$BIN" mail reply "$id" --body "apple-cli-test preview" --mode draft --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json,sys;d=json.load(sys.stdin)['data']
assert d['mode'] == 'draft', d['mode']
assert d['dry_run'] is True and d['executed'] is False and d['opened'] is False
assert d['drafted'] is False"
  run "$BIN" mail reply "$id" --body "apple-cli-test preview" --mode open --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json,sys;d=json.load(sys.stdin)['data']
assert d['mode'] == 'open' and d['executed'] is False"
}

# extra16 (BREAKING): the reply --subject lookup scopes to INBOX by default, like oracle B.
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
@test "mail reply --subject default scope excludes non-INBOX messages (extra16 behavior)" {
  require_index
  probe=$("$BIN" mail search --mailbox "Sent Messages" --limit 25 --no-content | python3 -c "
import json,sys,subprocess
bin=sys.argv[1]
msgs=json.load(sys.stdin)['data']['messages']
for m in msgs:
    s=m['subject'].strip()
    if len(s) < 8 or s.lower().startswith('re:'): continue
    r=subprocess.run([bin,'mail','search','--mailbox','INBOX','--subject',s,'--limit','1','--no-content'],
                     capture_output=True,text=True)
    try: hits=json.loads(r.stdout)['data']['messages']
    except Exception: continue
    if not hits:
        print(s); break" "$BIN")
  [ -n "$probe" ] || skip "no Sent-only subject found to probe with"
  run "$BIN" mail reply --dry-run --subject "$probe" --body x
  [ "$status" -eq 65 ]
  echo "$output" | grep -q 'mailbox'
  run "$BIN" mail reply --dry-run --subject "$probe" --mailbox All --body x
  [ "$status" -eq 0 ]
}

# extra14: the forward preview carries oracle B's `recipients` echo (== the --to list).
@test "mail forward --dry-run echoes recipients (extra14)" {
  require_index
  id=$("$BIN" mail search --mailbox INBOX --limit 1 --no-content | python3 -c "
import json,sys;m=json.load(sys.stdin)['data']['messages'];print(m[0]['id'] if m else '')")
  [ -n "$id" ] || skip "no INBOX message to target"
  APPLE_TEST_MODE=1 APPLE_TEST_RECIPIENTS="me@self.test" \
    run "$BIN" mail forward "$id" --to me@self.test --dry-run --test-mode
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json,sys;d=json.load(sys.stdin)['data']
assert d['recipients'] == ['me@self.test'], d"
}

# gap19: with nothing supplied, the preview reports the oracle's missing_details in the
# oracle's order (subject -> to -> body) and fills placeholder bodies.
#
# This runs on the BARE default (no --no-open) deliberately. `--open` defaults true since
# extra20, and a first implementation of that flip put guardOutbound + a required --subject on
# the default path, which made this call exit 64 — strictly less capable than oracle B, whose
# `compose.py:139-140` defaults `subject=""`/`to=None` and whose :178-186 reports exactly these
# missing_details. That attempt "fixed" the red by rewriting this test onto --no-open, hiding
# the regression behind the flag; review caught it. Keep the bare form: it is what pins the
# oracle-default path.
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

@test "mail trash empty --dry-run --text is HONORED (renders text, not JSON) (Q12 [10])" {
  # --dry-run hits the same `guard willExecute else` preview branch as the surface's default
  # (trash defaults to dry-run); the explicit flag satisfies the no-flagless-writes lint.
  run "$BIN" mail trash empty --account "apple-cli-test-noaccount" --dry-run --text
  [ "$status" -eq 0 ]
  echo "${lines[0]}" | grep -qv '{'
  echo "$output" | grep -q '^action: empty_trash'
}
