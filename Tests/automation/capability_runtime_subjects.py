"""Inert synthetic executable and child assertions for qualified acceptance only.

No discovery test or skip grants transport verification. A later explicitly
qualified lane must call run_qualified_subject and assert_child_transport with
real child observations; the canonical no-spawn lane does not execute this file.
"""
from pathlib import Path

# These executables only emulate the three Swift stages and the resulting dump command.
# They never dispatch another executable or load the candidate's source as code.
FAKE_EXECUTABLE = r'''
import json, os, pathlib, sys
config = json.loads(pathlib.Path(CONFIG_PATH).read_text())
args = sys.argv[1:]
if pathlib.Path(sys.argv[0]).name == "apple":
    stage = "dump"
else:
    stage = "test" if args[0] == "test" else "bin" if "--show-bin-path" in args else "build"
with open(config["log"], "a") as log:
    log.write(json.dumps({"stage": stage, "argv": sys.argv, "cwd": os.getcwd(),
                          "environment": dict(os.environ), "stdin_empty": sys.stdin.buffer.read() == b""}) + "\n")
if config.get("fail") == stage:
    print("synthetic stage failure", file=sys.stderr)
    sys.exit(9)
if stage == "test":
    pathlib.Path(args[args.index("--xunit-output") + 1]).write_bytes(bytes.fromhex(config["xml_hex"]))
elif stage == "build":
    binary = pathlib.Path(args[args.index("--scratch-path") + 1]) / "debug" / "apple"
    binary.parent.mkdir(parents=True)
    binary.write_text(pathlib.Path(sys.argv[0]).read_text())
    binary.chmod(0o700)
elif stage == "bin":
    if config.get("outside_bin"):
        print(pathlib.Path(CONFIG_PATH).parent)
    else:
        print(pathlib.Path(args[args.index("--scratch-path") + 1]) / "debug")
else:
    sys.stdout.buffer.write(bytes.fromhex(config["dump_hex"]))
'''



def assert_child_transport(case, calls, *, expected_environment, root):
    """Preserve the original actual-child stdin/environment checks."""
    case.assertTrue(calls)
    for child in calls:
        case.assertEqual(child["cwd"], str(root))
        case.assertTrue(child["stdin_empty"])
        observed = dict(child["environment"])
        # macOS may add this at child startup; no arbitrary ambient entry passes.
        observed.pop("__CF_USER_TEXT_ENCODING", None)
        case.assertEqual(observed, expected_environment)


def run_qualified_subject(policy, session, root, sha, tree_oid):
    """No fake admission or fallback; caller supplies the actual qualified session."""
    from capability_process import require_process_session
    admitted = require_process_session(session)
    return policy._default_runtime_runner(root, sha, tree_oid, process_session=admitted)
