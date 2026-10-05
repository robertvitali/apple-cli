"""Run one command under a portable, process-group-wide deadline.

The macOS CI image has Python 3.9 but not GNU coreutils. `start_new_session=True` makes the child
the leader of a fresh process group so a timed-out Swift process and every inherited descendant
(including osascript) receive the same TERM/KILL sequence. Deadline paths always return 124 and
normally preserve drained combined stdout/stderr for diagnostics; if a detached process keeps the
pipe open beyond the bounded post-KILL drain, that partial output is discarded instead of hanging.
Ordinary child statuses and combined output are preserved exactly.

External HUP/INT/TERM cancellation is distinct from a deadline: the wrapper cleans the same
process group, returns 128+signal, and deliberately discards buffered child output so a partial
live Apple payload cannot escape during cancellation. Live Bats callers must likewise capture a
completed result and immediately clear both `$output` and `$lines` before classifying/asserting it.

Callers wrapping `$BIN` must allow at least one second of grace so SIGTERM can run Swift snapshot
cleanup before SIGKILL. Shorter grace values below are only for synthetic contract fixtures.

`run()` uses `preexec_fn` only as a standalone, single-threaded wrapper entry point. Do not import
and call it concurrently from a multithreaded process; Python cannot make `preexec_fn` safe there.
"""

import argparse
import math
import os
import signal
import subprocess
import sys
from typing import List, Optional, Tuple


TIMEOUT_STATUS = 124
CANCELLATION_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)


class CancellationRequested(Exception):
    def __init__(self, signum: int) -> None:
        super().__init__(signum)
        self.signum = signum


def positive_seconds(raw: str) -> float:
    try:
        value = float(raw)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a number") from error
    if not math.isfinite(value) or value <= 0:
        raise argparse.ArgumentTypeError("must be finite and greater than zero")
    return value


def child_status(returncode: int) -> int:
    """Match shell status for a child terminated directly by a signal."""
    return returncode if returncode >= 0 else 128 - returncode


def try_signal_group(process_group: int, sig: signal.Signals) -> bool:
    try:
        os.killpg(process_group, sig)
        return True
    except ProcessLookupError:
        return False


def signal_group(process_group: int, sig: signal.Signals) -> None:
    try_signal_group(process_group, sig)


CLEANUP_PERMISSION_WARNING = (
    "bounded_exec: cleanup could not signal the command's process group (EPERM); exited members "
    "not yet reaped, or a member under other credentials, may remain"
)


def try_signal_cleanup_group(process: subprocess.Popen, sig: signal.Signals) -> bool:
    """Signal the command's group from cleanup, forgiving EPERM; returns whether it was sent.

    This wrapper never signals the group on a completed run, so unlike scripts/ci/quality.py no
    strict path exists; outside cleanup only the cancellation handler signals it. Not for the
    future local lease backend, which must not forgive EPERM; see
    docs/discovery/capability-local-owner-protocol.md.
    """
    try:
        return try_signal_group(process.pid, sig)
    except PermissionError:
        # EPERM means no member could be signalled. Darwin's killpg reports it, where Linux
        # succeeds, when every member has exited but some are not yet reaped: the leader, a
        # child of this wrapper, or orphans that launchd has not reaped yet. Cleanup's own
        # SIGTERM ending the leader together with its children leaves such a group, and so does
        # a child exiting as its deadline expires; a member under other credentials would
        # explain the error too. An unreaped exited leader is reaped here and the signal is
        # retried once: the retry tells a group the leader alone kept (ESRCH, nothing to report)
        # from one where something remains (EPERM again, warned below; a member the first call
        # could not reach is unlikely to accept the second, but would be reported sent). Any
        # other EPERM, with the leader running or already reaped, is reported as nothing sent
        # with a warning at once: cleanup runs only on a deadline (124), a cancellation (128+n)
        # or an error being re-raised, so forgiving it cannot turn a run green, and the warning
        # keeps the evidence that a member under other credentials may have survived
        # (scripts/ci/quality.py since 2026-10-03; here, and the retry in both, since
        # 2026-10-05).
        if process.returncode is None and process.poll() is not None:
            try:
                return try_signal_group(process.pid, sig)
            except PermissionError:
                pass
        print(CLEANUP_PERMISSION_WARNING, file=sys.stderr)
        return False


def kill_group_after_cancellation(process: subprocess.Popen) -> None:
    """A repeated cancellation's SIGKILL outside active cleanup; EPERM changes nothing."""
    try:
        signal_group(process.pid, signal.SIGKILL)
    except PermissionError:
        # This SIGKILL only accelerates cleanup. A signal handler must not poll the leader or
        # print, so it cannot tell an exited leader's EPERM from any other, and a warning
        # deferred to later would print on the cancellation path, whose output the caller
        # asserts is empty, even in the benign case. Raising would replace the cancellation's
        # 128+n with a traceback and status 1, and one landing in the `except
        # CancellationRequested` block before its cleanup starts would skip that cleanup.
        # Cleanup's own signals have run, against an earlier state of the group, or will run,
        # and warn on an EPERM an exited leader does not explain. The one exception is a first
        # cancellation that lands as the defensive-timeout or BaseException handler is
        # entered, before its cleanup starts: that escapes with a traceback, as before.
        pass


def emit(output: Optional[bytes]) -> None:
    if output:
        sys.stdout.buffer.write(output)
        sys.stdout.buffer.flush()


def close_output(process: subprocess.Popen) -> None:
    """Close the captured pipe after a bounded drain failure; safe to call repeatedly."""
    if process.stdout is not None and not process.stdout.closed:
        process.stdout.close()


def reap_leader(process: subprocess.Popen, grace: float) -> None:
    """Bounded best-effort reap of the process-group leader."""
    if process.returncode is not None:
        return
    try:
        process.wait(timeout=grace)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        process.kill()
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        # A process stuck in an uninterruptible kernel wait cannot be reaped without hanging the
        # caller. The group has received SIGKILL and every pipe owned here is already closed.
        pass


def drain_output(process: subprocess.Popen, grace: float) -> Tuple[Optional[bytes], bool]:
    """Return (output, complete), tolerating an already-closed/reaped Popen."""
    if process.stdout is None or process.stdout.closed:
        reap_leader(process, grace)
        return None, process.returncode is not None
    try:
        output, _ = process.communicate(timeout=grace)
        return output, True
    except subprocess.TimeoutExpired:
        return None, False
    except (OSError, ValueError):
        # `communicate()` raises ValueError when an earlier call already closed the pipe. Treat
        # that as an idempotent cleanup call, then make one bounded attempt to reap the leader.
        reap_leader(process, grace)
        return None, process.returncode is not None


def kill_remaining_group(
    process: subprocess.Popen,
    sigkill_already_sent: Optional[List[bool]] = None,
) -> None:
    """KILL the group unless the active cleanup handler already did so successfully."""
    if sigkill_already_sent is not None and sigkill_already_sent[0]:
        return
    try_signal_cleanup_group(process, signal.SIGKILL)


def stop_process_group(
    process: subprocess.Popen,
    grace: float,
    sigkill_already_sent: Optional[List[bool]] = None,
) -> Optional[bytes]:
    """TERM the group, then KILL it after `grace`; return drained combined output."""
    try_signal_cleanup_group(process, signal.SIGTERM)
    output, complete = drain_output(process, grace)
    if not complete:
        kill_remaining_group(process, sigkill_already_sent)
        output, complete = drain_output(process, grace)
        if not complete:
            # A detached descendant can retain the inherited pipe after the target group dies.
            # Bound this second drain too, then discard the partial stream and reap only the
            # leader; waiting for EOF here would turn the wrapper into another hang source.
            close_output(process)
            output = None
            reap_leader(process, grace)
    else:
        # The leader exited after TERM, but a descendant may have closed the inherited output
        # pipe and remained alive. KILL the now-orphaned remainder before returning. The window
        # in which the reaped leader's PGID could be reused before this call is negligible;
        # omitting this sweep would knowingly leave an inherited descendant alive. An EPERM
        # here is handled as in try_signal_cleanup_group.
        kill_remaining_group(process, sigkill_already_sent)
    return output


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a command with a TERM-then-KILL deadline; return 124 on timeout."
    )
    parser.add_argument("--timeout", required=True, type=positive_seconds)
    parser.add_argument("--grace", required=True, type=positive_seconds)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        parser.error("a command is required after --")
    return args


def run(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    process_holder: List[Optional[subprocess.Popen]] = [None]
    requested_signal: List[Optional[int]] = [None]
    cleanup_active = [False]
    cleanup_sent_sigkill = [False]

    def request_cancellation(signum: int, _frame: object) -> None:
        process = process_holder[0]
        if cleanup_active[0]:
            if requested_signal[0] is None:
                requested_signal[0] = signum
            if process is not None:
                try:
                    cleanup_sent_sigkill[0] = (
                        try_signal_group(process.pid, signal.SIGKILL)
                        or cleanup_sent_sigkill[0]
                    )
                except PermissionError:
                    # A signal handler must not poll the leader or print. Cleanup's own
                    # signals follow, or already ran against an earlier state of the group,
                    # and warn on an EPERM an exited leader does not explain (2026-10-05).
                    pass
            return
        if requested_signal[0] is None:
            requested_signal[0] = signum
            raise CancellationRequested(signum)
        # A cancellation is already being handled, and its cleanup has run or is about to. A
        # repeated signal accelerates it without raising again through `communicate()` and
        # abandoning the isolated group.
        if process is not None:
            kill_group_after_cancellation(process)

    def cleanup_process(process: subprocess.Popen, grace: float) -> Optional[bytes]:
        """Run group cleanup without letting a concurrent cancellation abandon it."""
        cleanup_active[0] = True
        cleanup_sent_sigkill[0] = False
        try:
            return stop_process_group(process, grace, cleanup_sent_sigkill)
        finally:
            cleanup_active[0] = False

    previous_handlers = {}
    output: Optional[bytes] = None
    status: int
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, CANCELLATION_SIGNALS)
    cancellation_masked = True

    def restore_child_mask() -> None:
        # The parent blocks cancellation across Popen. Undo that inherited mask in the child
        # before exec so TERM remains effective during the wrapper's graceful cleanup phase.
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

    try:
        try:
            process = subprocess.Popen(
                args.command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                start_new_session=True,
                preexec_fn=restore_child_mask,
            )
        except OSError as error:
            print(f"bounded_exec: failed to spawn {args.command[0]!r}: {error}", file=sys.stderr)
            return 125

        process_holder[0] = process
        try:
            for cancellation_signal in CANCELLATION_SIGNALS:
                previous_handlers[cancellation_signal] = signal.signal(
                    cancellation_signal, request_cancellation
                )
            try:
                # Mark the mask restored before unblocking: delivery of a signal already pending
                # from Popen can raise synchronously from pthread_sigmask itself.
                cancellation_masked = False
                signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
                try:
                    output, _ = process.communicate(timeout=args.timeout)
                except subprocess.TimeoutExpired:
                    output = cleanup_process(process, args.grace)
                    status = TIMEOUT_STATUS
                else:
                    status = child_status(process.returncode)
                # Atomically leave the result-selection region with cancellation blocked. A
                # signal delivered before this block is caught below; once the block succeeds,
                # temporary handlers can be restored without a late signal escaping the guard.
                signal.pthread_sigmask(signal.SIG_BLOCK, CANCELLATION_SIGNALS)
                cancellation_masked = True
            except CancellationRequested as cancellation:
                # Intentionally discard everything buffered before cancellation. The caller
                # asked to stop, and a partial Notes response can contain a live identifier.
                cleanup_process(process, args.grace)
                output = None
                status = 128 + cancellation.signum
            except subprocess.TimeoutExpired:
                # Defensive only: cleanup owns its grace expiry and must never leak the group.
                cleanup_process(process, args.grace)
                output = None
                status = TIMEOUT_STATUS
            except BaseException:
                cleanup_process(process, args.grace)
                raise
        finally:
            # Scope temporary handlers without reopening a cancellation window while they are
            # restored. The outer finally reinstates the exact prior mask afterward.
            if not cancellation_masked:
                signal.pthread_sigmask(signal.SIG_BLOCK, CANCELLATION_SIGNALS)
                cancellation_masked = True
            for cancellation_signal, previous_handler in previous_handlers.items():
                signal.signal(cancellation_signal, previous_handler)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)

    emit(output)
    return status


if __name__ == "__main__":
    raise SystemExit(run())
