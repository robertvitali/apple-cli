import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from types import ModuleType
import unicodedata
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
AGENTS_PATH = REPO_ROOT / "AGENTS.md"
TEMPLATE_PATH = REPO_ROOT / ".github" / "PULL_REQUEST_TEMPLATE.md"
CI_WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "ci.yml"
GOVERNANCE_WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "governance.yml"
RETIRED_METADATA_WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "pr-metadata.yml"
VALIDATOR_PATH = REPO_ROOT / "scripts" / "ci" / "pr_metadata.py"
WORKFLOW_POLICY_PATH = REPO_ROOT / "scripts" / "ci" / "workflow_policy.py"
ACTION_PINS_PATH = REPO_ROOT / "scripts" / "ci" / "action_pins.py"
ALLOWLIST_PATH = REPO_ROOT / ".github" / "actions-allowlist.json"


def load_validator_path(path: Path, module_name: str = "pr_metadata") -> ModuleType:
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load PR metadata validator")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def reviewed_checkout_pin() -> tuple[str, str]:
    """The reviewed `actions/checkout` commit and version, read from the allowlist, so a pin bump
    changes the allowlist and the workflows and no test."""
    spec = importlib.util.spec_from_file_location("action_pins", ACTION_PINS_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load action pin checker")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.load_allowlist(ALLOWLIST_PATH)["actions/checkout"]


CHECKOUT_SHA, CHECKOUT_VERSION = reviewed_checkout_pin()


def parse_governance_workflow(text: str) -> dict:
    """Parse with the `Supply-chain policy` scan's own fail-closed parser.

    The assertions then see the same mapping the scan judges (comments stripped, dash-form
    steps normalised), so the pin is exactly as faithful to GitHub's reading as that parser
    is, and a construct the parser refuses raises instead of passing a text match.
    """
    policy = load_validator_path(WORKFLOW_POLICY_PATH, "workflow_policy")
    return policy.parse_workflow(text)


def load_validator() -> ModuleType:
    return load_validator_path(VALIDATOR_PATH)


def checklist_items_from_template(template: str) -> list[str]:
    return re.findall(r"^- \[ \] (.+)$", template, flags=re.MULTILINE)


def template_checklist_items() -> list[str]:
    template = TEMPLATE_PATH.read_text(encoding="utf-8")
    return checklist_items_from_template(template)


def valid_body(checklist_items=None) -> str:
    required_items = (
        template_checklist_items() if checklist_items is None else checklist_items
    )
    checklist = "\n".join(f"- [x] {item}" for item in required_items)
    return f"""## Rationale

Give callers deterministic pull-request feedback.

## Details

Add a repository-owned metadata validator with no product behavior change.

## Testing

| Command | Result |
| --- | --- |
| `python3 -m unittest` | All targeted tests passed. |

## Checklist

{checklist}

Reviewed-by: automated reviewer (test-source) — approve
Co-Authored-By: Automation Example <automation@example.com>
"""


class PullRequestTemplateTests(unittest.TestCase):
    def test_template_has_exactly_four_required_h2_headings_in_order(self) -> None:
        self.assertTrue(TEMPLATE_PATH.is_file(), "PR template must exist")
        template = TEMPLATE_PATH.read_text(encoding="utf-8")

        headings = re.findall(r"^##\s+(.+?)\s*$", template, flags=re.MULTILINE)

        self.assertEqual(
            headings,
            ["Rationale", "Details", "Testing", "Checklist"],
        )

    def test_template_contains_every_required_checklist_item(self) -> None:
        validator = load_validator()

        checklist = template_checklist_items()

        self.assertEqual(len(checklist), 16)
        self.assertEqual(len(set(checklist)), 16)
        self.assertEqual(tuple(checklist), validator.REQUIRED_CHECKLIST_ITEMS)

    def test_tampered_template_cannot_weaken_validator_checklist_policy(self) -> None:
        trusted_validator = load_validator()
        template = TEMPLATE_PATH.read_text(encoding="utf-8")
        removed_item = trusted_validator.REQUIRED_CHECKLIST_ITEMS[0]
        tampered_template = template.replace(f"- [ ] {removed_item}\n", "", 1)
        tampered_items = checklist_items_from_template(tampered_template)
        self.assertEqual(len(tampered_items), 15)

        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            copied_validator_path = temporary_root / "scripts" / "ci" / "pr_metadata.py"
            copied_template_path = (
                temporary_root / ".github" / "PULL_REQUEST_TEMPLATE.md"
            )
            copied_validator_path.parent.mkdir(parents=True)
            copied_template_path.parent.mkdir(parents=True)
            shutil.copyfile(VALIDATOR_PATH, copied_validator_path)
            copied_template_path.write_text(tampered_template, encoding="utf-8")
            tampered_validator = load_validator_path(
                copied_validator_path,
                module_name="tampered_pr_metadata",
            )

            errors = tampered_validator.validate_body(valid_body(tampered_items))

        self.assertNotEqual(errors, [])
        self.assertEqual(
            tampered_validator.REQUIRED_CHECKLIST_ITEMS,
            trusted_validator.REQUIRED_CHECKLIST_ITEMS,
        )

    def test_template_guidance_covers_testing_privacy_and_squash_provenance(self) -> None:
        template = TEMPLATE_PATH.read_text(encoding="utf-8")

        self.assertIn("| Command | Result |", template)
        self.assertIn("| --- | --- |", template)
        for guidance in (
            "Do not include private tracker identifiers or internal URLs.",
            "Do not paste personal, account, message, mail, contact, note, calendar, reminder, or other live-store values.",
            "Use only commands, counts, hashes, field names, and pass/fail results as evidence.",
            "The final PR description becomes the squash commit body.",
            "End it with one or more contiguous Reviewed-by: trailers, followed by any Co-Authored-By: trailers.",
        ):
            self.assertIn(guidance, template)

        comments = re.findall(r"<!--.*?-->", template, flags=re.DOTALL)
        self.assertGreaterEqual(len(comments), 5)


class PullRequestWorkflowTests(unittest.TestCase):
    def test_trusted_metadata_job_invokes_repository_validator(self) -> None:
        self.assertTrue(
            GOVERNANCE_WORKFLOW_PATH.is_file(),
            "dedicated PR metadata workflow must exist",
        )
        self.assertFalse(RETIRED_METADATA_WORKFLOW_PATH.exists())
        workflow = GOVERNANCE_WORKFLOW_PATH.read_text(encoding="utf-8")
        match = re.search(
            r"^  required:\n(?P<job>.*?)(?=^  [a-z0-9-]+:\n|\Z)",
            workflow,
            flags=re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(match, "PR metadata job must exist")
        job = match.group("job")

        self.assertIn("name: governance / required", job)
        self.assertRegex(
            job,
            rf"(?m)^\s+- uses: actions/checkout@{CHECKOUT_SHA} +# {re.escape(CHECKOUT_VERSION)}$",
        )
        self.assertIn("ref: ${{ github.event.pull_request.base.sha }}", job)
        self.assertIn("persist-credentials: false", job)
        self.assertIn(
            'python3 scripts/ci/pr_metadata.py --event "$GITHUB_EVENT_PATH"',
            job,
        )
        self.assertNotIn("github.event.pull_request.title", job)
        self.assertNotIn("github.event.pull_request.body", job)
        self.assertNotIn("grep -qE", job)
        for forbidden in (
            "github.event.pull_request.head",
            "merge_commit_sha",
            "refs/pull/",
            "actions/cache",
            "upload-artifact",
            "download-artifact",
            "secrets.",
        ):
            self.assertNotIn(forbidden, workflow)
        self.assertIn("\n  pull_request_target:\n", workflow)
        self.assertNotIn("\n  pull_request:\n", workflow)
        self.assertIn(
            "types: [opened, edited, reopened, synchronize, ready_for_review]",
            workflow,
        )
        # The workflow scan admits any read scope outside its forbidden set, so these
        # exact parsed blocks are what pin the metadata-only posture: a new scope, even a
        # read one, fails here until the control-plane half lands with its own review.
        document = parse_governance_workflow(workflow)
        self.assertEqual(document["permissions"], {"contents": "read"})
        self.assertEqual(document["jobs"]["required"]["permissions"], {"contents": "read"})
        consumers = sorted(
            path.name
            for path in (REPO_ROOT / ".github" / "workflows").glob("*.yml")
            if re.search(
                r"(?m)^\s{2}pull_request_target:\s*$",
                path.read_text(encoding="utf-8"),
            )
        )
        self.assertEqual(consumers, ["governance.yml"])

    def test_pr_head_ci_cannot_duplicate_the_metadata_check(self) -> None:
        workflow = CI_WORKFLOW_PATH.read_text(encoding="utf-8")

        self.assertNotIn("metadata / required", workflow)
        self.assertNotIn("governance / required", workflow)
        self.assertNotIn("scripts/ci/pr_metadata.py", workflow)
        self.assertNotIn("pr-title-lint:", workflow)
        self.assertNotIn("pull_request_target:", workflow)

    def test_governance_job_runs_only_the_metadata_validator_today(self) -> None:
        self.assertTrue(GOVERNANCE_WORKFLOW_PATH.is_file())
        workflow = GOVERNANCE_WORKFLOW_PATH.read_text(encoding="utf-8")

        # The whole parsed workflow is pinned: any added step, scope, trigger or job, in
        # any YAML spelling the scan's parser accepts, fails here. Implementing the
        # control-plane half is a deliberate, reviewed edit of this expectation.
        self.assertEqual(
            parse_governance_workflow(workflow),
            {
                "name": "Governance",
                "on": {
                    "pull_request_target": {
                        "types": ["opened", "edited", "reopened", "synchronize", "ready_for_review"],
                    },
                },
                "permissions": {"contents": "read"},
                "jobs": {
                    "required": {
                        "name": "governance / required",
                        "runs-on": "ubuntu-latest",
                        "permissions": {"contents": "read"},
                        "timeout-minutes": "5",
                        "steps": [
                            {
                                "uses": f"actions/checkout@{CHECKOUT_SHA}",
                                "with": {
                                    "ref": "${{ github.event.pull_request.base.sha }}",
                                    "persist-credentials": False,
                                },
                            },
                            {
                                "name": "Validate pull request metadata",
                                "run": 'python3 scripts/ci/pr_metadata.py --event "$GITHUB_EVENT_PATH"',
                            },
                        ],
                    },
                },
            },
        )
        # The parser strips comments, so the header's disclosure is checked as text.
        self.assertIn("validates the pull request's title and body only", workflow)

    def test_repository_instructions_define_only_the_governance_exception(self) -> None:
        self.assertTrue(GOVERNANCE_WORKFLOW_PATH.is_file())
        instructions = " ".join(AGENTS_PATH.read_text(encoding="utf-8").split())
        metadata_workflow = GOVERNANCE_WORKFLOW_PATH.read_text(encoding="utf-8")
        check_name_match = re.search(
            r"(?m)^\s+name: (governance / required)$",
            metadata_workflow,
        )
        self.assertIsNotNone(check_name_match)
        check_name = check_name_match.group(1)

        self.assertIn(f"`{check_name}`", instructions)
        for required_policy in (
            "ordinary build/test stays on `pull_request` with a read-only token and no secrets",
            "sole `pull_request_target` workflow",
            "base-owned workflow checks out and executes only the base-owned metadata validator",
            "`contents: read`, no secrets, and PR title/body inspection only",
            "PR title/body inspection only for its verdict",
            "select one explanatory diagnostic and never change it",
            "never checkout, execute, download, or cache PR code or artifacts",
            "No other `pull_request_target` use is permitted",
            "proves metadata hygiene and nothing more",
            "must not be treated as that gate until it is",
        ):
            self.assertIn(required_policy, instructions)
        self.assertNotIn("metadata/control-plane inspection", instructions)
        self.assertNotIn(
            "keep `pull_request` (never `pull_request_target`)",
            instructions,
        )


class TitleValidationTests(unittest.TestCase):
    def test_accepts_supported_conventional_commit_title_variants(self) -> None:
        self.assertTrue(VALIDATOR_PATH.is_file(), "metadata validator must exist")
        validator = load_validator()
        self.assertTrue(hasattr(validator, "validate_title"))

        for title in (
            "feat: add export command",
            "fix(mail): preserve unread state",
            "fix(mail_sync.v2-test): preserve unread state",
            "refactor!: change output envelope",
            "ci(workflows)!: tighten required checks",
        ):
            with self.subTest(title=title):
                self.assertEqual(validator.validate_title(title), [])

    def test_rejects_unsupported_or_malformed_title_shapes(self) -> None:
        validator = load_validator()

        for title in (
            "feature: add export command",
            "feat(): add export command",
            "fix( ): preserve unread state",
            "fix:preserve unread state",
            "Fix: preserve unread state",
            "fix!(): preserve unread state",
        ):
            with self.subTest(title=title):
                self.assertNotEqual(validator.validate_title(title), [])

    def test_rejects_scope_characters_not_supported_by_commit_lint(self) -> None:
        validator = load_validator()

        for title in (
            "fix(Mail): preserve unread state",
            "fix(mail sync): preserve unread state",
            "fix(mail/sync): preserve unread state",
            "fix(mail@sync): preserve unread state",
        ):
            with self.subTest(title=title):
                self.assertNotEqual(validator.validate_title(title), [])

    def test_rejects_internal_tracker_metadata_without_echoing_title(self) -> None:
        validator = load_validator()
        tracker_name = "asa" + "na"
        invalid_titles = (
            f"docs: remove {tracker_name}: metadata",
            f"docs: remove https://app.{tracker_name}.com/0/project/task",
            "docs: remove " + "GID" + "-REDACTED",
        )

        for title in invalid_titles:
            with self.subTest(title=title):
                errors = validator.validate_title(title)

                self.assertTrue(any("tracker" in error for error in errors))
                self.assertFalse(any(title in error for error in errors))

    def test_rejects_nonlowercase_period_terminated_or_padded_descriptions(self) -> None:
        validator = load_validator()

        for title in (
            "feat: Add export command",
            "feat: add export command.",
            "feat:  add export command",
            "feat: add export command ",
        ):
            with self.subTest(title=title):
                self.assertNotEqual(validator.validate_title(title), [])

    def test_enforces_seventy_two_character_title_limit(self) -> None:
        validator = load_validator()

        self.assertEqual(validator.validate_title("docs: " + ("a" * 66)), [])
        self.assertNotEqual(validator.validate_title("docs: " + ("a" * 67)), [])


class BodyValidationTests(unittest.TestCase):
    def test_accepts_completed_body_with_required_sections_and_trailers(self) -> None:
        validator = load_validator()
        self.assertTrue(hasattr(validator, "validate_body"))

        self.assertEqual(validator.validate_body(valid_body()), [])
        self.assertEqual(
            validator.validate_body(
                valid_body().replace("automation@example.com", "automation@example.org")
            ),
            [],
        )
        self.assertEqual(
            validator.validate_body(
                valid_body().replace(
                    "Co-Authored-By: Automation Example <automation@example.com>\n",
                    "",
                )
            ),
            [],
        )
        self.assertEqual(
            validator.validate_body(
                valid_body().replace(
                    "Co-Authored-By: Automation Example <automation@example.com>",
                    "Co-Authored-By: Automation Example <automation@example.com>\n"
                    "Co-Authored-By: Second Automation <second@example.org>",
                )
            ),
            [],
        )

    def test_accepts_conventional_trailers_before_final_provenance(self) -> None:
        validator = load_validator()
        body = valid_body().replace(
            "Reviewed-by:",
            "BREAKING-CHANGE: callers must use the new synthetic field.\n"
            "Reviewed-by:",
            1,
        )

        self.assertEqual(validator.validate_body(body), [])

    def test_terminal_trailers_do_not_count_as_checklist_content(self) -> None:
        validator = load_validator()
        body = valid_body().replace("- [x]", "- [ ]").replace(
            "Reviewed-by:",
            "BREAKING-CHANGE: callers must use the new synthetic field.\n"
            "Reviewed-by:",
            1,
        )

        self.assertNotEqual(validator.validate_body(body), [])

    def test_rejects_missing_required_checklist_item(self) -> None:
        validator = load_validator()

        for required_item in template_checklist_items():
            with self.subTest(required_item=required_item):
                body = valid_body().replace(f"- [x] {required_item}\n", "", 1)
                errors = validator.validate_body(body)

                self.assertNotEqual(errors, [])
                self.assertFalse(any(required_item in error for error in errors))

    def test_rejects_body_with_only_one_required_checklist_item(self) -> None:
        validator = load_validator()
        required_items = template_checklist_items()
        body = valid_body()
        for required_item in required_items[1:]:
            body = body.replace(f"- [x] {required_item}\n", "", 1)

        errors = validator.validate_body(body)

        self.assertNotEqual(errors, [])
        self.assertFalse(
            any(item in error for item in required_items for error in errors)
        )

    def test_rejects_duplicate_required_checklist_item(self) -> None:
        validator = load_validator()

        for required_item in template_checklist_items():
            with self.subTest(required_item=required_item):
                checked_item = f"- [x] {required_item}\n"
                body = valid_body().replace(checked_item, checked_item * 2, 1)
                errors = validator.validate_body(body)

                self.assertNotEqual(errors, [])
                self.assertFalse(any(required_item in error for error in errors))

    def test_rejects_unchecked_required_checklist_item(self) -> None:
        validator = load_validator()

        for required_item in template_checklist_items():
            with self.subTest(required_item=required_item):
                body = valid_body().replace(
                    f"- [x] {required_item}",
                    f"- [ ] {required_item}",
                    1,
                )
                errors = validator.validate_body(body)

                self.assertNotEqual(errors, [])
                self.assertFalse(any(required_item in error for error in errors))

    def test_rejects_altered_required_checklist_item(self) -> None:
        validator = load_validator()

        for required_item in template_checklist_items():
            with self.subTest(required_item=required_item):
                altered_item = f"{required_item} altered"
                body = valid_body().replace(required_item, altered_item, 1)
                errors = validator.validate_body(body)

                self.assertNotEqual(errors, [])
                self.assertFalse(any(altered_item in error for error in errors))

    def test_rejects_missing_duplicate_reordered_or_extra_h2_headings(self) -> None:
        validator = load_validator()
        body = valid_body()
        reordered = (
            body.replace("## Rationale", "## Temporary", 1)
            .replace("## Details", "## Rationale", 1)
            .replace("## Temporary", "## Details", 1)
        )
        invalid_bodies = (
            body.replace("## Testing", "Testing", 1),
            body.replace("## Details", "## Rationale\n\nDuplicate.\n\n## Details", 1),
            reordered,
            body.replace("## Testing", "## Context\n\nExtra.\n\n## Testing", 1),
        )

        for invalid_body in invalid_bodies:
            with self.subTest():
                self.assertNotEqual(validator.validate_body(invalid_body), [])

    def test_rejects_sections_containing_only_comments_or_template_scaffolding(self) -> None:
        validator = load_validator()
        body = valid_body()
        invalid_bodies = (
            body.replace(
                "Give callers deterministic pull-request feedback.",
                "<!-- Describe the rationale. -->",
            ),
            body.replace(
                "Add a repository-owned metadata validator with no product behavior change.",
                "TBD",
            ),
            body.replace(
                "| `python3 -m unittest` | All targeted tests passed. |",
                "| <!-- exact command --> | <!-- value-free result --> |",
            ),
            body.replace("- [x]", "- [ ]"),
        )

        for invalid_body in invalid_bodies:
            with self.subTest():
                self.assertNotEqual(validator.validate_body(invalid_body), [])

    def test_requires_contiguous_final_provenance_trailers_in_order(self) -> None:
        validator = load_validator()
        body = valid_body()
        reviewed = "Reviewed-by: automated reviewer (test-source) — approve"
        coauthored = "Co-Authored-By: Automation Example <automation@example.com>"
        invalid_bodies = (
            body.replace(f"{reviewed}\n{coauthored}\n", ""),
            body.replace(f"{reviewed}\n", ""),
            body.replace(f"{reviewed}\n{coauthored}", f"{coauthored}\n{reviewed}"),
            body.replace(f"{reviewed}\n{coauthored}", f"{reviewed}\n\n{coauthored}"),
            body + "Evidence follows trailers.\n",
        )

        for invalid_body in invalid_bodies:
            with self.subTest():
                self.assertNotEqual(validator.validate_body(invalid_body), [])

    def test_rejects_internal_tracker_markers_urls_and_identifiers(self) -> None:
        validator = load_validator()
        body = valid_body()
        tracker_key = "asa" + "na:"
        tracker_url = "https://app." + "asana.com/0/project/task"
        tracker_identifier = "GID" + "-REDACTED"
        invalid_bodies = tuple(
            body.replace(
                "Reviewed-by:",
                f"{marker}\n\nReviewed-by:",
                1,
            )
            for marker in (tracker_key, tracker_url, tracker_identifier)
        )

        for invalid_body in invalid_bodies:
            with self.subTest():
                self.assertNotEqual(validator.validate_body(invalid_body), [])

    def test_rejects_non_reserved_coauthor_email_domains(self) -> None:
        validator = load_validator()
        invalid_bodies = tuple(
            valid_body().replace("automation@example.com", address)
            for address in (
                "automation@sample.invalid",
                "automation@localhost",
            )
        )

        for invalid_body in invalid_bodies:
            with self.subTest():
                self.assertNotEqual(validator.validate_body(invalid_body), [])

    def test_rejects_malformed_coauthor_trailer_values(self) -> None:
        validator = load_validator()
        valid_value = "Automation Example <automation@example.com>"
        invalid_values = (
            "Automation Example",
            "Automation Example automation@example.com",
            "<automation@example.com>",
            "name <automation@example.com>",
            "N/A <automation@example.com>",
            "--- <automation@example.com>",
            "Automation Example <automation@example.com> <second@example.org>",
            "Automation Example <automation@example.com> trailing",
            "Automation Example <automation@sample.invalid>",
        )

        for invalid_value in invalid_values:
            with self.subTest(invalid_value=invalid_value):
                body = valid_body().replace(valid_value, invalid_value, 1)
                errors = validator.validate_body(body)

                self.assertNotEqual(errors, [])
                self.assertFalse(any(invalid_value in error for error in errors))

    def test_rejects_unedited_provenance_placeholders(self) -> None:
        validator = load_validator()
        invalid_body = valid_body().replace(
            "Reviewed-by: automated reviewer (test-source) — approve\n"
            "Co-Authored-By: Automation Example <automation@example.com>",
            "Reviewed-by: <reviewer> (<model-or-source>) — <verdict>\n"
            "Co-Authored-By: <name> <name@example.com>",
        )

        self.assertNotEqual(validator.validate_body(invalid_body), [])


class MetadataValidationTests(unittest.TestCase):
    def test_combines_title_and_body_diagnostics(self) -> None:
        validator = load_validator()
        self.assertTrue(hasattr(validator, "validate_metadata"))
        invalid_body = valid_body().replace("## Details", "## Extra", 1)

        errors = validator.validate_metadata("feature: Add command.", invalid_body)

        self.assertGreaterEqual(len(errors), 2)


class CommandLineTests(unittest.TestCase):
    def test_reads_and_validates_default_github_event_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            event_path = Path(temporary_directory) / "event.json"
            environment = os.environ.copy()
            environment["GITHUB_EVENT_PATH"] = str(event_path)
            event = {
                "pull_request": {
                    "title": "ci: validate pull request metadata",
                    "body": valid_body(),
                }
            }
            event_path.write_text(json.dumps(event), encoding="utf-8")

            valid_result = subprocess.run(
                [sys.executable, str(VALIDATOR_PATH)],
                cwd=REPO_ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            event["pull_request"]["title"] = "Feature: Invalid metadata."
            event_path.write_text(json.dumps(event), encoding="utf-8")
            invalid_result = subprocess.run(
                [sys.executable, str(VALIDATOR_PATH)],
                cwd=REPO_ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertEqual(valid_result.returncode, 0)
        self.assertEqual(valid_result.stdout, "")
        self.assertEqual(valid_result.stderr, "")
        self.assertNotEqual(invalid_result.returncode, 0)
        self.assertIn("title", invalid_result.stderr.casefold())

    def test_supports_explicit_event_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            event_path = Path(temporary_directory) / "event.json"
            event_path.write_text(
                json.dumps(
                    {
                        "pull_request": {
                            "title": "ci: validate pull request metadata",
                            "body": valid_body(),
                        }
                    }
                ),
                encoding="utf-8",
            )

            result = subprocess.run(
                [sys.executable, str(VALIDATOR_PATH), "--event", str(event_path)],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")

    def test_supports_direct_title_and_body_file_input(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            body_path = Path(temporary_directory) / "body.md"
            body_path.write_text(valid_body(), encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    str(VALIDATOR_PATH),
                    "--title",
                    "ci: validate pull request metadata",
                    "--body-file",
                    str(body_path),
                ],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")

    def test_undecodable_body_file_is_unreadable_input(self) -> None:
        # The body file is read as bytes and decoded as UTF-8; bytes that are not UTF-8 are
        # unreadable input (exit 2, one value-free diagnostic), never a traceback.
        cases = {
            "UTF-16 byte-order mark alone": b"\xff\xfe",
            "UTF-16 body": b"\xff\xfe" + valid_body().encode("utf-16-le"),
            "stray continuation byte": valid_body().encode("utf-8") + b"\x80",
            "encoded surrogate": b"\xed\xa0\x80",
        }
        for name, content in cases.items():
            with self.subTest(case=name), tempfile.TemporaryDirectory() as temporary_directory:
                body_path = Path(temporary_directory) / "body.md"
                body_path.write_bytes(content)
                result = subprocess.run(
                    [
                        sys.executable, "-I", "-S", "-B", str(VALIDATOR_PATH),
                        "--title", "ci: validate pull request metadata",
                        "--body-file", str(body_path),
                    ],
                    cwd=REPO_ROOT,
                    text=True,
                    capture_output=True,
                    check=False,
                )

                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
                self.assertEqual(
                    result.stderr, "error: unable to read pull-request metadata input\n"
                )
                self.assertNotIn("Traceback", result.stderr)

    def test_failure_diagnostics_do_not_echo_metadata_contents(self) -> None:
        body_marker = "SENTINEL_BODY_CONTENT_MUST_NOT_BE_PRINTED"
        title_marker = "SENTINEL_TITLE_CONTENT_MUST_NOT_BE_PRINTED"
        invalid_body = f"## Rationale\n\n{body_marker}\n"
        tracker_name = "asa" + "na"
        invalid_title = f"docs: remove {tracker_name}: {title_marker}"
        with tempfile.TemporaryDirectory() as temporary_directory:
            body_path = Path(temporary_directory) / "body.md"
            body_path.write_text(invalid_body, encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    str(VALIDATOR_PATH),
                    "--title",
                    invalid_title,
                    "--body-file",
                    str(body_path),
                ],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertNotIn(body_marker, result.stderr)
        self.assertNotIn(title_marker, result.stderr)


# Synthetic stand-ins for the metadata Dependabot generates: a capitalised "Bump" title and a
# release-notes body with none of the template's sections. No real package or account.
DEPENDABOT_TITLE = "build(deps): Bump examplepkg from 1.0.0 to 1.1.0 in /docs"
DEPENDABOT_BODY = (
    "Bumps [examplepkg](https://example.com/examplepkg) from 1.0.0 to 1.1.0.\n"
    "<details>\n<summary>Release notes</summary>\n\nSynthetic release notes.\n"
    "</details>\n\n---\n\nDependabot will resolve any conflicts with this PR.\n"
)
REWRITTEN_DEPENDABOT_TITLE = "build(docs): bump examplepkg from 1.0.0 to 1.1.0"
# Ids no GitHub account or repository can hold, so no real account or repository is named.
SYNTHETIC_REPOSITORY_ID = -101


def dependabot_pull_request(title: str, body: str) -> dict:
    return {
        "title": title,
        "body": body,
        "user": {"login": "dependabot[bot]", "type": "Bot", "id": 49699333},
        "head": {"repo": {"id": SYNTHETIC_REPOSITORY_ID}},
        "base": {"repo": {"id": SYNTHETIC_REPOSITORY_ID}},
    }


def forged_identities() -> dict[str, dict]:
    """Each entry changes exactly one identity property of a genuine Dependabot event."""
    variants: dict[str, dict] = {}

    def variant(name: str, mutate) -> None:
        pull_request = dependabot_pull_request(DEPENDABOT_TITLE, DEPENDABOT_BODY)
        mutate(pull_request)
        variants[name] = pull_request

    variant("login without bot suffix", lambda pr: pr["user"].update(login="dependabot"))
    variant("login with other case", lambda pr: pr["user"].update(login="Dependabot[bot]"))
    variant("user account type", lambda pr: pr["user"].update(type="User"))
    variant("other account id", lambda pr: pr["user"].update(id=0))
    variant("account id as text", lambda pr: pr["user"].update(id="49699333"))
    variant("account id as float", lambda pr: pr["user"].update(id=49699333.0))
    variant("missing account id", lambda pr: pr["user"].pop("id"))
    variant("missing user", lambda pr: pr.pop("user"))
    variant("fork head repository", lambda pr: pr["head"]["repo"].update(id=SYNTHETIC_REPOSITORY_ID + 1))
    variant("deleted head repository", lambda pr: pr["head"].update(repo=None))
    variant("missing head", lambda pr: pr.pop("head"))
    variant("head repository id as text", lambda pr: pr["head"]["repo"].update(id=str(SYNTHETIC_REPOSITORY_ID)))
    variant("repository ids as booleans", lambda pr: (pr["base"]["repo"].update(id=True), pr["head"]["repo"].update(id=True)))
    variant("head repository id as boolean", lambda pr: (pr["head"]["repo"].update(id=False), pr["base"]["repo"].update(id=0)))
    variant("base repository id as boolean", lambda pr: (pr["head"]["repo"].update(id=0), pr["base"]["repo"].update(id=False)))
    variant("missing base repository", lambda pr: pr["base"].pop("repo"))
    return variants


class DependabotPathTests(unittest.TestCase):
    """Dependabot pull requests get no exemption: the merger rewrites their metadata (design §8)."""

    def run_event(self, pull_request: dict) -> tuple[int, str, str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            event_path = Path(temporary_directory) / "event.json"
            event_path.write_text(json.dumps({"pull_request": pull_request}), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, "-I", "-S", "-B", str(VALIDATOR_PATH), "--event", str(event_path)],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
        return result.returncode, result.stdout, result.stderr

    def test_identity_requires_every_field_exactly(self) -> None:
        validator = load_validator()
        genuine = dependabot_pull_request(DEPENDABOT_TITLE, DEPENDABOT_BODY)
        self.assertTrue(validator.is_dependabot_proposal(genuine))
        for name, pull_request in forged_identities().items():
            with self.subTest(name=name):
                self.assertFalse(validator.is_dependabot_proposal(pull_request))
        for value in (None, [], "dependabot[bot]", 49699333):
            with self.subTest(value=value):
                self.assertFalse(validator.is_dependabot_proposal(value))

    def test_default_dependabot_metadata_fails_and_names_the_rewrite(self) -> None:
        validator = load_validator()
        returncode, stdout, stderr = self.run_event(
            dependabot_pull_request(DEPENDABOT_TITLE, DEPENDABOT_BODY)
        )

        self.assertEqual(returncode, 1)
        self.assertEqual(stdout, "")
        self.assertIn("title description must start with a lowercase letter", stderr)
        self.assertIn("body must contain exactly the required H2 sections in order", stderr)
        self.assertEqual(stderr.count(validator.DEPENDABOT_REWRITE_DIAGNOSTIC), 1)
        self.assertTrue(stderr.rstrip("\n").endswith(validator.DEPENDABOT_REWRITE_DIAGNOSTIC))
        for echoed in ("examplepkg", "Synthetic release notes", "Bump"):
            self.assertNotIn(echoed, stderr)

    def test_rewritten_dependabot_metadata_passes(self) -> None:
        returncode, stdout, stderr = self.run_event(
            dependabot_pull_request(REWRITTEN_DEPENDABOT_TITLE, valid_body())
        )

        self.assertEqual((returncode, stdout, stderr), (0, "", ""))

    def test_forged_identity_never_receives_the_dependabot_diagnostic(self) -> None:
        validator = load_validator()
        for name, pull_request in forged_identities().items():
            with self.subTest(name=name):
                returncode, _, stderr = self.run_event(pull_request)
                self.assertEqual(returncode, 1)
                self.assertNotIn(validator.DEPENDABOT_REWRITE_DIAGNOSTIC, stderr)

    def test_identity_never_changes_the_verdict(self) -> None:
        validator = load_validator()
        cases = {
            "rewritten": (REWRITTEN_DEPENDABOT_TITLE, valid_body()),
            "default": (DEPENDABOT_TITLE, DEPENDABOT_BODY),
            "bad title only": (DEPENDABOT_TITLE, valid_body()),
            "bad body only": (REWRITTEN_DEPENDABOT_TITLE, DEPENDABOT_BODY),
        }
        for name, (title, body) in cases.items():
            with self.subTest(case=name):
                genuine = self.run_event(dependabot_pull_request(title, body))
                anonymous = self.run_event({"title": title, "body": body})
                self.assertEqual(genuine[0], anonymous[0])
                expected_extra = (
                    f"error: {validator.DEPENDABOT_REWRITE_DIAGNOSTIC}\n" if genuine[0] else ""
                )
                self.assertEqual(genuine[2], anonymous[2] + expected_extra)

    def test_direct_input_never_names_dependabot(self) -> None:
        validator = load_validator()
        with tempfile.TemporaryDirectory() as temporary_directory:
            body_path = Path(temporary_directory) / "body.md"
            body_path.write_text(DEPENDABOT_BODY, encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable, "-I", "-S", "-B", str(VALIDATOR_PATH),
                    "--title", DEPENDABOT_TITLE, "--body-file", str(body_path),
                ],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertEqual(result.returncode, 1)
        self.assertNotIn(validator.DEPENDABOT_REWRITE_DIAGNOSTIC, result.stderr)


REVIEWED_TRAILER = "Reviewed-by: automated reviewer (test-source) — approve"
COAUTHORED_TRAILER = "Co-Authored-By: Automation Example <automation@example.com>"
# Each one ends a line for Python's `str.splitlines()` but not for git, which splits at line
# feeds only (a lone carriage return is a line ending to Markdown, never to git's trailers).
PYTHON_ONLY_LINE_BREAKS = (
    "\u2028", "\u2029", "\x85", "\x0b", "\x0c", "\x1c", "\x1d", "\x1e", "\r",
)


def line_number_of(body: str, needle: str) -> int:
    return body[: body.index(needle)].count("\n") + 1


def replaced(text: str, old: str, new: str) -> str:
    """`text` with its one occurrence of `old` replaced by `new`. A fixture whose anchor is
    missing or repeated raises, so a drifted `valid_body()` cannot turn a case into a test of
    the unedited body (an acceptance case would then pass for the wrong reason)."""
    count = text.count(old)
    if count != 1:
        raise AssertionError(f"fixture anchor {ascii(old)} occurs {count} times, not once")
    return text.replace(old, new)


def with_crlf_line_endings(body: str) -> str:
    """`body` with every line feed made a CRLF pair; it must hold line feeds and no carriage
    return, so the result really is a CRLF body."""
    if "\r" in body or "\n" not in body:
        raise AssertionError("a CRLF fixture needs a line-feed body with no carriage return")
    return body.replace("\n", "\r\n")


def joined_trailers_body(separator: str) -> str:
    """The audit's P1: the last two trailers joined by something other than a line feed."""
    return replaced(
        valid_body(),
        f"{REVIEWED_TRAILER}\n{COAUTHORED_TRAILER}",
        f"{REVIEWED_TRAILER}{separator}{COAUTHORED_TRAILER}",
    )


def template_filled_body(before_trailers: str = "\n") -> str:
    """The PR template as a contributor fills it in: comments kept, prose added, every box
    checked, and the trailers appended after the template's closing comment."""
    template = TEMPLATE_PATH.read_text(encoding="utf-8")
    for old, new in (
        ("-->\n\n## Details", "-->\n\nGive callers deterministic pull-request feedback.\n\n## Details"),
        ("-->\n\n## Testing", "-->\n\nAdd a repository-owned metadata validator.\n\n## Testing"),
        (
            "| <!-- Replace with an exact command. --> | <!-- Replace with a value-free result. --> |",
            "| `python3 -m unittest` | All targeted tests passed. |",
        ),
    ):
        if template.count(old) != 1:
            raise AssertionError("the PR template no longer has the expected shape")
        template = template.replace(old, new)
    if not template.endswith("-->\n"):
        raise AssertionError("the PR template no longer ends with its trailer guidance comment")
    return (
        template.replace("- [ ] ", "- [x] ")
        + before_trailers
        + f"{REVIEWED_TRAILER}\n{COAUTHORED_TRAILER}\n"
    )


def run_both_input_paths(
    title: str, body: str
) -> tuple[subprocess.CompletedProcess, subprocess.CompletedProcess]:
    """Run the validator on the same metadata through `--event` and through `--body-file`."""
    with tempfile.TemporaryDirectory() as temporary_directory:
        event_path = Path(temporary_directory) / "event.json"
        event_path.write_text(
            json.dumps({"pull_request": {"title": title, "body": body}}),
            encoding="utf-8",
        )
        body_path = Path(temporary_directory) / "body.md"
        body_path.write_bytes(body.encode("utf-8"))
        command = [sys.executable, "-I", "-S", "-B", str(VALIDATOR_PATH)]
        event = subprocess.run(
            command + ["--event", str(event_path)],
            cwd=REPO_ROOT, text=True, capture_output=True, check=False,
        )
        direct = subprocess.run(
            command + ["--title", title, "--body-file", str(body_path)],
            cwd=REPO_ROOT, text=True, capture_output=True, check=False,
        )
    return event, direct


def git_trailer_lines(body: str) -> list[str]:
    """The trailers git reads from the squash commit message this body would become."""
    with tempfile.TemporaryDirectory() as temporary_directory:
        environment = {
            "PATH": os.environ.get("PATH", ""),
            "HOME": temporary_directory,
            "LC_ALL": "C",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CEILING_DIRECTORIES": str(Path(temporary_directory).parent),
        }
        result = subprocess.run(
            # `--no-divider`: git reads a commit's own trailers without treating a `---` line
            # as the start of a patch, so the oracle must too.
            ["git", "interpret-trailers", "--parse", "--no-divider"],
            input=f"ci: validate pull request metadata\n\n{body}".encode("utf-8"),
            cwd=temporary_directory,
            env=environment,
            capture_output=True,
            check=True,
            timeout=30,
        )
    return [line for line in result.stdout.decode("utf-8").split("\n") if line]


class RefusedCharacterTests(unittest.TestCase):
    """Text Python would split, strip or match differently from git and Markdown is refused."""

    def test_refused_character_rule_matches_the_workflow_scan(self) -> None:
        # The governance job executes only the validator, so it carries its own copy of the
        # workflow scan's rule; every code point must agree for every whitespace set it uses.
        validator = load_validator()
        policy = load_validator_path(WORKFLOW_POLICY_PATH, "workflow_policy")
        for whitespace in (
            validator.TITLE_WHITESPACE,
            validator.STRUCTURAL_WHITESPACE,
            validator.PROSE_WHITESPACE,
        ):
            with self.subTest(whitespace=[hex(ord(character)) for character in whitespace]):
                disagreements = [
                    code
                    for code in range(0x110000)
                    if validator._refused_character(chr(code), whitespace)
                    != policy.refused_character(chr(code), whitespace)
                ]
                self.assertEqual(disagreements, [])
        self.assertEqual(validator.STRUCTURAL_WHITESPACE, " \t")
        self.assertFalse(validator._refused_character(" ", validator.TITLE_WHITESPACE))
        self.assertTrue(validator._refused_character("\t", validator.TITLE_WHITESPACE))
        self.assertTrue(validator._refused_character("\n", validator.PROSE_WHITESPACE))

    def test_prose_admits_exactly_the_unicode_space_separators(self) -> None:
        validator = load_validator()
        space_separators = {
            chr(code)
            for code in range(0x110000)
            if unicodedata.category(chr(code)) == "Zs"
        }

        self.assertEqual(set(validator.UNICODE_SPACE_SEPARATORS), space_separators - {" "})
        self.assertEqual(
            set(validator.PROSE_WHITESPACE), {" ", "\t"} | set(validator.UNICODE_SPACE_SEPARATORS)
        )

    def test_rejects_title_characters_that_split_or_hide_the_subject_line(self) -> None:
        # The audit's P6: each of these passed, so one PR title could be one commit subject to
        # git and two to Python's `splitlines()` (a `fix:` read as a `feat:` bump).
        validator = load_validator()
        for character in (
            "\u2028", "\u2029", "\x85", "\x0c", "\x0b", "\x1c", "\r", "\n", "\t", "\x00",
            "\x7f", "\u00a0", "\u3000", "\ufeff", "\u202e", "\u200f", "\u200b", "\u2060",
            "\u00ad", "\U000e0041",
        ):
            title = f"fix: repair parsing{character}feat: add thing"
            with self.subTest(codepoint=f"U+{ord(character):04X}"):
                errors = validator.validate_title(title)

                self.assertEqual(
                    errors, [validator.REFUSED_TITLE_DIAGNOSTIC.format(ord(character))]
                )
                self.assertFalse(any("repair parsing" in error for error in errors))

    def test_title_still_admits_spaces_and_visible_non_ascii(self) -> None:
        validator = load_validator()
        for title in (
            "fix: repair parsing feat: add thing",
            "fix(mail): keep caf\u00e9 names intact — safely",
        ):
            with self.subTest(title=title):
                self.assertEqual(validator.validate_title(title), [])

    def test_rejects_trailers_joined_by_a_python_only_line_break(self) -> None:
        # The audit's P1: the validator read two trailers where git reads one.
        validator = load_validator()
        for separator in PYTHON_ONLY_LINE_BREAKS:
            body = joined_trailers_body(separator)
            with self.subTest(codepoint=f"U+{ord(separator):04X}"):
                errors = validator.validate_body(body)

                self.assertEqual(
                    errors,
                    [
                        validator.REFUSED_BODY_DIAGNOSTIC.format(
                            line_number_of(body, REVIEWED_TRAILER), ord(separator)
                        )
                    ],
                )
                self.assertFalse(any("automated reviewer" in error for error in errors))

    def test_rejects_refused_characters_anywhere_in_the_body(self) -> None:
        validator = load_validator()
        prose = "Give callers deterministic pull-request feedback."
        for character in PYTHON_ONLY_LINE_BREAKS + (
            "\x1f", "\x00", "\x7f", "\x86", "\ufeff", "\ufffe", "\u202e", "\u200f",
            "\u061c", "\u2066",
        ):
            body = replaced(valid_body(), prose, f"Give callers{character}deterministic feedback.")
            with self.subTest(codepoint=f"U+{ord(character):04X}"):
                self.assertEqual(
                    validator.validate_body(body),
                    [
                        validator.REFUSED_BODY_DIAGNOSTIC.format(
                            line_number_of(body, "Give callers"), ord(character)
                        )
                    ],
                )

    def test_prose_admits_unicode_spaces_and_tabs(self) -> None:
        # A no-break space is what Option+Space types on macOS; outside headings and the
        # Checklist section it changes no reading, so prose keeps it.
        validator = load_validator()
        prose = "Give callers deterministic pull-request feedback."
        for replacement in (
            "Give callers 10\u00a0MB of deterministic feedback.",
            "Give callers\u2003deterministic\u3000feedback.",
            "Give callers\tdeterministic feedback.",
            # Only spaces and tabs before a `#` make a structural line; a no-break space is
            # not indentation to Markdown, so this line is prose and keeps its no-break space.
            "Give callers deterministic feedback.\n\n\u00a0# is prose, not a heading.",
        ):
            with self.subTest(replacement=ascii(replacement)):
                self.assertEqual(
                    validator.validate_body(replaced(valid_body(), prose, replacement)), []
                )

    def test_rejects_unicode_spaces_on_headings_checklist_lines_and_trailers(self) -> None:
        validator = load_validator()
        body = valid_body()
        item = template_checklist_items()[0]
        prose = "Give callers deterministic pull-request feedback."
        cases = {
            # The audit's P7: the item reads the same once Python strips it, but only space and
            # tab may surround a checklist item.
            "checklist item": (
                replaced(body, f"- [x] {item}", f"- [x]\u2003{item}\u00a0"), item, 0x2003,
            ),
            "heading-like line in prose": (
                replaced(body, prose, f"{prose}\n\n#\u00a0Note"), "#\u00a0Note", 0xA0,
            ),
            # A `#` after leading spaces or tabs still makes the line structural.
            "space-indented heading-like line in prose": (
                replaced(body, prose, f"{prose}\n\n ##\u00a0Note"), " ##\u00a0Note", 0xA0,
            ),
            "tab-indented heading-like line in prose": (
                replaced(body, prose, f"{prose}\n\n\t#\u2003Note"), "\t#\u2003Note", 0x2003,
            ),
            # Invisible format characters (category Cf) are refused on structural lines too.
            "zero-width space in a coauthor name": (
                replaced(body, "Co-Authored-By: ", "Co-Authored-By: \u200b"), "Co-Authored-By:", 0x200B,
            ),
            "zero-width joiner in a checklist item": (
                replaced(body, f"- [x] {item}", f"- [x] {item}\u200d"), item, 0x200D,
            ),
            "word joiner in a heading-like line": (
                replaced(body, prose, f"{prose}\n\n# Note\u2060"), "# Note\u2060", 0x2060,
            ),
            "middle trailer value": (
                replaced(body, "automated reviewer", "automated\u00a0reviewer"),
                "Reviewed-by:",
                0xA0,
            ),
            # The audit's P2c: git reads this last value with the no-break space kept.
            "last trailer value": (
                replaced(body, "example.com>\n", "example.com>\u00a0\n"), "Co-Authored-By:", 0xA0,
            ),
            # The audit's P2 and P2b: git's blank-line test is ASCII-only, so this paragraph is
            # not trailers to git.
            "no-break space line after the trailers": (body + "\u00a0\n", "\u00a0\n", 0xA0),
            "ideographic space line after the trailers": (body + "\u3000\n", "\u3000\n", 0x3000),
        }
        for name, (case_body, needle, code) in cases.items():
            with self.subTest(case=name):
                self.assertEqual(
                    validator.validate_body(case_body),
                    [
                        validator.REFUSED_STRUCTURAL_DIAGNOSTIC.format(
                            line_number_of(case_body, needle), code
                        )
                    ],
                )

    def test_rejects_a_lone_carriage_return_hiding_a_heading(self) -> None:
        # The audit's P4: Markdown ends a line at a lone carriage return, so GitHub renders a
        # fifth H2 the validator's line-feed regex never saw.
        validator = load_validator()
        body = replaced(
            valid_body(),
            "Give callers deterministic pull-request feedback.",
            "Give callers deterministic pull-request feedback.\r## Extra section\rMore text.",
        )

        self.assertEqual(
            validator.validate_body(body),
            [
                validator.REFUSED_BODY_DIAGNOSTIC.format(
                    line_number_of(body, "Give callers"), 0x0D
                )
            ],
        )

    def test_rejects_a_required_item_hidden_inside_an_unchecked_item(self) -> None:
        # The audit's P7c: to Markdown this is one unchecked task item; rejoining Python's
        # lines with line feeds made the required item look checked on its own line.
        validator = load_validator()
        item = template_checklist_items()[0]
        body = replaced(valid_body(), f"- [x] {item}", f"- [ ] pending\u2028- [x] {item}")

        self.assertEqual(
            validator.validate_body(body),
            [
                validator.REFUSED_BODY_DIAGNOSTIC.format(
                    line_number_of(body, "- [ ] pending"), 0x2028
                )
            ],
        )

    def test_accepts_crlf_line_endings(self) -> None:
        # The audit's P3: a CRLF body was refused because its headings read as `Rationale\r`.
        validator = load_validator()

        self.assertEqual(validator.validate_body(with_crlf_line_endings(valid_body())), [])
        self.assertEqual(
            validator.validate_metadata(
                "ci: validate pull request metadata", with_crlf_line_endings(valid_body())
            ),
            [],
        )

    def test_event_and_body_file_inputs_reach_the_same_verdict(self) -> None:
        # The audit's P3b: the body file was read with universal newlines and the event's JSON
        # was not, so one body passed through one path and failed through the other.
        title = "ci: validate pull request metadata"
        prose = "Give callers deterministic pull-request feedback."
        cases = {
            "crlf": (with_crlf_line_endings(valid_body()), 0),
            "lone carriage return in prose": (
                replaced(valid_body(), prose, "Give callers\rdeterministic pull-request feedback."),
                1,
            ),
            "lone carriage return hiding a heading": (
                replaced(valid_body(), prose, "Give callers.\r## Extra section\rMore text."),
                1,
            ),
            "trailers joined by a line separator": (joined_trailers_body("\u2028"), 1),
        }
        for name, (body, expected_returncode) in cases.items():
            with self.subTest(case=name):
                event, direct = run_both_input_paths(title, body)

                self.assertEqual(event.returncode, expected_returncode, event.stderr)
                self.assertEqual(
                    (direct.returncode, direct.stdout, direct.stderr),
                    (event.returncode, event.stdout, event.stderr),
                )
                if expected_returncode:
                    self.assertIn("is refused", event.stderr)
                    self.assertNotIn("Give callers", event.stderr)

    def test_terminal_trailers_split_at_line_feeds_only(self) -> None:
        # Direct reader tests: once the refusal runs first, a revert to `splitlines()` or a
        # bare `rstrip()` is invisible end to end, so the reader is pinned on its own.
        validator = load_validator()

        joined = validator._terminal_trailers(f"{REVIEWED_TRAILER}\u2028{COAUTHORED_TRAILER}\n")
        self.assertEqual([match.group("key") for match in joined], ["Reviewed-by"])
        self.assertIn("\u2028", joined[0].group("value"))
        self.assertEqual(
            validator._terminal_trailers(f"{REVIEWED_TRAILER}\n{COAUTHORED_TRAILER}\n\u00a0\n"),
            [],
        )
        self.assertEqual(
            [
                match.group("key")
                for match in validator._terminal_trailers(
                    f"{REVIEWED_TRAILER}\n{COAUTHORED_TRAILER}\n \t\n"
                )
            ],
            ["Reviewed-by", "Co-Authored-By"],
        )

    def test_checklist_trailer_removal_splits_at_line_feeds_only(self) -> None:
        validator = load_validator()
        section = (
            "\n\n- [ ] pending\u2028- [x] Required item.\n\n"
            f"{REVIEWED_TRAILER}\n{COAUTHORED_TRAILER}\n"
        )

        remaining = validator._without_terminal_lines(section, 2)

        self.assertEqual(remaining, "\n\n- [ ] pending\u2028- [x] Required item.\n")
        self.assertEqual(
            validator._without_terminal_lines(f"- [x] Item.\n\n{REVIEWED_TRAILER}\n\u00a0\n", 1),
            f"- [x] Item.\n\n{REVIEWED_TRAILER}",
        )


class TrailerParagraphTests(unittest.TestCase):
    def test_rejects_trailers_joined_to_the_checklist(self) -> None:
        # The audit's P5: git reads trailers only from the final paragraph, so with no empty
        # line before them it reads none.
        validator = load_validator()
        body = replaced(valid_body(), f"\n\n{REVIEWED_TRAILER}", f"\n{REVIEWED_TRAILER}")

        self.assertEqual(
            validator.validate_body(body),
            ["body trailers must follow an empty line, as a paragraph of their own"],
        )

    def test_paragraph_check_reads_lines_and_blanks_as_git_does(self) -> None:
        # Direct: a line separator does not end a line for git, so the empty line still
        # precedes this one-trailer block; a no-break-space line is not blank to git.
        validator = load_validator()

        self.assertTrue(
            validator._trailers_follow_an_empty_line(
                f"- [x] Item.\n\n{REVIEWED_TRAILER}\u2028{COAUTHORED_TRAILER}\n", 1
            )
        )
        self.assertFalse(
            validator._trailers_follow_an_empty_line(f"- [x] Item.\n{REVIEWED_TRAILER}\n", 1)
        )
        self.assertFalse(
            validator._trailers_follow_an_empty_line(
                f"- [x] Item.\n\u00a0\n{REVIEWED_TRAILER}\n", 1
            )
        )

    def test_accepts_a_blank_line_holding_spaces_or_tabs(self) -> None:
        validator = load_validator()
        body = replaced(valid_body(), f"\n\n{REVIEWED_TRAILER}", f"\n \t\n{REVIEWED_TRAILER}")

        self.assertEqual(validator.validate_body(body), [])

    def test_filled_pull_request_template_passes(self) -> None:
        validator = load_validator()

        self.assertEqual(validator.validate_body(template_filled_body()), [])

    def test_filled_template_with_trailers_joined_to_its_closing_comment_fails(self) -> None:
        validator = load_validator()

        self.assertEqual(
            validator.validate_body(template_filled_body(before_trailers="")),
            ["body trailers must follow an empty line, as a paragraph of their own"],
        )

    @unittest.skipIf(shutil.which("git") is None, "git is not installed")
    def test_accepted_bodies_carry_exactly_the_trailers_git_reads(self) -> None:
        # Oracle: whenever the validator accepts a body, the squash commit's trailers as git
        # reads them are exactly the trailers the validator checked.
        validator = load_validator()
        item = template_checklist_items()[0]
        corpus = {
            "valid": valid_body(),
            "valid with CRLF line endings": with_crlf_line_endings(valid_body()),
            "blank line of spaces and a tab": replaced(
                valid_body(), f"\n\n{REVIEWED_TRAILER}", f"\n \t\n{REVIEWED_TRAILER}"
            ),
            "conventional trailer first": replaced(
                valid_body(),
                REVIEWED_TRAILER,
                f"BREAKING-CHANGE: callers use the new field.\n{REVIEWED_TRAILER}",
            ),
            "two coauthors": replaced(
                valid_body(),
                COAUTHORED_TRAILER,
                f"{COAUTHORED_TRAILER}\nCo-Authored-By: Second Automation <second@example.org>",
            ),
            "trailing spaces on a middle trailer": replaced(
                valid_body(), REVIEWED_TRAILER, f"{REVIEWED_TRAILER}  "
            ),
            "filled template": template_filled_body(),
            "thematic break in the Testing section": replaced(
                valid_body(), "\n\n## Checklist", "\n\n---\n\n## Checklist"
            ),
            "filled template, trailers joined to its comment": template_filled_body(""),
            "trailers joined to the checklist": replaced(
                valid_body(), f"\n\n{REVIEWED_TRAILER}", f"\n{REVIEWED_TRAILER}"
            ),
            "no-break space line after the trailers": valid_body() + "\u00a0\n",
            "ideographic space line after the trailers": valid_body() + "\u3000\n",
            "no-break space after the last trailer": replaced(
                valid_body(), "example.com>\n", "example.com>\u00a0\n"
            ),
            "required item inside an unchecked item": replaced(
                valid_body(), f"- [x] {item}", f"- [ ] pending\u2028- [x] {item}"
            ),
        }
        for separator in PYTHON_ONLY_LINE_BREAKS:
            corpus[f"trailers joined by U+{ord(separator):04X}"] = joined_trailers_body(separator)

        accepted = []
        for name, body in corpus.items():
            if validator.validate_body(body):
                continue
            accepted.append(name)
            with self.subTest(case=name):
                expected = []
                for match in validator._terminal_trailers(body.replace("\r\n", "\n")):
                    value = match.group("value").rstrip(" \t")
                    expected.append(f"{match.group('key')}: {value}")
                self.assertEqual(git_trailer_lines(body), expected)

        self.assertEqual(
            accepted,
            [
                "valid",
                "valid with CRLF line endings",
                "blank line of spaces and a tab",
                "conventional trailer first",
                "two coauthors",
                "trailing spaces on a middle trailer",
                "filled template",
                "thematic break in the Testing section",
            ],
        )


if __name__ == "__main__":
    unittest.main()
