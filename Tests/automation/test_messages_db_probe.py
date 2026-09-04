import errno
import importlib.util
import io
import os
from pathlib import Path
from types import ModuleType, SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch
from contextlib import redirect_stderr, redirect_stdout


REPO_ROOT = Path(__file__).resolve().parents[2]
PROBE_PATH = REPO_ROOT / "bats" / "helpers" / "messages_db_probe.py"


def load_probe() -> ModuleType:
    spec = importlib.util.spec_from_file_location("messages_db_probe", PROBE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load Messages database probe")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MessagesDatabaseProbeTests(unittest.TestCase):
    def test_home_override_does_not_change_account_database_target(self) -> None:
        probe = load_probe()
        real_read = os.read
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            account_home = root / "account"
            mutable_home = root / "mutable-home"
            database = account_home / "Library" / "Messages" / "chat.db"
            database.parent.mkdir(parents=True)
            database.write_bytes(b"x")
            mutable_home.mkdir()
            stdout = io.StringIO()
            stderr = io.StringIO()

            with (
                patch.dict(os.environ, {"HOME": str(mutable_home)}),
                patch.object(probe.os, "getuid", return_value=501),
                patch.object(
                    probe.pwd,
                    "getpwuid",
                    return_value=SimpleNamespace(pw_dir=str(account_home)),
                ) as getpwuid,
                patch.object(probe.os, "read", wraps=real_read) as read,
                redirect_stdout(stdout),
                redirect_stderr(stderr),
            ):
                status = probe.main()

        self.assertEqual(status, 0)
        getpwuid.assert_called_once_with(501)
        read.assert_called_once()
        self.assertEqual(read.call_args.args[1], 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(stderr.getvalue(), "")

    def test_expected_unavailability_and_unexpected_errors_are_distinct(self) -> None:
        probe = load_probe()
        for error_number, expected in (
            (errno.ENOENT, 77),
            (errno.EACCES, 77),
            (errno.EPERM, 77),
            (errno.EIO, 1),
        ):
            with self.subTest(error_number=error_number):
                stdout = io.StringIO()
                stderr = io.StringIO()
                with (
                    patch.object(
                        probe.pwd,
                        "getpwuid",
                        return_value=SimpleNamespace(pw_dir="/unused"),
                    ),
                    patch.object(
                        probe.os,
                        "open",
                        side_effect=OSError(error_number, "probe failed"),
                    ),
                    redirect_stdout(stdout),
                    redirect_stderr(stderr),
                ):
                    status = probe.main()

                self.assertEqual(status, expected)
                self.assertEqual(stdout.getvalue(), "")
                self.assertEqual(stderr.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
