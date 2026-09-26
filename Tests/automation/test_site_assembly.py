"""Tests for scripts/ci/site_assembly.py — the read-only complete-site assembly rehearsal.

Every case builds a synthetic git repository with tagged manuals and renders it with a
FAKE renderer (a tiny script that turns each Markdown page into an HTML page), so the
suite is hermetic. Set APPLE_CLI_SITE_RENDERER to a real `mkdocs` executable from the
pinned toolchain to also run the opt-in real-render case.
"""
from __future__ import annotations

import http.server
import importlib.util
import json
import os
import re
import shutil
import socketserver
import stat
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import threading
import unittest
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "ci" / "site_assembly.py"
GIT = "/usr/bin/git"
GIT_ENV = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
           "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "automation@example.com",
           "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "automation@example.com",
           "GIT_AUTHOR_DATE": "2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2026-01-01T00:00:00Z"}

FAKE_RENDERER = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import os, re, shutil, sys
    args = sys.argv[1:]
    assert args[:2] == ["build", "--strict"], args
    config = args[args.index("-f") + 1]
    out = args[args.index("-d") + 1]
    docs_dir = "docs/manual"
    for line in open(config, encoding="utf-8"):
        if line.startswith("docs_dir:"):
            docs_dir = line.split(":", 1)[1].strip()
    source = os.path.join(os.path.dirname(os.path.abspath(config)), docs_dir)
    for root, _dirs, files in os.walk(source):
        for name in sorted(files):
            src = os.path.join(root, name)
            rel = os.path.relpath(src, source)
            if name.endswith(".md"):
                page = "index.html" if rel == "index.md" else os.path.join(rel[:-3], "index.html")
                body = open(src, encoding="utf-8").read()
                target = os.path.join(out, page)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                open(target, "w", encoding="utf-8").write("<html><body><pre>" + body + "</pre></body></html>")
            else:
                target = os.path.join(out, rel)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                shutil.copyfile(src, target)
    """
)


def load_module():
    spec = importlib.util.spec_from_file_location("site_assembly", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


assembly = load_module()


def git(args, cwd):
    return subprocess.run([GIT, *args], cwd=str(cwd), env=GIT_ENV, check=True, stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True).stdout


class Fixture:
    """A synthetic repository: `commit_manual(version_text, pages)` adds a commit; `tag(name)` tags HEAD."""

    def __init__(self, root: Path) -> None:
        self.root = root
        root.mkdir(parents=True)
        git(["init", "-q", "-b", "main"], root)
        (root / "mkdocs.yml").write_text("site_name: test\ndocs_dir: docs/manual\n", encoding="utf-8")

    def commit_manual(self, marker: str, pages=("index.md", "mail/index.md"), constant=None) -> str:
        manual = self.root / "docs" / "manual"
        if manual.exists():
            shutil.rmtree(manual)
        if constant is None:
            constant = marker if re.fullmatch(r"\d+\.\d+\.\d+", marker) else "0.0.0"
        swift = self.root / "Sources" / "AppleKit" / "CommandSupport.swift"
        swift.parent.mkdir(parents=True, exist_ok=True)
        swift.write_text('public enum AppleVersion {{\n    public static let current = "{}"\n}}\n'.format(constant), encoding="utf-8")
        for page in pages:
            target = manual / page
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("# {} — {}\n".format(page, marker), encoding="utf-8")
        (manual / "assets").mkdir(exist_ok=True)
        (manual / "assets" / "logo.svg").write_text("<svg/>", encoding="utf-8")
        git(["add", "-A"], self.root)
        git(["commit", "-q", "-m", "docs: manual {}".format(marker)], self.root)
        return git(["rev-parse", "HEAD"], self.root).strip()

    def commit_without_manual(self) -> str:
        swift = self.root / "Sources" / "AppleKit" / "CommandSupport.swift"
        swift.parent.mkdir(parents=True, exist_ok=True)
        swift.write_text('public enum AppleVersion {\n    public static let current = "26.0.0"\n}\n', encoding="utf-8")
        (self.root / "README.md").write_text("no manual yet\n", encoding="utf-8")
        git(["add", "-A"], self.root)
        git(["commit", "-q", "-m", "chore: no manual"], self.root)
        return git(["rev-parse", "HEAD"], self.root).strip()

    def tag(self, name: str) -> None:
        git(["tag", name], self.root)

    def head(self) -> str:
        return git(["rev-parse", "HEAD"], self.root).strip()


class SiteAssemblyTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name).resolve()
        self.renderer = self.tmp / "fake-mkdocs"
        self.renderer.write_text(FAKE_RENDERER, encoding="utf-8")
        self.renderer.chmod(0o700)
        self.repo = Fixture(self.tmp / "repo")
        self.counter = 0

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_assembly(self, *extra, sha=None, version="27.0.0", archive_root="versions", report=True, env=None):
        self.counter += 1
        scratch = self.tmp / "scratch-{}".format(self.counter)
        report_path = self.tmp / "report-{}.json".format(self.counter)
        argv = [sys.executable, "-I", "-S", "-B", str(SCRIPT),
                "--candidate-root", str(self.repo.root), "--candidate-sha", sha or self.repo.head(),
                *(["--candidate-version", version] if version is not None else []),
                "--renderer", str(self.renderer), "--scratch", str(scratch),
                "--archive-root", archive_root, *extra]
        if report:
            argv += ["--report", str(report_path)]
        run_env = {"PATH": "/usr/bin:/bin", **(env or {})}
        completed = subprocess.run(argv, env=run_env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, check=False)
        return completed, scratch, report_path

    # ----- happy paths -------------------------------------------------------------

    def test_candidate_only_site(self) -> None:
        self.repo.commit_manual("current")
        completed, scratch, report_path = self.run_assembly()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertTrue(report["pass"])
        self.assertEqual(report["routes"], ["/", "/versions/", "/version-manifest.json"])
        self.assertEqual(report["published_tag_count"], 0)
        self.assertEqual(len(report["renderer_sha256"]), 64)
        self.assertNotIn(str(self.tmp), json.dumps(report))
        self.assertTrue(report["candidate_serves_root"])
        self.assertEqual(report["outward_writes"], [])
        self.assertNotIn("27.0.0", json.dumps(report), "the unassigned candidate version must not appear in the report")
        self.assertIn("UNASSIGNED", completed.stderr)
        self.assertNotIn("27.0", completed.stderr, "the run log must not name the unassigned version either")
        site = scratch / "site"
        self.assertTrue((site / "index.html").is_file())
        self.assertTrue((site / "versions" / "index.html").is_file())
        manifest = json.loads((site / "version-manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["current"]["path"], "/")
        self.assertTrue(manifest["current"]["candidate"])
        self.assertIsNone(manifest["current"]["tag"])
        self.assertIsNone(manifest["current"]["version"])
        self.assertIsNone(manifest["current"]["series"])
        for digested in sorted(site.rglob("*")):
            if digested.is_file():
                self.assertNotIn(b"27.0", digested.read_bytes(), "no digested byte may carry the unassigned candidate version: {}".format(digested))
        self.assertEqual(manifest["archives"], [])
        self.assertEqual(manifest["content_manifest_sha256"], report["content_manifest_sha256"])
        self.assertEqual(oct(stat.S_IMODE((site / "index.html").stat().st_mode)), "0o644")

    def test_archives_select_series_tips_and_current(self) -> None:
        self.repo.commit_manual("26.0.0"); self.repo.tag("v26.0.0")
        self.repo.commit_manual("26.0.1"); self.repo.tag("v26.0.1")
        self.repo.commit_manual("26.1.0"); self.repo.tag("v26.1.0")
        self.repo.commit_manual("27.0.0-candidate")
        completed, scratch, report_path = self.run_assembly(
            "--published-tag", "v26.0.0", "--published-tag", "v26.0.1", "--published-tag", "v26.1.0")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertEqual(report["routes"], ["/", "/versions/", "/versions/26.0/", "/versions/26.1/", "/version-manifest.json"])
        site = scratch / "site"
        self.assertIn("27.0.0-candidate", (site / "index.html").read_text(encoding="utf-8"))
        self.assertIn("26.0.1", (site / "versions" / "26.0" / "index.html").read_text(encoding="utf-8"))
        self.assertNotIn("26.0.0 ", (site / "versions" / "26.0" / "index.html").read_text(encoding="utf-8"))
        self.assertIn("26.1.0", (site / "versions" / "26.1" / "index.html").read_text(encoding="utf-8"))
        manifest = json.loads((site / "version-manifest.json").read_text(encoding="utf-8"))
        self.assertEqual([a["series"] for a in manifest["archives"]], ["26.0", "26.1"])
        self.assertEqual(manifest["archives"][0]["tag"], "v26.0.1")
        index = (site / "versions" / "index.html").read_text(encoding="utf-8")
        self.assertIn('href="26.1/"', index)
        self.assertIn('href="26.0/"', index)

    def test_maintenance_patch_candidate_becomes_archive_not_root(self) -> None:
        self.repo.commit_manual("26.0.0"); self.repo.tag("v26.0.0")
        self.repo.commit_manual("27.0.0"); self.repo.tag("v27.0.0")
        self.repo.commit_manual("26.0.1-candidate")
        completed, scratch, report_path = self.run_assembly(
            "--published-tag", "v26.0.0", "--published-tag", "v27.0.0", version="26.0.1")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertFalse(report["candidate_serves_root"])
        self.assertEqual(report["routes"], ["/", "/versions/", "/version-manifest.json"], "the candidate's own archive route must not be listed")
        self.assertEqual(report["archive_route_count"], 1)
        self.assertNotIn("26.0", json.dumps(report))
        site = scratch / "site"
        self.assertIn("27.0.0", (site / "index.html").read_text(encoding="utf-8"))
        self.assertIn("26.0.1-candidate", (site / "versions" / "candidate" / "index.html").read_text(encoding="utf-8"))
        self.assertFalse((site / "versions" / "26.0").exists(), "a candidate archive is mounted under a series-free path")
        index = (site / "versions" / "index.html").read_text(encoding="utf-8")
        self.assertNotIn("26.0", index)

    def test_deterministic_digests_and_artifact_restore(self) -> None:
        self.repo.commit_manual("26.0.0"); self.repo.tag("v26.0.0")
        self.repo.commit_manual("current")
        first, scratch1, report1 = self.run_assembly("--published-tag", "v26.0.0")
        second, scratch2, report2 = self.run_assembly("--published-tag", "v26.0.0")
        self.assertEqual((first.returncode, second.returncode), (0, 0), first.stderr + second.stderr)
        a = json.loads(report1.read_text(encoding="utf-8")); b = json.loads(report2.read_text(encoding="utf-8"))
        self.assertEqual(a["content_manifest_sha256"], b["content_manifest_sha256"])
        self.assertEqual(a["artifact_sha256"], b["artifact_sha256"])
        self.assertTrue(a["restore_verified"])
        with tarfile.open(scratch1 / "site.tar") as archive:
            members = archive.getmembers()
            self.assertTrue(all(m.mtime == 0 and m.uid == 0 and m.gid == 0 for m in members))
            self.assertTrue(all(m.isreg() or m.isdir() for m in members))
            names = [m.name for m in members]
            self.assertEqual(names, sorted(names))
        restored = scratch1 / "restore"
        self.assertTrue((restored / "versions" / "26.0" / "index.html").is_file())
        rows, digest = assembly.content_manifest(restored, exclude=("version-manifest.json",))
        self.assertEqual(digest, a["content_manifest_sha256"])
        self.assertIn(("versions", "dir"), rows)

    def test_routes_serve_on_loopback(self) -> None:
        self.repo.commit_manual("26.0.0"); self.repo.tag("v26.0.0")
        self.repo.commit_manual("current")
        completed, scratch, report_path = self.run_assembly("--published-tag", "v26.0.0")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        site = scratch / "site"
        self.assertTrue(report_path.exists())
        class QuietHandler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *_args) -> None:
                pass
        handler = lambda *args, **kwargs: QuietHandler(*args, directory=str(site), **kwargs)
        class ReusableServer(socketserver.TCPServer):
            allow_reuse_address = True
        with ReusableServer(("127.0.0.1", 0), handler) as server:
            server.timeout = 5
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                base = "http://127.0.0.1:{}".format(server.server_address[1])
                report_routes = json.loads(report_path.read_text(encoding="utf-8"))["routes"]
                self.assertEqual(report_routes, ["/", "/versions/", "/versions/26.0/", "/version-manifest.json"])
                for route, needle in (("/", "current"), ("/versions/", "Prior series"),
                                      ("/versions/26.0/", "26.0.0"), ("/version-manifest.json", '"schema_version"')):
                    with urllib.request.urlopen(base + route, timeout=5) as response:
                        self.assertEqual(response.status, 200, route)
                        self.assertIn(needle, response.read().decode("utf-8"), route)
            finally:
                server.shutdown()

    # ----- refusals and failures -----------------------------------------------------

    def test_design_route_collides_with_a_manual_page(self) -> None:
        self.repo.commit_manual("current", pages=("index.md", "version/index.md"))
        completed, _scratch, report_path = self.run_assembly(archive_root="version")
        self.assertEqual(completed.returncode, 1)
        self.assertIn("collides with a page of the current manual", completed.stderr)
        self.assertFalse(json.loads(report_path.read_text(encoding="utf-8"))["pass"])

    def test_selected_tag_without_a_manual_is_refused(self) -> None:
        self.repo.commit_without_manual(); self.repo.tag("v26.0.0")
        self.repo.commit_manual("current")
        completed, _s, _r = self.run_assembly("--published-tag", "v26.0.0")
        self.assertEqual(completed.returncode, 1)
        self.assertIn("carries no tracked docs/manual tree", completed.stderr)

    def test_symlink_in_site_inputs_is_refused(self) -> None:
        self.repo.commit_manual("26.0.0")
        os.symlink("index.md", self.repo.root / "docs" / "manual" / "alias.md")
        git(["add", "-A"], self.repo.root); git(["commit", "-q", "-m", "docs: alias"], self.repo.root)
        self.repo.tag("v26.0.0")
        self.repo.commit_manual("current")
        completed, _s, _r = self.run_assembly("--published-tag", "v26.0.0")
        self.assertEqual(completed.returncode, 1)
        self.assertIn("is a symlink", completed.stderr)

    def test_bad_tags_and_duplicates_are_refused(self) -> None:
        self.repo.commit_manual("26.0.0"); self.repo.tag("v26.0.0")
        self.repo.commit_manual("current")
        for tags, code, needle in (
            (["--published-tag", "v26.0.0-rc1"], 2, "not a strict"),
            (["--published-tag", "26.0.0"], 2, "not a strict"),
            (["--published-tag", "v26.0.0", "--published-tag", "v26.0.0"], 2, "repeats a version already in the set"),
            (["--published-tag", "v25.0.0"], 1, "not present"),
        ):
            with self.subTest(tags=tags):
                completed, scratch, _r = self.run_assembly(*tags)
                self.assertEqual(completed.returncode, code, completed.stderr)
                self.assertIn(needle, completed.stderr)
                if code == 2:
                    self.assertFalse(scratch.exists(), "a refusal must not create the scratch directory")

    def test_published_tag_equal_to_candidate_version_is_refused(self) -> None:
        self.repo.commit_manual("current"); self.repo.tag("v27.0.0")
        completed, _s, _r = self.run_assembly("--published-tag", "v27.0.0")
        self.assertEqual(completed.returncode, 2, completed.stderr)
        self.assertIn("equals the candidate version", completed.stderr)
        self.assertNotIn("27.0", completed.stderr, "a refusal must not echo a tag equal to the unassigned version")

    def test_dirty_or_wrong_checkout_fails(self) -> None:
        self.repo.commit_manual("current")
        head = self.repo.head()
        (self.repo.root / "stray.txt").write_text("x", encoding="utf-8")
        completed, _s, _r = self.run_assembly()
        self.assertEqual(completed.returncode, 1)
        self.assertIn("not clean", completed.stderr)
        (self.repo.root / "stray.txt").unlink()
        completed, _s, _r = self.run_assembly(sha="0" * 40)
        self.assertEqual(completed.returncode, 1)
        self.assertIn("does not equal", completed.stderr)
        self.assertEqual(head, self.repo.head())

    def test_unsafe_paths_and_bad_arguments_are_refused(self) -> None:
        self.repo.commit_manual("current")
        for extra, needle in (
            (["--scratch", str(self.repo.root / "inside")], "outside the candidate root"),
            (["--archive-root", "Bad/Root"], "short lowercase path segment"),
            (["--candidate-version", "27.0"], "strict MAJOR.MINOR.PATCH"),
            (["--renderer", str(self.tmp / "missing")], "executable file"),
        ):
            with self.subTest(extra=extra):
                argv = [sys.executable, "-I", "-S", "-B", str(SCRIPT), "--candidate-root", str(self.repo.root),
                        "--candidate-sha", self.repo.head(), "--candidate-version", "27.0.0",
                        "--renderer", str(self.renderer), "--scratch", str(self.tmp / "s-{}".format(needle[:4])), *extra]
                completed = subprocess.run(argv, env={"PATH": "/usr/bin:/bin"}, stdin=subprocess.DEVNULL,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
                self.assertEqual(completed.returncode, 2, completed.stderr)
                self.assertIn(needle, completed.stderr)
        existing = self.tmp / "existing-report.json"
        existing.write_text("{}", encoding="utf-8")
        completed, _s, _r = self.run_assembly("--report", str(existing), report=False)
        self.assertEqual(completed.returncode, 2)
        self.assertIn("must not already exist", completed.stderr)
        self.assertEqual(existing.read_text(encoding="utf-8"), "{}")

    def test_renderer_failure_is_a_checked_failure(self) -> None:
        self.repo.commit_manual("current")
        broken = self.tmp / "broken-mkdocs"
        broken.write_text("#!/bin/sh\nexit 7\n", encoding="utf-8"); broken.chmod(0o700)
        self.renderer = broken
        completed, _s, report_path = self.run_assembly()
        self.assertEqual(completed.returncode, 1, completed.stderr)
        self.assertIn("renderer exited 7", completed.stderr)
        self.assertFalse(json.loads(report_path.read_text(encoding="utf-8"))["pass"])

    def test_config_policy_refuses_code_loading_shapes(self) -> None:
        self.repo.commit_manual("current")
        base = self.repo.root / "mkdocs.yml"
        for config, needle in (
            ("site_name: t\ndocs_dir: docs/manual\nhooks:\n  - docs/hook.py\n", "keys are not admitted: hooks"),
            ("site_name: t\ndocs_dir: docs/manual\nplugins:\n  - search\n  - macros\n", "plugins not admitted: macros"),
            ("site_name: t\ndocs_dir: docs/manual\ntheme:\n  name: material\n  custom_dir: overrides\n", "theme keys are not admitted: custom_dir"),
            ("site_name: t\ndocs_dir: ../../etc\n", "docs_dir must be exactly docs/manual"),
            ("site_name: t\ndocs_dir: docs/manual\nmarkdown_extensions:\n  - evil.module\n", "markdown_extensions not admitted"),
            ("site_name: t\ndocs_dir: docs/manual\nextra_javascript:\n  - https://example.com/x.js\n", "relative path inside the manual"),
            ("site_name: t\ndocs_dir: docs/manual\ntheme: &a material\n", "outside the accepted YAML subset"),
            ("site_name: t\ndocs_dir: docs/manual\nmarkdown_extensions:\n  - pymdownx.snippets\n", "markdown_extensions not admitted: pymdownx.snippets"),
            ("site_name: t\ndocs_dir: docs/manual\nmarkdown_extensions:\n  - admonition:\n      base_path: /\n", "option(s) not admitted for admonition"),
            ("site_name: t\ndocs_dir: docs/manual\nmarkdown_extensions:\n  - toc:\n      slugify: pymdownx.slugs.slugify\n", "names a Python callable"),
            ("site_name: t\ndocs_dir: docs/manual\nplugins:\n  - search:\n      lang: en\n", "option(s) not admitted for search"),
            ("site_name: t\ndocs_dir: docs/manual\ntheme:\n  name: material\n  logo: https://example.com/l.svg\n", "theme.logo must be a relative path"),
            ("site_name: t\ndocs_dir: docs/manual\nsite_url: https://example.com/\n", "keys are not admitted: site_url"),
            ("site_name: t\ndocs_dir: docs/manual\nextra_javascript:\n  - path: https://example.com/x.js\n    type: module\n", "extra_javascript entry must be a relative path"),
            ("site_name: t\ndocs_dir: docs/manual\ntheme:\n  name: material\nextra:\n  analytics:\n    provider: google\n    property: G-XXXX\n", "extra may carry only `social`"),
            ("site_name: t\ndocs_dir: docs/manual\nextra:\n  social:\n    - icon: fontawesome/brands/github\n      link: http://example.com/x\n", "extra.social entries must be"),
        ):
            with self.subTest(config=config):
                base.write_text(config, encoding="utf-8")
                git(["add", "-A"], self.repo.root); git(["commit", "-q", "-m", "docs: config"], self.repo.root)
                completed, _s, _r = self.run_assembly()
                self.assertEqual(completed.returncode, 1, completed.stderr)
                self.assertIn(needle, completed.stderr)
        base.write_text("site_name: t\ndocs_dir: docs/manual\ntheme:\n  name: material\nplugins:\n  - search\nmarkdown_extensions:\n  - admonition\n  - toc:\n      permalink: true\n", encoding="utf-8")
        git(["add", "-A"], self.repo.root); git(["commit", "-q", "-m", "docs: config ok"], self.repo.root)
        completed, _s, _r = self.run_assembly()
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_candidate_below_its_series_tip_is_refused(self) -> None:
        self.repo.commit_manual("26.0.2"); self.repo.tag("v26.0.2")
        self.repo.commit_manual("27.0.0"); self.repo.tag("v27.0.0")
        self.repo.commit_manual("26.0.1-candidate")
        completed, _s, _r = self.run_assembly("--published-tag", "v26.0.2", "--published-tag", "v27.0.0", version="26.0.1")
        self.assertEqual(completed.returncode, 1, completed.stderr)
        self.assertIn("below a published tip", completed.stderr)
        self.assertNotIn("26.0", completed.stderr, "a refusal must not log the unassigned version or its series")

    def test_nondeterministic_renderer_is_refused(self) -> None:
        self.repo.commit_manual("current")
        flaky = self.tmp / "flaky-mkdocs"
        flaky.write_text("#!/bin/sh\nout=\"$6\"\nmkdir -p \"$out\"\ndate +%N > \"$out/index.html\"\n", encoding="utf-8")
        flaky.chmod(0o700)
        self.renderer = flaky
        completed, _s, _r = self.run_assembly()
        self.assertEqual(completed.returncode, 1, completed.stderr)
        self.assertIn("not deterministic", completed.stderr)

    def test_manifest_path_collision_and_mistagged_commit_are_refused(self) -> None:
        self.repo.commit_manual("current", pages=("index.md", "version-manifest.json.md"))
        completed, _s, _r = self.run_assembly()
        self.assertEqual(completed.returncode, 1, completed.stderr)
        self.assertIn("the manifest path", completed.stderr)
        self.repo.commit_manual("26.0.0", constant="26.0.1"); self.repo.tag("v26.0.0")
        self.repo.commit_manual("current")
        completed, _s, _r = self.run_assembly("--published-tag", "v26.0.0")
        self.assertEqual(completed.returncode, 1, completed.stderr)
        self.assertIn("version constant is 26.0.1", completed.stderr)
        # A declaration-shaped comment beside the real constant is two declarations: refused.
        swift = self.repo.root / "Sources" / "AppleKit" / "CommandSupport.swift"
        swift.write_text('// public static let current = "26.1.0"\npublic enum AppleVersion {\n    public static let current = "26.0.0"\n}\n', encoding="utf-8")
        git(["add", "-A"], self.repo.root); git(["commit", "-q", "-m", "chore: spoof"], self.repo.root); self.repo.tag("v26.1.0")
        self.repo.commit_manual("current2")
        completed, _s, _r = self.run_assembly("--published-tag", "v26.1.0")
        self.assertEqual(completed.returncode, 1, completed.stderr)
        self.assertIn("expected exactly one version-constant declaration", completed.stderr)

    def test_scratch_must_be_empty(self) -> None:
        self.repo.commit_manual("current")
        scratch = self.tmp / "prefilled"; scratch.mkdir(); (scratch / "x").write_text("x", encoding="utf-8")
        argv = [sys.executable, "-I", "-S", "-B", str(SCRIPT), "--candidate-root", str(self.repo.root),
                "--candidate-sha", self.repo.head(), "--candidate-version", "27.0.0",
                "--renderer", str(self.renderer), "--scratch", str(scratch)]
        completed = subprocess.run(argv, env={"PATH": "/usr/bin:/bin"}, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
        self.assertEqual(completed.returncode, 2)
        self.assertIn("must be empty", completed.stderr)

    def test_repository_mkdocs_config_passes_the_policy(self) -> None:
        """The tracked mkdocs.yml must stay inside the config allowlist, or the rehearsal turns red."""
        assembly.check_config_policy(REPO_ROOT / "mkdocs.yml", "repository")

    def test_use_directory_urls_false_is_refused(self) -> None:
        self.repo.commit_manual("current")
        (self.repo.root / "mkdocs.yml").write_text("site_name: t\ndocs_dir: docs/manual\nuse_directory_urls: false\n", encoding="utf-8")
        git(["add", "-A"], self.repo.root); git(["commit", "-q", "-m", "docs: flat urls"], self.repo.root)
        completed, _s, _r = self.run_assembly()
        self.assertEqual(completed.returncode, 1, completed.stderr)
        self.assertIn("use_directory_urls", completed.stderr)

    def test_printed_errors_escape_characters_that_could_start_a_line(self) -> None:
        # A refused tag or config key may hold a line feed; printed verbatim, a following
        # `::error::` would reach the runner as a workflow command. (A refused tag is quoted with
        # repr today; the check pins the outcome whichever layer does the escaping.)
        self.repo.commit_manual("current")
        completed, _s, _r = self.run_assembly("--published-tag", "v26.0.0\n::error::injected")
        self.assertEqual(completed.returncode, 2, completed.stderr)
        self.assertIn("::error::injected", completed.stderr)
        self.assertFalse(any(line.startswith("::") for line in completed.stderr.splitlines()), completed.stderr)
        (self.repo.root / "mkdocs.yml").write_text('site_name: t\ndocs_dir: docs/manual\n"a\\n::error::injected": x\n',
                                                   encoding="utf-8")
        git(["add", "-A"], self.repo.root); git(["commit", "-q", "-m", "docs: odd key"], self.repo.root)
        completed, _s, _r = self.run_assembly()
        self.assertEqual(completed.returncode, 1, completed.stderr)
        self.assertIn("::error::injected", completed.stderr)
        self.assertFalse(any(line.startswith("::") for line in completed.stderr.splitlines()), completed.stderr)

    def test_derived_candidate_version_routes_like_release_prep(self) -> None:
        self.repo.commit_manual("26.0.0"); self.repo.tag("v26.0.0")
        (self.repo.root / "feature.txt").write_text("x\n", encoding="utf-8")
        git(["add", "-A"], self.repo.root); git(["commit", "-q", "-m", "feat(x): something new"], self.repo.root)
        self.repo.commit_manual("current-after-feat")
        completed, scratch, report_path = self.run_assembly("--derive-candidate-version", "--published-tag", "v26.0.0", version=None)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertTrue(report["candidate_serves_root"])
        self.assertFalse(report["candidate_is_published_release"])
        self.assertEqual(report["routes"], ["/", "/versions/", "/versions/26.0/", "/version-manifest.json"])
        self.assertNotIn("26.1", completed.stderr + json.dumps(report), "the derived minor bump must not be logged or reported")

    def test_derived_candidate_at_a_tagged_release_folds_the_tag(self) -> None:
        self.repo.commit_manual("25.0.0"); self.repo.tag("v25.0.0")
        self.repo.commit_manual("26.0.0"); self.repo.tag("v26.0.0")
        completed, scratch, report_path = self.run_assembly("--derive-candidate-version", "--published-tag", "v25.0.0",
                                                            "--published-tag", "v26.0.0", version=None)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertTrue(report["candidate_is_published_release"])
        self.assertEqual(report["published_tag_count"], 2)
        self.assertEqual(report["routes"], ["/", "/versions/", "/versions/25.0/", "/version-manifest.json"])

    def test_published_set_from_a_releases_listing(self) -> None:
        self.repo.commit_manual("26.0.0"); self.repo.tag("v26.0.0")
        self.repo.commit_manual("26.1.0"); self.repo.tag("v26.1.0")
        self.repo.commit_manual("current")
        listing = self.tmp / "releases.json"
        listing.write_text(json.dumps([
            {"tag_name": "v26.1.0", "draft": False, "prerelease": False},
            {"tag_name": "v26.0.0", "draft": True, "prerelease": False},
            {"tag_name": "v27.0.0-rc.1", "draft": False, "prerelease": True},
        ]), encoding="utf-8")
        completed, _s, report_path = self.run_assembly("--published-from-json", str(listing))
        self.assertEqual(completed.returncode, 0, completed.stderr)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertEqual(report["routes"], ["/", "/versions/", "/versions/26.1/", "/version-manifest.json"])
        self.assertEqual(report["published_tag_count"], 1)
        for bad in ('{"tag_name": "v1.0.0"}', '[{"draft": false}]', '[{"tag_name": "release-1", "draft": false, "prerelease": false}]', "not json"):
            listing.write_text(bad, encoding="utf-8")
            with self.subTest(bad=bad):
                completed, scratch, _r = self.run_assembly("--published-from-json", str(listing))
                self.assertEqual(completed.returncode, 2, completed.stderr)
                self.assertFalse(scratch.exists())

    def test_derived_version_may_not_displace_a_published_tag(self) -> None:
        self.repo.commit_manual("26.0.0"); self.repo.tag("v26.0.0")
        self.repo.commit_manual("26.0.1"); self.repo.tag("v26.0.1")
        # Rewind: a branch off v26.0.0 with one fix commit derives 26.0.1 — already published elsewhere.
        git(["checkout", "-q", "-b", "fix", "v26.0.0"], self.repo.root)
        (self.repo.root / "fix.txt").write_text("x\n", encoding="utf-8")
        git(["add", "-A"], self.repo.root); git(["commit", "-q", "-m", "fix: something"], self.repo.root)
        completed, _s, _r = self.run_assembly("--derive-candidate-version", "--published-tag", "v26.0.1", version=None)
        self.assertEqual(completed.returncode, 1, completed.stderr)
        self.assertIn("already carries the derived candidate version", completed.stderr)
        self.assertNotIn("26.0.1", completed.stderr)

    def test_folded_tag_is_constant_checked_and_full_listing_page_is_refused(self) -> None:
        self.repo.commit_manual("26.0.0", constant="26.0.5"); self.repo.tag("v26.0.0")
        completed, _s, _r = self.run_assembly("--derive-candidate-version", "--published-tag", "v26.0.0", version=None)
        self.assertEqual(completed.returncode, 1, completed.stderr)
        self.assertIn("version constant is 26.0.5", completed.stderr)
        listing = self.tmp / "full.json"
        listing.write_text(json.dumps([{"tag_name": "v1.0.{}".format(i), "draft": False, "prerelease": False} for i in range(100)]), encoding="utf-8")
        completed, scratch, _r = self.run_assembly("--published-from-json", str(listing))
        self.assertEqual(completed.returncode, 2, completed.stderr)
        self.assertIn("may be truncated", completed.stderr)

    def test_version_source_is_exactly_one(self) -> None:
        self.repo.commit_manual("current")
        completed, scratch, _r = self.run_assembly(version=None)
        self.assertEqual(completed.returncode, 2, completed.stderr)
        self.assertIn("exactly one of", completed.stderr)
        completed, scratch, _r = self.run_assembly("--derive-candidate-version")
        self.assertEqual(completed.returncode, 2, completed.stderr)

    def test_selection_function(self) -> None:
        S = assembly.Selected
        cand = S((26, 0, 1), "c" * 40, None)
        pub = [S((26, 0, 0), "a" * 40, "v26.0.0"), S((27, 0, 0), "b" * 40, "v27.0.0"), S((26, 1, 0), "d" * 40, "v26.1.0")]
        current, archives = assembly.select(cand, pub)
        self.assertEqual(current.tag, "v27.0.0")
        self.assertEqual([(a.series, a.label) for a in archives], [("26.0", "candidate"), ("26.1", "v26.1.0")])


@unittest.skipUnless(os.environ.get("APPLE_CLI_SITE_RENDERER"), "set APPLE_CLI_SITE_RENDERER to the pinned mkdocs executable")
class RealRendererTests(unittest.TestCase):
    def test_real_tree_assembles_twice_identically_with_a_synthetic_archive(self) -> None:
        """Clone the real repository, tag an older manual-bearing commit with a SYNTHETIC tag
        inside the clone only, and assemble twice with the pinned renderer: archives, manifest
        and determinism are exercised against real MkDocs output."""
        with tempfile.TemporaryDirectory() as tmp:
            clone = Path(tmp) / "clone"
            git(["clone", "-q", "--no-hardlinks", str(REPO_ROOT), str(clone)], Path(tmp))
            head = git(["rev-parse", "HEAD"], clone).strip()
            older = git(["rev-list", "-n", "1", "HEAD~5", "--", "docs/manual"], clone).strip()
            if not older:
                self.skipTest("no older manual-bearing commit reachable")
            swift = git(["show", "{}:Sources/AppleKit/CommandSupport.swift".format(older)], clone)
            constant = assembly.CONSTANT_RE.search(swift).group(2)  # the synthetic tag must match the commit's constant
            # The clone is a throwaway: (re)tag v<constant> at an older manual-bearing commit so an
            # archive route is exercised with real MkDocs output.
            existing = subprocess.run([GIT, "tag", "--list", "v" + constant], cwd=str(clone), env=GIT_ENV, stdout=subprocess.PIPE,
                                      text=True, check=True).stdout.strip()
            if existing:
                git(["tag", "-d", "v" + constant], clone)
            git(["tag", "v" + constant, older], clone)
            reports = []
            for run in ("a", "b"):
                report = Path(tmp) / "report-{}.json".format(run)
                argv = [sys.executable, "-I", "-S", "-B", str(SCRIPT), "--candidate-root", str(clone), "--candidate-sha", head,
                        "--candidate-version", "27.0.0", "--published-tag", "v" + constant,
                        "--renderer", os.environ["APPLE_CLI_SITE_RENDERER"], "--scratch", str(Path(tmp) / ("scratch-" + run)),
                        "--report", str(report)]
                completed = subprocess.run(argv, env={"PATH": "/usr/bin:/bin"}, stdin=subprocess.DEVNULL,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                reports.append(json.loads(report.read_text(encoding="utf-8")))
            series = ".".join(constant.split(".")[:2])
            self.assertEqual(reports[0]["routes"], ["/", "/versions/", "/versions/{}/".format(series), "/version-manifest.json"])
            self.assertEqual(reports[0]["content_manifest_sha256"], reports[1]["content_manifest_sha256"])
            self.assertEqual(reports[0]["artifact_sha256"], reports[1]["artifact_sha256"])
            self.assertNotEqual(reports[0]["renderer_version"], "unknown")


if __name__ == "__main__":
    unittest.main()
