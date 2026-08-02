#!/usr/bin/env bats
# CLI smoke tests for the `notes` domain — invoke the built binary. No Apple automation and no
# real note data required: every assertion is an error path, a dry-run preview, or the read-only
# sync-status diagnostic, so nothing here depends on (or emits) real PII.
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

@test "notes --help lists the core subcommands" {
  run "$BIN" notes --help
  [ "$status" -eq 0 ]
  for c in get get-checklist get-metadata list search create update delete move \
           folders accounts attachments save-attachment batch-delete export stats \
           sync-status health doctor; do
    echo "$output" | grep -q "$c"
  done
}

@test "notes get-metadata with a bad id → validation error envelope, exit 64" {
  run "$BIN" notes get-metadata --id "bogus"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"schema_version" : 1'
  echo "$output" | grep -q '"tool" : "notes"'
  echo "$output" | grep -q '"ok" : false'
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "notes get-checklist with a bad id → validation error, exit 64" {
  run "$BIN" notes get-checklist --id "not-a-coredata-id"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "notes get with neither --id nor --title → validation error, exit 64" {
  run "$BIN" notes get
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "notes create --dry-run previews and writes nothing" {
  run "$BIN" notes create --dry-run "apple-cli-test smoke" --content "body"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q '"operation" : "create-note"'
}

# v1 pinned "--execute without APPLE_TEST_MODE is refused". That gate is lifted, and the same
# invocation now CREATES A REAL NOTE — so it is replaced by the restriction that took its place:
# inside the sandbox, create only labeled data. The probe title is deliberately synthetic and
# UNLABELED, so it exercises the gate and could never be mistaken for a real note.
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
@test "sandboxed create refuses the unlabeled title in --dry-run too (exit 64)" {
  run env APPLE_TEST_MODE=1 "$BIN" notes create --dry-run "Zz Unlabeled Note Probe" --content "body"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "sandboxed create-folder of an UNLABELED name → validation_error (exit 64)" {
  run env APPLE_TEST_MODE=1 "$BIN" notes create-folder "Zz Unlabeled Folder Probe" --execute
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
  assert_no_folder_named "Zz Unlabeled Folder Probe"
}

@test "sandboxed batch-move to an UNLABELED destination folder → validation_error (exit 64)" {
  run env APPLE_TEST_MODE=1 "$BIN" notes batch-move --execute --folder "Zz Unlabeled Folder Probe" --ids "x-coredata://A/ICNote/p1"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

# `move`'s DESTINATION is argv-supplied, so the sandbox must refuse a real folder on BOTH paths —
# batch-move always did this and single move never did.
@test "sandboxed move to an UNLABELED destination folder → validation_error (exit 64)" {
  run env APPLE_TEST_MODE=1 "$BIN" notes move --execute --id "x-coredata://A/ICNote/p1" --folder "Zz Unlabeled Folder Probe"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "sandboxed move refuses the unlabeled destination in --dry-run too (exit 64)" {
  run env APPLE_TEST_MODE=1 "$BIN" notes move --dry-run --id "x-coredata://A/ICNote/p1" --folder "Zz Unlabeled Folder Probe"
  [ "$status" -eq 64 ]
}

# --title addressing supplies the target name in argv, so the sandbox check is computable on the
# PREVIEW path too — and the preview must not claim it skipped a check it could have run.
@test "sandboxed --title delete refuses in --dry-run (argv-computable, no false excuse)" {
  run env APPLE_TEST_MODE=1 "$BIN" notes delete --dry-run --title "Zz A Real Looking Note"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "a sandboxed --title preview of a LABELED target claims no unchecked gate" {
  run env APPLE_TEST_MODE=1 "$BIN" notes delete --dry-run --title "apple-cli-test nope"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'did not run it'
}

# save-attachment writes to the FILESYSTEM and shipped with no --dry-run branch at all.
@test "save-attachment --dry-run previews and writes no file" {
  local dest="$BATS_TEST_TMPDIR/probe-attachment.png"
  run "$BIN" notes save-attachment --dry-run --note-id "x-coredata://A/ICNote/p1" --attachment-id "zz" --path "$dest"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  [ ! -e "$dest" ]
}

# ── CRITICAL regression guard: an empty folder specifier ───────────────────────────────
# `delete-folder ""` produced a BARE AppleScript `delete` inside `tell account …`, whose direct
# object binds to the ACCOUNT CONTAINER rather than a folder. v1 refused it only incidentally
# (the label gate rejected ""); the v2 lift removed that accident. The oracle is not vulnerable —
# its schema carries .min(1) — so this was a dropped oracle-mirrored input bound.
@test "an empty or separator-only folder name is refused everywhere (exit 64)" {
  for n in "" "/" "//"; do
    run "$BIN" notes delete-folder --dry-run "$n"
    [ "$status" -eq 64 ] || { echo "delete-folder '$n' dry-run did not refuse"; return 1; }
    run "$BIN" notes delete-folder --execute "$n"
    [ "$status" -eq 64 ] || { echo "delete-folder '$n' execute did not refuse"; return 1; }
    run "$BIN" notes create-folder --dry-run "$n"
    [ "$status" -eq 64 ] || { echo "create-folder '$n' did not refuse"; return 1; }
  done
  run "$BIN" notes move --dry-run --id "x-coredata://A/ICNote/p1" --folder ""
  [ "$status" -eq 64 ]
  run "$BIN" notes batch-move --dry-run --folder "" --ids "x-coredata://A/ICNote/p1"
  [ "$status" -eq 64 ]
  run "$BIN" notes create --dry-run "apple-cli-test t" --content b --folder ""
  [ "$status" -eq 64 ]
}

# PERMANENT default-pin (bats/smoke.bats caps the marker count). `delete-folder` is the ONE Notes
# surface that previews by default, because it destroys every note in the folder irreversibly —
# measured: the cascaded notes do NOT reach Recently Deleted. Nothing else would catch a silent
# flip of that default, and the invocation is safe precisely because the default holds.
@test "delete-folder PREVIEWS by default (per-surface default; every other write executes)" {
  run "$BIN" notes delete-folder "apple-cli-test nonexistent probe folder"  # flagless-on-purpose
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q 'EVERY NOTE IN IT'
}

# `create --folder` must label-check its destination inside the sandbox, exactly as move does.
@test "sandboxed create into an UNLABELED destination folder → validation_error (exit 64)" {
  run env APPLE_TEST_MODE=1 "$BIN" notes create --dry-run "apple-cli-test probe" --content b --folder "Zz Unlabeled Folder Probe"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

# save-attachment's path confinement is argv-computable, so preview and execute must agree.
@test "save-attachment refuses an out-of-roots path on BOTH paths (exit 64)" {
  run "$BIN" notes save-attachment --dry-run --note-id "x-coredata://A/ICNote/p1" --attachment-id z --path /etc/apple-cli-probe.png
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
  run "$BIN" notes save-attachment --execute --note-id "x-coredata://A/ICNote/p1" --attachment-id z --path /etc/apple-cli-probe.png
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
  [ ! -e /etc/apple-cli-probe.png ]
}

# ── v2 envelope + precedence contract ────────────────────────────────────────────────
@test "sandbox engagement is visible in the envelope; absent when unsandboxed" {
  run env APPLE_TEST_MODE=1 "$BIN" notes create --dry-run "apple-cli-test smoke" --content "b"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"sandbox" : true'
  run "$BIN" notes create --dry-run "apple-cli-test smoke" --content "b"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q '"sandbox"'
}

# A sandboxed preview of an id-addressed write says which check it could NOT run, instead of
# implying the target passed one.
@test "sandboxed update --dry-run discloses the unchecked fetched-target gate" {
  run env APPLE_TEST_MODE=1 "$BIN" notes update --dry-run --id "x-coredata://A/ICNote/p1" --new-content "apple-cli-test body"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
  echo "$output" | grep -q 'did not run it'
}

@test "unsandboxed update --dry-run makes no such claim" {
  run "$BIN" notes update --dry-run --id "x-coredata://A/ICNote/p1" --new-content "b"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'did not run it'
}

# Precedence pins must not rely on the behavior under test for their own safety: a regression
# would otherwise write before the assertion failed. `update` against a nonexistent id reaches
# the store and dies on not_found, so it provably mutates nothing either way.
@test "APPLE_DRY_RUN=1 restores dry-run-by-default for a flagless write" {
  APPLE_DRY_RUN=1 run "$BIN" notes update --id "x-coredata://A/ICNote/NOPE" --new-content "apple-cli-test body"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
}

@test "--dry-run beats --execute (highest precedence)" {
  APPLE_DRY_RUN=1 run "$BIN" notes update --dry-run --execute --id "x-coredata://A/ICNote/NOPE" --new-content "apple-cli-test body"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
}

# Fail-loud env parsing: an unrecognized spelling must refuse, never be guessed into "off".
@test "a junk APPLE_TEST_MODE refuses the write (exit 64), even with --dry-run" {
  run env APPLE_TEST_MODE=ture "$BIN" notes create --dry-run "apple-cli-test smoke" --content "b"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "a junk APPLE_DRY_RUN refuses the write (exit 64)" {
  run env APPLE_DRY_RUN=off "$BIN" notes create --dry-run "apple-cli-test smoke" --content "b"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "notes delete --dry-run previews and deletes nothing" {
  run "$BIN" notes delete --dry-run --id "x-coredata://ABC/ICNote/p1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"dry_run" : true'
}

@test "notes create with an invalid --format → validation error, exit 64" {
  run env APPLE_TEST_MODE=1 "$BIN" notes create "Zz Unlabeled Format Probe" --content "b" --format xml --execute
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
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

@test "notes batch-delete with no ids → validation error, exit 64" {
  run "$BIN" notes batch-delete --dry-run --ids
  [ "$status" -eq 64 ]
}

@test "notes create with an over-length title → validation error, exit 64 (input-bounds parity)" {
  # Bounds are checked before the dry-run/execute gate, mirroring the MCP's zod input validation.
  local long_title="apple-cli-test $(printf 'x%.0s' {1..2001})"
  run "$BIN" notes create --dry-run "$long_title" --content "b"
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"type" : "validation_error"'
}

@test "exit-code matrix: usage=64 for bad flags, well-formed envelope on the error path" {
  run "$BIN" notes get-checklist   # missing required --id
  [ "$status" -eq 64 ]
  run "$BIN" notes move --dry-run --id "x-coredata://A/ICNote/p1"   # missing required --folder
  [ "$status" -eq 64 ]
}

@test "every leaf subcommand --help exits 0 with non-empty output" {
  # Guards against a local @Option/@Flag whose long name collides with GlobalOptions
  # (--text/--dry-run/--execute/--test-mode): ArgumentParser rejects the dupe at PARSE time,
  # so that subcommand's --help exits 1 with empty stdout and the tool is silently 100% dead
  # while build + logic tests stay green. This asserts none of the 35 are dead.
  local subs=(get get-plaintext get-markdown get-by-id get-details get-metadata get-checklist \
    list search selected create update append delete move folders create-folder delete-folder \
    accounts default-location shared attachments save-attachment fetch-attachment show-attachment \
    batch-delete batch-move export stats sync-status health doctor show-note show-folder show-account)
  for s in "${subs[@]}"; do
    run "$BIN" notes "$s" --help
    [ "$status" -eq 0 ] || { echo "DEAD subcommand: notes $s (exit $status)"; false; }
    [ -n "$output" ] || { echo "EMPTY --help: notes $s"; false; }
  done
}

@test "golden: bad-id metadata error envelope is byte-stable" {
  run "$BIN" notes get-metadata --id "bogus"
  expected='{
  "error" : {
    "message" : "Invalid note ID format: \"bogus\". Expected format: x-coredata://UUID/ICNote/pNNN",
    "type" : "validation_error"
  },
  "ok" : false,
  "schema_version" : 1,
  "tool" : "notes"
}'
  [ "$output" = "$expected" ]
}
