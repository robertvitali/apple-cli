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

SRC = os.path.join(os.path.dirname(__file__), "..", "..",
                   "Sources", "MailKit", "Support", "MailScript.swift")


def literals(src: str) -> dict[str, str]:
    """Every triple-quoted `static let NAME` body, keyed by NAME."""
    out = {}
    for m in re.finditer(r'static let (\w+)\s*=\s*"""\n(.*?)\n\s*"""', src, re.S):
        out.setdefault(m.group(1), m.group(2))
    return out


def concat_form(src: str, name: str, tail: str) -> str | None:
    """Scripts built as head + guardAndSendTail + foot across three literals."""
    m = re.search(
        r'static let %s\s*=\s*"""\n(.*?)\n\s*"""\s*\+\s*guardAndSendTail\s*\+\s*"""\n(.*?)\n\s*"""'
        % re.escape(name), src, re.S)
    return None if not m else m.group(1) + "\n" + tail + "\n" + m.group(2)


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

    The wrapper always passes [candidate, account] first, then `extra`, so
    expected arity == 2 + len(extra).
    """
    ok = True
    # (script literal, wrapper func name, TOTAL argv count the Swift wrapper passes).
    # The locator-based scripts pass [candidate, account] first and then their extras, so their
    # total is 2 + extras; scripts that build their own argv list (sendHtmlGui) state it whole.
    expectations = [
        ("nativeReplyScript", "nativeReply", 2 + 8),    # +body, replyAll, sender, allow, att, cc, bcc, mbxHint
        ("nativeForwardScript", "nativeForward", 2 + 8),  # +body, to, cc, bcc, sender, allow, att, mbxHint
        # No locator prefix: htmlPath, subject, to, cc, bcc, att, sender, nonce. The nonce slot
        # is the gui-send window-binding marker — an arity drift here would make the script read
        # `item 8 of argv` off an empty list and fail only against live Mail, on the one path
        # that cannot be exercised autonomously (Accessibility + focus theft).
        ("sendHtmlGuiScript", "sendHtmlViaGui", 8),
    ]
    for name, func, want in expectations:
        body = lit.get(name, "")
        used = [int(m) for m in re.findall(r"item (\d+) of argv", body)]
        high = max(used) if used else 0
        if high != want:
            print(f"FAIL - {name}: reads up to `item {high} of argv` but {func} passes {want}")
            ok = False
            continue
        # Every slot from 1..high must actually be read — a hole means a silent off-by-one.
        holes = sorted(set(range(1, high + 1)) - set(used))
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

    # Native compose scripts: body + guardAndSendTail + locator + outbound helpers.
    for name in ("nativeReplyScript", "nativeForwardScript"):
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

    # Move scripts additionally append the nested-mailbox resolver.
    for name in ("moveScript", "gmailMoveScript"):
        assembled = lit[name] + "\n" + locator + "\n" + lit["mailboxPathResolver"]
        ok &= check(name, assembled)
        ok &= check_handlers_defined(name, assembled)

    # Every other findMsg-based mutation script compiles with just the locator.
    for name, body in sorted(lit.items()):
        if not name.endswith("Script"):
            continue
        if name in ("nativeReplyScript", "nativeForwardScript", "moveScript", "gmailMoveScript"):
            continue
        extra = ("\n" + locator) if "my findMsg(" in body else ""
        # Scripts that dispatch an outgoing message get the shared address guard appended at
        # runtime, so compile them the same way (otherwise `my firstDisallowed` is undefined).
        if "my firstDisallowed(" in body or "my collectAddrs(" in body:
            extra += "\n" + lit["addressGuardHelpers"]
        ok &= check(name, body + extra)
        ok &= check_handlers_defined(name, body + extra)

    ok &= check_argv_arity(src, lit)

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
