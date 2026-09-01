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
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
AGENTS_PATH = REPO_ROOT / "AGENTS.md"
TEMPLATE_PATH = REPO_ROOT / ".github" / "PULL_REQUEST_TEMPLATE.md"
CI_WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "ci.yml"
PR_METADATA_WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "pr-metadata.yml"
LEGACY_GOVERNANCE_WORKFLOW_PATH = (
    REPO_ROOT / ".github" / "workflows" / "governance.yml"
)
VALIDATOR_PATH = REPO_ROOT / "scripts" / "ci" / "pr_metadata.py"
CHECKOUT_SHA = "3d3c42e5aac5ba805825da76410c181273ba90b1"


def load_validator_path(path: Path, module_name: str = "pr_metadata") -> ModuleType:
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load PR metadata validator")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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
            PR_METADATA_WORKFLOW_PATH.is_file(),
            "dedicated PR metadata workflow must exist",
        )
        self.assertFalse(LEGACY_GOVERNANCE_WORKFLOW_PATH.exists())
        workflow = PR_METADATA_WORKFLOW_PATH.read_text(encoding="utf-8")
        match = re.search(
            r"^  required:\n(?P<job>.*?)(?=^  [a-z0-9-]+:\n|\Z)",
            workflow,
            flags=re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(match, "PR metadata job must exist")
        job = match.group("job")

        self.assertIn("name: metadata / required", job)
        self.assertRegex(
            job,
            rf"(?m)^\s+- uses: actions/checkout@{CHECKOUT_SHA} +# v7\.0\.1$",
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
        self.assertRegex(
            workflow,
            r"(?m)^permissions:\n  contents: read$",
        )
        consumers = sorted(
            path.name
            for path in (REPO_ROOT / ".github" / "workflows").glob("*.yml")
            if re.search(
                r"(?m)^\s{2}pull_request_target:\s*$",
                path.read_text(encoding="utf-8"),
            )
        )
        self.assertEqual(consumers, ["pr-metadata.yml"])

    def test_pr_head_ci_cannot_duplicate_the_metadata_check(self) -> None:
        workflow = CI_WORKFLOW_PATH.read_text(encoding="utf-8")

        self.assertNotIn("metadata / required", workflow)
        self.assertNotIn("governance / required", workflow)
        self.assertNotIn("scripts/ci/pr_metadata.py", workflow)
        self.assertNotIn("pr-title-lint:", workflow)
        self.assertNotIn("pull_request_target:", workflow)

    def test_metadata_job_does_not_claim_future_governance_enforcement(self) -> None:
        self.assertTrue(PR_METADATA_WORKFLOW_PATH.is_file())
        workflow = PR_METADATA_WORKFLOW_PATH.read_text(encoding="utf-8")

        self.assertNotIn("governance / required", workflow)
        self.assertNotIn("control-plane", workflow)

    def test_repository_instructions_define_only_the_metadata_exception(self) -> None:
        self.assertTrue(PR_METADATA_WORKFLOW_PATH.is_file())
        instructions = " ".join(AGENTS_PATH.read_text(encoding="utf-8").split())
        metadata_workflow = PR_METADATA_WORKFLOW_PATH.read_text(encoding="utf-8")
        check_name_match = re.search(
            r"(?m)^\s+name: (metadata / required)$",
            metadata_workflow,
        )
        self.assertIsNotNone(check_name_match)
        check_name = check_name_match.group(1)

        self.assertIn(f"`{check_name}`", instructions)
        for required_policy in (
            "ordinary build/test stays on `pull_request` with a read-only token and no secrets",
            "sole current `pull_request_target` exception",
            "base-owned workflow checks out and executes only the base-owned metadata validator",
            "`contents: read`, no secrets, and PR title/body inspection only",
            "never checkout, execute, download, or cache PR code or artifacts",
            "No other `pull_request_target` use is permitted",
            "not a substitute for the later `governance / required` control-plane gate",
            "must not be used as one before that gate lands",
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


if __name__ == "__main__":
    unittest.main()
