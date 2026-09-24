import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from types import ModuleType
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
CHECKER_PATH = REPO_ROOT / "scripts" / "ci" / "dependency_policy.py"
DEPENDABOT_PATH = REPO_ROOT / ".github" / "dependabot.yml"
DOCS_WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "docs.yml"
CI_WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "ci.yml"
REQUIREMENTS_IN_PATH = REPO_ROOT / "docs" / "requirements.in"
REQUIREMENTS_LOCK_PATH = REPO_ROOT / "docs" / "requirements.txt"


def load_checker() -> ModuleType:
    spec = importlib.util.spec_from_file_location("dependency_policy", CHECKER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load dependency policy checker")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DocsDependencyPolicyTests(unittest.TestCase):
    def test_repository_docs_dependencies_are_fully_locked_and_fresh(self) -> None:
        checker = load_checker()

        self.assertEqual(checker.validate_docs_dependencies(REPO_ROOT), [])
        pins = checker.parse_input_pins(REQUIREMENTS_IN_PATH.read_text(encoding="utf-8"))
        locked = checker.parse_hash_lock(REQUIREMENTS_LOCK_PATH.read_text(encoding="utf-8"))
        self.assertEqual(set(pins), {"mkdocs-material"})
        self.assertEqual(locked["mkdocs-material"].version, pins["mkdocs-material"])
        self.assertTrue(all(requirement.hashes for requirement in locked.values()))

    def test_lock_records_python_312_linux_resolution_contract(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "docs").mkdir()
            shutil.copyfile(REQUIREMENTS_IN_PATH, root / "docs" / "requirements.in")
            stale_lock = REQUIREMENTS_LOCK_PATH.read_text(encoding="utf-8").replace(
                "--python-version 3.12",
                "--python-version 3.11",
                1,
            )
            (root / "docs" / "requirements.txt").write_text(
                stale_lock,
                encoding="utf-8",
            )

            errors = checker.validate_docs_dependencies(root)

            self.assertTrue(any("Python 3.12" in error for error in errors))

    def test_changed_top_level_pin_makes_the_lock_stale(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "docs").mkdir()
            shutil.copyfile(REQUIREMENTS_LOCK_PATH, root / "docs" / "requirements.txt")
            (root / "docs" / "requirements.in").write_text(
                "mkdocs-material==9.7.8\n",
                encoding="utf-8",
            )

            errors = checker.validate_docs_dependencies(root)

            self.assertTrue(any("top-level lock is stale" in error for error in errors))

    def test_unhashed_or_unpinned_requirement_is_rejected(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            docs = root / "docs"
            docs.mkdir()
            (docs / "requirements.in").write_text("mkdocs-material>=9\n", encoding="utf-8")
            (docs / "requirements.txt").write_text(
                "mkdocs-material==9.7.7\n",
                encoding="utf-8",
            )

            errors = checker.validate_docs_dependencies(root)

            self.assertTrue(any("exactly pinned" in error for error in errors))
            self.assertTrue(any("hash" in error for error in errors))

    def test_missing_docs_lock_is_a_hard_failure(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "docs").mkdir()
            (root / "docs" / "requirements.in").write_text(
                "mkdocs-material==9.7.7\n",
                encoding="utf-8",
            )

            errors = checker.validate_docs_dependencies(root)

            self.assertTrue(any("requirements.txt is missing" in error for error in errors))

    def test_rejects_symlinked_and_oversized_docs_policy_inputs(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            docs = root / "docs"
            docs.mkdir()
            target = root / "requirements-source.in"
            target.write_text("mkdocs-material==9.7.7\n", encoding="utf-8")
            (docs / "requirements.in").symlink_to(target)
            (docs / "requirements.txt").write_text(
                "#" * (checker.MAX_LOCK_BYTES + 1),
                encoding="utf-8",
            )

            errors = checker.validate_docs_dependencies(root)

            self.assertTrue(any("requirements.in" in error for error in errors))
            self.assertTrue(any("requirements.txt" in error for error in errors))

    def test_rejects_nonregular_docs_policy_input_without_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            docs = root / "docs"
            docs.mkdir()
            os.mkfifo(docs / "requirements.in")
            shutil.copyfile(REQUIREMENTS_LOCK_PATH, docs / "requirements.txt")

            result = subprocess.run(
                [sys.executable, str(CHECKER_PATH), "--root", str(root)],
                check=False,
                capture_output=True,
                text=True,
                timeout=1,
            )

            self.assertNotEqual(result.returncode, 0)

    def test_workflows_install_docs_dependencies_only_from_hash_locked_file(self) -> None:
        docs_workflow = DOCS_WORKFLOW_PATH.read_text(encoding="utf-8")
        ci_workflow = CI_WORKFLOW_PATH.read_text(encoding="utf-8")
        approved_command = (
            "python -m pip install --require-hashes -r docs/requirements.txt"
        )

        # Two jobs install the documentation toolchain, both from the hash-locked file and
        # nothing else: the supply-chain lock-closure proof (ci.yml) and the site-assembly
        # rehearsal (docs.yml). No other `pip install` form is admitted anywhere.
        self.assertEqual(docs_workflow.count("pip install"), 1)
        self.assertIn(approved_command, docs_workflow)
        self.assertIn(approved_command, ci_workflow)
        self.assertNotIn("pip install mkdocs-material", ci_workflow)
        self.assertNotIn("python -m pip install mkdocs-material", ci_workflow)

        install_lines = []
        for path in sorted((REPO_ROOT / ".github" / "workflows").rglob("*.yml")):
            for line in path.read_text(encoding="utf-8").splitlines():
                if re.search(r"\bpip +install\b", line):
                    install_lines.append(line.strip())
        self.assertEqual(len(install_lines), 2)
        self.assertTrue(
            all(
                line in {approved_command, f"run: {approved_command}"}
                for line in install_lines
            )
        )


class DependabotPolicyTests(unittest.TestCase):
    def test_repository_dependabot_configuration_matches_policy(self) -> None:
        checker = load_checker()

        self.assertEqual(checker.validate_dependabot(REPO_ROOT), [])
        self.assertEqual(
            DEPENDABOT_PATH.read_text(encoding="utf-8"),
            checker.render_dependabot_policy(),
        )

        raw = DEPENDABOT_PATH.read_text(encoding="utf-8").lower()
        self.assertNotIn("auto-merge", raw)
        self.assertNotIn("automerge", raw)

    def test_missing_swift_root_manifests_is_a_hard_failure(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / ".github").mkdir()
            shutil.copyfile(DEPENDABOT_PATH, root / ".github" / "dependabot.yml")
            (root / "docs").mkdir()
            (root / "docs" / "requirements.in").write_text(
                "mkdocs-material==9.7.7\n",
                encoding="utf-8",
            )
            shutil.copyfile(REQUIREMENTS_LOCK_PATH, root / "docs" / "requirements.txt")

            errors = checker.validate_dependabot(root)

            self.assertTrue(any("Swift root manifest" in error for error in errors))

    def test_missing_docs_lock_blocks_pip_dependabot(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / ".github").mkdir()
            shutil.copyfile(DEPENDABOT_PATH, root / ".github" / "dependabot.yml")
            (root / "Package.swift").write_text("// fixture\n", encoding="utf-8")
            (root / "Package.resolved").write_text("{}\n", encoding="utf-8")

            errors = checker.validate_dependabot(root)

            self.assertTrue(any("docs dependency lock" in error for error in errors))

    def test_noncanonical_yaml_encodings_are_rejected_byte_for_byte(self) -> None:
        checker = load_checker()
        canonical = DEPENDABOT_PATH.read_text(encoding="utf-8")
        invalid_documents = (
            canonical.replace(
                'prefix: "build(actions)"',
                "prefix: 'build(''actions'')'",
                1,
            ),
            canonical.replace(
                'package-ecosystem: "github-actions"',
                "package-ecosystem: github-actions",
                1,
            ),
            canonical.replace("version: 2", "version: 2 # equivalent comment", 1),
        )

        for index, document in enumerate(invalid_documents):
            with self.subTest(document=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                github = root / ".github"
                github.mkdir()
                (github / "dependabot.yml").write_text(document, encoding="utf-8")
                (root / "Package.swift").write_text("// fixture\n", encoding="utf-8")
                (root / "Package.resolved").write_text("{}\n", encoding="utf-8")
                docs = root / "docs"
                docs.mkdir()
                shutil.copyfile(REQUIREMENTS_IN_PATH, docs / "requirements.in")
                shutil.copyfile(REQUIREMENTS_LOCK_PATH, docs / "requirements.txt")

                errors = checker.validate_dependabot(root)

                self.assertNotEqual(errors, [])
                self.assertTrue(any("canonical" in error for error in errors))

    def test_rejects_symlinked_and_oversized_dependabot_policy(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            github = root / ".github"
            github.mkdir()
            target = root / "dependabot-source.yml"
            target.write_text(DEPENDABOT_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            (github / "dependabot.yml").symlink_to(target)

            errors = checker.validate_dependabot(root)

            self.assertTrue(any("dependabot.yml" in error for error in errors))

            (github / "dependabot.yml").unlink()
            (github / "dependabot.yml").write_text(
                "#" * (checker.MAX_DEPENDABOT_BYTES + 1),
                encoding="utf-8",
            )
            errors = checker.validate_dependabot(root)
            self.assertTrue(any("dependabot.yml" in error for error in errors))

    def test_rejects_nonregular_dependabot_policy_without_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            github = root / ".github"
            github.mkdir()
            os.mkfifo(github / "dependabot.yml")
            (root / "Package.swift").write_text("// fixture\n", encoding="utf-8")
            (root / "Package.resolved").write_text("{}\n", encoding="utf-8")
            docs = root / "docs"
            docs.mkdir()
            shutil.copyfile(REQUIREMENTS_IN_PATH, docs / "requirements.in")
            shutil.copyfile(REQUIREMENTS_LOCK_PATH, docs / "requirements.txt")

            result = subprocess.run(
                [sys.executable, str(CHECKER_PATH), "--root", str(root)],
                check=False,
                capture_output=True,
                text=True,
                timeout=1,
            )

            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
