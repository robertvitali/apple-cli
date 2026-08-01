#!/usr/bin/env bats
# Mail `move --gmail-mode` CLI smoke tests (Gmail copy+delete label semantics; parity with
# s-morgan move_messages(gmail_mode=True)). CI-safe only: dry-run previews + gate-equivalence
# checks. NO test asserts a live Mail mutation — the live copy+delete and the live 77-refusal
# are validated by the operator. Index-dependent cases skip when the Envelope Index is
# unreadable (CI), exactly like bats/mail.bats.

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

@test "mail move --gmail-mode without --execute previews (dry-run, gmail_mode true, exit 0 not 64)" {
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
  # empty match means Phase 1 never evaluates a target here, in CI or locally. What it locks:
  # (a) the old exit-64 'not yet wired' rejection is gone on the --execute path, and (b) the
  # gmail flag does not fork the command's outcome vs a plain move on identical input. The GATE
  # itself needs no gmail-specific test: the gmailMode branch lives INSIDE the same
  # executeMessageMutation closure as plain move (one shared Phase-1 gate, locked by the plain
  # move/mark/flag refusal tests), and the live copy+delete + gate pass was operator-validated
  # (iCloud: archive:1 inbox:0 trash:1; Gmail: verbs applied, server collapsed the dup).
  run "$BIN" mail move --match-subject apple-cli-nonexistent-zzz --to Archive --execute
  local normal_status=$status
  run "$BIN" mail move --match-subject apple-cli-nonexistent-zzz --to Archive --gmail-mode --execute
  local gmail_status=$status
  [ "$gmail_status" -eq "$normal_status" ]
  [ "$gmail_status" -ne 64 ]
}
