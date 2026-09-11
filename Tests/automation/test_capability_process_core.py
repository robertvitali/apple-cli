"""Pure process-core contracts; no compiler, native library, or child process.

Constructed session fixtures explicitly replace qualification and OS boundaries.
They are not evidence of a qualified runtime or native ownership.
"""

from __future__ import annotations

import importlib
import inspect
from pathlib import Path
import sys
import unittest
from unittest import mock


CI = Path(__file__).resolve().parents[2] / "scripts" / "ci"
if str(CI) not in sys.path:
    sys.path.insert(0, str(CI))

core = importlib.import_module("capability_process")


class Clock:
    def __init__(self, value=10.0):
        self.value = value

    def __call__(self):
        return self.value


def session_fixture(clock=None):
    """Explicit no-spawn fixture: admission/runtime identity is replaced."""
    session = object.__new__(core.QualifiedProcessSession)
    session._clock = clock or Clock()
    session._state = "ready"
    session._prepared = True
    session._cancelled = False
    session._close_attempted = False
    session._close_completed = False
    session._close_failure = None
    session._decision_slot = {}
    session._cancellation_decision = None
    session._active_anchor = None
    session._directory = None
    session._signal_handlers = None
    return session


class PreparationBudgetTests(unittest.TestCase):
    def test_same_original_clock_and_deadline_transfer_once(self):
        clock = Clock(12.0)
        budget = core._PreparationBudget(clock, 10.0, 68.0)
        reader, started, deadline = budget._consume()
        self.assertIs(reader, clock)
        self.assertEqual((started, deadline, reader()), (10.0, 68.0, 12.0))
        with self.assertRaises(core.ProcessFailure):
            budget._consume()

    def test_expired_first_attempt_stays_consumed(self):
        clock = Clock(68.0)
        budget = core._PreparationBudget(clock, 10.0, 68.0)
        with self.assertRaises(core.ProcessFailure):
            budget._consume()
        clock.value = 11.0
        with self.assertRaises(core.ProcessFailure):
            budget._consume()

    def test_invalid_clock_domain_or_reset_budget_refuses(self):
        for observed in (True, 10, -1.0, float("nan"), float("inf"), 9.0):
            with self.subTest(observed=repr(observed)):
                with self.assertRaises(core.ProcessFailure):
                    core._PreparationBudget(Clock(observed), 10.0, 68.0)._consume()
        with self.assertRaises(core.ProcessFailure):
            core._PreparationBudget(Clock(), 10.0, 69.0)._consume()


class SessionAdmissionTests(unittest.TestCase):
    def test_fake_objects_and_wrong_states_do_not_gain_production_admission(self):
        class Duck:
            state = "ready"
            can_validate_final_checkout = True

            def run(self, request):
                raise AssertionError("must not run")

        for value in (None, object(), Duck()):
            with self.assertRaises(core.ProcessFailure):
                core.require_process_session(value)
        for state in ("preparing", "command-active", "closed"):
            value = session_fixture()
            value._state = state
            with self.assertRaises(core.ProcessFailure):
                core.require_process_session(value)

    def test_poisoned_identity_is_inspectable_but_cannot_validate_or_run(self):
        value = session_fixture()
        value._state = "poisoned"
        self.assertIs(core.require_process_session(value), value)
        self.assertFalse(value.can_validate_final_checkout)
        with self.assertRaises(core.ProcessFailure):
            value.run(object())

    def test_cancelled_ready_session_cannot_validate(self):
        value = session_fixture()
        value._latch_cancellation(2, None)
        self.assertFalse(value.can_validate_final_checkout)


class FinalDecisionTests(unittest.TestCase):
    def setUp(self):
        self.proposed = core.ProcessDecision(b"success\n", b"", 0)
        self.cancelled = core.ProcessDecision(b"failure\n", b"cancelled\n", 1)

    def test_finalize_requires_close_and_success_requires_clean_close(self):
        value = session_fixture()
        with self.assertRaises(core.ProcessFailure):
            value.finalize_decision(proposed=self.proposed, cancelled=self.cancelled)
        value._close_attempted = True
        with self.assertRaises(core.ProcessFailure):
            value.finalize_decision(proposed=self.proposed, cancelled=self.cancelled)

    def test_poisoned_close_cannot_authorize_success(self):
        value = session_fixture()
        value._state = "poisoned"
        value.close()
        with self.assertRaises(core.ProcessFailure):
            value.finalize_decision(proposed=self.proposed, cancelled=self.cancelled)

    def test_cancellation_before_boundary_wins_and_later_calls_keep_decision(self):
        value = session_fixture()
        value.close()
        value._latch_cancellation(2, None)
        self.assertIs(value.finalize_decision(proposed=self.proposed,
                                             cancelled=self.cancelled), self.cancelled)
        self.assertIs(value.finalize_decision(proposed=self.proposed,
                                             cancelled=self.cancelled), self.cancelled)

    def test_cancellation_after_boundary_does_not_rewrite_decision(self):
        value = session_fixture()
        value.close()
        result = value.finalize_decision(proposed=self.proposed,
                                         cancelled=self.cancelled)
        value._latch_cancellation(2, None)
        self.assertIs(result, self.proposed)
        self.assertIs(value.finalize_decision(proposed=self.cancelled,
                                             cancelled=self.cancelled), self.proposed)

    def test_injected_cancellation_immediately_before_and_after_commit(self):
        method = core.QualifiedProcessSession.finalize_decision
        lines, first_line = inspect.getsourcelines(method)
        # Trace the real built-in operation, without replacing the decision
        # dictionary or introducing a production cancellation test hook.
        commit_line = first_line + next(
            index for index, line in enumerate(lines)
            if line.strip() == 'return self._decision_slot.setdefault("decision", proposed)')
        for boundary, expected in (("line", self.cancelled), ("return", self.proposed)):
            with self.subTest(boundary=boundary):
                value = session_fixture()
                value.close()
                injections = []

                def trace(frame, event, argument):
                    if (frame.f_code is method.__code__ and event == boundary
                            and (event == "return" or frame.f_lineno == commit_line)
                            and not injections):
                        injections.append(event)
                        value._latch_cancellation(2, None)
                    return trace

                previous_trace = sys.gettrace()
                try:
                    sys.settrace(trace)
                    result = value.finalize_decision(
                        proposed=self.proposed, cancelled=self.cancelled)
                finally:
                    sys.settrace(previous_trace)
                self.assertEqual(injections, [boundary])
                self.assertIs(result, expected)
                self.assertIs(value.finalize_decision(
                    proposed=self.proposed, cancelled=self.cancelled), expected)


class RetainedAnchorCleanupTests(unittest.TestCase):
    def test_live_anchor_is_signalled_before_sole_wait(self):
        events = []
        anchor = mock.Mock()
        anchor.pid = 4242
        anchor.wait.side_effect = lambda **kwargs: events.append(("wait", kwargs)) or -9
        clock = Clock(10.0)
        with mock.patch.object(core.os, "killpg",
                               side_effect=lambda *args: events.append(("signal", args))):
            result = core._cleanup_anchor(anchor, deadline=11.0, clock=clock,
                                          observe=lambda child: (0, 0, 0, 0))
        self.assertEqual([event[0] for event in events], ["signal", "wait"])
        self.assertEqual(events[1][1], {"timeout": 2.0})
        self.assertEqual(result, -9)

    def test_successful_cleanup_retires_anchor_before_any_second_operation(self):
        anchor = mock.Mock(pid=4242)
        anchor.wait.return_value = -9
        observe = mock.Mock(return_value=(0, 0, 0, 0))
        with mock.patch.object(core.os, "killpg") as group_signal:
            self.assertEqual(core._cleanup_anchor(
                anchor, deadline=11.0, clock=Clock(), observe=observe), -9)
            observe.assert_called_once_with(4242)
            group_signal.assert_called_once_with(4242, 9)
            anchor.wait.assert_called_once_with(timeout=2.0)
            observe.reset_mock()
            group_signal.reset_mock()
            anchor.wait.reset_mock()
            with self.subTest(contract="second cleanup refuses"):
                with self.assertRaises(core.ProcessFailure):
                    core._cleanup_anchor(anchor, deadline=11.0, clock=Clock(),
                                         observe=observe)
            with self.subTest(contract="no second observation"):
                observe.assert_not_called()
            with self.subTest(contract="no second group signal"):
                group_signal.assert_not_called()
            with self.subTest(contract="no second waiter"):
                anchor.wait.assert_not_called()

    def test_synthetic_echild_zero_status_is_not_confirmed_cleanup(self):
        anchor = mock.Mock(pid=4242)
        # CPython can synthesize zero after ECHILD; receipt acceptance must not
        # treat that value as evidence that our SIGKILL was successfully reaped.
        anchor.wait.return_value = 0
        with mock.patch.object(core.os, "killpg") as group_signal:
            with self.assertRaises(core.ProcessFailure) as raised:
                core._cleanup_anchor(anchor, deadline=11.0, clock=Clock(),
                                     observe=lambda child: (0, 0, 0, 0))
        group_signal.assert_called_once_with(4242, 9)
        anchor.wait.assert_called_once_with(timeout=2.0)
        self.assertEqual(raised.exception.reason, "cleanup-failed")
        self.assertEqual(raised.exception.session_disposition, "poisoned")

    def test_wait_return_after_either_cleanup_bound_refuses(self):
        for started, deadline, finished, allowed_wait in (
                (10.0, 50.0, 12.001, 2.0),
                (12.0, 11.0, 13.001, 1.0)):
            with self.subTest(started=started, deadline=deadline):
                anchor = mock.Mock(pid=4242)
                anchor.wait.return_value = -9
                clock = mock.Mock(side_effect=(started, finished))
                with mock.patch.object(core.os, "killpg") as group_signal:
                    with self.assertRaises(core.ProcessFailure) as raised:
                        core._cleanup_anchor(anchor, deadline=deadline, clock=clock,
                                             observe=lambda child: (0, 0, 0, 0))
                group_signal.assert_called_once_with(4242, 9)
                anchor.wait.assert_called_once_with(timeout=allowed_wait)
                self.assertEqual(raised.exception.reason, "cleanup-failed")
                self.assertEqual(raised.exception.session_disposition, "poisoned")

    def test_terminal_anchor_is_reaped_without_group_signal(self):
        anchor = mock.Mock(pid=4242)
        anchor.wait.return_value = 1
        with mock.patch.object(core.os, "killpg") as group_signal:
            with self.assertRaises(core.ProcessFailure) as raised:
                core._cleanup_anchor(anchor, deadline=11.0, clock=Clock(),
                                     observe=lambda child: (1, child, 1, 1))
        group_signal.assert_not_called()
        anchor.wait.assert_called_once_with(timeout=2.0)
        self.assertEqual(raised.exception.reason, "ownership-lost")

    def test_echild_revokes_signal_and_wait_authority(self):
        anchor = mock.Mock(pid=4242)
        with mock.patch.object(core.os, "killpg") as group_signal:
            with self.assertRaises(core.ProcessFailure):
                core._cleanup_anchor(anchor, deadline=11.0, clock=Clock(),
                                     observe=mock.Mock(side_effect=ChildProcessError()))
        group_signal.assert_not_called()
        anchor.wait.assert_not_called()

    def test_revoked_anchor_cannot_be_observed_signalled_or_waited_again(self):
        anchor = mock.Mock(pid=4242)
        core._disarm_anchor(anchor)
        observe = mock.Mock()
        with mock.patch.object(core.os, "killpg") as group_signal:
            with self.assertRaises(core.ProcessFailure):
                core._cleanup_anchor(anchor, deadline=11.0, clock=Clock(),
                                     observe=observe)
        observe.assert_not_called()
        group_signal.assert_not_called()
        anchor.wait.assert_not_called()

    def test_failed_group_signal_has_no_pid_fallback_or_second_wait(self):
        anchor = mock.Mock(pid=4242)
        anchor.wait.return_value = -9
        with mock.patch.object(core.os, "killpg", side_effect=PermissionError()) as group_signal:
            with mock.patch.object(core.os, "kill") as pid_signal:
                with self.assertRaises(core.ProcessFailure) as raised:
                    core._cleanup_anchor(anchor, deadline=11.0, clock=Clock(),
                                         observe=lambda child: (0, 0, 0, 0))
        group_signal.assert_called_once()
        pid_signal.assert_not_called()
        anchor.kill.assert_not_called()
        anchor.terminate.assert_not_called()
        anchor.wait.assert_called_once_with(timeout=2.0)
        self.assertEqual(raised.exception.reason, "cleanup-failed")
        self.assertEqual(raised.exception.session_disposition, "poisoned")

    def test_late_cleanup_cannot_restart_reserve(self):
        anchor = mock.Mock(pid=4242)
        with mock.patch.object(core.os, "killpg") as group_signal:
            with self.assertRaises(core.ProcessFailure):
                core._cleanup_anchor(anchor, deadline=11.0, clock=Clock(13.0),
                                     observe=lambda child: (0, 0, 0, 0))
        anchor.wait.assert_not_called()
        # Expiry does not revoke this independently observed live anchor. Safe
        # group cleanup remains necessary; a new reap budget remains forbidden.
        group_signal.assert_called_once_with(4242, 9)


class DestructorBookkeepingTests(unittest.TestCase):
    def test_actual_popen_destructor_positive_control_and_disarm(self):
        # No Popen constructor or process. Exercise the loaded runtime's real
        # destructor with its polling operation explicitly replaced.
        anchor = object.__new__(core.subprocess.Popen)
        anchor.pid = 4242
        anchor.returncode = None
        anchor._child_created = True
        anchor._internal_poll = mock.Mock()
        try:
            with mock.patch.object(core.subprocess, "_active", []) as active:
                with self.assertWarns(ResourceWarning):
                    core.subprocess.Popen.__del__(anchor)
                anchor._internal_poll.assert_called_once()
                self.assertEqual(active, [anchor])
                active.clear()  # Remove only the synthetic positive control.
                anchor._internal_poll.reset_mock()
                core._disarm_anchor(anchor)
                self.assertIsNone(anchor.returncode)
                self.assertTrue(any(item is anchor for item in core._DISARMED_ANCHORS))
                core._disarm_anchor(anchor)
                core.subprocess.Popen.__del__(anchor)
                anchor._internal_poll.assert_not_called()
                self.assertEqual(active, [])
                self.assertIsNone(anchor.returncode)
        finally:
            anchor._child_created = False
            core._DISARMED_ANCHORS[:] = [
                item for item in core._DISARMED_ANCHORS if item is not anchor]

    def test_existing_active_entry_is_not_mistaken_for_safe_disarm(self):
        anchor = mock.Mock(pid=4242, returncode=None)
        try:
            with mock.patch.object(core.subprocess, "_active", [anchor]):
                with self.assertRaises(core.ProcessFailure):
                    core._disarm_anchor(anchor)
                self.assertIsNone(anchor.returncode)
                anchor.wait.assert_not_called()
        finally:
            core._DISARMED_ANCHORS[:] = [
                item for item in core._DISARMED_ANCHORS if item is not anchor]


if __name__ == "__main__":
    unittest.main()
