"""Tests for scripts/ci/workflow_policy.py — the parsed-YAML read-only workflow scan."""
from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "ci" / "workflow_policy.py"
CHECKOUT = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1"


def load_module():
    spec = importlib.util.spec_from_file_location("workflow_policy", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


policy = load_module()


QUALITY = textwrap.dedent(
    f"""\
    name: CI
    on:
      push:
        branches: [main]
      pull_request:
        types: [opened, edited, synchronize, reopened]
    permissions:
      contents: read
    jobs:
      build:
        runs-on: ubuntu-latest
        permissions:
          contents: read
        steps:
          - uses: {CHECKOUT}
            with:
              persist-credentials: false
          - name: Build
            run: |
              set -euo pipefail
              echo "building"  # a comment inside a block scalar is text
      quality-required:
        name: quality / required
        runs-on: ubuntu-latest
        permissions:
          contents: read
        if: always()
        needs: [build]
        steps:
          - run: test "${{{{ needs.build.result }}}}" = success
    """
)

METADATA = textwrap.dedent(
    f"""\
    name: PR Metadata
    on:
      pull_request_target:
        types: [opened, edited, reopened, synchronize, ready_for_review]
    permissions:
      contents: read
    jobs:
      required:
        name: metadata / required
        runs-on: ubuntu-latest
        permissions:
          contents: read
        steps:
          - uses: {CHECKOUT}
            with:
              ref: ${{{{ github.event.pull_request.base.sha }}}}
              persist-credentials: false
          - run: python3 scripts/ci/pr_metadata.py --event "$GITHUB_EVENT_PATH"
    """
)


def write_tree(root: Path, files: dict) -> None:
    for name, body in files.items():
        path = root / ".github" / "workflows" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")


class ParserTests(unittest.TestCase):
    def test_parses_the_repository_shapes(self) -> None:
        document = policy.parse_workflow(QUALITY)
        self.assertEqual(policy._normalize_triggers(document["on"]),
                         {"push": {"branches": ["main"]},
                          "pull_request": {"types": ["opened", "edited", "synchronize", "reopened"]}})
        job = document["jobs"]["build"]
        self.assertEqual(job["steps"][0]["with"]["persist-credentials"], False)
        self.assertIn('echo "building"  # a comment inside a block scalar is text', job["steps"][1]["run"])
        self.assertEqual(document["jobs"]["quality-required"]["needs"], ["build"])
        self.assertEqual(document["jobs"]["quality-required"]["if"], "always()")

    def test_apostrophe_in_plain_scalar_and_trailing_comment(self) -> None:
        document = policy.parse_workflow(
            "name: the manual's source # trailing\non: push\npermissions: read-all\njobs:\n"
            "  a:\n    runs-on: ubuntu-latest\n    permissions: read-all\n    steps:\n      - run: echo hi\n"
        )
        self.assertEqual(document["name"], "the manual's source")

    def test_refuses_structures_outside_the_subset(self) -> None:
        for body in (
            "name: x\non: push\njobs: &a\n  b: *a\n",
            "name: x\non: push\njobs: {a: b}\n",
            "---\nname: x\n",
            "name: x\non: [push, {a: b}]\n",
            "name: x\non: push\njobs:\n  a:\n    steps:\n      - - nested\n",
            "name: x\nname: y\n",
            "name: x\n\ton: push\n",
        ):
            with self.subTest(body=body):
                with self.assertRaises(policy.ParseError):
                    policy.parse_workflow(body)

    def test_double_quoted_escapes_are_decoded_or_refused(self) -> None:
        self.assertEqual(policy._scalar('"a\\u0063b\\x41\\tc\\"d"'), 'acbA\tc"d')
        for bad in ('"\\q"', '"\\u12"', '"trailing\\"', '"\\x4"'):
            with self.subTest(bad=bad):
                with self.assertRaises(policy.ParseError):
                    policy._scalar(bad)

    def test_quoted_mapping_keys_are_decoded(self) -> None:
        document = policy.parse_workflow('on: push\n"environm\\u0065nt": prod\n')
        self.assertEqual(document["environment"], "prod")
        with self.assertRaises(policy.ParseError):
            policy.parse_workflow('"a": 1\n"\\u0061": 2\n')

    def test_bracket_index_normalisation(self) -> None:
        self.assertEqual(policy._normalize_expression("secrets['A_B']"), "secrets.A_B")
        self.assertEqual(policy._normalize_expression('github["token"]'), "github.token")
        self.assertEqual(policy._normalize_expression("github.event.pull_request['head']['sha']"),
                         "github.event.pull_request.head.sha")

    def test_block_scalar_keeps_leading_and_trailing_comment_rows(self) -> None:
        document = policy.parse_workflow(
            "on: push\npermissions: read-all\njobs:\n  a:\n    runs-on: ubuntu-latest\n    permissions: read-all\n"
            "    steps:\n      - run: |\n          # leading\n          echo hi\n          # trailing\n      - run: second\n"
        )
        self.assertEqual(document["jobs"]["a"]["steps"][0]["run"], "# leading\necho hi\n# trailing")
        self.assertEqual(document["jobs"]["a"]["steps"][1]["run"], "second")

    def test_same_indent_sequence_may_be_followed_by_sibling_keys(self) -> None:
        document = policy.parse_workflow("on:\n- push\n- pull_request\npermissions: read-all\njobs:\n  a:\n    runs-on: ubuntu-latest\n    permissions: read-all\n    steps:\n    - run: echo hi\n")
        self.assertEqual(document["on"], ["push", "pull_request"])
        self.assertEqual(document["permissions"], "read-all")
        self.assertEqual(document["jobs"]["a"]["steps"], [{"run": "echo hi"}])

    def test_block_scalar_keeps_blank_lines_and_indentation(self) -> None:
        document = policy.parse_workflow(
            "on: push\npermissions: read-all\njobs:\n  a:\n    runs-on: ubuntu-latest\n    permissions: read-all\n"
            "    steps:\n      - run: |\n          first\n\n            indented\n      - run: second\n"
        )
        self.assertEqual(document["jobs"]["a"]["steps"][0]["run"], "first\n\n  indented")
        self.assertEqual(document["jobs"]["a"]["steps"][1]["run"], "second")


JOB_HEADER = "    runs-on: ubuntu-latest\n    permissions:\n      contents: read\n    steps:"
CHECKOUT_STEP = "      - uses: " + CHECKOUT + "\n        with:\n          persist-credentials: false\n"


def mutate(source: str, old: str, new: str) -> str:
    """Replace exactly one occurrence, refusing a silent no-op (a fixture typo must not pass as a scan pass)."""
    if source.count(old) != 1:
        raise AssertionError("fixture fragment not found exactly once: {!r}".format(old))
    return source.replace(old, new, 1)


class ScanTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def scan(self, files: dict) -> list:
        write_tree(self.root, files)
        return policy.scan_repository(self.root)

    def scan_ci(self, ci_body: str) -> list:
        return self.scan({"ci.yml": ci_body, "pr-metadata.yml": METADATA})

    def assert_ci_violation(self, ci_body: str, needle: str) -> None:
        violations = self.scan_ci(ci_body)
        self.assertTrue(any(needle in v for v in violations), violations)

    def test_conforming_tree_passes(self) -> None:
        self.assertEqual(self.scan({"ci.yml": QUALITY, "pr-metadata.yml": METADATA}), [])

    def test_missing_job_permissions_fails(self) -> None:
        body = mutate(QUALITY, JOB_HEADER, "    runs-on: ubuntu-latest\n    steps:")
        self.assert_ci_violation(body, "job `build`: no explicit `permissions` block")

    def test_missing_workflow_permissions_fails(self) -> None:
        body = mutate(QUALITY, "permissions:\n  contents: read\njobs:", "jobs:")
        self.assert_ci_violation(body, "workflow: no explicit `permissions` block")

    def test_write_permissions_fail(self) -> None:
        for bad in ("contents: write", "id-token: read", "pages: read", "packages: none"):
            body = mutate(QUALITY, JOB_HEADER, "    runs-on: ubuntu-latest\n    permissions:\n      {}\n    steps:".format(bad))
            with self.subTest(bad=bad):
                self.assert_ci_violation(body, "job `build`: permission")
        body = mutate(QUALITY, "permissions:\n  contents: read\njobs:", "permissions: write-all\njobs:")
        self.assert_ci_violation(body, "is not read-only")

    def test_forbidden_triggers_fail(self) -> None:
        for trigger in ("workflow_run", "workflow_dispatch", "repository_dispatch", "release", "deployment"):
            body = mutate(QUALITY, "on:\n  push:", "on:\n  {}:\n  push:".format(trigger))
            with self.subTest(trigger=trigger):
                self.assert_ci_violation(body, "trigger `{}` is forbidden".format(trigger))

    def test_environment_anywhere_fails(self) -> None:
        body = mutate(QUALITY, JOB_HEADER, "    runs-on: ubuntu-latest\n    environment: github-pages\n    permissions:\n      contents: read\n    steps:")
        self.assert_ci_violation(body, "`environment` is forbidden")

    def test_secrets_context_in_any_expression_fails(self) -> None:
        for old, new in (
            ("      - name: Build\n", "      - name: Build\n        env:\n          T: ${{ secrets.TOKEN }}\n"),
            ("        run: |\n", "        if: ${{ secrets.FLAG == 'x' }}\n        run: |\n"),
            ('          echo "building"', "          echo ${{ secrets.TOKEN }}"),
        ):
            body = mutate(QUALITY, old, new)
            with self.subTest(where=new):
                self.assert_ci_violation(body, "references the `secrets.` context")
        body = mutate(QUALITY, "  build:\n", "  build:\n    secrets: inherit\n")
        self.assert_ci_violation(body, "`secrets` mapping or `secrets: inherit` is forbidden")
        body = mutate(QUALITY, "  build:\n", '  build:\n    "s\\u0065crets": inherit\n')
        self.assert_ci_violation(body, "`secrets` mapping or `secrets: inherit` is forbidden")
        body = mutate(QUALITY, JOB_HEADER, '    runs-on: ubuntu-latest\n    "environm\\u0065nt": prod\n    permissions:\n      contents: read\n    steps:')
        self.assert_ci_violation(body, "`environment` is forbidden")

    def test_obfuscated_secret_references_fail(self) -> None:
        for old, new in (
            ('          echo "building"', "          echo ${{ secrets['TOKEN'] }}"),
            ('          echo "building"', "          echo ${{ secrets . TOKEN }}"),
            ("      - name: Build\n", '      - name: Build\n        env:\n          T: "${{ se\\u0063rets.TOKEN }}"\n'),
            ('          echo "building"', "          echo ${{ toJSON(secrets) }}"),
            ("        run: |\n", "        if: secrets.FLAG == 'x'\n        run: |\n"),
            ("      - name: Build\n", "      - name: Build\n        env:\n          \"${{ secrets.X }}\": y\n"),
        ):
            body = mutate(QUALITY, old, new)
            with self.subTest(new=new):
                self.assert_ci_violation(body, "references the `secrets.` context")
        body = mutate(QUALITY, "      - name: Build\n", '      - name: Build\n        env:\n          T: "\\q"\n')
        self.assert_ci_violation(body, "refused")

    def test_case_variants_and_literal_closers_fail(self) -> None:
        for command in ("echo ${{ SECRETS.MY_TOKEN }}", "echo ${{ GitHub.Token }}",
                        'echo "${{ format(\'}}\', secrets.MY_TOKEN) }}"'):
            body = mutate(QUALITY, 'echo "building"', command)
            with self.subTest(command=command):
                self.assertTrue(self.scan_ci(body), command)
        for command in ("curl $(echo -X POST) https://api.github.com/repos/o/r/git/refs",
                        "curl `echo -X POST` https://api.github.com/repos/o/r/git/refs",
                        'gh api repos/o/r/releases $(printf -- "-f") tag_name=v1'):
            body = mutate(QUALITY, 'echo "building"', command)
            with self.subTest(command=command):
                self.assert_ci_violation(body, "run script contains a")
        body = mutate(QUALITY, "    name: quality / required\n", "    name: quality / required\n    strategy:\n      matrix:\n        os: [ubuntu-latest]\n")
        self.assert_ci_violation(body, "may not carry a `strategy`")

    def test_prose_mentioning_secrets_is_not_a_reference(self) -> None:
        body = mutate(QUALITY, 'echo "building"', "echo 'this job receives no secrets'")
        self.assertEqual(self.scan_ci(body), [])

    def test_github_token_reference_fails(self) -> None:
        for expression in ("${{ github.token }}", "${{ github['token'] }}", "${{ toJSON(github.token) }}", "${{ github . token }}", "${{ github [ 'token' ] }}"):
            body = mutate(QUALITY, 'echo "building"', "echo " + expression)
            with self.subTest(expression=expression):
                self.assert_ci_violation(body, "references `github.token`")

    def test_runner_labels_are_policed(self) -> None:
        for label in ("self-hosted", "macos-latest", "[self-hosted, macOS]", "${{ matrix.os }}", "production-runner", "ubuntu-latest-8-cores"):
            body = mutate(QUALITY, JOB_HEADER, JOB_HEADER.replace("ubuntu-latest", label))
            with self.subTest(label=label):
                self.assert_ci_violation(body, "job `build`: `runs-on")

    def test_checkout_must_disable_persisted_credentials_explicitly(self) -> None:
        for replacement in ("      - uses: " + CHECKOUT + "\n        with:\n          fetch-depth: 0\n",
                            "      - uses: " + CHECKOUT + "\n"):
            body = mutate(QUALITY, CHECKOUT_STEP, replacement)
            with self.subTest(replacement=replacement):
                self.assert_ci_violation(body, "persist-credentials: false")

    def test_publish_actions_and_write_commands_fail(self) -> None:
        for uses in ("actions/deploy-pages@0000000000000000000000000000000000000000",
                     "softprops/action-gh-release@0000000000000000000000000000000000000000",
                     "actions/attest-build-provenance@0000000000000000000000000000000000000000",
                     "stefanzweifel/git-auto-commit-action@0000000000000000000000000000000000000000",
                     "someone/deploy-anything@0000000000000000000000000000000000000000",
                     "someone/publish-to-pages@0000000000000000000000000000000000000000"):
            body = mutate(QUALITY, CHECKOUT_STEP, "      - uses: {}\n".format(uses) + CHECKOUT_STEP)
            with self.subTest(uses=uses):
                self.assert_ci_violation(body, "publish, deploy or write path")
        for command in ("git push origin main", "git -C /tmp/x tag v1", "gh release create v1", "gh pr merge 1",
                        "gh workflow run x.yml", "gh api -X POST repos/o/r/releases",
                        "curl -X PATCH https://api.github.com/repos/o/r",
                        "/usr/bin/git push origin main", "git -c user.name=x -C . commit -m x",
                        "git --no-pager push", "curl https://api.github.com/repos/o/r/releases -X POST",
                        "curl -d '{}' https://api.github.com/repos/o/r/issues",
                        "curl --data-binary @f https://api.github.com/repos/o/r/releases/1/assets",
                        "curl -T asset.tgz https://api.github.com/uploads/x", "gh api repos/o/r/issues -f title=x",
                        "gh api --method=DELETE repos/o/r/git/refs/tags/v1", "git update-ref refs/heads/main HEAD",
                        "git \\\n            push origin main", "git --git-dir .git push", "curl -XPOST https://api.github.com/x",
                        "curl -d'{}' https://api.github.com/x", "gh -R o/r release create v1",
                        "gh api repos/o/r/issues \\\n            -f title=x",
                        'git -c user.name="CI Bot" push origin main', "curl -sSXPOST https://api.github.com/x",
                        '"git" push origin main', "g\\it pu\\sh origin main", 'gh api "--method" DELETE repos/o/r/git/refs/tags/v1', "curl '--request' DELETE https://api.github.com/x",
                        "curl --form-string a=b https://api.github.com/x", "docker buildx build --push -t x ."):
            body = mutate(QUALITY, 'echo "building"', command)
            with self.subTest(command=command):
                self.assert_ci_violation(body, "run script contains a")

    def test_checkout_credential_options_fail_everywhere(self) -> None:
        for option in ("token: ${{ github.token }}", "ssh-key: x", "github-server-url: https://example.com"):
            body = mutate(QUALITY, "          persist-credentials: false\n", "          persist-credentials: false\n          " + option + "\n")
            with self.subTest(option=option):
                self.assert_ci_violation(body, "checkout option `" + option.split(":")[0] + "` is forbidden")

    def test_more_publish_paths_fail(self) -> None:
        for command in ("npm publish", "cargo publish", "twine upload dist/*", "docker push ghcr.io/x/y",
                        "aws s3 cp a s3://b", 'curl -X POST -T a.tgz "https://uploads.github.com/repos/o/r/releases/1/assets?name=a"',
                        'curl -X POST "$GITHUB_API_URL/repos/o/r/git/refs" -d @body', "gh run download 1"):
            body = mutate(QUALITY, 'echo "building"', command)
            with self.subTest(command=command):
                self.assert_ci_violation(body, "run script contains a")

    def test_action_forms_outside_the_scan_are_refused(self) -> None:
        for uses in ("./.github/actions/local-publisher", "docker://alpine:3", "actions/checkout@v4",
                     "Peter-Evans/Create-Pull-Request@0000000000000000000000000000000000000000"):
            body = mutate(QUALITY, CHECKOUT_STEP, "      - uses: {}\n".format(uses) + CHECKOUT_STEP)
            with self.subTest(uses=uses):
                self.assertTrue(any("job `build` step 1" in v for v in self.scan_ci(body)), uses)
        body = mutate(QUALITY, CHECKOUT_STEP,
                      "      - uses: actions/github-script@0000000000000000000000000000000000000000\n        with:\n"
                      "          script: await github.rest.repos.createRelease({tag_name:'v9'})\n" + CHECKOUT_STEP)
        self.assert_ci_violation(body, "github-script body contains a write call")
        body = mutate(QUALITY, CHECKOUT_STEP,
                      "      - uses: actions/github-script@0000000000000000000000000000000000000000\n        with:\n"
                      "          script: core.setOutput('b', (await github.rest.repos.get(context.repo)).data.default_branch)\n" + CHECKOUT_STEP)
        self.assertEqual(self.scan_ci(body), [])

    def test_interpreter_swaps_and_non_string_run_fail(self) -> None:
        body = mutate(QUALITY, "        run: |\n", "        shell: python\n        run: |\n")
        self.assert_ci_violation(body, "is not an admitted interpreter")
        body = mutate(QUALITY, "permissions:\n  contents: read\njobs:", "permissions:\n  contents: read\ndefaults:\n  run:\n    shell: python\njobs:")
        self.assert_ci_violation(body, "`defaults.run.shell: python`")
        body = mutate(QUALITY, "  build:\n", "  build:\n    defaults:\n      run:\n        shell: bash -e {0} && git push\n")
        self.assert_ci_violation(body, "is not an admitted interpreter")
        body = mutate(QUALITY, "        run: |\n          set -euo pipefail\n          echo \"building\"  # a comment inside a block scalar is text", "        run: [git, push]")
        self.assert_ci_violation(body, "`run` must be a string scalar")
        body = mutate(QUALITY, "        run: |\n", "        shell: bash\n        run: |\n")
        self.assertEqual(self.scan_ci(body), [])

    def test_container_services_and_boolean_alias_roots_fail(self) -> None:
        body = mutate(QUALITY, JOB_HEADER, "    container: evil/image:latest\n" + JOB_HEADER)
        self.assert_ci_violation(body, "`container` is not admitted")
        body = mutate(QUALITY, JOB_HEADER, "    services:\n      db:\n        image: attacker/pg\n" + JOB_HEADER)
        self.assert_ci_violation(body, "`services` is not admitted")
        body = mutate(QUALITY, "permissions:\n  contents: read\njobs:", "true:\n  workflow_dispatch:\npermissions:\n  contents: read\njobs:")
        self.assert_ci_violation(body, "root key `true` is a YAML 1.1 boolean alias")

    def test_permissions_empty_mapping_and_single_label_list_are_accepted(self) -> None:
        body = mutate(QUALITY, JOB_HEADER, "    runs-on: [ubuntu-latest]\n    permissions: {}\n    steps:")
        self.assertEqual(self.scan_ci(body), [])
        body = mutate(QUALITY, "    steps:\n      - uses: " + CHECKOUT, "    steps:\n    - uses: " + CHECKOUT)
        body = body.replace("        with:\n          persist-credentials: false\n      - name: Build\n        run: |\n          set -euo pipefail\n          echo \"building\"  # a comment inside a block scalar is text",
                            "      with:\n        persist-credentials: false\n    - name: Build\n      run: |\n        set -euo pipefail\n        echo \"building\"  # a comment inside a block scalar is text")
        self.assertEqual(self.scan_ci(body), [])

    def test_run_command_patterns_are_linear_on_option_floods(self) -> None:
        import time
        floods = ["git " + "-c a=b " * 300 + "status", "git " + "-c " * 400, "git -c " + '"' * 600 + " x",
                  "curl " + "-d " * 400 + "https://api.github.com/x", "gh " + "-R o/r " * 400 + "api x",
                  "git " + "--no-pager " * 400 + "log", "git " + "-c a='b c' " * 300 + "push"]
        started = time.perf_counter()
        for flood in floods:
            for _label, pattern in policy.FORBIDDEN_RUN_RES:
                pattern.search(flood)
        self.assertLess(time.perf_counter() - started, 5.0, "a write-command pattern backtracks super-linearly")

    def test_read_only_git_and_gh_are_allowed(self) -> None:
        body = mutate(QUALITY, 'echo "building"', "git status && gh api repos/o/r && git describe --tags && curl -f -sS https://api.github.com/repos/o/r")
        self.assertEqual(self.scan_ci(body), [])
        body = mutate(QUALITY, 'echo "building"', "LATEST=$(git tag --list 'v*' --sort=-v:refname | head -1) && git notes show HEAD && git tag -l")
        self.assertEqual(self.scan_ci(body), [])
        body = mutate(QUALITY, 'echo "building"', "cat config/secrets.json && echo done")
        self.assertEqual(self.scan_ci(body), [])
        body = mutate(QUALITY, CHECKOUT_STEP, CHECKOUT_STEP + "      - uses: someone/tool@0000000000000000000000000000000000000000\n        with:\n          environment: staging\n")
        self.assertEqual(self.scan_ci(body), [])
        body = mutate(QUALITY, 'echo "building"', "git log --format=%s origin/main..HEAD  # check every commit header\n          curl -d x https://example.com/")
        self.assertEqual(self.scan_ci(body), [])
        body = mutate(QUALITY, CHECKOUT_STEP, "      - uses: wagoid/commitlint-github-action@0000000000000000000000000000000000000000\n" + CHECKOUT_STEP)
        self.assertEqual(self.scan_ci(body), [])

    def test_duplicate_check_names_across_workflows_fail(self) -> None:
        other = QUALITY.replace("name: CI", "name: Other").replace("  build:", "  build2:").replace("needs: [build]", "needs: [build2]")
        violations = self.scan({"ci.yml": QUALITY, "other.yml": other, "pr-metadata.yml": METADATA})
        self.assertTrue(any("check `quality / required` is also produced by" in v for v in violations), violations)

    def test_duplicate_check_names_within_one_workflow_fail(self) -> None:
        body = mutate(QUALITY, "  build:\n    runs-on", "  build:\n    name: quality / required\n    runs-on")
        self.assert_ci_violation(body, "check `quality / required` is also produced by job")

    def test_recorded_trigger_set_drift_fails(self) -> None:
        body = mutate(QUALITY, "types: [opened, edited, synchronize, reopened]", "types: [opened, synchronize, reopened]")
        self.assert_ci_violation(body, "trigger set differs from the recorded")
        body = mutate(QUALITY, "branches: [main]", "branches: [main, release/*]")
        self.assert_ci_violation(body, "trigger set differs from the recorded")

    def test_recorded_trigger_set_is_order_insensitive(self) -> None:
        body = mutate(QUALITY, "types: [opened, edited, synchronize, reopened]", "types: [reopened, synchronize, edited, opened]")
        self.assertEqual(self.scan_ci(body), [])

    def test_missing_recorded_check_fails(self) -> None:
        body = mutate(QUALITY, "    name: quality / required\n", "")
        self.assert_ci_violation(body, "recorded required check `quality / required` is produced by no workflow")

    def test_exactly_one_pull_request_target_workflow(self) -> None:
        violations = self.scan({"ci.yml": QUALITY})
        self.assertTrue(any("exactly one pull_request_target workflow is required; found 0" in v for v in violations), violations)
        second = METADATA.replace("name: PR Metadata", "name: Second").replace("metadata / required", "second / required")
        violations = self.scan({"ci.yml": QUALITY, "pr-metadata.yml": METADATA, "second.yml": second})
        self.assertTrue(any("exactly one pull_request_target workflow is required; found 2" in v for v in violations), violations)

    def test_pull_request_target_may_not_touch_the_proposal_head(self) -> None:
        base_ref = "ref: ${{ github.event.pull_request.base.sha }}"
        for old, new in (
            (base_ref, "ref: ${{ github.event.pull_request.head.sha }}"),
            (base_ref, "ref: refs/pull/1/merge"),
            (base_ref, "ref: ${{ github.event.pull_request['head']['sha'] }}"),
            ("      - run: python3", "      - run: git fetch origin pull/1/head && git checkout FETCH_HEAD\n      - run: python3"),
            ("      - run: python3", "      - run: gh pr checkout 1\n      - run: python3"),
            ("      - run: python3", "      - run: echo ${{ github.event.pull_request.HEAD.SHA }}\n      - run: python3"),
            ("      - run: python3", "      - run: curl -sSL ${{ github.event.pull_request.diff_url }}\n      - run: python3"),
            ("      - run: python3", "      - run: echo ${{ github.event.pull_request.merge_commit_sha }}\n      - run: python3"),
            ("      - run: python3", "      - run: git fetch origin pull/${{ github.event.number }}/head\n      - run: python3"),
            ("      - run: python3", "      - run: gh pr -R o/r checkout 1\n      - run: python3"),
            ("      - run: python3", "      - run: gh pr --repo=o/r checkout 1\n      - run: python3"),
            ("      - run: python3", "      - run: echo '${{ toJSON(github.event.pull_request) }}' > pr.json\n      - run: python3"),
            ("      - run: python3", "      - run: echo '${{ toJSON(github.event) }}' > ev.json\n      - run: python3"),
            ("      - run: python3", "      - run: echo '${{ toJSON(github) }}' > gh.json\n      - run: python3"),
            ("      - run: python3", "      - run: echo '${{ toJSON(github.*) }}' > gh.json\n      - run: python3"),
            ("      - run: python3", "      - run: echo '${{ toJSON(github.event.*) }}' > gh.json\n      - run: python3"),
            ("      - run: python3", "      - run: gh \"pr\" checkout 1\n      - run: python3"),
            ("      - run: python3", "      - run: gh p\\r checkout 1\n      - run: python3"),
            ("      - run: python3", "      - run: git fetch origin p\\ull/1/head\n      - run: python3"),
            ("      - run: python3", "      - run: |\n          git fetch origin pu\\\n          ll/1/head\n      - run: python3"),
            ("      - run: python3", "      - run: |\n          gh pr \\\n            checkout 1\n      - run: python3"),
            ("      - run: python3", "      - run: curl -sSL https://example.com/o/r/pull/1/files\n      - run: python3"),
            ("      - run: python3", "      - run: curl -sSL https://example.com/o/r/pull/1.diff\n      - run: python3"),
            ("    name: metadata / required\n", "    name: ${{ 'metadata / required' }}\n"),
            ("      - run: python3", "      - run: curl -sSL https://api.github.com/repos/o/r/actions/artifacts/1/zip -o a.zip\n      - run: python3"),
            ("      - run: python3", "      - run: git clone ${{ github.event.pull_request.head.repo.clone_url }} x\n      - run: python3"),
            ("- uses: " + CHECKOUT + "\n        with:\n          " + base_ref + "\n          persist-credentials: false\n",
             "- uses: " + CHECKOUT.replace("actions/checkout", "Actions/Checkout") + "\n        with:\n          " + base_ref + "\n"),
            ("      - run: python3", "      - uses: actions/download-artifact@0000000000000000000000000000000000000000\n      - run: python3"),
            ("          persist-credentials: false\n", "          persist-credentials: false\n          repository: someone/else\n"),
            ("permissions:\n  contents: read\njobs:", "permissions:\n  contents: read\nenv:\n  HEAD_REF: ${{ github.head_ref }}\njobs:"),
            ("        with:\n          " + base_ref + "\n          persist-credentials: false\n",
             "        with:\n          persist-credentials: false\n"),
        ):
            body = mutate(METADATA, old, new)
            with self.subTest(new=new):
                violations = self.scan({"ci.yml": QUALITY, "pr-metadata.yml": body})
                self.assertTrue(violations, "expected a violation for {!r}".format(new))

    def test_pull_request_target_may_read_event_name_and_base_fields(self) -> None:
        body = mutate(METADATA, "      - run: python3", "      - run: echo ${{ github.event_name }} ${{ github.event.number }} ${{ github.event.pull_request.number }}\n      - run: python3")
        self.assertEqual(self.scan({"ci.yml": QUALITY, "pr-metadata.yml": body}), [])

    def test_unparseable_workflow_is_a_violation_not_a_pass(self) -> None:
        violations = self.scan({"ci.yml": QUALITY, "pr-metadata.yml": METADATA, "odd.yml": "name: x\non: push\njobs: {a: b}\n"})
        self.assertTrue(any("odd.yml: refused" in v for v in violations), violations)


class RepositoryTests(unittest.TestCase):
    def test_repository_workflows_pass_the_scan(self) -> None:
        self.assertEqual(policy.scan_repository(REPO_ROOT), [])

    def test_cli_exit_status(self) -> None:
        result = subprocess.run([sys.executable, "-I", "-S", "-B", str(SCRIPT), "--root", str(REPO_ROOT)],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        with tempfile.TemporaryDirectory() as empty:
            result = subprocess.run([sys.executable, "-I", "-S", "-B", str(SCRIPT), "--root", empty],
                                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
            self.assertEqual(result.returncode, 1)
            self.assertIn("no workflows found", result.stderr)


if __name__ == "__main__":
    unittest.main()
