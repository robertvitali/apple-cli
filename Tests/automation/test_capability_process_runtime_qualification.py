"""Inert runtime/platform metadata contracts, not loaded-state qualification.

All identities and paths are synthetic. A valid descriptor only represents the
finite inputs and observations that a later actual-process qualifier must verify.
Loader names describe existing selection mechanisms; they install no importer.
The profile-specific bounds below are fixture values, not qualified host limits.
"""

from __future__ import annotations

import builtins
import copy
import unittest
from contextlib import ExitStack
from unittest import mock

from capability_runtime_metadata_fixtures import (
    descriptors, special_parent_records, stock_special_modules)
from test_capability_process_lifecycle import Clock, core


class RuntimeMetadataTests(unittest.TestCase):
    def setUp(self):
        self.platform, self.runtime = descriptors()
        self.clock = Clock(12.0)

    def admit(self, platform=None, runtime=None):
        operation = getattr(core, "_admit_runtime_metadata", None)
        self.assertTrue(callable(operation), "missing inert runtime metadata admission API")
        # Install the import guard last: constructing the test's guards is not
        # part of the metadata operation's permitted effect surface.
        with ExitStack() as stack:
            for owner, name in ((core.os, "open"), (core.os, "stat"), (core.os, "lstat"),
                                (core.subprocess, "Popen"), (core.signal, "signal")):
                stack.enter_context(mock.patch.object(owner, name,
                    side_effect=AssertionError("metadata performed runtime effect: " + name)))
            stack.enter_context(mock.patch.object(builtins, "__import__",
                side_effect=AssertionError("metadata imported runtime implementation")))
            return operation(self.platform if platform is None else platform,
                             self.runtime if runtime is None else runtime,
                             deadline=68.0, clock=self.clock)

    def reject(self, *, platform=None, runtime=None):
        with self.assertRaises(core.ProcessFailure):
            self.admit(platform, runtime)

    def module(self, name):
        return next(row for row in self.runtime["modules"] if row["name"] == name)

    def test_valid_metadata_is_deeply_immutable_and_has_no_live_process_authority(self):
        admitted = self.admit()
        self.assertEqual(admitted.runtime["images"]["main"]["file"], "main")
        self.assertEqual(admitted.platform["architecture"], "arm64")
        with self.assertRaises(TypeError):
            admitted.runtime["modules"][0]["aliases"][0:0] = ("replacement",)
        with self.assertRaises(TypeError):
            admitted.platform["apple_base"]["cache_uuid"] = "0" * 32
        for name in ("observe_child", "reset_child_disposition", "run", "recheck"):
            self.assertFalse(hasattr(admitted, name))
        self.runtime["images"]["main"]["file"] = "changed-input"
        self.assertEqual(admitted.runtime["images"]["main"]["file"], "main")

    def test_closed_top_level_and_nested_records_reject_unknown_or_missing_fields(self):
        cases = []
        for path in ((), ("startup",), ("bindings", "clock"), ("images", "main"), ("limits",)):
            for change in ("extra", "missing"):
                value = copy.deepcopy(self.runtime)
                target = value
                for name in path:
                    target = target[name]
                if change == "extra":
                    target["unexpected"] = "synthetic"
                else:
                    del target[next(iter(target))]
                cases.append(value)
        for index, value in enumerate(cases):
            with self.subTest(case=index):
                self.reject(runtime=value)

    def test_platform_does_not_convert_non_system_files_into_trusted_apple_base(self):
        for path in ("/synthetic/runtime/library", "/usr/lib/../private/library", "relative"):
            with self.subTest(path_kind=path.split("/")[0]):
                platform = copy.deepcopy(self.platform)
                platform["apple_base"]["images"][0]["install_name"] = path
                self.reject(platform=platform)

    def test_platform_requires_closed_version_architecture_and_observed_base_shape(self):
        cases = []
        for field, value in (("schema_version", True), ("system", "Other"),
                             ("architecture", "unqualified"), ("build_version", "")):
            platform = copy.deepcopy(self.platform)
            platform[field] = value
            cases.append(platform)
        platform = copy.deepcopy(self.platform)
        platform["apple_base"]["assumption"] = "whole-os-attested"
        cases.append(platform)
        platform = copy.deepcopy(self.platform)
        platform["apple_base"]["cache_uuid"] = None
        platform["apple_base"]["images"] = []
        cases.append(platform)
        for index, platform in enumerate(cases):
            with self.subTest(case=index):
                self.reject(platform=platform)

    def test_clock_and_reset_descriptors_cannot_select_an_alternate_contract(self):
        for section, field, value in (("clock", "value", True), ("clock", "value", 6),
                ("clock", "name", "monotonic"), ("clock", "module", "synthetic"),
                ("reset", "module", "signal"), ("reset", "name", "getsignal"),
                ("reset", "getter_offset", -1), ("reset", "wrapper_offset", True)):
            with self.subTest(section=section, field=field):
                runtime = copy.deepcopy(self.runtime)
                runtime["bindings"][section][field] = value
                self.reject(runtime=runtime)

    def test_images_require_distinct_bound_files_and_exact_macho_metadata(self):
        cases = []
        for image, field, value in (("main", "file", "missing"), ("main", "file", "launcher"),
                ("framework", "file_type", 2), ("main", "uuid", "bad"),
                ("main", "architecture", "unqualified")):
            runtime = copy.deepcopy(self.runtime)
            runtime["images"][image][field] = value
            cases.append(runtime)
        for index, runtime in enumerate(cases):
            with self.subTest(case=index):
                self.reject(runtime=runtime)

    def test_platform_main_and_framework_architectures_must_agree(self):
        for field in ("platform", "main", "framework"):
            with self.subTest(field=field):
                platform, runtime = descriptors()
                target = platform if field == "platform" else runtime["images"][field]
                target["architecture"] = "x86_64"
                self.reject(platform=platform, runtime=runtime)

    def test_distinct_image_ids_cannot_repackage_one_path_or_physical_file(self):
        for collision in ("path", "physical"):
            with self.subTest(collision=collision):
                runtime = copy.deepcopy(self.runtime)
                files = {row["id"]: row["identity"] for row in runtime["files"]}
                if collision == "path":
                    files["main"]["path"] = files["launcher"]["path"]
                else:
                    for name in ("device", "inode"):
                        files["main"][name] = files["launcher"][name]
                self.reject(runtime=runtime)

    def test_file_records_are_unique_canonical_regular_and_fully_pinned(self):
        cases = []
        runtime = copy.deepcopy(self.runtime)
        runtime["files"].append(copy.deepcopy(runtime["files"][0]))
        cases.append(runtime)
        for key, value in (("path", "/synthetic/../outside"), ("mode", 0o120777),
                           ("sha256", "bad"), ("size", True), ("inode", -1)):
            runtime = copy.deepcopy(self.runtime)
            runtime["files"][0]["identity"][key] = value
            cases.append(runtime)
        runtime = copy.deepcopy(self.runtime)
        del runtime["files"][0]["identity"]["ctime_ns"]
        cases.append(runtime)
        for index, runtime in enumerate(cases):
            with self.subTest(case=index):
                self.reject(runtime=runtime)

    def test_module_name_alias_or_kind_conflicts_refuse(self):
        cases = []
        runtime = copy.deepcopy(self.runtime)
        runtime["modules"].append(copy.deepcopy(runtime["modules"][0]))
        cases.append(runtime)
        for update in ({"aliases": ["time"]}, {"kind": "automatic"},
                       {"name": "bad..name"}, {"registry_name": ""}):
            runtime = copy.deepcopy(self.runtime)
            runtime["modules"][0].update(update)
            cases.append(runtime)
        for index, runtime in enumerate(cases):
            with self.subTest(case=index):
                self.reject(runtime=runtime)

    def test_external_entry_name_cannot_be_assigned_a_second_module_origin(self):
        for origin in ("canonical-name", "alias"):
            with self.subTest(origin=origin):
                runtime = copy.deepcopy(self.runtime)
                if origin == "canonical-name":
                    runtime["modules"].append({"name": "__main__", "kind": "builtin",
                        "registry_name": "synthetic_builtin", "spec_name": "synthetic_builtin",
                        "aliases": []})
                else:
                    runtime["modules"][0]["aliases"] = ["__main__"]
                self.reject(runtime=runtime)

    def test_distinct_module_alias_remains_valid_metadata(self):
        self.module("time")["aliases"] = ["synthetic_time_alias"]
        admitted = self.admit()
        row = next(row for row in admitted.runtime["modules"] if row["name"] == "time")
        self.assertEqual(row["aliases"], ("synthetic_time_alias",))

    def test_frozen_alias_may_name_source_metadata_without_becoming_source_implementation(self):
        row = self.module("importlib._bootstrap")
        row["file_alias"] = "subprocess-source"
        admitted = self.admit()
        result = next(row for row in admitted.runtime["modules"] if row["kind"] == "frozen")
        self.assertEqual(result["registry_name"], "_frozen_importlib")
        self.assertEqual(result["file_alias"], "subprocess-source")
        self.assertEqual(result["kind"], "frozen")

    def test_selected_bytecode_requires_its_own_pinned_file_even_with_no_bytecode_writes(self):
        self.assertEqual(self.runtime["startup"]["dont_write_bytecode"], 1)
        self.module("subprocess")["cache"] = None
        self.reject()

    def test_selected_source_and_cache_remain_explicit_existing_loader_choices(self):
        row = self.module("subprocess")
        row["selected_input"] = "source"
        row["cache"] = None
        admitted = self.admit()
        result = next(row for row in admitted.runtime["modules"] if row["name"] == "subprocess")
        self.assertEqual(result["loader"], "SourceFileLoader")
        self.assertEqual(result["selected_input"], "source")
        self.assertIsNone(result["cache"])
        # This is metadata only; actual source/cache selection evidence remains
        # required before a fresh process can be qualified.

    def test_unknown_or_missing_selected_loader_inputs_refuse(self):
        for change in ({"loader": "new-custom-loader"}, {"source": None},
                       {"cache": "missing"}, {"selected_input": "auto"},
                       {"package_member": "capability_process.py"}):
            with self.subTest(field=next(iter(change))):
                runtime = copy.deepcopy(self.runtime)
                row = next(row for row in runtime["modules"] if row["name"] == "subprocess")
                row.update(change)
                self.reject(runtime=runtime)

    def test_verified_package_buffer_is_a_distinct_closed_member_selection(self):
        self.runtime["modules"].append({"name": "capability_process", "kind": "source",
            "spec_name": "capability_process", "aliases": [],
            "loader": "verified-package-buffer", "selected_input": "package-buffer",
            "source": None, "cache": None, "package_member": "capability_process.py"})
        admitted = self.admit()
        self.assertTrue(any(row["name"] == "capability_process"
                            for row in admitted.runtime["modules"]))
        self.runtime["modules"][-1]["package_member"] = "unlisted.py"
        self.reject()

    def test_extension_requires_uuid_and_explicit_non_system_dependency_members(self):
        for change in ({"uuid": "bad"}, {"file": "missing"},
                       {"dependencies": ["missing"]}, {"dependencies": ["extension"]}):
            with self.subTest(field=next(iter(change))):
                runtime = copy.deepcopy(self.runtime)
                row = next(row for row in runtime["modules"] if row["kind"] == "extension")
                row.update(change)
                self.reject(runtime=runtime)

    def special_runtime(self):
        """The base descriptor plus the parent rows and both stock special rows.

        Always built from an untouched copy of the fixture, so no caller can
        enrich one descriptor twice: a doubly-enriched runtime refuses on its
        duplicate records, which would mask the rule a refusal test is checking.
        """
        runtime = copy.deepcopy(self.runtime)
        files, parents = special_parent_records()
        runtime["files"].extend(files)
        runtime["modules"].extend(parents)
        runtime["modules"].extend(stock_special_modules())
        return runtime

    def admitted_special_runtime(self):
        """`special_runtime`, proved to ADMIT before the caller mutates it.

        Non-vacuity guard: without it a later refusal could come from the fixture
        rather than from the rule under test, and the rule could be deleted with
        the refusal tests still green.
        """
        runtime = self.special_runtime()
        self.admit(runtime=runtime)
        return runtime

    def special(self, runtime, kind):
        return next(row for row in runtime["modules"] if row["kind"] == kind)

    def test_stock_special_kinds_describe_parent_attributes_without_an_import_spec(self):
        runtime = self.special_runtime()
        admitted = self.admit(runtime=runtime)
        rows = {row["name"]: row for row in admitted.runtime["modules"]}
        namespace = rows["typing.io"]
        self.assertEqual(namespace["kind"], "stock-typing-namespace")
        self.assertEqual(namespace["parent"], "typing")
        self.assertIsNone(namespace["spec_name"])
        self.assertEqual(namespace["exports"], ("BinaryIO", "IO", "TextIO"))
        child = rows["pyexpat.errors"]
        self.assertEqual(child["kind"], "stock-extension-child")
        self.assertEqual(child["parent"], "pyexpat")
        self.assertIsNone(child["spec_name"])
        self.assertIs(child["file_present"], False)
        self.assertIs(child["cached_present"], False)
        # Presence booleans encode the metadata absence the exact key set cannot.
        with self.assertRaises(TypeError):
            namespace["exports"][0:0] = ("Extra",)
        with self.assertRaises(TypeError):
            child["file_present"] = True

    def test_stock_special_rows_carry_no_aliases(self):
        runtime = self.special_runtime()
        admitted = self.admit(runtime=runtime)
        rows = {row["name"]: row for row in admitted.runtime["modules"]}
        for name in ("typing", "pyexpat", "typing.io", "pyexpat.errors"):
            self.assertEqual(rows[name]["aliases"], ())
        # An alias would otherwise re-enter the same child under its other
        # spelling, past the per-(parent, attribute) check, or claim an unrelated
        # module name. The empty-alias rule refuses first; the global alias
        # uniqueness that would catch the third case remains the backstop for
        # every other kind.
        for kind, aliases in (("stock-typing-namespace", ["typing.io_alias"]),
                              ("stock-extension-child", ["xml.parsers.expat.errors"]),
                              ("stock-extension-child", ["subprocess"])):
            with self.subTest(kind=kind, alias=aliases[0]):
                runtime = self.admitted_special_runtime()
                self.special(runtime, kind)["aliases"] = aliases
                self.reject(runtime=runtime)

    def test_typing_namespace_attributes_pin_their_own_member_name_set(self):
        runtime = self.special_runtime()
        self.special(runtime, "stock-typing-namespace").update(
            name="typing.re", attribute="re", exports=["Match", "Pattern"])
        admitted = self.admit(runtime=runtime)
        result = next(row for row in admitted.runtime["modules"]
                      if row["name"] == "typing.re")
        self.assertEqual(result["exports"], ("Match", "Pattern"))

    def test_extension_child_alias_spelling_is_supported_but_unobserved(self):
        runtime = self.special_runtime()
        self.special(runtime, "stock-extension-child")["name"] = "xml.parsers.expat.errors"
        admitted = self.admit(runtime=runtime)
        self.assertTrue(any(row["name"] == "xml.parsers.expat.errors"
                            for row in admitted.runtime["modules"]))

    def test_typing_namespace_member_names_reject_addresses_disorder_and_drift(self):
        for update in ({"exports": {"IO": 4096}},
                       {"exports": ["IO", "BinaryIO", "TextIO"]},
                       {"exports": ["BinaryIO", "BinaryIO", "IO", "TextIO"]},
                       {"exports": ["BinaryIO", "IO"]},
                       {"exports": ["BinaryIO", "IO", "TextIO", ""]},
                       {"attribute": "codecs"},
                       {"name": "typing.text"},
                       {"parent": "typing_absent", "name": "typing_absent.io"},
                       {"parent": "importlib._bootstrap",
                        "name": "importlib._bootstrap.io"},
                       {"spec_name": "typing.io"}):
            with self.subTest(field=sorted(update)[0]):
                runtime = self.admitted_special_runtime()
                self.special(runtime, "stock-typing-namespace").update(update)
                self.reject(runtime=runtime)

    def test_a_stock_special_row_cannot_be_reparented_onto_another_special_row(self):
        # The pinned parent literal forecloses this; the parent-kind clause behind
        # it is the defence in depth that would still refuse without the literal.
        runtime = self.admitted_special_runtime()
        runtime["modules"].append({
            "name": "pyexpat.errors.io", "kind": "stock-typing-namespace",
            "spec_name": None, "aliases": [], "parent": "pyexpat.errors",
            "attribute": "io", "exports": ["BinaryIO", "IO", "TextIO"]})
        self.reject(runtime=runtime)

    def test_a_child_placed_before_its_parent_refuses_and_parent_first_admits(self):
        # Row order is part of the descriptor: the admitted-module set is built as
        # the list is walked, so a child ahead of its parent is indistinguishable
        # from a dangling parent and refuses the same way.
        files, parents = special_parent_records()
        specials = stock_special_modules()
        # Parent-first ADMITS: proved first, so the refusal below cannot be the
        # fixture failing for some unrelated reason.
        runtime = copy.deepcopy(self.runtime)
        runtime["files"].extend(files)
        runtime["modules"].extend(parents + specials)
        admitted = self.admit(runtime=runtime)
        self.assertEqual(
            sum(row["kind"] in ("stock-typing-namespace", "stock-extension-child")
                for row in admitted.runtime["modules"]), 2)
        # The very same rows, reordered, refuse.
        runtime = copy.deepcopy(self.runtime)
        runtime["files"].extend(files)
        runtime["modules"].extend(specials + parents)
        self.reject(runtime=runtime)

    def test_extension_child_parent_must_be_an_extension_row_not_merely_so_named(self):
        runtime = self.admitted_special_runtime()
        parent = next(row for row in runtime["modules"] if row["name"] == "pyexpat")
        parent.clear()
        parent.update({"name": "pyexpat", "kind": "builtin", "registry_name": "pyexpat",
                       "spec_name": "pyexpat", "aliases": []})
        self.reject(runtime=runtime)

    def test_one_child_cannot_be_admitted_under_both_of_its_spellings(self):
        runtime = self.admitted_special_runtime()
        alias = copy.deepcopy(self.special(runtime, "stock-extension-child"))
        alias["name"] = "xml.parsers.expat.errors"
        runtime["modules"].append(alias)
        self.reject(runtime=runtime)

    def test_extension_child_requires_an_extension_parent_and_boolean_presence(self):
        for update in ({"parent": "time", "name": "time.errors"},
                       {"parent": "typing", "name": "typing.errors"},
                       {"parent": "pyexpat_absent", "name": "pyexpat_absent.errors"},
                       {"attribute": "handler"},
                       {"name": "pyexpat.errors_alias"},
                       {"name": "xml.parsers.expat.model"},
                       {"file_present": 0},
                       {"cached_present": None},
                       {"spec_name": "pyexpat.errors"}):
            with self.subTest(field=sorted(update)[0]):
                runtime = self.admitted_special_runtime()
                self.special(runtime, "stock-extension-child").update(update)
                self.reject(runtime=runtime)

    def test_relabelling_between_stock_special_and_imported_module_kinds_refuses(self):
        for kind, relabel in (("stock-typing-namespace", "builtin"),
                              ("stock-typing-namespace", "source"),
                              ("stock-extension-child", "extension"),
                              ("stock-extension-child", "frozen")):
            with self.subTest(kind=kind, relabel=relabel):
                runtime = self.admitted_special_runtime()
                self.special(runtime, kind)["kind"] = relabel
                self.reject(runtime=runtime)
        for name, relabel in (("importlib._bootstrap", "stock-typing-namespace"),
                              ("synthetic_extension", "stock-extension-child")):
            with self.subTest(name=name, relabel=relabel):
                runtime = self.admitted_special_runtime()
                next(row for row in runtime["modules"]
                     if row["name"] == name)["kind"] = relabel
                self.reject(runtime=runtime)

    def test_popen_record_requires_source_body_and_separate_empty_active_binding(self):
        for field, value in (("source", "missing"), ("module", "synthetic"),
                ("destructor", "different"), ("active_name", "other"),
                ("expected_active_count", 1), ("expected_active_count", False)):
            with self.subTest(field=field):
                runtime = copy.deepcopy(self.runtime)
                runtime["popen"][field] = value
                self.reject(runtime=runtime)

    def test_popen_body_source_must_match_the_selected_subprocess_source(self):
        # Both references exist and have valid identities; membership alone is
        # insufficient to bind the destructor to the selected implementation.
        self.runtime["popen"]["source"] = "subprocess-cache"
        self.reject()

    def test_declared_counts_sizes_and_code_bounds_are_exact_positive_integers(self):
        for field in self.runtime["limits"]:
            for invalid in (0, True, -1, 2**64):
                with self.subTest(field=field, invalid_kind=type(invalid).__name__):
                    runtime = copy.deepcopy(self.runtime)
                    runtime["limits"][field] = invalid
                    self.reject(runtime=runtime)
        for field, value in (("module_count", 1), ("file_count", 1),
                             ("per_file_bytes", 4095), ("aggregate_file_bytes", 4096)):
            with self.subTest(field=field):
                runtime = copy.deepcopy(self.runtime)
                runtime["limits"][field] = value
                self.reject(runtime=runtime)

    def test_existing_profile_json_size_and_structure_bounds_apply_before_expansion(self):
        for excessive in ("bytes", "depth", "cycle"):
            with self.subTest(excessive=excessive):
                runtime = copy.deepcopy(self.runtime)
                if excessive == "bytes":
                    runtime["search_paths"] = ["/" + "x" * (1024 * 1024)]
                elif excessive == "depth":
                    value = 0
                    for _ in range(17):
                        value = [value]
                    runtime["search_paths"] = value
                else:
                    runtime["search_paths"] = runtime
                self.reject(runtime=runtime)

    def test_complete_input_size_limit_is_independent_of_profile_declared_limits(self):
        for name in self.runtime["limits"]:
            self.runtime["limits"][name] = 2**63
        # Each path is small, canonical and distinct; the aggregate metadata
        # exceeds the existing JSON ceiling before any immutable copy is made.
        self.runtime["absent_inputs"] = [
            "/synthetic/" + str(index) + "/" + "x" * 1024 for index in range(1100)]
        with mock.patch.object(core, "_freeze_data",
                side_effect=AssertionError("oversized metadata reached expansion")):
            self.reject()

    def test_json_preflight_counts_utf8_and_structure_before_expansion(self):
        operation = getattr(core, "_bound_runtime_metadata", None)
        self.assertTrue(callable(operation), "missing inert metadata preflight")
        # A JSON object with a one-character key costs eight punctuation/key
        # bytes; this pins the complete encoded size, including Unicode bytes.
        operation({"x": "a" * (1024 * 1024 - 8)}, lambda: None)
        for value in ({"x": "a" * (1024 * 1024 - 7)},
                      {"x": "\u00e9" * (1024 * 512)},
                      {"x": [0] * 32768}):
            with self.assertRaises(core.ProcessFailure):
                operation(value, lambda: None)

    def test_absence_and_search_metadata_cannot_admit_traversal_or_contradict_bound_files(self):
        for field, value in (("search_paths", ["relative"]),
                ("absent_inputs", ["/synthetic/runtime/../elsewhere"]),
                ("absent_inputs", ["/synthetic/runtime/launcher"])):
            with self.subTest(field=field):
                runtime = copy.deepcopy(self.runtime)
                runtime[field] = value
                self.reject(runtime=runtime)

    def test_absent_directory_cannot_contain_a_bound_file(self):
        self.runtime["absent_inputs"] = ["/synthetic/runtime"]
        self.reject()

    def test_absent_search_directory_and_non_component_prefix_remain_valid_metadata(self):
        self.runtime["search_paths"].append("/synthetic/missing")
        self.runtime["absent_inputs"] = ["/synthetic/missing", "/synthetic/run"]
        admitted = self.admit()
        self.assertEqual(admitted.runtime["absent_inputs"],
                         ("/synthetic/missing", "/synthetic/run"))

    def test_expired_original_deadline_refuses_without_any_runtime_effect(self):
        self.clock.now = 68.0
        self.reject()

    def test_admission_consumes_same_clock_and_rejects_late_preflight_entry(self):
        readings = []
        def clock():
            readings.append(True)
            return 12.0 if len(readings) == 1 else 68.0
        self.clock = clock
        self.reject()
        self.assertGreaterEqual(len(readings), 2)

    def test_final_checkpoint_rejects_deadline_reached_during_immutable_copy(self):
        original = core._freeze_data
        copied = []

        def freeze(value):
            result = original(value)
            if value is self.runtime:
                copied.append(result)
                self.clock.now = 68.0
            return result

        with mock.patch.object(core, "_freeze_data", side_effect=freeze):
            self.reject()
        self.assertEqual(len(copied), 1)
        self.assertEqual(copied[0]["images"]["main"]["file"], "main")
