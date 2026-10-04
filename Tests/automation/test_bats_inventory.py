import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
from types import ModuleType
from typing import Optional
import unittest
from unittest import mock
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

# The pin-regeneration contract, written out here rather than read from the checker, so a change
# to the advice or to the literal format turns these tests red.
REGENERATE_HINT = (
    "if the change is reviewed and intended, re-pin locally, never in CI: run "
    "`python3 scripts/ci/bats_inventory.py --update-shas` from the repository root, after bringing "
    "bats/tier-inventory.json up to date if it reports manifest drift, and review the diff"
)
LIVE_STATE_ADVICE = f"a test that reads live state belongs in the local tier; {REGENERATE_HINT}"
PULL_REQUEST_NOTE = (
    "in a pull request the base branch's copy of this script and its pins judge the candidate, "
    "and a pull request cannot change a hosted file or a pinned helper: re-pinning lands only "
    "through a reviewed change on main"
)
EXEMPTION_NOTE = " (its pin exempts this content from the live-state heuristic)"


def ambiguous_reference(line_number: int) -> str:
    return (
        f"hosted file bats/hosted/sample.bats line {line_number} names the helper directory in a "
        'form the inventory cannot resolve (write "$HELPERS/<file name>" outside any '
        "substitution; the word helpers is refused anywhere else, comments included, and the "
        "line is read with quotes and backslashes removed, so helper's spells it too)"
    )


PIN_LITERAL = re.compile(r"(?ms)^(TRUSTED_HOSTED_(?:FILE|HELPER)_SHA256) = \{\n.*?^\}\n")
# The 8 helpers the hosted files run, and the 3 pinned on purpose for the local tier only.
HOSTED_HELPERS = {
    "applescript_syntax_check.py", "bounded_exec.py", "execute_envelope_lint.py",
    "md_tables_wellformed.py", "no_flagless_writes.py", "queue_table_wellformed.py",
    "quoted_not_found.py", "subcommand_allowlist.py",
}
LOCAL_ONLY_PINNED_HELPERS = {
    "bats/helpers/app_lifecycle.bash", "bats/helpers/app_lifecycle.py",
    "bats/helpers/messages_db_probe.py",
}


def pin_literal(name: str, pins: dict) -> str:
    return f"{name} = {{\n" + "".join(
        f'    "{path}": "{pins[path]}",\n' for path in sorted(pins)
    ) + "}\n"


def sha256_of(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def copy_checker(directory: Path) -> Path:
    """A private copy of the checker for `--update-shas` to rewrite; the real one is never touched."""
    script = directory / "scripts" / "ci" / "bats_inventory.py"
    script.parent.mkdir(parents=True)
    script.write_bytes(CHECKER_PATH.read_bytes())
    return script


def run_update_shas(script: Path, root: Path, manifest_path: Path, **environment: str):
    """`--update-shas` in a subprocess, with CI's own markers removed unless a test sets them."""
    env = {key: value for key, value in os.environ.items() if key not in ("CI", "GITHUB_ACTIONS")}
    env.update(environment)
    return subprocess.run(
        [sys.executable, str(script), "--root", str(root), "--manifest", str(manifest_path),
         "--update-shas"],
        check=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
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

    def test_helper_reference_reader_resolves_plain_forms_and_refuses_ambiguous_ones(self) -> None:
        checker = load_checker()
        resolved = {
            '  run python3 "$HELPERS/x.py"': {"x.py"},
            '  run python3 "${HELPERS}/x.py" --flag': {"x.py"},
            '  run python3 "$HELPERS"/x.py': {"x.py"},
            "  run bash -c 'python3 \"$0/helpers/x.py\"' \"$BATS_SUITE_ROOT\"": {"x.py"},
            '  python3 "$BATS_SUITE_ROOT/helpers/x.py"; true': {"x.py"},
            # macOS paths ignore case, so a case variant of the directory is still the directory.
            '  python3 "$REPO_ROOT/bats/Helpers/x.py"': {"x.py"},
            'load "$HELPERS/x"': {"x"},
            # Unquoted, bash reads `hel\pers` as `helpers`, so the backslash-free reading resolves it.
            "  python3 $BATS_SUITE_ROOT/hel\\pers/x.py": {"x.py"},
            # A subshell's `)` ends the name; only a command substitution makes a line ambiguous.
            '  (cd /tmp && python3 "$HELPERS/x.py")': {"x.py"},
        }
        for line, expected in resolved.items():
            with self.subTest(line=line):
                # The header carries the shared-root definition line, which is not a reference.
                names, ambiguous = checker._helper_references(FIXTURE_HEADER + line + "\n")
                self.assertEqual(names, expected)
                self.assertEqual(ambiguous, ())
        refused = (
            '  dir="$HELPERS"',
            '  run python3 "$HELPERS/$name"',
            "  HELPERS=/tmp",
            "  export HELPERS",
            '  run ls "$BATS_SUITE_ROOT/helpers"',
            '  run python3 "$HELPERS/sub/x.py"',
            '  run python3 "$HELPERS"/*.py',
            '  run python3 "${HELPERS:-/tmp}/x.py"',
            '  run python3 "$HELPERS/../x.py"',
            '  run python3 "$HELPERS/x.py$suffix"',
            '  run python3 "$HELPERS/"',
            # A bare word is refused anywhere, never read as prose.
            "  dir=helpers",
            "  cd helpers",
            "  helpers=/tmp",
            "  run true  # the helpers below, in a trailing comment",
            # A comment is no exception: the reader cannot be sure which lines bash reads as one.
            "# the helpers below are pure classifiers",
            "  # the helpers below, in an indented whole-line comment",
            "# see $HELPERS for the helpers",
            "# the bats/helpers directory",
            "# helpers/ holds the classifiers",
            # Only the exact variable HELPERS is the helper directory; `$helpers` is another one.
            '  run python3 "$helpers/x.py"',
            '  run python3 "${Helpers}/x.py"',
            # bash reads `HEL\PERS` as `HELPERS`.
            "  HEL\\PERS=/tmp",
            # A file name must end at a blank, a shell operator or the end of the line.
            '  run python3 "$HELPERS/x.py,"',
            '  run python3 "$HELPERS/x.py}"',
            '  run python3 "$HELPERS/x.py#c"',
            # A command substitution's output can extend or replace the path the name spells, on
            # this line or, through a variable, on a later one.
            '  run python3 "$(dirname "$HELPERS/x.py")/y.py"',
            '  run python3 "$(dirname "$HELPERS/x.py" )/y.py"',
            '  run python3 "$(dirname "$HELPERS/x.py")$suffix"',
            '  d=$(dirname "$HELPERS/x.py")',
            '  d=`dirname "$HELPERS/x.py"`',
            '  d=`dirname "$HELPERS/x.py" `',
            '  out="$(python3 "$HELPERS/x.py")"',
            # A process substitution hands its output on the same way, as does bash 5.3's `${ }`.
            '  read -r d < <(dirname "$HELPERS/x.py")',
            '  run diff <(python3 "$HELPERS/x.py") /dev/null',
            '  run tee >(python3 "$HELPERS/x.py") </dev/null',
            '  d=${ dirname "$HELPERS/x.py"; }',
            '  d=${| dirname "$HELPERS/x.py"; }',
            '  d=${\tdirname "$HELPERS/x.py"; }',
        )
        for line in refused:
            with self.subTest(line=line):
                source = FIXTURE_HEADER + line + "\n"
                names, ambiguous = checker._helper_references(source)
                self.assertEqual(ambiguous, (source.split("\n").index(line) + 1,))
                self.assertEqual(names, frozenset())
        # (body, the line that must be refused, which is the first line of its logical line): a
        # leading `#` exempts nothing, whatever bash makes of the line.
        not_comments = (
            # Inside a multi-line string the line is text, which `${d##* }` can turn into a path.
            ('  d="\n# helpers"\n  run python3 "$BATS_SUITE_ROOT/${d##* }/x.py"', '# helpers"'),
            # Inside a heredoc body the line is data to bash.
            ("  run python3 - <<'PY'\n# helpers\nPY", "# helpers"),
            # Quotes are removed before the word is read, so a possessive in a heredoc spells it.
            ("  run python3 - <<'PY'\n# The helper's guard\nPY", "# The helper's guard"),
            # After a line ending in a backslash, bash joins the lines, so `#` starts no comment.
            ("  run echo x\\\n#helpers", "  run echo x\\"),
            # A substitution later on the logical line refuses a reference before it.
            ('  run python3 "$HELPERS/x.py" \\\n  "$(date)"', '  run python3 "$HELPERS/x.py" \\'),
            # A substitution an earlier line opened is still open on this one.
            ('  d=$(\n  dirname "$HELPERS/x.py"\n)', '  dirname "$HELPERS/x.py"'),
            ('  d=`\n  dirname "$HELPERS/x.py"\n`', '  dirname "$HELPERS/x.py"'),
            # An escaped backtick inside it is literal to bash and does not close it.
            ('  d=`\n  echo \\`\n  dirname "$HELPERS/x.py"\n`', '  dirname "$HELPERS/x.py"'),
            # The `)` that closes it, followed by more path, extends what the name spells.
            ('  d=$(dirname \\\n  "$HELPERS/x.py")/y.py', '  d=$(dirname \\'),
            ("  d=$(printf '%s' \")\" \\\n  \"$HELPERS/x.py\")/y.py", "  d=$(printf '%s' \")\" \\"),
            # An opener split by a line continuation is read on the joined line.
            ('  d=$\\\n(dirname "$HELPERS/x.py")', '  d=$\\'),
            # A function substitution an earlier line left open.
            ('  d=${ \n  dirname "$HELPERS/x.py"; }', '  dirname "$HELPERS/x.py"; }'),
            # A bare `${` that ends the line opens a function substitution on it.
            (
                '  run python3 "$HELPERS/x.py" ${\n  echo --flag; }',
                '  run python3 "$HELPERS/x.py" ${',
            ),
            # A substitution opened mid-line without a continuation is not seen as open, but the
            # `)` that closes it, followed by more path, still refuses the reference before it.
            ('  d=$(cd /tmp; dirname\n  "$HELPERS/x.py")/y.py', '  "$HELPERS/x.py")/y.py'),
        )
        for body, line in not_comments:
            with self.subTest(body=body):
                source = FIXTURE_HEADER + body + "\n"
                names, ambiguous = checker._helper_references(source)
                self.assertEqual(ambiguous, (source.split("\n").index(line) + 1,))
                self.assertEqual(names, frozenset())
        # A line that ends with an opener (blanks or a `(` may follow it) or holds an odd number of
        # unescaped backticks refuses every reference after it, even once the substitution has
        # closed: the reader does not look for its end. A lone quoted backtick looks open too, which
        # fails closed.
        reference = '  run python3 "$HELPERS/x.py"'
        for body in ('  d=$(\n  date\n)\n' + reference,
                     '  d=`\n  date\n`\n' + reference,
                     '  d=${ \n  date\n}\n' + reference,
                     '  d=$( \\\n\n  date\n)\n' + reference,
                     "  echo 'a`b'\n" + reference,
                     # Two backticks, one escaped: the other opens a substitution.
                     "  echo \\` `\n" + reference,
                     # Process substitutions, and a subshell opened inside a substitution.
                     "  diff <(\n  date\n) /dev/null\n" + reference,
                     "  tee >(\n  cat\n) </dev/null\n" + reference,
                     "  d=$( (\n  date\n) )\n" + reference,
                     "  d=${|\n  date\n}\n" + reference):
            with self.subTest(after_unclosed=body):
                source = FIXTURE_HEADER + body + "\n"
                names, ambiguous = checker._helper_references(source)
                self.assertEqual(names, frozenset())
                self.assertEqual(ambiguous, (source.split("\n").index(reference) + 1,))
        # A substitution closed on its own line opens nothing for the lines after it, a quoted
        # `(` inside it included, and neither does an escaped backtick, which is literal.
        names, ambiguous = checker._helper_references(
            FIXTURE_HEADER
            + '  out="$(date)"\n  stamp=`date`\n  calls="$(grep -c \'f(\' "$src")"\n'
            + "  echo \\`\n"
            + reference
            + "\n"
        )
        self.assertEqual((names, ambiguous), (frozenset({"x.py"}), ()))

    def test_real_hosted_files_reference_only_pinned_helpers(self) -> None:
        checker = load_checker()
        referenced = set()
        for path in sorted((REPO_ROOT / "bats" / "hosted").glob("*.bats")):
            with self.subTest(path=path.relative_to(REPO_ROOT).as_posix()):
                names, ambiguous = checker._helper_references(path.read_text(encoding="utf-8"))
                self.assertEqual(ambiguous, ())
                referenced.update(names)
        self.assertEqual(referenced, HOSTED_HELPERS)
        pinned = set(checker.TRUSTED_HOSTED_HELPER_SHA256)
        referenced_paths = {f"bats/helpers/{name}" for name in referenced}
        self.assertLessEqual(referenced_paths, pinned)
        self.assertEqual(pinned - referenced_paths, LOCAL_ONLY_PINNED_HELPERS)

    def test_hosted_file_referencing_an_unpinned_helper_is_refused(self) -> None:
        checker = load_checker()
        cases = (
            # (line in the hosted test, helper files to create, helper the error must name)
            ('  run python3 "$HELPERS/synthetic_probe.py"', ("synthetic_probe.py",),
             "bats/helpers/synthetic_probe.py"),
            ('  run python3 "$HELPERS/absent_probe.py"', (), "bats/helpers/absent_probe.py"),
            ('  load "$HELPERS/synthetic"', ("synthetic.bash",), "bats/helpers/synthetic.bash"),
            # A pinned name does not excuse an unpinned file bats `load` would prefer.
            ('  run python3 "$HELPERS/bounded_exec.py"', ("bounded_exec.py.bash",),
             "bats/helpers/bounded_exec.py.bash"),
            # macOS paths ignore case, so a case variant on disk is that file.
            ('  load "$HELPERS/bounded_exec.py"', ("Bounded_Exec.py.bash",),
             "bats/helpers/Bounded_Exec.py.bash"),
            ('  run python3 "$HELPERS/synthetic_probe.py"', ("Synthetic_Probe.py",),
             "bats/helpers/Synthetic_Probe.py"),
        )
        for line, created, unpinned in cases:
            with self.subTest(line=line), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                manifest_path = write_fixture_manifest(root)
                for name in created:
                    (root / "bats" / "helpers" / name).write_text("# synthetic\n", encoding="utf-8")
                install_rehashed_source(
                    root, manifest_path, "hosted", bats_source("hosted example").replace("  true", line)
                )

                errors = checker.validate_repository(root, manifest_path)

            self.assertIn(
                f"hosted file bats/hosted/sample.bats references helper {unpinned}, which "
                f"TRUSTED_HOSTED_HELPER_SHA256 does not pin ({REGENERATE_HINT})",
                errors,
            )
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            pinned_run = '  run python3 "$HELPERS/bounded_exec.py"'
            install_rehashed_source(
                root, manifest_path, "hosted", bats_source("hosted example").replace("  true", pinned_run)
            )
            self.assertEqual(checker.validate_repository(root, manifest_path), ())

            install_rehashed_source(
                root,
                manifest_path,
                "hosted",
                bats_source("hosted example").replace("  true", '  dir="$HELPERS"'),
            )
            self.assertEqual(
                checker.validate_repository(root, manifest_path), (ambiguous_reference(8),)
            )

    def test_bare_helpers_word_is_refused_end_to_end(self) -> None:
        # Each body runs a helper through the bare word `helpers`, which the reader used to skip
        # as prose: the hosted file's own pin then covered the line, and a later edit to the
        # helper alone went unpinned.
        checker = load_checker()
        cases = (
            ('  dir=helpers\n  run python3 "$BATS_SUITE_ROOT/$dir/bounded_exec.py"', 8),
            ('  cd "$BATS_SUITE_ROOT"\n  cd helpers\n  run python3 ./bounded_exec.py', 9),
            (
                "  run python3 - \"$BATS_SUITE_ROOT\" <<'PY'\n"
                "import os, runpy, sys\n"
                "runpy.run_path(os.path.join(sys.argv[1], 'helpers', 'bounded_exec.py'))\n"
                "PY",
                10,
            ),
        )
        for body, line_number in cases:
            with self.subTest(line_number=line_number), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                manifest_path = write_fixture_manifest(root)
                source = bats_source("hosted example").replace("  true", body)
                install_rehashed_source(root, manifest_path, "hosted", source)

                errors = checker.validate_repository(root, manifest_path)

            self.assertIn(ambiguous_reference(line_number), errors)
            self.assertFalse(any("references helper" in error for error in errors), errors)

    def test_a_reference_after_an_unclosed_substitution_names_that_line(self) -> None:
        checker = load_checker()
        run = '  run python3 "$HELPERS/bounded_exec.py"'
        # (body, line of the reference): the advice names the first line left open, and holds
        # when a later line leaves one open too.
        cases = (
            ("  d=$(\n  date\n)\n" + run, 11),
            ("  d=$( (\n  date\n) )\n" + run, 11),
            ("  d=$(\n  date\n)\n  e=$(\n  date\n)\n" + run, 14),
        )
        for body, line_number in cases:
            with self.subTest(body=body), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                manifest_path = write_fixture_manifest(root)
                source = bats_source("hosted example").replace("  true", body)
                install_rehashed_source(root, manifest_path, "hosted", source)

                errors = checker.validate_repository(root, manifest_path)

            self.assertIn(
                ambiguous_reference(line_number)
                + "; line 8 leaves a substitution open for the lines after it (it ends with a "
                "substitution opener, which blanks or a ( may follow, or holds an odd number of "
                "unescaped backticks), so no later line may name a helper: close it there and on "
                "any later line that leaves one open, or name the helper above line 8",
                errors,
            )
        # A line refused for a reason of its own gets no such advice: closing line 8 would not
        # clear it.
        body = "  d=$(\n  date\n)\n  cd helpers"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = write_fixture_manifest(root)
            source = bats_source("hosted example").replace("  true", body)
            install_rehashed_source(root, manifest_path, "hosted", source)

            errors = checker.validate_repository(root, manifest_path)

        self.assertIn(ambiguous_reference(11), errors)
        self.assertFalse(any("leaves a substitution open" in error for error in errors), errors)

    def test_helper_file_a_quoted_reference_could_name_is_refused(self) -> None:
        # `"$HELPERS/bounded_exec.py other"` runs a file named `bounded_exec.py other`; with the
        # quotes removed the reader sees the pinned `bounded_exec.py`, so the other file must not
        # exist beside it.
        checker = load_checker()
        cases = (
            ("bounded_exec.py other", "bounded_exec.py other"),
            ("bounded_exec.py)", "bounded_exec.py)"),
            # macOS paths ignore case: this reference runs `BOUNDED_EXEC.py other` there.
            ("BOUNDED_EXEC.py other", "bounded_exec.py other"),
        )
        for file_name, reference in cases:
            with self.subTest(file_name=file_name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                manifest_path = write_fixture_manifest(root)
                (root / "bats" / "helpers" / file_name).write_text("# synthetic\n", encoding="utf-8")
                install_rehashed_source(
                    root,
                    manifest_path,
                    "hosted",
                    bats_source("hosted example").replace(
                        "  true", f'  run python3 "$HELPERS/{reference}"'
                    ),
                )

                errors = checker.validate_repository(root, manifest_path)

            self.assertEqual(
                errors,
                (
                    "hosted file bats/hosted/sample.bats references helper "
                    "bats/helpers/bounded_exec.py, and a file in bats/helpers extends that name "
                    "with a character outside [A-Za-z0-9_./-], which a quoted reference could run "
                    "instead (rename that file)",
                ),
            )

    def test_drift_messages_name_the_path_and_how_to_regenerate(self) -> None:
        checker = load_checker()
        live_read = '  run sqlite3 "$HOME/Library/Messages/chat.db" "select private_value"'
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            install_rehashed_source(
                root, manifest_path, "hosted", bats_source("hosted example").replace("  true", live_read)
            )
            unpinned_errors = checker.validate_repository(root, manifest_path)
            original_pins = checker.TRUSTED_HOSTED_FILE_SHA256
            checker.TRUSTED_HOSTED_FILE_SHA256 = {"bats/hosted/sample.bats": "0" * 64}
            try:
                drifted_errors = checker.validate_repository(root, manifest_path)
            finally:
                checker.TRUSTED_HOSTED_FILE_SHA256 = original_pins
            stdout = io.StringIO()
            stderr = io.StringIO()
            with redirect_stdout(stdout), redirect_stderr(stderr):
                status = checker.run(["--root", str(root), "--manifest", str(manifest_path)])

            helper = root / "bats" / "helpers" / "bounded_exec.py"
            helper.write_bytes(helper.read_bytes() + b"\n# private helper edit\n")
            (root / "bats" / "helpers" / "messages_db_probe.py").unlink()
            helper_errors = checker._validate_trusted_hosted_helpers(root)
            same_root_errors = checker.validate_candidate_repository(
                root, manifest_path, root, manifest_path
            )

            # In a pull request the base's copy judges, so its errors also say re-pinning cannot
            # happen from inside the pull request.
            policy_root = root / "policy"
            candidate_root = root / "candidate"
            policy_manifest = write_fixture_manifest(policy_root)
            candidate_manifest = write_fixture_manifest(candidate_root)
            candidate_helper = candidate_root / "bats" / "helpers" / "bounded_exec.py"
            candidate_helper.write_bytes(candidate_helper.read_bytes() + b"\n# helper edit\n")
            pull_request_errors = checker.validate_candidate_repository(
                policy_root, policy_manifest, candidate_root, candidate_manifest
            )

        self.assertIn(
            "hosted file contains live-state access: bats/hosted/sample.bats is not pinned in "
            f"TRUSTED_HOSTED_FILE_SHA256 ({LIVE_STATE_ADVICE})",
            unpinned_errors,
        )
        self.assertIn(
            "hosted file contains live-state access: bats/hosted/sample.bats no longer matches its "
            f"pin in TRUSTED_HOSTED_FILE_SHA256 ({LIVE_STATE_ADVICE})",
            drifted_errors,
        )
        self.assertTrue(any(REGENERATE_HINT in error for error in same_root_errors))
        self.assertNotIn(PULL_REQUEST_NOTE, same_root_errors)
        self.assertEqual(
            pull_request_errors,
            (
                "candidate inventory: hosted helper catalog drift: bats/helpers/bounded_exec.py "
                f"does not match its pin in TRUSTED_HOSTED_HELPER_SHA256 ({REGENERATE_HINT})",
                PULL_REQUEST_NOTE,
            ),
        )
        self.assertIn(
            "hosted helper catalog drift: bats/helpers/bounded_exec.py does not match its pin in "
            f"TRUSTED_HOSTED_HELPER_SHA256 ({REGENERATE_HINT})",
            helper_errors,
        )
        self.assertIn(
            "hosted helper catalog drift: bats/helpers/messages_db_probe.py is missing or not a "
            "regular file (restore it, or remove its pin by hand in a reviewed change; "
            "--update-shas never removes a helper pin)",
            helper_errors,
        )
        rendered = stdout.getvalue() + stderr.getvalue()
        self.assertEqual(status, 1)
        self.assertIn("bats/hosted/sample.bats", rendered)
        self.assertIn("--update-shas", rendered)
        for private in ("select private_value", "chat.db", "hosted example", str(root)):
            self.assertNotIn(private, rendered)

    def test_drift_message_never_echoes_an_unprintable_path(self) -> None:
        checker = load_checker()
        sentinel = "private\x1b[31m"
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            install_rehashed_source(
                root,
                manifest_path,
                "hosted",
                bats_source("hosted example").replace("  true", '  run osascript -e "return 1"'),
            )
            hosted = root / "bats" / "hosted" / "sample.bats"
            hosted.rename(hosted.with_name(f"{sentinel}.bats"))
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["tiers"]["hosted"]["files"][0]["path"] = f"bats/hosted/{sentinel}.bats"
            manifest_path.write_text(
                json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )

            errors = checker.validate_repository(root, manifest_path)

        # --update-shas refuses such a path, so the advice is to rename it, not to re-pin it.
        self.assertIn(
            "hosted file contains live-state access: a path outside [A-Za-z0-9_./-] is not pinned "
            "in TRUSTED_HOSTED_FILE_SHA256 (a test that reads live state belongs in the local "
            "tier; rename it to plain [A-Za-z0-9_./-] path text first: --update-shas pins no "
            "other)",
            errors,
        )
        self.assertFalse(any(sentinel in error or "\x1b" in error for error in errors), errors)
        self.assertEqual(checker._display_path("bats/hosted/smoke.bats"), "bats/hosted/smoke.bats")
        for unsafe in ("bats/hosted/a b.bats", "bats/hosted/\"q\".bats", "../x", "/abs", "bats//x"):
            self.assertEqual(checker._display_path(unsafe), "a path outside [A-Za-z0-9_./-]")

    def test_update_shas_pins_a_case_variant_under_its_spelling_on_disk(self) -> None:
        # macOS paths ignore case, so `"$HELPERS/synthetic_probe.py"` runs `Synthetic_Probe.py`:
        # that file is the one pinned, the tree then validates, and the report does not call it
        # unreferenced.
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            script = copy_checker(root)
            (root / "bats" / "helpers" / "Synthetic_Probe.py").write_text(
                "# synthetic\n", encoding="utf-8"
            )
            install_rehashed_source(
                root,
                manifest_path,
                "hosted",
                bats_source("hosted example").replace(
                    "  true", '  run python3 "$HELPERS/synthetic_probe.py"'
                ),
            )

            completed = run_update_shas(script, root, manifest_path)
            verified = subprocess.run(
                [sys.executable, str(script), "--root", str(root), "--manifest", str(manifest_path)],
                check=False,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            rewritten = script.read_text(encoding="utf-8")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("- helper added: bats/helpers/Synthetic_Probe.py\n", completed.stdout)
        self.assertNotIn("references it: bats/helpers/Synthetic_Probe.py", completed.stdout)
        self.assertIn('    "bats/helpers/Synthetic_Probe.py": "', rewritten)
        self.assertNotIn('"bats/helpers/synthetic_probe.py"', rewritten)
        self.assertEqual(verified.returncode, 0, verified.stderr)

    def test_update_shas_repins_adds_referenced_helpers_and_is_idempotent(self) -> None:
        real_checker = sha256_of(CHECKER_PATH)
        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = Path(temporary_directory)
            root = directory / "root"
            manifest_path = write_fixture_manifest(root, hosted_titles=["private hosted title"])
            # `--update-shas` rewrites only the copy inside the tree it pins.
            script = copy_checker(root)
            script.chmod(0o640)
            original = script.read_text(encoding="utf-8")
            outputs = []

            first = run_update_shas(script, root, manifest_path)
            outputs.append(first.stdout + first.stderr)
            after_first = script.read_text(encoding="utf-8")
            rewritten_mode = stat.S_IMODE(script.stat().st_mode)
            left_beside = sorted(path.name for path in script.parent.iterdir())

            helper = root / "bats" / "helpers" / "bounded_exec.py"
            helper.write_bytes(helper.read_bytes() + b"\n# private-helper-text\n")
            probe = root / "bats" / "helpers" / "synthetic_probe.py"
            probe.write_text("# private-helper-text\n", encoding="utf-8")
            hosted = install_rehashed_source(
                root,
                manifest_path,
                "hosted",
                bats_source("private hosted title").replace(
                    "  true", '  run python3 "$HELPERS/synthetic_probe.py"'
                ),
            )
            second = run_update_shas(script, root, manifest_path)
            outputs.append(second.stdout + second.stderr)
            after_second = script.read_text(encoding="utf-8")
            pinned_helpers = [*load_checker().TRUSTED_HOSTED_HELPER_SHA256]
            expected_helpers = {
                relative: sha256_of(root / relative)
                for relative in [*pinned_helpers, "bats/helpers/synthetic_probe.py"]
            }
            expected_files = {"bats/hosted/sample.bats": sha256_of(hosted)}

            third = run_update_shas(script, root, manifest_path)
            outputs.append(third.stdout + third.stderr)
            after_third = script.read_text(encoding="utf-8")
            verified = subprocess.run(
                [sys.executable, str(script), "--root", str(root), "--manifest", str(manifest_path)],
                check=False,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

        for completed in (first, second, third):
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(completed.stderr, "")
        self.assertIn("- hosted file added: bats/hosted/sample.bats\n", first.stdout)
        self.assertIn("- hosted file removed: bats/hosted/mail.bats\n", first.stdout)
        self.assertNotIn("- helper", first.stdout.replace("- helper kept", ""))
        # The rewrite keeps the file's mode and leaves no temporary file beside it.
        self.assertEqual(rewritten_mode, 0o640)
        self.assertEqual(left_beside, ["bats_inventory.py"])
        self.assertIn("- hosted file re-pinned: bats/hosted/sample.bats\n", second.stdout)
        self.assertIn("- helper re-pinned: bats/helpers/bounded_exec.py\n", second.stdout)
        self.assertIn("- helper added: bats/helpers/synthetic_probe.py\n", second.stdout)
        self.assertIn(
            "- helper kept although no hosted file references it: "
            "bats/helpers/messages_db_probe.py\n",
            second.stdout,
        )
        self.assertNotIn("references it: bats/helpers/synthetic_probe.py", second.stdout)
        self.assertIn(
            "Rewrote the pin maps in scripts/ci/bats_inventory.py (3 pin(s) changed); review the "
            "diff",
            second.stdout,
        )
        self.assertIn(pin_literal("TRUSTED_HOSTED_FILE_SHA256", expected_files), after_second)
        self.assertIn(pin_literal("TRUSTED_HOSTED_HELPER_SHA256", expected_helpers), after_second)
        # Nothing outside the two literals moves, and a second run on the same tree is a no-op.
        for text in (after_first, after_second):
            self.assertEqual(PIN_LITERAL.sub(r"\1", text), PIN_LITERAL.sub(r"\1", original))
            self.assertEqual(len(PIN_LITERAL.findall(text)), 2)
        self.assertEqual(after_third, after_second)
        self.assertIn("No pin changed: both maps already match the files on disk.\n", third.stdout)
        # Keys come out sorted whatever order the manifest lists the hosted files in.
        unsorted = {"bats/hosted/b.bats": "1" * 64, "bats/hosted/a.bats": "2" * 64}
        self.assertEqual(
            load_checker()._render_pin_literal("TRUSTED_HOSTED_FILE_SHA256", unsorted),
            pin_literal("TRUSTED_HOSTED_FILE_SHA256", unsorted),
        )
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertEqual(verified.stdout, "Bats tier inventory: 2 tests verified\n")
        for output in outputs:
            self.assertNotIn("private hosted title", output)
            self.assertNotIn("private-helper-text", output)
            self.assertNotIn(str(directory), output)
            self.assertIsNone(re.search(r"[0-9a-f]{64}", output), output)
        self.assertEqual(sha256_of(CHECKER_PATH), real_checker)

    def test_update_shas_changes_nothing_on_the_real_tree(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            script = copy_checker(Path(temporary_directory))
            before = script.read_bytes()

            report, errors = checker.update_trusted_shas(REPO_ROOT, MANIFEST_PATH, script)

            after = script.read_bytes()
        self.assertEqual(errors, ())
        self.assertEqual(after, before)
        self.assertEqual(report[-1], "No pin changed: both maps already match the files on disk.")
        self.assertEqual(
            {line.rsplit(": ", 1)[1] for line in report[:-1]},
            LOCAL_ONLY_PINNED_HELPERS,
        )

    def test_every_real_hosted_file_trips_the_live_state_heuristic(self) -> None:
        # AGENTS.md says all eight hosted files are flagged today, so each hosted pin is the
        # exemption that admits its file. If a hosted file stops tripping the heuristic, its pin
        # no longer matters, and that sentence needs updating along with this test.
        checker = load_checker()
        manifest = checker.load_manifest(MANIFEST_PATH)
        hosted = sorted(entry["path"] for entry in checker._manifest_entries(manifest, "hosted"))
        self.assertEqual(len(hosted), 8)
        self.assertEqual(hosted, sorted(checker.TRUSTED_HOSTED_FILE_SHA256))
        for relative in hosted:
            with self.subTest(path=relative):
                _payload, source, _titles = checker.read_bats_file(REPO_ROOT / relative, relative)
                self.assertTrue(checker._hosted_has_live_state_access(source))

    def test_update_shas_marks_a_hosted_pin_that_waives_the_live_state_heuristic(self) -> None:
        # The pin is what admits a flagged file, so the reviewer must see that it does.
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            install_rehashed_source(
                root,
                manifest_path,
                "hosted",
                bats_source("hosted example").replace("  true", '  run osascript -e "return 1"'),
            )
            script = copy_checker(root)

            report, errors = checker.update_trusted_shas(root, manifest_path, script)

            rewritten = script.read_text(encoding="utf-8")
        self.assertEqual(errors, ())
        self.assertIn("- hosted file added: bats/hosted/sample.bats" + EXEMPTION_NOTE, report)
        self.assertIn('    "bats/hosted/sample.bats": "', rewritten)

    def test_update_shas_leaves_no_temporary_file_and_ignores_a_stale_one(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            manifest_path = write_fixture_manifest(root)
            script = copy_checker(root)
            before = script.read_bytes()
            with mock.patch.object(checker.os, "replace", side_effect=OSError("synthetic")):
                failed = checker.update_trusted_shas(root, manifest_path, script)
            after_failure = script.read_bytes()
            left_after_failure = sorted(path.name for path in script.parent.iterdir())

            # A sibling left by a run killed between its write and its rename blocks no rerun.
            stale = script.parent / ".bats_inventory.py.stale1.update-shas"
            stale.write_text("stale\n", encoding="utf-8")
            report, errors = checker.update_trusted_shas(root, manifest_path, script)
            after_rerun = script.read_bytes()
            left_after_rerun = sorted(path.name for path in script.parent.iterdir())

        self.assertEqual(failed, ((), ("could not rewrite scripts/ci/bats_inventory.py",)))
        self.assertEqual(after_failure, before)
        self.assertEqual(left_after_failure, ["bats_inventory.py"])
        self.assertEqual(errors, ())
        self.assertNotEqual(after_rerun, before)
        self.assertEqual(
            left_after_rerun, [".bats_inventory.py.stale1.update-shas", "bats_inventory.py"]
        )
        self.assertTrue(
            report[-1].startswith("Rewrote the pin maps in scripts/ci/bats_inventory.py"), report
        )

    def test_update_shas_refuses_a_missing_duplicated_or_reformatted_literal(self) -> None:
        checker = load_checker()
        original = CHECKER_PATH.read_text(encoding="utf-8")
        helper_literal = next(
            match.group(0) for match in PIN_LITERAL.finditer(original)
            if match.group(1) == "TRUSTED_HOSTED_HELPER_SHA256"
        )
        file_literal = next(
            match.group(0) for match in PIN_LITERAL.finditer(original)
            if match.group(1) == "TRUSTED_HOSTED_FILE_SHA256"
        )
        # One entry line of the file literal, duplicated in place: the literal still appears
        # exactly once, but the same path is now pinned twice inside it.
        file_entry_line = re.search(r'    "[^"\\\n]*": "[0-9a-f]{64}",\n', file_literal).group(0)
        mutations = {
            "missing": original.replace(helper_literal, ""),
            "duplicated": original + "\n" + file_literal,
            "reformatted": original.replace(
                "TRUSTED_HOSTED_FILE_SHA256 = {", "TRUSTED_HOSTED_FILE_SHA256: dict = {", 1
            ),
            # The last file entry loses its trailing comma.
            "entry reformatted": original.replace(
                '",\n}\nTRUSTED_HOSTED_HELPER', '"\n}\nTRUSTED_HOSTED_HELPER', 1
            ),
            "duplicate entry": original.replace(
                file_literal, file_literal.replace(file_entry_line, file_entry_line * 2, 1), 1
            ),
            # The text check sees one literal at the start of a line in each of these; only the
            # parsed module shows a second binding that would win at run time.
            "assigned again in a block": original
            + "\nif True:\n    TRUSTED_HOSTED_FILE_SHA256 = {}\n",
            "assigned again on one line": original
            + "\n_unused = {}; TRUSTED_HOSTED_FILE_SHA256 = {}\n",
            "annotated reassignment": original
            + "\nif True:\n    TRUSTED_HOSTED_HELPER_SHA256: dict = {}\n",
            "tuple target": original
            + "\nif True:\n    _unused, TRUSTED_HOSTED_HELPER_SHA256 = 0, {}\n",
            "augmented assignment": original
            + "\ndef _extend() -> None:\n    global TRUSTED_HOSTED_FILE_SHA256\n"
            + "    TRUSTED_HOSTED_FILE_SHA256 |= {}\n",
            # Every other form that binds or deletes a name counts as a second binding too.
            "deleted": original
            + "\ndef _drop() -> None:\n    global TRUSTED_HOSTED_FILE_SHA256\n"
            + "    del TRUSTED_HOSTED_FILE_SHA256\n",
            "redefined as a function": original
            + "\ndef TRUSTED_HOSTED_FILE_SHA256() -> None:\n    pass\n",
            "redefined as a class": original + "\nclass TRUSTED_HOSTED_HELPER_SHA256:\n    pass\n",
            "imported over": original
            + "\nif True:\n    import json as TRUSTED_HOSTED_FILE_SHA256\n",
            "bound by an except clause": original
            + "\ntry:\n    pass\nexcept ValueError as TRUSTED_HOSTED_FILE_SHA256:\n    pass\n",
            "parameter": original
            + "\ndef _shadow(TRUSTED_HOSTED_FILE_SHA256: dict) -> None:\n    pass\n",
            "lambda parameter": original
            + "\n_shadow = lambda TRUSTED_HOSTED_HELPER_SHA256: None\n",
            # One binding, but the value the script uses is not the literal any more.
            "item assignment": original
            + '\nif True:\n    TRUSTED_HOSTED_FILE_SHA256["bats/hosted/x.bats"] = "0" * 64\n',
            "item deletion": original
            + '\nif True:\n    del TRUSTED_HOSTED_HELPER_SHA256["bats/helpers/x.py"]\n',
            "update call": original + "\nif True:\n    TRUSTED_HOSTED_FILE_SHA256.update({})\n",
            "clear call": original + "\nif True:\n    TRUSTED_HOSTED_HELPER_SHA256.clear()\n",
            "unbound method call": original
            + "\nif True:\n    dict.update(TRUSTED_HOSTED_FILE_SHA256, {})\n",
            "attribute taken": original
            + "\nif True:\n    _pop = TRUSTED_HOSTED_HELPER_SHA256.pop\n",
            "passed starred": original + "\nif True:\n    print(*TRUSTED_HOSTED_FILE_SHA256)\n",
            "star import": original + "\nfrom os.path import *\n",
            # The literal the text check finds is a copy inside a string: the one binding is
            # elsewhere, inside a block in one case and after another statement in the other.
            "literal only in a string": original.replace(
                file_literal,
                '_COPY = """\n'
                + file_literal
                + '"""\nif True:\n    TRUSTED_HOSTED_FILE_SHA256 = {}\n',
                1,
            ),
            "literal copied into a string": original.replace(
                file_literal,
                '_COPY = """\n' + file_literal + '"""\n_unused = 0; ' + file_literal,
                1,
            ),
        }
        expected_error = {
            "assigned again in a block": "TRUSTED_HOSTED_FILE_SHA256: expected exactly one "
            "assignment in the script, found 2",
            "assigned again on one line": "TRUSTED_HOSTED_FILE_SHA256: expected exactly one "
            "assignment in the script, found 2",
            "annotated reassignment": "TRUSTED_HOSTED_HELPER_SHA256: expected exactly one "
            "assignment in the script, found 2",
            "tuple target": "TRUSTED_HOSTED_HELPER_SHA256: expected exactly one assignment in the "
            "script, found 2",
            "augmented assignment": "TRUSTED_HOSTED_FILE_SHA256: expected exactly one assignment "
            "in the script, found 2",
            **{
                name: f"{map_name}: expected exactly one assignment in the script, found 2"
                for name, map_name in (
                    ("deleted", "TRUSTED_HOSTED_FILE_SHA256"),
                    ("redefined as a function", "TRUSTED_HOSTED_FILE_SHA256"),
                    ("redefined as a class", "TRUSTED_HOSTED_HELPER_SHA256"),
                    ("imported over", "TRUSTED_HOSTED_FILE_SHA256"),
                    ("bound by an except clause", "TRUSTED_HOSTED_FILE_SHA256"),
                    ("match capture", "TRUSTED_HOSTED_FILE_SHA256"),
                    ("match star", "TRUSTED_HOSTED_HELPER_SHA256"),
                    ("match rest", "TRUSTED_HOSTED_FILE_SHA256"),
                    ("parameter", "TRUSTED_HOSTED_FILE_SHA256"),
                    ("lambda parameter", "TRUSTED_HOSTED_HELPER_SHA256"),
                    ("star import", "TRUSTED_HOSTED_FILE_SHA256"),
                )
            },
            **{
                name: f"{map_name}: the script may change the map in place (an item assignment or "
                "deletion, an attribute of the map, or the map passed to a call), so the rewritten "
                "literal might not be what it uses"
                for name, map_name in (
                    ("item assignment", "TRUSTED_HOSTED_FILE_SHA256"),
                    ("item deletion", "TRUSTED_HOSTED_HELPER_SHA256"),
                    ("update call", "TRUSTED_HOSTED_FILE_SHA256"),
                    ("clear call", "TRUSTED_HOSTED_HELPER_SHA256"),
                    ("unbound method call", "TRUSTED_HOSTED_FILE_SHA256"),
                    ("attribute taken", "TRUSTED_HOSTED_HELPER_SHA256"),
                    ("passed starred", "TRUSTED_HOSTED_FILE_SHA256"),
                )
            },
            "literal only in a string": "TRUSTED_HOSTED_FILE_SHA256: its one assignment is not "
            "the module-level literal the rewrite replaces",
            "literal copied into a string": "TRUSTED_HOSTED_FILE_SHA256: its one assignment is "
            "not the module-level literal the rewrite replaces",
            "missing": "TRUSTED_HOSTED_HELPER_SHA256: expected exactly one literal in the "
            "existing format",
            "duplicated": "TRUSTED_HOSTED_FILE_SHA256: expected exactly one literal in the "
            "existing format",
            "reformatted": "TRUSTED_HOSTED_FILE_SHA256: expected exactly one literal in the "
            "existing format",
            "entry reformatted": "TRUSTED_HOSTED_FILE_SHA256: expected exactly one literal in "
            "the existing format",
            "duplicate entry": "TRUSTED_HOSTED_FILE_SHA256: the literal pins a path twice",
        }
        if sys.version_info >= (3, 10):
            # `match` parses from Python 3.10; the script itself still runs on older interpreters.
            mutations.update(
                {
                    "match capture": original
                    + "\nmatch 0:\n    case TRUSTED_HOSTED_FILE_SHA256:\n        pass\n",
                    "match star": original
                    + "\nmatch []:\n    case [*TRUSTED_HOSTED_HELPER_SHA256]:\n        pass\n",
                    "match rest": original
                    + "\nmatch {}:\n    case {**TRUSTED_HOSTED_FILE_SHA256}:\n        pass\n",
                }
            )
        for name, text in mutations.items():
            self.assertNotEqual(text, original, name)
            with self.subTest(mutation=name), tempfile.TemporaryDirectory() as temporary_directory:
                directory = Path(temporary_directory)
                root = directory / "root"
                manifest_path = write_fixture_manifest(root)
                script = copy_checker(directory / "tool")
                script.write_text(text, encoding="utf-8")

                report, errors = checker.update_trusted_shas(root, manifest_path, script)

                self.assertEqual(script.read_text(encoding="utf-8"), text)
            self.assertEqual(report, ())
            self.assertEqual(errors, (expected_error[name],))
        # A longer name that merely starts with a map's name is neither literal nor binding.
        lookalike = "\nTRUSTED_HOSTED_FILE_SHA256_OLD = {}\n"
        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = Path(temporary_directory)
            root = directory / "root"
            manifest_path = write_fixture_manifest(root)
            script = copy_checker(directory / "tool")
            script.write_text(original + lookalike, encoding="utf-8")

            report, errors = checker.update_trusted_shas(root, manifest_path, script)

            rewritten = script.read_text(encoding="utf-8")
        self.assertEqual(errors, ())
        self.assertTrue(rewritten.endswith(lookalike), rewritten[-200:])
        self.assertIn("- hosted file added: bats/hosted/sample.bats", report)

    def test_update_shas_refuses_trees_it_cannot_pin_and_never_drops_a_helper(self) -> None:
        checker = load_checker()

        def missing_pinned_helper(root: Path, _manifest_path: Path) -> None:
            (root / "bats" / "helpers" / "messages_db_probe.py").unlink()

        def hosted_body(body: str) -> str:
            return bats_source("hosted example").replace("  true", body)

        def stale_manifest(root: Path, _manifest_path: Path) -> None:
            hosted = root / "bats" / "hosted" / "sample.bats"
            hosted.write_text(hosted_body("  false"), encoding="utf-8")

        def ambiguous_helper_reference(root: Path, manifest_path: Path) -> None:
            install_rehashed_source(root, manifest_path, "hosted", hosted_body('  dir="$HELPERS"'))

        def absent_helper(root: Path, manifest_path: Path) -> None:
            install_rehashed_source(
                root, manifest_path, "hosted", hosted_body('  run python3 "$HELPERS/absent_probe.py"')
            )

        def symlinked_new_helper(root: Path, manifest_path: Path) -> None:
            # A newly referenced helper that resolves to a symlink, not a regular file: `present`
            # includes it (the scan does not look past the symlink), but `_safe_file` refuses it.
            (root / "bats" / "helpers" / "synthetic_probe.py").symlink_to(
                root / "bats" / "helpers" / "bounded_exec.py"
            )
            install_rehashed_source(
                root, manifest_path, "hosted",
                hosted_body('  run python3 "$HELPERS/synthetic_probe.py"'),
            )

        cases = (
            (
                missing_pinned_helper,
                "helper bats/helpers/messages_db_probe.py is missing or not a regular file "
                "(restore it, or remove its pin by hand in a reviewed change; --update-shas never "
                "removes a helper pin)",
            ),
            (stale_manifest, "file content drift in inventory file bats/hosted/sample.bats"),
            (ambiguous_helper_reference, ambiguous_reference(8)),
            (
                absent_helper,
                "hosted file bats/hosted/sample.bats references helper "
                "bats/helpers/absent_probe.py, which is not a file in bats/helpers",
            ),
            (
                symlinked_new_helper,
                "helper bats/helpers/synthetic_probe.py is not a regular file",
            ),
        )
        for mutate, expected in cases:
            with self.subTest(case=mutate.__name__), tempfile.TemporaryDirectory() as temporary_directory:
                directory = Path(temporary_directory)
                root = directory / "root"
                manifest_path = write_fixture_manifest(root)
                script = copy_checker(directory / "tool")
                before = script.read_bytes()
                mutate(root, manifest_path)

                report, errors = checker.update_trusted_shas(root, manifest_path, script)

                self.assertEqual(script.read_bytes(), before)
            self.assertEqual(report, ())
            self.assertIn(expected, errors)
            if mutate is stale_manifest:
                self.assertEqual(
                    errors[0],
                    "the tree fails the inventory even with regenerated pins; fix these first "
                    "(an edited Bats file needs its bats/tier-inventory.json entry brought up to "
                    "date):",
                )
            if mutate is symlinked_new_helper:
                # The plain message, never the restore-or-remove phrasing reserved for a helper
                # that was already pinned.
                self.assertNotIn("restore it, or remove its pin by hand", " ".join(errors))

    def test_update_shas_refuses_to_pin_a_hosted_path_with_an_unsafe_character(self) -> None:
        # This refusal is all that keeps a path out of the rewritten Python literal, so each file
        # really exists and is listed: without the refusal the tree would pass, and a quote or a
        # backslash would be written into the script's source.
        checker = load_checker()
        for character, label in (
            (" ", "a space"),
            ("\x1b", "a control character"),
            ('"', "a double quote"),
            ("\\", "a backslash"),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary_directory:
                directory = Path(temporary_directory)
                root = directory / "root"
                manifest_path = write_fixture_manifest(root)
                script = copy_checker(directory / "tool")
                before = script.read_bytes()
                relative = f"bats/hosted/a{character}b.bats"
                (root / "bats" / "hosted" / "sample.bats").rename(root / relative)
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                manifest["tiers"]["hosted"]["files"][0]["path"] = relative
                manifest_path.write_text(
                    json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
                )

                report, errors = checker.update_trusted_shas(root, manifest_path, script)

                self.assertEqual(script.read_bytes(), before)
            self.assertEqual(report, ())
            self.assertEqual(
                errors,
                ("hosted file a path outside [A-Za-z0-9_./-] cannot be pinned",),
            )

    def test_update_shas_refuses_to_pin_a_pre_existing_helper_with_an_unsafe_character(
        self,
    ) -> None:
        # A name `_helper_references` extracts can never carry an unsafe character --
        # `HELPER_REFERENCE_NAME` only ever captures `[A-Za-z0-9_.-]`, so a *referenced* helper
        # can never reach `_display_path`'s mismatch branch below. The only other way a path
        # lands in `helper_paths` is a pre-existing entry already in the script's own pinned
        # literal, which `_pin_literal` parses from any quoted text (space and control
        # characters included); this test reaches the helper side of the same check that way.
        checker = load_checker()
        for character, label in ((" ", "a space"), ("\x1b", "a control character")):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary_directory:
                directory = Path(temporary_directory)
                root = directory / "root"
                manifest_path = write_fixture_manifest(root)
                script = copy_checker(directory / "tool")
                original = script.read_text(encoding="utf-8")
                helper_literal = next(
                    match.group(0) for match in PIN_LITERAL.finditer(original)
                    if match.group(1) == "TRUSTED_HOSTED_HELPER_SHA256"
                )
                unsafe_entry = f'    "bats/helpers/a{character}b.py": "{"0" * 64}",\n'
                mutated_literal = helper_literal[:-2] + unsafe_entry + helper_literal[-2:]
                mutated = original.replace(helper_literal, mutated_literal, 1)
                script.write_text(mutated, encoding="utf-8")

                report, errors = checker.update_trusted_shas(root, manifest_path, script)

                self.assertEqual(script.read_text(encoding="utf-8"), mutated)
            self.assertEqual(report, ())
            self.assertEqual(
                errors,
                ("helper a path outside [A-Za-z0-9_./-] cannot be pinned",),
            )

    def test_update_shas_never_runs_in_ci_or_beside_a_policy_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = Path(temporary_directory)
            root = directory / "root"
            manifest_path = write_fixture_manifest(root)
            script = copy_checker(root)
            before = script.read_bytes()
            # The guard tests presence, not value: "1" is not the string "true", and an empty
            # value is still set, so a guard narrowed to `== "true"` or to a truthy value would
            # let these through and turn them red.
            refusals = {
                (flag, value): run_update_shas(script, root, manifest_path, **{flag: value})
                for flag in ("CI", "GITHUB_ACTIONS")
                for value in ("true", "1", "")
            }
            # A copy outside --root would write --root's digests into a script that does not
            # sit beside those files.
            outside_script = copy_checker(directory / "tool")
            outside_before = outside_script.read_bytes()
            outside = run_update_shas(outside_script, root, manifest_path)
            outside_after = outside_script.read_bytes()
            # --root's copy as a symlink to that outside copy: both paths resolve to one file, so
            # comparing resolved paths alone would let the rewrite land outside --root.
            linked_root = directory / "linked-root"
            linked_manifest = write_fixture_manifest(linked_root)
            linked_script = linked_root / "scripts" / "ci" / "bats_inventory.py"
            linked_script.parent.mkdir(parents=True)
            linked_script.symlink_to(outside_script)
            linked = {
                "through the link": run_update_shas(linked_script, linked_root, linked_manifest),
                "from the target": run_update_shas(outside_script, linked_root, linked_manifest),
            }
            linked_after = outside_script.read_bytes()
            with_policy_root = subprocess.run(
                [sys.executable, str(script), "--root", str(root), "--update-shas",
                 "--policy-root", str(root)],
                check=False,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            with_policy_manifest = subprocess.run(
                [sys.executable, str(script), "--root", str(root), "--manifest",
                 str(manifest_path), "--update-shas", "--policy-manifest", str(manifest_path)],
                check=False,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            after = script.read_bytes()

            # A synthetic root and a synthetic copy, never the real script: with CI and
            # GITHUB_ACTIONS both absent from the environment the guard must step aside and let
            # --update-shas run, so narrowing it to `== "true"` leaves CI=1 above refused while
            # this still proceeds, rather than turning red for the right reason.
            proceeding_root = directory / "proceeding-root"
            proceeding_manifest = write_fixture_manifest(proceeding_root)
            proceeding_script = copy_checker(proceeding_root)
            proceeds = run_update_shas(proceeding_script, proceeding_root, proceeding_manifest)

        self.assertEqual(after, before)
        for (flag, value), refusal in refusals.items():
            with self.subTest(flag=flag, value=value):
                self.assertEqual(refusal.returncode, 1)
                self.assertEqual(refusal.stdout, "")
                self.assertIn(
                    "it never runs in CI (CI or GITHUB_ACTIONS is set, even to an empty value)",
                    refusal.stderr,
                )
        self.assertEqual(outside.returncode, 1)
        self.assertEqual(outside.stdout, "")
        self.assertIn(
            "it rewrites the script it runs from, which must be scripts/ci/bats_inventory.py "
            "inside --root",
            outside.stderr,
        )
        self.assertEqual(outside_after, outside_before)
        for label, refusal in linked.items():
            with self.subTest(symlinked_script=label):
                self.assertEqual(refusal.returncode, 1)
                self.assertEqual(refusal.stdout, "")
                self.assertIn("inside --root, a regular file and not a symlink", refusal.stderr)
        self.assertEqual(linked_after, outside_before)
        for guard, with_policy in (
            ("policy-root", with_policy_root), ("policy-manifest", with_policy_manifest)
        ):
            with self.subTest(guard=guard):
                self.assertEqual(with_policy.returncode, 2)
                self.assertIn("--update-shas takes --root and --manifest only", with_policy.stderr)
        self.assertEqual(proceeds.returncode, 0, proceeds.stderr)
        self.assertEqual(proceeds.stderr, "")
        self.assertNotIn("never runs in CI", proceeds.stdout)
        self.assertIn("Bats tier inventory --update-shas:", proceeds.stdout)


if __name__ == "__main__":
    unittest.main()
