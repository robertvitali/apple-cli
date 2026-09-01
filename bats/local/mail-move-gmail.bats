#!/usr/bin/env bats

BATS_SUITE_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
REPO_ROOT="$(cd "$BATS_SUITE_ROOT/.." && pwd -P)"
HELPERS="$BATS_SUITE_ROOT/helpers"
# Mail `move --gmail-mode` CLI smoke tests (Gmail copy+delete label semantics; parity with
# s-morgan move_messages(gmail_mode=True)). Local-only: dry-run previews + flag-acceptance
# equivalence, with the --execute case run SANDBOXED (write-model v2: unsandboxed --execute
# is a real mutation path, so the sandbox label gate is the backstop when a filter ever
# matches). NO test asserts a live Mail mutation — the live copy+delete was validated by the
# operator. Index-dependent cases skip when the Envelope Index is unreadable.

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

@test "mail move --gmail-mode --dry-run previews (gmail_mode true, exit 0 not 64)" {
  require_index
  # The flag is accepted now (the old 'not yet wired' exit-64 rejection is GONE): a dry-run with
  # --gmail-mode previews like any move and carries gmail_mode in the detail. No Mail mutation.
  run "$BIN" mail move --dry-run --match-subject apple-cli-nonexistent-zzz --to Archive --gmail-mode
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"gmail_mode" : "true"'
  echo "$output" | grep -q '"dry_run" : true'
}

@test "mail move --gmail-mode --execute routes like a normal move (flag-acceptance equivalence; never the old exit 64)" {
  require_index
  # HONEST SCOPE (review finding): this is a FLAG-ACCEPTANCE smoke, not a gate exercise — the
  # zero-match filter means Phase 1 never evaluates a target here, in CI or locally. What it
  # locks: (a) the old exit-64 'not yet wired' rejection is gone on the --execute path, and
  # (b) the gmail flag does not fork the command's outcome vs a plain move on identical input.
  # SANDBOXED (v2 migration, review-caught): under write-model v2 an unsandboxed --execute is
  # a real mutation path with no label gate, so the nonexistent-subject filter would be the
  # ONLY protection; inside the sandbox the per-target label gate is the backstop again. The
  # gmailMode branch lives INSIDE the same executeMessageMutation closure as plain move (one
  # shared Phase-1 gate), and the live copy+delete + gate pass was operator-validated
  # (iCloud: archive:1 inbox:0 trash:1; Gmail: verbs applied, server collapsed the dup).
  APPLE_TEST_MODE=1 run "$BIN" mail move --match-subject apple-cli-nonexistent-zzz --to Archive --execute --test-mode
  local normal_status=$status
  APPLE_TEST_MODE=1 run "$BIN" mail move --match-subject apple-cli-nonexistent-zzz --to Archive --gmail-mode --execute --test-mode
  local gmail_status=$status
  [ "$gmail_status" -eq "$normal_status" ]
  [ "$gmail_status" -ne 64 ]
}
