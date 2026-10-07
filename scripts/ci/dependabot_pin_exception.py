#!/usr/bin/env python3
"""Offline core of the design §10.5 Dependabot workflow-pin exception.

Design §10.5 allows one automated control-plane exception: a Dependabot pull request that only
bumps GitHub Actions pins. This script judges such a proposal from files it is given. It reads
files and writes none: it calls no network and runs no command (run it with `-B`, so that loading
its sibling modules writes no bytecode either).

Three checks, each fail-closed:

1. Structure (`compare_trees`). Every changed path is a workflow file directly under
   `.github/workflows/` that both trees hold, and no two workflow paths differ only in case or
   Unicode normalization. Every changed line is a `uses:` line whose only change is the full
   commit SHA and its adjacent `vX.Y.Z` comment, moving an Action from its reviewed allowlist pin
   to a higher version (a major-version bump qualifies like any other; components compare as
   decimal numbers of any length). Both trees must parse under `workflow_policy`'s YAML subset,
   and the parsed documents may differ only in the `uses` value of a step
   (`jobs.<id>.steps[<n>].uses`), one per bumped line, each moving `name@old` to `name@new`. A
   `uses:` key anywhere else, such as under `env` or `with`, is data, not an Action reference,
   and a change to it is refused. Each bumped Action moves to one new pin everywhere, and no
   string in any parsed workflow is still a bumped Action's old pin (`name@old`), so a proposal
   cannot qualify while a `uses:` key outside a step still holds the old pin of an Action it
   bumps: changing that key is refused, and so is leaving it.
2. Pull request (`check_pull_request`): `pr_metadata.is_dependabot_proposal` on the
   pull-request object (login `dependabot[bot]`, type `Bot`, Dependabot's account id, a head
   repository that is the base repository), a base repository id equal to the expected one,
   a changed-file count equal to the length of the changed-path list, and a positive number
   and full head and base commits, which the report echoes. "Dependabot" is the
   identity that opened the pull request, as design §10.5 defines it; it says nothing about who
   pushed the head commits, so the structure check, not this one, bounds the content.
3. Reachability (`check_reachability`): for each bump, evidence that the tag named by its new
   version comment is the new commit. Design §10.5 also accepts a commit merely reachable from a
   tag or from the Action's default branch; this check accepts neither, because such a proof
   leaves the version comment, which becomes the reviewed allowlist's version label, unbound to
   the commit. This check compares only the tag name the evidence states and cannot tell which
   endpoint answered, so whoever gathers it must use the exact-match single-ref endpoint
   (`git/ref/tags/<version>`), never the plural one, which can answer a missing tag with prefix
   matches.

WHAT THIS DOES NOT PROVE. The base and head trees, the changed-path list, the pull-request
object and the reachability evidence are inputs: whoever gathers them (the head files and the
evidence from the GitHub API, the base as a checkout of the base branch's current tip) vouches
for them. This script checks their content, not their provenance or freshness, and ties them to
one another only through the checks above; the report echoes the pull request's number and head
and base commits so the caller can record what was judged. Judge only an up-to-date proposal:
`--base-root` is the base branch's current tip, and the caller checks that the head contains
that commit. If the base has moved, a workflow changed there that the proposal does not list is
refused, but one the proposal also lists is compared whole, so a pin rolled back on the base
reads as a bump the proposal did not make and can qualify, although a merge would keep the
rollback. The echoed `base_sha` is the pull request's, not necessarily the tip that was judged.
No workflow judges a proposal with it (CI runs only its tests); how a qualifying proposal
reaches `main` awaits the operator's ruling. It assumes the reviewed allowlist records each
Action's commit and version, as it does today; an allowlist that recorded only an Action's
identity would need the old-pin check adapted. A report that qualifies is necessary, not
sufficient: design §10.5 also requires the base policy to stay blocking, the proposed pins to
run only in the secret-free advisory lane, one qualified approval and no auto-merge, and a
broader diff to be recreated as a human-authored policy pull request. The draft launch
specification (§13) would also have the exception refuse, by literal path, any pull request
changing the four publisher workflows it proposes; this core does not, and refuses such a change
today only because a proposal may not add a workflow file.

The allowlist is read from this script's own checkout (`action_pins.load_allowlist`), never
through `--base-root` or `--head-root`; run the base branch's copy, so that the allowlist is the
base's.

Exit status: 0 when the proposal qualifies and 1 when it does not; 2, with nothing on stdout,
for a usage or input error: a missing or malformed argument, an unreadable JSON input or
allowlist, a root without a real `.github/workflows` directory, or `--pull-request` and
`--repository-id` not given together. A workflow file that cannot be read is a refusal (1), not
an input error.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import stat
import sys
import unicodedata
from pathlib import Path
from typing import Any, NamedTuple, Optional


def _load_sibling(name: str):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


action_pins = _load_sibling("action_pins")
workflow_policy = _load_sibling("workflow_policy")
pr_metadata = _load_sibling("pr_metadata")

SCHEMA_VERSION = 1
WORKFLOW_PATH_PATTERN = re.compile(r"\.github/workflows/[^/]+\.ya?ml")
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}")
MAX_INPUT_BYTES = 1024 * 1024
NOT_SUPPLIED = object()


class Bump(NamedTuple):
    path: str
    line: int
    name: str
    old_sha: str
    old_version: str
    new_sha: str
    new_version: str


def _version_key(version: str) -> tuple[tuple[int, str], ...]:
    """Orders `vX.Y.Z` numerically without converting to int, so a component of any length that
    action_pins.VERSION_PATTERN accepts compares (int() refuses one past Python's digit limit)."""
    key = []
    for digits in version[1:].split("."):
        significant = digits.lstrip("0") or "0"
        key.append((len(significant), significant))
    return tuple(key)


def _pin(line: str) -> Optional[tuple[str, str, str, str]]:
    """(key prefix, action name, commit, version comment) of a well-formed pinned `uses:` line."""
    match = action_pins.USES_KEY_PATTERN.fullmatch(line)
    if match is None:
        return None
    try:
        scalar, comment = action_pins.split_scalar_and_comment(match.group("rest"))
    except ValueError:
        return None
    remote = action_pins.REMOTE_PATTERN.fullmatch(scalar)
    if remote is None or comment is None or action_pins.VERSION_PATTERN.fullmatch(comment) is None:
        return None
    prefix = "{}|{}|{}".format(match.group("indent"), match.group("sequence") or "", match.group("space"))
    return prefix, remote.group("name"), remote.group("revision"), comment


def _differences(base: Any, head: Any, path: tuple = ()) -> list[tuple[tuple, Any, Any]]:
    """Each (path, base value, head value) at which two parsed documents differ. Mappings with the
    same keys in the same order and sequences of the same length are compared member by member;
    any other difference, including one of type, is reported at its own path."""
    if isinstance(base, dict) and isinstance(head, dict) and list(base) == list(head):
        found: list[tuple[tuple, Any, Any]] = []
        for key in base:
            found.extend(_differences(base[key], head[key], path + (key,)))
        return found
    if isinstance(base, list) and isinstance(head, list) and len(base) == len(head):
        found = []
        for index, (old, new) in enumerate(zip(base, head)):
            found.extend(_differences(old, new, path + (index,)))
        return found
    if type(base) is type(head) and base == head:
        return []
    return [(path, base, head)]


def _is_step_uses(path: tuple) -> bool:
    """True for `jobs.<id>.steps[<n>].uses`, the one place a `uses` value names an Action a step
    runs (`workflow_policy` refuses a job-level `uses`, a reusable-workflow call)."""
    return (len(path) == 5 and path[0] == "jobs" and isinstance(path[1], str) and path[2] == "steps"
            and type(path[3]) is int and path[4] == "uses")


def _strings(node: Any) -> list[str]:
    """Every string in a parsed document, keys included."""
    if isinstance(node, str):
        return [node]
    if isinstance(node, dict):
        return [text for key, value in node.items() for text in _strings(key) + _strings(value)]
    if isinstance(node, list):
        return [text for item in node for text in _strings(item)]
    return []


def compare_workflow_text(path: str, base: str, head: str,
                          approved: dict[str, tuple[str, str]]) -> tuple[list[Bump], list[str]]:
    """The pin bumps that turn `base` into `head`, and every reason the change is not only that."""
    label = action_pins.printable(path)
    errors: list[str] = []
    for side, text in (("base", base), ("head", head)):
        refused = workflow_policy.first_refused_character(text)
        if refused is None:
            refused = workflow_policy.first_invisible_character(text)
        if refused is not None:
            errors.append("{}: {} line {}: character U+{:04X} is refused".format(label, side, *refused))
    if errors:
        return [], errors
    base_lines = base.split("\n")
    head_lines = head.split("\n")
    if len(base_lines) != len(head_lines):
        return [], ["{}: the line count changed".format(label)]
    bumps: list[Bump] = []
    for number, (old, new) in enumerate(zip(base_lines, head_lines), start=1):
        if old == new:
            continue
        where = "{}: line {}".format(label, number)
        old_pin = _pin(old)
        new_pin = _pin(new)
        if old_pin is None or new_pin is None:
            errors.append(where + ": a changed line must be a pinned `uses:` line on both sides")
            continue
        old_prefix, old_name, old_sha, old_version = old_pin
        new_prefix, new_name, new_sha, new_version = new_pin
        if old_prefix != new_prefix:
            errors.append(where + ": the `uses:` key or its indentation changed")
            continue
        if old_name != new_name:
            errors.append(where + ": the action name changed")
            continue
        if old_name not in approved:
            errors.append(where + ": the action is not in the reviewed allowlist")
            continue
        if approved[old_name] != (old_sha, old_version):
            errors.append(where + ": the old pin is not the reviewed pin")
            continue
        if old_sha == new_sha:
            errors.append(where + ": the version comment changed but the commit did not")
            continue
        if _version_key(new_version) <= _version_key(old_version):
            errors.append(where + ": the version does not increase")
            continue
        if (old.count(old_sha) != 1 or old.count(old_version) != 1
                or old.replace(old_sha, new_sha).replace(old_version, new_version) != new):
            errors.append(where + ": the line changed beyond its commit and version comment")
            continue
        bumps.append(Bump(path, number, old_name, old_sha, old_version, new_sha, new_version))
    if errors:
        return [], errors
    try:
        base_document = workflow_policy.parse_workflow(base)
        head_document = workflow_policy.parse_workflow(head)
        differences = _differences(base_document, head_document)
    except (workflow_policy.ParseError, RecursionError):
        return [], ["{}: the workflow does not parse under the policy's YAML subset".format(label)]
    moves = {("{}@{}".format(bump.name, bump.old_sha), "{}@{}".format(bump.name, bump.new_sha)) for bump in bumps}
    if len(differences) != len(bumps) or any(
            not _is_step_uses(path) or (old, new) not in moves for path, old, new in differences):
        return [], ["{}: the parsed workflow differs beyond the bumped step `uses` pins".format(label)]
    return bumps, []


def _workflow_files(root: Path) -> dict[str, Path]:
    return {path.relative_to(root).as_posix(): path for path in action_pins.workflow_paths(root)}


def _read(path: Path) -> str:
    return action_pins.read_regular_utf8(path, action_pins.MAX_WORKFLOW_BYTES)


def compare_trees(base_root: Path, head_root: Path, changed_paths: list[str],
                  approved: dict[str, tuple[str, str]]) -> tuple[list[Bump], list[str]]:
    """The pin bumps between two checkouts' workflow files, and every reason the proposal is not
    a pure, complete pin bump. `changed_paths` is every path the proposal changes."""
    if not changed_paths:
        return [], ["the proposal changes no path"]
    if not all(isinstance(path, str) for path in changed_paths):
        return [], ["the changed-path list must hold only path strings"]
    errors: list[str] = []
    if len(set(changed_paths)) != len(changed_paths):
        errors.append("the changed-path list repeats a path")
    for path in changed_paths:
        if WORKFLOW_PATH_PATTERN.fullmatch(path) is None:
            errors.append("a changed path is not a workflow file directly under .github/workflows/")
    if errors:
        return [], errors
    base_files = _workflow_files(base_root)
    head_files = _workflow_files(head_root)
    folded: dict[str, str] = {}
    for path in [*changed_paths, *base_files, *head_files]:
        if folded.setdefault(unicodedata.normalize("NFC", path).casefold(), path) != path:
            return [], ["two workflow paths differ only in case or Unicode normalization"]
    if set(base_files) != set(head_files):
        return [], ["a workflow file was added, removed or renamed"]
    if not set(changed_paths) <= set(base_files):
        return [], ["a changed path is not a workflow file both trees hold"]
    bumps: list[Bump] = []
    head_texts: dict[str, str] = {}
    for relative in sorted(base_files):
        label = action_pins.printable(relative)
        try:
            base = _read(base_files[relative])
            head = _read(head_files[relative])
        except (OSError, UnicodeError, ValueError):
            errors.append("{}: the workflow must be a regular bounded UTF-8 file in both trees".format(label))
            continue
        head_texts[relative] = head
        if relative not in changed_paths:
            if base != head:
                errors.append("{}: the workflow changed but is not in the changed-path list".format(label))
            continue
        if base == head:
            errors.append("{}: listed as changed but identical".format(label))
            continue
        found, problems = compare_workflow_text(relative, base, head, approved)
        bumps.extend(found)
        errors.extend(problems)
    if errors:
        return [], errors
    if not bumps:
        return [], ["the proposal bumps no pin"]
    targets: dict[str, set[tuple[str, str, str, str]]] = {}
    for bump in bumps:
        targets.setdefault(bump.name, set()).add((bump.old_sha, bump.old_version, bump.new_sha, bump.new_version))
    for name, moves in sorted(targets.items()):
        if len(moves) != 1:
            errors.append("{}: the bumps do not all move the same old pin to the same new pin".format(name))
    if errors:
        return [], errors
    old_pins = {"{}@{}".format(name, next(iter(moves))[0]) for name, moves in targets.items()}
    for relative, text in sorted(head_texts.items()):
        label = action_pins.printable(relative)
        try:
            stale = any(value in old_pins for value in _strings(workflow_policy.parse_workflow(text)))
        except (workflow_policy.ParseError, RecursionError):
            errors.append("{}: the workflow does not parse under the policy's YAML subset".format(label))
            continue
        if stale:
            errors.append("{}: still pins the old commit of a bumped action".format(label))
    if errors:
        return [], errors
    return bumps, []


def check_pull_request(pull_request: object, repository_id: object, changed_count: Optional[int]) -> list[str]:
    """Every reason the pull-request object is not a Dependabot proposal in the expected
    repository that changes exactly `changed_count` files."""
    if not pr_metadata.is_dependabot_proposal(pull_request):
        return ["the pull request is not a Dependabot proposal from its own base repository"]
    errors = []
    if type(repository_id) is not int or pull_request["base"]["repo"]["id"] != repository_id:
        errors.append("the pull request's base repository is not the expected repository")
    changed_files = pull_request.get("changed_files")
    if type(changed_files) is not int or changed_files != changed_count:
        errors.append("the pull request's changed-file count is not the length of the changed-path list")
    proposal = _proposal(pull_request)
    if proposal["number"] is None or proposal["number"] < 1 or None in (proposal["head_sha"], proposal["base_sha"]):
        errors.append("the pull request does not name its number and its full head and base commits")
    return errors


def check_reachability(bumps: list[Bump], evidence: object) -> list[str]:
    """Every bumped action's new commit is shown to be its version's tag, and the evidence names
    nothing else. Evidence format, schema_version 1:

        {"schema_version": 1, "actions": {"owner/repo": {"sha": "<new commit>",
            "tag": {"name": "<new version>", "commit": "<commit>"}}}}

    where `commit` is the commit that `refs/tags/<new version>` in the Action's own repository
    peels to (an annotated tag's own object id is not a commit, and fails)."""
    if not isinstance(evidence, dict) or set(evidence) != {"schema_version", "actions"}:
        return ["the reachability evidence must be an object with exactly `schema_version` and `actions`"]
    if type(evidence["schema_version"]) is not int or evidence["schema_version"] != SCHEMA_VERSION:
        return ["the reachability evidence has an unsupported `schema_version`"]
    actions = evidence["actions"]
    if not isinstance(actions, dict):
        return ["the reachability evidence `actions` must be an object"]
    expected = {bump.name: bump for bump in bumps}
    errors: list[str] = []
    if set(actions) != set(expected):
        errors.append("the reachability evidence must name exactly the bumped actions")
    for name in sorted(set(actions) & set(expected)):
        bump = expected[name]
        entry = actions[name]
        if not (isinstance(entry, dict) and set(entry) == {"sha", "tag"} and entry["sha"] == bump.new_sha):
            errors.append("{}: the evidence must give exactly the new commit and its tag".format(name))
            continue
        tag = entry["tag"]
        if not (isinstance(tag, dict) and set(tag) == {"name", "commit"}
                and tag["name"] == bump.new_version and tag["commit"] == bump.new_sha):
            errors.append("{}: the tag named by the new version does not resolve to the new commit".format(name))
    return errors


def _proposal(pull_request: object) -> dict[str, Any]:
    """The pull request's number and head and base commits, where they have the expected types."""
    def field(*keys: str) -> Any:
        node = pull_request
        for key in keys:
            node = node.get(key) if isinstance(node, dict) else None
        return node
    number = field("number")
    head_sha = field("head", "sha")
    base_sha = field("base", "sha")
    return {
        "number": number if type(number) is int else None,
        "head_sha": head_sha if isinstance(head_sha, str) and COMMIT_PATTERN.fullmatch(head_sha) else None,
        "base_sha": base_sha if isinstance(base_sha, str) and COMMIT_PATTERN.fullmatch(base_sha) else None,
    }


def _no_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("a JSON object repeats a key")
        result[key] = value
    return result


def _read_json(path: Path) -> Any:
    text = action_pins.read_regular_utf8(path, MAX_INPUT_BYTES)
    try:
        return json.loads(text, object_pairs_hook=_no_duplicate_keys)
    except RecursionError:
        raise ValueError("a JSON input nests too deeply") from None


def _workflow_root_is_real(root: Path) -> bool:
    """True when `root/.github/workflows` is a directory and neither it nor `.github` is a symlink."""
    for path in (root / ".github", root / ".github" / "workflows"):
        try:
            mode = path.lstat().st_mode
        except OSError:
            return False
        if not stat.S_ISDIR(mode):
            return False
    return True


def judge(base_root: Path, head_root: Path, changed_paths: object, pull_request: object = NOT_SUPPLIED,
          reachability: object = NOT_SUPPLIED, approved: Optional[dict[str, tuple[str, str]]] = None,
          repository_id: object = None) -> dict[str, Any]:
    """The report: which checks ran, which passed, the bumps and the reasons. A check whose input
    was not supplied is "not run", and a proposal qualifies only when all three passed."""
    if approved is None:
        approved = action_pins.load_allowlist()
    if not isinstance(changed_paths, list):
        bumps, structure = [], ["the changed-path list must be a JSON list of paths"]
    else:
        bumps, structure = compare_trees(base_root, head_root, changed_paths, approved)
    checks = {"structure": "pass" if not structure else "fail"}
    errors = list(structure)
    proposal = None
    if pull_request is NOT_SUPPLIED:
        checks["pull_request"] = "not run"
    else:
        proposal = _proposal(pull_request)
        count = len(changed_paths) if isinstance(changed_paths, list) else None
        problems = check_pull_request(pull_request, repository_id, count)
        checks["pull_request"] = "pass" if not problems else "fail"
        errors.extend(problems)
    if reachability is NOT_SUPPLIED or structure:
        checks["reachability"] = "not run"
    else:
        problems = check_reachability(bumps, reachability)
        checks["reachability"] = "pass" if not problems else "fail"
        errors.extend(problems)
    return {
        "schema_version": SCHEMA_VERSION,
        "qualifies": all(result == "pass" for result in checks.values()),
        "checks": checks,
        "proposal": proposal,
        "bumps": [bump._asdict() for bump in bumps],
        "errors": errors,
    }


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Judge a Dependabot workflow-pin proposal from files.")
    parser.add_argument("--base-root", type=Path, required=True,
                        help="checkout of the current tip of the pull request's base branch")
    parser.add_argument("--head-root", type=Path, required=True,
                        help="directory holding the proposal's .github/workflows files")
    parser.add_argument("--changed-paths", type=Path, required=True,
                        help="JSON list of every path the proposal changes")
    parser.add_argument("--pull-request", type=Path,
                        help="JSON pull-request object from the GitHub API's single pull-request "
                             "endpoint (the list endpoint omits changed_files)")
    parser.add_argument("--repository-id", type=int,
                        help="id of the repository the proposal must target (with --pull-request)")
    parser.add_argument("--reachability", type=Path,
                        help="JSON reachability evidence (see check_reachability)")
    arguments = parser.parse_args(argv)
    if (arguments.pull_request is None) != (arguments.repository_id is None):
        print("dependabot pin exception: --pull-request and --repository-id go together", file=sys.stderr)
        return 2
    for root in (arguments.base_root, arguments.head_root):
        if not _workflow_root_is_real(root):
            print("dependabot pin exception: a root has no real .github/workflows directory", file=sys.stderr)
            return 2
    try:
        changed = _read_json(arguments.changed_paths)
        pull_request = NOT_SUPPLIED if arguments.pull_request is None else _read_json(arguments.pull_request)
        reachability = NOT_SUPPLIED if arguments.reachability is None else _read_json(arguments.reachability)
        report = judge(arguments.base_root, arguments.head_root, changed, pull_request, reachability,
                       repository_id=arguments.repository_id)
    except (OSError, UnicodeError, ValueError, RecursionError) as error:
        print("dependabot pin exception: an input could not be read ({})".format(
            type(error).__name__), file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2, sort_keys=True))
    for error in report["errors"]:
        print("dependabot pin exception: " + error, file=sys.stderr)
    return 0 if report["qualifies"] else 1


if __name__ == "__main__":
    sys.exit(main())
