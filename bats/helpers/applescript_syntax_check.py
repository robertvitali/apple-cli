#!/usr/bin/env python3
"""Compile-check every AppleScript embedded in MailScript.swift.

WHY THIS EXISTS: the AppleScript bodies are Swift string literals, so `swift build` and the
logic tier cannot see them at all — a syntax error only surfaces at runtime, on a LIVE Mail
mutation, which is exactly the path we cannot exercise in CI. `osacompile` parses without
executing, so this gives real coverage of the one tier that otherwise has none. It caught
`repeat with it in …` (`it` is an AppleScript reserved word) in review.

Scripts are assembled the same way MailScript assembles them: the per-op body, plus the shared
`findMsg` locator, plus whichever helper block that op appends.
"""
import re
import subprocess
import sys
import tempfile
import os
from typing import Optional

SRC = os.path.join(os.path.dirname(__file__), "..", "..",
                   "Sources", "MailKit", "Support", "MailScript.swift")

# Literals that MUST end up compile-checked, asserted at the end of main().
#
# WHY A LIST AT ALL: the catch-all loop in main() discovers scripts by the `*Script` NAME
# SUFFIX. That is INCIDENTAL coverage — rename a literal off the suffix, or let the
# `literals()` regex drift past it, and the script silently drops out of the run with no FAIL
# line at all. That is exactly how reply/forward stopped being compiled (review B1): the
# harness stayed green while covering less. Naming a script here converts "quietly uncovered"
# into a red run.
#
# WHY THESE TWO: the rule scripts carry destructive branches — createRuleScript arms
# `delete message` (the rule auto-trashes matching mail), updateRuleMetaScript resets and
# reapplies the whole action plan on an existing rule. No agent is permitted to live-verify a
# delete rule (AGENTS.md dangerous actions), and there is no logic-tier or bats coverage of
# AppleScript literals, so osacompile is the ONLY automated validation those branches get.
# Extend this set whenever a script gains a branch nobody may exercise by hand.
REQUIRED_SCRIPTS = {
    "createRuleScript",
    "updateRuleMetaScript",
}


def literals(src: str) -> dict[str, str]:
    """Every triple-quoted `static let NAME` body, keyed by NAME."""
    out = {}
    for m in re.finditer(r'static let (\w+)\s*=\s*"""\n(.*?)\n\s*"""', src, re.S):
        out.setdefault(m.group(1), m.group(2))
    return out


def concat_form(src: str, name: str, tail: str) -> Optional[str]:
    """Scripts built as head + guardAndSendTail + foot across three literals.

    THE JOIN IS READ FROM THE SOURCE, NEVER ASSUMED. Swift multiline literals carry NO
    trailing newline before the closing delimiter, so a bare `+ guardAndSendTail` join merges
    the head's last statement and the tail's first statement onto ONE line — invalid
    AppleScript.
    The previous version of this helper inserted the newline itself, which is exactly why a
    compile-breaking seam shipped with a green osacompile pin (review B2: the harness
    compiled a script Swift never emitted). Now the seam newline appears here if and ONLY if
    the Swift expression spells it (`+ "\\n" +`) — a reverted join assembles merged, fails
    osacompile, and turns this harness red.
    """
    m = re.search(
        r'static let %s\s*=\s*"""\n(.*?)\n\s*"""(\s*\+\s*"\\n")?\s*\+\s*guardAndSendTail\s*\+\s*"""\n(.*?)\n\s*"""'
        % re.escape(name), src, re.S)
    if not m:
        return None
    joiner = "\n" if m.group(2) else ""
    # The foot's captured body keeps its leading blank-line newline (faithful to Swift's
    # content), so no second joiner is synthesized either.
    return m.group(1) + joiner + tail + m.group(3)


def check(label: str, body: str) -> bool:
    with tempfile.NamedTemporaryFile("w", suffix=".applescript", delete=False) as f:
        f.write(body)
        path = f.name
    try:
        r = subprocess.run(["osacompile", "-o", "/dev/null", path],
                           capture_output=True, text=True)
        if r.returncode == 0:
            print(f"ok - {label}")
            return True
        print(f"FAIL - {label}\n{r.stderr.strip()}")
        return False
    finally:
        os.unlink(path)




def check_handlers_defined(label: str, body: str) -> bool:
    """Every `my <name>(` call in an assembled script must have an `on <name>(` definition.

    osacompile does NOT resolve handler calls at compile time, so a script that calls a handler
    nobody appended compiles clean, passes every test tier, and fails only against live Mail.
    This is the check that actually catches an assembly-list drift.
    """
    called = set(re.findall(r"\bmy ([A-Za-z_]\w*)\s*\(", body))
    defined = set(re.findall(r"^\s*on ([A-Za-z_]\w*)\s*\(", body, re.M))
    missing = sorted(called - defined)
    if missing:
        print(f"FAIL - {label}: calls undefined handler(s) {missing}")
        return False
    print(f"ok - {label} handlers all defined")
    return True


def check_argv_arity(src: str, lit: dict) -> bool:
    """Assert each script's highest `item N of argv` matches its Swift wrapper's argument count.

    WHY: the AppleScript reads positional argv; the Swift wrapper builds that array. If someone
    adds a parameter to one side only, `swift build` stays green, every logic test stays green,
    and the mismatch surfaces ONLY as a runtime failure against live Mail (`item 9 of argv` on an
    8-element list). This is the arity half of the same blind spot the compile check covers.

    Two argv shapes exist. A locator-based wrapper passes [candidate, account] first and then
    `extra`, so its expected arity is 2 + len(extra). A wrapper that addresses its target some
    other way (sendHtmlGui by window nonce, the rule scripts by index or by building a rule
    from scratch) has no locator prefix and states its total whole.
    """
    ok = True
    # (script literal, wrapper func name, TOTAL argv count the Swift wrapper passes).
    # The locator-based scripts pass [candidate, account] first and then their extras, so their
    # total is 2 + extras; scripts that build their own argv list (sendHtmlGui) state it whole.
    # (name, wrapper, total argv, slots deliberately never read in-script)
    expectations = [
        # nativeReplyScript/nativeReply (the plain `set content` reply) were DELETED by
        # decision-5 (2026-08-19): plain replies now route through nativeReplyHtmlScript with
        # the --body wrapped as an HTML fragment, so there is one reply script, below.
        # Slot 3 (body) is passed as "" and never read — the pasted HTML fragment IS the
        # body on this path; the slot is kept from the two-wrapper era's shared extra-args
        # ordering (a hole ANYWHERE ELSE is still a silent off-by-one).
        ("nativeReplyHtmlScript", "nativeReplyHtml", 2 + 10, {3}),  # …, mode, htmlFragmentPath (gap15)
        ("nativeForwardScript", "nativeForward", 2 + 8, set()),  # +body, to, cc, bcc, sender, allow, att, mbxHint
        # No locator prefix: htmlPath, subject, to, cc, bcc, att, sender, nonce. The nonce slot
        # is the gui-send window-binding marker — an arity drift here would make the script read
        # `item 8 of argv` off an empty list and fail only against live Mail, on the one path
        # that cannot be exercised autonomously (Accessibility + focus theft).
        ("sendHtmlGuiScript", "sendHtmlViaGui", 8, set()),
        # Rule scripts — no locator prefix: createRule builds a rule from scratch and
        # updateRuleMeta addresses one by 1-based index, so each states its argv total whole
        # (same shape as sendHtmlGuiScript above).
        # createRule passes: name, enabled, condBlob, actBlob, matchAll, moveTo, copyTo, flagIdx.
        ("createRuleScript", "createRule", 8, set()),
        # updateRuleMeta passes: idx, then three has/value pairs (name, enabled, matchAll), then
        # hasActs, actBlob, moveTo, copyTo, flagIdx. Every "has" flag is read next to its value,
        # so a drift that drops one shifts EVERY later slot — an off-by-one here would silently
        # patch the wrong field of a live Mail rule, on a path no agent may live-verify.
        ("updateRuleMetaScript", "updateRuleMeta", 12, set()),
    ]
    for name, func, want, allowed_holes in expectations:
        body = lit.get(name, "")
        used = [int(m) for m in re.findall(r"item (\d+) of argv", body)]
        high = max(used) if used else 0
        if high != want:
            print(f"FAIL - {name}: reads up to `item {high} of argv` but {func} passes {want}")
            ok = False
            continue
        # Every slot from 1..high must actually be read — a hole means a silent off-by-one.
        holes = sorted(set(range(1, high + 1)) - set(used) - allowed_holes)
        if holes:
            print(f"FAIL - {name}: argv slots never read: {holes}")
            ok = False
            continue
        print(f"ok - {name} argv arity {high} matches {func}")
    return ok


def main() -> int:
    src = open(SRC, encoding="utf-8").read()
    lit = literals(src)
    missing = [k for k in ("locator", "outboundGuardHelpers", "guardAndSendTail",
                           "mailboxPathResolver", "addressGuardHelpers", "hintedLocator") if k not in lit]
    if missing:
        print(f"FAIL - expected shared literals not found: {missing}")
        return 1
    locator = lit["locator"]
    ok = True
    # Every literal actually handed to osacompile below, for the REQUIRED_SCRIPTS assertion.
    # Recorded at the call sites rather than derived from `lit`, so it reflects what was
    # COMPILED, not merely what was parsed out of the source.
    compiled: set[str] = set()

    # Native compose scripts: body + guardAndSendTail + locator + outbound helpers.
    # nativeReplyHtmlScript is one of them — it shares the tail (review B1: it initially fell
    # through to the bare-locator loop, failed to compile there, and reply/forward were not
    # being compile-checked AT ALL because the seam regex no longer matched).
    for name in ("nativeReplyHtmlScript", "nativeForwardScript"):
        body = concat_form(src, name, lit["guardAndSendTail"])
        if body is None:
            print(f"FAIL - {name} not found in the expected concatenated form")
            ok = False
            continue
        # MUST mirror runLocated's runtime assembly exactly. osacompile resolves handler calls
        # at RUNTIME, so a missing handler still compiles clean here and fails only on a live
        # outbound send — the precise blind spot this harness exists to cover. When runLocated
        # gained mailboxPathResolver (findMsgHinted calls it) this list had to gain it too.
        assembled = (body + "\n" + locator + "\n" + lit["hintedLocator"]
                     + "\n" + lit["outboundGuardHelpers"]
                     + "\n" + lit["addressGuardHelpers"] + "\n" + lit["mailboxPathResolver"])
        ok &= check(name, assembled)
        ok &= check_handlers_defined(name, assembled)
        compiled.add(name)

    # Move scripts additionally append the nested-mailbox resolver.
    for name in ("moveScript", "gmailMoveScript"):
        assembled = lit[name] + "\n" + locator + "\n" + lit["mailboxPathResolver"]
        ok &= check(name, assembled)
        ok &= check_handlers_defined(name, assembled)
        compiled.add(name)

    # Every other findMsg-based mutation script compiles with just the locator.
    for name, body in sorted(lit.items()):
        if not name.endswith("Script"):
            continue
        if name in ("nativeReplyHtmlScript", "nativeForwardScript",
                    "moveScript", "gmailMoveScript"):
            continue
        extra = ("\n" + locator) if "my findMsg(" in body else ""
        # Scripts that dispatch an outgoing message get the shared address guard appended at
        # runtime, so compile them the same way (otherwise `my firstDisallowed` is undefined).
        if "my firstDisallowed(" in body or "my collectAddrs(" in body:
            extra += "\n" + lit["addressGuardHelpers"]
        ok &= check(name, body + extra)
        ok &= check_handlers_defined(name, body + extra)
        compiled.add(name)

    # Coverage assertion: the loops above find most scripts by name suffix, which is incidental
    # (see REQUIRED_SCRIPTS). A script that quietly stops being compiled must turn this red.
    never = sorted(REQUIRED_SCRIPTS - compiled)
    if never:
        print(f"FAIL - required scripts never compile-checked: {never}")
        ok = False
    else:
        print("ok - required scripts all compile-checked")

    ok &= check_argv_arity(src, lit)

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
