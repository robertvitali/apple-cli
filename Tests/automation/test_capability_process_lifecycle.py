"""Parent lifecycle acceptance with explicit synthetic qualification and workers.

No compiler, subprocess, signal or native library is executed. The fake worker
writes fixed captures and a real pipe; production parsing, file validation and
parent lifecycle remain the subject. These tests do not qualify a distribution.
"""

from __future__ import annotations

from contextlib import ExitStack
from dataclasses import replace
import hashlib
import importlib
import errno
import os
from pathlib import Path
import sys
import tempfile
from types import MappingProxyType, SimpleNamespace
import unittest
from unittest import mock


CI = Path(__file__).resolve().parents[2] / "scripts" / "ci"
if str(CI) not in sys.path:
    sys.path.insert(0, str(CI))
core = importlib.import_module("capability_process")
protocol = importlib.import_module("capability_process_protocol")


class Clock:
    def __init__(self, now=12.0):
        self.now = now

    def __call__(self):
        return self.now


def identity(path):
    data = path.read_bytes()
    info = path.stat()
    return protocol.ExecutableIdentity(
        str(path), hashlib.sha256(data).hexdigest(), info.st_dev, info.st_ino,
        info.st_size, info.st_mode, info.st_uid, info.st_gid,
        info.st_mtime_ns, info.st_ctime_ns)


class LifecycleFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="capability-process-unit-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.clock = Clock()
        self.events = []
        self.executable = self.root / "synthetic-tool"
        self.executable.write_bytes(b"synthetic non-executable test payload\n")
        self.executable.chmod(0o700)
        self.selected = identity(self.executable)
        self.profile = SimpleNamespace(executables=MappingProxyType({
            role: self.selected for role in
            ("git", "swift-test", "swift-build", "swift-bin-path")}))
        self.package = SimpleNamespace(root=self.root, sha256="1" * 64)
        self.runtime = SimpleNamespace()
        self.artifact = self.root / "synthetic-native"
        self.artifact.write_bytes(b"synthetic artifact, never loaded\n")
        self.native = SimpleNamespace(
            artifact=identity(self.artifact),
            observe_child=lambda pid: (0, 0, 0, 0),
            check_state=lambda: None)
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.popen = self.stack.enter_context(mock.patch.object(
            core.subprocess, "Popen", side_effect=AssertionError("unexpected process")))
        self.signal = self.stack.enter_context(mock.patch.object(
            core.os, "killpg", side_effect=lambda *args: self.events.append("signal")))
        self.stack.enter_context(mock.patch.object(
            core.os, "kill", side_effect=AssertionError("unexpected PID signal")))
        self.stack.enter_context(mock.patch.object(core.signal, "signal"))

    def succeed(self, operation):
        try:
            return operation()
        except core.ProcessFailure as failure:
            self.fail("expected accepted lifecycle, got " + failure.reason)

    def context(self):
        budget = core._PreparationBudget(self.clock, 10.0, 68.0)
        return core.TrustedRunnerRoot(self.root, "1" * 64, budget)

    def ready_session(self):
        """Explicitly replace preparation, never production admission policy."""
        value = object.__new__(core.QualifiedProcessSession)
        value._clock = self.clock
        value._state = "ready"
        value._prepared = True
        value._failed = False
        value._cancelled = False
        value._close_attempted = False
        value._close_completed = False
        value._close_failure = None
        value._decision_slot = {}
        value._cancellation_decision = None
        value._active_anchor = None
        value._signal_handlers = None
        value._directory = self.root / "session"
        value._directory.mkdir(mode=0o700)
        value._package = self.package
        value._profile = self.profile
        value._runtime = self.runtime
        value._native = self.native
        value._profile_id = "synthetic-profile"
        value._session_id = "2" * 32
        value._command_id = 0
        value._help_executables = {}
        self.stack.enter_context(mock.patch.object(
            core, "_revalidate_session", create=True,
            side_effect=lambda *args, **kwargs: self.events.append("revalidate")))
        return value

    def request(self, **changes):
        values = dict(role="git", executable=self.selected,
                      argv=(self.selected.path, "rev-parse", "HEAD"),
                      cwd=self.root, environment=protocol._GIT_ENV,
                      deadline=20.0, maximum_output_bytes=32)
        values.update(changes)
        return protocol.CommandRequest(**values)

    def worker(self, *, outcome="success", status=0, stdout=b"fixed\n", stderr=b"",
               transform=None, after_wait=None, delayed_tail=None):
        observed = []
        held_writers = []

        def spawn(session, request, context, directory):
            self.events.append("spawn")
            self.assertEqual(session.state, "command-active")
            self.assertEqual(request, self.current_request)
            self.assertEqual(context.command_id, len(observed) + 1)
            self.assertEqual(context.session_id, session._session_id)
            self.assertEqual(context.native_artifact_sha256, self.native.artifact.sha256)
            directory = Path(directory)
            self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
            for name, data in (("stdout.bin", stdout), ("stderr.bin", stderr)):
                descriptor = os.open(directory / name, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                try:
                    self.assertEqual(os.write(descriptor, data), len(data))
                finally:
                    os.close(descriptor)
            receipt = protocol.CommandReceipt(
                outcome, status, len(stdout), len(stderr),
                hashlib.sha256(stdout).hexdigest(), hashlib.sha256(stderr).hexdigest())
            raw = protocol.encode_receipt(receipt, request=request, context=context)
            if transform:
                raw = transform(raw)
            reader, writer = os.pipe()
            try:
                self.assertEqual(os.write(writer, raw), len(raw))
            except BaseException:
                os.close(reader)
                os.close(writer)
                raise
            if delayed_tail is None:
                os.close(writer)
            else:
                writer_info = os.fstat(writer)
                held_writers.append((writer, (writer_info.st_dev, writer_info.st_ino,
                                              writer_info.st_mode)))
            # Retain only this synthetic FD for fixture fallback cleanup. The
            # success assertion checks parent closure before any new FD opens.
            pipe_info = os.fstat(reader)
            observed.append((context, directory, reader,
                             (pipe_info.st_dev, pipe_info.st_ino, pipe_info.st_mode)))
            anchor = mock.Mock(pid=4242, returncode=None)

            def wait(**kwargs):
                self.events.append("wait")
                anchor.returncode = -9
                if delayed_tail is not None:
                    self.assertEqual(os.write(writer, delayed_tail), len(delayed_tail))
                    os.close(writer)
                if after_wait:
                    after_wait(directory)
                return -9

            anchor.wait.side_effect = wait
            return SimpleNamespace(anchor=anchor, receipt_fd=reader)

        self.stack.enter_context(mock.patch.object(core, "_spawn_worker", create=True,
                                                   side_effect=spawn))

        def cleanup():
            descriptors = [(entry[2], entry[3]) for entry in observed] + held_writers
            for descriptor, expected in descriptors:
                try:
                    actual = os.fstat(descriptor)
                    if (actual.st_dev, actual.st_ino, actual.st_mode) == expected:
                        os.close(descriptor)
                except OSError:
                    pass

        self.addCleanup(cleanup)
        return observed


class PreparationLifecycleTests(LifecycleFixture):
    def effects(self, *, failed=None, late=None):
        outputs = {"_verify_package": self.package, "_select_profile": self.profile,
                   "_qualify_runtime": self.runtime, "_build_projection": object(),
                   "_bootstrap_native": self.native}
        calls = {}
        for name, result in outputs.items():
            def effect(*args, _name=name, _result=result, **kwargs):
                self.events.append(_name)
                self.assertEqual(kwargs["deadline"], 68.0)
                if _name == failed:
                    raise core.ProcessFailure("process-unavailable")
                if _name == late:
                    self.clock.now = 70.001
                return _result

            calls[name] = self.stack.enter_context(mock.patch.object(
                core, name, create=True, side_effect=effect))
        return calls

    def test_prepare_consumes_original_budget_before_effects_and_builds_once(self):
        calls = self.effects()
        root = self.context()
        value = self.succeed(lambda: core.QualifiedProcessSession.prepare(root, "synthetic-profile"))
        self.assertTrue(root.budget._consumed)
        self.assertEqual(self.events, list(calls))
        self.assertEqual(value.state, "ready")
        self.assertIs(core.require_process_session(value), value)
        self.assertIs(value.selected_executable("git"), self.selected)
        with self.assertRaises(core.ProcessFailure):
            core.QualifiedProcessSession.prepare(root, "synthetic-profile")
        calls["_bootstrap_native"].assert_called_once()
        self.popen.assert_not_called()
        value.close()

    def test_failed_qualification_never_reaches_bootstrap_or_reuses_token(self):
        calls = self.effects(failed="_qualify_runtime")
        root = self.context()
        with self.assertRaises(core.ProcessFailure):
            core.QualifiedProcessSession.prepare(root, "synthetic-profile")
        self.assertTrue(root.budget._consumed)
        self.assertEqual(self.events, ["_verify_package", "_select_profile", "_qualify_runtime"])
        calls["_build_projection"].assert_not_called()
        calls["_bootstrap_native"].assert_not_called()
        with self.assertRaises(core.ProcessFailure):
            core.QualifiedProcessSession.prepare(root, "synthetic-profile")
        calls["_verify_package"].assert_called_once()
        self.popen.assert_not_called()

    def test_late_projection_cannot_reach_compiler_with_reset_budget(self):
        calls = self.effects(late="_build_projection")
        root = self.context()
        with self.assertRaises(core.ProcessFailure):
            core.QualifiedProcessSession.prepare(root, "synthetic-profile")
        calls["_build_projection"].assert_called_once()
        calls["_bootstrap_native"].assert_not_called()
        self.assertTrue(root.budget._consumed)


class CommandLifecycleTests(LifecycleFixture):
    def test_selected_executable_is_an_in_memory_lookup(self):
        value = self.ready_session()
        with mock.patch.object(core.os, "open", side_effect=AssertionError("unexpected open")):
            with mock.patch.object(core.os, "stat", side_effect=AssertionError("unexpected stat")):
                with mock.patch.object(core.os, "lstat", side_effect=AssertionError("unexpected lstat")):
                    value._clock = mock.Mock(side_effect=AssertionError("unexpected clock"))
                    self.assertIs(self.succeed(lambda: value.selected_executable("git")), self.selected)
        self.assertEqual(self.events, [])
        self.popen.assert_not_called()

    def test_success_accepts_bytes_only_after_cleanup_and_closes_receipt(self):
        value = self.ready_session()
        self.current_request = self.request()
        observed = self.worker(stderr=b"fixed diagnostic\n")
        result = self.succeed(lambda: value.run(self.current_request))
        self.assertEqual(result, protocol.CommandResult(b"fixed\n", b"fixed diagnostic\n", 0, True))
        self.assertEqual(value.state, "ready")
        self.assertEqual(self.events, ["revalidate", "spawn", "signal", "wait", "revalidate"])
        self.assertEqual(len(observed), 1)
        with self.assertRaises(OSError) as closed:
            os.fstat(observed[0][2])
        self.assertEqual(closed.exception.errno, errno.EBADF)
        self.assertFalse(observed[0][1].exists())
        self.popen.assert_not_called()

    def test_complete_nonzero_preserves_status_and_allows_next_command(self):
        value = self.ready_session()
        self.current_request = self.request()
        observed = self.worker(outcome="command-failed", status=7, stderr=b"private-marker\n")
        for command_id in (1, 2):
            with self.assertRaises(core.ProcessFailure) as raised:
                value.run(self.current_request)
            self.assertEqual(raised.exception.reason, "command-failed")
            self.assertEqual(raised.exception.command_status, 7)
            self.assertEqual(raised.exception.cleanup_disposition, "complete")
            self.assertEqual(raised.exception.session_disposition, "ready")
            self.assertNotIn("private-marker", str(raised.exception))
            self.assertEqual(value.state, "ready")
            self.assertEqual(len(observed), command_id)

    def test_partial_receipt_poison_prevents_second_worker(self):
        value = self.ready_session()
        self.current_request = self.request()
        observed = self.worker(transform=lambda raw: raw[:-2])
        with self.assertRaises(core.ProcessFailure) as raised:
            value.run(self.current_request)
        self.assertEqual(raised.exception.reason, "protocol-invalid")
        self.assertEqual(value.state, "poisoned")
        self.assertEqual(len(observed), 1)
        self.assertLess(self.events.index("signal"), self.events.index("wait"))
        with self.assertRaises(core.ProcessFailure):
            value.run(self.current_request)
        self.assertEqual(len(observed), 1)

    def test_extra_receipt_frame_refuses_after_owned_cleanup(self):
        value = self.ready_session()
        self.current_request = self.request()
        observed = self.worker(transform=lambda raw: raw + raw)
        with self.assertRaises(core.ProcessFailure) as raised:
            value.run(self.current_request)
        self.assertEqual(raised.exception.reason, "protocol-invalid")
        self.assertEqual(value.state, "poisoned")
        self.assertEqual(len(observed), 1)
        self.assertEqual(self.events.count("signal"), 1)
        self.assertEqual(self.events.count("wait"), 1)

    def test_short_receipt_reads_and_eagain_preserve_complete_frame(self):
        value = self.ready_session()
        self.current_request = self.request()
        observed = self.worker()
        original_read = os.read
        attempts = []

        def read(descriptor, maximum):
            if observed and descriptor == observed[0][2]:
                attempts.append(maximum)
                if len(attempts) == 1:
                    raise BlockingIOError(errno.EAGAIN, "synthetic retry")
                if len(attempts) == 2:
                    raise InterruptedError(errno.EINTR, "synthetic retry")
                return original_read(descriptor, min(maximum, 2))
            return original_read(descriptor, maximum)

        with mock.patch.object(core.os, "read", side_effect=read):
            result = self.succeed(lambda: value.run(self.current_request))
        self.assertEqual(result.stdout, b"fixed\n")
        self.assertGreater(len(attempts), 3)
        self.assertEqual(value.state, "ready")

    def test_tail_written_after_complete_frame_is_rejected_after_cleanup(self):
        value = self.ready_session()
        self.current_request = self.request()
        observed = self.worker(delayed_tail=b"x")
        with self.assertRaises(core.ProcessFailure) as raised:
            value.run(self.current_request)
        self.assertEqual(raised.exception.reason, "protocol-invalid")
        self.assertEqual(value.state, "poisoned")
        self.assertEqual(len(observed), 1)
        self.assertEqual(self.events.count("wait"), 1)

    def test_reported_overflow_fails_candidate_but_complete_cleanup_allows_final_git(self):
        value = self.ready_session()
        self.current_request = self.request()
        observed = self.worker(outcome="output-limit", status=None, stdout=b"A" * 32)
        with self.assertRaises(core.ProcessFailure) as raised:
            value.run(self.current_request)
        self.assertEqual(raised.exception.reason, "output-limit")
        self.assertEqual(raised.exception.cleanup_disposition, "complete")
        self.assertEqual(raised.exception.session_disposition, "ready")
        self.assertTrue(value.can_validate_final_checkout)
        self.assertEqual(len(observed), 1)

    def test_capture_changed_during_cleanup_is_not_returned(self):
        value = self.ready_session()
        self.current_request = self.request()
        observed = self.worker(after_wait=lambda directory: (directory / "stdout.bin").write_bytes(b"other\n"))
        with self.assertRaises(core.ProcessFailure):
            value.run(self.current_request)
        self.assertEqual(value.state, "poisoned")
        self.assertEqual(len(observed), 1)
        self.assertEqual(self.events.count("wait"), 1)

    def test_replaced_command_directory_refuses_and_preserves_replacement_files(self):
        value = self.ready_session()
        self.current_request = self.request()
        replacement = []

        def substitute(directory):
            directory.rename(self.root / "original-command")
            directory.mkdir(mode=0o700)
            for name, data in (("stdout.bin", b"fixed\n"), ("stderr.bin", b"")):
                path = directory / name
                path.write_bytes(data)
                path.chmod(0o600)
                replacement.append((path, data))

        observed = self.worker(after_wait=substitute)
        failure = None
        try:
            value.run(self.current_request)
        except core.ProcessFailure as caught:
            failure = caught
        with self.subTest(contract="replacement cannot produce success"):
            self.assertIsNotNone(failure)
            self.assertEqual(value.state, "poisoned")
        self.assertEqual(len(observed), 1)
        for path, expected in replacement:
            with self.subTest(contract="replacement file preserved", leaf=path.name):
                self.assertTrue(path.is_file())
                self.assertEqual(path.read_bytes(), expected)

    def test_capture_open_is_nonblocking_before_a_fifo_race_can_be_touched(self):
        value = self.ready_session()
        self.current_request = self.request()
        observed = self.worker()
        original_open = os.open
        flags_seen = []

        def open_leaf(path, flags, *args, **kwargs):
            if str(path) == "stdout.bin" and flags & os.O_ACCMODE == os.O_RDONLY:
                flags_seen.append(flags)
                # Never perform a potentially blocking FIFO open in the RED
                # version. Only the presence of O_NONBLOCK admits this fixture.
                if not flags & os.O_NONBLOCK:
                    raise core.ProcessFailure("identity-drift")
                parent = kwargs["dir_fd"]
                os.unlink("stdout.bin", dir_fd=parent)
                os.mkfifo("stdout.bin", mode=0o600, dir_fd=parent)
            return original_open(path, flags, *args, **kwargs)

        with mock.patch.object(core.os, "open", side_effect=open_leaf):
            with self.assertRaises(core.ProcessFailure):
                value.run(self.current_request)
        self.assertEqual(len(observed), 1)
        self.assertEqual(len(flags_seen), 1)
        self.assertTrue(flags_seen[0] & os.O_NONBLOCK)
        self.assertEqual(value.state, "poisoned")

    def test_capture_read_failure_withholds_output_and_closes_opened_leaf(self):
        value = self.ready_session()
        self.current_request = self.request()
        observed = self.worker()
        original_open, original_read = os.open, os.read
        leaves = []
        read_failures = []

        def open_leaf(path, flags, *args, **kwargs):
            descriptor = original_open(path, flags, *args, **kwargs)
            if str(path) == "stdout.bin" and flags & os.O_ACCMODE == os.O_RDONLY:
                leaves.append(descriptor)
            return descriptor

        def read(descriptor, maximum):
            if leaves and descriptor == leaves[0]:
                read_failures.append(descriptor)
                raise OSError(errno.EIO, "synthetic private read marker")
            return original_read(descriptor, maximum)

        with mock.patch.object(core.os, "open", side_effect=open_leaf):
            with mock.patch.object(core.os, "read", side_effect=read):
                with self.assertRaises(core.ProcessFailure) as raised:
                    value.run(self.current_request)
        self.assertEqual(len(observed), 1)
        self.assertEqual(len(read_failures), 1)
        self.assertNotIn("synthetic private read marker", str(raised.exception))
        self.assertEqual(value.state, "poisoned")
        with self.assertRaises(OSError) as closed:
            os.fstat(leaves[0])
        self.assertEqual(closed.exception.errno, errno.EBADF)

    def test_uncertain_capture_close_poison_has_no_retry(self):
        value = self.ready_session()
        self.current_request = self.request()
        self.worker()
        original_open, original_close = os.open, os.close
        leaves = []
        attempts = []

        def open_leaf(path, flags, *args, **kwargs):
            descriptor = original_open(path, flags, *args, **kwargs)
            if str(path) == "stdout.bin" and flags & os.O_ACCMODE == os.O_RDONLY:
                leaves.append(descriptor)
            return descriptor

        def close(descriptor):
            if leaves and descriptor == leaves[0]:
                attempts.append(descriptor)
                original_close(descriptor)
                raise OSError(errno.EIO, "synthetic uncertain close")
            return original_close(descriptor)

        with mock.patch.object(core.os, "open", side_effect=open_leaf):
            with mock.patch.object(core.os, "close", side_effect=close):
                with self.assertRaises(core.ProcessFailure) as raised:
                    value.run(self.current_request)
        self.assertEqual(len(attempts), 1)
        self.assertEqual(raised.exception.reason, "cleanup-failed")
        self.assertEqual(value.state, "poisoned")

    def test_directory_cleanup_failure_withholds_success(self):
        value = self.ready_session()
        self.current_request = self.request()
        observed = self.worker()
        with mock.patch.object(core, "_remove_command_directory",
                               side_effect=OSError(errno.EIO, "synthetic cleanup")) as removal:
            with self.assertRaises(core.ProcessFailure) as raised:
                value.run(self.current_request)
        removal.assert_called_once()
        self.assertEqual(len(observed), 1)
        self.assertEqual(raised.exception.reason, "cleanup-failed")
        self.assertEqual(raised.exception.cleanup_disposition, "failed")
        self.assertEqual(value.state, "poisoned")

    def test_symlink_capture_with_matching_bytes_is_refused(self):
        value = self.ready_session()
        self.current_request = self.request()
        target = self.root / "synthetic-capture-target"
        target.write_bytes(b"fixed\n")
        target.chmod(0o600)

        def substitute(directory):
            capture = directory / "stdout.bin"
            capture.unlink()
            capture.symlink_to(target)

        observed = self.worker(after_wait=substitute)
        with self.assertRaises(core.ProcessFailure):
            value.run(self.current_request)
        self.assertEqual(value.state, "poisoned")
        self.assertEqual(len(observed), 1)
        self.assertEqual(target.read_bytes(), b"fixed\n")

    def test_nonprivate_capture_mode_is_refused(self):
        value = self.ready_session()
        self.current_request = self.request()
        observed = self.worker(after_wait=lambda directory: (directory / "stdout.bin").chmod(0o644))
        with self.assertRaises(core.ProcessFailure):
            value.run(self.current_request)
        self.assertEqual(value.state, "poisoned")
        self.assertEqual(len(observed), 1)

    def test_late_post_cleanup_validation_cannot_publish_success(self):
        value = self.ready_session()
        self.current_request = self.request()
        observed = self.worker()
        checks = []

        def revalidate(*args, **kwargs):
            checks.append("check")
            if len(checks) == 2:
                self.clock.now = self.current_request.deadline + 2.001

        with mock.patch.object(core, "_revalidate_session", create=True, side_effect=revalidate):
            with self.assertRaises(core.ProcessFailure) as raised:
                value.run(self.current_request)
        self.assertEqual(raised.exception.reason, "deadline")
        self.assertEqual(value.state, "poisoned")
        self.assertEqual(checks, ["check", "check"])
        self.assertEqual(len(observed), 1)

    def test_cancellation_after_worker_assignment_still_cleans_owned_anchor(self):
        value = self.ready_session()
        self.current_request = self.request()
        observed = self.worker(transform=lambda raw: (value._latch_cancellation(2, None), raw)[1])
        with self.assertRaises(core.ProcessFailure) as raised:
            value.run(self.current_request)
        self.assertEqual(raised.exception.reason, "cancelled")
        self.assertEqual(value.state, "poisoned")
        self.assertEqual(len(observed), 1)
        self.assertLess(self.events.index("signal"), self.events.index("wait"))
        self.assertFalse(value.can_validate_final_checkout)

    def test_wrong_selected_identity_refuses_before_worker(self):
        value = self.ready_session()
        self.current_request = self.request(executable=replace(self.selected, sha256="3" * 64))
        observed = self.worker()
        with self.assertRaises(core.ProcessFailure):
            value.run(self.current_request)
        self.assertEqual(observed, [])
        self.assertNotIn("spawn", self.events)

    def test_expired_request_refuses_before_worker(self):
        value = self.ready_session()
        self.current_request = self.request(deadline=self.clock.now)
        observed = self.worker()
        with self.assertRaises(core.ProcessFailure) as raised:
            value.run(self.current_request)
        self.assertEqual(raised.exception.reason, "deadline")
        self.assertEqual(value.state, "poisoned")
        self.assertEqual(observed, [])


if __name__ == "__main__":
    unittest.main()
