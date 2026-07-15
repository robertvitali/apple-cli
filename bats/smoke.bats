#!/usr/bin/env bats
# CLI smoke tests — logic tier, no Apple permissions required. Runs on a
# Command-Line-Tools-only machine (no full Xcode needed) because it only invokes
# the built binary.

setup() {
  BIN="$(swift build --show-bin-path)/apple"
}

@test "apple --version prints a version" {
  run "$BIN" --version
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "apple --help lists all six domains" {
  run "$BIN" --help
  [ "$status" -eq 0 ]
  for d in messages mail contacts notes calendar reminders; do
    echo "$output" | grep -q "$d"
  done
}

@test "stub domains emit a JSON envelope with schema_version and ok=false" {
  run "$BIN" messages
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '"schema_version"'
  echo "$output" | grep -q '"ok" : false'
  echo "$output" | grep -q '"tool" : "messages"'
}
