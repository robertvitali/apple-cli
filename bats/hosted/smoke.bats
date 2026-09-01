#!/usr/bin/env bats

BATS_SUITE_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
REPO_ROOT="$(cd "$BATS_SUITE_ROOT/.." && pwd -P)"
HELPERS="$BATS_SUITE_ROOT/helpers"
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

# ── `tool: "<domain>"` on pre-dispatch failures (Q7-L3(a), the cross-domain central fix) ───────
# AGENTS.md and docs/DESIGN.md both specify `"tool": "<domain>"` on the ERROR envelope with no
# parse-failure carve-out. The binary previously emitted "apple" for every pre-dispatch failure,
# so a consumer routing on `tool` was misrouted exactly when something went wrong.

@test "a parse failure under a domain is attributed to that domain, not to apple" {
  for d in notes mail contacts messages calendar reminders; do
    local out; out="$("$BIN" "$d" --definitely-not-a-flag 2>/dev/null || true)"
    # Payload via argv, never spliced into the program text — a value containing a quote would
    # otherwise break out of the Python string literal. Inert with these constants, but this loop
    # is one "point it at a name list" away from arbitrary execution in CI.
    printf '%s' "$out" | python3 -c '
import sys, json
d = json.load(sys.stdin)
want, tool = sys.argv[1], d["tool"]
assert tool == want, f"{want}: envelope reported tool={tool!r}"
assert d["ok"] is False and d["error"]["type"] == "validation_error"
' "$d"
  done
}

@test "EVERY registered subcommand spelling attributes its own parse failure (list from the binary)" {
  # The class-sweep pin. The first version of `toolForParseFailure()` read
  # `configuration.commandName` through `compactMap`, which silently dropped any subcommand
  # without an explicit name and ignored `aliases` — review registered two such subcommands and
  # both DISPATCHED while the envelope said "apple". Fixing the one mechanism I had noticed and
  # calling the enumeration drift-proof is the same class-sweep failure this repo keeps hitting.
  #
  # So this test does NOT hardcode the six domains — it asks the binary. The list comes from
  # `--experimental-dump-help` (structured JSON) rather than the `--help` TEXT, because scraping
  # the text is wrong in two ways that review demonstrated against real ArgumentParser 1.8.2:
  # an aliased subcommand renders as `aliased, al` (HelpGenerator.swift:310-313), so a column
  # scrape yields the non-existent name `aliased,`; and a `shouldDisplay: false` subcommand is
  # omitted from the text entirely (HelpGenerator.swift:308) while still being dispatchable.
  # The structured dump carries commandName, aliases and shouldDisplay explicitly, so this covers
  # every registered spelling — which is what "forward pin" has to mean to be worth claiming.
  local dump names primaries
  dump="$("$BIN" --experimental-dump-help 2>/dev/null)"
  names="$(printf '%s' "$dump" | python3 -c '
import sys, json
for s in json.load(sys.stdin)["command"].get("subcommands", []):
    n = s.get("commandName")
    # `help` is injected by ArgumentParser itself and is NOT in Apple.configuration.subcommands,
    # so the helper cannot resolve it and `apple help --bogus` reports "apple". That is correct,
    # not a gap: `help` is not a DOMAIN, and the contract enumerates domains. Asserted separately
    # below so the exclusion is a checked claim rather than a silent filter.
    if n and n != "help":
        print(n)
        for a in (s.get("aliases") or []):
            print(a)
')"
  # The PRIMARY names — the closed set `tool` is allowed to take. Same payload, so it cannot
  # drift from the spellings above.
  primaries="$(printf '%s' "$dump" | python3 -c '
import sys, json
for s in json.load(sys.stdin)["command"].get("subcommands", []):
    n = s.get("commandName")
    if n and n != "help":
        print(n)
')"
  [ -n "$names" ]
  [ -n "$primaries" ]
  [ "$(printf '%s\n' "$names" | wc -l | tr -d ' ')" -ge 7 ]   # control: we actually parsed a list
  # `while read` rather than `for name in $names` — a commandName or alias containing whitespace
  # or a glob character would otherwise mis-iterate.
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    local out; out="$("$BIN" "$name" --definitely-not-a-flag 2>/dev/null || true)"
    printf '%s' "$out" | python3 -c '
import sys, json
d = json.load(sys.stdin)
spelling, primaries = sys.argv[1], set(sys.argv[2].split())
tool = d["tool"]
# MEMBERSHIP, not merely "not apple". The previous version asserted `tool != "apple"` under a
# comment claiming it checked for a registered primary name — a comment asserting a check the code
# did not perform. Review exploited exactly that gap: a caller that used the pinned helper only as
# a GATE and emitted raw argv made `apple ver --bogus` report tool="ver" (an ALIAS, absent from the
# domain enum) while this test and the source lint both stayed green.
assert d["ok"] is False, f"{spelling}: expected ok=false"
assert tool in primaries, \
    f"{spelling}: tool={tool!r} is not a registered primary name (expected one of {sorted(primaries)})"
' "$name" "$primaries"
  done <<< "$names"

  # The `help` exclusion above, asserted rather than assumed.
  run "$BIN" help --definitely-not-a-flag
  [ "$status" -eq 64 ]
  echo "$output" | grep -q '"tool" : "apple"'
}

@test "an argv[1] that names no subcommand stays apple and is never echoed into the envelope" {
  # The value lands on the stdout MACHINE channel, so it is matched against the registered
  # subcommand names — never reflected. Path-traversal and injection-shaped argv must not appear.
  for bad in nosuchdomain ../../etc/passwd 'x";DROP TABLE t;--' '$(whoami)' '--nonexistent-flag'; do
    local out; out="$("$BIN" "$bad" 2>/dev/null || true)"
    # Both assertions run INSIDE python, with the payload passed via argv rather than
    # interpolated into the script — the same rule AppleScriptRunner enforces for user text.
    # Interpolating it here would break the script on a payload containing a quote, which is
    # precisely the shape of one of the payloads above.
    printf '%s' "$out" | python3 -c '
import sys, json
bad = sys.argv[1]
raw = sys.stdin.read()
d = json.loads(raw)
tool = d["tool"]
assert tool == "apple", f"tool={tool!r} for argv[1]={bad!r}"

# The echo check runs over DECODED values, not the raw text. The previous version grepped the raw
# JSON, which is defeated by escaping: against a deliberately-leaking passthrough build,
# `../../etc/passwd` and `$(whoami)` are caught but `x";DROP TABLE t;--` is NOT, because JSON
# renders the quote as \" so the literal payload never appears.
#
# Precisely: the GREP LINE was blind for that payload — the TEST was not, because the parsed
# `tool == "apple"` assertion above it catches a passthrough for every payload (verified: a failing
# assert in this heredoc shape does exit 1 and does fail the bats test). So this is a weak
# assertion beside a sound one, not a vacuous test. It still matters, because the grep was the only
# thing covering fields OTHER than `tool` — a leak into `message` is the realistic one, and that is
# what the walk below now covers, for every payload regardless of how JSON chose to spell it.
def walk(v):
    if isinstance(v, str):  yield v
    elif isinstance(v, dict):
        for k, x in v.items():
            yield k
            yield from walk(x)
    elif isinstance(v, list):
        for x in v: yield from walk(x)

for s in walk(d):
    assert bad not in s, f"argv[1]={bad!r} leaked into the machine envelope as {s!r}"
' "$bad"
  done
}

@test "a bare invocation prints help and exits 0 — it emits NO envelope" {
  # This replaces a test that asserted "bare apple stays tool:apple". That was FALSE and the
  # test could not have caught it: it guarded on grep '"schema_version"' (quoted), but bare
  # `apple` prints help text where the token appears only UNQUOTED, so the body never ran and
  # the test passed in both the fixed and the reverted build. Assert what actually happens.
  # Capture the two streams SEPARATELY. bats' `run` merges stdout and stderr into `$output`
  # (measured: a process printing STDOUT_TOKEN and STDERR_TOKEN yields
  # `output=[STDOUT_TOKENSTDERR_TOKEN]`), so asserting "does not parse as JSON" over `$output`
  # actually asserts it over the CONCATENATION. That is weaker than the stated property and would
  # go vacuous under Q27 resolution (c) — moving help to stderr — which is precisely the open
  # question this test exists to pin. A test that stops testing when its own tracked question is
  # resolved is not a pin.
  local out err
  local errf; errf="$(mktemp)"
  out="$("$BIN" 2>"$errf")"; local st=$?
  err="$(cat "$errf")"; rm -f "$errf"
  [ "$st" -eq 0 ]
  printf '%s' "$out" | grep -q "SUBCOMMANDS:"
  # STDOUT specifically must not parse as an envelope.
  ! printf '%s' "$out" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null
  # and pin the 0-bytes-on-stderr fact Q27 measured, so resolution (c) has to update this test
  # deliberately rather than silently satisfying it.
  [ -z "$err" ]
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
  local perr; perr="$(mktemp)"
  out="$("$BIN" version SENTINEL_SECRET_XYZ 2>"$perr" || true)"
  # Assert over PARSED values, not raw bytes. A raw grep is only as strong as the payload's
  # transparency through JSON: this one survives solely because SENTINEL_SECRET_XYZ is [A-Z_] and
  # therefore encodes unchanged. One payload containing a quote, backslash or control character
  # and the assertion would pass against a leaking build — which is exactly what happened to the
  # sibling assertion on the hostile-argv test. This is the check the whole "argv detail must not
  # reach stdout" property rests on, so it should not depend on a lucky character class.
  printf '%s' "$out" | python3 -c '
import sys, json
bad = sys.argv[1]
def walk(v):
    if isinstance(v, str): yield v
    elif isinstance(v, dict):
        for k, x in v.items():
            yield k
            yield from walk(x)
    elif isinstance(v, list):
        for x in v: yield from walk(x)
for s in walk(json.load(sys.stdin)):
    assert bad not in s, f"operator argv leaked onto the stdout machine channel as {s!r}"
' SENTINEL_SECRET_XYZ
  # `version` IS a registered subcommand, so argv[1] resolves it and the envelope is attributed
  # to it per the `tool: "<domain>"` contract. This assertion said "apple" until that contract
  # violation was fixed; the SECURITY property this test exists for is the two greps around it.
  echo "$out" | grep -q '"tool" : "version"'
  echo "$out" | grep -q 'see stderr for details'
  grep -q "SENTINEL_SECRET_XYZ" "$perr"   # detail on stderr
  rm -f "$perr"
}

# ── Write-model v2 sweep invariant (docs/write-model-v2.md, rollout step 2) ─────────────────────
# v2 flips writes to execute-by-default, so a flagless write invocation in this suite — a safe
# preview under v1 — would become a LIVE MUTATION of the operator's real data at the core flip.
# The sandbox does not save it: fixtures are apple-cli-test-labeled and pass the label gate.
# Every write-verb invocation must carry an explicit --dry-run or --execute (or a truthy
# APPLE_DRY_RUN= env brake, or a `# flagless-on-purpose` marker). Two marker populations exist:
# PRE-FLIP markers pin a not-yet-flipped domain's v1 dry-run default (its flip commit migrates
# them), and PERMANENT default-pin markers lock a flipped domain's v2 per-surface defaults —
# those STAY (deleting them would silently unpin the trash-surface dry-run default). Enforced
# here so a flagless write is a suite FAILURE from the sweep commit onward.
#
# The fixture lines below assemble the `$BIN` token at runtime ('$BI' + 'N') so this file never
# contains a literal write invocation — otherwise the lint would count these fixtures as suite
# invocations and diff-mode would flag this very file's addition.

@test "lint: every bats write invocation carries an explicit flag (fail-closed floors)" {
  run python3 "$HELPERS/no_flagless_writes.py" "$BATS_SUITE_ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^OK: 0 flagless"
  # The lint self-checks logical-vs-physical coverage (a joiner regression fails closed);
  # here we additionally require a sane absolute volume so "scanned nothing" can't pass.
  local checked
  checked="$(echo "$output" | sed -n 's/.* checked \([0-9]*\) write invocation(s).*/\1/p')"
  [ -n "$checked" ] && [ "$checked" -ge 100 ]
  # PIN the marker count. flagless-on-purpose is the one sanctioned path to a flagless write
  # (besides the APPLE_DRY_RUN env-brake prefix, tested below), so its population is CAPPED
  # here: adding a marker requires editing this assertion — a reviewable event. (A net-neutral
  # marker SWAP holds the count without touching this line, but both halves of a swap are
  # visible line edits in the same diff; the cap's job is to stop growth.) Composition today:
  # **ZERO pre-flip markers — all six domains are now flipped** — plus 3 PERMANENT default-pin
  # markers (mail.bats ×2, notes.bats ×1) which lock the v2 per-surface defaults with deliberately
  # flagless invocations. 3 is therefore the FINAL count, and it should not change again unless a
  # domain adds a per-surface default-pin of its own.
  #
  # Messages shed the last pre-flip marker at its flip (2026-08-02), and did NOT replace it with a
  # permanent one — deliberately. `messages send` has no dry-run-by-default surface to pin, so a
  # flagless invocation there would attempt a REAL send to a real handle. Its posture is pinned in
  # the LOGIC tier instead ("Messages write-model v2 posture" in
  # Tests/MessagesKitTests/MessagesKitTests.swift), which needs no Messages.app access at all.
  # Two v1 send tests were DELETED rather than migrated for the same reason — see the safety
  # header in bats/messages.bats.
  #
  # Contacts (2) and Notes (2) shed their pre-flip markers at their own flips. Contacts added no
  # permanent default-pin, on purpose: a flagless write in either domain is a LIVE
  # mutation of the operator's real address book or notes under v2, so pinning the
  # execute-by-default posture with a deliberately flagless invocation is not safe the way it
  # is for Mail's trash surface (whose default IS dry-run). Contacts pins that posture in the
  # LOGIC tier instead — see the "Contacts write-model v2 posture" suite in
  # Tests/ContactsKitTests/WriteSafetyTests.swift, which asserts the same property with no
  # store access at all. Notes DID add one, for `delete-folder` alone: it is the single Notes
  # surface that previews by default (it destroys every note in the folder irreversibly), so the
  # flagless invocation that pins it is safe precisely because that default holds.
  local markers
  markers="$(echo "$output" | sed -n 's/.*, \([0-9]*\) marker(s)$/\1/p')"
  [ "$markers" -eq 3 ]
}

@test "lint: a truthy APPLE_DRY_RUN env-brake prefix exempts a flagless write; junk or a later command does not" {
  # v2 brake-behavior tests are DELIBERATELY flagless under `APPLE_DRY_RUN=1 …` — precedence
  # makes them dry-runs. The exemption must be exactly as narrow as the runtime semantics:
  # only the binary's truthy spellings, and only for the invocation the assignment prefixes.
  local T='$BI'; T="${T}N"
  mkdir -p "$BATS_TEST_TMPDIR/lintcase3"
  printf '%s\n' "APPLE_DRY_RUN=1 run \"$T\" mail send --to me@self.test --subject x --body y" \
    > "$BATS_TEST_TMPDIR/lintcase3/brake.bats"
  run python3 "$HELPERS/no_flagless_writes.py" "$BATS_TEST_TMPDIR/lintcase3"
  [ "$status" -eq 0 ]
  # A junk value is a runtime validation_error, NOT a brake — still a violation.
  printf '%s\n' "APPLE_DRY_RUN=off run \"$T\" mail send --to me@self.test --subject x --body y" \
    > "$BATS_TEST_TMPDIR/lintcase3/brake.bats"
  run python3 "$HELPERS/no_flagless_writes.py" "$BATS_TEST_TMPDIR/lintcase3"
  [ "$status" -eq 1 ]
  # `VAR=1 cmd1 && cmd2` does not export to cmd2 — the brake never exempts a later command.
  printf '%s\n' "APPLE_DRY_RUN=1 true && run \"$T\" mail send --to me@self.test --subject x --body y" \
    > "$BATS_TEST_TMPDIR/lintcase3/brake.bats"
  run python3 "$HELPERS/no_flagless_writes.py" "$BATS_TEST_TMPDIR/lintcase3"
  [ "$status" -eq 1 ]
}

@test "lint: a dynamic-verb write invocation without an explicit flag is a violation" {
  # `"$BIN" mail $sub` builds its verb at runtime — unclassifiable statically, so the lint
  # demands an explicit flag on the logical line. This shape hid four flagless bulk writes
  # from an earlier lint revision whose regex required a literal verb.
  local T='$BI'; T="${T}N"
  mkdir -p "$BATS_TEST_TMPDIR/lintcase"
  printf '%s\n' "run \"$T\" mail \$sub" > "$BATS_TEST_TMPDIR/lintcase/dyn.bats"
  run python3 "$HELPERS/no_flagless_writes.py" "$BATS_TEST_TMPDIR/lintcase"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "dynamic verb"
  # Flagged form passes.
  printf '%s\n' "run \"$T\" mail \$sub --dry-run" > "$BATS_TEST_TMPDIR/lintcase/dyn.bats"
  run python3 "$HELPERS/no_flagless_writes.py" "$BATS_TEST_TMPDIR/lintcase"
  [ "$status" -eq 0 ]
}

@test "lint --diff-mode catches an added --execute on a continuation line" {
  local T='$BI'; T="${T}N"
  run bash -c 'printf "%s\n" \
    "+++ b/bats/mail.bats" \
    "+  run \"$1\" mail send --to victim@example.com --subject x --body y \\" \
    "+    --mode send --execute --test-mode" \
    | python3 "$0/helpers/no_flagless_writes.py" --diff-mode' "$BATS_SUITE_ROOT" "$T"
  [ "$status" -eq 1 ]
}

@test "lint --diff-mode catches --execute added on a continuation under an UNCHANGED head line" {
  local T='$BI'; T="${T}N"
  run bash -c 'printf "%s\n" \
    "+++ b/bats/mail.bats" \
    "@@ -1,2 +1,3 @@" \
    "   run \"$1\" mail send --to victim@example.com --subject x --body y \\" \
    "+    --mode send --execute --test-mode" \
    | python3 "$0/helpers/no_flagless_writes.py" --diff-mode' "$BATS_SUITE_ROOT" "$T"
  [ "$status" -eq 1 ]
}

@test "lint --diff-mode catches an added --execute with unquoted \$BIN" {
  local T='$BI'; T="${T}N"
  run bash -c 'printf "%s\n" \
    "+++ b/bats/calendar.bats" \
    "+  run $1 calendar events create --title x --start 2026-07-20 --end 2026-07-20 --execute" \
    | python3 "$0/helpers/no_flagless_writes.py" --diff-mode' "$BATS_SUITE_ROOT" "$T"
  [ "$status" -eq 1 ]
}

@test "lint --diff-mode catches an added --execute on contacts vcard import" {
  local T='$BI'; T="${T}N"
  run bash -c 'printf "%s\n" \
    "+++ b/bats/contacts.bats" \
    "+  run \"$1\" contacts vcard import --vcard \"BEGIN:VCARD\" --execute" \
    | python3 "$0/helpers/no_flagless_writes.py" --diff-mode' "$BATS_SUITE_ROOT" "$T"
  [ "$status" -eq 1 ]
}

@test "lint --diff-mode is not masked by a preceding unbalanced-quote line" {
  local T='$BI'; T="${T}N"
  run bash -c 'printf "%s\n" \
    "+++ b/bats/mail.bats" \
    "+  run \"$1\" mail search --subject \"unbalanced" \
    "+  run \"$1\" mail mailboxes create --account iCloud --name X --execute" \
    | python3 "$0/helpers/no_flagless_writes.py" --diff-mode' "$BATS_SUITE_ROOT" "$T"
  [ "$status" -eq 1 ]
}

@test "lint: a pre-verb-option write invocation without an explicit flag is a violation" {
  # `"$BIN" mail --text send …` is a WORKING ArgumentParser form whose verb hides from the
  # literal-verb matcher — an earlier revision skipped it entirely (round-4 review HIGH).
  # It is treated as dynamic: flag required.
  local T='$BI'; T="${T}N"
  mkdir -p "$BATS_TEST_TMPDIR/lintcase2"
  printf '%s\n' "run \"$T\" mail --text send --to victim@example.com --subject x --body y" \
    > "$BATS_TEST_TMPDIR/lintcase2/opt.bats"
  run python3 "$HELPERS/no_flagless_writes.py" "$BATS_TEST_TMPDIR/lintcase2"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "dynamic verb"
  # Flagged form passes.
  printf '%s\n' "run \"$T\" mail --text --dry-run send --to me@self.test --subject x --body y" \
    > "$BATS_TEST_TMPDIR/lintcase2/opt.bats"
  run python3 "$HELPERS/no_flagless_writes.py" "$BATS_TEST_TMPDIR/lintcase2"
  [ "$status" -eq 0 ]
}

@test "lint --diff-mode catches --execute smuggled as a pre-verb option" {
  local T='$BI'; T="${T}N"
  run bash -c 'printf "%s\n" \
    "+++ b/bats/mail.bats" \
    "+  run \"$1\" mail --execute send --to victim@example.com --subject x --body y" \
    | python3 "$0/helpers/no_flagless_writes.py" --diff-mode' "$BATS_SUITE_ROOT" "$T"
  [ "$status" -eq 1 ]
}

@test "lint --diff-mode passes a clean --dry-run addition (control)" {
  local T='$BI'; T="${T}N"
  run bash -c 'printf "%s\n" \
    "+++ b/bats/mail.bats" \
    "+  run \"$1\" mail send --dry-run --to me@self.test --subject x --body y" \
    | python3 "$0/helpers/no_flagless_writes.py" --diff-mode' "$BATS_SUITE_ROOT" "$T"
  [ "$status" -eq 0 ]
}

# --- snapshot lifetime: the process must leave nothing behind -----------------------------
# THE regression gate for the temp-snapshot leak (COMPLETION-LOOP Q4d). Every other test of this
# feature exercises components in-process; only a real invocation reaches the `atexit` handler that
# replaces the never-running `deinit`, and only a real invocation reaches the reaper call site in
# `SnapshotSession.directory()`. Both lines are red-proofed: delete either and this test fails.
#
# TWO RULES THIS TEST OBEYS, both learned the hard way inside this same change:
#
# 1. IT NEVER DELETES SHARED STATE. An earlier draft ran `rm -rf "$TMPDIR/apple-cli-snapshots"`,
#    which would destroy the LIVE, LOCKED session directory of any concurrent `apple` — a developer
#    in another terminal, a parallel agent lane, a live-tier run. The entire point of the flock
#    design is that nothing can delete a live session; a test must not bypass it with a filesystem
#    remove. So this test only PLANTS uniquely-named entries and removes its own.
#    ($TMPDIR cannot be redirected to dodge this: `FileManager.temporaryDirectory` reads
#    `confstr(_CS_DARWIN_USER_TEMP_DIR)` and IGNORES the environment variable — verified directly.)
#
# 2. ITS LEAK PREDICATE IS THE LOCK, NOT A COUNT. Counting `s-` directories races a concurrent
#    `apple` in both directions. Instead: after a successful run, no session directory may exist
#    whose `.lock` is ACQUIRABLE. An acquirable lock means the owner is dead, so the directory is an
#    orphan — ours (atexit failed) or a stranger's (the reaper failed). A live process holds its
#    lock and is correctly ignored.

@test "lint: every COMPLETION-LOOP queue row keeps its 5 columns" {
  run python3 "$HELPERS/queue_table_wellformed.py" \
      "$REPO_ROOT/docs/COMPLETION-LOOP.md"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^OK: "
}

# Two table corruptions have shipped into this repo's records and BOTH were caught by review
# rather than tooling: a stray unescaped `|` that dropped a queue row's evidence column, and a
# prose paragraph fused onto a CHANGELOG table row, which GFM renders by DISCARDING the excess
# cell — silently deleting a documented fix. The source diff looks fine in both cases; only the
# rendered output loses content, which is exactly what eyeball review is worst at. The check
# above covers one table in one file; this covers every table in every record file.
@test "lint: every markdown table in the records is well-formed" {
  run python3 "$HELPERS/md_tables_wellformed.py" \
      "$REPO_ROOT/CHANGELOG.md" \
      "$REPO_ROOT/README.md" \
      "$REPO_ROOT/AGENTS.md" \
      "$REPO_ROOT/docs/COMPLETION-LOOP.md" \
      "$REPO_ROOT/docs/port-specs/notes.md" \
      "$REPO_ROOT/docs/port-specs/mail.md" \
      "$REPO_ROOT/docs/port-specs/messages.md" \
      "$REPO_ROOT/docs/port-specs/contacts.md" \
      "$REPO_ROOT/docs/port-specs/calendar-reminders.md"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^OK: "
}

# The subcommand-attribution test above is a FORWARD pin: it derives its list from
# `--experimental-dump-help`, so a new subcommand is covered automatically whichever mechanism
# named it — including an alias or a `shouldDisplay: false` entry, neither of which the `--help`
# TEXT renders in a scrapable form (see that test's own comment for the two failure modes). It cannot, however, fail
# on a REVERT — every subcommand registered today sets `commandName` explicitly and none declares
# an alias, so the buggy `compactMap { $0.configuration.commandName }` spelling is behaviourally
# identical right now. The bug it shipped (subcommands that dispatch while the envelope says
# "apple") is latent until someone adds a subcommand that leans on either of the other two naming
# mechanisms. A latent regression no runtime test can reach is exactly what a source lint is for —
# same situation, same remedy, as `quoted_not_found.py`.
#
# `--require-upstream` also pins the ASSUMPTION, not just our source: it asserts ArgumentParser's
# own matcher still dispatches on exactly the arms the allowlist unions, so a dependency bump that
# adds a third naming mechanism fails here instead of silently reintroducing the original bug in a
# file nobody edited. bats always runs post-build, so the checkout is present and its absence is a
# violation rather than a skip.
@test "lint: the parse-failure allowlist unions every arm ArgumentParser matches on" {
  # --upstream-root binds the lint's subject to the SAME scratch tree this suite built `BIN` from.
  # Without it the lint discovered a checkout by globbing `.build*`, and since `-` sorts before
  # `/`, any throwaway `.build-<label>/` outranked the real `.build/` — the subject actually
  # changed mid-review when a sibling process created one. A stale tree that still matches masks a
  # real dependency bump; an unrelated one red-flags a correct repo.
  run python3 "$HELPERS/subcommand_allowlist.py" --require-upstream \
      --upstream-root "$(swift build --show-bin-path)/../.." \
      "$REPO_ROOT/Sources/apple/Apple.swift"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^OK: "
  # the upstream check must have actually RUN, not been skipped into a pass
  ! echo "$output" | grep -q "^NOTE: skipping upstream-assumption check"
  # and it must name the tree it checked, so a silent retarget is visible in the log
  echo "$output" | grep -q "matcher agrees in: .*swift-argument-parser"
}

# Q12-A / review H3: write-model v2's `dry_run:false` execute-envelope rule is convention-only
# (the plain emit helpers stay callable with an execute payload). This source-lint gives it
# teeth: a bare read/domain payload on a plain emitNotesWrite/emitRemindersWrite/
# emitCalendarWrite is the drift that silently dropped the key across 27 sites.
@test "lint: execute-path envelopes route through the dry_run-stamping emit" {
  run python3 "$HELPERS/execute_envelope_lint.py"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok - plain write-emits"
  ! echo "$output" | grep -q "^FAIL"
}
