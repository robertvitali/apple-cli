"""Synthetic partial runtime inspection; no installed-runtime qualification.

Tests never call a native accessor, signal setter, child process or destructor.
Temporary reader files contain invented bytes. Source compilation/execution below
only constructs an inert synthetic class; no instance of that class is created.
"""

from __future__ import annotations

from contextlib import ExitStack
import ctypes
import errno
import hashlib
import importlib.util
import os
from pathlib import Path
import struct
import sys
import tempfile
import types
import unittest
from unittest import mock
import warnings
import _warnings
import _signal
import time

from capability_runtime_metadata_fixtures import descriptors
from test_capability_process_lifecycle import Clock, core, identity


SOURCE_PATH = "/synthetic/runtime/subprocess-source"
SOURCE = b'''import sys
import warnings
_active = []
class Popen:
    _child_created = False
    def __new__(cls, *args, **kwargs):
        raise AssertionError("synthetic class must never be instantiated")
    def __del__(self, _maxsize=sys.maxsize, _warn=warnings.warn):
        if not self._child_created:
            return
        if self.returncode is None:
            _warn("synthetic process", ResourceWarning, source=self)
        self._internal_poll(_deadstate=_maxsize)
'''


def synthetic_module(source=SOURCE):
    module = types.ModuleType("subprocess")
    module.__file__ = SOURCE_PATH
    exec(compile(source, SOURCE_PATH, "exec", dont_inherit=True, optimize=0), module.__dict__)
    return module


def image_bytes(*, file_type=6, uuid="d" * 32, vmaddr=0):
    uuid_command = struct.pack("<II", 0x1B, 24) + bytes.fromhex(uuid)
    segment = struct.pack("<II16sQQQQIIII", 0x19, 72, b"__TEXT", vmaddr,
                          4096, 0, 4096, 5, 5, 0, 0)
    commands = uuid_command + segment
    header = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, file_type,
                         2, len(commands), 0, 0)
    return header, commands


def universal_bytes(thin):
    """Two invented fat32 slices; selected arm64 row is deliberately second."""
    header = struct.pack(">II", 0xCAFEBABE, 2)
    table = struct.pack(">5I", 0x01000007, 3, 256, 64, 6)
    table += struct.pack(">5I", 0x0100000C, 0, 128, len(thin), 6)
    return header + table + b"\0" * (128 - len(header + table)) + thin + b"x" * 64


class RuntimeUniversalImageTests(unittest.TestCase):
    def decode(self, payload, *, file_type=6, uuid="d" * 32):
        expected = {"uuid": uuid, "file_type": file_type, "architecture": "arm64"}
        record = descriptors()[1]["files"][0]["identity"]
        record.update(size=len(payload), sha256=hashlib.sha256(payload).hexdigest())
        member = types.SimpleNamespace(identity=core.ExecutableIdentity(**record), payload=payload)
        return core._file_runtime_image(member, expected, 96, core._bounded_clock(Clock(), 68.0))

    def changed_row(self, payload, index, **changes):
        names = ("cpu", "subtype", "offset", "size", "align")
        position = 8 + 20 * index
        row = list(struct.unpack_from(">5I", payload, position))
        for name, value in changes.items():
            row[names.index(name)] = value
        return payload[:position] + struct.pack(">5I", *row) + payload[position + 20:]

    def test_universal_main_and_framework_match_their_thin_selected_slices(self):
        for file_type, uuid, vmaddr in ((2, "c" * 32, 0x10000), (6, "d" * 32, 0)):
            with self.subTest(file_type=file_type):
                thin = b"".join(image_bytes(file_type=file_type, uuid=uuid, vmaddr=vmaddr))
                self.assertEqual(self.decode(universal_bytes(thin), file_type=file_type, uuid=uuid),
                                 self.decode(thin, file_type=file_type, uuid=uuid))

    def test_universal_table_truncation_zero_or_excess_count_refuse(self):
        payload = universal_bytes(b"".join(image_bytes()))
        for malformed in (payload[:7], payload[:47],
                          payload[:4] + struct.pack(">I", 0) + payload[8:],
                          payload[:4] + struct.pack(">I", 0xFFFFFFFF) + payload[8:]):
            with self.subTest(size=len(malformed)):
                with self.assertRaises(core.ProcessFailure):
                    self.decode(malformed)

    def test_missing_or_duplicate_arm64_selection_refuses(self):
        payload = universal_bytes(b"".join(image_bytes()))
        for malformed in (self.changed_row(payload, 1, cpu=0x01000007),
                          self.changed_row(payload, 0, cpu=0x0100000C, subtype=0),
                          self.changed_row(payload, 1, subtype=1)):
            with self.assertRaises(core.ProcessFailure):
                self.decode(malformed)

    def test_slice_range_alignment_overlap_and_unsupported_container_refuse(self):
        payload = universal_bytes(b"".join(image_bytes()))
        for index, changes in ((1, {"offset": 32}), (1, {"offset": 129}),
                               (1, {"size": 0}), (1, {"size": 0xFFFFFFFF}),
                               (1, {"offset": 0xFFFFFFFF}), (1, {"align": 32}),
                               (0, {"offset": 128}), (0, {"size": 0xFFFFFFFF})):
            with self.subTest(index=index, fields=tuple(changes)):
                with self.assertRaises(core.ProcessFailure):
                    self.decode(self.changed_row(payload, index, **changes))
        for magic in (0xBEBAFECA, 0xCAFEBABF):
            with self.assertRaises(core.ProcessFailure):
                self.decode(struct.pack(">I", magic) + payload[4:])

    def test_load_commands_cannot_cross_selected_slice_into_other_bytes(self):
        payload = universal_bytes(b"".join(image_bytes()))
        # Full valid bytes remain in the container, but selected ownership ends
        # before its final command. A whole-container extent check is inadequate.
        malformed = self.changed_row(payload, 1, size=120)
        with self.assertRaises(core.ProcessFailure):
            self.decode(malformed)


class BuiltinAttemptGuard:
    """First-attempt witness, not a sandbox or retry containment mechanism.

    CPython3.9.6 ceval.c C_TRACE calls the profiler before the C function and
    skips that call on profiler error. sys.setprofile documents that an error
    unsets profiling. Subject inspection must therefore refuse without retry.
    https://github.com/python/cpython/blob/v3.9.6/Python/ceval.c#L4655-L4663
    https://docs.python.org/3.9/library/sys.html#sys.setprofile
    """
    def __init__(self, forbidden):
        self.forbidden = tuple(forbidden)
        self.attempts = []
        self.previous = None

    def __enter__(self):
        self.previous = sys.getprofile()
        sys.setprofile(self.profile)
        return self

    def profile(self, frame, event, argument):
        if event == "c_call" and any(argument is value for value in self.forbidden):
            self.attempts.append(argument.__name__)
            raise AssertionError("forbidden builtin invocation")
        if self.previous is not None:
            self.previous(frame, event, argument)

    def __exit__(self, *unused):
        sys.setprofile(self.previous)


class BuiltinAttemptGuardTests(unittest.TestCase):
    def test_harmless_builtin_attempt_is_recorded_before_its_mutation(self):
        values = []
        target = values.append
        previous = sys.getprofile()
        with BuiltinAttemptGuard((target,)) as guard:
            with self.assertRaisesRegex(AssertionError, "forbidden builtin invocation"):
                target("synthetic marker")
            self.assertEqual(values, [])
            self.assertEqual(guard.attempts, ["append"])
            # Explicitly witness why this is not a containment guarantee.
            self.assertIsNone(sys.getprofile())
        self.assertIs(sys.getprofile(), previous)

    def test_previous_profiler_is_restored_after_normal_and_exceptional_exit(self):
        original = sys.getprofile()
        events = []
        def prior(frame, event, argument):
            if event == "c_call" and argument is len:
                events.append("len")
        try:
            sys.setprofile(prior)
            with BuiltinAttemptGuard(()) as guard:
                self.assertEqual(len(()), 0)
            self.assertIs(sys.getprofile(), prior)
            self.assertEqual(guard.attempts, [])
            self.assertTrue(events)
            with self.assertRaisesRegex(ValueError, "synthetic failure"):
                with BuiltinAttemptGuard(()):
                    raise ValueError("synthetic failure")
            self.assertIs(sys.getprofile(), prior)
        finally:
            sys.setprofile(original)


class BindingFixture(unittest.TestCase):
    def api(self, name):
        operation = getattr(core, name, None)
        self.assertTrue(callable(operation), "missing partial inspection API: " + name)
        return operation

    def setUp(self):
        self.clock = Clock(12.0)
        self.deadline = 68.0
        self.limits = descriptors()[1]["limits"]
        # The synthetic method has more descriptor nodes than the intentionally
        # small metadata example. These remain fixture bounds, not host pins.
        self.limits.update(code_nodes=4096, code_depth=16, code_bytes=65536)
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.popen = self.stack.enter_context(mock.patch.object(core.subprocess, "Popen",
            side_effect=AssertionError("unexpected child process")))
        self.reset = self.stack.enter_context(mock.patch.object(core.signal, "signal",
            side_effect=AssertionError("unexpected signal reset")))
        self.stack.enter_context(mock.patch.object(core.os, "kill",
            side_effect=AssertionError("unexpected PID signal")))
        self.stack.enter_context(mock.patch.object(core.os, "killpg",
            side_effect=AssertionError("unexpected group signal")))
        # The Python signal.signal spy does not cover the distinct C builtin.
        # Preserve actual builtin identities and reject any recorded attempt,
        # even if subject code converts the guard exception to ProcessFailure.
        guard = BuiltinAttemptGuard((_signal.signal, time.clock_gettime))
        guard.__enter__()
        def restore_profile():
            guard.__exit__()
            self.assertEqual(guard.attempts, [])
        self.addCleanup(restore_profile)

    def checkpoint(self):
        return core._bounded_clock(self.clock, self.deadline)

    def source_record(self):
        record = next(row["identity"] for row in descriptors()[1]["files"]
                      if row["id"] == "subprocess-source")
        record.update(size=len(SOURCE), sha256=hashlib.sha256(SOURCE).hexdigest())
        return types.SimpleNamespace(identity=core.ExecutableIdentity(**record), payload=SOURCE)

    def bind(self, module):
        operation = self.api("_bind_popen_body")
        # Patch only the module registry observation, never the body comparison.
        with mock.patch.dict(sys.modules, {"subprocess": module}):
            return operation(self.source_record(), module, limits=self.limits,
                             checkpoint=self.checkpoint())


class RuntimeImageParserTests(BindingFixture):
    def decode(self, header, commands, *, maximum_bytes=96):
        return self.api("_decode_runtime_image")(header, commands,
            expected={"uuid": "d" * 32, "file_type": 6, "architecture": "arm64"},
            maximum_bytes=maximum_bytes, checkpoint=self.checkpoint())

    def test_exact_synthetic_image_has_immutable_identity_facts(self):
        result = self.decode(*image_bytes())
        self.assertEqual(result["uuid"], "d" * 32)
        self.assertEqual(result["file_type"], 6)
        self.assertEqual(result["architecture"], "arm64")
        self.assertEqual(result["text_vmaddr"], 0)
        with self.assertRaises(TypeError):
            result["uuid"] = "0" * 32

    def test_header_and_command_extent_refusals(self):
        self.api("_decode_runtime_image")
        header, commands = image_bytes()
        for head, body in ((header[:-1], commands), (header + b"x", commands),
                           (header, commands[:-1]), (header, commands + b"x")):
            with self.subTest(header_size=len(head), command_size=len(body)):
                with self.assertRaises(core.ProcessFailure):
                    self.decode(head, body)

    def test_architecture_type_and_command_header_mismatch_refusals(self):
        self.api("_decode_runtime_image")
        header, commands = image_bytes()
        for word, value in ((0, 0), (1, 0x01000007), (2, 1), (3, 2), (4, 0), (4, 99)):
            with self.subTest(word=word):
                words = list(struct.unpack("<8I", header))
                words[word] = value
                with self.assertRaises(core.ProcessFailure):
                    self.decode(struct.pack("<8I", *words), commands)
        for size in (0, 7, 23, 104):
            with self.subTest(command_size=size):
                body = commands[:4] + struct.pack("<I", size) + commands[8:]
                with self.assertRaises(core.ProcessFailure):
                    self.decode(header, body)

    def test_duplicate_or_missing_uuid_and_text_segment_refuse(self):
        self.api("_decode_runtime_image")
        header, commands = image_bytes()
        for body in (commands[:24] * 2, commands[24:] * 2):
            words = list(struct.unpack("<8I", header))
            words[5] = len(body)
            with self.subTest(body_size=len(body)):
                with self.assertRaises(core.ProcessFailure):
                    self.decode(struct.pack("<8I", *words), body, maximum_bytes=144)

    def test_wrong_uuid_and_framework_vmaddr_refuse(self):
        self.api("_decode_runtime_image")
        for arguments in ({"uuid": "c" * 32}, {"vmaddr": 4096}):
            with self.subTest(changed=next(iter(arguments))):
                with self.assertRaises(core.ProcessFailure):
                    self.decode(*image_bytes(**arguments))

    def test_command_byte_bound_is_exact_and_independent_of_declared_size(self):
        self.api("_decode_runtime_image")
        header, commands = image_bytes()
        self.decode(header, commands, maximum_bytes=96)
        with self.assertRaises(core.ProcessFailure):
            self.decode(header, commands, maximum_bytes=95)

    def test_parser_checks_original_deadline_before_return(self):
        self.api("_decode_runtime_image")
        readings = []
        def clock():
            readings.append(True)
            return 12.0 if len(readings) == 1 else 68.0
        self.clock = clock
        with self.assertRaises(core.ProcessFailure):
            self.decode(*image_bytes())
        self.assertGreaterEqual(len(readings), 2)


class RuntimeMemberReaderTests(BindingFixture):
    def make_member(self):
        directory = tempfile.TemporaryDirectory(prefix="capability-runtime-member-")
        self.addCleanup(directory.cleanup)
        path = Path(directory.name).resolve() / "synthetic-member"
        path.write_bytes(b"synthetic runtime member\n")
        return path, identity(path)

    def test_reader_uses_pinned_bytes_and_closes_actual_allocated_descriptor(self):
        operation = self.api("_read_runtime_member")
        path, expected = self.make_member()
        original_open, original_close = os.open, os.close
        opened, closed = [], []
        def open_member(value, flags, *args, **kwargs):
            descriptor = original_open(value, flags, *args, **kwargs)
            opened.append((descriptor, flags))
            return descriptor
        def close(descriptor):
            closed.append(descriptor)
            return original_close(descriptor)
        with mock.patch.object(core.os, "open", side_effect=open_member):
            with mock.patch.object(core.os, "close", side_effect=close):
                result = operation(expected, maximum_bytes=expected.size, retain=True,
                                   checkpoint=self.checkpoint())
        self.assertEqual(result.identity, expected)
        self.assertEqual(result.payload, b"synthetic runtime member\n")
        self.assertTrue(opened)
        self.assertEqual(sorted(fd for fd, _ in opened), sorted(closed))
        for descriptor, flags in opened:
            self.assertTrue(flags & os.O_NOFOLLOW)
            self.assertTrue(flags & os.O_NONBLOCK)
            with self.assertRaises(OSError) as raised:
                os.fstat(descriptor)
            self.assertEqual(raised.exception.errno, errno.EBADF)

    def test_changed_identity_and_excess_size_refuse(self):
        operation = self.api("_read_runtime_member")
        path, expected = self.make_member()
        with self.assertRaises(core.ProcessFailure):
            operation(expected, maximum_bytes=expected.size - 1, retain=True,
                      checkpoint=self.checkpoint())
        path.write_bytes(b"different synthetic bytes\n")
        with self.assertRaises(core.ProcessFailure):
            operation(expected, maximum_bytes=4096, retain=True, checkpoint=self.checkpoint())

    def test_close_returning_late_cannot_admit_verified_member(self):
        operation = self.api("_read_runtime_member")
        _, expected = self.make_member()
        original = os.close
        closed = []
        def close(descriptor):
            original(descriptor)
            closed.append(descriptor)
            self.clock.now = 68.0
        with mock.patch.object(core.os, "close", side_effect=close):
            with self.assertRaises(core.ProcessFailure):
                operation(expected, maximum_bytes=4096, retain=True, checkpoint=self.checkpoint())
        self.assertTrue(closed)

    def test_close_uncertainty_refuses_without_repeating_close(self):
        operation = self.api("_read_runtime_member")
        _, expected = self.make_member()
        original = os.close
        closed = []
        def close(descriptor):
            original(descriptor)
            closed.append(descriptor)
            raise OSError(errno.EIO, "synthetic close uncertainty")
        with mock.patch.object(core.os, "close", side_effect=close):
            with self.assertRaises(core.ProcessFailure):
                operation(expected, maximum_bytes=4096, retain=True, checkpoint=self.checkpoint())
        self.assertEqual(len(closed), len(set(closed)))
        self.assertTrue(closed)

    def test_read_error_closes_every_actual_allocated_descriptor(self):
        operation = self.api("_read_runtime_member")
        _, expected = self.make_member()
        original_open, original_close = os.open, os.close
        opened, closed = [], []
        def open_member(*arguments, **keywords):
            descriptor = original_open(*arguments, **keywords)
            opened.append(descriptor)
            return descriptor
        def close(descriptor):
            original_close(descriptor)
            closed.append(descriptor)
        with mock.patch.object(core.os, "open", side_effect=open_member):
            with mock.patch.object(core.os, "close", side_effect=close):
                with mock.patch.object(core.os, "read", side_effect=OSError(errno.EIO, "synthetic read")) as read:
                    with self.assertRaises(core.ProcessFailure):
                        operation(expected, maximum_bytes=4096, retain=True, checkpoint=self.checkpoint())
        self.assertTrue(opened)
        read.assert_called()
        self.assertEqual(opened, closed)
        for descriptor in opened:
            with self.assertRaises(OSError) as raised:
                os.fstat(descriptor)
            self.assertEqual(raised.exception.errno, errno.EBADF)


class PopenBodyBindingTests(BindingFixture):
    def test_exact_synthetic_body_is_bound_without_instantiation_or_reference_execution(self):
        self.api("_bind_popen_body")
        module = synthetic_module()
        with mock.patch("builtins.exec", side_effect=AssertionError("reference executed")):
            bound = self.bind(module)
        self.assertIsNotNone(bound)
        self.assertEqual(module._active, [])
        self.popen.assert_not_called()
        self.reset.assert_not_called()

    def test_changed_body_with_same_names_and_filename_refuses(self):
        self.api("_bind_popen_body")
        module = synthetic_module(SOURCE.replace(b"if not self._child_created:",
                                                 b"if self._child_created:"))
        self.assertEqual(module.Popen.__del__.__code__.co_filename, SOURCE_PATH)
        with self.assertRaises(core.ProcessFailure):
            self.bind(module)

    def test_initial_default_tuple_shape_type_and_bindings_refuse(self):
        self.api("_bind_popen_body")
        for defaults in (None, (), (sys.maxsize,), (True, warnings.warn),
                         (0, warnings.warn), (sys.maxsize, lambda *args: None)):
            with self.subTest(size=None if defaults is None else len(defaults)):
                module = synthetic_module()
                module.Popen.__del__.__defaults__ = defaults
                with self.assertRaises(core.ProcessFailure):
                    self.bind(module)

    def test_equal_maxsize_value_from_a_different_object_refuses(self):
        self.api("_bind_popen_body")
        module = synthetic_module()
        replacement = int(str(sys.maxsize))
        self.assertEqual(replacement, sys.maxsize)
        self.assertIsNot(replacement, sys.maxsize)
        module.Popen.__del__.__defaults__ = (replacement, warnings.warn)
        with self.assertRaises(core.ProcessFailure):
            self.bind(module)

    def test_wrong_globals_modules_or_nonempty_active_refuse(self):
        self.api("_bind_popen_body")
        for drift in ("sys", "warnings", "active", "active-type"):
            with self.subTest(drift=drift):
                module = synthetic_module()
                if drift == "sys":
                    module.sys = types.SimpleNamespace(maxsize=sys.maxsize)
                elif drift == "warnings":
                    module.warnings = types.SimpleNamespace(warn=_warnings.warn)
                elif drift == "active":
                    module._active.append(object())
                else:
                    module._active = ()
                with self.assertRaises(core.ProcessFailure):
                    self.bind(module)

    def test_class_lookup_override_and_subclass_refuse(self):
        self.api("_bind_popen_body")
        for drift in ("lookup", "subclass", "child-descriptor"):
            with self.subTest(drift=drift):
                module = synthetic_module()
                if drift == "lookup":
                    module.Popen.__getattribute__ = lambda self, name: object.__getattribute__(self, name)
                elif drift == "subclass":
                    module.Popen = type("Popen", (module.Popen,), {})
                else:
                    module.Popen._child_created = property(lambda self: False)
                with self.assertRaises(core.ProcessFailure):
                    self.bind(module)

    def test_class_lookup_descriptors_are_refused_without_invoking_them(self):
        self.api("_bind_popen_body")
        for name in ("__getattribute__", "__setattr__"):
            calls = []
            class LookupTrap:
                def __get__(self, instance, owner):
                    calls.append("invoked")
                    return getattr(object, name)
            module = synthetic_module()
            setattr(module.Popen, name, LookupTrap())
            refused = False
            try:
                self.bind(module)
            except core.ProcessFailure:
                refused = True
            with self.subTest(name=name, requirement="no descriptor invocation"):
                self.assertEqual(calls, [])
            with self.subTest(name=name, requirement="refusal"):
                self.assertTrue(refused)

    def test_body_traversal_after_reference_compile_returning_late_refuses(self):
        self.api("_bind_popen_body")
        shape = self.api("_popen_code_shape")
        module = synthetic_module()
        traversed = []
        def late_shape(*args, **kwargs):
            value = shape(*args, **kwargs)
            traversed.append(True)
            self.clock.now = 68.0
            return value
        # Keep the actual compile builtin intact. Reference compilation and
        # descriptor traversal still run; only their return boundary advances D.
        with mock.patch.object(core, "_popen_code_shape", side_effect=late_shape):
            with self.assertRaises(core.ProcessFailure):
                self.bind(module)
        self.assertTrue(traversed)

    def test_ambiguous_reference_class_or_method_refuses(self):
        self.api("_bind_popen_body")
        for addition in (b'\nclass Popen:\n    pass\n',
                         b'    def __del__(self):\n        return\n'):
            with self.subTest(addition_size=len(addition)):
                record = self.source_record()
                record.payload = SOURCE + addition
                record.identity = core.ExecutableIdentity(**dict(
                    vars(record.identity), size=len(record.payload),
                    sha256=hashlib.sha256(record.payload).hexdigest()))
                module = synthetic_module()
                with mock.patch.object(self, "source_record", return_value=record):
                    with self.assertRaises(core.ProcessFailure):
                        self.bind(module)


class PopenCodeShapeTests(BindingFixture):
    def shape(self, code, *, limits=None):
        return self.api("_popen_code_shape")(code, limits=self.limits if limits is None else limits,
                                            checkpoint=self.checkpoint())

    def test_independent_identical_compilations_have_equal_descriptors(self):
        self.api("_popen_code_shape")
        first = synthetic_module().Popen.__del__.__code__
        second = synthetic_module().Popen.__del__.__code__
        self.assertIsNot(first, second)
        self.assertEqual(self.shape(first), self.shape(second))

    def test_names_flags_lines_constants_and_code_changes_affect_descriptor(self):
        self.api("_popen_code_shape")
        code = synthetic_module().Popen.__del__.__code__
        original = self.shape(code)
        for change in ({"co_filename": "/synthetic/other.py"},
                       {"co_firstlineno": code.co_firstlineno + 1},
                       {"co_name": "different"}, {"co_flags": code.co_flags ^ 0x20},
                       {"co_consts": code.co_consts + ("additional",)},
                       {"co_argcount": code.co_argcount - 1},
                       {"co_posonlyargcount": 1},
                       {"co_kwonlyargcount": 1, "co_nlocals": code.co_nlocals + 1,
                        "co_varnames": code.co_varnames + ("additional",)},
                       {"co_stacksize": code.co_stacksize + 1},
                       {"co_names": code.co_names + ("additional",)},
                       {"co_freevars": code.co_freevars + ("additional",)},
                       {"co_cellvars": code.co_cellvars + ("additional",)},
                       {"co_nlocals": code.co_nlocals + 1,
                        "co_varnames": code.co_varnames + ("additional",)}):
            with self.subTest(field=next(iter(change))):
                altered = code.replace(**change)
                for field in change:
                    self.assertNotEqual(getattr(altered, field), getattr(code, field))
                self.assertNotEqual(self.shape(altered), original)

    def test_code_node_depth_and_byte_limits_refuse(self):
        self.api("_popen_code_shape")
        code = synthetic_module().Popen.__del__.__code__
        for key in ("code_nodes", "code_depth", "code_bytes"):
            with self.subTest(limit=key):
                limits = dict(self.limits, **{key: 1})
                with self.assertRaises(core.ProcessFailure):
                    self.shape(code, limits=limits)

    def test_bytecode_and_selected_line_table_bytes_affect_descriptor(self):
        self.api("_popen_code_shape")
        code = synthetic_module().Popen.__del__.__code__
        original = self.shape(code)
        # Appended bytes are inspected only, never executed as a function.
        self.assertNotEqual(self.shape(code.replace(co_code=code.co_code + b"\x09\x00")), original)
        # CodeType.replace uses lnotab on3.9 and linetable on newer test hosts.
        # Both controls require the selected co_lnotab observation to change.
        if sys.version_info[:2] == (3, 9):
            altered = code.replace(co_lnotab=code.co_lnotab + b"\x02\x01")
        else:
            altered = code.replace(co_linetable=b"")
        self.assertNotEqual(altered.co_lnotab, code.co_lnotab)
        self.assertNotEqual(self.shape(altered), original)

    def test_unsupported_constant_type_refuses(self):
        self.api("_popen_code_shape")
        code = synthetic_module().Popen.__del__.__code__
        with self.assertRaises(core.ProcessFailure):
            self.shape(code.replace(co_consts=code.co_consts + (frozenset({1}),)))

    def test_traversal_checks_same_deadline(self):
        self.api("_popen_code_shape")
        code = synthetic_module().Popen.__del__.__code__
        readings = []
        def clock():
            readings.append(True)
            return 12.0 if len(readings) <= 2 else 68.0
        self.clock = clock
        with self.assertRaises(core.ProcessFailure):
            self.shape(code)
        self.assertGreaterEqual(len(readings), 3)


class Symbol:
    """Python-only fake: a numeric address never becomes a native call."""
    def __init__(self, name, address, callback=None):
        self.name, self.address, self.callback = name, address, callback
        self.argtypes = self.restype = None
        self.calls = []

    def __call__(self, *arguments):
        if self.argtypes is None or self.restype is None:
            raise AssertionError("accessor invoked before declaration")
        self.calls.append(arguments)
        if self.callback is None:
            raise AssertionError("non-accessor symbol invoked")
        return self.callback(*arguments)


class NativeMemory:
    """Finite invented address space; unknown/out-of-range reads are assertions."""
    MAIN = 0x10000
    FRAMEWORK = 0x20000
    MAIN_NAME = 0x30000
    FRAMEWORK_NAME = 0x31000

    def __init__(self):
        main = image_bytes(file_type=2, uuid="c" * 32, vmaddr=self.MAIN)
        framework = image_bytes()
        self.memory = {self.MAIN: b"".join(main),
                       self.FRAMEWORK: b"".join(framework),
                       self.MAIN_NAME: b"/synthetic/runtime/main\0",
                       self.FRAMEWORK_NAME: b"/synthetic/runtime/framework\0"}
        self.reads, self.loads = [], []
        self.getter_offset, self.wrapper_offset, self.helper_offset = 128, 256, 384
        self.framework_base = self.FRAMEWORK
        self.clock_function = time.clock_gettime
        self.reset_function = _signal.signal
        self.getter = Symbol("PyCFunction_GetFunction", self.FRAMEWORK + 128, self.get_function)
        self.helper = Symbol("PyOS_setsig", self.FRAMEWORK + 384)
        self.loader = types.SimpleNamespace(
            dladdr=Symbol("dladdr", 0x40000, self.dladdr),
            _dyld_get_image_name=Symbol("name", 0x40010, lambda index: self.MAIN_NAME),
            _dyld_get_image_header=Symbol("header", 0x40020, lambda index: self.MAIN))
        # A CDLL getter is deliberately a trap: the Python API must retain GIL.
        self.loader.PyCFunction_GetFunction = Symbol("wrong getter", 0x40030)
        self.loader.PyOS_setsig = self.helper
        self.python_api = types.SimpleNamespace(PyCFunction_GetFunction=self.getter,
                                                PyOS_setsig=self.helper)

    def get_function(self, function):
        function = getattr(function, "value", function)
        if function is self.reset_function:
            return self.FRAMEWORK + self.wrapper_offset
        if function is self.clock_function:
            return self.FRAMEWORK + 512
        raise AssertionError("unapproved callable reached getter")

    def dladdr(self, address, destination):
        address = getattr(address, "value", address)
        target = destination._obj
        target.dli_fname = self.FRAMEWORK_NAME
        target.dli_fbase = self.framework_base
        target.dli_sname = 0
        target.dli_saddr = address
        return 1

    def cast(self, value, target):
        if not isinstance(value, Symbol) or target is not ctypes.c_void_p:
            raise AssertionError("unexpected pointer conversion")
        address = value.address
        if value is self.getter:
            address = self.FRAMEWORK + self.getter_offset
        if value is self.helper:
            address = self.FRAMEWORK + self.helper_offset
        return types.SimpleNamespace(value=address)

    def read(self, address, size):
        address = getattr(address, "value", address)
        if type(address) is not int or type(size) is not int or size < 0:
            raise AssertionError("unbounded pointer read")
        self.reads.append((address, size))
        for start, data in self.memory.items():
            if start <= address and address + size <= start + len(data):
                return data[address - start:address - start + size]
        raise AssertionError("pointer read outside synthetic memory")

    def install(self, stack):
        def load(kind, name, *arguments, **keywords):
            if name is not None or arguments or keywords:
                raise AssertionError("unexpected native namespace selection")
            self.loads.append(kind)
            return self.python_api if kind == "PyDLL" else self.loader
        stack.enter_context(mock.patch.object(ctypes, "CDLL", side_effect=lambda *a, **k: load("CDLL", *a, **k)))
        stack.enter_context(mock.patch.object(ctypes, "PyDLL", side_effect=lambda *a, **k: load("PyDLL", *a, **k)))
        stack.enter_context(mock.patch.object(ctypes, "cast", side_effect=self.cast))
        stack.enter_context(mock.patch.object(ctypes, "string_at", side_effect=self.read))


class AccessorBindingTests(BindingFixture):
    def observe(self, memory):
        operation = self.api("_observe_runtime_images")
        platform, runtime = descriptors()
        runtime["limits"] = dict(self.limits)
        records = {}
        for row in runtime["files"]:
            # Expected file bytes remain intact when loaded-memory tests mutate
            # their independent observations: the comparison must detect drift.
            if row["id"] == "main":
                payload = b"".join(image_bytes(file_type=2, uuid="c" * 32, vmaddr=memory.MAIN))
            elif row["id"] == "framework":
                payload = b"".join(image_bytes())
            else:
                payload = b"synthetic selected member\n"
            row["identity"].update(size=len(payload), sha256=hashlib.sha256(payload).hexdigest())
            records[row["id"]] = types.SimpleNamespace(
                identity=core.ExecutableIdentity(**row["identity"]), payload=payload)
        metadata = core._admit_runtime_metadata(platform, runtime, deadline=self.deadline, clock=self.clock)
        with ExitStack() as stack:
            memory.install(stack)
            stack.enter_context(mock.patch.object(sys, "executable", "/synthetic/runtime/launcher"))
            return operation(metadata, records, checkpoint=self.checkpoint())

    def test_exact_declarations_do_not_invoke_accessors(self):
        operation = self.api("_declare_runtime_loader")
        memory = NativeMemory()
        operation(memory.loader, memory.python_api)
        self.assertEqual(memory.loader.dladdr.argtypes[0], ctypes.c_void_p)
        pointer = memory.loader.dladdr.argtypes[1]
        self.assertEqual([field[1] for field in pointer._type_._fields_], [ctypes.c_void_p] * 4)
        self.assertIs(memory.loader.dladdr.restype, ctypes.c_int)
        for symbol in (memory.loader._dyld_get_image_name, memory.loader._dyld_get_image_header):
            self.assertEqual(symbol.argtypes, [ctypes.c_uint32])
            self.assertIs(symbol.restype, ctypes.c_void_p)
        self.assertEqual(memory.getter.argtypes, [ctypes.py_object])
        self.assertIs(memory.getter.restype, ctypes.c_void_p)
        for symbol in vars(memory.loader).values():
            self.assertEqual(symbol.calls, [])
        self.assertEqual(memory.getter.calls, [])

    def test_synthetic_image_observation_uses_pydll_and_never_calls_reset_helper(self):
        self.api("_observe_runtime_images")
        memory = NativeMemory()
        self.assertIsNotNone(self.observe(memory))
        self.assertIn("PyDLL", memory.loads)
        self.assertTrue(memory.getter.calls)
        self.assertEqual(memory.loader.PyCFunction_GetFunction.calls, [])
        self.assertEqual(memory.helper.calls, [])
        self.assertTrue(memory.reads)

    def test_getter_image_offset_is_checked_before_getter_invocation(self):
        self.api("_observe_runtime_images")
        memory = NativeMemory()
        memory.getter_offset += 1
        with self.assertRaises(core.ProcessFailure):
            self.observe(memory)
        self.assertEqual(memory.getter.calls, [])

    def test_path_base_uuid_and_wrapper_helper_offset_drift_refuse(self):
        self.api("_observe_runtime_images")
        for drift in ("main-path", "framework-path", "base", "uuid", "wrapper", "helper"):
            with self.subTest(drift=drift):
                memory = NativeMemory()
                if drift == "main-path":
                    memory.memory[memory.MAIN_NAME] = b"/synthetic/runtime/other\0"
                elif drift == "framework-path":
                    memory.memory[memory.FRAMEWORK_NAME] = b"/synthetic/runtime/other\0"
                elif drift == "base":
                    memory.framework_base = 0
                elif drift == "uuid":
                    memory.memory[memory.FRAMEWORK] = b"".join(image_bytes(uuid="e" * 32))
                elif drift == "wrapper":
                    memory.wrapper_offset += 1
                else:
                    memory.helper_offset += 1
                with self.assertRaises(core.ProcessFailure):
                    self.observe(memory)

    def test_invalid_header_prevents_following_body_dereference(self):
        self.api("_observe_runtime_images")
        for change in ("short", "magic", "count", "extent"):
            with self.subTest(change=change):
                memory = NativeMemory()
                header, commands = image_bytes(file_type=2, uuid="c" * 32, vmaddr=memory.MAIN)
                if change == "short":
                    original = memory.read
                    def short(address, size):
                        data = original(address, size)
                        return data[:-1] if address == memory.MAIN and size == 32 else data
                    memory.read = short
                else:
                    words = list(struct.unpack("<8I", header))
                    words[{"magic": 0, "count": 4, "extent": 5}[change]] = 0xFFFFFFFF
                    memory.memory[memory.MAIN] = struct.pack("<8I", *words) + commands
                with self.assertRaises(core.ProcessFailure):
                    self.observe(memory)
                self.assertFalse(any(address == memory.MAIN + 32 for address, _ in memory.reads))

    def test_nonbuiltin_reset_is_rejected_before_getter_call(self):
        self.api("_observe_runtime_images")
        memory = NativeMemory()
        with mock.patch.object(_signal, "signal", lambda *args: None):
            with self.assertRaises(core.ProcessFailure):
                self.observe(memory)
        self.assertEqual(memory.getter.calls, [])

    def test_null_main_pointer_is_not_dereferenced(self):
        self.api("_observe_runtime_images")
        memory = NativeMemory()
        memory.loader._dyld_get_image_header.callback = lambda index: 0
        with self.assertRaises(core.ProcessFailure):
            self.observe(memory)
        self.assertFalse(any(address == 0 for address, _ in memory.reads))

    def test_pointer_addition_overflow_refuses_before_load_command_read(self):
        self.api("_observe_runtime_images")
        memory = NativeMemory()
        address = 2**64 - 16
        memory.loader._dyld_get_image_header.callback = lambda index: address
        memory.memory[address] = image_bytes(file_type=2, uuid="c" * 32)[0]
        with self.assertRaises(core.ProcessFailure):
            self.observe(memory)
        self.assertFalse(any(start >= 2**64 for start, _ in memory.reads))
        self.assertFalse(any(start == address + 32 for start, _ in memory.reads))


class PartialRuntimeBindingTests(BindingFixture):
    """Real inspection decisions, mocked file bytes/native accessors only.

    Synthetic interpreter attributes describe the supported record shape. They
    do not assert that the test interpreter is that installed runtime. No
    source/cache/extension loading proof is supplied or fabricated.
    """
    def install_process(self):
        self.api("_inspect_runtime_bindings")
        self.api("_read_runtime_member")
        self.memory = NativeMemory()
        self.module = synthetic_module()
        platform, runtime = descriptors()
        runtime["limits"] = dict(self.limits)
        self.members = {}
        for row in runtime["files"]:
            name = row["id"]
            if name == "subprocess-source":
                payload = SOURCE
            elif name == "main":
                payload = self.memory.memory[self.memory.MAIN]
            elif name == "framework":
                payload = self.memory.memory[self.memory.FRAMEWORK]
            else:
                payload = b"synthetic selected member\n"
            row["identity"].update(size=len(payload), sha256=hashlib.sha256(payload).hexdigest())
            self.members[row["identity"]["path"]] = types.SimpleNamespace(
                identity=core.ExecutableIdentity(**row["identity"]), payload=payload)
        self.metadata = core._admit_runtime_metadata(platform, runtime,
            deadline=self.deadline, clock=self.clock)
        self.memory.install(self.stack)
        self.stack.enter_context(mock.patch.dict(sys.modules, {"subprocess": self.module}))
        self.stack.enter_context(mock.patch.object(core, "subprocess", self.module))
        self.stack.enter_context(mock.patch.object(sys, "executable", "/synthetic/runtime/launcher"))
        self.stack.enter_context(mock.patch.object(sys, "version_info", (3, 9, 6, "final", 0)))
        self.stack.enter_context(mock.patch.object(sys, "implementation", types.SimpleNamespace(
            name="cpython", cache_tag="cpython-39", version=(3, 9, 6, "final", 0))))
        self.stack.enter_context(mock.patch.object(sys, "flags", types.SimpleNamespace(
            isolated=1, no_site=1, dont_write_bytecode=1, ignore_environment=1, optimize=0)))
        self.stack.enter_context(mock.patch.object(sys, "dont_write_bytecode", True))
        self.stack.enter_context(mock.patch.object(importlib.util, "MAGIC_NUMBER", bytes.fromhex("11223344")))
        self.stack.enter_context(mock.patch.object(time, "CLOCK_UPTIME_RAW", 8, create=True))
        self.reads = []
        def read(expected, *, maximum_bytes, retain, checkpoint):
            checkpoint()
            self.reads.append(expected.path)
            record = self.members[expected.path]
            self.assertEqual(expected, record.identity)
            self.assertLessEqual(record.identity.size, maximum_bytes)
            checkpoint()
            return types.SimpleNamespace(identity=record.identity,
                payload=record.payload if retain else None)
        self.reader = self.stack.enter_context(mock.patch.object(core, "_read_runtime_member", side_effect=read))

    def inspect(self):
        return core._inspect_runtime_bindings(self.metadata, deadline=self.deadline, clock=self.clock)

    def test_matching_synthetic_process_returns_only_immutable_partial_status(self):
        self.install_process()
        partial = self.inspect()
        self.assertEqual(partial.status, "partial")
        with self.assertRaises((AttributeError, TypeError)):
            partial.status = "qualified"
        for operation in ("run", "reset", "launch", "observe_child", "native_artifact"):
            self.assertFalse(hasattr(partial, operation))
        with self.assertRaises((TypeError, core.ProcessFailure)):
            type(partial)()
        self.assertTrue(self.reads)
        self.assertEqual(self.memory.helper.calls, [])
        self.reset.assert_not_called()
        self.popen.assert_not_called()

    def test_matching_drift_checks_retain_original_clock_and_never_reset(self):
        self.install_process()
        partial = self.inspect()
        first_reads = len(self.reads)
        partial.inspect_drift(deadline=68.0)
        self.assertGreater(len(self.reads), first_reads)
        self.clock.now = 69.0
        partial._inspect_final_drift(deadline=70.0)
        self.assertEqual(self.memory.helper.calls, [])
        self.reset.assert_not_called()

    def test_equal_value_replacement_objects_are_drift(self):
        self.install_process()
        for drift in ("defaults", "code", "active", "method", "class"):
            with self.subTest(drift=drift):
                # Re-establish the same known initial synthetic module namespace.
                fresh = synthetic_module()
                self.module.__dict__.update(fresh.__dict__)
                # Rebind function globals to this module, without source execution.
                source_method = self.module.Popen.__del__
                method = types.FunctionType(source_method.__code__, self.module.__dict__,
                    "__del__", source_method.__defaults__)
                self.module.Popen.__del__ = method
                partial = self.inspect()
                if drift == "defaults":
                    replacement = tuple(list(method.__defaults__))
                    self.assertEqual(replacement, method.__defaults__)
                    self.assertIsNot(replacement, method.__defaults__)
                    method.__defaults__ = replacement
                elif drift == "code":
                    method.__code__ = method.__code__.replace()
                elif drift == "active":
                    self.module._active = []
                elif drift == "method":
                    self.module.Popen.__del__ = types.FunctionType(method.__code__,
                        self.module.__dict__, "__del__", method.__defaults__)
                else:
                    self.module.Popen = type("Popen", (object,), dict(self.module.Popen.__dict__))
                with self.assertRaises(core.ProcessFailure):
                    partial.inspect_drift(deadline=68.0)

    def test_later_deadline_arguments_refuse_before_read_or_native_observation(self):
        self.install_process()
        partial = self.inspect()
        for operation, deadline in ((partial.inspect_drift, 68.001),
                                    (partial.inspect_drift, 70.0),
                                    (partial._inspect_final_drift, 71.0)):
            with self.subTest(deadline=deadline):
                before = (len(self.reads), len(self.memory.reads), len(self.memory.getter.calls))
                with self.assertRaises(core.ProcessFailure):
                    operation(deadline=deadline)
                self.assertEqual(before, (len(self.reads), len(self.memory.reads), len(self.memory.getter.calls)))

    def test_original_and_final_exact_expiry_never_reset_budget(self):
        self.install_process()
        partial = self.inspect()
        self.clock.now = 68.0
        with self.assertRaises(core.ProcessFailure):
            partial.inspect_drift(deadline=68.0)
        self.clock.now = 70.0
        with self.assertRaises(core.ProcessFailure):
            partial._inspect_final_drift(deadline=70.0)

    def test_clock_error_nonfinite_negative_and_backward_reads_refuse(self):
        self.install_process()
        for observation in (float("nan"), float("inf"), -1.0, 11.0, OSError(errno.EIO, "synthetic clock")):
            with self.subTest(kind=type(observation).__name__):
                self.clock.now = 12.0
                partial = self.inspect()
                if isinstance(observation, Exception):
                    # Replace the retained facade's behavior, never the facade.
                    with mock.patch.object(Clock, "__call__", side_effect=observation):
                        with self.assertRaises(core.ProcessFailure):
                            partial.inspect_drift(deadline=68.0)
                else:
                    self.clock.now = observation
                    with self.assertRaises(core.ProcessFailure):
                        partial.inspect_drift(deadline=68.0)

    def test_wrong_clock_callable_and_exact_integer_constant_refuse_without_call(self):
        self.install_process()
        for constant in (True, 8.0, 9):
            with self.subTest(constant_type=type(constant).__name__):
                with mock.patch.object(time, "CLOCK_UPTIME_RAW", constant):
                    with self.assertRaises(core.ProcessFailure):
                        self.inspect()
        with mock.patch.object(time, "clock_gettime", side_effect=AssertionError("second clock read")) as replacement:
            with self.assertRaises(core.ProcessFailure):
                self.inspect()
            replacement.assert_not_called()

    def test_actual_builtin_with_wrong_name_module_self_binding_refuses(self):
        self.install_process()
        # These are real builtins, so a callable/type-only check is insufficient.
        for replacement in (time.time, len, _signal.getsignal):
            with self.subTest(name=replacement.__name__):
                with mock.patch.object(time, "clock_gettime", replacement):
                    with self.assertRaises(core.ProcessFailure):
                        self.inspect()

    def test_final_binding_boundary_returning_late_refuses(self):
        self.install_process()
        bind = self.api("_bind_popen_body")
        def late(*arguments, **keywords):
            result = bind(*arguments, **keywords)
            self.clock.now = 68.0
            return result
        with mock.patch.object(core, "_bind_popen_body", side_effect=late):
            with self.assertRaises(core.ProcessFailure):
                self.inspect()

    def test_partial_construction_returning_late_cannot_publish_result(self):
        self.install_process()
        result_type = getattr(core, "_PartialRuntimeBindings", None)
        self.assertTrue(isinstance(result_type, type), "missing internal partial result type")
        original = result_type.__init__
        constructed = []
        def late(instance, *arguments, **keywords):
            original(instance, *arguments, **keywords)
            constructed.append(True)
            self.clock.now = 68.0
        with mock.patch.object(result_type, "__init__", new=late):
            with self.assertRaises(core.ProcessFailure):
                self.inspect()
        self.assertEqual(constructed, [True])

    def test_partial_passes_do_not_enable_qualifier_or_worker_selectors(self):
        self.install_process()
        partial = self.inspect()
        for operation in (lambda: core._qualify_runtime(partial, deadline=68.0, clock=self.clock),
                          lambda: core._worker_launch(partial),
                          lambda: core._bootstrap_worker_launch(partial, deadline=68.0)):
            with self.assertRaises(core.ProcessFailure):
                operation()
        self.reset.assert_not_called()
        self.popen.assert_not_called()
