"""Actual policy orchestration with explicitly mocked no-spawn session admission.

The original three old-helper REDs are preserved in private controller evidence.
These migrated regressions assert the production adapter/finalization behavior;
no child, numeric signal, descriptor read or native qualification occurs here.
"""
from pathlib import Path
import os
import subprocess
import unittest
from unittest.mock import call, patch

import test_capability_policy as fixtures
from capability_session_fixtures import RecordingProcessSession, admit_recording_session, run_recorded_trusted, process


class CapabilityProcessIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.policy = fixtures.load_module(
            fixtures.POLICY_PATH, f"capability_process_integration_{id(self)}",
            synthetic_runtime=False,
        )
        self.session = RecordingProcessSession(process)
        for owner, name in ((subprocess, "Popen"), (os, "killpg"), (os, "kill")):
            guard = patch.object(owner, name, side_effect=AssertionError("unexpected process or signal endpoint"))
            guard.start()
            self.addCleanup(guard.stop)

    def admit(self):
        return admit_recording_session(self.policy, self.session)

    def test_nonzero_reap_cannot_be_followed_by_signal_or_second_wait(self):
        policy, session = self.policy, self.admit()
        nonzero = session.failure("command-failed", status=1)
        def failed(_request):
            raise nonzero
        session.handler = failed
        with self.assertRaisesRegex(policy.PolicyError, "^synthetic-command-failed$") as caught:
            policy._run_bounded_command(
                ["/usr/bin/git", "--version"], process_session=session, role="git",
                cwd=Path("/synthetic"), environment=policy._git_environment(), timeout=10, maximum=64,
                failure="synthetic-command-failed", output_failure="synthetic-output-too-large",
            )
        self.assertEqual(len(session.requests), 1)
        self.assertIs(caught.exception.__cause__, nonzero)
        self.assertEqual(session.state, "ready")
        # Only the session owns process cleanup. No handles or signal capability
        # cross this boundary, including a completely cleaned nonzero command.

    def test_snapshot_acquisition_failure_still_finalizes_validated_checkout(self):
        policy, session = self.policy, self.admit()
        root, sha = Path("/synthetic/base"), "1" * 40
        primary = policy.PolicyError("commit-tree-invalid")
        with patch.object(policy, "_validate_checkout", return_value=root) as validate, \
             patch.object(policy.CommitSnapshot, "capture", side_effect=primary) as capture:
            with self.assertRaises(policy.PolicyError) as caught:
                policy._capture_candidate(root, sha, process_session=session)
        self.assertIs(caught.exception, primary)
        capture.assert_called_once_with(root, sha, process_session=session)
        self.assertEqual(validate.call_args_list, [call(root, sha, process_session=session)] * 2)

    def test_head_acquisition_failure_still_finalizes_acquired_base(self):
        policy, session = self.policy, self.admit()
        base = {"repository_root": Path("/synthetic/base"), "sha": "1" * 40}
        head = {"repository_root": Path("/synthetic/head"), "sha": "2" * 40}
        primary = policy.PolicyError("commit-tree-invalid")
        acquired = []
        def acquire(candidate, *, process_session, operation_roots):
            self.assertIs(process_session, session)
            acquired.append(candidate)
            if candidate is head:
                raise primary
            operation_roots.append((base["repository_root"], base["sha"]))
            return policy.CandidateDetails(base["repository_root"], base["sha"], {}, {}, {})
        with patch.object(policy, "_checked_candidate_details", side_effect=acquire), \
             patch.object(policy, "_validate_checkout") as validate:
            with self.assertRaises(policy.PolicyError) as caught:
                policy.compare_candidates(base=base, head=head, process_session=session)
        self.assertIs(caught.exception, primary)
        self.assertEqual(acquired, [base, head])
        validate.assert_called_once_with(base["repository_root"], base["sha"], process_session=session)

    def test_primary_snapshot_error_survives_final_checkout_failure(self):
        policy, session = self.policy, self.admit()
        root, sha = Path("/synthetic/base"), "1" * 40
        primary = policy.PolicyError("commit-tree-invalid")
        with patch.object(policy, "_validate_checkout", side_effect=[root, policy.PolicyError("checkout-dirty")]), \
             patch.object(policy.CommitSnapshot, "capture", side_effect=primary):
            with self.assertRaises(policy.PolicyError) as caught:
                policy._capture_candidate(root, sha, process_session=session)
        self.assertIs(caught.exception, primary)

    def test_poison_after_initial_checkout_forbids_final_git_and_preserves_primary(self):
        policy, session = self.policy, self.admit()
        root, sha = Path("/synthetic/base"), "1" * 40
        primary = policy.PolicyError("commit-tree-invalid")
        def fail(*_args, **_kwargs):
            session.state = "poisoned"
            raise primary
        with patch.object(policy, "_validate_checkout", return_value=root) as validate, \
             patch.object(policy.CommitSnapshot, "capture", side_effect=fail):
            with self.assertRaises(policy.PolicyError) as caught:
                policy._capture_candidate(root, sha, process_session=session)
        self.assertIs(caught.exception, primary)
        self.assertTrue(primary.final_validation_unavailable)
        validate.assert_called_once_with(root, sha, process_session=session)
        self.assertEqual(session.requests, [])

    def test_unavailable_final_checkout_without_primary_refuses_success(self):
        policy, session = self.policy, self.admit()
        with patch.object(policy, "_validate_checkout") as validate:
            with self.assertRaisesRegex(policy.PolicyError, "^final-checkout-unavailable$"):
                with policy._final_checkout_scope(session, [(Path("/synthetic"), "1" * 40)]):
                    session.cancelled = True
        validate.assert_not_called()

    def test_final_poison_stops_other_root_and_does_not_replace_primary(self):
        policy, session = self.policy, self.admit()
        primary = policy.PolicyError("compare-evidence-removal")
        def poison(*_args, **_kwargs):
            session.state = "poisoned"
            raise policy.PolicyError("checkout-invalid")
        roots = [(Path("/synthetic/base"), "1" * 40), (Path("/synthetic/head"), "2" * 40)]
        with patch.object(policy, "_validate_checkout", side_effect=poison) as validate:
            with self.assertRaises(policy.PolicyError) as caught:
                with policy._final_checkout_scope(session, roots):
                    raise primary
        self.assertIs(caught.exception, primary)
        self.assertTrue(primary.final_validation_unavailable)
        self.assertEqual(validate.call_count, 1)

    def test_base_failure_never_acquires_head(self):
        policy, session = self.policy, self.admit()
        primary = policy.PolicyError("checkout-invalid")
        with patch.object(policy, "_checked_candidate_details", side_effect=primary) as acquire, \
             patch.object(policy, "_validate_checkout") as validate:
            with self.assertRaises(policy.PolicyError) as caught:
                policy.compare_candidates(base={}, head={}, process_session=session)
        self.assertIs(caught.exception, primary)
        self.assertEqual(acquire.call_count, 1)
        validate.assert_not_called()

    def test_single_final_checkout_failure_records_lost_authority(self):
        policy = self.policy
        root, sha = Path("/synthetic/base"), "1" * 40
        for loss in ("poison", "cancel"):
            for primary_present in (False, True):
                with self.subTest(loss=loss, primary=primary_present):
                    self.session = RecordingProcessSession(process)
                    session = self.admit()
                    primary = policy.PolicyError("compare-evidence-removal") if primary_present else None
                    final_error = policy.PolicyError("checkout-invalid")

                    def fail(*_args, **_kwargs):
                        if loss == "poison":
                            session.state = "poisoned"
                        else:
                            session.cancelled = True
                        raise final_error

                    with patch.object(policy, "_validate_checkout", side_effect=fail) as validate:
                        with self.assertRaises(policy.PolicyError) as caught:
                            with policy._final_checkout_scope(session, [(root, sha)]):
                                if primary is not None:
                                    raise primary
                    self.assertIs(caught.exception, primary if primary is not None else final_error)
                    self.assertTrue(getattr(caught.exception, "final_validation_unavailable", False))
                    validate.assert_called_once_with(root, sha, process_session=session)
                    self.assertEqual(session.requests, [])

    def test_single_final_checkout_returning_after_cancellation_refuses_success(self):
        policy = self.policy
        root, sha = Path("/synthetic/base"), "1" * 40
        for primary_present in (False, True):
            with self.subTest(primary=primary_present):
                self.session = RecordingProcessSession(process)
                session = self.admit()
                primary = policy.PolicyError("compare-evidence-removal") if primary_present else None

                def cancel(*_args, **_kwargs):
                    session.cancelled = True
                    return root

                with patch.object(policy, "_validate_checkout", side_effect=cancel) as validate:
                    with self.assertRaises(policy.PolicyError) as caught:
                        with policy._final_checkout_scope(session, [(root, sha)]):
                            if primary is not None:
                                raise primary
                if primary is not None:
                    self.assertIs(caught.exception, primary)
                else:
                    self.assertEqual(str(caught.exception), "final-checkout-unavailable")
                self.assertTrue(getattr(caught.exception, "final_validation_unavailable", False))
                validate.assert_called_once_with(root, sha, process_session=session)
                self.assertEqual(session.requests, [])

    def test_real_admission_rejects_fake_or_missing_session_before_git(self):
        for value in (None, object(), self.session):
            with self.subTest(value=type(value).__name__), patch.object(self.policy, "_validate_checkout") as validate:
                with self.assertRaisesRegex(self.policy.PolicyError, "^process-session-unavailable$"):
                    self.policy.check_candidate(repository_root=Path("/synthetic"), sha="1" * 40, process_session=value)
                validate.assert_not_called()

    def test_direct_main_and_invalid_trusted_context_refuse_without_preparation(self):
        policy = self.policy
        args = ["check", "--repository-root", "/synthetic", "--expected-sha", "1" * 40]
        with patch.object(policy.QualifiedProcessSession, "prepare") as prepare, \
             patch.object(policy, "_validate_checkout") as validate:
            direct = fixtures.run_policy_main(policy, args)
            with patch.object(policy, "_publish_decision", side_effect=lambda value: value) as publish:
                invalid = policy.run_trusted(args, context=object())
        self.assertEqual(direct.returncode, 2)
        self.assertEqual(direct.stdout, "")
        self.assertEqual(direct.stderr, "capability-policy: process-session-unavailable\n")
        self.assertEqual(invalid.exit_code, 2)
        self.assertEqual(invalid.stdout, b"")
        prepare.assert_not_called()
        validate.assert_not_called()
        publish.assert_called_once()

    def test_close_and_cancellation_preserve_primary_and_withhold_success(self):
        policy = self.policy
        args = ["check", "--repository-root", "/synthetic", "--expected-sha", "1" * 40]
        for primary_present in (False, True):
            for close_fails in (False, True):
                with self.subTest(primary=primary_present, close_fails=close_fails):
                    self.session = RecordingProcessSession(process)
                    session = self.admit()
                    session.cancelled = True
                    if close_fails:
                        session.close_error = session.failure("cleanup-failed")
                    primary = policy.PolicyError("evidence-claims-mismatch") if primary_present else None
                    with patch.object(policy, "check_candidate", side_effect=primary, return_value={"ok": True}), \
                         patch.object(policy, "_publish_decision", side_effect=lambda value: value):
                        result = run_recorded_trusted(policy, args, session)
                    expected = "evidence-claims-mismatch" if primary_present else "process-session-unavailable"
                    self.assertEqual(result.stderr, f"capability-policy: {expected}\n".encode())
                    self.assertEqual((result.stdout, result.exit_code), (b"", 2))
                    self.assertTrue(session.close_attempted)
                    self.assertIs(result, session.decision)

    def test_finalizer_refusal_publishes_one_fixed_failure_preserving_primary(self):
        policy = self.policy
        args = ["check", "--repository-root", "/synthetic", "--expected-sha", "1" * 40]
        for primary_present in (False, True):
            with self.subTest(primary=primary_present):
                self.session = RecordingProcessSession(process)
                session = self.admit()
                primary = policy.PolicyError("evidence-claims-mismatch") if primary_present else None
                refusal = session.failure("cleanup-failed")
                escaped = None
                with patch.object(policy, "check_candidate", side_effect=primary, return_value={"ok": True}), \
                     patch.object(session, "finalize_decision", side_effect=refusal) as finalize, \
                     patch.object(policy, "_publish_decision", side_effect=lambda value: value) as publish:
                    try:
                        result = run_recorded_trusted(policy, args, session)
                    except process.ProcessFailure as error:
                        escaped = error
                self.assertTrue(session.close_attempted)
                finalize.assert_called_once()
                self.assertIsNone(escaped, "typed finalization refusal escaped the fixed diagnostic boundary")
                publish.assert_called_once_with(result)
                expected = "evidence-claims-mismatch" if primary_present else "process-session-unavailable"
                self.assertEqual(result.stderr, f"capability-policy: {expected}\n".encode())
                self.assertEqual((result.stdout, result.exit_code), (b"", 2))


if __name__ == "__main__":
    unittest.main()
