"""The urgent-release runbook's restored workflow (docs/runbooks/urgent-release.md).

The runbook records, verbatim, the build-and-verify workflow that an operator-authorized urgent
release restores under `.github/workflows/` for one release (design section 18 step 5). These
tests keep that text restorable as it stands:
  * the runbook holds exactly one recorded workflow, at the recorded path;
  * it parses with the static scan's own parser, and the static scan and the action-pin check
    both pass over it beside the tracked workflows, with no exception for it;
  * its shape stays read-only: a push trigger on `main` only, `contents: read` at workflow and
    job level, one job guarded to release commits, a checkout without persisted credentials, no
    remote action beyond checkout and upload-artifact, and the upload as the last step with no
    step or job allowed to skip or tolerate a failure (so an artifact exists only when every
    check before it passed);
  * restored beside the tracked workflows, it adds exactly the action references the exact
    inventory in test_action_pins.py expects of it, so a restoration keeps the tier green;
  * its drift gate, mechanical re-render and notes step, run from the recorded text with the
    environment its `env:` mappings declare, against synthetic repositories built like the real
    flow (tag, candidate, restoration commit, release commit), pass a derived and a forced-minor
    release and fail a MAJOR change, a hand-edited changelog or constant file, a mismatched
    subject, an extra changed file, an existing tag, a merge commit and a checkout other than
    the pushed commit;
  * the git half of step 4's binding block, run verbatim from the runbook against the same
    repositories with step 2's render in place, accepts a normal and a retry release and a
    release after a clean abandoned attempt, and refuses content riding in the restoration commit
    (which the hosted steps cannot see), a retry behind an earlier restoration that carried more,
    a deletion hidden behind the added workflow, a candidate that did not land the entry and an
    unnamed extra commit;
  * step 5.1's notes block, run verbatim, extracts the release section whole when more than a
    pipe buffer of changelog follows it, and cuts an oversized section as the legacy publisher
    did;
  * a real YAML loader (libyaml, through Ruby, where Ruby is installed) accepts the recorded
    text, since the scan's own parser is more lenient than GitHub's;
  * its packaging step, run from the recorded text on macOS (its tools are the macOS ones:
    `nm` for Mach-O, bsdtar's flags, `cc` to build the fixtures), packages a clean binary to
    the D18 step (4) standard and refuses one with a debug-map entry, one carrying a
    home-directory path, and an archive that records its builder as owner, carries an
    extended-attribute record or holds a member that is not a regular file; the Linux policy job
    skips it, and the local canonical tier runs it;
    and, portably, its debug-map check reads nm's whole output, so an entry early in a long
    symbol table fails it (the `grep -q` form under pipefail passes one);
  * while it is restored, the file under `.github/workflows/` is byte-identical to the runbook's
    text, so a green run is the review of a restoration's content.
The scan being a recorded-list check, "passes the scan" means what it means there: no recorded
write command or forbidden shape, not a proof that nothing can write.
"""
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
RUNBOOK = ROOT / "docs" / "runbooks" / "urgent-release.md"
RESTORED_PATH = ".github/workflows/urgent-release-verify.yml"
BLOCK_RE = re.compile(
    r"^<!-- restored-workflow: (?P<path>\S+) -->\n```yaml\n(?P<body>.*?)^```\n<!-- restored-workflow: end -->$",
    re.S | re.M,
)


def _load(name: str, relative: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


policy = _load("workflow_policy_for_runbook", "scripts/ci/workflow_policy.py")
pins = _load("action_pins_for_runbook", "scripts/ci/action_pins.py")
inventory = _load("action_pins_inventory_for_runbook", "Tests/automation/test_action_pins.py")


def recorded_workflow():
    matches = list(BLOCK_RE.finditer(RUNBOOK.read_text(encoding="utf-8")))
    if len(matches) != 1:
        raise AssertionError("the runbook must record exactly one restored workflow, found {}".format(len(matches)))
    return matches[0].group("path"), matches[0].group("body")


class RecordedWorkflowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.path, self.text = recorded_workflow()

    def test_one_workflow_at_the_recorded_path(self) -> None:
        self.assertEqual(self.path, RESTORED_PATH)
        self.assertTrue(self.text.endswith("\n"))

    def test_the_scan_and_the_pin_check_pass_it_beside_the_tracked_workflows(self) -> None:
        with tempfile.TemporaryDirectory(prefix="urgent-release-runbook-") as tmp:
            root = pathlib.Path(tmp)
            workflows = root / ".github" / "workflows"
            workflows.mkdir(parents=True)
            for tracked in sorted((ROOT / ".github" / "workflows").glob("*.yml")):
                if tracked.name != pathlib.Path(RESTORED_PATH).name:
                    shutil.copyfile(tracked, workflows / tracked.name)
            (root / RESTORED_PATH).write_text(self.text, encoding="utf-8")
            self.assertEqual(policy.scan_repository(root), [])
            self.assertEqual(pins.validate_repository(root), [])

    def test_it_adds_exactly_the_references_the_inventory_expects(self) -> None:
        with tempfile.TemporaryDirectory(prefix="urgent-release-inventory-") as tmp:
            root = pathlib.Path(tmp)
            (root / ".github" / "workflows").mkdir(parents=True)
            (root / RESTORED_PATH).write_text(self.text, encoding="utf-8")
            references = [ref for ref in pins.collect_references(root) if ref.kind == "remote"]
        counts = {}
        for reference in references:
            counts[reference.name] = counts.get(reference.name, 0) + 1
            self.assertEqual((reference.revision, reference.version_comment),
                             inventory.EXPECTED_ACTION_PINS[reference.name])
        self.assertEqual(counts, inventory.URGENT_RELEASE_ACTION_COUNTS)
        self.assertEqual(pathlib.Path(RESTORED_PATH).name, inventory.URGENT_RELEASE_WORKFLOW.name)

    def test_its_shape_stays_read_only(self) -> None:
        document = policy.parse_workflow(self.text)
        self.assertEqual(document["on"], {"push": {"branches": ["main"]}})
        self.assertEqual(document["permissions"], {"contents": "read"})
        self.assertNotIn("env", document)
        self.assertEqual(list(document["jobs"]), ["verify"])
        job = document["jobs"]["verify"]
        self.assertEqual(job["permissions"], {"contents": "read"})
        self.assertEqual(job["if"], "startsWith(github.event.head_commit.message, 'chore(release): v')")
        for key in ("environment", "secrets", "container", "services", "uses"):
            self.assertNotIn(key, job)
        uses = [step["uses"].split("@")[0] for step in job["steps"] if "uses" in step]
        self.assertEqual(uses, ["actions/checkout", "actions/upload-artifact"])
        checkout = job["steps"][0]
        self.assertIs(checkout["with"]["persist-credentials"], False)
        self.assertNotIn("token", checkout["with"])
        self.assertTrue(job["steps"][-1].get("uses", "").startswith("actions/upload-artifact@"))
        self.assertNotIn("env", job)
        by_name = {step.get("name"): step for step in job["steps"]}
        build = by_name["Release build and runtime version check"]
        self.assertEqual(build["id"], "build")
        self.assertIn('echo "bin=$bin" >> "$GITHUB_OUTPUT"', build["run"])
        self.assertEqual(by_name["Packaging standard and checksummed artifact"]["env"]["BIN"],
                         "${{ steps.build.outputs.bin }}")
        self.assertNotIn("continue-on-error", job)
        for step in job["steps"]:
            self.assertNotIn("if", step)
            self.assertNotIn("continue-on-error", step)

    def test_no_block_runs_gh_or_git_after_leaving_the_repository(self) -> None:
        # Blocks run from the repository root; gh takes the repository from it, git its history.
        blocks = re.findall(r"^( *)```sh\n(.*?)^\1```$", RUNBOOK.read_text(encoding="utf-8"), re.S | re.M)
        self.assertGreaterEqual(len(blocks), 10)
        command = re.compile(r"(^|[^\w-])(gh|git)\s")
        for _, body in blocks:
            lines = [line.strip() for line in body.splitlines()]
            for index, line in enumerate(lines):
                where = re.search(r"(^|[^\w-])cd\s", line)
                if where:
                    rest = [line[where.end():]] + lines[index + 1:]
                    later = [text for text in rest if command.search(text)]
                    self.assertEqual(later, [], "a block calls gh or git after `{}`".format(line))

    def test_a_restored_copy_is_byte_identical_to_the_runbook(self) -> None:
        restored = ROOT / RESTORED_PATH
        if restored.exists():
            self.assertEqual(restored.read_bytes(), self.text.encode("utf-8"))


REPOSITORY = "example/apple-cli"
CONSTANT_REL = pathlib.Path("Sources/AppleKit/CommandSupport.swift")
CHANGELOG_REL = pathlib.Path("CHANGELOG.md")
MANIFEST_REL = pathlib.Path(".github/control-plane-manifest.json")
CONSTANT_SOURCE = (
    "public enum AppleVersion {\n"
    "    public static let current = \"26.0.0\" // release-preparation-managed\n"
    "}\n"
)
CHANGELOG_SOURCE = (
    "# Changelog\n\n"
    "## [Unreleased]\n\n"
    "### Fixed\n\n"
    "- **A caller-visible fix.** Manual: https://github.com/{repo}/blob/main/docs/manual/index.md\n\n"
    "## [26.0.0] - 2026-08-30\n\n"
    "### Added\n\n"
    "- First release. Manual: https://github.com/{repo}/blob/v26.0.0/docs/manual/index.md\n"
).format(repo=REPOSITORY)


# Git run by these tests acts on their synthetic repositories only, whatever the caller exported.
CLEAN_ENV = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}


def _git(args, cwd) -> str:
    return subprocess.run(["git", *args], cwd=str(cwd), check=True, stdin=subprocess.DEVNULL,
                          capture_output=True, text=True, env=CLEAN_ENV).stdout


class RecordedVerificationTests(unittest.TestCase):
    """Run the recorded drift gate and re-render against synthetic release commits."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="urgent-release-verify-")
        self.tmp = pathlib.Path(self._tmp.name)
        _, text = recorded_workflow()
        self.recorded = text
        self.steps = {step.get("name"): step for step in policy.parse_workflow(text)["jobs"]["verify"]["steps"]}
        self.ws = self.tmp / "ws"
        self.ws.mkdir()
        _git(["init", "-q"], self.ws)
        for key, value in (("user.email", "automation@example.com"), ("user.name", "Automation Example"),
                           ("commit.gpgsign", "false"), ("tag.gpgsign", "false")):
            _git(["config", key, value], self.ws)
        (self.ws / "scripts" / "ci").mkdir(parents=True)
        shutil.copyfile(ROOT / "scripts" / "ci" / "release_prep.py", self.ws / "scripts" / "ci" / "release_prep.py")
        shutil.copyfile(ROOT / "scripts" / "check-release-notes.py", self.ws / "scripts" / "check-release-notes.py")
        shutil.copyfile(ROOT / "Package.swift", self.ws / "Package.swift")
        (self.ws / CONSTANT_REL).parent.mkdir(parents=True)
        (self.ws / CONSTANT_REL).write_text(CONSTANT_SOURCE, encoding="utf-8")
        (self.ws / CHANGELOG_REL).write_text(CHANGELOG_SOURCE, encoding="utf-8")
        (self.ws / MANIFEST_REL).parent.mkdir(parents=True)
        (self.ws / MANIFEST_REL).write_text('[\n  "a"\n]\n', encoding="utf-8")
        _git(["add", "-A"], self.ws)
        _git(["commit", "-q", "-m", "chore(release): v26.0.0"], self.ws)
        _git(["tag", "-a", "v26.0.0", "-m", "v26.0.0"], self.ws)
        (self.ws / "note.txt").write_text("fix\n", encoding="utf-8")
        _git(["add", "note.txt"], self.ws)
        _git(["commit", "-q", "-m", "fix: correct a thing"], self.ws)
        self.env = dict(CLEAN_ENV, PATH=os.path.dirname(sys.executable) + os.pathsep + CLEAN_ENV.get("PATH", ""))

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def render(self, into: str, *bump: str) -> pathlib.Path:
        """Release preparation at HEAD, as step 2 renders it, into a scratch directory."""
        rendered = self.tmp / into
        prep = subprocess.run(
            [sys.executable, "-I", "-S", "-B", "scripts/ci/release_prep.py", "--candidate-root", str(self.ws),
             "--candidate-sha", _git(["rev-parse", "HEAD"], self.ws).strip(), "--repository", REPOSITORY,
             "--scratch", str(rendered), "--date", "2026-09-01", *bump],
            cwd=str(self.ws), stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False)
        self.assertEqual(prep.returncode, 0, prep.stderr)
        return rendered

    def authorize(self) -> None:
        """The step 1 entry, landed as a commit that changes HUMAN-DECISIONS.md alone; it is C."""
        with open(self.ws / "HUMAN-DECISIONS.md", "a", encoding="utf-8") as handle:
            handle.write("## D99 — urgent release (synthetic)\n")
        _git(["add", "HUMAN-DECISIONS.md"], self.ws)
        _git(["commit", "-q", "-m", "docs(governance): authorize an urgent release"], self.ws)

    def restore(self, inject: bool = False, add_file: bool = False, delete=None) -> None:
        """The restoration commit: the recorded workflow and its manifest entry (and, if asked, more)."""
        (self.ws / RESTORED_PATH).parent.mkdir(parents=True, exist_ok=True)
        (self.ws / RESTORED_PATH).write_text(self.recorded, encoding="utf-8")
        (self.ws / MANIFEST_REL).write_text('[\n  "a",\n  "{}"\n]\n'.format(RESTORED_PATH), encoding="utf-8")
        if inject:
            with open(self.ws / CONSTANT_REL, "a", encoding="utf-8") as handle:
                handle.write("public let injected = \"code riding in the restoration commit\"\n")
        if add_file:
            (self.ws / CONSTANT_REL).with_name("Injected.swift").write_text("public let injected = 1\n", encoding="utf-8")
        if delete:
            (self.ws / delete).unlink()
        _git(["add", "-A"], self.ws)
        _git(["commit", "-q", "-m", "ci(release): restore the urgent-release verify workflow"], self.ws)

    def remove(self) -> None:
        """Step 6.1's removal commit: the workflow and its manifest entry, nothing else."""
        (self.ws / RESTORED_PATH).unlink()
        (self.ws / MANIFEST_REL).write_text('[\n  "a"\n]\n', encoding="utf-8")
        _git(["add", "-A"], self.ws)
        _git(["commit", "-q", "-m", "ci(release): remove the urgent-release verify workflow"], self.ws)

    def release(self, *bump: str, subject=None, hand_edit=False, hand_edit_constant=False, extra_file=False,
                tag=False, merge=False, pushed=None, retry=False, inject=False, extra_commit=False,
                authorized=True, dirty_retry=False, lookalike=False, abandoned=False):
        """Render at the candidate, add the restoration and release commits, run the recorded steps.

        `retry` models step 7's shape (the candidate already carries the restored workflow), and
        `dirty_retry` gives that earlier restoration commit an extra file; `inject` rides content in
        the restoration commit and renders the release from it, which the hosted steps accept and
        step 4's commit-by-commit binding must refuse; `lookalike` has the restoration commit delete
        a file identical to the workflow, which rename detection would hide; `abandoned` puts a clean
        earlier attempt, restored and removed, before this one."""
        if abandoned:
            self.restore()
            self.remove()
        lookalike_path = RESTORED_PATH.replace("urgent-release-verify", "lookalike") if lookalike else None
        if lookalike_path:
            (self.ws / lookalike_path).parent.mkdir(parents=True, exist_ok=True)
            (self.ws / lookalike_path).write_text(self.recorded, encoding="utf-8")
            _git(["add", lookalike_path], self.ws)
            _git(["commit", "-q", "-m", "ci: add a workflow"], self.ws)
        if retry or dirty_retry:
            self.restore(add_file=dirty_retry)
        if authorized:
            self.authorize()
        candidate = _git(["rev-parse", "HEAD"], self.ws).strip()
        rendered = self.render("rendered", *bump)
        if not (retry or dirty_retry):
            self.restore(inject=inject, delete=lookalike_path)
            if inject:
                rendered = self.render("rendered-from-restoration", *bump)
        if extra_commit:
            (self.ws / "extra.txt").write_text("extra\n", encoding="utf-8")
            _git(["add", "extra.txt"], self.ws)
            _git(["commit", "-q", "-m", "chore: an unnamed commit"], self.ws)
        for rel in (CONSTANT_REL, CHANGELOG_REL):
            (self.ws / rel).write_bytes((rendered / rel).read_bytes())
        version = re.search(r'current = "([0-9.]+)"', (self.ws / CONSTANT_REL).read_text(encoding="utf-8")).group(1)
        if hand_edit:
            path = self.ws / CHANGELOG_REL
            path.write_text(path.read_text(encoding="utf-8").replace("## [Unreleased]\n", "## [Unreleased]\n\n", 1),
                            encoding="utf-8")
        if hand_edit_constant:
            with open(self.ws / CONSTANT_REL, "a", encoding="utf-8") as handle:
                handle.write("// an extra line riding in the release commit\n")
        if extra_file:
            (self.ws / "note.txt").write_text("fix\nmore\n", encoding="utf-8")
        _git(["commit", "-q", "-am", subject or "chore(release): v" + version], self.ws)
        if tag:
            _git(["tag", "v" + version], self.ws)
        if merge:
            # The same release tree, recorded as a merge of the restoration commit and the candidate.
            tree = _git(["rev-parse", "HEAD^{tree}"], self.ws).strip()
            merged = _git(["commit-tree", tree, "-p", "HEAD^", "-p", candidate, "-m",
                           subject or "chore(release): v" + version], self.ws).strip()
            _git(["reset", "-q", "--hard", merged], self.ws)
        output = self.tmp / "github_output"
        output.write_text("", encoding="utf-8")
        runner_temp = self.tmp / "runner_temp"
        runner_temp.mkdir()
        context = {"github.sha": pushed or _git(["rev-parse", "HEAD"], self.ws).strip(), "github.repository": REPOSITORY}
        base = dict(self.env, GITHUB_OUTPUT=str(output), RUNNER_TEMP=str(runner_temp), GITHUB_WORKSPACE=str(self.ws))
        results = {"outputs": {}, "candidate": candidate}
        for name, key in (("Drift gate", "gate"), ("Mechanical re-render from the parent", "rerender"),
                          ("Released-section notes contract", "notes")):
            step = self.steps[name]
            env = dict(base, **{variable: self.resolve(value, context) for variable, value in step.get("env", {}).items()})
            results[key] = subprocess.run(["bash", "-c", step["run"]], cwd=str(self.ws), env=env,
                                          stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False)
            if key == "gate":
                if results[key].returncode != 0:
                    return results
                outputs = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines())
                results["outputs"] = outputs
                context.update({"steps.release.outputs." + field: value for field, value in outputs.items()})
        return results

    def bind(self, candidate: str):
        """The git half of step 4's binding block (up to the run binding), verbatim from the runbook,
        with the step 2 render in place."""
        text = RUNBOOK.read_text(encoding="utf-8")
        block = re.search(r"^```sh\n(: \"\$\{SCRATCH:\?\}\" \"\$\{C:\?\}\" \"\$\{R:\?\}\".*?)^# The run is the restored",
                          text, re.S | re.M)
        self.assertIsNotNone(block, "step 4's binding block moved; update this test")
        env = dict(self.env, SCRATCH=str(self.tmp), C=candidate, R=_git(["rev-parse", "HEAD"], self.ws).strip(),
                   RUN="1", ATTEMPT="1")
        return subprocess.run(["bash", "-c", "set -euo pipefail\n" + block.group(1)], cwd=str(self.ws), env=env,
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False)

    @staticmethod
    def resolve(value: str, context: dict) -> str:
        """Evaluate a step's `env:` value: only the expressions this workflow uses are known."""
        match = re.fullmatch(r"\$\{\{ ([a-z_.]+) \}\}", value)
        if match is None or match.group(1) not in context:
            raise AssertionError("unsupported expression in the recorded workflow's env: {!r}".format(value))
        return context[match.group(1)]

    def test_a_derived_release_passes(self) -> None:
        results = self.release()
        for key in ("gate", "rerender", "notes"):
            self.assertEqual(results[key].returncode, 0, key + ": " + results[key].stderr)
        outputs = results["outputs"]
        self.assertEqual((outputs["version"], outputs["bump_option"], outputs["bump_value"]),
                         ("26.0.1", "--bump", "patch"))

    def test_step_4_binds_a_normal_release_to_the_candidate(self) -> None:
        results = self.release()
        binding = self.bind(results["candidate"])
        self.assertEqual(binding.returncode, 0, binding.stderr)

    def test_step_4_binds_a_retry_release_to_the_candidate(self) -> None:
        results = self.release(retry=True)
        for key in ("gate", "rerender", "notes"):
            self.assertEqual(results[key].returncode, 0, key + ": " + results[key].stderr)
        binding = self.bind(results["candidate"])
        self.assertEqual(binding.returncode, 0, binding.stderr)

    def test_step_4_refuses_content_riding_in_the_restoration_commit(self) -> None:
        results = self.release(inject=True)
        # The hosted steps cannot see it: they re-render from the release commit's parent.
        for key in ("gate", "rerender"):
            self.assertEqual(results[key].returncode, 0, key + ": " + results[key].stderr)
        self.assertNotEqual(self.bind(results["candidate"]).returncode, 0)

    def test_step_4_refuses_a_retry_behind_a_restoration_that_carried_more(self) -> None:
        results = self.release(dirty_retry=True)
        for key in ("gate", "rerender", "notes"):
            self.assertEqual(results[key].returncode, 0, key + ": " + results[key].stderr)
        self.assertNotEqual(self.bind(results["candidate"]).returncode, 0)

    def test_step_4_refuses_a_deletion_hidden_behind_the_added_workflow(self) -> None:
        results = self.release(lookalike=True)
        for key in ("gate", "rerender"):
            self.assertEqual(results[key].returncode, 0, key + ": " + results[key].stderr)
        self.assertNotEqual(self.bind(results["candidate"]).returncode, 0)

    def test_step_4_binds_a_release_after_a_clean_abandoned_attempt(self) -> None:
        results = self.release(abandoned=True)
        binding = self.bind(results["candidate"])
        self.assertEqual(binding.returncode, 0, binding.stderr)

    def test_step_4_refuses_a_candidate_that_did_not_land_the_entry(self) -> None:
        results = self.release(authorized=False)
        self.assertNotEqual(self.bind(results["candidate"]).returncode, 0)

    def test_step_4_refuses_an_unnamed_extra_commit(self) -> None:
        results = self.release(extra_commit=True)
        self.assertNotEqual(self.bind(results["candidate"]).returncode, 0)

    def test_a_forced_minor_release_passes(self) -> None:
        results = self.release("--bump", "minor")
        for key in ("gate", "rerender", "notes"):
            self.assertEqual(results[key].returncode, 0, key + ": " + results[key].stderr)
        self.assertEqual((results["outputs"]["version"], results["outputs"]["bump_value"]), ("26.1.0", "minor"))

    def assert_gate_refuses(self, results, message: str) -> None:
        self.assertEqual(results["gate"].returncode, 1)
        self.assertIn(message, results["gate"].stderr + results["gate"].stdout)
        self.assertNotIn("rerender", results)

    def test_a_major_change_is_refused(self) -> None:
        self.assert_gate_refuses(self.release("--macos-major", "27"), "a MAJOR change is not an urgent release")

    def test_a_hand_edited_changelog_fails_the_re_render(self) -> None:
        results = self.release(hand_edit=True)
        self.assertEqual(results["gate"].returncode, 0, results["gate"].stderr)
        self.assertNotEqual(results["rerender"].returncode, 0)

    def test_a_hand_edited_constant_file_fails_the_re_render(self) -> None:
        results = self.release(hand_edit_constant=True)
        self.assertEqual(results["gate"].returncode, 0, results["gate"].stderr)
        self.assertNotEqual(results["rerender"].returncode, 0)

    def test_a_mismatched_subject_is_refused(self) -> None:
        self.assert_gate_refuses(self.release(subject="chore(release): v9.9.9"),
                                 "the commit subject does not name the version constant")

    def test_an_extra_changed_file_is_refused(self) -> None:
        self.assert_gate_refuses(self.release(extra_file=True), "must change only the two rendered files")

    def test_an_existing_tag_is_refused(self) -> None:
        self.assert_gate_refuses(self.release(tag=True), "a tag of this version already exists")

    def test_a_merge_commit_is_refused(self) -> None:
        self.assert_gate_refuses(self.release(merge=True), "must have exactly one parent")

    def test_a_checkout_other_than_the_pushed_commit_is_refused(self) -> None:
        self.assert_gate_refuses(self.release(pushed="0" * 40), "checkout is not the pushed commit")


class RecordedNotesExtractionTests(unittest.TestCase):
    """Step 5.1's notes block, verbatim from the runbook, against a release commit's changelog.

    awk stops at the heading after the release section. Fed through a pipe from `git show`, the
    writer then dies of SIGPIPE whenever more than a pipe buffer of changelog follows, and
    pipefail stops the procedure; the real changelog has far more than that after any new
    section. The block reads the changelog from a file instead."""

    VERSION = "26.0.1"

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="urgent-release-notes-")
        self.tmp = pathlib.Path(self._tmp.name)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        _git(["init", "-q"], self.repo)
        for key, value in (("user.email", "automation@example.com"), ("user.name", "Automation Example"),
                           ("commit.gpgsign", "false")):
            _git(["config", key, value], self.repo)
        block = re.search(r'^   ```sh\n(   : "\$\{SCRATCH:\?\}" "\$\{R:\?\}"\n.*?)^   ```\n',
                          RUNBOOK.read_text(encoding="utf-8"), re.S | re.M)
        self.assertIsNotNone(block, "step 5.1's notes block moved; update this test")
        self.block = textwrap.dedent(block.group(1)).replace("X.Y.Z", self.VERSION)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text('#!/bin/sh\n[ "$1 $2" = "repo view" ] && echo {}\n'.format(REPOSITORY),
                                    encoding="utf-8")
        (bin_dir / "gh").chmod(0o755)
        self.env = dict(CLEAN_ENV, PATH=str(bin_dir) + os.pathsep + CLEAN_ENV.get("PATH", ""), SCRATCH=str(self.tmp))

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def notes(self, section: str, trailing: str):
        (self.repo / "CHANGELOG.md").write_text(
            "# Changelog\n\n## [Unreleased]\n\n## [{}] - 2026-09-01\n\n".format(self.VERSION) + section
            + "## [26.0.0] - 2026-08-30\n\n" + trailing, encoding="utf-8")
        _git(["add", "CHANGELOG.md"], self.repo)
        _git(["commit", "-q", "-m", "chore(release): v" + self.VERSION], self.repo)
        env = dict(self.env, R=_git(["rev-parse", "HEAD"], self.repo).strip())
        result = subprocess.run(["bash", "-c", "set -euo pipefail\n" + self.block], cwd=str(self.repo), env=env,
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False)
        return result, self.tmp / "notes.md"

    def test_a_section_followed_by_more_than_a_pipe_buffer_is_extracted_whole(self) -> None:
        section = "### Fixed\n\n- **A fix callers can see.** It works again.\n\n"
        result, notes = self.notes(section, "- an older entry that fills the rest of the file\n" * 8000)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(notes.read_text(encoding="utf-8"), "\n" + section)

    def test_an_oversized_section_is_cut_as_the_legacy_publisher_did(self) -> None:
        section = "### Fixed\n\n" + "".join("- entry {:05d} {}\n".format(n, "x" * 90) for n in range(1300)) + "\n"
        result, notes = self.notes(section, "- older\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        text = notes.read_text(encoding="utf-8")
        marker = ("\n\n---\n*Notes truncated \u2014 the complete section is [CHANGELOG.md]"
                  "(https://github.com/{}/blob/v{}/CHANGELOG.md).*\n".format(REPOSITORY, self.VERSION))
        self.assertTrue(text.endswith(marker), text[-300:])
        kept = text[: -len(marker)]
        self.assertLess(len(text.encode("utf-8")), 120000)
        self.assertTrue(kept.endswith("\n") and ("\n" + section).startswith(kept), "the cut must fall on a line boundary")


@unittest.skipUnless(shutil.which("ruby"), "needs Ruby for its libyaml-backed loader (present on hosted Ubuntu and macOS)")
class RecordedWorkflowLoadsInARealYamlLoader(unittest.TestCase):
    """The static scan's own parser is lenient where YAML is strict (an unquoted `: ` inside a
    value, for one); GitHub's loader is not, so a real loader must accept the recorded text."""

    def test_libyaml_reads_it_as_the_scan_does(self) -> None:
        _, text = recorded_workflow()
        script = 'require "psych"; require "json"; puts JSON.generate(Psych.safe_load(STDIN.read))'
        result = subprocess.run(["ruby", "-e", script], input=text, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        loaded = json.loads(result.stdout)
        # YAML 1.1 reads the bare `on` key as true; GitHub, and the scan, read it as the key "on".
        loaded["on"] = loaded.pop("true")

        def normal(value):
            if isinstance(value, dict):
                return {str(key): normal(item) for key, item in value.items()}
            if isinstance(value, list):
                return [normal(item) for item in value]
            if isinstance(value, bool):
                return "true" if value else "false"
            return str(value)

        self.assertEqual(normal(loaded), normal(policy.parse_workflow(text)))
        self.assertEqual(loaded["jobs"]["verify"]["if"],
                         "startsWith(github.event.head_commit.message, 'chore(release): v')")


class RecordedPackagingCheckReadsToTheEnd(unittest.TestCase):
    """A debug-map entry early in a long symbol table must fail the packaging step.

    `nm | grep -q` under pipefail passes such a binary: grep stops at the first match, nm dies
    writing to the closed pipe, and the non-zero pipeline reads as "no match". A small binary's
    symbol table fits in the pipe buffer and cannot show this, so a stand-in `nm` prints the
    entry first and then more than a megabyte of symbols. Portable: the step fails at this check,
    before any macOS-only tool runs."""

    def test_an_early_debug_map_entry_in_a_long_table_is_refused(self) -> None:
        _, text = recorded_workflow()
        steps = {step.get("name"): step for step in policy.parse_workflow(text)["jobs"]["verify"]["steps"]}
        with tempfile.TemporaryDirectory(prefix="urgent-release-nm-") as tmp:
            root = pathlib.Path(tmp)
            tools = root / "bin"
            tools.mkdir()
            fake_nm = tools / "nm"
            fake_nm.write_text("#!/bin/sh\necho '0000000000000000 - 00 0000    OSO /tmp/x.o'\n"
                               "i=0; while [ $i -lt 40000 ]; do echo '0000000100003f90 T _symbol_padding_line'; "
                               "i=$((i+1)); done\n", encoding="utf-8")
            fake_nm.chmod(0o755)
            binary = root / "apple"
            binary.write_bytes(b"\0" * 64)
            (root / "runner").mkdir()
            env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ.get("PATH", ""), NEW="26.0.1",
                       BIN=str(binary), RUNNER_TEMP=str(root / "runner"))
            result = subprocess.run(["bash", "-c", steps["Packaging standard and checksummed artifact"]["run"]],
                                    env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("carries 1 debug-map (N_OSO) entries", result.stdout + result.stderr)

    def run_with_nm(self, nm_script: str, binary_exists: bool = True):
        _, text = recorded_workflow()
        steps = {step.get("name"): step for step in policy.parse_workflow(text)["jobs"]["verify"]["steps"]}
        with tempfile.TemporaryDirectory(prefix="urgent-release-nm-") as tmp:
            root = pathlib.Path(tmp)
            tools = root / "bin"
            tools.mkdir()
            (tools / "nm").write_text(nm_script, encoding="utf-8")
            (tools / "nm").chmod(0o755)
            binary = root / "apple"
            if binary_exists:
                binary.write_bytes(b"\0" * 64)
            (root / "runner").mkdir()
            env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ.get("PATH", ""), NEW="26.0.1",
                       BIN=str(binary), RUNNER_TEMP=str(root / "runner"))
            result = subprocess.run(["bash", "-c", steps["Packaging standard and checksummed artifact"]["run"]],
                                    env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False)
            made = (root / "runner" / "urgent-release-artifact").exists()
        return result, made

    def test_an_nm_that_cannot_run_fails_the_step(self) -> None:
        result, made = self.run_with_nm("#!/bin/sh\nexit 1\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(made, "no artifact may be produced when the debug-map check cannot run")

    def test_a_home_path_check_that_cannot_run_fails_the_step(self) -> None:
        # nm reports nothing, then grep cannot read the binary (exit 2): that must fail, not pass.
        result, made = self.run_with_nm("#!/bin/sh\nexit 0\n", binary_exists=False)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("or the check could not run", result.stdout + result.stderr)
        self.assertFalse(made)


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("cc") and shutil.which("nm"),
                     "the packaging step uses macOS tools (Mach-O nm, bsdtar); the local canonical tier runs it")
class RecordedPackagingTests(unittest.TestCase):
    """Run the recorded packaging step against small compiled binaries."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="urgent-release-packaging-")
        self.tmp = pathlib.Path(self._tmp.name)
        _, text = recorded_workflow()
        steps = {step.get("name"): step for step in policy.parse_workflow(text)["jobs"]["verify"]["steps"]}
        self.script = steps["Packaging standard and checksummed artifact"]["run"]
        (self.tmp / "main.c").write_text("int main(void) { return 0; }\n", encoding="utf-8")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def binary(self, label: str, debug: bool = False) -> pathlib.Path:
        target = self.tmp / label / "apple"
        target.parent.mkdir()
        if debug:
            obj = self.tmp / (label + ".o")
            subprocess.run(["cc", "-g", "-c", str(self.tmp / "main.c"), "-o", str(obj)], check=True, capture_output=True)
            subprocess.run(["cc", str(obj), "-o", str(target)], check=True, capture_output=True)
        else:
            subprocess.run(["cc", str(self.tmp / "main.c"), "-o", str(target)], check=True, capture_output=True)
        return target

    def package(self, binary: pathlib.Path, tools: str = ""):
        runner_temp = self.tmp / ("runner-" + binary.parent.name)
        runner_temp.mkdir()
        path = os.path.dirname(sys.executable) + os.pathsep + os.environ.get("PATH", "")
        env = dict(os.environ, PATH=(tools + os.pathsep + path) if tools else path,
                   NEW="26.0.1", BIN=str(binary), RUNNER_TEMP=str(runner_temp))
        result = subprocess.run(["bash", "-c", self.script], env=env, stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, check=False)
        return result, runner_temp / "urgent-release-artifact"

    def test_a_clean_binary_is_packaged_to_the_standard(self) -> None:
        result, out = self.package(self.binary("clean"))
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = out / "apple-v26.0.1-macos-arm64.tar.gz"
        with tarfile.open(archive) as handle:
            members = [(m.name, m.uid, m.gid, m.uname, m.gname, m.isreg(), sorted(set(m.pax_headers) - {"mtime"}))
                       for m in handle.getmembers()]
        self.assertEqual(members, [("apple", 0, 0, "", "", True, [])])
        checksum = (out / "apple-v26.0.1-macos-arm64.tar.gz.sha256").read_text(encoding="utf-8")
        self.assertEqual(checksum.count("\n"), 1)
        self.assertEqual(checksum.split()[0], hashlib.sha256(archive.read_bytes()).hexdigest())
        self.assertIn(checksum.strip(), result.stdout)

    def test_a_debug_map_entry_is_refused(self) -> None:
        result, _ = self.package(self.binary("debug", debug=True))
        self.assertEqual(result.returncode, 1)
        self.assertIn("debug-map (N_OSO) entries", result.stdout + result.stderr)

    def test_an_archive_off_the_standard_is_refused(self) -> None:
        # A stand-in tar that drops the ownership options, as a regressed packaging line would:
        # the archive then records the building user, and the outcome check must refuse it.
        tools = self.tmp / "tools"
        tools.mkdir()
        shim = tools / "tar"
        shim.write_text(
            "#!/bin/bash\nargs=()\nskip=0\nfor a in \"$@\"; do\n"
            "  if [ \"$skip\" = 1 ]; then skip=0; continue; fi\n"
            "  case \"$a\" in --uid|--gid|--uname|--gname) skip=1; continue;; esac\n"
            "  args+=(\"$a\")\ndone\nexec /usr/bin/tar \"${args[@]}\"\n", encoding="utf-8")
        shim.chmod(0o755)
        if os.getuid() == 0:
            self.skipTest("running as root, so the building user is uid 0 anyway")
        result, _ = self.package(self.binary("owned"), tools=str(tools))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("the archive does not meet the packaging standard", result.stdout + result.stderr)

    def test_an_extended_attribute_record_is_refused(self) -> None:
        # A stand-in tar that drops the options suppressing extended attributes, on a binary that
        # carries one explicitly: the archive gains a pax record, which the check must refuse.
        tools = self.tmp / "tools-xattr"
        tools.mkdir()
        shim = tools / "tar"
        shim.write_text(
            "#!/bin/bash\nargs=()\nfor a in \"$@\"; do\n"
            "  case \"$a\" in --no-xattrs|--no-acls|--no-fflags) continue;; esac\n"
            "  args+=(\"$a\")\ndone\nexec /usr/bin/tar \"${args[@]}\"\n", encoding="utf-8")
        shim.chmod(0o755)
        binary = self.binary("xattr")
        subprocess.run(["xattr", "-w", "org.example.apple-cli-test", "1", str(binary)], check=True, capture_output=True)
        result, _ = self.package(binary, tools=str(tools))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("the archive does not meet the packaging standard", result.stdout + result.stderr)

    def test_a_member_that_is_not_a_regular_file_is_refused(self) -> None:
        # A short relative link, so the member carries no pax linkpath record and only the
        # regular-file condition can refuse it.
        target = self.binary("linked")
        target.rename(target.parent / "apple-real")
        (target.parent / "apple").symlink_to("apple-real")
        result, _ = self.package(target.parent / "apple")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("the archive does not meet the packaging standard", result.stdout + result.stderr)

    def test_a_home_directory_path_is_refused(self) -> None:
        binary = self.binary("home")
        with open(binary, "ab") as handle:
            handle.write(b"/Users/example/project")
        result, _ = self.package(binary)
        self.assertEqual(result.returncode, 1)
        self.assertIn("home-directory path", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
