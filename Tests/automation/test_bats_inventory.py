import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
from types import ModuleType
from typing import Optional
import unittest
from contextlib import redirect_stderr, redirect_stdout


REPO_ROOT = Path(__file__).resolve().parents[2]
CHECKER_PATH = REPO_ROOT / "scripts" / "ci" / "bats_inventory.py"
MANIFEST_PATH = REPO_ROOT / "bats" / "tier-inventory.json"

EXPECTED_FILES = {
    "hosted": {
        "bats/hosted/bounded_exec.bats": 5,
        "bats/hosted/calendar.bats": 20,
        "bats/hosted/contacts.bats": 49,
        "bats/hosted/mail.bats": 124,
        "bats/hosted/messages.bats": 10,
        "bats/hosted/notes.bats": 39,
        "bats/hosted/reminders.bats": 38,
        "bats/hosted/smoke.bats": 26,
    },
    "local": {
        "bats/local/contacts.bats": 4,
        "bats/local/mail.bats": 103,
        "bats/local/mail-move-gmail.bats": 2,
        "bats/local/messages.bats": 16,
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


def bats_source(*titles: str) -> str:
    tests = "\n\n".join(
        f'@test "{title}" {{\n  true\n}}' for title in titles
    )
    contract = "\n".join(ROOT_CONTRACT)
    return f"#!/usr/bin/env bats\n\n{contract}\n\n{tests}\n"


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
    hosted_path.write_text(bats_source(*hosted_titles), encoding="utf-8")
    local_path.write_text(bats_source(*local_titles), encoding="utf-8")
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


class BatsInventoryTests(unittest.TestCase):
    def test_checker_exists(self) -> None:
        self.assertTrue(CHECKER_PATH.is_file(), "Bats inventory checker must exist")

    def test_repository_manifest_pins_the_approved_partition(self) -> None:
        checker = load_checker()
        manifest = checker.load_manifest(MANIFEST_PATH)

        self.assertEqual(manifest["schema_version"], 1)
        self.assertEqual(manifest["test_count"], 445)
        self.assertEqual(
            {tier: manifest["tiers"][tier]["test_count"] for tier in ("hosted", "local")},
            {"hosted": 311, "local": 134},
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
        self.assertEqual(
            checker.validate_repository(REPO_ROOT, MANIFEST_PATH),
            (),
        )

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

    def test_bats_discovery_bounds_output_and_kills_descendants(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fake_bats = root / "fake-bats.py"
            pid_file = root / "descendant.pid"
            fake_bats.write_text(
                textwrap.dedent(
                    f"""\
                    #!{sys.executable}
                    import pathlib, subprocess, sys, time
                    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
                    pathlib.Path({str(pid_file)!r}).write_text(str(child.pid), encoding="utf-8")
                    sys.stdout.buffer.write(b"x" * 33)
                    sys.stdout.buffer.flush()
                    while True:
                        time.sleep(1)
                    """
                ),
                encoding="utf-8",
            )
            fake_bats.chmod(0o700)
            candidate = root / "sample.bats"
            candidate.write_text(bats_source("sample"), encoding="utf-8")
            original_executables = checker.BATS_EXECUTABLES
            original_timeout = checker.BATS_COUNT_TIMEOUT_SECONDS
            checker.BATS_EXECUTABLES = (fake_bats,)
            checker.BATS_COUNT_TIMEOUT_SECONDS = 0.5
            started = time.monotonic()
            try:
                with self.assertRaisesRegex(
                    checker.InventoryError,
                    "^Bats discovery failed$",
                ):
                    checker._discover_bats_count(candidate, "private-candidate-path")
            finally:
                checker.BATS_EXECUTABLES = original_executables
                checker.BATS_COUNT_TIMEOUT_SECONDS = original_timeout

            self.assertLess(time.monotonic() - started, 2)
            descendant_pid = int(pid_file.read_text(encoding="utf-8"))
            for _ in range(100):
                try:
                    os.kill(descendant_pid, 0)
                except ProcessLookupError:
                    break
                subprocess.run(
                    [sys.executable, "-c", "import time; time.sleep(0.02)"],
                    check=False,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            try:
                os.kill(descendant_pid, 0)
            except ProcessLookupError:
                pass
            else:
                os.kill(descendant_pid, signal.SIGKILL)
                self.fail("Bats discovery left a descendant running")

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
                bats_source(*addition_titles),
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


if __name__ == "__main__":
    unittest.main()
