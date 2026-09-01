import importlib.util
import io
import os
from pathlib import Path
import math
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
QUALITY_PATH = REPO_ROOT / "scripts" / "ci" / "quality.py"
FULL_SHA = "0123456789abcdef0123456789abcdef01234567"
BASE_SHA = "89abcdef0123456789abcdef0123456789abcdef"
OTHER_SHA = "fedcba9876543210fedcba9876543210fedcba98"


def load_quality():
    spec = importlib.util.spec_from_file_location("quality", QUALITY_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load quality driver")
    module = importlib.util.module_from_spec(spec)
    sys.modules["quality"] = module
    spec.loader.exec_module(module)
    return module


def write_executable(path: Path, source: str) -> None:
    path.write_text(source, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def init_repo(path: Path) -> str:
    subprocess.run(
        ["git", "init"],
        cwd=path,
        check=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    subprocess.run(
        ["git", "config", "user.email", "automation@example.com"],
        cwd=path,
        check=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    subprocess.run(
        ["git", "config", "user.name", "Automation Example"],
        cwd=path,
        check=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    (path / "README.md").write_text("synthetic\n", encoding="utf-8")
    subprocess.run(
        ["git", "add", "README.md"],
        cwd=path,
        check=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    subprocess.run(
        ["git", "commit", "-m", "test: seed synthetic repo"],
        cwd=path,
        check=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    completed = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=path,
        check=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return completed.stdout.strip()


class QualityDriverTests(unittest.TestCase):
    def setUp(self) -> None:
        self.quality = load_quality()

    def test_registry_is_immutable_ordered_and_mode_scoped(self) -> None:
        names = tuple(stage.name for stage in self.quality.STAGES)

        self.assertEqual(
            names,
            (
                "swiftly-build",
                "swiftly-test",
                "clt-build",
                "bats-local",
                "hosted-build",
                "hosted-test",
            ),
        )
        self.assertEqual(
            self.quality.stage_names_for_mode(self.quality.Mode.LOCAL),
            names[:4],
        )
        self.assertEqual(
            self.quality.stage_names_for_mode(self.quality.Mode.HOSTED),
            names[4:],
        )
        with self.assertRaises(Exception):
            self.quality.STAGES[0].name = "mutated"

    def test_registry_validation_rejects_duplicate_zero_and_nonfinite(self) -> None:
        valid = self.quality.STAGES[0]
        duplicate = (
            valid,
            self.quality.Stage(
                valid.name,
                valid.modes,
                valid.command,
                valid.timeout,
                valid.grace,
            ),
        )
        zero_timeout = (
            self.quality.Stage(
                "zero-timeout",
                valid.modes,
                valid.command,
                0,
                valid.grace,
            ),
        )
        nonfinite_grace = (
            self.quality.Stage(
                "nonfinite-grace",
                valid.modes,
                valid.command,
                valid.timeout,
                math.inf,
            ),
        )

        for stages in (duplicate, zero_timeout, nonfinite_grace):
            with self.subTest(stages=stages):
                with self.assertRaises(self.quality.PolicyError):
                    self.quality.validate_stage_registry(stages)

    def test_default_local_and_hosted_stage_order(self) -> None:
        self.assertEqual(
            self.quality.parse_request(["--mode", "local"]).stages,
            ("swiftly-build", "swiftly-test", "clt-build", "bats-local"),
        )
        self.assertEqual(
            self.quality.parse_request(
                [
                    "--mode",
                    "hosted",
                    "--hosted-context",
                    "trusted-ref",
                    "--candidate-sha",
                    FULL_SHA,
                ]
            ).stages,
            ("hosted-build", "hosted-test"),
        )

    def test_hosted_context_is_required_for_hosted_runs_and_rejected_for_local(self) -> None:
        self.assertEqual(
            self.quality.run_quality(
                ["--mode", "hosted", "--candidate-sha", FULL_SHA],
                git_validator=lambda request: None,
            ).status,
            2,
        )
        self.assertEqual(
            self.quality.run_quality(
                ["--mode", "local", "--hosted-context", "trusted-ref"],
                git_validator=lambda request: None,
            ).status,
            2,
        )
        self.assertEqual(
            self.quality.run_quality(
                ["--mode", "hosted", "--hosted-context", "pull-request", "--list-stages"],
                git_validator=lambda request: None,
                stdout=list,
            ).status,
            0,
        )

    def test_list_stages_executes_nothing(self) -> None:
        calls = []

        result = self.quality.run_quality(
            ["--mode", "local", "--list-stages"],
            runner=lambda *args, **kwargs: calls.append(args),
            stdout=list,
        )

        self.assertEqual(result.status, 0)
        self.assertEqual(calls, [])
        self.assertEqual(
            result.stdout,
            ("swiftly-build", "swiftly-test", "clt-build", "bats-local"),
        )

    def test_cli_list_stages_prints_names_without_checkout_validation(self) -> None:
        completed = subprocess.run(
            ["python3", str(QUALITY_PATH), "--mode", "local", "--list-stages"],
            cwd="/",
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(
            completed.stdout.splitlines(),
            ["swiftly-build", "swiftly-test", "clt-build", "bats-local"],
        )
        self.assertEqual(completed.stderr, "")

    def test_stage_subset_runs_in_registry_order_and_fail_fast(self) -> None:
        calls = []

        def runner(stage, command, cwd, timeout, grace, env):
            calls.append((stage.name, command, cwd))
            if stage.name == "clt-build":
                return self.quality.CommandResult(status=7)
            return self.quality.CommandResult(status=0)

        result = self.quality.run_quality(
            [
                "--mode",
                "local",
                "--stage",
                "bats-local",
                "--stage",
                "swiftly-build",
                "--stage",
                "clt-build",
            ],
            runner=runner,
            git_validator=lambda request: None,
        )

        self.assertEqual(result.status, 7)
        self.assertEqual(
            [name for name, _, _ in calls],
            ["swiftly-build", "clt-build"],
        )

    def test_cli_rejects_unknown_duplicate_and_incompatible_stages(self) -> None:
        for argv in (
            ["--mode", "local", "--stage", "missing"],
            ["--mode", "local", "--stage", "swiftly-build", "--stage", "swiftly-build"],
            [
                "--mode",
                "hosted",
                "--hosted-context",
                "trusted-ref",
                "--candidate-sha",
                FULL_SHA,
                "--stage",
                "bats-local",
            ],
        ):
            with self.subTest(argv=argv):
                result = self.quality.run_quality(argv, git_validator=lambda request: None)
                self.assertEqual(result.status, 2)

    def test_sha_validation_is_full_lowercase_hex_only(self) -> None:
        for bad_sha in (
            "1234",
            FULL_SHA.upper(),
            "g" * 40,
            f"{FULL_SHA}00",
        ):
            with self.subTest(bad_sha=bad_sha):
                result = self.quality.run_quality(
                    [
                        "--mode",
                        "hosted",
                        "--hosted-context",
                        "trusted-ref",
                        "--candidate-sha",
                        bad_sha,
                    ],
                    git_validator=lambda request: None,
                )
                self.assertEqual(result.status, 2)

    def test_hosted_requires_candidate_sha(self) -> None:
        result = self.quality.run_quality(
            ["--mode", "hosted", "--hosted-context", "trusted-ref"],
            git_validator=lambda request: None,
        )

        self.assertEqual(result.status, 2)

    def test_pull_request_context_requires_separate_candidate_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            checkout = Path(temporary_directory)
            request = self.quality.QualityRequest(
                mode=self.quality.Mode.HOSTED,
                hosted_context=self.quality.HostedContext.PULL_REQUEST,
                policy_root=checkout,
                candidate_root=checkout,
                candidate_sha=FULL_SHA,
                base_sha=FULL_SHA,
                stages=(),
            )

            def git(args, cwd):
                if args == ("rev-parse", "--show-toplevel"):
                    return str(checkout)
                if args == ("rev-parse", "HEAD"):
                    return FULL_SHA
                if args == ("status", "--porcelain"):
                    return ""
                raise AssertionError(args)

            with self.assertRaisesRegex(self.quality.PolicyError, "separate"):
                self.quality.validate_git_checkout(request, git=git)

    def test_hosted_separate_candidate_requires_matching_base_sha(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            candidate = Path(temporary_directory) / "candidate"
            candidate.mkdir()
            policy = Path(temporary_directory) / "policy"
            policy.mkdir()

            request = self.quality.QualityRequest(
                mode=self.quality.Mode.HOSTED,
                hosted_context=self.quality.HostedContext.PULL_REQUEST,
                policy_root=policy,
                candidate_root=candidate,
                candidate_sha=FULL_SHA,
                base_sha=None,
                stages=(),
            )
            with self.assertRaisesRegex(self.quality.PolicyError, "base-sha"):
                def git_missing_base(args, cwd):
                    if args == ("rev-parse", "--show-toplevel"):
                        return str(candidate)
                    if args == ("rev-parse", "HEAD"):
                        return FULL_SHA
                    if args == ("status", "--porcelain"):
                        return ""
                    raise AssertionError(args)

                self.quality.validate_git_checkout(
                    request,
                    git=git_missing_base,
                )

            request = self.quality.QualityRequest(
                mode=self.quality.Mode.HOSTED,
                hosted_context=self.quality.HostedContext.PULL_REQUEST,
                policy_root=policy,
                candidate_root=candidate,
                candidate_sha=FULL_SHA,
                base_sha=BASE_SHA,
                stages=(),
            )
            with self.assertRaisesRegex(self.quality.PolicyError, "trusted"):
                def git_mismatch_base(args, cwd):
                    if args == ("rev-parse", "--show-toplevel"):
                        return str(candidate) if cwd.resolve() == candidate.resolve() else str(policy)
                    if args == ("rev-parse", "HEAD"):
                        return FULL_SHA
                    if args == ("status", "--porcelain"):
                        return ""
                    raise AssertionError(args)

                self.quality.validate_git_checkout(
                    request,
                    git=git_mismatch_base,
                )

    def test_trusted_ref_context_rejects_base_sha_binding_and_separate_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            policy = root / "policy"
            candidate = root / "candidate"
            policy.mkdir()
            candidate.mkdir()
            same_root_request = self.quality.QualityRequest(
                mode=self.quality.Mode.HOSTED,
                hosted_context=self.quality.HostedContext.TRUSTED_REF,
                policy_root=policy,
                candidate_root=policy,
                candidate_sha=FULL_SHA,
                base_sha=FULL_SHA,
                stages=(),
            )
            separate_request = self.quality.QualityRequest(
                mode=self.quality.Mode.HOSTED,
                hosted_context=self.quality.HostedContext.TRUSTED_REF,
                policy_root=policy,
                candidate_root=candidate,
                candidate_sha=FULL_SHA,
                base_sha=None,
                stages=(),
            )

            def git(args, cwd):
                if args == ("rev-parse", "--show-toplevel"):
                    return str(cwd.resolve())
                if args == ("rev-parse", "HEAD"):
                    return FULL_SHA
                if args == ("status", "--porcelain"):
                    return ""
                raise AssertionError(args)

            with self.assertRaisesRegex(self.quality.PolicyError, "must not use --base-sha"):
                self.quality.validate_git_checkout(same_root_request, git=git)
            with self.assertRaisesRegex(self.quality.PolicyError, "same checkout"):
                self.quality.validate_git_checkout(separate_request, git=git)

    def test_pull_request_context_accepts_matching_separate_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            policy = root / "policy"
            candidate = root / "candidate"
            policy.mkdir()
            candidate.mkdir()
            request = self.quality.QualityRequest(
                mode=self.quality.Mode.HOSTED,
                hosted_context=self.quality.HostedContext.PULL_REQUEST,
                policy_root=policy,
                candidate_root=candidate,
                candidate_sha=FULL_SHA,
                base_sha=BASE_SHA,
                stages=(),
            )

            def git(args, cwd):
                resolved = cwd.resolve()
                if args == ("rev-parse", "--show-toplevel"):
                    return str(resolved)
                if args == ("rev-parse", "HEAD"):
                    return FULL_SHA if resolved == candidate.resolve() else BASE_SHA
                if args == ("status", "--porcelain"):
                    return ""
                raise AssertionError(args)

            self.quality.validate_git_checkout(request, git=git)

    def test_base_sha_must_match_policy_head_even_for_same_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            checkout = Path(temporary_directory)
            request = self.quality.QualityRequest(
                mode=self.quality.Mode.HOSTED,
                hosted_context=self.quality.HostedContext.TRUSTED_REF,
                policy_root=checkout,
                candidate_root=checkout,
                candidate_sha=FULL_SHA,
                base_sha=BASE_SHA,
                stages=(),
            )

            def git(args, cwd):
                if args == ("rev-parse", "--show-toplevel"):
                    return str(checkout)
                if args == ("rev-parse", "HEAD"):
                    return FULL_SHA
                if args == ("status", "--porcelain"):
                    return ""
                raise AssertionError(args)

            with self.assertRaisesRegex(self.quality.PolicyError, "base-sha"):
                self.quality.validate_git_checkout(request, git=git)

    def test_hosted_rejects_dirty_trusted_policy_checkout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            policy = root / "policy"
            candidate = root / "candidate"
            policy.mkdir()
            candidate.mkdir()
            request = self.quality.QualityRequest(
                mode=self.quality.Mode.HOSTED,
                hosted_context=self.quality.HostedContext.PULL_REQUEST,
                policy_root=policy,
                candidate_root=candidate,
                candidate_sha=FULL_SHA,
                base_sha=BASE_SHA,
                stages=(),
            )

            def git(args, cwd):
                resolved = cwd.resolve()
                if args == ("rev-parse", "--show-toplevel"):
                    return str(resolved)
                if args == ("rev-parse", "HEAD"):
                    return FULL_SHA if resolved == candidate.resolve() else BASE_SHA
                if args == ("status", "--porcelain"):
                    return "" if resolved == candidate.resolve() else " M quality.py\n"
                raise AssertionError(args)

            with self.assertRaisesRegex(self.quality.PolicyError, "trusted.*clean"):
                self.quality.validate_git_checkout(request, git=git)

    def test_hosted_separate_candidate_accepts_matching_clean_policy_checkout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            policy = root / "policy"
            candidate = root / "candidate"
            policy.mkdir()
            candidate.mkdir()
            request = self.quality.QualityRequest(
                mode=self.quality.Mode.HOSTED,
                hosted_context=self.quality.HostedContext.PULL_REQUEST,
                policy_root=policy,
                candidate_root=candidate,
                candidate_sha=FULL_SHA,
                base_sha=BASE_SHA,
                stages=(),
            )

            def git(args, cwd):
                resolved = cwd.resolve()
                if args == ("rev-parse", "--show-toplevel"):
                    return str(resolved)
                if args == ("rev-parse", "HEAD"):
                    return FULL_SHA if resolved == candidate.resolve() else BASE_SHA
                if args == ("status", "--porcelain"):
                    return ""
                raise AssertionError(args)

            self.quality.validate_git_checkout(request, git=git)

    def test_real_synthetic_git_repo_with_spaces_and_metacharacters_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            checkout = Path(temporary_directory) / "repo with spaces [ok]"
            checkout.mkdir()
            sha = init_repo(checkout)
            request = self.quality.QualityRequest(
                mode=self.quality.Mode.HOSTED,
                hosted_context=self.quality.HostedContext.TRUSTED_REF,
                policy_root=checkout,
                candidate_root=checkout,
                candidate_sha=sha,
                base_sha=None,
                stages=(),
            )

            self.quality.validate_git_checkout(request)

    def test_nonrepo_candidate_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            checkout = Path(temporary_directory)
            request = self.quality.QualityRequest(
                mode=self.quality.Mode.LOCAL,
                hosted_context=None,
                policy_root=checkout,
                candidate_root=checkout,
                candidate_sha=None,
                base_sha=None,
                stages=(),
            )

            with self.assertRaisesRegex(self.quality.PolicyError, "git"):
                self.quality.validate_git_checkout(request)

    def test_checkout_validation_rejects_dirty_short_uppercase_mismatch_and_nested(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            checkout = root / "repo"
            nested = checkout / "nested"
            nested.mkdir(parents=True)

            base_request = self.quality.QualityRequest(
                mode=self.quality.Mode.HOSTED,
                hosted_context=self.quality.HostedContext.TRUSTED_REF,
                policy_root=checkout,
                candidate_root=checkout,
                candidate_sha=FULL_SHA,
                base_sha=None,
                stages=(),
            )

            def make_git(show_toplevel=checkout, head=FULL_SHA, status=""):
                def git(args, cwd):
                    if args == ("rev-parse", "--show-toplevel"):
                        return str(show_toplevel)
                    if args == ("rev-parse", "HEAD"):
                        return head
                    if args == ("status", "--porcelain"):
                        return status
                    raise AssertionError(args)

                return git

            bad_cases = (
                (base_request, make_git(status=" M file\n"), "clean"),
                (base_request, make_git(head=FULL_SHA[:12]), "full"),
                (base_request, make_git(head=FULL_SHA.upper()), "full"),
                (base_request, make_git(head=BASE_SHA), "candidate"),
                (
                    self.quality.QualityRequest(
                        mode=self.quality.Mode.LOCAL,
                        hosted_context=None,
                        policy_root=checkout,
                        candidate_root=nested,
                        candidate_sha=None,
                        base_sha=None,
                        stages=(),
                    ),
                    make_git(show_toplevel=checkout),
                    "checkout root",
                ),
            )
            for request, git, expected in bad_cases:
                with self.subTest(expected=expected):
                    with self.assertRaisesRegex(self.quality.PolicyError, expected):
                        self.quality.validate_git_checkout(request, git=git)

    def test_local_checkout_may_be_dirty(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            checkout = Path(temporary_directory)
            request = self.quality.QualityRequest(
                mode=self.quality.Mode.LOCAL,
                hosted_context=None,
                policy_root=checkout,
                candidate_root=checkout,
                candidate_sha=None,
                base_sha=None,
                stages=(),
            )

            def git(args, cwd):
                if args == ("rev-parse", "--show-toplevel"):
                    return str(checkout)
                if args == ("rev-parse", "HEAD"):
                    return FULL_SHA
                if args == ("status", "--porcelain"):
                    return " M file\n"
                raise AssertionError(args)

            self.quality.validate_git_checkout(request, git=git)

    def test_stage_commands_are_shell_free_and_deterministic(self) -> None:
        stages = {stage.name: stage for stage in self.quality.STAGES}
        with tempfile.TemporaryDirectory() as temporary_directory:
            xunit_dir = Path(temporary_directory)
            swiftly_build = stages["swiftly-build"].command(REPO_ROOT, xunit_dir)
            swiftly_test = stages["swiftly-test"].command(REPO_ROOT, xunit_dir)
            clt_build = stages["clt-build"].command(REPO_ROOT, xunit_dir)
            bats_local = stages["bats-local"].command(REPO_ROOT, xunit_dir)

        self.assertEqual(swiftly_build[0], str(Path.home() / ".swiftly" / "bin" / "swift"))
        self.assertEqual(swiftly_build[1:], ("build", "--scratch-path", ".build-swiftly", "--disable-automatic-resolution"))
        self.assertEqual(swiftly_test[:5], (str(Path.home() / ".swiftly" / "bin" / "swift"), "test", "--scratch-path", ".build-swiftly", "--disable-automatic-resolution"))
        self.assertIn("--xunit-output", swiftly_test)
        self.assertEqual(clt_build, ("/usr/bin/swift", "build", "--disable-automatic-resolution"))
        self.assertEqual(bats_local[:3], ("/usr/bin/env", "PATH=/usr/bin:/bin:/usr/sbin:/sbin:" + os.environ.get("PATH", ""), "bats"))
        self.assertEqual(bats_local[-2:], ("-r", "bats/"))
        for command in (swiftly_build, swiftly_test, clt_build, bats_local):
            self.assertIsInstance(command, tuple)
            self.assertNotIn("&&", command)

    def test_git_checks_use_exact_usr_bin_git(self) -> None:
        calls = []

        def run(command, **kwargs):
            calls.append(command)

            class Completed:
                returncode = 0
                stdout = "/tmp/repo\n"
                stderr = ""

            return Completed()

        original = self.quality.subprocess.run
        try:
            self.quality.subprocess.run = run
            self.quality.git_output(("rev-parse", "--show-toplevel"), Path("/tmp/repo"))
        finally:
            self.quality.subprocess.run = original

        self.assertEqual(calls[0][0], "/usr/bin/git")

    def test_runner_does_not_mutate_parent_environment(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            script = Path(temporary_directory) / "envcheck.py"
            out = Path(temporary_directory) / "out.txt"
            write_executable(
                script,
                "#!/usr/bin/env python3\n"
                "import os, pathlib\n"
                f"pathlib.Path({str(out)!r}).write_text(os.environ.get('QUALITY_SENTINEL', ''), encoding='utf-8')\n",
            )
            os.environ["QUALITY_SENTINEL"] = "parent"
            env = os.environ.copy()
            env["QUALITY_SENTINEL"] = "child"
            try:
                result = self.quality.run_command(
                    ("python3", str(script)),
                    cwd=Path(temporary_directory),
                    timeout=5,
                    grace=1,
                    env=env,
                )
            finally:
                os.environ.pop("QUALITY_SENTINEL", None)

            self.assertEqual(result.status, 0)
            self.assertEqual(out.read_text(encoding="utf-8"), "child")

    def test_bounded_runner_maps_exit_signal_spawn_and_timeout_statuses(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            exit_script = root / "exit.py"
            term_script = root / "term.py"
            sleep_script = root / "sleep.py"
            write_executable(exit_script, "#!/usr/bin/env python3\nimport sys\nsys.exit(17)\n")
            write_executable(
                term_script,
                "#!/usr/bin/env python3\nimport os, signal\nos.kill(os.getpid(), signal.SIGTERM)\n",
            )
            write_executable(
                sleep_script,
                "#!/usr/bin/env python3\nimport time\nwhile True: time.sleep(1)\n",
            )

            self.assertEqual(
                self.quality.run_command((str(exit_script),), root, 5, 0.1).status,
                17,
            )
            self.assertEqual(
                self.quality.run_command((str(term_script),), root, 5, 0.1).status,
                128 + signal.SIGTERM,
            )
            self.assertEqual(
                self.quality.run_command((str(root / "missing"),), root, 5, 0.1).status,
                125,
            )
            self.assertEqual(
                self.quality.run_command((str(sleep_script),), root, 0.1, 0.1).status,
                124,
            )

    def test_bounded_runner_stops_descendants_and_closes_stdin(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            marker = root / "marker"
            stdin_script = root / "stdin.py"
            stubborn_script = root / "stubborn.py"
            write_executable(
                stdin_script,
                "#!/usr/bin/env python3\nimport sys\nsys.exit(0 if sys.stdin.read() == '' else 44)\n",
            )
            write_executable(
                stubborn_script,
                textwrap.dedent(
                    f"""\
                    #!/usr/bin/env python3
                    import os, pathlib, signal, subprocess, sys, time
                    signal.signal(signal.SIGTERM, lambda *_args: None)
                    pathlib.Path({str(marker)!r}).write_text("started", encoding="utf-8")
                    subprocess.Popen([sys.executable, "-c", "import time; time.sleep(20)"])
                    while True:
                        time.sleep(1)
                    """
                ),
            )

            self.assertEqual(
                self.quality.run_command((str(stdin_script),), root, 5, 0.1).status,
                0,
            )
            self.assertEqual(
                self.quality.run_command((str(stubborn_script),), root, 0.5, 0.1).status,
                124,
            )
            self.assertTrue(marker.is_file())

    def test_normal_success_cleans_same_group_descendant_that_closed_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            pid_file = root / "descendant.pid"
            leader = root / "leader.py"
            write_executable(
                leader,
                textwrap.dedent(
                    f"""\
                    #!/usr/bin/env python3
                    import pathlib, subprocess, sys
                    child = subprocess.Popen(
                        [sys.executable, "-c", "import time; time.sleep(30)"],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                    pathlib.Path({str(pid_file)!r}).write_text(str(child.pid), encoding="utf-8")
                    """
                ),
            )

            result = self.quality.run_command((str(leader),), root, 5, 0.2)
            descendant_pid = int(pid_file.read_text(encoding="utf-8"))
            for _ in range(100):
                try:
                    os.kill(descendant_pid, 0)
                except ProcessLookupError:
                    break
                subprocess.run(
                    ["python3", "-c", "import time; time.sleep(0.02)"],
                    check=False,
                    stdin=subprocess.DEVNULL,
                )

            self.assertEqual(result.status, 0)
            with self.assertRaises(ProcessLookupError):
                os.kill(descendant_pid, 0)

    def test_kill_remaining_group_records_successful_sigkill_and_is_idempotent(self) -> None:
        calls = []

        class Process:
            pid = 12345

        original = self.quality.try_signal_group
        try:
            def fake_try_signal_group(process_group, sig):
                calls.append((process_group, sig))
                return True

            self.quality.try_signal_group = fake_try_signal_group
            sent = [False]
            self.quality.kill_remaining_group(Process(), sent)
            self.quality.kill_remaining_group(Process(), sent)
        finally:
            self.quality.try_signal_group = original

        self.assertEqual(calls, [(12345, signal.SIGKILL)])
        self.assertEqual(sent, [True])

    def test_external_cancellation_suppresses_output_kills_descendant_and_cleans_xunit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            marker = root / "ready"
            pid_file = root / "descendant.pid"
            xunit_record = root / "xunit-path.txt"
            harness = root / "harness.py"
            child = root / "child.py"
            write_executable(
                child,
                textwrap.dedent(
                    f"""\
                    #!/usr/bin/env python3
                    import pathlib, signal, subprocess, sys, time
                    signal.signal(signal.SIGTERM, lambda *_args: None)
                    descendant = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
                    pathlib.Path({str(pid_file)!r}).write_text(str(descendant.pid), encoding="utf-8")
                    pathlib.Path({str(marker)!r}).write_text("ready", encoding="utf-8")
                    print("buffered-output-that-must-not-escape", flush=True)
                    while True:
                        time.sleep(1)
                    """
                ),
            )
            write_executable(
                harness,
                textwrap.dedent(
                    f"""\
                    #!/usr/bin/env python3
                    import pathlib, sys
                    sys.path.insert(0, {str(QUALITY_PATH.parent)!r})
                    import quality

                    def runner(stage, command, cwd, timeout, grace, env):
                        xunit = pathlib.Path(command[command.index("--xunit-output") + 1])
                        xunit.write_text("<testsuite><testcase name='ok'/></testsuite>", encoding="utf-8")
                        pathlib.Path({str(xunit_record)!r}).write_text(str(xunit), encoding="utf-8")
                        return quality.run_command(({str(child)!r},), pathlib.Path({str(root)!r}), 30, 0.2, env)

                    raise SystemExit(quality.run_quality(
                        ["--mode", "local", "--stage", "swiftly-test"],
                        runner=runner,
                        git_validator=lambda request: None,
                    ).status)
                    """
                ),
            )
            process = subprocess.Popen(
                ["python3", str(harness)],
                cwd=root,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            )
            for _ in range(100):
                if marker.exists() and pid_file.exists() and xunit_record.exists():
                    break
                subprocess.run(
                    ["python3", "-c", "import time; time.sleep(0.02)"],
                    check=False,
                    stdin=subprocess.DEVNULL,
                )
            self.assertTrue(marker.exists())
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=5)
            descendant_pid = int(pid_file.read_text(encoding="utf-8"))
            for _ in range(100):
                try:
                    os.kill(descendant_pid, 0)
                except ProcessLookupError:
                    break
                subprocess.run(
                    ["python3", "-c", "import time; time.sleep(0.02)"],
                    check=False,
                    stdin=subprocess.DEVNULL,
                )

            self.assertEqual(process.returncode, 128 + signal.SIGTERM, stderr)
            self.assertNotIn("buffered-output-that-must-not-escape", stdout)
            self.assertFalse(Path(xunit_record.read_text(encoding="utf-8")).exists())
            with self.assertRaises(ProcessLookupError):
                os.kill(descendant_pid, 0)

    def test_cancellation_during_timeout_cleanup_wins_over_timeout_status(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            runner = root / "runner.py"
            child = root / "child.py"
            marker = root / "cleanup-started"
            write_executable(
                child,
                textwrap.dedent(
                    """\
                    #!/usr/bin/env python3
                    import signal, time
                    signal.signal(signal.SIGTERM, lambda *_args: None)
                    while True:
                        time.sleep(1)
                    """
                ),
            )
            write_executable(
                runner,
                textwrap.dedent(
                    f"""\
                    #!/usr/bin/env python3
                    import os, pathlib, signal, sys
                    sys.path.insert(0, {str(QUALITY_PATH.parent)!r})
                    import quality
                    original = quality.stop_process_group

                    def wrapped(process, grace, sent):
                        pathlib.Path({str(marker)!r}).write_text("started", encoding="utf-8")
                        os.kill(os.getpid(), signal.SIGTERM)
                        return original(process, grace, sent)

                    quality.stop_process_group = wrapped
                    result = quality.run_command(({str(child)!r},), pathlib.Path({str(root)!r}), 0.05, 0.2)
                    raise SystemExit(result.status)
                    """
                ),
            )
            completed = subprocess.run(
                ["python3", str(runner)],
                cwd=root,
                check=False,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
                timeout=5,
            )

            self.assertTrue(marker.exists())
            self.assertEqual(completed.returncode, 128 + signal.SIGTERM)

    def test_xml_assertion_counts_only_non_skipped_testcases(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "results.xml"
            path.write_text(
                "<testsuite><testcase name='a &amp; b'/><testcase name='b'><skipped/></testcase></testsuite>",
                encoding="utf-8",
            )

            self.assertEqual(self.quality.assert_xunit_has_tests(path), 1)

    def test_xml_assertion_reads_opened_file_when_path_is_replaced_after_open(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            path = root / "results.xml"
            path.write_text(
                "<testsuite><testcase name='opened'/></testsuite>",
                encoding="utf-8",
            )

            def replace_path():
                replacement = root / "replacement.xml"
                replacement.write_text(
                    "<testsuite><testcase><skipped/></testcase></testsuite>",
                    encoding="utf-8",
                )
                os.replace(replacement, path)

            self.assertEqual(
                self.quality.assert_xunit_has_tests(path, after_open=replace_path),
                1,
            )

    def test_xml_assertion_rejects_empty_skipped_declarations_malformed_oversized_and_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            symlink_target = root / "target.xml"
            symlink_target.write_text("<testsuite><testcase/></testsuite>", encoding="utf-8")
            symlink_path = root / "symlink.xml"
            symlink_path.symlink_to(symlink_target)
            cases = {
                "missing.xml": None,
                "empty.xml": "",
                "skipped.xml": "<testsuite><testcase><skipped/></testcase></testsuite>",
                "doctype.xml": "<!DOCTYPE testsuite><testsuite><testcase/></testsuite>",
                "late-doctype.xml": "<testsuite><testcase/></testsuite><!-- filler --><!DocType late>",
                "entity.xml": "<testsuite><!ENTITY xxe SYSTEM 'file:///tmp/nope'><testcase/></testsuite>",
                "malformed.xml": "<testsuite><testcase></testsuite>",
                "oversized.xml": "<testsuite>" + (" " * (self.quality.MAX_XUNIT_BYTES + 1)) + "</testsuite>",
                "symlink.xml": None,
            }
            for name, contents in cases.items():
                path = root / name
                if contents is not None:
                    path.write_text(contents, encoding="utf-8")
                with self.subTest(name=name):
                    with self.assertRaises(self.quality.AssertionFailure):
                        self.quality.assert_xunit_has_tests(path)

    def test_orchestration_checks_swift_test_xml_and_cleans_tempdir(self) -> None:
        seen_paths = []

        def runner(stage, command, cwd, timeout, grace, env):
            if stage.name == "swiftly-test":
                xunit_path = Path(command[command.index("--xunit-output") + 1])
                seen_paths.append(xunit_path)
                xunit_path.write_text("<testsuite><testcase name='ok'/></testsuite>", encoding="utf-8")
            return self.quality.CommandResult(status=0)

        result = self.quality.run_quality(
            ["--mode", "local", "--stage", "swiftly-test"],
            runner=runner,
            git_validator=lambda request: None,
        )

        self.assertEqual(result.status, 0)
        self.assertEqual(len(seen_paths), 1)
        self.assertFalse(seen_paths[0].exists())

    def test_orchestration_fails_when_successful_swift_test_missing_xunit(self) -> None:
        seen_paths = []

        def runner(stage, command, cwd, timeout, grace, env):
            if stage.name == "swiftly-test":
                seen_paths.append(Path(command[command.index("--xunit-output") + 1]))
            return self.quality.CommandResult(status=0)

        result = self.quality.run_quality(
            ["--mode", "local", "--stage", "swiftly-test"],
            runner=runner,
            git_validator=lambda request: None,
        )

        self.assertEqual(result.status, 1)
        self.assertEqual(len(seen_paths), 1)
        self.assertFalse(seen_paths[0].exists())

    def test_orchestration_child_nonzero_skips_xunit_assertion_and_cleans_tempdir(self) -> None:
        seen_paths = []

        def runner(stage, command, cwd, timeout, grace, env):
            xunit_path = Path(command[command.index("--xunit-output") + 1])
            seen_paths.append(xunit_path)
            xunit_path.write_text("<testsuite><testcase/></testsuite>", encoding="utf-8")
            return self.quality.CommandResult(status=42)

        result = self.quality.run_quality(
            ["--mode", "local", "--stage", "swiftly-test"],
            runner=runner,
            git_validator=lambda request: None,
        )

        self.assertEqual(result.status, 42)
        self.assertEqual(len(seen_paths), 1)
        self.assertFalse(seen_paths[0].exists())

    def test_orchestration_timeout_status_cleans_tempdir(self) -> None:
        seen_paths = []

        def runner(stage, command, cwd, timeout, grace, env):
            xunit_path = Path(command[command.index("--xunit-output") + 1])
            seen_paths.append(xunit_path)
            xunit_path.write_text("<testsuite><testcase/></testsuite>", encoding="utf-8")
            return self.quality.CommandResult(status=124)

        result = self.quality.run_quality(
            ["--mode", "local", "--stage", "swiftly-test"],
            runner=runner,
            git_validator=lambda request: None,
        )

        self.assertEqual(result.status, 124)
        self.assertEqual(len(seen_paths), 1)
        self.assertFalse(seen_paths[0].exists())

    def test_timeout_suppresses_buffered_output_but_regular_failure_keeps_it(self) -> None:
        cases = (
            (self.quality.CommandResult(status=124, output=b"timeout payload"), b""),
            (self.quality.CommandResult(status=42, output=b"failure payload"), b"failure payload"),
        )
        for command_result, expected_stdout in cases:
            with self.subTest(status=command_result.status):
                completed_stdout = io.BytesIO()
                original_stdout = sys.stdout

                class Stdout:
                    buffer = completed_stdout

                def runner(stage, command, cwd, timeout, grace, env):
                    return command_result

                try:
                    sys.stdout = Stdout()
                    result = self.quality.run_quality(
                        ["--mode", "local", "--stage", "swiftly-build"],
                        runner=runner,
                        git_validator=lambda request: None,
                    )
                finally:
                    sys.stdout = original_stdout

                self.assertEqual(result.status, command_result.status)
                self.assertEqual(completed_stdout.getvalue(), expected_stdout)


if __name__ == "__main__":
    unittest.main()
