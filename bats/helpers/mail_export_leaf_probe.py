#!/usr/bin/env python3
"""Real export previews with private files and process creation denied per call.

Account loading falls back to indexed UUIDs when its AppleScript spawn is denied.
A positive control runs first; every restricted child must prove fork/spawn denial
before execing the CLI. Host index/account-fallback behavior is tested by Bats,
not established by the synthetic capability control alone. Never print host data.
"""

import contextlib
import errno
import importlib.util
import json
import os
from pathlib import Path
import signal
import stat
import sys
import tempfile

PROFILE = "(version 1)\n(allow default)\n(deny process-fork)"
SANDBOX_PREFIX = ("/usr/bin/sandbox-exec", "-p", PROFILE)
CANCELLATION_SIGNALS = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
DENIED = {"fork": "denied", "posix_spawn": "denied"}
CREATED = {"fork": "created_reaped_zero", "posix_spawn": "created_reaped_zero"}
FAILURE = "mail export composed-leaf preview regression failed"


class ProbeFailure(Exception):
    pass


class ProbeCancelled(Exception):
    def __init__(self, status):
        self.status = status


def require(condition):
    if not condition:
        raise ProbeFailure()


class DiscardOutput:
    # bounded_exec emits bytes through stdout.buffer and text on stderr. Neither
    # channel may forward captured sandbox/child diagnostics containing host paths.
    @property
    def buffer(self):
        return self

    def write(self, value):
        return len(value)

    def flush(self):
        pass


@contextlib.contextmanager
def cancellation_guard():
    seen = []

    def cancel(number, _frame):
        if not seen:
            seen.append(number)
            raise ProbeCancelled(128 + number)

    previous = {number: signal.getsignal(number) for number in CANCELLATION_SIGNALS}
    for number in CANCELLATION_SIGNALS:
        signal.signal(number, cancel)
    try:
        yield seen
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


def bounded_module():
    # Load the existing reviewed supervisor; do not duplicate its spawn/cancellation
    # signal-mask, TERM/grace/KILL, bounded drain, or reap implementation here.
    spec = importlib.util.spec_from_file_location(
        "mail_leaf_bounded_exec", Path(__file__).with_name("bounded_exec.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def process_creation_receipt():
    outcomes = {}
    for operation in ("fork", "posix_spawn"):
        try:
            if operation == "fork":
                pid = os.fork()
                if pid == 0:
                    os._exit(0)
            else:
                pid = os.posix_spawn(
                    "/usr/bin/true", ["true"], {"PATH": "/usr/bin:/bin"}, setpgroup=0,
                )
        except OSError as error:
            require(error.errno in {errno.EPERM, errno.EACCES})
            outcomes[operation] = "denied"
        else:
            waited, status = os.waitpid(pid, 0)
            require(waited == pid and os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0)
            outcomes[operation] = "created_reaped_zero"
    return outcomes


def child(mode, output_path, error_path, receipt_path, command):
    # The wrapper restores its child's cancellation mask before exec. Default and
    # unblock explicitly as well, including the alarm used only for this canary.
    for number in (*CANCELLATION_SIGNALS, signal.SIGALRM):
        signal.signal(number, signal.SIG_DFL)
    signal.pthread_sigmask(signal.SIG_UNBLOCK, {*CANCELLATION_SIGNALS, signal.SIGALRM})
    signal.alarm(4)
    for path, destination in ((output_path, 1), (error_path, 2)):
        descriptor = os.open(path, os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW)
        try:
            os.dup2(descriptor, destination)
        finally:
            if descriptor > 2:
                os.close(descriptor)
    outcome = process_creation_receipt()
    require(outcome == (DENIED if mode == "--child-restricted" else CREATED))
    descriptor = os.open(receipt_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as output:
        json.dump(outcome, output)
    if mode == "--child-restricted":
        require(bool(command))
        # Same process and same enforced profile after exec. No CLI process is ever
        # started when the denial check fails. The supervisor supplies its deadline.
        signal.alarm(0)
        environment = dict(os.environ, APPLE_TEST_MODE="1", APPLE_DRY_RUN="1")
        os.execve(command[0], command, environment)
    require(not command)
    return 0


def run_child(root, command, restricted, cancellation):
    # Regular files avoid an EOF dependency on inherited pipes and keep all host
    # output beneath an owned 0700 directory; files themselves are created 0600.
    with tempfile.TemporaryDirectory(prefix="call-", dir=root) as call_directory:
        call = Path(call_directory)
        stdout, stderr, receipt = (call / name for name in ("stdout", "stderr", "receipt"))
        for path in (stdout, stderr):
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.close(descriptor)
        arguments = [sys.executable, "-I", str(Path(__file__).resolve()),
                     "--child-restricted" if restricted else "--child-control",
                     str(stdout), str(stderr), str(receipt), *command]
        if restricted:
            arguments = [*SANDBOX_PREFIX, *arguments]
        supervisor = bounded_module()
        sink = DiscardOutput()
        with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            code = supervisor.run(["--timeout", "30" if restricted else "6", "--grace", "2", "--", *arguments])
        if code in {128 + number for number in CANCELLATION_SIGNALS}:
            cancellation.append(code - 128)  # suppress repeated signals through directory cleanup
            raise ProbeCancelled(code)
        require(code not in {124, 125})
        require(json.loads(receipt.read_bytes()) == (DENIED if restricted else CREATED))
        if not restricted:
            require(code == 0)
        return code, stdout.read_bytes()


def invoke(root, binary, arguments, cancellation):
    code, output = run_child(root, [binary, "mail", *arguments], True, cancellation)
    envelope = json.loads(output)
    require(isinstance(envelope, dict))
    require(envelope.get("tool") == "mail" and envelope.get("schema_version") == 1)
    return code, envelope


def probe(binary, cancellation):
    with tempfile.TemporaryDirectory(prefix="apple-cli-test-export-leaf-", dir=Path.home()) as owned:
        root = Path(owned).resolve()
        require(stat.S_IMODE(root.stat().st_mode) == 0o700)
        run_child(root, [], False, cancellation)
        code, envelope = invoke(root, binary,
                                ["search", "--mailbox", "All", "--limit", "1", "--no-content"], cancellation)
        require(code == 0 and envelope.get("ok") is True)
        rows = envelope["data"]["messages"]
        require(isinstance(rows, list) and len(rows) <= 1)
        if not rows:
            return 3  # Only a successful empty search may skip.
        account = rows[0]["account"]
        require(isinstance(account, str) and bool(account))
        out = root / "export"
        arguments = ["export", "--account", account, "--scope", "entire_mailbox",
                     "--mailbox", "All", "--max", "1", "--dir", str(out), "--dry-run", "--test-mode"]
        code, envelope = invoke(root, binary, arguments, cancellation)
        require(code == 0 and envelope.get("ok") is True)
        data = envelope["data"]
        require(data.get("dry_run") is True and data.get("exported") == 0)
        files = data["files"]
        require(isinstance(files, list) and len(files) == 1 and isinstance(files[0], str))
        require(not out.exists())
        leaf = Path(files[0])
        require(leaf.is_absolute() and leaf.parent == out / "All_export")
        require(leaf.name.startswith("1_") and leaf.name.endswith(".txt"))
        require(leaf.resolve() == leaf)
        leaf.parent.mkdir(parents=True, mode=0o700)
        sentinel = root / "sentinel.txt"
        sentinel_bytes = b"synthetic sentinel"
        sentinel.write_bytes(sentinel_bytes)
        missing = root / "missing-target.txt"
        for target in (sentinel, missing):
            leaf.symlink_to(target)
            before = sorted(str(path.relative_to(out)) for path in out.rglob("*"))
            for no_clobber in (False, True):
                code, envelope = invoke(root, binary, arguments + (["--no-clobber"] if no_clobber else []), cancellation)
                require(code == 77 and envelope.get("ok") is False and "data" not in envelope)
                error = envelope["error"]
                require(error.get("type") == "safety_violation")
                require(isinstance(error.get("message"), str) and "symlink" in error["message"])
                require(leaf.is_symlink() and os.readlink(leaf) == str(target))
                require(sentinel.read_bytes() == sentinel_bytes and not missing.exists())
                require(sorted(str(path.relative_to(out)) for path in out.rglob("*")) == before)
            leaf.unlink()
    return 0


def main():
    try:
        if sys.argv[1:2] in (["--child-control"], ["--child-restricted"]):
            require(len(sys.argv) >= 5)
            return child(sys.argv[1], *sys.argv[2:5], sys.argv[5:])
        require(len(sys.argv) == 2)
        with cancellation_guard() as cancellation:
            return probe(sys.argv[1], cancellation)
    except ProbeCancelled as cancelled:
        return cancelled.status
    except Exception:
        print(FAILURE, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
