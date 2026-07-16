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

# --- parser-level error path (Apple.swift main() catch) ------------------------------------
# These exercise ArgumentParser errors that fail in parseAsRoot() and never reach a command
# body — the ONLY path with no in-body runGuarded envelope. They are the regression guard for
# the double-emit/exit-code-clobber bug and the argv-echo-onto-stdout security fix, neither of
# which any swift test can reach (main() calls Foundation.exit).

@test "root-level parse error emits a tool:apple validation envelope (exit 64)" {
  run "$BIN" --nonexistent-flag
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"tool" : "apple"'
  echo "$output" | grep -q '"type" : "validation_error"'
  echo "$output" | grep -q '"ok" : false'
}

@test "unknown subcommand emits a tool:apple validation envelope (exit 64)" {
  run "$BIN" nosuchdomain
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"tool" : "apple"'
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "parse error emits EXACTLY ONE envelope on stdout (no double-emit regression)" {
  # The double-emit bug printed two envelopes and clobbered the exit code (77/65 → 64).
  # Capture stdout ONLY, count envelopes, and require a single valid JSON object.
  # `|| true` so the exit-64 command substitution doesn't itself fail the bats test.
  local out; out="$("$BIN" --nonexistent-flag 2>/dev/null || true)"
  [ "$(printf '%s' "$out" | grep -c '"schema_version"')" -eq 1 ]
  printf '%s' "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['tool']=='apple' and d['ok'] is False and d['error']['type']=='validation_error'"
}

@test "parse-error detail (may echo argv) stays on stderr, NOT the stdout machine envelope" {
  # `version` takes no positional args, so an extra token is 'Unexpected argument <token>' —
  # a parse error whose ArgumentParser message echoes the token. The token must NOT land on
  # stdout (the agent-captured channel); the generic message must, with detail on stderr.
  local out
  out="$("$BIN" version SENTINEL_SECRET_XYZ 2>/tmp/apple_perr.$$ || true)"
  ! echo "$out" | grep -q "SENTINEL_SECRET_XYZ"        # generic on stdout
  echo "$out" | grep -q '"tool" : "apple"'
  echo "$out" | grep -q 'see stderr for details'
  grep -q "SENTINEL_SECRET_XYZ" "/tmp/apple_perr.$$"   # detail on stderr
  rm -f "/tmp/apple_perr.$$"
}
