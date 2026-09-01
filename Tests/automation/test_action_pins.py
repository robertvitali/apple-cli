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
    "actions/checkout": 8,
    "actions/setup-python": 3,
    "astral-sh/setup-uv": 2,
    "actions/configure-pages": 1,
    "actions/upload-pages-artifact": 1,
    "actions/deploy-pages": 1,
}

EXPECTED_ACTION_PINS = {
    "actions/checkout": ("3d3c42e5aac5ba805825da76410c181273ba90b1", "v7.0.1"),
    "actions/setup-python": ("5fda3b95a4ea91299a34e894583c3862153e4b97", "v7.0.0"),
    "astral-sh/setup-uv": ("c771a70e6277c0a99b617c7a806ffedaca235ff9", "v9.0.0"),
    "actions/configure-pages": ("45bfe0192ca1faeb007ade9deae92b16b8254a0d", "v6.0.0"),
    "actions/upload-pages-artifact": ("fc324d3547104276b827a68afc52ff2a11cc49c9", "v5.0.0"),
    "actions/deploy-pages": ("cd2ce8fcbc39b97be8ca5fce6e763baed58fa128", "v5.0.0"),
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


class ActionPinPolicyTests(unittest.TestCase):
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

        self.assertEqual(len(remote), 16)
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

        for workflow_name in ("ci.yml", "docs.yml", "pr-metadata.yml", "release.yml"):
            blocks = re.findall(
                rf"(?m)^\s*- {checkout_line}\n(?P<with>\s+with:\n(?:\s{{10,}}[^\n]*\n)*)",
                workflows[workflow_name],
            )
            expected_count = {
                "ci.yml": 3,
                "docs.yml": 3,
                "pr-metadata.yml": 1,
                "release.yml": 1,
            }[workflow_name]
            self.assertEqual(len(blocks), expected_count)
            self.assertTrue(all("persist-credentials: false" in block for block in blocks))

    def test_release_token_is_explicit_only_in_publish_steps(self) -> None:
        workflow = (WORKFLOWS_ROOT / "release.yml").read_text(encoding="utf-8")
        named_steps = re.findall(
            r"(?ms)^      - name: (?P<name>[^\n]+)\n(?P<body>.*?)(?=^      - (?:name:|uses:)|\Z)",
            workflow,
        )
        token_steps = {
            name: body for name, body in named_steps if "${{ github.token }}" in body
        }

        self.assertEqual(
            set(token_steps),
            {
                "Push commit and tag (atomic)",
                "Create GitHub Release (idempotent; notes from the curated CHANGELOG section)",
            },
        )
        publish_step = token_steps["Push commit and tag (atomic)"]
        release_step = next(
            body
            for name, body in token_steps.items()
            if name.startswith("Create GitHub Release")
        )
        self.assertIn("PUBLISH_TOKEN: ${{ github.token }}", publish_step)
        self.assertIn("GIT_ASKPASS", publish_step)
        self.assertNotIn("git commit", publish_step)
        self.assertIn(
            'git push --atomic "$REMOTE" HEAD:refs/heads/main "refs/tags/v${NEW}:refs/tags/v${NEW}"',
            publish_step,
        )
        self.assertNotIn("git push --atomic origin", workflow)
        self.assertIn("GH_TOKEN: ${{ github.token }}", release_step)
        self.assertEqual(workflow.count("${{ github.token }}"), 2)

    def test_ci_blocks_on_supply_chain_policy_and_exact_lock_regeneration(self) -> None:
        workflow = (WORKFLOWS_ROOT / "ci.yml").read_text(encoding="utf-8")

        self.assertIn("  supply-chain-policy:\n", workflow)
        self.assertIn("name: Supply-chain policy", workflow)
        self.assertIn(
            "uses: astral-sh/setup-uv@c771a70e6277c0a99b617c7a806ffedaca235ff9 # v9.0.0",
            workflow,
        )
        setup_uv_block = re.compile(
            r"(?m)^\s*- uses: astral-sh/setup-uv@c771a70e6277c0a99b617c7a806ffedaca235ff9 # v9\.0\.0\n"
            r"\s+with:\n"
            r'\s+version: "0\.11\.27"\n'
            r"\s+enable-cache: false$"
        )
        self.assertEqual(len(setup_uv_block.findall(workflow)), 1)
        for command in (
            "python -m unittest Tests.automation.test_action_pins Tests.automation.test_dependency_policy",
            "python scripts/ci/action_pins.py",
            "python scripts/ci/dependency_policy.py",
            "uv pip compile docs/requirements.in --python-version 3.12 --python-platform x86_64-unknown-linux-gnu --generate-hashes --output-file docs/requirements.txt",
            "git diff --exit-code -- docs/requirements.txt",
            "python -m pip install --require-hashes -r docs/requirements.txt",
        ):
            self.assertIn(command, workflow)

    def test_release_runs_equivalent_supply_chain_guard_before_mutation(self) -> None:
        workflow = (WORKFLOWS_ROOT / "release.yml").read_text(encoding="utf-8")

        guard = workflow.index("- name: Guard — supply-chain policy and docs lock")
        mutation = workflow.index("- name: Update version constant + CHANGELOG")
        self.assertLess(guard, mutation)
        setup_uv_block = re.compile(
            r"(?m)^\s*- uses: astral-sh/setup-uv@c771a70e6277c0a99b617c7a806ffedaca235ff9 # v9\.0\.0\n"
            r"\s+with:\n"
            r'\s+version: "0\.11\.27"\n'
            r"\s+enable-cache: false$"
        )
        self.assertEqual(len(setup_uv_block.findall(workflow)), 1)
        for command in (
            "python -m unittest Tests.automation.test_action_pins Tests.automation.test_dependency_policy",
            "python scripts/ci/action_pins.py",
            "python scripts/ci/dependency_policy.py",
            "uv pip compile docs/requirements.in --python-version 3.12 --python-platform x86_64-unknown-linux-gnu --generate-hashes --output-file docs/requirements.txt",
            "git diff --exit-code -- docs/requirements.txt",
            "python -m pip install --require-hashes -r docs/requirements.txt",
        ):
            self.assertIn(command, workflow[guard:mutation])


if __name__ == "__main__":
    unittest.main()
