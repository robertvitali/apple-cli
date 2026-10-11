#!/usr/bin/env python3
"""Read-only exact-SHA release-preparation rehearsal (design section 14.1).

This is the pre-publication half of release preparation. It computes what a
release-preparation PR WOULD change for one explicit full commit ID and proves the
result satisfies the drift gate, but it writes only into a scratch directory the
caller names. It never touches the candidate tree, never creates a ref, never
calls the network, and never records the predicted version in its report.

    python3 -I -S -B scripts/ci/release_prep.py --candidate-root <clone> \
        --candidate-sha <40-hex> --repository owner/name --scratch <empty-dir> \
        [--bump minor|patch] [--macos-major NN] [--declared-version X.Y.Z] \
        [--source-adoption] [--report <path.json>]

Run it against a fresh scratch clone of the candidate, not the working checkout
(design section 14.1: "a fresh temporary tree or isolated scratch clone"); the
read-only guarantee is verified either way, the clone keeps the rehearsal away from
editor state and untracked files that would make a real checkout "dirty".

Exit status: 0 pass; 1 a checked condition on the candidate failed (or git / the
filesystem failed); 2 the request itself was refused before any work (bad argument
shape, scratch or report location, a report path that already exists, conflicting
inputs); 3 NOTHING TO RELEASE — the candidate is sound but there are no commits since
the last reachable release tag, or the `[Unreleased]` section is empty, or the candidate
is itself the release commit for the computed version and only its tag is missing (all
normal around a release; callers may treat 3 as advisory and must treat 1 as a defect). Every file the rehearsal writes is created new (O_EXCL, no symlink follow),
so no pre-existing inode — including a hard link to a tracked file — is ever modified.

What it checks and produces, in order:

1.  The candidate root is a clean checkout whose HEAD equals `--candidate-sha`
    (the same hardened `git` invocation the quality driver uses).
2.  The last release is the HIGHEST (not the nearest) strict `vMAJOR.MINOR.PATCH`
    tag reachable from the candidate (branch-reachable, per design section 14.2);
    at least one commit exists since it (subjects are read as git writes them, one
    per line feed).
3.  The next version: a valid pending unpublished marker, placed immediately under
    the sole `[Unreleased]` heading and matching `AppleVersion.current`, owns the
    next source-only `MAJOR.0.0` candidate. Otherwise `--macos-major NN` forces
    `NN.0.0` and must exceed the current major (the only way MAJOR moves; required
    for a first release, and exclusive with `--bump`); otherwise MINOR when any
    subject since the last tag is `feat` or carries the breaking `!` marker, or any
    body line starts with `BREAKING CHANGE:` / `BREAKING-CHANGE:`, else PATCH;
    `--bump` forces MINOR or PATCH. When `--declared-version` is given (the
    analogue of the freeze-lift variable of design section 15.1) a computed version
    that differs FAILS CLOSED rather than auto-correcting.
4.  The tag for that version must not already exist anywhere in the repository. An
    already-prepared release section with an empty `[Unreleased]` is treated as
    awaiting its tag, not as a new release.
5.  The transformation, rendered into `--scratch` and nowhere else:
    `Sources/AppleKit/CommandSupport.swift` with `AppleVersion.current` rewritten
    (exactly one match), and `CHANGELOG.md` with `[Unreleased]` moved under a new
    `## [X.Y.Z] - YYYY-MM-DD` heading (leaving an empty `[Unreleased]`), every
    `blob/main/docs/manual/` link inside the new section retargeted to the tag (at
    least one must exist there, and none may exist outside it — released sections
    link the manual at their own tag). With `--source-adoption`, the scratch output
    instead contains only the source-only constant and unpublished marker, or no
    files when that state is already present.
6.  The drift gate on normal release rendered copies: constant == changelog heading
    == tag-to-be, and nothing else in the allowlist changed.

The report (`--report`) is value-free by design: the pass result, the exact file
allowlist, the candidate SHA and the digests of the UNTRANSFORMED inputs. It carries
neither the version nor digests of the transformed files (design section 14.1: a
digest over a handful of candidate versions is reversed by enumeration). The
predicted version is printed to stderr, labelled UNASSIGNED, for the run log only.
On a checked failure the report records `pass: false` and a failure class, never a
message. THE SCRATCH DIRECTORY CONTAINS THE PREDICTED VERSION IN PLAINTEXT: it is
working material for a reviewer, never an artifact, never evidence, never uploaded.

Out of scope here, gated elsewhere: the release-notes contract
(`scripts/check-release-notes.py`), manual freshness (`scripts/gen-manual.py
--check`), the artifact build and its outcome gate (`scripts/ci/release_artifact.py`,
which builds and packages the candidate plus these rendered files and verifies the
outcome without printing or recording any digest in its report, its messages or tracked
evidence; this report's `artifact_sha256` slot stays empty pending the operator's ruling
on design section 14.1's deterministic-digest clause, HUMAN-DECISIONS D51), and every
outward write.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence, Tuple

POLICY_ROOT = Path(__file__).resolve().parents[2]
FULL_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
VERSION_RE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
TAG_RE = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
REPOSITORY_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?/[A-Za-z0-9_-][A-Za-z0-9._-]*$")
MACOS_MAJOR_RE = re.compile(r"^[1-9][0-9]*$")
CONSTANT_RE = re.compile(r'(public static let current = ")([^"]+)(")')
UNPUBLISHED_MARKER_LINE_RE = re.compile(r"^<!-- apple-cli-unpublished-version: ([^ ]+) -->$")
FEATURE_SUBJECT_RE = re.compile(r"^feat(\(|!|:)|^[a-z]+(\([^)]*\))?!:")
BREAKING_BODY_RE = re.compile(r"^BREAKING[ -]CHANGE:", re.M)
UNRELEASED_HEADING = "## [Unreleased]"
MANUAL_LINK_SUFFIX = "/blob/main/docs/manual/"
GIT_TIMEOUT_SECONDS = 30
POLICY_FAILURE_STATUS = 2
ASSERTION_FAILURE_STATUS = 1
NOTHING_TO_RELEASE_STATUS = 3
REPORT_SCHEMA_VERSION = 1

CONSTANT_PATH = Path("Sources/AppleKit/CommandSupport.swift")
CHANGELOG_PATH = Path("CHANGELOG.md")
ALLOWLIST: Tuple[Path, ...] = (CONSTANT_PATH, CHANGELOG_PATH)

GIT_CONFIG_OVERRIDES = (
    "--no-pager",
    "-c", "core.fsmonitor=false",
    "-c", "core.hooksPath=/dev/null",
    "-c", "credential.helper=",
    "-c", "credential.interactive=false",
    "-c", "core.askPass=",
    "-c", "core.sshCommand=",
    "-c", "diff.external=",
    "-c", "log.showSignature=false",
)
GIT_ENVIRONMENT = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "LC_ALL": "C",
    "LANG": "C",
    "GIT_OPTIONAL_LOCKS": "0",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_TERMINAL_PROMPT": "0",
}

GitRunner = Callable[[Sequence[str], Path], str]


class PolicyError(Exception):
    """A request that the rehearsal refuses before doing any work."""


class AssertionFailure(Exception):
    """A checked condition on the candidate that did not hold."""


class NothingToRelease(AssertionFailure):
    """The candidate is sound but carries nothing releasable (normal after a release)."""


class GitError(Exception):
    """git itself failed, timed out, or could not be spawned."""


class VersionState:
    def __init__(self, version: Tuple[int, int, int], label: str, last_tag: Optional[str],
                 pending_unpublished: bool = False, computed: bool = True) -> None:
        self.version = version
        self.label = label
        self.last_tag = last_tag
        self.pending_unpublished = pending_unpublished
        self.computed = computed


def run_git(args: Sequence[str], cwd: Path) -> str:
    command = ["/usr/bin/git", *GIT_CONFIG_OVERRIDES, *args]
    try:
        completed = subprocess.run(
            command,
            cwd=str(cwd),
            env=dict(GIT_ENVIRONMENT),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=GIT_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise GitError("git {}: {}".format(" ".join(args), error.__class__.__name__)) from error
    if completed.returncode != 0:
        raise GitError("git {} exited {}".format(" ".join(args), completed.returncode))
    return completed.stdout.decode("utf-8", "replace")


def full_sha(raw: Optional[str], label: str) -> str:
    if raw is None or FULL_SHA_RE.fullmatch(raw) is None:
        raise PolicyError("{} must be a lowercase full 40-hex SHA".format(label))
    return raw


def parse_version(raw: str, label: str) -> Tuple[int, int, int]:
    match = VERSION_RE.fullmatch(raw)
    if match is None:
        raise PolicyError("{} must be strict MAJOR.MINOR.PATCH without leading zeros".format(label))
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def parse_date(raw: str) -> str:
    try:
        parsed = _dt.datetime.strptime(raw, "%Y-%m-%d")
    except ValueError as error:
        raise PolicyError("--date must be a real calendar date, YYYY-MM-DD") from error
    return parsed.strftime("%Y-%m-%d")


def format_version(version: Tuple[int, int, int]) -> str:
    return "{}.{}.{}".format(*version)


def parse_constant_version(source: str) -> str:
    matches = list(CONSTANT_RE.finditer(source))
    if len(matches) != 1:
        raise AssertionFailure(
            "expected exactly one `public static let current = \"...\"` in the version constant file"
        )
    if VERSION_RE.fullmatch(matches[0].group(2)) is None:
        raise AssertionFailure("the current version constant is not strict MAJOR.MINOR.PATCH")
    return matches[0].group(2)


def validate_checkout(root: Path, candidate_sha: str, git: GitRunner) -> None:
    toplevel = git(["rev-parse", "--show-toplevel"], root).strip()
    if Path(toplevel).resolve() != root.resolve():
        raise PolicyError("candidate root must be the checkout root")
    head = git(["rev-parse", "HEAD"], root).strip()
    if head != candidate_sha:
        raise AssertionFailure("candidate HEAD does not equal --candidate-sha")
    if git(["status", "--porcelain", "--untracked-files=all"], root).strip():
        raise AssertionFailure("candidate worktree is not clean")


def commit_subjects(output: str) -> List[str]:
    """The subjects in `git log --format=%s` output, one per commit, newest first.

    CONTROL PLANE — git ends each subject with a line feed and nothing else, and the
    commit-lint job reads them with `read -r`, which splits on line feeds only. Python's
    `splitlines()` also breaks at U+2028, U+2029, U+0085, a vertical tab, a form feed, U+001C-
    U+001E and a lone carriage return, and `strip()` also removes a no-break space: one `fix:`
    subject holding U+2028 read as two subjects here (a MINOR bump where git's single subject
    gave PATCH), and a subject of only a no-break space read as empty. So the output is split
    on line feeds only, and every subject is kept as git wrote it, one per commit, even one that
    is empty or blank. A subject is never refused here: it is published history that no later
    commit can change, so refusing one would block every later rehearsal and release with no
    way out short of a new tag or a history rewrite. `FEATURE_SUBJECT_RE` matches at the start
    of a subject only, so no character inside one can change the bump."""
    subjects = output.split("\n")
    if subjects and subjects[-1] == "":
        subjects.pop()  # the line feed that terminates the last subject
    return subjects


def reachable_release_tags(root: Path, git: GitRunner) -> List[Tuple[Tuple[int, int, int], str]]:
    """Strict `vMAJOR.MINOR.PATCH` tags reachable from HEAD, highest first.

    Names are split on line feeds only and matched exactly: git allows a no-break space or
    U+2028 in a tag name, and `strip()` or `splitlines()` would turn such a name into a strict
    release tag git does not have."""
    listing = git(["tag", "--list", "--merged", "HEAD", "v[0-9]*"], root)
    tags: List[Tuple[Tuple[int, int, int], str]] = []
    for name in listing.split("\n"):
        match = TAG_RE.fullmatch(name)
        if match is None:
            continue
        tags.append(((int(match.group(1)), int(match.group(2)), int(match.group(3))), name))
    tags.sort(reverse=True)
    return tags


def tag_exists(root: Path, tag: str, git: GitRunner) -> bool:
    listing = git(["tag", "--list", tag], root)
    return any(line == tag for line in listing.split("\n"))


def read_candidate_text(root: Path, relative_path: Path) -> str:
    try:
        return (root / relative_path).read_text(encoding="utf-8")
    except FileNotFoundError as error:
        raise AssertionFailure("candidate {} is required for version validation".format(relative_path.as_posix())) from error
    except UnicodeDecodeError as error:
        raise AssertionFailure("candidate {} must be UTF-8 text".format(relative_path.as_posix())) from error


def assert_no_unmarked_ahead_constant(constant_source: str, changelog: str, last_version: Tuple[int, int, int],
                                      expected_version: Tuple[int, int, int]) -> None:
    constant_version = parse_version(parse_constant_version(constant_source), "version constant")
    expected_text = format_version(expected_version)
    if constant_version > last_version and not (
        constant_version == expected_version and awaiting_tag_shape(changelog, expected_text)
    ):
        raise AssertionFailure("the version constant is ahead of the latest release without the unpublished marker")


def released_heading_exists(changelog: str, version: str) -> bool:
    return re.search(r"^## \[{}\] - \d{{4}}-\d{{2}}-\d{{2}}$".format(re.escape(version)),
                     changelog, re.M) is not None


def find_unpublished_marker(changelog: str) -> Optional[str]:
    marker_lines: List[Tuple[int, str]] = []
    for index, line in enumerate(changelog.split("\n")):
        if "apple-cli-unpublished-version" in line:
            marker_lines.append((index, line))
    if not marker_lines:
        return None
    if len(marker_lines) != 1:
        raise AssertionFailure("the unpublished version marker must appear exactly once")
    index, line = marker_lines[0]
    match = UNPUBLISHED_MARKER_LINE_RE.fullmatch(line)
    if match is None:
        raise AssertionFailure("the unpublished version marker must be one strict marker line")
    lines = changelog.split("\n")
    unreleased_indexes = [i for i, item in enumerate(lines) if item == UNRELEASED_HEADING]
    if len(unreleased_indexes) != 1:
        raise AssertionFailure("CHANGELOG must contain exactly one `## [Unreleased]` heading")
    if index != unreleased_indexes[0] + 1:
        raise AssertionFailure("the unpublished version marker must appear immediately after `## [Unreleased]`")
    parse_version(match.group(1), "unpublished version marker")
    return match.group(1)


def remove_unpublished_marker(changelog: str) -> str:
    lines = changelog.split("\n")
    return "\n".join(line for line in lines if "apple-cli-unpublished-version:" not in line)


def awaiting_tag_shape(changelog: str, version: str) -> bool:
    existing = re.search(r"^## \[{}\] - \d{{4}}-\d{{2}}-\d{{2}}$".format(re.escape(version)), changelog, re.M)
    unreleased = re.search(r"^## \[Unreleased\][^\n]*\n(.*?)(?=^## )", changelog, re.S | re.M)
    return (
        existing is not None
        and unreleased is not None
        and not unreleased.group(1).strip()
        and unreleased.end() == existing.start()
    )


def awaiting_tag_state(root: Path, git: GitRunner, constant_source: str, changelog: str,
                       last_release: Optional[Tuple[Tuple[int, int, int], str]], bump: Optional[str],
                       macos_major: Optional[int]) -> Optional[VersionState]:
    if last_release is None:
        return None
    constant = parse_constant_version(constant_source)
    version = parse_version(constant, "version constant")
    if version <= last_release[0]:
        return None
    if tag_exists(root, "v" + constant, git):
        return None
    if not awaiting_tag_shape(changelog, constant):
        return None
    if bump is not None:
        raise AssertionFailure("--bump is incompatible with an awaiting-tag source version")
    if macos_major is not None and version != (macos_major, 0, 0):
        raise AssertionFailure("--macos-major is incompatible with the awaiting-tag source version")
    return VersionState(version, "awaiting tag", last_release[1], False, False)


def insert_unpublished_marker(changelog: str, version: str) -> str:
    if find_unpublished_marker(changelog) is not None:
        return changelog
    lines = changelog.split("\n")
    indexes = [i for i, line in enumerate(lines) if line == UNRELEASED_HEADING]
    if len(indexes) != 1:
        raise AssertionFailure("CHANGELOG must contain exactly one `## [Unreleased]` heading")
    lines.insert(indexes[0] + 1, "<!-- apple-cli-unpublished-version: {} -->".format(version))
    return "\n".join(lines)


def valid_pending_version(
    root: Path,
    git: GitRunner,
    constant_source: str,
    changelog: str,
    last_release: Optional[Tuple[Tuple[int, int, int], str]],
    bump: Optional[str],
    macos_major: Optional[int],
) -> Optional[VersionState]:
    marker = find_unpublished_marker(changelog)
    constant = parse_constant_version(constant_source)
    if marker is None:
        return None
    if constant != marker:
        raise AssertionFailure("the version constant does not match the unpublished version marker")
    version = parse_version(marker, "unpublished version marker")
    if version[1] != 0 or version[2] != 0:
        raise AssertionFailure("the unpublished version marker must name MAJOR.0.0")
    if last_release is None:
        raise AssertionFailure("the unpublished version marker requires an existing release tag")
    if version[0] <= last_release[0][0]:
        raise AssertionFailure("the unpublished version marker must exceed the released macOS major")
    if tag_exists(root, "v" + marker, git):
        raise AssertionFailure("the unpublished version marker names a tag that already exists")
    if released_heading_exists(changelog, marker):
        raise AssertionFailure("the unpublished version marker already has a released heading")
    if bump is not None:
        raise AssertionFailure("--bump is incompatible with a pending unpublished version")
    if macos_major is not None and version != (macos_major, 0, 0):
        raise AssertionFailure("--macos-major is incompatible with the pending unpublished version")
    return VersionState(version, "pending unpublished source", last_release[1] if last_release else None, True)


def compute_bump(subjects: Sequence[str], bodies: Sequence[str]) -> str:
    if any(FEATURE_SUBJECT_RE.search(subject) for subject in subjects):
        return "minor"
    if any(BREAKING_BODY_RE.search(body) for body in bodies):
        return "minor"
    return "patch"


def compute_version(
    root: Path,
    git: GitRunner,
    bump: Optional[str],
    macos_major: Optional[int],
) -> Tuple[Tuple[int, int, int], str, Optional[str]]:
    """Return (version, bump label, last reachable release tag or None)."""
    state = compute_version_state(root, git, bump, macos_major)
    return state.version, state.label, state.last_tag


def compute_version_state(
    root: Path,
    git: GitRunner,
    bump: Optional[str],
    macos_major: Optional[int],
    constant_source: Optional[str] = None,
    changelog_text: Optional[str] = None,
) -> VersionState:
    """Return the shared candidate version state for release prep, artifact and site."""
    tags = reachable_release_tags(root, git)
    last = tags[0] if tags else None
    if constant_source is None:
        constant_source = read_candidate_text(root, CONSTANT_PATH)
    if changelog_text is None:
        changelog_text = read_candidate_text(root, CHANGELOG_PATH)
    pending = valid_pending_version(root, git, constant_source, changelog_text, last, bump, macos_major)
    if pending is not None:
        return pending
    awaiting = awaiting_tag_state(root, git, constant_source, changelog_text, last, bump, macos_major)
    if awaiting is not None:
        return awaiting
    subjects: List[str] = []
    last_tag: Optional[str] = None
    if last is not None:
        last_tag = last[1]
        subjects = commit_subjects(git(["log", "--format=%s", "{}..HEAD".format(last_tag)], root))
        if not subjects:
            raise NothingToRelease("no commits since the last reachable release tag")
    if macos_major is not None:
        if last is not None and macos_major <= last[0][0]:
            raise AssertionFailure(
                "--macos-major must exceed the current major of the last reachable release tag"
            )
        computed_version = (macos_major, 0, 0)
        if tag_exists(root, "v" + format_version(computed_version), git):
            raise AssertionFailure("the requested macOS major already has a release tag")
        if last is not None:
            assert_no_unmarked_ahead_constant(constant_source, changelog_text, last[0], computed_version)
        return VersionState(computed_version, "major (macos-major input)", last_tag)
    if last is None:
        raise AssertionFailure(
            "no reachable release tag: a first release must set --macos-major"
        )
    major, minor, patch = last[0]
    if bump is None:
        bodies = git(["log", "--format=%B%x00", "{}..HEAD".format(last_tag)], root).split("\x00")
        label = compute_bump(subjects, bodies)
    else:
        label = bump
    computed_version = (major, minor + 1, 0) if label == "minor" else (major, minor, patch + 1)
    if tag_exists(root, "v" + format_version(computed_version), git):
        raise AssertionFailure("the computed version already has a release tag")
    assert_no_unmarked_ahead_constant(constant_source, changelog_text, last[0], computed_version)
    return VersionState(computed_version, label, last_tag)


def render_constant(source: str, version: str) -> str:
    matches = list(CONSTANT_RE.finditer(source))
    parse_constant_version(source)
    match = matches[0]
    return source[: match.start(2)] + version + source[match.end(2):]


def render_changelog(text: str, version: str, date: str, repository: str,
                     current_version: Optional[str] = None) -> str:
    if len(re.findall(r"^## \[Unreleased\]", text, re.M)) != 1:
        raise AssertionFailure("CHANGELOG must contain exactly one `## [Unreleased]` heading")
    new_heading = "## [{}] - {}".format(version, date)
    existing = re.search(r"^## \[{}\]".format(re.escape(version)), text, re.M)
    if existing:
        # A release commit pushed ahead of its tag (the urgent-release runbook pushes the commit,
        # verifies it, and only then tags it) declares the computed version in its constant and
        # carries that version's heading directly under an empty [Unreleased]. That is nothing to
        # release, not drift, unless a main-branch manual link survives; with [Unreleased] empty
        # such a link can only sit in a released section, so drift is still checked first, as below.
        unreleased = re.search(r"^## \[Unreleased\][^\n]*\n(.*?)(?=^## )", text, re.S | re.M)
        awaiting_tag = (
            current_version == version
            and unreleased is not None
            and not unreleased.group(1).strip()
            and unreleased.end() == existing.start()
        )
        if awaiting_tag:
            if "https://github.com/{}{}".format(repository, MANUAL_LINK_SUFFIX) in text:
                raise AssertionFailure(
                    "a `{}` manual link survives in a released section; released sections "
                    "must link the manual at their own tag".format(MANUAL_LINK_SUFFIX)
                )
            raise NothingToRelease(
                "the candidate is the release commit for the computed version, awaiting its tag"
            )
        raise AssertionFailure("CHANGELOG already carries a heading for the computed version")
    moved = re.sub(
        r"^## \[Unreleased\][^\n]*$",
        lambda _match: UNRELEASED_HEADING + "\n\n" + new_heading,
        text,
        count=1,
        flags=re.M,
    )
    section_match = re.search(
        r"^## \[{}\][^\n]*\n(.*?)(?=^## |\Z)".format(re.escape(version)),
        moved,
        re.S | re.M,
    )
    if section_match is None:
        raise AssertionFailure("release heading not found after the move")
    placeholder = "https://github.com/{}{}".format(repository, MANUAL_LINK_SUFFIX)
    target = "https://github.com/{}/blob/v{}/docs/manual/".format(repository, version)
    section = section_match.group(0)
    inside = section.count(placeholder)
    # Drift checks come BEFORE the nothing-to-release classification, so a stray
    # main-branch link in a released section is never masked as "nothing to release".
    if moved.count(placeholder) != inside:
        raise AssertionFailure(
            "a `{}` manual link exists outside the new release section; released sections "
            "must link the manual at their own tag".format(MANUAL_LINK_SUFFIX)
        )
    if not section_match.group(1).strip():
        raise NothingToRelease("the moved [Unreleased] section is empty; nothing to release")
    if inside == 0:
        raise AssertionFailure(
            "the new release section carries no `{}` manual link".format(MANUAL_LINK_SUFFIX)
        )
    section = section.replace(placeholder, target)
    rendered = moved[: section_match.start()] + section + moved[section_match.end():]
    if placeholder in rendered or rendered.count(target) != inside:
        raise AssertionFailure("failed to retarget the release manual links to the tag")
    return rendered


def drift_gate(constant_source: str, changelog: str, version: str) -> None:
    match = CONSTANT_RE.search(constant_source)
    if match is None or match.group(2) != version:
        raise AssertionFailure("drift gate: version constant does not equal the computed version")
    heading = r"^## \[{}\] - \d{{4}}-\d{{2}}-\d{{2}}$".format(re.escape(version))
    if re.search(heading, changelog, re.M) is None:
        raise AssertionFailure("drift gate: CHANGELOG heading does not equal the computed version")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def resolve_outside(path: Path, candidate_root: Path, label: str) -> Path:
    """Resolve `path` and refuse it when it is a symlink, the candidate root, or under it."""
    expanded = path.expanduser()
    if expanded.is_symlink():
        raise PolicyError("{} must not be a symlink".format(label))
    resolved = expanded.resolve()
    if resolved == candidate_root or candidate_root in resolved.parents:
        raise PolicyError("{} must lie outside the candidate root".format(label))
    return resolved


def prepare_scratch(scratch: Path) -> None:
    """Require an empty, private directory; create it (0700) only when absent."""
    if scratch.exists():
        if scratch.is_symlink() or not scratch.is_dir():
            raise PolicyError("--scratch must be a real directory")
        if scratch.stat().st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise PolicyError("--scratch must not be group- or world-writable")
        if any(scratch.iterdir()):
            raise PolicyError("--scratch must be empty")
    else:
        scratch.mkdir(parents=True, mode=0o700)


def write_private(destination: Path, data: str) -> None:
    """Create a NEW private file; never follows a symlink, never touches an existing inode
    (a pre-existing target could be a hard link to a file the rehearsal must not modify)."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    descriptor = os.open(str(destination), flags, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
        handle.write(data)


def rehearse(
    candidate_root: Path,
    candidate_sha: str,
    repository: str,
    scratch: Path,
    bump: Optional[str],
    macos_major: Optional[int],
    declared_version: Optional[str],
    date: str,
    source_adoption: bool = False,
    git: GitRunner = run_git,
    log: Optional[Callable[[str], None]] = None,
) -> Dict[str, object]:
    emit = log or (lambda message: print(message, file=sys.stderr))
    validate_checkout(candidate_root, candidate_sha, git)

    constant_bytes = (candidate_root / CONSTANT_PATH).read_bytes()
    changelog_bytes = (candidate_root / CHANGELOG_PATH).read_bytes()
    constant_source = constant_bytes.decode("utf-8")
    changelog_text = changelog_bytes.decode("utf-8")

    if source_adoption:
        if declared_version is None or macos_major is None:
            raise PolicyError("--source-adoption requires --macos-major and --declared-version")
        version_tuple = parse_version(declared_version, "--declared-version")
        if version_tuple != (macos_major, 0, 0):
            raise PolicyError("--source-adoption requires --declared-version to match --macos-major")
        version = format_version(version_tuple)
        if bump is not None:
            raise PolicyError("--source-adoption is incompatible with --bump")
        tags = reachable_release_tags(candidate_root, git)
        last = tags[0] if tags else None
        if last is None:
            raise AssertionFailure("source adoption requires an existing release tag")
        if version_tuple[1:] != (0, 0) or version_tuple[0] <= last[0][0]:
            raise AssertionFailure("--source-adoption must name the next macOS MAJOR.0.0")
        if tag_exists(candidate_root, "v" + version, git):
            raise AssertionFailure("the source-adoption version already has a tag")
        current_version = parse_constant_version(constant_source)
        pending_state = valid_pending_version(candidate_root, git, constant_source, changelog_text, last, None, macos_major)
        marker = format_version(pending_state.version) if pending_state is not None else None
        if marker is None:
            assert_no_unmarked_ahead_constant(constant_source, changelog_text, last[0], version_tuple)
        if marker is not None and marker != version:
            raise AssertionFailure("the unpublished version marker does not match --source-adoption")
        if marker == version and current_version == version:
            prepare_scratch(scratch)
            emit("release-prep: source adoption already adopted; scratch left empty")
            return {
                "schema_version": REPORT_SCHEMA_VERSION,
                "pass": True,
                "candidate_sha": candidate_sha,
                "declared_version_checked": True,
                "source_adoption": True,
                "source_adoption_noop": True,
                "allowlist": [str(path) for path in ALLOWLIST],
                "input_sha256": {
                    str(CONSTANT_PATH): sha256_bytes(constant_bytes),
                    str(CHANGELOG_PATH): sha256_bytes(changelog_bytes),
                },
                "artifact_sha256": {},
                "outward_writes": [],
                "note": "source adoption already present; no transformed files were written",
            }
        if marker is not None and current_version != version:
            raise AssertionFailure("the version constant does not match the unpublished version marker")
        if released_heading_exists(changelog_text, version):
            raise AssertionFailure("the source-adoption version already has a released heading")
        rendered_constant = render_constant(constant_source, version)
        rendered_changelog = insert_unpublished_marker(changelog_text, version)
        prepare_scratch(scratch)
        write_private(scratch / CONSTANT_PATH, rendered_constant)
        write_private(scratch / CHANGELOG_PATH, rendered_changelog)
        if (candidate_root / CONSTANT_PATH).read_bytes() != constant_bytes:
            raise AssertionFailure("the candidate version constant file changed during the rehearsal")
        if (candidate_root / CHANGELOG_PATH).read_bytes() != changelog_bytes:
            raise AssertionFailure("the candidate CHANGELOG changed during the rehearsal")
        if git(["status", "--porcelain", "--untracked-files=all"], candidate_root).strip():
            raise AssertionFailure("candidate worktree is not clean after the rehearsal")
        emit("release-prep: source adoption rendered 2 files into the scratch directory; candidate tree untouched")
        return {
            "schema_version": REPORT_SCHEMA_VERSION,
            "pass": True,
            "candidate_sha": candidate_sha,
            "declared_version_checked": True,
            "source_adoption": True,
            "source_adoption_noop": False,
            "allowlist": [str(path) for path in ALLOWLIST],
            "input_sha256": {
                str(CONSTANT_PATH): sha256_bytes(constant_bytes),
                str(CHANGELOG_PATH): sha256_bytes(changelog_bytes),
            },
            "artifact_sha256": {},
            "outward_writes": [],
            "note": "source-adoption transformed files exist only in the scratch directory; no version is recorded",
        }

    state = compute_version_state(candidate_root, git, bump, macos_major, constant_source, changelog_text)
    version_tuple, bump_label, last_tag = state.version, state.label, state.last_tag
    version = format_version(version_tuple)
    if declared_version is not None and declared_version != version:
        raise AssertionFailure(
            "computed version differs from --declared-version; refusing rather than auto-correcting"
        )
    tag = "v" + version
    if tag_exists(candidate_root, tag, git):
        raise AssertionFailure("the tag for the computed version already exists")

    rendered_constant = render_constant(constant_source, version)
    current_version = CONSTANT_RE.search(constant_source).group(2)  # exactly one, checked above
    release_changelog = remove_unpublished_marker(changelog_text) if state.pending_unpublished else changelog_text
    rendered_changelog = render_changelog(release_changelog, version, date, repository, current_version)
    drift_gate(rendered_constant, rendered_changelog, version)

    prepare_scratch(scratch)
    write_private(scratch / CONSTANT_PATH, rendered_constant)
    write_private(scratch / CHANGELOG_PATH, rendered_changelog)

    # The tree must be exactly as it was: this rehearsal is read-only by contract.
    if (candidate_root / CONSTANT_PATH).read_bytes() != constant_bytes:
        raise AssertionFailure("the candidate version constant file changed during the rehearsal")
    if (candidate_root / CHANGELOG_PATH).read_bytes() != changelog_bytes:
        raise AssertionFailure("the candidate CHANGELOG changed during the rehearsal")
    if git(["status", "--porcelain", "--untracked-files=all"], candidate_root).strip():
        raise AssertionFailure("candidate worktree is not clean after the rehearsal")

    emit("release-prep: predicted next version {} (UNASSIGNED; bump {}; last tag {})".format(
        version, bump_label, last_tag or "none"))
    emit("release-prep: rendered {} files into the scratch directory; candidate tree untouched; "
         "the scratch copies carry the version and are not evidence".format(len(ALLOWLIST)))
    return {
        "schema_version": REPORT_SCHEMA_VERSION,
        "pass": True,
        "candidate_sha": candidate_sha,
        "declared_version_checked": declared_version is not None,
        "allowlist": [str(path) for path in ALLOWLIST],
        "input_sha256": {
            str(CONSTANT_PATH): sha256_bytes(constant_bytes),
            str(CHANGELOG_PATH): sha256_bytes(changelog_bytes),
        },
        "artifact_sha256": {},
        "outward_writes": [],
        "note": (
            "transformed files exist only in the scratch directory; their digests and the "
            "predicted version are deliberately not recorded (design section 14.1)"
        ),
    }


def failure_report(candidate_sha: str, failure_class: str) -> Dict[str, object]:
    return {
        "schema_version": REPORT_SCHEMA_VERSION,
        "pass": False,
        "candidate_sha": candidate_sha,
        "failure_class": failure_class,
        "outward_writes": [],
    }


def parse_args(argv: Optional[Sequence[str]]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Read-only exact-SHA release-preparation rehearsal.")
    parser.add_argument("--candidate-root", type=Path, default=POLICY_ROOT)
    parser.add_argument("--candidate-sha", required=True)
    parser.add_argument("--repository", required=True, help="owner/name used in manual links")
    parser.add_argument("--scratch", type=Path, required=True, help="empty directory for rendered copies")
    parser.add_argument("--bump", choices=("minor", "patch"), default=None,
                        help="force the bump level (default: derived from commit subjects)")
    parser.add_argument("--macos-major", default=None,
                        help="adopt a new macOS major: the ONLY way MAJOR moves; exclusive with --bump")
    parser.add_argument("--declared-version", default=None)
    parser.add_argument("--source-adoption", action="store_true",
                        help="render an unpublished source version marker and constant into scratch only")
    parser.add_argument("--report", type=Path, default=None)
    parser.add_argument("--date", default=None, help=argparse.SUPPRESS)
    return parser.parse_args(argv)


def write_report(report_path: Path, report: Dict[str, object]) -> None:
    write_private(report_path, json.dumps(report, indent=2, sort_keys=True) + "\n")


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    report_path: Optional[Path] = None
    candidate_sha = ""
    try:
        candidate_sha = full_sha(args.candidate_sha, "--candidate-sha")
        if REPOSITORY_RE.fullmatch(args.repository) is None:
            raise PolicyError("--repository must be owner/name")
        if args.macos_major is not None and MACOS_MAJOR_RE.fullmatch(args.macos_major) is None:
            raise PolicyError("--macos-major must be a positive integer without leading zeros")
        if args.macos_major is not None and args.bump is not None:
            raise PolicyError("--macos-major and --bump are exclusive")
        if args.declared_version is not None:
            parse_version(args.declared_version, "--declared-version")
        if args.date is not None:
            date = parse_date(args.date)
        else:
            date = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d")
        candidate_root = args.candidate_root.expanduser().resolve()
        scratch = resolve_outside(args.scratch, candidate_root, "--scratch")
        if args.report is not None:
            report_path = resolve_outside(args.report, candidate_root, "--report")
            if report_path.exists() or report_path.is_symlink():
                raise PolicyError("--report must name a file that does not exist yet")
        prepare_scratch(scratch)
    except PolicyError as error:
        print("release-prep: policy: {}".format(error), file=sys.stderr)
        return POLICY_FAILURE_STATUS
    except OSError as error:
        print("release-prep: policy: {}".format(error.strerror or error.__class__.__name__),
              file=sys.stderr)
        return POLICY_FAILURE_STATUS

    try:
        report = rehearse(
            candidate_root=candidate_root,
            candidate_sha=candidate_sha,
            repository=args.repository,
            scratch=scratch,
            bump=args.bump,
            macos_major=int(args.macos_major) if args.macos_major is not None else None,
            declared_version=args.declared_version,
            date=date,
            source_adoption=args.source_adoption,
        )
    except PolicyError as error:
        print("release-prep: policy: {}".format(error), file=sys.stderr)
        return POLICY_FAILURE_STATUS
    except (AssertionFailure, GitError, OSError, UnicodeDecodeError) as error:
        status = ASSERTION_FAILURE_STATUS
        if isinstance(error, OSError):
            detail = error.strerror or error.__class__.__name__
            failure_class = "io"
        elif isinstance(error, UnicodeDecodeError):
            detail = "an allowlisted file is not UTF-8"
            failure_class = "io"
        elif isinstance(error, NothingToRelease):
            detail = str(error)
            failure_class = "nothing-to-release"
            status = NOTHING_TO_RELEASE_STATUS
        else:
            detail = str(error)
            failure_class = "git" if isinstance(error, GitError) else "assertion"
        label = "NOTHING TO RELEASE" if status == NOTHING_TO_RELEASE_STATUS else "FAIL"
        print("release-prep: {}: {}".format(label, detail), file=sys.stderr)
        if report_path is not None:
            try:
                write_report(report_path, failure_report(candidate_sha, failure_class))
            except OSError:
                # An unwritable report is an I/O defect in its own right: never advisory.
                print("release-prep: FAIL: the failure report could not be written", file=sys.stderr)
                status = ASSERTION_FAILURE_STATUS
        return status

    try:
        if report_path is not None:
            write_report(report_path, report)
    except OSError as error:
        print("release-prep: FAIL: {}".format(error.strerror or error.__class__.__name__),
              file=sys.stderr)
        return ASSERTION_FAILURE_STATUS
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
