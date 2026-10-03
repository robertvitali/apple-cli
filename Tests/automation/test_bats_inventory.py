import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
from types import ModuleType
from typing import Optional
import unittest
from contextlib import contextmanager, redirect_stderr, redirect_stdout


REPO_ROOT = Path(__file__).resolve().parents[2]
CHECKER_PATH = REPO_ROOT / "scripts" / "ci" / "bats_inventory.py"
MANIFEST_PATH = REPO_ROOT / "bats" / "tier-inventory.json"

EXPECTED_FILES = {
    "hosted": {
        "bats/hosted/bounded_exec.bats": 5,
        "bats/hosted/calendar.bats": 20,
        "bats/hosted/contacts.bats": 50,
        "bats/hosted/mail.bats": 120,
        "bats/hosted/messages.bats": 11,
        "bats/hosted/notes.bats": 39,
        "bats/hosted/reminders.bats": 38,
        "bats/hosted/smoke.bats": 26,
    },
    "local": {
        "bats/local/contacts.bats": 4,
        "bats/local/mail.bats": 113,
        "bats/local/mail-move-gmail.bats": 2,
        "bats/local/messages.bats": 15,
        "bats/local/notes.bats": 5,
        "bats/local/reminders.bats": 1,
        "bats/local/smoke.bats": 3,
    },
}
ROOT_CONTRACT = (
    'BATS_SUITE_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"',
    'REPO_ROOT="$(cd "$BATS_SUITE_ROOT/.." && pwd -P)"',
    'HELPERS="$BATS_SUITE_ROOT/helpers"',
)


def load_checker() -> ModuleType:
    spec = importlib.util.spec_from_file_location("bats_inventory", CHECKER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load Bats inventory checker")
    module = importlib.util.module_from_spec(spec)
    sys.modules["bats_inventory"] = module
    spec.loader.exec_module(module)
    return module


def title_digest(title: str) -> str:
    return hashlib.sha256(title.encode("utf-8")).hexdigest()


def bats_source(*titles: str, lifecycle: bool = False) -> str:
    tests = "\n\n".join(
        f'@test "{title}" {{\n  true\n}}' for title in titles
    )
    contract = "\n".join(ROOT_CONTRACT)
    hook = '\nload "$HELPERS/app_lifecycle"' if lifecycle else ""
    return f"#!/usr/bin/env bats\n\n{contract}{hook}\n\n{tests}\n"


def manifest_entry(root: Path, path: str, titles: list[str]) -> dict:
    return {
        "path": path,
        "test_count": len(titles),
        "ordered_title_sha256": [title_digest(title) for title in titles],
        "file_sha256": hashlib.sha256((root / path).read_bytes()).hexdigest(),
    }


def write_fixture_manifest(
    root: Path,
    *,
    hosted_titles: Optional[list[str]] = None,
    local_titles: Optional[list[str]] = None,
) -> Path:
    hosted_titles = hosted_titles or ["hosted example"]
    local_titles = local_titles or ["local example"]
    hosted_path = root / "bats" / "hosted" / "sample.bats"
    local_path = root / "bats" / "local" / "sample.bats"
    live_path = root / "bats" / "live" / "manual.sh"
    hosted_path.parent.mkdir(parents=True)
    local_path.parent.mkdir(parents=True)
    live_path.parent.mkdir(parents=True)
    for relative in load_checker().TRUSTED_HOSTED_HELPER_SHA256:
        destination = root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes((REPO_ROOT / relative).read_bytes())
    hosted_path.write_text(bats_source(*hosted_titles), encoding="utf-8")
    local_path.write_text(bats_source(*local_titles, lifecycle=True), encoding="utf-8")
    live_path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    manifest = {
        "schema_version": 1,
        "test_count": len(hosted_titles) + len(local_titles),
        "tiers": {
            "hosted": {
                "test_count": len(hosted_titles),
                "files": [
                    manifest_entry(root, "bats/hosted/sample.bats", hosted_titles)
                ],
            },
            "local": {
                "test_count": len(local_titles),
                "files": [
                    manifest_entry(root, "bats/local/sample.bats", local_titles)
                ],
            },
        },
        "live": {
            "test_count": 0,
            "files": ["bats/live/manual.sh"],
        },
    }
    manifest_path = root / "bats" / "tier-inventory.json"
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return manifest_path


def install_rehashed_source(root: Path, manifest_path: Path, tier: str, source: str) -> Path:
    """Replace the fixture's `tier` file and re-pin its digest, so only the reading is tested."""
    path = root / "bats" / tier / "sample.bats"
    path.write_text(source, encoding="utf-8")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["tiers"][tier]["files"][0]["file_sha256"] = hashlib.sha256(
        path.read_bytes()
    ).hexdigest()
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return path


def refusal_message(label: str, line: int, code: int) -> str:
    return (
        f"{label} line {line} contains refused character U+{code:04X} "
        "(only space, tab and line feed may be whitespace; no control, byte-order mark "
        "or bidirectional control)"
    )


@contextmanager
def refusal_bypassed(checker: ModuleType):
    """Stub out the character refusal, so a test reaches the tokenisers behind it."""
    original = checker._first_refused_character
    checker._first_refused_character = lambda _source: None
    try:
        yield
    finally:
        checker._first_refused_character = original


# Each fixture reads differently to Python's wide whitespace and line-break rules than to bash
# and bats, which split lines at a line feed only and treat only a space and a tab as blanks.
# Synthetic text only; `echo` and `osascript -e 'return 1'` stand in for real commands.
LIFECYCLE_LOAD = 'load "$HELPERS/app_lifecycle"'
FIXTURE_HEADER = "#!/usr/bin/env bats\n\n" + "\n".join(ROOT_CONTRACT) + "\n"
WHITESPACE_FIXTURES = {
    # A no-break space before `#` is not a comment to bash, which runs the command after `||`.
    "B1": (
        "hosted",
        FIXTURE_HEADER + '\n@test "hosted example" {\n  \u00a0# || osascript -e \'return 1\'\n}\n',
        8,
        0x00A0,
    ),
    # The lifecycle load sits inside a comment to bash (U+2028 is no line break there).
    "B2": (
        "local",
        FIXTURE_HEADER + "#\u2028" + LIFECYCLE_LOAD + '\n\n@test "local example" {\n  true\n}\n',
        6,
        0x2028,
    ),
    # Two comments ending in U+2028 and a quote flip a splitlines() reader's quote state, hiding a
    # lifecycle override and a test that bats counts.
    "B3": (
        "local",
        FIXTURE_HEADER
        + LIFECYCLE_LOAD
        + '\n# a \u2028"\nteardown_file() { :; }\n@test "hidden" {\n  true\n}\n'
        + '# b \u2028"\n@test "local example" {\n  true\n}\n',
        7,
        0x2028,
    ),
    # An executable line before the lifecycle load that a wide strip reads as a comment.
    "B4": (
        "local",
        FIXTURE_HEADER + "\u00a0# || echo PRE\n" + LIFECYCLE_LOAD
        + '\n\n@test "local example" {\n  true\n}\n',
        6,
        0x00A0,
    ),
    # A no-break-space-only line before the load is a command to bash, not a blank line.
    "B4b": (
        "local",
        FIXTURE_HEADER + "\u00a0\n" + LIFECYCLE_LOAD + '\n\n@test "local example" {\n  true\n}\n',
        6,
        0x00A0,
    ),
    # A test declaration bats never sees (it is inside a comment to bash).
    "B5": (
        "hosted",
        FIXTURE_HEADER + '\n# \u2028@test "phantom" {\n# \u2028}\n@test "hosted example" {\n  true\n}\n',
        7,
        0x2028,
    ),
    # Every shared-root contract line inside a comment to bash, so none of them runs.
    "B7": (
        "hosted",
        "#!/usr/bin/env bats\n\n"
        + "".join(f"#\u2028{line}\n" for line in ROOT_CONTRACT)
        + '\n@test "hosted example" {\n  true\n}\n',
        3,
        0x2028,
    ),
}
# Python treats each of these as whitespace or a line break; bash and bats treat none of them as
# a blank or a line feed, and the rest are controls, the byte-order mark or a bidirectional control.
REFUSED_SAMPLES = (
    "\u00a0", "\u1680", "\u2000", "\u2007", "\u200a", "\u2028", "\u2029", "\u202f", "\u205f",
    "\u3000", "\u0085", "\x0b", "\x0c", "\x1c", "\x1d", "\x1e", "\x1f", "\r", "\ufeff", "\u202e",
)


class BatsInventoryTests(unittest.TestCase):
    def test_checker_exists(self) -> None:
        self.assertTrue(CHECKER_PATH.is_file(), "Bats inventory checker must exist")

    def test_repository_manifest_pins_the_approved_partition(self) -> None:
        checker = load_checker()
        manifest = checker.load_manifest(MANIFEST_PATH)

        self.assertEqual(manifest["schema_version"], 1)
        self.assertEqual(manifest["test_count"], 452)
        self.assertEqual(
            {tier: manifest["tiers"][tier]["test_count"] for tier in ("hosted", "local")},
            {"hosted": 309, "local": 143},
        )
        self.assertEqual(
            {
                tier: {
                    entry["path"]: entry["test_count"]
                    for entry in manifest["tiers"][tier]["files"]
                }
                for tier in ("hosted", "local")
            },
            EXPECTED_FILES,
        )
        local_messages = next(
            entry
            for entry in manifest["tiers"]["local"]["files"]
            if entry["path"] == "bats/local/messages.bats"
        )
        self.assertEqual(
            local_messages["ordered_title_sha256"][-1],
            title_digest("messages send --dry-run --text neutralizes ANSI (Q12 [17])"),
        )
        moved_mail_titles = (
            "mail: sandbox:true is carried by rules-preview and trash-empty envelopes too (no forgotten emit site)",
            "v2 default: the flagless trash surface stays a dry-run preview (trash empty)",
            "mail trash empty dry-run previews without emptying trash (exit 0)",
            "every AppleScript embedded in MailScript.swift compiles (osacompile)",
            "mail trash empty --dry-run --text is HONORED (renders text, not JSON) (Q12 [10])",
        )
        hosted_mail_titles = checker.read_bats_file(
            REPO_ROOT / "bats" / "hosted" / "mail.bats",
            "bats/hosted/mail.bats",
        )[2]
        local_mail_titles = checker.read_bats_file(
            REPO_ROOT / "bats" / "local" / "mail.bats",
            "bats/local/mail.bats",
        )[2]
        for title in moved_mail_titles:
            self.assertNotIn(title, hosted_mail_titles)
            self.assertIn(title, local_mail_titles)
        self.assertEqual(
            checker.validate_repository(REPO_ROOT, MANIFEST_PATH),
            (),
        )
        probe_path = "bats/helpers/messages_db_probe.py"
        self.assertEqual(
            checker.TRUSTED_HOSTED_HELPER_SHA256.get(probe_path),
            hashlib.sha256((REPO_ROOT / probe_path).read_bytes()).hexdigest(),
        )
        for lifecycle_path in (
            "bats/helpers/app_lifecycle.py",
            "bats/helpers/app_lifecycle.bash",
        ):
            self.assertEqual(
                checker.TRUSTED_HOSTED_HELPER_SHA256.get(lifecycle_path),
                hashlib.sha256((REPO_ROOT / lifecycle_path).read_bytes()).hexdigest(),
            )

    def test_export_preview_uses_a_unique_absent_target_without_deleting_it(self) -> None:
        source = (REPO_ROOT / "bats/local/mail.bats").read_text(encoding="utf-8")
        body = source.split(
            '@test "mail export --dry-run writes nothing and reports the cap" {', 1
        )[1].split("\n}", 1)[0]
        preparation = body.split('run "$BIN"', 1)[0]
        self.assertNotIn("rm ", body)
        self.assertIn("${BATS_RUN_TMPDIR##*/}", preparation)
        self.assertIn("$BATS_TEST_NUMBER", preparation)
        self.assertIn('[ ! -e "$target" ]', preparation)
        self.assertIn('[ ! -L "$target" ]', preparation)

    def test_app_lifecycle_hook_is_local_only_and_loaded_by_every_local_file(self) -> None:
        local_files = sorted((REPO_ROOT / "bats" / "local").glob("*.bats"))
        hosted_files = sorted((REPO_ROOT / "bats" / "hosted").glob("*.bats"))
        hook_load = 'load "$HELPERS/app_lifecycle"'

        self.assertEqual(len(local_files), 7)
        for path in local_files:
            with self.subTest(path=path.relative_to(REPO_ROOT).as_posix()):
                self.assertIn(hook_load, path.read_text(encoding="utf-8"))
        for path in hosted_files:
            with self.subTest(path=path.relative_to(REPO_ROOT).as_posix()):
                self.assertNotIn("app_lifecycle", path.read_text(encoding="utf-8"))

    def test_rejects_non_executable_local_lifecycle_loads_end_to_end(self) -> None:
        checker = load_checker()
        disguised_loads = (
            "cat <<'PAYLOAD' >/dev/null\n"
            'load "$HELPERS/app_lifecycle"\n'
            "PAYLOAD",
            '@test "local example" {\n'
            'load "$HELPERS/app_lifecycle"\n'
            "  true\n"
            "}",
            "if false; then\n"
            'load "$HELPERS/app_lifecycle"\n'
            "fi",
            "false && \\\n"
            'load "$HELPERS/app_lifecycle"',
        )
        for disguised_load in disguised_loads:
            with self.subTest(disguised_load=disguised_load), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                manifest_path = write_fixture_manifest(root)
                local = root / "bats" / "local" / "sample.bats"
                source = bats_source("local example")
                if disguised_load.startswith("@test"):
                    source = source.replace(
                        '@test "local example" {\n  true\n}',
                        disguised_load,
                    )
                else:
                    source = source.replace("\n\n@test", f"\n{disguised_load}\n\n@test")
                local.write_text(source, encoding="utf-8")
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                manifest["tiers"]["local"]["files"][0]["file_sha256"] = hashlib.sha256(
                    local.read_bytes()
                ).hexdigest()
                manifest_path.write_text(
                    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )

                errors = checker.validate_repository(root, manifest_path)

            self.assertTrue(
                any("executable top-level app lifecycle hook" in error for error in errors),
                errors,
            )

    def test_rejects_local_lifecycle_load_before_ordered_header_end_to_end(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            local = root / "bats" / "local" / "sample.bats"
            local.write_text(
                "#!/usr/bin/env bats\n\n"
                'load "$HELPERS/app_lifecycle"\n'
                + "\n".join(ROOT_CONTRACT)
                + '\n\n@test "local example" {\n  true\n}\n',
                encoding="utf-8",
            )
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["tiers"]["local"]["files"][0]["file_sha256"] = hashlib.sha256(
                local.read_bytes()
            ).hexdigest()
            manifest_path.write_text(
                json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )

            errors = checker.validate_repository(root, manifest_path)

        self.assertTrue(
            any("ordered header" in error for error in errors),
            errors,
        )

    def test_rejects_local_lifecycle_hook_overrides_end_to_end(self) -> None:
        checker = load_checker()
        definitions = (
            "setup_file() {\n  true\n}",
            "teardown_file() {\n  true\n}",
            "setup_file()\n{ true; }",
            "setup_file \\\n() {\n  true\n}",
            "setup_file()\n# synthetic comment\n{ true; }",
        )
        for definition in definitions:
            with self.subTest(definition=definition), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                manifest_path = write_fixture_manifest(root)
                local = root / "bats" / "local" / "sample.bats"
                local.write_text(
                    bats_source("local example", lifecycle=True)
                    + f"\n{definition}\n",
                    encoding="utf-8",
                )
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                manifest["tiers"]["local"]["files"][0]["file_sha256"] = hashlib.sha256(
                    local.read_bytes()
                ).hexdigest()
                manifest_path.write_text(
                    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )

                errors = checker.validate_repository(root, manifest_path)

            self.assertTrue(
                any("overrides app lifecycle hook" in error for error in errors),
                errors,
            )

    def test_app_lifecycle_helper_mutation_is_rejected(self) -> None:
        checker = load_checker()
        for relative in (
            "bats/helpers/app_lifecycle.py",
            "bats/helpers/app_lifecycle.bash",
        ):
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as temporary_directory:
                expected = checker.TRUSTED_HOSTED_HELPER_SHA256[relative]
                root = Path(temporary_directory)
                helper = root / relative
                helper.parent.mkdir(parents=True)
                helper.write_bytes((REPO_ROOT / relative).read_bytes() + b"\n# mutation\n")
                original_catalog = checker.TRUSTED_HOSTED_HELPER_SHA256
                checker.TRUSTED_HOSTED_HELPER_SHA256 = {relative: expected}
                try:
                    errors = checker._validate_trusted_hosted_helpers(root)
                finally:
                    checker.TRUSTED_HOSTED_HELPER_SHA256 = original_catalog

            self.assertTrue(any("hosted helper catalog drift" in error for error in errors), errors)

    def test_missing_lifecycle_helpers_are_rejected_end_to_end(self) -> None:
        checker = load_checker()
        for relative in (
            "bats/helpers/app_lifecycle.py",
            "bats/helpers/app_lifecycle.bash",
        ):
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                repository_root = root / "repository"
                repository_manifest = write_fixture_manifest(repository_root)
                (repository_root / relative).unlink()
                repository_errors = checker.validate_repository(
                    repository_root,
                    repository_manifest,
                )

                policy_root = root / "policy"
                candidate_root = root / "candidate"
                policy_manifest = write_fixture_manifest(policy_root)
                candidate_manifest = write_fixture_manifest(candidate_root)
                (candidate_root / relative).unlink()
                candidate_errors = checker.validate_candidate_repository(
                    policy_root,
                    policy_manifest,
                    candidate_root,
                    candidate_manifest,
                )

            self.assertTrue(any("hosted helper catalog drift" in error for error in repository_errors))
            self.assertTrue(any("hosted helper catalog drift" in error for error in candidate_errors))

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            repository_root = root / "repository"
            repository_manifest = write_fixture_manifest(repository_root)
            shutil.rmtree(repository_root / "bats" / "helpers")
            repository_errors = checker.validate_repository(
                repository_root,
                repository_manifest,
            )

            policy_root = root / "policy"
            candidate_root = root / "candidate"
            policy_manifest = write_fixture_manifest(policy_root)
            candidate_manifest = write_fixture_manifest(candidate_root)
            shutil.rmtree(candidate_root / "bats" / "helpers")
            candidate_errors = checker.validate_candidate_repository(
                policy_root,
                policy_manifest,
                candidate_root,
                candidate_manifest,
            )

        self.assertTrue(any("hosted helper catalog drift" in error for error in repository_errors))
        self.assertTrue(any("hosted helper catalog drift" in error for error in candidate_errors))

    def test_partition_does_not_overwrite_bats_internal_root(self) -> None:
        for path in sorted((REPO_ROOT / "bats").glob("*/*.bats")):
            with self.subTest(path=path.relative_to(REPO_ROOT).as_posix()):
                source = path.read_text(encoding="utf-8")
                self.assertNotRegex(source, r"(?m)^BATS_ROOT=")
                for contract_line in ROOT_CONTRACT:
                    self.assertIn(contract_line, source)

    def test_valid_fixture_passes(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)

            self.assertEqual(checker.validate_repository(root, manifest_path), ())

    def test_counts_only_real_tests_outside_comments_strings_and_heredocs(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            hosted = root / "bats" / "hosted" / "sample.bats"
            contract = "\n".join(ROOT_CONTRACT)
            source = (
                "#!/usr/bin/env bats\n\n"
                f"{contract}\n\n"
                "# @test \"comment example\" {\n"
                "payload='\n"
                "@test \"string example\" {\n"
                "'\n"
                "cat <<'PAYLOAD' >/dev/null\n"
                "@test \"heredoc example\" {\n"
                "PAYLOAD\n\n"
                "@test \"hosted example\" {\n"
                "  true\n"
                "}\n"
            )
            hosted.write_text(source, encoding="utf-8")
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["tiers"]["hosted"]["files"][0]["file_sha256"] = hashlib.sha256(
                hosted.read_bytes()
            ).hexdigest()
            manifest_path.write_text(
                json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )

            errors = checker.validate_repository(root, manifest_path)

        self.assertEqual(errors, ())

    def test_cross_checks_parser_count_against_bats_discovery(self) -> None:
        checker = load_checker()
        original = getattr(checker, "_discover_bats_count", None)
        checker._discover_bats_count = lambda _path, _relative: 2
        try:
            with tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                manifest_path = write_fixture_manifest(root)

                errors = checker.validate_repository(root, manifest_path)
        finally:
            if original is None:
                del checker._discover_bats_count
            else:
                checker._discover_bats_count = original

        self.assertTrue(
            any("Bats discovery test-count drift" in error for error in errors),
            errors,
        )

    def test_static_bats_discovery_counts_without_external_bats(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            observed_path = root / "observed.txt"
            candidate = root / "sample.bats"
            candidate.write_text(
                textwrap.dedent(
                    f"""\
                    #!/usr/bin/env bats
                    touch {observed_path}

                    @test "sample" {{
                      true
                    }}
                    """
                ),
                encoding="utf-8",
            )

            self.assertEqual(
                checker._discover_bats_count(candidate, "private-candidate-path"),
                1,
            )
            self.assertFalse(observed_path.exists())

    def test_static_bats_discovery_uses_same_syntax_rejections(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            candidate = root / "sample.bats"
            candidate.write_text(
                "#!/usr/bin/env bats\n\n@test unquoted_title {\n  true\n}\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                checker.InventoryError,
                "^unknown @test declaration syntax in Bats file$",
            ):
                checker._discover_bats_count(candidate, "private-candidate-path")

    def test_rejects_unknown_test_declaration_syntax(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            hosted = root / "bats" / "hosted" / "sample.bats"
            hosted.write_text(
                "#!/usr/bin/env bats\n\n@test unquoted_title {\n  true\n}\n",
                encoding="utf-8",
            )

            errors = checker.validate_repository(root, manifest_path)

        self.assertTrue(any("unknown @test declaration syntax" in error for error in errors))

    def test_rejects_duplicate_titles_and_empty_inventory_files(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            hosted = root / "bats" / "hosted" / "sample.bats"
            hosted.write_text(bats_source("same title", "same title"), encoding="utf-8")

            duplicate_errors = checker.validate_repository(root, manifest_path)

            hosted.write_text("#!/usr/bin/env bats\n", encoding="utf-8")
            empty_errors = checker.validate_repository(root, manifest_path)

        self.assertTrue(any("duplicate test title" in error for error in duplicate_errors))
        self.assertTrue(any("contains no tests" in error for error in empty_errors))

    def test_rejects_manifest_drift_and_unexpected_test_locations(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            hosted = root / "bats" / "hosted" / "sample.bats"
            hosted.write_text(bats_source("changed title"), encoding="utf-8")
            unexpected = root / "bats" / "unexpected.bats"
            unexpected.write_text(bats_source("unexpected"), encoding="utf-8")

            errors = checker.validate_repository(root, manifest_path)

        self.assertTrue(any("ordered test-title identity drift" in error for error in errors))
        self.assertTrue(any("unexpected Bats test file" in error for error in errors))

    def test_rejects_same_title_test_body_drift(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            hosted = root / "bats" / "hosted" / "sample.bats"
            hosted.write_text(
                bats_source("hosted example").replace("  true", "  false"),
                encoding="utf-8",
            )

            errors = checker.validate_repository(root, manifest_path)

        self.assertTrue(any("file content drift" in error for error in errors))

    def test_rejects_same_title_hosted_direct_live_read_even_when_rehashed(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            hosted = root / "bats" / "hosted" / "sample.bats"
            hosted.write_text(
                bats_source("hosted example").replace(
                    "  true",
                    '  run sqlite3 "$HOME/Library/Messages/chat.db" "select 1"',
                ),
                encoding="utf-8",
            )
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["tiers"]["hosted"]["files"][0]["file_sha256"] = hashlib.sha256(
                hosted.read_bytes()
            ).hexdigest()
            manifest_path.write_text(
                json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )

            errors = checker.validate_repository(root, manifest_path)

        self.assertTrue(any("hosted file contains live-state access" in error for error in errors))

    def test_rejects_known_cli_paths_that_probe_live_state_even_when_rehashed(self) -> None:
        checker = load_checker()
        commands = (
            '  run "$BIN" messages send 2125550100 --message synthetic --dry-run',
            '  run "${BIN}" messages send 2125550100 --message synthetic --dry-run',
            '  cli="$BIN"\n  run "$cli" messages send 2125550100 --message synthetic --dry-run',
            '  domain=messages\n  action=send\n  run "$BIN" "$domain" "$action" 2125550100 --message synthetic --dry-run',
            '  argv=(messages send 2125550100 --message synthetic --dry-run)\n  run "$BIN" "${argv[@]}"',
            '  argv=("$BIN" messages send 2125550100 --message synthetic --dry-run)\n  run "${argv[@]}"',
            '  run apple messages send 2125550100 --message synthetic --dry-run',
            '  run "$BIN" reminders doctor',
            '  domain=reminders\n  action=doctor\n  run "${BIN}" "$domain" "$action"',
            '  run "$BIN" reminders doctor; printf "%s" --help',
        )
        for command in commands:
            with self.subTest(command=command), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                manifest_path = write_fixture_manifest(root)
                hosted = root / "bats" / "hosted" / "sample.bats"
                hosted.write_text(
                    bats_source("hosted example").replace("  true", command),
                    encoding="utf-8",
                )
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                manifest["tiers"]["hosted"]["files"][0]["file_sha256"] = hashlib.sha256(
                    hosted.read_bytes()
                ).hexdigest()
                manifest_path.write_text(
                    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )

                errors = checker.validate_repository(root, manifest_path)

            self.assertTrue(
                any("hosted file contains live-state access" in error for error in errors)
            )

    def test_rejects_obfuscated_live_paths_and_non_enumerated_cli_reads(self) -> None:
        checker = load_checker()
        commands = (
            '  target="$HOME""/Library/""Messages/chat.db"\n  run test -r "$target"',
            '  base="$HOME/Library"\n  area=Messages\n  target="$base/$area/chat.db"\n  run test -r "$target"',
            '  first=mess\n  second=ages\n  third=rec\n  fourth=ent\n  run "$BIN" "$first$second" "$third$fourth" --limit 1',
            '  run "$BIN" messages recent --limit 1',
            '  tool="$(printf apple)"\n  run "$tool" messages recent --limit 1',
            '  tool=`printf apple`\n  run "$tool" messages recent --limit 1',
            '  run "$unknown_tool" messages recent --limit 1',
            '  tool="$REPO_ROOT/.build/debug/apple"\n  run "$tool" messages recent --limit 1',
            '  run "$BIN" mes""sages rec""ent --limit 1',
            '  run "$REPO_ROOT/.build/debug/ap""ple" messages recent --limit 1',
            '  run "sql""ite3" "$BATS_TEST_TMPDIR/synthetic.db" "select 1"',
            '  runner=("$REPO_ROOT/.build/debug/ap""ple")\n  run "${runner[@]}" messages recent --limit 1',
        )
        for command in commands:
            with self.subTest(command=command), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                manifest_path = write_fixture_manifest(root)
                hosted = root / "bats" / "hosted" / "sample.bats"
                hosted.write_text(
                    bats_source("hosted example").replace("  true", command),
                    encoding="utf-8",
                )
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                manifest["tiers"]["hosted"]["files"][0]["file_sha256"] = hashlib.sha256(
                    hosted.read_bytes()
                ).hexdigest()
                manifest_path.write_text(
                    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )

                errors = checker.validate_repository(root, manifest_path)

            self.assertTrue(
                any("hosted file contains live-state access" in error for error in errors),
                errors,
            )

    def test_hosted_detector_allows_help_and_non_cli_fixture_checks(self) -> None:
        checker = load_checker()
        controls = (
            '  run "$BIN" messages --help',
            '  run test -r "$BATS_TEST_TMPDIR/synthetic.db"',
            '  tool=test\n  run "$tool" -r "$BATS_TEST_TMPDIR/synthetic.db"',
        )
        for command in controls:
            with self.subTest(command=command), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                manifest_path = write_fixture_manifest(root)
                hosted = root / "bats" / "hosted" / "sample.bats"
                hosted.write_text(
                    bats_source("hosted example").replace("  true", command),
                    encoding="utf-8",
                )
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                manifest["tiers"]["hosted"]["files"][0]["file_sha256"] = hashlib.sha256(
                    hosted.read_bytes()
                ).hexdigest()
                manifest_path.write_text(
                    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )

                errors = checker.validate_repository(root, manifest_path)

            self.assertFalse(
                any("hosted file contains live-state access" in error for error in errors),
                errors,
            )

    def test_rejects_quoted_live_tool_invocation_even_when_rehashed(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            hosted = root / "bats" / "hosted" / "sample.bats"
            hosted.write_text(
                bats_source("hosted example").replace(
                    "  true",
                    '  run "/usr/bin/osascript" -e "return 1"',
                ),
                encoding="utf-8",
            )
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["tiers"]["hosted"]["files"][0]["file_sha256"] = hashlib.sha256(
                hosted.read_bytes()
            ).hexdigest()
            manifest_path.write_text(
                json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )

            errors = checker.validate_repository(root, manifest_path)

        self.assertTrue(any("hosted file contains live-state access" in error for error in errors))

    def test_rejects_bats_declarations_under_live(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            live = root / "bats" / "live" / "manual.sh"
            live.write_text(bats_source("must not run here"), encoding="utf-8")

            errors = checker.validate_repository(root, manifest_path)

        self.assertTrue(any("live file contains a Bats test declaration" in error for error in errors))

    def test_rejects_live_helper_references_in_hosted_tests(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            hosted = root / "bats" / "hosted" / "sample.bats"
            hosted.write_text(
                bats_source("hosted example") + "\nrequire_index\n",
                encoding="utf-8",
            )

            errors = checker.validate_repository(root, manifest_path)

        self.assertTrue(any("hosted file references live-only helper" in error for error in errors))

    def test_rejects_overwriting_bats_internal_root(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            hosted = root / "bats" / "hosted" / "sample.bats"
            hosted.write_text(
                bats_source("hosted example") + '\nBATS_ROOT="synthetic"\n',
                encoding="utf-8",
            )

            errors = checker.validate_repository(root, manifest_path)

        self.assertTrue(any("reserved BATS_ROOT" in error for error in errors))

    def test_rejects_missing_root_contract_and_stale_nested_paths(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            hosted = root / "bats" / "hosted" / "sample.bats"
            source = hosted.read_text(encoding="utf-8")
            hosted.write_text(
                source.replace(ROOT_CONTRACT[2], 'HELPERS="$BATS_TEST_DIRNAME/helpers"'),
                encoding="utf-8",
            )

            errors = checker.validate_repository(root, manifest_path)

        self.assertTrue(any("shared-root contract" in error for error in errors))

    def test_rejects_symlinked_inventory_and_live_files(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            external = root / "external.bats"
            external.write_text(bats_source("external test"), encoding="utf-8")

            hosted = root / "bats" / "hosted" / "sample.bats"
            hosted.unlink()
            hosted.symlink_to(external)
            inventory_errors = checker.validate_repository(root, manifest_path)

            hosted.unlink()
            hosted.write_text(bats_source("hosted example"), encoding="utf-8")
            live = root / "bats" / "live" / "manual.sh"
            live.unlink()
            live.symlink_to(external)
            live_errors = checker.validate_repository(root, manifest_path)

        self.assertTrue(
            any("missing or not a regular file" in error for error in inventory_errors)
        )
        self.assertTrue(any("live file is a symlink" in error for error in live_errors))
        self.assertFalse(
            any("live file contains a Bats test declaration" in error for error in live_errors)
        )

    def test_rejects_oversized_or_symlinked_policy_inputs_without_reading_them(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            hosted = root / "bats" / "hosted" / "sample.bats"
            original_manifest = manifest_path.read_bytes()
            original_hosted = hosted.read_bytes()
            hosted.write_bytes(b"#!/usr/bin/env bats\n" + b"x" * (2 * 1024 * 1024))
            oversized_bats_errors = checker.validate_repository(root, manifest_path)

            hosted.write_bytes(original_hosted)
            manifest_path.write_bytes(b"{" + b" " * (1024 * 1024) + b"}")
            oversized_manifest_errors = checker.validate_repository(root, manifest_path)

            manifest_path.write_bytes(original_manifest)
            external_manifest = root / "external-manifest.json"
            external_manifest.write_bytes(manifest_path.read_bytes())
            manifest_path.unlink()
            manifest_path.symlink_to(external_manifest)
            symlink_manifest_errors = checker.validate_repository(root, manifest_path)

        self.assertTrue(any("Bats file is too large" in error for error in oversized_bats_errors))
        self.assertTrue(
            any("inventory manifest is too large" in error for error in oversized_manifest_errors)
        )
        self.assertTrue(
            any("inventory manifest is not a regular file" in error for error in symlink_manifest_errors)
        )

    def test_recursive_scan_enforces_count_depth_and_aggregate_bounds(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            bats_root = root / "bats"
            files = [path for path in bats_root.rglob("*") if path.is_file()]
            exact_limits = {
                "MAX_SCAN_FILES": len(files),
                "MAX_SCAN_DEPTH": max(
                    len(path.relative_to(bats_root).parts) for path in files
                ),
                "MAX_SCAN_AGGREGATE_BYTES": sum(path.stat().st_size for path in files),
            }
            for name, value in exact_limits.items():
                setattr(checker, name, value)

            self.assertEqual(checker.validate_repository(root, manifest_path), ())

            cases = (
                ("MAX_SCAN_FILES", "file-count limit"),
                ("MAX_SCAN_DEPTH", "depth limit"),
                ("MAX_SCAN_AGGREGATE_BYTES", "aggregate-byte limit"),
            )
            for name, expected in cases:
                with self.subTest(limit=name):
                    setattr(checker, name, exact_limits[name] - 1)
                    errors = checker.validate_repository(root, manifest_path)
                    self.assertTrue(any(expected in error for error in errors))
                    setattr(checker, name, exact_limits[name])

    def test_trusted_catalog_rejects_reduction_reclassification_and_hosted_changes(self) -> None:
        checker = load_checker()
        cases = (
            (
                ["hosted example"],
                ["local one", "local two"],
                ["hosted example"],
                ["local one"],
                None,
                "trusted local catalog",
            ),
            (
                ["hosted example"],
                ["local example"],
                ["local example"],
                ["hosted example"],
                None,
                "trusted hosted catalog",
            ),
            (
                ["hosted example"],
                ["local example"],
                ["hosted example", "new hosted example"],
                ["local example"],
                None,
                "trusted hosted catalog",
            ),
            (
                ["hosted example"],
                ["local example"],
                ["hosted example"],
                ["local example"],
                "rehash-hosted-body",
                "trusted hosted file",
            ),
            (
                ["hosted example"],
                ["local example"],
                ["hosted example"],
                ["local example"],
                "rehash-local-body",
                "trusted local file",
            ),
        )
        for (
            policy_hosted,
            policy_local,
            candidate_hosted,
            candidate_local,
            mutation,
            expected,
        ) in cases:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                policy_root = root / "policy"
                candidate_root = root / "candidate"
                policy_manifest = write_fixture_manifest(
                    policy_root,
                    hosted_titles=policy_hosted,
                    local_titles=policy_local,
                )
                candidate_manifest = write_fixture_manifest(
                    candidate_root,
                    hosted_titles=candidate_hosted,
                    local_titles=candidate_local,
                )
                if mutation == "rehash-hosted-body":
                    hosted = candidate_root / "bats" / "hosted" / "sample.bats"
                    hosted.write_text(
                        hosted.read_text(encoding="utf-8").replace("  true", "  false"),
                        encoding="utf-8",
                    )
                    manifest = json.loads(candidate_manifest.read_text(encoding="utf-8"))
                    manifest["tiers"]["hosted"]["files"][0]["file_sha256"] = (
                        hashlib.sha256(hosted.read_bytes()).hexdigest()
                    )
                    candidate_manifest.write_text(
                        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                        encoding="utf-8",
                    )
                if mutation == "rehash-local-body":
                    local = candidate_root / "bats" / "local" / "sample.bats"
                    local.write_text(
                        local.read_text(encoding="utf-8").replace("  true", "  false"),
                        encoding="utf-8",
                    )
                    manifest = json.loads(candidate_manifest.read_text(encoding="utf-8"))
                    manifest["tiers"]["local"]["files"][0]["file_sha256"] = (
                        hashlib.sha256(local.read_bytes()).hexdigest()
                    )
                    candidate_manifest.write_text(
                        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                        encoding="utf-8",
                    )

                errors = checker.validate_candidate_repository(
                    policy_root,
                    policy_manifest,
                    candidate_root,
                    candidate_manifest,
                )

                self.assertTrue(
                    any(expected in error for error in errors),
                    errors,
                )

    def test_trusted_catalog_rejects_messages_database_probe_changes(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            policy_root = root / "policy"
            candidate_root = root / "candidate"
            policy_manifest = write_fixture_manifest(policy_root)
            candidate_manifest = write_fixture_manifest(candidate_root)
            helper = candidate_root / "bats" / "helpers" / "messages_db_probe.py"
            helper.parent.mkdir(parents=True, exist_ok=True)
            helper.write_text("# helper v1\n", encoding="utf-8")
            expected = hashlib.sha256(helper.read_bytes()).hexdigest()
            original_catalog = checker.TRUSTED_HOSTED_HELPER_SHA256
            checker.TRUSTED_HOSTED_HELPER_SHA256 = {
                "bats/helpers/messages_db_probe.py": expected,
            }
            try:
                helper.write_text("# helper v2\n", encoding="utf-8")

                errors = checker.validate_candidate_repository(
                    policy_root,
                    policy_manifest,
                    candidate_root,
                    candidate_manifest,
                )
            finally:
                checker.TRUSTED_HOSTED_HELPER_SHA256 = original_catalog

            self.assertTrue(
                any("hosted helper catalog drift" in error for error in errors),
                errors,
            )

    def test_trusted_catalog_allows_self_consistent_new_local_files(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            policy_root = root / "policy"
            candidate_root = root / "candidate"
            policy_manifest = write_fixture_manifest(policy_root)
            candidate_manifest = write_fixture_manifest(candidate_root)
            addition_path = candidate_root / "bats" / "local" / "addition.bats"
            addition_titles = ["new local example"]
            addition_path.write_text(
                bats_source(*addition_titles, lifecycle=True),
                encoding="utf-8",
            )
            manifest = json.loads(candidate_manifest.read_text(encoding="utf-8"))
            manifest["test_count"] += 1
            manifest["tiers"]["local"]["test_count"] += 1
            manifest["tiers"]["local"]["files"].append(
                manifest_entry(
                    candidate_root,
                    "bats/local/addition.bats",
                    addition_titles,
                )
            )
            candidate_manifest.write_text(
                json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )

            errors = checker.validate_candidate_repository(
                policy_root,
                policy_manifest,
                candidate_root,
                candidate_manifest,
            )

        self.assertEqual(errors, ())

    def test_duplicate_manifest_keys_are_rejected(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            manifest_path = Path(temporary_directory) / "manifest.json"
            manifest_path.write_text(
                '{"schema_version":1,"schema_version":1}',
                encoding="utf-8",
            )

            with self.assertRaisesRegex(checker.InventoryError, "duplicate JSON key"):
                checker.load_manifest(manifest_path)

    def test_rejects_unknown_manifest_fields(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["unexpected"] = True
            manifest_path.write_text(
                json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )

            errors = checker.validate_repository(root, manifest_path)

        self.assertTrue(any("unexpected fields" in error for error in errors))

    def test_rejects_unknown_tier_entry_and_live_fields(self) -> None:
        checker = load_checker()
        mutations = (
            lambda manifest: manifest["tiers"]["hosted"].__setitem__("unexpected", True),
            lambda manifest: manifest["tiers"]["hosted"]["files"][0].__setitem__(
                "unexpected", True
            ),
            lambda manifest: manifest["live"].__setitem__("unexpected", True),
        )
        for mutate in mutations:
            with self.subTest(mutation=mutate), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                manifest_path = write_fixture_manifest(root)
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                mutate(manifest)
                manifest_path.write_text(
                    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )

                errors = checker.validate_repository(root, manifest_path)

            self.assertTrue(any("unexpected fields" in error for error in errors))

    def test_cli_reports_value_free_failure_and_success(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            completed = subprocess.run(
                [
                    sys.executable,
                    str(CHECKER_PATH),
                    "--root",
                    str(root),
                    "--manifest",
                    str(manifest_path),
                ],
                check=False,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(completed.stdout, "Bats tier inventory: 2 tests verified\n")
            self.assertEqual(completed.stderr, "")

            (root / "bats" / "hosted" / "sample.bats").write_text(
                bats_source("private candidate title"),
                encoding="utf-8",
            )
            failed = subprocess.run(
                [
                    sys.executable,
                    str(CHECKER_PATH),
                    "--root",
                    str(root),
                    "--manifest",
                    str(manifest_path),
                ],
                check=False,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

        self.assertEqual(failed.returncode, 1)
        self.assertEqual(failed.stdout, "")
        self.assertIn("Bats tier inventory failed:", failed.stderr)
        self.assertNotIn("hosted example", failed.stderr)
        self.assertNotIn("private candidate title", failed.stderr)

    def test_public_diagnostics_never_echo_candidate_paths_or_control_text(self) -> None:
        checker = load_checker()
        sentinel = "private-candidate-path\x1b[31m"
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["tiers"]["hosted"]["files"][0]["path"] = (
                f"bats/hosted/{sentinel}.bats"
            )
            manifest_path.write_text(
                json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            stdout = io.StringIO()
            stderr = io.StringIO()

            with redirect_stdout(stdout), redirect_stderr(stderr):
                status = checker.run(
                    ["--root", str(root), "--manifest", str(manifest_path)]
                )

        rendered = stdout.getvalue() + stderr.getvalue()
        self.assertEqual(status, 1)
        self.assertNotIn(sentinel, rendered)
        self.assertNotIn("\x1b", rendered)
        self.assertNotIn(str(root), rendered)

    def test_duplicate_key_diagnostic_never_echoes_candidate_key(self) -> None:
        checker = load_checker()
        sentinel = "private-candidate-key"
        with tempfile.TemporaryDirectory() as temporary_directory:
            manifest_path = Path(temporary_directory) / "manifest.json"
            manifest_path.write_text(
                f'{{"{sentinel}":1,"{sentinel}":2}}',
                encoding="utf-8",
            )

            with self.assertRaises(checker.InventoryError) as raised:
                checker.load_manifest(manifest_path)

        self.assertNotIn(sentinel, str(raised.exception))

    def test_refused_character_rule_matches_the_workflow_scan(self) -> None:
        # The inventory carries a copy of the workflow scan's rule; every code point must agree.
        checker = load_checker()
        spec = importlib.util.spec_from_file_location(
            "workflow_policy", REPO_ROOT / "scripts" / "ci" / "workflow_policy.py"
        )
        policy = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(policy)
        disagreements = [
            code for code in range(0x110000)
            if checker._refused_character(chr(code)) != policy.refused_character(chr(code), " \t")
        ]
        self.assertEqual(disagreements, [])
        self.assertFalse(checker._refused_character(" "))
        self.assertFalse(checker._refused_character("\t"))
        self.assertTrue(checker._refused_character("\n"))  # line feeds are split out before the check

    def test_bats_readers_refuse_unicode_whitespace_and_controls_before_tokenising(self) -> None:
        checker = load_checker()
        sentinel = "private-candidate-text"
        for character in REFUSED_SAMPLES:
            with self.subTest(code_point=f"U+{ord(character):04X}"), tempfile.TemporaryDirectory() as temporary_directory:
                candidate = Path(temporary_directory) / "sample.bats"
                candidate.write_text(
                    FIXTURE_HEADER + f"# {sentinel}{character}x\n"
                    + '\n@test "hosted example" {\n  true\n}\n',
                    encoding="utf-8",
                )
                expected = refusal_message("Bats file", 6, ord(character))

                with self.assertRaises(checker.InventoryError) as parse_refusal:
                    checker._parse_bats_source(
                        candidate.read_bytes().decode("utf-8"), "bats/hosted/sample.bats"
                    )
                with self.assertRaises(checker.InventoryError) as read_refusal:
                    checker.read_bats_file(candidate, "bats/hosted/sample.bats")
                with self.assertRaises(checker.InventoryError) as discovery_refusal:
                    checker._discover_bats_count(candidate, "bats/hosted/sample.bats")

            self.assertEqual(str(parse_refusal.exception), expected)
            self.assertEqual(str(read_refusal.exception), expected)
            self.assertEqual(str(discovery_refusal.exception), expected)
            self.assertNotIn(sentinel, expected)
        self.assertEqual(checker._first_refused_character("a\tb \nc\n"), None)
        self.assertEqual(checker._first_refused_character("a\nb\u2028c\n"), (2, 0x2028))

    def test_misleading_whitespace_fixtures_are_refused_end_to_end(self) -> None:
        checker = load_checker()
        for name, (tier, source, line, code) in WHITESPACE_FIXTURES.items():
            with self.subTest(fixture=name), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                manifest_path = write_fixture_manifest(root)
                install_rehashed_source(root, manifest_path, tier, source)
                stdout = io.StringIO()
                stderr = io.StringIO()

                errors = checker.validate_repository(root, manifest_path)
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    status = checker.run(["--root", str(root), "--manifest", str(manifest_path)])

            self.assertIn(refusal_message("Bats file", line, code), errors)
            self.assertEqual(status, 1)
            rendered = stdout.getvalue() + stderr.getvalue()
            self.assertIn(f"U+{code:04X}", rendered)
            for fixture_line in source.split("\n"):
                if any(checker._refused_character(character) for character in fixture_line):
                    self.assertNotIn(fixture_line, rendered)
            self.assertNotIn("osascript", rendered)
            self.assertNotIn("phantom", rendered)

    def test_live_file_with_refused_character_is_rejected(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            live = root / "bats" / "live" / "manual.sh"
            # To sh the no-break space starts a command word, so `# @test` is not a comment.
            live.write_text("#!/bin/sh\n\u00a0# @test\nexit 0\n", encoding="utf-8")

            errors = checker.validate_repository(root, manifest_path)

        self.assertEqual(errors, (refusal_message("live file", 2, 0x00A0),))

    def test_line_splitting_follows_line_feeds_only(self) -> None:
        checker = load_checker()
        for sample in ("", "\n", "a", "a\n", "a\n\n", "a\nb", "a\n\nb\n", "\n\na\n"):
            with self.subTest(sample=sample):
                self.assertEqual(checker._lf_lines(sample), sample.splitlines())
        self.assertEqual(
            checker._lf_lines("a\u2028b\u2029c\x85d\re\x0bf\x0cg\x1ch\ni\n"),
            ["a\u2028b\u2029c\x85d\re\x0bf\x0cg\x1ch", "i"],
        )

    def test_tokenizer_keeps_shell_state_across_unicode_separators_in_comments(self) -> None:
        # Called with the refusal bypassed: a U+2028 inside a comment or a heredoc body ends
        # nothing for bash, so neither the quote state, the heredoc nor the declared tests change.
        checker = load_checker()
        _, b3, _, _ = WHITESPACE_FIXTURES["B3"]
        _, b5, _, _ = WHITESPACE_FIXTURES["B5"]
        _, b2, _, _ = WHITESPACE_FIXTURES["B2"]
        # Bash keeps `x<U+2028>EOF` as one heredoc body line, so the heredoc runs on past the
        # quote to the real `EOF`; a reader that broke the line there would end the heredoc early
        # and then read the quote as opening an unterminated string.
        heredoc_body = 'cat <<EOF\nx\u2028EOF\n"\nEOF\n@test "hosted example" {\n  true\n}\n'
        heredoc = FIXTURE_HEADER + heredoc_body
        heredoc_split_there = FIXTURE_HEADER + heredoc_body.replace("\u2028", "\n")

        with refusal_bypassed(checker), tempfile.TemporaryDirectory() as temporary_directory:
            self.assertEqual(
                checker._parse_bats_source(b3, "bats/local/sample.bats"),
                ("hidden", "local example"),
            )
            self.assertEqual(
                checker._parse_bats_source(b5, "bats/hosted/sample.bats"),
                ("hosted example",),
            )
            self.assertEqual(
                checker._parse_bats_source(heredoc, "bats/hosted/sample.bats"),
                ("hosted example",),
            )
            candidate = Path(temporary_directory) / "sample.bats"
            candidate.write_text(heredoc, encoding="utf-8")
            self.assertEqual(checker._discover_bats_count(candidate, "bats/hosted/sample.bats"), 1)
            with self.assertRaisesRegex(checker.InventoryError, "^unterminated shell construct"):
                checker._parse_bats_source(heredoc_split_there, "bats/hosted/sample.bats")
            self.assertIn(
                "local file overrides app lifecycle hook",
                checker._local_lifecycle_errors(b3, "bats/local/sample.bats"),
            )
            self.assertIn(
                "local file does not load executable top-level app lifecycle hook after ordered header",
                checker._local_lifecycle_errors(b2, "bats/local/sample.bats"),
            )

    def test_bats_parser_refuses_before_it_tokenises(self) -> None:
        # The refusal lives in `_parse_bats_source` itself, so `capability_policy` and
        # `bats_evidence`, which call it directly, are covered as well as `read_bats_file`. Each
        # fixture gives a different error when tokenised first, so the refusal must come first.
        checker = load_checker()
        fixtures = {
            # A CRLF declaration line: tokenised first, it is an unknown declaration.
            "carriage return": (
                FIXTURE_HEADER + '\n@test "hosted example" {\r\n  true\n}\n',
                7,
                0x000D,
                "unknown @test declaration syntax in Bats file",
            ),
            # The only test sits behind `# ` and U+2028: tokenised first, the file has no tests.
            "only test behind a separator": (
                FIXTURE_HEADER + '\n# \u2028@test "hosted example" {\n# \u2028}\n',
                7,
                0x2028,
                "inventory file contains no tests",
            ),
        }
        for name, (source, line, code, tokenised_error) in fixtures.items():
            expected = refusal_message("Bats file", line, code)
            with self.subTest(fixture=name), tempfile.TemporaryDirectory() as temporary_directory:
                candidate = Path(temporary_directory) / "sample.bats"
                candidate.write_bytes(source.encode("utf-8"))
                original_scan = checker._scan_shell_line

                def tokenising_started(*_arguments, **_keywords):
                    raise AssertionError("tokenising must not start before the refusal")

                checker._scan_shell_line = tokenising_started
                try:
                    readers = (
                        lambda: checker._parse_bats_source(source, "bats/hosted/sample.bats"),
                        lambda: checker.read_bats_file(candidate, "bats/hosted/sample.bats"),
                        lambda: checker._discover_bats_count(candidate, "bats/hosted/sample.bats"),
                    )
                    for reader in readers:
                        with self.assertRaises(checker.InventoryError) as refusal:
                            reader()
                        self.assertEqual(str(refusal.exception), expected)
                finally:
                    checker._scan_shell_line = original_scan

                with refusal_bypassed(checker), self.assertRaises(checker.InventoryError) as tokenised:
                    checker._parse_bats_source(source, "bats/hosted/sample.bats")
                self.assertEqual(str(tokenised.exception), tokenised_error)

    def test_comment_and_blank_filters_admit_only_space_and_tab(self) -> None:
        # Called directly, without the refusal: a no-break space before `#` keeps the line
        # executable, as it is to bash, and a no-break-space-only line is not blank.
        checker = load_checker()
        no_load = "local file does not load executable top-level app lifecycle hook after ordered header"
        for name in ("B4", "B4b"):
            with self.subTest(fixture=name):
                _, source, _, _ = WHITESPACE_FIXTURES[name]
                self.assertIn(
                    no_load,
                    checker._local_lifecycle_errors(source, "bats/local/sample.bats"),
                )
        _, b1, _, _ = WHITESPACE_FIXTURES["B1"]
        hidden_after_separator = (
            FIXTURE_HEADER
            + '\n@test "hosted example" {\n  : \u2028# x; osascript -e \'return 1\'\n}\n'
        )
        substitution_beside_contract = (
            FIXTURE_HEADER + "true\u2028" + ROOT_CONTRACT[0] + '\n@test "hosted example" {\n  true\n}\n'
        )
        for source in (b1, hidden_after_separator, substitution_beside_contract):
            with self.subTest(source=ascii(source)):
                self.assertTrue(checker._hosted_has_live_state_access(source))
        self.assertFalse(checker._hosted_has_live_state_access(bats_source("hosted example")))

    def test_inventory_reads_like_bash_even_if_the_refusal_were_bypassed(self) -> None:
        # Defence in depth: with the refusal stubbed out, every reader still reads the fixtures as
        # bash and bats do instead of accepting them.
        checker = load_checker()
        with refusal_bypassed(checker):
            with tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                counts = {}
                for name in ("B3", "B5"):
                    candidate = root / f"{name}.bats"
                    candidate.write_text(WHITESPACE_FIXTURES[name][1], encoding="utf-8")
                    counts[name] = checker._discover_bats_count(candidate, "private-candidate-path")
            self.assertEqual(counts, {"B3": 2, "B5": 1})

            expected = {
                "B1": "hosted file contains live-state access",
                "B2": "local file does not load executable top-level app lifecycle hook",
                "B3": "local file overrides app lifecycle hook",
                "B4": "local file does not load executable top-level app lifecycle hook",
                "B7": "inventory file violates the shared-root contract",
            }
            for name, message in expected.items():
                with self.subTest(fixture=name), tempfile.TemporaryDirectory() as temporary_directory:
                    root = Path(temporary_directory)
                    manifest_path = write_fixture_manifest(root)
                    tier, source, _, _ = WHITESPACE_FIXTURES[name]
                    install_rehashed_source(root, manifest_path, tier, source)

                    errors = checker.validate_repository(root, manifest_path)

                self.assertTrue(any(message in error for error in errors), errors)
                self.assertFalse(any("refused character" in error for error in errors), errors)


if __name__ == "__main__":
    unittest.main()
