#!/usr/bin/env python3
"""Static read-only scan of every workflow under `.github/workflows/` (design section 18 step 17).

Verified on PARSED YAML, never by text search. The parser accepts exactly the subset
`scripts/ci/action_pins.py` already enforces (block mappings, block sequences, scalar-only
flow sequences, quoted scalars, literal/folded block scalars, comments) and refuses
everything else, so a workflow that hides structure from this scanner fails the scan
rather than passing it.

    python3 -I -S -B scripts/ci/workflow_policy.py [--root <repo>]

What must hold for every workflow (exit 0), each named in the violations otherwise:

- triggers: only `push`, `pull_request`, `pull_request_target`, `schedule` and
  `workflow_call`; never `workflow_run`, `workflow_dispatch`, `repository_dispatch`,
  `deployment*`, `release`, `registry_package` or `page_build`;
- a top-level `permissions` block AND a `permissions` block on every job, each either
  `read-all` or a mapping whose every value is `read` or `none`; never `write`,
  `write-all`, `id-token`, `pages`, `deployments`, `attestations` or `packages`;
- no `environment` on any job (Section 3 permits none before launch; a referenced name
  would create an unprotected environment); no `strategy` on a job that produces a
  recorded required check (a matrix reports `name (value)` contexts, not the recorded one);
- no `secrets` context reference in any expression (dotted or bracket-indexed, in a
  `${{ }}` block or a bare `if:`), under `env`, `with`, `run`, `if`, a mapping key or
  anywhere else, no `secrets:` mapping, no `secrets: inherit`; double-quoted scalars are
  decoded with YAML's full escape set first, and an escape outside that set is a refusal;
- no `github.token` reference in any expression (dotted or bracket-indexed);
- every `runs-on` is one of the ADMITTED hosted labels below (no `self-hosted`, no
  floating `macos-latest`, no custom label, no expression, no label group);
- every `actions/checkout` step sets `persist-credentials: false` explicitly;
- no action from the explicit write-action denylist and none whose path names a
  release, deploy, publish, attest or Pages capability; no `git push` / `commit` /
  `tag` / `update-ref` (path-prefixed or option-laden forms included), `gh release`,
  `gh pr merge`, `gh workflow run`, or a mutating `gh api` / GitHub REST `curl` call
  (write method or request body) on any line of any `run:` script;
- no two jobs, within or across workflows, produce a check with the same literal
  display name (matrix-expanded `name (value)` contexts are outside this scan; a
  recorded required check may not carry a `strategy` at all);
- each RECORDED required check is produced by exactly one workflow whose trigger set
  equals the recorded one at activity-type / branch-filter granularity (Section 7.2);
- every `uses:` is a remote action pinned to a full commit SHA (a local `./` composite
  action or a `docker://` image would place steps outside this scan); no `container:`
  or `services:` image; an `actions/github-script` body is checked for write calls;
- exactly one `pull_request_target` workflow exists; nothing in it — workflow-level
  `env`, `concurrency` or `defaults` included — references the proposal head
  (`head.sha`, `head.ref`, `github.head_ref`, `refs/pull/`, PR checkout/fetch/diff
  forms), and no expression reads any `github.event.pull_request` field other than
  `base.sha` and `number`; no step downloads an
  artifact (any `download-artifact` action or `gh run download`), no checkout names a
  `repository`, and every checkout in it sets an explicit `ref` that resolves to the
  protected base (`github.event.pull_request.base.sha` or the default branch);
- the root `on` key is spelled exactly `on` (YAML 1.1 boolean aliases are refused).

WHAT THIS SCAN CANNOT PROVE. The action denylist and the command patterns are recorded
lists, not a proof: a write reachable only through a remote action's own code, or a
publish command outside the recorded patterns, is not detected statically. Shell text is
normalised for the common obfuscations (line continuations, command substitution,
quoted tokens, backslash escapes) before matching, but variable indirection, `eval`,
encoded scripts and similar are beyond what a text pattern can prove. The
normalisations also apply to prose inside a `pull_request_target` workflow's scripts,
so a sentence such as "…the head. Sha…" is read as `head.Sha` and fails closed there;
reword the prose. The
explicit read-only `permissions` requirement on every job (backed by the repository's
`default_workflow_permissions: read` read-back), the absence of any secret, and the
SHA pinning enforced by `action_pins.py` are the controls that bound what such a path
could do. The recorded sets below are control plane: changing a trigger, a required
check name or an admitted runner label edits them in the same reviewed commit.
"""
from __future__ import annotations

import argparse
import importlib.util
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

POLICY_ROOT = Path(__file__).resolve().parents[2]
MAX_WORKFLOW_BYTES = 1024 * 1024

ALLOWED_TRIGGERS = {"push", "pull_request", "pull_request_target", "schedule", "workflow_call"}
FORBIDDEN_PERMISSION_SCOPES = {"id-token", "pages", "deployments", "attestations", "packages"}
READ_ONLY_PERMISSION_VALUES = {"read", "none"}
# CONTROL PLANE — hosted runner labels this repository may target. `macos-latest` is absent
# because a macOS image change moves the Xcode/Swift toolchain under the build jobs, which the
# repository pins to a named image on purpose; `ubuntu-latest` is admitted because the Python
# tooling it runs has no such dependency. Any label outside this set — including a custom label
# that could name a self-hosted runner — fails the scan; a GitHub image retirement is handled by
# editing this set in a reviewed commit.
ADMITTED_RUNNER_LABELS = {"ubuntu-latest", "ubuntu-24.04", "ubuntu-22.04", "macos-15", "macos-14", "macos-26"}
# Actions that publish, deploy, attest, or write refs. The first group is an explicit denylist of
# known write actions; the second refuses any path segment that names a publish/deploy/attest/
# Pages capability. Generic words such as `commit` or `push` are NOT substring-matched, because
# read-only lint actions carry them (the explicit list holds the known writers of that kind).
FORBIDDEN_ACTIONS = {
    "actions/configure-pages", "actions/upload-pages-artifact", "actions/deploy-pages",
    "actions/create-release", "actions/upload-release-asset", "actions/attest",
    "actions/attest-build-provenance", "actions/attest-sbom",
    "softprops/action-gh-release", "ncipollo/release-action", "marvinpinto/action-automatic-releases",
    "peter-evans/create-pull-request", "stefanzweifel/git-auto-commit-action",
    "ad-m/github-push-action", "EndBug/add-and-commit", "JamesIves/github-pages-deploy-action",
    "peaceiris/actions-gh-pages", "docker/build-push-action", "docker/login-action",
    "pypa/gh-action-pypi-publish", "actions/publish-action",
}
FORBIDDEN_ACTIONS_FOLDED = {name.casefold() for name in FORBIDDEN_ACTIONS}
FORBIDDEN_ACTION_SEGMENT_RE = re.compile(r"(?:^|[/-])(?:release|deploy|publish|attest|pages|gh-pages)\w*(?:$|[/-])", re.I)
# Only a remote action pinned to a full commit SHA is admitted. A local composite action
# (`./…`) or a `docker://` image would place steps outside this scan's reach, so both are refused.
REMOTE_ACTION_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$")
# `actions/github-script` runs JavaScript with an authenticated Octokit client; its `with.script`
# is checked with the run-command rules AND any REST write verb it could call.
GITHUB_SCRIPT_WRITE_RE = re.compile(r"(?<!core\.)\b(?:create|update|delete|merge|upload|set|add|remove|dispatch|enable|disable|request)\w*\s*\(", re.I)
# Write commands in `run:` scripts, matched per line. A command may be path-prefixed
# (`/usr/bin/git`) and carry leading options (`git -c k=v -C dir push`); `curl` against
# api.github.com is mutating when it names a write method OR sends a body/upload; `gh api` is
# mutating when it names a write method OR passes field/body flags (which imply POST).
# A shell word, quoted spans included; possessive quantifiers so a non-match cannot backtrack.
_QUOTED_OR_WORD = r"""[^\s"']*+(?:(?:"[^"]*+"|'[^']*+')[^\s"']*+)*+"""
_OPTION = (r"(?:-[cC]\s+" + _QUOTED_OR_WORD + r"|--(?:git-dir|work-tree|namespace|exec-path|super-prefix|config-env)\s+"
           + _QUOTED_OR_WORD + r"|--?[\w-]+(?:=" + _QUOTED_OR_WORD + r")?)")
# The option loops are possessive (`*+`): once an option token is consumed it is never given
# back, so a long run of options cannot make the match backtrack exponentially.
_GIT = r"(?<![\w.-])(?:\S*/)?git(?:\s+" + _OPTION + r")*+\s+"
_GH = r"(?<![\w.-])(?:\S*/)?gh(?:\s+(?:-R\s+\S+|--(?:repo|hostname)\s+\S+|--?[\w-]+(?:=\S*)?))*+\s+"
_WRITE_METHOD = r"(?:(?:^|\s)-[A-Za-z]*X|--request|--method)(?:\s*=\s*|\s*)['\"]?(?:POST|PUT|PATCH|DELETE)\b"
_CURL_BODY_FLAG = r"""(?:^|[\s"'])(?:-[A-Za-z]*[dFT](?![A-Za-z])|--(?:data(?:-\w+)?|json|form(?:-string)?|upload-file)(?![\w-]))"""
_GH_BODY_FLAG = r"""(?:^|[\s"'])(?:-[fF](?![A-Za-z])|--(?:field|raw-field|input)(?![\w-]))"""
_GITHUB_HOST = r"(?:api\.github\.com|uploads\.github\.com|GITHUB_API_URL|GITHUB_SERVER_URL)"
CONTINUATION_RE = re.compile(r"\\\n\s*")
# Shell command boundaries: a line is matched one command at a time so a flag on one command
# (curl's `-f`) is never read as belonging to another (`gh api`) on the same line.
# Substitution delimiters are blanked, not split on, so a flag produced inside `$( )` or
# backticks stays attributed to the command that consumes it.
COMMAND_SPLIT_RE = re.compile(r"\s*(?:&&|\|\||;|\|)\s*")
SUBSTITUTION_RE = re.compile(r"\$\(|`|\)")


TOKEN_QUOTE_RE = re.compile(r"""(["'])([^"'\s]*)\1""")  # a fully quoted single token: "git" → git
BACKSLASH_ESCAPE_RE = re.compile(r"\\(.)", re.S)  # an unquoted backslash escapes and then vanishes


def _flatten_shell(text: str) -> str:
    """Shell-normalise a scalar: a backslash-newline is removed outright (the shell's semantics,
    so `pu\\<newline>ll` is `pull`), substitution delimiters are blanked, and a fully quoted
    single token loses its quotes (`"pr"` → `pr`)."""
    flattened = SUBSTITUTION_RE.sub(" ", CONTINUATION_RE.sub("", text))
    flattened = BACKSLASH_ESCAPE_RE.sub(r"\1", flattened)  # `p\\r` → `pr`, `p\\ull` → `pull`
    return TOKEN_QUOTE_RE.sub(r"\2", flattened)


def _command_segments(script: str) -> List[str]:
    return [segment for line in _flatten_shell(script).splitlines() for segment in COMMAND_SPLIT_RE.split(line) if segment]
FORBIDDEN_RUN_RES = (
    # `git tag` with a listing/query switch and `git notes show|list` are the read-only forms and
    # are exempted; every other spelling of these subcommands is treated as a write.
    ("git ref write", re.compile(_GIT + r"(?:push|commit|update-ref|send-pack"
                                 r"|tag\b(?!\s+(?:-l\b|--list\b|--points-at\b|--contains\b|--no-contains\b|--merged\b|--no-merged\b|-n\b))"
                                 r"|notes\b(?!\s+(?:show|list)\b))\b")),
    ("GitHub release write", re.compile(_GH + r"release\b")),
    ("pull-request merge", re.compile(_GH + r"pr\s+merge\b")),
    ("workflow dispatch", re.compile(_GH + r"workflow\s+run\b")),
    ("artifact download", re.compile(_GH + r"run\s+download\b")),
    ("mutating gh api call", re.compile(_GH + r"api\b(?=.*(?:" + _WRITE_METHOD + "|" + _GH_BODY_FLAG + "))")),
    ("mutating REST call", re.compile(r"(?<![\w.-])(?:\S*/)?curl\b(?=.*" + _GITHUB_HOST + r")(?=.*(?:" + _WRITE_METHOD + "|" + _CURL_BODY_FLAG + "))")),
    ("distribution publish command", re.compile(
        r"(?<![\w.-])(?:\S*/)?(?:npm|yarn|pnpm)\s+publish\b|(?<![\w.-])(?:\S*/)?cargo\s+publish\b|(?<![\w.-])(?:\S*/)?gem\s+push\b"
        r"|(?<![\w.-])(?:\S*/)?twine\s+upload\b|(?<![\w.-])(?:\S*/)?docker\s+(?:push|login)\b|(?<![\w.-])(?:\S*/)?docker\b.*\s--push\b"
        r"|(?<![\w.-])(?:\S*/)?brew\s+pr-upload\b"
        r"|(?<![\w.-])(?:\S*/)?aws\s+s3\s+(?:cp|sync|mv)\b|(?<![\w.-])(?:\S*/)?gsutil\s+(?:cp|rsync)\b")),
)
# Expression contexts are checked after bracket-index normalisation (`secrets['X']` →
# `secrets.X`, `github['token']` → `github.token`), on the bodies of `${{ }}` blocks and on
# `if:` values (which are expressions without the delimiters).
INDEX_FORM_RE = re.compile(r"""\s*\[\s*(?:'([^']*)'|"([^"]*)")\s*\]""")
EXPRESSION_RE = re.compile(r"\$\{\{(.*?)\}\}", re.S)
EXPRESSION_SPAN_RE = re.compile(r"\$\{\{(.*)\}\}", re.S)  # greedy: first opener to last closer
SECRETS_CONTEXT_RE = re.compile(r"(?<![\w.])secrets(?![\w-])", re.I)
GITHUB_TOKEN_RE = re.compile(r"\bgithub\.token\b", re.I)
PROPOSAL_HEAD_RE = re.compile(
    r"head\.sha|head\.ref|head\.repo|head\.label|pull_request\.head\b|github\.head_ref|refs/pull/"
    r"|(?<!\w)pull/|(?<![\w-])pr\s+(?:(?:-R|--repo)(?:\s+|=)\S+\s+)*(?:checkout|diff|view)\b|(?<![\w-])merge-base\b"
    r"|/actions/artifacts|/artifacts/\d+/zip|\.(?:diff|patch)\b",
    re.I,
)
# Under pull_request_target the ONLY pull-request event fields a base-owned workflow may read
# through an expression: the protected base commit and the number. Every other
# `github.event.pull_request.*` field (head, URLs, merge commit, labels…) is refused, so a new
# spelling of the proposal head never needs a new denylist entry.
# Matches the whole `github.event` object, any sub-object (`github.event.pull_request`) and any
# field path, so a whole-object read such as `toJSON(github.event.pull_request)` is refused too.
PR_EVENT_FIELD_RE = re.compile(r"github\.event(?!\w)(?:\.\w+)*", re.I)
# A bare `github` context read (`toJSON(github)`) would expose the whole event object.
BARE_GITHUB_CONTEXT_RE = re.compile(r"(?<![\w.])github(?![\w.])|(?<![\w.])github(?:\.\w+)*\.\*", re.I)
PRT_ALLOWED_EVENT_FIELDS = {"github.event.pull_request.base.sha", "github.event.pull_request.number", "github.event.number"}
# YAML 1.1 loaders resolve these keys to a boolean; GitHub's loader treats `on` that way, so a
# second spelling at the root could carry a trigger set this scan never looked at.
YAML11_BOOLEAN_KEYS = {"y", "Y", "yes", "Yes", "YES", "n", "N", "no", "No", "NO", "true", "True", "TRUE",
                       "false", "False", "FALSE", "on", "On", "ON", "off", "Off", "OFF"}
# Interpreters a `run:` step may select. The write-command patterns are shell patterns, so a
# step that swaps in another interpreter (python, pwsh, a custom template) is refused.
ADMITTED_SHELLS = {"bash", "sh"}
BASE_REF_VALUES = {"${{ github.event.pull_request.base.sha }}", "main", "refs/heads/main"}
# Checkout inputs that carry or mint credentials; none is admitted in any workflow.
CHECKOUT_CREDENTIAL_OPTIONS = {"token", "ssh-key", "ssh-known-hosts", "ssh-strict", "github-server-url"}

# Section 7.2 recorded trigger sets, at activity-type / branch-filter granularity.
RECORDED_REQUIRED_CHECKS: Dict[str, Dict[str, Any]] = {
    "quality / required": {
        "push": {"branches": ["main"]},
        "pull_request": {"types": ["opened", "edited", "synchronize", "reopened"]},
    },
    # The interim metadata gate; design step 5 folds it into `governance / required`
    # in a later reviewed change, which edits this entry.
    "metadata / required": {
        "pull_request_target": {"types": ["opened", "edited", "reopened", "synchronize", "ready_for_review"]},
    },
}


class ParseError(Exception):
    """The file is outside the accepted YAML subset; the scan refuses it."""


# --------------------------------------------------------------------------- parsing

def _load_action_pins():
    spec = importlib.util.spec_from_file_location("action_pins", Path(__file__).with_name("action_pins.py"))
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def _strip_comment(line: str) -> str:
    """Remove a trailing ` #` comment that sits outside a quoted scalar.

    A quote opens a quoted scalar only at the start of a value (line start, or after
    `:`, `-`, `[` or `,` plus spaces); an apostrophe inside a plain scalar is text.
    """
    quote: Optional[str] = None
    index = 0
    while index < len(line):
        character = line[index]
        if quote == '"':
            if character == "\\":
                index += 2
                continue
            if character == '"':
                quote = None
        elif quote == "'":
            if character == "'":
                if index + 1 < len(line) and line[index + 1] == "'":
                    index += 2
                    continue
                quote = None
        elif character in {'"', "'"}:
            before = line[:index].rstrip()
            if before == "" or before[-1] in ":-[,":
                quote = character
        elif character == "#" and (index == 0 or line[index - 1].isspace()):
            return line[:index].rstrip()
        index += 1
    return line.rstrip()


_SIMPLE_ESCAPES = {
    "0": "\0", "a": "\a", "b": "\b", "t": "\t", "\t": "\t", "n": "\n", "v": "\v", "f": "\f",
    "r": "\r", "e": "\x1b", " ": " ", '"': '"', "/": "/", "\\": "\\", "N": "\u0085", "_": "\u00a0",
    "L": "\u2028", "P": "\u2029",
}
_HEX_ESCAPES = {"x": 2, "u": 4, "U": 8}


def _decode_double_quoted(body: str) -> str:
    """Decode a YAML double-quoted scalar with the full escape set; refuse anything else.

    GitHub's YAML loader decodes `\\u0063` and friends, so a scanner that left them encoded
    would let `"${{ se\\u0063rets.X }}"` through. Every escape YAML defines is decoded here and
    an escape outside that set is a parse refusal (a violation), never a pass-through.
    """
    out = []
    index = 0
    while index < len(body):
        character = body[index]
        if character != "\\":
            out.append(character)
            index += 1
            continue
        if index + 1 >= len(body):
            raise ParseError("dangling backslash in double-quoted scalar")
        code = body[index + 1]
        if code in _SIMPLE_ESCAPES:
            out.append(_SIMPLE_ESCAPES[code])
            index += 2
            continue
        if code in _HEX_ESCAPES:
            width = _HEX_ESCAPES[code]
            digits = body[index + 2:index + 2 + width]
            if len(digits) != width or not re.fullmatch(r"[0-9A-Fa-f]+", digits):
                raise ParseError("malformed \\{} escape in double-quoted scalar".format(code))
            out.append(chr(int(digits, 16)))
            index += 2 + width
            continue
        raise ParseError("unsupported escape \\{} in double-quoted scalar".format(code))
    return "".join(out)


DOT_SPACING_RE = re.compile(r"\s*\.\s*")


def _normalize_expression(text: str) -> str:
    """Rewrite bracket property access to dotted form and drop whitespace around the dot, so
    one regex covers `secrets.X`, `secrets['X']` and `secrets . X` alike."""
    previous = None
    while previous != text:
        previous = text
        text = INDEX_FORM_RE.sub(lambda m: "." + (m.group(1) if m.group(1) is not None else m.group(2)), text)
    return DOT_SPACING_RE.sub(".", text)


def _expression_bodies(key: Optional[str], text: str) -> List[str]:
    bodies = [_normalize_expression(m.group(1)) for m in EXPRESSION_RE.finditer(text)]
    # A `}}` inside a string literal would end the non-greedy match early; the greedy span from
    # the first opener to the last closer is checked as well, so no token hides behind one.
    span = EXPRESSION_SPAN_RE.search(text)
    if span:
        bodies.append(_normalize_expression(span.group(1)))
    if key == "if":
        bodies.append(_normalize_expression(text))
    return bodies


def _scalar(raw: str) -> Any:
    text = raw.strip()
    if text == "":
        return None
    if text[0] == '"':
        if len(text) < 2 or text[-1] != '"':
            raise ParseError("unterminated double-quoted scalar")
        return _decode_double_quoted(text[1:-1])
    if text[0] == "'":
        if len(text) < 2 or text[-1] != "'":
            raise ParseError("unterminated single-quoted scalar")
        return text[1:-1].replace("''", "'")
    if text == "{}":
        return {}
    if text[0] == "[":
        if text[-1] != "]":
            raise ParseError("flow sequence must close on the same line")
        inner = text[1:-1].strip()
        if inner == "":
            return []
        items = []
        for item in inner.split(","):
            item = item.strip()
            if item == "" or item[0] in "[{" or "{" in item:
                raise ParseError("flow sequences may hold scalars only")
            items.append(_scalar(item))
        return items
    if text[0] in "{&*!?%@`|>":
        raise ParseError("flow mappings, anchors, aliases, tags and bare block indicators are refused")
    if text in {"true", "True", "TRUE"}:
        return True
    if text in {"false", "False", "FALSE"}:
        return False
    if text in {"null", "Null", "NULL", "~"}:
        return None
    return text


KEY_RE = re.compile(r"^(?P<key>[A-Za-z0-9_.\-/*]+|\"[^\"]*\"|'[^']*')\s*:(?:\s+(?P<value>.*))?$")


class _Lines:
    def __init__(self, text: str) -> None:
        self.rows: List[Tuple[int, int, str]] = []  # (indent, lineno, content-with-comment-stripped)
        raw_rows = text.split("\n")
        self.raw = raw_rows
        for number, raw in enumerate(raw_rows, start=1):
            if raw.strip() == "" or raw.lstrip().startswith("#"):
                continue
            if raw.startswith("---") or raw.startswith("..."):
                raise ParseError("line {}: multi-document markers are refused".format(number))
            if "\t" in raw[: len(raw) - len(raw.lstrip())]:
                raise ParseError("line {}: tab indentation is refused".format(number))
            indent = len(raw) - len(raw.lstrip(" "))
            self.rows.append((indent, number, _strip_comment(raw)))
        self.position = 0

    def peek(self) -> Optional[Tuple[int, int, str]]:
        return self.rows[self.position] if self.position < len(self.rows) else None

    def take(self) -> Tuple[int, int, str]:
        row = self.rows[self.position]
        self.position += 1
        return row


def _block_scalar(lines: _Lines, parent_indent: int, indicator: str) -> str:
    """Collect a literal/folded block scalar body: every following raw line indented
    deeper than the parent (blank lines included), returned joined by newlines."""
    if lines.position >= len(lines.rows):
        return ""
    body: List[str] = []
    next_row = lines.peek()
    if next_row is None or next_row[0] <= parent_indent:
        return ""
    block_indent = next_row[0]
    # Walk raw lines from the current row's line number to reproduce blank lines inside.
    start_lineno = next_row[1]
    end_lineno = start_lineno
    for indent, lineno, _content in lines.rows[lines.position:]:
        if indent < block_indent:
            break
        end_lineno = lineno

    def _comment_row(raw: str) -> bool:
        return raw.lstrip().startswith("#") and len(raw) - len(raw.lstrip(" ")) >= block_indent

    # `#`-only rows are not parse rows, but inside a block scalar they are body text: extend the
    # body backwards to the row after the indicator and forwards over trailing comment rows.
    previous_lineno = lines.rows[lines.position - 1][1] if lines.position > 0 else 0
    while start_lineno - 1 > previous_lineno and _comment_row(lines.raw[start_lineno - 2]):
        start_lineno -= 1
    while end_lineno < len(lines.raw) and (_comment_row(lines.raw[end_lineno]) or (
            lines.raw[end_lineno].strip() == "" and end_lineno + 1 < len(lines.raw) and _comment_row(lines.raw[end_lineno + 1]))):
        end_lineno += 1
    for raw in lines.raw[start_lineno - 1:end_lineno]:
        if raw.strip() == "":
            body.append("")
        else:
            body.append(raw[block_indent:])
    while lines.position < len(lines.rows) and lines.rows[lines.position][1] <= end_lineno:
        lines.position += 1
    text = "\n".join(body)
    return text if indicator.startswith("|") else re.sub(r"(?<!\n)\n(?!\n)", " ", text)


def _parse_block(lines: _Lines, indent: int) -> Any:
    row = lines.peek()
    if row is None:
        return None
    if row[0] != indent:
        raise ParseError("line {}: unexpected indentation".format(row[1]))
    if row[2].lstrip().startswith("- "):
        return _parse_sequence(lines, indent)
    return _parse_mapping(lines, indent)


def _parse_sequence(lines: _Lines, indent: int, under_key: bool = False) -> List[Any]:
    """Parse `- item` rows at `indent`. With `under_key` (a sequence written at its parent key's
    own column) the sequence ends at the first row of that column that is not an item."""
    items: List[Any] = []
    while True:
        row = lines.peek()
        if row is None or row[0] < indent:
            return items
        if row[0] != indent or not row[2].lstrip().startswith("- "):
            if row[0] == indent:
                if under_key and items:
                    return items
                raise ParseError("line {}: mixed sequence and mapping at one level".format(row[1]))
            raise ParseError("line {}: unexpected indentation".format(row[1]))
        lines.take()
        rest = row[2].lstrip()[2:]
        item_indent = indent + 2
        if rest.strip() == "":
            items.append(_parse_block(lines, item_indent) if _next_deeper(lines, indent) else None)
            continue
        if rest.strip().startswith("- "):
            raise ParseError("line {}: nested sequences are refused".format(row[1]))
        match = KEY_RE.match(rest.strip())
        if match and not rest.strip().startswith(("'", '"', "[")):
            # Inline mapping start: "- key: value" followed by sibling keys at the key's column.
            key_indent = indent + 2 + (len(rest) - len(rest.lstrip()))
            mapping = _parse_mapping_from_first(lines, key_indent, match, row[1])
            items.append(mapping)
            continue
        items.append(_scalar(rest))


def _next_deeper(lines: _Lines, indent: int) -> bool:
    row = lines.peek()
    return row is not None and row[0] > indent


def _parse_mapping_from_first(lines: _Lines, indent: int, first: "re.Match[str]", lineno: int) -> Dict[str, Any]:
    mapping: Dict[str, Any] = {}
    _assign(mapping, lines, indent, first, lineno)
    while True:
        row = lines.peek()
        if row is None or row[0] < indent:
            return mapping
        if row[0] > indent:
            raise ParseError("line {}: unexpected indentation".format(row[1]))
        if row[2].lstrip().startswith("- "):
            raise ParseError("line {}: mixed sequence and mapping at one level".format(row[1]))
        match = KEY_RE.match(row[2].strip())
        if match is None:
            raise ParseError("line {}: not a mapping entry in the accepted subset".format(row[1]))
        lines.take()
        _assign(mapping, lines, indent, match, row[1])


def _parse_mapping(lines: _Lines, indent: int) -> Dict[str, Any]:
    row = lines.take()
    match = KEY_RE.match(row[2].strip())
    if match is None:
        raise ParseError("line {}: not a mapping entry in the accepted subset".format(row[1]))
    return _parse_mapping_from_first(lines, indent, match, row[1])


def _assign(mapping: Dict[str, Any], lines: _Lines, indent: int, match: "re.Match[str]", lineno: int) -> None:
    raw_key = match.group("key")
    key = _scalar(raw_key) if raw_key[0] in "\"'" else raw_key
    if not isinstance(key, str):
        raise ParseError("line {}: mapping key must be a scalar".format(lineno))
    if key in mapping:
        raise ParseError("line {}: duplicate key `{}`".format(lineno, key))
    value = match.group("value")
    if value is None or value.strip() == "":
        row = lines.peek()
        if _next_deeper(lines, indent):
            mapping[key] = _parse_block(lines, row[0])
        elif row is not None and row[0] == indent and row[2].lstrip().startswith("- "):
            mapping[key] = _parse_sequence(lines, indent, under_key=True)
        else:
            mapping[key] = None
        return
    stripped = value.strip()
    if re.fullmatch(r"[|>][+-]?[0-9]?", stripped):
        mapping[key] = _block_scalar(lines, indent, stripped)
        return
    mapping[key] = _scalar(stripped)


def parse_workflow(text: str) -> Dict[str, Any]:
    lines = _Lines(text)
    if lines.peek() is None:
        raise ParseError("empty workflow")
    document = _parse_block(lines, 0)
    if lines.peek() is not None:
        raise ParseError("line {}: trailing content".format(lines.peek()[1]))
    if not isinstance(document, dict):
        raise ParseError("workflow root must be a mapping")
    return document


# --------------------------------------------------------------------------- walking

def _walk_strings(node: Any, path: str, key: Optional[str] = None):
    """Yield (path, nearest mapping key, text) for every string scalar under `node`.

    Mapping keys are walked as strings too, so a key spelled with an expression or an escape
    cannot carry a forbidden reference past the checks."""
    if isinstance(node, dict):
        for child_key, value in node.items():
            child_path = "{}.{}".format(path, child_key)
            yield child_path, None, str(child_key)
            yield from _walk_strings(value, child_path, str(child_key))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from _walk_strings(value, "{}[{}]".format(path, index), key)
    elif isinstance(node, str):
        yield path, key, node


def _walk_keys(node: Any, path: str):
    if isinstance(node, dict):
        for key, value in node.items():
            yield "{}.{}".format(path, key), key, value
            yield from _walk_keys(value, "{}.{}".format(path, key))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from _walk_keys(value, "{}[{}]".format(path, index))


def _normalize_triggers(on: Any) -> Dict[str, Any]:
    if isinstance(on, str):
        return {on: {}}
    if isinstance(on, list):
        return {str(item): {} for item in on}
    if isinstance(on, dict):
        return {str(key): (value if isinstance(value, dict) else {}) for key, value in on.items()}
    return {}


def _permissions_violations(block: Any, where: str) -> List[str]:
    if block is None:
        return ["{}: no explicit `permissions` block (an omitted block inherits the repository default)".format(where)]
    if isinstance(block, str):
        if block == "read-all":
            return []
        return ["{}: `permissions: {}` is not read-only".format(where, block)]
    if not isinstance(block, dict):
        return ["{}: `permissions` must be `read-all` or a mapping".format(where)]
    problems = []
    for scope, value in block.items():
        if scope in FORBIDDEN_PERMISSION_SCOPES:
            problems.append("{}: permission scope `{}` is forbidden before launch".format(where, scope))
        if str(value) not in READ_ONLY_PERMISSION_VALUES:
            problems.append("{}: permission `{}: {}` is not read-only".format(where, scope, value))
    return problems


def _shell_violations(defaults: Any, where: str) -> List[str]:
    if not isinstance(defaults, dict):
        return []
    run_defaults = defaults.get("run")
    shell = run_defaults.get("shell") if isinstance(run_defaults, dict) else None
    if shell is not None and shell not in ADMITTED_SHELLS:
        return ["{}: `defaults.run.shell: {}` is not an admitted interpreter".format(where, shell)]
    return []


def _display_check_name(job_id: str, job: Dict[str, Any]) -> str:
    name = job.get("name")
    return name if isinstance(name, str) and name.strip() else job_id


def scan_workflow(display: str, document: Dict[str, Any]) -> Tuple[List[str], Dict[str, Any]]:
    """Return (violations, facts) for one parsed workflow."""
    violations: List[str] = []
    facts: Dict[str, Any] = {"checks": {}, "triggers": {}, "pull_request_target": False}

    for root_key in document:
        if root_key in YAML11_BOOLEAN_KEYS and root_key != "on":
            violations.append("{}: root key `{}` is a YAML 1.1 boolean alias of `on`; only the literal `on` is accepted".format(display, root_key))
    on = document.get("on")
    triggers = _normalize_triggers(on)
    facts["triggers"] = triggers
    if not triggers:
        violations.append("{}: no triggers declared".format(display))
    for trigger in triggers:
        if trigger not in ALLOWED_TRIGGERS:
            violations.append("{}: trigger `{}` is forbidden".format(display, trigger))
    facts["pull_request_target"] = "pull_request_target" in triggers

    violations.extend(_permissions_violations(document.get("permissions"), "{}: workflow".format(display)))

    for path, key, value in _walk_keys(document, display):
        if key == "secrets":
            violations.append("{}: `secrets` mapping or `secrets: inherit` is forbidden".format(path))
    for path, key, text in _walk_strings(document, display):
        bodies = _expression_bodies(key, text)
        if any(SECRETS_CONTEXT_RE.search(body) for body in bodies):
            violations.append("{}: references the `secrets.` context".format(path))
        if any(GITHUB_TOKEN_RE.search(body) for body in bodies):
            violations.append("{}: references `github.token`".format(path))

    violations.extend(_shell_violations(document.get("defaults"), "{}: workflow".format(display)))
    jobs = document.get("jobs")
    if not isinstance(jobs, dict) or not jobs:
        violations.append("{}: no jobs".format(display))
        return violations, facts
    for job_id, job in jobs.items():
        where = "{}: job `{}`".format(display, job_id)
        if not isinstance(job, dict):
            violations.append("{}: job body must be a mapping".format(where))
            continue
        if "environment" in job:
            violations.append("{}: `environment` is forbidden before launch".format(where))
        violations.extend(_shell_violations(job.get("defaults"), where))
        for image_key in ("container", "services"):
            if image_key in job:
                violations.append("{}: `{}` is not admitted (an unpinned third-party image would run {} the job)".format(
                    where, image_key, "as" if image_key == "container" else "beside"))
        check_name = _display_check_name(job_id, job)
        if "${{" in check_name:
            violations.append("{}: job `name` may not contain an expression (the check name must be a literal)".format(where))
        if "strategy" in job and check_name in RECORDED_REQUIRED_CHECKS:
            violations.append("{}: a recorded required check may not carry a `strategy` (matrix names diverge from the recorded context)".format(where))
        if check_name in facts["checks"]:
            violations.append("{}: check `{}` is also produced by job `{}`".format(where, check_name, facts["checks"][check_name]))
        else:
            facts["checks"][check_name] = job_id
        violations.extend(_permissions_violations(job.get("permissions"), where))
        runs_on = job.get("runs-on")
        if "uses" in job:
            violations.append("{}: reusable-workflow calls are not admitted by this scan".format(where))
        elif isinstance(runs_on, list) and len(runs_on) == 1 and isinstance(runs_on[0], str) and runs_on[0].strip() in ADMITTED_RUNNER_LABELS:
            pass
        elif not isinstance(runs_on, str):
            violations.append("{}: `runs-on` must be a single hosted label from ADMITTED_RUNNER_LABELS".format(where))
        elif runs_on.strip() not in ADMITTED_RUNNER_LABELS:
            violations.append("{}: `runs-on: {}` is not in ADMITTED_RUNNER_LABELS (edit that set in a reviewed commit to admit a label)".format(where, runs_on))
        steps = job.get("steps")
        if not isinstance(steps, list) or not steps:
            violations.append("{}: no steps".format(where))
            continue
        for index, step in enumerate(steps):
            step_where = "{} step {}".format(where, index + 1)
            if not isinstance(step, dict):
                violations.append("{}: step must be a mapping".format(step_where))
                continue
            uses = step.get("uses")
            if isinstance(uses, str):
                action = uses.split("@", 1)[0]
                if not REMOTE_ACTION_RE.match(uses):
                    violations.append("{}: `uses: {}` is not a remote action pinned to a full commit SHA (local and docker actions are outside this scan)".format(step_where, uses))
                if action.casefold() in FORBIDDEN_ACTIONS_FOLDED or FORBIDDEN_ACTION_SEGMENT_RE.search(action):
                    violations.append("{}: action `{}` is a publish, deploy or write path".format(step_where, action))
                if action.casefold() == "actions/github-script":
                    with_block = step.get("with")
                    script = with_block.get("script") if isinstance(with_block, dict) else None
                    if script is not None and not isinstance(script, str):
                        violations.append("{}: github-script `script` must be a string scalar".format(step_where))
                    script_text = script if isinstance(script, str) else ""
                    if GITHUB_SCRIPT_WRITE_RE.search(script_text) or any(
                        pattern.search(segment) for _label, pattern in FORBIDDEN_RUN_RES for segment in _command_segments(script_text)
                    ):
                        violations.append("{}: github-script body contains a write call".format(step_where))
                if action.casefold() == "actions/checkout":
                    with_block = step.get("with")
                    persist = with_block.get("persist-credentials") if isinstance(with_block, dict) else None
                    if persist is not False and str(persist) != "false":
                        violations.append("{}: checkout must set `persist-credentials: false` explicitly".format(step_where))
                    if isinstance(with_block, dict):
                        for option in sorted(set(with_block) & CHECKOUT_CREDENTIAL_OPTIONS):
                            violations.append("{}: checkout option `{}` is forbidden".format(step_where, option))
                    if facts["pull_request_target"]:
                        ref = with_block.get("ref") if isinstance(with_block, dict) else None
                        if not isinstance(ref, str) or ref.strip() not in BASE_REF_VALUES:
                            violations.append(
                                "{}: checkout under pull_request_target must pin `ref` to the protected base".format(step_where)
                            )
                        if isinstance(with_block, dict) and "repository" in with_block:
                            violations.append(
                                "{}: checkout under pull_request_target may not name a `repository`".format(step_where)
                            )
                if facts["pull_request_target"] and "download-artifact" in action.casefold():
                    violations.append("{}: artifact download under pull_request_target is forbidden".format(step_where))
            if "shell" in step and step["shell"] not in ADMITTED_SHELLS:
                violations.append("{}: `shell: {}` is not an admitted interpreter".format(step_where, step["shell"]))
            run = step.get("run")
            if "run" in step and not isinstance(run, str):
                violations.append("{}: `run` must be a string scalar".format(step_where))
            if isinstance(run, str):
                for label, pattern in FORBIDDEN_RUN_RES:
                    if any(pattern.search(segment) for segment in _command_segments(run)):
                        violations.append("{}: run script contains a {}".format(step_where, label))
    if facts["pull_request_target"]:
        for path, key, text in _walk_strings(document, display):
            normalized = _normalize_expression(_flatten_shell(text))
            if any(BARE_GITHUB_CONTEXT_RE.search(body) for body in _expression_bodies(key, text)):
                violations.append("{}: whole `github` context read is not admitted under pull_request_target".format(path))
            if PROPOSAL_HEAD_RE.search(normalized):
                violations.append("{}: references the proposal head under pull_request_target".format(path))
            for field in PR_EVENT_FIELD_RE.findall(normalized):
                if field.lower() not in PRT_ALLOWED_EVENT_FIELDS:
                    violations.append("{}: pull-request event field `{}` is not readable under pull_request_target".format(path, field))
    return violations, facts


def _canonical(value: Any) -> Any:
    """Order-insensitive form of a trigger set: list order in `types:`/`branches:` is not semantic."""
    if isinstance(value, dict):
        return {key: _canonical(item) for key, item in value.items()}
    if isinstance(value, list):
        return sorted(str(item) for item in value)
    return value


def scan_repository(root: Path) -> List[str]:
    violations: List[str] = []
    try:
        pins = _load_action_pins()
    except Exception as error:  # noqa: BLE001 — any loader failure is a scan failure, reported not raised
        return ["scripts/ci/action_pins.py could not be loaded: {}".format(error)]
    checks_seen: Dict[str, str] = {}
    triggers_by_check: Dict[str, Dict[str, Any]] = {}
    prt_workflows: List[str] = []
    paths = pins.workflow_paths(root)
    if not paths:
        return ["no workflows found under .github/workflows"]
    for path in paths:
        display = path.relative_to(root).as_posix()
        try:
            text = pins.read_regular_utf8(path, MAX_WORKFLOW_BYTES)
            document = parse_workflow(text)
        except Exception as error:  # noqa: BLE001 — any failure to read or parse is a refusal (a violation), never a pass
            violations.append("{}: refused: {}".format(display, error))
            continue
        file_violations, facts = scan_workflow(display, document)
        violations.extend(file_violations)
        if facts["pull_request_target"]:
            prt_workflows.append(display)
        for check_name in facts["checks"]:
            if check_name in checks_seen:
                violations.append("{}: check `{}` is also produced by {}".format(display, check_name, checks_seen[check_name]))
            else:
                checks_seen[check_name] = display
            triggers_by_check[check_name] = facts["triggers"]
    if len(prt_workflows) != 1:
        violations.append("exactly one pull_request_target workflow is required; found {}".format(len(prt_workflows)))
    for check_name, expected in RECORDED_REQUIRED_CHECKS.items():
        if check_name not in triggers_by_check:
            violations.append("recorded required check `{}` is produced by no workflow".format(check_name))
            continue
        if _canonical(triggers_by_check[check_name]) != _canonical(expected):
            violations.append(
                "check `{}`: trigger set differs from the recorded Section 7.2 set (edit RECORDED_REQUIRED_CHECKS in the same reviewed commit as a deliberate trigger change)".format(check_name)
            )
    return violations


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Static read-only scan of every GitHub workflow.")
    parser.add_argument("--root", type=Path, default=POLICY_ROOT)
    args = parser.parse_args(argv)
    violations = scan_repository(args.root.expanduser().resolve())
    if violations:
        for violation in violations:
            print("workflow-policy: {}".format(violation), file=sys.stderr)
        return 1
    print("workflow-policy: every workflow is read-only and matches the recorded control plane")
    return 0


if __name__ == "__main__":
    sys.exit(main())
