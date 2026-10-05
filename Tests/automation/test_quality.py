import errno
import gc
import importlib.util
import io
import os
from pathlib import Path
import plistlib
import math
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import textwrap
import types
import unittest
from unittest import mock
import weakref


REPO_ROOT = Path(__file__).resolve().parents[2]
QUALITY_PATH = REPO_ROOT / "scripts" / "ci" / "quality.py"
CI_WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "ci.yml"
FULL_SHA = "0123456789abcdef0123456789abcdef01234567"
BASE_SHA = "89abcdef0123456789abcdef0123456789abcdef"
OTHER_SHA = "fedcba9876543210fedcba9876543210fedcba98"
TRUSTED_HOSTED_ENVIRONMENT = {
    "GITHUB_ACTIONS": "true",
    "RUNNER_OS": "macOS",
    "RUNNER_ENVIRONMENT": "github-hosted",
}


def _force_remove(path) -> None:
    """Remove a test tree even where a test left directories without owner access."""
    if not os.path.lexists(path):
        return
    if os.path.islink(path):
        os.unlink(path)
        return
    for directory, subdirectories, _files in os.walk(path):
        for name in subdirectories:
            candidate = os.path.join(directory, name)
            if not os.path.islink(candidate):
                os.chmod(candidate, 0o700)
    os.chmod(path, 0o700)
    shutil.rmtree(path)


def load_quality():
    spec = importlib.util.spec_from_file_location("quality", QUALITY_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load quality driver")
    module = importlib.util.module_from_spec(spec)
    sys.modules["quality"] = module
    spec.loader.exec_module(module)
    return module


def workflow_job(source: str, name: str) -> str:
    match = re.search(
        rf"(?ms)^  {re.escape(name)}:\n(?P<body>.*?)(?=^  [a-z0-9-]+:\n|\Z)",
        source,
    )
    if match is None:
        raise AssertionError(f"workflow job is missing: {name}")
    return match.group("body")


def workflow_named_step(job: str, name: str) -> str:
    match = re.search(
        rf"(?ms)^      - name: {re.escape(name)}\n(?P<body>.*?)(?=^      - (?:name:|uses:)|\Z)",
        job,
    )
    if match is None:
        raise AssertionError(f"workflow step is missing: {name}")
    return match.group("body")


def assert_pinned_bats_install(testcase: unittest.TestCase, install_step: str) -> None:
    testcase.assertIn(
        "sha512-giSYKGTOcPZyJDbfbTtzAedLcNWdjCLbXYU3/MwPnjyvDXzu6Dgw8d2M+8jHhZXSmsCMSQqCp+YBsJ603UO4vQ==",
        install_step,
    )
    testcase.assertIn(
        'tarball="$RUNNER_TEMP/bats-1.13.0.tgz"',
        install_step,
    )
    testcase.assertIn(
        'npm pack bats@1.13.0 --pack-destination "$RUNNER_TEMP" --ignore-scripts >/dev/null',
        install_step,
    )
    testcase.assertIn(
        '[ -f "$tarball" ] || { echo "Pinned Bats tarball was not downloaded."; exit 1; }',
        install_step,
    )
    testcase.assertIn(
        'ACTUAL_INTEGRITY="sha512-$(openssl dgst -sha512 -binary "$tarball" | openssl base64 -A)"',
        install_step,
    )
    testcase.assertIn(
        'if [ "$ACTUAL_INTEGRITY" != "$BATS_INTEGRITY" ]; then',
        install_step,
    )
    testcase.assertIn(
        "npm install --ignore-scripts --no-audit --no-fund \"$tarball\"",
        install_step,
    )
    testcase.assertIn(
        'bats_bin="$RUNNER_TEMP/node_modules/bats/bin"',
        install_step,
    )
    testcase.assertIn(
        '[ -x "$bats_bin/bats" ] || { echo "Pinned Bats executable missing after install."; exit 1; }',
        install_step,
    )
    testcase.assertNotIn("GITHUB_PATH", install_step)
    testcase.assertIn(
        'echo "BATS_EXECUTABLE=$bats_bin/bats" >> "$GITHUB_ENV"',
        install_step,
    )
    testcase.assertIn(
        '[ "$("$bats_bin/bats" --version)" = "Bats 1.13.0" ]',
        install_step,
    )
    testcase.assertNotIn("brew install", install_step)
    testcase.assertNotIn("sudo", install_step)
    testcase.assertNotIn("--global", install_step)
    for setting in (
        "NPM_CONFIG_USERCONFIG: /dev/null",
        "NPM_CONFIG_REGISTRY: https://registry.npmjs.org/",
        'NPM_CONFIG_IGNORE_SCRIPTS: "true"',
    ):
        testcase.assertIn(setting, install_step)
    testcase.assertNotRegex(
        install_step,
        r"(?m)^          NPM_CONFIG_GLOBALCONFIG:",
    )
    testcase.assertIn(
        'npm_global_config="$(mktemp "$RUNNER_TEMP/npm-globalrc.XXXXXX")"',
        install_step,
    )
    testcase.assertIn('chmod 400 "$npm_global_config"', install_step)
    testcase.assertIn("trap 'rm -f \"$npm_global_config\"' EXIT", install_step)
    testcase.assertIn(
        'export NPM_CONFIG_GLOBALCONFIG="$npm_global_config"',
        install_step,
    )
    ordered_markers = (
        'npm_global_config="$(mktemp "$RUNNER_TEMP/npm-globalrc.XXXXXX")"',
        'chmod 400 "$npm_global_config"',
        "trap 'rm -f \"$npm_global_config\"' EXIT",
        'export NPM_CONFIG_GLOBALCONFIG="$npm_global_config"',
        'cd "$RUNNER_TEMP"',
        'tarball="$RUNNER_TEMP/bats-1.13.0.tgz"',
        'npm pack bats@1.13.0 --pack-destination "$RUNNER_TEMP" --ignore-scripts >/dev/null',
        '[ -f "$tarball" ] || { echo "Pinned Bats tarball was not downloaded."; exit 1; }',
        'ACTUAL_INTEGRITY="sha512-$(openssl dgst -sha512 -binary "$tarball" | openssl base64 -A)"',
        'if [ "$ACTUAL_INTEGRITY" != "$BATS_INTEGRITY" ]; then',
        'npm install --ignore-scripts --no-audit --no-fund "$tarball"',
        'bats_bin="$RUNNER_TEMP/node_modules/bats/bin"',
        '[ -x "$bats_bin/bats" ] || { echo "Pinned Bats executable missing after install."; exit 1; }',
        'echo "BATS_EXECUTABLE=$bats_bin/bats" >> "$GITHUB_ENV"',
        '[ "$("$bats_bin/bats" --version)" = "Bats 1.13.0" ]',
    )
    marker_offsets = [install_step.index(marker) for marker in ordered_markers]
    testcase.assertEqual(marker_offsets, sorted(marker_offsets))
    testcase.assertIn('cd "$RUNNER_TEMP"', install_step)


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

    def hosted_request(self, stages):
        return self.quality.QualityRequest(
            mode=self.quality.Mode.HOSTED,
            hosted_context=self.quality.HostedContext.TRUSTED_REF,
            policy_root=REPO_ROOT,
            candidate_root=REPO_ROOT,
            candidate_sha=FULL_SHA,
            base_sha=None,
            stages=tuple(stages),
        )

    def test_docs_manual_freshness_runs_on_the_recorded_macos_image(self) -> None:
        # Every macOS hosted job runs on `macos-26` (design section 4.1, 2026-09-29 amendment);
        # the CI jobs are pinned below, and this pins the one macOS job in the Docs workflow.
        workflow = (REPO_ROOT / ".github" / "workflows" / "docs.yml").read_text(encoding="utf-8")
        self.assertIn("runs-on: macos-26", workflow_job(workflow, "manual-fresh"))

    def test_ci_runs_the_full_hosted_quality_gate_with_exact_sha_bindings(self) -> None:
        workflow = CI_WORKFLOW_PATH.read_text(encoding="utf-8")
        job = workflow_job(workflow, "build-test")
        bats_build_job = workflow_job(workflow, "hosted-bats-build")
        bats_job = workflow_job(workflow, "hosted-bats")

        self.assertIn("\n  pull_request:\n", workflow)
        self.assertNotIn("pull_request_target", workflow)
        self.assertRegex(workflow, r"(?m)^permissions:\n  contents: read$")
        for hosted_job in (job, bats_build_job, bats_job):
            self.assertIn("runs-on: macos-26", hosted_job)
            self.assertNotIn("self-hosted", hosted_job)
            self.assertNotRegex(hosted_job, r"\$\{\{\s*secrets\.")
            self.assertNotRegex(hosted_job, r"(?m)^    environment:")
            self.assertNotIn("bats/local", hosted_job)
            self.assertNotIn("--stage", hosted_job)
            self.assertEqual(
                hosted_job.count("--mode hosted"),
                2,
            )
        checkout = re.search(
            r"(?ms)^      - uses: actions/checkout@[0-9a-f]{40} # v[0-9.]+\n"
            r"        with:\n(?P<with>(?:          [^\n]+\n)+)",
            job,
        )
        self.assertIsNotNone(checkout)
        checkout_settings = checkout.group("with")
        self.assertIn("fetch-depth: 0", checkout_settings)
        self.assertIn("persist-credentials: false", checkout_settings)
        self.assertIn(
            "ref: ${{ github.event_name == 'pull_request' && github.event.pull_request.head.sha || github.sha }}",
            checkout_settings,
        )

        self.assertNotIn("Install pinned Bats", job)
        self.assertNotIn("Install pinned Bats", bats_build_job)
        self.assertIn("needs: hosted-bats-build", bats_job)
        assert_pinned_bats_install(self, workflow_named_step(bats_job, "Install pinned Bats"))

        policy_step = workflow_named_step(job, "Prepare trusted policy checkout")
        self.assertIn("worktree add --detach", policy_step)
        self.assertIn('"${{ github.event.pull_request.base.sha }}"', policy_step)
        self.assertIn('"$RUNNER_TEMP/trusted-policy"', policy_step)
        bats_build_policy_step = workflow_named_step(
            bats_build_job,
            "Prepare trusted policy checkout",
        )
        self.assertIn("worktree add --detach", bats_build_policy_step)
        self.assertIn('"${{ github.event.pull_request.base.sha }}"', bats_build_policy_step)
        self.assertIn('"$RUNNER_TEMP/trusted-policy"', bats_build_policy_step)
        bats_policy_step = workflow_named_step(bats_job, "Prepare trusted policy checkout")
        self.assertIn("worktree add --detach", bats_policy_step)
        self.assertIn('"${{ github.event.pull_request.base.sha }}"', bats_policy_step)
        self.assertIn('"$RUNNER_TEMP/trusted-policy"', bats_policy_step)

        bats_pull_request_build_step = workflow_named_step(
            bats_build_job,
            "Build candidate for hosted Bats (pull request)",
        )
        bats_pull_request_build_command = " ".join(
            line.strip().rstrip("\\") for line in bats_pull_request_build_step.splitlines()
        )
        for required in (
            'python3 "$RUNNER_TEMP/trusted-policy/scripts/ci/quality.py"',
            "--mode hosted",
            "--hosted-context pull-request",
            "--hosted-phase build",
            '--candidate-root "$GITHUB_WORKSPACE"',
            '--candidate-sha "${{ github.event.pull_request.head.sha }}"',
            '--base-sha "${{ github.event.pull_request.base.sha }}"',
        ):
            self.assertIn(required, bats_pull_request_build_command)

        bats_trusted_build_step = workflow_named_step(
            bats_build_job,
            "Build candidate for hosted Bats (trusted ref)",
        )
        bats_trusted_build_command = " ".join(
            line.strip().rstrip("\\") for line in bats_trusted_build_step.splitlines()
        )
        for required in (
            "python3 scripts/ci/quality.py",
            "--mode hosted",
            "--hosted-context trusted-ref",
            "--hosted-phase build",
            '--candidate-root "$GITHUB_WORKSPACE"',
            '--candidate-sha "${{ github.sha }}"',
        ):
            self.assertIn(required, bats_trusted_build_command)
        self.assertNotIn("--base-sha", bats_trusted_build_command)
        self.assertNotIn("--hosted-phase bats", bats_build_job)
        self.assertNotIn("--hosted-phase build", bats_job)
        self.assertIn(
            "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1",
            bats_build_job,
        )
        self.assertIn(
            "name: hosted-bats-apple-${{ github.run_id }}-${{ github.run_attempt }}",
            bats_build_job,
        )
        package_step = workflow_named_step(bats_build_job, "Package hosted Bats binary artifact")
        for required in (
            'artifact_dir="$RUNNER_TEMP/hosted-bats-artifact"',
            'binary_path="$(swift build --show-bin-path)/apple"',
            '[ -x "$binary_path" ] || { echo "Built apple binary is unavailable."; exit 1; }',
            'upstream_root="$(cd "$(dirname "$binary_path")/../.." && pwd -P)"',
            'upstream_matcher="$upstream_root/checkouts/swift-argument-parser/Sources/ArgumentParser/Utilities/Tree.swift"',
            '[ -f "$upstream_matcher" ] || { echo "Swift ArgumentParser matcher source is unavailable."; exit 1; }',
            'cp "$binary_path" "$artifact_dir/apple"',
            'chmod 755 "$artifact_dir/apple"',
            'mkdir -p "$artifact_dir/upstream-root/checkouts/swift-argument-parser/Sources/ArgumentParser/Utilities"',
            'cp "$upstream_matcher" "$artifact_dir/upstream-root/checkouts/swift-argument-parser/Sources/ArgumentParser/Utilities/Tree.swift"',
            '(cd "$artifact_dir" && shasum -a 256 apple upstream-root/checkouts/swift-argument-parser/Sources/ArgumentParser/Utilities/Tree.swift > apple.sha256)',
        ):
            self.assertIn(required, package_step)
        self.assertIn("path: ${{ runner.temp }}/hosted-bats-artifact/", bats_build_job)
        self.assertIn("if-no-files-found: error", bats_build_job)
        self.assertIn(
            "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1",
            bats_job,
        )
        self.assertIn(
            "name: hosted-bats-apple-${{ github.run_id }}-${{ github.run_attempt }}",
            bats_job,
        )
        install_artifact_step = workflow_named_step(
            bats_job,
            "Validate hosted Bats binary artifact",
        )
        for required in (
            'cd "$RUNNER_TEMP/hosted-bats-bin"',
            "shasum -a 256 -c apple.sha256",
            "chmod 755 apple",
            'echo "APPLE_CLI_TEST_BINARY=$RUNNER_TEMP/hosted-bats-bin/apple" >> "$GITHUB_ENV"',
            'echo "APPLE_CLI_UPSTREAM_ROOT=$RUNNER_TEMP/hosted-bats-bin/upstream-root" >> "$GITHUB_ENV"',
        ):
            self.assertIn(required, install_artifact_step)
        self.assertLess(
            bats_job.index("- name: Install pinned Bats"),
            bats_job.index("actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1"),
        )
        self.assertLess(
            bats_job.index("actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1"),
            bats_job.index("- name: Validate hosted Bats binary artifact"),
        )
        self.assertLess(
            bats_job.index("- name: Validate hosted Bats binary artifact"),
            bats_job.index("- name: Run hosted Bats quality (trusted ref)"),
        )

        pull_request_step = workflow_named_step(
            job,
            "Run hosted quality (pull request)",
        )
        pull_request_command = " ".join(
            line.strip().rstrip("\\") for line in pull_request_step.splitlines()
        )
        for required in (
            'python3 "$RUNNER_TEMP/trusted-policy/scripts/ci/quality.py"',
            "--mode hosted",
            "--hosted-context pull-request",
            "--hosted-phase swift",
            '--candidate-root "$GITHUB_WORKSPACE"',
            '--candidate-sha "${{ github.event.pull_request.head.sha }}"',
            '--base-sha "${{ github.event.pull_request.base.sha }}"',
        ):
            self.assertIn(required, pull_request_command)

        trusted_step = workflow_named_step(job, "Run hosted quality (trusted ref)")
        trusted_command = " ".join(
            line.strip().rstrip("\\") for line in trusted_step.splitlines()
        )
        for required in (
            "python3 scripts/ci/quality.py",
            "--mode hosted",
            "--hosted-context trusted-ref",
            "--hosted-phase swift",
            '--candidate-root "$GITHUB_WORKSPACE"',
            '--candidate-sha "${{ github.sha }}"',
        ):
            self.assertIn(required, trusted_command)
        self.assertNotIn("--base-sha", trusted_command)

        bats_pull_request_step = workflow_named_step(
            bats_job,
            "Run hosted Bats quality (pull request)",
        )
        bats_pull_request_command = " ".join(
            line.strip().rstrip("\\") for line in bats_pull_request_step.splitlines()
        )
        for required in (
            'python3 "$RUNNER_TEMP/trusted-policy/scripts/ci/quality.py"',
            "--mode hosted",
            "--hosted-context pull-request",
            "--hosted-phase bats",
            '--candidate-root "$GITHUB_WORKSPACE"',
            '--candidate-sha "${{ github.event.pull_request.head.sha }}"',
            '--base-sha "${{ github.event.pull_request.base.sha }}"',
        ):
            self.assertIn(required, bats_pull_request_command)

        bats_trusted_step = workflow_named_step(
            bats_job,
            "Run hosted Bats quality (trusted ref)",
        )
        bats_trusted_command = " ".join(
            line.strip().rstrip("\\") for line in bats_trusted_step.splitlines()
        )
        for required in (
            "python3 scripts/ci/quality.py",
            "--mode hosted",
            "--hosted-context trusted-ref",
            "--hosted-phase bats",
            '--candidate-root "$GITHUB_WORKSPACE"',
            '--candidate-sha "${{ github.sha }}"',
        ):
            self.assertIn(required, bats_trusted_command)
        self.assertNotIn("--base-sha", bats_trusted_command)

        aggregate_job = workflow_job(workflow, "quality-required")
        self.assertIn("name: quality / required", aggregate_job)
        self.assertIn("if: always()", aggregate_job)
        for dependency in (
            "- supply-chain-policy",
            "- build-test",
            "- hosted-bats-build",
            "- hosted-bats",
            "- commit-lint",
        ):
            self.assertIn(dependency, aggregate_job)
        for result in (
            'SUPPLY_CHAIN_POLICY_RESULT: ${{ needs.supply-chain-policy.result }}',
            'BUILD_TEST_RESULT: ${{ needs.build-test.result }}',
            'HOSTED_BATS_BUILD_RESULT: ${{ needs.hosted-bats-build.result }}',
            'HOSTED_BATS_RESULT: ${{ needs.hosted-bats.result }}',
            'COMMIT_LINT_RESULT: ${{ needs.commit-lint.result }}',
        ):
            self.assertIn(result, aggregate_job)
        for check in (
            '[ "$SUPPLY_CHAIN_POLICY_RESULT" = "success" ]',
            '[ "$BUILD_TEST_RESULT" = "success" ]',
            '[ "$HOSTED_BATS_BUILD_RESULT" = "success" ]',
            '[ "$HOSTED_BATS_RESULT" = "success" ]',
            '[ "$COMMIT_LINT_RESULT" = "success" ]',
        ):
            self.assertIn(check, aggregate_job)

    def test_only_hosted_bats_job_installs_pinned_bats(self) -> None:
        ci_workflow = CI_WORKFLOW_PATH.read_text(encoding="utf-8")

        ci_policy_job = workflow_job(ci_workflow, "supply-chain-policy")
        ci_bats_job = workflow_job(ci_workflow, "hosted-bats")

        assert_pinned_bats_install(
            self,
            workflow_named_step(ci_bats_job, "Install pinned Bats"),
        )
        self.assertNotIn("Install pinned Bats", ci_policy_job)
        self.assertNotIn("BATS_INTEGRITY", ci_policy_job)

    def test_ci_commit_lint_uses_full_checkout_without_authenticated_fetch(self) -> None:
        workflow = CI_WORKFLOW_PATH.read_text(encoding="utf-8")
        job = workflow_job(workflow, "commit-lint")

        self.assertIn("fetch-depth: 0", job)
        self.assertIn("persist-credentials: false", job)
        self.assertIn(
            "ref: ${{ github.event_name == 'pull_request' && github.event.pull_request.head.sha || github.sha }}",
            job,
        )
        self.assertNotIn("git fetch", job)
        self.assertIn(
            "BASE_SHA: ${{ github.event.pull_request.base.sha }}",
            job,
        )
        self.assertNotIn("BASE_REF:", job)
        self.assertIn('git log --format=%s "${BASE_SHA}..HEAD"', job)

    def test_registry_is_immutable_ordered_and_mode_scoped(self) -> None:
        names = tuple(stage.name for stage in self.quality.STAGES)

        self.assertEqual(
            names,
            (
                "bats-inventory",
                "swiftly-build",
                "swiftly-test",
                "clt-build",
                "bats-local",
                "hosted-build",
                "hosted-test",
                "bats-hosted",
            ),
        )
        self.assertEqual(
            self.quality.stage_names_for_mode(self.quality.Mode.LOCAL),
            names[:5],
        )
        self.assertEqual(
            self.quality.stage_names_for_mode(self.quality.Mode.HOSTED),
            ("bats-inventory", "hosted-build", "hosted-test", "bats-hosted"),
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
            ("bats-inventory", "swiftly-build", "swiftly-test", "clt-build", "bats-local"),
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
            ("bats-inventory", "hosted-build", "hosted-test", "bats-hosted"),
        )
        self.assertEqual(
            self.quality.parse_request(
                [
                    "--mode",
                    "hosted",
                    "--hosted-context",
                    "trusted-ref",
                    "--hosted-phase",
                    "build",
                    "--candidate-sha",
                    FULL_SHA,
                ]
            ).stages,
            ("hosted-build",),
        )
        self.assertEqual(
            self.quality.parse_request(
                [
                    "--mode",
                    "hosted",
                    "--hosted-context",
                    "trusted-ref",
                    "--hosted-phase",
                    "swift",
                    "--candidate-sha",
                    FULL_SHA,
                ]
            ).stages,
            ("hosted-build", "hosted-test"),
        )
        self.assertEqual(
            self.quality.parse_request(
                [
                    "--mode",
                    "hosted",
                    "--hosted-context",
                    "trusted-ref",
                    "--hosted-phase",
                    "bats",
                    "--candidate-sha",
                    FULL_SHA,
                ]
            ).stages,
            ("bats-inventory", "bats-hosted"),
        )

    def test_hosted_phase_union_matches_complete_hosted_registry(self) -> None:
        def hosted_phase(phase: str) -> tuple[str, ...]:
            return self.quality.parse_request(
                [
                    "--mode",
                    "hosted",
                    "--hosted-context",
                    "trusted-ref",
                    "--hosted-phase",
                    phase,
                    "--candidate-sha",
                    FULL_SHA,
                ]
            ).stages

        build = hosted_phase("build")
        swift = hosted_phase("swift")
        bats = hosted_phase("bats")
        all_hosted = hosted_phase("all")

        self.assertEqual(build, ("hosted-build",))
        self.assertEqual(swift, ("hosted-build", "hosted-test"))
        self.assertEqual(bats, ("bats-inventory", "bats-hosted"))
        self.assertEqual(all_hosted, self.quality.stage_names_for_mode(self.quality.Mode.HOSTED))
        self.assertEqual(set(swift).union(bats), set(all_hosted))
        self.assertEqual(
            set(swift).intersection(bats),
            set(),
            "published hosted phases must be disjoint so aggregate jobs cannot double-count a stage",
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
            ("bats-inventory", "swiftly-build", "swiftly-test", "clt-build", "bats-local"),
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
            ["bats-inventory", "swiftly-build", "swiftly-test", "clt-build", "bats-local"],
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

    def test_hosted_cli_rejects_all_stage_subsets(self) -> None:
        for stage in self.quality.stage_names_for_mode(self.quality.Mode.HOSTED):
            with self.subTest(stage=stage):
                result = self.quality.run_quality(
                    [
                        "--mode",
                        "hosted",
                        "--hosted-context",
                        "trusted-ref",
                        "--candidate-sha",
                        FULL_SHA,
                        "--stage",
                        stage,
                    ],
                    runner=lambda *args: self.quality.CommandResult(status=0),
                    git_validator=lambda request: None,
                )

                self.assertEqual(result.status, self.quality.POLICY_FAILURE_STATUS)

    def test_hosted_execution_refuses_untrusted_runner_contexts(self) -> None:
        contexts = (
            {},
            {
                "GITHUB_ACTIONS": "true",
                "RUNNER_OS": "Linux",
                "RUNNER_ENVIRONMENT": "github-hosted",
            },
            {
                "GITHUB_ACTIONS": "true",
                "RUNNER_OS": "macOS",
                "RUNNER_ENVIRONMENT": "self-hosted",
            },
        )
        for environment in contexts:
            calls = []
            with self.subTest(environment=environment), mock.patch.dict(
                self.quality.os.environ,
                environment,
                clear=True,
            ):
                result = self.quality.run_quality(
                    [
                        "--mode",
                        "hosted",
                        "--hosted-context",
                        "pull-request",
                        "--candidate-sha",
                        FULL_SHA,
                    ],
                    runner=lambda *args: calls.append(args),
                    git_validator=lambda request: None,
                )

            self.assertEqual(result.status, self.quality.POLICY_FAILURE_STATUS)
            self.assertEqual(calls, [])

    def test_hosted_execution_accepts_trusted_runner_and_isolates_all_candidate_stages(self) -> None:
        calls = []

        def runner(stage, command, cwd, timeout, grace, env):
            calls.append((stage.name, dict(env)))
            if stage.requires_xunit:
                xunit_path = self.quality.xunit_output_path(command)
                xunit_path.write_text(
                    "<testsuite><testcase name='synthetic'/></testsuite>",
                    encoding="utf-8",
                )
            return self.quality.CommandResult(status=0)

        inherited = {
            **TRUSTED_HOSTED_ENVIRONMENT,
            "HOME": "/synthetic/operator-home",
            "PATH": "/usr/bin:/bin",
        }
        with mock.patch.dict(self.quality.os.environ, inherited, clear=True):
            result = self.quality.run_quality(
                [
                    "--mode",
                    "hosted",
                    "--hosted-context",
                    "pull-request",
                    "--candidate-sha",
                    FULL_SHA,
                ],
                runner=runner,
                git_validator=lambda request: None,
            )

        self.assertEqual(result.status, 0)
        self.assertEqual(
            [name for name, _env in calls],
            ["bats-inventory", "hosted-build", "hosted-test", "bats-inventory", "bats-hosted"],
        )
        candidate_environments = {
            name: environment
            for name, environment in calls
            if name in ("hosted-build", "hosted-test", "bats-hosted")
        }
        self.assertEqual(set(candidate_environments), {"hosted-build", "hosted-test", "bats-hosted"})
        isolated_homes = set()
        for name, environment in candidate_environments.items():
            with self.subTest(stage=name):
                self.assertNotEqual(environment["HOME"], inherited["HOME"])
                self.assertEqual(environment["CFFIXED_USER_HOME"], environment["HOME"])
                isolated_root = Path(environment["HOME"]).parent
                isolated_homes.add(environment["HOME"])
                for variable in (
                    "HOME",
                    "TMPDIR",
                    "XDG_CONFIG_HOME",
                    "XDG_CACHE_HOME",
                    "XDG_DATA_HOME",
                ):
                    self.assertTrue(Path(environment[variable]).is_relative_to(isolated_root))
        self.assertEqual(len(isolated_homes), 3)

    def _green_hosted_runner(self, status_by_stage=None, write_xunit=True):
        def runner(stage, command, cwd, timeout, grace, env):
            status = (status_by_stage or {}).get(stage.name, 0)
            if status == 0 and stage.requires_xunit and write_xunit:
                self.quality.xunit_output_path(command).write_text(
                    "<testsuite><testcase name='synthetic'/></testsuite>",
                    encoding="utf-8",
                )
            return self.quality.CommandResult(status=status)

        return runner

    def _run_hosted(self, runner):
        inherited = {**TRUSTED_HOSTED_ENVIRONMENT, "HOME": "/synthetic/operator-home"}
        with mock.patch.dict(self.quality.os.environ, inherited, clear=True):
            return self.quality.run_quality(
                ["--mode", "hosted", "--hosted-context", "pull-request", "--candidate-sha", FULL_SHA],
                runner=runner,
                git_validator=lambda request: None,
            )

    def _temporary_root(self):
        root = self.quality.create_temporary_root()
        self.addCleanup(_force_remove, root.path)
        return root

    def _foreign(self, device, relative):
        return self.quality.ForeignMount(device, relative)

    def _image(self, root, whole, *relatives):
        return self.quality.DiskImage(whole, tuple(os.path.join(root.real_path, r) for r in relatives))

    def test_scan_lists_outermost_foreign_directories_and_never_follows_a_symlink(self) -> None:
        root = self._temporary_root()
        base = Path(root.path)
        mount = "hosted-build/home/Library/Developer/DVTDownloads/MetalToolchain/mounts/abc"
        (base / mount / "nested").mkdir(parents=True)
        (base / "hosted-test" / "home").mkdir(parents=True)
        (base / "link").symlink_to(base / "hosted-test")
        (base / "devlink").symlink_to("/dev")
        foreign = {mount: 99, f"{mount}/nested": 98, "link/home": 97}

        found = self.quality.scan_temporary_root(
            root, lambda relative, status: foreign.get(relative, status.st_dev)
        )

        self.assertEqual(found, [self._foreign(99, mount)])

    def test_scan_holds_one_descriptor_per_level_not_per_directory(self) -> None:
        resource = __import__("resource")
        root = self._temporary_root()
        wide = Path(root.path) / "hosted-test" / "tmp"
        for index in range(200):
            (wide / f"d{index:03d}" / "inner").mkdir(parents=True)
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        resource.setrlimit(resource.RLIMIT_NOFILE, (min(64, hard), hard))
        try:
            found = self.quality.scan_temporary_root(root)
            self.quality.delete_temporary_root(root)
        finally:
            resource.setrlimit(resource.RLIMIT_NOFILE, (soft, hard))

        self.assertEqual(found, [])
        self.assertFalse(os.path.exists(root.path))

    def test_scan_refuses_a_replaced_or_symlinked_root_and_cleanup_touches_nothing(self) -> None:
        for replacement in ("symlink", "directory"):
            with self.subTest(replacement=replacement):
                root = self._temporary_root()
                moved = root.path + "-moved"
                self.addCleanup(_force_remove, moved)
                Path(root.path, "kept").write_text("x", encoding="utf-8")
                os.rename(root.path, moved)
                if replacement == "symlink":
                    os.symlink(moved, root.path)
                else:
                    os.mkdir(root.path)
                    Path(root.path, "sentinel").write_text("x", encoding="utf-8")
                calls = []

                failure = self.quality.remove_temporary_root(
                    root,
                    images=lambda: calls.append("images") or {},
                    detach=lambda device, force: calls.append(("detach", device, force)),
                )

                self.assertIsNotNone(failure)
                self.assertNotIn(root.path, failure)
                self.assertEqual(calls, [])
                self.assertTrue(Path(moved, "kept").exists(), "nothing is done through a symlinked root")
                if replacement == "directory":
                    self.assertTrue(Path(root.path, "sentinel").exists())

    def test_delete_refuses_a_root_swapped_after_the_scan(self) -> None:
        root = self._temporary_root()
        moved = root.path + "-moved"
        self.addCleanup(_force_remove, moved)
        Path(root.path, "kept").write_text("x", encoding="utf-8")
        swapped = []

        def scan_then_swap(scanned_root):
            found = self.quality.scan_temporary_root(scanned_root)
            if not swapped:
                os.rename(root.path, moved)
                os.mkdir(root.path)
                Path(root.path, "sentinel").write_text("x", encoding="utf-8")
                swapped.append(True)
            return found

        with mock.patch("sys.stderr", new_callable=io.StringIO):
            failure = self.quality.remove_temporary_root(root, scan=scan_then_swap)

        self.assertIsNotNone(failure)
        self.assertTrue(Path(root.path, "sentinel").exists())
        self.assertTrue(Path(moved, "kept").exists())

    def test_delete_never_crosses_onto_another_filesystem(self) -> None:
        root = self._temporary_root()
        (Path(root.path) / "a" / "m").mkdir(parents=True)
        (Path(root.path) / "a" / "m" / "file").write_text("x", encoding="utf-8")
        (Path(root.path) / "b").write_text("x", encoding="utf-8")
        foreign = {"a/m": 99}

        with self.assertRaisesRegex(OSError, "<tmp>/a/m is a mounted filesystem"):
            self.quality.delete_temporary_root(
                root, lambda relative, status: foreign.get(relative, status.st_dev)
            )

        self.assertTrue((Path(root.path) / "a" / "m" / "file").exists())

    def test_delete_unlinks_symlinks_and_special_files_without_following_them(self) -> None:
        root = self._temporary_root()
        outside = self._temporary_root()
        Path(outside.path, "kept").write_text("x", encoding="utf-8")
        base = Path(root.path)
        (base / "d").mkdir()
        (base / "d" / "to-directory").symlink_to(outside.path)
        (base / "d" / "to-file").symlink_to(Path(outside.path, "kept"))
        (base / "d" / "to-dev").symlink_to("/dev")
        (base / "d" / "dangling").symlink_to(Path(outside.path, "missing"))
        os.mkfifo(base / "d" / "fifo")

        self.quality.delete_temporary_root(root)

        self.assertFalse(os.path.lexists(root.path))
        self.assertEqual(os.listdir(outside.path), ["kept"])

    def test_delete_refuses_a_root_swapped_before_its_final_rmdir(self) -> None:
        root = self._temporary_root()
        moved = root.path + "-moved"
        self.addCleanup(_force_remove, moved)

        def device_of(relative, status):
            return status.st_dev

        (Path(root.path) / "a").mkdir()
        real_rmdir = os.rmdir
        swapped = []

        def swap_then_rmdir(path, *args, **kwargs):
            if kwargs.get("dir_fd") is not None and path == "a" and not swapped:
                result = real_rmdir(path, *args, **kwargs)
                os.rename(root.path, moved)
                os.mkdir(root.path)
                swapped.append(True)
                return result
            return real_rmdir(path, *args, **kwargs)

        with mock.patch.object(self.quality.os, "rmdir", swap_then_rmdir):
            with self.assertRaises(self.quality.TemporaryRootReplaced):
                self.quality.delete_temporary_root(root, device_of)

        self.assertTrue(os.path.isdir(root.path), "the swapped-in directory must not be removed")
        self.assertTrue(os.path.isdir(moved))

    def test_cleanup_refuses_an_image_hdiutil_does_not_record_at_the_scanned_path(self) -> None:
        root = self._temporary_root()
        mount = self._foreign(99, "hosted-build/home/mounts/abc")
        events = []
        for image in (
            self.quality.DiskImage("/dev/disk6", ()),
            self._image(root, "/dev/disk6", "hosted-build/home/mounts/other"),
        ):
            with self.subTest(mount_points=image.mount_points):
                failure = self.quality.remove_temporary_root(
                    root,
                    scan=lambda _root: [mount],
                    images=lambda: {99: image},
                    detach=lambda device, force: events.append((device, force)),
                    describe=lambda path: "described",
                    remove=lambda removed_root: events.append("removed"),
                )
                self.assertEqual(
                    failure,
                    "<tmp>/hosted-build/home/mounts/abc is on disk image /dev/disk6, but hdiutil "
                    "records no volume of it mounted there (described)",
                )
        self.assertEqual(events, [])

    def test_scan_refuses_a_directory_swapped_between_its_stat_and_its_open(self) -> None:
        for replacement in ("directory", "symlink"):
            with self.subTest(replacement=replacement):
                root = self._temporary_root()
                base = Path(root.path)
                (base / "a" / "b").mkdir(parents=True)
                elsewhere = self._temporary_root()

                def swap_after_stat(relative, status):
                    if relative == "a":
                        os.rename(base / "a", base / "a-moved")
                        if replacement == "directory":
                            (base / "a").mkdir()
                        else:
                            (base / "a").symlink_to(elsewhere.path)
                    return status.st_dev

                with self.assertRaises(OSError):
                    self.quality.scan_temporary_root(root, swap_after_stat)

    def test_temporary_root_is_never_registered_for_automatic_deletion(self) -> None:
        root = self._temporary_root()

        registered = [
            info for info in weakref.finalize._registry.values()
            if root.path in (str(argument) for argument in info.args)
        ]

        self.assertEqual(registered, [])
        self.assertEqual(root.identity, (os.lstat(root.path).st_dev, os.lstat(root.path).st_ino))
        self.assertEqual(root.real_path, os.path.realpath(root.path))

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root ignores directory modes")
    def test_scan_opens_unreadable_directories_instead_of_skipping_them(self) -> None:
        root = self._temporary_root()
        base = Path(root.path)
        for directory, mode in (("unlistable", 0o000), ("unsearchable", 0o600), ("write-only", 0o300)):
            (base / directory / "inner").mkdir(parents=True)
            os.chmod(base / directory, mode)
        foreign = {"unlistable/inner": 91, "unsearchable/inner": 92, "write-only/inner": 93}

        found = self.quality.scan_temporary_root(
            root, lambda relative, status: foreign.get(relative, status.st_dev)
        )

        self.assertEqual(
            sorted((mount.device, mount.relative) for mount in found),
            [(91, "unlistable/inner"), (92, "unsearchable/inner"), (93, "write-only/inner")],
        )

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root ignores directory modes")
    def test_cleanup_removes_a_tree_with_unreadable_directories(self) -> None:
        root = self._temporary_root()
        base = Path(root.path)
        (base / "a" / "b").mkdir(parents=True)
        (base / "a" / "b" / "file").write_text("x", encoding="utf-8")
        os.chmod(base / "a" / "b", 0o500)
        os.chmod(base / "a", 0o000)

        self.assertIsNone(self.quality.remove_temporary_root(root))
        self.assertFalse(base.exists())

    def test_disk_images_resolve_hfs_and_apfs_shapes_to_the_image_whole_disk(self) -> None:
        container = "EF57347C-0000-11AA-AA11-00306543ECAC"
        listing = {
            "images": [
                {"system-entities": [
                    {"dev-entry": "/dev/disk6", "content-hint": "GUID_partition_scheme"},
                    {"dev-entry": "/dev/disk6s1", "mount-point": "/x/hfs"},
                ]},
                {"system-entities": [
                    {"dev-entry": "/dev/disk8", "content-hint": "GUID_partition_scheme"},
                    {"dev-entry": "/dev/disk8s1", "content-hint": "7C3457EF-0000-11AA-AA11-00306543ECAC"},
                    {"dev-entry": "/dev/disk9", "content-hint": container},
                    {"dev-entry": "/dev/disk9s1", "content-hint": "41504653-0000-11AA-AA11-00306543ECAC", "mount-point": "/x/apfs"},
                ]},
                {"system-entities": [
                    {"dev-entry": "/dev/disk10"},
                    {"dev-entry": "/dev/disk11", "content-hint": container},
                    {"dev-entry": "/dev/disk11s1", "mount-point": "/x/flat"},
                ]},
                {"system-entities": [{"dev-entry": "/dev/disk7s1"}]},
                {"system-entities": [{"dev-entry": "/dev/disk12"}, {"dev-entry": "/dev/disk13"}]},
                {"system-entities": [{"dev-entry": "/dev/disk14"}, {"dev-entry": "/tmp/../dev/disk14s1"}]},
                {"system-entities": [{"dev-entry": "/dev/disk15"}, {"dev-entry": "/dev/disk15s1"}, {"dev-entry": "/dev/disk15s2"}]},
                {"system-entities": "not a list"},
                "not an image",
            ]
        }
        numbers = {
            "/dev/disk6": 600, "/dev/disk6s1": 601,
            "/dev/disk8": 800, "/dev/disk8s1": 801, "/dev/disk9": 900, "/dev/disk9s1": 901,
            "/dev/disk10": 1000, "/dev/disk11": 1100, "/dev/disk11s1": 1101,
            "/dev/disk7s1": 701, "/dev/disk12": 1200, "/dev/disk13": 1300,
            "/dev/disk14": 1400, "/dev/disk15": 1500,
        }
        calls = []

        def run_tool(arguments, merge_stderr=True):
            calls.append((arguments, merge_stderr))
            return subprocess.CompletedProcess(arguments, 0, stdout=plistlib.dumps(listing), stderr=b"hdiutil: WARNING: deprecated")

        def device_of_entry(entry):
            if entry == "/dev/disk15s1":
                raise FileNotFoundError(entry)
            if entry == "/dev/disk15s2":
                return types.SimpleNamespace(st_mode=stat.S_IFCHR | 0o640, st_rdev=1502)
            return types.SimpleNamespace(st_mode=stat.S_IFBLK | 0o640, st_rdev=numbers[entry])

        with mock.patch.object(self.quality, "_run_cleanup_tool", run_tool):
            mapping = self.quality.attached_disk_images(device_of_entry)

        hfs = self.quality.DiskImage("/dev/disk6", ("/x/hfs",))
        apfs = self.quality.DiskImage("/dev/disk8", ("/x/apfs",))
        flat = self.quality.DiskImage("/dev/disk10", ("/x/flat",))
        self.assertEqual(
            mapping,
            {
                600: hfs, 601: hfs,
                800: apfs, 801: apfs, 900: apfs, 901: apfs,
                1000: flat, 1100: flat, 1101: flat,
                1400: self.quality.DiskImage("/dev/disk14", ()),
                1500: self.quality.DiskImage("/dev/disk15", ()),
            },
        )
        self.assertEqual(calls, [(("/usr/bin/hdiutil", "info", "-plist"), False)])

        def failing_tool(arguments, merge_stderr=True):
            return subprocess.CompletedProcess(arguments, 1, stdout=b"", stderr=b"no")

        with mock.patch.object(self.quality, "_run_cleanup_tool", failing_tool):
            with self.assertRaisesRegex(OSError, "hdiutil info exited 1: no"):
                self.quality.attached_disk_images(device_of_entry)

    def test_malformed_hdiutil_output_is_a_reported_failure(self) -> None:
        root = self._temporary_root()
        for output in (b"not a plist", b"", plistlib.dumps(["a", "list"])):
            with self.subTest(output=output[:12]):
                with mock.patch.object(
                    self.quality, "_run_cleanup_tool",
                    lambda arguments, merge_stderr=True: subprocess.CompletedProcess(arguments, 0, stdout=output, stderr=b""),
                ):
                    failure = self.quality.remove_temporary_root(
                        root,
                        scan=lambda _root: [self._foreign(99, "m")],
                        describe=lambda path: "described",
                        remove=lambda removed: self.fail("must not delete around a mount"),
                    )
                self.assertIsNotNone(failure)

    def test_cleanup_tools_run_with_closed_stdin_a_fixed_environment_and_a_timeout(self) -> None:
        captured = []

        def run(argv, **kwargs):
            captured.append((argv, kwargs))
            return subprocess.CompletedProcess(argv, 1, stdout=b"busy")

        with mock.patch.object(self.quality.subprocess, "run", run), mock.patch(
            "sys.stderr", new_callable=io.StringIO
        ) as stderr:
            self.quality.detach_disk_image("/dev/disk6", False)
            self.quality.detach_disk_image("/dev/disk6", True)
            self.quality._run_cleanup_tool(("/usr/bin/hdiutil", "info", "-plist"), merge_stderr=False)

        self.assertEqual(
            [argv for argv, _kwargs in captured],
            [
                ("/usr/bin/hdiutil", "detach", "/dev/disk6"),
                ("/usr/bin/hdiutil", "detach", "-force", "/dev/disk6"),
                ("/usr/bin/hdiutil", "info", "-plist"),
            ],
        )
        for _argv, kwargs in captured:
            self.assertIs(kwargs["stdin"], subprocess.DEVNULL)
            self.assertEqual(kwargs["env"], self.quality.CLEANUP_TOOL_ENVIRONMENT)
            self.assertEqual(kwargs["timeout"], self.quality.CLEANUP_TOOL_TIMEOUT_SECONDS)
        self.assertEqual([kwargs["stderr"] for _argv, kwargs in captured],
                         [subprocess.STDOUT, subprocess.STDOUT, subprocess.PIPE])
        self.assertIn("hdiutil detach -force /dev/disk6 exited 1: busy", stderr.getvalue())

    def test_mount_table_summary_reports_who_mounted_it_without_the_name(self) -> None:
        table = (
            b"/dev/disk3s1 on / (apfs, sealed, local, read-only, journaled)\n"
            b"/dev/disk6s1 on /private/var/t/a b (hfs, local, read-only, noowners, mounted by runner)\n"
            b"/dev/disk7s1 on /private/var/t/c (apfs, local, read-only, mounted by someone-else)\n"
        )
        with mock.patch.object(
            self.quality, "_run_cleanup_tool",
            lambda arguments, merge_stderr=True: subprocess.CompletedProcess(arguments, 0, stdout=table),
        ), mock.patch.object(
            self.quality.pwd, "getpwuid", lambda uid: types.SimpleNamespace(pw_name="runner")
        ):
            self.assertEqual(
                self.quality.mount_table_summary("/private/var/t/a b"),
                "/dev/disk6s1, hfs, local, read-only, noowners; mounted by this user: yes",
            )
            self.assertEqual(
                self.quality.mount_table_summary("/private/var/t/c"),
                "/dev/disk7s1, apfs, local, read-only; mounted by this user: no",
            )
            self.assertEqual(
                self.quality.mount_table_summary("/"),
                "/dev/disk3s1, apfs, sealed, local, read-only, journaled; mounted by this user: unknown",
            )
            self.assertEqual(self.quality.mount_table_summary("/elsewhere"), "no mount-table entry")

    def test_cleanup_detaches_by_device_and_forces_only_when_a_rescan_still_finds_it(self) -> None:
        mount = self._foreign(99, "hosted-build/home/mounts/abc")
        for scans, expected_detaches, removed in (
            ([[mount], []], [("/dev/disk6", False)], True),
            ([[mount], [mount], []], [("/dev/disk6", False), ("/dev/disk6", True)], True),
            ([[mount], [mount], [mount]], [("/dev/disk6", False), ("/dev/disk6", True)], False),
        ):
            with self.subTest(scans=len(scans), removed=removed):
                root = self._temporary_root()
                pending = list(scans)
                events = []

                with mock.patch("sys.stderr", new_callable=io.StringIO):
                    failure = self.quality.remove_temporary_root(
                        root,
                        scan=lambda _root: pending.pop(0),
                        images=lambda: {99: self._image(root, "/dev/disk6", mount.relative)},
                        detach=lambda device, force: events.append((device, force)),
                        describe=lambda path: "hfs, read-only",
                        remove=lambda removed_root: events.append("removed"),
                    )

                self.assertEqual([e for e in events if e != "removed"], expected_detaches)
                if removed:
                    self.assertIsNone(failure)
                    self.assertEqual(events[-1], "removed")
                else:
                    self.assertEqual(
                        failure,
                        "<tmp>/hosted-build/home/mounts/abc is still mounted after hdiutil detach "
                        "and detach -force of /dev/disk6",
                    )
                    self.assertNotIn("removed", events)

    def test_cleanup_tries_every_mount_and_refuses_what_it_cannot_safely_detach(self) -> None:
        root = self._temporary_root()
        graft = self._foreign(98, "hosted-build/home/graft")
        shared = self._foreign(97, "hosted-build/home/shared")
        image = self._foreign(99, "hosted-test/home/image")
        pending = [[graft, shared, image], [graft, shared]]
        events = []
        outside = self.quality.DiskImage("/dev/disk7", (os.path.join(root.real_path, shared.relative), "/Volumes/other"))

        with mock.patch("sys.stderr", new_callable=io.StringIO):
            failure = self.quality.remove_temporary_root(
                root,
                scan=lambda _root: pending.pop(0),
                images=lambda: {99: self._image(root, "/dev/disk6", image.relative), 97: outside},
                detach=lambda device, force: events.append((device, force)),
                describe=lambda path: f"described {path == os.path.join(root.real_path, graft.relative) or path.endswith('shared')}",
                remove=lambda removed_root: events.append("removed"),
            )

        self.assertEqual(events, [("/dev/disk6", False)])
        self.assertEqual(
            failure,
            "<tmp>/hosted-build/home/graft is a mounted filesystem but not an attached disk image "
            "(described True); <tmp>/hosted-build/home/shared belongs to disk image /dev/disk7, which "
            "also has a volume mounted outside the temporary directory (described True)",
        )

    def test_cleanup_rescans_once_when_the_delete_fails(self) -> None:
        root = self._temporary_root()
        for failures_before_success, expect_none in ((1, True), (2, False)):
            with self.subTest(failures_before_success=failures_before_success):
                attempts = []
                scans = []

                def remove(removed_root):
                    attempts.append(removed_root)
                    if len(attempts) <= failures_before_success:
                        raise OSError(30, "Read-only file system", f"{root.real_path}/hosted-build/home/m")

                with mock.patch("sys.stderr", new_callable=io.StringIO):
                    failure = self.quality.remove_temporary_root(
                        root,
                        scan=lambda _root: scans.append(1) or [],
                        remove=remove,
                    )

                self.assertEqual(len(scans), min(failures_before_success + 1, 2))
                if expect_none:
                    self.assertIsNone(failure)
                else:
                    self.assertEqual(
                        failure,
                        "OSError: [Errno 30] Read-only file system: '<tmp>/hosted-build/home/m'",
                    )

    def test_cleanup_never_raises_and_keeps_names_on_one_escaped_line(self) -> None:
        root = self._temporary_root()

        def scan(_root):
            raise OSError(f"{root.path}/a\n::error::b")

        failure = self.quality.remove_temporary_root(root, scan=scan)

        self.assertEqual(failure, "OSError: <tmp>/a\\n::error::b")

    def test_hosted_cleanup_failure_is_a_warning_and_keeps_the_stage_verdict(self) -> None:
        for status_by_stage, expected_status in (({}, 0), ({"hosted-build": 7}, 7)):
            with self.subTest(status_by_stage=status_by_stage):
                roots = []

                def failing_cleanup(root):
                    roots.append(root.path)
                    self.addCleanup(_force_remove, root.path)
                    return "synthetic 50% mount\nleft behind"

                with mock.patch.object(self.quality, "remove_temporary_root", failing_cleanup), mock.patch(
                    "sys.stderr", new_callable=io.StringIO
                ), mock.patch("sys.stdout", new_callable=io.StringIO) as stdout:
                    result = self._run_hosted(self._green_hosted_runner(status_by_stage))
                gc.collect()

                self.assertEqual(result.status, expected_status)
                self.assertEqual(result.stderr[-1], "cleanup failed: synthetic 50% mount\nleft behind")
                self.assertIn(
                    "::warning title=quality cleanup::synthetic 50%25 mount%0Aleft behind\n",
                    stdout.getvalue(),
                )
                self.assertTrue(os.path.isdir(roots[0]), "nothing but the cleanup may delete the tree")

    def test_local_cleanup_failure_fails_a_green_run_without_an_annotation(self) -> None:
        for status, expected in ((0, self.quality.ASSERTION_FAILURE_STATUS), (7, 7)):
            with self.subTest(status=status), mock.patch(
                "sys.stderr", new_callable=io.StringIO
            ), mock.patch("sys.stdout", new_callable=io.StringIO) as stdout:
                result = self.quality.apply_cleanup_failure(
                    self.quality.Mode.LOCAL,
                    self.quality.QualityResult(status, stderr=("stage line",)),
                    "synthetic",
                )
            self.assertEqual(result.status, expected)
            self.assertEqual(result.stderr, ("stage line", "cleanup failed: synthetic"))
            self.assertEqual(stdout.getvalue(), "")

    def test_cleanup_failure_is_reported_when_a_stage_raises(self) -> None:
        runner = self._green_hosted_runner(write_xunit=False)
        with mock.patch("sys.stderr", new_callable=io.StringIO):
            baseline = self._run_hosted(runner)
        self.assertNotEqual(baseline.status, 0)

        with mock.patch.object(
            self.quality, "remove_temporary_root",
            lambda root: _force_remove(root.path) or "synthetic",
        ), mock.patch("sys.stderr", new_callable=io.StringIO), mock.patch(
            "sys.stdout", new_callable=io.StringIO
        ):
            result = self._run_hosted(runner)

        self.assertEqual(result.status, baseline.status)
        self.assertEqual(result.stderr, baseline.stderr + ("cleanup failed: synthetic",))

    def test_cleanup_failure_is_reported_when_a_stage_raises_a_policy_error(self) -> None:
        def runner(stage, command, cwd, timeout, grace, env):
            raise self.quality.PolicyError("synthetic policy")

        with mock.patch.object(
            self.quality, "remove_temporary_root",
            lambda root: _force_remove(root.path) or "synthetic",
        ), mock.patch("sys.stderr", new_callable=io.StringIO), mock.patch(
            "sys.stdout", new_callable=io.StringIO
        ):
            result = self._run_hosted(runner)

        self.assertEqual(result.status, self.quality.POLICY_FAILURE_STATUS)
        self.assertEqual(result.stderr, ("synthetic policy", "cleanup failed: synthetic"))

    def test_cleanup_failure_is_printed_even_when_an_unexpected_exception_escapes(self) -> None:
        def runner(stage, command, cwd, timeout, grace, env):
            raise RuntimeError("synthetic crash")

        with mock.patch.object(
            self.quality, "remove_temporary_root",
            lambda root: _force_remove(root.path) or "synthetic",
        ), mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
            with self.assertRaisesRegex(RuntimeError, "synthetic crash"):
                self._run_hosted(runner)

        self.assertIn("quality: cleanup failed: synthetic\n", stderr.getvalue())

    def test_hosted_run_removes_its_temporary_root_after_green_stages(self) -> None:
        roots = []
        runner = self._green_hosted_runner()

        def recording_runner(stage, command, cwd, timeout, grace, env):
            if env.get("HOME") != "/synthetic/operator-home":
                roots.append(Path(env["HOME"]).parents[1])
            return runner(stage, command, cwd, timeout, grace, env)

        with mock.patch("sys.stderr", new_callable=io.StringIO):
            result = self._run_hosted(recording_runner)

        self.assertEqual(result.status, 0)
        self.assertEqual(len(set(roots)), 1)
        self.assertFalse(roots[0].exists())

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
        with tempfile.TemporaryDirectory() as temporary_directory, mock.patch.dict(
            self.quality.os.environ,
            {"PATH": os.environ.get("PATH", "")},
            clear=True,
        ):
            xunit_dir = Path(temporary_directory)
            inventory = stages["bats-inventory"].command(REPO_ROOT, REPO_ROOT, xunit_dir)
            swiftly_build = stages["swiftly-build"].command(REPO_ROOT, REPO_ROOT, xunit_dir)
            swiftly_test = stages["swiftly-test"].command(REPO_ROOT, REPO_ROOT, xunit_dir)
            clt_build = stages["clt-build"].command(REPO_ROOT, REPO_ROOT, xunit_dir)
            bats_local = stages["bats-local"].command(REPO_ROOT, REPO_ROOT, xunit_dir)
            bats_hosted = stages["bats-hosted"].command(REPO_ROOT, REPO_ROOT, xunit_dir)

        self.assertEqual(inventory[0], sys.executable)
        self.assertEqual(inventory[1], str(REPO_ROOT / "scripts" / "ci" / "bats_inventory.py"))
        self.assertEqual(
            inventory[2:],
            (
                "--root",
                str(REPO_ROOT),
                "--manifest",
                str(REPO_ROOT / "bats" / "tier-inventory.json"),
                "--policy-root",
                str(REPO_ROOT),
                "--policy-manifest",
                str(REPO_ROOT / "bats" / "tier-inventory.json"),
            ),
        )
        self.assertEqual(swiftly_build[0], str(Path.home() / ".swiftly" / "bin" / "swift"))
        self.assertEqual(swiftly_build[1:], ("build", "--scratch-path", ".build-swiftly", "--disable-automatic-resolution"))
        self.assertEqual(swiftly_test[:5], (str(Path.home() / ".swiftly" / "bin" / "swift"), "test", "--scratch-path", ".build-swiftly", "--disable-automatic-resolution"))
        xunit_arguments = [argument for argument in swiftly_test if argument.startswith("--xunit-output")]
        self.assertEqual(len(xunit_arguments), 1)
        self.assertTrue(xunit_arguments[0].startswith("--xunit-output="))
        self.assertNotIn("--xunit-output", swiftly_test)
        self.assertEqual(clt_build, ("/usr/bin/swift", "build", "--disable-automatic-resolution"))
        self.assertEqual(bats_local[:3], ("/usr/bin/env", "PATH=/usr/bin:/bin:/usr/sbin:/sbin:" + os.environ.get("PATH", ""), "bats"))
        self.assertEqual(bats_local[-2:], ("-r", "bats/"))
        self.assertEqual(bats_hosted[:3], bats_local[:3])
        self.assertEqual(bats_hosted[-2:], ("-r", "bats/hosted/"))
        for command in (inventory, swiftly_build, swiftly_test, clt_build, bats_local, bats_hosted):
            self.assertIsInstance(command, tuple)
            self.assertNotIn("&&", command)

    def test_hosted_bats_command_uses_absolute_executable_override(self) -> None:
        stages = {stage.name: stage for stage in self.quality.STAGES}
        with tempfile.TemporaryDirectory() as temporary_directory:
            fake_bats = Path(temporary_directory) / "synthetic-bats"
            write_executable(fake_bats, "#!/bin/sh\nexit 0\n")
            xunit_dir = Path(temporary_directory)
            with mock.patch.dict(
                self.quality.os.environ,
                {"PATH": "/synthetic/bin", "BATS_EXECUTABLE": str(fake_bats)},
                clear=True,
            ):
                command = stages["bats-hosted"].command(REPO_ROOT, REPO_ROOT, xunit_dir)

        self.assertEqual(
            command[:3],
            (
                "/usr/bin/env",
                "PATH=/usr/bin:/bin:/usr/sbin:/sbin:/synthetic/bin",
                str(fake_bats),
            ),
        )

    def test_hosted_bats_command_rejects_relative_executable_override(self) -> None:
        stages = {stage.name: stage for stage in self.quality.STAGES}
        with tempfile.TemporaryDirectory() as temporary_directory, mock.patch.dict(
            self.quality.os.environ,
            {"BATS_EXECUTABLE": "relative-bats"},
            clear=True,
        ):
            xunit_dir = Path(temporary_directory)
            with self.assertRaisesRegex(
                self.quality.PolicyError,
                "^Bats executable override must be absolute$",
            ):
                stages["bats-hosted"].command(REPO_ROOT, REPO_ROOT, xunit_dir)

    def test_bats_command_rejects_unavailable_executable_override(self) -> None:
        stages = {stage.name: stage for stage in self.quality.STAGES}
        with tempfile.TemporaryDirectory() as temporary_directory, mock.patch.dict(
            self.quality.os.environ,
            {"BATS_EXECUTABLE": str(Path(temporary_directory) / "missing-bats")},
            clear=True,
        ):
            xunit_dir = Path(temporary_directory)
            with self.assertRaisesRegex(
                self.quality.PolicyError,
                "^Bats executable override is unavailable$",
            ):
                stages["bats-local"].command(REPO_ROOT, REPO_ROOT, xunit_dir)

    def test_hosted_bats_receives_a_fresh_isolated_home_and_config_roots(self) -> None:
        captured = {}

        def runner(stage, command, cwd, timeout, grace, env):
            captured.update(env)
            captured["directories_exist"] = all(
                name in env and Path(env[name]).is_dir()
                for name in (
                    "HOME",
                    "TMPDIR",
                    "XDG_CONFIG_HOME",
                    "XDG_CACHE_HOME",
                    "XDG_DATA_HOME",
                )
            )
            return self.quality.CommandResult(status=0)

        result = self.quality._run_quality_request(
            self.hosted_request(("bats-hosted",)),
            runner=runner,
            git_validator=lambda request: None,
            environment=TRUSTED_HOSTED_ENVIRONMENT,
        )

        self.assertEqual(result.status, 0)
        self.assertTrue(captured["directories_exist"])
        for name in ("CFFIXED_USER_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME"):
            self.assertIn(name, captured)
        self.assertNotEqual(captured["HOME"], os.environ.get("HOME"))
        self.assertEqual(captured["CFFIXED_USER_HOME"], captured["HOME"])
        isolated_root = Path(captured["HOME"]).parent
        for name in ("HOME", "TMPDIR", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME"):
            self.assertTrue(Path(captured[name]).is_relative_to(isolated_root))

    def test_pre_bats_gate_revalidates_git_state_after_build(self) -> None:
        git_checks = []
        stages = []

        def git_validator(request):
            git_checks.append(request)
            if len(git_checks) == 2:
                raise self.quality.PolicyError("candidate changed after build")

        def runner(stage, command, cwd, timeout, grace, env):
            stages.append(stage.name)
            return self.quality.CommandResult(status=0)

        result = self.quality._run_quality_request(
            self.hosted_request(("hosted-build", "bats-hosted")),
            runner=runner,
            git_validator=git_validator,
            environment=TRUSTED_HOSTED_ENVIRONMENT,
        )

        self.assertEqual(result.status, 2)
        self.assertEqual(len(git_checks), 2)
        self.assertEqual(stages, ["hosted-build"])

    def test_pre_bats_gate_revalidates_inventory_and_fails_before_bats(self) -> None:
        stages = []
        git_checks = []

        def runner(stage, command, cwd, timeout, grace, env):
            stages.append(stage.name)
            status = 9 if stage.name == "bats-inventory" else 0
            return self.quality.CommandResult(status=status)

        result = self.quality._run_quality_request(
            self.hosted_request(("hosted-build", "bats-hosted")),
            runner=runner,
            git_validator=lambda request: git_checks.append(request),
            environment=TRUSTED_HOSTED_ENVIRONMENT,
        )

        self.assertEqual(result.status, 9)
        self.assertEqual(len(git_checks), 2)
        self.assertEqual(stages, ["hosted-build", "bats-inventory"])

    def test_git_checks_use_exact_usr_bin_git(self) -> None:
        calls = []

        def run(command, **kwargs):
            calls.append((command, kwargs))

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

        command, kwargs = calls[0]
        self.assertEqual(command[0], "/usr/bin/git")
        self.assertIn(("-c", "core.fsmonitor=false"), tuple(zip(command, command[1:])))
        self.assertIn(("-c", "core.hooksPath=/dev/null"), tuple(zip(command, command[1:])))
        self.assertIn(("-c", "credential.helper="), tuple(zip(command, command[1:])))
        self.assertIn(("-c", "credential.interactive=false"), tuple(zip(command, command[1:])))
        self.assertIn(("-c", "core.askPass="), tuple(zip(command, command[1:])))
        self.assertEqual(kwargs["timeout"], self.quality.GIT_TIMEOUT_SECONDS)
        self.assertEqual(
            kwargs["env"],
            {
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LC_ALL": "C",
                "LANG": "C",
                "GIT_OPTIONAL_LOCKS": "0",
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_TERMINAL_PROMPT": "0",
            },
        )

    def test_git_checks_disable_repository_fsmonitor_helpers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            init_repo(root)
            marker = root / "fsmonitor-ran"
            helper = root / "fsmonitor-helper.sh"
            write_executable(
                helper,
                "#!/bin/sh\n"
                f"printf invoked > {str(marker)!r}\n"
                "printf '\\n'\n",
            )
            subprocess.run(
                ["/usr/bin/git", "config", "core.fsmonitor", str(helper)],
                cwd=root,
                check=True,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            self.quality.git_output(("status", "--porcelain"), root)

            self.assertFalse(marker.exists())

    def test_git_timeout_uses_a_stable_value_free_diagnostic(self) -> None:
        def run(_command, **_kwargs):
            raise subprocess.TimeoutExpired(
                cmd=("synthetic-private-command",),
                timeout=1,
                output="private-output",
                stderr="private-error",
            )

        original = self.quality.subprocess.run
        try:
            self.quality.subprocess.run = run
            with self.assertRaisesRegex(self.quality.PolicyError, "^git command timed out$"):
                self.quality.git_output(("status", "--porcelain"), Path("/tmp/repo"))
        finally:
            self.quality.subprocess.run = original

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

    def test_bounded_runner_kills_output_bomb_with_fixed_diagnostic(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            pid_file = root / "descendant.pid"
            bomb = root / "bomb.py"
            write_executable(
                bomb,
                textwrap.dedent(
                    f"""\
                    #!/usr/bin/env python3
                    import pathlib, subprocess, sys, time
                    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
                    pathlib.Path({str(pid_file)!r}).write_text(str(child.pid), encoding="utf-8")
                    sys.stdout.buffer.write(b"x" * 4097)
                    sys.stdout.buffer.flush()
                    while True:
                        time.sleep(1)
                    """
                ),
            )
            original_limit = getattr(self.quality, "MAX_COMMAND_OUTPUT_BYTES", None)
            self.quality.MAX_COMMAND_OUTPUT_BYTES = 4096
            try:
                result = self.quality.run_command((str(bomb),), root, 2, 0.2)
            finally:
                if original_limit is None:
                    del self.quality.MAX_COMMAND_OUTPUT_BYTES
                else:
                    self.quality.MAX_COMMAND_OUTPUT_BYTES = original_limit

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

            self.assertEqual(result.status, self.quality.OUTPUT_LIMIT_STATUS)
            self.assertEqual(result.output, self.quality.OUTPUT_LIMIT_DIAGNOSTIC)
            with self.assertRaises(ProcessLookupError):
                os.kill(descendant_pid, 0)

    def test_bounded_runner_accepts_exact_output_limit_across_both_streams(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            writer = root / "writer.py"
            write_executable(
                writer,
                "#!/usr/bin/env python3\n"
                "import sys\n"
                "sys.stdout.buffer.write(b'a' * 2048)\n"
                "sys.stdout.buffer.flush()\n"
                "sys.stderr.buffer.write(b'b' * 2048)\n"
                "sys.stderr.buffer.flush()\n",
            )
            original_limit = getattr(self.quality, "MAX_COMMAND_OUTPUT_BYTES", None)
            self.quality.MAX_COMMAND_OUTPUT_BYTES = 4096
            try:
                result = self.quality.run_command((str(writer),), root, 30, 0.2)
            finally:
                if original_limit is None:
                    del self.quality.MAX_COMMAND_OUTPUT_BYTES
                else:
                    self.quality.MAX_COMMAND_OUTPUT_BYTES = original_limit

            self.assertEqual(result.status, 0)
            self.assertEqual(len(result.output), 4096)
            self.assertEqual(result.output.count(b"a"), 2048)
            self.assertEqual(result.output.count(b"b"), 2048)

    def test_command_runner_never_uses_unbounded_communicate(self) -> None:
        source = QUALITY_PATH.read_text(encoding="utf-8")
        runner_source = source[source.index("def drain_output"):source.index("def read_regular_file_no_follow")]
        self.assertNotIn(".communicate(", runner_source)

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
                self.quality.run_command((str(stubborn_script),), root, 2, 0.1).status,
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

    def test_group_signal_permission_error_is_forgiven_for_an_unreaped_exited_leader_or_in_cleanup(
        self,
    ) -> None:
        # Darwin's killpg fails with EPERM for a group whose members have all exited while the
        # leader is unreaped; Linux, where this tier runs in CI, does not fail for such a group,
        # so the handling is pinned with stand-ins here (2026-10-02).
        class Process:
            pid = 12345

            def __init__(self, returncode, exit_status):
                self.returncode = returncode
                self.exit_status = exit_status

            def poll(self):
                if self.returncode is None:
                    self.returncode = self.exit_status
                return self.returncode

        error = PermissionError(errno.EPERM, os.strerror(errno.EPERM))
        gone = ProcessLookupError(errno.ESRCH, os.strerror(errno.ESRCH))
        # The leader has exited but is unreaped, and was its group's only member: it is reaped
        # through Popen, the retried signal finds the group gone, and nothing is sent.
        with mock.patch.object(
            self.quality.os, "killpg", side_effect=[error, gone, error, gone]
        ) as killpg:
            zombie = Process(None, -signal.SIGKILL)
            self.assertFalse(self.quality.try_signal_leader_group(zombie, signal.SIGTERM))
            self.assertEqual(zombie.returncode, -signal.SIGKILL)
            zombie = Process(None, 0)
            sent = [False]
            self.quality.kill_remaining_group(zombie, sent)
            self.assertEqual((sent, zombie.returncode), ([False], 0))
        self.assertEqual(
            [call.args[1] for call in killpg.call_args_list],
            [signal.SIGTERM, signal.SIGTERM, signal.SIGKILL, signal.SIGKILL],
        )

        # A member the reap does not explain survives it: the retry signals that member and
        # reports the signal sent, or meets EPERM again, which stands outside cleanup and is
        # forgiven with a warning in cleanup (2026-10-05).
        with mock.patch.object(self.quality.os, "killpg", side_effect=[error, None]):
            zombie = Process(None, 0)
            sent = [False]
            self.quality.kill_remaining_group(zombie, sent)
            self.assertEqual((sent, zombie.returncode), ([True], 0))
        first = PermissionError(errno.EPERM, os.strerror(errno.EPERM))
        retried = PermissionError(errno.EPERM, os.strerror(errno.EPERM))
        with mock.patch.object(self.quality.os, "killpg", side_effect=[first, retried]):
            zombie = Process(None, 0)
            with self.assertRaises(PermissionError) as raised:
                self.quality.try_signal_leader_group(zombie, signal.SIGKILL)
            # The original error is the one that stands, with nothing chained to it.
            self.assertIs(raised.exception, first)
            self.assertIsNone(raised.exception.__context__)
            self.assertEqual(zombie.returncode, 0)
        with mock.patch.object(self.quality.os, "killpg", side_effect=error) as killpg:
            zombie = Process(None, 0)
            sent = [False]
            with mock.patch.object(self.quality.sys, "stderr", io.StringIO()) as warnings:
                self.quality.kill_remaining_group(zombie, sent, cleanup=True)
            self.assertEqual((sent, zombie.returncode), ([False], 0))
            self.assertEqual(warnings.getvalue(), self.quality.CLEANUP_PERMISSION_WARNING + "\n")
        self.assertEqual(killpg.call_count, 2)

        with mock.patch.object(self.quality.os, "killpg", side_effect=error) as killpg:
            # The leader is still running: nothing explains the error, so it stands.
            running = Process(None, None)
            with self.assertRaises(PermissionError):
                self.quality.try_signal_leader_group(running, signal.SIGTERM)

            # The leader was reaped before the signal, as at every completed stage's sweep:
            # the error stands, and nothing is recorded as sent.
            reaped = Process(0, 0)
            sent = [False]
            with self.assertRaises(PermissionError):
                self.quality.kill_remaining_group(reaped, sent)
            self.assertEqual(sent, [False])

            # In cleanup the same error is forgiven with a warning: the stage's status is
            # already a failure.
            with mock.patch.object(self.quality.sys, "stderr", io.StringIO()) as warnings:
                self.quality.kill_remaining_group(reaped, sent, cleanup=True)
            self.assertEqual(sent, [False])
            self.assertEqual(warnings.getvalue(), self.quality.CLEANUP_PERMISSION_WARNING + "\n")

            # The pid-only helpers forgive nothing.
            with self.assertRaises(PermissionError):
                self.quality.try_signal_group(12345, signal.SIGTERM)

        self.assertEqual(
            killpg.call_args_list,
            [
                mock.call(12345, signal.SIGTERM),
                mock.call(12345, signal.SIGKILL),
                mock.call(12345, signal.SIGKILL),
                mock.call(12345, signal.SIGTERM),
            ],
        )

    def test_cleanup_stop_forgives_permission_error_from_an_unreaped_exited_leader(self) -> None:
        # Cleanup's first signal, stop_process_group's SIGTERM, is where the macOS flake was
        # reproduced. The integration test below cannot show it on Linux, so this pins, with
        # stand-ins, that both of cleanup's signals go through try_signal_leader_group and that
        # the error is forgiven there (2026-10-03).
        class Process:
            pid = 12345
            stdout = None
            returncode = None

            def poll(self):
                if self.returncode is None:
                    self.returncode = -signal.SIGKILL
                return self.returncode

            def wait(self, timeout=None):
                return self.poll()

        # The leader is the group's only member here, so once it is reaped the group is gone:
        # the retried SIGTERM and the sweep's SIGKILL find nothing.
        effects = [
            PermissionError(errno.EPERM, os.strerror(errno.EPERM)),
            ProcessLookupError(errno.ESRCH, os.strerror(errno.ESRCH)),
            ProcessLookupError(errno.ESRCH, os.strerror(errno.ESRCH)),
        ]
        zombie = Process()
        sent = [False]
        helper = self.quality.try_signal_leader_group
        warnings = io.StringIO()
        spy = mock.patch.object(self.quality, "try_signal_leader_group", wraps=helper)
        with mock.patch.object(self.quality.os, "killpg", side_effect=effects) as killpg, \
                spy as routed, mock.patch.object(self.quality.sys, "stderr", warnings):
            self.assertIsNone(self.quality.stop_process_group(zombie, 0.1, sent))

        # An unreaped exited leader explains the error fully, so nothing is warned.
        self.assertEqual(warnings.getvalue(), "")

        self.assertEqual(
            routed.call_args_list,
            [
                mock.call(zombie, signal.SIGTERM, cleanup=True),
                mock.call(zombie, signal.SIGKILL, cleanup=True),
            ],
        )
        self.assertEqual((sent, zombie.returncode), ([False], -signal.SIGKILL))
        self.assertEqual(
            killpg.call_args_list,
            [
                mock.call(12345, signal.SIGTERM),
                mock.call(12345, signal.SIGTERM),
                mock.call(12345, signal.SIGKILL),
            ],
        )

    def test_cleanup_escalation_forgives_permission_error_from_a_leader_still_unreaped(
        self,
    ) -> None:
        # The escalation branch (drain_output did not complete): the leader is still running
        # or caught mid-exit when its group's SIGKILL meets EPERM. Cleanup forgives it with a
        # warning instead of raising; without the flag the error would stand (2026-10-03).
        class Process:
            pid = 12345
            stdout = None
            returncode = None
            waits = 0

            def poll(self):
                return self.returncode

            def wait(self, timeout=None):
                self.waits += 1
                if self.waits == 1:
                    raise subprocess.TimeoutExpired(("leader",), timeout)
                self.returncode = -signal.SIGKILL
                return self.returncode

        effects = [None, PermissionError(errno.EPERM, os.strerror(errno.EPERM))]
        leader = Process()
        sent = [False]
        helper = self.quality.try_signal_leader_group
        warnings = io.StringIO()
        spy = mock.patch.object(self.quality, "try_signal_leader_group", wraps=helper)
        with mock.patch.object(self.quality.os, "killpg", side_effect=effects), \
                spy as routed, mock.patch.object(self.quality.sys, "stderr", warnings):
            self.assertIsNone(self.quality.stop_process_group(leader, 0.1, sent))

        self.assertEqual(
            routed.call_args_list,
            [
                mock.call(leader, signal.SIGTERM, cleanup=True),
                mock.call(leader, signal.SIGKILL, cleanup=True),
            ],
        )
        self.assertEqual((sent, leader.waits), ([False], 2))
        self.assertEqual(warnings.getvalue(), self.quality.CLEANUP_PERMISSION_WARNING + "\n")

    def test_cleanup_forgives_permission_error_after_its_wait_reaped_the_leader(self) -> None:
        # A canonical run's failure (2026-10-03): cleanup's SIGTERM reached a live leader, its
        # own wait reaped it, and the sweep's SIGKILL met EPERM from exited orphans launchd
        # had not reaped yet. The stage's status is already a failure, so the error is reported
        # as nothing sent; the completed-stage sweep still raises (the next test).
        class Process:
            pid = 12345
            stdout = None
            returncode = None

            def poll(self):
                return self.returncode

            def wait(self, timeout=None):
                self.returncode = -signal.SIGTERM
                return self.returncode

        effects = [None, PermissionError(errno.EPERM, os.strerror(errno.EPERM))]
        leader = Process()
        sent = [False]
        warnings = io.StringIO()
        with mock.patch.object(self.quality.os, "killpg", side_effect=effects) as killpg, \
                mock.patch.object(self.quality.sys, "stderr", warnings):
            self.assertIsNone(self.quality.stop_process_group(leader, 0.1, sent))

        self.assertEqual((sent, leader.returncode), ([False], -signal.SIGTERM))
        # The forgiven error still leaves its evidence, as a warning, not a failure.
        self.assertEqual(warnings.getvalue(), self.quality.CLEANUP_PERMISSION_WARNING + "\n")
        self.assertEqual(
            killpg.call_args_list,
            [mock.call(12345, signal.SIGTERM), mock.call(12345, signal.SIGKILL)],
        )

    def test_completed_stage_sweep_permission_error_fails_closed(self) -> None:
        # A completed stage's leader is reaped before the sweep, so EPERM there means an
        # exited orphan or a member under other credentials, never the zombie-leader group
        # cleanup forgives; it must not let the stage's own status 0 stand (2026-10-02).
        calls = []

        # Every SIGKILL meets EPERM and every SIGTERM finds the group gone, so nothing here
        # reaches the real kernel: the sweep raises, and the cleanup that follows forgives its
        # own SIGKILL's EPERM with a warning before the sweep's error is re-raised.
        def killpg(_process_group, sig):
            calls.append(sig)
            if sig == signal.SIGKILL:
                raise PermissionError(errno.EPERM, os.strerror(errno.EPERM))
            raise ProcessLookupError(errno.ESRCH, os.strerror(errno.ESRCH))

        warnings = io.StringIO()
        with tempfile.TemporaryDirectory() as temporary_directory:
            with mock.patch.object(self.quality.os, "killpg", side_effect=killpg), \
                    mock.patch.object(self.quality.sys, "stderr", warnings):
                with self.assertRaises(PermissionError) as raised:
                    self.quality.run_command(
                        (sys.executable, "-c", "pass"),
                        Path(temporary_directory),
                        60,
                        0.2,
                    )

        # A first SIGKILL proves the run took the completed path; a deadline would start
        # with cleanup's SIGTERM. The error raised is the sweep's own, not cleanup's.
        self.assertEqual(calls, [signal.SIGKILL, signal.SIGTERM, signal.SIGKILL])
        self.assertIsNone(raised.exception.__context__)
        self.assertEqual(warnings.getvalue(), self.quality.CLEANUP_PERMISSION_WARNING + "\n")

    def test_the_cancellation_accelerator_ignores_permission_and_lookup_errors(self) -> None:
        class Process:
            pid = 12345

        for effect in (
            PermissionError(errno.EPERM, os.strerror(errno.EPERM)),
            ProcessLookupError(errno.ESRCH, os.strerror(errno.ESRCH)),
            None,
        ):
            with self.subTest(effect=type(effect).__name__), \
                    mock.patch.object(self.quality.os, "killpg", side_effect=effect) as killpg:
                self.assertIsNone(self.quality.kill_group_after_cancellation(Process()))
            killpg.assert_called_once_with(12345, signal.SIGKILL)

    def test_repeated_cancellation_outside_cleanup_keeps_its_status(self) -> None:
        # A first SIGTERM raises the cancellation; a second, before cleanup has started, takes
        # the handler's accelerating SIGKILL, which meets EPERM. Raising there used to replace
        # 128+SIGTERM with a traceback (2026-10-05). The signals are raised from inside the
        # completed stage's sweep, which run_command calls with cancellation unblocked and no
        # cleanup active, so the order is exact.
        real_kill_remaining_group = self.quality.kill_remaining_group
        raised = []

        def kill_remaining_group(process, sent_sigkill, *, cleanup=False):
            if not raised:
                # Raising SIGTERM with no handler installed would end the whole test process.
                if signal.getsignal(signal.SIGTERM) in (signal.SIG_DFL, signal.SIG_IGN):
                    raise AssertionError("the sweep ran outside the cancellation handler's scope")
                try:
                    signal.raise_signal(signal.SIGTERM)
                except self.quality.CancellationRequested:
                    raised.append("first")
                    signal.raise_signal(signal.SIGTERM)
                    raised.append("second")
                    raise
            return real_kill_remaining_group(process, sent_sigkill, cleanup=cleanup)

        def killpg(_process_group, _sig):
            raise PermissionError(errno.EPERM, os.strerror(errno.EPERM))

        warnings = io.StringIO()
        with tempfile.TemporaryDirectory() as temporary_directory:
            with mock.patch.object(
                self.quality, "kill_remaining_group", side_effect=kill_remaining_group
            ), mock.patch.object(self.quality.os, "killpg", side_effect=killpg) as group_kill, \
                    mock.patch.object(self.quality.sys, "stderr", warnings):
                result = self.quality.run_command(
                    (sys.executable, "-c", "pass"),
                    Path(temporary_directory),
                    60,
                    0.2,
                )

        self.assertEqual(raised, ["first", "second"])
        self.assertEqual(result.status, 128 + signal.SIGTERM)
        # The handler's SIGKILL first, then cleanup's SIGTERM and sweep, each forgiven with a
        # warning because the leader had already been reaped.
        self.assertEqual(
            [call.args[1] for call in group_kill.call_args_list],
            [signal.SIGKILL, signal.SIGTERM, signal.SIGKILL],
        )
        self.assertEqual(
            warnings.getvalue(), (self.quality.CLEANUP_PERMISSION_WARNING + "\n") * 2
        )

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
                        xunit = quality.xunit_output_path(command)
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
            exited = root / "child-exited-unreaped"
            # The child ignores SIGTERM and ends on its own after 60 s, twice the runner's
            # bound below, so a runner that hangs leaves nothing running for long.
            write_executable(
                child,
                textwrap.dedent(
                    """\
                    #!/usr/bin/env python3
                    import signal, time
                    signal.signal(signal.SIGTERM, lambda *_args: None)
                    deadline = time.monotonic() + 60
                    while time.monotonic() < deadline:
                        time.sleep(1)
                    """
                ),
            )
            # The child never ends inside the 0.05 s timeout, so cleanup always starts on the
            # timeout path; the runner then signals itself, and the handler, seeing a
            # cancellation during cleanup, sends the group SIGKILL. The wrapper then holds
            # cleanup's own first signal until the child has exited but is still unreaped
            # (waitid with WNOWAIT, or ps where os.waitid is missing), for up to 10 s of room
            # for a starved runner; only the handler's SIGKILL can end the child before then,
            # so the exited marker also proves the escalation. That order used to arise by
            # chance, in about one run in thirty on macOS: Darwin's killpg fails with EPERM on
            # such a group, and the error ended the runner with status 1 (2026-10-02). Linux
            # signals such a group without error, so there this test passes either way; the
            # stand-in tests above pin the handling, cleanup's routing through it and the path
            # a canonical run met (2026-10-03).
            write_executable(
                runner,
                textwrap.dedent(
                    f"""\
                    #!/usr/bin/env python3
                    import os, pathlib, signal, subprocess, sys, time
                    sys.path.insert(0, {str(QUALITY_PATH.parent)!r})
                    import quality
                    original = quality.stop_process_group
                    exited = pathlib.Path({str(exited)!r})

                    def exited_unreaped(pid):
                        if hasattr(os, "waitid"):
                            flags = os.WEXITED | os.WNOHANG | os.WNOWAIT
                            return os.waitid(os.P_PID, pid, flags) is not None
                        # macOS has os.waitid only from Python 3.13; ps shows the zombie.
                        state = subprocess.run(
                            ["ps", "-o", "stat=", "-p", str(pid)],
                            stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL,
                            text=True,
                        ).stdout
                        return state.strip().startswith("Z")

                    def wrapped(process, grace, sent):
                        pathlib.Path({str(marker)!r}).write_text("started", encoding="utf-8")
                        os.kill(os.getpid(), signal.SIGTERM)
                        deadline = time.monotonic() + 10
                        while time.monotonic() < deadline:
                            if exited_unreaped(process.pid):
                                exited.write_text("exited", encoding="utf-8")
                                break
                            time.sleep(0.01)
                        return original(process, grace, sent)

                    quality.stop_process_group = wrapped
                    result = quality.run_command(({str(child)!r},), pathlib.Path({str(root)!r}), 0.05, 0.2)
                    raise SystemExit(result.status)
                    """
                ),
            )
            # The bound only catches a runner that never returns: unloaded it finishes in
            # well under a second, and the room is for interpreter start-up on a starved
            # runner (it was 5 s until 2026-10-02).
            completed = subprocess.run(
                ["python3", str(runner)],
                cwd=root,
                check=False,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
                timeout=30,
            )

            self.assertTrue(marker.exists(), completed.stderr)
            self.assertTrue(
                exited.exists(),
                f"child not seen exited before cleanup signalled it\n{completed.stderr}",
            )
            self.assertEqual(completed.returncode, 128 + signal.SIGTERM, completed.stderr)

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
                xunit_path = self.quality.xunit_output_path(command)
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

    def test_orchestration_accepts_known_swift_testing_xunit_filename(self) -> None:
        seen_paths = []

        def runner(stage, command, cwd, timeout, grace, env):
            if stage.name == "swiftly-test":
                exact_path = self.quality.xunit_output_path(command)
                compatibility_path = exact_path.with_name(
                    f"{exact_path.stem}-swift-testing{exact_path.suffix}"
                )
                seen_paths.extend((exact_path, compatibility_path))
                compatibility_path.write_text(
                    "<testsuite><testcase name='ok'/></testsuite>",
                    encoding="utf-8",
                )
            return self.quality.CommandResult(status=0)

        result = self.quality.run_quality(
            ["--mode", "local", "--stage", "swiftly-test"],
            runner=runner,
            git_validator=lambda request: None,
        )

        self.assertEqual(result.status, 0)
        self.assertEqual(len(seen_paths), 2)
        self.assertTrue(all(not path.exists() for path in seen_paths))

    def test_orchestration_fails_when_successful_swift_test_missing_xunit(self) -> None:
        seen_paths = []

        def runner(stage, command, cwd, timeout, grace, env):
            if stage.name == "swiftly-test":
                seen_paths.append(self.quality.xunit_output_path(command))
            return self.quality.CommandResult(status=0)

        result = self.quality.run_quality(
            ["--mode", "local", "--stage", "swiftly-test"],
            runner=runner,
            git_validator=lambda request: None,
        )

        self.assertEqual(result.status, 1)
        self.assertEqual(len(seen_paths), 1)
        self.assertFalse(seen_paths[0].exists())

    def test_orchestration_rejects_ambiguous_swift_test_xunit_outputs(self) -> None:
        seen_paths = []

        def runner(stage, command, cwd, timeout, grace, env):
            if stage.name == "swiftly-test":
                candidates = self.quality.xunit_output_candidates(command)
                seen_paths.extend(candidates)
                for path in candidates:
                    path.write_text(
                        "<testsuite><testcase name='ok'/></testsuite>",
                        encoding="utf-8",
                    )
            return self.quality.CommandResult(status=0)

        result = self.quality.run_quality(
            ["--mode", "local", "--stage", "swiftly-test"],
            runner=runner,
            git_validator=lambda request: None,
        )

        self.assertEqual(result.status, 1)
        self.assertEqual(len(seen_paths), 2)
        self.assertTrue(all(not path.exists() for path in seen_paths))

    def test_orchestration_rejects_compatibility_xunit_symlink(self) -> None:
        seen_paths = []

        def runner(stage, command, cwd, timeout, grace, env):
            if stage.name == "swiftly-test":
                exact_path, compatibility_path = self.quality.xunit_output_candidates(command)
                target = exact_path.with_name("target.xml")
                target.write_text(
                    "<testsuite><testcase name='ok'/></testsuite>",
                    encoding="utf-8",
                )
                compatibility_path.symlink_to(target)
                seen_paths.extend((exact_path, compatibility_path, target))
            return self.quality.CommandResult(status=0)

        result = self.quality.run_quality(
            ["--mode", "local", "--stage", "swiftly-test"],
            runner=runner,
            git_validator=lambda request: None,
        )

        self.assertEqual(result.status, 1)
        self.assertEqual(len(seen_paths), 3)
        self.assertTrue(all(not path.exists() for path in seen_paths))

    def test_orchestration_child_nonzero_skips_xunit_assertion_and_cleans_tempdir(self) -> None:
        seen_paths = []

        def runner(stage, command, cwd, timeout, grace, env):
            xunit_path = self.quality.xunit_output_path(command)
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
            xunit_path = self.quality.xunit_output_path(command)
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
