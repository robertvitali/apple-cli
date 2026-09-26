#!/usr/bin/env python3
"""Read-only complete-site assembly rehearsal (design sections 16 and 18 step 16).

Assembles the WHOLE documentation site that a future Pages deployment would serve — the
current manual at `/`, the prior-series archive index at `/versions/`, one archive per
prior MAJOR.MINOR series at `/versions/MAJOR.MINOR/`, and `/version-manifest.json` — into
an empty directory the caller names, from one exact candidate commit plus the set of
published stable release tags the caller supplies. It then packs that directory into a
deterministic tar artifact, restores the artifact into a second empty directory, and
proves the restored tree carries the same content digest. Pages stays disabled: nothing
here deploys, uploads, tags, or writes outside the directories it was given.

    python3 -I -S -B scripts/ci/site_assembly.py \\
        --candidate-root <clean checkout> --candidate-sha <full 40-hex> \\
        (--candidate-version X.Y.Z | --derive-candidate-version) \\
        [--published-tag vX.Y.Z]... [--published-from-json <releases listing>] \\
        --renderer <mkdocs executable> --scratch <empty dir> [--report <new file>]

`--derive-candidate-version` computes the candidate's pending version the way release
preparation does (`release_prep.compute_version`: the Conventional Commit subjects since the
last reachable release tag, default bump rules) and never prints it; when nothing is
releasable (the candidate IS the last tagged release) the candidate takes that tag's
version and a matching entry in the published set is folded into it. It is a ROUTING
input only: an operator-chosen macOS-major bump cannot change which manual serves `/`
because the candidate is the newest either way. `--published-from-json` reads a saved
GitHub Releases listing (the unauthenticated public listing, which returns no drafts) and
keeps the strict `vMAJOR.MINOR.PATCH` tags of non-draft, non-prerelease entries.

Selection (section 16): every published tag and the candidate are grouped by
MAJOR.MINOR; the highest patch of each series is that series' tip; the numerically
highest tip is `current` and serves `/`; every other tip is an archive. A candidate that
is a maintenance patch on an older series therefore becomes that series' archive while
`/` keeps the highest published release.

Inputs are taken ONLY from git objects (the tracked `docs/manual/**` and `mkdocs.yml` of
each selected commit, extracted with `git archive` into a fresh directory) and rendered
with the renderer the caller supplies — the pinned MkDocs toolchain from
`docs/requirements.txt` in every real run. A selected commit whose tree has no tracked
manual, or any symlink under it, is a refusal; a selected commit's `mkdocs.yml` is checked
against a recorded allowlist (no `hooks`, no plugin but `search`, no `theme.custom_dir`,
`docs_dir` pinned to the tracked manual, pure Markdown extensions only) before the pinned
toolchain reads it, so no historical code path is executed; every selected manual is
rendered twice and the two renders must agree byte for byte; retention-limited Actions
artifacts are never an input. What this cannot prove: the pinned toolchain itself is code
that runs with the caller's privileges — its integrity rests on `docs/requirements.txt`
being installed with hashes required, not on this script.

The published set is a CALLER precondition: the design's "published, non-draft,
non-prerelease Releases" is a Release property that git cannot see (a draft Release's tag
is an ordinary ref), so the caller passes only tags whose Release it has read back as
published; this script verifies each such tag exists, resolves to a commit, and that the
commit's own `AppleVersion.current` equals the tag's version.

Exit status: 0 pass; 1 a checked condition failed (dirty checkout, tag not found, version
constant mismatch, renderer failure, restore mismatch); 2 the request was refused without
rendering anything or writing outside the scratch directory (bad arguments, unsafe paths,
malformed or duplicate tags). The report is value-free: digests, counts and PUBLISHED series
routes only — neither the candidate's unassigned version nor its series appears in it,
in the run log, in the scratch manifest, or in the archive index page; the number exists
only in the argument the caller passes (release preparation's computed next version).
The reported digests therefore cover only public commit content (the rendered manuals of
public commits) plus those version-free files, so they cannot be enumerated back to a
version; renderer diagnostics on failure are over that same public content, with scratch
paths redacted.
"""
from __future__ import annotations

import argparse
import hashlib
import html
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tarfile
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

_SPEC = importlib.util.spec_from_file_location("release_prep", Path(__file__).with_name("release_prep.py"))
_RELEASE_PREP = importlib.util.module_from_spec(_SPEC)
assert _SPEC.loader is not None
_SPEC.loader.exec_module(_RELEASE_PREP)

PolicyError = _RELEASE_PREP.PolicyError
NothingToRelease = _RELEASE_PREP.NothingToRelease
compute_version = _RELEASE_PREP.compute_version
AssertionFailure = _RELEASE_PREP.AssertionFailure
GitError = _RELEASE_PREP.GitError
run_git = _RELEASE_PREP.run_git
full_sha = _RELEASE_PREP.full_sha
parse_version = _RELEASE_PREP.parse_version
format_version = _RELEASE_PREP.format_version
validate_checkout = _RELEASE_PREP.validate_checkout
resolve_outside = _RELEASE_PREP.resolve_outside
prepare_scratch = _RELEASE_PREP.prepare_scratch
write_private = _RELEASE_PREP.write_private
TAG_RE = _RELEASE_PREP.TAG_RE
POLICY_ROOT = _RELEASE_PREP.POLICY_ROOT
CONSTANT_RE = _RELEASE_PREP.CONSTANT_RE
CONSTANT_PATH = _RELEASE_PREP.CONSTANT_PATH

# COUPLING: the MkDocs configuration policy parses `mkdocs.yml` with the workflow scan's YAML
# subset parser. A tightening of that parser aimed at workflow files also changes which
# historical `mkdocs.yml` files this rehearsal admits; `test_repository_mkdocs_config_passes_the_policy`
# covers HEAD's file, and a tag-era file that stops parsing is a refusal (fail-closed), never a pass.
_WP_SPEC = importlib.util.spec_from_file_location("workflow_policy", Path(__file__).with_name("workflow_policy.py"))
_WORKFLOW_POLICY = importlib.util.module_from_spec(_WP_SPEC)
assert _WP_SPEC.loader is not None
_WP_SPEC.loader.exec_module(_WORKFLOW_POLICY)
parse_yaml_subset = _WORKFLOW_POLICY.parse_workflow
YamlParseError = _WORKFLOW_POLICY.ParseError

# MkDocs configuration policy. A historical `mkdocs.yml` is DATA taken from a tag, so every
# key that could make the pinned toolchain load code or read files from outside the manual is
# refused before MkDocs sees the file: `hooks` (repository Python files), `plugins` other than
# the built-in `search`, `theme.custom_dir` (repository templates), `docs_dir` other than the
# tracked manual, `site_dir`, `watch`, `extra_templates`, `INHERIT`, and any unknown top-level
# key. Markdown extensions are limited to a recorded pure set.
ALLOWED_CONFIG_KEYS = {"site_name", "site_description", "site_author", "repo_url", "repo_name", "edit_uri",
                       "copyright", "docs_dir", "theme", "markdown_extensions", "plugins", "extra", "nav",
                       "use_directory_urls", "strict", "extra_css", "extra_javascript", "not_in_nav", "exclude_docs"}
ALLOWED_THEME_KEYS = {"name", "logo", "favicon", "features", "palette", "font", "icon", "language", "locale"}
ALLOWED_THEMES = {"material", "mkdocs", "readthedocs"}
ALLOWED_PLUGINS = {"search"}
ALLOWED_MARKDOWN_EXTENSIONS = {"admonition", "toc", "tables", "attr_list", "md_in_html", "def_list", "footnotes", "abbr",
                               "pymdownx.highlight", "pymdownx.superfences", "pymdownx.inlinehilite", "pymdownx.details",
                               "pymdownx.tabbed"}
# Options an admitted extension may carry; an extension absent here takes none. `pymdownx.snippets`
# is refused outright (its `base_path`/`url_download` options read host files and URLs).
ALLOWED_EXTENSION_OPTIONS = {
    "toc": {"permalink", "permalink_title", "title", "toc_depth", "slugify"},
    "pymdownx.highlight": {"anchor_linenums", "line_spans", "pygments_lang_class", "use_pygments", "linenums", "linenums_style"},
    "pymdownx.tabbed": {"alternate_style", "slugify"},
}
REQUIRED_DOCS_DIR = "docs/manual"

MANIFEST_SCHEMA_VERSION = 1
REPORT_SCHEMA_VERSION = 1
SITE_INPUTS = ("docs/manual", "mkdocs.yml")
MANIFEST_NAME = "version-manifest.json"
# Design section 16 route, amended 2026-09-23 (HUMAN-DECISIONS D29) from `version` to `versions`
# because the generated manual renders the `apple version` command page at `/version/`; the
# collision refusal below is what found it.
DEFAULT_ARCHIVE_ROOT = "versions"
ARCHIVE_ROOT_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
RENDER_TIMEOUT_SECONDS = 600
MAX_INPUT_BYTES = 64 * 1024 * 1024
MAX_OUTPUT_BYTES = 512 * 1024 * 1024
MAX_OUTPUT_FILES = 20000
LISTING_PAGE_LIMIT = 100  # the Releases API page size the hosted job requests; a full page means "maybe more"
Version = Tuple[int, int, int]


class Selected:
    """One rendered manual: the candidate (tag None) or a published tag."""

    def __init__(self, version: Version, commit: str, tag: Optional[str]) -> None:
        self.version = version
        self.commit = commit
        self.tag = tag

    @property
    def series(self) -> str:
        return "{}.{}".format(self.version[0], self.version[1])

    @property
    def label(self) -> str:
        return self.tag if self.tag is not None else "candidate"


def check_archive_root_free(rendered_current: Path, archive_root: str) -> None:
    """The archive root must not collide with a page of the current manual. The generated
    manual has a page per command, so a command named like the archive root (today:
    `apple version` renders to `/version/`) would be overwritten by the archive index or
    shadow it; either is a route the design never classified, so it is refused."""
    if (rendered_current / archive_root).exists():
        raise AssertionFailure(
            "archive root /{}/ collides with a page of the current manual; choose a route no command renders to".format(archive_root))
    if (rendered_current / MANIFEST_NAME).exists():
        raise AssertionFailure("the current manual renders a file at /{}, the manifest path".format(MANIFEST_NAME))


def select(candidate: Selected, published: Sequence[Selected]) -> Tuple[Selected, List[Selected]]:
    tips: Dict[str, Selected] = {}
    for item in [candidate, *published]:
        held = tips.get(item.series)
        if held is None or item.version > held.version:
            tips[item.series] = item
    current = max(tips.values(), key=lambda item: item.version)
    archives = sorted((item for item in tips.values() if item is not current), key=lambda item: item.version)
    return current, archives


def resolve_tag(root: Path, tag: str, git) -> Selected:
    match = TAG_RE.fullmatch(tag)
    if match is None:
        raise PolicyError("--published-tag {!r} is not a strict vMAJOR.MINOR.PATCH tag".format(tag))
    try:
        commit = git(["rev-parse", "--verify", "--end-of-options", "refs/tags/{}^{{commit}}".format(tag)], root).strip()
    except GitError as error:
        raise AssertionFailure("published tag {} is not present in the candidate repository".format(tag)) from error
    return Selected((int(match.group(1)), int(match.group(2)), int(match.group(3))), full_sha(commit, "tag commit"), tag)


def check_tag_version_constant(root: Path, item: Selected, git) -> None:
    """A published tag's commit must declare the same version in `AppleVersion.current`; a
    mistagged commit would otherwise render under the wrong series."""
    try:
        source = git(["show", "{}:{}".format(item.commit, CONSTANT_PATH.as_posix())], root)
    except GitError as error:
        raise AssertionFailure("{}: commit {} carries no {}".format(item.label, item.commit, CONSTANT_PATH)) from error
    matches = CONSTANT_RE.findall(source)
    if len(matches) != 1:
        raise AssertionFailure("{}: expected exactly one version-constant declaration in {}, found {}".format(
            item.label, CONSTANT_PATH, len(matches)))
    if matches[0][1] != format_version(item.version):
        raise AssertionFailure("{}: tag names {} but the commit's version constant is {}".format(
            item.label, format_version(item.version), matches[0][1]))


def renderer_identity(renderer: Path, home: Path) -> Dict[str, str]:
    """Digest of the renderer executable and its self-reported version, path-free. HOME is a
    scratch directory: an interpreter that writes a cache under HOME must land there, never
    beside the caller's working directory."""
    with open(renderer, "rb") as handle:
        digest = hashlib.sha256(handle.read()).hexdigest()
    version = "unknown"
    try:
        completed = subprocess.run([str(renderer), "--version"],
                                   env={"PATH": "/usr/bin:/bin", "LC_ALL": "C.UTF-8", "HOME": str(home), "PYTHONDONTWRITEBYTECODE": "1"},
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60, check=False)
        match = re.search(r"version\s+(\S+)", completed.stdout.decode("utf-8", "replace"))
        if match:
            version = match.group(1)
    except (OSError, subprocess.TimeoutExpired):
        pass
    return {"renderer_sha256": digest, "renderer_version": version}


def check_inputs_tree(root: Path, item: Selected, git) -> None:
    listing = git(["ls-tree", "-r", "-l", "-z", item.commit, "--", *SITE_INPUTS], root)
    entries = [entry for entry in listing.split("\0") if entry]
    manual_files = 0
    total = 0
    total_bytes = 0
    for entry in entries:
        meta, _tab, path = entry.partition("\t")
        fields = meta.split()
        mode = fields[0]
        if len(fields) >= 4 and fields[3].isdigit():
            total_bytes += int(fields[3])
            if total_bytes > MAX_INPUT_BYTES:
                raise AssertionFailure("{}: site inputs exceed the size bound".format(item.label))
        if mode == "120000":
            raise AssertionFailure("{}: {} is a symlink; links are refused as site input".format(item.label, path))
        if mode not in {"100644", "100755"}:
            raise AssertionFailure("{}: {} has an unexpected mode {}".format(item.label, path, mode))
        if ".." in Path(path).parts:
            raise AssertionFailure("{}: {} traverses upward".format(item.label, path))
        if path.startswith("docs/manual/"):
            manual_files += 1
        total += 1
    if manual_files == 0:
        raise AssertionFailure("{}: commit {} carries no tracked docs/manual tree".format(item.label, item.commit))
    if not any(entry.endswith("\tmkdocs.yml") for entry in entries):
        raise AssertionFailure("{}: commit {} carries no tracked mkdocs.yml".format(item.label, item.commit))


def extract_inputs(root: Path, item: Selected, destination: Path, git) -> None:
    check_inputs_tree(root, item, git)
    destination.mkdir(parents=True, mode=0o700)
    command = ["/usr/bin/git", *_RELEASE_PREP.GIT_CONFIG_OVERRIDES, "archive", "--format=tar", item.commit, "--", *SITE_INPUTS]
    try:
        completed = subprocess.run(command, cwd=str(root), env=dict(_RELEASE_PREP.GIT_ENVIRONMENT), stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=_RELEASE_PREP.GIT_TIMEOUT_SECONDS * 4,
                                   check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise GitError("git archive: {}".format(error.__class__.__name__)) from error
    if completed.returncode != 0:
        raise GitError("git archive exited {}".format(completed.returncode))
    if len(completed.stdout) > MAX_INPUT_BYTES:
        raise AssertionFailure("{}: site inputs exceed the size bound".format(item.label))
    with tarfile.open(fileobj=io.BytesIO(completed.stdout), mode="r:") as archive:
        for member in archive.getmembers():
            if not (member.isreg() or member.isdir()):
                raise AssertionFailure("{}: {} is not a regular file or directory".format(item.label, member.name))
            target = (destination / member.name)
            if destination not in target.resolve().parents and target.resolve() != destination:
                raise AssertionFailure("{}: {} escapes the extraction root".format(item.label, member.name))
        archive.extractall(destination, filter="data")


def _names(items: object) -> List[str]:
    """Names of a MkDocs list whose entries are either `name` or `{name: {...}}`."""
    names: List[str] = []
    if not isinstance(items, list):
        raise AssertionFailure("configuration list must be a sequence")
    for item in items:
        if isinstance(item, str):
            names.append(item)
        elif isinstance(item, dict) and len(item) == 1:
            names.append(str(next(iter(item))))
        else:
            raise AssertionFailure("configuration list entry has an unexpected shape")
    return names


def check_config_policy(config_path: Path, label: str) -> None:
    """Refuse any MkDocs configuration that could load code or leave the manual tree."""
    try:
        document = parse_yaml_subset(config_path.read_text(encoding="utf-8"))
    except (YamlParseError, OSError, UnicodeDecodeError) as error:
        raise AssertionFailure("{}: mkdocs.yml is outside the accepted YAML subset: {}".format(label, error)) from error
    if not isinstance(document, dict):
        raise AssertionFailure("{}: mkdocs.yml must be a mapping".format(label))
    unknown = sorted(set(document) - ALLOWED_CONFIG_KEYS)
    if unknown:
        raise AssertionFailure("{}: mkdocs.yml keys are not admitted: {}".format(label, ", ".join(unknown)))
    if document.get("docs_dir") != REQUIRED_DOCS_DIR:
        raise AssertionFailure("{}: mkdocs.yml docs_dir must be exactly {}".format(label, REQUIRED_DOCS_DIR))
    if document.get("use_directory_urls", True) is not True:
        raise AssertionFailure("{}: mkdocs.yml use_directory_urls must be absent or true (the route shape of section 16)".format(label))
    theme = document.get("theme", "mkdocs")  # MkDocs' own default when the key is absent
    if isinstance(theme, str):
        theme = {"name": theme}
    if not isinstance(theme, dict) or theme.get("name") not in ALLOWED_THEMES:
        raise AssertionFailure("{}: mkdocs.yml theme must name one of {}".format(label, sorted(ALLOWED_THEMES)))
    unknown_theme = sorted(set(theme) - ALLOWED_THEME_KEYS)
    if unknown_theme:
        raise AssertionFailure("{}: mkdocs.yml theme keys are not admitted: {}".format(label, ", ".join(unknown_theme)))
    for key, allowed in (("plugins", ALLOWED_PLUGINS), ("markdown_extensions", ALLOWED_MARKDOWN_EXTENSIONS)):
        if key in document:
            names = _names(document[key])
            refused = sorted(set(names) - allowed)
            if refused:
                raise AssertionFailure("{}: mkdocs.yml {} not admitted: {}".format(label, key, ", ".join(refused)))
            for entry in document[key]:
                if isinstance(entry, dict):
                    name = str(next(iter(entry)))
                    options = entry[name] or {}
                    if not isinstance(options, dict):
                        raise AssertionFailure("{}: mkdocs.yml {} options for {} must be a mapping".format(label, key, name))
                    allowed_options = ALLOWED_EXTENSION_OPTIONS.get(name, set()) if key == "markdown_extensions" else set()
                    refused_options = sorted(set(options) - allowed_options)
                    if refused_options:
                        raise AssertionFailure("{}: mkdocs.yml {} option(s) not admitted for {}: {}".format(
                            label, key, name, ", ".join(refused_options)))
                    if name == "toc" and "slugify" in options:
                        raise AssertionFailure("{}: mkdocs.yml toc.slugify names a Python callable and is refused".format(label))
                    if name == "pymdownx.tabbed" and "slugify" in options:
                        raise AssertionFailure("{}: mkdocs.yml pymdownx.tabbed.slugify names a Python callable and is refused".format(label))
    def _relative_asset(text: object, what: str) -> None:
        # MkDocs admits `- path.css` or `- {path: path.js, type: module, async: true, defer: true}`;
        # the mapping form is validated on its `path` VALUE, and no other keys are admitted.
        if isinstance(text, dict):
            if set(text) - {"path", "type", "async", "defer"}:
                raise AssertionFailure("{}: mkdocs.yml {} carries keys outside path/type/async/defer".format(label, what))
            value = text.get("path")
        else:
            value = text
        if not isinstance(value, str) or not value or "://" in value or value.startswith("/") or ".." in Path(value).parts or "\\" in value:
            raise AssertionFailure("{}: mkdocs.yml {} must be a relative path inside the manual".format(label, what))

    for key in ("extra_css", "extra_javascript"):
        for entry in document.get(key) or []:
            _relative_asset(entry, key + " entry")
    # `extra` is theme-interpreted: Material reads `extra.analytics` (third-party script), `extra.consent`,
    # `extra.version` (a JSON fetch) and more. Only the recorded `social` shape is admitted.
    extra = document.get("extra")
    if extra is not None:
        if not isinstance(extra, dict) or set(extra) - {"social"}:
            raise AssertionFailure("{}: mkdocs.yml extra may carry only `social`".format(label))
        for entry in extra.get("social") or []:
            if not isinstance(entry, dict) or set(entry) - {"icon", "link", "name"} or not isinstance(entry.get("link"), str) \
                    or not entry["link"].startswith("https://") or not isinstance(entry.get("icon"), str) or "/" not in entry["icon"]:
                raise AssertionFailure("{}: mkdocs.yml extra.social entries must be {{icon: bundled/name, link: https://…}}".format(label))
    for asset_key in ("logo", "favicon"):
        if asset_key in theme:
            _relative_asset(theme[asset_key], "theme." + asset_key)
    if "icon" in theme:
        icons = theme["icon"]
        if not isinstance(icons, dict) or any(not isinstance(v, str) or "/" not in v or "://" in v or ".." in v for v in icons.values()):
            raise AssertionFailure("{}: mkdocs.yml theme.icon values must be bundled icon names".format(label))


def render(renderer: Path, source: Path, output: Path) -> None:
    output.mkdir(parents=True, mode=0o700)
    command = [str(renderer), "build", "--strict", "-f", str(source / "mkdocs.yml"), "-d", str(output)]
    env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C.UTF-8", "LANG": "C.UTF-8", "HOME": str(source), "PYTHONDONTWRITEBYTECODE": "1",
           "SOURCE_DATE_EPOCH": "0", "TZ": "UTC"}
    try:
        completed = subprocess.run(command, cwd=str(source), env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, timeout=RENDER_TIMEOUT_SECONDS, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise AssertionFailure("renderer could not run: {}".format(error.__class__.__name__)) from error
    if completed.returncode != 0:
        # The tail is a diagnostic over PUBLIC commit content; scratch paths are redacted so a
        # hosted log never shows where the runner keeps its temporary tree.
        scratch_root = str(source.parent.parent)
        tail = [line.replace(scratch_root, "<scratch>") for line in completed.stdout.decode("utf-8", "replace").splitlines()[-20:]]
        raise AssertionFailure("renderer exited {} for {}:\n{}".format(completed.returncode, source.name, "\n".join(tail)))
    if not (output / "index.html").is_file():
        raise AssertionFailure("renderer produced no index.html for {}".format(source.name))
    check_output_bounds(output)


def check_output_bounds(root: Path) -> None:
    """Refuse an oversized render before anything else reads it (a renderer that fills the
    disk fails the run, which is the fail-closed outcome; total disk use is not otherwise
    enforceable from here)."""
    total_bytes = 0
    total_files = 0
    for path in root.rglob("*"):
        if path.is_symlink():
            raise AssertionFailure("rendered output contains a symlink: {}".format(path.relative_to(root)))
        if path.is_file():
            total_files += 1
            total_bytes += path.stat().st_size
            if total_files > MAX_OUTPUT_FILES or total_bytes > MAX_OUTPUT_BYTES:
                raise AssertionFailure("rendered output exceeds the size bound")


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def copy_tree(source: Path, destination: Path, running: Dict[str, int]) -> None:
    """Copy regular files only, refusing links; directories are created 0755, files 0644. The
    bound in `running` is a cap on what is MOUNTED across every selected manual (the render
    step has its own per-render check); it is not a filesystem quota on the renderer."""
    total_bytes = running.get("bytes", 0)
    total_files = running.get("files", 0)
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        if path.is_symlink():
            raise AssertionFailure("rendered output contains a symlink: {}".format(relative))
        target = destination / relative
        if path.is_dir():
            target.mkdir(parents=True, exist_ok=True, mode=0o755)
        elif path.is_file():
            total_files += 1
            total_bytes += path.stat().st_size
            if total_files > MAX_OUTPUT_FILES or total_bytes > MAX_OUTPUT_BYTES:
                raise AssertionFailure("mounted output exceeds the size bound")
            running["bytes"], running["files"] = total_bytes, total_files
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
            with open(path, "rb") as handle:
                data = handle.read()
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
            descriptor = os.open(str(target), flags, 0o644)
            with os.fdopen(descriptor, "wb") as out:
                out.write(data)
        else:
            raise AssertionFailure("rendered output contains a special file: {}".format(relative))


def content_manifest(site: Path, exclude: Sequence[str] = ()) -> Tuple[List[Tuple[str, str]], str]:
    """Rows for every directory (digest `dir`) and every file (sha256), plus the digest of the
    JSON-encoded rows — an encoding that cannot be confused by newlines in names."""
    rows: List[Tuple[str, str]] = []
    for path in sorted(site.rglob("*")):
        if path.is_symlink():
            raise AssertionFailure("site contains a symlink: {}".format(path.relative_to(site)))
        relative = path.relative_to(site).as_posix()
        if relative in exclude:
            continue
        if path.is_dir():
            rows.append((relative, "dir"))
        elif path.is_file():
            rows.append((relative, _sha256_file(path)))
    digest = hashlib.sha256(json.dumps(rows, separators=(",", ":"), ensure_ascii=True).encode("utf-8")).hexdigest()
    return rows, digest


def archive_index_html(current: Selected, archives: Sequence[Selected]) -> str:
    """The archive index names PUBLISHED series only. The candidate — whether it serves `/` or
    is itself an archive — is never named, so no digested byte carries an unassigned version
    (a handful of candidate versions would otherwise be recoverable from the report's digests
    by enumeration, the exposure `release_prep.py` also avoids)."""
    items = "".join(
        '<li><a href="{series}/">{series}</a> — {version}</li>\n'.format(
            series=html.escape(item.series), version=html.escape(format_version(item.version)))
        for item in reversed(archives) if item.tag is not None
    ) or "<li>No prior series archived.</li>\n"
    return (
        "<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
        "<title>apple manual — versions</title></head><body>\n"
        "<h1>apple manual — versions</h1>\n"
        '<p><a href="../">Current manual</a></p>\n'
        "<h2>Prior series</h2>\n<ul>\n{items}</ul>\n</body></html>\n"
    ).format(items=items)


def build_manifest(current: Selected, archives: Sequence[Selected], candidate_sha: str, content_digest: str,
                   archive_root: str) -> Dict[str, object]:
    def describe(item: Selected) -> Dict[str, object]:
        # The candidate's version and series are unassigned until release preparation names
        # them, so the scratch manifest records them as null for the candidate (the publisher's
        # manifest, produced after the version is assigned, fills them in).
        assigned = item.tag is not None
        return {
            "series": item.series if assigned else None,
            "version": format_version(item.version) if assigned else None,
            "tag": item.tag,
            "candidate": not assigned,
            "commit": item.commit,
            "path": "/" if item is current else "/{}/{}/".format(archive_root, item.series if assigned else "candidate"),
        }
    return {
        "schema_version": MANIFEST_SCHEMA_VERSION,
        "candidate_commit": candidate_sha,
        "current": describe(current),
        "archives": [describe(item) for item in archives],
        "archive_index": "/{}/".format(archive_root),
        "content_manifest_sha256": content_digest,
    }


def pack_artifact(site: Path, artifact: Path) -> str:
    """Deterministic tar: sorted members, fixed metadata, no wall-clock, created O_EXCL."""
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    descriptor = os.open(str(artifact), flags, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        with tarfile.open(fileobj=handle, mode="w", format=tarfile.PAX_FORMAT) as archive:
            for path in sorted(site.rglob("*")):
                relative = path.relative_to(site).as_posix()
                info = tarfile.TarInfo(relative)
                info.mtime = 0
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                if path.is_symlink():
                    raise AssertionFailure("site contains a symlink: {}".format(relative))
                if path.is_dir():
                    info.type = tarfile.DIRTYPE
                    info.mode = 0o755
                    archive.addfile(info)
                elif path.is_file():
                    info.type = tarfile.REGTYPE
                    info.mode = 0o644
                    info.size = path.stat().st_size
                    with open(path, "rb") as source:
                        archive.addfile(info, source)
                else:
                    raise AssertionFailure("site contains a non-regular entry: {}".format(relative))
    return _sha256_file(artifact)


def restore_artifact(artifact: Path, destination: Path) -> None:
    destination.mkdir(parents=True, mode=0o700)
    with tarfile.open(artifact, mode="r:") as archive:
        for member in archive.getmembers():
            if not (member.isreg() or member.isdir()):
                raise AssertionFailure("artifact contains a non-regular entry: {}".format(member.name))
        archive.extractall(destination, filter="data")


def published_tags_from_listing(path: Path) -> List[str]:
    """Strict release tags of the non-draft, non-prerelease entries of a saved Releases listing."""
    try:
        listing = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PolicyError("--published-from-json is not a readable JSON document: {}".format(error.__class__.__name__)) from error
    if not isinstance(listing, list):
        raise PolicyError("--published-from-json must hold a JSON list of releases")
    if len(listing) >= LISTING_PAGE_LIMIT:
        raise PolicyError("--published-from-json holds a full page; the listing may be truncated (fetch every page)")
    tags: List[str] = []
    for entry in listing:
        if not isinstance(entry, dict) or not isinstance(entry.get("tag_name"), str):
            raise PolicyError("--published-from-json entries must be release objects with a tag_name")
        if entry.get("draft") is True or entry.get("prerelease") is True:
            continue
        if TAG_RE.fullmatch(entry["tag_name"]) is None:
            raise PolicyError("--published-from-json holds a published release whose tag is not strict vMAJOR.MINOR.PATCH")
        tags.append(entry["tag_name"])
    return tags


def assemble(args: argparse.Namespace) -> Dict[str, object]:
    git = run_git
    candidate_root = args.candidate_root.expanduser().resolve()
    candidate_sha = full_sha(args.candidate_sha, "--candidate-sha")
    if (args.candidate_version is None) == (not args.derive_candidate_version):
        raise PolicyError("exactly one of --candidate-version and --derive-candidate-version is required")
    candidate_version: Optional[Version] = None
    if args.candidate_version is not None:
        candidate_version = parse_version(args.candidate_version, "--candidate-version")
    published_tag_args = list(args.published_tag or [])
    if args.published_from_json is not None:
        published_tag_args.extend(published_tags_from_listing(args.published_from_json.expanduser()))
    if ARCHIVE_ROOT_RE.fullmatch(args.archive_root) is None:
        raise PolicyError("--archive-root must be a short lowercase path segment")
    renderer = args.renderer.expanduser().resolve()
    if not renderer.is_file() or not os.access(str(renderer), os.X_OK):
        raise PolicyError("--renderer must be an executable file")
    scratch = resolve_outside(args.scratch, candidate_root, "--scratch")
    report_path = resolve_outside(args.report, candidate_root, "--report") if args.report is not None else None
    if report_path is not None and (report_path.exists() or report_path.is_symlink()):
        raise PolicyError("--report must not already exist")
    requested_versions: Dict[Version, str] = {}
    for tag in published_tag_args:
        match = TAG_RE.fullmatch(tag)
        if match is None:
            raise PolicyError("--published-tag {!r} is not a strict vMAJOR.MINOR.PATCH tag".format(tag))
        version = (int(match.group(1)), int(match.group(2)), int(match.group(3)))
        if version in requested_versions or version == candidate_version:
            raise PolicyError("a --published-tag repeats a version already in the set, or equals the candidate version")
        requested_versions[version] = tag
    prepare_scratch(scratch)
    validate_checkout(candidate_root, candidate_sha, git)

    folded_tag: Optional[str] = None
    if candidate_version is None:
        try:
            candidate_version = compute_version(candidate_root, git, None, None)[0]
            if candidate_version in requested_versions:
                raise AssertionFailure("a published tag already carries the derived candidate version; refusing to displace it")
        except NothingToRelease:
            # Nothing releasable: the candidate commit IS the last tagged release. It takes that
            # tag's version, and the same tag in the published set is folded into the candidate.
            # NothingToRelease is raised only when a reachable tag exists with no commits after it,
            # so the tag list is non-empty and its newest entry points at HEAD == the candidate.
            tags = _RELEASE_PREP.reachable_release_tags(candidate_root, git)
            candidate_version = tags[0][0]
            folded_tag = requested_versions.pop(candidate_version, None)
            if folded_tag is not None:
                folded = resolve_tag(candidate_root, folded_tag, git)
                if folded.commit != candidate_sha:  # unreachable by construction; kept as a defence
                    raise AssertionFailure("the published tag of the candidate's version does not point at the candidate")
                check_tag_version_constant(candidate_root, folded, git)
    candidate = Selected(candidate_version, candidate_sha, None)

    published: List[Selected] = []
    for version, tag in sorted(requested_versions.items()):
        item = resolve_tag(candidate_root, tag, git)
        check_tag_version_constant(candidate_root, item, git)
        published.append(item)
    for item in published:
        if item.series == candidate.series and item.version > candidate.version:
            raise AssertionFailure("candidate is below a published tip of its own series; nothing would serve it")
    current, archives = select(candidate, published)
    # The candidate's version stays out of the log too: a hosted run's log is public, and the
    # release freeze forbids describing pending work by a number it has not been given.
    print("site-assembly: candidate (version UNASSIGNED) serves {}".format(
        "/" if current is candidate else "/{}/candidate/".format(args.archive_root)), file=sys.stderr)

    archive_root = args.archive_root
    site = scratch / "site"
    site.mkdir(mode=0o755)
    (scratch / "home").mkdir(mode=0o700)
    mounted: Dict[str, int] = {}
    for item in [current, *archives]:
        source = scratch / "src" / item.label
        rendered = scratch / "render" / item.label
        extract_inputs(candidate_root, item, source, git)
        check_config_policy(source / "mkdocs.yml", item.label)
        render(renderer, source, rendered)
        # Determinism is proven, not assumed: a second independent render of the same inputs
        # must reproduce the first byte for byte before it is mounted.
        repeat = scratch / "render-repeat" / item.label
        render(renderer, source, repeat)
        if content_manifest(rendered) != content_manifest(repeat):
            raise AssertionFailure("{}: two renders of the same inputs differ; the toolchain is not deterministic".format(item.label))
        if item is current:
            check_archive_root_free(rendered, archive_root)
        mount_leaf = item.series if item.tag is not None else "candidate"
        mount = site if item is current else site / archive_root / mount_leaf
        if item is not current and mount.exists():
            raise AssertionFailure("archive route collision at /{}/{}/".format(archive_root, mount_leaf))
        copy_tree(rendered, mount, mounted)
    index_dir = site / archive_root
    index_dir.mkdir(parents=True, exist_ok=True, mode=0o755)
    write_private(index_dir / "index.html", archive_index_html(current, archives))
    os.chmod(index_dir / "index.html", 0o644)

    rows, content_digest = content_manifest(site, exclude=(MANIFEST_NAME,))
    manifest = build_manifest(current, archives, candidate_sha, content_digest, archive_root)
    write_private(site / MANIFEST_NAME, json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    os.chmod(site / MANIFEST_NAME, 0o644)

    artifact = scratch / "site.tar"
    artifact_digest = pack_artifact(site, artifact)
    restored = scratch / "restore"
    restore_artifact(artifact, restored)
    restored_rows, restored_digest = content_manifest(restored, exclude=(MANIFEST_NAME,))
    if restored_digest != content_digest or restored_rows != rows:
        raise AssertionFailure("restored artifact does not reproduce the assembled site")
    with open(restored / MANIFEST_NAME, "rb") as handle, open(site / MANIFEST_NAME, "rb") as original:
        if handle.read() != original.read():
            raise AssertionFailure("restored manifest differs from the assembled manifest")

    # The candidate's own archive route (when it is a maintenance patch) would name its
    # unassigned series, so only PUBLISHED archive routes are listed; the count covers the rest.
    routes = ["/", "/{}/".format(archive_root),
              *["/{}/{}/".format(archive_root, item.series) for item in archives if item is not candidate],
              "/{}".format(MANIFEST_NAME)]
    report = {
        "schema_version": REPORT_SCHEMA_VERSION,
        "pass": True,
        "candidate_sha": candidate_sha,
        "published_tag_count": len(published) + (1 if folded_tag is not None else 0),
        "candidate_is_published_release": folded_tag is not None,
        "candidate_serves_root": current is candidate,
        "routes": routes,
        "archive_route_count": len(archives),
        "file_count": sum(1 for _name, sha in rows if sha != "dir"),
        "content_manifest_sha256": content_digest,
        "artifact_sha256": artifact_digest,
        "restore_verified": True,
        **renderer_identity(renderer, scratch / "home"),
        "outward_writes": [],
        "note": "complete-site assembly rehearsal; Pages disabled; nothing deployed or uploaded",
    }
    if report_path is not None:
        write_private(report_path, json.dumps(report, indent=2, sort_keys=True) + "\n")
    return report


def _write_failure(report_path: Optional[Path], candidate_sha: str, failure_class: str) -> None:
    if report_path is not None and not report_path.exists() and not report_path.is_symlink():
        try:
            write_private(report_path, json.dumps(failure_report(candidate_sha, failure_class), indent=2, sort_keys=True) + "\n")
        except OSError:
            pass


def failure_report(candidate_sha: str, failure_class: str) -> Dict[str, object]:
    return {"schema_version": REPORT_SCHEMA_VERSION, "pass": False, "candidate_sha": candidate_sha,
            "failure_class": failure_class, "outward_writes": []}


def parse_args(argv: Optional[Sequence[str]]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Read-only complete-site assembly rehearsal.")
    parser.add_argument("--candidate-root", type=Path, default=POLICY_ROOT)
    parser.add_argument("--candidate-sha", required=True)
    parser.add_argument("--candidate-version", default=None,
                        help="the pending, unassigned version of the candidate: release preparation's computed next version "
                             "(scripts/ci/release_prep.py), never a number written anywhere tracked")
    parser.add_argument("--derive-candidate-version", action="store_true",
                        help="compute the candidate's pending version the way release preparation does; never printed")
    parser.add_argument("--published-tag", action="append", default=[],
                        help="a published, non-draft, non-prerelease release tag (repeatable)")
    parser.add_argument("--published-from-json", type=Path, default=None,
                        help="a saved GitHub Releases listing; its non-draft, non-prerelease strict tags join the published set")
    parser.add_argument("--renderer", type=Path, required=True, help="mkdocs executable from the pinned toolchain")
    parser.add_argument("--scratch", type=Path, required=True, help="empty directory for inputs, renders, site, artifact, restore")
    parser.add_argument("--report", type=Path, default=None)
    parser.add_argument("--archive-root", default=DEFAULT_ARCHIVE_ROOT,
                        help="path segment of the archive index and per-series routes (design section 16 as amended by D29: `versions`)")
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    candidate_sha = args.candidate_sha if _RELEASE_PREP.FULL_SHA_RE.fullmatch(args.candidate_sha or "") else ""
    report_path: Optional[Path] = None
    try:
        if args.report is not None:
            report_path = args.report.expanduser()
        report = assemble(args)
    except PolicyError as error:
        print("site-assembly: refused: {}".format(_WORKFLOW_POLICY._printable(str(error))), file=sys.stderr)
        return 2
    except (AssertionFailure, GitError) as error:
        print("site-assembly: FAIL: {}".format(_WORKFLOW_POLICY._printable(str(error))), file=sys.stderr)
        _write_failure(report_path, candidate_sha, "checked-failure")
        return 1
    except Exception as error:  # noqa: BLE001 — never a traceback with scratch paths; still a failure
        print("site-assembly: FAIL: unclassified {} during assembly".format(error.__class__.__name__), file=sys.stderr)
        _write_failure(report_path, candidate_sha, "unclassified-failure")
        return 1
    print("site-assembly: PASS routes={} files={} content={} artifact={}".format(
        " ".join(report["routes"]), report["file_count"], report["content_manifest_sha256"][:16], report["artifact_sha256"][:16]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
