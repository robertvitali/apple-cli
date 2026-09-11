"""Retained transport contracts with explicit no-spawn/no-signal effect seams.

Private files and pipes are real. Process, readiness, wait and signal observations
are synthetic; these tests do not qualify a runtime, profile or native artifact.
"""

from __future__ import annotations

import hashlib
import errno
import os
import signal
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from test_capability_process_lifecycle import LifecycleFixture, core, protocol


class ImmediateSelector:
    """Finite readiness script; never waits on the operating system."""
    def __init__(self, before_select=None):
        self.keys = {}
        self.calls = 0
        self.before_select = before_select

    def register(self, fileobj, events, data=None):
        fd = fileobj if type(fileobj) is int else fileobj.fileno()
        key = SimpleNamespace(fileobj=fileobj, fd=fd, events=events, data=data)
        self.keys[fd] = key
        return key

    def unregister(self, fileobj):
        fd = fileobj if type(fileobj) is int else fileobj.fileno()
        return self.keys.pop(fd)

    def get_map(self):
        return self.keys

    def select(self, timeout=None):
        self.calls += 1
        if self.calls > 32:
            raise AssertionError("unbounded synthetic selector loop")
        if self.before_select:
            self.before_select()
        return [(key, key.events) for key in list(self.keys.values())]

    def close(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


class TransportFixture(LifecycleFixture):
    def api(self, name):
        value = getattr(core, name, None)
        self.assertTrue(callable(value), "missing shared transport API: " + name)
        return value

    def checkpoint(self):
        if self.clock.now >= 20.0:
            raise core.ProcessFailure("deadline")
        return 20.0 - self.clock.now

    def directory(self):
        value = self.root / "command"
        value.mkdir(mode=0o700)
        return value

    def fixed_command(self, maximum=16):
        return self.api("_FixedCommand")(
            executable=self.selected, argv=(self.selected.path, "synthetic-argument"),
            cwd=self.root, environment=protocol._GIT_ENV,
            deadline=20.0, maximum_output_bytes=maximum)

    def launch(self):
        return self.api("_WorkerLaunch")(
            executable=self.selected,
            argv=(self.selected.path, "-I", "-S", "-B", "synthetic-fixed-worker-entry"),
            cwd=self.root, environment=(("LC_ALL", "C"),))

    def pipe(self, payload=b"", *, hold_writer=False):
        read_fd, write_fd = os.pipe()
        if payload:
            self.assertEqual(os.write(write_fd, payload), len(payload))
        if not hold_writer:
            os.close(write_fd)
        # Fallback cleanup verifies identities so a consumed number cannot close
        # a subsequently reused descriptor in a failing implementation.
        for descriptor in (read_fd, write_fd) if hold_writer else (read_fd,):
            info = os.fstat(descriptor)
            def close_owned(fd=descriptor, expected=(info.st_dev, info.st_ino, info.st_mode)):
                try:
                    actual = os.fstat(fd)
                    if (actual.st_dev, actual.st_ino, actual.st_mode) == expected:
                        os.close(fd)
                except OSError:
                    pass
            self.addCleanup(close_owned)
        return read_fd, write_fd

    def child(self, stdout=b"out", stderr=b"err", status=0, *, hold_stdout=False):
        out_fd, _ = self.pipe(stdout, hold_writer=hold_stdout)
        err_fd, _ = self.pipe(stderr)
        child = mock.Mock()
        child.pid = 424242
        child.returncode = None
        child.stdout = os.fdopen(out_fd, "rb", buffering=0)
        child.stderr = os.fdopen(err_fd, "rb", buffering=0)
        self.addCleanup(child.stdout.close)
        self.addCleanup(child.stderr.close)
        child.wait.return_value = status
        child.poll.side_effect = AssertionError("inner command must not be polled")
        child.communicate.side_effect = AssertionError("unbounded communicate forbidden")
        child.kill.side_effect = AssertionError("PID fallback forbidden")
        return child


class RetainedLaunchTests(TransportFixture):
    def assert_parent_cleans_anchor_after_start_failure(self, failure):
        # Same explicit no-spawn preparation replacement as lifecycle tests.
        # The production _spawn_worker/run error handoff itself stays real.
        launch = self.launch()
        session = self.ready_session()
        anchor = mock.Mock(pid=434340, returncode=None)
        anchor.wait.side_effect = lambda **kwargs: self.events.append("wait") or -9
        transports = []
        parent_ends = []
        close_failed = []
        original_close = os.close
        open_transport = self.api("_open_worker_transport")
        self.api("_worker_launch")

        def allocate(*args, **kwargs):
            value = open_transport(*args, **kwargs)
            transports.append(value)
            parent_ends.extend((value.request_fd, value.receipt_write_fd))
            return value

        def spawn(*args, **kwargs):
            if failure == "cancelled":
                session._latch_cancellation(None, None)
            return anchor

        def close(fd):
            original_close(fd)
            if (failure == "close" and self.popen.called
                    and fd in parent_ends and not close_failed):
                close_failed.append(True)
                raise OSError("synthetic uncertain parent close")

        self.popen.side_effect = spawn
        with mock.patch.object(core, "_worker_launch", return_value=launch):
            with mock.patch.object(core, "_open_worker_transport", side_effect=allocate):
                with mock.patch.object(core.os, "close", side_effect=close):
                    with self.assertRaises(core.ProcessFailure):
                        session.run(self.request())
        if failure == "close":
            self.assertEqual(close_failed, [True])
        self.assertEqual(self.events.count("signal"), 1)
        self.assertEqual(self.events.count("wait"), 1)
        self.assertLess(self.events.index("signal"), self.events.index("wait"))
        self.assertEqual(session.state, "poisoned")
        self.assertFalse(session.can_validate_final_checkout)
        self.assertEqual(len(transports), 1)
        for name in ("request_fd", "receipt_fd", "receipt_write_fd"):
            self.assertIsNone(getattr(transports[0], name))
        anchor.poll.assert_not_called()

    def test_parent_cleans_anchor_when_post_spawn_cancellation_prevents_helper_return(self):
        self.assert_parent_cleans_anchor_after_start_failure("cancelled")

    def test_parent_cleans_anchor_when_parent_end_close_prevents_helper_return(self):
        self.assert_parent_cleans_anchor_after_start_failure("close")

    def test_request_file_and_only_two_inherited_fds_reach_exact_worker_launch(self):
        launch = self.launch()
        transport = self.api("_open_worker_transport")(
            b'{"synthetic":true}\n', self.directory(), checkpoint=self.checkpoint)
        self.addCleanup(lambda: self.api("_close_worker_transport")(transport))
        request_fd, receipt_write = transport.request_fd, transport.receipt_write_fd
        self.assertEqual(os.lseek(request_fd, 0, os.SEEK_CUR), 0)
        self.assertEqual(os.fstat(request_fd).st_mode & 0o777, 0o600)
        with self.assertRaises(OSError) as readonly:
            os.write(request_fd, b"synthetic forbidden write")
        self.assertEqual(readonly.exception.errno, errno.EBADF)
        self.assertFalse(os.get_blocking(transport.receipt_fd))
        self.assertFalse(os.get_blocking(receipt_write))
        anchor = mock.Mock(pid=434343, returncode=None)

        def spawn(argv, **kwargs):
            self.assertEqual(tuple(argv), launch.argv + (
                "--request-fd", str(request_fd), "--receipt-fd", str(receipt_write)))
            self.assertEqual(kwargs["executable"], launch.executable.path)
            self.assertEqual(kwargs["cwd"], launch.cwd)
            self.assertEqual(kwargs["env"], dict(launch.environment))
            self.assertEqual(set(kwargs["pass_fds"]), {request_fd, receipt_write})
            self.assertTrue(kwargs["close_fds"])
            self.assertTrue(kwargs["start_new_session"])
            for name in ("stdin", "stdout", "stderr"):
                self.assertEqual(kwargs[name], core.subprocess.DEVNULL)
            self.assertEqual(os.read(request_fd, 1024), b'{"synthetic":true}\n')
            return anchor

        self.popen.side_effect = spawn
        self.api("_start_retained_worker")(transport, launch, checkpoint=self.checkpoint)
        self.assertIs(transport.anchor, anchor)
        self.assertIsNone(transport.request_fd)
        self.assertIsNone(transport.receipt_write_fd)
        self.assertIsNotNone(transport.receipt_fd)
        anchor.wait.assert_not_called()
        anchor.poll.assert_not_called()

    def test_returned_anchor_is_recorded_before_cancellation_checkpoint(self):
        launch = self.launch()
        transport = self.api("_open_worker_transport")(
            b'{}\n', self.directory(), checkpoint=self.checkpoint)
        self.addCleanup(lambda: self.api("_close_worker_transport")(transport))
        anchor = mock.Mock(pid=434344, returncode=None)
        returned = []

        def spawn(*args, **kwargs):
            returned.append(True)
            return anchor

        def checkpoint():
            if returned:
                self.assertIs(transport.anchor, anchor)
                raise core.ProcessFailure("cancelled")
            return self.checkpoint()

        self.popen.side_effect = spawn
        with self.assertRaises(core.ProcessFailure) as raised:
            self.api("_start_retained_worker")(transport, launch, checkpoint=checkpoint)
        self.assertEqual(raised.exception.reason, "cancelled")
        self.assertIs(transport.anchor, anchor)
        anchor.wait.assert_not_called()
        anchor.poll.assert_not_called()
        self.signal.assert_not_called()

    def test_expired_launch_never_creates_anchor(self):
        launch = self.launch()
        transport = self.api("_open_worker_transport")(
            b'{}\n', self.directory(), checkpoint=self.checkpoint)
        self.addCleanup(lambda: self.api("_close_worker_transport")(transport))
        self.clock.now = 20.0
        with self.assertRaises(core.ProcessFailure):
            self.api("_start_retained_worker")(transport, launch, checkpoint=self.checkpoint)
        self.assertIsNone(transport.anchor)
        self.popen.assert_not_called()

    def test_oversized_request_refuses_before_creating_files_or_fds(self):
        directory = self.directory()
        operation = self.api("_open_worker_transport")
        with mock.patch.object(core.os, "open", side_effect=AssertionError("oversized request open")):
            with self.assertRaises(core.ProcessFailure):
                operation(b"x" * (65536 + 1), directory, checkpoint=self.checkpoint)
        self.assertEqual(list(directory.iterdir()), [])

    def test_existing_request_file_is_preserved(self):
        directory = self.directory()
        request = directory / "request.json"
        request.write_bytes(b"synthetic existing sentinel")
        with self.assertRaises(core.ProcessFailure):
            self.api("_open_worker_transport")(b'{}\n', directory, checkpoint=self.checkpoint)
        self.assertEqual(request.read_bytes(), b"synthetic existing sentinel")
        self.popen.assert_not_called()

    def test_popen_failure_keeps_no_anchor_and_all_allocated_fds_can_close_once(self):
        launch = self.launch()
        transport = self.api("_open_worker_transport")(
            b'{}\n', self.directory(), checkpoint=self.checkpoint)
        self.popen.side_effect = OSError("synthetic launch failure")
        try:
            with self.assertRaises(core.ProcessFailure):
                self.api("_start_retained_worker")(transport, launch, checkpoint=self.checkpoint)
            self.assertIsNone(transport.anchor)
        finally:
            self.api("_close_worker_transport")(transport)
        for name in ("request_fd", "receipt_fd", "receipt_write_fd"):
            self.assertIsNone(getattr(transport, name))
        self.signal.assert_not_called()

    def test_pipe_allocation_failure_closes_request_and_preserves_no_unknown_file(self):
        directory = self.directory()
        operation = self.api("_open_worker_transport")
        original_open, original_close = os.open, os.close
        opened, closed = [], []
        def open_file(*args, **kwargs):
            descriptor = original_open(*args, **kwargs)
            opened.append(descriptor)
            return descriptor
        def close(fd):
            closed.append(fd)
            return original_close(fd)
        with mock.patch.object(core.os, "open", side_effect=open_file):
            with mock.patch.object(core.os, "close", side_effect=close):
                with mock.patch.object(core.os, "pipe", side_effect=OSError("synthetic pipe failure")):
                    with self.assertRaises(core.ProcessFailure):
                        operation(b'{}\n', directory, checkpoint=self.checkpoint)
        self.assertCountEqual(opened, closed)
        self.assertTrue(set(path.name for path in directory.iterdir()) <= {"request.json"})
        self.popen.assert_not_called()

    def test_close_is_inert_for_anchor_and_attempts_each_fd_once_after_failure(self):
        transport = self.api("_open_worker_transport")(
            b'{}\n', self.directory(), checkpoint=self.checkpoint)
        anchor = mock.Mock(pid=434345, returncode=None)
        transport.anchor = anchor
        descriptors = [transport.request_fd, transport.receipt_fd, transport.receipt_write_fd]
        original_close = os.close
        closed = []

        def close(fd):
            original_close(fd)
            closed.append(fd)
            if len(closed) == 1:
                raise OSError("synthetic uncertain close")

        with mock.patch.object(core.os, "close", side_effect=close):
            with self.assertRaises(core.ProcessFailure):
                self.api("_close_worker_transport")(transport)
            self.api("_close_worker_transport")(transport)
        self.assertCountEqual(closed, descriptors)
        anchor.wait.assert_not_called()
        anchor.poll.assert_not_called()
        self.signal.assert_not_called()


class WorkerCaptureTests(TransportFixture):
    def capture(self, child, *, maximum=16, before_select=None):
        command = self.fixed_command(maximum)
        directory = self.directory()
        request_fd, _ = self.pipe()
        receipt_read, receipt_write = self.pipe(hold_writer=True)
        os.set_inheritable(request_fd, True)
        os.set_inheritable(receipt_write, True)

        def spawn(argv, **kwargs):
            self.assertFalse(os.get_inheritable(request_fd))
            self.assertFalse(os.get_inheritable(receipt_write))
            self.assertEqual(tuple(argv), command.argv)
            self.assertEqual(kwargs["executable"], command.executable.path)
            self.assertEqual(kwargs["cwd"], command.cwd)
            self.assertEqual(kwargs["env"], dict(command.environment))
            self.assertEqual(kwargs["stdin"], core.subprocess.DEVNULL)
            self.assertEqual(kwargs["stdout"], core.subprocess.PIPE)
            self.assertEqual(kwargs["stderr"], core.subprocess.PIPE)
            self.assertTrue(kwargs["close_fds"])
            self.assertFalse(kwargs.get("start_new_session", False))
            self.assertEqual(tuple(kwargs.get("pass_fds", ())), ())
            return child

        self.popen.side_effect = spawn
        selector = ImmediateSelector(before_select)
        with mock.patch.object(core.selectors, "DefaultSelector", return_value=selector):
            result = self.api("_capture_worker_command")(
                command, directory, request_fd=request_fd, receipt_fd=receipt_write,
                checkpoint=self.checkpoint)
        return result, directory

    def test_exact_inner_launch_noninheritance_captures_and_one_wait(self):
        child = self.child()
        result, directory = self.capture(child)
        self.assertIs(type(result), protocol.CommandReceipt)
        self.assertEqual((result.outcome, result.command_status), ("success", 0))
        for name, data in (("stdout", b"out"), ("stderr", b"err")):
            path = directory / (name + ".bin")
            self.assertEqual(path.read_bytes(), data)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(getattr(result, name + "_sha256"), hashlib.sha256(data).hexdigest())
            self.assertEqual(getattr(result, name + "_bytes"), len(data))
        child.wait.assert_called_once()
        self.assertLessEqual(child.wait.call_args.kwargs["timeout"], 8.0)
        self.signal.assert_not_called()

    def test_nonzero_command_receipt_preserves_status(self):
        child = self.child(status=7)
        result, _ = self.capture(child)
        self.assertEqual((result.outcome, result.command_status), ("command-failed", 7))
        child.wait.assert_called_once()

    def test_aggregate_overflow_keeps_only_cap_and_never_waits_live_command(self):
        child = self.child(stdout=b"abcd", stderr=b"efgh")
        result, directory = self.capture(child, maximum=5)
        self.assertEqual(result.outcome, "output-limit")
        self.assertIsNone(result.command_status)
        self.assertEqual(result.stdout_bytes + result.stderr_bytes, 5)
        self.assertEqual(sum((directory / name).stat().st_size for name in
                             ("stdout.bin", "stderr.bin")), 5)
        child.wait.assert_not_called()
        child.poll.assert_not_called()
        self.assertTrue(any(item is child for item in core._WORKER_COMMANDS))
        self.signal.assert_not_called()

    def test_zero_cap_still_observes_one_byte_to_detect_overflow(self):
        child = self.child(stdout=b"x", stderr=b"")
        result, directory = self.capture(child, maximum=0)
        self.assertEqual(result.outcome, "output-limit")
        self.assertEqual((result.stdout_bytes, result.stderr_bytes), (0, 0))
        self.assertEqual((directory / "stdout.bin").read_bytes(), b"")
        child.wait.assert_not_called()

    def test_fair_reads_obey_remaining_plus_one_and_short_writes_are_complete(self):
        child = self.child(stdout=b"abcd", stderr=b"efgh")
        stream_fds = {child.stdout.fileno(), child.stderr.fileno()}
        original_read, original_write = os.read, os.write
        reads = []
        observed = 0

        def read(fd, maximum):
            nonlocal observed
            if fd in stream_fds:
                self.assertLessEqual(maximum, 8 - observed + 1)
                reads.append(fd)
                data = original_read(fd, min(maximum, 1))
                observed += len(data)
                return data
            return original_read(fd, maximum)

        def write(fd, payload):
            return original_write(fd, payload[:1])

        with mock.patch.object(core.os, "read", side_effect=read):
            with mock.patch.object(core.os, "write", side_effect=write):
                result, directory = self.capture(child, maximum=8)
        self.assertEqual(set(reads[:2]), stream_fds)
        self.assertEqual(result.outcome, "success")
        self.assertEqual((directory / "stdout.bin").read_bytes(), b"abcd")
        self.assertEqual((directory / "stderr.bin").read_bytes(), b"efgh")

    def test_select_return_at_original_deadline_withholds_receipt_success(self):
        child = self.child(hold_stdout=True)
        result, _ = self.capture(child, before_select=lambda: setattr(self.clock, "now", 20.0))
        self.assertEqual(result.outcome, "deadline")
        self.assertIsNone(result.command_status)
        child.wait.assert_not_called()

    def test_wait_return_after_original_deadline_cannot_report_success(self):
        child = self.child()
        def wait(**kwargs):
            self.clock.now = 20.0
            return 0
        child.wait.side_effect = wait
        result, _ = self.capture(child)
        self.assertEqual(result.outcome, "deadline")
        self.assertEqual(result.command_status, 0)
        child.wait.assert_called_once()

    def test_interrupted_and_not_ready_reads_do_not_drop_output(self):
        child = self.child(stdout=b"abc", stderr=b"def")
        out_fd = child.stdout.fileno()
        original_read = os.read
        attempts = []
        def read(fd, maximum):
            if fd == out_fd:
                attempts.append(True)
                if len(attempts) == 1:
                    raise BlockingIOError()
                if len(attempts) == 2:
                    raise InterruptedError()
            return original_read(fd, maximum)
        with mock.patch.object(core.os, "read", side_effect=read):
            result, directory = self.capture(child)
        self.assertEqual(result.outcome, "success")
        self.assertEqual((directory / "stdout.bin").read_bytes(), b"abc")
        self.assertEqual((directory / "stderr.bin").read_bytes(), b"def")

    def test_stream_read_failure_reports_failure_and_retains_unreaped_command(self):
        child = self.child()
        out_fd = child.stdout.fileno()
        original_read = os.read
        def read(fd, maximum):
            if fd == out_fd:
                raise OSError("synthetic stream failure")
            return original_read(fd, maximum)
        with mock.patch.object(core.os, "read", side_effect=read):
            result, _ = self.capture(child)
        self.assertEqual(result.outcome, "read-failed")
        self.assertIsNone(result.command_status)
        child.wait.assert_not_called()
        self.assertTrue(any(item is child for item in core._WORKER_COMMANDS))

    def test_noninheritance_failure_refuses_before_inner_spawn(self):
        command = self.fixed_command()
        directory = self.directory()
        request_fd, _ = self.pipe()
        _, receipt_write = self.pipe(hold_writer=True)
        with mock.patch.object(core.os, "set_inheritable", side_effect=OSError("synthetic flag failure")):
            with self.assertRaises(core.ProcessFailure):
                self.api("_capture_worker_command")(
                    command, directory, request_fd=request_fd, receipt_fd=receipt_write,
                    checkpoint=self.checkpoint)
        self.popen.assert_not_called()

    def test_capture_write_failure_reports_failure_and_closes_both_streams(self):
        child = self.child()
        with mock.patch.object(core.os, "write", side_effect=OSError("synthetic capture write failure")):
            result, directory = self.capture(child)
        self.assertEqual(result.outcome, "read-failed")
        self.assertIsNone(result.command_status)
        self.assertTrue(child.stdout.closed)
        self.assertTrue(child.stderr.closed)
        self.assertLessEqual(sum(path.stat().st_size for path in directory.iterdir()), 16)
        child.wait.assert_not_called()


class WorkerReceiptAndHoldTests(TransportFixture):
    def test_uncertain_request_close_cannot_publish_success_accepted_by_parent(self):
        session = self.ready_session()
        command_request = self.request(maximum_output_bytes=16)
        closed_uncertain = []
        sent = []
        held = []
        original_close = os.close
        class StopAtHold(BaseException):
            pass

        def spawn(_session, request, context, directory):
            request_fd, _ = self.pipe()
            receipt_read, receipt_write = self.pipe(hold_writer=True)
            anchor = mock.Mock(pid=484848, returncode=None)
            def wait(**kwargs):
                self.events.append("wait")
                # Simulate kernel endpoint closure from the already-recorded
                # owned-group signal. Never launch or terminate a real child.
                try:
                    os.fstat(receipt_write)
                except OSError:
                    pass
                else:
                    original_close(receipt_write)
                return -9
            anchor.wait.side_effect = wait
            command = core._FixedCommand(request.executable, request.argv, request.cwd,
                                         request.environment, request.deadline,
                                         request.maximum_output_bytes)
            def capture(*args, **kwargs):
                for name in ("stdout.bin", "stderr.bin"):
                    path = directory / name
                    path.write_bytes(b"")
                    path.chmod(0o600)
                return protocol.CommandReceipt("success", 0, 0, 0,
                    hashlib.sha256(b"").hexdigest(), hashlib.sha256(b"").hexdigest())
            def close(fd):
                original_close(fd)
                if fd == request_fd and not closed_uncertain:
                    closed_uncertain.append(True)
                    raise OSError("synthetic request close uncertainty")
            real_send = core._send_worker_receipt
            def send(*args, **kwargs):
                real_send(*args, **kwargs)
                sent.append(True)
            def hold(**kwargs):
                held.append(True)
                raise StopAtHold()
            with mock.patch.object(core, "_capture_worker_command", side_effect=capture):
                with mock.patch.object(core, "_send_worker_receipt", side_effect=send):
                    with mock.patch.object(core.os, "close", side_effect=close):
                        with mock.patch.object(core, "_hold_worker", side_effect=hold):
                            try:
                                core._run_worker_body(command, request, context, directory,
                                    request_fd=request_fd, receipt_fd=receipt_write,
                                    clock=self.clock, sleep=lambda _: None)
                            except StopAtHold:
                                pass
            return SimpleNamespace(anchor=anchor, receipt_fd=receipt_read)

        def selector():
            return ImmediateSelector(lambda: setattr(self.clock, "now", self.clock.now + 1.0))
        with mock.patch.object(core, "_spawn_worker", side_effect=spawn):
            with mock.patch.object(core.selectors, "DefaultSelector", side_effect=selector):
                with self.subTest(check="parent-refusal"):
                    with self.assertRaises(core.ProcessFailure):
                        session.run(command_request)
        self.assertEqual(closed_uncertain, [True])
        self.assertEqual(held, [True])
        with self.subTest(check="no-complete-frame"):
            self.assertEqual(sent, [])
        self.assertEqual(self.events.count("signal"), 1)
        self.assertEqual(self.events.count("wait"), 1)
        self.assertLess(self.events.index("signal"), self.events.index("wait"))
        self.popen.assert_not_called()

    def test_request_close_precedes_success_send_and_receipt_writer_lives_through_hold(self):
        command = self.fixed_command()
        request = self.request(argv=command.argv, maximum_output_bytes=16)
        context = protocol.ProtocolContext("2" * 32, 1, "1" * 64, "synthetic-profile", "3" * 64)
        receipt = protocol.CommandReceipt("success", 0, 0, 0,
            hashlib.sha256(b"").hexdigest(), hashlib.sha256(b"").hexdigest())
        request_fd, _ = self.pipe()
        _, receipt_fd = self.pipe(hold_writer=True)
        observations = []
        class StopAtHold(BaseException):
            pass
        def is_open(fd):
            try:
                os.fstat(fd)
                return True
            except OSError:
                return False
        def send(*args, **kwargs):
            observations.append(("send", is_open(request_fd), is_open(receipt_fd)))
        def hold(**kwargs):
            opened = is_open(receipt_fd)
            observations.append(("hold", is_open(request_fd), opened))
            if opened:
                self.assertFalse(os.get_inheritable(receipt_fd))
            raise StopAtHold()
        with mock.patch.object(core, "_capture_worker_command", return_value=receipt):
            with mock.patch.object(core, "_send_worker_receipt", side_effect=send):
                with mock.patch.object(core, "_hold_worker", side_effect=hold):
                    with self.assertRaises(StopAtHold):
                        core._run_worker_body(command, request, context, self.root,
                            request_fd=request_fd, receipt_fd=receipt_fd,
                            clock=self.clock, sleep=lambda _: None)
        # This no-process fixture substitutes for the parent's owned-group
        # kernel closure after observing the retained writer at hold.
        os.close(receipt_fd)
        self.assertEqual(observations, [("send", False, True), ("hold", False, True)])

    def test_worker_body_reaches_retained_hold_after_success_capture_or_send_failure(self):
        operation = self.api("_run_worker_body")
        command = self.fixed_command()
        request = self.request(argv=command.argv, maximum_output_bytes=16)
        context = protocol.ProtocolContext("2" * 32, 1, "1" * 64, "synthetic-profile", "3" * 64)
        receipt = protocol.CommandReceipt("success", 0, 0, 0,
            hashlib.sha256(b"").hexdigest(), hashlib.sha256(b"").hexdigest())
        class StopAfterHold(BaseException):
            pass
        for failure in ("none", "capture", "send", "close"):
            with self.subTest(failure=failure):
                request_fd, _ = self.pipe()
                _, receipt_fd = self.pipe(hold_writer=True)
                events = []
                original_close = os.close
                closed = []
                def close(fd):
                    original_close(fd)
                    closed.append(fd)
                    if failure == "close" and fd == request_fd:
                        raise OSError("synthetic uncertain passed-FD close")
                def capture(*args, **kwargs):
                    events.append("capture")
                    if failure == "capture":
                        raise core.ProcessFailure("process-unavailable")
                    return receipt
                def send(*args, **kwargs):
                    events.append("send")
                    if failure == "send":
                        raise core.ProcessFailure("deadline")
                def hold(**kwargs):
                    events.append("hold")
                    self.assertEqual(kwargs["deadline"], 20.0)
                    self.assertIs(kwargs["clock"], self.clock)
                    with self.assertRaises(OSError):
                        os.fstat(request_fd)
                    os.fstat(receipt_fd)
                    self.assertFalse(os.get_inheritable(receipt_fd))
                    raise StopAfterHold()
                with mock.patch.object(core, "_capture_worker_command", side_effect=capture, create=True):
                    with mock.patch.object(core, "_send_worker_receipt", side_effect=send, create=True):
                        with mock.patch.object(core, "_hold_worker", side_effect=hold, create=True):
                            with mock.patch.object(core.os, "close", side_effect=close):
                                with self.assertRaises(StopAfterHold):
                                    operation(command, request, context, self.root,
                                        request_fd=request_fd, receipt_fd=receipt_fd,
                                        clock=self.clock, sleep=lambda _: None)
                # Explicit fixture cleanup stands in for parent-owned group
                # termination; it is outside the worker's close observation.
                original_close(receipt_fd)
                self.assertEqual(closed, [request_fd])
                self.assertEqual(events, ["capture", "hold"] if failure in ("capture", "close")
                                 else ["capture", "send", "hold"])

    def test_framed_send_survives_short_write_eagain_and_interruption(self):
        read_fd, write_fd = self.pipe(hold_writer=True)
        frame = b'{"synthetic":true}\n'
        original_write = os.write
        calls = []
        def write(fd, data):
            calls.append(len(data))
            if len(calls) == 1:
                raise BlockingIOError()
            if len(calls) == 2:
                raise InterruptedError()
            return original_write(fd, data[:2])
        with mock.patch.object(core.selectors, "DefaultSelector", return_value=ImmediateSelector()):
            with mock.patch.object(core.os, "write", side_effect=write):
                self.api("_send_worker_receipt")(write_fd, frame, checkpoint=self.checkpoint)
        self.assertFalse(os.get_blocking(write_fd))
        self.assertEqual(os.read(read_fd, len(frame)), frame)
        self.assertGreater(len(calls), 3)

    def test_invalid_or_oversized_frame_never_writes(self):
        operation = self.api("_send_worker_receipt")
        _, write_fd = self.pipe(hold_writer=True)
        for frame in (b"{}", b"{}\nextra", b"{}\n{}\n", b"x" * 4096 + b"\n"):
            with self.subTest(size=len(frame)):
                with mock.patch.object(core.os, "write", side_effect=AssertionError("invalid frame write")):
                    with self.assertRaises(core.ProcessFailure):
                        operation(write_fd, frame, checkpoint=self.checkpoint)

    def test_write_return_at_deadline_refuses_even_if_bytes_reached_pipe(self):
        _, write_fd = self.pipe(hold_writer=True)
        original_write = os.write
        def write(fd, data):
            result = original_write(fd, data)
            self.clock.now = 20.0
            return result
        with mock.patch.object(core.selectors, "DefaultSelector", return_value=ImmediateSelector()):
            with mock.patch.object(core.os, "write", side_effect=write):
                with self.assertRaises(core.ProcessFailure) as raised:
                    self.api("_send_worker_receipt")(write_fd, b'{}\n', checkpoint=self.checkpoint)
        self.assertEqual(raised.exception.reason, "deadline")

    def test_zero_write_refuses_without_unbounded_retry(self):
        _, write_fd = self.pipe(hold_writer=True)
        with mock.patch.object(core.selectors, "DefaultSelector", return_value=ImmediateSelector()):
            with mock.patch.object(core.os, "write", return_value=0) as written:
                with self.assertRaises(core.ProcessFailure):
                    self.api("_send_worker_receipt")(write_fd, b'{}\n', checkpoint=self.checkpoint)
        written.assert_called_once()

    def test_permanent_backpressure_reaches_original_deadline_without_writing_success(self):
        _, write_fd = self.pipe(hold_writer=True)
        def advance():
            self.clock.now += 2.0
        selector = ImmediateSelector(advance)
        with mock.patch.object(core.selectors, "DefaultSelector", return_value=selector):
            with mock.patch.object(core.os, "write", side_effect=BlockingIOError()) as written:
                with self.assertRaises(core.ProcessFailure) as raised:
                    self.api("_send_worker_receipt")(write_fd, b'{}\n', checkpoint=self.checkpoint)
        self.assertEqual(raised.exception.reason, "deadline")
        self.assertLessEqual(selector.calls, 4)
        self.assertLessEqual(written.call_count, 5)

    def test_post_report_hold_uses_original_deadline_plus_three_without_early_signal(self):
        operation = self.api("_hold_worker")
        self.clock.now = 19.0
        sleeps = []
        class StopAfterSignal(BaseException):
            pass
        def sleep(duration):
            self.assertGreater(duration, 0)
            self.assertLessEqual(duration, 0.1)
            sleeps.append(duration)
            self.clock.now = 23.0 if len(sleeps) == 2 else 22.999
        def kill(group, number):
            self.assertEqual(group, 454545)
            self.assertEqual(number, signal.SIGKILL)
            self.assertEqual(self.clock.now, 23.0)
            raise StopAfterSignal()
        with mock.patch.object(core.os, "getpid", return_value=454545):
            with mock.patch.object(core.os, "killpg", side_effect=kill) as killed:
                with self.assertRaises(StopAfterSignal):
                    operation(deadline=20.0, clock=self.clock, sleep=sleep)
        self.assertEqual(len(sleeps), 2)
        killed.assert_called_once()
        self.popen.assert_not_called()

    def test_hold_primitive_faults_refuse_without_early_signal_or_clock_replacement(self):
        operation = self.api("_hold_worker")
        for fault in ("clock-error", "nonfinite", "backwards", "sleep-error"):
            with self.subTest(fault=fault):
                if fault == "clock-error":
                    observed_clock = mock.Mock(side_effect=OSError("synthetic clock failure"))
                elif fault == "nonfinite":
                    observed_clock = mock.Mock(return_value=float("nan"))
                elif fault == "backwards":
                    observed_clock = mock.Mock(side_effect=[19.0, 18.0])
                else:
                    observed_clock = mock.Mock(return_value=19.0)
                sleeper = mock.Mock(side_effect=OSError("synthetic sleep failure")
                                    if fault == "sleep-error" else None)
                with self.assertRaises(core.ProcessFailure) as raised:
                    operation(deadline=20.0, clock=observed_clock, sleep=sleeper)
                self.assertEqual(raised.exception.reason, "deadline")
                self.assertLessEqual(observed_clock.call_count, 2)
                self.assertLessEqual(sleeper.call_count, 1)
        self.signal.assert_not_called()
        self.popen.assert_not_called()


class PreNativeCleanupTests(TransportFixture):
    def test_cleanup_authorities_share_one_consumption_registry_in_both_orders(self):
        bootstrap = self.api("_cleanup_bootstrap_anchor")
        for order in ("bootstrap-first", "operational-first"):
            with self.subTest(order=order):
                anchor = mock.Mock(pid=464640, returncode=None)
                anchor.wait.return_value = -9
                observe = mock.Mock(return_value=(0, 0, 0, 0))
                self.events.clear()
                if order == "bootstrap-first":
                    bootstrap(anchor, deadline=20.0, clock=self.clock)
                    with self.assertRaises(core.ProcessFailure):
                        core._cleanup_anchor(anchor, deadline=20.0, clock=self.clock, observe=observe)
                    observe.assert_not_called()
                else:
                    core._cleanup_anchor(anchor, deadline=20.0, clock=self.clock, observe=observe)
                    with self.assertRaises(core.ProcessFailure):
                        bootstrap(anchor, deadline=20.0, clock=self.clock)
                    observe.assert_called_once()
                self.assertEqual(self.events, ["signal"])
                anchor.wait.assert_called_once()

    def test_pre_native_cleanup_signals_before_sole_wait_without_native_observer(self):
        anchor = mock.Mock(pid=464646, returncode=None)
        anchor.wait.side_effect = lambda **kwargs: self.events.append("wait") or -9
        operation = self.api("_cleanup_bootstrap_anchor")
        with mock.patch.object(core, "_cleanup_anchor", side_effect=AssertionError("fake native observer forbidden")):
            self.assertEqual(operation(anchor, deadline=20.0, clock=self.clock), -9)
        self.assertEqual(self.events, ["signal", "wait"])
        anchor.poll.assert_not_called()
        with self.assertRaises(core.ProcessFailure):
            operation(anchor, deadline=20.0, clock=self.clock)
        self.assertEqual(self.events, ["signal", "wait"])

    def test_pre_native_cleanup_failed_signal_never_uses_pid_fallback_or_second_wait(self):
        anchor = mock.Mock(pid=464647, returncode=None)
        anchor.wait.return_value = -9
        operation = self.api("_cleanup_bootstrap_anchor")
        with mock.patch.object(core.os, "killpg", side_effect=PermissionError()):
            with self.assertRaises(core.ProcessFailure):
                operation(anchor, deadline=20.0, clock=self.clock)
        anchor.wait.assert_called_once()
        anchor.kill.assert_not_called()
        anchor.poll.assert_not_called()
        with self.assertRaises(core.ProcessFailure):
            operation(anchor, deadline=20.0, clock=self.clock)
        anchor.wait.assert_called_once()

    def test_pre_native_late_wait_cannot_reset_original_cleanup_reserve(self):
        anchor = mock.Mock(pid=464648, returncode=None)
        self.clock.now = 21.5
        def wait(**kwargs):
            self.assertEqual(kwargs["timeout"], 0.5)
            self.clock.now = 22.0
            return -9
        anchor.wait.side_effect = wait
        with self.assertRaises(core.ProcessFailure) as raised:
            self.api("_cleanup_bootstrap_anchor")(anchor, deadline=20.0, clock=self.clock)
        self.assertEqual(raised.exception.reason, "cleanup-failed")
        anchor.wait.assert_called_once()

    def test_pre_native_synthetic_echild_zero_never_counts_as_confirmed_reap(self):
        anchor = mock.Mock(pid=464649, returncode=None)
        anchor.wait.return_value = 0
        with self.assertRaises(core.ProcessFailure):
            self.api("_cleanup_bootstrap_anchor")(anchor, deadline=20.0, clock=self.clock)
        anchor.wait.assert_called_once()
        self.assertIsNone(anchor.returncode)


class PreparingTransportTests(TransportFixture):
    def preparing(self):
        # Deliberate in-memory fixture state; never passed to public admission.
        session = core.QualifiedProcessSession()
        session._state = "preparing"
        session._prepared = False
        session._failed = False
        session._cancelled = False
        session._clock = self.clock
        session._last_clock = self.clock.now
        session._active_anchor = None
        session._active_transport = None
        session._bootstrap_consumed = False
        session._bootstrap_deadline = 20.0
        session._runtime = None
        session._session_id = "2" * 32
        session._profile_id = "synthetic-profile"
        session._package = SimpleNamespace(sha256="1" * 64)
        info = self.root.stat()
        sdk = protocol.SDKIdentity(str(self.root), "4" * 64,
            info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid)
        request = protocol.BootstrapRequest(self.selected, self.selected, sdk,
            self.root, protocol._BOOT_ENV, 20.0, protocol.BOOTSTRAP_OUTPUT_BYTES)
        context = protocol.ProtocolContext("2" * 32, 1, "1" * 64, "synthetic-profile", None)
        return session, request, context

    def test_preparing_dispatch_requires_reset_acceptance_then_uses_shared_transport_once(self):
        operation = self.api("_spawn_bootstrap_worker")
        self.api("_bootstrap_worker_launch")
        launch = self.launch()
        session, request, context = self.preparing()
        directory = self.directory()
        anchor = mock.Mock(pid=474747, returncode=None)
        anchor.wait.return_value = -9
        ordered = []
        def accepted(*args, **kwargs):
            ordered.append("qualified-reset-accepted")
            return launch
        def spawn(*args, **kwargs):
            self.assertEqual(ordered, ["qualified-reset-accepted"])
            ordered.append("spawn")
            return anchor
        self.popen.side_effect = spawn
        with mock.patch.object(core, "_bootstrap_worker_launch", side_effect=accepted):
            transport = operation(session, request, context, directory, deadline=20.0)
            try:
                self.assertIs(transport.anchor, anchor)
                self.assertIs(session._active_transport, transport)
                self.assertTrue(session._bootstrap_consumed)
                with self.assertRaises(core.ProcessFailure):
                    operation(session, request, context, directory, deadline=20.0)
                self.assertEqual(ordered, ["qualified-reset-accepted", "spawn"])
            finally:
                self.api("_cleanup_bootstrap_anchor")(anchor, deadline=20.0, clock=self.clock)
                self.api("_close_worker_transport")(transport)

    def test_missing_runtime_or_failed_reset_acceptance_never_spawns(self):
        operation = self.api("_spawn_bootstrap_worker")
        self.api("_bootstrap_worker_launch")
        for failure in ("missing-runtime", "failed-reset"):
            with self.subTest(failure=failure):
                session, request, context = self.preparing()
                directory = self.root / failure
                directory.mkdir(mode=0o700)
                if failure == "failed-reset":
                    with mock.patch.object(core, "_bootstrap_worker_launch",
                            side_effect=core.ProcessFailure("process-unavailable")):
                        with self.assertRaises(core.ProcessFailure):
                            operation(session, request, context, directory, deadline=20.0)
                else:
                    with self.assertRaises(core.ProcessFailure):
                        operation(session, request, context, directory, deadline=20.0)
                self.assertTrue(session._bootstrap_consumed)
                self.assertEqual(list(directory.iterdir()), [])
        self.popen.assert_not_called()

    def test_operational_or_mismatched_deadline_cannot_obtain_bootstrap_privilege(self):
        operation = self.api("_spawn_bootstrap_worker")
        self.api("_bootstrap_worker_launch")
        for mismatch in ("ready", "poisoned", "deadline"):
            with self.subTest(mismatch=mismatch):
                session, request, context = self.preparing()
                if mismatch != "deadline":
                    session._state = mismatch
                with mock.patch.object(core, "_bootstrap_worker_launch",
                        side_effect=AssertionError("invalid bootstrap qualification")) as qualify:
                    with self.assertRaises(core.ProcessFailure):
                        operation(session, request, context, self.root,
                                  deadline=21.0 if mismatch == "deadline" else 20.0)
                qualify.assert_not_called()
        self.popen.assert_not_called()

    def test_jointly_changed_request_and_argument_cannot_replace_original_budget(self):
        operation = self.api("_spawn_bootstrap_worker")
        session, original, context = self.preparing()
        changed = protocol.BootstrapRequest(original.compiler, original.source, original.sdk,
            original.cwd, original.environment, 21.0, original.maximum_output_bytes)
        with mock.patch.object(core, "_bootstrap_worker_launch",
                side_effect=AssertionError("reset after changed budget")) as qualify:
            with mock.patch.object(core.os, "open", side_effect=AssertionError("file after changed budget")) as opened:
                with self.assertRaises(core.ProcessFailure):
                    operation(session, changed, context, self.root, deadline=21.0)
        self.assertEqual(session._bootstrap_deadline, 20.0)
        qualify.assert_not_called()
        opened.assert_not_called()
        self.popen.assert_not_called()
