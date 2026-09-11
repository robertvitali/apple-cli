"""Exact claims with synthetic sources and fake Swift runtime evidence only."""

import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import test_capability_policy as fixtures


class CapabilityClaimBindingRegressionTests(unittest.TestCase):
    def policy(self):
        return fixtures.load_module(
            fixtures.POLICY_PATH, f"capability_claim_regression_{id(self)}"
        )

    def test_one_reference_cannot_satisfy_two_roles(self):
        policy = self.policy()
        with tempfile.TemporaryDirectory() as directory:
            fixture = fixtures.write_candidate_fixture(Path(directory).resolve())
            self.assertTrue(policy.check_candidate(**fixtures.candidate_input(fixture))["ok"])

            def reuse_parser_as_behavior(manifest):
                evidence = manifest["commands"][0]["evidence"]
                evidence["behavior"] = sorted([*evidence["behavior"], evidence["parser_help"][0]])

            fixtures.mutate_manifest(fixture, reuse_parser_as_behavior)
            with patch.object(policy, "_default_runtime_runner") as runner:
                with self.assertRaises(policy.PolicyError) as caught:
                    policy.check_candidate(**fixtures.candidate_input(fixture))
                self.assertEqual(str(caught.exception), "evidence-role-mismatch")
                runner.assert_not_called()

    def test_retained_reference_cannot_gain_another_surface_claim(self):
        policy = self.policy()
        with tempfile.TemporaryDirectory() as base_directory, tempfile.TemporaryDirectory() as head_directory:
            base = fixtures.write_candidate_fixture(Path(base_directory).resolve())
            head = fixtures.write_candidate_fixture(Path(head_directory).resolve())

            def extend_retained_behavior(manifest):
                reference = "swift:Tests/CapabilityTests.swift:testAdditionalBehavior:1"
                evidence = manifest["commands"][1]["evidence"]
                self.assertNotIn(reference, evidence["behavior"])
                evidence["behavior"] = sorted([*evidence["behavior"], reference])

            fixtures.mutate_manifest(head, extend_retained_behavior)
            # Both candidates declare their own complete claims and are valid.
            # Only historical comparison can reject the unchanged test's growth.
            fixtures.sync_fixture_bindings(head)
            fixtures.commit_fixture(head)
            self.assertEqual((base["repository_root"] / "Tests/CapabilityTests.swift").read_bytes(),
                             (head["repository_root"] / "Tests/CapabilityTests.swift").read_bytes())
            self.assertEqual(json.loads(base["test_catalog"].read_text())["tests"],
                             json.loads(head["test_catalog"].read_text())["tests"])
            self.assertTrue(policy.check_candidate(**fixtures.candidate_input(base))["ok"])
            self.assertTrue(policy.check_candidate(**fixtures.candidate_input(head))["ok"])
            with self.assertRaises(policy.PolicyError) as caught:
                policy.compare_candidates(base=fixtures.candidate_input(base), head=fixtures.candidate_input(head))
            self.assertEqual(str(caught.exception), "compare-test-content-change")

    def test_individually_valid_role_swap_cannot_reclassify_retained_evidence(self):
        policy = self.policy()
        with tempfile.TemporaryDirectory() as left, tempfile.TemporaryDirectory() as right:
            base = fixtures.write_candidate_fixture(Path(left).resolve())
            head = fixtures.write_candidate_fixture(Path(right).resolve())
            manifest = json.loads(head["manifest"].read_text())
            for surface in manifest["commands"] + manifest["arguments"]:
                evidence = surface["evidence"]
                evidence["parser_help"], evidence["json_envelope"] = evidence["json_envelope"], evidence["parser_help"]
            fixtures.write_json(head["manifest"], manifest, canonical=True)
            fixtures.sync_fixture_bindings(head)
            fixtures.commit_fixture(head)
            self.assertTrue(policy.check_candidate(**fixtures.candidate_input(base))["ok"])
            self.assertTrue(policy.check_candidate(**fixtures.candidate_input(head))["ok"])
            self.assertEqual((base["repository_root"] / "Tests/CapabilityTests.swift").read_bytes(),
                             (head["repository_root"] / "Tests/CapabilityTests.swift").read_bytes())
            # Role-list removal is the established, earlier comparison guard.
            with self.assertRaisesRegex(policy.PolicyError, "^compare-evidence-removal$"):
                policy.compare_candidates(base=fixtures.candidate_input(base), head=fixtures.candidate_input(head))

    def test_retained_claim_removal_changes_record_and_fails_existing_removal_guard(self):
        policy = self.policy()
        reference = "swift:Tests/CapabilityTests.swift:testAdditionalBehavior:1"
        with tempfile.TemporaryDirectory() as left, tempfile.TemporaryDirectory() as right:
            base = fixtures.write_candidate_fixture(Path(left).resolve())
            head = fixtures.write_candidate_fixture(Path(right).resolve())
            fixtures.mutate_manifest(head, lambda manifest:
                manifest["arguments"][-1]["evidence"]["behavior"].remove(reference))
            fixtures.sync_fixture_bindings(head)
            fixtures.commit_fixture(head)
            records = []
            for fixture in (base, head):
                self.assertTrue(policy.check_candidate(**fixtures.candidate_input(fixture))["ok"])
                raw = json.loads(fixture["test_catalog"].read_text())
                sources = policy._swift_catalog(fixture["repository_root"], raw)
                bound, _ = policy._validate_evidence(json.loads(fixture["manifest"].read_text()), sources, raw["bindings"])
                records.append(bound[reference])
            self.assertEqual(records[0][:4], records[1][:4])
            self.assertEqual(len(records[0].claims), 2)
            self.assertEqual(len(records[1].claims), 1)
            self.assertNotEqual(records[0], records[1])
            # Valid claim removal necessarily removes a manifest reference from
            # that surface, so the existing earlier guard must keep its priority.
            with self.assertRaisesRegex(policy.PolicyError, "^compare-evidence-removal$"):
                policy.compare_candidates(base=fixtures.candidate_input(base), head=fixtures.candidate_input(head))

    def test_bats_declarations_without_execution_refuse_before_runtime(self):
        policy = self.policy()
        for tier in ("hosted", "local"):
            with self.subTest(tier=tier), tempfile.TemporaryDirectory() as directory:
                fixture = fixtures.write_candidate_fixture(Path(directory).resolve(), include_bats=tier == "hosted")
                if tier == "local":
                    reference = fixtures.add_local_bats(fixture)
                    fixtures.mutate_manifest(fixture, lambda manifest: manifest["arguments"][-1]["evidence"]["behavior"].insert(0, reference))
                    fixtures.sync_fixture_bindings(fixture)
                    fixtures.commit_fixture(fixture)
                # Prove static closure first; otherwise missing claims could hide
                # the absence of runtime evidence in this assertion.
                catalog = json.loads(fixture["test_catalog"].read_text())
                sources = policy._swift_catalog(fixture["repository_root"], catalog)
                sources.update(policy._bats_catalog(fixture["repository_root"], json.loads(fixture["bats_inventory"].read_text())))
                policy._validate_evidence(json.loads(fixture["manifest"].read_text()), sources, catalog["bindings"])
                with patch.object(policy, "_default_runtime_runner") as runner:
                    with self.assertRaises(policy.PolicyError) as caught:
                        policy.check_candidate(**fixtures.candidate_input(fixture))
                    self.assertEqual(str(caught.exception), "bats-execution-unavailable")
                    runner.assert_not_called()

    def test_catalog_v1_and_malformed_roots_refuse_before_runtime(self):
        policy = self.policy()
        cases = (lambda raw: raw.update(schema_version=1),
                 lambda raw: raw.update(schema_version=True),
                 lambda raw: raw.pop("bindings"),
                 lambda raw: raw.update(bindings={}),
                 lambda raw: raw.update(extra="synthetic"))
        for mutate in cases:
            with self.subTest(mutate=mutate), tempfile.TemporaryDirectory() as directory:
                fixture = fixtures.write_candidate_fixture(Path(directory).resolve())
                raw = json.loads(fixture["test_catalog"].read_text())
                mutate(raw)
                fixtures.write_json(fixture["test_catalog"], raw, canonical=True)
                fixtures.commit_fixture(fixture)
                with patch.object(policy, "_default_runtime_runner") as runner:
                    with self.assertRaisesRegex(policy.PolicyError, "^test-catalog-invalid$"):
                        policy.check_candidate(**fixtures.candidate_input(fixture))
                    runner.assert_not_called()

    def add_surface(self, policy, fixture, *, existing_file):
        dump = json.loads(fixture["dump"].read_text())
        dump["command"]["subcommands"][0]["arguments"].append(fixtures.named_argument("extra"))
        fixtures.write_json(fixture["dump"], dump)
        argument = next(item for item in policy.snapshot_manifest(dump)["arguments"]
                        if item["id"] == "apple foo::flag::--extra")
        argument["origin_id"] = "extra:synthetic.foo"
        relative = "Tests/CapabilityTests.swift" if existing_file else "Tests/NewSurfaceTests.swift"
        path = fixture["repository_root"] / relative
        symbols = ("newParser", "newInvalid", "newJSON", "newBehavior")
        source = path.read_text() if path.exists() else ""
        path.write_text(source + "\n".join(f"@Test func {symbol}() {{}}" for symbol in symbols) + "\n")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        raw = json.loads(fixture["test_catalog"].read_text())
        for record in raw["tests"]:
            if record["path"] == relative:
                record["file_sha256"] = digest
        for role, symbol in zip(fixtures.EVIDENCE_ROLES, symbols):
            reference = f"swift:{relative}:{symbol}:1"
            argument["evidence"][role] = [reference]
            raw["tests"].append(dict(id=reference, path=relative, symbol=symbol, occurrence=1,
                                     runtime_id=f"NewSurface::{symbol}", tier="logic", file_sha256=digest))
        fixtures.write_json(fixture["test_catalog"], raw, canonical=True)
        manifest = json.loads(fixture["manifest"].read_text())
        manifest["arguments"].append(argument)
        manifest["arguments"].sort(key=lambda item: item["id"])
        manifest["counts"]["arguments"] += 1
        fixtures.write_json(fixture["manifest"], manifest, canonical=True)
        manual = fixture["repository_root"] / "docs/manual/foo.md"
        manual.write_text(manual.read_text() + "\n`--extra`\n")
        fixtures.sync_fixture_bindings(fixture)
        fixtures.commit_fixture(fixture)

    def test_new_surface_requires_independent_file_and_preserves_whole_file_freeze(self):
        policy = self.policy()
        for existing_file in (False, True):
            with self.subTest(existing_file=existing_file), tempfile.TemporaryDirectory() as left, tempfile.TemporaryDirectory() as right:
                base = fixtures.write_candidate_fixture(Path(left).resolve())
                head = fixtures.write_candidate_fixture(Path(right).resolve())
                self.add_surface(policy, head, existing_file=existing_file)
                self.assertTrue(policy.check_candidate(**fixtures.candidate_input(head))["ok"])
                if existing_file:
                    with self.assertRaisesRegex(policy.PolicyError, "^compare-test-content-change$"):
                        policy.compare_candidates(base=fixtures.candidate_input(base), head=fixtures.candidate_input(head))
                else:
                    report = policy.compare_candidates(base=fixtures.candidate_input(base), head=fixtures.candidate_input(head))
                    self.assertTrue(report["ok"])
                    self.assertEqual((report["new_commands"], report["new_arguments"]), (0, 1))

    def test_swift_runtime_identity_alias_refuses_even_with_distinct_source_references(self):
        policy = self.policy()
        with tempfile.TemporaryDirectory() as directory:
            fixture = fixtures.write_candidate_fixture(Path(directory).resolve())
            raw = json.loads(fixture["test_catalog"].read_text())
            original = raw["tests"][0]
            relative = "Tests/AliasTests.swift"
            path = fixture["repository_root"] / relative
            path.write_text(f'@Test func {original["symbol"]}() {{}}\n')
            alias = dict(original, id=f'swift:{relative}:{original["symbol"]}:1', path=relative,
                         file_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
            raw["tests"].append(alias)
            with self.assertRaisesRegex(policy.PolicyError, "^test-catalog-invalid$"):
                policy._swift_catalog(fixture["repository_root"], raw)


class CapabilityClaimValidationTests(unittest.TestCase):
    def setUp(self):
        self.policy = fixtures.load_module(fixtures.POLICY_PATH, f"claim_validation_{id(self)}")
        self.manifest = self.policy.snapshot_manifest(fixtures.sample_dump())
        self.sources = {}
        references = {}
        for role, symbol in zip(fixtures.EVIDENCE_ROLES, ("parser", "invalid", "json", "behavior")):
            reference = f"swift:Tests/Claims.swift:{symbol}:1"
            references[role] = [reference]
            self.sources[reference] = self.policy.SourceEvidenceRecord("logic", "0" * 64, f"Claims::{symbol}")
        for surface in self.manifest["commands"] + self.manifest["arguments"]:
            surface["evidence"] = copy.deepcopy(references)
        self.bindings = fixtures.bindings_for_manifest(self.manifest)

    def validate(self):
        return self.policy._validate_evidence(self.manifest, self.sources, self.bindings)

    def reject(self, code):
        with self.assertRaises(self.policy.PolicyError) as caught:
            self.validate()
        self.assertEqual(str(caught.exception), code)

    def test_complete_sharing_binds_distinct_command_and_argument_claims_immutably(self):
        bound, fanout = self.validate()
        record = next(iter(bound.values()))
        self.assertIsInstance(record.claims, tuple)
        self.assertIn(self.policy.Claim("apple", None), record.claims)
        self.assertIn(self.policy.Claim("apple", "apple::flag::--version"), record.claims)
        self.assertEqual(set(fanout.values()), {5})
        with self.assertRaises(AttributeError):
            record.role = "behavior"
        with self.assertRaises(AttributeError):
            record.claims[0].command_id = "changed"
        self.bindings[0]["claims"][0]["command_id"] = "changed"
        self.assertNotIn("changed", [claim.command_id for claim in record.claims])

    def test_binding_types_keys_roles_and_order_fail_closed(self):
        mutations = (
            (lambda value: value.update(reference=[]), "evidence-binding-invalid"),
            (lambda value: value.update(role=[]), "evidence-binding-invalid"),
            (lambda value: value.update(role="unknown"), "evidence-binding-invalid"),
            (lambda value: value.update(claims={}), "evidence-binding-invalid"),
            (lambda value: value.update(claims=[]), "evidence-binding-invalid"),
            (lambda value: value.update(extra=True), "evidence-binding-invalid"),
            (lambda value: value.update(role="parser_help" if value["role"] != "parser_help" else "behavior"), "evidence-role-mismatch"),
        )
        original = copy.deepcopy(self.bindings)
        for mutate, code in mutations:
            with self.subTest(code=code):
                self.bindings = copy.deepcopy(original)
                mutate(self.bindings[0])
                self.reject(code)
        self.bindings = list(reversed(original))
        self.reject("evidence-binding-order")
        self.bindings = [original[0], *original]
        self.reject("evidence-binding-order")

    def test_claim_shapes_owner_membership_and_exact_sets(self):
        original = copy.deepcopy(self.bindings)
        mutations = (
            (lambda claim: claim.update(command_id=[]), "evidence-claim-invalid"),
            (lambda claim: claim.update(command_id=True), "evidence-claim-invalid"),
            (lambda claim: claim.update(argument_id={}), "evidence-claim-invalid"),
            (lambda claim: claim.update(argument_id=False), "evidence-claim-invalid"),
            (lambda claim: claim.update(command_id="apple missing"), "evidence-claim-invalid"),
            (lambda claim: claim.update(argument_id="missing"), "evidence-claim-invalid"),
            (lambda claim: claim.update(argument_id="apple foo::option::--name"), "evidence-claim-invalid"),
            (lambda claim: claim.update(extra="synthetic"), "evidence-claim-invalid"),
        )
        for mutate, code in mutations:
            with self.subTest(code=code):
                self.bindings = copy.deepcopy(original)
                mutate(self.bindings[0]["claims"][0])
                self.reject(code)
        self.bindings = copy.deepcopy(original)
        self.bindings[0]["claims"].pop()
        self.reject("evidence-claims-mismatch")
        self.bindings = copy.deepcopy(original)
        self.bindings[0]["claims"][1] = self.bindings[0]["claims"][0]
        self.reject("evidence-claim-order")
        self.bindings = copy.deepcopy(original)
        self.bindings[0]["claims"].reverse()
        self.reject("evidence-claim-order")

    def test_valid_but_unused_extra_claim_is_rejected(self):
        reference = "swift:Tests/Claims.swift:extraBehavior:1"
        self.sources[reference] = self.policy.SourceEvidenceRecord("logic", "0" * 64, "Claims::extraBehavior")
        behavior = self.manifest["commands"][0]["evidence"]["behavior"]
        behavior.append(reference)
        behavior.sort()
        self.bindings = fixtures.bindings_for_manifest(self.manifest)
        self.assertEqual(len(self.validate()[0][reference].claims), 1)
        binding = next(item for item in self.bindings if item["reference"] == reference)
        binding["claims"].append({"command_id": "apple foo", "argument_id": None})
        self.reject("evidence-claims-mismatch")

    def test_missing_unused_and_orphan_records_preserve_closure(self):
        original = copy.deepcopy(self.bindings)
        self.bindings.pop()
        self.reject("evidence-binding-missing")
        self.bindings = copy.deepcopy(original)
        extra = copy.deepcopy(original[-1])
        extra["reference"] = "swift:Tests/Unused.swift:unused:1"
        self.bindings.append(extra)
        self.bindings.sort(key=lambda item: item["reference"])
        self.reject("evidence-binding-unused")
        self.bindings = original
        self.sources[extra["reference"]] = self.policy.SourceEvidenceRecord("logic", "0" * 64, "Unused::unused")
        self.reject("test-catalog-orphan")

    def test_identity_alias_cannot_split_its_role_between_bindings(self):
        refs = list(self.sources)
        self.sources[refs[1]] = self.sources[refs[1]]._replace(runtime_id=self.sources[refs[0]].runtime_id)
        self.reject("evidence-identity-alias")

    def test_named_count_bounds_allow_exact_and_refuse_one_over(self):
        totals = {"MAX_BINDINGS": 4, "MAX_CLAIMS_PER_BINDING": 5,
                  "MAX_DECLARED_CLAIMS": 20, "MAX_REFERENCE_OCCURRENCES": 20}
        codes = {"MAX_BINDINGS": "evidence-bindings-too-large", "MAX_CLAIMS_PER_BINDING": "evidence-claims-too-large",
                 "MAX_DECLARED_CLAIMS": "evidence-claims-too-large", "MAX_REFERENCE_OCCURRENCES": "evidence-references-too-large"}
        for name, count in totals.items():
            with self.subTest(limit=name), patch.object(self.policy, name, count):
                self.assertEqual(len(self.validate()[0]), 4)
            with self.subTest(limit=name, exceeded=True), patch.object(self.policy, name, count - 1):
                self.reject(codes[name])
        self.bindings[0]["claims"].append(copy.deepcopy(self.bindings[0]["claims"][0]))
        self.reject("evidence-claims-too-large")

    def test_count_limits_fire_before_iterating_oversized_input(self):
        class Unexpanded(list):
            def __iter__(self):
                raise AssertionError("oversized input was expanded")
        original = self.bindings
        self.bindings = Unexpanded(original)
        with patch.object(self.policy, "MAX_BINDINGS", 3):
            self.reject("evidence-bindings-too-large")
        self.bindings = copy.deepcopy(original)
        self.bindings[0]["claims"] = Unexpanded([None] * 6)
        self.reject("evidence-claims-too-large")
        self.bindings = original
        self.manifest["commands"][0]["evidence"]["parser_help"] = Unexpanded([None, None])
        with patch.object(self.policy, "MAX_REFERENCE_OCCURRENCES", 1):
            self.reject("evidence-references-too-large")


if __name__ == "__main__":
    unittest.main()
