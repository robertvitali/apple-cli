"""External shim handoff and verified-buffer loading with synthetic package code.

Real filesystem/anonymous-pipe operations only; no process, native loader or reset.
The handoff tests exercise the old loader entry as their behavioral baseline.
They do not qualify the native prelude, CLT exec transport or a production profile.
"""
import builtins
import ctypes
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import struct
import sys
import tempfile
import types
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
SHIM_PATH = HERE.parents[1] / 'scripts' / 'ci' / 'authority' / 'capability_authority_shim.py'
GOLDEN_PATH = HERE / 'fixtures' / 'capability-bootstrap-v1.json'
PREFIX = '--capability-bootstrap-fd'
PROFILE = 'synthetic-unqualified'
OPERANDS = ['check', '--repository-root', '/synthetic/candidate', '--expected-sha', '0' * 40]
MODULES = (
    'capability_process_protocol', 'capability_process', 'capability_schema',
    'bats_inventory', 'bats_evidence', 'capability_policy',
)
MANIFEST = 'capability_package_manifest.json'
EVENT_KEY = '_capability_authority_fixture_events'
CONTEXT_KEY = '_capability_authority_fixture_context'
FIXTURE_SHA256 = hashlib.sha256


def load_template():
    spec = importlib.util.spec_from_file_location('authority_shim_fixture', SHIM_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def binding_bytes(root, manifest, profile):
    """Independent spec encoder; shared golden vectors pin its exact bytes."""
    root_bytes, profile_bytes = root.encode('utf-8'), profile.encode('ascii')
    return (b'capability-bootstrap-authority-v1\x00'
            + struct.pack('>I', len(root_bytes)) + root_bytes + bytes.fromhex(manifest)
            + struct.pack('>I', len(profile_bytes)) + profile_bytes)


def bootstrap_record(root, manifest, profile=PROFILE, *, started=100.0, deadline=158.0):
    return struct.pack('>8sIIdd32s', b'CAPBOOT1', 8, 0, started, deadline,
                       FIXTURE_SHA256(binding_bytes(root, manifest, profile)).digest())


class AuthorityShimTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='authority-shim-synthetic-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve() / 'bundle'
        self.root.mkdir(mode=0o700)
        self.shim = load_template()
        self.events = []
        self.old_modules = {name: sys.modules.get(name) for name in MODULES}
        for name in MODULES:
            sys.modules.pop(name, None)
        self.old_path = list(sys.path)
        setattr(builtins, EVENT_KEY, self.events)
        setattr(builtins, CONTEXT_KEY, None)
        self.addCleanup(self.restore_modules)
        # These tripwires also record calls: a caught exception cannot hide a first attempt.
        # They are test containment for reviewed code, not a hostile-code sandbox.
        for target in ('subprocess.Popen', 'subprocess.run', 'os.system', 'os.fork',
                       'os.posix_spawn', 'os.posix_spawnp', 'os.execve', 'os.execv',
                       'os.kill', 'os.killpg', 'ctypes.CDLL', 'ctypes.PyDLL',
                       'signal.signal'):
            patcher = mock.patch(target, side_effect=AssertionError('forbidden process/native effect'))
            effect = patcher.start()
            self.addCleanup(patcher.stop)
            self.addCleanup(effect.assert_not_called)
        self.sources = {}
        for name in MODULES:
            self.sources[name + '.py'] = self.module_source(name)
        self.sources['capability_process_native.c'] = b'/* synthetic source; never compiled */\n'
        self.sources['capability_process_profiles.json'] = b'{"schema_version":1,"profiles":[]}\n'
        self.write_bundle()

    def restore_modules(self):
        for name, previous in self.old_modules.items():
            sys.modules.pop(name, None)
            if previous is not None:
                sys.modules[name] = previous
        sys.path[:] = self.old_path
        delattr(builtins, EVENT_KEY)
        delattr(builtins, CONTEXT_KEY)

    @staticmethod
    def module_source(name):
        prefix = 'import builtins\nbuiltins.' + EVENT_KEY + '.append(' + repr(name) + ')\n'
        if name == 'capability_process':
            prefix += '''class _PreparationBudget:
    def __init__(self, captured_clock, started, deadline):
        self.captured_clock = captured_clock
        self.started = started
        self.deadline = deadline
        self.consumed = False
class TrustedRunnerRoot:
    def __init__(self, path, expected_manifest_sha256, budget):
        self.path = path
        self.expected_manifest_sha256 = expected_manifest_sha256
        self.budget = budget
class TrustedEntryContext:
    def __init__(self, trusted_root, expected_manifest_sha256, profile_id):
        self.trusted_root = trusted_root
        self.expected_manifest_sha256 = expected_manifest_sha256
        self.profile_id = profile_id
'''
        if name == 'capability_policy':
            prefix += '''def run_trusted(argv, *, context):
    builtins._capability_authority_fixture_events.append(('dispatch', tuple(argv)))
    builtins._capability_authority_fixture_context = context
    return 17
'''
        return prefix.encode('utf-8')

    def records(self):
        return [dict(path=path, kind=('python-source' if path.endswith('.py') else
                    'native-source' if path.endswith('.c') else 'profile-data'),
                    size=len(payload), sha256=hashlib.sha256(payload).hexdigest())
                for path, payload in sorted(self.sources.items())]

    def write_manifest(self, value=None, payload=None):
        if payload is None:
            payload = json.dumps(value if value is not None else
                                 {'schema_version': 1, 'members': self.records()},
                                 separators=(',', ':')).encode()
        path = self.root / MANIFEST
        path.write_bytes(payload)
        path.chmod(0o600)
        self.digest = hashlib.sha256(payload).hexdigest()

    def write_bundle(self):
        for path, payload in self.sources.items():
            target = self.root / path
            target.write_bytes(payload)
            target.chmod(0o600)
        self.write_manifest()

    def clock_capture(self):
        self.events.append('clock-start')
        def clock():
            self.events.append('clock-check')
            return 100.0
        return clock, 100.0

    def run_loader(self, clock_capture=None, *, payload=None, argument_transform=None,
                   read_transform=None, close_transform=None, descriptor=None,
                   literal_overrides=None):
        if payload is None:
            payload = bootstrap_record(str(self.root), self.digest)
        reader = writer = None
        self.handoff_closed = None
        self.handoff_reads = []
        self.handoff_closes = []
        original_read, original_close = os.read, os.close
        if descriptor is None:
            reader, writer = os.pipe()
            self.assertGreater(reader, 2)
            self.assertGreater(writer, 2)
            os.set_blocking(reader, False)
            os.set_blocking(writer, False)
            # Small, finite writes with no reader process. No blocking fixture producer.
            self.assertLessEqual(len(payload), 65)
            self.assertEqual(os.write(writer, payload), len(payload))
            original_close(writer)
            writer = None
            descriptor = reader
        self.last_handoff_fd = descriptor
        owned_identity = os.fstat(descriptor) if reader is not None else None

        def is_handoff(fd):
            if fd != descriptor:
                return False
            try:
                current = os.fstat(fd)
                return (owned_identity is not None and current.st_dev == owned_identity.st_dev
                        and current.st_ino == owned_identity.st_ino)
            except OSError:
                return False

        def observed_read(fd, count):
            if is_handoff(fd):
                self.handoff_reads.append(count)
                self.events.append('handoff-read')
                if read_transform is not None:
                    return read_transform(original_read, fd, count)
            return original_read(fd, count)

        def observed_close(fd):
            if is_handoff(fd):
                self.handoff_closes.append(fd)
                self.events.append('handoff-close')
                if close_transform is not None:
                    return close_transform(original_close, fd)
            return original_close(fd)

        args = [PREFIX, str(descriptor)] + OPERANDS
        if argument_transform is not None:
            args = argument_transform(args)
        literals = dict(TRUSTED_PACKAGE_ROOT=str(self.root),
                        EXPECTED_MANIFEST_SHA256=self.digest, ADMITTED_PROFILE_ID=PROFILE)
        if literal_overrides is not None:
            literals.update(literal_overrides)
        try:
            with mock.patch.multiple(self.shim, **literals), \
                 mock.patch.object(self.shim, '_capture_clock',
                                   clock_capture or self.clock_capture), \
                 mock.patch.object(os, 'read', observed_read), \
                 mock.patch.object(os, 'close', observed_close):
                return self.shim._run(args)
        finally:
            # Observe closure before fixture reclamation; fixture cleanup is not evidence.
            self.handoff_closed = not is_handoff(descriptor)
            if reader is not None and not self.handoff_closed:
                original_close(reader)
            if writer is not None:
                original_close(writer)

    def load_successfully(self):
        try:
            return self.run_loader()
        except self.shim.ShimRefusal:
            self.fail("new loader behavior absent: verified synthetic bundle was refused")

    def assert_refused(self):
        with self.assertRaises(self.shim.ShimRefusal) as captured:
            self.run_loader()
        self.assertEqual(str(captured.exception), 'process-session-unavailable')
        self.assertFalse(any(item in MODULES for item in self.events if isinstance(item, str)))
        self.assertFalse(any(isinstance(item, tuple) and item[0] == 'dispatch' for item in self.events))

    def assert_handoff_refused(self, **kwargs):
        self.events.clear()
        with self.assertRaises(self.shim.ShimRefusal) as captured:
            self.run_loader(**kwargs)
        self.assertEqual(str(captured.exception), 'process-session-unavailable')
        self.assertFalse(any(item in MODULES for item in self.events if isinstance(item, str)))
        self.assertFalse(any(isinstance(item, tuple) for item in self.events))
        self.assertTrue(self.handoff_closed, 'subject must close its accepted read FD')

    def test_static_cross_language_vectors_match_independent_spec_encoding(self):
        golden = json.loads(GOLDEN_PATH.read_text())
        self.assertEqual(golden['schema_version'], 1)
        data = binding_bytes(golden['root'], golden['manifest_sha256'], golden['profile_id'])
        self.assertEqual(data.hex(), golden['binding_encoding_hex'])
        self.assertEqual(FIXTURE_SHA256(data).hexdigest(), golden['binding_sha256'])
        for row in golden['records']:
            with self.subTest(started=row['started']):
                record = bootstrap_record(golden['root'], golden['manifest_sha256'],
                                          golden['profile_id'], started=row['started'],
                                          deadline=row['deadline'])
                self.assertEqual(len(record), 64)
                self.assertEqual(record.hex(), row['record_hex'])

    def test_native_elapsed_time_is_not_restarted_at_python_entry(self):
        def capture():
            self.events.append('clock-start')
            return lambda: 125.0, 125.0
        self.assertEqual(self.run_loader(capture), 17)
        budget = getattr(builtins, CONTEXT_KEY).trusted_root.budget
        self.assertEqual((budget.started, budget.deadline), (100.0, 158.0))
        self.assertEqual(budget.deadline - budget.captured_clock(), 33.0)
        self.assertTrue(self.handoff_closed)
        self.assertEqual(self.events[-1], ('dispatch', tuple(OPERANDS)))

    def test_invalid_literals_still_close_the_valid_inherited_descriptor(self):
        cases = [('TRUSTED_PACKAGE_ROOT', 'relative'),
                 ('TRUSTED_PACKAGE_ROOT', None),
                 ('TRUSTED_PACKAGE_ROOT', '/' + 'x' * 4096),
                 ('EXPECTED_MANIFEST_SHA256', 'UNSET'),
                 ('EXPECTED_MANIFEST_SHA256', 'A' * 64),
                 ('EXPECTED_MANIFEST_SHA256', None),
                 ('ADMITTED_PROFILE_ID', ''),
                 ('ADMITTED_PROFILE_ID', None),
                 ('ADMITTED_PROFILE_ID', 'x' * 129),
                 ('ADMITTED_PROFILE_ID', '/unqualified')]
        for literal, value in cases:
            with self.subTest(literal=literal, case=cases.index((literal, value))):
                self.assert_handoff_refused(literal_overrides={literal: value})
                self.assertEqual(self.handoff_closes, [self.last_handoff_fd])
                self.assertIn('clock-start', self.events)

    def test_missing_or_noncanonical_internal_descriptor_prefix_refuses(self):
        transforms = (
            lambda args: args[2:],
            lambda args: ['--wrong-bootstrap-fd'] + args[1:],
            lambda args: [PREFIX],
            lambda args: [PREFIX, ''],
            lambda args: [PREFIX, '+' + args[1]] + args[2:],
            lambda args: [PREFIX, '0' + args[1]] + args[2:],
            lambda args: [PREFIX, ' ' + args[1]] + args[2:],
            lambda args: [PREFIX, args[1] + '.0'] + args[2:],
            lambda args: [PREFIX, '\u0663'] + args[2:],
            lambda args: [PREFIX, '-1'] + args[2:],
            lambda args: [PREFIX, '9' * 4097] + args[2:],
            lambda args: args[:2] + args,
        )
        for transform in transforms:
            with self.subTest(transform=transforms.index(transform)):
                self.events.clear()
                with self.assertRaises(self.shim.ShimRefusal):
                    self.run_loader(argument_transform=transform)
                self.assertFalse(any(isinstance(event, tuple) for event in self.events))
                # Invalid prefix/FD text does not transfer fixture-FD ownership.

    def test_standard_descriptors_are_rejected_without_read_or_close(self):
        read, close = os.read, os.close
        for descriptor in (0, 1, 2):
            with self.subTest(descriptor=descriptor):
                attempted = []
                def reject_read(fd, count):
                    if fd in (0, 1, 2):
                        attempted.append(('read', fd))
                    self.assertNotIn(fd, (0, 1, 2))
                    return read(fd, count)
                def reject_close(fd):
                    if fd in (0, 1, 2):
                        attempted.append(('close', fd))
                    self.assertNotIn(fd, (0, 1, 2))
                    return close(fd)
                with mock.patch.object(os, 'read', reject_read), \
                     mock.patch.object(os, 'close', reject_close):
                    with self.assertRaises(self.shim.ShimRefusal):
                        self.run_loader(argument_transform=lambda args: [PREFIX, str(descriptor)] + args[2:])
                self.assertEqual(attempted, [])
                self.assertFalse(any(isinstance(event, tuple) for event in self.events))

    def test_every_truncated_frame_and_eof_refuses_before_package_execution(self):
        valid = bootstrap_record(str(self.root), self.digest)
        for length in range(64):
            with self.subTest(length=length):
                self.assert_handoff_refused(payload=valid[:length])

    def test_complete_frame_with_tail_refuses(self):
        self.assert_handoff_refused(payload=bootstrap_record(str(self.root), self.digest) + b'\x00')

    def test_magic_clock_reserved_and_endianness_refuse(self):
        valid = bootstrap_record(str(self.root), self.digest)
        cases = [b'CAPBOOT2' + valid[8:], valid[:8] + struct.pack('>I', 7) + valid[12:],
                 valid[:12] + struct.pack('>I', 1) + valid[16:],
                 struct.pack('<8sIIdd32s', b'CAPBOOT1', 8, 0, 100.0, 158.0, valid[32:])]
        for frame in cases:
            with self.subTest(frame=cases.index(frame)):
                self.assert_handoff_refused(payload=frame)

    def test_exact_root_manifest_and_profile_binding_refuse_retargeting(self):
        cases = [(str(self.root) + '-other', self.digest, PROFILE),
                 (str(self.root), 'f' * 64, PROFILE),
                 (str(self.root), self.digest, PROFILE + '-other')]
        for root, manifest, profile in cases:
            with self.subTest(field=cases.index((root, manifest, profile))):
                self.assert_handoff_refused(payload=bootstrap_record(root, manifest, profile))

    def test_nonfinite_negative_future_or_changed_allowance_refuses(self):
        cases = [(float('nan'), 158.0), (float('inf'), 158.0), (-1.0, 57.0),
                 (100.0, float('nan')), (100.0, float('inf')), (101.0, 159.0),
                 (100.0, 157.0), (100.0, 159.0), (1e300, 1e300)]
        for started, deadline in cases:
            with self.subTest(started=started, deadline=deadline):
                self.assert_handoff_refused(payload=bootstrap_record(
                    str(self.root), self.digest, started=started, deadline=deadline))

    def test_stale_equal_and_late_record_cannot_gain_python_budget(self):
        for now in (158.0, 159.0):
            with self.subTest(now=now):
                self.assert_handoff_refused(clock_capture=lambda: (lambda: now, now))

    def test_consumed_descriptor_cannot_be_reused_for_another_dispatch(self):
        self.assertEqual(self.run_loader(), 17)
        self.assertTrue(self.handoff_closed)
        old_descriptor = self.last_handoff_fd
        self.events.clear()
        with self.assertRaises(self.shim.ShimRefusal):
            self.run_loader(descriptor=old_descriptor)
        self.assertFalse(any(isinstance(event, tuple) for event in self.events))

    def test_short_record_reads_are_bounded_and_preserve_bytes(self):
        self.assertEqual(self.run_loader(read_transform=lambda read, fd, count: read(fd, min(3, count))), 17)
        self.assertGreater(len(self.handoff_reads), 2)
        self.assertTrue(all(0 < count <= 65 for count in self.handoff_reads))
        self.assertTrue(self.handoff_closed)
        self.assertEqual(self.events[-1], ('dispatch', tuple(OPERANDS)))

    def test_eagain_and_eintr_before_ready_record_are_incremental(self):
        attempts = []
        def interrupted(read, fd, count):
            attempts.append(count)
            if len(attempts) == 1:
                raise BlockingIOError(errno.EAGAIN, 'synthetic-not-ready')
            if len(attempts) == 2:
                raise InterruptedError(errno.EINTR, 'synthetic-interruption')
            return read(fd, count)
        self.assertEqual(self.run_loader(read_transform=interrupted), 17)
        self.assertGreaterEqual(len(attempts), 4)  # two interruptions, bytes, EOF
        self.assertTrue(self.handoff_closed)
        self.assertEqual(self.events[-1], ('dispatch', tuple(OPERANDS)))

    def test_permanent_eagain_exhausts_original_deadline_and_closes_fd(self):
        now = [100.0]
        def unreadable(read, fd, count):
            now[0] += 10.0
            if now[0] > 180.0:
                raise AssertionError('unbounded handoff retry')
            raise BlockingIOError(errno.EAGAIN, 'synthetic-not-ready')
        self.assert_handoff_refused(clock_capture=lambda: (lambda: now[0], 100.0),
                                    read_transform=unreadable)
        self.assertGreaterEqual(now[0], 158.0)
        self.assertLessEqual(now[0], 180.0)

    def test_read_failure_and_cancellation_close_fd_without_dispatch(self):
        for exception in (OSError(errno.EIO, 'synthetic-read-error'), KeyboardInterrupt()):
            with self.subTest(exception=type(exception).__name__):
                def failed(read, fd, count):
                    raise exception
                self.assert_handoff_refused(read_transform=failed)
                self.assertTrue(self.handoff_reads)

    def test_late_eof_observation_refuses_even_after_complete_frame(self):
        now = [100.0]
        def late_eof(read, fd, count):
            data = read(fd, count)
            if not data:
                now[0] = 158.0
            return data
        self.assert_handoff_refused(clock_capture=lambda: (lambda: now[0], 100.0),
                                    read_transform=late_eof)

    def test_complete_frame_without_eof_cannot_dispatch(self):
        now = [100.0]
        delivered = []
        def missing_eof(read, fd, count):
            if not delivered:
                data = read(fd, count)
                delivered.append(data)
                return data
            now[0] += 10.0
            if now[0] > 180.0:
                raise AssertionError('unbounded EOF retry')
            raise BlockingIOError(errno.EAGAIN, 'synthetic-writer-not-closed')
        self.assert_handoff_refused(clock_capture=lambda: (lambda: now[0], 100.0),
                                    read_transform=missing_eof)
        self.assertEqual(b''.join(delivered), bootstrap_record(str(self.root), self.digest))
        self.assertGreaterEqual(now[0], 158.0)
        self.assertLessEqual(now[0], 180.0)

    def test_uncertain_close_refuses_even_when_kernel_fd_was_closed(self):
        def failed_close(close, fd):
            close(fd)
            raise OSError(errno.EIO, 'synthetic-close-error')
        self.assert_handoff_refused(close_transform=failed_close)
        self.assertEqual(self.handoff_closes, [self.last_handoff_fd])

    def test_invalid_loaded_clock_after_handoff_still_refuses(self):
        calls = []
        def capture():
            self.events.append('clock-start')
            def clock():
                calls.append(None)
                return 99.0 if self.handoff_closes else 100.0
            return clock, 100.0
        self.assert_handoff_refused(clock_capture=capture)
        self.assertTrue(calls)

    def test_verified_sources_load_in_fixed_order_and_dispatch_exact_arguments(self):
        self.assertEqual(self.load_successfully(), 17)
        self.assertEqual([event for event in self.events if event in MODULES], list(MODULES))
        self.assertEqual(self.events[0], 'clock-start')
        self.assertEqual(self.events[-1], ('dispatch', ('check', '--repository-root',
                         '/synthetic/candidate', '--expected-sha', '0' * 40)))
        context = getattr(builtins, CONTEXT_KEY)
        self.assertEqual(context.trusted_root.path, self.root)
        self.assertEqual(context.expected_manifest_sha256, self.digest)
        self.assertEqual(context.trusted_root.expected_manifest_sha256, self.digest)
        self.assertEqual(context.profile_id, 'synthetic-unqualified')
        self.assertEqual(context.trusted_root.budget.started, 100.0)
        self.assertEqual(context.trusted_root.budget.deadline, 158.0)
        self.assertFalse(context.trusted_root.budget.consumed)
        self.assertEqual(context.trusted_root.budget.captured_clock(), 100.0)
        self.assertTrue(self.handoff_closed)
        self.assertTrue(self.handoff_reads)
        self.assertEqual(self.handoff_closes, [self.last_handoff_fd])
        self.assertLess(self.events.index('handoff-close'), self.events.index(MODULES[0]))

    def test_first_clock_precedes_manifest_and_member_hashing(self):
        original = hashlib.sha256
        def observed_hash(*args, **kwargs):
            self.assertIn('clock-start', self.events)
            self.events.append('hash')
            return original(*args, **kwargs)
        with mock.patch.object(hashlib, 'sha256', observed_hash):
            self.assertEqual(self.load_successfully(), 17)
        self.assertIn('hash', self.events)
        self.assertLess(self.events.index('clock-start'), self.events.index('hash'))

    def test_no_charged_import_precedes_clock_capture(self):
        original = builtins.__import__
        watched = {'hashlib', 'json', 'os', 'pathlib', 'stat', 'types'}
        def observed_import(name, *args, **kwargs):
            if name.split('.')[0] in watched:
                self.assertIn('clock-start', self.events)
            return original(name, *args, **kwargs)
        with mock.patch.object(builtins, '__import__', observed_import):
            self.assertEqual(self.load_successfully(), 17)

    def test_all_members_verified_before_any_package_code(self):
        last = self.root / (MODULES[-1] + '.py')
        last.write_bytes(last.read_bytes() + b'# changed after manifest\n')
        self.assert_refused()

    def test_manifest_digest_is_external_not_relearned_from_disk(self):
        self.digest = 'f' * 64
        self.assert_refused()

    def test_extra_missing_and_symlink_members_refuse(self):
        with self.subTest('extra'):
            extra = self.root / 'unlisted.py'; extra.write_bytes(b'raise RuntimeError()\n')
            self.assert_refused(); extra.unlink()
        with self.subTest('missing'):
            target = self.root / 'capability_schema.py'; saved = target.read_bytes(); target.unlink()
            self.assert_refused(); target.write_bytes(saved); target.chmod(0o600)
        with self.subTest('symlink'):
            target = self.root / 'capability_schema.py'; target.unlink()
            target.symlink_to(self.root / 'bats_inventory.py')
            self.assert_refused()

    def test_manifest_and_root_symlinks_refuse(self):
        manifest = self.root / MANIFEST
        original = manifest.read_bytes(); manifest.unlink()
        alternate = Path(self.temporary.name) / 'external-manifest.json'; alternate.write_bytes(original)
        manifest.symlink_to(alternate)
        self.assert_refused()
        manifest.unlink(); manifest.write_bytes(original); manifest.chmod(0o600)
        alias = Path(self.temporary.name) / 'bundle-alias'; alias.symlink_to(self.root, target_is_directory=True)
        self.root = alias
        self.assert_refused()

    def test_wrong_schema_kind_size_hash_and_duplicates_refuse(self):
        original = self.records()
        cases = []
        for key, value in [('kind', 'executable'), ('size', True), ('size', -1), ('sha256', 'A' * 64), ('sha256', '0' * 64),
                           ('path', '../escape.py'), ('path', '/absolute.py'), ('path', 'nested/member.py'),
                           ('path', 'nonascii-\u00e9.py')]:
            rows = [dict(row) for row in original]; rows[0][key] = value
            cases.append({'schema_version': 1, 'members': rows})
        cases += [{'schema_version': True, 'members': original},
                  {'schema_version': 1, 'members': original + [original[-1]]},
                  {'schema_version': 1, 'members': list(reversed(original))},
                  {'schema_version': 1, 'members': original, 'extra': 0}]
        for value in cases:
            with self.subTest(value=value):
                self.write_manifest(value); self.assert_refused()
        self.write_manifest(payload=b'{"schema_version":1,"schema_version":1,"members":[]}')
        self.assert_refused()

    def test_member_manifest_and_count_bounds_refuse(self):
        original = self.records()
        for payload in [b' ' * (65536 + 1), b'{"schema_version":1,"members":[]}']:
            self.write_manifest(payload=payload); self.assert_refused()
        rows = [dict(row) for row in original]; rows[0]['size'] = 1048577
        self.write_manifest({'schema_version': 1, 'members': rows}); self.assert_refused()
        rows = [dict(original[0], path='extra_%02d.py' % n) for n in range(17)]
        self.write_manifest({'schema_version': 1, 'members': rows}); self.assert_refused()

    def test_manifest_may_not_include_itself_or_shim(self):
        for name in (MANIFEST, 'capability_authority_shim.py'):
            self.write_manifest({'schema_version': 1, 'members': sorted(
                self.records() + [dict(path=name, kind='profile-data', size=0, sha256='0' * 64)],
                key=lambda row: row['path'])})
            self.assert_refused()

    def test_unexpected_preloaded_package_module_refuses_without_replacing_it(self):
        sentinel = types.ModuleType('capability_schema')
        sys.modules['capability_schema'] = sentinel
        self.assert_refused()
        self.assertIs(sys.modules['capability_schema'], sentinel)

    def test_expired_budget_refuses_before_package_execution(self):
        with self.assertRaises(self.shim.ShimRefusal):
            self.run_loader(lambda: (lambda: 158.0, 100.0))
        self.assertFalse(any(event in MODULES for event in self.events))

    def test_short_reads_preserve_verified_source_bytes(self):
        original = os.read
        def short_read(fd, length):
            return original(fd, min(length, 7))
        with mock.patch.object(os, 'read', short_read):
            self.assertEqual(self.load_successfully(), 17)

    def test_in_read_member_mutation_refuses_before_package_execution(self):
        target = self.root / 'capability_schema.py'
        identity = target.stat().st_ino
        original = os.read
        changed = []
        def mutate(fd, length):
            payload = original(fd, length)
            if not changed and os.fstat(fd).st_ino == identity:
                changed.append(True)
                with target.open('ab') as writer:
                    writer.write(b'# mutation while fd is open\n')
            return payload
        with mock.patch.object(os, 'read', mutate):
            self.assert_refused()
        self.assertTrue(changed)

    def test_directory_fifo_hardlink_and_writable_member_refuse(self):
        target = self.root / 'capability_schema.py'
        saved = target.read_bytes()
        target.unlink(); target.mkdir()
        self.assert_refused(); target.rmdir()
        os.mkfifo(target, 0o600)
        self.assert_refused(); target.unlink()
        target.write_bytes(saved); target.chmod(0o600)
        other = Path(self.temporary.name) / 'hardlink'
        os.link(target, other)
        self.assert_refused(); other.unlink()
        target.chmod(0o622)
        self.assert_refused()

    def test_late_syntax_failure_executes_no_package_prefix(self):
        self.sources['capability_policy.py'] = b'def invalid(\n'
        self.write_bundle()
        self.assert_refused()

    def test_snapshot_bytes_never_replaced_by_late_pathname_contents(self):
        target = self.root / 'capability_schema.py'
        original = builtins.compile
        changed = []
        def replace_before_compile(source, filename, mode, *args, **kwargs):
            if not changed and filename == str(self.root / 'capability_process_protocol.py'):
                changed.append(True)
                replacement = self.root / 'replacement.tmp'
                replacement.write_bytes(b'import builtins\nbuiltins.' + EVENT_KEY.encode() +
                                        b'.append("UNVERIFIED")\n')
                replacement.chmod(0o600)
                replacement.replace(target)
            return original(source, filename, mode, *args, **kwargs)
        with mock.patch.object(builtins, 'compile', replace_before_compile):
            with self.assertRaises(self.shim.ShimRefusal):
                self.run_loader()
        self.assertTrue(changed)
        self.assertNotIn('UNVERIFIED', self.events)
        self.assertIn('capability_schema', self.events)
        self.assertFalse(any(isinstance(item, tuple) for item in self.events))
        self.assertTrue(all(name not in sys.modules for name in MODULES))

    def test_deadline_after_module_execution_removes_partial_modules(self):
        def capture():
            self.events.append('clock-start')
            def clock():
                return 158.0 if 'capability_process_protocol' in self.events else 100.0
            return clock, 100.0
        with self.assertRaises(self.shim.ShimRefusal):
            self.run_loader(capture)
        self.assertIn('capability_process_protocol', self.events)
        self.assertNotIn('capability_process', self.events)
        self.assertTrue(all(name not in sys.modules for name in MODULES))

    def test_context_constructor_failure_is_value_free_and_never_dispatches(self):
        self.sources['capability_process.py'] += b'\nclass TrustedEntryContext:\n    def __init__(self, *args):\n        raise ValueError("fixture-private-diagnostic")\n'
        self.write_bundle()
        with self.assertRaises(self.shim.ShimRefusal) as captured:
            self.run_loader()
        self.assertEqual(str(captured.exception), 'process-session-unavailable')
        self.assertFalse(any(isinstance(item, tuple) for item in self.events))
        self.assertTrue(all(name not in sys.modules for name in MODULES))

    def test_exact_member_and_aggregate_byte_boundary_loads(self):
        for name, payload in list(self.sources.items()):
            remaining = 1048576 - len(payload)
            self.sources[name] = payload + b'#' + b'x' * (remaining - 2) + b'\n'
        self.write_bundle()
        self.assertEqual(sum(map(len, self.sources.values())), 8388608)
        self.assertEqual(self.load_successfully(), 17)

    def test_fake_clock_values_are_strict_finite_and_nondecreasing(self):
        for value in (None, True, 0, float('nan'), float('inf'), -1.0):
            with self.subTest(value=value):
                with self.assertRaises(self.shim.ShimRefusal):
                    self.shim._checked_read(lambda _clock_id: value, [None])
        previous = [None]
        self.assertEqual(self.shim._checked_read(lambda _clock_id: 5.0, previous), 5.0)
        self.assertEqual(self.shim._checked_read(lambda _clock_id: 5.0, previous), 5.0)
        with self.assertRaises(self.shim.ShimRefusal):
            self.shim._checked_read(lambda _clock_id: 4.0, previous)
        def failed(_clock_id):
            raise OSError('fixture-only')
        with self.assertRaises(self.shim.ShimRefusal):
            self.shim._checked_read(failed, previous)

    def test_wrong_builtin_and_clock_constant_refuse_without_reading_clock(self):
        import time
        with mock.patch.object(time, 'clock_gettime', lambda _: self.fail('fake clock was called')):
            with self.assertRaises(self.shim.ShimRefusal):
                self.shim._capture_clock()
        for value in (True, 7, 8.0):
            with mock.patch.object(time, 'CLOCK_UPTIME_RAW', value, create=True):
                with self.assertRaises(self.shim.ShimRefusal):
                    self.shim._capture_clock()

    def test_root_descriptor_close_failure_precedes_policy_dispatch(self):
        identity = self.root.stat().st_ino
        original = os.close
        failed = []
        def fail_after_close(fd):
            is_root = os.fstat(fd).st_ino == identity
            original(fd)
            if is_root:
                failed.append(True)
                raise OSError('fixture-close-error')
        with mock.patch.object(os, 'close', fail_after_close):
            with self.assertRaises(self.shim.ShimRefusal) as captured:
                self.run_loader()
        self.assertTrue(failed)
        self.assertEqual(str(captured.exception), 'process-session-unavailable')
        self.assertFalse(any(isinstance(item, tuple) for item in self.events))

    def test_unset_template_has_no_admitted_entry(self):
        with self.assertRaises(self.shim.ShimRefusal):
            self.shim._run([])
        self.assertEqual(self.events, [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
