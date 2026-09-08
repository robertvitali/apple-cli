#!/usr/bin/env bats

BATS_SUITE_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
REPO_ROOT="$(cd "$BATS_SUITE_ROOT/.." && pwd -P)"
HELPERS="$BATS_SUITE_ROOT/helpers"
load "$HELPERS/app_lifecycle"
# Local Contacts capability tests. Refusal cases may query the real store only for an exact
# synthetic miss after the write is blocked; they never emit live values or perform a mutation.
# Do not run this tier on hosted or fork-reachable CI.
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
@test "not_found messages quote the identifier like the oracle's !r (CONTACTS-L2)" {
  # The ONLY case in this file that must reach the store, so it is the only one that can
  # break the header's "no Contacts TCC required / no prompting in CI" contract: not_found
  # exists only PAST the authorization gate (ContactsReadCommands.swift calls
  # requireAuthorization() BEFORE the notFound throw), so an unauthorized machine exits 77,
  # and a notDetermined one would pop the TCC dialog inside requestAccess(). `contacts auth`
  # reads authorizationStatus() directly and never prompts, so it is a safe probe: skip
  # unless access is already granted. Same tolerance as assert_no_contact_named above.
  run "$BIN" contacts auth
  echo "$output" | grep -qE '"status" : "(authorized|limited)"' \
    || skip "Contacts TCC not granted — not_found is unreachable without it"
  run "$BIN" contacts get "SOME-BOGUS-ID"
  [ "$status" -eq 65 ]
  echo "$output" | grep -q "No contact found with identifier 'SOME-BOGUS-ID'"
  run "$BIN" contacts groups members "BOGUS-GROUP:ABGroup"
  [ "$status" -eq 65 ]
  echo "$output" | grep -q "No group found with identifier 'BOGUS-GROUP:ABGroup'"
}
