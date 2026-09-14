"""Synthetic connected pre-load metadata; no filesystem/runtime qualification."""

from __future__ import annotations

import builtins
import copy
import json
from contextlib import ExitStack
from pathlib import Path
from types import MappingProxyType
import unittest
from unittest import mock

from capability_runtime_metadata_fixtures import (
    descriptors, special_parent_records, stock_special_modules)
from test_capability_process_lifecycle import Clock, core


ROOT = "/synthetic/runtime"


def directory(path):
    return {"path": path, "device": 1, "inode": 2, "mode": 0o40755,
            "uid": 1, "gid": 1, "mtime_ns": 1, "ctime_ns": 1}


def source_profile():
    platform, runtime = descriptors()
    runtime["files"] = [row for row in runtime["files"] if row["id"] != "subprocess-cache"]
    source = next(row for row in runtime["files"] if row["id"] == "subprocess-source")
    source["identity"]["path"] = ROOT + "/subprocess.py"
    module = next(row for row in runtime["modules"] if row["name"] == "subprocess")
    module.update(selected_input="source", cache=None)
    cache = ROOT + "/__pycache__/subprocess.cpython-39.pyc"
    legacy = ROOT + "/subprocess.pyc"
    runtime["absent_inputs"] = sorted((cache, legacy, ROOT + "/subprocess.so", ROOT + "/extension.py"))
    preload = {"schema_version": 1, "policy": "stock-source-no-cache-v1",
        "launch_environment": {"LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
        "cache_branch": {"pycache_prefix": None, "check_hash_based_pycs": "default"},
        "directories": [directory(ROOT), directory(ROOT + "/__pycache__")],
        "searches": [
            {"module": "subprocess", "candidates": [
                {"path": ROOT + "/subprocess.so", "file": None},
                {"path": ROOT + "/subprocess.py", "file": "subprocess-source"},
                {"path": cache, "file": None}, {"path": legacy, "file": None}]},
            {"module": "synthetic_extension", "candidates": [
                {"path": ROOT + "/extension", "file": "extension"},
                {"path": ROOT + "/extension.py", "file": None}]}]}
    tool = copy.deepcopy(next(row["identity"] for row in runtime["files"] if row["id"] == "launcher"))
    return {"id": "synthetic-profile", "status": "qualified", "platform": platform,
            "runtime": runtime, "preload": preload, "projection": {"synthetic": True},
            "compiler_arguments": ["synthetic-never-executed"],
            "executables": {name: copy.deepcopy(tool) for name in ("git", "swift", "compiler", "linker")}}


def root_source_profile():
    """Same finite synthetic inputs, with the source directly below slash."""
    row = source_profile()
    for record in row["runtime"]["files"]:
        record["identity"]["path"] = record["identity"]["path"][len(ROOT):]
    row["runtime"]["search_paths"] = ["/"]
    row["runtime"]["absent_inputs"] = [path[len(ROOT):] for path in row["runtime"]["absent_inputs"]]
    row["preload"]["directories"] = [directory("/"), directory("/__pycache__")]
    for search in row["preload"]["searches"]:
        for candidate in search["candidates"]:
            candidate["path"] = candidate["path"][len(ROOT):]
    return row


class PreloadMetadataTests(unittest.TestCase):
    def setUp(self):
        self.row = source_profile()
        self.clock = Clock(12.0)

    def select(self, row=None):
        payload = json.dumps({"schema_version": 1, "profiles": [self.row if row is None else row]}).encode()
        package = core._VerifiedPackage(Path("/synthetic/package"), "1" * 64,
            MappingProxyType({"capability_process_profiles.json": payload}), MappingProxyType({}), ())
        with ExitStack() as stack:
            for owner, name in ((core.os, "open"), (core.os, "stat"), (core.os, "lstat"),
                    (core.subprocess, "Popen"), (core.signal, "signal"),
                    (core.ctypes, "CDLL"), (core.ctypes, "PyDLL"), (core.ctypes, "string_at")):
                stack.enter_context(mock.patch.object(owner, name,
                    side_effect=AssertionError("metadata effect: " + name)))
            stack.enter_context(mock.patch.object(builtins, "__import__",
                side_effect=AssertionError("metadata import")))
            return core._select_profile(package, "synthetic-profile", deadline=68.0, clock=self.clock)

    def reject(self, row=None):
        with self.assertRaises(core.ProcessFailure):
            self.select(row)

    def test_previously_accepted_profile_without_preload_now_refuses(self):
        del self.row["preload"]
        self.reject()

    def test_valid_selected_profile_retains_detached_immutable_preload(self):
        selected = self.select()
        self.assertEqual(selected.preload.descriptor["policy"], "stock-source-no-cache-v1")
        with self.assertRaises(TypeError):
            selected.preload.descriptor["directories"][0]["path"] = "/changed"
        self.row["preload"]["directories"][0]["path"] = "/changed"
        self.assertEqual(selected.preload.descriptor["directories"][0]["path"], ROOT)
        for name in ("run", "recheck", "observe_child", "reset_child_disposition", "clock"):
            self.assertFalse(hasattr(selected.preload, name))
        with self.assertRaises(core.ProcessFailure):
            core._qualify_runtime(selected, deadline=68.0, clock=self.clock)

    def test_unknown_missing_and_wrong_container_fields_refuse(self):
        for path in ((), ("launch_environment",), ("cache_branch",), ("directories", 0),
                     ("searches", 0), ("searches", 0, "candidates", 0)):
            for operation in ("missing", "extra"):
                row = copy.deepcopy(self.row)
                target = row["preload"]
                for part in path:
                    target = target[part]
                if operation == "missing":
                    del target[next(iter(target))]
                else:
                    target["unexpected"] = "synthetic"
                with self.subTest(path=path, operation=operation):
                    self.reject(row)
        for key in ("directories", "searches"):
            row = copy.deepcopy(self.row)
            row["preload"][key] = {}
            self.reject(row)

    def test_schema_policy_environment_and_cache_branch_are_exact(self):
        changes = (("schema_version", True), ("schema_version", 2), ("policy", "other"),
                   ("launch_environment", {"LC_ALL": "C"}),
                   ("launch_environment", {"LC_ALL": "C", "PATH": "/synthetic"}),
                   ("cache_branch", {"pycache_prefix": ROOT, "check_hash_based_pycs": "default"}),
                   ("cache_branch", {"pycache_prefix": None, "check_hash_based_pycs": "always"}))
        for key, value in changes:
            row = copy.deepcopy(self.row)
            row["preload"][key] = value
            with self.subTest(field=key, value=value):
                self.reject(row)

    def test_directory_numbers_modes_and_canonical_paths_refuse(self):
        changes = [("mode", mode) for mode in (0o40777, 0o40765, 0o41755, 0o40355, 0o40655, 0o100755)]
        changes += [(key, value) for key in ("device", "inode", "uid", "gid", "mtime_ns", "ctime_ns")
                    for value in (True, -1, 2**64)]
        changes += [("path", path) for path in ("relative", ROOT + "/../runtime", ROOT + "//child", "/" + "x" * 4096)]
        for key, value in changes:
            row = copy.deepcopy(self.row)
            row["preload"]["directories"][0][key] = value
            with self.subTest(field=key, value=value):
                self.reject(row)

    def test_duplicate_and_noncanonical_directory_or_search_order_refuses(self):
        for field in ("directories", "searches"):
            for operation in ("duplicate", "reverse"):
                row = copy.deepcopy(self.row)
                values = row["preload"][field]
                if operation == "duplicate":
                    values.append(copy.deepcopy(values[0]))
                else:
                    values.reverse()
                with self.subTest(field=field, operation=operation):
                    self.reject(row)

    def test_file_directory_and_absence_collisions_refuse(self):
        for path in (ROOT + "/subprocess.py", ROOT + "/subprocess.pyc"):
            row = copy.deepcopy(self.row)
            row["preload"]["directories"].append(directory(path))
            row["preload"]["directories"].sort(key=lambda value: value["path"])
            self.reject(row)
        row = copy.deepcopy(self.row)
        row["runtime"]["absent_inputs"].append(ROOT)
        self.reject(row)

    def test_regular_file_cannot_be_directory_ancestor_but_prefix_sibling_is_allowed(self):
        for path, accepted in ((ROOT + "/subprocess.py/child", False), (ROOT + "/subprocess.py-extra", True)):
            row = copy.deepcopy(self.row)
            row["preload"]["directories"].append(directory(path))
            row["preload"]["directories"].sort(key=lambda value: value["path"])
            with self.subTest(accepted=accepted):
                if accepted:
                    self.assertIsNotNone(self.select(row).preload)
                else:
                    self.reject(row)

    def test_missing_file_parent_and_unclassified_search_root_refuse(self):
        row = copy.deepcopy(self.row)
        row["preload"]["directories"] = row["preload"]["directories"][1:]
        self.reject(row)
        self.row["runtime"]["search_paths"].append("/synthetic/unknown")
        self.reject()

    def test_absent_search_root_closes_branch_without_child_candidates(self):
        absent = "/synthetic/absent-search"
        self.row["runtime"]["search_paths"].insert(0, absent)
        self.row["runtime"]["absent_inputs"].append(absent)
        self.assertIsNotNone(self.select().preload)
        child = absent + "/subprocess.so"
        self.row["runtime"]["absent_inputs"].append(child)
        self.row["preload"]["searches"][0]["candidates"].insert(0, {"path": child, "file": None})
        self.reject()

    def test_stock_special_kinds_contribute_no_stock_loader_search(self):
        # The parents are ordinary searchable rows, declared with the searches that
        # cover them; the two special rows that follow add none of their own.
        row = copy.deepcopy(self.row)
        files, parents = special_parent_records()
        source = next(value for value in files if value["id"] == "typing-source")
        source["identity"]["path"] = ROOT + "/typing.py"
        extension = next(value for value in files if value["id"] == "expat-extension")
        extension["identity"]["path"] = ROOT + "/pyexpat"
        cache = ROOT + "/__pycache__/typing.cpython-39.pyc"
        legacy = ROOT + "/typing.pyc"
        row["runtime"]["files"].extend(files)
        row["runtime"]["modules"].extend(parents)
        row["runtime"]["absent_inputs"] = sorted(
            row["runtime"]["absent_inputs"] + [cache, legacy])
        row["preload"]["searches"].extend((
            {"module": "pyexpat", "candidates": [
                {"path": ROOT + "/pyexpat", "file": "expat-extension"}]},
            {"module": "typing", "candidates": [
                {"path": ROOT + "/typing.py", "file": "typing-source"},
                {"path": cache, "file": None}, {"path": legacy, "file": None}]}))
        row["preload"]["searches"].sort(key=lambda search: search["module"])
        # Independently computed, so this cannot pass by comparing a value to
        # itself: the declared searches must cover exactly the searchable rows.
        searchable = sum(module["kind"] == "extension"
                         or (module["kind"] == "source"
                             and module["loader"] == "SourceFileLoader")
                         for module in row["runtime"]["modules"])
        self.assertEqual(len(row["preload"]["searches"]), searchable)
        self.assertIsNotNone(self.select(row).preload)
        row["runtime"]["modules"].extend(stock_special_modules())
        self.assertEqual(len(row["preload"]["searches"]), searchable)
        self.assertIsNotNone(self.select(row).preload)
        # A search that DOES name a special row refuses, so the equality above
        # cannot be satisfied by handing one a search.
        row["preload"]["searches"].insert(1, {
            "module": "pyexpat.errors",
            "candidates": [{"path": ROOT + "/pyexpat.errors", "file": None}]})
        self.reject(row)

    def test_module_coverage_requires_exact_stock_loader_set(self):
        for operation in ("missing", "builtin", "unknown"):
            row = copy.deepcopy(self.row)
            if operation == "missing":
                row["preload"]["searches"].pop()
            else:
                row["preload"]["searches"][0]["module"] = "time" if operation == "builtin" else "unknown"
            self.reject(row)

    def test_candidate_order_is_preserved_and_not_normalized(self):
        self.row["preload"]["searches"][0]["candidates"].reverse()
        selected = self.select()
        actual = selected.preload.descriptor["searches"][0]["candidates"]
        self.assertEqual([value["path"] for value in actual],
                         [value["path"] for value in self.row["preload"]["searches"][0]["candidates"]])

    def test_candidate_duplicate_unknown_and_mismatched_file_references_refuse(self):
        for operation in ("duplicate", "unknown", "wrong-file", "no-file", "unknown-absence"):
            row = copy.deepcopy(self.row)
            values = row["preload"]["searches"][0]["candidates"]
            if operation == "duplicate":
                values.append(copy.deepcopy(values[0]))
            elif operation == "unknown":
                values[1]["file"] = "unknown"
            elif operation == "wrong-file":
                values[1]["file"] = "extension"
            elif operation == "no-file":
                values[1]["file"] = None
            else:
                values[0]["path"] = ROOT + "/unlisted.so"
            self.reject(row)

    def test_source_cache_selection_and_missing_cache_absences_refuse(self):
        for operation in ("cache-selected", "ordinary-missing", "legacy-missing"):
            row = copy.deepcopy(self.row)
            if operation == "cache-selected":
                module = next(value for value in row["runtime"]["modules"] if value["name"] == "subprocess")
                cache = copy.deepcopy(next(value for value in row["runtime"]["files"] if value["id"] == "subprocess-source"))
                cache["id"] = "source-cache"
                cache["identity"].update(path=ROOT + "/selected-cache", inode=999)
                row["runtime"]["files"].append(cache)
                module.update(selected_input="cache", cache="source-cache")
            else:
                row["preload"]["searches"][0]["candidates"].pop(2 if operation == "ordinary-missing" else 3)
            self.reject(row)

    def test_runtime_file_size_ceiling_is_independent_of_declared_runtime_limit(self):
        self.row["runtime"]["limits"].update(per_file_bytes=128 * 1024 * 1024, aggregate_file_bytes=256 * 1024 * 1024)
        self.row["runtime"]["files"][0]["identity"]["size"] = 64 * 1024 * 1024 + 1
        self.reject()

    def test_original_deadline_is_not_restarted(self):
        self.clock.now = 68.0
        self.reject()

    def test_root_source_uses_single_slash_ordinary_cache_path(self):
        row = root_source_profile()
        selected = self.select(row)
        paths = tuple(value["path"] for value in selected.preload.descriptor["searches"][0]["candidates"])
        self.assertIn("/subprocess.py", paths)
        self.assertIn("/__pycache__/subprocess.cpython-39.pyc", paths)
        self.assertIn("/subprocess.pyc", paths)
        self.assertFalse(any(path.startswith("//") for path in paths))

    def test_root_source_missing_cache_or_double_slash_still_refuses(self):
        cache = "/__pycache__/subprocess.cpython-39.pyc"
        for operation in ("missing-candidate", "missing-absence", "double-slash"):
            row = root_source_profile()
            candidates = row["preload"]["searches"][0]["candidates"]
            if operation == "missing-candidate":
                candidates[:] = [value for value in candidates if value["path"] != cache]
            elif operation == "missing-absence":
                row["runtime"]["absent_inputs"].remove(cache)
            else:
                for value in candidates:
                    if value["path"] == cache:
                        value["path"] = "/" + cache
                row["runtime"]["absent_inputs"].remove(cache)
                row["runtime"]["absent_inputs"].append("/" + cache)
            with self.subTest(operation=operation):
                self.reject(row)

    def direct_metadata(self):
        return core._admit_runtime_metadata(self.row["platform"], self.row["runtime"],
                                           deadline=68.0, clock=self.clock)

    def test_direct_preload_rejects_oversize_and_cycle_before_freeze(self):
        metadata = self.direct_metadata()
        for operation in ("oversize", "cycle"):
            preload = copy.deepcopy(self.row["preload"])
            preload["policy"] = "x" * (1024 * 1024 + 1) if operation == "oversize" else preload
            with self.subTest(operation=operation), \
                    mock.patch.object(core, "_bound_runtime_metadata", wraps=core._bound_runtime_metadata) as bound, \
                    mock.patch.object(core, "_freeze_data") as freeze:
                with self.assertRaises(core.ProcessFailure):
                    core._admit_preload_metadata(metadata, preload, deadline=68.0, clock=self.clock)
                bound.assert_called_once()
                self.assertIs(bound.call_args.args[0], preload)
                freeze.assert_not_called()

    def test_direct_preload_final_expiry_after_freeze_refuses(self):
        metadata = self.direct_metadata()
        preload = self.row["preload"]
        original = core._freeze_data
        completed = []

        def expire_after_freeze(value):
            frozen = original(value)
            if value is preload:
                completed.append(frozen)
                self.clock.now = 68.0
            return frozen

        with mock.patch.object(core, "_freeze_data", side_effect=expire_after_freeze):
            with self.assertRaises(core.ProcessFailure):
                core._admit_preload_metadata(metadata, preload, deadline=68.0, clock=self.clock)
        self.assertEqual(len(completed), 1)
        self.assertEqual(completed[0]["policy"], "stock-source-no-cache-v1")

    def test_direct_preload_retains_detached_deeply_immutable_data(self):
        metadata = self.direct_metadata()
        preload = self.row["preload"]
        admitted = core._admit_preload_metadata(metadata, preload, deadline=68.0, clock=self.clock)
        self.assertIsInstance(admitted.descriptor, MappingProxyType)
        self.assertIsInstance(admitted.descriptor["searches"], tuple)
        retained = admitted.descriptor["searches"][0]["candidates"][0]["path"]
        with self.assertRaises(TypeError):
            admitted.descriptor["searches"][0]["candidates"][0]["path"] = "/changed"
        preload["searches"][0]["candidates"][0]["path"] = "/changed"
        preload["directories"].clear()
        self.assertEqual(admitted.descriptor["searches"][0]["candidates"][0]["path"], retained)
        self.assertEqual(len(admitted.descriptor["directories"]), 2)


if __name__ == "__main__":
    unittest.main()
