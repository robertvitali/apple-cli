#!/usr/bin/env bats

BATS_SUITE_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
REPO_ROOT="$(cd "$BATS_SUITE_ROOT/.." && pwd -P)"
HELPERS="$BATS_SUITE_ROOT/helpers"
load "$HELPERS/app_lifecycle"
# Local read-only capability tests for the `messages` domain. These checks need the operator's
# existing Full Disk Access but assert only schema, booleans, and counts; no live values are emitted.

setup() {
  export PATH="$HOME/.swiftly/bin:$PATH"
  BIN="$(swift build --show-bin-path)/apple"
}

# Live Messages reads need a readable chat.db. Probe it independently of the CLI under test:
# only a missing database or an explicit permission denial may skip.
require_messages_database() {
  local xtrace_was_on=0 probe_status
  case "$-" in
    *x*) xtrace_was_on=1; set +x ;;
  esac

  run /usr/bin/python3 "$HELPERS/messages_db_probe.py"
  probe_status="$status"
  output=""
  lines=()

  if [ "$probe_status" -eq 77 ]; then
    [ "$xtrace_was_on" -eq 0 ] || set -x
    skip "Messages database is missing or unreadable; Full Disk Access may be required"
  fi
  if [ "$probe_status" -ne 0 ]; then
    [ "$xtrace_was_on" -eq 0 ] || set -x
    echo "Messages database preflight failed unexpectedly" >&2
    return 1
  fi
  [ "$xtrace_was_on" -eq 0 ] || set -x
}

# --- send safety -----------------------------------------------------------------------------
#
# These commands cannot send, but Messages resolves the synthetic handle through the local
# AddressBook before it selects the preview or sandbox-refusal path. They therefore belong in
# the local tier even though the assertions themselves are deterministic.

@test "send --dry-run previews: executed=false, dry_run=true, ok=true, nothing sent" {
  run "$BIN" messages send 2125550100 --message "smoke test" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"executed" : false'
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"ok" : true'
}

@test "APPLE_DRY_RUN=1 restores dry-run-by-default for a flagless send" {
  APPLE_DRY_RUN=1 run "$BIN" messages send 2125550100 --message "smoke test"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"executed" : false'
}

@test "sandbox via --test-mode alone refuses a non-allowlisted recipient (exit 64, nothing sent)" {
  unset APPLE_TEST_MODE
  run "$BIN" messages send 2125550100 --message "must not send" --test-mode --execute
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"ok" : false'
  echo "$output" | grep -qi "not in the test allowlist"
  echo "$output" | grep -q '"sandbox" : true'
}

@test "sandbox via APPLE_TEST_MODE env alone refuses a non-allowlisted recipient (exit 64)" {
  APPLE_TEST_MODE=1 run "$BIN" messages send 2125550100 --message "must not send" --execute
  [ "$status" -eq 64 ]
  echo "$output" | grep -qi "not in the test allowlist"
  echo "$output" | grep -q '"sandbox" : true'
}

@test "sandboxed --dry-run refuses the same recipient an execute would (no dishonest preview)" {
  run "$BIN" messages send 2125550100 --message "must not send" --test-mode --dry-run
  [ "$status" -eq 64 ]
  echo "$output" | grep -qi "not in the test allowlist"
}

# The refusal is STRUCTURAL, not an allowlist miss: the allowlist is seeded with the very chat id
# being sent to (scoped to this one invocation, so no APPLE_* variable is set for the suite), and
# the send is still refused. Asserting the group-specific wording — and the absence of the
# allowlist wording — is what proves the structural guard ran rather than a lucky mismatch.
@test "sandboxed group send is refused structurally even when the chat id is itself allowlisted" {
  APPLE_TEST_RECIPIENTS="iMessage;-;chat123456789" run "$BIN" messages send "iMessage;-;chat123456789" --message "must not send" --group --test-mode --dry-run
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"ok" : false'
  echo "$output" | grep -q '"sandbox" : true'
  echo "$output" | grep -qi "group-chat send is unavailable"
  ! echo "$output" | grep -qi "not in the test allowlist"
}

# --- help + subcommand surface (no TCC) ---

@test "check-db emits the documented JSON shape" {
  run "$BIN" messages check-db
  # Skip only if FDA is missing on this machine (connected=false path).
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"tool" : "messages"'
  echo "$output" | grep -q '"ok" : true'
  for field in exists readable connected has_message_table has_handle_table has_chat_table path; do
    echo "$output" | grep -q "\"$field\""
  done
}

@test "find-contact with no matches still returns ok=true, count 0" {
  run "$BIN" messages find-contact "zzzznonexistentzzzz9999"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"ok" : true'
  echo "$output" | grep -q '"count" : 0'
}

@test "check-availability returns available boolean + service" {
  require_messages_database
  run "$BIN" messages check-availability 2125550100
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"available"'
  echo "$output" | grep -q '"service"'
  echo "$output" | grep -q '"recommendation"'
}

@test "text mode (--text) emits non-JSON on stdout" {
  run "$BIN" messages check-db --text
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "path:"
  ! echo "$output" | grep -q '"schema_version"'
}

# --- flagless read leaves must actually be invoked (a GlobalOptions collision
#     would otherwise never surface). FDA is granted so these run. ---

# A message from a named group (a group name on a row that still has a chat) means that chat is
# a named chat, so the listing cannot be empty: the chats cases below that would pass on an
# empty listing rest on this one. (The listing leaves out a chat row with no identifier, which
# chat.db does not hold for a named chat.)
@test "chats runs and emits ok=true with a count" {
  require_messages_database
  messages_live_check named -- messages recent --hours 720 --limit 500
  take_live_number named
  local named="$live_number"
  messages_live_check count -- messages chats
  take_live_number count
  [ "$named" -eq 0 ] || [ "$live_number" -gt 0 ]
}

@test "check-contacts runs and emits ok=true with a count" {
  run "$BIN" messages check-contacts
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"ok" : true'
  echo "$output" | grep -q '"count"'
}

@test "check-addressbook runs and emits ok=true with database_count" {
  run "$BIN" messages check-addressbook
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"ok" : true'
  echo "$output" | grep -q '"database_count"'
}

@test "doctor runs and emits ok=true with full_disk_access" {
  run "$BIN" messages doctor
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"ok" : true'
  echo "$output" | grep -q '"full_disk_access"'
}

# --- surfaces added by outside pull requests 3 and 4 ----------------------------------------
#
# Live-store reads below never let a value reach Bats' output: the CLI's JSON goes straight into
# a fixed checker that prints only "ok", "empty", a value-free reason or a bare count, so a
# failing case shows no message, chat or participant text. Counts are compared in the shell, and
# the helper turns off --verbose-run so not even a count is echoed. A case whose window or store
# holds nothing to check skips, and a malformed answer fails. The chats cases that would pass on
# an empty listing (an equal count, an empty match, a bound) rely on "chats runs" above, which
# fails an empty listing when the last 30 days hold a message from a named group.

MESSAGES_LIVE_CHECK='
import json, re, sys, unicodedata
check, arg = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else None)
try:
    envelope = json.load(sys.stdin)
except Exception:
    print("not a JSON envelope")
    sys.exit(0)
data = envelope.get("data") if isinstance(envelope, dict) else None
if not isinstance(data, dict) or envelope.get("ok") is not True:
    print("not an ok envelope")
    sys.exit(0)
messages = data.get("messages")
chats = data.get("chats")
identity = ("chat_identifier", "chat_guid", "is_group")
activity = ("last_activity", "last_activity_timestamp", "participants")
rows = messages if check in ("direct", "undirected", "groups", "directs", "named") else chats
if not isinstance(rows, list) or not all(isinstance(r, dict) for r in rows):
    print("check %s failed" % check)
    sys.exit(0)
flags = all(all(k in m for k in identity) and isinstance(m.get("is_group"), bool)
            for m in rows) if check in ("direct", "undirected") else True
# Two signals that do not come from the chat.style behind is_group mark a row as a group row
# whatever is_group says: a group_name (from the room-name lookup) on a row that still belongs to
# a chat (a message in Recently Deleted keeps its group_name but loses its chat), and a chat
# identifier of the form chat<digits>, which Messages gives group chats only. Unnamed groups
# with any other identifier have no such signal. A red from a signal can also mean a chat<digits>
# chat whose style is not 43, or a message whose first chat is not its named group: --direct-only
# keeps such a group message, so read the red rather than retry it.
has_chat = lambda m: isinstance(m.get("chat_identifier"), str) and m["chat_identifier"] != ""
named = lambda m: has_chat(m) and isinstance(m.get("group_name"), str) and m["group_name"] != ""
group_signal = lambda m: named(m) or (has_chat(m)
                                      and re.fullmatch(r"chat[0-9]+", m["chat_identifier"]) is not None)
# The CLI matches names by character: composing first keeps a decomposed accent with its letter.
fold = lambda name: unicodedata.normalize("NFC", name).lower()
if check == "direct":
    good = (data.get("direct_only") is True and data.get("direct_only_applied") is True
            and flags and not any(m.get("is_group") is True or group_signal(m) for m in rows))
    if good:
        print("direct=%d" % len(rows))
        sys.exit(0)
elif check == "undirected":
    if (data.get("direct_only") is False and data.get("direct_only_applied") is False
            and not rows):
        print("empty")
        sys.exit(0)
    # Some row must still name its chat: identity lost on every row (a chat.db change, or a
    # failed lookup) would otherwise read as a store with no group message. A window holding
    # only Recently Deleted messages, which have left their chats, fails here too.
    good = (data.get("direct_only") is False and data.get("direct_only_applied") is False
            and flags and any(has_chat(m) for m in rows))
elif check == "chat-rows":
    if "name_filter" in data and data["name_filter"] is None and not rows:
        print("empty")
        sys.exit(0)
    good = ("name_filter" in data and data["name_filter"] is None
            and all(all(k in c for k in activity) for c in rows))
elif check in ("groups", "directs", "named", "activity", "count", "matched", "names"):
    if check == "groups":
        if any(group_signal(m) and m.get("is_group") is not True for m in rows):
            print("check groups failed")
            sys.exit(0)
        number = sum(1 for m in rows if m.get("is_group") is True)
    elif check == "directs":
        number = sum(1 for m in rows if m.get("is_group") is False)
    elif check == "named":
        number = sum(1 for m in rows if named(m))
    elif check == "names":
        wanted = fold(arg or "")
        number = (sum(1 for c in rows if isinstance(c.get("display_name"), str)
                      and wanted in fold(c["display_name"])) if wanted else None)
    elif check == "activity":
        number = sum(1 for c in rows if c.get("last_activity") is not None)
    elif check == "count":
        number = data.get("count")
        if not isinstance(number, int) or isinstance(number, bool) or number != len(rows):
            number = None
    else:
        wanted = fold(arg or "")
        keep = all(isinstance(c.get("display_name"), str)
                   and wanted in fold(c["display_name"]) for c in rows)
        number = len(rows) if data.get("name_filter") == arg and wanted and keep else None
    if number is not None:
        print("%s=%d" % (check, number))
        sys.exit(0)
    good = False
else:
    good = False
print("ok" if good else "check %s failed" % check)
'

# messages_live_check <check> [<checker arg>] -- <apple arguments...>
messages_live_check() {
  # A local BATS_VERBOSE_RUN reaches run (bash scopes dynamically) and is restored on return.
  local check="$1" arg="" BATS_VERBOSE_RUN=
  shift
  if [ "$1" != "--" ]; then
    arg="$1"
    shift
  fi
  [ "$1" = "--" ] || return 2
  shift
  run /bin/bash -c 'set -o pipefail; program="$1" check="$2" arg="$3"; shift 3
    "$@" 2>/dev/null | /usr/bin/python3 -c "$program" "$check" "$arg"' \
    _ "$MESSAGES_LIVE_CHECK" "$check" "$arg" "$BIN" "$@"
}

# take_live_number <name>: after a successful messages_live_check, require "<name>=<digits>"
# and leave the number in $live_number; any other answer fails the case. Clears the output.
take_live_number() {
  # On failure, name the checker's answer: a fixed reason, never a store value.
  [ "$status" -eq 0 ] || { echo "live check exited $status: $output" >&2; return 1; }
  case "$output" in
    "$1"=[0-9]*) ;;
    *) echo "live check answered: $output" >&2; return 1 ;;
  esac
  live_number="${output#"$1"=}"
  output=""
  lines=()
  case "$live_number" in
    *[!0-9]*) return 1 ;;
  esac
}

# The two --direct-only cases first read the same window unfiltered. Every row with a group
# signal the checker reads apart from is_group (a group name, or a chat<digits> identifier) must
# be flagged a group, so a classification that reports those rows as direct fails rather than
# skips. The filtered read runs before any skip and must report the filter applied. It must also
# keep the direct rows: the filter is applied in SQL before the limit, so over the newest 500
# messages of ten years (far from the window edge on any store holding that many) it returns at
# least as many as the unfiltered read held, barring a deletion between the reads. The search
# window's edge is near, so there it must only be non-empty when direct rows exist. A case skips
# only when its window holds no row flagged a group and no row with a signal, after those checks.
@test "recent --direct-only drops the group rows an unfiltered read of the same window returns" {
  require_messages_database
  messages_live_check groups -- messages recent --hours 87600 --limit 500
  take_live_number groups
  local groups="$live_number"
  messages_live_check directs -- messages recent --hours 87600 --limit 500
  take_live_number directs
  local directs="$live_number"
  messages_live_check direct -- messages recent --hours 87600 --limit 500 --direct-only
  take_live_number direct
  [ "$live_number" -ge "$directs" ]
  [ "$groups" -gt 0 ] || skip "no group-chat message in the window to filter out"
}

@test "recent without --direct-only reports both flags false and chat identity keys on every row" {
  require_messages_database
  messages_live_check undirected -- messages recent --hours 720 --limit 500
  [ "$status" -eq 0 ]
  [ "$output" != "empty" ] || skip "no message in the window to check"
  [ "$output" = "ok" ]
}

# search sets is_group itself; the same group-signal requirement applies to its rows.
@test "search --direct-only drops the group rows an unfiltered search of the same window returns" {
  require_messages_database
  messages_live_check groups -- messages search e --match contains --hours 168
  take_live_number groups
  local groups="$live_number"
  messages_live_check directs -- messages search e --match contains --hours 168
  take_live_number directs
  local directs="$live_number"
  messages_live_check direct -- messages search e --match contains --hours 168 --direct-only
  take_live_number direct
  [ "$directs" -eq 0 ] || [ "$live_number" -gt 0 ]
  [ "$groups" -gt 0 ] || skip "no group-chat message in the window to filter out"
}

@test "chats rows carry last_activity, last_activity_timestamp and participants, name_filter null" {
  require_messages_database
  messages_live_check chat-rows -- messages chats
  [ "$status" -eq 0 ]
  [ "$output" != "empty" ] || skip "no named group chat to check"
  [ "$output" = "ok" ]
}

@test "chats --name with an empty string matches the unfiltered count" {
  require_messages_database
  messages_live_check count -- messages chats
  take_live_number count
  local all="$live_number"
  messages_live_check count -- messages chats --name ""
  take_live_number count
  [ "$live_number" -eq "$all" ]
}

@test "chats --name with text no chat name holds echoes the filter and matches nothing" {
  require_messages_database
  messages_live_check matched apple-cli-test-no-such-chat -- messages chats --name apple-cli-test-no-such-chat
  take_live_number matched
  [ "$live_number" -eq 0 ]
}

# Whether any named chat holds the text comes from the unfiltered listing, so a filter that
# returns nothing fails. The checker composes names (NFC) before matching; a combining mark with
# no composed form still separates from its letter for the checker but not for the CLI, so the
# filtered count is bounded by, not equal to, that count.
@test "chats --name keeps the named chats whose name holds the text, and only those" {
  require_messages_database
  messages_live_check names e -- messages chats
  take_live_number names
  local expected="$live_number"
  [ "$expected" -gt 0 ] || skip "no named group chat holds the letter e"
  messages_live_check matched e -- messages chats --name e
  take_live_number matched
  [ "$live_number" -gt 0 ]
  [ "$live_number" -le "$expected" ]
}

@test "chats --limit 1 returns one chat when the listing holds any, and none otherwise" {
  require_messages_database
  messages_live_check count -- messages chats
  take_live_number count
  local all="$live_number"
  messages_live_check count -- messages chats --limit 1
  take_live_number count
  local expected=0
  [ "$all" -eq 0 ] || expected=1
  [ "$live_number" -eq "$expected" ]
}

@test "chats --text names last activity, and recent --direct-only --text exits 0" {
  require_messages_database
  run /bin/bash -c '"$@" >/dev/null 2>&1; echo "exit=$?"' _ "$BIN" messages recent --direct-only --text
  [ "$output" = "exit=0" ]
  # A message from a named group in the last 30 days gives its chat a last activity, so then no
  # activity at all is a regression, not a skip.
  messages_live_check named -- messages recent --hours 720 --limit 500
  take_live_number named
  local named="$live_number"
  messages_live_check activity -- messages chats
  take_live_number activity
  [ "$named" -eq 0 ] || [ "$live_number" -gt 0 ]
  [ "$live_number" -gt 0 ] || skip "no named group chat with a message"
  # grep -c reads to the end, so the CLI never takes a SIGPIPE that pipefail would report.
  run /bin/bash -c 'set -o pipefail; n=$("$@" 2>/dev/null | grep -c "last activity") && [ "$n" -gt 0 ] && echo ok' \
    _ "$BIN" messages chats --text
  [ "$output" = "ok" ]
}

# --- send --service and --file (pull request 4), dry-run only: nothing is sent ----------------

@test "send --dry-run reports service_requested auto, files and the auto service plan" {
  run "$BIN" messages send 2125550100 --message "smoke test" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"service_requested" : "auto"'
  echo "$output" | grep -q '"files" : \['
  echo "$output" | grep -q '"service_plan" : "iMessage→SMS auto"'
}

@test "send --service sms --dry-run reports the SMS-only plan" {
  run "$BIN" messages send 2125550100 --message "smoke test" --service sms --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"service_plan" : "SMS only"'
}

@test "send --service rcs → validation error naming the accepted services (exit 64)" {
  run "$BIN" messages send 2125550100 --message "smoke test" --service rcs --dry-run
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
  echo "$output" | grep -q 'auto, imessage, sms'
}

@test "send with neither --message nor --file → validation error (exit 64)" {
  run "$BIN" messages send 2125550100 --dry-run
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
  echo "$output" | grep -q 'nothing to send'
}

@test "send --file that does not exist → not_found (exit 65)" {
  run "$BIN" messages send 2125550100 --file "$BATS_TEST_TMPDIR/apple-cli-test-missing.txt" --dry-run
  [ "$status" -eq 65 ]
  echo "$output" | grep -q '"type" : "not_found"'
}

@test "send --file inside a credential folder is refused (exit 77)" {
  # A stand-in home keeps the operator's real credential folders out of the test.
  local home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home/.ssh"
  : > "$home/.ssh/id_ed25519"
  CFFIXED_USER_HOME="$home" run "$BIN" messages send 2125550100 --file "$home/.ssh/id_ed25519" --dry-run
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "send --file with a blocked extension → validation error (exit 64)" {
  : > "$BATS_TEST_TMPDIR/apple-cli-test.sh"
  run "$BIN" messages send 2125550100 --file "$BATS_TEST_TMPDIR/apple-cli-test.sh" --dry-run
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
  echo "$output" | grep -q 'is blocked (executable/script)'
}

@test "send --file naming a .app folder → not_found (exit 65); a plain x.app file → exit 64" {
  mkdir -p "$BATS_TEST_TMPDIR/apple-cli-test.app"
  run "$BIN" messages send 2125550100 --file "$BATS_TEST_TMPDIR/apple-cli-test.app" --dry-run
  [ "$status" -eq 65 ]
  echo "$output" | grep -q '"type" : "not_found"'
  : > "$BATS_TEST_TMPDIR/x.app"
  run "$BIN" messages send 2125550100 --file "$BATS_TEST_TMPDIR/x.app" --dry-run
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
  echo "$output" | grep -q 'is blocked (executable/script)'
}

@test "send --file --dry-run resolves a relative symbolic link to its absolute target" {
  echo "apple-cli-test" > "$BATS_TEST_TMPDIR/apple-cli-test.txt"
  ln -s apple-cli-test.txt "$BATS_TEST_TMPDIR/apple-cli-test-link.txt"
  cd "$BATS_TEST_TMPDIR"
  local out
  out="$("$BIN" messages send 2125550100 --file apple-cli-test-link.txt --dry-run 2>/dev/null)"
  printf '%s' "$out" | /usr/bin/python3 -c '
import json, os, sys
files = json.load(sys.stdin)["data"]["files"]
assert len(files) == 1
path = files[0]
assert os.path.isabs(path) and not os.path.islink(path)
assert os.path.basename(path) == "apple-cli-test.txt" and os.path.samefile(path, sys.argv[1])
' "$BATS_TEST_TMPDIR/apple-cli-test.txt"
}

@test "send --file --dry-run --text names the attachment count" {
  echo "apple-cli-test" > "$BATS_TEST_TMPDIR/apple-cli-test.txt"
  run "$BIN" messages send 2125550100 --file "$BATS_TEST_TMPDIR/apple-cli-test.txt" --dry-run --text
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '1 file(s)'
}

@test "send --service sms to an email address → validation error (exit 64)" {
  run "$BIN" messages send jane.doe@example.com --message "smoke test" --service sms --dry-run
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
  echo "$output" | grep -q 'SMS needs a phone number'
}

@test "sandboxed send --file is refused as a recipient miss, before any attachment check (exit 64)" {
  unset APPLE_TEST_MODE APPLE_TEST_RECIPIENTS
  run "$BIN" messages send 2125550100 --file /apple-cli-test-nonexistent --test-mode --dry-run
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"sandbox" : true'
  echo "$output" | grep -qi 'not in the test allowlist'
  ! echo "$output" | grep -qi 'attach'
}

@test "messages send --dry-run --text neutralizes ANSI (Q12 [17])" {
  msg=$(printf 'apple-cli-test \033[31mRED\033[0m')
  run "$BIN" messages send "+15555550123" --message "$msg" --dry-run --text
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '\^\[\[31mRED'
  ! printf '%s' "$output" | grep -q "$(printf '\033')"
}
