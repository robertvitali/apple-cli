"""Write-posture pin discipline — the tree-level half of the ambient-canary invariant.

`Tests/AppleKitTests/AmbientEnvironmentCanaryTests.swift` claims to be the ONLY test that reports
an operator's exported write-posture variable (`APPLE_TEST_MODE` / `APPLE_TEST_SANDBOX` /
`APPLE_TEST_RECIPIENTS` / `APPLE_DRY_RUN`). That claim rests on three conventions the Swift test
tree cannot enforce for itself, so this check enforces them structurally:

1. No test file re-spells the write-posture variable set by hand. A pin of the form
   `"APPLE_DRY_RUN": String?.none` (or `TestMode.dryRunVar: nil`, or any other spelling of an
   absent value as the whole entry) outside `TestSupport`
   is a hand-rolled subset of `TestEnvironment.writeModeVariables`: correct on the day it is
   written, silently under-pinning the day a fifth variable joins the shared list. The two such
   pins that survived the consolidation (Contacts `pinnedGates`, Notes `pinnedEnv`) are what this
   rule now forbids. Pins go through `TestEnvironment.withoutWriteModeOverrides` /
   `withoutSandboxOverrides`; a test that wants a variable SET nests `TestEnvironment.with` with a
   non-nil value, which this rule does not touch.
2. No test file calls `setenv` / `unsetenv` / `putenv` directly. A raw mutation outside a `TestEnvironment`
   window outlives its test and desynchronises `AmbientEnvironment.atStartup` from the live table,
   so the canary keeps reporting a shell the process no longer runs in.
3. `AmbientEnvironment.atStartup` is read from exactly one test file — the canary. A second
   reader is a second reporter, which is exactly the duplication the canary's placement exists to
   prevent.

What this does NOT prove: that every write-posture RESOLUTION happens inside a pin. That would
take running the whole Swift suite under `APPLE_DRY_RUN=1` and asserting the canary is the only
failure — a full rebuild-and-run of the logic tier (minutes) inside an automation tier that must
stay at seconds, and a second Swift run per CI job. It is instead measured by hand at each change
to the pins (last: 2026-09-09, under `APPLE_DRY_RUN=1` and under `APPLE_DRY_RUN=`, canary alone
red). These three rules are the structural preconditions that claim depends on.

This is a LINT over the repo's own test tree, aimed at shapes an author writes by habit, not a
sandbox against an author trying to evade it. Known blind spots, accepted: a forbidden shape
built from string pieces or reached through a helper; a pin whose key is a raw-delimited literal
or whose value is wrapped in more than one pair of parentheses; prose inside a raw literal or
inside a comment within an interpolation that happens to spell a pin. Each is code no reviewer
would let past as a habit, and review — not this scan — is the control for deliberate evasion.
"""

from pathlib import Path
import re
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
TESTS_ROOT = REPO_ROOT / "Tests"
CANARY = Path("AppleKitTests/AmbientEnvironmentCanaryTests.swift")

WRITE_MODE_VARIABLES = (
    "APPLE_TEST_MODE",
    "APPLE_TEST_SANDBOX",
    "APPLE_TEST_RECIPIENTS",
    "APPLE_DRY_RUN",
)

RAW_ENV_MUTATION = re.compile(r"\b(?:setenv|unsetenv|putenv)\s*\(")
SNAPSHOT_READ = re.compile(r"\bAmbientEnvironment\.atStartup\b")


def _blank(text: str) -> str:
    return "".join("\n" if c == "\n" else " " for c in text)


def _skip_comment(source: str, i: int) -> int:
    """`i` is at `//` or `/*`; return the index just past the comment (nested blocks honoured)."""
    n = len(source)
    if source.startswith("//", i):
        j = source.find("\n", i)
        return n if j == -1 else j
    depth, j = 1, i + 2
    while j < n and depth:
        if source.startswith("/*", j):
            depth, j = depth + 1, j + 2
        elif source.startswith("*/", j):
            depth, j = depth - 1, j + 2
        else:
            j += 1
    return j


def _skip_string(source: str, i: int, code_spans: list | None = None) -> int:
    """`i` is at the opening of a Swift string literal (a double quote, a triple quote, or a raw
    hash-prefixed form); return the index just past its closing delimiter.

    Handles: backslash escapes in ordinary literals; multi-line literals, where the closing
    triple quote must not be escaped (a backslash-prefixed triple quote inside one is content);
    raw literals, where the escape prefix is backslash-plus-hashes and the closing delimiter is
    a quote followed by the same number of hashes;
    and interpolation (backslash-paren, or backslash-hash-paren in raw form), which is walked as CODE — parentheses
    balanced, nested literals and comments skipped by recursion — so a quote or `//` inside an
    interpolated expression neither ends the literal early nor starts a comment. Each
    interpolation's code span is appended to `code_spans` when given, so the caller can scan
    it as code: a mutation written inside an interpolation is a real mutation.
    """
    n = len(source)
    hashes = 0
    while source[i + hashes] == "#":
        hashes += 1
    j = i + hashes
    multiline = source.startswith('"""', j)
    j += 3 if multiline else 1
    close = ('"""' if multiline else '"') + "#" * hashes
    escape = "\\" + "#" * hashes
    while j < n:
        if source.startswith(escape, j):
            after = j + len(escape)
            if source.startswith("(", after):
                # interpolation: balance parentheses through nested literals/comments
                depth, k = 1, after + 1
                while k < n and depth:
                    c = source[k]
                    if c == "(":
                        depth, k = depth + 1, k + 1
                    elif c == ")":
                        depth, k = depth - 1, k + 1
                    elif c == '"' or (c == "#" and _raw_string_starts(source, k)):
                        k = _skip_string(source, k, code_spans)
                    elif source.startswith("//", k) or source.startswith("/*", k):
                        k = _skip_comment(source, k)
                    else:
                        k += 1
                if code_spans is not None:
                    code_spans.append((after + 1, k - 1))
                j = k
            else:
                j = after + 1          # any other escape: skip the escaped character
            continue
        if source.startswith(close, j):
            return j + len(close)
        j += 1
    return n


def _raw_string_starts(source: str, i: int) -> bool:
    """`i` is at `#`: is this `#…#"` opening a raw literal?"""
    j = i
    while j < len(source) and source[j] == "#":
        j += 1
    return j < len(source) and source[j] == '"'


def lex(source: str, keep_single_line_literals: bool) -> str:
    """Return `source` with comments blanked and string literals either blanked or, when
    `keep_single_line_literals`, kept if they do not span a line. Newlines are preserved
    throughout so an offset into the result maps to the same line of the source.

    Why a lexer and not a regex: a `//` inside a URL literal would otherwise start a "comment"
    that swallows real code after it, a literal that merely QUOTES a forbidden shape would trip
    the scan, and an interpolation's inner quote would end the literal early. Unterminated
    literals or comments run to end of file, which Swift itself rejects, so they cannot hide a
    violation in code that compiles.
    """
    out: list[str] = []
    i, n = 0, len(source)
    while i < n:
        c = source[i]
        if source.startswith("//", i) or source.startswith("/*", i):
            j = _skip_comment(source, i)
            out.append(_blank(source[i:j]))
            i = j
        elif source.startswith("#/", i):
            # `#/…/#` regex literal (Swift 5.7+): opaque text, ends at the matching `/#`
            j = source.find("/#", i + 2)
            j = n if j == -1 else j + 2
            out.append(_blank(source[i:j]))
            i = j
        elif c == '"' or (c == "#" and _raw_string_starts(source, i)):
            spans: list = []
            j = _skip_string(source, i, spans)
            text = source[i:j]
            if keep_single_line_literals and "\n" not in text:
                out.append(text)
            else:
                # blank the literal, but keep each interpolation's CODE visible (itself lexed)
                blanked = list(_blank(text))
                for a, b in spans:
                    blanked[a - i:b - i] = list(lex(source[a:b], keep_single_line_literals))
                out.append("".join(blanked))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


# A hand-rolled ABSENT pin: a write-mode variable mapped to an absent value. The KEY is either
# the quoted variable name — matched on the comment-blanked source, since the name is itself a
# literal, and a literal that merely quotes the shape cannot match because its inner quotes
# would have to be escaped — or a `TestMode.*Var` constant, matched on the fully-blanked source
# (code only, so prose naming the constant is not a hit). The VALUE must be the whole entry:
# any spelling of absent (`String?.none`, `Optional<String>.none`, `.none`, `nil`, optionally
# parenthesised), followed by the entry's end (`,` or `]`), so `String?.none ?? "1"` is a SET
# value and not a pin.
ABSENT_VALUE = r"\(?\s*(?:String\?\.none|Optional<String>\.none|\.none|nil)\s*\)?\s*(?=[,\]])"
QUOTED_KEY_PIN = re.compile(
    r'"(?:' + "|".join(WRITE_MODE_VARIABLES) + r')"\s*:\s*' + ABSENT_VALUE
)
CONSTANT_KEY_PIN = re.compile(r"\bTestMode\.\w+Var\s*:\s*" + ABSENT_VALUE)


def line_of(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def scan(tests_root: Path) -> dict:
    """Return the violations under `tests_root`, keyed by rule."""
    hand_rolled: list[str] = []
    raw_mutations: list[str] = []
    snapshot_readers: list[str] = []
    for path in sorted(tests_root.rglob("*.swift")):
        relative = path.relative_to(tests_root).as_posix()
        source = path.read_text(encoding="utf-8")
        with_literals = lex(source, keep_single_line_literals=True)
        code = lex(source, keep_single_line_literals=False)
        pins = [m.start() for m in QUOTED_KEY_PIN.finditer(with_literals)]
        pins += [m.start() for m in CONSTANT_KEY_PIN.finditer(code)]
        for offset in sorted(pins):
            hand_rolled.append(f"{relative}:{line_of(source, offset)}")
        for m in RAW_ENV_MUTATION.finditer(code):
            raw_mutations.append(f"{relative}:{line_of(source, m.start())}")
        if SNAPSHOT_READ.search(code):
            snapshot_readers.append(relative)
    return {
        "hand_rolled_pins": hand_rolled,
        "raw_env_mutations": raw_mutations,
        "snapshot_readers": snapshot_readers,
    }


class WritePosturePinsInTree(unittest.TestCase):
    """The rules hold on the real tree."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.result = scan(TESTS_ROOT)

    def test_no_hand_rolled_write_mode_pins(self) -> None:
        self.assertEqual(
            self.result["hand_rolled_pins"],
            [],
            "pin write-posture variables through TestEnvironment.withoutWriteModeOverrides / "
            "withoutSandboxOverrides, never by re-spelling the set",
        )

    def test_no_raw_environment_mutation(self) -> None:
        self.assertEqual(
            self.result["raw_env_mutations"],
            [],
            "route every setenv/unsetenv through a TestEnvironment window",
        )

    def test_the_canary_is_the_only_snapshot_reader(self) -> None:
        self.assertEqual(self.result["snapshot_readers"], [CANARY.as_posix()])

    def test_the_shared_set_still_names_every_variable(self) -> None:
        # The scan's own list must match TestSupport's, or a fifth variable would be pinnable
        # by hand without this check noticing. Read the declaration rather than duplicating it.
        support = (REPO_ROOT / "Sources/TestSupport/TestProcessFixtures.swift").read_text(encoding="utf-8")
        sandbox = re.search(r"static let sandboxVariables = \[(.*?)\]", support, flags=re.S)
        extra = re.search(r'static let writeModeVariables = sandboxVariables \+ \[(.*?)\]', support, flags=re.S)
        self.assertIsNotNone(sandbox)
        self.assertIsNotNone(extra)
        declared = set(re.findall(r'"([A-Z_]+)"', sandbox.group(1) + extra.group(1)))
        self.assertEqual(declared, set(WRITE_MODE_VARIABLES))


class ScannerSelfTest(unittest.TestCase):
    """The scanner catches each shape it exists for, and ignores the shapes it must allow."""

    def write(self, root: Path, relative: str, body: str) -> None:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")

    def test_catches_each_violation_once(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write(root, "XKitTests/A.swift", '\n'.join([
                'let a = TestEnvironment.with(["APPLE_DRY_RUN": String?.none]) {}',
                'let b = TestEnvironment.with([TestMode.dryRunVar: String?.none]) {}',
                'setenv("APPLE_TEST_MODE", "1", 1)',
                'unsetenv("APPLE_TEST_MODE")',
                'let c = AmbientEnvironment.atStartup["APPLE_DRY_RUN"]',
                # split across lines: still one pin, reported at the KEY's line
                'let d = TestEnvironment.with([',
                '    "APPLE_TEST_MODE":',
                '        String?.none,',
                '])',
                # a `//` inside a literal must not hide the mutation after it
                'let url = "https://example.com"; unsetenv("APPLE_DRY_RUN")',
                # every spelling of absent, and putenv
                'let e = TestEnvironment.with(["APPLE_TEST_SANDBOX": nil]) {}',
                'let f = TestEnvironment.with(["APPLE_TEST_RECIPIENTS": Optional<String>.none]) {}',
                'let g = TestEnvironment.with([TestMode.testModeVar: .none]) {}',
                'putenv("APPLE_DRY_RUN=1")',
                # interpolation: the inner quote and `//` must not end the literal or hide code
                'let h = "\\(String("//"))"; unsetenv("APPLE_DRY_RUN")',
                # an escaped triple-quote inside a multi-line literal is content, not the close
                'let m = """',
                '    \\"""',
                '    """',
                'unsetenv("APPLE_TEST_MODE")',
                # a parenthesised absent value is still absent
                'let i = TestEnvironment.with(["APPLE_DRY_RUN": (nil)]) {}',
                # code inside an interpolation is still code
                'let j = "\\(unsetenv("APPLE_DRY_RUN"))"',
                # a regex literal's quote must not open a string that hides the call after it
                'let regex = #/"/#; unsetenv("APPLE_TEST_SANDBOX")',
            ]))
            self.write(root, "AppleKitTests/AmbientEnvironmentCanaryTests.swift",
                       'let v = AmbientEnvironment.atStartup[key]\n')
            result = scan(root)
        self.assertEqual(result["hand_rolled_pins"],
                         ["XKitTests/A.swift:1", "XKitTests/A.swift:2", "XKitTests/A.swift:7",
                          "XKitTests/A.swift:11", "XKitTests/A.swift:12", "XKitTests/A.swift:13",
                          "XKitTests/A.swift:20"])
        self.assertEqual(result["raw_env_mutations"],
                         ["XKitTests/A.swift:3", "XKitTests/A.swift:4", "XKitTests/A.swift:10",
                          "XKitTests/A.swift:14", "XKitTests/A.swift:15", "XKitTests/A.swift:19",
                          "XKitTests/A.swift:21", "XKitTests/A.swift:22"])
        self.assertEqual(result["snapshot_readers"],
                         ["AppleKitTests/AmbientEnvironmentCanaryTests.swift", "XKitTests/A.swift"])

    def test_allows_set_windows_shared_pins_and_commentary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write(root, "XKitTests/B.swift", '\n'.join([
                '// a doc comment may quote "APPLE_DRY_RUN": String?.none and setenv( freely',
                '/* so may a block: unsetenv("APPLE_DRY_RUN") */',
                'try TestEnvironment.withoutWriteModeOverrides { }',
                'try TestEnvironment.with(["APPLE_TEST_MODE": "1"]) { }',
                'try TestEnvironment.with(["APPLE_TEST_MODE": "nil"]) { }',
                'try TestEnvironment.with(["APPLE_TEST_MODE": nilValueOwnedByTheTest]) { }',
                'try TestEnvironment.with(["APPLE_CLI_TEST_OWNED": String?.none]) { }',
                'try TestEnvironment.with(["APPLE_SEND_RATELIMIT_STATE": path]) { }',
                # a literal that names the forbidden call or the snapshot is prose, not code
                'let msg = "Do not call unsetenv( here, and never read AmbientEnvironment.atStartup"',
                'let doc = """',
                '    setenv("APPLE_DRY_RUN", "1", 1) is forbidden; so is "APPLE_DRY_RUN": String?.none',
                '    """',
                '/* nested /* block */ with unsetenv("APPLE_DRY_RUN") inside */',
                'let raw = #"a "quoted" unsetenv("APPLE_DRY_RUN") // not a comment"#; let after = 1',
                'let esc = "ends with a backslash \\\\"; let alsoAfter = AmbientEnvironment.other',
                # prose naming the constant key, and an interpolation quoting the forbidden call
                'let advice = "Never use TestMode.dryRunVar: nil here"',
                'let quoted = "\\(String("unsetenv("))"',
                # an absent-looking value that resolves to SET is not a pin
                'try TestEnvironment.with(["APPLE_DRY_RUN": String?.none ?? "1"]) { }',
                # a regex literal that spells the call is opaque text
                'let pattern = #/unsetenv\\(foo\\)/#',
            ]))
            result = scan(root)
        self.assertEqual(result, {"hand_rolled_pins": [], "raw_env_mutations": [], "snapshot_readers": []})


if __name__ == "__main__":
    unittest.main()
