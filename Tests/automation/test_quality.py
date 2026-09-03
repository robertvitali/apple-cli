import importlib.util
import io
import os
from pathlib import Path
import math
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
QUALITY_PATH = REPO_ROOT / "scripts" / "ci" / "quality.py"
CI_WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "ci.yml"
RELEASE_WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "release.yml"
FULL_SHA = "0123456789abcdef0123456789abcdef01234567"
BASE_SHA = "89abcdef0123456789abcdef0123456789abcdef"
OTHER_SHA = "fedcba9876543210fedcba9876543210fedcba98"
TRUSTED_HOSTED_ENVIRONMENT = {
    "GITHUB_ACTIONS": "true",
    "RUNNER_OS": "macOS",
    "RUNNER_ENVIRONMENT": "github-hosted",
}


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
        'echo "$RUNNER_TEMP/node_modules/.bin" >> "$GITHUB_PATH"',
        install_step,
    )
    testcase.assertIn(
        'echo "BATS_EXECUTABLE=$RUNNER_TEMP/node_modules/.bin/bats" >> "$GITHUB_ENV"',
        install_step,
    )
    testcase.assertIn(
        '[ "$("$RUNNER_TEMP/node_modules/.bin/bats" --version)" = "Bats 1.13.0" ]',
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
        'echo "$RUNNER_TEMP/node_modules/.bin" >> "$GITHUB_PATH"',
        'echo "BATS_EXECUTABLE=$RUNNER_TEMP/node_modules/.bin/bats" >> "$GITHUB_ENV"',
        '[ "$("$RUNNER_TEMP/node_modules/.bin/bats" --version)" = "Bats 1.13.0" ]',
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

    def test_ci_runs_the_full_hosted_quality_gate_with_exact_sha_bindings(self) -> None:
        workflow = CI_WORKFLOW_PATH.read_text(encoding="utf-8")
        job = workflow_job(workflow, "build-test")
        bats_build_job = workflow_job(workflow, "hosted-bats-build")
        bats_job = workflow_job(workflow, "hosted-bats")

        self.assertIn("\n  pull_request:\n", workflow)
        self.assertNotIn("pull_request_target", workflow)
        self.assertRegex(workflow, r"(?m)^permissions:\n  contents: read$")
        for hosted_job in (job, bats_build_job, bats_job):
            self.assertIn("runs-on: macos-15", hosted_job)
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
        release_workflow = RELEASE_WORKFLOW_PATH.read_text(encoding="utf-8")

        ci_policy_job = workflow_job(ci_workflow, "supply-chain-policy")
        ci_bats_job = workflow_job(ci_workflow, "hosted-bats")
        release_job = workflow_job(release_workflow, "release")

        assert_pinned_bats_install(
            self,
            workflow_named_step(ci_bats_job, "Install pinned Bats"),
        )
        self.assertNotIn("Install pinned Bats", ci_policy_job)
        self.assertNotIn("BATS_INTEGRITY", ci_policy_job)
        self.assertNotIn("Install pinned Bats", release_job)
        self.assertNotIn("BATS_INTEGRITY", release_job)

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
