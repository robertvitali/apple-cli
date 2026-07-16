#!/usr/bin/env bash
# Live-tier e2e for the Mail WRITE surface — the repeatable form of the manual e2e run that
# validated the write paths. NOT for CI: needs a real Mac with Mail signed in + Full Disk Access
# + Automation permission. Every action is self-only + labeled `apple-cli-test…` + cleaned up.
#
# Usage:
#   APPLE_TEST_RECIPIENTS="you@example.com,you@example.com" bats/live/mail-writes.sh
#
# APPLE_TEST_RECIPIENTS MUST list ONLY your own address(es) — reply addresses the original
# sender, so the account's real send-address must be included. The safety gates (covered by the
# CI tests in Tests/MailKitTests/WriteSafetyTests.swift + bats/mail.bats) refuse anything else.
set -uo pipefail
cd "$(dirname "$0")/../.."
export PATH="$HOME/.swiftly/bin:$PATH"
export APPLE_TEST_MODE=1
: "${APPLE_TEST_RECIPIENTS:?set APPLE_TEST_RECIPIENTS to your own address(es), comma-separated}"
SELF="${APPLE_TEST_RECIPIENTS%%,*}"                     # first listed self-address = send target
BIN="$(swift build --show-bin-path)/apple"
TS="$(date +%Y%m%d-%H%M%S)"; SUBJ="apple-cli-test $TS live-writes"
pass=0; fail=0
trap 'pkill -9 -f osascript 2>/dev/null' EXIT           # never leave a hung Mail scan behind
jq() { python3 -c "import json,sys; d=json.load(sys.stdin); print(d$1)" 2>/dev/null; }
step() { # step "name" "expected-substring" <json-producing-cmd...>
  local name="$1" want="$2"; shift 2
  local out; out="$("$@" 2>/dev/null)"
  if printf '%s' "$out" | grep -q "$want"; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name — wanted '$want', got: $(printf '%s' "$out" | head -c 200)"; fail=$((fail+1)); fi
}

echo "== build =="; swift build >/dev/null 2>&1 || { echo "build failed"; exit 1; }

echo "== outbound: send a labeled self test email =="
step "send self" '"executed" : true' \
  timeout 40 "$BIN" mail send --to "$SELF" --subject "$SUBJ" --body "live e2e; safe to delete" --mode send --execute --test-mode

echo "== wait for the message to land in the index =="
ID=""; for _ in $(seq 1 8); do
  ID="$(timeout 20 "$BIN" mail search --subject "live-writes" --limit 5 2>/dev/null \
        | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next((str(m["id"]) for m in d.get("data",{}).get("messages",[]) if "'"$TS"'" in m["subject"]),""))')"
  [ -n "$ID" ] && break; osascript -e 'delay 5' >/dev/null 2>&1
done
[ -n "$ID" ] && echo "  found id=$ID" || { echo "  FAIL  message never indexed"; fail=$((fail+1)); }

if [ -n "$ID" ]; then
  echo "== message mutations (label-gated) =="
  step "flag"       '"applied"'        timeout 40 env APPLE_TEST_MODE=1 "$BIN" mail flag "$ID" --color blue --execute --test-mode
  step "mark read"  '"applied"'        timeout 40 env APPLE_TEST_MODE=1 "$BIN" mail mark "$ID" --read --execute --test-mode
  step "reply self" '"executed" : true' timeout 40 env APPLE_TEST_MODE=1 "$BIN" mail reply "$ID" --body "live reply" --mode send --execute --test-mode
  step "trash"      '"applied"'        timeout 40 env APPLE_TEST_MODE=1 "$BIN" mail delete "$ID" --execute --test-mode
fi

echo "== rules cycle (create → enable → disable → delete) =="
step "rule create"  '"executed" : true' timeout 30 env APPLE_TEST_MODE=1 "$BIN" mail rules create --name "apple-cli-test-live-rule" --condition "subject:contains:apple-cli-test-xyz" --action "mark_read=true" --execute --test-mode
RIDX="$(timeout 20 env APPLE_TEST_MODE=1 "$BIN" mail rules list 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next((str(r["index"]) for r in d["data"]["rules"] if r["name"]=="apple-cli-test-live-rule"),""))')"
if [ -n "$RIDX" ]; then
  step "rule enable"  '"executed" : true' timeout 20 env APPLE_TEST_MODE=1 "$BIN" mail rules enable  "$RIDX" --execute --test-mode
  step "rule disable" '"executed" : true' timeout 20 env APPLE_TEST_MODE=1 "$BIN" mail rules disable "$RIDX" --execute --test-mode
  step "rule delete"  '"executed" : true' timeout 20 env APPLE_TEST_MODE=1 "$BIN" mail rules delete  "$RIDX" --execute --test-mode
else echo "  FAIL  created rule not found"; fail=$((fail+1)); fi

echo "== draft cycle (create → list → delete) =="
step "draft create" '"executed" : true' timeout 30 env APPLE_TEST_MODE=1 "$BIN" mail draft create --subject "apple-cli-test-live-draft" --body x --to "$SELF" --execute --test-mode
step "draft delete" 'deleted 1 draft'   timeout 25 env APPLE_TEST_MODE=1 "$BIN" mail draft delete --subject "apple-cli-test-live-draft" --execute --test-mode

echo "== negative gates (must REFUSE) =="
step "refuse non-self send" '"safety_violation"' timeout 20 env APPLE_TEST_MODE=1 "$BIN" mail send --to nobody-else@example.com --subject "apple-cli-test x" --body y --mode send --execute --test-mode

echo
echo "== residue check: no apple-cli-test messages left in the active index =="
LEFT="$(timeout 20 "$BIN" mail search --subject "apple-cli-test" --limit 20 2>/dev/null | python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("data",{}).get("messages",[])))')"
echo "  active-index apple-cli-test messages: ${LEFT:-?} (want 0; copies in Trash are fine — never empty-trash)"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
