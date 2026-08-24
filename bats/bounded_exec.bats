#!/usr/bin/env bats
# Contract tests for the portable bounded process-group wrapper used by live-tier Bats cases.
# Fixtures use only synthetic processes and payloads.

@test "bounded_exec preserves child results and restores signal state" {
  local bounded="$BATS_TEST_DIRNAME/helpers/bounded_exec.py"

  # A child that exits before the deadline keeps its status and combined output exactly.
  run /usr/bin/python3 "$bounded" --timeout 10 --grace 0.1 -- \
    /usr/bin/python3 -c \
      'import sys; print("child-stdout", flush=True); print("child-stderr", file=sys.stderr, flush=True); sys.exit(23)'
  [ "$status" -eq 23 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "child-stdout" ]
  [ "${lines[1]}" = "child-stderr" ]

  # Spawn failures are never mistaken for timeouts or child statuses.
  run /usr/bin/python3 "$bounded" --timeout 1 --grace 0.1 -- /definitely-not-an-executable
  [ "$status" -eq 125 ]
  [[ "$output" == *"failed to spawn"* ]]

  # The wrapper's temporary parent mask must not survive exec into the wrapped command.
  run /usr/bin/python3 "$bounded" --timeout 10 --grace 0.1 -- \
    /usr/bin/python3 -c '
import signal
current = signal.pthread_sigmask(signal.SIG_BLOCK, [])
blocked = {signal.SIGHUP, signal.SIGINT, signal.SIGTERM}
raise SystemExit(1 if current.intersection(blocked) else 0)
'
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # Normal completion and spawn failure both restore the importing process's prior handlers/mask.
  run /usr/bin/python3 -c '
import contextlib, importlib.util, io, signal, sys
spec = importlib.util.spec_from_file_location("bounded_exec", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
signals = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
before_mask = signal.pthread_sigmask(signal.SIG_BLOCK, [])
before_handlers = {item: signal.getsignal(item) for item in signals}
assert module.run(["--timeout", "1", "--grace", "0.1", "--", "/usr/bin/true"]) == 0
assert signal.pthread_sigmask(signal.SIG_BLOCK, []) == before_mask
assert {item: signal.getsignal(item) for item in signals} == before_handlers
with contextlib.redirect_stderr(io.StringIO()):
    assert module.run([
        "--timeout", "1", "--grace", "0.1", "--", "/definitely-not-an-executable",
    ]) == 125
assert signal.pthread_sigmask(signal.SIG_BLOCK, []) == before_mask
assert {item: signal.getsignal(item) for item in signals} == before_handlers
' "$bounded"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # A cancellation arriving after result selection but before temporary handler restoration must
  # still take the guarded cancellation path. Inject it immediately before the second SIG_BLOCK,
  # which is the final handler/mask transition after a normally completed child.
  run /usr/bin/python3 -c '
import importlib.util, os, signal, sys
spec = importlib.util.spec_from_file_location("bounded_exec", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
real_pthread_sigmask = module.signal.pthread_sigmask
block_calls = []

def cancel_before_second_block(how, mask):
    if how == signal.SIG_BLOCK:
        block_calls.append(1)
        if len(block_calls) == 2:
            os.kill(os.getpid(), signal.SIGTERM)
    return real_pthread_sigmask(how, mask)

module.signal.pthread_sigmask = cancel_before_second_block
try:
    status = module.run([
        "--timeout", "1", "--grace", "0.1", "--",
        "/usr/bin/printf", "synthetic-buffered-output",
    ])
finally:
    module.signal.pthread_sigmask = real_pthread_sigmask
assert status == 143, (status, len(block_calls))
' "$bounded"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "bounded_exec cleanup is idempotent and handles signal re-entry" {
  local bounded="$BATS_TEST_DIRNAME/helpers/bounded_exec.py"

  run /usr/bin/python3 -c '
import importlib.util, os, signal, subprocess, sys
spec = importlib.util.spec_from_file_location("bounded_exec", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
process = subprocess.Popen(
    [sys.executable, "-c", "pass"],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    start_new_session=True,
)
process.communicate()
assert process.returncode == 0
module.stop_process_group(process, 0.05)
module.stop_process_group(process, 0.05)
assert process.returncode == 0

real_signal_group = module.signal_group
real_drain_output = module.drain_output
active = subprocess.Popen(
    ["/bin/sleep", "5"],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    start_new_session=True,
)
module.signal_group = lambda _process_group, _item: (_ for _ in ()).throw(
    PermissionError(1, "injected active-group denial")
)
try:
    try:
        module.stop_process_group(active, 0.05)
    except PermissionError:
        pass
    else:
        raise AssertionError("active-group EPERM must remain loud")
finally:
    real_signal_group(active.pid, signal.SIGKILL)
    active.communicate(timeout=1)

active_after_grace = subprocess.Popen(
    ["/bin/sleep", "5"],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    start_new_session=True,
)
signal_calls = []
module.drain_output = lambda _process, _grace: (None, False)
def active_after_grace_eperm(_process_group, item):
    signal_calls.append(item)
    if len(signal_calls) == 2:
        raise PermissionError(1, "injected active-group denial after grace")
module.signal_group = active_after_grace_eperm
try:
    try:
        module.stop_process_group(active_after_grace, 0.05)
    except PermissionError:
        pass
    else:
        raise AssertionError("post-grace active-group EPERM must remain loud")
finally:
    module.drain_output = real_drain_output
    real_signal_group(active_after_grace.pid, signal.SIGKILL)
    active_after_grace.communicate(timeout=1)

module.signal_group = real_signal_group

run_calls = []
run_drain_calls = []
real_killpg = module.os.killpg
def run_handler_success_drain(process, grace):
    run_drain_calls.append(1)
    if len(run_drain_calls) == 1:
        os.kill(os.getpid(), signal.SIGTERM)
        return None, False
    return real_drain_output(process, grace)
def run_handler_success_signal(process_group, item):
    run_calls.append(item)
    return real_killpg(process_group, item)
module.drain_output = run_handler_success_drain
module.os.killpg = run_handler_success_signal
try:
    status = module.run([
        "--timeout", "1", "--grace", "0.2", "--",
        sys.executable, "-c",
        "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(5)",
    ])
    assert status == module.TIMEOUT_STATUS, (status, run_calls)
    assert run_calls[0] == signal.SIGTERM, (status, run_calls)
    assert signal.SIGKILL in run_calls, (status, run_calls)
finally:
    module.drain_output = real_drain_output
    module.os.killpg = real_killpg

run_calls = []
run_drain_calls = []
def run_handler_eperm_drain(process, grace):
    run_drain_calls.append(1)
    if len(run_drain_calls) == 1:
        os.kill(os.getpid(), signal.SIGTERM)
        return None, False
    return real_drain_output(process, grace)
def run_handler_eperm_try_signal(process_group, item):
    run_calls.append(item)
    if item == signal.SIGKILL and len([call for call in run_calls if call == signal.SIGKILL]) == 1:
        raise PermissionError(1, "injected handler process-group denial")
    return real_killpg(process_group, item)
module.drain_output = run_handler_eperm_drain
module.os.killpg = run_handler_eperm_try_signal
try:
    status = module.run([
        "--timeout", "1", "--grace", "0.2", "--",
        sys.executable, "-c",
        "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(5)",
    ])
    assert status == module.TIMEOUT_STATUS, (status, run_calls)
    assert run_calls[0] == signal.SIGTERM, (status, run_calls)
    assert signal.SIGKILL in run_calls, (status, run_calls)
finally:
    module.drain_output = real_drain_output
    module.os.killpg = real_killpg
' "$bounded"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "bounded_exec deadlines clean process groups during signal re-entry" {
  local bounded="$BATS_TEST_DIRNAME/helpers/bounded_exec.py"

  # Deadline path 1: SIGTERM is enough. The wrapper still returns its own timeout sentinel.
  run /usr/bin/python3 "$bounded" --timeout 0.05 --grace 0.2 -- /bin/sleep 5
  [ "$status" -eq 124 ]
  [ -z "$output" ]

  # Deadline path 2: a TERM-ignoring child forces process-group SIGKILL, but still returns 124.
  run /usr/bin/python3 "$bounded" --timeout 5 --grace 0.5 -- \
    /usr/bin/python3 -c \
      'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print("term-ignored", flush=True); time.sleep(10)'
  [ "$status" -eq 124 ]
  [ "$output" = "term-ignored" ]

  # A signal received after deadline cleanup starts must accelerate cleanup without escaping the
  # TimeoutExpired handler or changing status 124. Popen waits for the child's atomic readiness
  # marker, so the 0.1s deadline starts only after its TERM handler is installed.
  local cleanup_signal
  for cleanup_signal in HUP INT TERM; do
    local cleanup_state="$BATS_TEST_TMPDIR/cleanup-$cleanup_signal.state"
    run /usr/bin/python3 -c '
import importlib.util, os, signal, sys, time
spec = importlib.util.spec_from_file_location("bounded_exec", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
state, signal_name = sys.argv[2:]
real_popen = module.subprocess.Popen

def ready_popen(*args, **kwargs):
    process = real_popen(*args, **kwargs)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            with open(state, encoding="utf-8") as handle:
                if handle.read().strip() == str(process.pid):
                    return process
        except FileNotFoundError:
            pass
        time.sleep(0.01)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=1)
    raise SystemExit(96)

module.subprocess.Popen = ready_popen
child_source = r"""
import os, signal, sys, time
target = getattr(signal, "SIG" + sys.argv[2])
def during_cleanup(_signum, _frame):
    os.kill(os.getppid(), target)
signal.signal(signal.SIGTERM, during_cleanup)
temporary = sys.argv[1] + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    handle.write(f"{os.getpid()}\n")
os.replace(temporary, sys.argv[1])
time.sleep(5)
"""
raise SystemExit(module.run([
    "--timeout", "0.1", "--grace", "0.5", "--",
    sys.executable, "-c", child_source, state, signal_name,
]))
' "$bounded" "$cleanup_state" "$cleanup_signal"
    local cleanup_status="$status"
    local cleanup_output="$output"
    local cleanup_child=""
    [ -s "$cleanup_state" ] && read -r cleanup_child < "$cleanup_state"
    local cleanup_gone=1
    if [[ "$cleanup_child" =~ ^[0-9]+$ ]]; then
      /usr/bin/python3 -c '
import os, sys, time
pid = int(sys.argv[1])
deadline = time.monotonic() + 1
while time.monotonic() < deadline:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        raise SystemExit(0)
    time.sleep(0.01)
raise SystemExit(1)
' "$cleanup_child" && cleanup_gone=0
      if [ "$cleanup_gone" -ne 0 ]; then
        /usr/bin/python3 -c '
import os, signal, sys
try:
    os.killpg(int(sys.argv[1]), signal.SIGKILL)
except ProcessLookupError:
    pass
' "$cleanup_child"
      fi
    fi
    if [ "$cleanup_status" -ne 124 ]; then
      echo "cleanup signal $cleanup_signal returned $cleanup_status: $cleanup_output"
      return 1
    fi
    [ "$cleanup_gone" -eq 0 ]
    [[ "$cleanup_output" != *"Traceback"* ]]
  done
}

@test "bounded_exec bounds detached pipes and removes timed-out descendants" {
  local bounded="$BATS_TEST_DIRNAME/helpers/bounded_exec.py"

  # A detached descendant can outlive the killed child group while retaining its stdout pipe.
  # The helper must bound that post-KILL drain instead of waiting forever for EOF. This outer
  # harness has its own deadline and kills every exact synthetic process group on the red path.
  local detached_state="$BATS_TEST_TMPDIR/detached-pipe.state"
  run /usr/bin/python3 -c '
import os, signal, subprocess, sys, time

bounded, state = sys.argv[1:]
child_source = r"""
import os, signal, subprocess, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
descendant = subprocess.Popen(
    [sys.executable, "-c", "import time; time.sleep(10)"],
    stdin=subprocess.DEVNULL,
    start_new_session=True,
)
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(f"{os.getpid()} {descendant.pid}\n")
os.replace(sys.argv[1], sys.argv[1].removesuffix(".tmp"))
time.sleep(10)
"""
wrapper = subprocess.Popen(
    [sys.executable, bounded, "--timeout", "5", "--grace", "0.05", "--",
     sys.executable, "-c", child_source, state + ".tmp"],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    start_new_session=True,
)
state_pids = None
ready_deadline = time.monotonic() + 10
while time.monotonic() < ready_deadline:
    try:
        with open(state, encoding="utf-8") as handle:
            values = handle.read().split()
        if len(values) == 2 and all(value.isdecimal() for value in values):
            parsed = tuple(int(value) for value in values)
            if parsed[0] != parsed[1] and all(os.getpgid(pid) == pid for pid in parsed):
                state_pids = parsed
                break
    except (FileNotFoundError, ProcessLookupError, ValueError):
        pass
    time.sleep(0.01)

timed_out = False
output = b""
try:
    if state_pids is not None:
        try:
            output, _ = wrapper.communicate(timeout=7)
        except subprocess.TimeoutExpired:
            timed_out = True
finally:
    process_groups = {wrapper.pid}
    if state_pids is not None:
        process_groups.update(state_pids)
    else:
        # The precondition failed before the helper deadline. Discover only descendants of this
        # exact synthetic wrapper so every known group is removed before returning the red code.
        listing = subprocess.run(
            ["/bin/ps", "-axo", "pid=,ppid=,pgid="],
            check=True,
            stdout=subprocess.PIPE,
            text=True,
        ).stdout
        records = []
        for line in listing.splitlines():
            fields = line.split()
            if len(fields) == 3:
                try:
                    records.append(tuple(int(value) for value in fields))
                except ValueError:
                    pass
        descendants = {wrapper.pid}
        changed = True
        while changed:
            changed = False
            for pid, parent, process_group in records:
                if parent in descendants and pid not in descendants:
                    descendants.add(pid)
                    process_groups.add(process_group)
                    changed = True
    for process_group in process_groups:
        try:
            os.killpg(process_group, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        wrapper.wait(timeout=0.2)
    except subprocess.TimeoutExpired:
        wrapper.kill()
        wrapper.wait(timeout=0.2)

if state_pids is None:
    raise SystemExit(93)
if timed_out:
    raise SystemExit(91)
if wrapper.returncode != 124 or b"Traceback" in output:
    raise SystemExit(92)
' "$bounded" "$detached_state"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # Descendants inherit the new session/process group and cannot outlive a timed-out parent.
  run /usr/bin/python3 "$bounded" --timeout 5 --grace 0.5 -- \
    /usr/bin/python3 -c '
import subprocess, sys, time
child = subprocess.Popen([
    sys.executable, "-c",
    "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(10)",
], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(child.pid, flush=True)
time.sleep(10)
'
  [ "$status" -eq 124 ]
  local descendant_pid="$output"
  [[ "$descendant_pid" =~ ^[0-9]+$ ]]
  run /usr/bin/python3 -c '
import os, sys, time
pid = int(sys.argv[1])
deadline = time.monotonic() + 1
while time.monotonic() < deadline:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        raise SystemExit(0)
    time.sleep(0.01)
raise SystemExit(1)
' "$descendant_pid"
  [ "$status" -eq 0 ]
}

@test "bounded_exec cancellation returns signal status and removes descendants" {
  local bounded="$BATS_TEST_DIRNAME/helpers/bounded_exec.py"

  # Deterministically inject SIGTERM after Popen creates the isolated child but before it returns
  # to `run()`. The wrapper must defer delivery until its handler owns the known child group.
  local spawn_window_state="$BATS_TEST_TMPDIR/spawn-window.state"
  run /usr/bin/python3 -c '
import importlib.util, os, signal, sys
spec = importlib.util.spec_from_file_location("bounded_exec", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
real_popen = module.subprocess.Popen

def interrupted_popen(*args, **kwargs):
    process = real_popen(*args, **kwargs)
    with open(sys.argv[2], "w", encoding="utf-8") as state:
        state.write(f"{process.pid}\n")
    os.kill(os.getpid(), signal.SIGTERM)
    return process

module.subprocess.Popen = interrupted_popen
raise SystemExit(module.run([
    "--timeout", "30", "--grace", "0.05", "--", "/bin/sleep", "5",
]))
' "$bounded" "$spawn_window_state"
  local spawn_window_status="$status"
  local spawn_window_output="$output"
  local spawn_window_child=""
  [ -s "$spawn_window_state" ] && read -r spawn_window_child < "$spawn_window_state"
  local spawn_window_gone=1
  if [[ "$spawn_window_child" =~ ^[0-9]+$ ]]; then
    /usr/bin/python3 -c '
import os, sys, time
pid = int(sys.argv[1])
deadline = time.monotonic() + 1
while time.monotonic() < deadline:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        raise SystemExit(0)
    time.sleep(0.01)
raise SystemExit(1)
' "$spawn_window_child" && spawn_window_gone=0
    if [ "$spawn_window_gone" -ne 0 ]; then
      /usr/bin/python3 -c '
import os, signal, sys
try:
    os.killpg(int(sys.argv[1]), signal.SIGKILL)
except ProcessLookupError:
    pass
' "$spawn_window_child"
    fi
  fi
  [ "$spawn_window_status" -eq 143 ]
  [ "$spawn_window_gone" -eq 0 ]
  [ -z "$spawn_window_output" ]

  # Cancelling the wrapper must clean up its isolated child group, discard buffered output, and
  # preserve the conventional 128+signal status. The children ignore all three signals so every
  # case exercises bounded KILL escalation. A delayed second signal remains harmless whether
  # cleanup is still active or the wrapper has already exited; the active-cleanup race is pinned
  # separately above.
  local cancellation_case
  for cancellation_case in TERM:143 INT:130 HUP:129; do
    local cancellation_signal="${cancellation_case%%:*}"
    local expected_status="${cancellation_case##*:}"
    local state_file="$BATS_TEST_TMPDIR/cancel-$cancellation_signal.state"
    local captured_file="$BATS_TEST_TMPDIR/cancel-$cancellation_signal.output"

    /usr/bin/python3 "$bounded" --timeout 30 --grace 0.05 -- \
      /usr/bin/python3 -c '
import os, signal, subprocess, sys, time
for name in ("SIGHUP", "SIGINT", "SIGTERM"):
    signal.signal(getattr(signal, name), signal.SIG_IGN)
descendant = subprocess.Popen([
    sys.executable, "-c",
    "import signal,time\nfor name in (\"SIGHUP\", \"SIGINT\", \"SIGTERM\"):\n signal.signal(getattr(signal, name), signal.SIG_IGN)\ntime.sleep(5)\n",
], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.05)
print("partial-live-payload", flush=True)
temporary = sys.argv[1] + ".tmp"
with open(temporary, "w", encoding="utf-8") as state:
    state.write(f"{os.getpid()} {descendant.pid}\n")
os.replace(temporary, sys.argv[1])
time.sleep(5)
' "$state_file" >"$captured_file" 2>&1 &
    local wrapper_pid=$!
    local ready=0
    if /usr/bin/python3 -c '
import os, sys, time
deadline = time.monotonic() + 10
while time.monotonic() < deadline:
    try:
        if os.path.getsize(sys.argv[1]) > 0:
            raise SystemExit(0)
    except FileNotFoundError:
        pass
    time.sleep(0.01)
raise SystemExit(1)
' "$state_file"; then
      ready=1
    fi
    if [ "$ready" -ne 1 ]; then
      # Let the wrapper's TERM handler clean its isolated child group. If the wrapper still does
      # not exit, kill it and only direct children proven to lead their own process groups.
      /usr/bin/python3 -c '
import os, signal, subprocess, sys, time
wrapper = int(sys.argv[1])
listing = subprocess.run(
    ["/bin/ps", "-axo", "pid=,ppid=,pgid="],
    check=True,
    stdout=subprocess.PIPE,
    text=True,
).stdout
child_groups = []
for line in listing.splitlines():
    fields = line.split()
    if len(fields) != 3:
        continue
    try:
        child, parent, group = (int(value) for value in fields)
    except ValueError:
        continue
    if parent == wrapper and group == child:
        child_groups.append(group)
try:
    os.kill(wrapper, signal.SIGTERM)
except ProcessLookupError:
    pass
deadline = time.monotonic() + 1
while time.monotonic() < deadline:
    try:
        os.kill(wrapper, 0)
    except ProcessLookupError:
        break
    time.sleep(0.01)
else:
    try:
        os.kill(wrapper, signal.SIGKILL)
    except ProcessLookupError:
        pass
for process_group in child_groups:
    try:
        os.killpg(process_group, signal.SIGKILL)
    except ProcessLookupError:
        pass
' "$wrapper_pid"
      wait "$wrapper_pid" 2>/dev/null || true
      echo "bounded cancellation fixture failed to become ready: $cancellation_signal"
      return 1
    fi

    local cancel_child_pid cancel_descendant_pid
    read -r cancel_child_pid cancel_descendant_pid < "$state_file"
    [[ "$cancel_child_pid" =~ ^[0-9]+$ ]]
    [[ "$cancel_descendant_pid" =~ ^[0-9]+$ ]]
    /bin/kill -s "$cancellation_signal" "$wrapper_pid"
    if [ "$cancellation_signal" = TERM ]; then
      /bin/sleep 0.25
      /bin/kill -s INT "$wrapper_pid" 2>/dev/null || true
    fi
    local wrapper_status=0
    wait "$wrapper_pid" || wrapper_status=$?

    local gone_status=0
    /usr/bin/python3 -c '
import os, sys, time
pids = [int(value) for value in sys.argv[1:]]
deadline = time.monotonic() + 1
while time.monotonic() < deadline:
    alive = []
    for pid in pids:
        try:
            os.kill(pid, 0)
            alive.append(pid)
        except ProcessLookupError:
            pass
    if not alive:
        raise SystemExit(0)
    time.sleep(0.01)
raise SystemExit(1)
' "$cancel_child_pid" "$cancel_descendant_pid" || gone_status=$?

    # Mandatory red-path cleanup: sweep only when disappearance was not confirmed.
    if [ "$gone_status" -ne 0 ]; then
      /usr/bin/python3 -c '
import os, signal, sys
try:
    os.killpg(int(sys.argv[1]), signal.SIGKILL)
except ProcessLookupError:
    pass
' "$cancel_child_pid"
    fi

    [ "$wrapper_status" -eq "$expected_status" ]
    [ "$gone_status" -eq 0 ]
    [ ! -s "$captured_file" ]
  done
}
