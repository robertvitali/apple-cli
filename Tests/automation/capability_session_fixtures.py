"""Explicit mocked session admission; real Git observations, simulated transport.

Git runs only when capture_git_fixture() is called by fixture setup. Session.run
never launches a child. Nothing here establishes native runtime qualification.
"""
from dataclasses import dataclass
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

# Test discovery may start with only Tests/automation on PYTHONPATH. Resolve the
# trusted test dependency from this repository, independently of test order or
# whether another suite has already imported capability_policy.
PROCESS_DIRECTORY = Path(__file__).resolve().parents[2] / "scripts" / "ci"
if str(PROCESS_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(PROCESS_DIRECTORY))
import capability_process as process


@dataclass(frozen=True)
class GitObservation:
    stdout: bytes
    stderr: bytes
    status: int


def executable_identity(process, path):
    return process.ExecutableIdentity(
        path=str(path), sha256="0" * 64, device=1, inode=1, size=0,
        mode=0o100755, uid=0, gid=0, mtime_ns=0, ctime_ns=0,
    )


class RecordingProcessSession:
    """One explicitly admitted test instance, not a QualifiedProcessSession."""
    def __init__(self, process, *, swift="/synthetic/swift", handler=None):
        self.process = process
        self.state = "ready"
        self.cancelled = False
        self.close_error = None
        self.close_attempted = False
        self.decision = None
        self.requests = []
        self.observations = {}
        self.handler = handler
        self.swift = swift
        self.now = 100.0

    def clock(self):
        return self.now

    @property
    def can_validate_final_checkout(self):
        return self.state == "ready" and not self.cancelled

    def failure(self, reason, *, status=None):
        return self.process.ProcessFailure(
            reason=reason, command_status=status,
            cleanup_disposition="complete", session_disposition=self.state,
        )

    def selected_executable(self, role):
        if not self.can_validate_final_checkout:
            raise self.failure("process-unavailable")
        if role not in ("git", "swift-test", "swift-build", "swift-bin-path"):
            raise AssertionError("unrecognized synthetic executable role")
        return executable_identity(self.process, "/usr/bin/git" if role == "git" else self.swift)

    def bind_help_executable(self, binary, *, build_root, expected_sha256, deadline):
        binary.resolve(strict=True).relative_to(build_root.resolve(strict=True))
        if not self.can_validate_final_checkout or deadline <= self.clock():
            raise self.failure("process-unavailable")
        if hashlib.sha256(binary.read_bytes()).hexdigest() != expected_sha256:
            raise self.failure("identity-drift")
        return executable_identity(self.process, binary)

    def run(self, request):
        if not self.can_validate_final_checkout:
            raise self.failure("process-unavailable")
        if type(request) is not self.process.CommandRequest:
            raise AssertionError("request bypassed production immutable type")
        if request.deadline <= self.clock() or request.argv[0] != request.executable.path:
            raise AssertionError("invalid synthetic request identity or deadline")
        self.requests.append(request)
        if self.handler is not None:
            result = self.handler(request)
        else:
            if request.role != "git":
                raise AssertionError("unexpected non-Git fixture request")
            key = (str(request.cwd), request.argv, request.environment)
            if key not in self.observations:
                raise AssertionError("request has no separately captured Git observation")
            observation = self.observations[key]
            if observation.status:
                raise self.failure("command-failed", status=observation.status)
            result = self.process.CommandResult(
                stdout=observation.stdout, stderr=observation.stderr,
                command_status=0, cleanup_complete=True,
            )
        if len(result.stdout) + len(result.stderr) > request.maximum_output_bytes:
            raise self.failure("output-limit")
        return result

    def close(self):
        self.close_attempted = True
        self.state = "closed"
        if self.close_error is not None:
            raise self.close_error

    def finalize_decision(self, *, proposed, cancelled):
        if not self.close_attempted:
            raise AssertionError("decision before close")
        if self.decision is None:
            self.decision = cancelled if self.cancelled else proposed
        return self.decision


def admit_recording_session(policy, session):
    """Patch only this module's imported admission gate, for exactly one object."""
    def admit(value):
        if value is not session or session.state not in ("ready", "poisoned"):
            raise session.failure("process-unavailable")
        return session
    policy.require_process_session = admit
    return session


def capture_git_fixture(policy, session, fixture):
    """Observe actual synthetic repository data before policy evaluation begins."""
    root = fixture["repository_root"].resolve()
    sha = fixture["sha"]
    prefix = ("/usr/bin/git", "-c", "core.fsmonitor=false", "-c",
              "core.hooksPath=/dev/null", "-c", "credential.helper=", "-C", str(root))
    environment = tuple(sorted(policy._git_environment().items()))

    def observe(*arguments):
        argv = prefix + tuple(arguments)
        # Setup subprocesses are ordinary synthetic Git observations, outside
        # production policy and outside this no-spawn session. Bound retained
        # bytes before materialization; these files are not a disk quota claim.
        maximum = 64 * 1024 * 1024
        with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
            completed = subprocess.run(argv, cwd=root, env=dict(environment),
                                       stdin=subprocess.DEVNULL, stdout=stdout,
                                       stderr=stderr, timeout=10, check=False)
            if stdout.tell() + stderr.tell() > maximum:
                raise AssertionError("synthetic fixture capture exceeded bound")
            stdout.seek(0)
            stderr.seek(0)
            output = stdout.read(maximum + 1)
            diagnostic = stderr.read(maximum - len(output) + 1)
            if len(output) + len(diagnostic) > maximum:
                raise AssertionError("synthetic fixture capture exceeded bound")
        result = GitObservation(output, diagnostic, completed.returncode)
        session.observations[(str(root), argv, environment)] = result
        return result

    observe("rev-parse", "--show-toplevel")
    observe("rev-parse", "HEAD")
    observe("status", "--porcelain=v1", "-z")
    observe("rev-parse", f"{sha}^{{tree}}")
    tree = observe("ls-tree", "-r", "-z", "--full-tree", sha)
    observe("ls-tree", "-r", "-z", "--name-only", "HEAD", "--", "docs")
    if tree.status == 0:
        for record in tree.stdout.split(b"\0"):
            if not record:
                continue
            metadata = record.split(b"\t", 1)[0].split(b" ")
            if len(metadata) == 3 and metadata[1] == b"blob":
                observe("cat-file", "blob", metadata[2].decode("ascii"))


def fixture_session(policy, *fixtures):
    session = RecordingProcessSession(process)
    for fixture in fixtures:
        capture_git_fixture(policy, session, fixture)
    return admit_recording_session(policy, session)


def run_recorded_trusted(policy, arguments, session):
    """Mock context admission and preparation explicitly, not production authority."""
    from types import SimpleNamespace
    context = SimpleNamespace(trusted_root=object(), profile_id="synthetic-no-spawn")
    with patch.object(policy, "require_trusted_entry_context", side_effect=lambda value:
                      context if value is context else (_ for _ in ()).throw(AssertionError("wrong context"))), \
         patch.object(policy.QualifiedProcessSession, "prepare", return_value=session):
        return policy.run_trusted(arguments, context=context)
