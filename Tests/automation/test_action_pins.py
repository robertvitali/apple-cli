import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from types import ModuleType
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
CHECKER_PATH = REPO_ROOT / "scripts" / "ci" / "action_pins.py"
POLICY_PATH = REPO_ROOT / "scripts" / "ci" / "workflow_policy.py"
WORKFLOWS_ROOT = REPO_ROOT / ".github" / "workflows"
ALLOWLIST_PATH = REPO_ROOT / ".github" / "actions-allowlist.json"

# How often each Action is used: an expectation of workflow usage kept independently of the
# allowlist. The allowlist, .github/actions-allowlist.json, is the only list of pins. Test
# fixtures read the pins they need from it (`reviewed_pin`, REVIEWED_CHECKOUT_SHA), so a refusal
# test starts from the reviewed pin whatever it is; only the urgent-release runbook's recorded
# workflow, restored verbatim on the day, quotes pins (checkout and upload-artifact) and moves
# with a bump of them.
EXPECTED_ACTION_COUNTS = {
    "actions/checkout": 10,
    "actions/setup-python": 2,
    "astral-sh/setup-uv": 1,
    "actions/upload-artifact": 1,
    "actions/download-artifact": 1,
}

# The workflow the urgent-release runbook (docs/runbooks/urgent-release.md) restores for one
# release adds exactly these references while it exists. test_urgent_release_runbook.py pins them
# against the recorded text, and pins a restored copy byte for byte to that text.
URGENT_RELEASE_WORKFLOW = WORKFLOWS_ROOT / "urgent-release-verify.yml"
URGENT_RELEASE_ACTION_COUNTS = {"actions/checkout": 1, "actions/upload-artifact": 1}


def load_checker() -> ModuleType:
    spec = importlib.util.spec_from_file_location("action_pins", CHECKER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load action pin checker")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_policy() -> ModuleType:
    spec = importlib.util.spec_from_file_location("workflow_policy", POLICY_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load workflow policy")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


REVIEWED_CHECKOUT_SHA, REVIEWED_CHECKOUT_VERSION = load_checker().load_allowlist(ALLOWLIST_PATH)["actions/checkout"]


def reviewed_pin(name: str) -> str:
    """The `uses:` text of an allowlisted Action, read from the reviewed allowlist, so a pin bump
    changes the allowlist and the workflows and no test."""
    sha, version = load_checker().load_allowlist(ALLOWLIST_PATH)[name]
    return f"{name}@{sha} # {version}"


def write_workflow(root: Path, relative: str, body: str) -> Path:
    path = root / ".github" / "workflows" / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    return path


def workflow_job(source: str, name: str) -> str:
    match = re.search(
        rf"(?ms)^  {re.escape(name)}:\n(?P<body>.*?)(?=^  [a-z0-9-]+:\n|\Z)",
        source,
    )
    if match is None:
        raise AssertionError(f"workflow job is missing: {name}")
    return match.group("body")


def workflow_named_step(job: str, name: str) -> str:
    match = re.search(
        rf"(?ms)^      - name: {re.escape(name)}\n(?P<body>.*?)(?=^      - (?:name:|uses:)|\Z)",
        job,
    )
    if match is None:
        raise AssertionError(f"workflow step is missing: {name}")
    return match.group("body")


class ActionPinPolicyTests(unittest.TestCase):
    def test_bootstrap_has_no_release_workflow(self) -> None:
        self.assertFalse((WORKFLOWS_ROOT / "release.yml").exists())
        self.assertFalse((WORKFLOWS_ROOT / "release.yaml").exists())

    def test_bootstrap_workflows_are_read_only_and_have_no_publishers(self) -> None:
        workflows = {
            path.name: path.read_text(encoding="utf-8")
            for suffix in ("*.yml", "*.yaml")
            for path in WORKFLOWS_ROOT.glob(suffix)
        }
        combined = "\n".join(workflows.values())
        forbidden_patterns = {
            "manual dispatch": r"(?m)^\s*workflow_dispatch\s*:",
            "write permission": r"(?m)^\s*[^#\s][^:]*:\s*write(?:\s*(?:#.*)?)?$",
            "write-all permissions": r"(?m)^\s*permissions\s*:\s*write-all(?:\s*(?:#.*)?)?$",
            "deployment environment": r"(?m)^\s*environment\s*:",
            "Pages action": r"(?m)^\s*(?:-\s+)?uses:\s*actions/(?:configure-pages|upload-pages-artifact|deploy-pages)@",
            "git publisher": r"\bgit\s+(?:commit|push|tag)\b",
            "GitHub release publisher": r"\bgh\s+release\s+(?:create|edit|delete|upload)\b",
            "GitHub workflow token": r"\$\{\{\s*github\.token\s*\}\}",
        }
        for publisher, pattern in forbidden_patterns.items():
            with self.subTest(publisher=publisher):
                self.assertNotRegex(combined, pattern)

    def test_bootstrap_docs_retains_only_read_only_advisory_jobs(self) -> None:
        docs = (WORKFLOWS_ROOT / "docs.yml").read_text(encoding="utf-8")
        jobs = docs.split("\njobs:\n", 1)[1]
        self.assertEqual(
            re.findall(r"(?m)^  ([a-z0-9-]+):\s*$", jobs),
            ["manual-fresh", "release-notes", "release-prep-rehearsal", "site-assembly-rehearsal"],
        )
        site = workflow_job(docs, "site-assembly-rehearsal")
        # The site rehearsal is read-only: no token reaches it, the Releases listing is read
        # unauthenticated, everything it writes lives under RUNNER_TEMP and goes on exit, and
        # only the value-free report is printed. A rate-limited listing is a notice, not a pass
        # of the assembly (the assembly step exits before running in that case).
        self.assertIn("permissions:\n      contents: read", site)
        self.assertIn("fetch-depth: 0", site)
        self.assertIn("python3 -I -S -B scripts/ci/site_assembly.py", site)
        self.assertIn("--derive-candidate-version", site)
        self.assertIn('--published-from-json "$RUNNER_TEMP/releases.json"', site)
        self.assertIn("pip install --require-hashes -r docs/requirements.txt", site)
        self.assertTrue((REPO_ROOT / "scripts" / "ci" / "site_assembly.py").is_file())
        self.assertNotIn("continue-on-error", site)
        self.assertNotRegex(site, r"upload-artifact|actions/cache|GITHUB_OUTPUT|GITHUB_STEP_SUMMARY|github\.token|secrets\.|GH_TOKEN|Authorization")
        self.assertRegex(site, r"trap 'rm -rf \"\$RUNNER_TEMP/site-scratch\"[^']*' EXIT")
        self.assertIn("x-ratelimit-remaining: 0|retry-after:", site)
        self.assertIn('echo "::warning::site-assembly: the public Releases listing is rate-limited', site)
        self.assertIn('echo "::error::site-assembly: the public Releases listing returned HTTP $status"; exit 1', site)
        self.assertIn('!= run ]; then', site)
        site_run_keys = re.findall(r"(?m)^\s+run:.*$", site)
        site_run_blocks = re.findall(r"(?ms)^        run: \|\n(.*?)(?=^      - |\Z)", site)
        self.assertTrue(site_run_blocks)
        self.assertEqual(len(site_run_keys), len(site_run_blocks))
        for block in site_run_blocks:
            self.assertNotIn("${{", block)
        rehearsal = workflow_job(docs, "release-prep-rehearsal")
        # The rehearsal must stay read-only and must never publish its scratch copies,
        # which carry the predicted version; only the nothing-to-release status (exit 3)
        # is advisory, and exits 1 and 2 fail the job.
        self.assertIn("permissions:\n      contents: read", rehearsal)
        self.assertIn("fetch-depth: 0", rehearsal)
        self.assertIn("python3 -I -S -B scripts/ci/release_prep.py", rehearsal)
        self.assertTrue((REPO_ROOT / "scripts" / "ci" / "release_prep.py").is_file())
        self.assertNotIn("continue-on-error", rehearsal)
        # Only the script's nothing-to-release status (3) is advisory; 1 and 2 fail the job.
        self.assertRegex(rehearsal, r'(?m)^\s+3\) echo "::notice::')
        self.assertNotRegex(rehearsal, r'(?m)^\s+1\) ')
        self.assertRegex(rehearsal, r'(?m)^\s+\*\) echo "::error::[^"]*"; exit "\$status" ;;')
        self.assertNotRegex(rehearsal, r"upload-artifact|actions/cache|GITHUB_OUTPUT|GITHUB_STEP_SUMMARY")
        self.assertIn('--scratch "$RUNNER_TEMP/', rehearsal)
        self.assertRegex(rehearsal, r"trap 'rm -rf \"\$RUNNER_TEMP/release-prep-scratch\"[^']*' EXIT")
        # The job also builds and checks the release binary from the candidate plus release
        # preparation's two rendered files, which needs the macOS image; nothing is built when
        # there is nothing to release, and the work directory (binary, archive) goes on exit.
        self.assertIn("runs-on: macos-26", rehearsal)
        self.assertIn("timeout-minutes: 45", rehearsal)
        self.assertTrue((REPO_ROOT / "scripts" / "ci" / "release_artifact.py").is_file())
        self.assertRegex(
            rehearsal,
            r"trap 'rm -rf \"\$RUNNER_TEMP/release-prep-scratch\"[^']*\"\$RUNNER_TEMP/release-artifact-work\"[^']*' EXIT",
        )
        self.assertRegex(rehearsal, r'(?m)^\s+3\) echo "::notice::[^"]*"; exit 0 ;;$')
        artifact_invocation = (
            "          set +e\n"
            "          python3 -I -S -B scripts/ci/release_artifact.py \\\n"
            '            --candidate-root "$RUNNER_TEMP/candidate" \\\n'
            '            --candidate-sha "$CANDIDATE_SHA" \\\n'
            '            --overlay "$RUNNER_TEMP/release-prep-scratch" \\\n'
            '            --work "$RUNNER_TEMP/release-artifact-work"\n'
            "          status=$?\n"
            "          set -e\n"
            '          if [ "$status" != 0 ]; then\n'
            '            echo "::error::release-artifact rehearsal failed (exit $status); see the log"; exit "$status"\n'
            "          fi\n"
        )
        self.assertEqual(rehearsal.count(artifact_invocation), 1)
        self.assertEqual(rehearsal.count("scripts/ci/release_artifact.py"), 1)
        self.assertLess(rehearsal.index("          esac\n"), rehearsal.index(artifact_invocation))
        self.assertIn(
            "      - name: Record build toolchain\n", rehearsal,
        )
        self.assertLess(rehearsal.index("      - name: Record build toolchain\n"),
                        rehearsal.index("      - name: Read-only release-preparation and release-artifact rehearsal"))
        for command in ("sw_vers", "xcode-select -p", "/usr/bin/xcodebuild -version", "/usr/bin/swift --version"):
            self.assertIn(command, workflow_named_step(rehearsal, "Record build toolchain"))
        # Inputs reach the shell through env:, never by expression: every run: must be a
        # literal block and no block may contain an expression marker.
        run_keys = re.findall(r"(?m)^\s+run:.*$", rehearsal)
        run_blocks = re.findall(r"(?ms)^        run: \|\n(.*?)(?=^      - |\Z)", rehearsal)
        self.assertTrue(run_blocks)
        self.assertEqual(len(run_keys), len(run_blocks))
        for block in run_blocks:
            self.assertNotIn("${{", block)
        self.assertEqual(
            re.findall(r"(?m)^permissions:\n(?:  [^\n]+\n?)+", docs),
            ["permissions:\n  contents: read\n"],
        )
        self.assertNotRegex(docs, r"(?i)\bpages\b|\bPAGES_ENABLED\b")

    def test_missing_workflow_directory_is_a_hard_failure(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as directory:
            errors = checker.validate_repository(Path(directory))

        self.assertNotEqual(errors, [])
        self.assertTrue(any("workflow directory" in error for error in errors))

    def test_accepts_only_an_exact_reviewed_remote_action_pin(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            write_workflow(
                root,
                "nested/valid.yaml",
                """name: valid
jobs:
  test:
    steps:
      - uses: """ + reviewed_pin("actions/checkout") + "\n",
            )

            self.assertEqual(checker.validate_repository(root), [])

    def test_ignores_uses_shaped_text_inside_a_run_block(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            write_workflow(
                root,
                "script.yml",
                """name: "uses"
run-name: "quoted text: !!str uses {? uses: value} &anchor *alias"
display-name: safe # !!str uses: inline-comment {? &anchor *alias}
jobs:
  test:
    steps:
      -   run: |
            uses: this-is-shell-text
            !!str uses: tagged-shell-text
            {? uses: flow-shell-text}
            &anchor uses: anchored-shell-text
            *alias: aliased-shell-text
      # !!str uses: tagged-comment-text {? &anchor *alias}
      - uses: """ + reviewed_pin("actions/checkout") + "\n",
            )

            self.assertEqual(checker.validate_repository(root), [])

    def test_rejects_unapproved_remote_local_and_container_references(self) -> None:
        checker = load_checker()
        invalid_values = (
            "vendor/example@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v0.1.0",
            "./build/action",
            "./.github/workflows/reusable.yml",
            "docker://example.invalid/tool@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        )

        for index, invalid_value in enumerate(invalid_values):
            with self.subTest(value=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_workflow(
                    root,
                    "transitive.yml",
                    f"jobs:\n  test:\n    uses: {invalid_value}\n",
                )

                errors = checker.validate_repository(root)

                self.assertNotEqual(errors, [])
                self.assertTrue(all(invalid_value not in error for error in errors))

    def test_rejects_quoted_uses_keys_and_flow_style_uses_nodes(self) -> None:
        checker = load_checker()
        documents = (
            ('jobs:\n  test:\n    "uses": actions/checkout@' + REVIEWED_CHECKOUT_SHA + ' # ' + REVIEWED_CHECKOUT_VERSION + '\n'),
            ("jobs:\n  test:\n    'uses': actions/checkout@" + REVIEWED_CHECKOUT_SHA + " # " + REVIEWED_CHECKOUT_VERSION + "\n"),
            ("jobs: {test: {uses: actions/checkout@" + REVIEWED_CHECKOUT_SHA + "}}\n"),
            ("jobs:\n  test:\n    steps: [{uses: actions/checkout@" + REVIEWED_CHECKOUT_SHA + "}]\n"),
            ('jobs:\n  test:\n    ? "uses"\n    : actions/checkout@' + REVIEWED_CHECKOUT_SHA + '\n'),
            ("jobs:\n  test:\n    ? uses\n    : actions/checkout@" + REVIEWED_CHECKOUT_SHA + "\n"),
            "jobs:\n  test:\n    steps:\n      -   uses: vendor/example@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v0.1.0\n",
            ('jobs: {"u\\u0073es": actions/checkout@' + REVIEWED_CHECKOUT_SHA + '}\n'),
        )

        for index, document in enumerate(documents):
            with self.subTest(document=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_workflow(root, "hostile.yml", document)

                errors = checker.validate_repository(root)

                self.assertNotEqual(errors, [])
                self.assertTrue(any("hostile.yml" in error for error in errors))

    def test_rejects_yaml_structure_that_can_hide_uses_keys(self) -> None:
        checker = load_checker()
        documents = (
            ("jobs:\n  test:\n    !!str uses: actions/checkout@" + REVIEWED_CHECKOUT_SHA + " # " + REVIEWED_CHECKOUT_VERSION + "\n"),
            ("jobs: {test: {? uses: actions/checkout@" + REVIEWED_CHECKOUT_SHA + "}}\n"),
            ("jobs:\n  test:\n    &action-key uses: actions/checkout@" + REVIEWED_CHECKOUT_SHA + " # " + REVIEWED_CHECKOUT_VERSION + "\n"),
            ("key: &action-key uses\njobs:\n  test:\n    *action-key: actions/checkout@" + REVIEWED_CHECKOUT_SHA + " # " + REVIEWED_CHECKOUT_VERSION + "\n"),
            ("jobs:\n  test:\n    !<tag:yaml.org,2002:str> uses: actions/checkout@" + REVIEWED_CHECKOUT_SHA + " # " + REVIEWED_CHECKOUT_VERSION + "\n"),
            ("jobs:\n  test:\n    &é uses: actions/checkout@" + REVIEWED_CHECKOUT_SHA + " # " + REVIEWED_CHECKOUT_VERSION + "\n"),
        )

        for index, document in enumerate(documents):
            with self.subTest(document=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_workflow(root, "structural.yml", document)

                errors = checker.validate_repository(root)

                self.assertNotEqual(errors, [])
                self.assertTrue(all("structural.yml" in error for error in errors))

    def test_rejects_implicit_mappings_inside_flow_sequences(self) -> None:
        checker = load_checker()
        documents = (
            ("jobs:\n  test:\n    steps: [ uses: actions/checkout@" + REVIEWED_CHECKOUT_SHA + " ]\n"),
            ('jobs:\n  test:\n    steps: [ "uses": actions/checkout@' + REVIEWED_CHECKOUT_SHA + ' ]\n'),
            ('jobs:\n  test:\n    steps: [ "u\\u0073es": actions/checkout@' + REVIEWED_CHECKOUT_SHA + ' ]\n'),
        )

        for index, document in enumerate(documents):
            with self.subTest(document=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_workflow(root, "implicit.yml", document)

                errors = checker.validate_repository(root)

                self.assertNotEqual(errors, [])
                self.assertTrue(all("implicit.yml" in error for error in errors))

    def test_allows_scalar_only_flow_sequences(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_workflow(
                root,
                "scalar-array.yml",
                'name: scalar arrays\non:\n  push:\n    branches: [main, "topic:one"]\n',
            )

            self.assertEqual(checker.validate_repository(root), [])

    def test_rejects_reviewed_action_with_changed_sha_or_version_comment(self) -> None:
        checker = load_checker()
        # Built from the reviewed pin, so the only mismatch is the one under test: one nibble of
        # the commit, or the version label beside the reviewed commit.
        other_sha = REVIEWED_CHECKOUT_SHA[:-1] + ("1" if REVIEWED_CHECKOUT_SHA[-1] == "0" else "0")
        major, minor, patch = REVIEWED_CHECKOUT_VERSION[1:].split(".")
        values = (
            f"actions/checkout@{other_sha} # {REVIEWED_CHECKOUT_VERSION}",
            f"actions/checkout@{REVIEWED_CHECKOUT_SHA} # v{major}.{minor}.{int(patch) + 1}",
        )

        for index, value in enumerate(values):
            with self.subTest(value=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_workflow(root, "changed.yml", f"jobs:\n  test:\n    uses: {value}\n")

                errors = checker.validate_repository(root)
                self.assertTrue(any("does not match the reviewed allowlist" in error for error in errors), errors)

    def test_rejects_symlink_and_oversized_workflow_files(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workflow_root = root / ".github" / "workflows"
            workflow_root.mkdir(parents=True)
            target = root / "target.yml"
            target.write_text(
                ("jobs:\n  test:\n    uses: actions/checkout@" + REVIEWED_CHECKOUT_SHA + " # " + REVIEWED_CHECKOUT_VERSION + "\n"),
                encoding="utf-8",
            )
            (workflow_root / "linked.yml").symlink_to(target)
            (workflow_root / "oversized.yml").write_text(
                "#" * (checker.MAX_WORKFLOW_BYTES + 1),
                encoding="utf-8",
            )

            errors = checker.validate_repository(root)

            self.assertTrue(any("linked.yml" in error for error in errors))
            self.assertTrue(any("oversized.yml" in error for error in errors))

    def test_rejects_whitespace_other_than_space_tab_and_line_feed(self) -> None:
        # The same rule the workflow scan applies: whitespace other than space, tab and line feed
        # (Python's isspace() and splitlines() accept more than YAML's separators, and a carriage
        # return is a YAML line break this line scan does not split on), a byte-order mark, a
        # bidirectional control, and any character outside YAML's printable set.
        checker = load_checker()
        pinned = ("actions/checkout@" + REVIEWED_CHECKOUT_SHA + " # " + REVIEWED_CHECKOUT_VERSION)
        for character in ("\u00a0", "\u2028", "\x85", "\x0b", "\r", "\x00", "\x7f", "\x86", "\ufffe", "\ufeff", "\u202e", "\u200f"):
            codepoint = "U+{:04X}".format(ord(character))
            with self.subTest(codepoint=codepoint), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_workflow(root, "odd.yml",
                               "jobs:\n  test:\n    steps:\n      - run: echo ok{}x\n      - uses: {}\n".format(character, pinned))
                errors = checker.validate_repository(root)
                self.assertTrue(any("odd.yml" in error and codepoint in error for error in errors), errors)

    def test_rejects_a_pin_hidden_behind_a_no_break_space(self) -> None:
        # Before the refusal, `@<sha><NBSP>#<NBSP><version>` read here as the approved pin and its
        # annotation, while GitHub reads the whole scalar as the ref: not a SHA.
        checker = load_checker()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_workflow(root, "hidden.yml",
                           "jobs:\n  test:\n    steps:\n      - uses: actions/checkout@"
                           + REVIEWED_CHECKOUT_SHA + "\u00a0#\u00a0" + REVIEWED_CHECKOUT_VERSION + "\n")
            errors = checker.validate_repository(root)
            self.assertTrue(any("hidden.yml" in error and "U+00A0" in error for error in errors), errors)

    def test_block_scalar_under_a_sequence_item_does_not_hide_a_uses_key(self) -> None:
        # For `- name: |` the block's content must be deeper than the key column, not the dash
        # column; a `uses:` at the key column is a sibling key that YAML reads.
        checker = load_checker()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_workflow(root, "hidden.yml",
                           "jobs:\n  test:\n    steps:\n      - name: |\n"
                           "        uses: attacker/evil-action@0123456789abcdef0123456789abcdef01234567 # v1.0.0\n")
            errors = checker.validate_repository(root)
            self.assertTrue(any("hidden.yml" in error and "allowlist" in error for error in errors), errors)

    def test_printed_errors_escape_characters_that_could_start_a_line(self) -> None:
        # A workflow file name may hold a line feed; printed verbatim, `::error::` would start a
        # runner workflow command.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_workflow(root, "x\n::error::injected.yml", "jobs:\n  test:\n    steps:\n      - uses: evil/action@main\n")
            result = subprocess.run([sys.executable, str(CHECKER_PATH), "--root", str(root)],
                                    check=False, capture_output=True, text=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("::error::injected", result.stderr)
            self.assertFalse(any(line.startswith("::") for line in result.stderr.splitlines()), result.stderr)

    def test_refused_character_rule_matches_the_workflow_scan(self) -> None:
        # The two scanners carry the same rule in two places; every code point must agree.
        checker = load_checker()
        spec = importlib.util.spec_from_file_location(
            "workflow_policy", REPO_ROOT / "scripts" / "ci" / "workflow_policy.py"
        )
        policy = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(policy)
        disagreements = [
            code for code in range(0x110000)
            if checker._refused_character(chr(code)) != policy.refused_character(chr(code), " \t")
        ]
        self.assertEqual(disagreements, [])
        self.assertFalse(checker._refused_character(" "))
        self.assertFalse(checker._refused_character("\t"))
        self.assertTrue(checker._refused_character("\n"))  # line feeds are split out before the check

    def test_invisible_character_rule_matches_the_workflow_scan(self) -> None:
        # The second rule, too, is carried in both scanners; every code point must agree under
        # one interpreter (category Cn follows its Unicode database).
        checker = load_checker()
        spec = importlib.util.spec_from_file_location(
            "workflow_policy", REPO_ROOT / "scripts" / "ci" / "workflow_policy.py"
        )
        policy = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(policy)
        disagreements = [
            code for code in range(0x110000)
            if checker._invisible_character(chr(code)) != policy.invisible_character(chr(code))
        ]
        self.assertEqual(disagreements, [])
        self.assertEqual(checker._INVISIBLE_OUTSIDE_FORMAT, policy.INVISIBLE_OUTSIDE_FORMAT)
        self.assertFalse(checker._invisible_character(" "))
        self.assertFalse(checker._invisible_character("a"))

    def test_rejects_invisible_characters(self) -> None:
        checker = load_checker()
        pinned = ("actions/checkout@" + REVIEWED_CHECKOUT_SHA + " # " + REVIEWED_CHECKOUT_VERSION)
        for character in INVISIBLE_SAMPLES:
            codepoint = "U+{:04X}".format(ord(character))
            with self.subTest(codepoint=codepoint), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_workflow(root, "odd.yml",
                               "jobs:\n  test:\n    steps:\n      - run: echo ok{}x\n      - uses: {}\n".format(character, pinned))
                errors = checker.validate_repository(root)
                self.assertTrue(any("odd.yml" in error and codepoint in error and "invisible" in error
                                    for error in errors), errors)

    def test_rejects_nonregular_workflow_without_blocking(self) -> None:
        # The timeout stands in for "never returns". A blocking open of a FIFO that has no writer
        # waits forever, so any finite bound still catches that regression (the run raises
        # TimeoutExpired and the child is killed). A bound of a second or so would mostly measure a
        # fresh interpreter's start-up and imports, which a starved runner can spend most of; 30 s
        # matches the file's other checker subprocess run (the printed-errors test). The checker
        # opens with O_NONBLOCK and refuses a non-regular file after fstat; dropping that flag is
        # the regression, and it blocks forever rather than for some bounded time.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workflow_root = root / ".github" / "workflows"
            workflow_root.mkdir(parents=True)
            os.mkfifo(workflow_root / "nonregular.yml")

            result = subprocess.run(
                [sys.executable, str(CHECKER_PATH), "--root", str(root)],
                check=False,
                capture_output=True,
                text=True,
                timeout=30,
            )

            self.assertNotEqual(result.returncode, 0)

    def test_rejects_every_mutable_or_ambiguous_uses_shape(self) -> None:
        checker = load_checker()
        invalid_values = (
            "actions/checkout@v7",
            "actions/checkout@" + REVIEWED_CHECKOUT_SHA.upper() + " # " + REVIEWED_CHECKOUT_VERSION,
            ("actions/checkout@" + REVIEWED_CHECKOUT_SHA),
            "actions/checkout@${{ github.sha }} # " + REVIEWED_CHECKOUT_VERSION,
            "docker://example.invalid/tool:latest",
            "docker://example.invalid/tool@sha256:AAAA",
            "./local/action",
            "../shared/action",
            ">",
            "|",
            "",
        )

        for index, invalid_value in enumerate(invalid_values):
            with self.subTest(value=index), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_workflow(
                    root,
                    "invalid.yml",
                    f"jobs:\n  test:\n    uses: {invalid_value}\n",
                )

                errors = checker.validate_repository(root)

                self.assertNotEqual(errors, [])
                self.assertTrue(all("invalid.yml:3:" in error for error in errors))
                if invalid_value:
                    self.assertTrue(all(invalid_value not in error for error in errors))

    def test_finds_both_yml_and_yaml_recursively(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            write_workflow(root, "first.yml", "jobs:\n  a:\n    uses: bad@ref\n")
            write_workflow(root, "nested/second.yaml", "jobs:\n  b:\n    uses: bad@ref\n")

            errors = checker.validate_repository(root)

            self.assertEqual(len(errors), 2)
            self.assertTrue(any("first.yml:3:" in error for error in errors))
            self.assertTrue(any("second.yaml:3:" in error for error in errors))

    def test_diagnostics_do_not_echo_references(self) -> None:
        checker = load_checker()
        secret_shaped_reference = "vendor.invalid/private-action@private-ref"
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            write_workflow(
                root,
                "private.yml",
                f"jobs:\n  test:\n    uses: {secret_shaped_reference}\n",
            )

            errors = checker.validate_repository(root)

            self.assertNotEqual(errors, [])
            self.assertFalse(any(secret_shaped_reference in error for error in errors))

    def test_rejects_malformed_or_duplicate_uses_keys_fail_closed(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            write_workflow(
                root,
                "malformed.yml",
                ("""jobs:
  test:
    uses : actions/checkout@""" + REVIEWED_CHECKOUT_SHA + """ # """ + REVIEWED_CHECKOUT_VERSION + """
    uses: actions/checkout@""" + REVIEWED_CHECKOUT_SHA + """ # """ + REVIEWED_CHECKOUT_VERSION + """
"""),
            )

            errors = checker.validate_repository(root)

            self.assertTrue(any("malformed.yml:4:" in error and "duplicate uses key in one mapping" in error
                                for error in errors), errors)


class RepositoryActionInventoryTests(unittest.TestCase):
    def test_all_repository_workflows_pass_the_generic_checker(self) -> None:
        checker = load_checker()

        self.assertEqual(checker.validate_repository(REPO_ROOT), [])

    def test_remote_action_inventory_is_exact_and_version_annotated(self) -> None:
        checker = load_checker()

        # collect_references returns only references whose pin matched the allowlist, so the pin
        # values need no second comparison here; the counts are the independent expectation.
        references = checker.collect_references(REPO_ROOT)
        remote = [reference for reference in references if reference.kind == "remote"]

        expected = dict(EXPECTED_ACTION_COUNTS)
        if URGENT_RELEASE_WORKFLOW.exists():
            for name, count in URGENT_RELEASE_ACTION_COUNTS.items():
                expected[name] = expected.get(name, 0) + count
        self.assertEqual(len(remote), sum(expected.values()))
        self.assertEqual(sum(EXPECTED_ACTION_COUNTS.values()), 15)
        counts = {}
        for reference in remote:
            counts[reference.name] = counts.get(reference.name, 0) + 1
        self.assertEqual(counts, expected)

    def test_all_checkouts_disable_persisted_credentials(self) -> None:
        workflows = {
            path.name: path.read_text(encoding="utf-8")
            for path in WORKFLOWS_ROOT.glob("*.yml")
        }
        checkout_line = (
            r"uses: actions/checkout@[0-9a-f]{40} "
            r"# v[0-9]+\.[0-9]+\.[0-9]+"
        )

        for workflow_name in ("ci.yml", "docs.yml", "governance.yml"):
            blocks = re.findall(
                rf"(?m)^\s*- {checkout_line}\n(?P<with>\s+with:\n(?:\s{{10,}}[^\n]*\n)*)",
                workflows[workflow_name],
            )
            expected_count = {
                "ci.yml": 5,
                "docs.yml": 4,
                "governance.yml": 1,
            }[workflow_name]
            self.assertEqual(len(blocks), expected_count)
            self.assertTrue(all("persist-credentials: false" in block for block in blocks))

    def test_ci_blocks_on_supply_chain_policy_and_exact_lock_regeneration(self) -> None:
        workflow = (WORKFLOWS_ROOT / "ci.yml").read_text(encoding="utf-8")
        job = workflow_job(workflow, "supply-chain-policy")
        validation_step = workflow_named_step(job, "Validate supply-chain policy")
        docs_step = workflow_named_step(job, "Prove documentation lock closure")
        aggregate_job = workflow_job(workflow, "quality-required")

        self.assertIn("  supply-chain-policy:\n", workflow)
        self.assertIn("name: Supply-chain policy", workflow)
        self.assertIn("name: quality / required", aggregate_job)
        self.assertIn("if: always()", aggregate_job)
        for dependency in (
            "- supply-chain-policy",
            "- build-test",
            "- hosted-bats",
            "- commit-lint",
        ):
            self.assertIn(dependency, aggregate_job)
        uv_sha, uv_version = load_checker().load_allowlist()["astral-sh/setup-uv"]
        self.assertIn(f"uses: astral-sh/setup-uv@{uv_sha} # {uv_version}", job)
        setup_uv_block = re.compile(
            r"(?m)^\s*- uses: astral-sh/setup-uv@" + re.escape(f"{uv_sha} # {uv_version}") + r"\n"
            r"\s+with:\n"
            r'\s+version: "0\.11\.27"\n'
            r"\s+enable-cache: false$"
        )
        self.assertEqual(len(setup_uv_block.findall(workflow)), 1)
        for command in (
            "python -m unittest discover -s Tests/automation -p 'test_*.py'",
            "python scripts/ci/action_pins.py",
            "python scripts/ci/dependency_policy.py",
            "python scripts/ci/workflow_policy.py",
        ):
            self.assertIn(command, validation_step)
        self.assertRegex(docs_step, r'(?m)^        env:\n          UV_NO_CONFIG: "1"\n        run: \|$')
        for command in (
            "(cd docs && uv pip compile requirements.in --python-version 3.12 --python-platform x86_64-unknown-linux-gnu --generate-hashes --output-file requirements.txt)",
            "git diff --exit-code -- docs/requirements.txt",
            "python -m pip install --require-hashes -r docs/requirements.txt",
        ):
            self.assertIn(command, docs_step)


# Characters a reviewer cannot see: format characters (Cf, the tag character U+E0041 among them),
# private use (Co), unassigned (Cn: U+0378 in every Unicode version), and the default-ignorable code
# points and the blank outside those categories.
INVISIBLE_SAMPLES = (
    "\u200b", "\u200c", "\u200d", "\u2060", "\u00ad", "\u2062", "\U000e0041", "\ue000", "\U000f0000",
    "\u0378", "\u3164", "\uffa0", "\u115f", "\u1160", "\u2800", "\u034f", "\ufe0f", "\U000e0101",
    "\u180b", "\u17b4",
)


def synthetic_allowlist() -> dict:
    return {
        "schema_version": 1,
        "actions": [
            {"name": "example/one", "sha": "1" * 40, "version": "v1.0.0"},
            {"name": "example/two", "sha": "2" * 40, "version": "v2.0.0"},
        ],
    }


def dump(document: object) -> str:
    return json.dumps(document, indent=2) + "\n"


def with_first_entry(field: str, value: object) -> str:
    document = synthetic_allowlist()
    document["actions"][0][field] = value
    return dump(document)


def with_top_level(field: str, value: object) -> str:
    document = synthetic_allowlist()
    document[field] = value
    return dump(document)


VALID_ALLOWLIST = dump(synthetic_allowlist())
ENTRY_ONE = '{"name": "example/one", "sha": "' + "1" * 40 + '", "version": "v1.0.0"}'
# A value from the synthetic file: a message that quotes one is not value-free.
FILE_VALUE_RE = re.compile(r"example|[0-9a-f]{8}|v[0-9]+\.[0-9]+", re.I)


class AllowlistTests(unittest.TestCase):
    """`.github/actions-allowlist.json`, the single approved-Actions source, and its loader."""

    def refusal(self, content: bytes) -> str:
        """The loader's message for `content` as the allowlist; it must refuse, value-free, naming
        the file, and the real workflows must then fail the repository check with that message."""
        checker = load_checker()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "actions-allowlist.json"
            path.write_bytes(content)
            with self.assertRaises(ValueError) as caught:
                checker.load_allowlist(path)
            message = str(caught.exception)
            self.assertEqual(checker.validate_repository(REPO_ROOT, path), [message])
        self.assertTrue(message.startswith(".github/actions-allowlist.json"), message)
        self.assertIsNone(FILE_VALUE_RE.search(message), message)
        return message

    def test_the_synthetic_allowlist_loads(self) -> None:
        # The baseline every refusal below departs from by one change.
        checker = load_checker()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "actions-allowlist.json"
            path.write_text(VALID_ALLOWLIST, encoding="utf-8")
            self.assertEqual(checker.load_allowlist(path),
                             {"example/one": ("1" * 40, "v1.0.0"), "example/two": ("2" * 40, "v2.0.0")})

    def test_the_tracked_allowlist_lists_exactly_the_actions_the_workflows_use(self) -> None:
        checker = load_checker()
        self.assertEqual(checker.ALLOWLIST_PATH, ALLOWLIST_PATH)
        allowlist = checker.load_allowlist()
        used = {reference.name for reference in checker.collect_references(REPO_ROOT) if reference.kind == "remote"}
        # The urgent-release runbook's recorded workflow is restored for one release at a time; its
        # Actions stay listed (test_urgent_release_runbook.py pins its references to these counts).
        used |= set(URGENT_RELEASE_ACTION_COUNTS)
        self.assertEqual(set(allowlist), used)

    def test_neither_script_embeds_an_allowlist(self) -> None:
        # Design section 18 step 4: the scripts read the file rather than carrying a second list.
        for script, module in ((CHECKER_PATH, load_checker()), (POLICY_PATH, load_policy())):
            with self.subTest(script=script.name):
                source = script.read_text(encoding="utf-8")
                self.assertIsNone(re.search(r"(?<![0-9A-Fa-f])[0-9A-Fa-f]{40}(?![0-9A-Fa-f])", source))
                self.assertNotIn("APPROVED_REMOTE_ACTIONS", source)
                self.assertFalse(hasattr(module, "APPROVED_REMOTE_ACTIONS"))

    def test_a_narrowed_or_repinned_allowlist_turns_the_real_workflows_red(self) -> None:
        checker = load_checker()
        tracked = json.loads(ALLOWLIST_PATH.read_text(encoding="utf-8"))
        narrowed = dict(tracked, actions=[entry for entry in tracked["actions"] if entry["name"] != "astral-sh/setup-uv"])
        repinned = dict(tracked, actions=[dict(entry, sha="0" * 40) if entry["name"] == "actions/checkout" else entry
                                          for entry in tracked["actions"]])
        for label, document, needle in (("narrowed", narrowed, "is not in the reviewed allowlist"),
                                        ("repinned", repinned, "does not match the reviewed allowlist")):
            with self.subTest(allowlist=label), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "actions-allowlist.json"
                path.write_text(dump(document), encoding="utf-8")
                errors = checker.validate_repository(REPO_ROOT, path)
                self.assertTrue(errors)
                self.assertTrue(all(needle in error for error in errors), errors)

    def test_the_scanned_root_cannot_approve_its_own_actions(self) -> None:
        # The list is read from the scripts' own checkout; one planted in the tree under scan is
        # ignored by both checkers.
        checker = load_checker()
        policy = load_policy()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            planted = root / ".github" / "actions-allowlist.json"
            write_workflow(root, "own.yml",
                           "jobs:\n  test:\n    steps:\n      - uses: example/one@" + "1" * 40 + " # v1.0.0\n")
            planted.write_text(VALID_ALLOWLIST, encoding="utf-8")
            self.assertIn("example/one", checker.load_allowlist(planted))
            errors = checker.validate_repository(root)
            self.assertTrue(any("own.yml:4:" in error and "reviewed allowlist" in error for error in errors), errors)
            violations = policy.scan_repository(root)
            self.assertTrue(any("own.yml" in v and "reviewed action-pin allowlist" in v for v in violations), violations)
            # Nor does the inventory helper collect the planted list's Action.
            self.assertEqual([ref for ref in checker.collect_references(root) if ref.kind == "remote"], [])

    def test_a_missing_symlinked_or_nonregular_allowlist_fails_closed(self) -> None:
        checker = load_checker()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target.json"
            target.write_text(VALID_ALLOWLIST, encoding="utf-8")
            link = root / "linked.json"
            link.symlink_to(target)
            self.assertIn("example/one", checker.load_allowlist(target))
            for label, path, expected in (
                ("missing", root / "absent.json", "file is missing"),
                ("symlink", link, "must be a readable regular file (a symlink is refused)"),
                ("directory", root, "file must be regular"),
            ):
                with self.subTest(allowlist=label):
                    with self.assertRaises(ValueError) as caught:
                        checker.load_allowlist(path)
                    message = str(caught.exception)
                    self.assertEqual(message, ".github/actions-allowlist.json: " + expected)
                    self.assertEqual(checker.validate_repository(REPO_ROOT, path), [message])

    def test_malformed_allowlists_fail_closed_with_a_value_free_message(self) -> None:
        checker = load_checker()
        oversized = VALID_ALLOWLIST + " " * (checker.MAX_ALLOWLIST_BYTES + 1 - len(VALID_ALLOWLIST))
        cases = (
            ("over the size limit", oversized.encode("utf-8"), "size limit"),
            ("not UTF-8", VALID_ALLOWLIST.encode("utf-8").replace(b"v1.0.0", b"v1.0.0\xff"), "must be UTF-8"),
            ("byte-order mark", ("\ufeff" + VALID_ALLOWLIST).encode("utf-8"), "U+FEFF is refused"),
            # A carriage return is JSON whitespace, so only the character rule refuses it.
            ("carriage return", VALID_ALLOWLIST.replace("\n", "\r\n").encode("utf-8"), "U+000D is refused"),
            # Raw in the file, not a JSON escape: the character rule reads the text before parsing.
            ("bidirectional control", VALID_ALLOWLIST.replace("example/one", "example/o\u202ene", 1).encode("utf-8"),
             "U+202E is refused"),
            # An invisible character, raw in the file, is refused by the second character rule.
            ("zero-width space", VALID_ALLOWLIST.replace("example/one", "example/o\u200bne", 1).encode("utf-8"),
             "U+200B is refused (an invisible format"),
            ("variation selector", VALID_ALLOWLIST.replace("v1.0.0", "v1.0.0\ufe0f", 1).encode("utf-8"),
             "U+FE0F is refused (an invisible format"),
            ("invalid JSON", VALID_ALLOWLIST.replace("\n  ]", ",\n  ]").encode("utf-8"), "not valid JSON"),
            ("repeated top-level key",
             ('{"schema_version": 1, "schema_version": 1, "actions": [' + ENTRY_ONE + "]}\n").encode("utf-8"),
             "repeats a key"),
            ("repeated entry key",
             ('{"schema_version": 1, "actions": [' + ENTRY_ONE.replace("{", '{"sha": "' + "1" * 40 + '", ', 1)
              + "]}\n").encode("utf-8"),
             "repeats a key"),
            # A list holding the two key names has the right set of members but is no object.
            ("a list at the top level", b'["schema_version", "actions"]\n',
             "exactly the keys `schema_version` and `actions`"),
            ("an extra top-level key", with_top_level("note", "x").encode("utf-8"),
             "exactly the keys `schema_version` and `actions`"),
            ("a missing top-level key", dump({"schema_version": 1}).encode("utf-8"),
             "exactly the keys `schema_version` and `actions`"),
            ("schema_version true", with_top_level("schema_version", True).encode("utf-8"), "the integer 1"),
            ("schema_version 1.0", with_top_level("schema_version", 1.0).encode("utf-8"), "the integer 1"),
            ("schema_version a string", with_top_level("schema_version", "1").encode("utf-8"), "the integer 1"),
            ("schema_version 2", with_top_level("schema_version", 2).encode("utf-8"), "the integer 1"),
            ("actions an object", with_top_level("actions", {"x": 1}).encode("utf-8"), "non-empty list"),
            ("actions empty", with_top_level("actions", []).encode("utf-8"), "non-empty list"),
            ("an entry that is not an object", with_top_level("actions", [["name", "sha", "version"]]).encode("utf-8"),
             "exactly the keys `name`, `sha` and `version`"),
            ("an extra entry key", with_first_entry("pinned_by", "x").encode("utf-8"),
             "exactly the keys `name`, `sha` and `version`"),
            ("a missing entry key",
             dump(dict(synthetic_allowlist(), actions=[{"name": "example/one", "sha": "1" * 40}])).encode("utf-8"),
             "exactly the keys `name`, `sha` and `version`"),
            ("name not a string", with_first_entry("name", 1).encode("utf-8"), "`name` must be"),
            ("sha not a string", with_first_entry("sha", None).encode("utf-8"), "`sha` must be"),
            ("version not a string", with_first_entry("version", 1).encode("utf-8"), "`version` must be"),
            ("uppercase sha", with_first_entry("sha", "A" * 40).encode("utf-8"), "`sha` must be"),
            ("short sha", with_first_entry("sha", "1" * 39).encode("utf-8"), "`sha` must be"),
            ("long sha", with_first_entry("sha", "1" * 41).encode("utf-8"), "`sha` must be"),
            ("non-hexadecimal sha", with_first_entry("sha", "g" * 40).encode("utf-8"), "`sha` must be"),
            ("a repeated name", dump(dict(synthetic_allowlist(), actions=[synthetic_allowlist()["actions"][0]] * 2))
             .encode("utf-8"), "`name` repeats an earlier entry"),
            ("unsorted names", dump(dict(synthetic_allowlist(), actions=synthetic_allowlist()["actions"][::-1]))
             .encode("utf-8"), "sorted by `name`"),
        )
        bad_names = ("Example/one", "example", "example/one/sub", "example/..", "../one", "example/../one",
                     "example/.one", "-example/one", "example-/one", "example/one ", " example/one",
                     "example /one", "example/one\t", "")
        bad_versions = ("1.0.0", "v1.0", "v1.0.0-rc.1", "V1.0.0", "v1.0.0 ", "")
        cases += tuple(("name " + repr(name), with_first_entry("name", name).encode("utf-8"), "`name` must be")
                       for name in bad_names)
        cases += tuple(("version " + repr(version), with_first_entry("version", version).encode("utf-8"),
                        "`version` must be") for version in bad_versions)
        for label, content, needle in cases:
            with self.subTest(case=label):
                self.assertIn(needle, self.refusal(content))


if __name__ == "__main__":
    unittest.main()
