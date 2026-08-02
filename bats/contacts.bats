#!/usr/bin/env bats
# CLI smoke tests for `apple contacts` — logic tier, no Contacts TCC required. Every
# case here resolves BEFORE the authorization gate (help / auth-status / input
# validation / the write-safety gate / dry-run), so it runs on a Command-Line-Tools-only
# machine and in CI without prompting. Live data-command parity is covered separately
# (see the run report), not here.
#
# WRITE-MODEL v2 (docs/write-model-v2.md): contacts writes EXECUTE by default. That makes
# TCC-freedom a SAFETY property here, not just a portability one — a case that reaches
# `ContactsStore()` on a TCC-granted machine would mutate the operator's real address book.
# So every write case below refuses (or previews) strictly BEFORE the store is touched:
#
#   - `--dry-run` (or the `APPLE_DRY_RUN=1` env brake) — never constructs the store;
#   - a SANDBOX label refusal computable from argv alone — create/groups-create names,
#     `groups rename`'s new name, and every `vcard import` card name (a static parse);
#   - the oracle-mirrored env gate on `delete` / `groups delete`.
#
# The fetched-target label checks (update / note / photo / groups add|remove, and the
# target side of rename/delete) are deliberately NOT covered here: they resolve the target
# out of the store, so exercising them needs TCC and belongs to the live tier. Their
# absence from a preview is asserted positively instead, via the `gate_note` disclosure.

setup() {
  BIN="$(swift build --show-bin-path)/apple"
}

# A refusal test whose REGRESSION mode would create something has to prove nothing was created.
# Otherwise a broken label gate leaves behind UNLABELED residue — worse than labeled residue,
# because nothing in the cleanup discipline can recognize it. The probe names below are
# deliberately synthetic ("Zz … Probe") so they are both unlabeled (exercising the gate) and
# impossible to confuse with a real address-book entry.
# Tolerates a machine without Contacts TCC, where the search itself cannot run.
assert_no_contact_named() {
  run "$BIN" contacts search --name "$1"
  if [ "$status" -eq 0 ]; then
    echo "$output" | grep -q '"count" : 0' \
      || { echo "LEAKED: the refusal did not hold — a contact named '$1' now exists"; return 1; }
  fi
}

assert_no_group_named() {
  run "$BIN" contacts groups list
  if [ "$status" -eq 0 ]; then
    ! echo "$output" | grep -q "\"name\" : \"$1\"" \
      || { echo "LEAKED: the refusal did not hold — a group named '$1' now exists"; return 1; }
  fi
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

# SANDBOX label refusals — computable from argv, so they fire before the store exists.
# (v1 pinned "--execute without test-mode → 77" here; that gate is lifted, so these now
# pin the restriction that REPLACED it: inside the sandbox, create only labeled data.)
@test "sandboxed create of an UNLABELED name → safety_violation (exit 77)" {
  run env APPLE_TEST_MODE=1 "$BIN" contacts create --first "Zz Unlabeled Probe" --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
  echo "$output" | grep -q '"ok" : false'
  echo "$output" | grep -q 'apple-cli-test'
  assert_no_contact_named "Zz Unlabeled Probe"
}

# The --test-mode FLAG engages the sandbox on its own in v2 (either signal alone).
@test "sandbox engages via --test-mode alone: unlabeled create still refused (exit 77)" {
  run "$BIN" contacts create --first "Zz Unlabeled Flag Probe" --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
  assert_no_contact_named "Zz Unlabeled Flag Probe"
}

@test "sandboxed groups create of an UNLABELED name → safety_violation (exit 77)" {
  run env APPLE_TEST_MODE=1 "$BIN" contacts groups create "Zz Unlabeled Group Probe" --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
  assert_no_group_named "Zz Unlabeled Group Probe"
}

# Golden-ish snapshot — synthetic labeled data only, no real PII.
@test "create --dry-run previews planned fields, mutates nothing" {
  run "$BIN" contacts create --dry-run --first "apple-cli-test Ada" --org "Acme"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"ok" : true'
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"operation" : "create_contact"'
  echo "$output" | grep -q '"given_name" : "apple-cli-test Ada"'
  echo "$output" | grep -q '"organization" : "Acme"'
}

@test "update --dry-run previews, requires a field" {
  run "$BIN" contacts update --dry-run "SOME-ID" --set given_name=apple-cli-test
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

# ── ORACLE-MIRRORED HARD GATE on the two deletes ─────────────────────────────────────
# apple-contacts-mcp refuses delete_contact (server.py:965) and delete_group (:1715)
# outside CONTACTS_TEST_MODE=true via require_test_mode_for (security.py:161). That gate
# is part of the behavior being replicated, so v2 KEEPS it unconditionally — and mirrors
# its ENV keying exactly. These two cases are the only v1 "→ 77" refusals that survive
# the flip unchanged.
@test "delete --execute without APPLE_TEST_MODE → safety_violation (exit 77)" {
  run "$BIN" contacts delete "SOME-ID" --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
  echo "$output" | grep -q 'APPLE_TEST_MODE=1'
}

@test "groups delete --execute without APPLE_TEST_MODE → safety_violation (exit 77)" {
  run "$BIN" contacts groups delete "GID" --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
  echo "$output" | grep -q 'APPLE_TEST_MODE=1'
}

# SECURITY-CRITICAL PIN. The oracle keys this gate to an ENVIRONMENT variable, so the
# mirror must too: a --test-mode FLAG lives in the agent's own argv, and if it satisfied
# the gate an agent could self-grant the one control the operator holds over an
# unconfirmable delete. --test-mode engages the sandbox (asserted above) and still leaves
# this refusal standing.
@test "the --test-mode FLAG does NOT satisfy the delete env gate (exit 77)" {
  run "$BIN" contacts delete "SOME-ID" --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
  echo "$output" | grep -q 'FLAG deliberately does NOT satisfy'
}

@test "the --test-mode FLAG does NOT satisfy the groups-delete env gate (exit 77)" {
  run "$BIN" contacts groups delete "GID" --execute --test-mode
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

# ── Sandbox label refusals that survive without a store read ──────────────────────────
# `groups rename`'s NEW name and every `vcard import` card name are pure-string checks,
# so v2 hoists them above the store: the sandboxed preview refuses exactly what the
# execute path refuses. (The v1 cases here pinned the lifted two-factor gate instead.)
@test "sandboxed groups rename to an UNLABELED new name → safety_violation (exit 77)" {
  run env APPLE_TEST_MODE=1 "$BIN" contacts groups rename "GID" "Zz Unlabeled Rename Probe" --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "sandboxed groups rename refuses the unlabeled new name in --dry-run too (exit 77)" {
  run env APPLE_TEST_MODE=1 "$BIN" contacts groups rename --dry-run "GID" "Zz Unlabeled Rename Probe"
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "sandboxed vcard import of an UNLABELED card → safety_violation (exit 77)" {
  run env APPLE_TEST_MODE=1 "$BIN" contacts vcard import --vcard "BEGIN:VCARD
VERSION:3.0
N:Test;A;;;
FN:A Test
END:VCARD" --execute
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

@test "sandboxed vcard import refuses the unlabeled card in --dry-run too (exit 77)" {
  run env APPLE_TEST_MODE=1 "$BIN" contacts vcard import --dry-run --vcard "BEGIN:VCARD
VERSION:3.0
N:Test;A;;;
FN:A Test
END:VCARD"
  [ "$status" -eq 77 ]
  echo "$output" | grep -q '"type" : "safety_violation"'
}

# ── PREVIEW HONESTY: gate_note discloses what a preview could NOT check ───────────────
# update / note / photo / groups add|remove have no argv-computable sandbox gate — their
# only one resolves the target out of the store. Rather than let a sandboxed preview imply
# the target passed a check that never ran, it says so. (These replace the v1 "→ 77" cases
# for the same commands: the gate they pinned no longer exists.)
@test "sandboxed update --dry-run discloses the unchecked fetched-target gate" {
  run env APPLE_TEST_MODE=1 "$BIN" contacts update --dry-run "SOME-ID" --set given_name=apple-cli-test
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"gate_note"'
  echo "$output" | grep -q 'did not run it'
}

@test "sandboxed note set --dry-run discloses the unchecked fetched-target gate" {
  run env APPLE_TEST_MODE=1 "$BIN" contacts note set --dry-run "SOME-ID" --note "apple-cli-test"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"gate_note"'
}

@test "sandboxed photo set --dry-run discloses the unchecked fetched-target gate" {
  run env APPLE_TEST_MODE=1 "$BIN" contacts photo set --dry-run "SOME-ID" --clear
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"gate_note"'
}

@test "sandboxed groups add --dry-run names BOTH unchecked targets" {
  run env APPLE_TEST_MODE=1 "$BIN" contacts groups add --dry-run "CID" "GID"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"gate_note"'
  echo "$output" | grep -q 'both the target contact and the target group'
}

@test "sandboxed groups remove --dry-run discloses the unchecked group gate" {
  run env APPLE_TEST_MODE=1 "$BIN" contacts groups remove --dry-run "CID" "GID"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"gate_note"'
}

# The disclosure is SANDBOX-SCOPED: outside the sandbox there is no label gate to miss,
# so an unsandboxed preview must not manufacture a warning.
@test "unsandboxed update --dry-run carries no gate_note" {
  run "$BIN" contacts update --dry-run "SOME-ID" --set given_name=x
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q '"gate_note"'
}

# A delete preview names the env gate that WILL refuse it, so --dry-run never reports
# clean for a call the execute path rejects.
@test "delete --dry-run names the unmet env gate in gate_note" {
  run "$BIN" contacts delete --dry-run "SOME-ID"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"operation" : "delete_contact"'
  echo "$output" | grep -q 'APPLE_TEST_MODE=1'
}

@test "delete --dry-run WITH the env gate granted drops that half of the note" {
  run env APPLE_TEST_MODE=1 "$BIN" contacts delete --dry-run "SOME-ID"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'only available with'
  # ...but the sandbox is now engaged, so the fetched-target disclosure remains.
  echo "$output" | grep -q 'did not run it'
}

# ── v2 envelope + precedence contract ─────────────────────────────────────────────────
@test "sandbox engagement is visible in the envelope; absent when unsandboxed" {
  run env APPLE_TEST_MODE=1 "$BIN" contacts create --dry-run --first "apple-cli-test Ada"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"sandbox" : true'
  run "$BIN" contacts create --dry-run --first "apple-cli-test Ada"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q '"sandbox"'
}

# These two pin the precedence chain itself, so the thing under test cannot also be the thing
# keeping them safe: if precedence regressed, a `create` would run and write a real contact
# BEFORE the assertion failed. They therefore use `update` against an id that does not exist —
# a regression then reaches the store and dies on not_found, provably mutating nothing, while
# still failing the test.
# --text is not part of the versioned contract, but a human reading it needs the sandbox
# indication as much as a machine reading the envelope does.
@test "--text write output shows the sandbox; omits it when unsandboxed" {
  run env APPLE_TEST_MODE=1 "$BIN" contacts create --text --dry-run --first "apple-cli-test Ada"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^sandbox: true'
  run "$BIN" contacts create --text --dry-run --first "apple-cli-test Ada"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'sandbox'
}

@test "APPLE_DRY_RUN=1 restores dry-run-by-default for a flagless write" {
  APPLE_DRY_RUN=1 run "$BIN" contacts update "NO-SUCH-ID-PRECEDENCE-PROBE" --set given_name=apple-cli-test
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"operation" : "update_contact"'
}

@test "--dry-run beats --execute (highest precedence)" {
  APPLE_DRY_RUN=1 run "$BIN" contacts update --dry-run --execute "NO-SUCH-ID-PRECEDENCE-PROBE" --set given_name=apple-cli-test
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
}

# ENV BRAKE fail-loud: an unrecognized spelling must refuse the command, never be guessed
# into "off" — the difference between a preview and a live mutation of a real address book.
@test "a junk APPLE_TEST_MODE refuses the write (exit 64), even with --dry-run" {
  run env APPLE_TEST_MODE=ture "$BIN" contacts create --dry-run --first "apple-cli-test Ada"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "a junk APPLE_DRY_RUN refuses the write (exit 64)" {
  run env APPLE_DRY_RUN=off "$BIN" contacts create --dry-run --first "apple-cli-test Ada"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

# Reads are unaffected by the sandbox (v2: it restricts write paths only).
@test "a read command is byte-identical with the sandbox on and off" {
  run "$BIN" contacts auth
  [ "$status" -eq 0 ]
  local plain="$output"
  run env APPLE_TEST_MODE=1 "$BIN" contacts auth
  [ "$status" -eq 0 ]
  [ "$output" = "$plain" ]
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
