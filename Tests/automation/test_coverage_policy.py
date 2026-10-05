import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
POLICY_PATH = REPO_ROOT / "scripts" / "ci" / "coverage_policy.py"
TARGETS = (
    "AppleKit",
    "EventKitCore",
    "MessagesKit",
    "MailKit",
    "ContactsKit",
    "NotesKit",
    "CalendarKit",
    "RemindersKit",
    "apple",
)


def load_policy():
    spec = importlib.util.spec_from_file_location("coverage_policy", POLICY_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load coverage policy")
    module = importlib.util.module_from_spec(spec)
    sys.modules["coverage_policy"] = module
    spec.loader.exec_module(module)
    return module


def run_git(repo: Path, *args: str) -> str:
    completed = subprocess.run(
        ["/usr/bin/git", "-C", str(repo), *args],
        check=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=10,
    )
    return completed.stdout.strip()


def write(path: Path, text: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def write_bytes(path: Path, data: bytes) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def init_repo(path: Path, targets=TARGETS) -> str:
    path.mkdir(parents=True, exist_ok=True)
    run_git(path, "init", "-q")
    run_git(path, "config", "user.name", "Jane Doe")
    run_git(path, "config", "user.email", "jane@example.com")
    for target in targets:
        write(path / "Sources" / target / "Synthetic.swift", "line one\nline two\n")
    write(path / "README.md", "synthetic fixture\n")
    run_git(path, "add", "README.md", "Sources")
    run_git(path, "commit", "-q", "-m", "test: seed fixture")
    return run_git(path, "rev-parse", "HEAD")


def commit_file(repo: Path, rel: str, text: str) -> str:
    write(repo / rel, text)
    run_git(repo, "add", rel)
    run_git(repo, "commit", "-q", "-m", "test: update fixture")
    return run_git(repo, "rev-parse", "HEAD")


def lcov_record(source_file: Path, da_hits, *, lf=None, lh=None) -> str:
    ordered = list(da_hits)
    if lf is None:
        lf = len({line for line, _hits in ordered})
    if lh is None:
        lh = sum(1 for _line, hits in ordered if hits > 0)
    lines = ["TN:", f"SF:{source_file}", "FN:2,synthetic_function", "FNDA:1,synthetic_function"]
    lines.extend(f"DA:{line},{hits}" for line, hits in ordered)
    lines.extend([f"LF:{lf}", f"LH:{lh}", "end_of_record"])
    return "\n".join(lines) + "\n"


def lcov_for(repo: Path, coverage_by_target) -> str:
    records = []
    for target, (lf, lh) in coverage_by_target.items():
        source = repo / "Sources" / target / "Synthetic.swift"
        da_count = min(lf, 10)
        da_hits = [(line, 1 if line <= min(lh, da_count) else 0) for line in range(1, da_count + 1)]
        records.append(lcov_record(source, da_hits, lf=lf, lh=lh))
    return "".join(records)


def show_output(statuses):
    rendered = []
    for line, status in statuses:
        count = "       " if status == "non_coverable" else "      0" if status == "uncovered" else "      7"
        rendered.append(f"{line:5d}|{count}|synthetic")
    return "\n".join(rendered) + "\n"


REFUSED_SOURCE = "changed source contains a refused character"
# A Swift comment that, read by `str.splitlines`, ends at U+2028 and leaves a hunk header behind.
FORGED_HUNK_COMMENT = "// note\u2028@@ -1 +200,90 @@"


def separator_source() -> str:
    """A new Swift file of 100 lines by line feed: ten uncovered functions, then 90 comment
    lines that each hold U+2028 and an llvm-cov `N|count|` prefix (190 lines to `splitlines`)."""
    functions = "".join(f"func f{index}() {{}}\n" for index in range(1, 11))
    return functions + "".join(f"// pad\u2028   {100 + index}|      9|\n" for index in range(1, 91))


def separator_show() -> str:
    """llvm-cov `show` text for `separator_source`, assuming it prints source text verbatim."""
    functions = "".join(f"{index:5d}|      0|func f{index}() {{}}\n" for index in range(1, 11))
    return functions + "".join(
        f"{10 + index:5d}|       |// pad\u2028   {100 + index}|      9|\n" for index in range(1, 91)
    )


class CoverageTool:
    def __init__(self, base_binary, head_binary, base_lcov, head_lcov, statuses):
        self.base_binary = str(base_binary)
        self.head_binary = str(head_binary)
        self.base_lcov = base_lcov
        self.head_lcov = head_lcov
        self.statuses = statuses
        self.commands = []
        self.export_index = 0

    def export(self, command, cwd):
        self.commands.append((tuple(command), cwd))
        self._assert_xcrun(command)
        if command[1:4] != ["llvm-cov", "export", "-format=lcov"]:
            raise AssertionError("wrong export command")
        outputs = [self.base_lcov, self.head_lcov]
        if self.export_index >= len(outputs):
            raise AssertionError("unexpected export request")
        output = outputs[self.export_index]
        self.export_index += 1
        return output

    def show(self, command, cwd):
        self.commands.append((tuple(command), cwd))
        self._assert_xcrun(command)
        if command[1:5] != ["llvm-cov", "show", "--show-line-counts-or-regions", "--show-instantiations=false"]:
            raise AssertionError("wrong show command")
        rel = command[-1]
        if rel not in self.statuses:
            raise AssertionError("unexpected source request")
        return show_output(self.statuses[rel])

    def _assert_xcrun(self, command):
        if command[0] != "/usr/bin/xcrun":
            raise AssertionError("wrong tool")


class CoveragePolicyTests(unittest.TestCase):
    def setUp(self):
        self.policy = load_policy()
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.base_repo = self.root / "base"
        self.head_repo = self.root / "head"
        self.base_sha = init_repo(self.base_repo)
        self.head_sha = init_repo(self.head_repo)
        self.base_binary = write(self.root / "base-binary", "base binary\n")
        self.base_profdata = write(self.root / "base.profdata", "base profile\n")
        self.head_binary = write(self.root / "head-binary", "head binary\n")
        self.head_profdata = write(self.root / "head.profdata", "head profile\n")

    def tearDown(self):
        self.tmp.cleanup()

    def test_snapshot_directory_prefers_the_private_tmp_root_and_falls_to_the_platform_tempdir(self):
        # macOS: /tmp resolves to /private/tmp, and the identity checks compare canonical
        # paths, so the fixed private root is preferred whenever it exists. The probe is
        # pinned to its receiver so a wrong path being tested cannot pass by accident.
        with mock.patch.object(self.policy.Path, "is_dir", autospec=True, return_value=True) as probe:
            self.assertEqual(self.policy._snapshot_directory(), "/private/tmp")
        self.assertEqual([call.args[0] for call in probe.call_args_list], [Path("/private/tmp")])
        # A hosted Linux runner has no /private: the fixed /tmp root is next, never the
        # environment-derived TMPDIR.
        def only_tmp(path):
            return str(path) == "/tmp"
        with mock.patch.object(self.policy.Path, "is_dir", autospec=True, side_effect=only_tmp) as probe:
            self.assertEqual(self.policy._snapshot_directory(), "/tmp")
        self.assertEqual([call.args[0] for call in probe.call_args_list],
                         [Path("/private/tmp"), Path("/tmp")])
        # Neither fixed root exists: the platform default is the last resort, and the
        # snapshot is still created privately by NamedTemporaryFile (O_EXCL, 0600).
        with mock.patch.object(self.policy.Path, "is_dir", autospec=True, return_value=False), \
                mock.patch.object(self.policy.tempfile, "gettempdir", return_value="/synthetic/tmp"):
            self.assertEqual(self.policy._snapshot_directory(), "/synthetic/tmp")

    def test_snapshot_files_are_private_regardless_of_root(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(self.policy, "_snapshot_directory", return_value=directory):
                path = self.policy._write_snapshot(b"payload", error_message="coverage tool input is invalid")
            try:
                self.assertEqual(path.parent, Path(directory).resolve())
                self.assertEqual(oct(path.stat().st_mode & 0o777), "0o600")
                self.assertEqual(path.read_bytes(), b"payload")
            finally:
                path.unlink()

    def evaluate(self, base_lcov, head_lcov, statuses=None, **kwargs):
        tool = kwargs.pop("tool", None) or CoverageTool(
            self.base_binary,
            self.head_binary,
            base_lcov,
            head_lcov,
            statuses or {},
        )
        result = self.policy.evaluate_policy(
            base_coverage_binary_path=kwargs.get("base_coverage_binary_path", self.base_binary),
            base_profdata_path=kwargs.get("base_profdata_path", self.base_profdata),
            head_coverage_binary_path=kwargs.get("head_coverage_binary_path", self.head_binary),
            head_profdata_path=kwargs.get("head_profdata_path", self.head_profdata),
            base_repository_root=kwargs.get("base_repository_root", self.base_repo),
            head_repository_root=kwargs.get("head_repository_root", self.head_repo),
            expected_base_sha=kwargs.get("expected_base_sha", self.base_sha),
            expected_head_sha=kwargs.get("expected_head_sha", self.head_sha),
            llvm_cov_export_runner=kwargs.get("llvm_cov_export_runner", tool.export),
            llvm_cov_show_runner=kwargs.get("llvm_cov_show_runner", tool.show),
        )
        return result, tool

    def test_internal_lcov_generation_is_authoritative(self):
        good = {target: (10, 9) for target in TARGETS}
        bad = dict(good)
        bad["AppleKit"] = (1000, 100)
        forged_external_lcov = lcov_for(self.head_repo, good)
        self.assertIn("LH:9", forged_external_lcov)

        result, _tool = self.evaluate(lcov_for(self.base_repo, good), lcov_for(self.head_repo, bad))

        self.assertFalse(result.ok)
        self.assertIn("aggregate coverage is below 90%", result.diagnostics)
        self.assertEqual(result.targets["AppleKit"].covered, 100)
        self.assertEqual(result.targets["AppleKit"].count, 1000)

    def test_tracked_production_file_missing_from_generated_lcov_fails(self):
        self.base_sha = commit_file(self.base_repo, "Sources/AppleKit/Omitted.swift", "same\n")
        self.head_sha = commit_file(self.head_repo, "Sources/AppleKit/Omitted.swift", "same\n")
        cov = {target: (10, 9) for target in TARGETS}

        result, _tool = self.evaluate(lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov))

        self.assertFalse(result.ok)
        self.assertIn("missing coverage record for base production file", result.diagnostics)
        self.assertIn("missing coverage record for head production file", result.diagnostics)

    def test_coverage_tool_inputs_are_snapshotted_and_cleaned(self):
        cov = {target: (10, 9) for target in TARGETS}
        generated = [lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov)]
        commands = []

        def export_runner(command, _cwd):
            commands.append(tuple(command))
            self.assertTrue(Path(command[-1]).exists())
            profile_arg = next(arg for arg in command if arg.startswith("-instr-profile="))
            self.assertTrue(Path(profile_arg.removeprefix("-instr-profile=")).exists())
            return generated[len(commands) - 1]

        result, _tool = self.evaluate(
            generated[0],
            generated[1],
            llvm_cov_export_runner=export_runner,
        )

        self.assertTrue(result.ok, result.diagnostics)
        snapshot_paths = []
        for command in commands:
            snapshot_paths.append(Path(command[-1]))
            snapshot_paths.append(Path(next(arg for arg in command if arg.startswith("-instr-profile=")).removeprefix("-instr-profile=")))
        self.assertNotIn(self.base_binary, snapshot_paths)
        self.assertNotIn(self.head_binary, snapshot_paths)
        self.assertTrue(all(not path.exists() for path in snapshot_paths))

    def test_partial_snapshot_failure_removes_prior_snapshots(self):
        cov = {target: (10, 9) for target in TARGETS}
        retained = []

        def failing_snapshot(data, *, error_message):
            if len(retained) == 2:
                raise self.policy.PolicyError(error_message)
            path = self.root / f"snapshot-{len(retained)}"
            path.write_bytes(data)
            retained.append(path)
            return path

        with mock.patch.object(self.policy, "_write_snapshot", side_effect=failing_snapshot):
            result, _tool = self.evaluate(lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov))

        self.assertFalse(result.ok)
        self.assertEqual(result.diagnostics, "coverage tool input is invalid")
        self.assertTrue(retained)
        self.assertTrue(all(not path.exists() for path in retained))

    def test_snapshot_writer_removes_partial_file_when_creation_fails(self):
        leaked_path = self.root / "partial-snapshot"

        class FailingTempFile:
            name = str(leaked_path)

            def write(self, data):
                leaked_path.write_bytes(data)
                raise OSError("synthetic failure")

            def close(self):
                pass

        with mock.patch.object(self.policy.tempfile, "NamedTemporaryFile", return_value=FailingTempFile()):
            with self.assertRaises(self.policy.PolicyError) as raised:
                self.policy._write_snapshot(b"partial", error_message="coverage tool input is invalid")

        self.assertEqual(str(raised.exception), "coverage tool input is invalid")
        self.assertFalse(leaked_path.exists())

    def test_reviewed_declaration_only_files_may_be_absent_from_lcov(self):
        approved_content = (REPO_ROOT / "Sources" / "AppleKit" / "AppleScriptRunning.swift").read_text(encoding="utf-8")
        for repo in (self.base_repo, self.head_repo):
            write(repo / "Sources" / "AppleKit" / "AppleScriptRunning.swift", approved_content)
            run_git(repo, "add", "Sources/AppleKit/AppleScriptRunning.swift")
            run_git(repo, "commit", "-q", "-m", "test: add declaration-only fixture")
        self.base_sha = run_git(self.base_repo, "rev-parse", "HEAD")
        self.head_sha = run_git(self.head_repo, "rev-parse", "HEAD")
        cov = {target: (10, 9) for target in TARGETS}

        result, _tool = self.evaluate(lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov))

        self.assertTrue(result.ok, result.diagnostics)

    def test_apple_entrypoint_file_must_have_coverage_record(self):
        for repo in (self.base_repo, self.head_repo):
            write(repo / "Sources" / "apple" / "Apple.swift", "public func syntheticEntrypoint() {}\n")
            run_git(repo, "add", "Sources/apple/Apple.swift")
            run_git(repo, "commit", "-q", "-m", "test: add executable entrypoint fixture")
        self.base_sha = run_git(self.base_repo, "rev-parse", "HEAD")
        self.head_sha = run_git(self.head_repo, "rev-parse", "HEAD")
        cov = {target: (10, 9) for target in TARGETS}

        result, _tool = self.evaluate(lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov))

        self.assertFalse(result.ok)
        self.assertIn("missing coverage record for base production file", result.diagnostics)
        self.assertIn("missing coverage record for head production file", result.diagnostics)

    def test_snapshot_replacement_after_validation_fails_closed(self):
        cov = {target: (10, 9) for target in TARGETS}

        def replacing_export(command, _cwd):
            Path(command[-1]).write_text("replaced binary\n", encoding="utf-8")
            return lcov_for(self.base_repo if replacing_export.calls == 0 else self.head_repo, cov)

        replacing_export.calls = 0

        def counted_export(command, cwd):
            output = replacing_export(command, cwd)
            replacing_export.calls += 1
            return output

        result, _tool = self.evaluate(
            lcov_for(self.base_repo, cov),
            lcov_for(self.head_repo, cov),
            llvm_cov_export_runner=counted_export,
        )

        self.assertFalse(result.ok)
        self.assertEqual(result.diagnostics, "coverage tool input is invalid")

    def test_git_invocations_ignore_candidate_fsmonitor_and_global_config(self):
        observed = {}

        def fake_run(command, cwd, **kwargs):
            observed["command"] = command
            observed["cwd"] = cwd
            observed["env"] = kwargs.get("env")
            observed["max_output_bytes"] = kwargs.get("max_output_bytes")
            observed["timeout_seconds"] = kwargs.get("timeout_seconds")
            return b""

        with mock.patch.object(self.policy, "_run_bounded_command_bytes", side_effect=fake_run, create=True):
            self.policy._run_git(self.base_repo, ("rev-parse", "HEAD"), error_message="checkout identity is invalid")

        self.assertEqual(observed["command"][0], "/usr/bin/git")
        self.assertIn("core.fsmonitor=false", observed["command"])
        self.assertIn("core.hooksPath=/dev/null", observed["command"])
        self.assertIn("credential.helper=", observed["command"])
        self.assertEqual(observed["env"]["GIT_CONFIG_GLOBAL"], "/dev/null")
        self.assertEqual(observed["env"]["GIT_CONFIG_NOSYSTEM"], "1")
        self.assertEqual(observed["env"]["GIT_OPTIONAL_LOCKS"], "0")
        self.assertEqual(observed["env"]["LC_ALL"], "C")
        self.assertEqual(observed["cwd"], self.base_repo)
        self.assertEqual(observed["max_output_bytes"], self.policy.MAX_GIT_OUTPUT_BYTES)
        self.assertEqual(observed["timeout_seconds"], self.policy.MAX_GIT_SECONDS)

    def test_xcrun_invocations_use_a_dedicated_scrubbed_environment(self):
        observed = {}

        def fake_run(command, cwd, **kwargs):
            observed["command"] = command
            observed["cwd"] = cwd
            observed["env"] = kwargs.get("env")
            return ""

        hostile_environment = {
            "DEVELOPER_DIR": "/private/tmp/redirected-developer",
            "TOOLCHAINS": "redirected-toolchain",
            "SDKROOT": "/private/tmp/redirected-sdk",
            "DYLD_INSERT_LIBRARIES": "/private/tmp/redirected-library",
            "LLVM_PROFILE_FILE": "/private/tmp/redirected-profile",
            "PATH": "/private/tmp/redirected-path",
        }
        command = ["/usr/bin/xcrun", "llvm-cov", "export"]
        with mock.patch.dict(os.environ, hostile_environment, clear=False):
            with mock.patch.object(self.policy, "_run_bounded_command", side_effect=fake_run):
                self.policy._run_bounded_xcrun(command, self.root, error_message="coverage input is invalid")

        self.assertEqual(observed["command"], command)
        self.assertEqual(observed["cwd"], self.root)
        self.assertEqual(observed["env"], self.policy.XCRUN_ENV)
        self.assertEqual(
            observed["env"],
            {
                "LANG": "C",
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": "/private/tmp",
            },
        )
        for key in hostile_environment:
            if key not in {"PATH"}:
                self.assertNotIn(key, observed["env"])

    def test_oversized_committed_swift_blob_is_rejected_before_content_read(self):
        rel = "Sources/AppleKit/Oversized.swift"
        self.head_sha = commit_file(self.head_repo, rel, "0123456789abcdef\n")
        source = self.policy._git_tree_source_files(self.head_repo, self.head_sha)[rel]
        real_run_git_bytes = self.policy._run_git_bytes
        observed = []

        def reject_content_read(root, args, **kwargs):
            observed.append(tuple(args))
            if tuple(args[:2]) == ("cat-file", "blob"):
                raise AssertionError("oversized blob content was materialized")
            return real_run_git_bytes(root, args, **kwargs)

        with mock.patch.object(self.policy, "MAX_SOURCE_BYTES", 8):
            with mock.patch.object(self.policy, "_run_git_bytes", side_effect=reject_content_read):
                with self.assertRaises(self.policy.PolicyError) as raised:
                    self.policy._read_blob_lines(self.head_repo, source)

        self.assertEqual(str(raised.exception), "checkout identity is invalid")
        self.assertTrue(any(args[:2] == ("cat-file", "-s") for args in observed))
        self.assertFalse(any(args[:2] == ("cat-file", "blob") for args in observed))

    def test_checkout_must_be_whole_repo_clean(self):
        cov = {target: (10, 9) for target in TARGETS}
        write(self.head_repo / "Tests" / "SyntheticTests.swift", "dirty\n")
        dirty_tests, _tool = self.evaluate(lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov))
        (self.head_repo / "Tests" / "SyntheticTests.swift").unlink()
        write(self.head_repo / "Package.swift", "dirty\n")
        dirty_manifest, _tool = self.evaluate(lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov))

        self.assertFalse(dirty_tests.ok)
        self.assertEqual(dirty_tests.diagnostics, "checkout identity is invalid")
        self.assertFalse(dirty_manifest.ok)
        self.assertEqual(dirty_manifest.diagnostics, "checkout identity is invalid")

    def test_oversized_generated_lcov_output_fails_value_free(self):
        cov = {target: (10, 9) for target in TARGETS}

        def oversized_export(_command, _cwd):
            return "x" * 11

        with mock.patch.object(self.policy, "MAX_TOOL_OUTPUT_BYTES", 10):
            result, _tool = self.evaluate(
                lcov_for(self.base_repo, cov),
                lcov_for(self.head_repo, cov),
                llvm_cov_export_runner=oversized_export,
            )

        self.assertFalse(result.ok)
        self.assertEqual(result.diagnostics, "coverage input is invalid")

    def test_distinct_base_and_head_pairs_are_used(self):
        base = {target: (10, 10) for target in TARGETS}
        head = {target: (10, 9) for target in TARGETS}

        result, tool = self.evaluate(lcov_for(self.base_repo, base), lcov_for(self.head_repo, head))

        self.assertFalse(result.ok)
        self.assertIn("target coverage regressed", result.diagnostics)
        export_commands = [command for command, _cwd in tool.commands if command[1:3] == ("llvm-cov", "export")]
        self.assertNotEqual(export_commands[0][-1], export_commands[1][-1])

    def test_changed_lines_are_derived_and_show_output_is_authoritative(self):
        self.head_sha = commit_file(self.head_repo, "Sources/AppleKit/Synthetic.swift", "changed\nline one\nline two\n")
        cov = {target: (10, 10) for target in TARGETS}
        statuses = {"Sources/AppleKit/Synthetic.swift": [(1, "uncovered")]}

        result, _tool = self.evaluate(lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov), statuses)

        self.assertFalse(result.ok)
        self.assertIn("changed-line coverage is below 90%", result.diagnostics)

    def test_nul_containing_swift_is_refused_before_changed_lines(self):
        # NUL is a C0 control, which the shared refusal rule refuses like every other one, so
        # a changed blob holding it is refused before git ever diffs it.
        write_bytes(self.base_repo / "Sources" / "AppleKit" / "NulComment.swift", b"let value = 1\n// comment\x00\n")
        write_bytes(self.head_repo / "Sources" / "AppleKit" / "NulComment.swift", b"let value = 2\n// comment\x00\n")
        for repo in (self.base_repo, self.head_repo):
            run_git(repo, "add", "Sources/AppleKit/NulComment.swift")
            run_git(repo, "commit", "-q", "-m", "test: add nul fixture")
        self.base_sha = run_git(self.base_repo, "rev-parse", "HEAD")
        self.head_sha = run_git(self.head_repo, "rev-parse", "HEAD")
        cov = {target: (10, 10) for target in TARGETS}
        base_lcov = lcov_for(self.base_repo, cov) + lcov_record(self.base_repo / "Sources" / "AppleKit" / "NulComment.swift", [(1, 1)], lf=1, lh=1)
        head_lcov = lcov_for(self.head_repo, cov) + lcov_record(self.head_repo / "Sources" / "AppleKit" / "NulComment.swift", [(1, 1)], lf=1, lh=1)
        statuses = {"Sources/AppleKit/NulComment.swift": [(1, "uncovered")]}

        result, _tool = self.evaluate(base_lcov, head_lcov, statuses)

        self.assertFalse(result.ok)
        self.assertEqual(result.diagnostics, REFUSED_SOURCE)

    def test_refused_character_rule_matches_the_workflow_scan(self):
        # The coverage policy carries the workflow scan's rule as a local copy; every code point
        # must agree, as action_pins.py's copy must.
        spec = importlib.util.spec_from_file_location(
            "workflow_policy", REPO_ROOT / "scripts" / "ci" / "workflow_policy.py"
        )
        workflow_policy = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(workflow_policy)
        disagreements = [
            code for code in range(0x110000)
            if self.policy._refused_character(chr(code)) != workflow_policy.refused_character(chr(code), " \t")
        ]
        self.assertEqual(disagreements, [])
        # Space, tab and line feed are the only whitespace a source may hold.
        text = self.policy._decode_source_text(b"let a\t= 1 \n", error_message="checkout identity is invalid")
        self.assertEqual(text, "let a\t= 1 \n")

    def test_changed_swift_holding_a_refused_character_is_refused(self):
        rel = "Sources/AppleKit/Synthetic.swift"
        cov = {target: (10, 10) for target in TARGETS}
        for character in ("\u2028", "\u2029", "\u0085", "\u000b", "\u000c", "\u001c", "\r", "\u00a0",
                          "\u3000", "\ufeff", "\u202e"):
            with self.subTest(code_point=f"U+{ord(character):04X}"):
                comment = FORGED_HUNK_COMMENT.replace("\u2028", character)
                self.head_sha = commit_file(self.head_repo, rel, f"line one {comment}\nline two\n")

                result, _tool = self.evaluate(
                    lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov), {rel: [(1, "covered")]}
                )

                self.assertFalse(result.ok)
                self.assertEqual(result.diagnostics, REFUSED_SOURCE)
                self.assertNotIn(comment, result.diagnostics)

    def test_base_swift_holding_a_refused_character_may_be_cleaned_up(self):
        # Only git reads the base blob, and its removed lines reach the policy prefixed with `-`,
        # so the forged hunk header in the removed comment changes nothing: the change that
        # removes the character passes, with exactly git's two changed lines.
        rel = "Sources/AppleKit/Synthetic.swift"
        self.base_sha = commit_file(self.base_repo, rel, f"line one {FORGED_HUNK_COMMENT}\nline two\n")
        self.head_sha = commit_file(self.head_repo, rel, "line one\nline two changed\n")
        cov = {target: (10, 10) for target in TARGETS}

        result, _tool = self.evaluate(
            lcov_for(self.base_repo, cov),
            lcov_for(self.head_repo, cov),
            {rel: [(1, "covered"), (2, "covered")]},
        )

        self.assertTrue(result.ok, result.diagnostics)
        self.assertEqual((result.changed_coverage.covered, result.changed_coverage.count), (2, 2))

    def test_new_swift_file_holding_line_separators_cannot_pass_changed_coverage(self):
        rel = "Sources/AppleKit/NewFile.swift"
        self.head_sha = commit_file(self.head_repo, rel, separator_source())
        cov = {target: (10, 10) for target in TARGETS}
        head_lcov = lcov_for(self.head_repo, cov) + lcov_record(
            self.head_repo / rel, [(line, 0) for line in range(1, 11)], lf=10, lh=0
        )

        result, _tool = self.evaluate(
            lcov_for(self.base_repo, cov), head_lcov, llvm_cov_show_runner=lambda _command, _cwd: separator_show()
        )

        self.assertFalse(result.ok)
        self.assertEqual(result.diagnostics, REFUSED_SOURCE)
        self.assertNotEqual(result.changed_coverage.status, "PASS")

    def test_new_file_lines_are_numbered_by_line_feeds_even_without_the_refusal(self):
        # Defence in depth: with the refusal patched out, the new file is still numbered as git
        # and llvm-cov number it (100 lines, not 190), so its ten uncovered functions fail.
        rel = "Sources/AppleKit/NewFile.swift"
        self.head_sha = commit_file(self.head_repo, rel, separator_source())
        source = self.policy._git_tree_source_files(self.head_repo, self.head_sha)[rel]
        cov = {target: (10, 10) for target in TARGETS}
        head_lcov = lcov_for(self.head_repo, cov) + lcov_record(
            self.head_repo / rel, [(line, 0) for line in range(1, 11)], lf=10, lh=0
        )

        with mock.patch.object(self.policy, "_refused_character", return_value=False):
            lines = self.policy._read_blob_lines(self.head_repo, source)
            result, _tool = self.evaluate(
                lcov_for(self.base_repo, cov), head_lcov, llvm_cov_show_runner=lambda _command, _cwd: separator_show()
            )

        self.assertEqual(len(lines), 100)
        self.assertEqual(result.changed_coverage, self.policy.ChangedCoverage(covered=0, count=10, status="FAIL"))

    def test_changed_lines_follow_git_line_feeds_not_unicode_line_separators(self):
        base = "".join(f"let v{index} = {index}\n" for index in range(1, 301))
        head = base.replace("let v5 = 5\n", f"let v5 = 5 {FORGED_HUNK_COMMENT}\n", 1)
        base_path = write(self.root / "diff-base.swift", base)
        head_path = write(self.root / "diff-head.swift", head)

        diff = self.policy._run_git_diff(base_path, head_path)

        hunks = [line for line in diff.split("\n") if line.startswith("@@")]
        self.assertEqual(len(hunks), 1)
        self.assertTrue(hunks[0].startswith("@@ -5 +5 @@"))
        self.assertEqual(self.policy._changed_lines_from_unified_diff(diff), [5])

    def test_hunk_header_pattern_reads_ascii_digits_only(self):
        self.assertIsNotNone(self.policy.DIFF_HUNK_RE.match("@@ -1,2 +3,4 @@ context"))
        # git writes hunk ranges in ASCII digits; `\d` would also match other scripts' digits.
        for header in ("@@ -1 +\u0665 @@", "@@ -1 +5,\u0665 @@", "@@ -\uff11 +5 @@", "@@ -1,\u0661 +5 @@"):
            with self.subTest(header=ascii(header)):
                self.assertIsNone(self.policy.DIFF_HUNK_RE.match(header))

    def test_changed_content_without_hunks_fails_closed(self):
        self.head_sha = commit_file(self.head_repo, "Sources/AppleKit/Synthetic.swift", "changed\nline two\n")
        cov = {target: (10, 9) for target in TARGETS}

        with mock.patch.object(self.policy, "_run_git_diff", return_value="Binary files differ\n"):
            result, _tool = self.evaluate(lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov))

        self.assertFalse(result.ok)
        self.assertEqual(result.diagnostics, "changed-line input is invalid")

    def test_omitted_changed_show_status_fails_closed(self):
        self.head_sha = commit_file(self.head_repo, "Sources/AppleKit/Synthetic.swift", "line one\nline two\nline three\n")
        cov = {target: (10, 9) for target in TARGETS}

        result, _tool = self.evaluate(lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov), {})

        self.assertFalse(result.ok)
        self.assertEqual(result.diagnostics, "line-status input is invalid")

    def test_changed_line_missing_from_show_output_fails_closed(self):
        rel = "Sources/AppleKit/Synthetic.swift"
        self.head_sha = commit_file(self.head_repo, rel, "line one\nline two\nline three\n")
        cov = {target: (10, 9) for target in TARGETS}
        show = "    1|      2|synthetic\n    2|      7|synthetic\n"

        result, _tool = self.evaluate(
            lcov_for(self.base_repo, cov),
            lcov_for(self.head_repo, cov),
            llvm_cov_show_runner=lambda command, cwd: show,
        )

        self.assertFalse(result.ok)
        self.assertEqual(result.diagnostics, "line-status input is invalid")

    def test_show_command_suppresses_instantiation_subviews(self):
        rel = "Sources/AppleKit/Synthetic.swift"
        self.head_sha = commit_file(self.head_repo, rel, "line one\nline two\nline three\n")
        cov = {target: (10, 9) for target in TARGETS}
        commands = []

        def show(command, cwd):
            commands.append(list(command))
            return "    1|      2|synthetic\n    2|      7|synthetic\n    3|      7|synthetic\n"

        result, _tool = self.evaluate(lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov), llvm_cov_show_runner=show)

        self.assertTrue(result.ok, result.diagnostics)
        self.assertEqual(len(commands), 1)
        self.assertIn("--show-instantiations=false", commands[0])
        self.assertEqual(commands[0][-1], rel)

    def test_show_output_with_instantiation_subviews_fails_closed(self):
        rel = "Sources/AppleKit/Synthetic.swift"
        self.head_sha = commit_file(self.head_repo, rel, "line one\nline two\nline three\n")
        cov = {target: (10, 9) for target in TARGETS}
        show = (
            "    1|      2|synthetic\n"
            "    2|      7|synthetic\n"
            "    3|      7|synthetic\n"
            "  ------------------\n"
            "  | $s9Synthetic1fyyxlFSi_Tg5:\n"
            "  |    3|      7|synthetic\n"
            "  ------------------\n"
            "  | Unexecuted instantiation: $s9Synthetic1fyyxlFSS_Tg5\n"
            "  ------------------\n"
        )

        result, _tool = self.evaluate(
            lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov), llvm_cov_show_runner=lambda command, cwd: show
        )

        self.assertFalse(result.ok)
        self.assertEqual(result.diagnostics, "line-status input is invalid")

    def test_changed_line_with_a_wrapped_count_is_covered_end_to_end(self):
        rel = "Sources/AppleKit/Synthetic.swift"
        self.head_sha = commit_file(self.head_repo, rel, "line one\nline two\nline three\n")
        cov = {target: (10, 9) for target in TARGETS}
        for count, expected in (("  18.4E", (1, 1, "PASS")), ("      0", (0, 1, "FAIL"))):
            show = f"    1|      2|synthetic\n    2|      7|synthetic\n    3|{count}|synthetic\n"
            with self.subTest(count=count):
                result, _tool = self.evaluate(
                    lcov_for(self.base_repo, cov),
                    lcov_for(self.head_repo, cov),
                    llvm_cov_show_runner=lambda command, cwd, show=show: show,
                )
                changed = result.changed_coverage
                self.assertEqual((changed.covered, changed.count, changed.status), expected)

    def test_changed_non_coverable_lines_are_classified_and_can_be_na(self):
        self.head_sha = commit_file(self.head_repo, "Sources/AppleKit/Synthetic.swift", "line one\nline two\ncomment only\n")
        cov = {target: (10, 9) for target in TARGETS}
        statuses = {"Sources/AppleKit/Synthetic.swift": [(3, "non_coverable")]}

        result, _tool = self.evaluate(lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov), statuses)

        self.assertTrue(result.ok, result.diagnostics)
        self.assertEqual(result.changed_coverage.status, "N/A")
        self.assertIsNone(result.changed_coverage.percent)

    def test_new_file_branch_uses_common_changed_line_cap(self):
        self.head_sha = commit_file(self.head_repo, "Sources/AppleKit/NewFile.swift", "a\nb\nc\n")
        cov = {target: (10, 9) for target in TARGETS}
        head_lcov = lcov_for(self.head_repo, cov) + lcov_record(self.head_repo / "Sources" / "AppleKit" / "NewFile.swift", [(1, 1), (2, 1), (3, 1)], lf=3, lh=3)
        with mock.patch.object(self.policy, "MAX_CHANGED_LINES", 2):
            result, _tool = self.evaluate(lcov_for(self.base_repo, cov), head_lcov)

        self.assertFalse(result.ok)
        self.assertEqual(result.diagnostics, "changed-line input is invalid")

    def test_changed_file_cap_is_enforced_before_xcrun_show_fanout(self):
        self.head_sha = commit_file(self.head_repo, "Sources/AppleKit/NewOne.swift", "a\n")
        self.head_sha = commit_file(self.head_repo, "Sources/AppleKit/NewTwo.swift", "b\n")
        cov = {target: (10, 9) for target in TARGETS}
        head_lcov = lcov_for(self.head_repo, cov)
        head_lcov += lcov_record(self.head_repo / "Sources" / "AppleKit" / "NewOne.swift", [(1, 1)], lf=1, lh=1)
        head_lcov += lcov_record(self.head_repo / "Sources" / "AppleKit" / "NewTwo.swift", [(1, 1)], lf=1, lh=1)

        with mock.patch.object(self.policy, "MAX_CHANGED_FILES", 1, create=True):
            result, _tool = self.evaluate(lcov_for(self.base_repo, cov), head_lcov)

        self.assertFalse(result.ok)
        self.assertEqual(result.diagnostics, "changed-line input is invalid")

    def test_changed_diff_file_cap_is_enforced_before_diff_derivation(self):
        self.head_sha = commit_file(self.head_repo, "Sources/AppleKit/Synthetic.swift", "changed\nline two\n")
        cov = {target: (10, 9) for target in TARGETS}

        with mock.patch.object(self.policy, "MAX_DIFF_FILES", 0, create=True):
            result, _tool = self.evaluate(lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov))

        self.assertFalse(result.ok)
        self.assertEqual(result.diagnostics, "changed-line input is invalid")

    def test_diff_file_cap_counts_changed_production_files_only(self):
        self.head_sha = commit_file(self.head_repo, "Sources/AppleKit/Synthetic.swift", "changed\nline two\n")
        cov = {target: (10, 9) for target in TARGETS}
        statuses = {"Sources/AppleKit/Synthetic.swift": [(1, "covered")]}

        with mock.patch.object(self.policy, "MAX_DIFF_FILES", 1, create=True):
            result, _tool = self.evaluate(lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov), statuses)

        self.assertTrue(result.ok, result.diagnostics)

    def test_diff_file_cap_rejects_too_many_changed_production_files(self):
        self.head_sha = commit_file(self.head_repo, "Sources/AppleKit/NewOne.swift", "a\n")
        self.head_sha = commit_file(self.head_repo, "Sources/AppleKit/NewTwo.swift", "b\n")
        cov = {target: (10, 9) for target in TARGETS}
        head_lcov = lcov_for(self.head_repo, cov)
        head_lcov += lcov_record(self.head_repo / "Sources" / "AppleKit" / "NewOne.swift", [(1, 1)], lf=1, lh=1)
        head_lcov += lcov_record(self.head_repo / "Sources" / "AppleKit" / "NewTwo.swift", [(1, 1)], lf=1, lh=1)

        with mock.patch.object(self.policy, "MAX_DIFF_FILES", 1, create=True):
            result, _tool = self.evaluate(lcov_for(self.base_repo, cov), head_lcov)

        self.assertFalse(result.ok)
        self.assertEqual(result.diagnostics, "changed-line input is invalid")

    def test_line_status_total_output_cap_is_enforced_across_show_calls(self):
        self.head_sha = commit_file(self.head_repo, "Sources/AppleKit/Synthetic.swift", "changed\nline two\n")
        cov = {target: (10, 9) for target in TARGETS}
        statuses = {"Sources/AppleKit/Synthetic.swift": [(1, "covered")]}

        with mock.patch.object(self.policy, "MAX_TOTAL_SHOW_OUTPUT_BYTES", 10, create=True):
            result, _tool = self.evaluate(lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov), statuses)

        self.assertFalse(result.ok)
        self.assertEqual(result.diagnostics, "line-status input is invalid")

    def test_line_status_passes_remaining_output_cap_to_each_show_call(self):
        observed_caps = []

        def fake_xcrun(_command, _cwd, **kwargs):
            observed_caps.append(kwargs.get("max_output_bytes"))
            return "1|1|\n"

        with mock.patch.object(self.policy, "_run_bounded_xcrun", side_effect=fake_xcrun):
            with mock.patch.object(self.policy, "MAX_TOTAL_SHOW_OUTPUT_BYTES", 12, create=True):
                statuses = self.policy._line_status_from_llvm_cov(
                    {("Sources/AppleKit/One.swift", 1), ("Sources/AppleKit/Two.swift", 1)},
                    head_root=self.head_repo,
                    binary_path=self.head_binary,
                    profdata_path=self.head_profdata,
                )

        self.assertEqual(statuses["Sources/AppleKit/One.swift"][1], "covered")
        self.assertEqual(observed_caps, [12, 7])

    def test_line_status_global_deadline_rejects_slow_runner(self):
        self.head_sha = commit_file(self.head_repo, "Sources/AppleKit/Synthetic.swift", "changed\nline two\n")
        cov = {target: (10, 9) for target in TARGETS}

        def slow_show(_command, _cwd):
            time.sleep(0.02)
            return show_output([(1, "covered")])

        with mock.patch.object(self.policy, "MAX_TOTAL_SHOW_SECONDS", 0.001, create=True):
            result, _tool = self.evaluate(
                lcov_for(self.base_repo, cov),
                lcov_for(self.head_repo, cov),
                llvm_cov_show_runner=slow_show,
            )

        self.assertFalse(result.ok)
        self.assertEqual(result.diagnostics, "line-status input is invalid")

    def test_lf_lh_may_exceed_da_when_bounds_are_consistent(self):
        cov = {target: (10, 9) for target in TARGETS}
        cov["AppleKit"] = (20, 18)
        result, _tool = self.evaluate(lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov))

        self.assertTrue(result.ok, result.diagnostics)
        self.assertEqual(result.targets["AppleKit"].covered, 18)
        self.assertEqual(result.targets["AppleKit"].count, 20)

    def test_reversed_lcov_from_generated_tool_fails_value_free(self):
        cov = {target: (10, 9) for target in TARGETS}
        result, _tool = self.evaluate(lcov_for(self.head_repo, cov), lcov_for(self.base_repo, cov))

        self.assertFalse(result.ok)
        self.assertEqual(result.diagnostics, "coverage input is invalid")

    def test_checkout_head_and_sources_tree_must_match_expected_commit(self):
        cov = {target: (10, 9) for target in TARGETS}
        checkout_mismatch, _tool = self.evaluate(lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov), expected_base_sha="f" * 40)
        write(self.head_repo / "Sources" / "AppleKit" / "Synthetic.swift", "dirty\n")
        dirty_sources, _tool = self.evaluate(lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov))

        self.assertFalse(checkout_mismatch.ok)
        self.assertEqual(checkout_mismatch.diagnostics, "checkout identity is invalid")
        self.assertFalse(dirty_sources.ok)
        self.assertEqual(dirty_sources.diagnostics, "checkout identity is invalid")

    def test_base_target_missing_from_head_fails(self):
        self.tmp.cleanup()
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.base_repo = self.root / "base"
        self.head_repo = self.root / "head"
        self.base_binary = write(self.root / "base-binary", "base binary\n")
        self.base_profdata = write(self.root / "base.profdata", "base profile\n")
        self.head_binary = write(self.root / "head-binary", "head binary\n")
        self.head_profdata = write(self.root / "head.profdata", "head profile\n")
        self.base_sha = init_repo(self.base_repo, [*TARGETS, "ExtraKit"])
        self.head_sha = init_repo(self.head_repo)
        base_cov = {target: (10, 9) for target in [*TARGETS, "ExtraKit"]}
        head_cov = {target: (10, 9) for target in TARGETS}

        result, _tool = self.evaluate(lcov_for(self.base_repo, base_cov), lcov_for(self.head_repo, head_cov))

        self.assertFalse(result.ok)
        self.assertIn("missing required head target", result.diagnostics)

    def test_new_head_target_is_allowed_only_when_it_meets_floor(self):
        self.tmp.cleanup()
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.base_repo = self.root / "base"
        self.head_repo = self.root / "head"
        self.base_binary = write(self.root / "base-binary", "base binary\n")
        self.base_profdata = write(self.root / "base.profdata", "base profile\n")
        self.head_binary = write(self.root / "head-binary", "head binary\n")
        self.head_profdata = write(self.root / "head.profdata", "head profile\n")
        self.base_sha = init_repo(self.base_repo)
        self.head_sha = init_repo(self.head_repo, [*TARGETS, "ExtraKit"])
        base_cov = {target: (10, 9) for target in TARGETS}
        passing_head = {target: (10, 9) for target in [*TARGETS, "ExtraKit"]}
        failing_head = dict(passing_head)
        failing_head["ExtraKit"] = (10, 8)
        statuses = {"Sources/ExtraKit/Synthetic.swift": [(1, "covered"), (2, "covered")]}

        pass_result, _tool = self.evaluate(lcov_for(self.base_repo, base_cov), lcov_for(self.head_repo, passing_head), statuses)
        fail_result, _tool = self.evaluate(lcov_for(self.base_repo, base_cov), lcov_for(self.head_repo, failing_head), statuses)

        self.assertTrue(pass_result.ok, pass_result.diagnostics)
        self.assertFalse(fail_result.ok)
        self.assertIn("target coverage is below 90%", fail_result.diagnostics)

    def test_existing_head_target_below_floor_fails_even_without_regression(self):
        base = {target: (100, 100) for target in TARGETS}
        head = {target: (100, 100) for target in TARGETS}
        base["AppleKit"] = (10, 8)
        head["AppleKit"] = (10, 8)

        result, _tool = self.evaluate(lcov_for(self.base_repo, base), lcov_for(self.head_repo, head))

        self.assertFalse(result.ok)
        self.assertIn("target coverage is below 90%", result.diagnostics)

    def test_declaration_only_exclusion_requires_reviewed_blob_digest(self):
        for repo in (self.base_repo, self.head_repo):
            write(repo / "Sources" / "AppleKit" / "AppleScriptRunning.swift", "public func executableNow() { print(1) }\n")
            run_git(repo, "add", "Sources/AppleKit/AppleScriptRunning.swift")
            run_git(repo, "commit", "-q", "-m", "test: change excluded path content")
        self.base_sha = run_git(self.base_repo, "rev-parse", "HEAD")
        self.head_sha = run_git(self.head_repo, "rev-parse", "HEAD")
        cov = {target: (10, 9) for target in TARGETS}

        result, _tool = self.evaluate(lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov))

        self.assertFalse(result.ok)
        self.assertIn("missing coverage record for base production file", result.diagnostics)
        self.assertIn("missing coverage record for head production file", result.diagnostics)

    def test_zero_line_target_in_inventory_fails(self):
        cov = {target: (10, 9) for target in TARGETS}
        cov["MailKit"] = (0, 0)
        result, _tool = self.evaluate(lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov))

        self.assertFalse(result.ok)
        self.assertIn("required head target has zero coverable lines", result.diagnostics)

    def test_candidate_target_text_is_absent_from_result_and_cli_diagnostics(self):
        adversarial_target = "SyntheticPrivateTarget\x1b[31m"
        self.tmp.cleanup()
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.base_repo = self.root / "base"
        self.head_repo = self.root / "head"
        self.base_binary = write(self.root / "base-binary", "base binary\n")
        self.base_profdata = write(self.root / "base.profdata", "base profile\n")
        self.head_binary = write(self.root / "head-binary", "head binary\n")
        self.head_profdata = write(self.root / "head.profdata", "head profile\n")
        self.base_sha = init_repo(self.base_repo, [*TARGETS, adversarial_target])
        self.head_sha = init_repo(self.head_repo, [*TARGETS, adversarial_target])
        base_cov = {target: (10, 10) for target in [*TARGETS, adversarial_target]}
        head_cov = {target: (10, 9) for target in [*TARGETS, adversarial_target]}
        head_cov[adversarial_target] = (10, 8)

        result, _tool = self.evaluate(lcov_for(self.base_repo, base_cov), lcov_for(self.head_repo, head_cov))

        self.assertFalse(result.ok)
        self.assertIn("target coverage is below 90%", result.diagnostics)
        self.assertIn("target coverage regressed", result.diagnostics)
        self.assertNotIn(adversarial_target, result.diagnostics)
        self.assertNotIn("\x1b", result.diagnostics)

        args = SimpleNamespace(
            base_coverage_binary=self.base_binary,
            base_profdata=self.base_profdata,
            head_coverage_binary=self.head_binary,
            head_profdata=self.head_profdata,
            base_repository_root=self.base_repo,
            head_repository_root=self.head_repo,
            expected_base_sha=self.base_sha,
            expected_head_sha=self.head_sha,
        )
        with mock.patch.object(self.policy, "parse_args", return_value=args):
            with mock.patch.object(self.policy, "evaluate_policy", return_value=result):
                with mock.patch("builtins.print") as output:
                    exit_code = self.policy.main([])
        rendered = "\n".join(" ".join(str(value) for value in call.args) for call in output.call_args_list)
        self.assertEqual(exit_code, 1)
        self.assertNotIn(adversarial_target, rendered)
        self.assertNotIn("\x1b", rendered)

    def test_lcov_rejects_malformed_records_value_free(self):
        source = self.base_repo / "Sources" / "AppleKit" / "Synthetic.swift"
        malformed_inputs = [
            f"DA:1,1\nSF:{source}\nLF:1\nLH:1\nend_of_record\n",
            f"TN:\nSF:{source}\nDA:1,1\nLF:1\nLH:1\n",
            lcov_record(source, [(1, 1), (1, 0)], lf=2, lh=1),
            lcov_record(source, [(1, 1)], lf=0, lh=0),
            lcov_record(source, [(1, 1)], lf=1, lh=2),
            f"TN:\nSF:{source}\nDA:one,1\nLF:1\nLH:1\nend_of_record\n",
            f"TN:\nSF:{source}\nDA:1,-1\nLF:1\nLH:1\nend_of_record\n",
            f"TN:\nSF:{source}\nDA:1,{'9' * 5_000}\nLF:1\nLH:1\nend_of_record\n",
        ]

        for body in malformed_inputs:
            with self.subTest(body=body.splitlines()[0]):
                with self.assertRaises(self.policy.PolicyError) as raised:
                    self.policy.parse_lcov_text_for_test(body, self.base_repo)
                self.assertEqual(str(raised.exception), "coverage input is invalid")

    def test_lcov_counts_a_wrapped_64_bit_count_as_covered(self):
        # The changed-line reader classes a wrapped count (18.4E) as covered because this path does.
        source = self.base_repo / "Sources" / "AppleKit" / "Synthetic.swift"
        body = f"TN:\nSF:{source}\nDA:1,{2**64 - 1}\nDA:2,0\nLF:2\nLH:1\nend_of_record\n"

        report = self.policy.parse_lcov_text_for_test(body, self.base_repo)

        self.assertEqual(report.line_coverage["Sources/AppleKit/Synthetic.swift"], {1: True, 2: False})

    def test_lcov_rejects_nul_bearing_source_path_value_free(self):
        source = self.base_repo / "Sources" / "AppleKit" / "Synthetic.swift"
        body = lcov_record(Path(f"{source}\x00suffix"), [(1, 1)], lf=1, lh=1)

        with self.assertRaises(self.policy.PolicyError) as raised:
            self.policy.parse_lcov_text_for_test(body, self.base_repo)

        self.assertEqual(str(raised.exception), "coverage input is invalid")

    def test_lcov_lines_are_split_at_line_feeds_only(self):
        # llvm-cov ends LCOV lines with line feeds: a U+2028 inside a test name does not start
        # an `SF:` line, so the record that follows has no source and is refused.
        source = self.base_repo / "Sources" / "AppleKit" / "Synthetic.swift"
        body = f"TN:\u2028SF:{source}\nDA:1,1\nLF:1\nLH:1\nend_of_record\n"

        with self.assertRaises(self.policy.PolicyError) as raised:
            self.policy.parse_lcov_text_for_test(body, self.base_repo)

        self.assertEqual(str(raised.exception), "coverage input is invalid")

    def test_lcov_ignores_test_support_records_without_counting_them_as_production(self):
        support = write(self.base_repo / "Sources" / "TestSupport" / "ScratchDirs.swift", "one\n")
        report = self.policy.parse_lcov_text_for_test(lcov_record(support, [(1, 1)]), self.base_repo)

        self.assertEqual(report.targets, {})
        self.assertEqual(report.line_coverage, {})

    def test_lcov_rejects_nonexistent_and_symlink_production_files(self):
        missing = self.base_repo / "Sources" / "AppleKit" / "Missing.swift"
        real = self.base_repo / "Sources" / "AppleKit" / "Real.swift"
        linked = self.base_repo / "Sources" / "AppleKit" / "Linked.swift"
        write(real, "one\n")
        linked.symlink_to(real)

        for source in (missing, linked):
            with self.subTest():
                with self.assertRaises(self.policy.PolicyError) as raised:
                    self.policy.parse_lcov_text_for_test(lcov_record(source, [(1, 1)]), self.base_repo)
                self.assertEqual(str(raised.exception), "coverage input is invalid")

    def test_llvm_export_runner_failures_are_value_free(self):
        cov = {target: (10, 9) for target in TARGETS}

        def failing_runner(_command, _cwd):
            raise self.policy.PolicyError("coverage input is invalid")

        result, _tool = self.evaluate(
            lcov_for(self.base_repo, cov),
            lcov_for(self.head_repo, cov),
            llvm_cov_export_runner=failing_runner,
        )

        self.assertFalse(result.ok)
        self.assertEqual(result.diagnostics, "coverage input is invalid")

    def test_injected_policy_error_text_is_not_public(self):
        adversarial_text = "SyntheticPrivateDiagnostic\x1b[31m"
        cov = {target: (10, 9) for target in TARGETS}

        def failing_runner(_command, _cwd):
            raise self.policy.PolicyError(adversarial_text)

        result, _tool = self.evaluate(
            lcov_for(self.base_repo, cov),
            lcov_for(self.head_repo, cov),
            llvm_cov_export_runner=failing_runner,
        )

        self.assertFalse(result.ok)
        self.assertEqual(result.diagnostics, "coverage policy validation failed")
        self.assertNotIn(adversarial_text, result.diagnostics)
        self.assertNotIn("\x1b", result.diagnostics)

    def test_default_runner_kills_over_limit_output_before_process_completes(self):
        command = [
            "/usr/bin/xcrun",
            "/bin/sh",
            "-c",
            "printf 12345678901234567890; sleep 3; printf done",
        ]

        start = time.monotonic()
        with mock.patch.object(self.policy, "MAX_TOOL_OUTPUT_BYTES", 10):
            with self.assertRaises(self.policy.PolicyError) as raised:
                self.policy._default_llvm_cov_export_runner(command, self.root)
        elapsed = time.monotonic() - start

        self.assertEqual(str(raised.exception), "coverage input is invalid")
        self.assertLess(elapsed, 2.0)

    def test_default_runner_enforces_combined_stdout_stderr_cap(self):
        command = [
            "/usr/bin/xcrun",
            "/bin/sh",
            "-c",
            "printf 12345678; printf 12345678 >&2",
        ]

        with mock.patch.object(self.policy, "MAX_TOOL_OUTPUT_BYTES", 10):
            with self.assertRaises(self.policy.PolicyError) as raised:
                self.policy._default_llvm_cov_export_runner(command, self.root)

        self.assertEqual(str(raised.exception), "coverage input is invalid")

    def test_llvm_show_parser_rejects_malformed_and_duplicate_lines(self):
        with self.assertRaises(self.policy.PolicyError):
            self.policy.parse_llvm_cov_show("    1|      0|synthetic\n    1|      7|synthetic\n")
        with self.assertRaises(self.policy.PolicyError):
            self.policy.parse_llvm_cov_show("ambiguous output\n")

    def test_llvm_show_parser_accepts_blank_separator_lines(self):
        statuses = self.policy.parse_llvm_cov_show("    1|      0|synthetic\n\n    2|       |synthetic\n")

        self.assertEqual(statuses, {1: "uncovered", 2: "non_coverable"})

    def test_llvm_show_parser_accepts_real_abbreviated_positive_counts(self):
        statuses = self.policy.parse_llvm_cov_show("    1|  2.00k|synthetic\n    2|  1.25M|synthetic\n")

        self.assertEqual(statuses, {1: "covered", 2: "covered"})

    def test_llvm_show_parser_accepts_only_the_abbreviated_shapes_llvm_prints(self):
        accepted = (
            "1.00k", "99.9k", "999k", "2.50M", "1.00G", "1.00T", "999P",
            "1.00E", "9.99E", "10.0E", "18.4E",
        )
        body = "".join(f"{index:5}|{token:>7}|synthetic\n" for index, token in enumerate(accepted, start=1))

        self.assertEqual(
            self.policy.parse_llvm_cov_show(body),
            {index: "covered" for index in range(1, len(accepted) + 1)},
        )
        refused = (
            # Suffixes LLVM's formatCount never prints for a 64-bit count.
            "1.20K", "2.50m", "1.00g", "1.00t", "1.50Z", "2.00Y",
            # Shapes it never prints: it always shows three significant digits.
            "1.2k", ".5k", "0.50k", "1.234k", "12.34k", "1000k", "1.2kB", "k",
            # E values above the largest 64-bit count, 2**64 - 1 (18.4E).
            "18.5E", "19.0E", "99.9E", "999E",
            # E shapes formatCount never prints.
            "0.50E", "1.0E",
        )
        for token in refused:
            with self.subTest(token=token):
                with self.assertRaises(self.policy.PolicyError) as raised:
                    self.policy.parse_llvm_cov_show(f"    1|{token:>7}|synthetic\n")
                self.assertEqual(str(raised.exception), "line-status input is invalid")

    def test_llvm_show_parser_refuses_instantiation_subviews(self):
        # The show command suppresses sub-views, so any of their text is an unexpected layout.
        top = "    1|      2|x\n"
        bodies = (
            top + "  ------------------\n",
            top + "  | $s9Synthetic1fyyxlFSi_Tg5:\n",
            top + "  |    1|      2|x\n",
            top + "  | Unexecuted instantiation: $s9Synthetic1fyyxlFSS_Tg5\n",
            top + "  |      ^0\n",
        )
        for body in bodies:
            with self.subTest(body=ascii(body)):
                with self.assertRaises(self.policy.PolicyError) as raised:
                    self.policy.parse_llvm_cov_show(body)
                self.assertEqual(str(raised.exception), "line-status input is invalid")

    def test_llvm_show_parser_treats_zero_integer_forms_as_uncovered(self):
        statuses = self.policy.parse_llvm_cov_show("    1|     00|synthetic\n")

        self.assertEqual(statuses, {1: "uncovered"})

    def test_llvm_show_parser_numbers_entries_by_line_feed_only(self):
        statuses = self.policy.parse_llvm_cov_show("    1|      0|// pad\u2028    2|      9|\n    3|       |x\n")

        self.assertEqual(statuses, {1: "uncovered", 3: "non_coverable"})
        self.assertEqual(sorted(self.policy.parse_llvm_cov_show(separator_show())), list(range(1, 101)))

    def test_llvm_show_parser_admits_only_ascii_spaces_and_digits_in_its_columns(self):
        bodies = (
            "\u00a0   1|      7|synthetic\n",
            "\u3000   1|      7|synthetic\n",
            "    1|      7|synthetic\n\u00a0      ^7\n",
            "   \u0667|      9|synthetic\n",
            "   \uff15|      9|synthetic\n",
            # The count column is padded with ASCII spaces only.
            "    1|\u00a0     7|synthetic\n",
            "    1|\t     7|synthetic\n",
            "    1|      7\u2028|synthetic\n",
            "    1|      7\r|synthetic\n",
            "    1|\u00a0|synthetic\n",
        )
        for body in bodies:
            with self.subTest(body=ascii(body)):
                with self.assertRaises(self.policy.PolicyError) as raised:
                    self.policy.parse_llvm_cov_show(body)
                self.assertEqual(str(raised.exception), "line-status input is invalid")
        # A region-marker line indented with ASCII spaces is still skipped.
        self.assertEqual(self.policy.parse_llvm_cov_show("    1|      7|synthetic\n       ^7\n"), {1: "covered"})

    def test_nonnegative_int_parser_accepts_only_ascii_digits(self):
        self.assertEqual(self.policy._parse_nonnegative_int("5"), 5)
        for raw in ("\u0665", "\uff15", "5\u0665"):
            with self.subTest(raw=ascii(raw)):
                with self.assertRaises(self.policy.PolicyError) as raised:
                    self.policy._parse_nonnegative_int(raw)
                self.assertEqual(str(raised.exception), "coverage input is invalid")
        source = self.base_repo / "Sources" / "AppleKit" / "Synthetic.swift"
        with self.assertRaises(self.policy.PolicyError) as raised:
            self.policy.parse_lcov_text_for_test(f"TN:\nSF:{source}\nDA:\u0665,1\nLF:1\nLH:1\nend_of_record\n", self.base_repo)
        self.assertEqual(str(raised.exception), "coverage input is invalid")

    def test_llvm_show_parser_rejects_oversized_integer_count_value_free(self):
        body = f"    1|{'9' * 5_000}|synthetic\n"

        with self.assertRaises(self.policy.PolicyError) as raised:
            self.policy.parse_llvm_cov_show(body)

        self.assertEqual(str(raised.exception), "line-status input is invalid")

    def test_llvm_show_parser_rejects_oversized_abbreviated_count_value_free(self):
        body = f"    1|{'9' * 5_000}.1k|synthetic\n"

        with self.assertRaises(self.policy.PolicyError) as raised:
            self.policy.parse_llvm_cov_show(body)

        self.assertEqual(str(raised.exception), "line-status input is invalid")

    def test_evaluate_policy_rejects_oversized_show_count_value_free(self):
        self.head_sha = commit_file(self.head_repo, "Sources/AppleKit/Synthetic.swift", "changed\nline two\n")
        cov = {target: (10, 9) for target in TARGETS}

        def oversized_show(_command, _cwd):
            return f"    1|{'9' * 5_000}|synthetic\n"

        result, _tool = self.evaluate(
            lcov_for(self.base_repo, cov),
            lcov_for(self.head_repo, cov),
            llvm_cov_show_runner=oversized_show,
        )

        self.assertFalse(result.ok)
        self.assertEqual(result.diagnostics, "line-status input is invalid")

    def test_validated_relative_inputs_are_passed_to_xcrun_as_absolute_paths(self):
        cov = {target: (10, 9) for target in TARGETS}
        calls = []
        tool = CoverageTool(
            self.base_binary,
            self.head_binary,
            lcov_for(self.base_repo, cov),
            lcov_for(self.head_repo, cov),
            {},
        )

        def recording_export(command, cwd):
            calls.append(tuple(command))
            return tool.export(command, cwd)

        with mock.patch.object(Path, "cwd", return_value=self.root):
            result, _tool = self.evaluate(
                lcov_for(self.base_repo, cov),
                lcov_for(self.head_repo, cov),
                base_coverage_binary_path=Path("base-binary"),
                base_profdata_path=Path("base.profdata"),
                head_coverage_binary_path=Path("head-binary"),
                head_profdata_path=Path("head.profdata"),
                llvm_cov_export_runner=recording_export,
            )

        self.assertTrue(result.ok, result.diagnostics)
        snapshot_paths = []
        for command in calls:
            snapshot_paths.append(Path(command[-1]))
            snapshot_paths.append(Path(next(arg for arg in command if arg.startswith("-instr-profile=")).removeprefix("-instr-profile=")))
        self.assertTrue(all(path.is_absolute() for path in snapshot_paths))
        self.assertNotIn(self.base_binary, snapshot_paths)
        self.assertNotIn(self.head_binary, snapshot_paths)
        self.assertTrue(all(not path.exists() for path in snapshot_paths))

    def test_raw_coverage_input_rejects_parent_symlink_and_fifo(self):
        real_dir = self.root / "real-artifacts"
        linked_dir = self.root / "linked-artifacts"
        real_dir.mkdir()
        linked_dir.symlink_to(real_dir)
        linked_binary = write(linked_dir / "coverage-binary", "binary bytes\n")
        cov = {target: (10, 9) for target in TARGETS}

        result, _tool = self.evaluate(lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov), head_coverage_binary_path=linked_binary)

        self.assertFalse(result.ok)
        self.assertEqual(result.diagnostics, "coverage tool input is invalid")

        if hasattr(os, "mkfifo"):
            fifo = self.root / "profile.pipe"
            os.mkfifo(fifo)
            result, _tool = self.evaluate(lcov_for(self.base_repo, cov), lcov_for(self.head_repo, cov), head_profdata_path=fifo)
            self.assertFalse(result.ok)
            self.assertEqual(result.diagnostics, "coverage tool input is invalid")

    def test_secure_read_does_not_use_path_read_text_reopen_pattern(self):
        with mock.patch.object(Path, "read_text", side_effect=AssertionError("path reopen")):
            self.policy.validate_coverage_tool_inputs(self.base_binary, self.base_profdata)

    def test_cli_uses_raw_coverage_pairs_with_no_lcov_or_threshold_args(self):
        bad = subprocess.run(
            [
                "python3",
                str(POLICY_PATH),
                "--base-coverage-binary",
                str(self.base_binary),
                "--base-profdata",
                str(self.base_profdata),
                "--head-coverage-binary",
                str(self.head_binary),
                "--head-profdata",
                str(self.head_profdata),
                "--base-repository-root",
                str(self.base_repo),
                "--head-repository-root",
                str(self.head_repo),
                "--expected-base-sha",
                self.base_sha,
                "--expected-head-sha",
                self.head_sha,
                "--base-lcov",
                "forged.lcov",
                "--minimum",
                "1",
            ],
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        self.assertEqual(bad.returncode, 2)
        self.assertIn("unrecognized arguments", bad.stderr)


if __name__ == "__main__":
    unittest.main()
