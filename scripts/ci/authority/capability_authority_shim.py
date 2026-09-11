"""Unadmitted external authority template. No literal identifies a live bundle.

An external invocation review must freeze these literals and this file's bytes.
Importing this template does not import package code, load native code or spawn.
"""
TRUSTED_PACKAGE_ROOT = 'UNSET'
EXPECTED_MANIFEST_SHA256 = 'UNSET'
ADMITTED_PROFILE_ID = 'UNSET'
MANIFEST_NAME = 'capability_package_manifest.json'
BOOTSTRAP_PREFIX = '--capability-bootstrap-fd'
MODULE_ORDER = (
    'capability_process_protocol', 'capability_process', 'capability_schema',
    'bats_inventory', 'bats_evidence', 'capability_policy',
)


class ShimRefusal(ValueError):
    def __str__(self):
        return 'process-session-unavailable'


def _checked_read(clock, previous):
    try:
        value = clock(8)
    except Exception:
        raise ShimRefusal() from None
    if (type(value) is not float or value != value or value < 0
            or value == float('inf')
            or (previous[0] is not None and value < previous[0])):
        raise ShimRefusal()
    previous[0] = value
    return value


def _capture_clock():
    # These minimal built-in observations precede charged imports and hashing.
    import time
    import sys
    clock = getattr(time, 'clock_gettime', None)
    if (type(clock) is not type(len) or clock.__module__ != 'time'
            or clock.__name__ != 'clock_gettime' or clock.__self__ is not time
            or sys.modules.get('time') is not time
            or 'time' not in sys.builtin_module_names
            or getattr(getattr(time, '__spec__', None), 'origin', None) != 'built-in'
            or type(getattr(time, 'CLOCK_UPTIME_RAW', None)) is not int
            or time.CLOCK_UPTIME_RAW != 8):
        raise ShimRefusal()
    previous = [None]

    def captured():
        if (getattr(time, 'clock_gettime', None) is not clock
                or type(getattr(time, 'CLOCK_UPTIME_RAW', None)) is not int
                or time.CLOCK_UPTIME_RAW != 8):
            raise ShimRefusal()
        return _checked_read(clock, previous)

    try:
        started = captured()
    except Exception:
        raise ShimRefusal() from None
    return captured, started


def _adopt_bootstrap(argv):
    # Only the fixed internal vector transfers this one descriptor. Never touch
    # stdio or close a descriptor inferred from malformed/noncanonical text.
    if (type(argv) not in (list, tuple) or len(argv) < 2
            or argv[0] != BOOTSTRAP_PREFIX or type(argv[1]) is not str
            or not 1 <= len(argv[1]) <= 10 or argv[1][0] == '0'
            or any(c not in '0123456789' for c in argv[1])):
        raise ShimRefusal()
    descriptor = int(argv[1])
    if not 2 < descriptor <= 2147483647:
        raise ShimRefusal()
    os_module = None
    try:
        clock, first = _capture_clock()
        previous = [first]
        times = [None, None]

        def checkpoint():
            now = clock()
            if (type(now) is not float or now != now or now < 0
                    or now == float('inf') or type(previous[0]) is not float
                    or previous[0] != previous[0] or previous[0] < 0
                    or previous[0] == float('inf') or now < previous[0]):
                raise ShimRefusal()
            previous[0] = now
            if times[0] is not None and not times[0] <= now < times[1]:
                raise ShimRefusal()
            return now

        checkpoint()
        import os as os_module
        checkpoint()
        # Literal refusal still owns the syntactically accepted handoff FD.
        # No CLI/env/candidate operand selects these authority values.
        if (type(TRUSTED_PACKAGE_ROOT) is not str or not TRUSTED_PACKAGE_ROOT.startswith('/')
                or len(TRUSTED_PACKAGE_ROOT) > 4096
                or type(EXPECTED_MANIFEST_SHA256) is not str
                or len(EXPECTED_MANIFEST_SHA256) != 64
                or any(c not in '0123456789abcdef' for c in EXPECTED_MANIFEST_SHA256)
                or type(ADMITTED_PROFILE_ID) is not str or not ADMITTED_PROFILE_ID
                or len(ADMITTED_PROFILE_ID) > 128
                or ADMITTED_PROFILE_ID[0] not in 'abcdefghijklmnopqrstuvwxyz0123456789'
                or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789._-' for c in ADMITTED_PROFILE_ID)):
            raise ShimRefusal()
        checkpoint()
        import stat
        checkpoint()
        import fcntl
        checkpoint()
        import struct
        checkpoint()
        import hashlib
        checkpoint()
        if BOOTSTRAP_PREFIX in argv[2:]:
            raise ShimRefusal()
        info = os_module.fstat(descriptor)
        checkpoint()
        if not stat.S_ISFIFO(info.st_mode) or os_module.get_blocking(descriptor):
            raise ShimRefusal()
        checkpoint()
        flags = fcntl.fcntl(descriptor, fcntl.F_GETFL)
        checkpoint()
        if flags & os_module.O_ACCMODE != os_module.O_RDONLY:
            raise ShimRefusal()
        os_module.set_inheritable(descriptor, False)
        checkpoint()

        data = bytearray()
        interruptions = 0
        # The prelude closes its writer before exec. D cannot be inferred until
        # the frame arrives: finite reads bound malformed/test-seam retries,
        # without inventing a new time allowance. Once available, D is checked
        # before/after every observation, including the mandatory EOF read.
        for _attempt in range(73):  # 64 one-byte reads + EOF + 8 interruptions
            checkpoint()
            try:
                part = os_module.read(descriptor, 65 - len(data))
            except (BlockingIOError, InterruptedError):
                checkpoint()
                interruptions += 1
                if interruptions >= 8:
                    raise ShimRefusal()
                continue
            checkpoint()
            if not part:
                if len(data) != 64 or times[0] is None:
                    raise ShimRefusal()
                break
            data.extend(part)
            if len(data) > 64:
                raise ShimRefusal()
            if len(data) == 64:
                magic, clock_id, reserved, started, deadline, binding = struct.unpack(
                    '>8sIIdd32s', data)
                if (magic != b'CAPBOOT1' or clock_id != 8 or reserved != 0
                        or started != started or started < 0 or started == float('inf')
                        or deadline != deadline or deadline == float('inf')
                        or deadline <= started or deadline != started + 58.0
                        or started > first):
                    raise ShimRefusal()
                times[:] = [started, deadline]
                checkpoint()
                root = TRUSTED_PACKAGE_ROOT.encode('utf-8')
                profile = ADMITTED_PROFILE_ID.encode('ascii')
                if len(root) > 4096 or len(profile) > 128:
                    raise ShimRefusal()
                encoded = (b'capability-bootstrap-authority-v1\x00'
                           + struct.pack('>I', len(root)) + root
                           + bytes.fromhex(EXPECTED_MANIFEST_SHA256)
                           + struct.pack('>I', len(profile)) + profile)
                if hashlib.sha256(encoded).digest() != binding:
                    raise ShimRefusal()
                checkpoint()
        else:
            raise ShimRefusal()
        checkpoint()
        # Transfer no descriptor to package code, including on an uncertain close.
        closing, descriptor = descriptor, None
        os_module.close(closing)
        checkpoint()
        return clock, times[0], times[1], list(argv[2:])
    except BaseException:
        raise ShimRefusal() from None
    finally:
        if descriptor is not None:
            # Capture/import failure must still discharge the parsed handoff FD.
            try:
                if os_module is None:
                    import os as os_module
                closing, descriptor = descriptor, None
                os_module.close(closing)
            except BaseException:
                raise ShimRefusal() from None


def _run(argv):
    try:
        clock, started, deadline, argv = _adopt_bootstrap(argv)

        def checkpoint():
            now = clock()
            if type(now) is not float or now != now or now < started or now >= deadline:
                raise ShimRefusal()

        checkpoint()
        import os
        checkpoint()
        import stat
        checkpoint()
        import hashlib
        checkpoint()
        import json
        checkpoint()
        import types
        checkpoint()
        import sys
        checkpoint()
        from pathlib import Path
        checkpoint()
        from importlib.machinery import ModuleSpec
        checkpoint()
    except Exception:
        raise ShimRefusal() from None

    required = {name + '.py': 'python-source' for name in MODULE_ORDER}
    required.update({'capability_process_native.c': 'native-source',
                     'capability_process_profiles.json': 'profile-data'})
    root_fd = None
    installed = []
    old_path = list(sys.path)

    def metadata(st):
        return (st.st_dev, st.st_ino, st.st_mode, st.st_nlink, st.st_uid, st.st_gid,
                st.st_size, st.st_mtime_ns, st.st_ctime_ns)

    def regular(st):
        if (not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid()
                or st.st_nlink != 1 or st.st_mode & 0o022):
            raise ShimRefusal()

    def read_member(name, maximum, expected_size=None):
        fd = None
        try:
            checkpoint()
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                         dir_fd=root_fd)
            initial = os.fstat(fd)
            regular(initial)
            if initial.st_size < 0 or initial.st_size > maximum:
                raise ShimRefusal()
            if expected_size is not None and initial.st_size != expected_size:
                raise ShimRefusal()
            pieces = []
            total = 0
            while True:
                checkpoint()
                part = os.read(fd, min(65536, maximum + 1 - total))
                checkpoint()
                if not part:
                    break
                total += len(part)
                if total > maximum:
                    raise ShimRefusal()
                pieces.append(part)
            if total != initial.st_size or metadata(os.fstat(fd)) != metadata(initial):
                raise ShimRefusal()
            named = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
            if metadata(named) != metadata(initial):
                raise ShimRefusal()
            checkpoint()
            return b''.join(pieces), metadata(initial)
        finally:
            if fd is not None:
                os.close(fd)

    def digest(payload):
        checkpoint()
        value = hashlib.sha256(payload).hexdigest()
        checkpoint()
        return value

    def members_on_disk():
        names = set()
        checkpoint()
        with os.scandir(root_fd) as iterator:
            for entry in iterator:
                checkpoint()
                if len(names) >= 17 or entry.name in names:
                    raise ShimRefusal()
                names.add(entry.name)
        checkpoint()
        if names != set(required) | {MANIFEST_NAME}:
            raise ShimRefusal()

    def pairs(values):
        result = {}
        for key, value in values:
            if key in result:
                raise ShimRefusal()
            result[key] = value
        return result

    def bad_constant(_value):
        raise ShimRefusal()

    try:
        if any(name in sys.modules for name in MODULE_ORDER):
            raise ShimRefusal()
        raw = TRUSTED_PACKAGE_ROOT
        if os.path.normpath(raw) != raw or raw == '/':
            raise ShimRefusal()
        # Open every component without following links, including the root spelling.
        root_fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        for component in raw.split('/')[1:]:
            checkpoint()
            next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                              dir_fd=root_fd)
            previous_fd, root_fd = root_fd, next_fd
            os.close(previous_fd)
        initial_root = os.fstat(root_fd)
        if initial_root.st_uid != os.getuid() or stat.S_IMODE(initial_root.st_mode) != 0o700:
            raise ShimRefusal()
        members_on_disk()
        manifest_bytes, manifest_stat = read_member(MANIFEST_NAME, 65536)
        if digest(manifest_bytes) != EXPECTED_MANIFEST_SHA256:
            raise ShimRefusal()
        manifest = json.loads(manifest_bytes.decode('utf-8'), object_pairs_hook=pairs,
                              parse_constant=bad_constant)
        checkpoint()
        if (type(manifest) is not dict or set(manifest) != {'schema_version', 'members'}
                or type(manifest['schema_version']) is not int or manifest['schema_version'] != 1
                or type(manifest['members']) is not list or not 1 <= len(manifest['members']) <= 16):
            raise ShimRefusal()
        names, total = [], 0
        for row in manifest['members']:
            if type(row) is not dict or set(row) != {'path', 'kind', 'size', 'sha256'}:
                raise ShimRefusal()
            name, size, sha = row['path'], row['size'], row['sha256']
            if (type(name) is not str or name not in required
                    or type(row['kind']) is not str or row['kind'] != required[name]
                    or type(size) is not int or not 0 <= size <= 1048576
                    or type(sha) is not str or len(sha) != 64
                    or any(c not in '0123456789abcdef' for c in sha)):
                raise ShimRefusal()
            if total > 8388608 - size:
                raise ShimRefusal()
            total += size
            names.append(name)
        if names != sorted(required) or len(set(names)) != len(names):
            raise ShimRefusal()
        verified, recorded = {}, {}
        for row in manifest['members']:
            payload, identity = read_member(row['path'], 1048576, row['size'])
            if digest(payload) != row['sha256']:
                raise ShimRefusal()
            verified[row['path']] = payload
            recorded[row['path']] = identity
        members_on_disk()
        if metadata(os.fstat(root_fd)) != metadata(initial_root):
            raise ShimRefusal()
        # Compile immutable snapshots before executing the first package module.
        compiled = {}
        for name in MODULE_ORDER:
            checkpoint()
            compiled[name] = compile(verified[name + '.py'], raw + '/' + name + '.py', 'exec',
                                     dont_inherit=True)
            checkpoint()
        for name in MODULE_ORDER:
            checkpoint()
            if name in sys.modules:
                raise ShimRefusal()
            module = types.ModuleType(name)
            module.__file__ = raw + '/' + name + '.py'
            module.__package__ = ''
            module.__spec__ = ModuleSpec(name, loader=None, origin=module.__file__)
            module.__cached__ = None
            sys.modules[name] = module
            installed.append((name, module))
            exec(compiled[name], module.__dict__)
            checkpoint()
        # Revalidate bindings before handing the same budget to effectful preparation.
        members_on_disk()
        check_manifest, check_stat = read_member(MANIFEST_NAME, 65536)
        if check_stat != manifest_stat or digest(check_manifest) != EXPECTED_MANIFEST_SHA256:
            raise ShimRefusal()
        for row in manifest['members']:
            payload, identity = read_member(row['path'], 1048576, row['size'])
            if identity != recorded[row['path']] or digest(payload) != row['sha256']:
                raise ShimRefusal()
        if (metadata(os.fstat(root_fd)) != metadata(initial_root)
                or metadata(os.stat(raw, follow_symlinks=False)) != metadata(initial_root)
                or any(sys.modules.get(name) is not module for name, module in installed)):
            raise ShimRefusal()
        process = sys.modules['capability_process']
        budget = process._PreparationBudget(clock, started, deadline)
        trusted_root = process.TrustedRunnerRoot(Path(raw), EXPECTED_MANIFEST_SHA256, budget)
        context = process.TrustedEntryContext(trusted_root, EXPECTED_MANIFEST_SHA256, ADMITTED_PROFILE_ID)
        checkpoint()
        # Discharge loader-owned OS descriptors before policy may publish a result.
        closing_fd, root_fd = root_fd, None
        os.close(closing_fd)
        checkpoint()
        # Budget consumption and full runtime qualification belong to run_trusted/prepare.
        # Do not apply the 58-second preparation deadline after the full policy run.
        result = sys.modules['capability_policy'].run_trusted(argv, context=context)
        if type(result) is not int or not 0 <= result <= 255:
            raise ShimRefusal()
        return result
    except BaseException:
        raise ShimRefusal() from None
    finally:
        for name, module in reversed(installed):
            if sys.modules.get(name) is module:
                del sys.modules[name]
        sys.path[:] = old_path
        if root_fd is not None:
            try:
                os.close(root_fd)
            except OSError:
                raise ShimRefusal() from None


if __name__ == '__main__':
    import sys
    try:
        status = _run(sys.argv[1:])
    except ShimRefusal:
        sys.stderr.write('capability-policy: process-session-unavailable\n')
        status = 2
    raise SystemExit(status)
