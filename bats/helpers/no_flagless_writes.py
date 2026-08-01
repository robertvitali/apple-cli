#!/usr/bin/env python3
"""Lint: every write-verb CLI invocation in the bats suite must carry an explicit
--dry-run or --execute (write-model v2, rollout step 2 — docs/write-model-v2.md).

Why this exists: v2 flips writes to execute-by-default. A flagless write invocation in a
test was a safe preview under v1 and becomes a LIVE MUTATION of the operator's real data
under v2 — and engaging the sandbox does not save it, because test fixtures are
apple-cli-test-labeled and pass the label gate. Explicit flags are the only safe contract.

The command tables below were verified against the BUILT BINARY's --help tree (not guessed):
run `apple <domain> --help` / `apple <domain> <container> --help` when touching them. The
review checklist for any new write command includes adding its verb here.

LOGICAL LINES. Invocations are matched on logical lines assembled by a shell-quote state
machine: a physical line continues into the next when it ends inside an open single- or
double-quoted string, or with an unescaped backslash outside single quotes. Scanning stops
at an unquoted comment (`#` at a word boundary — start, whitespace, or after ;|&): quotes
inside comments are prose, not syntax. Not modeled (verified absent from the suite; keep it
that way): heredoc bodies, $'ANSI-C' quoting.

EVERY invocation on a logical line is checked (finditer, not first-match), each judged on
its own command portion: from its match to the next invocation or the comment. `--help`
must appear as a bare token to exempt a line (a quoted string mentioning --help does not).

DYNAMIC INVOCATIONS. `"$BIN" <domain> $var ...` builds its verb at runtime, so it cannot be
classified read-vs-write statically. Any such invocation MUST carry an explicit --dry-run
or --execute on its logical line — flagless-dynamic is a violation, full stop (this exact
shape hid four flagless bulk Mail writes from an earlier revision whose regex required a
literal verb). A pre-verb option (`"$BIN" mail --text send …`) is treated the same way.
Known limit: an invocation hiding the DOMAIN token too (`"$BIN" $cmd`) is invisible to a
static lint. ONE such site exists — calendar.bats:27 `run $BIN $leaf --help`, safe because
every loop value is a --help probe — do not add another.

SELF-CHECK (fail-closed): the logically-checked counts (classified + dynamic) must each be
>= the same counts taken over raw physical lines. This guards the LINE JOINER — a joiner
regression that swallows regions cannot report a clean suite. It deliberately does NOT
guard the matcher (both sides share the regexes); the dynamic-invocation rule above plus
the verified-against-binary tables are the matcher's defenses. Zero files or zero matches
also fails. checked > physical prints a warning (an over-count can offset a future miss).

MARKER. A logical line whose test deliberately pins the v1 flagless default may carry
`# flagless-on-purpose` on its FIRST physical line. Tree mode reports and counts markers
without failing; bats/smoke.bats pins the exact count as a CAP on the marked population
(any new marker forces an edit there; a net-neutral marker swap keeps the count but both
halves are visible line edits in the same diff). The v2 core flip MUST remove every marker.

Two modes:

  Tree mode (default):    python3 bats/helpers/no_flagless_writes.py [bats-dir]
    Scans every non-live .bats file; exit 1 listing any flagless write invocation.

  Diff mode:              git diff ... | python3 bats/helpers/no_flagless_writes.py --diff-mode
    Reads a unified diff on stdin; exit 1 if an ADDED (or added-onto) write invocation
    carries --execute. Hunks are reassembled from context + added lines, so --execute
    added on a continuation line is caught even when the invocation's head line is
    unchanged context. The sweep invariant is "flagless becomes --dry-run, ALWAYS".
    Files under a live/ path segment are exempt, mirroring tree mode. This mode is a
    SWEEP-TIME tool, deliberately not a blanket CI gate (ordinary development adds
    legitimate --execute tests); its correctness is regression-tested in bats/smoke.bats.
"""
import re
import sys
from pathlib import Path

# Write-shaped second tokens per domain (verified against the binary's --help tree).
# `mail export` writes .eml files; `notes export` emits to stdout (a read) and is absent.
WRITE_VERBS = {
    "mail": {"send", "reply", "forward", "draft", "draft-rich", "move", "mark", "flag",
             "delete", "trash", "rules", "templates", "mailboxes", "attachments", "export"},
    "notes": {"create", "update", "append", "delete", "move", "batch-delete", "batch-move",
              "create-folder", "delete-folder", "save-attachment"},
    "contacts": {"create", "update", "delete", "groups", "note", "photo", "vcard"},
    "calendar": {"events", "calendars"},
    "reminders": {"tasks", "lists", "subtasks"},
    "messages": {"send"},
}

# (domain, container, leaf) combos that are READS despite a write-shaped second token.
# Leaf verbs verified against each container's --help ("mail draft" is action-positional,
# its `list` action is the read). `contacts vcard export` is read-by-default and treated as
# a read; it writes a LOCAL file only when --out is passed (never user data), and sweeping
# it would flip its payload-emitting default.
READ_EXCEPTIONS = {
    ("mail", "rules", "list"),
    ("mail", "templates", "list"), ("mail", "templates", "get"),
    ("mail", "templates", "render"),
    ("mail", "mailboxes", "list"), ("mail", "attachments", "list"),
    ("mail", "draft", "list"),
    ("contacts", "groups", "list"), ("contacts", "groups", "members"),
    ("contacts", "note", "get"), ("contacts", "photo", "get"),
    ("contacts", "vcard", "export"),
    ("calendar", "events", "read"),
    ("calendar", "calendars", "list"),
    ("reminders", "tasks", "read"), ("reminders", "lists", "read"),
    ("reminders", "subtasks", "read"),
}

MARKER = "# flagless-on-purpose"

DOMAINS = "mail|notes|contacts|calendar|reminders|messages"
# "$BIN" or bare $BIN; verbs are [a-z][a-z-]* so option tokens (--to) can never bind as
# the sub/leaf group.
INVOKE = re.compile(rf'"?\$BIN"?\s+({DOMAINS})\s+([a-z][a-z-]*)(?:\s+([a-z][a-z-]*))?')
# Coarse shape: $BIN + domain + ANY next token. Where INVOKE does not also match, the verb
# is dynamic (a $variable, quote, or substitution) — see DYNAMIC INVOCATIONS above.
COARSE = re.compile(rf'"?\$BIN"?\s+({DOMAINS})\s+(\S+)')


def scan_quote_state(text, in_single=False, in_double=False):
    """Walk shell quoting through text. Returns (in_single, in_double, ends_with_continuation,
    comment_pos): comment_pos is the index of the first unquoted `#` starting a comment
    (at start, after whitespace, or after ;|&), or -1. Scanning STOPS at the comment —
    quotes and apostrophes inside a shell comment ("don't") are prose, not syntax, and a
    trailing backslash inside a comment does not continue the line."""
    escape = False
    comment_pos = -1
    prev_boundary = True
    for i, ch in enumerate(text):
        if escape:
            escape = False
            prev_boundary = False
            continue
        if in_single:
            if ch == "'":
                in_single = False
            prev_boundary = False
            continue
        if ch == "\\":
            escape = True
            prev_boundary = False
            continue
        if in_double:
            if ch == '"':
                in_double = False
            prev_boundary = False
            continue
        if ch == "'":
            in_single = True
            prev_boundary = False
            continue
        if ch == '"':
            in_double = True
            prev_boundary = False
            continue
        if ch == "#" and prev_boundary:
            comment_pos = i
            return in_single, in_double, False, comment_pos
        prev_boundary = ch in " \t;|&"
    return in_single, in_double, escape, comment_pos


def logical_lines(physical):
    """Join physical lines into shell logical lines. Yields (first_lineno_1based,
    first_physical_line, joined_text)."""
    i, n = 0, len(physical)
    while i < n:
        start = i
        joined = physical[i]
        in_s, in_d, cont, _ = scan_quote_state(joined)
        while (in_s or in_d or cont) and i + 1 < n:
            i += 1
            if cont and not (in_s or in_d):
                joined = joined[:-1] + " " + physical[i].strip()
            else:
                joined = joined + " " + physical[i].strip() if not (in_s or in_d) \
                    else joined + " " + physical[i]
            in_s, in_d, cont, _ = scan_quote_state(joined)
        yield (start + 1, physical[start], joined)
        i += 1


def classify(domain, sub, subsub):
    if sub not in WRITE_VERBS.get(domain, set()):
        return False
    if (domain, sub, subsub) in READ_EXCEPTIONS:
        return False
    return True


def has_bare_token(portion, token):
    return token in portion.split()


def invocations(logical):
    """All invocation occurrences on a logical line: list of (kind, match, portion) where
    kind is 'write' (classified write), or 'dynamic' (verb not statically classifiable —
    a $variable or a pre-verb option; must be explicitly flagged). Literal-verb reads and
    --help probes are omitted; a DYNAMIC read is NOT omitted — fail-closed, it needs a
    flag like any other dynamic invocation."""
    stripped = logical.strip()
    if stripped.startswith("#"):
        return []
    _, _, _, comment_pos = scan_quote_state(logical)
    coarse = [m for m in COARSE.finditer(logical)
              if comment_pos < 0 or m.start() < comment_pos]
    out = []
    for k, m in enumerate(coarse):
        end = coarse[k + 1].start() if k + 1 < len(coarse) else len(logical)
        if 0 <= comment_pos < end:
            end = comment_pos
        portion = logical[m.start():end]
        if has_bare_token(portion, "--help"):
            continue
        im = INVOKE.match(logical, m.start())
        if im:
            if classify(im.group(1), im.group(2), im.group(3)):
                out.append(("write", im, portion))
            continue
        # Everything else — verb in a $variable, OR a pre-verb option (`"$BIN" mail --text
        # send …`, a working ArgumentParser form that hides the verb from INVOKE) — is
        # DYNAMIC: unclassifiable statically, so it must carry an explicit flag. Never skip
        # these; a skip here is regex-symmetric with the floor and hides flagless writes
        # from both (a round-4 review proved the option form reachable against the binary).
        # The seven real bare-domain `--help` probes are exempted by the token check above.
        out.append(("dynamic", m, portion))
    return out


def physical_counts(physical):
    """(write, dynamic) occurrence counts over raw physical lines — the joiner-independent
    floor. Comment-aware with the same rule as the logical scan."""
    w = d = 0
    for line in physical:
        for kind, _m, _p in invocations(line):
            if kind == "write":
                w += 1
            else:
                d += 1
    return w, d


def check_tree(root: Path):
    bad, markers = [], []
    files = checked_w = checked_d = phys_w = phys_d = 0
    for f in sorted(root.rglob("*.bats")):
        # The live tier drives real writes deliberately and manages its own flags/cleanup.
        if "live" in f.parts:
            continue
        files += 1
        physical = f.read_text().splitlines()
        pw, pd = physical_counts(physical)
        phys_w += pw
        phys_d += pd
        for lineno, first, logical in logical_lines(physical):
            for kind, m, portion in invocations(logical):
                if kind == "write":
                    checked_w += 1
                else:
                    checked_d += 1
                if "--dry-run" in portion or "--execute" in portion:
                    continue
                if MARKER in first:
                    markers.append(f"{f}:{lineno}")
                    continue
                label = "" if kind == "write" else " [dynamic verb — must carry an explicit flag]"
                bad.append(f"{f}:{lineno}:{label} {portion.strip()[:140]}")
    return bad, markers, files, (checked_w, checked_d), (phys_w, phys_d)


def check_diff(diff_text: str):
    """Reassemble each hunk's AFTER-state (context + added lines), scan its logical lines,
    and flag write/dynamic invocations that carry --execute where any physical line of the
    span was ADDED. Catches --execute added on a continuation under an unchanged head."""
    bad = []
    fname = "?"
    skip = False
    hunk = []  # list of (text, added?)

    def flush():
        nonlocal hunk
        if hunk and not skip:
            texts = [t for t, _ in hunk]
            added_flags = [a for _, a in hunk]
            spans = [(lineno - 1, logical) for lineno, _f, logical in logical_lines(texts)]
            for k, (start, logical) in enumerate(spans):
                end = spans[k + 1][0] if k + 1 < len(spans) else len(texts)
                if not any(added_flags[start:end]):
                    continue
                for _kind, _m, portion in invocations(logical):
                    if "--execute" in portion:
                        bad.append(f"{fname}: {portion.strip()[:140]}")
        hunk = []

    for line in diff_text.splitlines():
        if line.startswith("+++ "):
            flush()
            fname = line[4:].strip()
            # Same scope as tree mode: *.bats outside live/. Anything else (this helper's
            # own Python, docs, Swift) is not shell — the quote heuristics would misfire
            # on it (this very file's comments once self-flagged).
            skip = (not fname.endswith(".bats")
                    or "/live/" in fname or fname.startswith("live/"))
            continue
        if line.startswith("@@"):
            flush()
            continue
        if line.startswith("+") and not line.startswith("+++"):
            hunk.append((line[1:], True))
        elif line.startswith(" "):
            hunk.append((line[1:], False))
        elif line.startswith("-") and not line.startswith("---"):
            continue  # before-state only
        else:
            flush()
    flush()
    return bad


if __name__ == "__main__":
    if "--diff-mode" in sys.argv:
        violations = check_diff(sys.stdin.read())
        for v in violations:
            print(v)
        print(f"{'FAIL' if violations else 'OK'}: {len(violations)} added --execute write invocation(s)")
        sys.exit(1 if violations else 0)
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    root = Path(args[0]) if args else Path("bats")
    violations, markers, files, (cw, cd), (pw, pd) = check_tree(root)
    for v in violations:
        print(v)
    for m in markers:
        print(f"marker: {m} (flagless-on-purpose — remove at the v2 core flip)")
    print(f"scanned {files} file(s), checked {cw} write invocation(s) (physical floor {pw}) "
          f"+ {cd} dynamic (physical floor {pd}), {len(markers)} marker(s)")
    if files == 0 or (cw + cd) == 0:
        print("FAIL: nothing scanned — wrong root or matcher regression (fail-closed)")
        sys.exit(1)
    if cw < pw or cd < pd:
        print("FAIL: logical scan checked fewer invocations than exist on raw physical lines "
              "— either the line joiner is swallowing regions, or a genuinely multi-line "
              "shape confuses the physical floor (fail-closed either way)")
        sys.exit(1)
    if cw > pw or cd > pd:
        print("warning: logical count exceeds physical floor — benign for joined spans, but "
              "an over-count can offset a future matcher miss; worth a look")
    print(f"{'FAIL' if violations else 'OK'}: {len(violations)} flagless write invocation(s)")
    sys.exit(1 if violations else 0)
