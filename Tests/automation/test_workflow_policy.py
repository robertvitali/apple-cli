"""Tests for scripts/ci/workflow_policy.py — the parsed-YAML read-only workflow scan."""
from __future__ import annotations

import collections
import importlib.util
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "ci" / "workflow_policy.py"
PINS_SCRIPT = REPO_ROOT / "scripts" / "ci" / "action_pins.py"
ALLOWLIST = REPO_ROOT / ".github" / "actions-allowlist.json"


def load_module(name: str = "workflow_policy", script: Path = SCRIPT):
    spec = importlib.util.spec_from_file_location(name, script)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


policy = load_module()
pins = load_module("action_pins", PINS_SCRIPT)


def reviewed_pin(name: str) -> str:
    """The `uses:` text of an allowlisted Action, read from the reviewed allowlist, so a pin bump
    changes the allowlist and the workflows and no test."""
    sha, version = pins.load_allowlist(ALLOWLIST)[name]
    return f"{name}@{sha} # {version}"


CHECKOUT = reviewed_pin("actions/checkout")

# The libyaml comparisons below run wherever Ruby is present. In CI a missing Ruby fails them instead
# of skipping them, so the hosted run cannot pass without comparing anything. The libyaml behind
# Ruby differs by host (0.2.1 on the macOS where the record was made).
NEEDS_LIBYAML = unittest.skipUnless(shutil.which("ruby") or "CI" in os.environ or "GITHUB_ACTIONS" in os.environ,
                                    "needs Ruby for its libyaml-backed loader (present on hosted Ubuntu and macOS)")


QUALITY = textwrap.dedent(
    f"""\
    name: CI
    on:
      push:
        branches: [main]
      pull_request:
        types: [opened, edited, synchronize, reopened]
    permissions:
      contents: read
    jobs:
      build:
        runs-on: ubuntu-latest
        permissions:
          contents: read
        steps:
          - uses: {CHECKOUT}
            with:
              persist-credentials: false
          - name: Build
            run: |
              set -euo pipefail
              echo "building"  # a comment inside a block scalar is text
      quality-required:
        name: quality / required
        runs-on: ubuntu-latest
        permissions:
          contents: read
        if: always()
        needs: [build]
        steps:
          - run: test "${{{{ needs.build.result }}}}" = success
    """
)

METADATA = textwrap.dedent(
    f"""\
    name: Governance
    on:
      pull_request_target:
        types: [opened, edited, reopened, synchronize, ready_for_review]
    permissions:
      contents: read
    jobs:
      required:
        name: governance / required
        runs-on: ubuntu-latest
        permissions:
          contents: read
        steps:
          - uses: {CHECKOUT}
            with:
              ref: ${{{{ github.event.pull_request.base.sha }}}}
              persist-credentials: false
          - run: python3 scripts/ci/pr_metadata.py --event "$GITHUB_EVENT_PATH"
    """
)


def write_tree(root: Path, files: dict) -> None:
    for name, body in files.items():
        path = root / ".github" / "workflows" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")


class ParserTests(unittest.TestCase):
    def test_parses_the_repository_shapes(self) -> None:
        document = policy.parse_workflow(QUALITY)
        self.assertEqual(policy._normalize_triggers(document["on"]),
                         {"push": {"branches": ["main"]},
                          "pull_request": {"types": ["opened", "edited", "synchronize", "reopened"]}})
        job = document["jobs"]["build"]
        self.assertEqual(job["steps"][0]["with"]["persist-credentials"], False)
        self.assertIn('echo "building"  # a comment inside a block scalar is text', job["steps"][1]["run"])
        self.assertEqual(document["jobs"]["quality-required"]["needs"], ["build"])
        self.assertEqual(document["jobs"]["quality-required"]["if"], "always()")

    def test_apostrophe_in_plain_scalar_and_trailing_comment(self) -> None:
        document = policy.parse_workflow(
            "name: the manual's source # trailing\non: push\npermissions: read-all\njobs:\n"
            "  a:\n    runs-on: ubuntu-latest\n    permissions: read-all\n    steps:\n      - run: echo hi\n"
        )
        self.assertEqual(document["name"], "the manual's source")

    def test_refuses_structures_outside_the_subset(self) -> None:
        for body in (
            "name: x\non: push\njobs: &a\n  b: *a\n",
            "name: x\non: push\njobs: {a: b}\n",
            "---\nname: x\n",
            "name: x\non: [push, {a: b}]\n",
            "name: x\non: push\njobs:\n  a:\n    steps:\n      - - nested\n",
            "name: x\nname: y\n",
            "name: x\n\ton: push\n",
        ):
            with self.subTest(body=body):
                with self.assertRaises(policy.ParseError):
                    policy.parse_workflow(body)

    def test_double_quoted_escapes_are_decoded_or_refused(self) -> None:
        self.assertEqual(policy._scalar('"a\\u0063b\\x41\\tc\\"d"'), 'acbA\tc"d')
        for bad in ('"\\q"', '"\\u12"', '"trailing\\"', '"\\x4"', '"\\U00110000"'):
            with self.subTest(bad=bad):
                with self.assertRaises(policy.ParseError):
                    policy._scalar(bad)

    def test_a_single_quoted_scalar_must_close_at_the_end_of_its_line(self) -> None:
        # `''` is an escaped quote, so each of these continues onto the next line in YAML or is a
        # YAML error (`'a'#x'` is `a` and a comment to libyaml); none is the scalar it looks like.
        for bad in ("'x ''", "'''", "'a'b'", "'a'''b'", "'a'#x'"):
            with self.subTest(bad=bad):
                with self.assertRaisesRegex(policy.ParseError, "does not close at the end of its line"):
                    policy._scalar(bad)
        # A flow-sequence item and a sequence entry reach the same reader: YAML reads each of these
        # as one item (`a '] j: ['b`, `b', c`, `x ' - y`) where this parser read two keys or items.
        for document in ("k: ['a '']\nj: [''b']\n", "k: [a, 'b'', c']\n", "k:\n  - 'x ''\n  - y'\n"):
            with self.subTest(document=document):
                with self.assertRaisesRegex(policy.ParseError, "does not close at the end of its line"):
                    policy.parse_workflow(document)
        for good, value in (("'it''s'", "it's"), ("''", ""), ("''''", "'"), ("'a '' b'", "a ' b")):
            with self.subTest(good=good):
                self.assertEqual(policy._scalar(good), value)

    def test_a_double_quoted_scalar_may_not_hold_an_unescaped_quote(self) -> None:
        for bad in ('"a" b"', '"a"b"', '""""', '"a"#"'):
            with self.subTest(bad=bad):
                with self.assertRaisesRegex(policy.ParseError, "unescaped quote inside a double-quoted scalar"):
                    policy._scalar(bad)
        for good, value in (('"a\\"b"', 'a"b'), ('"a\\\\"', "a\\"), ('""', "")):
            with self.subTest(good=good):
                self.assertEqual(policy._scalar(good), value)

    @NEEDS_LIBYAML
    def test_quoted_scalar_refusals_and_values_agree_with_libyaml(self) -> None:
        # Each form on a line of its own. libyaml rejects every malformed form, and gives the same
        # value for every accepted one. It reads a comment-adjacent form as `a` and a comment;
        # the subset refuses that too, so a quote mid-value never reads two ways.
        malformed = ["'x ''", "'''", "'a'b'", "'a'''b'", '"a" b"', '"a"b"', '""""']
        comment_adjacent = ["'a'#x'", '"a"#"']
        accepted = ["'it''s'", "''", "''''", "'a '' b'", '"a\\"b"', '"a\\\\"', '""']
        forms = malformed + comment_adjacent + accepted
        script = ('require "psych"; require "json"; puts JSON.generate(JSON.parse(STDIN.read).map { |t| '
                  'begin; [true, Psych.safe_load("k: " + t)["k"]]; rescue Psych::SyntaxError; [false, nil]; end })')
        result = subprocess.run(["ruby", "-e", script], input=json.dumps(forms),
                                capture_output=True, text=True, check=False, timeout=LIBYAML_TIMEOUT_SECONDS)
        self.assertEqual(result.returncode, 0, result.stderr)
        loaded = json.loads(result.stdout)
        self.assertEqual(len(loaded), len(forms))
        for form, (ok, value) in zip(forms, loaded):
            with self.subTest(form=form):
                if form in malformed:
                    self.assertFalse(ok)
                elif form in comment_adjacent:
                    self.assertEqual((ok, value), (True, "a"))
                else:
                    self.assertTrue(ok)
                    self.assertEqual(policy._scalar(form), value)
                    continue
                with self.assertRaises(policy.ParseError):
                    policy._scalar(form)

    FLOW_ITEMS_REFUSED = ("k: [path: x.js]\n", "k: [a, b: c]\n", "k: [a:]\n", "k: [x\t: y]\n", "k: [a: &r run]\n",
                          "k: [a:[&r run]]\n", "k: [a:[b]]\n", "k: [a :[]]\n", "k: [a:\tb]\n", "k: [a[b]]\n",
                          "k: [a}]\n")
    # Refused as a precaution: libyaml 0.2.1 rejects these and 0.2.5 reads them as strings.
    FLOW_ITEMS_LOADERS_DISAGREE = ("k: [a:b]\n", "k: [https://example.com/x]\n")
    SEQUENCE_ENTRIES_REFUSED = ("k:\n  - a b: c\n", "k:\n  - b': b'\n", "k:\n  - *r : x\n", "k:\n  - a b:\n",
                                "k:\n  - a b:\tc\n")
    PLAIN_VALUES_REFUSED = ("k: echo: evil\n", "k:\n  - run: echo: evil\n", "k: done:\n", "k: echo:\tevil\n")

    def test_a_plain_flow_item_holding_a_colon_or_a_bracket_is_refused(self) -> None:
        # YAML reads a plain item holding `key: value` or `key:` as a one-pair mapping, and loaders
        # disagree on other plain items with a colon (`[a:b]`, an unquoted URL); a quoted item stays
        # a string.
        for document in self.FLOW_ITEMS_REFUSED + self.FLOW_ITEMS_LOADERS_DISAGREE:
            with self.subTest(document=document):
                with self.assertRaisesRegex(policy.ParseError, "flow sequences may hold scalars only"):
                    policy.parse_workflow(document)
        self.assertEqual(policy.parse_workflow("k: ['a: b', 'https://example.com/x', b]\n"),
                         {"k": ["a: b", "https://example.com/x", "b"]})

    def test_a_sequence_entry_holding_a_key_the_parser_does_not_admit_is_refused(self) -> None:
        # YAML reads each of these entries as a mapping; a key outside KEY_RE would otherwise make
        # the entry a string here. An alias (`*r`) is never a key.
        for document in self.SEQUENCE_ENTRIES_REFUSED:
            with self.subTest(document=document):
                with self.assertRaisesRegex(policy.ParseError, "needs a key this parser admits"):
                    policy.parse_workflow(document)
        # A lone `- -` is a nested sequence to YAML (`[[null]]`), not the string `-`.
        for document in ("k:\n  - -\n", "k:\n  - - #c\n"):
            with self.subTest(document=document):
                with self.assertRaisesRegex(policy.ParseError, "nested sequences are refused"):
                    policy.parse_workflow(document)
        with self.assertRaises(policy.ParseError):
            policy.parse_workflow("*r : x\n")
        self.assertEqual(policy.parse_workflow("k:\n  - https://example.com/x\n  - echo a:b\n"),
                         {"k": ["https://example.com/x", "echo a:b"]})

    def test_a_plain_value_holding_a_colon_and_a_space_is_refused(self) -> None:
        # In block context YAML refuses a plain value holding `: ` or ending in `:`.
        for document in self.PLAIN_VALUES_REFUSED:
            with self.subTest(document=document):
                with self.assertRaisesRegex(policy.ParseError, "may not hold a colon followed by a space or a tab"):
                    policy.parse_workflow(document)
        self.assertEqual(policy.parse_workflow("k: echo a:b https://example.com/x\n"),
                         {"k": "echo a:b https://example.com/x"})

    def test_a_document_nested_past_the_recursion_limit_is_a_parse_refusal(self) -> None:
        deep = "k:\n" + "".join(" " * level + "a:\n" for level in range(1, 2000)) + " " * 2000 + "a: x\n"
        with self.assertRaisesRegex(policy.ParseError, "nests too deeply"):
            policy.parse_workflow(deep)

    @NEEDS_LIBYAML
    def test_each_refused_shape_is_a_mapping_a_nested_sequence_an_alias_or_an_error_to_libyaml(self) -> None:
        documents = list(self.FLOW_ITEMS_REFUSED + self.SEQUENCE_ENTRIES_REFUSED + self.PLAIN_VALUES_REFUSED)
        documents += ["*r : x\n", 'k: "\\U00110000"\n', "k:\n  - -\n"]
        script = ('require "psych"; require "json"; '
                  'deep = ->(v) { v.is_a?(Hash) || (v.is_a?(Array) && v.any? { |x| x.is_a?(Array) || deep.(x) }) }; '
                  'puts JSON.generate(JSON.parse(STDIN.read).map { |t| '
                  'begin; d = Psych.safe_load(t, aliases: true); deep.(d.is_a?(Hash) ? d["k"] : d); '
                  'rescue Psych::Exception; nil; end })')
        result = subprocess.run(["ruby", "-e", script], input=json.dumps(documents),
                                capture_output=True, text=True, check=False, timeout=LIBYAML_TIMEOUT_SECONDS)
        self.assertEqual(result.returncode, 0, result.stderr)
        loaded = json.loads(result.stdout)
        self.assertEqual(len(loaded), len(documents))
        for document, mapped in zip(documents, loaded):
            with self.subTest(document=document):
                self.assertIn(mapped, (None, True))
                with self.assertRaises(policy.ParseError):
                    policy.parse_workflow(document)

    def test_quoted_mapping_keys_are_decoded(self) -> None:
        document = policy.parse_workflow('on: push\n"environm\\u0065nt": prod\n')
        self.assertEqual(document["environment"], "prod")
        with self.assertRaises(policy.ParseError):
            policy.parse_workflow('"a": 1\n"\\u0061": 2\n')

    def test_bracket_index_normalisation(self) -> None:
        self.assertEqual(policy._normalize_expression("secrets['A_B']"), "secrets.A_B")
        self.assertEqual(policy._normalize_expression('github["token"]'), "github.token")
        self.assertEqual(policy._normalize_expression("github.event.pull_request['head']['sha']"),
                         "github.event.pull_request.head.sha")

    def test_block_scalar_keeps_leading_and_trailing_comment_rows(self) -> None:
        document = policy.parse_workflow(
            "on: push\npermissions: read-all\njobs:\n  a:\n    runs-on: ubuntu-latest\n    permissions: read-all\n"
            "    steps:\n      - run: |\n          # leading\n          echo hi\n          # trailing\n      - run: second\n"
        )
        self.assertEqual(document["jobs"]["a"]["steps"][0]["run"], "# leading\necho hi\n# trailing\n")  # libyaml's value (clip)
        self.assertEqual(document["jobs"]["a"]["steps"][1]["run"], "second")

    def test_same_indent_sequence_may_be_followed_by_sibling_keys(self) -> None:
        document = policy.parse_workflow("on:\n- push\n- pull_request\npermissions: read-all\njobs:\n  a:\n    runs-on: ubuntu-latest\n    permissions: read-all\n    steps:\n    - run: echo hi\n")
        self.assertEqual(document["on"], ["push", "pull_request"])
        self.assertEqual(document["permissions"], "read-all")
        self.assertEqual(document["jobs"]["a"]["steps"], [{"run": "echo hi"}])

    def test_block_scalar_keeps_blank_lines_and_indentation(self) -> None:
        document = policy.parse_workflow(
            "on: push\npermissions: read-all\njobs:\n  a:\n    runs-on: ubuntu-latest\n    permissions: read-all\n"
            "    steps:\n      - run: |\n          first\n\n            indented\n      - run: second\n"
        )
        self.assertEqual(document["jobs"]["a"]["steps"][0]["run"], "first\n\n  indented\n")  # libyaml's value (clip)
        self.assertEqual(document["jobs"]["a"]["steps"][1]["run"], "second")

    # A quote opens a quoted scalar only where YAML may start a node; elsewhere it is plain text, and a
    # ` #` after it starts a comment. Each value is libyaml's reading.
    QUOTE_IS_PLAIN_TEXT = (("k: a-'x #y'\n", "a-'x"), ('k: :"b #c"\n', ':"b'), ('k:\t:"b #\n', ':"b'),
                           ("k: a, 'x #y'\n", "a, 'x"), ("k: a [b, 'x #y']\n", "a [b, 'x"),
                           ("k: -'x #'\n", "-'x"), ("k:\n  - a-'x #y'\n", ["a-'x"]),
                           ('k: a ? "x #y"\n', 'a ? "x'), ("k: a ?\t'x #y'\n", "a ?\t'x"),
                           ("k:\n  - a ? 'x #y'\n", ["a ? 'x"]), ("k: a - 'x #y'\n", "a - 'x"))
    # A plain scalar that starts with a flow indicator or `#`, `-` alone or `- x` after a key, a tab
    # after a sequence entry's `-`: each is a YAML error to libyaml 0.2.1 and 0.2.5.
    INDICATOR_STARTS_REFUSED = ("k: ,\n", "k: ]x\n", "k: }\n", "k: -\n", "k: - b\n", "k:\t-\n", "'': -\n",
                                "k:\n  - ,\n", "k:\n  - ]\n", "k:\n  a: }-\n", "k: [#, a]\n", "k: [a, - ]\n",
                                "k:\n  - [b, ,]\n", "k:\n  - \ta\n", "k:\n  -\tb\n", "k:\n-\t:\n- b\n",
                                "k:\n  - -\t: x\n", "k: -\tb\n")
    # Refused as a precaution: libyaml 0.2.1 rejects a `?` in a plain flow item and 0.2.5 mostly reads
    # it as text.
    FLOW_QUESTION_MARK_REFUSED = ("k: [a?]\n", "k: [b, /?]\n", "k:\n  - [x\"?, a]\n")
    BLOCK_WITH_DASH_TAB = "k: |\n  -\tx\n  - \ty\nl: x\n"
    # A `-` right before `,` or `]` is the string `-` to YAML (`[a, - ]` is an error, above).
    LONE_DASH_ITEMS = (("k: [a,-]\n", ["a", "-"]), ("k: [-, x]\n", ["-", "x"]), ("k: [ -]\n", ["-"]))

    def test_a_quote_away_from_a_node_start_is_plain_text(self) -> None:
        for document, value in self.QUOTE_IS_PLAIN_TEXT:
            with self.subTest(document=document):
                self.assertEqual(policy.parse_workflow(document), {"k": value})
        # Inside a flow collection a `:` is taken, conservatively, to start a node with no space
        # after it, so a JSON-like value keeps its ` #` (the parser then refuses the flow mapping as
        # a whole).
        self.assertEqual(policy._strip_comment('k: {"a":"b #c"}'), 'k: {"a":"b #c"}')
        # An anchor inside a flow collection ends at the `,` (libyaml reads `[null, "x #y"]`).
        self.assertEqual(policy._strip_comment("k: [&a,'x #y']"), "k: [&a,'x #y']")
        # Where a node starts the quote still opens, so a ` #` inside it is text.
        self.assertEqual(policy.parse_workflow("k: 'a #b'\nl:\n  - \"c #d\"\n  - x: 'e #f'\nm: ['g #h', \"i #j\"]\n"),
                         {"k": "a #b", "l": ["c #d", {"x": "e #f"}], "m": ["g #h", "i #j"]})

    def test_a_plain_scalar_starting_with_an_indicator_is_refused(self) -> None:
        for document in self.INDICATOR_STARTS_REFUSED + self.FLOW_QUESTION_MARK_REFUSED:
            with self.subTest(document=document):
                with self.assertRaises(policy.ParseError):
                    policy.parse_workflow(document)
        self.assertEqual(policy.parse_workflow("k: -x\nl: a,b]\nm:\n  - -1\n"), {"k": "-x", "l": "a,b]", "m": ["-1"]})
        for document, value in self.LONE_DASH_ITEMS:
            with self.subTest(document=document):
                self.assertEqual(policy.parse_workflow(document), {"k": value})
        # A block scalar's lines are text: a tab after a `-` there is kept, as YAML keeps it.
        self.assertEqual(policy.parse_workflow(self.BLOCK_WITH_DASH_TAB), {"k": "-\tx\n- \ty\n", "l": "x"})

    @NEEDS_LIBYAML
    def test_quote_and_indicator_shapes_agree_with_libyaml(self) -> None:
        documents = [document for document, _ in self.QUOTE_IS_PLAIN_TEXT] + list(self.INDICATOR_STARTS_REFUSED)
        trees = libyaml_trees(documents)
        for (document, value), tree in zip(self.QUOTE_IS_PLAIN_TEXT, trees):
            with self.subTest(document=document):
                self.assertEqual(tree, tree_of({"k": value}))
        for document, tree in zip(self.INDICATOR_STARTS_REFUSED, trees[len(self.QUOTE_IS_PLAIN_TEXT):]):
            with self.subTest(document=document):
                self.assertIsNone(tree)
        accepted = [self.BLOCK_WITH_DASH_TAB] + [document for document, _ in self.LONE_DASH_ITEMS]
        self.assertEqual(libyaml_trees(accepted), [parser_tree(document) for document in accepted])
        self.assertEqual(libyaml_trees(['k: {"a":"b #c"}\n']), [tree_of({"k": {"a": "b #c"}})])


# --------------------------------------------------------------------------- libyaml differential

# libyaml's reading as a node tree, through Ruby's Psych: a scalar keeps its text and whether it was
# plain, so YAML 1.1 type resolution (`on` as true, `3.10` as 3.1) can neither fake nor hide a
# difference. Any tag, anchor, alias or non-scalar key reports the document as outside the subset,
# since this parser refuses all of them; so does a stream holding other than one document.
LIBYAML_TREE_SCRIPT = r"""
require "psych"; require "json"
def walk(n)
  raise "anchor" if n.respond_to?(:anchor) && n.anchor
  raise "tag" if n.respond_to?(:tag) && n.tag
  case n
  when Psych::Nodes::Scalar then [n.plain ? "plain" : "quoted", n.value]
  when Psych::Nodes::Sequence then ["seq", n.children.map { |c| walk(c) }]
  when Psych::Nodes::Mapping
    ["map", n.children.each_slice(2).map { |k, v|
      key = walk(k)
      raise "key" unless key[0] == "plain" || key[0] == "quoted"
      [key[1], walk(v)]
    }]
  else raise "alias"
  end
end
STDERR.puts "libyaml-version " + Psych::LIBYAML_VERSION
puts JSON.generate(JSON.parse(STDIN.read).map { |t|
  begin
    s = Psych.parse_stream(t)
    s.children.length == 1 ? walk(s.children[0].root) : nil
  rescue Psych::SyntaxError, RuntimeError
    nil
  end
})
"""


def _resolved(node):
    """A libyaml node tree in `tree_of`'s form, with plain scalars resolved as this parser resolves
    them (YAML 1.2's spellings of true, false and null) and every other scalar a string."""
    kind, body = node
    if kind == "plain" and body in ("true", "True", "TRUE"):
        return True
    if kind == "plain" and body in ("false", "False", "FALSE"):
        return False
    if kind == "plain" and body in ("null", "Null", "NULL", "~", ""):
        return None
    if kind in ("plain", "quoted"):
        return ["str", body]
    if kind == "seq":
        return ["seq", [_resolved(item) for item in body]]
    return ["map", [[key, _resolved(value)] for key, value in body]]


def tree_of(value):
    """This parser's reading in a form comparable with libyaml's: key order kept, strings tagged."""
    if isinstance(value, dict):
        return ["map", [[key, tree_of(item)] for key, item in value.items()]]
    if isinstance(value, list):
        return ["seq", [tree_of(item) for item in value]]
    if isinstance(value, str):
        return ["str", value]
    return value


LIBYAML_TIMEOUT_SECONDS = 600
LIBYAML_VERSIONS_SEEN = []  # printed once per run, so each hosted log names the libyaml it compared with


def libyaml_trees(texts):
    """libyaml's reading of each text in `tree_of`'s form, or None where it is outside the subset."""
    try:
        result = subprocess.run(["ruby", "-e", LIBYAML_TREE_SCRIPT], input=json.dumps(texts),
                                capture_output=True, text=True, check=False, timeout=LIBYAML_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        raise AssertionError("the libyaml oracle did not answer within {} s".format(LIBYAML_TIMEOUT_SECONDS)) from None
    if result.returncode != 0:
        raise AssertionError("the libyaml oracle failed: " + result.stderr[-2000:])
    version = [line[len("libyaml-version "):] for line in result.stderr.splitlines()
               if line.startswith("libyaml-version ")][:1]
    if version not in LIBYAML_VERSIONS_SEEN:
        LIBYAML_VERSIONS_SEEN.append(version)
        print("libyaml oracle: libyaml " + (version[0] if version else "version not reported"), file=sys.stderr)
    trees = json.loads(result.stdout)
    if len(trees) != len(texts):
        raise AssertionError("the libyaml oracle answered {} of {} texts".format(len(trees), len(texts)))
    return [None if tree is None else _resolved(tree) for tree in trees]


def parser_tree(text):
    try:
        return tree_of(policy.parse_workflow(text))
    except policy.ParseError:
        return None


# The seeded generator behind the recorded differential (readiness row 17): documents built from
# short runs of the characters and pairs that decide how YAML reads a line, in the shapes outside
# block scalars (values, keys, sequence entries, flow sequences, continuation lines). The test runs
# the record's own set, seeds 1 to 4 with 4,000 documents per template each; the record also read
# them with libyaml 0.2.5 and PyYAML's pure-Python loader. Widen it before trusting a zero: at 600
# documents per template, seven of nine seeds found no document the old quote handling reads
# differently, where the 272,000 found 8.
DIFFERENTIAL_PIECES = ("a", "b", "x", " ", "  ", "\t", ":", ": ", "#", " #", "'", '"', "''", "\\\"", "-", "- ",
                       "- -", "[", "]", "{", "}", ",", "&", "*", "!", "|", ">", "?", "%", "@", "`", "\\", "=",
                       "$", "/", ".", "~", "<<", "a:b", "true", "null", "3.10", "on", "${{ x }}", "\u00e9")


def _piece(rng, low=1, high=5):
    return "".join(rng.choice(DIFFERENTIAL_PIECES) for _ in range(rng.randint(low, high)))


def _gap(rng):
    return rng.choice((" ", " ", "  ", "\t", " \t"))


def _quote(rng):
    return rng.choice(("'", '"'))


def _key(rng):
    # Keys that may collide, by spelling or once decoded.
    return rng.choice(("a", "b", "'a'", '"a"', '"\\u0061"', "a ", "on", "'on'", "a b", "-a", "a#b"))


DIFFERENTIAL_TEMPLATES = {
    "plain value": lambda r: "k:" + _gap(r) + _piece(r) + "\n",
    "quoted value": lambda r: "k:" + _gap(r) + _quote(r) + _piece(r, 0, 4) + _quote(r) + _piece(r, 0, 3) + "\n",
    "comment after": lambda r: ("k: " + _quote(r) + _piece(r, 0, 3) + _quote(r) + r.choice(("", " ", "\t", "x"))
                                + "#" + _piece(r) + "\n"),
    "key": lambda r: _piece(r) + ":" + _gap(r) + _piece(r) + "\n",
    "quoted key": lambda r: _quote(r) + _piece(r, 0, 4) + _quote(r) + ":" + _gap(r) + _piece(r) + "\n",
    "nested key": lambda r: "k:\n  " + _piece(r) + ": " + _piece(r) + "\n",
    "two keys": lambda r: _key(r) + ":" + _gap(r) + _piece(r, 1, 3) + "\n" + _key(r) + ":" + _gap(r) + _piece(r, 1, 3) + "\n",
    "sequence entry": lambda r: "k:\n  -" + _gap(r) + _piece(r) + "\n",
    "sequence at key column": lambda r: "k:\n-" + _gap(r) + _piece(r) + "\n- b\n",
    "sequence pair": lambda r: "k:\n  -" + _gap(r) + _piece(r) + ":" + _gap(r) + _piece(r) + "\n",
    "sequence quoted key": lambda r: "k:\n  - " + _quote(r) + _piece(r, 0, 4) + _quote(r) + ": " + _piece(r, 1, 3) + "\n",
    "sequence mapping": lambda r: "k:\n  - a: " + _piece(r) + "\n    " + _piece(r) + ": x\n",
    "flow": lambda r: "k: [" + _piece(r) + r.choice((", ", ",", " , ")) + _piece(r, 0, 3) + "]\n",
    "flow entry": lambda r: "k:\n  - [" + _piece(r) + ", " + _piece(r, 0, 3) + "]\n",
    "continuation": lambda r: "k: " + _piece(r) + "\n  " + _piece(r) + "\n",
    "entry continuation": lambda r: "k:\n  - " + _piece(r) + "\n    " + _piece(r) + "\n",
    "properties": lambda r: "k: " + r.choice(("&a ", "!t ", "!!str ", "*a", "<<: ", "? ")) + _piece(r) + "\n",
}


# A second seeded set aims every document at a shape the record's set produces only rarely: a run
# of one to three pieces, a blank, an indicator or another piece that may or may not start a node,
# then a quote holding a ` #`. The record's seeds produced none with a `?` in plain text there, so a
# `?` in plain text read as an indicator passed them; this set reports such documents.
QUOTE_RUN_LEADS = ("? ", "?\t", "- ", "-\t", ": ", "&a ", "!t ", "a ", ", ", "[", "-", "?", "", " ")


def _quote_run(rng):
    lead = "".join(rng.choice(QUOTE_RUN_LEADS) for _ in range(rng.randint(1, 2)))
    return (_piece(rng, 1, 3) + _gap(rng) + lead + _quote(rng) + _piece(rng, 0, 3) + " #" + _piece(rng, 0, 3)
            + rng.choice(("", "'", '"')))


QUOTE_RUN_TEMPLATES = {
    "quote run value": lambda r: "k:" + _gap(r) + _quote_run(r) + "\n",
    "quote run entry": lambda r: "k:\n  -" + _gap(r) + _quote_run(r) + "\n",
    "quote run nested value": lambda r: "k:\n  b:" + _gap(r) + _quote_run(r) + "\n",
}


def differential_documents(seed, per_template, templates=None):
    """`per_template` documents from each template, reproducible from `seed`."""
    rng = random.Random(seed)
    templates = DIFFERENTIAL_TEMPLATES if templates is None else templates
    return [(name, make(rng)) for name, make in templates.items() for _ in range(per_template)]


class LibyamlDifferentialTests(unittest.TestCase):
    """Wherever this parser accepts a document, libyaml accepts it too and reads the same tree."""

    def assert_reads_as_libyaml(self, documents):
        trees = libyaml_trees([text for _, text in documents])
        offenders = []
        agreed = {}
        for (name, text), expected in zip(documents, trees):
            mine = parser_tree(text)
            if mine is not None:
                if mine != expected:
                    offenders.append((name, text, mine, expected))
                else:
                    agreed[name] = agreed.get(name, 0) + 1
        self.assertEqual(offenders[:5], [], "{} documents read differently, or only here".format(len(offenders)))
        return agreed

    @NEEDS_LIBYAML
    def test_each_scanned_workflow_and_the_mkdocs_configuration_reads_as_libyaml_reads_it(self) -> None:
        documents = [(path.relative_to(REPO_ROOT).as_posix(),
                      pins.read_regular_utf8(path, policy.MAX_WORKFLOW_BYTES))
                     for path in pins.workflow_paths(REPO_ROOT)]
        documents.append(("mkdocs.yml", (REPO_ROOT / "mkdocs.yml").read_text(encoding="utf-8")))
        # The urgent-release runbook's recorded workflow, which this scan reads and GitHub runs once
        # it is restored.
        runbook = load_module("urgent_release_runbook_tests", Path(__file__).with_name("test_urgent_release_runbook.py"))
        documents.append(runbook.recorded_workflow())
        self.assertGreaterEqual(len(documents), 5)
        agreed = self.assert_reads_as_libyaml(documents)
        # Each one parsed here, counted per name: once the urgent-release workflow is restored it is
        # both scanned and recorded, so its name appears twice on each side.
        self.assertEqual(agreed, dict(collections.Counter(name for name, _ in documents)))

    @NEEDS_LIBYAML
    def test_generated_documents_never_read_differently_or_only_here(self) -> None:
        documents = [document for seed in (1, 2, 3, 4) for document in differential_documents(seed, 4000)]
        agreed = self.assert_reads_as_libyaml(documents)
        # Not vacuous: the parser accepts 35,047 of the 272,000, at least 208 from each template but
        # the properties one (anchors, tags, aliases, merge keys, explicit keys), which it refuses.
        self.assertGreaterEqual(sum(agreed.values()), 30000)
        self.assertEqual(agreed.get("properties", 0), 0)
        for name in DIFFERENTIAL_TEMPLATES:
            if name != "properties":
                with self.subTest(template=name):
                    self.assertGreaterEqual(agreed.get(name, 0), 100)

    @NEEDS_LIBYAML
    def test_quote_runs_never_read_differently_or_only_here(self) -> None:
        documents = [document for seed in (5, 6, 7, 8)
                     for document in differential_documents(seed, 4000, QUOTE_RUN_TEMPLATES)]
        agreed = self.assert_reads_as_libyaml(documents)
        # Not vacuous: the parser accepts 17,438 of the 48,000, at least 3,678 from each template, and
        # with a `?` in plain text read as an indicator 2,873 of them read differently.
        self.assertGreaterEqual(sum(agreed.values()), 15000)
        for name in QUOTE_RUN_TEMPLATES:
            with self.subTest(template=name):
                self.assertGreaterEqual(agreed.get(name, 0), 3000)


JOB_HEADER = "    runs-on: ubuntu-latest\n    permissions:\n      contents: read\n    steps:"
CHECKOUT_STEP = "      - uses: " + CHECKOUT + "\n        with:\n          persist-credentials: false\n"


# Characters a reviewer cannot see: format characters (Cf, the tag character U+E0041 among them),
# private use (Co), unassigned (Cn: U+0378 in every Unicode version), and the default-ignorable code
# points and the blank outside those categories.
INVISIBLE_SAMPLES = (
    "\u200b", "\u200c", "\u200d", "\u2060", "\u00ad", "\u2062", "\U000e0041", "\ue000", "\U000f0000",
    "\u0378", "\u3164", "\uffa0", "\u115f", "\u1160", "\u2800", "\u034f", "\ufe0f", "\U000e0101",
    "\u180b", "\u17b4",
)


def mutate(source: str, old: str, new: str) -> str:
    """Replace exactly one occurrence, refusing a silent no-op (a fixture typo must not pass as a scan pass)."""
    if source.count(old) != 1:
        raise AssertionError("fixture fragment not found exactly once: {!r}".format(old))
    return source.replace(old, new, 1)


class ScanTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def scan(self, files: dict) -> list:
        write_tree(self.root, files)
        return policy.scan_repository(self.root)

    def scan_ci(self, ci_body: str) -> list:
        return self.scan({"ci.yml": ci_body, "governance.yml": METADATA})

    def scan_ci_rules(self, ci_body: str) -> list:
        # For fixtures that use a dummy SHA to test the scan's own rules; the reviewed pin
        # allowlist is tested on its own (`test_every_uses_is_checked_against_the_reviewed_pin_allowlist`).
        return [v for v in self.scan_ci(ci_body) if "reviewed action-pin allowlist" not in v]

    def assert_ci_violation(self, ci_body: str, needle: str) -> None:
        violations = self.scan_ci(ci_body)
        self.assertTrue(any(needle in v for v in violations), violations)

    def test_conforming_tree_passes(self) -> None:
        self.assertEqual(self.scan({"ci.yml": QUALITY, "governance.yml": METADATA}), [])

    def test_quoted_scalars_that_do_not_close_on_their_line_fail_the_scan(self) -> None:
        # YAML reads this `run` as "true ' id: x name: '; git push origin HEAD:main", so the shell
        # runs the push; read line by line, the push sits in a `name` the command scan never reads.
        hidden = ("      - run: 'true ''\n"
                  "        id: x\n"
                  "        name: ''; git push origin HEAD:main'\n")
        body = mutate(QUALITY, "  quality-required:\n", hidden + "  quality-required:\n")
        self.assert_ci_violation(body, "single-quoted scalar does not close at the end of its line")
        # The same fold could hide a key the scan requires: YAML reads `path` as
        # "src ' persist-credentials: false clean: x", so the checkout keeps its credentials.
        folded = mutate(QUALITY, "          persist-credentials: false\n",
                        "          path: 'src ''\n          persist-credentials: false\n          clean: x'\n")
        self.assert_ci_violation(folded, "single-quoted scalar does not close at the end of its line")
        quoted = mutate(QUALITY, "      - name: Build\n", '      - name: "Build" now"\n')
        self.assert_ci_violation(quoted, "unescaped quote inside a double-quoted scalar")
        plain = mutate(QUALITY, "  quality-required:\n",
                       "      - run: true; git push origin HEAD:main\n  quality-required:\n")
        self.assert_ci_violation(plain, "git ref write")

    def test_an_alias_used_as_a_step_key_is_refused(self) -> None:
        # With anchors, YAML reads this step as `run: git push origin HEAD:main`; read here, the
        # key would be the literal `*r` and the push would sit in a value the command scan skips.
        step = mutate(QUALITY, "  quality-required:\n", "      - *r : git push origin HEAD:main\n  quality-required:\n")
        self.assert_ci_violation(step, "needs a key this parser admits")
        anchored = mutate(step, "\njobs:\n", "\nenv:\n  K: [a: &r run]\njobs:\n")
        self.assert_ci_violation(anchored, "flow sequences may hold scalars only")

    @NEEDS_LIBYAML
    def test_libyaml_reads_the_aliased_step_as_a_run(self) -> None:
        # The reading the alias-key refusal guards against, checked against a real YAML loader.
        anchored = mutate(mutate(QUALITY, "  quality-required:\n",
                                 "      - *r : git push origin HEAD:main\n  quality-required:\n"),
                          "\njobs:\n", "\nenv:\n  K: [a: &r run]\njobs:\n")
        script = ('require "psych"; require "json"; '
                  'puts JSON.generate(Psych.safe_load(STDIN.read, aliases: true)["jobs"]["build"]["steps"].last)')
        result = subprocess.run(["ruby", "-e", script], input=anchored, capture_output=True, text=True, check=False,
                                timeout=LIBYAML_TIMEOUT_SECONDS)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"run": "git push origin HEAD:main"})

    def test_missing_job_permissions_fails(self) -> None:
        body = mutate(QUALITY, JOB_HEADER, "    runs-on: ubuntu-latest\n    steps:")
        self.assert_ci_violation(body, "job `build`: no explicit `permissions` block")

    def test_missing_workflow_permissions_fails(self) -> None:
        body = mutate(QUALITY, "permissions:\n  contents: read\njobs:", "jobs:")
        self.assert_ci_violation(body, "workflow: no explicit `permissions` block")

    def test_write_permissions_fail(self) -> None:
        for bad in ("contents: write", "id-token: read", "pages: read", "packages: none"):
            body = mutate(QUALITY, JOB_HEADER, "    runs-on: ubuntu-latest\n    permissions:\n      {}\n    steps:".format(bad))
            with self.subTest(bad=bad):
                self.assert_ci_violation(body, "job `build`: permission")
        body = mutate(QUALITY, "permissions:\n  contents: read\njobs:", "permissions: write-all\njobs:")
        self.assert_ci_violation(body, "is not read-only")

    def test_forbidden_triggers_fail(self) -> None:
        for trigger in ("workflow_run", "workflow_dispatch", "repository_dispatch", "release", "deployment"):
            body = mutate(QUALITY, "on:\n  push:", "on:\n  {}:\n  push:".format(trigger))
            with self.subTest(trigger=trigger):
                self.assert_ci_violation(body, "trigger `{}` is forbidden".format(trigger))

    def test_environment_anywhere_fails(self) -> None:
        body = mutate(QUALITY, JOB_HEADER, "    runs-on: ubuntu-latest\n    environment: github-pages\n    permissions:\n      contents: read\n    steps:")
        self.assert_ci_violation(body, "`environment` is forbidden")

    def test_secrets_context_in_any_expression_fails(self) -> None:
        for old, new in (
            ("      - name: Build\n", "      - name: Build\n        env:\n          T: ${{ secrets.TOKEN }}\n"),
            ("        run: |\n", "        if: ${{ secrets.FLAG == 'x' }}\n        run: |\n"),
            ('          echo "building"', "          echo ${{ secrets.TOKEN }}"),
        ):
            body = mutate(QUALITY, old, new)
            with self.subTest(where=new):
                self.assert_ci_violation(body, "references the `secrets.` context")
        body = mutate(QUALITY, "  build:\n", "  build:\n    secrets: inherit\n")
        self.assert_ci_violation(body, "`secrets` mapping or `secrets: inherit` is forbidden")
        body = mutate(QUALITY, "  build:\n", '  build:\n    "s\\u0065crets": inherit\n')
        self.assert_ci_violation(body, "`secrets` mapping or `secrets: inherit` is forbidden")
        body = mutate(QUALITY, JOB_HEADER, '    runs-on: ubuntu-latest\n    "environm\\u0065nt": prod\n    permissions:\n      contents: read\n    steps:')
        self.assert_ci_violation(body, "`environment` is forbidden")

    def test_obfuscated_secret_references_fail(self) -> None:
        for old, new in (
            ('          echo "building"', "          echo ${{ secrets['TOKEN'] }}"),
            ('          echo "building"', "          echo ${{ secrets . TOKEN }}"),
            ("      - name: Build\n", '      - name: Build\n        env:\n          T: "${{ se\\u0063rets.TOKEN }}"\n'),
            ('          echo "building"', "          echo ${{ toJSON(secrets) }}"),
            ("        run: |\n", "        if: secrets.FLAG == 'x'\n        run: |\n"),
            ("      - name: Build\n", "      - name: Build\n        env:\n          \"${{ secrets.X }}\": y\n"),
        ):
            body = mutate(QUALITY, old, new)
            with self.subTest(new=new):
                self.assert_ci_violation(body, "references the `secrets.` context")
        body = mutate(QUALITY, "      - name: Build\n", '      - name: Build\n        env:\n          T: "\\q"\n')
        self.assert_ci_violation(body, "refused")

    def test_case_variants_and_literal_closers_fail(self) -> None:
        for command in ("echo ${{ SECRETS.MY_TOKEN }}", "echo ${{ GitHub.Token }}",
                        'echo "${{ format(\'}}\', secrets.MY_TOKEN) }}"'):
            body = mutate(QUALITY, 'echo "building"', command)
            with self.subTest(command=command):
                self.assertTrue(self.scan_ci(body), command)
        for command in ("curl $(echo -X POST) https://api.github.com/repos/o/r/git/refs",
                        "curl `echo -X POST` https://api.github.com/repos/o/r/git/refs",
                        'gh api repos/o/r/releases $(printf -- "-f") tag_name=v1'):
            body = mutate(QUALITY, 'echo "building"', command)
            with self.subTest(command=command):
                self.assert_ci_violation(body, "run script contains a")
        body = mutate(QUALITY, "    name: quality / required\n", "    name: quality / required\n    strategy:\n      matrix:\n        os: [ubuntu-latest]\n")
        self.assert_ci_violation(body, "may not carry a `strategy`")

    def test_prose_mentioning_secrets_is_not_a_reference(self) -> None:
        body = mutate(QUALITY, 'echo "building"', "echo 'this job receives no secrets'")
        self.assertEqual(self.scan_ci(body), [])

    def test_github_token_reference_fails(self) -> None:
        for expression in ("${{ github.token }}", "${{ github['token'] }}", "${{ toJSON(github.token) }}", "${{ github . token }}", "${{ github [ 'token' ] }}"):
            body = mutate(QUALITY, 'echo "building"', "echo " + expression)
            with self.subTest(expression=expression):
                self.assert_ci_violation(body, "references `github.token`")

    def test_runner_labels_are_policed(self) -> None:
        for label in ("self-hosted", "macos-latest", "[self-hosted, macOS]", "${{ matrix.os }}", "production-runner", "ubuntu-latest-8-cores"):
            body = mutate(QUALITY, JOB_HEADER, JOB_HEADER.replace("ubuntu-latest", label))
            with self.subTest(label=label):
                self.assert_ci_violation(body, "job `build`: `runs-on")
        # The macOS set holds only the image the recorded workflows use, so a move back to a
        # retired image is refused by the scan, not only by the per-job pins in the other tests.
        for label in ("macos-15", "macos-14"):
            body = mutate(QUALITY, JOB_HEADER, JOB_HEADER.replace("ubuntu-latest", label))
            with self.subTest(retired=label):
                self.assert_ci_violation(body, "job `build`: `runs-on")
        body = mutate(QUALITY, JOB_HEADER, JOB_HEADER.replace("ubuntu-latest", "macos-26"))
        self.assertEqual(self.scan_ci(body), [])

    def test_checkout_must_disable_persisted_credentials_explicitly(self) -> None:
        for replacement in ("      - uses: " + CHECKOUT + "\n        with:\n          fetch-depth: 0\n",
                            "      - uses: " + CHECKOUT + "\n"):
            body = mutate(QUALITY, CHECKOUT_STEP, replacement)
            with self.subTest(replacement=replacement):
                self.assert_ci_violation(body, "persist-credentials: false")

    def test_publish_actions_and_write_commands_fail(self) -> None:
        for uses in ("actions/deploy-pages@0000000000000000000000000000000000000000",
                     "softprops/action-gh-release@0000000000000000000000000000000000000000",
                     "actions/attest-build-provenance@0000000000000000000000000000000000000000",
                     "stefanzweifel/git-auto-commit-action@0000000000000000000000000000000000000000",
                     "someone/deploy-anything@0000000000000000000000000000000000000000",
                     "someone/publish-to-pages@0000000000000000000000000000000000000000"):
            body = mutate(QUALITY, CHECKOUT_STEP, "      - uses: {}\n".format(uses) + CHECKOUT_STEP)
            with self.subTest(uses=uses):
                self.assert_ci_violation(body, "publish, deploy or write path")
        for command in ("git push origin main", "git -C /tmp/x tag v1", "gh release create v1", "gh pr merge 1",
                        "gh workflow run x.yml", "gh api -X POST repos/o/r/releases",
                        "curl -X PATCH https://api.github.com/repos/o/r",
                        "/usr/bin/git push origin main", "git -c user.name=x -C . commit -m x",
                        "git --no-pager push", "curl https://api.github.com/repos/o/r/releases -X POST",
                        "curl -d '{}' https://api.github.com/repos/o/r/issues",
                        "curl --data-binary @f https://api.github.com/repos/o/r/releases/1/assets",
                        "curl -T asset.tgz https://api.github.com/uploads/x", "gh api repos/o/r/issues -f title=x",
                        "gh api --method=DELETE repos/o/r/git/refs/tags/v1", "git update-ref refs/heads/main HEAD",
                        "git \\\n            push origin main", "git --git-dir .git push", "curl -XPOST https://api.github.com/x",
                        "curl -d'{}' https://api.github.com/x", "gh -R o/r release create v1",
                        "gh api repos/o/r/issues \\\n            -f title=x",
                        'git -c user.name="CI Bot" push origin main', "curl -sSXPOST https://api.github.com/x",
                        '"git" push origin main', "g\\it pu\\sh origin main", 'gh api "--method" DELETE repos/o/r/git/refs/tags/v1', "curl '--request' DELETE https://api.github.com/x",
                        "curl --form-string a=b https://api.github.com/x", "docker buildx build --push -t x ."):
            body = mutate(QUALITY, 'echo "building"', command)
            with self.subTest(command=command):
                self.assert_ci_violation(body, "run script contains a")

    def test_checkout_credential_options_fail_everywhere(self) -> None:
        for option in ("token: ${{ github.token }}", "ssh-key: x", "github-server-url: https://example.com"):
            body = mutate(QUALITY, "          persist-credentials: false\n", "          persist-credentials: false\n          " + option + "\n")
            with self.subTest(option=option):
                self.assert_ci_violation(body, "checkout option `" + option.split(":")[0] + "` is forbidden")

    def test_more_publish_paths_fail(self) -> None:
        for command in ("npm publish", "cargo publish", "twine upload dist/*", "docker push ghcr.io/x/y",
                        "aws s3 cp a s3://b", 'curl -X POST -T a.tgz "https://uploads.github.com/repos/o/r/releases/1/assets?name=a"',
                        'curl -X POST "$GITHUB_API_URL/repos/o/r/git/refs" -d @body', "gh run download 1"):
            body = mutate(QUALITY, 'echo "building"', command)
            with self.subTest(command=command):
                self.assert_ci_violation(body, "run script contains a")

    def test_action_forms_outside_the_scan_are_refused(self) -> None:
        for uses in ("./.github/actions/local-publisher", "docker://alpine:3", "actions/checkout@v4",
                     "Peter-Evans/Create-Pull-Request@0000000000000000000000000000000000000000"):
            body = mutate(QUALITY, CHECKOUT_STEP, "      - uses: {}\n".format(uses) + CHECKOUT_STEP)
            with self.subTest(uses=uses):
                self.assertTrue(any("job `build` step 1" in v for v in self.scan_ci(body)), uses)
        body = mutate(QUALITY, CHECKOUT_STEP,
                      "      - uses: actions/github-script@0000000000000000000000000000000000000000\n        with:\n"
                      "          script: await github.rest.repos.createRelease({tag_name:'v9'})\n" + CHECKOUT_STEP)
        self.assert_ci_violation(body, "github-script body contains a write call")
        body = mutate(QUALITY, CHECKOUT_STEP,
                      "      - uses: actions/github-script@0000000000000000000000000000000000000000\n        with:\n"
                      "          script: core.setOutput('b', (await github.rest.repos.get(context.repo)).data.default_branch)\n" + CHECKOUT_STEP)
        self.assertEqual(self.scan_ci_rules(body), [])

    def test_interpreter_swaps_and_non_string_run_fail(self) -> None:
        body = mutate(QUALITY, "        run: |\n", "        shell: python\n        run: |\n")
        self.assert_ci_violation(body, "is not an admitted interpreter")
        body = mutate(QUALITY, "permissions:\n  contents: read\njobs:", "permissions:\n  contents: read\ndefaults:\n  run:\n    shell: python\njobs:")
        self.assert_ci_violation(body, "`defaults.run.shell: python`")
        body = mutate(QUALITY, "  build:\n", "  build:\n    defaults:\n      run:\n        shell: bash -e {0} && git push\n")
        self.assert_ci_violation(body, "is not an admitted interpreter")
        body = mutate(QUALITY, "        run: |\n          set -euo pipefail\n          echo \"building\"  # a comment inside a block scalar is text", "        run: [git, push]")
        self.assert_ci_violation(body, "`run` must be a string scalar")
        body = mutate(QUALITY, "        run: |\n", "        shell: bash\n        run: |\n")
        self.assertEqual(self.scan_ci(body), [])

    def test_container_services_and_boolean_alias_roots_fail(self) -> None:
        body = mutate(QUALITY, JOB_HEADER, "    container: evil/image:latest\n" + JOB_HEADER)
        self.assert_ci_violation(body, "`container` is not admitted")
        body = mutate(QUALITY, JOB_HEADER, "    services:\n      db:\n        image: attacker/pg\n" + JOB_HEADER)
        self.assert_ci_violation(body, "`services` is not admitted")
        body = mutate(QUALITY, "permissions:\n  contents: read\njobs:", "true:\n  workflow_dispatch:\npermissions:\n  contents: read\njobs:")
        self.assert_ci_violation(body, "root key `true` is a YAML 1.1 boolean alias")

    def test_permissions_empty_mapping_and_single_label_list_are_accepted(self) -> None:
        body = mutate(QUALITY, JOB_HEADER, "    runs-on: [ubuntu-latest]\n    permissions: {}\n    steps:")
        self.assertEqual(self.scan_ci(body), [])
        body = mutate(QUALITY, "    steps:\n      - uses: " + CHECKOUT, "    steps:\n    - uses: " + CHECKOUT)
        body = body.replace("        with:\n          persist-credentials: false\n      - name: Build\n        run: |\n          set -euo pipefail\n          echo \"building\"  # a comment inside a block scalar is text",
                            "      with:\n        persist-credentials: false\n    - name: Build\n      run: |\n        set -euo pipefail\n        echo \"building\"  # a comment inside a block scalar is text")
        self.assertEqual(self.scan_ci(body), [])

    def test_run_command_patterns_are_linear_on_option_floods(self) -> None:
        import time
        floods = ["git " + "-c a=b " * 300 + "status", "git " + "-c " * 400, "git -c " + '"' * 600 + " x",
                  "curl " + "-d " * 400 + "https://api.github.com/x", "gh " + "-R o/r " * 400 + "api x",
                  "git " + "--no-pager " * 400 + "log", "git " + "-c a='b c' " * 300 + "push"]
        started = time.perf_counter()
        for flood in floods:
            for _label, pattern in policy.FORBIDDEN_RUN_RES:
                pattern.search(flood)
        self.assertLess(time.perf_counter() - started, 5.0, "a write-command pattern backtracks super-linearly")

    def test_read_only_git_and_gh_are_allowed(self) -> None:
        body = mutate(QUALITY, 'echo "building"', "git status && gh api repos/o/r && git describe --tags && curl -f -sS https://api.github.com/repos/o/r")
        self.assertEqual(self.scan_ci(body), [])
        body = mutate(QUALITY, 'echo "building"', "LATEST=$(git tag --list 'v*' --sort=-v:refname | head -1) && git notes show HEAD && git tag -l")
        self.assertEqual(self.scan_ci(body), [])
        body = mutate(QUALITY, 'echo "building"', "cat config/secrets.json && echo done")
        self.assertEqual(self.scan_ci(body), [])
        body = mutate(QUALITY, CHECKOUT_STEP, CHECKOUT_STEP + "      - uses: someone/tool@0000000000000000000000000000000000000000\n        with:\n          environment: staging\n")
        self.assertEqual(self.scan_ci_rules(body), [])
        body = mutate(QUALITY, 'echo "building"', "git log --format=%s origin/main..HEAD  # check every commit header\n          curl -d x https://example.com/")
        self.assertEqual(self.scan_ci(body), [])
        body = mutate(QUALITY, CHECKOUT_STEP, "      - uses: wagoid/commitlint-github-action@0000000000000000000000000000000000000000\n" + CHECKOUT_STEP)
        self.assertEqual(self.scan_ci_rules(body), [])

    def test_duplicate_check_names_across_workflows_fail(self) -> None:
        other = QUALITY.replace("name: CI", "name: Other").replace("  build:", "  build2:").replace("needs: [build]", "needs: [build2]")
        violations = self.scan({"ci.yml": QUALITY, "other.yml": other, "governance.yml": METADATA})
        self.assertTrue(any("check `quality / required` is also produced by" in v for v in violations), violations)

    def test_duplicate_check_names_within_one_workflow_fail(self) -> None:
        body = mutate(QUALITY, "  build:\n    runs-on", "  build:\n    name: quality / required\n    runs-on")
        self.assert_ci_violation(body, "check `quality / required` is also produced by job")

    def test_a_comment_after_a_mid_value_question_mark_cannot_hide_a_duplicate_check_name(self) -> None:
        # YAML reads both names as `lint ? 'fast` (the rest of the second is a comment), so the two
        # jobs produce one check name; read with the quote opened, the second would differ.
        body = mutate(QUALITY, "  build:\n    runs-on", "  build:\n    name: lint ? 'fast\n    runs-on")
        body = mutate(body, "  quality-required:\n",
                      "  lint:\n    name: lint ? 'fast #shadow'\n    runs-on: ubuntu-latest\n    permissions:\n"
                      "      contents: read\n    steps:\n      - run: echo lint\n  quality-required:\n")
        self.assert_ci_violation(body, "check `lint ? 'fast` is also produced by job")

    def test_recorded_trigger_set_drift_fails(self) -> None:
        body = mutate(QUALITY, "types: [opened, edited, synchronize, reopened]", "types: [opened, synchronize, reopened]")
        self.assert_ci_violation(body, "trigger set differs from the recorded")
        body = mutate(QUALITY, "branches: [main]", "branches: [main, release/*]")
        self.assert_ci_violation(body, "trigger set differs from the recorded")

    def test_recorded_trigger_set_is_order_insensitive(self) -> None:
        body = mutate(QUALITY, "types: [opened, edited, synchronize, reopened]", "types: [reopened, synchronize, edited, opened]")
        self.assertEqual(self.scan_ci(body), [])

    def test_missing_recorded_check_fails(self) -> None:
        body = mutate(QUALITY, "    name: quality / required\n", "")
        self.assert_ci_violation(body, "recorded required check `quality / required` is produced by no workflow")

    def test_exactly_one_pull_request_target_workflow(self) -> None:
        violations = self.scan({"ci.yml": QUALITY})
        self.assertTrue(any("exactly one pull_request_target workflow is required; found 0" in v for v in violations), violations)
        second = METADATA.replace("name: Governance", "name: Second").replace("governance / required", "second / required")
        violations = self.scan({"ci.yml": QUALITY, "governance.yml": METADATA, "second.yml": second})
        self.assertTrue(any("exactly one pull_request_target workflow is required; found 2" in v for v in violations), violations)

    def test_pull_request_target_may_not_touch_the_proposal_head(self) -> None:
        base_ref = "ref: ${{ github.event.pull_request.base.sha }}"
        for old, new in (
            (base_ref, "ref: ${{ github.event.pull_request.head.sha }}"),
            (base_ref, "ref: refs/pull/1/merge"),
            (base_ref, "ref: ${{ github.event.pull_request['head']['sha'] }}"),
            ("      - run: python3", "      - run: git fetch origin pull/1/head && git checkout FETCH_HEAD\n      - run: python3"),
            ("      - run: python3", "      - run: gh pr checkout 1\n      - run: python3"),
            ("      - run: python3", "      - run: echo ${{ github.event.pull_request.HEAD.SHA }}\n      - run: python3"),
            ("      - run: python3", "      - run: curl -sSL ${{ github.event.pull_request.diff_url }}\n      - run: python3"),
            ("      - run: python3", "      - run: echo ${{ github.event.pull_request.merge_commit_sha }}\n      - run: python3"),
            ("      - run: python3", "      - run: git fetch origin pull/${{ github.event.number }}/head\n      - run: python3"),
            ("      - run: python3", "      - run: gh pr -R o/r checkout 1\n      - run: python3"),
            ("      - run: python3", "      - run: gh pr --repo=o/r checkout 1\n      - run: python3"),
            ("      - run: python3", "      - run: echo '${{ toJSON(github.event.pull_request) }}' > pr.json\n      - run: python3"),
            ("      - run: python3", "      - run: echo '${{ toJSON(github.event) }}' > ev.json\n      - run: python3"),
            ("      - run: python3", "      - run: echo '${{ toJSON(github) }}' > gh.json\n      - run: python3"),
            ("      - run: python3", "      - run: echo '${{ toJSON(github.*) }}' > gh.json\n      - run: python3"),
            ("      - run: python3", "      - run: echo '${{ toJSON(github.event.*) }}' > gh.json\n      - run: python3"),
            ("      - run: python3", "      - run: gh \"pr\" checkout 1\n      - run: python3"),
            ("      - run: python3", "      - run: gh p\\r checkout 1\n      - run: python3"),
            ("      - run: python3", "      - run: git fetch origin p\\ull/1/head\n      - run: python3"),
            ("      - run: python3", "      - run: |\n          git fetch origin pu\\\n          ll/1/head\n      - run: python3"),
            ("      - run: python3", "      - run: |\n          gh pr \\\n            checkout 1\n      - run: python3"),
            ("      - run: python3", "      - run: curl -sSL https://example.com/o/r/pull/1/files\n      - run: python3"),
            ("      - run: python3", "      - run: curl -sSL https://example.com/o/r/pull/1.diff\n      - run: python3"),
            ("    name: governance / required\n", "    name: ${{ 'governance / required' }}\n"),
            ("      - run: python3", "      - run: curl -sSL https://api.github.com/repos/o/r/actions/artifacts/1/zip -o a.zip\n      - run: python3"),
            ("      - run: python3", "      - run: git clone ${{ github.event.pull_request.head.repo.clone_url }} x\n      - run: python3"),
            ("- uses: " + CHECKOUT + "\n        with:\n          " + base_ref + "\n          persist-credentials: false\n",
             "- uses: " + CHECKOUT.replace("actions/checkout", "Actions/Checkout") + "\n        with:\n          " + base_ref + "\n"),
            ("      - run: python3", "      - uses: actions/download-artifact@0000000000000000000000000000000000000000\n      - run: python3"),
            ("          persist-credentials: false\n", "          persist-credentials: false\n          repository: someone/else\n"),
            ("permissions:\n  contents: read\njobs:", "permissions:\n  contents: read\nenv:\n  HEAD_REF: ${{ github.head_ref }}\njobs:"),
            ("        with:\n          " + base_ref + "\n          persist-credentials: false\n",
             "        with:\n          persist-credentials: false\n"),
        ):
            body = mutate(METADATA, old, new)
            with self.subTest(new=new):
                violations = self.scan({"ci.yml": QUALITY, "governance.yml": body})
                self.assertTrue(violations, "expected a violation for {!r}".format(new))

    def test_pull_request_target_may_read_event_name_and_base_fields(self) -> None:
        body = mutate(METADATA, "      - run: python3", "      - run: echo ${{ github.event_name }} ${{ github.event.number }} ${{ github.event.pull_request.number }}\n      - run: python3")
        self.assertEqual(self.scan({"ci.yml": QUALITY, "governance.yml": body}), [])

    def test_whitespace_other_than_space_tab_and_line_feed_is_refused(self) -> None:
        # Python's isspace() treats a no-break space as whitespace; YAML and bash do not. Before
        # this refusal, `echo ok<NBSP># ; gh release create v1` parsed here as `echo ok` plus a
        # comment, while GitHub kept the whole line and the runner's shell ran the release.
        hidden = mutate(QUALITY, CHECKOUT_STEP,
                        "      - run: echo ok\u00a0# ; gh release create v1\n" + CHECKOUT_STEP)
        violations = self.scan_ci(hidden)
        self.assertTrue(any("ci.yml: refused" in v and "U+00A0" in v for v in violations), violations)
        for character in ("\u00a0", "\u2009", "\u3000", "\u2028", "\u2029", "\x85", "\x0b", "\x0c", "\x1c", "\r"):
            codepoint = "U+{:04X}".format(ord(character))
            body = mutate(QUALITY, CHECKOUT_STEP, "      - run: echo ok{}x\n".format(character) + CHECKOUT_STEP)
            with self.subTest(codepoint=codepoint):
                violations = self.scan_ci(body)
                self.assertTrue(any("ci.yml: refused" in v and codepoint in v for v in violations), violations)
        # Space and tab still start a comment exactly as YAML and the shell do: the recorded
        # write inside the comment is text, and would be flagged if the boundary were missed.
        for separator in (" ", "\t"):
            body = mutate(QUALITY, CHECKOUT_STEP,
                          "      - run: echo ok{}# gh release create v1\n".format(separator) + CHECKOUT_STEP)
            with self.subTest(separator=repr(separator)):
                self.assertEqual(self.scan_ci(body), [])

    def test_decoded_escapes_and_unprintable_characters_are_refused(self) -> None:
        # A double-quoted escape yields characters the file's text never held: `\_` is a
        # no-break space, so `"ubuntu-latest\_"` stripped to an admitted runner label here while
        # GitHub read a different, custom one. Decoded scalars are checked as well.
        build_runner = "  build:\n    runs-on: ubuntu-latest\n"
        for escape, codepoint in (("\\_", "U+00A0"), ("\\N", "U+0085"), ("\\L", "U+2028"), ("\\P", "U+2029"),
                                  ("\\r", "U+000D"), ("\\v", "U+000B"), ("\\f", "U+000C"), ("\\0", "U+0000"),
                                  ("\\e", "U+001B"), ("\\x7f", "U+007F"), ("\\u0086", "U+0086"),
                                  ("\\ud800", "U+D800"), ("\\u3000", "U+3000")):
            body = mutate(QUALITY, build_runner,
                          "  build:\n    runs-on: \"ubuntu-latest{}\"\n".format(escape))
            with self.subTest(escape=escape):
                violations = self.scan_ci(body)
                self.assertTrue(any("ci.yml: refused" in v and codepoint in v for v in violations), violations)
        # Admitted whitespace survives decoding, so the allowlists compare exactly, unstripped.
        for label in ('"ubuntu-latest "', '" ubuntu-latest"', '"ubuntu-latest\\t"', '"ubuntu-latest\\n"',
                      '["ubuntu-latest "]'):
            body = mutate(QUALITY, build_runner, "  build:\n    runs-on: {}\n".format(label))
            with self.subTest(label=label):
                self.assert_ci_violation(body, "ADMITTED_RUNNER_LABELS")
        # The escape check walks every list item and every key, not only mapping values: a `run:`
        # sits inside the `steps` list, where `g\0h` read as two words here but `gh` to the shell,
        # which drops a NUL; and a quoted key decodes like a value.
        for fragment, codepoint in (('      - run: "echo ok\\ng\\0h release create v1"\n', "U+0000"),
                                    ('      - env:\n          "A\\_B": x\n        run: echo ok\n', "U+00A0")):
            body = mutate(QUALITY, CHECKOUT_STEP, fragment + CHECKOUT_STEP)
            with self.subTest(fragment=fragment):
                violations = self.scan_ci(body)
                self.assertTrue(any("ci.yml: refused" in v and codepoint in v for v in violations), violations)
        for ref in ('"${{ github.event.pull_request.base.sha }} "', '"${{ github.event.pull_request.base.sha }}\\n"'):
            body = mutate(METADATA, "ref: ${{ github.event.pull_request.base.sha }}", "ref: " + ref)
            with self.subTest(ref=ref):
                violations = self.scan({"ci.yml": QUALITY, "governance.yml": body})
                self.assertTrue(any("must pin `ref`" in v for v in violations), violations)
        # Characters outside YAML's printable set, a byte-order mark and bidirectional controls are
        # refused in the file's text too.
        for character in ("\x00", "\x01", "\x7f", "\x86", "\ufffe", "\ufeff", "\u202e", "\u2066", "\u061c", "\u200e", "\u200f"):
            codepoint = "U+{:04X}".format(ord(character))
            body = mutate(QUALITY, CHECKOUT_STEP, "      - run: echo ok{}x\n".format(character) + CHECKOUT_STEP)
            with self.subTest(codepoint=codepoint):
                violations = self.scan_ci(body)
                self.assertTrue(any("ci.yml: refused" in v and codepoint in v for v in violations), violations)

    def test_invisible_characters_are_refused_in_text_and_decoded_scalars(self) -> None:
        # A zero-width space, a variation selector or a Hangul filler changes no parse here, but
        # the file a code owner reviews then differs from the file every reader runs.
        for character in INVISIBLE_SAMPLES:
            codepoint = "U+{:04X}".format(ord(character))
            body = mutate(QUALITY, CHECKOUT_STEP, "      - run: echo ok{}x\n".format(character) + CHECKOUT_STEP)
            with self.subTest(codepoint=codepoint):
                violations = self.scan_ci(body)
                self.assertTrue(any("ci.yml: refused" in v and codepoint in v and "invisible" in v
                                    for v in violations), violations)
        # A double-quoted escape decodes to one as well.
        build_runner = "  build:\n    runs-on: ubuntu-latest\n"
        for escape, codepoint in (("\\u200b", "U+200B"), ("\\ue000", "U+E000"), ("\\u3164", "U+3164"),
                                  ("\\U000e0041", "U+E0041"), ("\\ufe0f", "U+FE0F")):
            body = mutate(QUALITY, build_runner, "  build:\n    runs-on: \"ubuntu-latest{}\"\n".format(escape))
            with self.subTest(escape=escape):
                violations = self.scan_ci(body)
                self.assertTrue(any("ci.yml: refused" in v and codepoint in v for v in violations), violations)
        # A decoded scalar has no source line of its own, so only its code point is named.
        with self.assertRaises(policy.ParseError) as decoded:
            policy.parse_workflow('on: push\nname: "a\\u200bb"\n')
        self.assertEqual(str(decoded.exception), "a scalar decodes to character U+200B, which is refused")
        with self.assertRaises(policy.ParseError) as refusal:
            policy.parse_workflow("on: push\n# a\u200bb\n")
        self.assertEqual(
            str(refusal.exception),
            "line 2: character U+200B is refused (an invisible format, private-use, unassigned, "
            "default-ignorable or blank character, which a reviewer cannot see, such as a variation "
            "selector after an emoji)",
        )
        # Visible text, a space and a tab pass; the extra set holds no format or unassigned code
        # point, which category alone would cover.
        self.assertIsNone(policy.first_invisible_character("a b\tc\n\u00e9\n"))
        self.assertEqual(policy.first_invisible_character("a\nb\u2060c\n"), (2, 0x2060))
        import unicodedata
        self.assertFalse(any(unicodedata.category(chr(code)) in ("Cf", "Co", "Cn")
                             for code in policy.INVISIBLE_OUTSIDE_FORMAT))
        # The set itself, written out independently: the copies in action_pins.py and
        # bats_inventory.py only agree with this one, so an edit to all three needs this to change.
        expected = {0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B, 0x180C, 0x180D, 0x180F, 0x2800,
                    0x3164, 0xFFA0}
        expected |= {code for code in range(0xFE00, 0xFE0F + 1)}
        expected |= {code for code in range(0xE0100, 0xE01EF + 1)}
        self.assertEqual(set(policy.INVISIBLE_OUTSIDE_FORMAT), expected)

    def test_a_pin_hidden_behind_a_no_break_space_is_refused(self) -> None:
        # With the no-break space read as a comment start and then stripped, both scanners saw the
        # approved `@<sha> # <version>`; GitHub reads `@<sha><NBSP>#<NBSP><version>`, a non-SHA ref.
        hidden = CHECKOUT.replace(" # ", "\u00a0#\u00a0")
        self.assertNotEqual(hidden, CHECKOUT)
        violations = self.scan_ci(QUALITY.replace(CHECKOUT, hidden))
        self.assertTrue(any("ci.yml: refused" in v and "U+00A0" in v for v in violations), violations)

    def test_a_pin_with_a_decoded_trailing_line_feed_is_refused(self) -> None:
        # Python's `$` also matches before a final line feed, and a decoded line feed is admitted,
        # so `"<action>@<sha>\n"` matched the pin shape until the comparison became a full match.
        pinned, version = CHECKOUT.split(" # ")
        quoted = QUALITY.replace("- uses: " + CHECKOUT, '- uses: "{}\\n" # {}'.format(pinned, version))
        self.assertNotEqual(quoted, QUALITY)
        self.assert_ci_violation(quoted, "is not a remote action pinned to a full commit SHA")

    def test_padded_job_names_are_refused(self) -> None:
        # `quality / required ` is a different check context than the recorded one; whether GitHub
        # would trim it is not something the scan should have to know.
        for name in ('"quality / required "', '" quality / required"', '"quality / required\\t"',
                     '"quality /\\nrequired"'):
            body = mutate(QUALITY, "    name: quality / required\n", "    name: {}\n".format(name))
            with self.subTest(name=name):
                self.assert_ci_violation(body, "may not begin or end with whitespace")

    def test_block_scalar_indentation_follows_yaml(self) -> None:
        # YAML takes a block scalar's indentation from its first non-empty line, and a `#` line
        # inside it is content. Taking it from the first non-comment line instead let a shallow
        # leading `#` line lower YAML's indentation while the parser dropped a trailing `#` line
        # that the shell then ran through a continuation or an open quote.
        for body_lines in (("# setup", "  echo ok\\", "#; gh release create v1"),
                           ("# setup", '  python3 -c "print(1)', '#"; gh release create v1')):
            block = "      - run: |\n" + "".join("          {}\n".format(line) for line in body_lines)
            body = mutate(QUALITY, CHECKOUT_STEP, block + CHECKOUT_STEP)
            with self.subTest(body_lines=body_lines):
                document = policy.parse_workflow(body)
                run = document["jobs"]["build"]["steps"][0]["run"]
                self.assertIn(body_lines[-1], run)
                self.assert_ci_violation(body, "run script contains a")

    def test_block_scalar_values_match_libyaml(self) -> None:
        # Values recorded from libyaml 0.2.1 (Ruby Psych 3.1): leading empty lines, clip, strip and
        # keep chomping, folding around more-indented lines, whitespace-only content lines, and a
        # block that ends the file without a final line feed.
        cases = (
            ("k: |\n  a\n  b\n", "a\nb\n"),
            ("k: |-\n  a\n  b\n", "a\nb"),
            ("k: |+\n  a\n\n\nn: x\n", "a\n\n\n"),
            ("k: |\n\n  a\n", "\na\n"),
            ("k: >\n  a\n  b\n\n  c\n", "a b\nc\n"),
            ("k: >\n  a\n    b\n  c\n", "a\n  b\nc\n"),
            ("k: >-\n  a\n\n    b\n", "a\n\n  b"),
            ("k: |\n  a\n     \n  b\n", "a\n   \nb\n"),
            ("k: |+\n\nn: x\n", "\n"),
            ("k: |\n  a", "a"),
            ("k: |\n  # c\n    x\n", "# c\n  x\n"),
            ("k: >+\n  a\n  b\n\n", "a b\n\n"),
            ("k: |+\n  a\n  ", "a\n"),
            ("k: |+\n\n  ", "\n"),
            ("k: |+\n  ", ""),
            ("k: |+\n  \n", "\n"),
            ("k: |\n  \n  a\n", "\na\n"),
            ("k: |\n  a\n  \nn: x\n", "a\n"),
        )
        for text, expected in cases:
            with self.subTest(text=text):
                self.assertEqual(policy.parse_workflow(text)["k"], expected)
        # Each of these is an error to libyaml: a leading empty line deeper than the first content
        # line, and a tab where indentation is expected, on an empty, content or comment-looking line.
        for text in ("k: |\n      \n  a\n", "k: |\n  a\n\t\n  b\n", "k: x\n\t\nn: y\n",
                     "k: |\n \ta\n", "k: |\n  a\n \tb\n", "k: |\n  \t# a\n", "k: |\n  a\n \t# b\n"):
            with self.subTest(refused=text), self.assertRaises(policy.ParseError):
                policy.parse_workflow(text)
        # libyaml accepts these, and this parser refuses them. In the first three the tab falls after
        # the block's indentation and is content, but the parser refuses a tab in any line's leading
        # whitespace rather than track where it is content. In the last, libyaml reads a leading empty
        # line deeper than the first content line as an empty block; the YAML specification makes it
        # an error, and the parser follows the specification.
        for text in ("k: |\n  a\n  \tb\n", "k: |\n  a\n  \t# b\n", "k: >\n  a\n  \t\n  b\n",
                     "k: |\n    \n  # c\nn: v\n"):
            with self.subTest(over_refused=text), self.assertRaises(policy.ParseError):
                policy.parse_workflow(text)

    def test_block_scalar_values_meet_the_exact_comparisons(self) -> None:
        # A block scalar keeps its final line feed, so it can no longer read as an admitted label,
        # a recorded check name or the base ref (it did while the value was trimmed).
        body = mutate(QUALITY, "  build:\n    runs-on: ubuntu-latest\n", "  build:\n    runs-on: |\n      ubuntu-latest\n")
        self.assert_ci_violation(body, "ADMITTED_RUNNER_LABELS")
        body = mutate(QUALITY, "    name: quality / required\n", "    name: |\n\n      quality / required\n")
        self.assert_ci_violation(body, "may not begin or end with whitespace")
        governance = mutate(METADATA, "ref: ${{ github.event.pull_request.base.sha }}",
                            "ref: |\n                ${{ github.event.pull_request.base.sha }}")
        violations = self.scan({"ci.yml": QUALITY, "governance.yml": governance})
        self.assertTrue(any("must pin `ref`" in v for v in violations), violations)

    def test_explicit_block_indentation_indicators_are_refused(self) -> None:
        # The parser accepted `|-2` and then ignored the indicator, so it could disagree with YAML
        # about where the scalar ends. No tracked file uses one.
        for indicator in ("|2", "|-2", "|2-", ">2", ">+1"):
            body = mutate(QUALITY, CHECKOUT_STEP,
                          "      - run: {}\n            echo ok\n".format(indicator) + CHECKOUT_STEP)
            with self.subTest(indicator=indicator):
                violations = self.scan_ci(body)
                self.assertTrue(any("ci.yml: refused" in v and "indentation indicator" in v for v in violations),
                                violations)

    def test_every_uses_is_checked_against_the_reviewed_pin_allowlist(self) -> None:
        # One source of truth: the scan checks each parsed `uses` against
        # .github/actions-allowlist.json, read through action_pins.load_allowlist, so a line the
        # action-pin line scan skips is still judged here.
        sha = "0123456789abcdef0123456789abcdef01234567"
        body = mutate(QUALITY, CHECKOUT_STEP, "      - uses: actions/cache@{} # v1.0.0\n".format(sha) + CHECKOUT_STEP)
        self.assert_ci_violation(body, "not in the reviewed action-pin allowlist")
        hidden = mutate(QUALITY, CHECKOUT_STEP,
                        "      - name: |\n        uses: attacker/evil-action@{} # v1.0.0\n".format(sha) + CHECKOUT_STEP)
        self.assert_ci_violation(hidden, "not in the reviewed action-pin allowlist")
        # An approved name at a SHA outside the allowlist is refused too, visible or hidden.
        version = CHECKOUT.split(" # ")[1]
        for fragment in ("      - uses: actions/checkout@{} # {}\n".format(sha, version),
                         "      - name: |\n        uses: actions/checkout@{} # {}\n".format(sha, version)):
            body = mutate(QUALITY, CHECKOUT_STEP, fragment + CHECKOUT_STEP)
            with self.subTest(fragment=fragment):
                self.assert_ci_violation(body, "not in the reviewed action-pin allowlist")

    def test_printed_violations_escape_characters_that_could_start_a_line(self) -> None:
        # A decoded key or value may hold a line feed; printed verbatim, a following `::error::`
        # would reach the runner as a workflow command.
        body = QUALITY.replace("  build:\n", '  "a\\n::error::injected":\n    runs-on: ubuntu-latest\n  build:\n', 1)
        write_tree(self.root, {"ci.yml": body, "governance.yml": METADATA})
        result = subprocess.run([sys.executable, "-I", "-S", "-B", str(SCRIPT), "--root", str(self.root)],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                check=False)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("::error::injected", result.stderr)
        self.assertFalse(any(line.startswith("::") for line in result.stderr.splitlines()), result.stderr)

    def test_unparseable_workflow_is_a_violation_not_a_pass(self) -> None:
        violations = self.scan({"ci.yml": QUALITY, "governance.yml": METADATA, "odd.yml": "name: x\non: push\njobs: {a: b}\n"})
        self.assertTrue(any("odd.yml: refused" in v for v in violations), violations)


class AllowlistTests(unittest.TestCase):
    """The scan and the action-pin check judge every `uses` against the same allowlist file."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name) / "tree"
        self.lists = Path(self._tmp.name) / "lists"
        self.lists.mkdir()
        write_tree(self.root, {"ci.yml": QUALITY, "governance.yml": METADATA})

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def allowlist(self, name: str, document: dict) -> Path:
        path = self.lists / name
        path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
        return path

    def test_both_checkers_refuse_an_unlisted_action_and_a_listed_action_at_another_sha(self) -> None:
        self.assertEqual(policy.scan_repository(self.root), [])
        self.assertEqual(pins.validate_repository(self.root), [])
        sha = "0123456789abcdef0123456789abcdef01234567"
        reviewed_version = pins.load_allowlist(ALLOWLIST)["actions/checkout"][1]
        for fragment in ("      - uses: example/unlisted@{} # v1.0.0\n".format(sha),
                         "      - uses: actions/checkout@{} # {}\n".format(sha, reviewed_version)):
            with self.subTest(fragment=fragment):
                write_tree(self.root, {"ci.yml": mutate(QUALITY, CHECKOUT_STEP, fragment + CHECKOUT_STEP)})
                self.assertTrue(any("ci.yml" in v and "reviewed action-pin allowlist" in v
                                    for v in policy.scan_repository(self.root)))
                self.assertTrue(any("ci.yml" in e and "reviewed allowlist" in e
                                    for e in pins.validate_repository(self.root)))

    def test_a_narrowed_or_repinned_allowlist_turns_both_checkers_red(self) -> None:
        tracked = json.loads(ALLOWLIST.read_text(encoding="utf-8"))
        narrowed = dict(tracked, actions=[entry for entry in tracked["actions"] if entry["name"] != "actions/checkout"])
        repinned = dict(tracked, actions=[dict(entry, sha="0" * 40) if entry["name"] == "actions/checkout" else entry
                                          for entry in tracked["actions"]])
        for label, document in (("narrowed", narrowed), ("repinned", repinned)):
            with self.subTest(allowlist=label):
                path = self.allowlist(label + ".json", document)
                self.assertEqual(policy.scan_repository(self.root, path),
                                 ["{}: job `{}` step 1: `uses` is not in the reviewed action-pin allowlist "
                                  "(.github/actions-allowlist.json)".format(name, job)
                                  for name, job in ((".github/workflows/ci.yml", "build"),
                                                    (".github/workflows/governance.yml", "required"))])
                errors = pins.validate_repository(self.root, path)
                self.assertEqual(len(errors), 2, errors)
                self.assertTrue(all("reviewed allowlist" in error for error in errors), errors)

    def test_an_allowlist_that_does_not_load_is_a_violation_not_a_pass(self) -> None:
        # The scan reports exactly the loader's own value-free message, so both checkers read the
        # file through one loader, and a list that does not load never lets a tree pass.
        tracked = json.loads(ALLOWLIST.read_text(encoding="utf-8"))
        bad = {
            "missing": self.lists / "absent.json",
            "schema_version true": self.allowlist("bool.json", dict(tracked, schema_version=True)),
            "unsorted": self.allowlist("unsorted.json", dict(tracked, actions=tracked["actions"][::-1])),
        }
        for label, path in bad.items():
            with self.subTest(allowlist=label):
                with self.assertRaises(ValueError) as caught:
                    pins.load_allowlist(path)
                message = str(caught.exception)
                self.assertTrue(message.startswith(".github/actions-allowlist.json: "), message)
                self.assertEqual(policy.scan_repository(self.root, path), [message])
                self.assertEqual(pins.validate_repository(self.root, path), [message])


class RepositoryTests(unittest.TestCase):
    def test_repository_workflows_pass_the_scan(self) -> None:
        self.assertEqual(policy.scan_repository(REPO_ROOT), [])

    def test_cli_exit_status(self) -> None:
        result = subprocess.run([sys.executable, "-I", "-S", "-B", str(SCRIPT), "--root", str(REPO_ROOT)],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        with tempfile.TemporaryDirectory() as empty:
            result = subprocess.run([sys.executable, "-I", "-S", "-B", str(SCRIPT), "--root", empty],
                                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
            self.assertEqual(result.returncode, 1)
            self.assertIn("no workflows found", result.stderr)


if __name__ == "__main__":
    unittest.main()
