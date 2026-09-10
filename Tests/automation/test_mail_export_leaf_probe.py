import contextlib
import importlib.util
import io
import json
from pathlib import Path
import signal
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parents[2]
PROBE_PATH = REPO_ROOT / "bats" / "helpers" / "mail_export_leaf_probe.py"


def load_probe():
    spec = importlib.util.spec_from_file_location("mail_export_leaf_probe", PROBE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MailExportLeafProbeTests(unittest.TestCase):
    def test_positive_control_reaps_real_harmless_children_and_removes_captures(self):
        probe = load_probe()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            code, output = probe.run_child(root, [], False, [])
            self.assertEqual(code, 0)
            self.assertEqual(output, b"")
            self.assertEqual(list(root.iterdir()), [])

    def test_missing_restriction_refuses_before_executing_synthetic_target(self):
        probe = load_probe()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "must-not-exist"
            target = [sys.executable, "-I", "-c",
                      "from pathlib import Path; Path(" + repr(str(marker)) + ").write_text('synthetic')"]
            # Deliberately omit the kernel restriction. The real child canary must
            # detect successful fork/spawn and refuse before execing this target.
            with patch.object(probe, "SANDBOX_PREFIX", ()):
                with self.assertRaises((probe.ProbeFailure, FileNotFoundError)):
                    probe.run_child(root, target, True, [])
            self.assertFalse(marker.exists())
            self.assertEqual(list(root.iterdir()), [])

    def test_each_invocation_requires_a_valid_denial_receipt_without_retry(self):
        probe = load_probe()
        envelope = {"schema_version": 1, "tool": "mail", "ok": False,
                    "error": {"type": "safety_violation", "message": "synthetic symlink"}}
        for receipt_bytes, accepted in (
            (None, False), (b"not-json", False),
            (json.dumps(probe.CREATED).encode(), False),
            (json.dumps(probe.DENIED).encode(), True),
        ):
            with self.subTest(receipt=receipt_bytes), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                calls = []

                def supervised(arguments):
                    calls.append(arguments)
                    self.assertEqual(arguments[:6], ["--timeout", "30", "--grace", "2", "--", "/usr/bin/sandbox-exec"])
                    self.assertIn(probe.PROFILE, arguments)
                    start = arguments.index("--child-restricted")
                    Path(arguments[start + 1]).write_text(json.dumps(envelope))
                    if receipt_bytes is not None:
                        Path(arguments[start + 3]).write_bytes(receipt_bytes)
                    return 77

                with patch.object(probe, "bounded_module", return_value=SimpleNamespace(run=supervised)):
                    if accepted:
                        self.assertEqual(probe.invoke(root, "/synthetic/apple", ["export", "--dry-run"], []),
                                         (77, envelope))
                    else:
                        with self.assertRaises((probe.ProbeFailure, FileNotFoundError, ValueError)):
                            probe.invoke(root, "/synthetic/apple", ["export", "--dry-run"], [])
                self.assertEqual(len(calls), 1)
                self.assertEqual(list(root.iterdir()), [])

    def test_supervisor_failures_and_cancellation_suppress_output_and_remove_captures(self):
        probe = load_probe()
        for code in (124, 125, 128 + signal.SIGTERM):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                stdout, stderr = io.StringIO(), io.StringIO()
                cancellation = []

                def supervised(_arguments):
                    sys.stdout.buffer.write(b"synthetic-private-stdout")
                    print("synthetic-private-stderr", file=sys.stderr)
                    return code

                with patch.object(probe, "bounded_module", return_value=SimpleNamespace(run=supervised)):
                    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                        expected = probe.ProbeCancelled if code == 128 + signal.SIGTERM else probe.ProbeFailure
                        with self.assertRaises(expected) as caught:
                            probe.run_child(root, ["/synthetic/apple"], True, cancellation)
                if code == 128 + signal.SIGTERM:
                    self.assertEqual(caught.exception.status, code)
                    self.assertEqual(cancellation, [signal.SIGTERM])
                self.assertEqual(stdout.getvalue(), "")
                self.assertEqual(stderr.getvalue(), "")
                self.assertEqual(list(root.iterdir()), [])

    def test_only_successful_empty_search_skips_and_outer_private_root_is_removed(self):
        probe = load_probe()
        for response, expected in (
            ((0, {"ok": True, "data": {"messages": []}}), 3),
            ((65, {"ok": False, "error": {"message": "synthetic-private-marker"}}), 1),
            ((0, {"ok": True, "data": {"messages": "malformed"}}), 1),
        ):
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                stdout, stderr = io.StringIO(), io.StringIO()
                with patch.object(probe.Path, "home", return_value=root):
                    with patch.object(probe, "run_child", return_value=(0, b"")):
                        with patch.object(probe, "invoke", return_value=response):
                            with patch.object(probe.sys, "argv", ["probe", "/synthetic/apple"]):
                                with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                                    self.assertEqual(probe.main(), expected)
                self.assertEqual(stdout.getvalue(), "")
                self.assertEqual(stderr.getvalue(), "" if expected == 3 else probe.FAILURE + "\n")
                self.assertEqual(list(root.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
