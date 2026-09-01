#!/usr/bin/env bats

BATS_SUITE_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
REPO_ROOT="$(cd "$BATS_SUITE_ROOT/.." && pwd -P)"
HELPERS="$BATS_SUITE_ROOT/helpers"
# Local read-only capability tests for the `reminders` domain. Authorization diagnostics probe
# protected local paths and therefore cannot run in the hosted tier.

setup() {
  export PATH="$HOME/.swiftly/bin:$PATH"
  BIN="$(swift build --show-bin-path)/apple"
}

@test "reminders doctor reports authorization without prompting (exit 0)" {
  run "$BIN" reminders doctor
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"reminders_authorization"'
  echo "$output" | grep -q '"full_disk_access"'
  echo "$output" | grep -q '"tool" : "reminders"'
}
