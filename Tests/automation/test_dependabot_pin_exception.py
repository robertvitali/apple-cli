"""Tests for scripts/ci/dependabot_pin_exception.py, the offline core of the design §10.5
Dependabot workflow-pin exception."""
from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Optional

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "ci" / "dependabot_pin_exception.py"


def load_module():
    spec = importlib.util.spec_from_file_location("dependabot_pin_exception", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


exception = load_module()

OLD_A = "a1" * 20
NEW_A = "b2" * 20
OTHER_A = "c3" * 20
OLD_B = "d4" * 20
NEW_B = "e5" * 20
APPROVED = {"actions/checkout": (OLD_A, "v1.2.3"), "actions/setup-python": (OLD_B, "v5.0.0")}


def workflow(checkout: str = OLD_A + " # v1.2.3", python: str = OLD_B + " # v5.0.0",
             extra: str = "") -> str:
    return (
        "name: CI\n"
        "on:\n"
        "  push:\n"
        "    branches: [main]\n"
        "permissions:\n"
        "  contents: read\n"
        "jobs:\n"
        "  build:\n"
        "    runs-on: ubuntu-latest\n"
        "    steps:\n"
        "      - uses: actions/checkout@" + checkout + "\n"
        "        with:\n"
        "          persist-credentials: false\n"
        "      - uses: actions/setup-python@" + python + "\n"
        "      - run: python3 -V\n" + extra
    )


BUMPED = workflow(checkout=NEW_A + " # v1.2.4")


def a_higher_patch(version: str) -> str:
    """`version` with a digit appended to its patch, which always raises it, with no int() on a
    component of any length."""
    return version + "1"


REPOSITORY_ID = 7
HEAD_COMMIT = "f6" * 20
BASE_COMMIT = "07" * 20


def dependabot_pull_request(changed_files: int = 1) -> dict:
    return {
        "number": 12,
        "changed_files": changed_files,
        "user": {"login": "dependabot[bot]", "type": "Bot", "id": exception.pr_metadata.DEPENDABOT_ACCOUNT_ID},
        "head": {"sha": HEAD_COMMIT, "repo": {"id": REPOSITORY_ID}},
        "base": {"sha": BASE_COMMIT, "repo": {"id": REPOSITORY_ID}},
    }


def write_tree(root: Path, files: dict[str, str]) -> None:
    for relative, text in files.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")


class WorkflowTextTests(unittest.TestCase):
    def compare(self, head: str, base: str = None):
        return exception.compare_workflow_text(".github/workflows/ci.yml", workflow() if base is None else base,
                                               head, APPROVED)

    def assert_refused(self, head: str, reason: str, base: str = None) -> None:
        bumps, errors = self.compare(head, base)
        self.assertEqual(bumps, [])
        self.assertTrue(any(reason in error for error in errors), errors)

    def test_a_single_pin_bump_is_accepted(self) -> None:
        bumps, errors = self.compare(BUMPED)
        self.assertEqual(errors, [])
        self.assertEqual(bumps, [exception.Bump(".github/workflows/ci.yml", 11, "actions/checkout",
                                                OLD_A, "v1.2.3", NEW_A, "v1.2.4")])

    def test_two_actions_bumped_in_one_file_are_accepted(self) -> None:
        bumps, errors = self.compare(workflow(checkout=NEW_A + " # v1.3.0", python=NEW_B + " # v6.0.0"))
        self.assertEqual(errors, [])
        self.assertEqual([(b.name, b.new_version) for b in bumps],
                         [("actions/checkout", "v1.3.0"), ("actions/setup-python", "v6.0.0")])

    def test_any_other_changed_line_is_refused(self) -> None:
        for head in (BUMPED.replace("contents: read", "contents: write"),
                     BUMPED.replace("python3 -V", "python3 -c 'print(1)'"),
                     BUMPED.replace("persist-credentials: false", "persist-credentials: true"),
                     BUMPED.replace("name: CI", "name: CI2")):
            with self.subTest(head=head):
                self.assert_refused(head, "a changed line must be a pinned `uses:` line")

    def test_an_added_or_removed_line_is_refused(self) -> None:
        self.assert_refused(BUMPED + "      - run: echo hi\n", "the line count changed")
        self.assert_refused(BUMPED.replace("      - run: python3 -V\n", ""), "the line count changed")

    def test_the_uses_key_and_its_indentation_must_not_change(self) -> None:
        self.assert_refused(BUMPED.replace("      - uses: actions/checkout", "      -  uses: actions/checkout"),
                            "the `uses:` key or its indentation changed")
        self.assert_refused(BUMPED.replace("      - uses: actions/checkout", "      - uses : actions/checkout"),
                            "the `uses:` key or its indentation changed")

    def test_the_action_name_must_not_change(self) -> None:
        self.assert_refused(workflow(checkout=OLD_A + " # v1.2.3").replace(
            "actions/checkout@" + OLD_A + " # v1.2.3", "actions/setup-python@" + NEW_A + " # v1.2.4"),
            "the action name changed")

    def test_an_action_outside_the_allowlist_is_refused(self) -> None:
        base = workflow().replace("actions/setup-python", "someone/tool")
        head = base.replace(OLD_B + " # v5.0.0", NEW_B + " # v5.0.1")
        self.assert_refused(head, "not in the reviewed allowlist", base=base)

    def test_the_old_pin_must_be_the_reviewed_pin(self) -> None:
        base = workflow(checkout=OTHER_A + " # v1.2.3")
        self.assert_refused(workflow(checkout=NEW_A + " # v1.2.4"), "the old pin is not the reviewed pin", base=base)
        base = workflow(checkout=OLD_A + " # v1.2.2")
        self.assert_refused(workflow(checkout=NEW_A + " # v1.2.4"), "the old pin is not the reviewed pin", base=base)

    def test_a_comment_change_without_a_new_commit_is_refused(self) -> None:
        self.assert_refused(workflow(checkout=OLD_A + " # v1.2.4"), "the commit did not")

    def test_the_version_must_increase(self) -> None:
        for version in ("v1.2.3", "v1.2.2", "v0.9.9", "v1.1.10"):
            with self.subTest(version=version):
                self.assert_refused(workflow(checkout=NEW_A + " # " + version), "the version does not increase")

    def test_versions_compare_numerically(self) -> None:
        for version in ("v1.2.10", "v1.2.04", "v1.2.123456789"):
            with self.subTest(version=version):
                bumps, errors = self.compare(workflow(checkout=NEW_A + " # " + version))
                self.assertEqual(errors, [])
                self.assertEqual(bumps[0].new_version, version)
        self.assert_refused(workflow(checkout=NEW_A + " # v1.2.003"), "the version does not increase")

    def test_leading_zeros_compare_by_value(self) -> None:
        for old, new, increases in (("v1.2.05", "v1.2.4", False), ("v1.2.04", "v1.2.4", False),
                                    ("v1.2.4", "v1.2.05", True), ("v1.2.010", "v1.2.9", False),
                                    ("v1.2.9", "v1.2.010", True)):
            with self.subTest(old=old, new=new):
                approved = dict(APPROVED, **{"actions/checkout": (OLD_A, old)})
                bumps, errors = exception.compare_workflow_text(
                    ".github/workflows/ci.yml", workflow(checkout=OLD_A + " # " + old),
                    workflow(checkout=NEW_A + " # " + new), approved)
                if increases:
                    self.assertEqual(errors, [])
                else:
                    self.assertTrue(any("the version does not increase" in error for error in errors), errors)

    def test_versions_of_any_length_compare_without_failing(self) -> None:
        nines, power = "9" * 5000, "1" + "0" * 5000
        cases = {
            "v1.2." + nines: [("v1.2." + power, True), ("v1.3.0", True), ("v1.2.0" + nines, False),
                              ("v1.2." + nines[:-1] + "8", False), ("v1.2." + nines[:-1], False)],
            "v1." + nines + ".0": [("v1." + power + ".0", True), ("v2.0.0", True), ("v1." + nines[:-1] + ".9", False)],
            "v" + nines + ".0.0": [("v" + power + ".0.0", True), ("v" + nines + ".0.1", True),
                                   ("v" + nines[:-1] + ".9.9", False)],
        }
        for old, heads in cases.items():
            approved = dict(APPROVED, **{"actions/checkout": (OLD_A, old)})
            base = workflow(checkout=OLD_A + " # " + old)
            for version, increases in heads:
                with self.subTest(old=old[:8], version=version[:12], length=len(version)):
                    bumps, errors = exception.compare_workflow_text(
                        ".github/workflows/ci.yml", base, workflow(checkout=NEW_A + " # " + version), approved)
                    if increases:
                        self.assertEqual(errors, [])
                        self.assertEqual(bumps[0].new_version, version)
                    else:
                        self.assertTrue(any("the version does not increase" in error for error in errors), errors)

    def test_only_a_step_uses_path_counts_as_a_step_action(self) -> None:
        self.assertTrue(exception._is_step_uses(("jobs", "build", "steps", 0, "uses")))
        for path in (("jobs", 0, "steps", 0, "uses"), ("jobs", "build", "steps", 0, "run"),
                     ("jobs", "build", "steps", "0", "uses"), ("jobs", "build", "steps", True, "uses"),
                     ("x", "build", "steps", 0, "uses"), ("jobs", "build", "foo", 0, "uses"),
                     ("jobs", "build", "steps", 0, "uses", "uses"), ("jobs", "build", "steps", 0)):
            with self.subTest(path=path):
                self.assertFalse(exception._is_step_uses(path))

    def test_a_malformed_new_pin_is_refused(self) -> None:
        for value in (NEW_A[:12] + " # v1.2.4", NEW_A + " # v1.2.4 extra", NEW_A + " # 1.2.4", NEW_A,
                      NEW_A.upper() + " # v1.2.4", "${{ env.PIN }} # v1.2.4", NEW_A + "  #  v1.2.4x",
                      NEW_A + " # v1.2." + chr(0x664), NEW_A + " # v1.2." + chr(0xFF14)):
            with self.subTest(value=value):
                self.assert_refused(workflow(checkout=value), "a changed line must be a pinned `uses:` line")

    def test_any_change_beyond_the_commit_and_comment_is_refused(self) -> None:
        for head in (workflow().replace("actions/checkout@" + OLD_A + " # v1.2.3",
                                        '"actions/checkout@' + NEW_A + '" # v1.2.4'),
                     workflow(checkout=NEW_A + "  # v1.2.4"),
                     workflow(checkout=NEW_A + " #  v1.2.4")):
            with self.subTest(head=head):
                self.assert_refused(head, "the line changed beyond its commit and version comment")

    def test_refused_and_invisible_characters_are_refused_on_either_side(self) -> None:
        for character in ("\r", "\u00a0", "\u200b", "\u2028", "\ufeff"):
            with self.subTest(character=repr(character)):
                self.assert_refused(BUMPED.replace("name: CI", "name: CI" + character), "is refused")
                self.assert_refused(BUMPED, "is refused", base=workflow().replace("name: CI", "name: CI" + character))

    def test_pin_shaped_text_inside_a_run_block_does_not_count_as_a_pin(self) -> None:
        extra = "      - run: |\n          echo actions/checkout@" + OLD_A + " # v1.2.3\n"
        base = workflow(extra=extra)
        head = workflow(extra="      - run: |\n          uses: actions/checkout@" + NEW_A + " # v1.2.4\n")
        base = base.replace("          echo actions", "          uses: actions")
        self.assert_refused(head, "the parsed workflow differs beyond the bumped step `uses` pins", base=base)

    def test_a_uses_key_that_is_not_a_step_action_is_refused(self) -> None:
        placements = {
            "workflow env": lambda pin: ("env:\n  uses: actions/checkout@" + pin + "\n", ""),
            "step env": lambda pin: ("", "        env:\n          uses: actions/checkout@" + pin + "\n"),
            "step with": lambda pin: ("", "        with:\n          uses: actions/checkout@" + pin + "\n"),
            "job": lambda pin: ("", "  call:\n    uses: actions/checkout@" + pin + "\n"),
            "top-level key other than jobs": lambda pin: (
                "x:\n  build:\n    steps:\n      - uses: actions/checkout@" + pin + "\n", ""),
            "job key other than steps": lambda pin: ("", "    foo:\n      - uses: actions/checkout@" + pin + "\n"),
            "steps as a mapping": lambda pin: (
                "", "  other:\n    steps:\n      first:\n        uses: actions/checkout@" + pin + "\n"),
            "uses under a step's uses": lambda pin: (
                "", "      - uses:\n          uses: actions/checkout@" + pin + "\n"),
        }
        for where, placement in placements.items():
            with self.subTest(where=where):
                base_lead, base_extra = placement(OLD_A + " # v1.2.3")
                head_lead, head_extra = placement(NEW_A + " # v1.2.4")
                base = base_lead + workflow(extra=base_extra)
                head = head_lead + workflow(checkout=NEW_A + " # v1.2.4", extra=head_extra)
                self.assertEqual(self.compare(base, base), ([], []))
                self.assert_refused(head, "the parsed workflow differs beyond the bumped step `uses` pins",
                                    base=base)

    def test_a_step_action_bumped_alongside_another_uses_key_is_still_refused(self) -> None:
        base = workflow(extra="        env:\n          uses: actions/checkout@" + OLD_A + " # v1.2.3\n")
        head = base.replace(OLD_A + " # v1.2.3", NEW_A + " # v1.2.4")
        self.assertEqual(head.count(NEW_A), 2)
        self.assert_refused(head, "the parsed workflow differs beyond the bumped step `uses` pins", base=base)

    def test_a_base_outside_the_yaml_subset_is_refused(self) -> None:
        base = workflow().replace("    branches: [main]\n", "    branches: {a: b}\n")
        head = BUMPED.replace("    branches: [main]\n", "    branches: {a: b}\n")
        self.assert_refused(head, "does not parse under the policy's YAML subset", base=base)


class TreeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.base = Path(self.directory.name) / "base"
        self.head = Path(self.directory.name) / "head"
        write_tree(self.base, {".github/workflows/ci.yml": workflow(),
                               ".github/workflows/docs.yml": workflow()})

    def tearDown(self) -> None:
        self.directory.cleanup()

    def judge(self, head_files: dict[str, str], changed: list[str]):
        write_tree(self.head, head_files)
        return exception.compare_trees(self.base, self.head, changed, APPROVED)

    def assert_refused(self, head_files: dict[str, str], changed: list[str], reason: str) -> None:
        bumps, errors = self.judge(head_files, changed)
        self.assertEqual(bumps, [])
        self.assertTrue(any(reason in error for error in errors), errors)

    def test_a_complete_bump_across_two_files_is_accepted(self) -> None:
        bumps, errors = self.judge({".github/workflows/ci.yml": BUMPED, ".github/workflows/docs.yml": BUMPED},
                                   [".github/workflows/ci.yml", ".github/workflows/docs.yml"])
        self.assertEqual(errors, [])
        self.assertEqual([bump.path for bump in bumps], [".github/workflows/ci.yml", ".github/workflows/docs.yml"])

    def test_only_top_level_workflow_files_may_change(self) -> None:
        both = {".github/workflows/ci.yml": BUMPED, ".github/workflows/docs.yml": BUMPED}
        for path in (".github/actions-allowlist.json", ".github/workflows/nested/ci.yml", "ci.yml",
                     ".github/workflows/ci.json", ".github/workflows/../ci.yml"):
            with self.subTest(path=path):
                self.assert_refused(both, [".github/workflows/ci.yml", ".github/workflows/docs.yml", path],
                                    "not a workflow file directly under .github/workflows/")

    def test_an_empty_or_repeating_changed_path_list_is_refused(self) -> None:
        self.assert_refused({}, [], "the proposal changes no path")
        self.assert_refused({}, [".github/workflows/ci.yml", ".github/workflows/ci.yml"], "repeats a path")

    def test_a_changed_path_list_holding_anything_but_strings_is_refused(self) -> None:
        for changed in ([[]], [{}], [None], [".github/workflows/ci.yml", 1], [["a"], ["a"]]):
            with self.subTest(changed=changed):
                self.assert_refused({}, changed, "must hold only path strings")

    def test_an_added_or_removed_workflow_is_refused(self) -> None:
        self.assert_refused({".github/workflows/ci.yml": BUMPED, ".github/workflows/docs.yml": BUMPED,
                             ".github/workflows/new.yml": BUMPED},
                            [".github/workflows/ci.yml", ".github/workflows/docs.yml", ".github/workflows/new.yml"],
                            "added, removed or renamed")
        self.assert_refused({".github/workflows/ci.yml": BUMPED}, [".github/workflows/ci.yml"],
                            "added, removed or renamed")

    def test_an_unlisted_change_and_a_listed_unchanged_file_are_refused(self) -> None:
        self.assert_refused({".github/workflows/ci.yml": BUMPED, ".github/workflows/docs.yml": BUMPED},
                            [".github/workflows/ci.yml"], "changed but is not in the changed-path list")
        self.assert_refused({".github/workflows/ci.yml": BUMPED, ".github/workflows/docs.yml": workflow()},
                            [".github/workflows/ci.yml", ".github/workflows/docs.yml"],
                            "listed as changed but identical")

    def test_a_listed_path_neither_tree_holds_is_refused(self) -> None:
        self.assert_refused({".github/workflows/ci.yml": BUMPED, ".github/workflows/docs.yml": BUMPED},
                            [".github/workflows/ci.yml", ".github/workflows/docs.yml", ".github/workflows/new.yml"],
                            "a changed path is not a workflow file both trees hold")

    def test_paths_that_differ_only_in_case_or_normalization_are_refused(self) -> None:
        both = {".github/workflows/ci.yml": BUMPED, ".github/workflows/docs.yml": BUMPED}
        for extra in (".github/workflows/CI.yml", ".github/workflows/Docs.yml"):
            with self.subTest(extra=extra):
                self.assert_refused(both, [".github/workflows/ci.yml", ".github/workflows/docs.yml", extra],
                                    "differ only in case or Unicode normalization")
        composed = ".github/workflows/caf" + chr(0xE9) + ".yml"
        decomposed = ".github/workflows/cafe" + chr(0x301) + ".yml"
        self.assert_refused(both, [".github/workflows/ci.yml", ".github/workflows/docs.yml", composed, decomposed],
                            "differ only in case or Unicode normalization")

    def test_a_partial_bump_is_refused(self) -> None:
        self.assert_refused({".github/workflows/ci.yml": BUMPED, ".github/workflows/docs.yml": workflow()},
                            [".github/workflows/ci.yml"], "still pins the old commit of a bumped action")

    def test_an_old_pin_left_in_a_uses_key_outside_a_step_is_refused(self) -> None:
        for extra in ("        env:\n          uses: actions/checkout@" + OLD_A + " # v1.2.3\n",
                      '        env:\n          "actions/checkout@' + OLD_A + '": kept\n'):
            with self.subTest(extra=extra):
                write_tree(self.base, {".github/workflows/ci.yml": workflow(extra=extra),
                                       ".github/workflows/docs.yml": BUMPED})
                self.assert_refused({".github/workflows/ci.yml": workflow(checkout=NEW_A + " # v1.2.4", extra=extra),
                                     ".github/workflows/docs.yml": BUMPED},
                                    [".github/workflows/ci.yml"], "still pins the old commit of a bumped action")

    def test_a_base_rollback_in_a_listed_workflow_reads_as_a_bump(self) -> None:
        # Pins the residual the docstring states: judged against a base that moved after the
        # proposal was cut, a pin rolled back there reads as a bump the proposal never made, which
        # is why the caller must judge only a proposal whose head contains the base tip.
        rolled_back = "f0" * 20
        tip = workflow(python=rolled_back + " # v4.9.0")
        write_tree(self.base, {".github/workflows/ci.yml": tip, ".github/workflows/docs.yml": tip})
        approved = dict(APPROVED, **{"actions/setup-python": (rolled_back, "v4.9.0")})
        stale_head = workflow(checkout=NEW_A + " # v1.2.4")
        write_tree(self.head, {".github/workflows/ci.yml": stale_head, ".github/workflows/docs.yml": stale_head})
        bumps, errors = exception.compare_trees(
            self.base, self.head, [".github/workflows/ci.yml", ".github/workflows/docs.yml"], approved)
        self.assertEqual(errors, [])
        self.assertIn(("actions/setup-python", rolled_back, OLD_B), {(b.name, b.old_sha, b.new_sha) for b in bumps})

    def test_an_old_pin_left_without_a_version_comment_is_refused(self) -> None:
        bare = workflow(checkout=OLD_A, python=OLD_B)
        write_tree(self.base, {".github/workflows/docs.yml": bare})
        self.assert_refused({".github/workflows/ci.yml": BUMPED, ".github/workflows/docs.yml": bare},
                            [".github/workflows/ci.yml"], "still pins the old commit of a bumped action")

    def test_an_old_pin_quoted_in_a_run_block_is_text_not_a_pin(self) -> None:
        block = "      - run: |\n          uses: actions/checkout@" + OLD_A + " # v1.2.3\n"
        write_tree(self.base, {".github/workflows/docs.yml": workflow(extra=block)})
        bumps, errors = self.judge({".github/workflows/ci.yml": BUMPED,
                                    ".github/workflows/docs.yml": workflow(checkout=NEW_A + " # v1.2.4", extra=block)},
                                   [".github/workflows/ci.yml", ".github/workflows/docs.yml"])
        self.assertEqual(errors, [])
        self.assertEqual(len(bumps), 2)

    def test_an_action_moved_to_two_different_pins_is_refused(self) -> None:
        self.assert_refused({".github/workflows/ci.yml": BUMPED,
                             ".github/workflows/docs.yml": workflow(checkout=OTHER_A + " # v1.2.5")},
                            [".github/workflows/ci.yml", ".github/workflows/docs.yml"],
                            "do not all move the same old pin to the same new pin")

    def test_a_symlinked_workflow_is_refused(self) -> None:
        write_tree(self.head, {".github/workflows/docs.yml": workflow(), "elsewhere.yml": BUMPED})
        os.symlink(self.head / "elsewhere.yml", self.head / ".github/workflows/ci.yml")
        bumps, errors = exception.compare_trees(self.base, self.head, [".github/workflows/ci.yml"], APPROVED)
        self.assertEqual(bumps, [])
        self.assertTrue(any("regular bounded UTF-8 file" in error for error in errors), errors)


class PullRequestTests(unittest.TestCase):
    def check(self, pull_request: object, repository_id: object = REPOSITORY_ID, count: object = 1) -> list:
        return exception.check_pull_request(pull_request, repository_id, count)

    def test_a_dependabot_proposal_in_the_expected_repository_passes(self) -> None:
        self.assertEqual(self.check(dependabot_pull_request()), [])

    def test_a_proposal_that_is_not_dependabots_fails(self) -> None:
        cases = []
        for path, value in ((("user", "login"), "dependabot"), (("user", "type"), "User"),
                            (("user", "id"), 1), (("user", "id"), str(exception.pr_metadata.DEPENDABOT_ACCOUNT_ID)),
                            (("head", "repo", "id"), 8)):
            pull_request = dependabot_pull_request()
            node = pull_request
            for key in path[:-1]:
                node = node[key]
            node[path[-1]] = value
            cases.append(pull_request)
        cases.extend([None, [], {"user": {}}])
        for pull_request in cases:
            with self.subTest(pull_request=pull_request):
                self.assertEqual(self.check(pull_request),
                                 ["the pull request is not a Dependabot proposal from its own base repository"])

    def test_another_repository_fails(self) -> None:
        for repository_id in (8, None, str(REPOSITORY_ID), True):
            with self.subTest(repository_id=repository_id):
                self.assertEqual(self.check(dependabot_pull_request(), repository_id),
                                 ["the pull request's base repository is not the expected repository"])

    def test_a_changed_file_count_that_does_not_match_fails(self) -> None:
        for pull_request, count in ((dependabot_pull_request(2), 1), (dependabot_pull_request(), 2),
                                    (dependabot_pull_request(), None), (dict(dependabot_pull_request(), changed_files="1"), 1),
                                    (dict(dependabot_pull_request(), changed_files=True), 1)):
            with self.subTest(changed_files=pull_request.get("changed_files"), count=count):
                self.assertEqual(self.check(pull_request, count=count),
                                 ["the pull request's changed-file count is not the length of the changed-path list"])

    def test_a_pull_request_without_its_number_or_full_commits_fails(self) -> None:
        cases = []
        for path, value in ((("number",), None), (("number",), "12"), (("number",), 0), (("number",), True),
                            (("head", "sha"), None), (("head", "sha"), HEAD_COMMIT.upper()),
                            (("head", "sha"), HEAD_COMMIT[:12]), (("base", "sha"), None),
                            (("base", "sha"), "\n" + BASE_COMMIT[1:])):
            pull_request = dependabot_pull_request()
            node = pull_request
            for key in path[:-1]:
                node = node[key]
            if value is None:
                del node[path[-1]]
            else:
                node[path[-1]] = value
            cases.append((path, value, pull_request))
        for path, value, pull_request in cases:
            with self.subTest(field=".".join(path), value=value):
                self.assertEqual(self.check(pull_request),
                                 ["the pull request does not name its number and its full head and base commits"])


class ReachabilityTests(unittest.TestCase):
    BUMPS = [exception.Bump(".github/workflows/ci.yml", 11, "actions/checkout", OLD_A, "v1.2.3", NEW_A, "v1.2.4")]

    def evidence(self, proof: dict, sha: str = NEW_A, name: str = "actions/checkout") -> dict:
        return {"schema_version": 1, "actions": {name: dict({"sha": sha}, **proof)}}

    def test_the_tag_named_by_the_new_version_at_the_new_commit_passes(self) -> None:
        self.assertEqual(exception.check_reachability(self.BUMPS, self.evidence({"tag": {"name": "v1.2.4", "commit": NEW_A}})), [])

    def test_unproven_reachability_fails(self) -> None:
        tag = {"tag": {"name": "v1.2.4", "commit": NEW_A}}
        cases = [
            self.evidence({"tag": {"name": "v1.2.5", "commit": NEW_A}}),
            self.evidence({"tag": {"name": "v1.2.4", "commit": OTHER_A}}),
            self.evidence({"tag": {"name": "v1.2.4"}}),
            self.evidence({"tag": {"name": "v1.2.4", "commit": NEW_A, "peeled": True}}),
            self.evidence({"tag": ["v1.2.4", NEW_A]}),
            self.evidence({"default_branch": {"name": "main", "compare_status": "behind"}}),
            self.evidence(dict(tag, default_branch={"name": "main", "compare_status": "behind"})),
            self.evidence(tag, sha=OTHER_A),
            self.evidence({"elsewhere": {}}),
            self.evidence(tag, name="actions/setup-python"),
            {"schema_version": 2, "actions": self.evidence(tag)["actions"]},
            {"schema_version": True, "actions": self.evidence(tag)["actions"]},
            {"schema_version": 1, "actions": self.evidence(tag)["actions"], "extra": 1},
            {"schema_version": 1, "actions": []},
            {"actions": {}},
            [],
        ]
        extra = self.evidence(tag)
        extra["actions"]["someone/tool"] = {"sha": NEW_B, "tag": {"name": "v1.0.0", "commit": NEW_B}}
        cases.append(extra)
        for evidence in cases:
            with self.subTest(evidence=evidence):
                self.assertNotEqual(exception.check_reachability(self.BUMPS, evidence), [])


class JudgeAndCommandTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.base = self.root / "base"
        self.head = self.root / "head"
        write_tree(self.base, {".github/workflows/ci.yml": workflow()})
        write_tree(self.head, {".github/workflows/ci.yml": BUMPED})
        self.tag = {"schema_version": 1,
                    "actions": {"actions/checkout": {"sha": NEW_A, "tag": {"name": "v1.2.4", "commit": NEW_A}}}}

    def tearDown(self) -> None:
        self.directory.cleanup()

    def judge(self, changed: object, pull_request: object = exception.NOT_SUPPLIED,
              reachability: object = exception.NOT_SUPPLIED) -> dict:
        return exception.judge(self.base, self.head, changed, pull_request, reachability, APPROVED,
                               repository_id=REPOSITORY_ID)

    def test_a_proposal_qualifies_only_when_every_check_ran_and_passed(self) -> None:
        changed = [".github/workflows/ci.yml"]
        report = self.judge(changed, dependabot_pull_request(), self.tag)
        self.assertEqual(report["checks"], {"structure": "pass", "pull_request": "pass", "reachability": "pass"})
        self.assertTrue(report["qualifies"])
        self.assertEqual(report["errors"], [])
        self.assertEqual(report["bumps"][0]["new_sha"], NEW_A)
        self.assertEqual(report["proposal"], {"number": 12, "head_sha": HEAD_COMMIT, "base_sha": BASE_COMMIT})
        report = self.judge(changed)
        self.assertEqual(report["checks"], {"structure": "pass", "pull_request": "not run", "reachability": "not run"})
        self.assertIsNone(report["proposal"])
        self.assertFalse(report["qualifies"])

    def test_a_supplied_null_input_fails_rather_than_not_running(self) -> None:
        report = self.judge([".github/workflows/ci.yml"], None, None)
        self.assertEqual(report["checks"], {"structure": "pass", "pull_request": "fail", "reachability": "fail"})
        self.assertFalse(report["qualifies"])

    def test_reachability_does_not_run_when_the_structure_fails(self) -> None:
        report = self.judge([".github/workflows/ci.yml", ".github/workflows/ci.yml"], dependabot_pull_request(2), self.tag)
        self.assertEqual(report["checks"]["structure"], "fail")
        self.assertEqual(report["checks"]["reachability"], "not run")

    def test_a_changed_path_list_that_is_not_a_list_fails_the_structure(self) -> None:
        for changed in (".github/workflows/ci.yml", {".github/workflows/ci.yml": 1}, None):
            with self.subTest(changed=changed):
                report = self.judge(changed)
                self.assertEqual(report["checks"]["structure"], "fail")
                self.assertEqual(report["errors"], ["the changed-path list must be a JSON list of paths"])

    def test_the_proposal_echo_drops_fields_of_the_wrong_type(self) -> None:
        pull_request = dependabot_pull_request()
        pull_request["number"] = "12"
        pull_request["head"]["sha"] = HEAD_COMMIT.upper()
        pull_request["base"]["sha"] = "\n" + BASE_COMMIT[1:]
        report = self.judge([".github/workflows/ci.yml"], pull_request, self.tag)
        self.assertEqual(report["proposal"], {"number": None, "head_sha": None, "base_sha": None})
        self.assertEqual(report["checks"]["pull_request"], "fail")
        self.assertFalse(report["qualifies"])

    def run_command(self, changed: object, pull_request: object = None, reachability: object = None,
                    raw: dict = None, repository_id: object = "with the pull request",
                    base: Optional[Path] = None) -> subprocess.CompletedProcess:
        arguments = [sys.executable, "-I", "-S", "-B", str(SCRIPT), "--base-root", str(base or self.base),
                     "--head-root", str(self.head)]
        if repository_id == "with the pull request":
            given = pull_request is not None or "--pull-request" in (raw or {})
            repository_id = REPOSITORY_ID if given else None
        if repository_id is not None:
            arguments += ["--repository-id", str(repository_id)]
        for flag, value in (("--changed-paths", changed), ("--pull-request", pull_request),
                            ("--reachability", reachability)):
            if value is None and flag not in (raw or {}):
                continue
            path = self.root / (flag.strip("-") + ".json")
            path.write_text((raw or {}).get(flag, json.dumps(value)), encoding="utf-8")
            arguments += [flag, str(path)]
        return subprocess.run(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True, check=False)

    def use_reviewed_checkout_pin(self) -> tuple[str, str]:
        sha, version = exception.action_pins.load_allowlist()["actions/checkout"]
        new_version = a_higher_patch(version)
        text = workflow().replace("actions/checkout@" + OLD_A + " # v1.2.3",
                                  "actions/checkout@" + sha + " # " + version)
        write_tree(self.base, {".github/workflows/ci.yml": text})
        write_tree(self.head, {".github/workflows/ci.yml": text.replace(sha + " # " + version,
                                                                        NEW_A + " # " + new_version)})
        return sha, new_version

    def test_the_command_reports_and_exits_zero_only_for_a_qualifying_proposal(self) -> None:
        _, new_version = self.use_reviewed_checkout_pin()
        evidence = {"schema_version": 1,
                    "actions": {"actions/checkout": {"sha": NEW_A, "tag": {"name": new_version, "commit": NEW_A}}}}
        result = self.run_command([".github/workflows/ci.yml"], dependabot_pull_request(), evidence)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)["qualifies"])
        result = self.run_command([".github/workflows/ci.yml"], dependabot_pull_request(), evidence, repository_id=None)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("--pull-request and --repository-id go together", result.stderr)
        result = self.run_command([".github/workflows/ci.yml"], repository_id=REPOSITORY_ID)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("--pull-request and --repository-id go together", result.stderr)
        result = self.run_command([".github/workflows/ci.yml"], dependabot_pull_request(), evidence, repository_id=8)
        self.assertEqual(result.returncode, 1)
        self.assertIn("is not the expected repository", result.stderr)
        result = self.run_command([".github/workflows/ci.yml"])
        self.assertEqual(result.returncode, 1)
        self.assertFalse(json.loads(result.stdout)["qualifies"])

    def test_the_command_gives_a_verdict_for_a_version_of_any_length(self) -> None:
        sha, version = exception.action_pins.load_allowlist()["actions/checkout"]
        text = workflow().replace("actions/checkout@" + OLD_A + " # v1.2.3", "actions/checkout@" + sha + " # " + version)
        write_tree(self.base, {".github/workflows/ci.yml": text})
        for new_version, code in ((a_higher_patch(version) + "0" * 5000, 0), ("v0.0." + "0" * 5000, 1)):
            with self.subTest(length=len(new_version), code=code):
                write_tree(self.head, {".github/workflows/ci.yml": text.replace(
                    sha + " # " + version, NEW_A + " # " + new_version)})
                evidence = {"schema_version": 1, "actions": {
                    "actions/checkout": {"sha": NEW_A, "tag": {"name": new_version, "commit": NEW_A}}}}
                result = self.run_command([".github/workflows/ci.yml"], dependabot_pull_request(), evidence)
                self.assertEqual(result.returncode, code, result.stderr[-300:])
                self.assertEqual(json.loads(result.stdout)["qualifies"], code == 0)

    def test_the_command_judges_against_the_tracked_allowlist(self) -> None:
        result = self.run_command([".github/workflows/ci.yml"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("the old pin is not the reviewed pin", result.stderr)

    def test_unreadable_input_exits_two_with_nothing_on_stdout(self) -> None:
        oversized = json.dumps([".github/workflows/ci.yml"]) + " " * exception.MAX_INPUT_BYTES
        for raw in ({"--changed-paths": '["a", '}, {"--pull-request": '{"user": {}, "user": {}}'},
                    {"--changed-paths": "[" * 100000}, {"--reachability": "[" * 100000},
                    {"--changed-paths": oversized}):
            with self.subTest(flag=list(raw)[0], size=len(list(raw.values())[0])):
                result = self.run_command([".github/workflows/ci.yml"], raw=raw)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("Traceback", result.stderr)
                self.assertIn("an input could not be read", result.stderr)

    def test_a_root_without_a_real_workflow_directory_exits_two(self) -> None:
        linked = self.root / "linked"
        linked.mkdir()
        os.symlink(self.base / ".github", linked / ".github")
        for base in (self.root / "missing", linked):
            with self.subTest(base=base.name):
                result = self.run_command([".github/workflows/ci.yml"], base=base)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertIn("no real .github/workflows directory", result.stderr)

    def test_a_changed_path_list_of_non_strings_is_judged_not_crashed(self) -> None:
        for changed in ([[]], [{"a": 1}], [[".github/workflows/ci.yml"]]):
            with self.subTest(changed=changed):
                result = self.run_command(changed)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertFalse(json.loads(result.stdout)["qualifies"])
                self.assertIn("must hold only path strings", result.stderr)

    def test_a_patch_bump_of_every_tracked_workflow_pin_qualifies(self) -> None:
        tracked = REPO_ROOT / ".github" / "workflows"
        texts = {".github/workflows/" + path.name: path.read_text(encoding="utf-8")
                 for path in sorted(tracked.iterdir()) if path.suffix in (".yml", ".yaml")}
        bumped = 0
        for name, (sha, version) in sorted(exception.action_pins.load_allowlist().items()):
            pin = "{}@{} # {}".format(name, sha, version)
            if not any(name + "@" in text for text in texts.values()):
                continue
            with self.subTest(action=name):
                self.assertTrue(any(pin in text for text in texts.values()), "no `@sha # version` pin form")
                new_version = a_higher_patch(version)
                head = {path: text.replace(pin, "{}@{} # {}".format(name, NEW_A, new_version))
                        for path, text in texts.items()}
                changed = [path for path in texts if head[path] != texts[path]]
                with tempfile.TemporaryDirectory() as directory:
                    base_root, head_root = Path(directory) / "base", Path(directory) / "head"
                    write_tree(base_root, texts)
                    write_tree(head_root, head)
                    evidence = {"schema_version": 1,
                                "actions": {name: {"sha": NEW_A, "tag": {"name": new_version, "commit": NEW_A}}}}
                    report = exception.judge(base_root, head_root, changed, dependabot_pull_request(len(changed)),
                                             evidence, repository_id=REPOSITORY_ID)
                self.assertEqual(report["errors"], [])
                self.assertTrue(report["qualifies"])
                bumped += 1
        self.assertGreater(bumped, 0)

    def test_the_script_embeds_no_commit_id(self) -> None:
        self.assertIsNone(re.search(r"[0-9a-f]{40}", SCRIPT.read_text(encoding="utf-8")))


if __name__ == "__main__":
    unittest.main()
