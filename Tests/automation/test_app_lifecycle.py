from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import textwrap
import time
from contextlib import redirect_stderr, redirect_stdout
from types import ModuleType
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
ENGINE_PATH = REPO_ROOT / "bats" / "helpers" / "app_lifecycle.py"
HOOK_PATH = REPO_ROOT / "bats" / "helpers" / "app_lifecycle.bash"
APPS = (
    ("mail", "Mail", "com.apple.mail"),
    ("notes", "Notes", "com.apple.Notes"),
    ("messages", "Messages", "com.apple.MobileSMS"),
    ("contacts", "Contacts", "com.apple.AddressBook"),
    ("calendar", "Calendar", "com.apple.iCal"),
    ("reminders", "Reminders", "com.apple.reminders"),
)


def load_engine() -> ModuleType:
    spec = importlib.util.spec_from_file_location("app_lifecycle", ENGINE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load app lifecycle planner")
    module = importlib.util.module_from_spec(spec)
    sys.modules["app_lifecycle"] = module
    spec.loader.exec_module(module)
    return module


def quote(value: object) -> str:
    return shlex.quote(str(value))


class AppLifecyclePlannerTests(unittest.TestCase):
    def setUp(self):
        self.engine = load_engine()

    def write_private(self, path: Path, value: str | bytes) -> None:
        if isinstance(value, str):
            path.write_text(value, encoding="utf-8")
        else:
            path.write_bytes(value)
        path.chmod(0o600)

    def test_python_is_pure_state_and_parsing(self):
        source = ENGINE_PATH.read_text(encoding="utf-8")
        for forbidden in (
            "import subprocess", "import signal", "osascript", "System Events",
            "lsappinfo", "os.kill", "SIGKILL",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, source)

    def test_snapshot_restore_plan_and_opt_out_are_strict(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state"
            self.engine.write_snapshot(state, disabled=False, running="101001")
            self.assertEqual(stat.S_IMODE(state.stat().st_mode), 0o600)
            self.assertEqual(self.engine.restore_plan(state, "111011"), ("notes", "calendar"))
            self.assertTrue(state.exists())
            self.assertEqual(self.engine.APPLICATION_KEYS, tuple(key for key, _, _ in APPS))
            self.assertEqual(
                self.engine.APPLICATION_IDENTITIES,
                {key: (name, bundle) for key, name, bundle in APPS},
            )
        for value in ("1", "true", "yes"):
            self.assertTrue(self.engine.preserve_requested({self.engine.PRESERVE_ENV: value}))
        for value in ("0", "false", "TRUE", " yes ", ""):
            with self.subTest(value=value), self.assertRaises(self.engine.LifecycleError):
                self.engine.preserve_requested({self.engine.PRESERVE_ENV: value})

    def test_state_reader_rejects_missing_malformed_symlink_oversize_and_bad_mode(self):
        for kind in ("missing", "malformed", "symlink", "oversize", "mode"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                state = Path(directory) / "state"
                if kind == "malformed":
                    self.write_private(state, '{"schema_version":1,"disabled":false,"running":"x"}')
                elif kind == "symlink":
                    target = Path(directory) / "target"
                    self.write_private(target, '{"schema_version":1,"disabled":false,"running":"000000"}')
                    state.symlink_to(target)
                elif kind == "oversize":
                    self.write_private(state, b"x" * (self.engine.MAX_STATE_BYTES + 1))
                elif kind == "mode":
                    self.write_private(state, '{"schema_version":1,"disabled":false,"running":"000000"}')
                    state.chmod(0o644)
                with self.assertRaises(self.engine.LifecycleError):
                    self.engine.restore_plan(state, "000000")

    def test_find_parser_accepts_absence_and_exact_single_asn(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / str(index) for index in range(2)]
            self.write_private(paths[0], "")
            self.write_private(paths[1], "\n")
            self.assertEqual(self.engine.parse_find_outputs("mail", *paths), "NONE")
            values = ("ASN:0x0-0x40c40c:\n", 'ASN:0x0-0x40c40c-"Mail":\n')
            for path, value in zip(paths, values):
                self.write_private(path, value)
            self.assertEqual(self.engine.parse_find_outputs("mail", *paths), "ASN:0x0-0x40c40c")

    def test_find_parser_rejects_malformed_multiple_mismatch_and_wrong_suffix(self):
        cases = (
            ("junk\n", ""),
            ("ASN:0x0-0x1:\nASN:0x0-0x1:\n", 'ASN:0x0-0x1-"Mail":\n'),
            ("ASN:0x0-0x2:\n", 'ASN:0x0-0x1-"Mail":\n'),
            ("ASN:0x0-0x1:\n", 'ASN:0x0-0x1-"Notes":\n'),
            (" \n", "\n"),
            ("\n\n", "\n"),
        )
        for values in cases:
            with self.subTest(values=values), tempfile.TemporaryDirectory() as directory:
                paths = [Path(directory) / str(index) for index in range(2)]
                for path, value in zip(paths, values):
                    self.write_private(path, value)
                with self.assertRaises(self.engine.LifecycleError):
                    self.engine.parse_find_outputs("mail", *paths)

    def test_info_parser_accepts_exact_identity_and_hashes_checkin(self):
        checkin = "2026-09-04 12:34:56 +0000"
        fixture = textwrap.dedent(f'''\
            "LSDisplayName"="Mail"
            "pid"=4242
            "CFBundleIdentifier"="com.apple.mail"
            "LSCheckInTime*"="{checkin}"
        ''')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "info"
            self.write_private(path, fixture)
            digest = hashlib.sha256(f'"{checkin}"'.encode("ascii")).hexdigest()
            self.assertEqual(
                self.engine.parse_info_output("mail", "ASN:0x0-0x40c40c", path),
                f"ASN:0x0-0x40c40c\t4242\t{digest}",
            )

    def test_info_parser_ignores_relative_age_drift_for_same_checkin(self):
        fixtures = (
            '"LSCheckInTime*"="100 seconds ago, 2026/09/04 12:34:56"\n',
            '"LSCheckInTime*"="101 seconds ago, 2026/09/04 12:34:56"\n',
        )
        identities = []
        with tempfile.TemporaryDirectory() as directory:
            for index, checkin in enumerate(fixtures):
                path = Path(directory) / str(index)
                self.write_private(
                    path,
                    '"LSDisplayName"="Mail"\n'
                    '"pid"=4242\n'
                    '"CFBundleIdentifier"="com.apple.mail"\n'
                    + checkin,
                )
                identities.append(
                    self.engine.parse_info_output("mail", "ASN:0x0-0x40c40c", path)
                )

        self.assertEqual(identities[0], identities[1])
        stable_digest = hashlib.sha256(b"2026/09/04 12:34:56").hexdigest()
        self.assertTrue(identities[0].endswith(f"\t{stable_digest}"))

    def test_info_parser_normalizes_quoted_and_unquoted_checkin_displays(self):
        absolute = "2030/01/02 03:04:05"
        displays = (
            f"9 seconds ago, {absolute}",
            f"10 seconds ago, {absolute}",
            absolute,
            f'"11 seconds ago, {absolute}"',
            f'"{absolute}"',
        )
        identities = []
        with tempfile.TemporaryDirectory() as directory:
            for index, display in enumerate(displays):
                path = Path(directory) / str(index)
                self.write_private(
                    path,
                    '"LSDisplayName"="Mail"\n'
                    '"pid"=4242\n'
                    '"CFBundleIdentifier"="com.apple.mail"\n'
                    f'"LSCheckInTime*"={display}\n',
                )
                identities.append(
                    self.engine.parse_info_output("mail", "ASN:0x0-0x40c40c", path)
                )

            changed = Path(directory) / "changed"
            self.write_private(
                changed,
                '"LSDisplayName"="Mail"\n'
                '"pid"=4242\n'
                '"CFBundleIdentifier"="com.apple.mail"\n'
                '"LSCheckInTime*"=2030/01/02 03:04:06\n',
            )
            changed_identity = self.engine.parse_info_output(
                "mail", "ASN:0x0-0x40c40c", changed
            )

        expected_digest = hashlib.sha256(absolute.encode("ascii")).hexdigest()
        self.assertEqual(len(set(identities)), 1)
        self.assertTrue(identities[0].endswith(f"\t{expected_digest}"))
        self.assertNotEqual(identities[0], changed_identity)

    def test_info_parser_accepts_exact_observed_complete_stopped_record(self):
        fixture = (
            '"LSDisplayName"=  [ NULL ]  \n'
            '"pid"=[ NULL ]\t\n'
            '"CFBundleIdentifier"= [ NULL ]\n'
            '"LSCheckInTime*"=[ NULL ]   \n'
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "info"
            self.write_private(path, fixture)
            self.assertEqual(self.engine.parse_info_output("mail", "ASN:0x0-0x1", path), "STOPPED")

    def test_info_parser_rejects_bare_or_partial_observed_null(self):
        fixtures = (
            "LSDisplayName=NULL\npid=NULL\nCFBundleIdentifier=NULL\nLSCheckInTime*=NULL\n",
            'LSDisplayName=[ NULL ]\npid=42\nCFBundleIdentifier=[ NULL ]\nLSCheckInTime*=[ NULL ]\n',
        )
        for fixture in fixtures:
            with self.subTest(fixture=fixture), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "info"
                self.write_private(path, fixture)
                with self.assertRaises(self.engine.LifecycleError):
                    self.engine.parse_info_output("mail", "ASN:0x0-0x1", path)

    def test_info_parser_rejects_unsafe_or_ambiguous_records(self):
        valid = {
            "LSDisplayName": '"Mail"', "pid": "4242",
            "CFBundleIdentifier": '"com.apple.mail"', "LSCheckInTime*": '"stamp"',
        }
        mutations = (
            {"pid": "NULL"}, {"LSDisplayName": '"Notes"'},
            {"CFBundleIdentifier": '"COM.APPLE.MAIL"'}, {"pid": "0"},
            {"pid": "+2"}, {"pid": "１２"}, {"pid": "99999999999"},
            {"LSCheckInTime*": '"café"'}, {"LSCheckInTime*": '"' + "x" * 1025 + '"'},
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                values = dict(valid); values.update(mutation)
                path = Path(directory) / "info"
                self.write_private(path, "".join(f"{key}={value}\n" for key, value in values.items()))
                with self.assertRaises(self.engine.LifecycleError):
                    self.engine.parse_info_output("mail", "ASN:0x0-0x1", path)
        for fixture in (
            "LSDisplayName=\"Mail\"\nLSDisplayName=\"Mail\"\npid=2\nCFBundleIdentifier=\"com.apple.mail\"\nLSCheckInTime*=x\n",
            "LSDisplayName=\"Mail\"\npid=2\nCFBundleIdentifier=\"com.apple.mail\"\nLSCheckInTime*=x\nunknown=y\n",
        ):
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "info"; self.write_private(path, fixture)
                with self.assertRaises(self.engine.LifecycleError):
                    self.engine.parse_info_output("mail", "ASN:0x0-0x1", path)

    def test_parser_cli_is_generic_and_never_echoes_private_input(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "private-name"
            self.write_private(path, "private-process-output\n")
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                status = self.engine.run([
                    "parse-info", "--app", "mail", "--asn", "private-asn", "--output", str(path)
                ])
            self.assertEqual(status, 1)
            self.assertEqual(stderr.getvalue(), "app lifecycle operation failed\n")
            # A record that PARSES far enough to be refused by a named check carries that
            # check's fixed reason code — and still not one byte of the record itself.
            self.write_private(path, "LSDisplayName=\"private-name\"\npid=42\nCFBundleIdentifier=\"private.bundle\"\nLSCheckInTime*=2026/01/01 00:00:00\n")
            coded = io.StringIO()
            with redirect_stderr(coded):
                status = self.engine.run([
                    "parse-info", "--app", "mail", "--asn", "ASN:0x0-0x1", "--output", str(path)
                ])
            self.assertEqual(status, 1)
            self.assertEqual(coded.getvalue(), "app lifecycle operation failed: info-name-mismatch\n")
            self.assertNotIn("private", coded.getvalue())


class AppLifecycleShellTests(unittest.TestCase):
    def run_shell(self, body: str, *, env: dict[str, str] | None = None, timeout: float = 10) -> subprocess.CompletedProcess:
        script = f"source {quote(HOOK_PATH)}\n{body}"
        merged = os.environ.copy()
        if env:
            merged.update(env)
        return subprocess.run(["/bin/bash", "-c", script], capture_output=True, text=True, env=merged, timeout=timeout)

    def test_python_wrapper_rejects_unexpected_stderr_without_echoing_it(self):
        fixtures = (
            b"/private/example/secret-value.py: unable to open file\n",
            b'Traceback (most recent call last):\n  File "/private/example/secret-value.py", line 1\nValueError: private-value\n',
            b"private alphabetic value\n",
            b"app lifecycle operation failed: private-value\n",
            b"app lifecycle operation failed: info-field\nprivate-value\n",
            b"app lifecycle operation failed: info-field\n\n",
            b"app lifecycle operation failed: info-field\x00\n",
            b"app lifecycle operation failed: info-field",
            b"",
        )
        for payload in fixtures:
            with self.subTest(payload=payload), tempfile.TemporaryDirectory() as directory:
                helper = Path(directory) / "app_lifecycle.py"
                helper.write_text(f"import sys\nsys.stderr.buffer.write({payload!r})\nraise SystemExit(1)\n")
                completed = self.run_shell(f"""\
                    HELPERS={quote(directory)}
                    app_lifecycle_python {quote(Path(directory) / 'error')}; status=$?
                    printf 'STATUS:%s\\n' "$status"
                    app_lifecycle_error "$APPLE_CLI_BATS_APP_LAST_REASON"
                """)
                self.assertEqual(completed.stdout, "STATUS:1\n")
                self.assertEqual(completed.stderr, "app lifecycle operation failed: python:unexpected-error\n")

    def test_python_wrapper_accepts_only_complete_fixed_diagnostics(self):
        codes = (
            "", "find-multiple", "find-name", "find-asn", "find-bundle-exact-disagree",
            "info-line-shape", "info-field", "info-fields-missing", "info-pid",
            "info-partial-null", "info-name-mismatch", "info-bundle-mismatch", "info-checkin",
        )
        diagnostics = [(1, "app lifecycle operation failed" + (f": {code}" if code else "")) for code in codes]
        diagnostics.append((130, "app lifecycle interrupted"))
        for status, diagnostic in diagnostics:
            with self.subTest(diagnostic=diagnostic), tempfile.TemporaryDirectory() as directory:
                helper = Path(directory) / "app_lifecycle.py"
                helper.write_text(f"import sys\nprint({diagnostic!r}, file=sys.stderr)\nraise SystemExit({status})\n")
                completed = self.run_shell(f"""\
                    HELPERS={quote(directory)}
                    app_lifecycle_python {quote(Path(directory) / 'error')}; status=$?
                    printf 'STATUS:%s\\n' "$status"
                    app_lifecycle_error "$APPLE_CLI_BATS_APP_LAST_REASON"
                """)
                self.assertEqual(completed.stdout, f"STATUS:{status}\n")
                self.assertEqual(completed.stderr, f"app lifecycle operation failed: python:{diagnostic}\n")

    def test_python_wrapper_rejects_invalid_error_destinations_without_leaks(self):
        for kind in ("missing-parent", "directory", "fifo", "symlink", "dangling-symlink"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                marker = root / "executed"
                target = root / "preserved"
                target.write_text("preserve-me")
                target.chmod(0o644)
                error = root / "private-error"
                if kind == "missing-parent":
                    error = root / "private-missing" / "error"
                elif kind == "directory":
                    error.mkdir()
                elif kind == "fifo":
                    os.mkfifo(error, 0o600)
                else:
                    error.symlink_to(target if kind == "symlink" else root / "absent")
                (root / "app_lifecycle.py").write_text(
                    f"from pathlib import Path\nimport sys\nPath({str(marker)!r}).touch()\n"
                    "print('private-value', file=sys.stderr)\nraise SystemExit(1)\n"
                )
                completed = self.run_shell(f"""\
                    HELPERS={quote(root)}
                    APPLE_CLI_BATS_APP_LAST_REASON=stale-reason
                    app_lifecycle_python {quote(error)}; status=$?
                    printf 'STATUS:%s\\n' "$status"
                    app_lifecycle_error "$APPLE_CLI_BATS_APP_LAST_REASON"
                """)
                self.assertEqual(completed.stdout, "STATUS:1\n")
                self.assertEqual(completed.stderr, "app lifecycle operation failed: python:unexpected-error\n")
                self.assertFalse(marker.exists())
                self.assertEqual(target.read_text(), "preserve-me")
                self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o644)
                self.assertFalse((root / "absent").exists())

    def test_python_wrapper_recreates_reused_capture_privately_before_writing(self):
        for linked in (False, True):
            with self.subTest(linked=linked), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                error = root / "error"
                target = root / "preserved"
                target.write_text("preserve-me")
                target.chmod(0o644)
                if linked:
                    os.link(target, error)
                else:
                    error.write_text("old-output")
                    error.chmod(0o644)
                (root / "app_lifecycle.py").write_text(
                    "import os, stat, sys\n"
                    "print('MODE:%o' % stat.S_IMODE(os.fstat(2).st_mode))\n"
                    "print('private-value', file=sys.stderr)\nraise SystemExit(1)\n"
                )
                completed = self.run_shell(f"""\
                    HELPERS={quote(root)}
                    app_lifecycle_python {quote(error)}; status=$?
                    printf 'STATUS:%s\\n' "$status"
                    app_lifecycle_error "$APPLE_CLI_BATS_APP_LAST_REASON"
                """)
                self.assertEqual(completed.stdout, "MODE:600\nSTATUS:1\n")
                self.assertEqual(completed.stderr, "app lifecycle operation failed: python:unexpected-error\n")
                self.assertEqual(error.read_text(), "private-value\n")
                self.assertEqual(stat.S_IMODE(error.stat().st_mode), 0o600)
                self.assertEqual(target.read_text(), "preserve-me")
                self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o644)

    def test_shell_uses_only_targeted_launchservices_calls(self):
        source = HOOK_PATH.read_text(encoding="utf-8")
        self.assertNotIn("osascript", source)
        self.assertNotIn("System Events", source)
        self.assertNotIn("app_lifecycle_ps", source)
        self.assertEqual(source.count("/usr/bin/lsappinfo"), 1)
        self.assertNotRegex(source, r"lsappinfo[^\n]*(?:\slist\s|\s-list\s)")
        self.assertNotRegex(source, r"\$\([^\n]*lsappinfo")
        self.assertNotIn("app_lifecycle_kill_pid", source)
        self.assertNotRegex(source, r"kill\s+-KILL\s+--\s+\"?\$?(?:pid|APP_LIFECYCLE_PID)")
        self.assertNotIn("kill -force", source)
        self.assertNotIn("kill -childapps", source)
        self.assertNotIn("kill -coalition", source)
        self.assertNotIn("kill -launchdjobs", source)
        self.assertRegex(source, r'app_lifecycle_lsappinfo_exec "\$@"[^\n]*&\n[ \t]*APPLE_CLI_BATS_APP_CHILD_PID=\$!')
        target_find = source[source.index("app_lifecycle_target_find()") : source.index("app_lifecycle_observe()")]
        self.assertEqual(target_find.count("app_lifecycle_run_lsappinfo"), 2)
        self.assertNotRegex(target_find, r'find "name=\$APP_LIFECYCLE_NAME"\s*$')
        self.assertIn('find "bundleid=$APP_LIFECYCLE_BUNDLE"', target_find)
        self.assertIn('find "name=$APP_LIFECYCLE_NAME" "bundleid=$APP_LIFECYCLE_BUNDLE"', target_find)
        documentation = (REPO_ROOT / "AGENTS.md").read_text(encoding="utf-8")
        self.assertIn("Name-only queries are deliberately excluded", documentation)
        self.assertIn("helper process", documentation)

    def test_bats_load_activates_file_setup_and_teardown_hooks(self):
        bats = Path("/opt/homebrew/bin/bats")
        if not bats.is_file():
            self.skipTest("Bats is unavailable")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "calls"
            test_file = root / "hook.bats"
            test_file.write_text(textwrap.dedent(f"""\
                #!/usr/bin/env bats
                load {quote(str(HOOK_PATH.with_suffix('')))}
                app_lifecycle_setup_file_impl() {{ printf '%s\n' setup >> "$LOG_PATH"; APPLE_CLI_BATS_APP_SNAPSHOT_READY=true; }}
                app_lifecycle_teardown_file_impl() {{ printf '%s\n' teardown >> "$LOG_PATH"; }}
                @test "hook body" {{ printf '%s\n' test >> "$LOG_PATH"; }}
            """), encoding="utf-8")
            completed = subprocess.run(
                [str(bats), str(test_file)],
                capture_output=True,
                text=True,
                env={**os.environ, "LOG_PATH": str(log)},
                timeout=10,
            )
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            self.assertEqual(log.read_text(encoding="utf-8").splitlines(), ["setup", "test", "teardown"])

    def test_bats_teardown_restores_same_instance_after_relative_age_drift(self):
        bats = Path("/opt/homebrew/bin/bats")
        if not bats.is_file():
            self.skipTest("Bats is unavailable")
        stable_digest = hashlib.sha256(b"2026/09/04 12:34:56").hexdigest()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "calls"
            test_file = root / "age-drift.bats"
            test_file.write_text(textwrap.dedent(f"""\
                #!/usr/bin/env bats
                HELPERS={quote(HOOK_PATH.parent)}
                load {quote(str(HOOK_PATH.with_suffix('')))}
                app_lifecycle_setup_file_impl() {{
                  /usr/bin/python3 "$HELPERS/app_lifecycle.py" write-snapshot \
                    --state "$BATS_FILE_TMPDIR/apple-cli-app-state.json" --running 000000
                  APPLE_CLI_BATS_APP_SNAPSHOT_READY=true
                }}
                app_lifecycle_observe() {{
                  if [ -e "$BATS_FILE_TMPDIR/killed" ]; then
                    APPLE_CLI_BATS_APP_RESULT=000000
                    APPLE_CLI_BATS_APP_OBSERVED_MAIL=""
                  else
                    APPLE_CLI_BATS_APP_RESULT=100000
                    APPLE_CLI_BATS_APP_OBSERVED_MAIL=$'ASN:0x0-0x40c40c\t4242\t{stable_digest}'
                  fi
                }}
                app_lifecycle_lsappinfo_exec() {{
                  op="$1"; shift
                  case "$op" in
                    find) printf '%s\n' 'ASN:0x0-0x40c40c-"Mail":' ;;
                    info)
                      if [ -e "$BATS_FILE_TMPDIR/killed" ]; then
                        printf '%s\n' 'LSDisplayName=[ NULL ]' 'pid=[ NULL ]' \
                          'CFBundleIdentifier=[ NULL ]' 'LSCheckInTime*=[ NULL ]'
                      else
                        count=0
                        [ ! -e "$BATS_FILE_TMPDIR/info-count" ] || count=$(<"$BATS_FILE_TMPDIR/info-count")
                        count=$((count + 1)); printf '%s' "$count" > "$BATS_FILE_TMPDIR/info-count"
                        age=$((99 + count))
                        printf 'LSDisplayName="Mail"\npid=4242\nCFBundleIdentifier="com.apple.mail"\nLSCheckInTime*="%s seconds ago, 2026/09/04 12:34:56"\n' "$age"
                      fi
                      ;;
                    kill)
                      : > "$BATS_FILE_TMPDIR/killed"
                      printf '%s\n' TERM >> "$LOG_PATH"
                      ;;
                    *) return 68 ;;
                  esac
                }}
                @test "body" {{ true; }}
            """), encoding="utf-8")
            completed = subprocess.run(
                [str(bats), str(test_file)],
                capture_output=True,
                text=True,
                env={**os.environ, "LOG_PATH": str(log)},
                timeout=10,
            )

            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            self.assertEqual(log.read_text(encoding="utf-8").splitlines(), ["TERM"])

    def test_application_case_arms_pin_exact_name_bundle_pairs(self):
        source = HOOK_PATH.read_text(encoding="utf-8")
        for key, name, bundle in APPS:
            self.assertRegex(source, rf"(?m)^    {key}\) APP_LIFECYCLE_NAME={name}; APP_LIFECYCLE_BUNDLE={re.escape(bundle)} ;;$")

    def test_observe_captures_full_identity_for_the_exact_observed_asn(self):
        body = textwrap.dedent("""\
            tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
            app_lifecycle_target_find() {
              if [ "$1" = mail ]; then APPLE_CLI_BATS_APP_RESULT=ASN:0x0-0x1
              else APPLE_CLI_BATS_APP_RESULT=NONE
              fi
            }
            app_lifecycle_info() {
              printf '%s\n' "$1:$2" >> "$tmp/info-calls"
              APPLE_CLI_BATS_APP_RESULT=$'ASN:0x0-0x1\t42\ttoken'
            }
            app_lifecycle_observe "$tmp/observe" true; status=$? running="$APPLE_CLI_BATS_APP_RESULT"
            app_lifecycle_observed_identity mail; identity="$APPLE_CLI_BATS_APP_RESULT"
            printf 'STATUS:%s RUNNING:%s IDENTITY:%s\n' "$status" "$running" "$identity"
            sed -n '1,99p' "$tmp/info-calls"
        """)
        completed = self.run_shell(body)
        self.assertEqual(
            completed.stdout.splitlines(),
            ["STATUS:0 RUNNING:100000 IDENTITY:ASN:0x0-0x1\t42\ttoken", "mail:ASN:0x0-0x1"],
        )
        self.assertEqual(completed.stderr, "")

    def fake_body(self, scenario: str) -> str:
        return textwrap.dedent(f"""\
            tmp=$(mktemp -d)
            trap 'rm -rf "$tmp"' EXIT
            HELPERS={quote(HOOK_PATH.parent)}
            export FAKE_DIR="$tmp" FAKE_SCENARIO={quote(scenario)}
            app_lifecycle_lsappinfo_exec() {{
              op="$1"; shift
              case "$op" in
                find)
                  case "$#:$1:${{2-}}" in
                    1:bundleid=com.apple.mail:) kind=bundle ;;
                    2:name=Mail:bundleid=com.apple.mail) kind=exact ;;
                    *) exit 65 ;;
                  esac
                  printf 'FIND:%s\n' "$kind" >> "$FAKE_DIR/log"
                  printf '%s\n' 'ASN:0x0-0x40c40c-"Mail":'
                  ;;
                info)
                  [ "$*" = '-only name -only pid -only bundleID -only kLSCheckInTimeKey -app ASN:0x0-0x40c40c' ] || exit 66
                  count=0; [ ! -f "$FAKE_DIR/count" ] || count=$(<"$FAKE_DIR/count")
                  count=$((count + 1)); printf '%s' "$count" > "$FAKE_DIR/count"
                  printf 'INFO:%s\n' "$count" >> "$FAKE_DIR/log"
                  if [ "$FAKE_SCENARIO" = stopped ] && [ "$count" -ge 2 ]; then
                    printf '%s\n' 'LSDisplayName=[ NULL ]' 'pid=[ NULL ]' 'CFBundleIdentifier=[ NULL ]' 'LSCheckInTime*=[ NULL ]'
                  elif [ "$FAKE_SCENARIO" = grace ] && [ "$count" -ge 3 ]; then
                    printf '%s\n' 'LSDisplayName=[ NULL ]' 'pid=[ NULL ]' 'CFBundleIdentifier=[ NULL ]' 'LSCheckInTime*=[ NULL ]'
                  elif [ "$FAKE_SCENARIO" = postkill ] && [ "$count" -ge 4 ]; then
                    printf '%s\n' 'LSDisplayName=[ NULL ]' 'pid=[ NULL ]' 'CFBundleIdentifier=[ NULL ]' 'LSCheckInTime*=[ NULL ]'
                  elif [ "$FAKE_SCENARIO" = replacement ] && [ "$count" -ge 2 ]; then
                    printf '%s\n' 'LSDisplayName="Mail"' 'pid=4243' 'CFBundleIdentifier="com.apple.mail"' 'LSCheckInTime*="new"'
                  elif [ "$FAKE_SCENARIO" = changedtoken ] && [ "$count" -ge 2 ]; then
                    printf '%s\n' 'LSDisplayName="Mail"' 'pid=4242' 'CFBundleIdentifier="com.apple.mail"' 'LSCheckInTime*="new"'
                  else
                    printf '%s\n' 'LSDisplayName="Mail"' 'pid=4242' 'CFBundleIdentifier="com.apple.mail"' 'LSCheckInTime*="old"'
                  fi
                  ;;
                kill)
                  case "$#:$1:${{2-}}" in
                    1:ASN:0x0-0x40c40c:) printf '%s\n' TERM >> "$FAKE_DIR/log"; [ "$FAKE_SCENARIO" != refusal ] ;;
                    2:-hard:ASN:0x0-0x40c40c) printf '%s\n' HARD >> "$FAKE_DIR/log" ;;
                    *) exit 67 ;;
                  esac
                  ;;
                *) exit 68 ;;
              esac
            }}
            APPLE_CLI_BATS_APP_GRACE_TICKS=0
            APPLE_CLI_BATS_APP_TERM_TICKS=0
            APPLE_CLI_BATS_APP_POLL_SECONDS=0
            app_lifecycle_target_find mail "$tmp/observed.find"
            asn="$APPLE_CLI_BATS_APP_RESULT"
            app_lifecycle_info mail "$asn" "$tmp/observed"
            observed="$APPLE_CLI_BATS_APP_RESULT"
            app_lifecycle_restore_one mail "$observed" "$tmp/work"
            status=$?
            printf 'STATUS:%s\n' "$status"
            sed -n '1,99p' "$tmp/log"
            """)

    def test_restore_call_order_is_targeted_and_instance_bound(self):
        completed = self.run_shell(self.fake_body("postkill"))
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout.splitlines(), [
            "STATUS:0", "FIND:bundle", "FIND:exact", "INFO:1",
            "INFO:2", "TERM", "INFO:3", "HARD", "INFO:4",
        ])

    def test_restore_stopped_replacement_refusal_and_persistent_fail_closed(self):
        expectations = {
            "stopped": ("STATUS:0", False), "grace": ("STATUS:0", False),
            "replacement": ("STATUS:1", False),
            "changedtoken": ("STATUS:1", False), "refusal": ("STATUS:1", False),
            "persistent": ("STATUS:1", True),
        }
        for scenario, (status, hard_killed) in expectations.items():
            with self.subTest(scenario=scenario):
                completed = self.run_shell(self.fake_body(scenario))
                lines = completed.stdout.splitlines()
                self.assertEqual(lines[0], status, completed.stderr)
                self.assertEqual("HARD" in lines, hard_killed)

    def test_watchdog_latches_four_signals_and_kills_only_its_running_child(self):
        for name, number, status in (("INT", signal.SIGINT, 130), ("TERM", signal.SIGTERM, 143), ("HUP", signal.SIGHUP, 129), ("QUIT", signal.SIGQUIT, 131)):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                script = Path(directory) / "probe.sh"
                script.write_text(textwrap.dedent(f"""\
                    source {quote(HOOK_PATH)}
                    app_lifecycle_lsappinfo_exec() {{ while :; do sleep 1; done; }}
                    app_lifecycle_after_spawn() {{ kill -{name} $$; }}
                    APPLE_CLI_BATS_APP_POLL_SECONDS=0.01
                    APPLE_CLI_BATS_APP_TERM_TICKS=1
                    app_lifecycle_run_lsappinfo {quote(Path(directory) / 'out')} find name=Mail
                    printf 'STATUS:%s CHILD:%s\n' "$?" "$APPLE_CLI_BATS_APP_CHILD_PID"
                """), encoding="utf-8")
                completed = subprocess.run(["/bin/bash", str(script)], capture_output=True, text=True, timeout=5)
                self.assertEqual(completed.stdout.strip(), f"STATUS:{status} CHILD:", completed.stderr)

    def test_watchdog_timeout_terminates_its_child(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "term"
            ready = Path(directory) / "ready"
            body = textwrap.dedent(f"""\
                app_lifecycle_lsappinfo_exec() {{
                  trap 'printf term > {quote(marker)}; exit 0' TERM
                  : > {quote(ready)}
                  while :; do :; done
                }}
                app_lifecycle_after_spawn() {{
                  ready_ticks=0
                  while [ ! -e {quote(ready)} ] && [ "$ready_ticks" -lt 1000 ]; do
                    sleep 0.001
                    ready_ticks=$((ready_ticks + 1))
                  done
                  [ -e {quote(ready)} ]
                }}
                APPLE_CLI_BATS_APP_TIMEOUT_TICKS=0
                APPLE_CLI_BATS_APP_TERM_TICKS=5
                APPLE_CLI_BATS_APP_POLL_SECONDS=0.01
                app_lifecycle_run_lsappinfo {quote(Path(directory) / 'out')} find name=Mail
                printf 'STATUS:%s CHILD:%s READY:%s MARKER:%s\n' "$?" "$APPLE_CLI_BATS_APP_CHILD_PID" "$(test -e {quote(ready)}; printf '%s' $?)" "$(test -e {quote(marker)}; printf '%s' $?)"
            """)
            completed = self.run_shell(body, timeout=5)
            self.assertEqual(completed.stdout, "STATUS:124 CHILD: READY:0 MARKER:0\n", completed.stderr)

    def test_setup_failure_sentinel_and_valid_opt_out_make_no_queries(self):
        body = textwrap.dedent("""\
            tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
            BATS_FILE_TMPDIR="$tmp"; HELPERS="${HOOK_PATH%/*}"
            calls="$tmp/calls"; app_lifecycle_lsappinfo_exec() { printf x >> "$calls"; return 1; }
            APPLE_CLI_BATS_PRESERVE_APPS=1
            setup_file; first=$?; teardown_file; second=$?
            [ ! -e "$calls" ]
            printf '%s:%s:%s\n' "$first" "$second" "$APPLE_CLI_BATS_APP_SNAPSHOT_READY"
        """)
        completed = self.run_shell(body, env={"HOOK_PATH": str(HOOK_PATH)})
        self.assertEqual(completed.stdout, "0:0:true\n", completed.stderr)

    def test_failed_setup_suppresses_teardown_and_invalid_opt_out_fails(self):
        body = textwrap.dedent(f"""\
            tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
            BATS_FILE_TMPDIR="$tmp"; HELPERS={quote(HOOK_PATH.parent)}
            app_lifecycle_observe() {{ return 1; }}
            app_lifecycle_restore_one() {{ printf restore >> "$tmp/calls"; }}
            setup_file; first=$?; teardown_file; second=$?
            printf '%s:%s:%s:%s\n' "$first" "$second" "$APPLE_CLI_BATS_APP_SNAPSHOT_READY" "$(test -e "$tmp/calls"; printf '%s' $?)"
            APPLE_CLI_BATS_PRESERVE_APPS=false
            setup_file; printf 'INVALID:%s\n' "$?"
        """)
        completed = self.run_shell(body)
        self.assertEqual(completed.stdout, "1:0:false:1\nINVALID:1\n", completed.stderr)
        self.assertEqual(completed.stderr, "app lifecycle operation failed: setup:observe:1:\napp lifecycle operation failed: setup:opt-out-invalid\n")

    def test_teardown_continues_after_one_restore_failure_and_preserves_state(self):
        body = textwrap.dedent(f"""\
            tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
            BATS_FILE_TMPDIR="$tmp"; HELPERS={quote(HOOK_PATH.parent)}
            /usr/bin/python3 "$HELPERS/app_lifecycle.py" write-snapshot --state "$tmp/apple-cli-app-state.json" --running 000000
            APPLE_CLI_BATS_APP_SNAPSHOT_READY=true
            app_lifecycle_observe() {{
              APPLE_CLI_BATS_APP_RESULT=110000
              APPLE_CLI_BATS_APP_OBSERVED_MAIL=mail-identity
              APPLE_CLI_BATS_APP_OBSERVED_NOTES=notes-identity
            }}
            app_lifecycle_restore_one() {{ printf '%s\n' "$1" >> "$tmp/calls"; [ "$1" != mail ]; }}
            app_lifecycle_teardown_file_impl; status=$?
            printf 'STATUS:%s STATE:%s\n' "$status" "$(test -e "$tmp/apple-cli-app-state.json"; printf '%s' $?)"
            sed -n '1,99p' "$tmp/calls"
        """)
        completed = self.run_shell(body)
        self.assertEqual(completed.stdout.splitlines(), ["STATUS:1 STATE:0", "mail", "notes"])
        self.assertEqual(completed.stderr, "app lifecycle operation failed: teardown:restore-status=1:mail:round=0:\n")

    def test_teardown_does_not_reuse_reason_from_previous_restore_failure(self):
        body = textwrap.dedent(f"""\
            tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
            BATS_FILE_TMPDIR="$tmp"; HELPERS={quote(HOOK_PATH.parent)}
            /usr/bin/python3 "$HELPERS/app_lifecycle.py" write-snapshot --state "$tmp/apple-cli-app-state.json" --running 000000
            APPLE_CLI_BATS_APP_SNAPSHOT_READY=true
            app_lifecycle_observe() {{
              APPLE_CLI_BATS_APP_RESULT=110000
              APPLE_CLI_BATS_APP_OBSERVED_MAIL=mail-identity
              APPLE_CLI_BATS_APP_OBSERVED_NOTES=notes-identity
            }}
            app_lifecycle_restore_one() {{
              printf '%s\\n' "$1" >> "$tmp/calls"
              if [ "$1" = mail ]; then APPLE_CLI_BATS_APP_LAST_REASON=validate:mail:mismatch; return 1; fi
              return 2
            }}
            app_lifecycle_teardown_file_impl; status=$?
            printf 'STATUS:%s STATE:%s\\n' "$status" "$(test -e "$tmp/apple-cli-app-state.json"; printf '%s' $?)"
            cat "$tmp/calls"
        """)
        completed = self.run_shell(body)
        self.assertEqual(completed.stdout.splitlines(), ["STATUS:1 STATE:0", "mail", "notes"])
        self.assertEqual(completed.stderr, "app lifecycle operation failed: teardown:restore-status=2:notes:round=0:\n")

    def test_teardown_rescans_and_restores_late_registration(self):
        body = textwrap.dedent(f"""\
            tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
            BATS_FILE_TMPDIR="$tmp"; HELPERS={quote(HOOK_PATH.parent)}
            /usr/bin/python3 "$HELPERS/app_lifecycle.py" write-snapshot --state "$tmp/apple-cli-app-state.json" --running 000000
            APPLE_CLI_BATS_APP_SNAPSHOT_READY=true
            app_lifecycle_observe() {{
              count=0; [ ! -e "$tmp/observes" ] || count=$(<"$tmp/observes")
              count=$((count + 1)); printf '%s' "$count" > "$tmp/observes"
              APPLE_CLI_BATS_APP_OBSERVED_MAIL=""
              case "$count" in
                1) APPLE_CLI_BATS_APP_RESULT=000000 ;;
                2) APPLE_CLI_BATS_APP_RESULT=100000; APPLE_CLI_BATS_APP_OBSERVED_MAIL=$'ASN:0x0-0x1\t42\ttoken' ;;
                *) APPLE_CLI_BATS_APP_RESULT=000000 ;;
              esac
            }}
            app_lifecycle_restore_one() {{ printf '%s\n' "$1" >> "$tmp/restores"; }}
            APPLE_CLI_BATS_APP_QUIET_TICKS=1; APPLE_CLI_BATS_APP_SETTLE_TICKS=5
            APPLE_CLI_BATS_APP_POLL_SECONDS=0
            app_lifecycle_teardown_file_impl; status=$?
            printf 'STATUS:%s STATE:%s OBSERVES:%s\n' "$status" "$(test -e "$tmp/apple-cli-app-state.json"; printf '%s' $?)" "$(<"$tmp/observes")"
            sed -n '1,99p' "$tmp/restores"
        """)
        completed = self.run_shell(body)
        self.assertEqual(completed.stdout.splitlines(), ["STATUS:0 STATE:1 OBSERVES:4", "mail"])
        self.assertEqual(completed.stderr, "")

    def test_teardown_requires_bounded_quiet_window(self):
        body = textwrap.dedent(f"""\
            tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
            BATS_FILE_TMPDIR="$tmp"; HELPERS={quote(HOOK_PATH.parent)}
            /usr/bin/python3 "$HELPERS/app_lifecycle.py" write-snapshot --state "$tmp/apple-cli-app-state.json" --running 000000
            APPLE_CLI_BATS_APP_SNAPSHOT_READY=true
            app_lifecycle_observe() {{
              count=0; [ ! -e "$tmp/observes" ] || count=$(<"$tmp/observes")
              count=$((count + 1)); printf '%s' "$count" > "$tmp/observes"
              APPLE_CLI_BATS_APP_RESULT=000000
            }}
            app_lifecycle_restore_one() {{ return 70; }}
            APPLE_CLI_BATS_APP_QUIET_TICKS=2; APPLE_CLI_BATS_APP_SETTLE_TICKS=5
            APPLE_CLI_BATS_APP_POLL_SECONDS=0
            app_lifecycle_teardown_file_impl; status=$?
            printf 'STATUS:%s STATE:%s OBSERVES:%s\n' "$status" "$(test -e "$tmp/apple-cli-app-state.json"; printf '%s' $?)" "$(<"$tmp/observes")"
        """)
        completed = self.run_shell(body)
        self.assertEqual(completed.stdout, "STATUS:0 STATE:1 OBSERVES:3\n")
        self.assertEqual(completed.stderr, "")

    def test_teardown_quiescence_timeout_fails_and_preserves_state(self):
        body = textwrap.dedent(f"""\
            tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
            BATS_FILE_TMPDIR="$tmp"; HELPERS={quote(HOOK_PATH.parent)}
            /usr/bin/python3 "$HELPERS/app_lifecycle.py" write-snapshot --state "$tmp/apple-cli-app-state.json" --running 000000
            APPLE_CLI_BATS_APP_SNAPSHOT_READY=true
            app_lifecycle_observe() {{
              count=0; [ ! -e "$tmp/observes" ] || count=$(<"$tmp/observes")
              count=$((count + 1)); printf '%s' "$count" > "$tmp/observes"
              APPLE_CLI_BATS_APP_RESULT=000000
            }}
            APPLE_CLI_BATS_APP_QUIET_TICKS=3; APPLE_CLI_BATS_APP_SETTLE_TICKS=1
            APPLE_CLI_BATS_APP_POLL_SECONDS=0
            app_lifecycle_teardown_file_impl; status=$?
            printf 'STATUS:%s STATE:%s OBSERVES:%s\n' "$status" "$(test -e "$tmp/apple-cli-app-state.json"; printf '%s' $?)" "$(<"$tmp/observes")"
        """)
        completed = self.run_shell(body)
        self.assertEqual(completed.stdout, "STATUS:1 STATE:0 OBSERVES:2\n")
        self.assertEqual(completed.stderr, "app lifecycle operation failed: teardown:quiescence-timeout:rounds=1\n")

    def test_teardown_preserves_preexisting_apps_through_quiet_window(self):
        body = textwrap.dedent(f"""\
            tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
            BATS_FILE_TMPDIR="$tmp"; HELPERS={quote(HOOK_PATH.parent)}
            /usr/bin/python3 "$HELPERS/app_lifecycle.py" write-snapshot --state "$tmp/apple-cli-app-state.json" --running 100000
            APPLE_CLI_BATS_APP_SNAPSHOT_READY=true
            app_lifecycle_observe() {{
              count=0; [ ! -e "$tmp/observes" ] || count=$(<"$tmp/observes")
              count=$((count + 1)); printf '%s' "$count" > "$tmp/observes"
              APPLE_CLI_BATS_APP_RESULT=100000
              APPLE_CLI_BATS_APP_OBSERVED_MAIL=$'ASN:0x0-0x1\t42\ttoken'
            }}
            app_lifecycle_restore_one() {{ printf called > "$tmp/restores"; return 70; }}
            APPLE_CLI_BATS_APP_QUIET_TICKS=1; APPLE_CLI_BATS_APP_SETTLE_TICKS=3
            APPLE_CLI_BATS_APP_POLL_SECONDS=0
            app_lifecycle_teardown_file_impl; status=$?
            printf 'STATUS:%s STATE:%s OBSERVES:%s RESTORES:%s\n' "$status" "$(test -e "$tmp/apple-cli-app-state.json"; printf '%s' $?)" "$(<"$tmp/observes")" "$(test -e "$tmp/restores"; printf '%s' $?)"
        """)
        completed = self.run_shell(body)
        self.assertEqual(completed.stdout, "STATUS:0 STATE:1 OBSERVES:2 RESTORES:1\n")
        self.assertEqual(completed.stderr, "")

    def test_teardown_reopened_processed_key_fails_without_second_restore(self):
        body = textwrap.dedent(f"""\
            tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
            BATS_FILE_TMPDIR="$tmp"; HELPERS={quote(HOOK_PATH.parent)}
            /usr/bin/python3 "$HELPERS/app_lifecycle.py" write-snapshot --state "$tmp/apple-cli-app-state.json" --running 000000
            APPLE_CLI_BATS_APP_SNAPSHOT_READY=true
            app_lifecycle_observe() {{
              count=0; [ ! -e "$tmp/observes" ] || count=$(<"$tmp/observes")
              count=$((count + 1)); printf '%s' "$count" > "$tmp/observes"
              APPLE_CLI_BATS_APP_RESULT=100000
              if [ "$count" -eq 1 ]; then
                APPLE_CLI_BATS_APP_OBSERVED_MAIL=$'ASN:0x0-0x1\t42\tfirst'
              else
                APPLE_CLI_BATS_APP_OBSERVED_MAIL=$'ASN:0x0-0x2\t43\tsecond'
              fi
            }}
            app_lifecycle_restore_one() {{ printf '%s\n' "$2" >> "$tmp/restores"; }}
            APPLE_CLI_BATS_APP_QUIET_TICKS=1; APPLE_CLI_BATS_APP_SETTLE_TICKS=3
            APPLE_CLI_BATS_APP_POLL_SECONDS=0
            app_lifecycle_teardown_file_impl; status=$?
            printf 'STATUS:%s STATE:%s OBSERVES:%s RESTORES:%s\n' "$status" "$(test -e "$tmp/apple-cli-app-state.json"; printf '%s' $?)" "$(<"$tmp/observes")" "$(wc -l < "$tmp/restores" | tr -d ' ')"
            sed -n '1,99p' "$tmp/restores"
        """)
        completed = self.run_shell(body)
        self.assertEqual(
            completed.stdout.splitlines(),
            ["STATUS:1 STATE:0 OBSERVES:2 RESTORES:1", "ASN:0x0-0x1\t42\tfirst"],
        )
        self.assertEqual(completed.stderr, "app lifecycle operation failed: teardown:reappeared:mail:round=1\n")

    def test_restore_validates_observed_identity_without_refinding_replacement(self):
        body = textwrap.dedent(f"""\
            tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
            HELPERS={quote(HOOK_PATH.parent)}
            export FAKE_DIR="$tmp"
            app_lifecycle_lsappinfo_exec() {{
              op="$1"; shift
              printf '%s\n' "$op" >> "$FAKE_DIR/log"
              case "$op" in
                find) printf '%s\n' 'ASN:0x0-0x2-"Mail":' ;;
                info)
                  printf '%s\n' 'LSDisplayName="Mail"' 'pid=43' \
                    'CFBundleIdentifier="com.apple.mail"' 'LSCheckInTime*="new"'
                  ;;
                kill) ;;
                *) return 68 ;;
              esac
            }}
            APPLE_CLI_BATS_APP_GRACE_TICKS=0; APPLE_CLI_BATS_APP_TERM_TICKS=0
            APPLE_CLI_BATS_APP_POLL_SECONDS=0
            observed=$'ASN:0x0-0x1\t42\tfirst'
            app_lifecycle_restore_one mail "$observed" "$tmp/work"; status=$?
            printf 'STATUS:%s\n' "$status"
            sed -n '1,99p' "$tmp/log"
        """)
        completed = self.run_shell(body)
        self.assertEqual(completed.stdout.splitlines(), ["STATUS:1", "info"])
        self.assertEqual(completed.stderr, "")

    def test_real_restore_path_attempts_second_target_after_first_kill_refusal(self):
        mail_token = hashlib.sha256(b'"mail-token"').hexdigest()
        notes_token = hashlib.sha256(b'"notes-token"').hexdigest()
        body = textwrap.dedent(f"""\
            tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
            BATS_FILE_TMPDIR="$tmp"; HELPERS={quote(HOOK_PATH.parent)}
            export FAKE_DIR="$tmp"
            /usr/bin/python3 "$HELPERS/app_lifecycle.py" write-snapshot --state "$tmp/apple-cli-app-state.json" --running 000000
            APPLE_CLI_BATS_APP_SNAPSHOT_READY=true
            app_lifecycle_observe() {{
              APPLE_CLI_BATS_APP_RESULT=110000
              APPLE_CLI_BATS_APP_OBSERVED_MAIL=$'ASN:0x0-0x1\t42\t{mail_token}'
              APPLE_CLI_BATS_APP_OBSERVED_NOTES=$'ASN:0x0-0x2\t43\t{notes_token}'
            }}
            app_lifecycle_lsappinfo_exec() {{
              op="$1"; shift
              case "$op" in
                find)
                  case "$*" in
                    *Mail*|*com.apple.mail*) key=mail; asn=ASN:0x0-0x1; name=Mail ;;
                    *Notes*|*com.apple.Notes*) key=notes; asn=ASN:0x0-0x2; name=Notes ;;
                    *) exit 65 ;;
                  esac
                  printf 'FIND:%s\n' "$key" >> "$FAKE_DIR/log"
                  printf '%s-"%s":\n' "$asn" "$name"
                  ;;
                info)
                  asn="${{@:$#}}"
                  case "$asn" in
                    ASN:0x0-0x1) key=mail; name=Mail; bundle=com.apple.mail; pid=42 ;;
                    ASN:0x0-0x2) key=notes; name=Notes; bundle=com.apple.Notes; pid=43 ;;
                    *) exit 66 ;;
                  esac
                  if [ "$key" = notes ] && [ -e "$FAKE_DIR/notes-killed" ]; then
                    printf '%s\n' 'LSDisplayName=[ NULL ]' 'pid=[ NULL ]' 'CFBundleIdentifier=[ NULL ]' 'LSCheckInTime*=[ NULL ]'
                  else
                    printf 'LSDisplayName="%s"\npid=%s\nCFBundleIdentifier="%s"\nLSCheckInTime*="%s-token"\n' "$name" "$pid" "$bundle" "$key"
                  fi
                  ;;
                kill)
                  hard=false
                  if [ "$1" = -hard ]; then hard=true; shift; fi
                  case "$1" in ASN:0x0-0x1) key=mail ;; ASN:0x0-0x2) key=notes ;; *) exit 67 ;; esac
                  printf '%s:%s\n' "$(if [ "$hard" = true ]; then printf HARD; else printf TERM; fi)" "$key" >> "$FAKE_DIR/log"
                  if [ "$key" = mail ]; then return 1; fi
                  : > "$FAKE_DIR/notes-killed"
                  ;;
                *) exit 68 ;;
              esac
            }}
            APPLE_CLI_BATS_APP_GRACE_TICKS=0; APPLE_CLI_BATS_APP_TERM_TICKS=0
            APPLE_CLI_BATS_APP_POLL_SECONDS=0
            app_lifecycle_teardown_file_impl; status=$?
            printf 'STATUS:%s STATE:%s\n' "$status" "$(test -e "$tmp/apple-cli-app-state.json"; printf '%s' $?)"
            sed -n '/^TERM:/p;/^HARD:/p' "$tmp/log"
        """)
        completed = self.run_shell(body)
        self.assertEqual(
            completed.stdout.splitlines(),
            ["STATUS:1 STATE:0", "TERM:mail", "TERM:notes"],
            completed.stderr,
        )
        self.assertEqual(completed.stderr, "app lifecycle operation failed: teardown:restore-status=1:mail:round=0:\n")

    def test_setup_aggregate_timeout_spans_individually_fast_observations(self):
        body = textwrap.dedent(f"""\
            tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
            BATS_FILE_TMPDIR="$tmp"; HELPERS={quote(HOOK_PATH.parent)}
            app_lifecycle_lsappinfo_exec() {{
              count=0; [ ! -e "$tmp/calls" ] || count=$(wc -l < "$tmp/calls")
              printf '%s\n' call >> "$tmp/calls"
              if [ "$count" -eq 0 ]; then sleep 0.005; else sleep 0.08; fi
              printf '%s\n' success
            }}
            app_lifecycle_observe() {{
              app_lifecycle_run_lsappinfo "$tmp/first" info || return $?
              app_lifecycle_run_lsappinfo "$tmp/second" info || return $?
              APPLE_CLI_BATS_APP_RESULT=000000
            }}
            APPLE_CLI_BATS_APP_POLL_SECONDS=0.005
            APPLE_CLI_BATS_APP_SETUP_TIMEOUT_SECONDS=0.04
            setup_file; status=$?
            printf 'STATUS:%s READY:%s CHILD:%s TIMER:%s STATE:%s CALLS:%s\n' "$status" \
              "$APPLE_CLI_BATS_APP_SNAPSHOT_READY" "$APPLE_CLI_BATS_APP_CHILD_PID" \
              "$APPLE_CLI_BATS_APP_TIMER_PID" "$(test -e "$tmp/apple-cli-app-state.json"; printf '%s' $?)" \
              "$(wc -l < "$tmp/calls" | tr -d ' ')"
        """)
        completed = self.run_shell(body)
        self.assertEqual(
            completed.stdout,
            "STATUS:124 READY:false CHILD: TIMER: STATE:1 CALLS:2\n",
            completed.stderr,
        )
        self.assertEqual(completed.stderr, "app lifecycle operation failed: setup:observe:124:\n")

    def test_teardown_aggregate_timeout_spans_rescan_and_preserves_state(self):
        body = textwrap.dedent(f"""\
            tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
            BATS_FILE_TMPDIR="$tmp"; HELPERS={quote(HOOK_PATH.parent)}
            /usr/bin/python3 "$HELPERS/app_lifecycle.py" write-snapshot --state "$tmp/apple-cli-app-state.json" --running 000000
            APPLE_CLI_BATS_APP_SNAPSHOT_READY=true
            app_lifecycle_observe() {{ sleep 0.03; APPLE_CLI_BATS_APP_RESULT=000000; }}
            APPLE_CLI_BATS_APP_QUIET_TICKS=5
            APPLE_CLI_BATS_APP_SETTLE_TICKS=10
            APPLE_CLI_BATS_APP_POLL_SECONDS=0
            APPLE_CLI_BATS_APP_TEARDOWN_TIMEOUT_SECONDS=0.05
            teardown_file; status=$?
            printf 'STATUS:%s TIMER:%s STATE:%s\n' "$status" "$APPLE_CLI_BATS_APP_TIMER_PID" \
              "$(test -e "$tmp/apple-cli-app-state.json"; printf '%s' $?)"
        """)
        completed = self.run_shell(body)
        self.assertEqual(completed.stdout, "STATUS:124 TIMER: STATE:0\n", completed.stderr)
        self.assertEqual(completed.stderr, "app lifecycle operation failed: teardown:phase-timer:round=0:124\n")

    def test_phase_timer_is_cancelled_and_reaped_after_normal_success(self):
        body = textwrap.dedent(f"""\
            tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
            BATS_FILE_TMPDIR="$tmp"; HELPERS={quote(HOOK_PATH.parent)}
            APPLE_CLI_BATS_PRESERVE_APPS=1
            APPLE_CLI_BATS_APP_SETUP_TIMEOUT_SECONDS=2
            setup_file; status=$?
            jobs -pr > "$tmp/jobs"
            printf 'STATUS:%s TIMER:%s JOBS:%s\n' "$status" "$APPLE_CLI_BATS_APP_TIMER_PID" \
              "$(wc -l < "$tmp/jobs" | tr -d ' ')"
        """)
        completed = self.run_shell(body)
        self.assertEqual(completed.stdout, "STATUS:0 TIMER: JOBS:0\n", completed.stderr)
        self.assertEqual(completed.stderr, "")

    def test_phase_timer_uses_absolute_sleep_not_shell_or_path_shadow(self):
        source = HOOK_PATH.read_text(encoding="utf-8")
        self.assertIn('/bin/sleep "$duration" &', source)
        self.assertNotRegex(source, r"(?m)^[ \t]*sleep(?:[ \t]|$)")
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "shadowed"
            body = textwrap.dedent(f"""\
                BATS_FILE_TMPDIR={quote(directory)}
                sleep() {{ : > {quote(marker)}; return 99; }}
                app_lifecycle_setup_file_impl() {{ return 0; }}
                APPLE_CLI_BATS_APP_SETUP_TIMEOUT_SECONDS=2
                setup_file; status=$?
                printf 'STATUS:%s SHADOW:%s\n' "$status" \
                  "$(test -e {quote(marker)}; printf '%s' $?)"
            """)
            completed = self.run_shell(body)
            self.assertEqual(completed.stdout, "STATUS:0 SHADOW:1\n", completed.stderr)

    def test_polling_ignores_hanging_shell_sleep_shadow(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            body = textwrap.dedent(f"""\
                sleep() {{ : > {quote(root / 'shadowed')}; while :; do :; done; }}
                app_lifecycle_lsappinfo_exec() {{ /bin/sleep 0.03; printf '%s\n' success; }}
                APPLE_CLI_BATS_APP_POLL_SECONDS=0.005
                app_lifecycle_run_lsappinfo {quote(root / 'output')} info
                printf 'STATUS:%s SHADOW:%s\n' "$?" \
                  "$(test -e {quote(root / 'shadowed')}; printf '%s' $?)"
            """)
            completed = self.run_shell(body, timeout=1)
            self.assertEqual(completed.stdout, "STATUS:0 SHADOW:1\n", completed.stderr)

    def test_stopped_ls_child_is_bounded_and_reaped(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            body = textwrap.dedent(f"""\
                app_lifecycle_lsappinfo_exec() {{ exec /bin/sleep 10; }}
                app_lifecycle_after_spawn() {{
                  FAKE_JOB_PID="$APPLE_CLI_BATS_APP_CHILD_PID"
                  FAKE_JOB_STATE=stopped
                }}
                jobs() {{
                  case "$1:$FAKE_JOB_STATE" in
                    -pr:running|-ps:stopped|-p:running|-p:stopped) printf '%s\n' "$FAKE_JOB_PID" ;;
                  esac
                }}
                app_lifecycle_signal_job() {{
                  [ "$2" = "$FAKE_JOB_PID" ] || return 1
                  if [ "$1" = KILL ]; then FAKE_JOB_STATE=done; builtin kill -KILL "$2"; fi
                }}
                APPLE_CLI_BATS_APP_TIMEOUT_TICKS=0
                APPLE_CLI_BATS_APP_TERM_TICKS=0
                app_lifecycle_run_lsappinfo {quote(root / 'output')} info
                status=$?
                jobs -p > {quote(root / 'jobs')}
                printf 'STATUS:%s CHILD:%s JOBS:%s\n' "$status" \
                  "$APPLE_CLI_BATS_APP_CHILD_PID" \
                  "$(wc -l < {quote(root / 'jobs')} | tr -d ' ')"
            """)
            completed = self.run_shell(body, timeout=1)
            self.assertEqual(completed.stdout, "STATUS:124 CHILD: JOBS:0\n", completed.stderr)

    def test_stopped_timer_fails_closed_and_is_bounded_and_reaped(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            body = textwrap.dedent(f"""\
                BATS_FILE_TMPDIR={quote(root)}
                app_lifecycle_setup_file_impl() {{
                  APPLE_CLI_BATS_APP_SNAPSHOT_READY=true
                  FAKE_JOB_STATE=stopped
                }}
                jobs() {{
                  FAKE_JOB_PID="$APPLE_CLI_BATS_APP_TIMER_PID"
                  case "$1:$FAKE_JOB_STATE" in
                    -pr:running|-ps:stopped|-p:running|-p:stopped) printf '%s\n' "$FAKE_JOB_PID" ;;
                  esac
                }}
                app_lifecycle_signal_job() {{
                  [ "$2" = "$APPLE_CLI_BATS_APP_TIMER_PID" ] || return 1
                  if [ "$1" = KILL ]; then FAKE_JOB_STATE=done; builtin kill -KILL "$2"; fi
                }}
                FAKE_JOB_STATE=running
                APPLE_CLI_BATS_APP_TERM_TICKS=0
                APPLE_CLI_BATS_APP_SETUP_TIMEOUT_SECONDS=2
                setup_file; status=$?
                jobs -p > {quote(root / 'jobs')}
                printf 'STATUS:%s READY:%s TIMER:%s JOBS:%s\n' "$status" \
                  "$APPLE_CLI_BATS_APP_SNAPSHOT_READY" "$APPLE_CLI_BATS_APP_TIMER_PID" \
                  "$(wc -l < {quote(root / 'jobs')} | tr -d ' ')"
            """)
            completed = self.run_shell(body, timeout=1)
            self.assertEqual(
                completed.stdout,
                "STATUS:124 READY:false TIMER: JOBS:0\n",
                completed.stderr,
            )
            self.assertEqual(completed.stderr, "app lifecycle operation failed: setup:phase-timer-after:124\n")

    def test_timer_natural_exit_after_final_check_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            body = textwrap.dedent(f"""\
                BATS_FILE_TMPDIR={quote(directory)}
                app_lifecycle_setup_file_impl() {{ APPLE_CLI_BATS_APP_SNAPSHOT_READY=true; return 0; }}
                app_lifecycle_cleanup_child() {{
                  while app_lifecycle_child_is_running_job "$APPLE_CLI_BATS_APP_TIMER_PID" \
                      "$APPLE_CLI_BATS_APP_TIMER_JOB_FILE"; do :; done
                }}
                APPLE_CLI_BATS_APP_SETUP_TIMEOUT_SECONDS=0.01
                setup_file; status=$?
                printf 'STATUS:%s READY:%s TIMER:%s\n' "$status" \
                  "$APPLE_CLI_BATS_APP_SNAPSHOT_READY" "$APPLE_CLI_BATS_APP_TIMER_PID"
            """)
            completed = self.run_shell(body)
            self.assertEqual(completed.stdout, "STATUS:124 READY:false TIMER:\n", completed.stderr)
            self.assertEqual(completed.stderr, "app lifecycle operation failed: cleanup:interrupt:124\n")

    def test_timer_unexpected_exit_after_final_check_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            body = textwrap.dedent(f"""\
                BATS_FILE_TMPDIR={quote(directory)}
                app_lifecycle_setup_file_impl() {{ APPLE_CLI_BATS_APP_SNAPSHOT_READY=true; return 0; }}
                app_lifecycle_cleanup_child() {{
                  app_lifecycle_signal_job KILL "$APPLE_CLI_BATS_APP_TIMER_PID"
                  while app_lifecycle_child_is_running_job "$APPLE_CLI_BATS_APP_TIMER_PID" \
                      "$APPLE_CLI_BATS_APP_TIMER_JOB_FILE"; do :; done
                }}
                APPLE_CLI_BATS_APP_SETUP_TIMEOUT_SECONDS=2
                setup_file; status=$?
                printf 'STATUS:%s READY:%s TIMER:%s\n' "$status" \
                  "$APPLE_CLI_BATS_APP_SNAPSHOT_READY" "$APPLE_CLI_BATS_APP_TIMER_PID"
            """)
            completed = self.run_shell(body)
            self.assertEqual(completed.stdout, "STATUS:124 READY:false TIMER:\n", completed.stderr)
            self.assertEqual(completed.stderr, "app lifecycle operation failed: cleanup:interrupt:124\n")

    def test_phase_timer_and_current_ls_child_are_cleaned_after_cancellation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            body = textwrap.dedent(f"""\
                BATS_FILE_TMPDIR={quote(root)}; HELPERS={quote(HOOK_PATH.parent)}
                app_lifecycle_lsappinfo_exec() {{ while :; do sleep 1; done; }}
                app_lifecycle_after_spawn() {{ kill -TERM $$; }}
                APPLE_CLI_BATS_APP_POLL_SECONDS=0.01
                APPLE_CLI_BATS_APP_TERM_TICKS=1
                APPLE_CLI_BATS_APP_SETUP_TIMEOUT_SECONDS=2
                setup_file; status=$?
                jobs -pr > {quote(root / 'jobs')}
                printf 'STATUS:%s READY:%s CHILD:%s TIMER:%s JOBS:%s\n' "$status" \
                  "$APPLE_CLI_BATS_APP_SNAPSHOT_READY" "$APPLE_CLI_BATS_APP_CHILD_PID" \
                  "$APPLE_CLI_BATS_APP_TIMER_PID" "$(wc -l < {quote(root / 'jobs')} | tr -d ' ')"
            """)
            completed = self.run_shell(body, timeout=5)
            self.assertEqual(
                completed.stdout,
                "STATUS:143 READY:false CHILD: TIMER: JOBS:0\n",
                completed.stderr,
            )
            self.assertEqual(completed.stderr, "app lifecycle operation failed: setup:observe:143:\n")

    def test_setup_and_teardown_restore_atypical_caller_umask_after_success(self):
        for wrapper in ("setup", "teardown"):
            with self.subTest(wrapper=wrapper), tempfile.TemporaryDirectory() as directory:
                implementation = f"app_lifecycle_{wrapper}_file_impl"
                body = textwrap.dedent(f"""\
                    BATS_FILE_TMPDIR={quote(directory)}
                    {implementation}() {{ umask 077; return 0; }}
                    umask 027
                    {wrapper}_file; status=$?
                    printf 'STATUS:%s UMASK:%s\n' "$status" "$(umask)"
                """)
                completed = self.run_shell(body)
                self.assertEqual(completed.stdout, "STATUS:0 UMASK:0027\n", completed.stderr)

    def test_setup_and_teardown_restore_caller_umask_after_error_and_cancellation(self):
        for wrapper in ("setup", "teardown"):
            for mode, expected_status in (("error", 7), ("cancel", 143)):
                with self.subTest(wrapper=wrapper, mode=mode), tempfile.TemporaryDirectory() as directory:
                    implementation = f"app_lifecycle_{wrapper}_file_impl"
                    cancellation = (
                        "APPLE_CLI_BATS_APP_INTERRUPT_STATUS=143; " if mode == "cancel" else ""
                    )
                    body = textwrap.dedent(f"""\
                        BATS_FILE_TMPDIR={quote(directory)}
                        {implementation}() {{ umask 077; {cancellation}return {expected_status}; }}
                        umask 027
                        {wrapper}_file; status=$?
                        printf 'STATUS:%s UMASK:%s\n' "$status" "$(umask)"
                    """)
                    completed = self.run_shell(body)
                    self.assertEqual(
                        completed.stdout,
                        f"STATUS:{expected_status} UMASK:0027\n",
                        completed.stderr,
                    )

    def test_setup_and_teardown_restore_caller_umask_after_timeout(self):
        for wrapper in ("setup", "teardown"):
            with self.subTest(wrapper=wrapper), tempfile.TemporaryDirectory() as directory:
                implementation = f"app_lifecycle_{wrapper}_file_impl"
                timeout_variable = f"APPLE_CLI_BATS_APP_{wrapper.upper()}_TIMEOUT_SECONDS"
                body = textwrap.dedent(f"""\
                    BATS_FILE_TMPDIR={quote(directory)}
                    {implementation}() {{ umask 077; sleep 0.03; return 0; }}
                    {timeout_variable}=0.01
                    umask 027
                    {wrapper}_file; status=$?
                    printf 'STATUS:%s UMASK:%s\n' "$status" "$(umask)"
                """)
                completed = self.run_shell(body)
                self.assertEqual(completed.stdout, "STATUS:124 UMASK:0027\n", completed.stderr)

    def test_setup_restores_caller_umask_without_weakening_private_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "apple-cli-app-state.json"
            body = textwrap.dedent(f"""\
                BATS_FILE_TMPDIR={quote(directory)}; HELPERS={quote(HOOK_PATH.parent)}
                APPLE_CLI_BATS_PRESERVE_APPS=1
                umask 002
                setup_file; status=$?
                printf 'STATUS:%s UMASK:%s\n' "$status" "$(umask)"
            """)
            completed = self.run_shell(body)
            self.assertEqual(completed.stdout, "STATUS:0 UMASK:0002\n", completed.stderr)
            self.assertEqual(stat.S_IMODE(state.stat().st_mode), 0o600)

    def test_teardown_interruption_aborts_remaining_apps_and_preserves_state(self):
        body = textwrap.dedent(f"""\
            tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
            BATS_FILE_TMPDIR="$tmp"; HELPERS={quote(HOOK_PATH.parent)}
            /usr/bin/python3 "$HELPERS/app_lifecycle.py" write-snapshot --state "$tmp/apple-cli-app-state.json" --running 000000
            APPLE_CLI_BATS_APP_SNAPSHOT_READY=true
            app_lifecycle_observe() {{
              APPLE_CLI_BATS_APP_RESULT=110000
              APPLE_CLI_BATS_APP_OBSERVED_MAIL=mail-identity
              APPLE_CLI_BATS_APP_OBSERVED_NOTES=notes-identity
            }}
            app_lifecycle_restore_one() {{
              printf '%s\n' "$1" >> "$tmp/calls"
              APPLE_CLI_BATS_APP_INTERRUPT_STATUS=143
              return 143
            }}
            app_lifecycle_teardown_file_impl; status=$?
            printf 'STATUS:%s STATE:%s\n' "$status" "$(test -e "$tmp/apple-cli-app-state.json"; printf '%s' $?)"
            sed -n '1,99p' "$tmp/calls"
        """)
        completed = self.run_shell(body)
        self.assertEqual(completed.stdout.splitlines(), ["STATUS:143 STATE:0", "mail"])
        self.assertEqual(completed.stderr, "app lifecycle operation failed: teardown:interrupt:mail:143\n")


if __name__ == "__main__":
    unittest.main()
