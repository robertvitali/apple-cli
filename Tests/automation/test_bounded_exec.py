import errno
import importlib.util
import io
import os
from pathlib import Path
import signal
import subprocess
import sys
import unittest
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
BOUNDED_EXEC_PATH = REPO_ROOT / "bats" / "helpers" / "bounded_exec.py"


def load_bounded_exec():
    spec = importlib.util.spec_from_file_location("bounded_exec", BOUNDED_EXEC_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load bounded_exec")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def permission_error() -> PermissionError:
    return PermissionError(errno.EPERM, os.strerror(errno.EPERM))


def lookup_error() -> ProcessLookupError:
    return ProcessLookupError(errno.ESRCH, os.strerror(errno.ESRCH))


class Leader:
    """A stand-in for the group leader's Popen: poll() reaps it if it has exited."""

    pid = 12345
    stdout = None

    def __init__(self, returncode, exit_status) -> None:
        self.returncode = returncode
        self.exit_status = exit_status

    def poll(self):
        if self.returncode is None:
            self.returncode = self.exit_status
        return self.returncode

    def wait(self, timeout=None):
        return self.poll()


class BoundedExecPermissionErrorTests(unittest.TestCase):
    # Darwin's killpg fails with EPERM for a group whose members have all exited but are not
    # yet reaped; Linux, where this tier runs in CI, does not fail for such a group, so the
    # handling is pinned with stand-ins here, as in test_quality.py (2026-10-05).

    def setUp(self) -> None:
        self.bounded = load_bounded_exec()

    def test_cleanup_signal_reaps_an_exited_leader_without_a_warning(self) -> None:
        # The leader was the group's only member, so the retry after the reap finds it gone.
        warnings = io.StringIO()
        effects = [permission_error(), lookup_error()]
        with mock.patch.object(self.bounded.os, "killpg", side_effect=effects) as killpg, \
                mock.patch.object(self.bounded.sys, "stderr", warnings):
            zombie = Leader(None, -signal.SIGKILL)
            self.assertFalse(self.bounded.try_signal_cleanup_group(zombie, signal.SIGTERM))
        self.assertEqual(zombie.returncode, -signal.SIGKILL)
        self.assertEqual(warnings.getvalue(), "")
        self.assertEqual(
            killpg.call_args_list,
            [mock.call(12345, signal.SIGTERM), mock.call(12345, signal.SIGTERM)],
        )

    def test_cleanup_signal_retries_once_after_reaping_an_exited_leader(self) -> None:
        # A member the reap does not explain: the retry signals it, or meets EPERM again and
        # leaves the warning. Either way the leader is reaped and the signal is tried twice.
        cases = (
            (permission_error(), False, self.bounded.CLEANUP_PERMISSION_WARNING + "\n"),
            (None, True, ""),
        )
        for retry, sent, warned in cases:
            warnings = io.StringIO()
            zombie = Leader(None, 0)
            with self.subTest(retry=type(retry).__name__), \
                    mock.patch.object(
                        self.bounded.os, "killpg", side_effect=[permission_error(), retry]
                    ) as killpg, mock.patch.object(self.bounded.sys, "stderr", warnings):
                self.assertIs(self.bounded.try_signal_cleanup_group(zombie, signal.SIGKILL), sent)
            self.assertEqual(zombie.returncode, 0)
            self.assertEqual(warnings.getvalue(), warned)
            self.assertEqual(killpg.call_count, 2)

    def test_cleanup_signal_forgives_any_other_permission_error_with_a_warning(self) -> None:
        # A running leader, or one already reaped as after cleanup's own wait: nothing explains
        # the error, so it is reported as nothing sent and leaves a warning.
        for leader in (Leader(None, None), Leader(-signal.SIGTERM, -signal.SIGTERM)):
            warnings = io.StringIO()
            with self.subTest(returncode=leader.returncode), \
                    mock.patch.object(self.bounded.os, "killpg", side_effect=permission_error()), \
                    mock.patch.object(self.bounded.sys, "stderr", warnings):
                self.assertFalse(self.bounded.try_signal_cleanup_group(leader, signal.SIGKILL))
            self.assertEqual(warnings.getvalue(), self.bounded.CLEANUP_PERMISSION_WARNING + "\n")

    def test_cleanup_signal_reports_success_and_a_missing_group_unchanged(self) -> None:
        leader = Leader(None, None)
        with mock.patch.object(self.bounded.os, "killpg", return_value=None) as killpg:
            self.assertTrue(self.bounded.try_signal_cleanup_group(leader, signal.SIGTERM))
        killpg.assert_called_once_with(12345, signal.SIGTERM)
        with mock.patch.object(self.bounded.os, "killpg", side_effect=lookup_error()):
            self.assertFalse(self.bounded.try_signal_cleanup_group(leader, signal.SIGTERM))
        self.assertIsNone(leader.returncode)

    def test_pid_only_helpers_forgive_nothing(self) -> None:
        with mock.patch.object(self.bounded.os, "killpg", side_effect=permission_error()):
            with self.assertRaises(PermissionError):
                self.bounded.try_signal_group(12345, signal.SIGTERM)
            with self.assertRaises(PermissionError):
                self.bounded.signal_group(12345, signal.SIGKILL)

    def test_cleanup_stop_routes_both_signals_through_the_cleanup_helper(self) -> None:
        # Cleanup's SIGTERM meets EPERM from an exited, unreaped leader, the group's only
        # member, so once it is reaped the retried SIGTERM and the sweep's SIGKILL find nothing.
        zombie = Leader(None, -signal.SIGKILL)
        helper = self.bounded.try_signal_cleanup_group
        warnings = io.StringIO()
        spy = mock.patch.object(self.bounded, "try_signal_cleanup_group", wraps=helper)
        effects = [permission_error(), lookup_error(), lookup_error()]
        with mock.patch.object(self.bounded.os, "killpg", side_effect=effects) as killpg, \
                spy as routed, mock.patch.object(self.bounded.sys, "stderr", warnings):
            self.assertIsNone(self.bounded.stop_process_group(zombie, 0.1))

        self.assertEqual(
            routed.call_args_list,
            [mock.call(zombie, signal.SIGTERM), mock.call(zombie, signal.SIGKILL)],
        )
        self.assertEqual(
            killpg.call_args_list,
            [
                mock.call(12345, signal.SIGTERM),
                mock.call(12345, signal.SIGTERM),
                mock.call(12345, signal.SIGKILL),
            ],
        )
        self.assertEqual(zombie.returncode, -signal.SIGKILL)
        self.assertEqual(warnings.getvalue(), "")

    def test_cleanup_escalation_forgives_permission_error_from_a_live_leader(self) -> None:
        # The escalation branch (the first drain did not complete): the group's SIGKILL meets
        # EPERM while the leader is still running. Cleanup warns instead of raising; the first
        # drain's bounded reap has already killed the leader by pid, and the second drain's
        # wait collects it.
        class Stuck(Leader):
            waits = 0
            kills = 0

            def poll(self):
                return self.returncode

            def kill(self):
                self.kills += 1

            def wait(self, timeout=None):
                self.waits += 1
                if self.waits <= 2:
                    raise subprocess.TimeoutExpired(("leader",), timeout)
                self.returncode = -signal.SIGKILL
                return self.returncode

        leader = Stuck(None, None)
        warnings = io.StringIO()
        with mock.patch.object(self.bounded.os, "killpg", side_effect=[None, permission_error()]), \
                mock.patch.object(self.bounded.sys, "stderr", warnings):
            self.assertIsNone(self.bounded.stop_process_group(leader, 0.1))
        self.assertEqual((leader.waits, leader.kills, leader.returncode), (3, 1, -signal.SIGKILL))
        self.assertEqual(warnings.getvalue(), self.bounded.CLEANUP_PERMISSION_WARNING + "\n")

    def test_a_deadline_whose_group_signals_meet_permission_error_still_returns_124(
        self,
    ) -> None:
        # Every group signal fails with EPERM, so the real child survives both; the bounded
        # leader reap (Popen.kill, which signals the pid, not the group) ends it, and the
        # wrapper returns the deadline status instead of a traceback.
        warnings = io.StringIO()
        command = [sys.executable, "-c", "import time; time.sleep(30)"]
        argv = ["--timeout", "0.3", "--grace", "0.2", "--", *command]
        popens = []
        real_popen = subprocess.Popen

        def recording_popen(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            popens.append(process)
            return process

        def end_recorded_children():
            # A regression that raises before the leader reap would leave the real child
            # sleeping; end it here so no test outlives its own run.
            for process in popens:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)

        self.addCleanup(end_recorded_children)
        with mock.patch.object(self.bounded.os, "killpg", side_effect=permission_error()), \
                mock.patch.object(self.bounded.subprocess, "Popen", side_effect=recording_popen), \
                mock.patch.object(self.bounded.sys, "stderr", warnings):
            status = self.bounded.run(argv)

        self.assertEqual(status, self.bounded.TIMEOUT_STATUS)
        self.assertEqual(len(popens), 1)
        # The leader reap waits only the grace after its pid-level SIGKILL, which a loaded host
        # can outlast; the kill itself is what this pins.
        self.assertEqual(popens[0].wait(timeout=10), -signal.SIGKILL)
        self.assertEqual(warnings.getvalue(), (self.bounded.CLEANUP_PERMISSION_WARNING + "\n") * 2)

    def test_repeated_cancellation_outside_cleanup_keeps_its_status(self) -> None:
        # A first SIGTERM raises the cancellation; a second, before cleanup has started, takes
        # the handler's accelerating SIGKILL, which meets EPERM. The run must still clean up and
        # return 128+SIGTERM. The signals are raised from inside child_status, which run()
        # calls with cancellation unblocked and no cleanup active, so the order is exact.
        real_child_status = self.bounded.child_status
        raised = []

        def child_status(returncode):
            # Raising SIGTERM with no handler installed would end the whole test process.
            if signal.getsignal(signal.SIGTERM) in (signal.SIG_DFL, signal.SIG_IGN):
                raise AssertionError("child_status ran outside the cancellation handler's scope")
            try:
                signal.raise_signal(signal.SIGTERM)
            except self.bounded.CancellationRequested:
                raised.append("first")
                signal.raise_signal(signal.SIGTERM)
                raised.append("second")
                raise
            return real_child_status(returncode)

        def killpg(_process_group, sig):
            raise permission_error()

        warnings = io.StringIO()
        argv = ["--timeout", "60", "--grace", "0.2", "--", sys.executable, "-c", "pass"]
        with mock.patch.object(self.bounded, "child_status", side_effect=child_status), \
                mock.patch.object(self.bounded.os, "killpg", side_effect=killpg) as group_kill, \
                mock.patch.object(self.bounded.sys, "stderr", warnings):
            status = self.bounded.run(argv)

        self.assertEqual(raised, ["first", "second"])
        self.assertEqual(status, 128 + signal.SIGTERM)
        # The handler's SIGKILL first, then cleanup's SIGTERM and sweep, each forgiven: the
        # leader was reaped by communicate(), so cleanup's two EPERMs leave warnings.
        self.assertEqual(
            [call.args[1] for call in group_kill.call_args_list],
            [signal.SIGKILL, signal.SIGTERM, signal.SIGKILL],
        )
        self.assertEqual(warnings.getvalue(), (self.bounded.CLEANUP_PERMISSION_WARNING + "\n") * 2)

    def test_the_cancellation_accelerator_ignores_permission_and_lookup_errors(self) -> None:
        leader = Leader(None, None)
        for effect in (permission_error(), lookup_error(), None):
            with self.subTest(effect=type(effect).__name__), \
                    mock.patch.object(self.bounded.os, "killpg", side_effect=effect) as killpg:
                self.assertIsNone(self.bounded.kill_group_after_cancellation(leader))
            killpg.assert_called_once_with(12345, signal.SIGKILL)
        self.assertIsNone(leader.returncode)

    def test_a_completed_run_never_signals_the_group(self) -> None:
        # Only cleanup and the cancellation handler signal the group, so the forgiveness above
        # can never reach a run that completes on its own.
        argv = ["--timeout", "60", "--grace", "0.2", "--", sys.executable, "-c", "pass"]
        with mock.patch.object(self.bounded.os, "killpg") as killpg:
            self.assertEqual(self.bounded.run(argv), 0)
        killpg.assert_not_called()


if __name__ == "__main__":
    unittest.main()
