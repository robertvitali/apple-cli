#!/usr/bin/env python3
"""Run the four synthetic native-authority harnesses on macOS arm64 with CLT.

From the repository root:
    python3 -I -S -B scripts/test-capability-authority.py

This is developer verification, not compiler/runtime qualification or profile
activation. It compiles reviewed repository sources with the installed CLT.
Timeout cleanup covers only the retained direct child, not compiler descendants.
Synchronous spawn/filesystem calls and inherited output sinks are not hard bounded.
"""

import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile


REPO = Path(__file__).resolve().parent.parent
CLT = Path("/Library/Developer/CommandLineTools")
COMPILER = CLT / "usr/bin/clang"
SDK = CLT / "SDKs/MacOSX.sdk"
COMPILE_SECONDS = 60
RUN_SECONDS = 15
REAP_SECONDS = 5
# Retain an unresolved child until the outer no-wait exit guard runs.
ACTIVE_CHILD = None


class RunFailure(Exception):
    pass


def command(argv, *, scratch, seconds, label):
    """Serial direct-child execution; never signal after observed termination."""
    global ACTIVE_CHILD
    print("authority-tests: " + label, flush=True)
    ACTIVE_CHILD = subprocess.Popen(
        [str(value) for value in argv], cwd=scratch,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C",
             "TMPDIR": str(scratch)},
        stdin=subprocess.DEVNULL, close_fds=True,
    )
    try:
        status = ACTIVE_CHILD.wait(timeout=seconds)
    except BaseException:
        # No group signalling or additional waiter. On an unresolved reap the
        # caller preserves scratch and the outer guard avoids Popen finalization.
        if ACTIVE_CHILD.returncode is None:
            ACTIVE_CHILD.kill()
            ACTIVE_CHILD.wait(timeout=REAP_SECONDS)
        raise
    else:
        ACTIVE_CHILD = None
        return status


def owned_directory(path, identity):
    current = path.lstat()
    if (not stat.S_ISDIR(current.st_mode) or current.st_uid != os.getuid()
            or stat.S_IMODE(current.st_mode) != 0o700
            or (current.st_dev, current.st_ino) != identity):
        raise RunFailure("scratch identity changed; preserved")


def main():
    if len(sys.argv) != 1:
        raise RunFailure("no arguments supported")
    if sys.platform != "darwin" or os.uname().machine != "arm64":
        raise RunFailure("requires macOS arm64 with Command Line Tools")
    if signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL:
        raise RunFailure("requires default SIGCHLD disposition")
    # Ordinary developer-process precondition: no inherited SA_NOCLDWAIT flag.
    # getsignal does not inspect sigaction flags; this is not native admission.
    if not COMPILER.is_file() or not os.access(COMPILER, os.X_OK) or not SDK.is_dir():
        raise RunFailure("requires installed Command Line Tools compiler and SDK")
    include = REPO / "scripts/ci/authority"
    source = include / "capability_authority_entry.c"
    harnesses = (
        ("primitive", REPO / "Tests/automation/capability_authority_native_tests.c"),
        ("schema", REPO / "Tests/automation/capability_authority_schema_tests.c"),
        ("nested", REPO / "Tests/automation/capability_authority_nested_tests.c"),
        ("files", REPO / "Tests/automation/capability_authority_files_tests.c"),
    )
    file_entry = REPO / "Tests/automation/capability_authority_files_test_entry.c"
    for path in (source, file_entry, include / "capability_authority_entry.h",
                 REPO / "Tests/automation/capability_authority_files_test_hooks.h",
                 REPO / "Tests/automation/capability_authority_nested_fixture.h",
                 *(path for _, path in harnesses)):
        if not path.is_file() or path.is_symlink():
            raise RunFailure("missing or symlinked harness input")

    # Resolve the parent so the no-follow primitive can traverse the fixture.
    parent = Path(tempfile.gettempdir()).resolve(strict=True)
    scratch = Path(tempfile.mkdtemp(prefix="apple-cli-authority-tests-", dir=parent))
    initial = scratch.lstat()
    identity = (initial.st_dev, initial.st_ino)
    cleanup = False
    try:
        owned_directory(scratch, identity)
        fixture = scratch / "fixture"
        fixture.mkdir(mode=0o700)
        # Explicitly set only this owned directory; do not change inherited umask.
        fixture.chmod(0o700)
        for name, harness in harnesses:
            binary = scratch / (name + "-tests")
            argv = [COMPILER, "--no-default-config", "-arch", "arm64",
                    "-isysroot", SDK, "-B", CLT / "usr/bin", "-std=c11",
                    "-D_DARWIN_C_SOURCE", "-Wall", "-Wextra", "-Werror",
                    "-O0", "-g0", "-fno-modules", "-fno-implicit-modules",
                    "-I", include, harness, file_entry if name == "files" else source,
                    "-o", binary]
            status = command(argv, scratch=scratch, seconds=COMPILE_SECONDS,
                             label="compile " + name)
            if status:
                print("authority-tests: compiler status=" + str(status), file=sys.stderr)
                cleanup = True
                return status if 0 < status < 126 else 1
            invocation = [binary, fixture] if name in ("primitive", "files") else [binary]
            status = command(invocation, scratch=scratch, seconds=RUN_SECONDS,
                             label="run " + name)
            if status:
                print("authority-tests: harness status=" + str(status), file=sys.stderr)
                cleanup = True
                return status if 0 < status < 126 else 1
        cleanup = True
        return 0
    finally:
        if cleanup:
            owned_directory(scratch, identity)
            # This exclusively created tree contains only our compile outputs and
            # synthetic fixtures. rmtree does not follow fixture symlinks.
            shutil.rmtree(scratch)
        else:
            print("authority-tests: interrupted/setup failure; scratch preserved at "
                  + str(scratch), file=sys.stderr)


if __name__ == "__main__":
    try:
        try:
            status = main()
            if status == 0:
                print("authority-tests: all four synthetic harnesses passed", flush=True)
            raise SystemExit(status)
        except RunFailure as error:
            print("authority-tests: " + str(error), file=sys.stderr)
            raise SystemExit(1)
        except (OSError, subprocess.TimeoutExpired) as error:
            print("authority-tests: failed (" + type(error).__name__ + ")", file=sys.stderr)
            raise SystemExit(1)
        except KeyboardInterrupt:
            print("authority-tests: cancelled", file=sys.stderr)
            raise SystemExit(130)
    finally:
        if ACTIVE_CHILD is not None and ACTIVE_CHILD.returncode is None:
            try:
                sys.stderr.flush()
            finally:
                os._exit(1)
