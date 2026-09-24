import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from types import ModuleType
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
CHECKER_PATH = REPO_ROOT / "scripts" / "ci" / "action_pins.py"
WORKFLOWS_ROOT = REPO_ROOT / ".github" / "workflows"

EXPECTED_ACTION_COUNTS = {
    "actions/checkout": 10,
    "actions/setup-python": 2,
    "astral-sh/setup-uv": 1,
    "actions/upload-artifact": 1,
    "actions/download-artifact": 1,
}

EXPECTED_ACTION_PINS = {
    "actions/checkout": ("3d3c42e5aac5ba805825da76410c181273ba90b1", "v7.0.1"),
    "actions/setup-python": ("5fda3b95a4ea91299a34e894583c3862153e4b97", "v7.0.0"),
    "astral-sh/setup-uv": ("bec219d24cd3e171d82865faccec33120bb574f4", "v10.1.0"),
    "actions/upload-artifact": ("043fb46d1a93c77aae656e7c1c64a875d1fc6a0a", "v7.0.1"),
    "actions/download-artifact": ("3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c", "v8.0.1"),
}


def load_checker() -> ModuleType:
    spec = importlib.util.spec_from_file_location("action_pins", CHECKER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load action pin checker")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_workflow(root: Path, relative: str, body: str) -> Path:
    path = root / ".github" / "workflows" / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    return path


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


class ActionPinPolicyTests(unittest.TestCase):
    def test_bootstrap_has_no_release_workflow(self) -> None:
        self.assertFalse((WORKFLOWS_ROOT / "release.yml").exists())
        self.assertFalse((WORKFLOWS_ROOT / "release.yaml").exists())

    def test_bootstrap_workflows_are_read_only_and_have_no_publishers(self) -> None:
        workflows = {
            path.name: path.read_text(encoding="utf-8")
            for suffix in ("*.yml", "*.yaml")
            for path in WORKFLOWS_ROOT.glob(suffix)
        }
        combined = "\n".join(workflows.values())
        forbidden_patterns = {
            "manual dispatch": r"(?m)^\s*workflow_dispatch\s*:",
            "write permission": r"(?m)^\s*[^#\s][^:]*:\s*write(?:\s*(?:#.*)?)?$",
            "write-all permissions": r"(?m)^\s*permissions\s*:\s*write-all(?:\s*(?:#.*)?)?$",
            "deployment environment": r"(?m)^\s*environment\s*:",
            "Pages action": r"(?m)^\s*(?:-\s+)?uses:\s*actions/(?:configure-pages|upload-pages-artifact|deploy-pages)@",
            "git publisher": r"\bgit\s+(?:commit|push|tag)\b",
            "GitHub release publisher": r"\bgh\s+release\s+(?:create|edit|delete|upload)\b",
            "GitHub workflow token": r"\$\{\{\s*github\.token\s*\}\}",
        }
        for publisher, pattern in forbidden_patterns.items():
            with self.subTest(publisher=publisher):
                self.assertNotRegex(combined, pattern)

    def test_bootstrap_docs_retains_only_read_only_advisory_jobs(self) -> None:
        docs = (WORKFLOWS_ROOT / "docs.yml").read_text(encoding="utf-8")
        jobs = docs.split("\njobs:\n", 1)[1]
        self.assertEqual(
            re.findall(r"(?m)^  ([a-z0-9-]+):\s*$", jobs),
            ["manual-fresh", "release-notes", "release-prep-rehearsal", "site-assembly-rehearsal"],
        )
        site = workflow_job(docs, "site-assembly-rehearsal")
        # The site rehearsal is read-only: no token reaches it, the Releases listing is read
        # unauthenticated, everything it writes lives under RUNNER_TEMP and goes on exit, and
        # only the value-free report is printed. A rate-limited listing is a notice, not a pass
        # of the assembly (the assembly step exits before running in that case).
        self.assertIn("permissions:\n      contents: read", site)
        self.assertIn("fetch-depth: 0", site)
        self.assertIn("python3 -I -S -B scripts/ci/site_assembly.py", site)
        self.assertIn("--derive-candidate-version", site)
        self.assertIn('--published-from-json "$RUNNER_TEMP/releases.json"', site)
        self.assertIn("pip install --require-hashes -r docs/requirements.txt", site)
        self.assertTrue((REPO_ROOT / "scripts" / "ci" / "site_assembly.py").is_file())
        self.assertNotIn("continue-on-error", site)
        self.assertNotRegex(site, r"upload-artifact|actions/cache|GITHUB_OUTPUT|GITHUB_STEP_SUMMARY|github\.token|secrets\.|GH_TOKEN|Authorization")
        self.assertRegex(site, r"trap 'rm -rf \"\$RUNNER_TEMP/site-scratch\"[^']*' EXIT")
        self.assertIn("x-ratelimit-remaining: 0|retry-after:", site)
        self.assertIn('echo "::warning::site-assembly: the public Releases listing is rate-limited', site)
        self.assertIn('echo "::error::site-assembly: the public Releases listing returned HTTP $status"; exit 1', site)
        self.assertIn('!= run ]; then', site)
        site_run_keys = re.findall(r"(?m)^\s+run:.*$", site)
        site_run_blocks = re.findall(r"(?ms)^        run: \|\n(.*?)(?=^      - |\Z)", site)
        self.assertTrue(site_run_blocks)
        self.assertEqual(len(site_run_keys), len(site_run_blocks))
        for block in site_run_blocks:
            self.assertNotIn("${{", block)
        rehearsal = workflow_job(docs, "release-prep-rehearsal")
        # The rehearsal must stay read-only and must never publish its scratch copies,
        # which carry the predicted version; only a CHECKED refusal (exit 1) is advisory.
        self.assertIn("permissions:\n      contents: read", rehearsal)
        self.assertIn("fetch-depth: 0", rehearsal)
        self.assertIn("python3 -I -S -B scripts/ci/release_prep.py", rehearsal)
        self.assertTrue((REPO_ROOT / "scripts" / "ci" / "release_prep.py").is_file())
        self.assertNotIn("continue-on-error", rehearsal)
        # Only the script's nothing-to-release status (3) is advisory; 1 and 2 fail the job.
        self.assertRegex(rehearsal, r'(?m)^\s+3\) echo "::notice::')
        self.assertNotRegex(rehearsal, r'(?m)^\s+1\) ')
        self.assertRegex(rehearsal, r'(?m)^\s+\*\) echo "::error::[^"]*"; exit "\$status" ;;')
        self.assertNotRegex(rehearsal, r"upload-artifact|actions/cache|GITHUB_OUTPUT|GITHUB_STEP_SUMMARY")
        self.assertIn('--scratch "$RUNNER_TEMP/', rehearsal)
        self.assertRegex(rehearsal, r"trap 'rm -rf \"\$RUNNER_TEMP/release-prep-scratch\"[^']*' EXIT")
        # Inputs reach the shell through env:, never by expression: every run: must be a
        # literal block and no block may contain an expression marker.
        run_keys = re.findall(r"(?m)^\s+run:.*$", rehearsal)
        run_blocks = re.findall(r"(?ms)^        run: \|\n(.*?)(?=^      - |\Z)", rehearsal)
        self.assertTrue(run_blocks)
        self.assertEqual(len(run_keys), len(run_blocks))
        for block in run_blocks:
            self.assertNotIn("${{", block)
        self.assertEqual(
            re.findall(r"(?m)^permissions:\n(?:  [^\n]+\n?)+", docs),
            ["permissions:\n  contents: read\n"],
        )
        self.assertNotRegex(docs, r"(?i)\bpages\b|\bPAGES_ENABLED\b")

    def test_missing_workflow_directory_is_a_hard_failure(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as directory:
            errors = checker.validate_repository(Path(directory))

        self.assertNotEqual(errors, [])
        self.assertTrue(any("workflow directory" in error for error in errors))

    def test_accepts_only_an_exact_reviewed_remote_action_pin(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            write_workflow(
                root,
                "nested/valid.yaml",
                """name: valid
jobs:
  test:
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
""",
            )

            self.assertEqual(checker.validate_repository(root), [])

    def test_ignores_uses_shaped_text_inside_a_run_block(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            write_workflow(
                root,
                "script.yml",
                """name: "uses"
run-name: "quoted text: !!str uses {? uses: value} &anchor *alias"
display-name: safe # !!str uses: inline-comment {? &anchor *alias}
jobs:
  test:
    steps:
      -   run: |
          uses: this-is-shell-text
          !!str uses: tagged-shell-text
          {? uses: flow-shell-text}
          &anchor uses: anchored-shell-text
          *alias: aliased-shell-text
      # !!str uses: tagged-comment-text {? &anchor *alias}
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
""",
            )

            self.assertEqual(checker.validate_repository(root), [])

    def test_rejects_unapproved_remote_local_and_container_references(self) -> None:
        checker = load_checker()
        invalid_values = (
            "vendor/example@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v0.1.0",
            "./build/action",
            "./.github/workflows/reusable.yml",
            "docker://example.invalid/tool@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        )

        for index, invalid_value in enumerate(invalid_values):
            with self.subTest(value=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_workflow(
                    root,
                    "transitive.yml",
                    f"jobs:\n  test:\n    uses: {invalid_value}\n",
                )

                errors = checker.validate_repository(root)

                self.assertNotEqual(errors, [])
                self.assertTrue(all(invalid_value not in error for error in errors))

    def test_rejects_quoted_uses_keys_and_flow_style_uses_nodes(self) -> None:
        checker = load_checker()
        documents = (
            'jobs:\n  test:\n    "uses": actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n',
            "jobs:\n  test:\n    'uses': actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n",
            "jobs: {test: {uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1}}\n",
            "jobs:\n  test:\n    steps: [{uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1}]\n",
            'jobs:\n  test:\n    ? "uses"\n    : actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n',
            "jobs:\n  test:\n    ? uses\n    : actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n",
            "jobs:\n  test:\n    steps:\n      -   uses: vendor/example@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v0.1.0\n",
            'jobs: {"u\\u0073es": actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1}\n',
        )

        for index, document in enumerate(documents):
            with self.subTest(document=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_workflow(root, "hostile.yml", document)

                errors = checker.validate_repository(root)

                self.assertNotEqual(errors, [])
                self.assertTrue(any("hostile.yml" in error for error in errors))

    def test_rejects_yaml_structure_that_can_hide_uses_keys(self) -> None:
        checker = load_checker()
        documents = (
            "jobs:\n  test:\n    !!str uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n",
            "jobs: {test: {? uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1}}\n",
            "jobs:\n  test:\n    &action-key uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n",
            "key: &action-key uses\njobs:\n  test:\n    *action-key: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n",
            "jobs:\n  test:\n    !<tag:yaml.org,2002:str> uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n",
            "jobs:\n  test:\n    &é uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n",
        )

        for index, document in enumerate(documents):
            with self.subTest(document=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_workflow(root, "structural.yml", document)

                errors = checker.validate_repository(root)

                self.assertNotEqual(errors, [])
                self.assertTrue(all("structural.yml" in error for error in errors))

    def test_rejects_implicit_mappings_inside_flow_sequences(self) -> None:
        checker = load_checker()
        documents = (
            "jobs:\n  test:\n    steps: [ uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 ]\n",
            'jobs:\n  test:\n    steps: [ "uses": actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 ]\n',
            'jobs:\n  test:\n    steps: [ "u\\u0073es": actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 ]\n',
        )

        for index, document in enumerate(documents):
            with self.subTest(document=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_workflow(root, "implicit.yml", document)

                errors = checker.validate_repository(root)

                self.assertNotEqual(errors, [])
                self.assertTrue(all("implicit.yml" in error for error in errors))

    def test_allows_scalar_only_flow_sequences(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_workflow(
                root,
                "scalar-array.yml",
                'name: scalar arrays\non:\n  push:\n    branches: [main, "topic:one"]\n',
            )

            self.assertEqual(checker.validate_repository(root), [])

    def test_rejects_reviewed_action_with_changed_sha_or_version_comment(self) -> None:
        checker = load_checker()
        values = (
            "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b0 # v7.0.1",
            "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.0",
        )

        for index, value in enumerate(values):
            with self.subTest(value=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_workflow(root, "changed.yml", f"jobs:\n  test:\n    uses: {value}\n")

                self.assertNotEqual(checker.validate_repository(root), [])

    def test_rejects_symlink_and_oversized_workflow_files(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workflow_root = root / ".github" / "workflows"
            workflow_root.mkdir(parents=True)
            target = root / "target.yml"
            target.write_text(
                "jobs:\n  test:\n    uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n",
                encoding="utf-8",
            )
            (workflow_root / "linked.yml").symlink_to(target)
            (workflow_root / "oversized.yml").write_text(
                "#" * (checker.MAX_WORKFLOW_BYTES + 1),
                encoding="utf-8",
            )

            errors = checker.validate_repository(root)

            self.assertTrue(any("linked.yml" in error for error in errors))
            self.assertTrue(any("oversized.yml" in error for error in errors))

    def test_rejects_nonregular_workflow_without_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workflow_root = root / ".github" / "workflows"
            workflow_root.mkdir(parents=True)
            os.mkfifo(workflow_root / "nonregular.yml")

            result = subprocess.run(
                [sys.executable, str(CHECKER_PATH), "--root", str(root)],
                check=False,
                capture_output=True,
                text=True,
                timeout=1,
            )

            self.assertNotEqual(result.returncode, 0)

    def test_rejects_every_mutable_or_ambiguous_uses_shape(self) -> None:
        checker = load_checker()
        invalid_values = (
            "actions/checkout@v7",
            "actions/checkout@3D3C42E5AAC5BA805825DA76410C181273BA90B1 # v7.0.1",
            "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
            "actions/checkout@${{ github.sha }} # v7.0.1",
            "docker://example.invalid/tool:latest",
            "docker://example.invalid/tool@sha256:AAAA",
            "./local/action",
            "../shared/action",
            ">",
            "|",
            "",
        )

        for index, invalid_value in enumerate(invalid_values):
            with self.subTest(value=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_workflow(
                    root,
                    "invalid.yml",
                    f"jobs:\n  test:\n    uses: {invalid_value}\n",
                )

                errors = checker.validate_repository(root)

                self.assertNotEqual(errors, [])
                self.assertTrue(all("invalid.yml:3:" in error for error in errors))
                if invalid_value:
                    self.assertTrue(all(invalid_value not in error for error in errors))

    def test_finds_both_yml_and_yaml_recursively(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            write_workflow(root, "first.yml", "jobs:\n  a:\n    uses: bad@ref\n")
            write_workflow(root, "nested/second.yaml", "jobs:\n  b:\n    uses: bad@ref\n")

            errors = checker.validate_repository(root)

            self.assertEqual(len(errors), 2)
            self.assertTrue(any("first.yml:3:" in error for error in errors))
            self.assertTrue(any("second.yaml:3:" in error for error in errors))

    def test_diagnostics_do_not_echo_references(self) -> None:
        checker = load_checker()
        secret_shaped_reference = "vendor.invalid/private-action@private-ref"
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            write_workflow(
                root,
                "private.yml",
                f"jobs:\n  test:\n    uses: {secret_shaped_reference}\n",
            )

            errors = checker.validate_repository(root)

            self.assertNotEqual(errors, [])
            self.assertFalse(any(secret_shaped_reference in error for error in errors))

    def test_rejects_malformed_or_duplicate_uses_keys_fail_closed(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            write_workflow(
                root,
                "malformed.yml",
                """jobs:
  test:
    uses : actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
""",
            )

            errors = checker.validate_repository(root)

            self.assertTrue(any("malformed.yml:4:" in error for error in errors))


class RepositoryActionInventoryTests(unittest.TestCase):
    def test_all_repository_workflows_pass_the_generic_checker(self) -> None:
        checker = load_checker()

        self.assertEqual(checker.validate_repository(REPO_ROOT), [])

    def test_remote_action_inventory_is_exact_and_version_annotated(self) -> None:
        checker = load_checker()

        references = checker.collect_references(REPO_ROOT)
        remote = [reference for reference in references if reference.kind == "remote"]

        self.assertEqual(len(remote), 15)
        counts = {}
        for reference in remote:
            counts[reference.name] = counts.get(reference.name, 0) + 1
            self.assertEqual(
                (reference.revision, reference.version_comment),
                EXPECTED_ACTION_PINS[reference.name],
            )
        self.assertEqual(counts, EXPECTED_ACTION_COUNTS)

    def test_all_checkouts_disable_persisted_credentials(self) -> None:
        workflows = {
            path.name: path.read_text(encoding="utf-8")
            for path in WORKFLOWS_ROOT.glob("*.yml")
        }
        checkout_line = (
            r"uses: actions/checkout@[0-9a-f]{40} "
            r"# v[0-9]+\.[0-9]+\.[0-9]+"
        )

        for workflow_name in ("ci.yml", "docs.yml", "pr-metadata.yml"):
            blocks = re.findall(
                rf"(?m)^\s*- {checkout_line}\n(?P<with>\s+with:\n(?:\s{{10,}}[^\n]*\n)*)",
                workflows[workflow_name],
            )
            expected_count = {
                "ci.yml": 5,
                "docs.yml": 4,
                "pr-metadata.yml": 1,
            }[workflow_name]
            self.assertEqual(len(blocks), expected_count)
            self.assertTrue(all("persist-credentials: false" in block for block in blocks))

    def test_ci_blocks_on_supply_chain_policy_and_exact_lock_regeneration(self) -> None:
        workflow = (WORKFLOWS_ROOT / "ci.yml").read_text(encoding="utf-8")
        job = workflow_job(workflow, "supply-chain-policy")
        validation_step = workflow_named_step(job, "Validate supply-chain policy")
        docs_step = workflow_named_step(job, "Prove documentation lock closure")
        aggregate_job = workflow_job(workflow, "quality-required")

        self.assertIn("  supply-chain-policy:\n", workflow)
        self.assertIn("name: Supply-chain policy", workflow)
        self.assertIn("name: quality / required", aggregate_job)
        self.assertIn("if: always()", aggregate_job)
        for dependency in (
            "- supply-chain-policy",
            "- build-test",
            "- hosted-bats",
            "- commit-lint",
        ):
            self.assertIn(dependency, aggregate_job)
        self.assertIn(
            "uses: astral-sh/setup-uv@bec219d24cd3e171d82865faccec33120bb574f4 # v10.1.0",
            job,
        )
        setup_uv_block = re.compile(
            r"(?m)^\s*- uses: astral-sh/setup-uv@bec219d24cd3e171d82865faccec33120bb574f4 # v10\.1\.0\n"
            r"\s+with:\n"
            r'\s+version: "0\.11\.27"\n'
            r"\s+enable-cache: false$"
        )
        self.assertEqual(len(setup_uv_block.findall(workflow)), 1)
        for command in (
            "python -m unittest discover -s Tests/automation -p 'test_*.py'",
            "python scripts/ci/action_pins.py",
            "python scripts/ci/dependency_policy.py",
            "python scripts/ci/workflow_policy.py",
        ):
            self.assertIn(command, validation_step)
        for command in (
            "uv pip compile docs/requirements.in --python-version 3.12 --python-platform x86_64-unknown-linux-gnu --generate-hashes --output-file docs/requirements.txt",
            "git diff --exit-code -- docs/requirements.txt",
            "python -m pip install --require-hashes -r docs/requirements.txt",
        ):
            self.assertIn(command, docs_step)

if __name__ == "__main__":
    unittest.main()
