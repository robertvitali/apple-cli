"""Actual policy runner/parsers with explicit no-spawn transport; no Swift execution."""

import base64
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_capability_policy import (
    POLICY_PATH, candidate_cli_arguments, commit_fixture, load_module,
    mutate_manifest, run_policy_main, sample_dump, write_candidate_fixture, write_json,
)


PASS_XML = b'<testsuites><testsuite><testcase classname="Synthetic" name="passed"/></testsuite></testsuites>'


class CapabilityXUnitTests(unittest.TestCase):
    def setUp(self):
        self.policy = load_module(POLICY_PATH, f"capability_xunit_{id(self)}", synthetic_runtime=False)

    def reject(self, payload, code="runtime-xunit-invalid"):
        with self.assertRaises(self.policy.PolicyError) as caught:
            self.policy._passed_xunit_ids(payload)
        self.assertEqual(str(caught.exception), code)

    def test_namespaced_report_includes_only_passes(self):
        payload = b'''<?xml version="1.0" encoding="UTF-8"?>
<testsuites xmlns="urn:synthetic"><testsuite>
  <testcase classname="Synthetic" name="passed"><system-out>text</system-out></testcase>
  <testcase classname="Synthetic" name="failed"><failure/></testcase>
  <testcase classname="Synthetic" name="errored"><error/></testcase>
  <testcase classname="Synthetic" name="skipped"><skipped/></testcase>
  <testcase classname="Other" name="passed"/>
</testsuite></testsuites>'''
        expected = frozenset(("Synthetic::passed", "Other::passed"))
        self.assertEqual(self.policy._passed_xunit_ids(payload), expected)
        self.assertEqual(self.policy._passed_xunit_ids(b"\xef\xbb\xbf" + payload), expected)

    def test_malformed_missing_invalid_and_empty_pass_reports(self):
        payloads = [b"", b"<testsuites>", b"<testsuites/>",
                    b'<testcase name="passed"/>', b'<testcase classname="Synthetic"/>',
                    b'<testcase classname="" name="passed"/>',
                    b'<testcase classname="Synthetic" name=""/>',
                    b'<testcase classname="Synthetic" name="bad&#127;"/>',
                    b'<testcase classname="Synthetic" name="bad&#10;"/>',
                    b'<testcase classname="Synthetic" name="' + b'x' * 513 + b'"/>',
                    b'<testcase classname="' + b'x' * 513 + b'" name="passed"/>',
                    b'<testcase classname="Synthetic" name="passed"><skipped/></testcase>',
                    b'<testcase classname="Synthetic" name="passed"><failure/></testcase>',
                    b'<testcase classname="Synthetic" name="passed"><error/></testcase>']
        for index, payload in enumerate(payloads):
            with self.subTest(case=index):
                self.reject(payload)

    def test_duplicate_ids_fail_including_pass_failure_collision(self):
        for outcome in (b"", b"<failure/>", b"<skipped/>"):
            with self.subTest(outcome=outcome):
                self.reject(b'<testsuite><testcase classname="Synthetic" name="passed"/>'
                            b'<testcase classname="Synthetic" name="passed">' + outcome +
                            b'</testcase></testsuite>')

    def test_declarations_rejected_in_utf8_and_encoded_xml(self):
        # Internal declarations only: this is rejection coverage, not an external-entity claim.
        documents = [
            '<!DOCTYPE testcase><testcase classname="Synthetic" name="passed"/>',
            '<!DOCTYPE testcase [<!ENTITY label "passed">]>'
            '<testcase classname="Synthetic" name="&label;"/>',
        ]
        for encoding in ("utf-8", "utf-16", "utf-16-le", "utf-16-be", "utf-32", "utf-32-le", "utf-32-be"):
            for index, document in enumerate(documents):
                with self.subTest(encoding=encoding, document=index):
                    self.reject(document.encode(encoding))
        for declaration in (b"<!doctype testcase>", b"<!DoCtYpE testcase>", b'<!EnTiTy label "passed">'):
            with self.subTest(declaration=declaration):
                self.reject(declaration + PASS_XML)

    def test_case_and_node_limits_fail_closed(self):
        with patch.object(self.policy, "MAX_SWIFT_TESTS", 1):
            self.assertEqual(self.policy._passed_xunit_ids(PASS_XML), frozenset(("Synthetic::passed",)))
            self.reject(b'<testsuite><testcase classname="Synthetic" name="one"/>'
                        b'<testcase classname="Synthetic" name="two"/></testsuite>', "runtime-xunit-too-large")
        with patch.object(self.policy.schema, "MAX_JSON_NODES", 3):
            self.assertEqual(self.policy._passed_xunit_ids(PASS_XML), frozenset(("Synthetic::passed",)))
            self.reject(b'<testsuite><testcase classname="Synthetic" name="passed"/>'
                        b'<extra><nested/></extra></testsuite>', "runtime-xunit-too-large")


class CapabilitySwiftMaskTests(unittest.TestCase):
    def setUp(self):
        self.policy = load_module(POLICY_PATH, f"capability_mask_{id(self)}")

    def assert_only_real(self, source):
        masked = self.policy._swift_code_mask(source)
        self.assertEqual(len(masked), len(source))
        self.assertEqual([i for i, c in enumerate(masked) if c in "\r\n"],
                         [i for i, c in enumerate(source) if c in "\r\n"])
        self.assertEqual(self.policy._swift_function_tests(source), {"realTest": [True]})
        self.assertEqual(masked.index("func realTest"), source.index("func realTest"))
        return masked

    def test_escaped_nonraw_multiline_quote_keeps_fake_test_hidden_and_real_cataloged(self):
        source = ('let text = """\n'
                  '\\"""\n@Test func fakeTest() {}\n'
                  '"""\n@Test func realTest() {}\n')
        self.assert_only_real(source)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            path = root / "Tests" / "Synthetic.swift"
            path.parent.mkdir()
            path.write_text(source, encoding="utf-8")
            catalog = {"schema_version": 2, "bindings": [], "tests": [{
                "file_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "id": "swift:Tests/Synthetic.swift:realTest:1", "occurrence": 1,
                "path": "Tests/Synthetic.swift", "runtime_id": "Synthetic::realTest",
                "symbol": "realTest", "tier": "logic",
            }]}
            records = self.policy._swift_catalog(root, catalog, frozenset(("Synthetic::realTest",)))
            self.assertEqual(set(records), {"swift:Tests/Synthetic.swift:realTest:1"})
            catalog["tests"][0].update(id="swift:Tests/Synthetic.swift:fakeTest:1",
                                        symbol="fakeTest", runtime_id="Synthetic::fakeTest")
            with self.assertRaises(self.policy.PolicyError) as caught:
                self.policy._swift_catalog(root, catalog, frozenset(("Synthetic::fakeTest",)))
            self.assertEqual(str(caught.exception), "test-catalog-symbol-missing")

    def test_backslash_raw_multiline_and_nested_comment_controls(self):
        controls = [
            'let text = """\n\\\\\n@Test func fakeTest() {}\n"""\n',
            'let text = #"""\n"""\n@Test func fakeTest() {}\n"""#\n',
            '/* outer /* @Test func fakeTest() {} */ still comment */\r\n',
            '// @Test func fakeTest() {}\r\nlet text = "escaped \\" quote"\n',
        ]
        for index, prefix in enumerate(controls):
            with self.subTest(case=index):
                self.assert_only_real(prefix + '@Test\nfunc realTest() {}\n')

    def test_unterminated_literals_and_comments_fail_closed(self):
        for source in ('let text = "unterminated', 'let text = """\nunterminated',
                       'let text = #"""\nunterminated', '/* outer /* inner */'):
            with self.subTest(source=source):
                with self.assertRaises(self.policy.PolicyError) as caught:
                    self.policy._swift_code_mask(source)
                self.assertEqual(str(caught.exception), "test-catalog-source-invalid")

    def test_line_comment_ends_at_a_lone_carriage_return_as_swift_reads_it(self):
        # Swift's lexer ends a `//` comment at a carriage return as well as at a line feed, so
        # swiftc compiles the code after a lone CR; ending the comment only at a line feed hid it.
        self.assertEqual(self.policy._swift_function_tests("// note\r@Test func hidden() {}\n"),
                         {"hidden": [True]})
        # Line-feed and CRLF controls read as before.
        for ending in ("\n", "\r\n"):
            with self.subTest(ending=ending.encode("unicode_escape").decode("ascii")):
                source = "// note" + ending + "@Test func hidden() {}" + ending
                self.assertEqual(self.policy._swift_function_tests(source), {"hidden": [True]})

    def test_other_line_separators_do_not_end_a_line_comment(self):
        # Only a line feed or a carriage return ends a Swift `//` comment: swiftc keeps U+2028,
        # U+2029, U+0085, U+000B and U+000C inside it, so the code after them is comment text
        # and the fake test stays hidden. Ending the comment at any of them would expose it.
        for separator in ("\u2028", "\u2029", "\x85", "\x0b", "\x0c"):
            with self.subTest(separator="U+{:04X}".format(ord(separator))):
                source = ("// note" + separator + "@Test func fakeTest() {}\n"
                          "@Test func realTest() {}\n")
                masked = self.assert_only_real(source)
                self.assertEqual(set(masked[:source.index("\n")]), {" "})

    def test_test_attribute_after_a_lone_carriage_return_starts_its_line(self):
        # A lone CR ends a Swift line, so an attribute after one is at the start of its line.
        self.assertEqual(
            self.policy._swift_function_tests("func helper() {}\r@Test func realTest() {}\r"),
            {"helper": [False], "realTest": [True]},
        )

    def test_lone_carriage_returns_in_comments_and_literals_read_as_swift_reads_them(self):
        # A lone CR ends a line comment but neither a block comment nor a multi-line string
        # literal; inside both it is content to swiftc as well. Each fake test stays hidden.
        controls = [
            '// comment\r',
            '/* outer /* @Test func fakeTest() {}\r */ still comment */\r',
            'let text = """\r@Test func fakeTest() {}\r"""\r',
            'let text = #"""\r"""\r@Test func fakeTest() {}\r"""#\r',
            'let text = "escaped \\" quote" // @Test func fakeTest() {}\r',
        ]
        for index, prefix in enumerate(controls):
            with self.subTest(case=index):
                self.assert_only_real(prefix + '@Test\rfunc realTest() {}\r')

    def test_catalog_reads_a_lone_carriage_return_as_a_line_end(self):
        # Before the fix the comment ran on to the line feed: `realTest` was invisible and its
        # `@Test` passed to the next function, so a catalog entry naming the helper was accepted
        # as a test declaration although swiftc compiles `realTest` as the test.
        source = '@Test\n// note\rfunc realTest() {}\nfunc helperOnly() {}\n'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            path = root / "Tests" / "Synthetic.swift"
            path.parent.mkdir()
            path.write_bytes(source.encode("utf-8"))
            catalog = {"schema_version": 2, "bindings": [], "tests": [{
                "file_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "id": "swift:Tests/Synthetic.swift:helperOnly:1", "occurrence": 1,
                "path": "Tests/Synthetic.swift", "runtime_id": "Synthetic::helperOnly",
                "symbol": "helperOnly", "tier": "logic",
            }]}
            with self.assertRaises(self.policy.PolicyError) as caught:
                self.policy._swift_catalog(root, catalog, frozenset(("Synthetic::helperOnly",)))
            self.assertEqual(str(caught.exception), "test-catalog-symbol-not-test")
            catalog["tests"][0].update(id="swift:Tests/Synthetic.swift:realTest:1",
                                        symbol="realTest", runtime_id="Synthetic::realTest")
            records = self.policy._swift_catalog(root, catalog, frozenset(("Synthetic::realTest",)))
            self.assertEqual(set(records), {"swift:Tests/Synthetic.swift:realTest:1"})


class CapabilityDiagnosticTests(unittest.TestCase):
    def assert_diagnostic(self, mutate, expected):
        policy = load_module(POLICY_PATH, f"capability_diagnostic_{id(self)}")
        with tempfile.TemporaryDirectory() as directory:
            fixture = write_candidate_fixture(Path(directory).resolve())
            mutate(fixture)
            completed = run_policy_main(policy, ["check", *candidate_cli_arguments(fixture)],
                                        process_session=fixture_session(policy, fixture))
        self.assertEqual(completed.returncode, 2)
        self.assertEqual(completed.stdout, "")
        self.assertEqual(completed.stderr, f"capability-policy: {expected}\n")

    def test_manifest_not_curated_has_exact_diagnostic(self):
        self.assert_diagnostic(lambda fixture: mutate_manifest(
            fixture, lambda manifest: manifest.update(status="draft")), "manifest-not-curated")

    def test_argument_only_runtime_difference_has_exact_diagnostic(self):
        def mutate(fixture):
            dump = json.loads(fixture["dump"].read_text())
            dump["command"]["subcommands"][0]["arguments"][0]["isOptional"] = False
            write_json(fixture["dump"], dump)
            commit_fixture(fixture)
        self.assert_diagnostic(mutate, "runtime-argument-bijection")

    def test_unused_catalog_entry_has_exact_diagnostic(self):
        def mutate(fixture):
            path = fixture["repository_root"] / "Tests" / "CapabilityTests.swift"
            path.write_text(path.read_text() + "@Test func sentinelUnreferenced() {}\n")
            catalog = json.loads(fixture["test_catalog"].read_text())
            record = dict(catalog["tests"][0])
            record.update(id="swift:Tests/CapabilityTests.swift:sentinelUnreferenced:1",
                          symbol="sentinelUnreferenced", runtime_id="SyntheticTests::sentinelUnreferenced")
            catalog["tests"].append(record)
            for record in catalog["tests"]:
                record["file_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
            write_json(fixture["test_catalog"], catalog, canonical=True)
            commit_fixture(fixture)
        self.assert_diagnostic(mutate, "test-catalog-orphan")

    def test_unused_origin_has_exact_diagnostic(self):
        def mutate(manifest):
            for surface in [*manifest["commands"], *manifest["arguments"]]:
                surface["origin_id"] = "extra:synthetic.foo"
        self.assert_diagnostic(lambda fixture: mutate_manifest(fixture, mutate), "origin-orphan-or-missing")

    def test_unknown_evidence_role_has_exact_diagnostic(self):
        self.assert_diagnostic(lambda fixture: mutate_manifest(fixture, lambda manifest:
            manifest["commands"][0]["evidence"].update(sentinelUnknownRole=[])), "evidence-roles-invalid")


# Retained separately for the mandatory qualified child-transport acceptance lane.
from capability_runtime_subjects import FAKE_EXECUTABLE
from capability_session_fixtures import RecordingProcessSession, admit_recording_session, fixture_session, process


class CapabilityRuntimeRunnerTests(unittest.TestCase):
    def setUp(self):
        self.policy = load_module(POLICY_PATH, f"capability_real_runner_{id(self)}", synthetic_runtime=False)
        self.temporary = tempfile.TemporaryDirectory(prefix="capability-fake-executables-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.bin = self.root / "tools"
        self.bin.mkdir()
        self.log = self.root / "calls.jsonl"
        self.config_path = self.root / "config.json"
        self.dump = json.dumps(sample_dump(), separators=(",", ":")).encode()
        self.config = {"log": str(self.log), "xml_hex": PASS_XML.hex(), "dump_hex": self.dump.hex()}
        # Absolute interpreter shebang and a PATH containing only our fake Swift prevent fallback.
        self.executable = (f"#!{sys.executable}\nCONFIG_PATH = {str(self.config_path)!r}\n" + FAKE_EXECUTABLE).encode()
        swift = self.bin / "swift"
        swift.write_bytes(self.executable)
        swift.chmod(0o700)
        self.sha, self.tree = "1" * 40, "2" * 40
        self.session = RecordingProcessSession(process, swift=str(swift), handler=self.stage)
        admit_recording_session(self.policy, self.session)

    def stage(self, request):
        # Actual policy code runs; only transport/file-producing subject is fake.
        args = list(request.argv)
        stage = {"swift-test": "test", "swift-build": "build", "swift-bin-path": "bin", "help-dump": "dump"}[request.role]
        with self.log.open("a") as log:
            log.write(json.dumps({"stage": stage, "argv": args, "cwd": str(request.cwd),
                                  "environment": dict(request.environment)}) + "\n")
        if self.config.get("fail") == stage:
            raise self.session.failure("command-failed", status=9)
        stdout = b""
        if stage == "test":
            Path(args[args.index("--xunit-output") + 1]).write_bytes(bytes.fromhex(self.config["xml_hex"]))
        elif stage == "build":
            binary = Path(args[args.index("--scratch-path") + 1]) / "debug" / "apple"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(self.executable)
            binary.chmod(0o700)
        elif stage == "bin":
            location = self.root if self.config.get("outside_bin") else Path(args[args.index("--scratch-path") + 1]) / "debug"
            stdout = (str(location) + "\n").encode()
        else:
            stdout = bytes.fromhex(self.config["dump_hex"])
        return process.CommandResult(stdout=stdout, stderr=b"", command_status=0, cleanup_complete=True)

    def invoke(self):
        self.config_path.write_text(json.dumps(self.config))
        environment = {"PATH": str(self.bin), "HOME": str(self.root), "LC_ALL": "C",
                       "TMPDIR": str(self.root), "DEVELOPER_DIR": "/synthetic/developer",
                       "SDKROOT": "/synthetic/sdk", "TOOLCHAINS": "synthetic-toolchain",
                       "APPLE_TEST_MODE": "1", "SYNTHETIC_SECRET": "must-not-inherit"}
        with patch.dict(os.environ, environment, clear=True), \
             patch("subprocess.Popen", side_effect=AssertionError("no-spawn transport launched child")), \
             patch.object(os, "killpg", side_effect=AssertionError("no-spawn transport signalled group")):
            return self.policy._default_runtime_runner(self.root, self.sha, self.tree, process_session=self.session)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def assert_cleaned(self, calls):
        self.assertTrue(calls)
        homes = {record["environment"]["HOME"] for record in calls}
        self.assertEqual(len(homes), 1)
        for home in homes:
            self.assertNotEqual(Path(home).parent, self.root)
            self.assertFalse(Path(home).parent.exists())
        self.assertTrue(self.root.is_dir())

    def test_actual_runner_emits_exact_requests_parses_artifacts_and_cleans_files(self):
        with patch.object(self.policy, "_run_bounded_command",
                          wraps=self.policy._run_bounded_command) as commands:
            payload = self.invoke()
        value = json.loads(payload)
        self.assertEqual(value, {
            "schema_version": 1, "contract": "apple-cli-capability-runtime-v1",
            "sha": self.sha, "tree_oid": self.tree,
            "binary_sha256": hashlib.sha256(self.executable).hexdigest(),
            "dump_sha256": hashlib.sha256(self.dump).hexdigest(),
            "dump_base64": base64.b64encode(self.dump).decode(),
            "passed_swift_runtime_ids": ["Synthetic::passed"],
        })
        self.assertEqual(payload, self.policy.canonical_json(value).encode())
        calls = self.calls()
        self.assertEqual([call["stage"] for call in calls], ["test", "build", "bin", "dump"])
        temporary_root = Path(calls[0]["environment"]["HOME"]).parent
        common = ["--package-path", str(self.root), "--scratch-path", str(temporary_root / "build"),
                  "--disable-automatic-resolution"]
        self.assertEqual(calls[0]["argv"], [str(self.bin / "swift"), "test", *common,
                                             "--xunit-output", str(temporary_root / "swift-tests.xml")])
        self.assertEqual(calls[1]["argv"], [str(self.bin / "swift"), "build", *common, "--product", "apple"])
        self.assertEqual(calls[2]["argv"], [str(self.bin / "swift"), "build", *common, "--show-bin-path"])
        self.assertEqual(calls[3]["argv"], [str(temporary_root / "build/debug/apple"), "--experimental-dump-help"])
        expected_environment = {
                "HOME": str(temporary_root / "home"), "TMPDIR": str(temporary_root / "tmp"),
                "LC_ALL": "C", "PATH": str(self.bin), "DEVELOPER_DIR": "/synthetic/developer",
                "SDKROOT": "/synthetic/sdk", "TOOLCHAINS": "synthetic-toolchain",
        }
        for command in commands.call_args_list:
            self.assertEqual(command.kwargs["environment"], expected_environment)
        for request in self.session.requests:
            self.assertEqual(request.cwd, self.root)
            self.assertEqual(dict(request.environment), expected_environment)
        self.assertEqual([request.role for request in self.session.requests],
                         ["swift-test", "swift-build", "swift-bin-path", "help-dump"])
        # Actual child-observed stdin/environment remains in the qualified fixture.
        # These are supplied request assertions, not child transport observations.
        self.assert_cleaned(calls)

    def test_nonzero_stage_errors_stop_later_stages_and_remove_temporary_files(self):
        # A cleaned nonzero session result maps to the original stage diagnostic.
        # No numeric process ownership crosses this policy boundary.
        stages = ["test", "build", "bin", "dump"]
        for index, stage in enumerate(stages):
            with self.subTest(stage=stage):
                self.log.unlink(missing_ok=True)
                self.config["fail"] = stage
                expected = {"test": "runtime-tests-failed", "build": "runtime-build-failed",
                            "bin": "runtime-build-failed", "dump": "runtime-dump-failed"}[stage]
                with self.assertRaises(self.policy.PolicyError) as caught:
                    self.invoke()
                self.assertEqual(str(caught.exception), expected)
                calls = self.calls()
                self.assertEqual([call["stage"] for call in calls], stages[:index + 1])
                self.assert_cleaned(calls)

    def test_invalid_and_oversized_xunit_stop_before_build_and_cleanup(self):
        for payload, maximum, expected in ((b"<invalid", 1024, "runtime-xunit-invalid"),
                                           (PASS_XML, len(PASS_XML) - 1, "input-too-large")):
            with self.subTest(expected=expected):
                self.log.unlink(missing_ok=True)
                self.config["xml_hex"] = payload.hex()
                with patch.object(self.policy, "MAX_XUNIT_BYTES", maximum):
                    with self.assertRaises(self.policy.PolicyError) as caught:
                        self.invoke()
                self.assertEqual(str(caught.exception), expected)
                calls = self.calls()
                self.assertEqual([call["stage"] for call in calls], ["test"])
                self.assert_cleaned(calls)

    def test_outside_scratch_binary_refused_before_dump_and_cleanup(self):
        self.config["outside_bin"] = True
        with self.assertRaises(self.policy.PolicyError) as caught:
            self.invoke()
        self.assertEqual(str(caught.exception), "runtime-binary-invalid")
        calls = self.calls()
        self.assertEqual([call["stage"] for call in calls], ["test", "build", "bin"])
        self.assert_cleaned(calls)

    def test_missing_swift_is_value_free_and_executes_nothing(self):
        with patch.dict(os.environ, {"PATH": str(self.root / "missing")}, clear=True), \
             patch.object(self.session, "selected_executable", side_effect=self.session.failure("process-unavailable")):
            with self.assertRaises(self.policy.PolicyError) as caught:
                self.policy._default_runtime_runner(self.root, self.sha, self.tree, process_session=self.session)
        self.assertEqual(str(caught.exception), "runtime-runner-unavailable")
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
