"""Synthetic package/profile metadata and help-binary admission, without execution.

Profile selection is data admission only. The synthetic runtime/projection
descriptors deliberately cannot qualify a real runtime or compiler invocation.
"""

from __future__ import annotations

import hashlib
import json
import os
from dataclasses import replace
from pathlib import Path
from unittest import mock

from test_capability_process_lifecycle import Clock, LifecycleFixture, core, identity


MEMBERS = {
    "bats_evidence.py": "python-source",
    "bats_inventory.py": "python-source",
    "capability_policy.py": "python-source",
    "capability_process.py": "python-source",
    "capability_process_native.c": "native-source",
    "capability_process_profiles.json": "profile-data",
    "capability_process_protocol.py": "python-source",
    "capability_schema.py": "python-source",
}


class AdmissionFixture(LifecycleFixture):
    def setUp(self):
        super().setUp()
        self.package_root = self.root / "package"
        self.package_root.mkdir(mode=0o700)
        for name in MEMBERS:
            content = (b'{"schema_version":1,"profiles":[]}\n' if name.endswith(".json")
                       else b"# synthetic source, never executed\n" if name.endswith(".py")
                       else b"/* synthetic source, never compiled */\n")
            (self.package_root / name).write_bytes(content)
        self.write_manifest()

    def write_manifest(self, transform=None):
        members = [{"path": name, "kind": kind,
                    "size": (self.package_root / name).stat().st_size,
                    "sha256": hashlib.sha256((self.package_root / name).read_bytes()).hexdigest()}
                   for name, kind in sorted(MEMBERS.items())]
        payload = {"schema_version": 1, "members": members}
        if transform:
            payload = transform(payload)
        data = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode() + b"\n"
        (self.package_root / "capability_package_manifest.json").write_bytes(data)
        self.trusted = core.TrustedRunnerRoot(
            self.package_root, hashlib.sha256(data).hexdigest(),
            core._PreparationBudget(self.clock, 10.0, 68.0))

    def verify(self):
        return core._verify_package(self.trusted, deadline=68.0, clock=self.clock)

    def raw_manifest(self, payload):
        (self.package_root / "capability_package_manifest.json").write_bytes(payload)
        self.trusted = replace(self.trusted, expected_manifest_sha256=hashlib.sha256(payload).hexdigest())

    def profile_row(self):
        record = vars(self.selected).copy()
        return {"id": "synthetic-profile", "status": "qualified",
                "platform": {"qualification_fixture": True},
                "runtime": {"qualification_fixture": True},
                "projection": {"qualification_fixture": True},
                "compiler_arguments": ["synthetic-never-executed"],
                "executables": {name: dict(record) for name in ("git", "swift", "compiler", "linker")}}

    def install_profiles(self, rows):
        data = {"schema_version": 1, "profiles": rows}
        (self.package_root / "capability_process_profiles.json").write_text(json.dumps(data) + "\n")
        self.write_manifest()
        return self.succeed(self.verify)


class ClosedPackageTests(AdmissionFixture):
    def test_wrong_external_digest_refuses_intact_package(self):
        self.trusted = replace(self.trusted, expected_manifest_sha256="5" * 64)
        with self.assertRaises(core.ProcessFailure):
            self.verify()
        self.popen.assert_not_called()

    def test_exact_manifest_returns_immutable_verified_member_bytes_without_execution(self):
        with mock.patch("builtins.exec", side_effect=AssertionError("source execution forbidden")):
            package = self.succeed(self.verify)
        self.assertEqual(package.root, self.package_root)
        self.assertEqual(package.sha256, self.trusted.expected_manifest_sha256)
        self.assertEqual(set(package.members), set(MEMBERS))
        self.assertEqual(package.members["capability_policy.py"], b"# synthetic source, never executed\n")
        with self.assertRaises(TypeError):
            package.members["capability_policy.py"] = b"changed"
        self.popen.assert_not_called()
        self.signal.assert_not_called()

    def test_changed_member_refuses_without_implicitly_repinning_manifest(self):
        (self.package_root / "capability_policy.py").write_bytes(b"changed\n")
        with self.assertRaises(core.ProcessFailure):
            self.verify()
        self.popen.assert_not_called()

    def test_unlisted_file_refuses_even_when_listed_hashes_match(self):
        (self.package_root / "shadow.py").write_bytes(b"not admitted\n")
        with self.assertRaises(core.ProcessFailure):
            self.verify()

    def test_missing_file_refuses(self):
        (self.package_root / "bats_inventory.py").unlink()
        with self.assertRaises(core.ProcessFailure):
            self.verify()

    def test_link_member_refuses_even_with_matching_target_bytes(self):
        member = self.package_root / "bats_evidence.py"
        target = self.root / "synthetic-source"
        target.write_bytes(member.read_bytes())
        member.unlink()
        member.symlink_to(target)
        with self.assertRaises(core.ProcessFailure):
            self.verify()

    def test_manifest_cannot_admit_itself_or_extra_members(self):
        def recursive(payload):
            payload["members"].append({"path": "capability_package_manifest.json",
                                       "kind": "profile-data", "size": 0, "sha256": "1" * 64})
            return payload
        self.write_manifest(recursive)
        with self.assertRaises(core.ProcessFailure):
            self.verify()

    def test_oversized_member_refuses_before_opening_it(self):
        path = self.package_root / "capability_policy.py"
        path.write_bytes(b"x" * (1024 * 1024 + 1))
        self.write_manifest()
        original_open = os.open
        opened = []

        def open_member(path, flags, *args, **kwargs):
            if Path(path).name == "capability_policy.py":
                opened.append(path)
                raise AssertionError("oversized member must be rejected before open")
            return original_open(path, flags, *args, **kwargs)

        with mock.patch.object(core.os, "open", side_effect=open_member):
            with self.assertRaises(core.ProcessFailure):
                self.verify()
        self.assertEqual(opened, [])

    def test_expired_package_deadline_precedes_first_file_open(self):
        self.clock.now = 68.0
        with mock.patch.object(core.os, "open", side_effect=AssertionError("late open")) as opened:
            with self.assertRaises(core.ProcessFailure):
                self.verify()
        opened.assert_not_called()

    def test_manifest_duplicate_keys_records_and_wrong_types_refuse(self):
        original = (self.package_root / "capability_package_manifest.json").read_bytes()
        cases = []
        cases.append(original.replace(b'"schema_version":1', b'"schema_version":1,"schema_version":1'))
        for change in ("duplicate-member", "schema-bool", "size-bool", "wrong-kind"):
            payload = json.loads(original)
            if change == "duplicate-member":
                payload["members"][1] = payload["members"][0]
            elif change == "schema-bool":
                payload["schema_version"] = True
            elif change == "size-bool":
                payload["members"][0]["size"] = True
            else:
                payload["members"][0]["kind"] = "native-source"
            cases.append(json.dumps(payload).encode())
        for index, raw in enumerate(cases):
            with self.subTest(case=index):
                self.raw_manifest(raw)
                with self.assertRaises(core.ProcessFailure):
                    self.verify()

    def test_manifest_size_and_nesting_bounds_refuse(self):
        for raw in (b" " * (64 * 1024 + 1), b'{"nested":' + b"[" * 17 + b"0" + b"]" * 17 + b"}"):
            with self.subTest(size=len(raw)):
                self.raw_manifest(raw)
                with self.assertRaises(core.ProcessFailure):
                    self.verify()

    def test_last_member_read_returning_late_cannot_admit_package(self):
        original_open, original_read = os.open, os.read
        last = []
        returned = []

        def open_member(path, flags, *args, **kwargs):
            descriptor = original_open(path, flags, *args, **kwargs)
            if Path(path).name == "capability_schema.py":
                last.append(descriptor)
            return descriptor

        def read(descriptor, maximum):
            result = original_read(descriptor, maximum)
            if last and descriptor == last[0]:
                returned.append(len(result))
                self.clock.now = 68.001
            return result

        with mock.patch.object(core.os, "open", side_effect=open_member):
            with mock.patch.object(core.os, "read", side_effect=read):
                with self.assertRaises(core.ProcessFailure) as raised:
                    self.verify()
        self.assertTrue(returned)
        self.assertEqual(raised.exception.reason, "deadline")

    def test_unlisted_file_added_during_last_member_read_refuses(self):
        original_open, original_read = os.open, os.read
        original_members = {name: (self.package_root / name).read_bytes() for name in MEMBERS}
        last = []
        added = []
        extra = self.package_root / "unlisted.py"

        def open_member(path, flags, *args, **kwargs):
            descriptor = original_open(path, flags, *args, **kwargs)
            if Path(path).name == "capability_schema.py":
                last.append(descriptor)
            return descriptor

        def read(descriptor, maximum):
            result = original_read(descriptor, maximum)
            if last and descriptor == last[0] and not added:
                extra.write_bytes(b"synthetic unlisted source, never executed\n")
                added.append(True)
            return result

        with mock.patch.object(core.os, "open", side_effect=open_member):
            with mock.patch.object(core.os, "read", side_effect=read):
                with self.subTest(check="refusal"):
                    with self.assertRaises(core.ProcessFailure) as raised:
                        self.verify()
                    self.assertEqual(raised.exception.reason, "identity-drift")
        self.assertEqual(added, [True])
        self.assertTrue(extra.is_file())
        self.assertEqual({name: (self.package_root / name).read_bytes() for name in MEMBERS},
                         original_members)
        self.popen.assert_not_called()

    def test_package_root_close_returning_late_cannot_admit_package(self):
        original_open, original_close = os.open, os.close
        root_descriptors = []
        closed = []

        def open_root(path, flags, *args, **kwargs):
            descriptor = original_open(path, flags, *args, **kwargs)
            if Path(path) == self.package_root:
                root_descriptors.append(descriptor)
            return descriptor

        def close(descriptor):
            original_close(descriptor)
            if descriptor in root_descriptors:
                closed.append(descriptor)
                self.clock.now = 68.0

        with mock.patch.object(core.os, "open", side_effect=open_root):
            with mock.patch.object(core.os, "close", side_effect=close):
                with self.subTest(check="refusal"):
                    with self.assertRaises(core.ProcessFailure) as raised:
                        self.verify()
                    self.assertEqual(raised.exception.reason, "deadline")
        self.assertEqual(len(root_descriptors), 1)
        self.assertEqual(closed, root_descriptors)
        self.popen.assert_not_called()


class ProfileMetadataTests(AdmissionFixture):
    def test_nested_profile_metadata_is_deeply_immutable(self):
        row = self.profile_row()
        row["runtime"]["nested"] = [{"value": 1}]
        package = self.install_profiles([row])
        selected = self.succeed(lambda: core._select_profile(
            package, "synthetic-profile", deadline=68.0, clock=self.clock))
        with self.assertRaises(TypeError):
            selected.runtime["nested"][0]["value"] = 2
        self.assertIs(type(selected.runtime["nested"]), tuple)

    def test_selected_tool_identities_are_immutable_metadata_not_runtime_authority(self):
        package = self.install_profiles([self.profile_row()])
        selected = self.succeed(lambda: core._select_profile(
            package, "synthetic-profile", deadline=68.0, clock=self.clock))
        self.assertEqual(selected.executables["git"], self.selected)
        for role in ("swift-test", "swift-build", "swift-bin-path"):
            self.assertEqual(selected.executables[role], self.selected)
        with self.assertRaises(TypeError):
            selected.executables["git"] = self.selected
        with self.assertRaises(TypeError):
            selected.runtime["qualification_fixture"] = False
        with self.assertRaises(core.ProcessFailure):
            core._qualify_runtime(selected, deadline=68.0, clock=self.clock)
        self.popen.assert_not_called()

    def test_inactive_and_missing_profile_refuse(self):
        row = self.profile_row()
        row["status"] = "inactive"
        package = self.install_profiles([row])
        for selected in ("synthetic-profile", "missing-profile"):
            with self.subTest(selected=selected):
                with self.assertRaises(core.ProcessFailure):
                    core._select_profile(package, selected, deadline=68.0, clock=self.clock)

    def test_duplicate_profile_identity_refuses(self):
        package = self.install_profiles([self.profile_row(), self.profile_row()])
        with self.assertRaises(core.ProcessFailure):
            core._select_profile(package, "synthetic-profile", deadline=68.0, clock=self.clock)

    def test_missing_fixed_tool_mapping_refuses(self):
        row = self.profile_row()
        del row["executables"]["linker"]
        package = self.install_profiles([row])
        with self.assertRaises(core.ProcessFailure):
            core._select_profile(package, "synthetic-profile", deadline=68.0, clock=self.clock)

    def test_profile_bytes_are_taken_from_verified_package_not_reread_after_drift(self):
        package = self.install_profiles([self.profile_row()])
        (self.package_root / "capability_process_profiles.json").write_bytes(b"unverified replacement\n")
        selected = self.succeed(lambda: core._select_profile(
            package, "synthetic-profile", deadline=68.0, clock=self.clock))
        self.assertEqual(selected.executables["git"], self.selected)
        # Selection uses the captured bytes; affected launch still requires the
        # complete package recheck, which must reject the changed disk member.
        with self.assertRaises(core.ProcessFailure):
            self.verify()

    def test_malformed_and_overdeep_profile_data_refuses(self):
        valid = json.dumps({"schema_version": 1, "profiles": [self.profile_row()]}).encode()
        cases = [valid.replace(b'"schema_version": 1', b'"schema_version": 1,"schema_version":1'),
                 valid.replace(b'"schema_version": 1', b'"schema_version": true'),
                 b'{"schema_version":1,"profiles":' + b"[" * 17 + b"0" + b"]" * 17 + b"}"]
        for index, raw in enumerate(cases):
            with self.subTest(case=index):
                (self.package_root / "capability_process_profiles.json").write_bytes(raw)
                self.write_manifest()
                package = self.succeed(self.verify)
                with self.assertRaises(core.ProcessFailure):
                    core._select_profile(package, "synthetic-profile", deadline=68.0, clock=self.clock)

    def test_oversized_profile_member_cannot_reach_selection(self):
        (self.package_root / "capability_process_profiles.json").write_bytes(b" " * (1024 * 1024 + 1))
        self.write_manifest()
        with self.assertRaises(core.ProcessFailure):
            self.verify()


class HelpBinaryBindingTests(AdmissionFixture):
    def assert_parent_close_boundary_refuses(self, reason):
        original_open, original_close = os.open, os.close
        parents = []
        closed = []

        def open_parent(path, flags, *args, **kwargs):
            descriptor = original_open(path, flags, *args, **kwargs)
            if Path(path) == self.build_root:
                parents.append(descriptor)
            return descriptor

        def close(descriptor):
            original_close(descriptor)
            if descriptor in parents:
                closed.append(descriptor)
                if reason == "deadline":
                    self.clock.now = 72.0
                else:
                    self.value._latch_cancellation(None, None)

        with mock.patch.object(core.os, "open", side_effect=open_parent):
            with mock.patch.object(core.os, "close", side_effect=close):
                with self.assertRaises(core.ProcessFailure) as raised:
                    self.bind()
        self.assertEqual(raised.exception.reason, reason)
        self.assertEqual(len(parents), 1)
        self.assertEqual(closed, parents)
        self.assertEqual(self.value._help_executables, {})
        with self.subTest(check="poison-state"):
            self.assertEqual(self.value.state, "poisoned")
        with self.subTest(check="persistent-failure"):
            self.assertTrue(self.value._failed)
        with self.subTest(check="final-checkout-refused"):
            self.assertFalse(self.value.can_validate_final_checkout)
        with mock.patch.object(core.os, "open", side_effect=AssertionError("retry opened file")) as opened:
            with self.subTest(check="retry-refused-before-open"):
                with self.assertRaises(core.ProcessFailure):
                    self.bind(deadline=self.clock.now + 60.0)
                opened.assert_not_called()
        self.assertEqual(self.value._help_executables, {})
        self.popen.assert_not_called()
        self.signal.assert_not_called()

    def test_help_parent_close_at_deadline_poisons_without_binding_or_retry(self):
        self.assert_parent_close_boundary_refuses("deadline")

    def test_help_parent_close_cancellation_poisons_without_binding_or_retry(self):
        self.assert_parent_close_boundary_refuses("cancelled")

    def test_same_byte_inode_replacement_cannot_rebind_prior_identity(self):
        original = self.succeed(self.bind)
        replacement = self.build_root / "replacement"
        replacement.write_bytes(self.binary.read_bytes())
        replacement.chmod(0o700)
        replacement.replace(self.binary)
        self.assertNotEqual(identity(self.binary).inode, original.inode)
        self.assertEqual(identity(self.binary).sha256, original.sha256)
        with self.assertRaises(core.ProcessFailure):
            self.bind()
        self.assertEqual(self.value.state, "poisoned")
        self.assertFalse(self.value.can_validate_final_checkout)

    def setUp(self):
        super().setUp()
        self.value = self.ready_session()
        self.build_root = self.root / "build"
        self.build_root.mkdir(mode=0o700)
        self.binary = self.build_root / "apple"
        self.binary.write_bytes(b"synthetic help executable, never run\n")
        self.binary.chmod(0o700)
        self.expected = hashlib.sha256(self.binary.read_bytes()).hexdigest()

    def bind(self, **changes):
        arguments = dict(build_root=self.build_root, expected_sha256=self.expected, deadline=72.0)
        arguments.update(changes)
        return self.value.bind_help_executable(self.binary, **arguments)

    def test_regular_confined_binary_binds_complete_identity_without_launch(self):
        result = self.succeed(self.bind)
        self.assertEqual(result, identity(self.binary))
        self.assertEqual(self.value._help_executables[str(self.binary)], result)
        self.assertEqual(self.value.state, "ready")
        self.popen.assert_not_called()
        self.signal.assert_not_called()

    def test_wrong_content_hash_does_not_bind(self):
        with self.assertRaises(core.ProcessFailure):
            self.bind(expected_sha256="4" * 64)
        self.assertEqual(self.value._help_executables, {})

    def test_leaf_symlink_with_same_bytes_refuses(self):
        target = self.root / "synthetic-binary-target"
        self.binary.rename(target)
        self.binary.symlink_to(target)
        with self.assertRaises(core.ProcessFailure):
            self.bind()
        self.assertEqual(self.value._help_executables, {})

    def test_outside_build_root_refuses(self):
        outside = self.root / "other-build"
        outside.mkdir()
        with self.assertRaises(core.ProcessFailure):
            self.bind(build_root=outside)
        self.assertEqual(self.value._help_executables, {})

    def test_non_executable_regular_file_refuses(self):
        self.binary.chmod(0o600)
        with self.assertRaises(core.ProcessFailure):
            self.bind()
        self.assertEqual(self.value._help_executables, {})

    def test_sparse_oversized_binary_refuses_before_payload_open(self):
        with self.binary.open("wb") as stream:
            stream.truncate(256 * 1024 * 1024 + 1)
        original_open = os.open
        opened = []

        def open_leaf(path, flags, *args, **kwargs):
            if Path(path).name == "apple":
                opened.append(path)
                raise AssertionError("oversized binary must refuse before open")
            return original_open(path, flags, *args, **kwargs)

        with mock.patch.object(core.os, "open", side_effect=open_leaf):
            with self.assertRaises(core.ProcessFailure):
                self.bind()
        self.assertEqual(opened, [])

    def test_help_capture_open_cannot_block_on_replacement_fifo(self):
        original_open = os.open
        observed = []

        def open_leaf(path, flags, *args, **kwargs):
            if Path(path).name == "apple" and flags & os.O_ACCMODE == os.O_RDONLY:
                observed.append(flags)
                if not flags & os.O_NONBLOCK:
                    raise core.ProcessFailure("identity-drift")
                self.binary.unlink()
                os.mkfifo(self.binary, mode=0o600)
            return original_open(path, flags, *args, **kwargs)

        with mock.patch.object(core.os, "open", side_effect=open_leaf):
            with self.assertRaises(core.ProcessFailure):
                self.bind()
        self.assertEqual(len(observed), 1)
        self.assertTrue(observed[0] & os.O_NONBLOCK)
        self.assertEqual(self.value._help_executables, {})

    def test_expired_original_deadline_refuses_before_open(self):
        with mock.patch.object(core.os, "open", side_effect=AssertionError("expired open")) as opened:
            with self.assertRaises(core.ProcessFailure) as raised:
                self.bind(deadline=self.clock.now)
        self.assertEqual(raised.exception.reason, "deadline")
        self.assertEqual(self.value._help_executables, {})
        opened.assert_not_called()

    def test_post_read_late_observation_cannot_bind_or_restart_deadline(self):
        original_read = os.read
        reads = []

        def read(descriptor, maximum):
            result = original_read(descriptor, maximum)
            reads.append(len(result))
            self.clock.now = 72.001
            return result

        with mock.patch.object(core.os, "read", side_effect=read):
            with self.assertRaises(core.ProcessFailure) as raised:
                self.bind()
        self.assertTrue(reads)
        self.assertEqual(raised.exception.reason, "deadline")
        self.assertEqual(self.value._help_executables, {})

    def test_changed_binary_cannot_reuse_old_bound_identity(self):
        original = self.succeed(self.bind)
        self.binary.write_bytes(b"different synthetic bytes\n")
        with self.assertRaises(core.ProcessFailure):
            self.bind()
        self.assertNotEqual(identity(self.binary), original)
        self.assertFalse(self.value.can_validate_final_checkout)
        self.assertEqual(self.value.state, "poisoned")
