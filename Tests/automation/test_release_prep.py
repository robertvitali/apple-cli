"""Tests for scripts/ci/release_prep.py — the read-only exact-SHA release rehearsal."""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "ci" / "release_prep.py"
REPOSITORY = "example-owner/example-cli"
CONSTANT_REL = Path("Sources/AppleKit/CommandSupport.swift")
CHANGELOG_REL = Path("CHANGELOG.md")
# Scratch repositories are built with no global or system git configuration (a developer's hooks
# path, signing or default-branch setting must not shape a fixture) and a synthetic identity.
GIT_TEST_ENVIRONMENT = dict(
    os.environ,
    GIT_CONFIG_GLOBAL="/dev/null",
    GIT_CONFIG_NOSYSTEM="1",
    GIT_AUTHOR_NAME="Automation Example",
    GIT_AUTHOR_EMAIL="automation@example.com",
    GIT_COMMITTER_NAME="Automation Example",
    GIT_COMMITTER_EMAIL="automation@example.com",
)
# Characters git keeps inside one subject (it ends a subject at a line feed only) that Python's
# `splitlines()` treats as a line boundary: the line and paragraph separators, NEL, a vertical
# tab, a form feed, the file, group and record separators, and a lone carriage return.
SUBJECT_LINE_BREAKS = ("\u2028", "\u2029", "\x85", "\x0b", "\x0c", "\x1c", "\x1d", "\x1e", "\r")


def load_module():
    spec = importlib.util.spec_from_file_location("release_prep", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


release_prep = load_module()


def git(args, cwd):
    completed = subprocess.run(
        ["git", *args],
        cwd=str(cwd),
        env=GIT_TEST_ENVIRONMENT,
        check=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return completed.stdout


CONSTANT_SOURCE = (
    "import Foundation\n\n"
    "public enum AppleVersion {\n"
    "    public static let current = \"26.0.0\" // workflow-owned\n"
    "    public static var schema: Int { 1 }\n"
    "}\n"
)

CHANGELOG_SOURCE = (
    "# Changelog\n\n"
    "Intro text.\n\n"
    "## [Unreleased]\n\n"
    "### Added\n\n"
    "- **Something callers can see.** Manual: "
    "https://github.com/{repo}/blob/main/docs/manual/README.md\n\n"
    "## [26.0.0] - 2026-08-30\n\n"
    "### Added\n\n"
    "- First release. Manual: https://github.com/{repo}/blob/v26.0.0/docs/manual/README.md\n"
).format(repo=REPOSITORY)


def seed_repo(path: Path, changelog: str = CHANGELOG_SOURCE, constant: str = CONSTANT_SOURCE) -> str:
    git(["init", "-q"], path)
    git(["config", "user.email", "automation@example.com"], path)
    git(["config", "user.name", "Automation Example"], path)
    git(["config", "commit.gpgsign", "false"], path)
    git(["config", "tag.gpgsign", "false"], path)
    (path / CONSTANT_REL).parent.mkdir(parents=True)
    (path / CONSTANT_REL).write_text(constant, encoding="utf-8")
    (path / CHANGELOG_REL).write_text(changelog, encoding="utf-8")
    git(["add", "-A"], path)
    git(["commit", "-q", "-m", "chore(release): v26.0.0"], path)
    git(["tag", "-a", "v26.0.0", "-m", "v26.0.0"], path)
    return git(["rev-parse", "HEAD"], path).strip()


def commit(path: Path, subject: str, body: str = "", filename: str = "note.txt") -> str:
    target = path / filename
    with open(target, "a", encoding="utf-8") as handle:
        handle.write(subject + "\n")
    git(["add", filename], path)
    message = subject if not body else subject + "\n\n" + body
    git(["commit", "-q", "-m", message], path)
    return git(["rev-parse", "HEAD"], path).strip()


def run_script(*args: str, cwd: Path):
    return subprocess.run(
        [sys.executable, "-I", "-S", "-B", str(SCRIPT), *args],
        cwd=str(cwd),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )


class ReleasePrepTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name) / "candidate"
        self.root.mkdir()
        self.scratch = Path(self._tmp.name) / "scratch"
        self.report = Path(self._tmp.name) / "out" / "report.json"
        self.base = seed_repo(self.root)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def rehearse(self, sha: str, *extra: str):
        return run_script(
            "--candidate-root", str(self.root),
            "--candidate-sha", sha,
            "--repository", REPOSITORY,
            "--scratch", str(self.scratch),
            "--report", str(self.report),
            "--date", "2026-09-23",
            *extra,
            cwd=self.root,
        )

    def tree_digest(self) -> str:
        return git(["rev-parse", "HEAD^{tree}"], self.root).strip() + git(["status", "--porcelain"], self.root)

    # --- version computation -------------------------------------------------

    def test_patch_bump_from_fix_commit(self) -> None:
        sha = commit(self.root, "fix(mail): handle empty mailbox")
        before = self.tree_digest()
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("predicted next version 26.0.1 (UNASSIGNED", result.stderr)
        self.assertEqual(before, self.tree_digest())
        rendered = (self.scratch / CONSTANT_REL).read_text(encoding="utf-8")
        self.assertIn('public static let current = "26.0.1"', rendered)
        changelog = (self.scratch / CHANGELOG_REL).read_text(encoding="utf-8")
        self.assertIn("## [Unreleased]\n\n## [26.0.1] - 2026-09-23\n\n### Added", changelog)
        self.assertIn("blob/v26.0.1/docs/manual/README.md", changelog)
        self.assertEqual(changelog.count("blob/main/docs/manual/"), 0)
        self.assertIn("blob/v26.0.0/docs/manual/", changelog)

    def test_minor_bump_from_feat_subject(self) -> None:
        commit(self.root, "fix(mail): first")
        sha = commit(self.root, "feat(notes): add search")
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("26.1.0 (UNASSIGNED", result.stderr)

    def test_minor_bump_from_breaking_marker_subject(self) -> None:
        sha = commit(self.root, "refactor(api)!: rename field")
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("26.1.0 (UNASSIGNED", result.stderr)

    def test_minor_bump_from_breaking_body(self) -> None:
        sha = commit(self.root, "fix(output): retype id", body="BREAKING CHANGE: id is now a string")
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("26.1.0 (UNASSIGNED", result.stderr)

    def test_breaking_word_inside_body_paragraph_does_not_bump(self) -> None:
        sha = commit(self.root, "docs: explain that nothing here is a BREAKING CHANGE")
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("26.0.1 (UNASSIGNED", result.stderr)

    def test_forced_bump_overrides_auto(self) -> None:
        sha = commit(self.root, "feat(notes): add search")
        result = self.rehearse(sha, "--bump", "patch")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("26.0.1 (UNASSIGNED", result.stderr)

    def test_macos_major_forces_new_major(self) -> None:
        sha = commit(self.root, "fix(mail): small")
        result = self.rehearse(sha, "--macos-major", "27")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("27.0.0 (UNASSIGNED", result.stderr)
        self.assertIn("## [27.0.0] - 2026-09-23", (self.scratch / CHANGELOG_REL).read_text(encoding="utf-8"))

    def test_macos_major_is_exclusive_with_bump(self) -> None:
        sha = commit(self.root, "fix(mail): small")
        result = self.rehearse(sha, "--macos-major", "27", "--bump", "minor")
        self.assertEqual(result.returncode, 2)
        self.assertIn("exclusive", result.stderr)

    def test_macos_major_still_requires_commits_since_last_tag(self) -> None:
        result = self.rehearse(self.base, "--macos-major", "27")
        self.assertEqual(result.returncode, 3)
        self.assertIn("NOTHING TO RELEASE: no commits since", result.stderr)

    def test_macos_major_must_exceed_current(self) -> None:
        sha = commit(self.root, "fix(mail): small")
        result = self.rehearse(sha, "--macos-major", "26")
        self.assertEqual(result.returncode, 1)
        self.assertIn("must exceed the current major", result.stderr)

    def test_macos_major_rejects_leading_zero_and_junk(self) -> None:
        sha = commit(self.root, "fix(mail): small")
        for value in ("027", "27a", "0", "-1"):
            result = self.rehearse(sha, "--macos-major", value)
            self.assertEqual(result.returncode, 2, value)
            self.assertIn("policy", result.stderr)

    def test_first_release_requires_macos_major(self) -> None:
        git(["tag", "-d", "v26.0.0"], self.root)
        sha = commit(self.root, "feat: initial")
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 1)
        self.assertIn("first release must set --macos-major", result.stderr)
        self.report.unlink()  # the first attempt wrote a failure report; a report is never overwritten
        result = self.rehearse(sha, "--macos-major", "26")
        self.assertEqual(result.returncode, 1)
        self.assertIn("already carries a heading", result.stderr)

    def test_no_commits_since_tag_is_nothing_to_release(self) -> None:
        result = self.rehearse(self.base)
        self.assertEqual(result.returncode, 3)
        self.assertIn("NOTHING TO RELEASE: no commits since", result.stderr)
        report = json.loads(self.report.read_text(encoding="utf-8"))
        self.assertEqual((report["pass"], report["failure_class"]), (False, "nothing-to-release"))

    def test_unreachable_tag_is_ignored(self) -> None:
        # A higher tag on an unrelated branch must not become "the last release".
        git(["checkout", "-q", "-b", "side"], self.root)
        commit(self.root, "feat: side feature", filename="side.txt")
        git(["tag", "-a", "v26.5.0", "-m", "side"], self.root)
        git(["checkout", "-q", "-"], self.root)
        sha = commit(self.root, "fix(mail): mainline fix")
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("26.0.1 (UNASSIGNED", result.stderr)

    def test_loose_tag_names_are_ignored(self) -> None:
        git(["tag", "v26.0.0-rc1"], self.root)
        git(["tag", "v26.1"], self.root)
        sha = commit(self.root, "fix(mail): fix")
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("26.0.1 (UNASSIGNED", result.stderr)

    # --- subjects and tag names are read as git writes them ---------------------

    def raw_subjects(self) -> str:
        # Bytes decoded explicitly: the fixture check must see exactly what git printed.
        completed = subprocess.run(
            ["git", "log", "--format=%s", "v26.0.0..HEAD"], cwd=str(self.root), env=GIT_TEST_ENVIRONMENT,
            check=True, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        return completed.stdout.decode("utf-8")

    def test_subject_holding_a_line_break_character_is_read_as_one_subject(self) -> None:
        # R1: git ends a subject at a line feed only, so it (and the commit-lint job's
        # `read -r`) sees ONE `fix:` subject here, a PATCH bump; `splitlines()` read two
        # subjects, the second a `feat:`, and the rehearsal predicted a MINOR bump. The subject
        # is read, never refused: it is history that no later commit can change.
        for index, character in enumerate(SUBJECT_LINE_BREAKS):
            codepoint = "U+{:04X}".format(ord(character))
            with self.subTest(codepoint=codepoint):
                subject = "fix: repair parsing" + character + "feat: add thing"
                sha = commit(self.root, subject)
                try:
                    self.assertEqual(self.raw_subjects(), subject + "\n")  # git's view: one subject
                    scratch = Path(self._tmp.name) / "scratch-{}".format(index)
                    report = Path(self._tmp.name) / "out" / "report-{}.json".format(index)
                    result = run_script(
                        "--candidate-root", str(self.root), "--candidate-sha", sha,
                        "--repository", REPOSITORY, "--scratch", str(scratch), "--report", str(report),
                        "--date", "2026-09-23", cwd=self.root,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("predicted next version 26.0.1 (UNASSIGNED", result.stderr)
                    for fragment in ("repair parsing", "add thing"):  # value-free: never the subject
                        self.assertNotIn(fragment, result.stderr)
                        self.assertNotIn(fragment, report.read_text(encoding="utf-8"))
                finally:
                    git(["reset", "-q", "--hard", self.base], self.root)

    def test_subject_of_only_a_no_break_space_is_a_commit_not_empty(self) -> None:
        # `strip()` removed the no-break space, so this commit read as "no commits since the
        # last release tag" (an advisory exit 3) although git holds a non-empty subject.
        sha = commit(self.root, "\u00a0")
        self.assertEqual(self.raw_subjects(), "\u00a0\n")
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("predicted next version 26.0.1 (UNASSIGNED", result.stderr)
        self.assertNotIn("NOTHING TO RELEASE", result.stderr)

    def test_ordinary_non_ascii_subjects_compute_the_same_bump(self) -> None:
        # Printable non-ASCII text and an ASCII tab read as ordinary subject text.
        commit(self.root, "docs: explain the caf\u00e9 \u2014 r\u00e9sum\u00e9 flow")
        sha = commit(self.root, "fix(mail):\thandle \u201cquoted\u201d names")
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("predicted next version 26.0.1 (UNASSIGNED", result.stderr)

    def side_release_tag(self, name: str) -> None:
        """A real `v26.9.0` on an unreachable branch, and the tag `name` on the candidate's
        history. Only the real tag is a release tag to git, and it is not reachable."""
        git(["checkout", "-q", "-b", "side"], self.root)
        commit(self.root, "feat: side feature", filename="side.txt")
        git(["tag", "-a", "v26.9.0", "-m", "side"], self.root)
        git(["checkout", "-q", "-"], self.root)
        git(["tag", name], self.root)

    def test_tag_name_ending_in_a_no_break_space_is_not_a_release_tag(self) -> None:
        # `strip()` read this tag as `v26.9.0`, a reachable release that git does not have, and
        # the rehearsal then measured from the unreachable real `v26.9.0` and predicted 26.9.1.
        self.side_release_tag("v26.9.0\u00a0")
        sha = commit(self.root, "fix(mail): mainline fix")
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("predicted next version 26.0.1 (UNASSIGNED", result.stderr)

    def test_tag_name_holding_a_line_separator_is_not_a_release_tag(self) -> None:
        # `splitlines()` read this one tag as two names, the second the release tag `v26.9.0`.
        self.side_release_tag("v26\u2028v26.9.0")
        sha = commit(self.root, "fix(mail): mainline fix")
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("predicted next version 26.0.1 (UNASSIGNED", result.stderr)

    def test_declared_version_mismatch_fails_closed(self) -> None:
        sha = commit(self.root, "feat(notes): add search")
        result = self.rehearse(sha, "--declared-version", "26.0.1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("differs from --declared-version", result.stderr)
        self.assertFalse((self.scratch / CHANGELOG_REL).exists())
        self.report.unlink()  # failure report from the refused attempt; never overwritten
        result = self.rehearse(sha, "--declared-version", "26.1.0")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_declared_version_shape_is_policed(self) -> None:
        sha = commit(self.root, "fix: x")
        result = self.rehearse(sha, "--declared-version", "v26.0.1")
        self.assertEqual(result.returncode, 2)

    def test_existing_tag_for_computed_version_is_refused(self) -> None:
        # The computed version's tag exists on an UNREACHABLE commit: it is not the last
        # release, but creating it again would collide, so the rehearsal refuses.
        git(["checkout", "-q", "-b", "side"], self.root)
        commit(self.root, "fix: side fix", filename="side.txt")
        git(["tag", "-a", "v26.0.1", "-m", "side"], self.root)
        git(["checkout", "-q", "-"], self.root)
        sha = commit(self.root, "fix(mail): mainline fix")
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 1)
        self.assertIn("already exists", result.stderr)
        self.assertFalse(self.scratch.exists() and any(self.scratch.iterdir()))

    # --- checkout and identity -----------------------------------------------

    def test_sha_mismatch_is_refused(self) -> None:
        commit(self.root, "fix: x")
        result = self.rehearse(self.base)
        self.assertEqual(result.returncode, 1)
        self.assertIn("HEAD does not equal", result.stderr)

    def test_malformed_sha_is_policy_error(self) -> None:
        result = self.rehearse("abc123")
        self.assertEqual(result.returncode, 2)

    def test_dirty_tree_is_refused(self) -> None:
        sha = commit(self.root, "fix: x")
        (self.root / "stray.txt").write_text("x\n", encoding="utf-8")
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 1)
        self.assertIn("not clean", result.stderr)

    def test_scratch_inside_candidate_is_refused_without_creating_anything(self) -> None:
        sha = commit(self.root, "fix: x")
        before = self.tree_digest()
        for inside in (self.root / "scratch", self.root / "deep" / "nested" / "scratch", self.root):
            result = run_script(
                "--candidate-root", str(self.root), "--candidate-sha", sha,
                "--repository", REPOSITORY, "--scratch", str(inside),
                cwd=self.root,
            )
            self.assertEqual(result.returncode, 2, inside)
            self.assertIn("outside the candidate root", result.stderr)
        self.assertFalse((self.root / "scratch").exists())
        self.assertFalse((self.root / "deep").exists())
        self.assertEqual(before, self.tree_digest())

    def test_scratch_through_symlink_into_candidate_is_refused(self) -> None:
        sha = commit(self.root, "fix: x")
        link = Path(self._tmp.name) / "link-into-repo"
        os.symlink(self.root, link)
        result = run_script(
            "--candidate-root", str(self.root), "--candidate-sha", sha,
            "--repository", REPOSITORY, "--scratch", str(link / "scratch"),
            cwd=self.root,
        )
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.root / "scratch").exists())

    def test_report_inside_candidate_is_refused_and_tree_untouched(self) -> None:
        sha = commit(self.root, "fix: x")
        before = self.tree_digest()
        tracked = self.root / "note.txt"
        original = tracked.read_bytes()
        result = run_script(
            "--candidate-root", str(self.root), "--candidate-sha", sha,
            "--repository", REPOSITORY, "--scratch", str(self.scratch),
            "--report", str(tracked),
            cwd=self.root,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("--report must lie outside", result.stderr)
        self.assertEqual(tracked.read_bytes(), original)
        self.assertFalse(self.scratch.exists())
        self.assertEqual(before, self.tree_digest())

    def test_report_hard_linked_to_tracked_file_is_refused(self) -> None:
        sha = commit(self.root, "fix: x")
        tracked = self.root / "note.txt"
        original = tracked.read_bytes()
        linked = Path(self._tmp.name) / "linked-report.json"
        os.link(tracked, linked)
        result = run_script(
            "--candidate-root", str(self.root), "--candidate-sha", sha,
            "--repository", REPOSITORY, "--scratch", str(self.scratch), "--report", str(linked),
            cwd=self.root,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("does not exist yet", result.stderr)
        self.assertEqual(tracked.read_bytes(), original)
        self.assertFalse(self.scratch.exists())

    def test_existing_report_file_is_refused(self) -> None:
        sha = commit(self.root, "fix: x")
        self.report.parent.mkdir(parents=True)
        self.report.write_text("{}\n", encoding="utf-8")
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 2)
        self.assertIn("does not exist yet", result.stderr)
        self.assertEqual(self.report.read_text(encoding="utf-8"), "{}\n")

    def test_report_symlink_is_refused(self) -> None:
        sha = commit(self.root, "fix: x")
        target = Path(self._tmp.name) / "elsewhere.json"
        target.write_text("keep\n", encoding="utf-8")
        self.report.parent.mkdir(parents=True)
        os.symlink(target, self.report)
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 2)
        self.assertIn("must not be a symlink", result.stderr)
        self.assertEqual(target.read_text(encoding="utf-8"), "keep\n")

    def test_failure_report_is_written_without_values(self) -> None:
        sha = commit(self.root, "feat(notes): add search")
        result = self.rehearse(sha, "--declared-version", "26.0.1")  # a genuine checked failure
        self.assertEqual(result.returncode, 1)
        report = json.loads(self.report.read_text(encoding="utf-8"))
        self.assertEqual(report["pass"], False)
        self.assertEqual(report["failure_class"], "assertion")
        self.assertEqual(report["candidate_sha"], sha)
        self.assertNotIn("declared", json.dumps(report))
        self.assertNotIn("26.1.0", json.dumps(report))

    def test_invalid_date_is_policy_error(self) -> None:
        sha = commit(self.root, "fix: x")
        result = run_script(
            "--candidate-root", str(self.root), "--candidate-sha", sha,
            "--repository", REPOSITORY, "--scratch", str(self.scratch), "--date", "9999-99-99",
            cwd=self.root,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("calendar date", result.stderr)

    def test_non_empty_scratch_is_refused(self) -> None:
        sha = commit(self.root, "fix: x")
        self.scratch.mkdir()
        (self.scratch / "old").write_text("x", encoding="utf-8")
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 2)
        self.assertIn("must be empty", result.stderr)

    def test_repository_shape_is_policed(self) -> None:
        sha = commit(self.root, "fix: x")
        result = self.rehearse(sha, "--repository", "not a repo")
        self.assertEqual(result.returncode, 2)

    # --- transformation guards -----------------------------------------------

    def test_every_manual_link_in_the_section_is_retargeted(self) -> None:
        text = CHANGELOG_SOURCE.replace(
            "### Added\n\n- **Something",
            "### Added\n\n- Extra https://github.com/{}/blob/main/docs/manual/x.md\n- **Something".format(REPOSITORY),
            1,
        )
        (self.root / CHANGELOG_REL).write_text(text, encoding="utf-8")
        git(["commit", "-q", "-am", "docs: two links"], self.root)
        sha = git(["rev-parse", "HEAD"], self.root).strip()
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 0, result.stderr)
        changelog = (self.scratch / CHANGELOG_REL).read_text(encoding="utf-8")
        self.assertEqual(changelog.count("blob/main/docs/manual/"), 0)
        self.assertEqual(changelog.count("blob/v26.0.1/docs/manual/"), 2)

    def test_section_without_manual_link_is_refused(self) -> None:
        text = CHANGELOG_SOURCE.replace(" Manual: https://github.com/{}/blob/main/docs/manual/README.md".format(REPOSITORY), "")
        (self.root / CHANGELOG_REL).write_text(text, encoding="utf-8")
        git(["commit", "-q", "-am", "docs: no link"], self.root)
        sha = git(["rev-parse", "HEAD"], self.root).strip()
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 1)
        self.assertIn("carries no `/blob/main/docs/manual/` manual link", result.stderr)

    def test_main_link_outside_unreleased_is_refused(self) -> None:
        text = CHANGELOG_SOURCE.replace("blob/v26.0.0/docs/manual/", "blob/main/docs/manual/")
        (self.root / CHANGELOG_REL).write_text(text, encoding="utf-8")
        git(["commit", "-q", "-am", "docs: stale link"], self.root)
        sha = git(["rev-parse", "HEAD"], self.root).strip()
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 1)
        self.assertIn("outside the new release section", result.stderr)

    def test_empty_unreleased_is_refused(self) -> None:
        text = CHANGELOG_SOURCE.replace(
            "## [Unreleased]\n\n### Added\n\n- **Something callers can see.** Manual: "
            "https://github.com/{}/blob/main/docs/manual/README.md\n\n".format(REPOSITORY),
            "## [Unreleased]\n\n",
        )
        (self.root / CHANGELOG_REL).write_text(text, encoding="utf-8")
        git(["commit", "-q", "-am", "docs: empty unreleased"], self.root)
        sha = git(["rev-parse", "HEAD"], self.root).strip()
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 3)
        self.assertIn("NOTHING TO RELEASE: the moved [Unreleased] section is empty", result.stderr)

    def release_commit(self, *extra: str) -> str:
        """Commit release preparation's rendered copies, as the urgent-release runbook does."""
        fix = commit(self.root, "fix: correct a thing")
        rendered = self.rehearse(fix, *extra)
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        for rel in (CONSTANT_REL, CHANGELOG_REL):
            (self.root / rel).write_bytes((self.scratch / rel).read_bytes())
        git(["commit", "-q", "-am", "chore(release): v26.0.1"], self.root)
        shutil.rmtree(self.scratch)
        self.report.unlink()
        return git(["rev-parse", "HEAD"], self.root).strip()

    def test_release_commit_awaiting_its_tag_is_nothing_to_release(self) -> None:
        sha = self.release_commit()
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("NOTHING TO RELEASE: the candidate is the release commit for the computed version, awaiting its tag",
                      result.stderr)

    def test_existing_heading_under_a_non_empty_unreleased_is_still_refused(self) -> None:
        self.release_commit()
        text = (self.root / CHANGELOG_REL).read_text(encoding="utf-8").replace(
            "## [Unreleased]\n\n", "## [Unreleased]\n\n### Fixed\n\n- **Another fix.**\n\n", 1)
        (self.root / CHANGELOG_REL).write_text(text, encoding="utf-8")
        git(["commit", "-q", "-am", "docs: note after the release commit"], self.root)
        result = self.rehearse(git(["rev-parse", "HEAD"], self.root).strip())
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("already carries a heading for the computed version", result.stderr)

    def test_release_heading_without_the_matching_constant_is_refused(self) -> None:
        self.release_commit()
        text = (self.root / CONSTANT_REL).read_text(encoding="utf-8").replace('"26.0.1"', '"26.0.0"')
        (self.root / CONSTANT_REL).write_text(text, encoding="utf-8")
        git(["commit", "-q", "-am", "fix: constant rolled back by mistake"], self.root)
        result = self.rehearse(git(["rev-parse", "HEAD"], self.root).strip())
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("already carries a heading for the computed version", result.stderr)

    def test_release_heading_not_directly_under_unreleased_is_refused(self) -> None:
        self.release_commit()
        text = (self.root / CHANGELOG_REL).read_text(encoding="utf-8").replace(
            "## [Unreleased]\n\n", "## [Unreleased]\n\n## [0.0.1] - 2020-01-01\n\n", 1)
        (self.root / CHANGELOG_REL).write_text(text, encoding="utf-8")
        git(["commit", "-q", "-am", "docs: an out-of-place heading"], self.root)
        result = self.rehearse(git(["rev-parse", "HEAD"], self.root).strip())
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("already carries a heading for the computed version", result.stderr)

    def test_release_commit_with_a_stray_main_link_is_drift(self) -> None:
        self.release_commit()
        text = (self.root / CHANGELOG_REL).read_text(encoding="utf-8").replace(
            "blob/v26.0.0/docs/manual/", "blob/main/docs/manual/")
        (self.root / CHANGELOG_REL).write_text(text, encoding="utf-8")
        git(["commit", "-q", "-am", "docs: stale link"], self.root)
        result = self.rehearse(git(["rev-parse", "HEAD"], self.root).strip())
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("manual link survives in a released section", result.stderr)

    def test_stray_link_is_a_failure_even_when_unreleased_is_empty(self) -> None:
        text = CHANGELOG_SOURCE.replace(
            "## [Unreleased]\n\n### Added\n\n- **Something callers can see.** Manual: "
            "https://github.com/{}/blob/main/docs/manual/README.md\n\n".format(REPOSITORY),
            "## [Unreleased]\n\n",
        ).replace("blob/v26.0.0/docs/manual/", "blob/main/docs/manual/")
        (self.root / CHANGELOG_REL).write_text(text, encoding="utf-8")
        git(["commit", "-q", "-am", "docs: empty unreleased plus stale link"], self.root)
        sha = git(["rev-parse", "HEAD"], self.root).strip()
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 1)  # drift, not nothing-to-release
        self.assertIn("outside the new release section", result.stderr)

    def test_unwritable_failure_report_is_never_advisory(self) -> None:
        self.report.parent.mkdir(parents=True)
        self.report.parent.chmod(0o500)
        try:
            result = self.rehearse(self.base)  # nothing to release, but the report cannot be written
        finally:
            self.report.parent.chmod(0o700)
        self.assertEqual(result.returncode, 1)
        self.assertIn("NOTHING TO RELEASE", result.stderr)
        self.assertIn("failure report could not be written", result.stderr)

    def test_missing_or_duplicate_constant_is_refused(self) -> None:
        (self.root / CONSTANT_REL).write_text(CONSTANT_SOURCE + CONSTANT_SOURCE, encoding="utf-8")
        git(["commit", "-q", "-am", "chore: duplicate constant"], self.root)
        sha = git(["rev-parse", "HEAD"], self.root).strip()
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 1)
        self.assertIn("exactly one", result.stderr)

    def test_duplicate_unreleased_heading_is_refused(self) -> None:
        (self.root / CHANGELOG_REL).write_text(CHANGELOG_SOURCE + "\n## [Unreleased]\n", encoding="utf-8")
        git(["commit", "-q", "-am", "docs: duplicate heading"], self.root)
        sha = git(["rev-parse", "HEAD"], self.root).strip()
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 1)
        self.assertIn("exactly one `## [Unreleased]`", result.stderr)

    # --- report contract -----------------------------------------------------

    def test_report_is_value_free_and_scratch_only(self) -> None:
        sha = commit(self.root, "feat(notes): add search")
        result = self.rehearse(sha)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(self.report.read_text(encoding="utf-8"))
        stdout_report = json.loads(result.stdout)
        self.assertEqual(report, stdout_report)
        self.assertTrue(report["pass"])
        self.assertEqual(report["candidate_sha"], sha)
        self.assertEqual(report["allowlist"], [str(CONSTANT_REL), str(CHANGELOG_REL)])
        self.assertEqual(report["outward_writes"], [])
        self.assertEqual(sorted(report["input_sha256"]), [str(CHANGELOG_REL), str(CONSTANT_REL)])
        self.assertEqual(report["schema_version"], 1)
        self.assertEqual(report["artifact_sha256"], {})
        serialized = json.dumps(report)
        for leak in ("26.1.0", "v26.1.0", "minor", "bump"):
            self.assertNotIn(leak, serialized)
        self.assertEqual(sorted(p.relative_to(self.scratch).as_posix() for p in self.scratch.rglob("*") if p.is_file()),
                         sorted([CONSTANT_REL.as_posix(), CHANGELOG_REL.as_posix()]))
        self.assertEqual(git(["status", "--porcelain"], self.root), "")

    def test_drift_gate_unit(self) -> None:
        with self.assertRaises(release_prep.AssertionFailure):
            release_prep.drift_gate('public static let current = "1.2.3"', "## [1.2.4] - 2026-01-01\n", "1.2.3")
        with self.assertRaises(release_prep.AssertionFailure):
            release_prep.drift_gate('public static let current = "1.2.4"', "## [1.2.3] - 2026-01-01\n", "1.2.3")
        release_prep.drift_gate('public static let current = "1.2.3"', "## [1.2.3] - 2026-01-01\n", "1.2.3")

    def test_compute_version_with_fake_git(self) -> None:
        calls = []

        def fake_git(args, cwd):
            calls.append(list(args))
            if args[:2] == ["tag", "--list"] and "--merged" in args:
                return "v26.0.0\nv26.0.0-rc1\nv26.2\nv25.9.9\n"
            if args[:2] == ["log", "--format=%s"]:
                return "fix: a\nrefactor!: b\n"
            if args[:2] == ["log", "--format=%B%x00"]:
                return "fix: a\x00refactor!: b\x00"
            raise AssertionError(args)

        version, label, last = release_prep.compute_version(Path("/nonexistent"), fake_git, None, None)
        self.assertEqual((version, label, last), ((26, 1, 0), "minor", "v26.0.0"))
        version, label, last = release_prep.compute_version(Path("/nonexistent"), fake_git, "patch", None)
        self.assertEqual((version, label, last), ((26, 0, 1), "patch", "v26.0.0"))
        version, label, last = release_prep.compute_version(Path("/nonexistent"), fake_git, None, 27)
        self.assertEqual((version, label, last), ((27, 0, 0), "major (macos-major input)", "v26.0.0"))
        self.assertTrue(all(call[0] in ("tag", "log") for call in calls))

    def test_compute_bump_unit(self) -> None:
        self.assertEqual(release_prep.compute_bump(["fix: a", "docs: b"], ["fix: a\n"]), "patch")
        self.assertEqual(release_prep.compute_bump(["feat: a"], []), "minor")
        self.assertEqual(release_prep.compute_bump(["feat!: a"], []), "minor")
        self.assertEqual(release_prep.compute_bump(["fix(x)!: a"], []), "minor")
        self.assertEqual(release_prep.compute_bump(["fix: a"], ["fix: a\n\nBREAKING-CHANGE: yes\n"]), "minor")
        self.assertEqual(release_prep.compute_bump(["feature: a"], []), "patch")
        self.assertEqual(release_prep.compute_bump(["fix: a"], ["not a BREAKING CHANGE line\n"]), "patch")
        self.assertEqual(release_prep.compute_bump(["fix: a"], ["BREAKING CHANGES ahead\n"]), "patch")

    def test_commit_subjects_splits_on_line_feeds_only(self) -> None:
        for output in ("", "\n", "fix: a\n", "fix: a\nfeat(x)!: b\n", "docs: caf\u00e9 \u2014 note\n", "fix:\ttab\n"):
            with self.subTest(output=output):
                self.assertEqual(release_prep.commit_subjects(output), output.splitlines())
        for character in SUBJECT_LINE_BREAKS + ("\u00a0", "\u3000", "\x1f", "\x00", "\ufeff", "\u202e"):
            codepoint = "U+{:04X}".format(ord(character))
            with self.subTest(codepoint=codepoint):
                subjects = release_prep.commit_subjects("docs: first\nfix: repair" + character + "feat: add\n")
                self.assertEqual(subjects, ["docs: first", "fix: repair" + character + "feat: add"])
                self.assertEqual(release_prep.compute_bump(subjects, []), "patch")

    def test_every_commit_since_the_tag_counts_whatever_its_subject(self) -> None:
        # A subject may be blank to `strip()` (a tab, a no-break space) or empty (git's
        # `--allow-empty-message`); it is still a commit since the tag. Only no commit at all
        # is nothing to release.
        def fake_git(log_output):
            def run(args, cwd):
                if args[:2] == ["tag", "--list"]:
                    return "v26.0.0\n"
                if args[:2] == ["log", "--format=%s"]:
                    return log_output
                if args[:2] == ["log", "--format=%B%x00"]:
                    return log_output.replace("\n", "\x00")
                raise AssertionError(args)
            return run

        for log_output in ("\t\n", "\u00a0\n", "\n", " \n\n"):
            with self.subTest(log_output=ascii(log_output)):
                version, label, last = release_prep.compute_version(Path("/nonexistent"), fake_git(log_output), None, None)
                self.assertEqual((version, label, last), ((26, 0, 1), "patch", "v26.0.0"))
        with self.assertRaises(release_prep.NothingToRelease):
            release_prep.compute_version(Path("/nonexistent"), fake_git(""), None, None)

    def test_release_tags_are_matched_exactly(self) -> None:
        def fake_git(listing):
            return lambda args, cwd: listing

        listing = "v26.0.0\nv26.9.0\u00a0\nv26\u2028v26.8.0\nv26.7.0\u2029\n"
        self.assertEqual(release_prep.reachable_release_tags(Path("/nonexistent"), fake_git(listing)),
                         [((26, 0, 0), "v26.0.0")])
        for listing, present in (
            ("v26.0.1\n", True), ("", False), ("v26.0.1\u00a0\n", False), ("x\u2028v26.0.1\n", False),
        ):
            with self.subTest(listing=listing):
                self.assertEqual(release_prep.tag_exists(Path("/nonexistent"), "v26.0.1", fake_git(listing)), present)

    def test_subjects_are_never_refused(self) -> None:
        # Refusing a subject would block every later rehearsal and release for good, since
        # history cannot be corrected by a follow-up commit: whatever a subject holds, the
        # version is computed, in every mode.
        refused_classes = SUBJECT_LINE_BREAKS + (
            "\u00a0", "\u3000", "\u200b", "\x00", "\x1f", "\x7f", "\x85", "\ufeff",
            "\u202e", "\u2066", "\ufffe", "\uffff", "\ud800",
        )

        def fake_git(log_output):
            def run(args, cwd):
                if args[:2] == ["tag", "--list"]:
                    return "v26.0.0\n"
                if args[:2] == ["log", "--format=%s"]:
                    return log_output
                if args[:2] == ["log", "--format=%B%x00"]:
                    return log_output.replace("\n", "\x00")
                raise AssertionError(args)
            return run

        for character in refused_classes:
            subjects = "docs: first\nfix: repair" + character + "feat: add\n"
            with self.subTest(code_point="U+{:04X}".format(ord(character))):
                for bump, major, expected in ((None, None, (26, 0, 1)), ("minor", None, (26, 1, 0)),
                                              (None, 27, (27, 0, 0))):
                    version, _label, _last = release_prep.compute_version(
                        Path("/nonexistent"), fake_git(subjects), bump, major)
                    self.assertEqual(version, expected)


if __name__ == "__main__":
    unittest.main()
