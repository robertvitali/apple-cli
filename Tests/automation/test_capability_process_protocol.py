"""Pure protocol contracts; synthetic identities confer no runtime authority."""

from dataclasses import FrozenInstanceError, replace
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch


MODULE_PATH = Path(__file__).resolve().parents[2] / "scripts/ci/capability_process_protocol.py"
NOW = 100.0
HASH = "a" * 64
NATIVE = "b" * 64
EMPTY_HASH = hashlib.sha256(b"").hexdigest()
GIT_ENV = (("GIT_CONFIG_GLOBAL", "/dev/null"), ("GIT_CONFIG_NOSYSTEM", "1"),
           ("GIT_NO_REPLACE_OBJECTS", "1"), ("GIT_OPTIONAL_LOCKS", "0"),
           ("LC_ALL", "C"), ("PATH", "/usr/bin:/bin"))
BUILD_ENV = (("HOME", "/synthetic/home"), ("LC_ALL", "C"),
             ("PATH", "/usr/bin:/bin"), ("TMPDIR", "/synthetic/tmp"))
BOOT_ENV = (("LC_ALL", "C"), ("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"))


def canonical(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True,
                       separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")


def load_module():
    spec = importlib.util.spec_from_file_location("capability_process_protocol", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class CapabilityProcessProtocolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.api = load_module()

    def identity(self, path="/synthetic/bin/git", *, mode=0o100755):
        return self.api.ExecutableIdentity(
            path=path, sha256=HASH, device=1, inode=2, size=3, mode=mode,
            uid=501, gid=20, mtime_ns=4, ctime_ns=5,
        )

    def context(self, *, bootstrap=False):
        return self.api.ProtocolContext(
            session_id="c" * 32, command_id=1, trusted_closure_sha256=HASH,
            profile_id="synthetic-inactive-v1",
            native_artifact_sha256=None if bootstrap else NATIVE,
        )

    def request(self, **changes):
        identity = self.identity()
        values = dict(role="git", executable=identity,
                      argv=(identity.path, "--version"), cwd=Path("/synthetic/candidate"),
                      environment=GIT_ENV, deadline=NOW + 10.0, maximum_output_bytes=4096)
        values.update(changes)
        return self.api.CommandRequest(**values)

    def bootstrap(self, **changes):
        values = dict(
            compiler=self.identity("/synthetic/bin/clang"),
            source=self.identity("/synthetic/input/native.c", mode=0o100444),
            sdk=self.api.SDKIdentity(path="/synthetic/projection", manifest_sha256=HASH,
                                    device=1, inode=3, mode=0o40500, uid=501, gid=20),
            cwd=Path("/synthetic/build"), environment=BOOT_ENV,
            deadline=NOW + 58.0, maximum_output_bytes=1024 * 1024,
        )
        values.update(changes)
        return self.api.BootstrapRequest(**values)

    def receipt(self, **changes):
        values = dict(outcome="success", command_status=0, stdout_bytes=0, stderr_bytes=0,
                      stdout_sha256=EMPTY_HASH, stderr_sha256=EMPTY_HASH)
        values.update(changes)
        return self.api.CommandReceipt(**values)

    def reject(self, function, *args, **kwargs):
        with self.assertRaises(self.api.ProcessFailure) as caught:
            function(*args, **kwargs)
        self.assertEqual(caught.exception.reason, "protocol-invalid")
        self.assertEqual(str(caught.exception), "protocol-invalid")

    def wire(self, request=None, context=None):
        return self.api.encode_request(request or self.request(), context=context or self.context(), now=NOW)

    def parse_wire(self, payload, *, expected=None, context=None, now=NOW):
        return self.api.parse_request(payload, expected=expected or self.request(),
                                      context=context or self.context(), now=now)

    def mutate(self, **changes):
        value = json.loads(self.wire())
        value.update(changes)
        return canonical(value)

    def test_fixed_request_round_trip_exact_fields_and_identity(self):
        request = self.request()
        frame = self.wire(request)
        value = json.loads(frame)
        self.assertEqual(frame, canonical(value))
        self.assertEqual(set(value), {"version", "role", "session_id", "command_id",
                         "trusted_closure_sha256", "profile_id", "native_artifact_sha256",
                         "executable", "argv", "cwd", "environment", "deadline",
                         "maximum_output_bytes"})
        self.assertEqual(set(value["executable"]), {"path", "sha256", "device", "inode",
                         "size", "mode", "uid", "gid", "mtime_ns", "ctime_ns"})
        self.assertEqual(value["argv"], list(request.argv))
        self.assertEqual(value["environment"], [list(pair) for pair in GIT_ENV])
        self.assertEqual(self.parse_wire(frame), request)
        with self.assertRaises(FrozenInstanceError):
            request.deadline = 999.0
        with self.assertRaises(FrozenInstanceError):
            request.executable.path = "/synthetic/other"
        with self.assertRaises(TypeError):
            self.api.CommandRequest(request.role, request.executable, request.argv,
                                    request.cwd, request.environment, request.deadline,
                                    request.maximum_output_bytes)

    def test_operational_role_budgets_and_bootstrap_exclusion(self):
        for role, allowance in (("git", 10.0), ("swift-test", 1800.0),
                                ("swift-build", 1800.0), ("swift-bin-path", 1800.0),
                                ("help-dump", 60.0)):
            with self.subTest(role=role):
                env = GIT_ENV if role == "git" else BUILD_ENV
                request = self.request(role=role, environment=env, deadline=NOW + allowance)
                self.assertEqual(self.parse_wire(self.wire(request), expected=request), request)
                self.reject(lambda: self.wire(replace(request, deadline=NOW + allowance + 0.01)))
        for role in ("compiler-bootstrap", "bats", "unknown", True, 3):
            self.reject(lambda role=role: self.wire(self.request(role=role)))

    def test_absolute_deadline_cannot_be_replaced_or_reset_by_later_now(self):
        original = self.request()
        frame = self.wire(original)
        self.assertEqual(self.parse_wire(frame, now=109.0), original)
        self.reject(self.parse_wire, frame, now=110.0)
        self.reject(self.parse_wire, frame, now=111.0)
        self.reject(self.parse_wire, self.mutate(deadline=119.0), now=109.0)
        for deadline in (NOW, NOW - 1.0, 110, True, float("nan"), float("inf"), -float("inf")):
            self.reject(lambda deadline=deadline: self.wire(self.request(deadline=deadline)))
        for now in (100, True, -1.0, float("nan"), float("inf")):
            self.reject(self.parse_wire, frame, now=now)

    def test_scalar_ranges_bool_and_correlation_mismatches_refuse(self):
        for changes in ({"version": True}, {"version": 2}, {"role": "help-dump"},
                        {"command_id": True}, {"command_id": 0}, {"command_id": 2**53},
                        {"session_id": "c" * 31}, {"session_id": "C" * 32},
                        {"trusted_closure_sha256": "d" * 64}, {"profile_id": "other"},
                        {"native_artifact_sha256": None}, {"native_artifact_sha256": "d" * 64},
                        {"maximum_output_bytes": True}, {"maximum_output_bytes": -1},
                        {"maximum_output_bytes": 64 * 1024 * 1024 + 1}, {"extra": 1}):
            with self.subTest(changes=changes):
                self.reject(self.parse_wire, self.mutate(**changes))
        for command_id in (1, 2**53 - 1):
            context = replace(self.context(), command_id=command_id)
            self.assertEqual(self.parse_wire(self.wire(context=context), context=context), self.request())
        for limit in (0, 64 * 1024 * 1024):
            request = self.request(maximum_output_bytes=limit)
            self.assertEqual(self.parse_wire(self.wire(request), expected=request), request)

    def test_full_expected_executable_argv_cwd_environment_are_bound(self):
        value = json.loads(self.wire())
        mutations = (
            {"argv": [value["executable"]["path"], "different"]},
            {"cwd": "/synthetic/other"},
            {"environment": [list(pair) for pair in GIT_ENV[:-1]] + [["PATH", "/bin"]]},
            {"executable": {**value["executable"], "inode": 99}},
            {"executable": {**value["executable"], "sha256": "d" * 64}},
        )
        for changes in mutations:
            with self.subTest(field=tuple(changes)):
                self.reject(self.parse_wire, canonical({**value, **changes}))

    def test_identity_scalar_modes_and_paths_are_validated(self):
        value = json.loads(self.wire())
        for field in ("device", "inode", "size", "mode", "uid", "gid", "mtime_ns", "ctime_ns"):
            for invalid in (True, -1, "1", [], 2**64):
                altered = {**value, "executable": {**value["executable"], field: invalid}}
                self.reject(self.parse_wire, canonical(altered))
        for changes in ({"mode": 0o100644}, {"mode": 0o40755}, {"mode": 0o120777},
                        {"path": "relative"}, {"path": "/synthetic/../bin/git"},
                        {"path": "/synthetic//bin/git"}, {"path": "/synthetic/bin/git\x00"},
                        {"sha256": "A" * 64}, {"extra": 1}):
            altered = {**value, "executable": {**value["executable"], **changes}}
            self.reject(self.parse_wire, canonical(altered))
        del value["executable"]["inode"]
        self.reject(self.parse_wire, canonical(value))

    def test_immutable_containers_and_argument_zero_match_are_required(self):
        for changes in ({"argv": ["/synthetic/bin/git"]}, {"argv": ()},
                        {"argv": ("/synthetic/other",)}, {"argv": ("/synthetic/bin/git", 1)},
                        {"environment": list(GIT_ENV)}, {"environment": tuple(list(x) for x in GIT_ENV)},
                        {"environment": tuple(reversed(GIT_ENV))},
                        {"environment": GIT_ENV + (GIT_ENV[-1],)}, {"cwd": "/synthetic/candidate"}):
            self.reject(lambda changes=changes: self.wire(self.request(**changes)))
        for field in ("argv", "environment"):
            value = json.loads(self.wire())
            value[field] = {}
            self.reject(self.parse_wire, canonical(value))

    def test_owning_role_environment_allowlist_and_exact_values(self):
        for changes in (dict(GIT_ENV, LC_ALL="other"), dict(GIT_ENV, GIT_CONFIG_NOSYSTEM="0"),
                        dict(GIT_ENV, EXTRA="value"), dict(GIT_ENV, PATH="/bin")):
            self.reject(lambda changes=changes: self.wire(self.request(environment=tuple(sorted(changes.items())))))
        for key in ("HOME", "TMPDIR", "LC_ALL", "PATH"):
            env = tuple(pair for pair in BUILD_ENV if pair[0] != key)
            self.reject(lambda env=env: self.wire(self.request(role="swift-build", environment=env)))
        for key in ("DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS"):
            env = tuple(sorted(BUILD_ENV + ((key, "/synthetic/selected"),)))
            request = self.request(role="swift-build", environment=env)
            frame = self.wire(request)
            self.assertEqual(self.parse_wire(frame, expected=request), request)
            expected = replace(request, environment=BUILD_ENV)
            self.reject(self.parse_wire, frame, expected=expected)

    def test_argv_argument_environment_value_and_cwd_byte_bounds(self):
        request = self.request(argv=("/synthetic/bin/git",) + ("x",) * 255)
        self.assertEqual(self.parse_wire(self.wire(request), expected=request), request)
        self.reject(lambda: self.wire(replace(request, argv=request.argv + ("x",))))
        for argument in ("x" * 4096, "é" * 2048):
            request = self.request(argv=("/synthetic/bin/git", argument))
            self.assertEqual(self.parse_wire(self.wire(request), expected=request), request)
            self.reject(lambda request=request: self.wire(replace(request, argv=request.argv[:-1] + (argument + "x",))))
        env = tuple(sorted(BUILD_ENV + (("TOOLCHAINS", "x" * 8192),)))
        request = self.request(role="swift-build", environment=env)
        self.assertEqual(self.parse_wire(self.wire(request), expected=request), request)
        oversized = tuple((key, value + "x" if key == "TOOLCHAINS" else value) for key, value in env)
        self.reject(lambda: self.wire(replace(request, environment=oversized)))
        cwd = Path("/" + "x" * 4095)
        request = self.request(cwd=cwd)
        self.assertEqual(self.parse_wire(self.wire(request), expected=request), request)
        self.reject(lambda: self.wire(replace(request, cwd=Path(str(cwd) + "x"))))
        for value in ("nul\x00", "bad\ud800"):
            self.reject(lambda value=value: self.wire(self.request(argv=("/synthetic/bin/git", value))))

    def test_whole_request_limit_before_json_expansion(self):
        self.assertEqual(self.api.MAX_REQUEST_BYTES, 65536)
        argv = ("/synthetic/bin/git",) + ("x" * 4096,) * 15 + ("",)
        request = self.request(argv=argv)
        padding = self.api.MAX_REQUEST_BYTES - len(self.wire(request))
        self.assertGreaterEqual(padding, 0)
        self.assertLessEqual(padding, 4096)
        request = replace(request, argv=argv[:-1] + ("x" * padding,))
        exact = self.wire(request)
        self.assertEqual(len(exact), self.api.MAX_REQUEST_BYTES)
        self.assertEqual(self.parse_wire(exact, expected=request), request)
        oversized = exact[:-1] + b" \n"
        with patch.object(self.api.json, "loads", side_effect=AssertionError("oversize JSON expanded")):
            self.reject(self.parse_wire, oversized, expected=request)
        self.reject(lambda: self.wire(replace(request, argv=request.argv[:-1] + ("x" * (padding + 1),))))

    def test_canonical_frame_rejects_duplicates_constants_and_extra_bytes(self):
        frame = self.wire()
        cases = (b"", frame[:-1], frame + b"\n", frame + b"{}\n", b"\xef\xbb\xbf" + frame,
                 b" " + frame, frame.replace(b",", b", ", 1), frame.replace(b"\n", b"\r\n"),
                 frame.replace(b'"version":1', b'"version":1,"version":1'),
                 frame.replace(b'"deadline":110.0', b'"deadline":NaN'),
                 frame.replace(b'"deadline":110.0', b'"deadline":Infinity'),
                 frame.replace(b'"command_id":1', b'"command_id":' + b"9" * 10000),
                 frame.replace(b'"deadline":110.0', b'"deadline":1e9999'),
                 frame + b"\x00", b"\xff\n", bytearray(frame), frame.decode(), None)
        for payload in cases:
            with self.subTest(payload_type=type(payload).__name__):
                self.reject(self.parse_wire, payload)
        self.reject(self.parse_wire, b"[" * 1000 + b"0" + b"]" * 1000 + b"\n")

    def test_bootstrap_has_distinct_exact_schema_and_no_artifact_or_argv(self):
        request = self.bootstrap()
        context = self.context(bootstrap=True)
        frame = self.api.encode_bootstrap_request(request, context=context, now=NOW)
        value = json.loads(frame)
        self.assertEqual(set(value), {"version", "role", "session_id", "command_id",
                         "trusted_closure_sha256", "profile_id", "compiler", "source", "sdk",
                         "cwd", "environment", "deadline", "maximum_output_bytes"})
        self.assertEqual(value["role"], "compiler-bootstrap")
        self.assertEqual(set(value["sdk"]), {"path", "manifest_sha256", "device", "inode", "mode", "uid", "gid"})
        self.assertEqual(self.api.parse_bootstrap_request(frame, expected=request, context=context, now=NOW), request)
        for changes in ({"argv": []}, {"native_artifact_sha256": NATIVE},
                        {"role": "git"}, {"maximum_output_bytes": 0},
                        {"compiler": value["source"]}, {"source": {**value["source"], "mode": 0o40500}},
                        {"sdk": {**value["sdk"], "manifest_sha256": "d" * 64}},
                        {"sdk": {**value["sdk"], "mode": 0o100444}}):
            self.reject(self.api.parse_bootstrap_request, canonical({**value, **changes}),
                        expected=request, context=context, now=NOW)
        self.reject(self.api.parse_bootstrap_request, self.wire(), expected=request, context=context, now=NOW)
        self.reject(self.parse_wire, frame)
        self.reject(self.api.encode_bootstrap_request, request, context=self.context(), now=NOW)
        self.reject(self.api.encode_request, self.request(), context=context, now=NOW)
        self.reject(self.api.parse_bootstrap_request, frame, expected=request, context=context, now=158.0)
        self.reject(self.api.parse_bootstrap_request, canonical({**value, "deadline": 167.0}),
                    expected=request, context=context, now=157.0)

    def test_receipt_round_trip_exact_schema_and_status_outcomes(self):
        request, context = self.request(), self.context()
        for outcome, status in (("success", 0), ("command-failed", 23), ("command-failed", -31),
                                ("command-failed", -1), ("command-failed", 255),
                                ("launch-failed", None), ("read-failed", None),
                                ("read-failed", 0), ("output-limit", None), ("deadline", None)):
            with self.subTest(outcome=outcome, status=status):
                receipt = self.receipt(outcome=outcome, command_status=status)
                frame = self.api.encode_receipt(receipt, request=request, context=context)
                value = json.loads(frame)
                self.assertEqual(set(value), {"version", "role", "session_id", "command_id",
                                 "trusted_closure_sha256", "profile_id", "native_artifact_sha256",
                                 "outcome", "command_status", "stdout_bytes", "stderr_bytes",
                                 "stdout_sha256", "stderr_sha256"})
                self.assertEqual(self.api.parse_receipt(frame, request=request, context=context), receipt)
                self.assertEqual(frame, canonical(value))
                self.assertNotIn("pid", value)

    def test_receipt_invalid_status_lengths_hashes_and_correlation(self):
        request, context = self.request(), self.context()
        valid = json.loads(self.api.encode_receipt(self.receipt(), request=request, context=context))
        mutations = (
            {"command_status": True}, {"command_status": False}, {"command_status": 256},
            {"command_status": -32}, {"command_status": "0"}, {"command_status": 0.0},
            {"command_status": None}, {"command_status": 1},
            {"outcome": "command-failed", "command_status": 0},
            {"outcome": "command-failed", "command_status": None},
            {"outcome": "launch-failed", "command_status": 0}, {"outcome": "other"},
            {"stdout_bytes": True}, {"stdout_bytes": -1}, {"stderr_bytes": 4097},
            {"stdout_bytes": 2049, "stderr_bytes": 2048},
            {"stdout_sha256": "A" * 64}, {"stderr_sha256": "bad"},
            {"session_id": "d" * 32}, {"command_id": 2}, {"profile_id": "other"},
            {"native_artifact_sha256": None}, {"native_artifact_sha256": "d" * 64},
            {"worker_pid": 123}, {"capture_path": "/synthetic/forbidden"},
        )
        for changes in mutations:
            with self.subTest(fields=tuple(changes)):
                self.reject(self.api.parse_receipt, canonical({**valid, **changes}), request=request, context=context)
        for name in valid:
            incomplete = {key: value for key, value in valid.items() if key != name}
            self.reject(self.api.parse_receipt, canonical(incomplete), request=request, context=context)
        receipt = self.receipt(stdout_bytes=2048, stderr_bytes=2048,
                               stdout_sha256=HASH, stderr_sha256=HASH)
        self.assertEqual(self.api.parse_receipt(self.api.encode_receipt(receipt, request=request, context=context),
                                               request=request, context=context), receipt)

    def test_receipt_byte_cap_and_exact_single_frame(self):
        request, context = self.request(), self.context()
        self.assertEqual(self.api.MAX_RECEIPT_BYTES, 4096)
        frame = self.api.encode_receipt(self.receipt(), request=request, context=context)
        for malformed in (frame[:-1], frame + b"\n", frame + frame, b" " + frame,
                          frame.replace(b'"version":1', b'"version":1,"version":1'),
                          frame.replace(b"\n", b"\r\n"), b"\xef\xbb\xbf" + frame):
            self.reject(self.api.parse_receipt, malformed, request=request, context=context)
        with patch.object(self.api.json, "loads", side_effect=AssertionError("oversize receipt expanded")):
            self.reject(self.api.parse_receipt, b"x" * 4096 + b"\n", request=request, context=context)

    def test_bootstrap_receipt_cannot_supply_artifact_authority(self):
        request, context = self.bootstrap(), self.context(bootstrap=True)
        receipt = self.receipt(outcome="command-failed", command_status=23)
        frame = self.api.encode_receipt(receipt, request=request, context=context)
        self.assertNotIn("native_artifact_sha256", json.loads(frame))
        self.assertEqual(self.api.parse_receipt(frame, request=request, context=context), receipt)
        altered = {**json.loads(frame), "native_artifact_sha256": NATIVE}
        self.reject(self.api.parse_receipt, canonical(altered), request=request, context=context)
        self.reject(self.api.parse_receipt, frame, request=self.request(), context=self.context())
        operational = self.api.encode_receipt(self.receipt(), request=self.request(), context=self.context())
        self.reject(self.api.parse_receipt, operational, request=request, context=context)

    def test_result_decision_and_failure_records_have_closed_typed_shapes(self):
        result = self.api.CommandResult(stdout=b"fixed", stderr=b"", command_status=0, cleanup_complete=True)
        decision = self.api.ProcessDecision(stdout=b"fixed", stderr=b"", exit_code=0)
        with self.assertRaises(FrozenInstanceError):
            result.stdout = b"changed"
        with self.assertRaises(FrozenInstanceError):
            decision.exit_code = 1
        for changes in ({"command_status": 1}, {"command_status": False}, {"cleanup_complete": 1},
                        {"cleanup_complete": False}, {"stdout": "text"}, {"stderr": bytearray()}):
            self.reject(lambda changes=changes: self.api.CommandResult(**{
                "stdout": b"", "stderr": b"", "command_status": 0, "cleanup_complete": True, **changes}))
        for status in (-1, 256, True, 0.0):
            self.reject(self.api.ProcessDecision, stdout=b"", stderr=b"", exit_code=status)
        reasons = ("command-failed", "output-limit", "deadline", "cancelled", "process-unavailable",
                   "ownership-lost", "protocol-invalid", "identity-drift", "cleanup-failed")
        for reason in reasons:
            failure = self.api.ProcessFailure(reason, command_status=None,
                cleanup_disposition="not-needed", session_disposition="poisoned")
            self.assertEqual(str(failure), reason)
            self.assertEqual(failure.reason, reason)
        for changes in ({"reason": "raw private error"}, {"command_status": True},
                        {"cleanup_disposition": "other"}, {"session_disposition": "ready-again"}):
            self.reject(lambda changes=changes: self.api.ProcessFailure(**{
                "reason": "protocol-invalid", "command_status": None,
                "cleanup_disposition": "not-needed", "session_disposition": "poisoned", **changes}))


if __name__ == "__main__":
    unittest.main()
