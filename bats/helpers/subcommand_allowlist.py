#!/usr/bin/env python3
"""Pin `Apple.toolForParseFailure()` — the helper that puts a value on the stdout MACHINE channel.

WHY A SOURCE LINT AND NOT A BEHAVIOURAL TEST. The helper must satisfy three properties, and only
the first is reachable by any runtime test:

  1. an unknown argv[1] yields the constant "apple"                    — runtime-testable, and tested
  2. the emitted value is a REGISTERED literal, never argv[1]'s bytes  — not testable in-tree
  3. the emitted value is the subcommand's PRIMARY name, not an alias  — not testable in-tree

"Not testable IN-TREE" is the precise claim, and it is weaker than "not testable". Review proved 3
by building an ISOLATED copy that registered `aliases: ["ver"]` plus a subcommand with no explicit
`commandName`, then measuring: `apple ver --bogus` -> "version" and
`apple sec-rev-probe-command --bogus` -> "sec-rev-probe-command", both of which report "apple" under
the old spelling. So the property is provable — it just needs a subcommand roster this product does
not have, and shipping one to test it would put test-only code in the product target.

2 is unreachable because Swift's `==` is Unicode CANONICAL equivalence, so an echo of `candidate`
differs from the registered name only when some non-ASCII string is canonically equal to a
registered one — and a sweep of 0x20..0x10FFFF finds the only non-ASCII scalar canonically equal
to an ASCII letter is U+212A KELVIN (equal to uppercase K), while every registered name is pure
lowercase ASCII. 3 is unreachable because no subcommand declares an alias yet. Both properties are
therefore live in the code and invisible to the suite, which is what this lint is for.

WHY IT PINS WHAT IS REQUIRED RATHER THAN LISTING WHAT IS FORBIDDEN. An earlier version of this
lint checked that certain substrings were PRESENT and certain bad spellings ABSENT. Review broke
it with 5 of 7 mutants — `let hit = known.first {...}; return hit == nil ? fallback : candidate`,
`known.first {...}.map { _ in candidate } ?? fallback`, `if known.contains(where:) { return
candidate }`, and two that re-dropped a naming arm while keeping the required tokens in a comment.
The lesson is structural, not a matter of adding entries: FORBIDDEN is an unbounded set, so
enumerating it can never finish, and each entry excludes exactly one spelling. The ALLOWED set is
bounded and tiny — there is ONE correct implementation. So this pins that implementation exactly,
modulo comments and whitespace, and every other spelling is excluded BY CONSTRUCTION.

That makes any TOKEN-level rewrite fail. Reindents, reflows and comments are normalized away and
do NOT fail — verified by negative controls — so the false-positive cost is limited to changes that
actually alter the code. "Someone rewrote these tokens" is precisely the event worth a human look on
a function that decides what lands on the machine channel. Update EXPECTED_BODY when you change it
on purpose — never to make the lint pass.

Do NOT extend this pattern to larger functions. The false-positive cost grows with the size of the
subject while the payoff does not; it earns its keep here because the subject is eight lines and two
of its three properties have no other control.

TWO SUBJECTS, because there are two ways this rots:

  A. OUR SOURCE drifts — someone rewrites the helper.
  B. THE UPSTREAM ASSUMPTION drifts — a swift-argument-parser bump changes how a subcommand may
     be named, so our resolution silently under-covers again while our source is untouched. The
     first version of check B compared only the FIRST path component after `$0.element.`, so a new
     arm hung off `configuration` (where `aliases` itself lives — the likeliest shape by far) was
     invisible: review passed `|| $0.element.configuration.alternateNames.contains(name)` straight
     through the check written to catch exactly that. Check B now pins the matcher body the same
     exact way as check A.

Fails closed everywhere: an unreadable file, a subject it cannot find, or an unrecognized flag is a
violation, never a silent pass.
"""
import glob
import os
import re
import sys

# The one correct implementation, whitespace-normalized. Comments are stripped before comparison,
# so they are free to change; code is not.
EXPECTED_BODY = (
    'let fallback = "apple" '
    'guard CommandLine.arguments.count > 1 else { return fallback } '
    'let candidate = CommandLine.arguments[1] '
    'let match = configuration.subcommands.first { '
    '$0._commandName == candidate || $0.configuration.aliases.contains(candidate) '
    '} '
    'return match?._commandName ?? fallback'
)

# ArgumentParser's own subcommand matcher, whitespace-normalized. If this changes, the set of ways
# a subcommand can be named has changed, and EXPECTED_BODY above must be re-derived from it.
EXPECTED_MATCHER = (
    'children.first(where: { '
    '$0.element._commandName == name || $0.element.configuration.aliases.contains(name) '
    '})'
)

UPSTREAM_REL = "checkouts/swift-argument-parser/Sources/ArgumentParser/Utilities/Tree.swift"


def normalize(src):
    """Strip comments, then collapse all whitespace runs to single spaces.

    Both comment forms are stripped. Sound in the direction that matters: Swift cannot execute
    code inside a comment, so stripping can only remove NON-executing text — it can never hide a
    live mutation from the pin. (Block comments were originally left in, which made a legitimate
    `/* */` fail with "not the pinned implementation" — pointing the reader at a semantic change
    that had not happened. A comment is not a refactor.)
    """
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    src = re.sub(r"//[^\n]*", "", src)
    return " ".join(src.split())


def find_upstream(apple_swift_path, explicit_root):
    """Locate the ArgumentParser checkout belonging to the tree UNDER TEST.

    `explicit_root` is the authority when given: the bats suite passes the scratch root it derives
    from `swift build --show-bin-path`, i.e. the very tree the binary being tested was built from,
    so the lint and the behavioural tests cannot disagree about their subject.

    Discovery is the fallback for a hand-run. It must consider EVERY `.build*` tree, not just one:
    an earlier version returned `sorted(glob(...))[0]`, and because `-` (0x2D) sorts before `/`
    (0x2F), any `.build-<anything>/` outranked the real `.build/`. That was not theoretical — the
    subject silently changed mid-review when a sibling process created a `.build-critic3/` scratch
    dir, and this repo's own .gitignore hunk documents throwaway scratch trees as the normal state.
    It fails BOTH ways: a stale tree that still matches masks a real dependency bump (false green),
    and an unrelated scratch tree with an old matcher red-flags a correct repo (false red) — and a
    control that red-flags on an unrelated directory is a control that gets switched off.

    So discovery returns ALL candidates and the caller requires every one to match. Agreement among
    every checkout on disk is a claim that does not depend on which one we happened to pick.
    """
    if explicit_root:
        return [os.path.join(explicit_root, UPSTREAM_REL)]
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(apple_swift_path))))
    return sorted(glob.glob(os.path.join(repo, ".build*", UPSTREAM_REL)))


def extract(path, signature, what):
    """Return the body of the single declaration matching `signature`, by BRACE BALANCE.

    Two lessons are baked in here.

    Indentation-agnostic. The terminator used to be a fixed-width `\\n  \\}`, so reindenting a
    declaration INCLUDING its closing brace — the ordinary output of running a formatter — made the
    non-greedy body run on to the next brace at the old depth and over-capture an unrelated
    initialiser. The lint then reported "the matcher changed" and printed a `found:` field that was
    the matcher plus half of something else: a diagnostic that misdirects whoever triages it. For
    OUR source a reformat SHOULD fail the pin (that is the point), but upstream is a third-party
    file we do not control, where a reformat on a dependency bump is routine.

    Uniqueness. `re.search` returns the FIRST match, so the pin only ever constrained whichever
    definition appeared first — a decoy carrying the pinned text above the real one would let the
    real helper be mutated freely. A pin has to establish that it is pinning the thing that
    executes, so 0 or 2+ definitions are both violations.
    """
    try:
        src = open(path, encoding="utf-8").read()
    except OSError as e:
        return None, f"cannot read {path}: {e}"
    starts = [m.end() for m in re.finditer(re.escape(signature) + r"\s*\{", src)]
    if not starts:
        return None, (f"could not locate {what} in {path} — the lint must not pass by failing to "
                      "find its subject. If it moved or was renamed, re-derive the pin from the "
                      "new definition rather than deleting this check.")
    if len(starts) > 1:
        return None, (f"found {len(starts)} definitions of {what} in {path}; expected exactly 1. "
                      "A pin over the first match does not constrain the one that executes.")
    i, depth = starts[0], 1
    while i < len(src) and depth:
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
        i += 1
    if depth:
        return None, f"unbalanced braces while reading {what} in {path}"
    return src[starts[0]:i - 1], None


def check_ours(path):
    body, err = extract(path, "static func toolForParseFailure() -> String",
                        "toolForParseFailure()")
    if err:
        return [err]
    got = normalize(body)
    if got != EXPECTED_BODY:
        return ["toolForParseFailure() is not the pinned implementation.\n"
                f"    expected: {EXPECTED_BODY}\n"
                f"    found   : {got}\n"
                "    This function decides what argv-derived value reaches the stdout MACHINE\n"
                "    channel, and two of its three properties cannot be reached by any runtime\n"
                "    test. If you changed it deliberately, update EXPECTED_BODY in this file and\n"
                "    say why in the commit; do not edit the pin to make the lint go green."]
    return []


def check_upstream(apple_swift_path, required, explicit_root, resolved):
    paths = find_upstream(apple_swift_path, explicit_root)
    if not paths:
        if required:
            return ["no swift-argument-parser checkout found under any .build*/ next to "
                    f"{apple_swift_path} — build first (`swift build`), do not drop "
                    "--require-upstream, which would silently disable this check"]
        print("NOTE: skipping upstream-assumption check — no .build*/ checkout found "
              "(run `swift build` first; the bats suite passes --require-upstream)")
        return []

    problems = []
    for path in paths:
        body, err = extract(path, "func firstChild(withName name: String) -> Tree?",
                            "Tree.firstChild(withName:)")
        if err:
            problems.append(err)
            continue
        got = normalize(body)
        resolved.append(path)
        if got != EXPECTED_MATCHER:
            problems.append(
                "ArgumentParser's subcommand matcher changed, so the set of ways a subcommand "
                "can be named may have changed too.\n"
                f"    expected: {EXPECTED_MATCHER}\n"
                f"    found   : {got}\n"
                f"    source  : {path}\n"
                "    Re-derive toolForParseFailure() from the new matcher — under-covering it is\n"
                "    exactly the bug this helper was written to fix, and it would reappear here\n"
                "    without anyone editing our source.")
    return problems


# Every `Output.emitError` on the pre-dispatch path must take its `tool` FROM the pinned helper.
# Pinning the helper alone is not enough: review built a caller that used it only as a GATE —
# `tool: Apple.toolForParseFailure() == "apple" ? "apple" : CommandLine.arguments[1]` — which emits
# raw argv bytes while the helper itself stays byte-identical to the pin. That mutant passed the
# lint AND all 28 bats tests, and reproduced the exact bug this change exists to fix. The
# properties are about the value EMITTED, so the emission sites are part of the subject.
EXPECTED_EMIT = "Output.emitError(tool: Apple.toolForParseFailure(),"


def check_call_sites(path):
    try:
        src = open(path, encoding="utf-8").read()
    except OSError as e:
        return [f"cannot read {path}: {e}"]
    sites = re.findall(r"Output\.emitError\(tool:[^,]*,", src)
    if not sites:
        return [f"no Output.emitError(tool: …) call sites found in {path} — the lint must not "
                "pass by failing to find its subject"]
    bad = [s for s in sites if " ".join(s.split()) != EXPECTED_EMIT]
    if bad:
        return [f"{len(bad)} of {len(sites)} pre-dispatch emitError site(s) do not take `tool` "
                "from the pinned helper:\n"
                + "".join(f"    found   : {' '.join(s.split())}\n" for s in bad)
                + f"    expected: {EXPECTED_EMIT}\n"
                "    A caller can satisfy the helper pin and still emit argv bytes by using the\n"
                "    helper as a gate rather than as the value. Both emission sites are pinned."]
    return []


# `defaultSubcommand` dispatches through `firstChild(equalTo:)` (CommandParser.swift:277-282), NOT
# `firstChild(withName:)` — so adopting one would add a dispatch route the completeness argument
# above does not cover, and `apple --bogus` would dispatch INTO it while argv[1] matches nothing
# and the envelope reports "apple". Fail-safe (under-attribution), but it is the same defect class.
# Assert its absence so adopting one forces a deliberate re-derivation rather than silent drift.
def check_no_default_subcommand(path):
    try:
        src = open(path, encoding="utf-8").read()
    except OSError as e:
        return [f"cannot read {path}: {e}"]
    if re.search(r"\bdefaultSubcommand\s*:", src):
        return ["Apple.configuration now sets `defaultSubcommand:`, which dispatches through "
                "ArgumentParser's firstChild(equalTo:) rather than firstChild(withName:).\n"
                "    toolForParseFailure() resolves NAME-based dispatch only, so a bare "
                "`apple --bogus`\n"
                "    would dispatch into the default subcommand and still report \"apple\". "
                "Re-derive the\n"
                "    helper (and this lint) from both dispatch routes before adopting one."]
    return []


def main(argv):
    args, flags, upstream_root = [], [], None
    rest = list(argv[1:])
    while rest:
        a = rest.pop(0)
        if a == "--upstream-root":
            if not rest:
                print("--upstream-root requires a path", file=sys.stderr)
                return 2
            upstream_root = rest.pop(0)
        elif a.startswith("--"):
            flags.append(a)
        else:
            args.append(a)
    # An unrecognized flag must not be silently swallowed: `--require-upstreams` would otherwise
    # degrade check B to a skip while still printing OK.
    unknown = [f for f in flags if f != "--require-upstream"]
    if unknown or len(args) != 1:
        if unknown:
            print(f"unrecognized flag(s): {' '.join(unknown)}", file=sys.stderr)
        print("usage: subcommand_allowlist.py [--require-upstream] [--upstream-root DIR] "
              "<Sources/apple/Apple.swift>", file=sys.stderr)
        return 2

    resolved = []
    problems = (check_ours(args[0])
                + check_call_sites(args[0])
                + check_no_default_subcommand(args[0])
                + check_upstream(args[0], "--require-upstream" in flags, upstream_root, resolved))
    if problems:
        for p in problems:
            print(f"VIOLATION: {p}")
        return 1
    # Name the resolved subject on SUCCESS too. When only failures named it, there was no way to
    # notice the check had silently retargeted a different scratch tree.
    where = ", ".join(resolved) if resolved else "(upstream check skipped)"
    print("OK: toolForParseFailure() is the pinned implementation, both emitError sites take "
          "`tool` from it, no defaultSubcommand is set, and the matcher agrees in: " + where)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
