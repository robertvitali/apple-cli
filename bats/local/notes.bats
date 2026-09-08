#!/usr/bin/env bats

BATS_SUITE_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
REPO_ROOT="$(cd "$BATS_SUITE_ROOT/.." && pwd -P)"
HELPERS="$BATS_SUITE_ROOT/helpers"
load "$HELPERS/app_lifecycle"
# CLI smoke tests for the `notes` domain — invoke the built binary. No real note data is used.
# Most assertions avoid Apple automation. The one NOTES-H1 title-fallthrough assertion is an
# explicit `APPLE_LIVE_NOTES=1` live-tier opt-in and skips before its helper/AppleEvents otherwise.
# When opted in, it is a read-only synthetic miss, host-bounded, and gated only for narrowly
# recognized automation unavailability. Authorization and arbitrary failures remain red, and no
# successful live payload is emitted.
#
# WRITE-MODEL v2 (docs/write-model-v2.md): notes writes EXECUTE by default. That makes
# automation-freedom a SAFETY property here, not just a portability one — a case that reaches
# NotesScript() on a machine with Automation granted would mutate the operator's real notes.
# Every write case below therefore refuses (or previews) strictly BEFORE Notes.app is touched:
#
#   - `--dry-run` (or the `APPLE_DRY_RUN=1` env brake) — never runs a script;
#   - a SANDBOX label refusal computable from argv alone — `create`'s title, `update --new-title`,
#     `create-folder`/`delete-folder`'s name, `batch-move`'s destination folder;
#   - input-bounds and --format validation, which precede the gate entirely.
#
# The fetched-target label checks (update/append/delete/move by id-or-title, and the batch
# per-id sweep) resolve the target out of Notes.app, so they need Automation and belong to the
# live tier. A sandboxed preview discloses that it skipped them rather than implying they passed.

setup() {
  BIN="$(swift build --show-bin-path)/apple"
}

# A refusal test whose REGRESSION mode would create something has to prove nothing was created;
# otherwise a broken label gate writes first and asserts second. The probe names are synthetic
# ("Zz … Probe") so they are unlabeled (exercising the gate) yet impossible to confuse with a
# real note. Tolerates a machine without Automation, where the search itself cannot run.
assert_no_note_titled() {
  run "$BIN" notes search --query "$1"
  if [ "$status" -eq 0 ]; then
    echo "$output" | grep -q "$1" \
      && { echo "LEAKED: the refusal did not hold — a note titled '$1' now exists"; return 1; }
  fi
  return 0
}

assert_no_folder_named() {
  run "$BIN" notes folders
  if [ "$status" -eq 0 ]; then
    echo "$output" | grep -q "$1" \
      && { echo "LEAKED: the refusal did not hold — a folder named '$1' now exists"; return 1; }
  fi
  return 0
}

# A NOTES-H1 live-title probe may be skipped only when Notes automation is unavailable in one of
# the three ways the command maps explicitly, or when the portable host deadline returns its single
# timeout sentinel (124). Status 69 alone is insufficient: unrelated failures must stay red.
notes_h1_automation_unavailable() {
  local probe_status="$1"
  local probe_output="$2"

  [ "$probe_status" -eq 124 ] && return 0
  [ "$probe_status" -eq 69 ] || return 1
  case "$probe_output" in
    *'"type" : "upstream_error"'*) ;;
    *) return 1 ;;
  esac
  case "$probe_output" in
    *'"message" : "Notes.app timed out. It may be unresponsive or busy syncing; try again."'*) return 0 ;;
    *'"message" : "Lost connection to Notes.app. The app may have crashed or been restarted."'*) return 0 ;;
    *'"message" : "Notes.app is not responding. Try opening Notes.app manually."'*) return 0 ;;
    *) return 1 ;;
  esac
}

notes_h1_exact_not_found() {
  local probe_output="$1"
  local expected_message="$2"

  # Parse the envelope without echoing it: even a surprising success payload must stay private.
  # The Bash builtin is deliberate so live payload never appears in a child process argv.
  printf '%s' "$probe_output" | /usr/bin/python3 -c '
import json, sys
raw = sys.stdin.read()
decoder = json.JSONDecoder()
payload = None
for index, character in enumerate(raw):
    if character != "{":
        continue
    try:
        candidate, _ = decoder.raw_decode(raw[index:])
    except (json.JSONDecodeError, UnicodeDecodeError):
        continue
    if isinstance(candidate, dict):
        payload = candidate
        break
if payload is None:
    raise SystemExit(1)
error = payload.get("error") if isinstance(payload, dict) else None
matches = (
    isinstance(error, dict)
    and error.get("type") == "not_found"
    and error.get("message") == sys.argv[1]
)
raise SystemExit(0 if matches else 1)
' "$expected_message"
}

@test "sandboxed create of an UNLABELED title → validation_error (exit 64)" {
  run env APPLE_TEST_MODE=1 "$BIN" notes create "Zz Unlabeled Note Probe" --content "body" --execute
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
  echo "$output" | grep -q 'apple-cli-test'
  assert_no_note_titled "Zz Unlabeled Note Probe"
}

# The --test-mode FLAG engages the sandbox on its own in v2 (either signal alone).
@test "sandbox engages via --test-mode alone: unlabeled create still refused (exit 64)" {
  run "$BIN" notes create "Zz Unlabeled Flag Probe" --content "body" --execute --test-mode
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
  assert_no_note_titled "Zz Unlabeled Flag Probe"
}

# Argv-computable, so the SAME refusal fires on the preview path — a sandboxed dry-run must not
# report clean for a title the execute path rejects.
@test "sandboxed create-folder of an UNLABELED name → validation_error (exit 64)" {
  run env APPLE_TEST_MODE=1 "$BIN" notes create-folder "Zz Unlabeled Folder Probe" --execute
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
  assert_no_folder_named "Zz Unlabeled Folder Probe"
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

@test "get-link empty id falls through to title when Notes automation is available (NOTES-H1)" {
  [ "${APPLE_LIVE_NOTES:-0}" = "1" ] \
    || skip "set APPLE_LIVE_NOTES=1 to run live Notes automation"
  local probe_title="ZZZ-no-such-note-xyz"
  local expected_message="Note \"$probe_title\" not found. Use search-notes to find notes, then use the note's ID for reliable operations."
  # NotesScript.swift:31,45,55 define a 45s attempt timeout, two read attempts, and a 1000ms
  # backoff; lines 102 and 117-120 apply them. The 91s retried-transient upper bound fits this cap;
  # a coincidental title hit may need a second link lookup and intentionally reaches the 124 skip.
  local deadline=100

  # Exercise the exact path once under a host deadline. A coincidental success payload remains
  # captured only long enough to classify the result and is never emitted by this test.
  local xtrace_was_on=0
  case "$-" in
    *x*) xtrace_was_on=1; set +x ;;
  esac
  run /usr/bin/python3 "$HELPERS/bounded_exec.py" \
    --timeout "$deadline" --grace 2 -- "$BIN" notes get-link --id "" --title "$probe_title"
  local live_status="$status"
  local live_output="$output"
  output=""
  lines=()

  if notes_h1_automation_unavailable "$live_status" "$live_output"; then
    # Accepted opt-in-live residual: a host timeout cannot prove parity, but status 124 is the
    # bounded alternative to hanging the test runner indefinitely.
    [ "$live_status" -eq 124 ] \
      && skip "Notes automation unavailable: host invocation timed out"
    skip "Notes automation unavailable: recognized upstream error"
  fi
  [ "$live_status" -eq 65 ]
  notes_h1_exact_not_found "$live_output" "$expected_message"
  unset live_output
  [ "$xtrace_was_on" -eq 0 ] || set -x
}
