import base64
from contextlib import redirect_stderr, redirect_stdout
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import ModuleType
from typing import Optional, Set
import unittest
from unittest import mock

from capability_session_fixtures import fixture_session, run_recorded_trusted


REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = REPO_ROOT / "scripts" / "ci" / "capability_schema.py"
POLICY_PATH = REPO_ROOT / "scripts" / "ci" / "capability_policy.py"
MANUAL_GENERATOR_PATH = REPO_ROOT / "scripts" / "gen-manual.py"


def load_module(
    path: Path, name: str, *, synthetic_runtime: bool = True
) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load capability module")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    if synthetic_runtime and path == POLICY_PATH and "synthetic_runner" in globals():
        module._default_runtime_runner = synthetic_runner
    return module


def named_argument(
    name: str,
    *,
    kind: str = "flag",
    optional: bool = True,
    repeating: bool = False,
) -> dict:
    preferred = {"kind": "long", "name": name}
    return {
        "abstract": f"Synthetic {name}.",
        "isOptional": optional,
        "isRepeating": repeating,
        "kind": kind,
        "names": [preferred],
        "parsingStrategy": "default",
        "preferredName": preferred,
        "shouldDisplay": True,
        "valueName": name,
    }


def positional_argument(value_name: str) -> dict:
    return {
        "abstract": f"Synthetic {value_name}.",
        "isOptional": False,
        "isRepeating": False,
        "kind": "positional",
        "parsingStrategy": "default",
        "shouldDisplay": True,
        "valueName": value_name,
    }


def framework_help_command() -> dict:
    return {
        "abstract": "Show subcommand help information.",
        "arguments": [
            {
                "isOptional": True,
                "isRepeating": True,
                "kind": "positional",
                "parsingStrategy": "default",
                "shouldDisplay": True,
                "valueName": "subcommands",
            },
            {
                "isOptional": True,
                "isRepeating": False,
                "kind": "flag",
                "names": [
                    {"kind": "short", "name": "h"},
                    {"kind": "long", "name": "help"},
                    {"kind": "longWithSingleDash", "name": "help"},
                ],
                "parsingStrategy": "default",
                "preferredName": {"kind": "long", "name": "help"},
                "shouldDisplay": False,
                "valueName": "help",
            },
            {
                "abstract": "Show the version.",
                "isOptional": True,
                "isRepeating": False,
                "kind": "flag",
                "names": [{"kind": "long", "name": "version"}],
                "parsingStrategy": "default",
                "preferredName": {"kind": "long", "name": "version"},
                "shouldDisplay": True,
                "valueName": "version",
            },
        ],
        "commandName": "help",
        "shouldDisplay": True,
        "superCommands": ["apple"],
    }


def sample_dump() -> dict:
    return {
        "serializationVersion": 0,
        "command": {
            "abstract": "Synthetic root.",
            "arguments": [named_argument("version")],
            "commandName": "apple",
            "shouldDisplay": True,
            "subcommands": [
                {
                    "abstract": "Synthetic child.",
                    "aliases": ["f"],
                    "arguments": [
                        named_argument("name", kind="option"),
                        positional_argument("input"),
                    ],
                    "commandName": "foo",
                    "shouldDisplay": True,
                    "superCommands": ["apple"],
                },
                framework_help_command(),
            ],
        },
    }


def nested_manual_dump() -> dict:
    leaf = {
        "abstract": "Synthetic leaf.",
        "arguments": [],
        "commandName": "leaf",
        "shouldDisplay": True,
        "superCommands": ["apple", "parent", "nested"],
    }
    nested = {
        "abstract": "Synthetic nested parent.",
        "arguments": [],
        "commandName": "nested",
        "shouldDisplay": True,
        "subcommands": [leaf],
        "superCommands": ["apple", "parent"],
    }
    parent = {
        "abstract": "Synthetic parent.",
        "arguments": [],
        "commandName": "parent",
        "shouldDisplay": True,
        "subcommands": [nested],
        "superCommands": ["apple"],
    }
    return {
        "serializationVersion": 0,
        "command": {
            "abstract": "Synthetic root.",
            "arguments": [],
            "commandName": "apple",
            "shouldDisplay": True,
            "subcommands": [parent, framework_help_command()],
        },
    }


def colliding_manual_dump() -> dict:
    dump = nested_manual_dump()
    nested = dump["command"]["subcommands"][0]["subcommands"][0]
    nested["subcommands"][0]["commandName"] = "index"
    return dump


def root_colliding_manual_dump() -> dict:
    dump = nested_manual_dump()
    dump["command"]["subcommands"] = [
        {
            "abstract": "Synthetic index child.",
            "arguments": [],
            "commandName": "index",
            "shouldDisplay": True,
            "superCommands": ["apple"],
        },
        framework_help_command(),
    ]
    return dump


EVIDENCE_ROLES = ("parser_help", "invalid_exit", "json_envelope", "behavior")


def write_json(path: Path, value: object, *, canonical: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if canonical:
        source = (
            json.dumps(
                value,
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            )
            + "\n"
        )
    else:
        source = json.dumps(value, indent=2, sort_keys=True) + "\n"
    path.write_text(source, encoding="utf-8")


def bindings_for_manifest(manifest: dict) -> list[dict]:
    """Explicit fixture construction, never an implicit repair during policy checks."""
    uses = {}
    for surfaces, is_argument in ((manifest["commands"], False), (manifest["arguments"], True)):
        for surface in surfaces:
            claim = {"command_id": surface["command_id"] if is_argument else surface["id"],
                     "argument_id": surface["id"] if is_argument else None}
            for role, references in surface["evidence"].items():
                for reference in references:
                    binding = uses.setdefault(reference, {"reference": reference, "role": role, "claims": []})
                    if binding["role"] != role:
                        raise ValueError("synthetic binding has mixed roles")
                    binding["claims"].append(claim)
    for binding in uses.values():
        binding["claims"].sort(key=lambda claim: (claim["command_id"], claim["argument_id"] is not None, claim["argument_id"] or ""))
    return [uses[reference] for reference in sorted(uses)]


def sync_fixture_bindings(fixture: dict) -> None:
    """Use only when a test intentionally constructs an internally valid candidate."""
    catalog = json.loads(fixture["test_catalog"].read_text(encoding="utf-8"))
    manifest = json.loads(fixture["manifest"].read_text(encoding="utf-8"))
    catalog["bindings"] = bindings_for_manifest(manifest)
    write_json(fixture["test_catalog"], catalog, canonical=True)


def write_candidate_fixture(root: Path, *, include_bats: bool = False) -> dict:
    policy = load_module(POLICY_PATH, f"capability_policy_fixture_{id(root)}")
    dump = sample_dump()
    manifest = policy.snapshot_manifest(dump)

    swift_path = root / "Tests" / "CapabilityTests.swift"
    swift_path.parent.mkdir(parents=True)
    symbols = ("testParser", "testInvalid", "testJSON", "testBehavior", "testAdditionalBehavior")
    swift_path.write_text(
        "\n".join(f"@Test func {symbol}() {{}}" for symbol in symbols) + "\n",
        encoding="utf-8",
    )
    swift_digest = hashlib.sha256(swift_path.read_bytes()).hexdigest()
    swift_ids = {
        role: f"swift:Tests/CapabilityTests.swift:{symbol}:1"
        for role, symbol in zip(EVIDENCE_ROLES, symbols)
    }
    catalog = {
        "schema_version": 2,
        "bindings": [],
        "tests": [
            {
                "file_sha256": swift_digest,
                "id": swift_ids[role],
                "occurrence": 1,
                "path": "Tests/CapabilityTests.swift",
                "runtime_id": f"SyntheticTests::{symbol}",
                "symbol": symbol,
                "tier": "logic",
            }
            for role, symbol in zip(EVIDENCE_ROLES, symbols)
        ],
    }

    additional_ref = "swift:Tests/CapabilityTests.swift:testAdditionalBehavior:1"
    catalog["tests"].append({
        "file_sha256": swift_digest, "id": additional_ref, "occurrence": 1,
        "path": "Tests/CapabilityTests.swift", "runtime_id": "SyntheticTests::testAdditionalBehavior",
        "symbol": "testAdditionalBehavior", "tier": "logic",
    })

    bats_title = "synthetic behavior"
    bats_title_digest = hashlib.sha256(bats_title.encode("utf-8")).hexdigest()
    bats_path = root / "bats" / "hosted" / "capability.bats"
    bats_path.parent.mkdir(parents=True)
    bats_path.write_text(
        f'#!/usr/bin/env bats\n\n@test "{bats_title}" {{\n  true\n}}\n',
        encoding="utf-8",
    )
    bats_ref = f"bats:hosted:bats/hosted/capability.bats:{bats_title_digest}"
    inventory = {
        "live": {"files": [], "test_count": 0},
        "schema_version": 1,
        "test_count": 1,
        "tiers": {
            "hosted": {
                "files": [
                    {
                        "file_sha256": hashlib.sha256(bats_path.read_bytes()).hexdigest(),
                        "ordered_title_sha256": [bats_title_digest],
                        "path": "bats/hosted/capability.bats",
                        "test_count": 1,
                    }
                ],
                "test_count": 1,
            },
            "local": {"files": [], "test_count": 0},
        },
    }

    origins = sorted([
        {
            "anchor": "<!-- capability-id: port:synthetic.root -->",
            "document": "docs/port-specs/synthetic.md",
            "id": "port:synthetic.root",
            "kind": "port-spec",
        },
        {
            "anchor": "<!-- capability-id: extra:synthetic.foo -->",
            "document": "docs/capability-extras.md",
            "id": "extra:synthetic.foo",
            "kind": "cli-extra",
        },
    ], key=lambda item: item["id"])
    (root / "docs" / "port-specs").mkdir(parents=True)
    (root / "docs" / "port-specs" / "synthetic.md").write_text(
        "# Synthetic\n\n<!-- capability-id: port:synthetic.root -->\n",
        encoding="utf-8",
    )
    (root / "docs" / "capability-extras.md").write_text(
        "# Extras\n\n<!-- capability-id: extra:synthetic.foo -->\n",
        encoding="utf-8",
    )
    (root / "docs" / "manual").mkdir(parents=True)
    (root / "docs" / "manual" / "index.md").write_text(
        "# apple\n\n`--version`\n", encoding="utf-8"
    )
    (root / "docs" / "manual" / "foo.md").write_text(
        "# apple foo\n\n`--name` `input`\n", encoding="utf-8"
    )

    for command in manifest["commands"]:
        command["origin_id"] = (
            "port:synthetic.root"
            if command["id"] == "apple"
            else "extra:synthetic.foo"
        )
        command["evidence"] = {
            role: [swift_ids[role]] for role in EVIDENCE_ROLES
        }
    for argument in manifest["arguments"]:
        argument["origin_id"] = (
            "port:synthetic.root"
            if argument["command_id"] == "apple"
            else "extra:synthetic.foo"
        )
        argument["evidence"] = {
            role: [swift_ids[role]] for role in EVIDENCE_ROLES
        }
    manifest["commands"][0]["evidence"]["behavior"].append(additional_ref)
    manifest["arguments"][-1]["evidence"]["behavior"].append(additional_ref)
    if include_bats:
        manifest["arguments"][-1]["evidence"]["behavior"].append(bats_ref)
    else:
        bats_path.unlink()
        inventory["test_count"] = 0
        inventory["tiers"]["hosted"] = {"files": [], "test_count": 0}
    catalog["bindings"] = bindings_for_manifest(manifest)
    for surface in [*manifest["commands"], *manifest["arguments"]]:
        for role in EVIDENCE_ROLES:
            surface["evidence"][role].sort()
    manifest["origins"] = origins
    manifest["counts"]["origins"] = len(origins)
    manifest["status"] = "curated"

    dump_path = root / "artifacts" / "dump.json"
    manifest_path = root / "docs" / "capabilities.json"
    catalog_path = root / "Tests" / "capability-tests.json"
    inventory_path = root / "bats" / "tier-inventory.json"
    write_json(dump_path, dump)
    write_json(manifest_path, manifest, canonical=True)
    write_json(catalog_path, catalog, canonical=True)
    write_json(inventory_path, inventory, canonical=True)

    subprocess.run(["git", "init", "-q", str(root)], check=True)
    subprocess.run(["git", "-C", str(root), "add", "."], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "-c",
            "user.name=Synthetic",
            "-c",
            "user.email=synthetic@example.com",
            "commit",
            "-qm",
            "test: synthetic fixture",
        ],
        check=True,
    )
    sha = subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
    ).strip()
    return {
        "bats_inventory": inventory_path,
        "dump": dump_path,
        "manifest": manifest_path,
        "repository_root": root,
        "sha": sha,
        "test_catalog": catalog_path,
    }


def commit_fixture(fixture: dict) -> None:
    root = fixture["repository_root"]
    subprocess.run(["git", "-C", str(root), "add", "."], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "-c",
            "user.name=Synthetic",
            "-c",
            "user.email=synthetic@example.com",
            "commit",
            "-qm",
            "test: mutate fixture",
        ],
        check=True,
    )
    fixture["sha"] = subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
    ).strip()


def mutate_manifest(fixture: dict, mutate) -> None:
    manifest = json.loads(fixture["manifest"].read_text(encoding="utf-8"))
    mutate(manifest)
    write_json(fixture["manifest"], manifest, canonical=True)
    commit_fixture(fixture)


def sort_supersedes(manifest: dict) -> None:
    manifest["supersedes"].sort(
        key=lambda item: (item["old"], item["new"], item["reason"])
    )


def self_supersede_swift_file(
    manifest: dict,
    swift_path: str,
    reason: str,
    *,
    exclude: Optional[Set[str]] = None,
) -> None:
    excluded = exclude or set()
    refs = sorted(
        {
            reference
            for surface in [*manifest["commands"], *manifest["arguments"]]
            for role in EVIDENCE_ROLES
            for reference in surface["evidence"][role]
            if reference.startswith(f"swift:{swift_path}:")
            and reference not in excluded
        }
    )
    manifest["supersedes"].extend(
        {"new": reference, "old": reference, "reason": reason}
        for reference in refs
    )
    sort_supersedes(manifest)


def add_local_bats(fixture: dict, title: str = "local synthetic behavior") -> str:
    title_digest = hashlib.sha256(title.encode("utf-8")).hexdigest()
    path = fixture["repository_root"] / "bats" / "local" / "capability.bats"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        f'#!/usr/bin/env bats\n\n@test "{title}" {{\n  true\n}}\n',
        encoding="utf-8",
    )
    inventory = json.loads(fixture["bats_inventory"].read_text(encoding="utf-8"))
    inventory["tiers"]["local"] = {
        "files": [
            {
                "file_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "ordered_title_sha256": [title_digest],
                "path": "bats/local/capability.bats",
                "test_count": 1,
            }
        ],
        "test_count": 1,
    }
    inventory["test_count"] = inventory["tiers"]["hosted"]["test_count"] + 1
    write_json(fixture["bats_inventory"], inventory, canonical=True)
    return f"bats:local:bats/local/capability.bats:{title_digest}"


def candidate_cli_arguments(fixture: dict, prefix: str = "") -> list[str]:
    option_prefix = f"{prefix}-" if prefix else ""
    sha_option = f"--expected-{prefix}-sha" if prefix else "--expected-sha"
    return [
        f"--{option_prefix}repository-root",
        str(fixture["repository_root"]),
        sha_option,
        fixture["sha"],
    ]


def synthetic_attestation(
    root: Path,
    sha: str,
    tree_oid: str,
    *,
    dump: Optional[object] = None,
    passed_runtime_ids: Optional[list[str]] = None,
    attested_sha: Optional[str] = None,
    attested_tree_oid: Optional[str] = None,
) -> bytes:
    runtime_dump = dump if dump is not None else json.loads(
        (root / "artifacts" / "dump.json").read_text(encoding="utf-8")
    )
    catalog = json.loads(
        (root / "Tests" / "capability-tests.json").read_text(encoding="utf-8")
    )
    passed = passed_runtime_ids
    if passed is None:
        passed = sorted(entry["runtime_id"] for entry in catalog["tests"])
    dump_payload = json.dumps(
        runtime_dump,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    value = {
        "binary_sha256": "0" * 64,
        "contract": "apple-cli-capability-runtime-v1",
        "dump_base64": base64.b64encode(dump_payload).decode("ascii"),
        "dump_sha256": hashlib.sha256(dump_payload).hexdigest(),
        "passed_swift_runtime_ids": passed,
        "schema_version": 1,
        "sha": attested_sha if attested_sha is not None else sha,
        "tree_oid": (
            attested_tree_oid if attested_tree_oid is not None else tree_oid
        ),
    }
    return (
        json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        + "\n"
    ).encode("utf-8")


def synthetic_runner(root: Path, sha: str, tree_oid: str, *, process_session) -> bytes:
    return synthetic_attestation(root, sha, tree_oid)


def candidate_input(fixture: dict) -> dict:
    return {
        "repository_root": fixture["repository_root"],
        "sha": fixture["sha"],
    }


def run_policy_main(policy, arguments: list[str], *, process_session=None) -> subprocess.CompletedProcess:
    stdout = io.StringIO()
    stderr = io.StringIO()
    with redirect_stdout(stdout), redirect_stderr(stderr):
        return_code = (policy.main(arguments) if process_session is None else
                       run_recorded_trusted(policy, arguments, process_session))
    return subprocess.CompletedProcess(
        arguments,
        return_code,
        stdout.getvalue(),
        stderr.getvalue(),
    )


class CapabilityPolicyBootstrapTests(unittest.TestCase):
    def test_policy_entrypoints_exist(self) -> None:
        self.assertTrue(SCHEMA_PATH.is_file())
        self.assertTrue(POLICY_PATH.is_file())

    def test_strict_json_rejects_duplicate_keys(self) -> None:
        schema = load_module(SCHEMA_PATH, "capability_schema_duplicate")
        self.assertTrue(hasattr(schema, "parse_json_bytes"))

        with self.assertRaisesRegex(schema.SchemaError, "json-duplicate-key"):
            schema.parse_json_bytes(b'{"schema_version":1,"schema_version":1}')

    def test_strict_json_rejects_excessive_depth(self) -> None:
        schema = load_module(SCHEMA_PATH, "capability_schema_depth")
        payload = ("[" * 70 + "0" + "]" * 70).encode("utf-8")

        with self.assertRaisesRegex(schema.SchemaError, "json-depth"):
            schema.parse_json_bytes(payload)

    def test_strict_json_rejects_nonstandard_numeric_constants(self) -> None:
        schema = load_module(SCHEMA_PATH, "capability_schema_numbers")

        with self.assertRaisesRegex(schema.SchemaError, "json-invalid"):
            schema.parse_json_bytes(b'{"value":NaN}')

    def test_strict_json_bounds_integer_tokens_and_rejects_floats(self) -> None:
        schema = load_module(SCHEMA_PATH, "capability_schema_numeric_bounds")

        with self.assertRaisesRegex(schema.SchemaError, "json-number"):
            schema.parse_json_bytes(b'{"value":' + b"9" * 5000 + b"}")
        with self.assertRaisesRegex(schema.SchemaError, "json-number"):
            schema.parse_json_bytes(b'{"value":1.5}')

    def test_strict_json_rejects_unpaired_unicode_surrogates(self) -> None:
        schema = load_module(SCHEMA_PATH, "capability_schema_unicode")

        with self.assertRaisesRegex(schema.SchemaError, "json-invalid-unicode"):
            schema.parse_json_bytes(b'{"value":"\\ud800"}')

    def test_bounded_reader_rejects_symlink_nonregular_and_oversized_inputs(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_reader")
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory).resolve()
            target = root / "target.json"
            target.write_text("{}\n", encoding="utf-8")
            link = root / "link.json"
            link.symlink_to(target)
            directory = root / "directory.json"
            directory.mkdir()

            with self.assertRaisesRegex(policy.PolicyError, "input-not-regular"):
                policy._read_regular_bytes(link)
            with self.assertRaisesRegex(policy.PolicyError, "input-not-regular"):
                policy._read_regular_bytes(directory)
            with self.assertRaisesRegex(policy.PolicyError, "input-too-large"):
                policy._read_regular_bytes(target, maximum=2)

    def test_snapshot_is_canonical_and_excludes_only_framework_help(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_snapshot")
        self.assertTrue(hasattr(policy, "snapshot_manifest"))

        snapshot = policy.snapshot_manifest(sample_dump())
        encoded = policy.canonical_json(snapshot)

        self.assertEqual(encoded, policy.canonical_json(json.loads(encoded)))
        self.assertEqual(snapshot["contract_stage"], "command-arguments")
        self.assertEqual(snapshot["status"], "draft")
        self.assertEqual(
            [command["id"] for command in snapshot["commands"]],
            ["apple", "apple foo"],
        )
        self.assertEqual(snapshot["counts"], {"arguments": 3, "commands": 2, "origins": 0})

    def test_manual_paths_match_generated_parent_and_leaf_layout(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_manual_parent_paths")

        snapshot = policy.snapshot_manifest(nested_manual_dump())
        paths = {
            command["id"]: command["manual"]["path"]
            for command in snapshot["commands"]
        }

        self.assertEqual(
            paths,
            {
                "apple": "docs/manual/index.md",
                "apple parent": "docs/manual/parent/index.md",
                "apple parent nested": "docs/manual/parent/nested/index.md",
                "apple parent nested leaf": "docs/manual/parent/nested/leaf.md",
            },
        )
        self.assertEqual(
            policy._manual_path(["apple", "unknown"]),
            "docs/manual/unknown.md",
        )

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory).resolve()
            for command in snapshot["commands"]:
                manual = root / command["manual"]["path"]
                manual.parent.mkdir(parents=True, exist_ok=True)
                manual.write_text(command["id"] + "\n", encoding="utf-8")

            policy._validate_manual(root, snapshot)

    def test_manual_path_collisions_fail_before_snapshot_or_manual_reads(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_manual_path_collision")

        cases = (
            ("root", root_colliding_manual_dump()),
            ("nested", colliding_manual_dump()),
        )
        for label, dump in cases:
            with self.subTest(label=label), self.assertRaisesRegex(
                policy.PolicyError,
                "^manual-path-collision$",
            ):
                policy.snapshot_manifest(dump)

        manifest = policy.snapshot_manifest(nested_manual_dump())
        leaf = next(
            command
            for command in manifest["commands"]
            if command["id"] == "apple parent nested leaf"
        )
        leaf["id"] = "apple parent nested index"
        leaf["name"] = "index"
        leaf["path"] = ["apple", "parent", "nested", "index"]
        leaf["manual"] = {
            "path": "docs/manual/parent/nested/index.md",
            "tokens": ["apple parent nested index"],
        }
        manifest["commands"].sort(key=lambda command: command["id"])

        with self.assertRaisesRegex(policy.PolicyError, "^manual-path-collision$"):
            policy._validate_manual(Path("/does-not-exist"), manifest)

    def test_manual_generator_rejects_collisions_before_replacing_output(self) -> None:
        generator = load_module(
            MANUAL_GENERATOR_PATH,
            "capability_policy_manual_generator_collision",
            synthetic_runtime=False,
        )
        cases = (
            ("root", root_colliding_manual_dump()),
            ("nested", colliding_manual_dump()),
        )
        for label, dump in cases:
            with (
                self.subTest(label=label),
                tempfile.TemporaryDirectory() as temporary_directory,
            ):
                root = Path(temporary_directory).resolve()
                output = root / "docs" / "manual"
                output.mkdir(parents=True)
                sentinel = output / "sentinel.txt"
                sentinel.write_text("preserve\n", encoding="utf-8")

                with (
                    mock.patch.object(generator, "REPO", root),
                    mock.patch.object(generator, "OUT", output),
                    mock.patch.object(
                        generator,
                        "SIDECAR",
                        root / "docs" / "manual-prose.json",
                    ),
                    mock.patch.object(generator, "dump_help", return_value=dump["command"]),
                    mock.patch.object(
                        sys,
                        "argv",
                        ["gen-manual.py", "--binary", "synthetic"],
                    ),
                    redirect_stdout(io.StringIO()),
                    self.assertRaisesRegex(SystemExit, "manual-page-path-collision"),
                ):
                    generator.main()

                self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve\n")

    def test_framework_help_exclusion_requires_the_exact_synthetic_shape(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_framework_help")
        dump = sample_dump()
        help_command = dump["command"]["subcommands"][-1]
        help_command["abstract"] = "Product-defined help behavior."

        with self.assertRaisesRegex(policy.PolicyError, "dump-framework-help-invalid"):
            policy.snapshot_manifest(dump)

    def test_runtime_dump_requires_the_synthetic_framework_help_command(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_framework_help_missing")
        dump = sample_dump()
        dump["command"]["subcommands"] = [
            command
            for command in dump["command"]["subcommands"]
            if command["commandName"] != "help"
        ]

        with self.assertRaisesRegex(policy.PolicyError, "dump-framework-help-missing"):
            policy.snapshot_manifest(dump)

    def test_current_stage_reserves_but_does_not_accept_future_contracts(self) -> None:
        schema = load_module(SCHEMA_PATH, "capability_schema_future")
        policy = load_module(POLICY_PATH, "capability_policy_future")
        snapshot = policy.snapshot_manifest(sample_dump())
        self.assertIn("future_contracts", snapshot)
        self.assertEqual(
            snapshot["future_contracts"],
            {"output_fields": [], "validation_surfaces": []},
        )
        schema.validate_manifest(snapshot)
        snapshot["future_contracts"]["output_fields"].append({"id": "not-yet-supported"})

        with self.assertRaisesRegex(schema.SchemaError, "manifest-future-contracts"):
            schema.validate_manifest(snapshot)

    def test_manifest_schema_rejects_unknown_root_keys(self) -> None:
        schema = load_module(SCHEMA_PATH, "capability_schema_unknown")
        policy = load_module(POLICY_PATH, "capability_policy_unknown")
        manifest = policy.snapshot_manifest(sample_dump())
        manifest["unexpected"] = True
        self.assertTrue(hasattr(schema, "validate_manifest"))

        with self.assertRaisesRegex(schema.SchemaError, "manifest-root-fields"):
            schema.validate_manifest(manifest)

    def test_manifest_schema_rejects_boolean_version_and_wrong_stage(self) -> None:
        schema = load_module(SCHEMA_PATH, "capability_schema_types")
        policy = load_module(POLICY_PATH, "capability_policy_types")
        manifest = policy.snapshot_manifest(sample_dump())
        manifest["schema_version"] = True

        with self.assertRaisesRegex(schema.SchemaError, "manifest-version"):
            schema.validate_manifest(manifest)

        manifest["schema_version"] = 1
        manifest["contract_stage"] = "full-contract"
        with self.assertRaisesRegex(schema.SchemaError, "manifest-stage"):
            schema.validate_manifest(manifest)

    def test_manifest_schema_recomputes_counts(self) -> None:
        schema = load_module(SCHEMA_PATH, "capability_schema_counts")
        policy = load_module(POLICY_PATH, "capability_policy_counts")
        manifest = policy.snapshot_manifest(sample_dump())
        manifest["counts"]["commands"] = 99

        with self.assertRaisesRegex(schema.SchemaError, "manifest-counts"):
            schema.validate_manifest(manifest)

    def test_manifest_schema_requires_explicit_draft_or_curated_status(self) -> None:
        schema = load_module(SCHEMA_PATH, "capability_schema_status")
        policy = load_module(POLICY_PATH, "capability_policy_status")
        manifest = policy.snapshot_manifest(sample_dump())
        manifest["status"] = 1

        with self.assertRaisesRegex(schema.SchemaError, "manifest-status"):
            schema.validate_manifest(manifest)

        manifest["status"] = []
        with self.assertRaisesRegex(schema.SchemaError, "manifest-status"):
            schema.validate_manifest(manifest)

    def test_manifest_schema_validates_command_identity_types(self) -> None:
        schema = load_module(SCHEMA_PATH, "capability_schema_command_shape")
        policy = load_module(POLICY_PATH, "capability_policy_command_shape")
        manifest = policy.snapshot_manifest(sample_dump())
        manifest["commands"][0]["path"] = "apple"

        with self.assertRaisesRegex(schema.SchemaError, "manifest-command-shape"):
            schema.validate_manifest(manifest)

    def test_manifest_schema_validates_argument_identity_and_structure(self) -> None:
        schema = load_module(SCHEMA_PATH, "capability_schema_argument_structure")
        policy = load_module(POLICY_PATH, "capability_policy_argument_structure")
        manifest = policy.snapshot_manifest(sample_dump())
        manifest["arguments"][0]["structure"]["unexpected"] = True

        with self.assertRaisesRegex(schema.SchemaError, "manifest-argument-structure"):
            schema.validate_manifest(manifest)

    def test_manifest_schema_fail_closes_on_unhashable_nested_types(self) -> None:
        schema = load_module(SCHEMA_PATH, "capability_schema_unhashable")
        policy = load_module(POLICY_PATH, "capability_policy_unhashable")
        mutations = (
            lambda value: value["arguments"][0].__setitem__("command_id", []),
            lambda value: value["arguments"][0]["structure"].__setitem__("kind", []),
            lambda value: value["arguments"][0]["structure"].__setitem__(
                "parsing_strategy", []
            ),
            lambda value: value["arguments"][0]["structure"]["names"][0].__setitem__(
                "kind", []
            ),
        )
        for mutation in mutations:
            manifest = policy.snapshot_manifest(sample_dump())
            mutation(manifest)
            with self.assertRaises(schema.SchemaError):
                schema.validate_manifest(manifest)

    def test_manifest_schema_requires_deterministic_origin_order(self) -> None:
        schema = load_module(SCHEMA_PATH, "capability_schema_origin_order")
        policy = load_module(POLICY_PATH, "capability_policy_origin_order")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            manifest = json.loads(fixture["manifest"].read_text(encoding="utf-8"))
        manifest["origins"].reverse()

        with self.assertRaisesRegex(schema.SchemaError, "manifest-origin-order"):
            schema.validate_manifest(manifest)

    def test_manifest_schema_validates_and_orders_supersedes_records(self) -> None:
        schema = load_module(SCHEMA_PATH, "capability_schema_supersedes")
        policy = load_module(POLICY_PATH, "capability_policy_supersedes")
        manifest = policy.snapshot_manifest(sample_dump())
        manifest["supersedes"] = [
            {
                "new": "swift:Tests/New.swift:testNew:1",
                "old": "swift:Tests/Old.swift:testOld:1",
                "reason": 7,
            }
        ]

        with self.assertRaisesRegex(schema.SchemaError, "manifest-supersedes-shape"):
            schema.validate_manifest(manifest)

    def test_runtime_dump_rejects_unknown_keys_and_hidden_commands(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_dump_fields")
        dump = sample_dump()
        dump["unexpected"] = None
        with self.assertRaisesRegex(policy.PolicyError, "dump-root-fields"):
            policy.snapshot_manifest(dump)

        dump = sample_dump()
        dump["command"]["subcommands"][0]["shouldDisplay"] = False
        with self.assertRaisesRegex(policy.PolicyError, "dump-hidden-surface"):
            policy.snapshot_manifest(dump)

    def test_runtime_dump_requires_exact_root_and_serialization_version(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_root_identity")
        dump = sample_dump()
        dump["serializationVersion"] = False
        with self.assertRaisesRegex(policy.PolicyError, "dump-root-invalid"):
            policy.snapshot_manifest(dump)

        dump = sample_dump()
        dump["command"]["commandName"] = "pear"
        with self.assertRaisesRegex(policy.PolicyError, "dump-root-command-invalid"):
            policy.snapshot_manifest(dump)

    def test_curated_candidate_checks_command_argument_stage(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_valid")
        self.assertTrue(hasattr(policy, "check_candidate"))
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())

            report = policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

        self.assertTrue(report["ok"])
        self.assertEqual(report["contract_stage"], "command-arguments")
        self.assertEqual(report["counts"], {"arguments": 3, "commands": 2, "origins": 2})
        self.assertNotIn("outputs", report)
        self.assertNotIn("validations", report)

    def test_manual_live_inventory_files_are_not_capability_evidence(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_live_inventory")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            live_path = fixture["repository_root"] / "bats" / "live" / "manual.sh"
            live_path.parent.mkdir(parents=True)
            live_path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            inventory = json.loads(
                fixture["bats_inventory"].read_text(encoding="utf-8")
            )
            inventory["live"] = {
                "files": ["bats/live/manual.sh"],
                "test_count": 0,
            }
            write_json(fixture["bats_inventory"], inventory, canonical=True)
            commit_fixture(fixture)

            report = policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

        self.assertTrue(report["ok"])

    def test_supplied_bats_inventory_keeps_its_owned_pretty_json_format(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_bats_format")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve(), include_bats=True)
            inventory = json.loads(
                fixture["bats_inventory"].read_text(encoding="utf-8")
            )
            write_json(fixture["bats_inventory"], inventory, canonical=False)
            commit_fixture(fixture)

            # Pretty inventory bytes validate; declaration-only evidence still
            # cannot pass the new execution-admission boundary.
            with self.assertRaisesRegex(policy.PolicyError, "^bats-execution-unavailable$"):
                policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

    def test_bats_evidence_titles_must_match_hardened_source_declarations(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_bats_titles")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve(), include_bats=True)
            invented_digest = hashlib.sha256(b"invented title").hexdigest()
            inventory = json.loads(
                fixture["bats_inventory"].read_text(encoding="utf-8")
            )
            entry = inventory["tiers"]["hosted"]["files"][0]
            old_digest = entry["ordered_title_sha256"][0]
            entry["ordered_title_sha256"] = [invented_digest]
            write_json(fixture["bats_inventory"], inventory, canonical=True)
            manifest = json.loads(fixture["manifest"].read_text(encoding="utf-8"))
            old_ref = f"bats:hosted:bats/hosted/capability.bats:{old_digest}"
            new_ref = f"bats:hosted:bats/hosted/capability.bats:{invented_digest}"
            for argument in manifest["arguments"]:
                argument["evidence"]["behavior"] = [
                    new_ref if reference == old_ref else reference
                    for reference in argument["evidence"]["behavior"]
                ]
            write_json(fixture["manifest"], manifest, canonical=True)
            commit_fixture(fixture)

            with self.assertRaisesRegex(policy.PolicyError, "bats-inventory-title-drift"):
                policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

    def test_manual_tokens_must_name_the_exact_command_or_argument(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_manual_identity")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            mutate_manifest(
                fixture,
                lambda manifest: manifest["arguments"][0].__setitem__(
                    "manual_tokens", ["apple foo"]
                ),
            )

            with self.assertRaisesRegex(policy.PolicyError, "manual-identity-missing"):
                policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

    def test_manual_path_is_derived_from_the_exact_command_path(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_manual_path")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            alternate = fixture["repository_root"] / "docs" / "manual" / "alternate.md"
            alternate.write_text(
                "# apple foo\n\n`--name` `input`\n",
                encoding="utf-8",
            )
            manifest = json.loads(fixture["manifest"].read_text(encoding="utf-8"))
            foo = next(command for command in manifest["commands"] if command["id"] == "apple foo")
            foo["manual"]["path"] = "docs/manual/alternate.md"
            write_json(fixture["manifest"], manifest, canonical=True)
            commit_fixture(fixture)

            with self.assertRaisesRegex(policy.PolicyError, "manual-path-invalid"):
                policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

    def test_documented_capability_anchors_cannot_be_orphaned(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_origin_anchor_orphan")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            document = fixture["repository_root"] / "docs" / "capability-extras.md"
            document.write_text(
                document.read_text(encoding="utf-8")
                + "\n<!-- capability-id: extra:synthetic.orphan -->\n",
                encoding="utf-8",
            )
            commit_fixture(fixture)

            with self.assertRaisesRegex(policy.PolicyError, "origin-anchor-orphan"):
                policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

    def test_origin_document_scan_is_bounded(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_origin_bounds")
        self.assertTrue(hasattr(policy, "MAX_ORIGIN_DOCUMENTS"))
        policy.MAX_ORIGIN_DOCUMENTS = 1
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())

            with self.assertRaisesRegex(policy.PolicyError, "origin-documents-too-large"):
                policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

    def test_swift_evidence_ids_must_resolve_to_test_declarations(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_swift_test_symbol")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            swift_path = fixture["repository_root"] / "Tests" / "CapabilityTests.swift"
            swift_path.write_text(
                swift_path.read_text(encoding="utf-8") + "func helperOnly() {}\n",
                encoding="utf-8",
            )
            digest = hashlib.sha256(swift_path.read_bytes()).hexdigest()
            catalog = json.loads(fixture["test_catalog"].read_text(encoding="utf-8"))
            for entry in catalog["tests"]:
                entry["file_sha256"] = digest
            helper_id = "swift:Tests/CapabilityTests.swift:helperOnly:1"
            catalog["tests"].append(
                {
                    "file_sha256": digest,
                    "id": helper_id,
                    "occurrence": 1,
                    "path": "Tests/CapabilityTests.swift",
                    "runtime_id": "SyntheticTests::helperOnly",
                    "symbol": "helperOnly",
                    "tier": "logic",
                }
            )
            write_json(fixture["test_catalog"], catalog, canonical=True)
            manifest = json.loads(fixture["manifest"].read_text(encoding="utf-8"))
            manifest["commands"][0]["evidence"]["behavior"].append(helper_id)
            write_json(fixture["manifest"], manifest, canonical=True)
            commit_fixture(fixture)

            with self.assertRaisesRegex(policy.PolicyError, "test-catalog-symbol-not-test"):
                policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

    def test_swift_evidence_resolves_multiline_test_attributes(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_swift_multiline")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            swift_path = fixture["repository_root"] / "Tests" / "CapabilityTests.swift"
            swift_path.write_text(
                swift_path.read_text(encoding="utf-8")
                + '@Test(\n  "synthetic multiline"\n)\nfunc testMultiline() {}\n',
                encoding="utf-8",
            )
            digest = hashlib.sha256(swift_path.read_bytes()).hexdigest()
            catalog = json.loads(fixture["test_catalog"].read_text(encoding="utf-8"))
            for entry in catalog["tests"]:
                entry["file_sha256"] = digest
            multiline_id = "swift:Tests/CapabilityTests.swift:testMultiline:1"
            catalog["tests"].append(
                {
                    "file_sha256": digest,
                    "id": multiline_id,
                    "occurrence": 1,
                    "path": "Tests/CapabilityTests.swift",
                    "runtime_id": "SyntheticTests::testMultiline",
                    "symbol": "testMultiline",
                    "tier": "logic",
                }
            )
            write_json(fixture["test_catalog"], catalog, canonical=True)
            manifest = json.loads(fixture["manifest"].read_text(encoding="utf-8"))
            manifest["commands"][0]["evidence"]["behavior"].append(multiline_id)
            write_json(fixture["manifest"], manifest, canonical=True)
            sync_fixture_bindings(fixture)
            commit_fixture(fixture)

            report = policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

        self.assertTrue(report["ok"])

    def test_swift_evidence_ids_disambiguate_duplicate_symbols_by_occurrence(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_swift_occurrence")
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory).resolve()
            source_path = root / "Tests" / "DuplicateTests.swift"
            source_path.parent.mkdir(parents=True)
            source_path.write_text(
                '@Test("first") func sameName() {}\n'
                '@Test("second") func sameName() {}\n',
                encoding="utf-8",
            )
            digest = hashlib.sha256(source_path.read_bytes()).hexdigest()
            catalog = {
                "schema_version": 2,
                "bindings": [],
                "tests": [
                    {
                        "file_sha256": digest,
                        "id": f"swift:Tests/DuplicateTests.swift:sameName:{occurrence}",
                        "occurrence": occurrence,
                        "path": "Tests/DuplicateTests.swift",
                        "runtime_id": f"SyntheticTests{occurrence}::sameName",
                        "symbol": "sameName",
                        "tier": "logic",
                    }
                    for occurrence in (1, 2)
                ],
            }

            resolved = policy._swift_catalog(root, catalog)

        self.assertEqual(set(resolved), {entry["id"] for entry in catalog["tests"]})

    def test_evidence_catalog_versions_reject_boolean_integers(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_catalog_versions")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            catalog = json.loads(fixture["test_catalog"].read_text(encoding="utf-8"))
            catalog["schema_version"] = True
            write_json(fixture["test_catalog"], catalog, canonical=True)
            commit_fixture(fixture)
            with self.assertRaisesRegex(policy.PolicyError, "test-catalog-invalid"):
                policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            inventory = json.loads(fixture["bats_inventory"].read_text(encoding="utf-8"))
            inventory["schema_version"] = True
            write_json(fixture["bats_inventory"], inventory, canonical=True)
            commit_fixture(fixture)
            with self.assertRaisesRegex(policy.PolicyError, "bats-inventory-invalid"):
                policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

    def test_checkout_validation_disables_repository_configured_fsmonitor(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_fsmonitor")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            marker = fixture["repository_root"] / ".git" / "fsmonitor-ran"
            hook = fixture["repository_root"] / ".git" / "synthetic-fsmonitor.sh"
            hook.write_text(
                f"#!/bin/sh\ntouch '{marker}'\nexit 0\n",
                encoding="utf-8",
            )
            hook.chmod(0o700)
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(fixture["repository_root"]),
                    "config",
                    "core.fsmonitor",
                    str(hook),
                ],
                check=True,
            )

            report = policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

            self.assertTrue(report["ok"])
            self.assertFalse(marker.exists(), "policy must not execute repository-configured helpers")

    def test_git_subprocess_output_is_bounded(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_git_output_bound")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            for index in range(8):
                path = fixture["repository_root"] / f"untracked-{index}.txt"
                path.write_text("synthetic\n", encoding="utf-8")
            policy.MAX_GIT_OUTPUT_BYTES = 32

            with self.assertRaisesRegex(policy.PolicyError, "checkout-output-too-large"):
                policy._run_git(
                    fixture["repository_root"],
                    "status",
                    "--porcelain=v1",
                    "-z",
                    process_session=fixture_session(policy, fixture),
                )

    def test_manifest_rejects_unknown_nested_fields(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_nested_fields")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            mutate_manifest(
                fixture,
                lambda manifest: manifest["commands"][0].__setitem__("unexpected", True),
            )

            with self.assertRaisesRegex(policy.PolicyError, "manifest-command-fields"):
                policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

    def test_manifest_rejects_unknown_argument_origin_and_supersedes_fields(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_nested_more")
        mutations = (
            ("manifest-argument-fields", lambda value: value["arguments"][0].__setitem__("unexpected", True)),
            ("manifest-origin-fields", lambda value: value["origins"][0].__setitem__("unexpected", True)),
            (
                "manifest-supersedes-fields",
                lambda value: value["supersedes"].append(
                    {"old": "swift:Tests/Old.swift:testOld:1", "new": "swift:Tests/New.swift:testNew:1"}
                ),
            ),
        )
        for diagnostic, mutation in mutations:
            with self.subTest(diagnostic=diagnostic), tempfile.TemporaryDirectory() as temporary_directory:
                fixture = write_candidate_fixture(Path(temporary_directory).resolve())
                mutate_manifest(fixture, mutation)
                with self.assertRaisesRegex(policy.PolicyError, diagnostic):
                    policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

    def test_every_surface_requires_every_nonempty_evidence_role(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_evidence_roles")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            mutate_manifest(
                fixture,
                lambda manifest: manifest["commands"][0]["evidence"].__setitem__(
                    "invalid_exit", []
                ),
            )

            with self.assertRaisesRegex(policy.PolicyError, "evidence-role-empty"):
                policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

    def test_evidence_references_have_deterministic_order(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_evidence_order")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            manifest = json.loads(fixture["manifest"].read_text(encoding="utf-8"))
            behavior = manifest["arguments"][-1]["evidence"]["behavior"]
            behavior.append(manifest["commands"][0]["evidence"]["parser_help"][0])
            manifest["arguments"][-1]["evidence"]["behavior"] = sorted(
                behavior,
                reverse=True,
            )
            write_json(fixture["manifest"], manifest, canonical=True)
            commit_fixture(fixture)

            with self.assertRaisesRegex(policy.PolicyError, "evidence-order"):
                policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

    def test_evidence_roles_fail_close_on_unhashable_references(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_evidence_unhashable")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            mutate_manifest(
                fixture,
                lambda manifest: manifest["commands"][0]["evidence"].__setitem__(
                    "behavior", [{}]
                ),
            )

            with self.assertRaisesRegex(policy.PolicyError, "evidence-role-empty"):
                policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

    def test_parser_exit_and_json_evidence_must_be_hosted_safe(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_hosted_evidence")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve(), include_bats=True)
            title = "local synthetic behavior"
            title_digest = hashlib.sha256(title.encode("utf-8")).hexdigest()
            path = fixture["repository_root"] / "bats" / "local" / "capability.bats"
            path.parent.mkdir(parents=True)
            path.write_text(
                f'#!/usr/bin/env bats\n\n@test "{title}" {{\n  true\n}}\n',
                encoding="utf-8",
            )
            inventory = json.loads(
                fixture["bats_inventory"].read_text(encoding="utf-8")
            )
            inventory["tiers"]["local"] = {
                "files": [
                    {
                        "file_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        "ordered_title_sha256": [title_digest],
                        "path": "bats/local/capability.bats",
                        "test_count": 1,
                    }
                ],
                "test_count": 1,
            }
            inventory["test_count"] = 2
            write_json(fixture["bats_inventory"], inventory, canonical=True)
            manifest = json.loads(fixture["manifest"].read_text(encoding="utf-8"))
            local_ref = f"bats:local:bats/local/capability.bats:{title_digest}"
            manifest["commands"][0]["evidence"]["parser_help"] = [local_ref]
            write_json(fixture["manifest"], manifest, canonical=True)
            commit_fixture(fixture)

            with self.assertRaisesRegex(policy.PolicyError, "evidence-not-hosted-safe"):
                policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

    def test_compare_accepts_two_exact_unchanged_candidates(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_compare_valid")
        self.assertTrue(hasattr(policy, "compare_candidates"))
        with tempfile.TemporaryDirectory() as base_directory, tempfile.TemporaryDirectory() as head_directory:
            base = write_candidate_fixture(Path(base_directory).resolve())
            head = write_candidate_fixture(Path(head_directory).resolve())

            report = policy.compare_candidates(base=candidate_input(base), head=candidate_input(head), process_session=fixture_session(policy, base, head))

        self.assertTrue(report["ok"])
        self.assertEqual(report["contract_stage"], "command-arguments")
        self.assertEqual(report["new_commands"], 0)
        self.assertEqual(report["new_arguments"], 0)

    def test_compare_normalizes_supplied_relative_checkout_roots(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_compare_relative")
        with tempfile.TemporaryDirectory() as base_directory, tempfile.TemporaryDirectory() as head_directory:
            base = write_candidate_fixture(Path(base_directory).resolve())
            head = write_candidate_fixture(Path(head_directory).resolve())
            base["repository_root"] = Path(
                os.path.relpath(base["repository_root"], Path.cwd())
            )
            head["repository_root"] = Path(
                os.path.relpath(head["repository_root"], Path.cwd())
            )

            report = policy.compare_candidates(base=candidate_input(base), head=candidate_input(head), process_session=fixture_session(policy, base, head))

        self.assertTrue(report["ok"])

    def test_compare_rejects_dirty_or_mismatched_exact_checkouts(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_compare_checkout")
        with tempfile.TemporaryDirectory() as base_directory, tempfile.TemporaryDirectory() as head_directory:
            base = write_candidate_fixture(Path(base_directory).resolve())
            head = write_candidate_fixture(Path(head_directory).resolve())
            head["sha"] = "0" * 40
            with self.assertRaisesRegex(policy.PolicyError, "checkout-invalid"):
                policy.compare_candidates(base=candidate_input(base), head=candidate_input(head), process_session=fixture_session(policy, base, head))

            head["sha"] = subprocess.check_output(
                ["git", "-C", str(head["repository_root"]), "rev-parse", "HEAD"],
                text=True,
            ).strip()
            (head["repository_root"] / "dirty.txt").write_text("dirty\n", encoding="utf-8")
            with self.assertRaisesRegex(policy.PolicyError, "checkout-dirty"):
                policy.compare_candidates(base=candidate_input(base), head=candidate_input(head), process_session=fixture_session(policy, base, head))

    def test_compare_rejects_command_or_argument_removal(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_compare_removal")
        with tempfile.TemporaryDirectory() as base_directory, tempfile.TemporaryDirectory() as head_directory:
            base = write_candidate_fixture(Path(base_directory).resolve())
            head = write_candidate_fixture(Path(head_directory).resolve())
            dump = json.loads(head["dump"].read_text(encoding="utf-8"))
            dump["command"]["subcommands"] = [
                command
                for command in dump["command"]["subcommands"]
                if command["commandName"] == "help"
            ]
            write_json(head["dump"], dump)
            manifest = json.loads(head["manifest"].read_text(encoding="utf-8"))
            manifest["commands"] = [
                command for command in manifest["commands"] if command["id"] == "apple"
            ]
            manifest["arguments"] = [
                argument
                for argument in manifest["arguments"]
                if argument["command_id"] == "apple"
            ]
            manifest["origins"] = [
                origin
                for origin in manifest["origins"]
                if origin["id"] == "port:synthetic.root"
            ]
            manifest["counts"] = {"arguments": 1, "commands": 1, "origins": 1}
            (head["repository_root"] / "docs" / "capability-extras.md").write_text(
                "# Extras\n", encoding="utf-8"
            )
            write_json(head["manifest"], manifest, canonical=True)
            sync_fixture_bindings(head)
            commit_fixture(head)

            with self.assertRaisesRegex(policy.PolicyError, "compare-surface-removal"):
                policy.compare_candidates(base=candidate_input(base), head=candidate_input(head), process_session=fixture_session(policy, base, head))

    def test_compare_rejects_origin_changes(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_compare_origin")
        with tempfile.TemporaryDirectory() as base_directory, tempfile.TemporaryDirectory() as head_directory:
            base = write_candidate_fixture(Path(base_directory).resolve())
            head = write_candidate_fixture(Path(head_directory).resolve())
            new_id = "extra:synthetic.root-reclassified"
            anchor = f"<!-- capability-id: {new_id} -->"
            document = head["repository_root"] / "docs" / "root-extra.md"
            document.write_text(f"# Root extra\n\n{anchor}\n", encoding="utf-8")
            manifest = json.loads(head["manifest"].read_text(encoding="utf-8"))
            manifest["origins"] = [
                origin
                for origin in manifest["origins"]
                if origin["id"] != "port:synthetic.root"
            ]
            manifest["origins"].append(
                {
                    "anchor": anchor,
                    "document": "docs/root-extra.md",
                    "id": new_id,
                    "kind": "cli-extra",
                }
            )
            for surface in [*manifest["commands"], *manifest["arguments"]]:
                if surface["origin_id"] == "port:synthetic.root":
                    surface["origin_id"] = new_id
            (head["repository_root"] / "docs" / "port-specs" / "synthetic.md").write_text(
                "# Synthetic\n", encoding="utf-8"
            )
            write_json(head["manifest"], manifest, canonical=True)
            commit_fixture(head)

            with self.assertRaisesRegex(policy.PolicyError, "compare-origin-change"):
                policy.compare_candidates(base=candidate_input(base), head=candidate_input(head), process_session=fixture_session(policy, base, head))

    def test_compare_rejects_evidence_role_shrinkage(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_compare_shrink")
        with tempfile.TemporaryDirectory() as base_directory, tempfile.TemporaryDirectory() as head_directory:
            base = write_candidate_fixture(Path(base_directory).resolve())
            head = write_candidate_fixture(Path(head_directory).resolve())
            mutate_manifest(
                head,
                lambda manifest: manifest["arguments"][-1]["evidence"].__setitem__(
                    "behavior", manifest["arguments"][-1]["evidence"]["behavior"][:1]
                ),
            )

            sync_fixture_bindings(head)
            commit_fixture(head)
            with self.assertRaisesRegex(policy.PolicyError, "compare-evidence-removal"):
                policy.compare_candidates(base=candidate_input(base), head=candidate_input(head), process_session=fixture_session(policy, base, head))

    def test_compare_rejects_test_replacement_without_structured_supersedes(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_compare_replacement")
        with tempfile.TemporaryDirectory() as base_directory, tempfile.TemporaryDirectory() as head_directory:
            base = write_candidate_fixture(Path(base_directory).resolve())
            head = write_candidate_fixture(Path(head_directory).resolve())
            swift_path = head["repository_root"] / "Tests" / "CapabilityTests.swift"
            swift_path.write_text(
                swift_path.read_text(encoding="utf-8") + "@Test func testParserReplacement() {}\n",
                encoding="utf-8",
            )
            catalog = json.loads(head["test_catalog"].read_text(encoding="utf-8"))
            replacement = "swift:Tests/CapabilityTests.swift:testParserReplacement:1"
            old = "swift:Tests/CapabilityTests.swift:testParser:1"
            digest = hashlib.sha256(swift_path.read_bytes()).hexdigest()
            catalog["tests"] = [
                entry for entry in catalog["tests"] if entry["id"] != old
            ]
            for entry in catalog["tests"]:
                entry["file_sha256"] = digest
            catalog["tests"].append(
                {
                    "file_sha256": digest,
                    "id": replacement,
                    "occurrence": 1,
                    "path": "Tests/CapabilityTests.swift",
                    "runtime_id": "SyntheticTests::testParserReplacement",
                    "symbol": "testParserReplacement",
                    "tier": "logic",
                }
            )
            write_json(head["test_catalog"], catalog, canonical=True)
            manifest = json.loads(head["manifest"].read_text(encoding="utf-8"))
            for surface in [*manifest["commands"], *manifest["arguments"]]:
                surface["evidence"]["parser_help"] = [
                    replacement if reference == old else reference
                    for reference in surface["evidence"]["parser_help"]
                ]
            write_json(head["manifest"], manifest, canonical=True)
            sync_fixture_bindings(head)
            commit_fixture(head)

            with self.assertRaisesRegex(policy.PolicyError, "compare-evidence-removal"):
                policy.compare_candidates(base=candidate_input(base), head=candidate_input(head), process_session=fixture_session(policy, base, head))

            mutate_manifest(
                head,
                lambda value: (
                    value["supersedes"].append(
                        {
                            "new": replacement,
                            "old": old,
                            "reason": "The replacement asserts the same parser contract more directly.",
                        }
                    ),
                    self_supersede_swift_file(
                        value,
                        "Tests/CapabilityTests.swift",
                        "The shared Swift file changed while preserving existing evidence.",
                        exclude={old, replacement},
                    ),
                ),
            )
            with self.assertRaisesRegex(policy.PolicyError, "compare-supersedes-frozen"):
                policy.compare_candidates(base=candidate_input(base), head=candidate_input(head), process_session=fixture_session(policy, base, head))

    def test_compare_rejects_same_id_test_body_replacement(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_compare_test_body")
        with tempfile.TemporaryDirectory() as base_directory, tempfile.TemporaryDirectory() as head_directory:
            base = write_candidate_fixture(Path(base_directory).resolve())
            head = write_candidate_fixture(Path(head_directory).resolve())
            swift_path = head["repository_root"] / "Tests" / "CapabilityTests.swift"
            swift_path.write_text(
                swift_path.read_text(encoding="utf-8").replace(
                    "@Test func testParser() {}",
                    "@Test func testParser() { let changed = true }",
                ),
                encoding="utf-8",
            )
            digest = hashlib.sha256(swift_path.read_bytes()).hexdigest()
            catalog = json.loads(head["test_catalog"].read_text(encoding="utf-8"))
            for entry in catalog["tests"]:
                entry["file_sha256"] = digest
            write_json(head["test_catalog"], catalog, canonical=True)
            commit_fixture(head)

            with self.assertRaisesRegex(policy.PolicyError, "compare-test-content-change"):
                policy.compare_candidates(base=candidate_input(base), head=candidate_input(head), process_session=fixture_session(policy, base, head))

            mutate_manifest(
                head,
                lambda manifest: self_supersede_swift_file(
                    manifest,
                    "Tests/CapabilityTests.swift",
                    "The same test identities now assert the revised contract.",
                ),
            )
            with self.assertRaisesRegex(policy.PolicyError, "compare-supersedes-frozen"):
                policy.compare_candidates(base=candidate_input(base), head=candidate_input(head), process_session=fixture_session(policy, base, head))

    def test_compare_rejects_hosted_to_local_evidence_downgrade(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_compare_downgrade")
        with tempfile.TemporaryDirectory() as base_directory, tempfile.TemporaryDirectory() as head_directory:
            base = write_candidate_fixture(Path(base_directory).resolve(), include_bats=True)
            head = write_candidate_fixture(Path(head_directory).resolve(), include_bats=True)
            local_ref = add_local_bats(head)
            manifest = json.loads(head["manifest"].read_text(encoding="utf-8"))
            behavior = manifest["arguments"][-1]["evidence"]["behavior"]
            old_hosted = next(reference for reference in behavior if reference.startswith("bats:"))
            retained = [reference for reference in behavior if reference != old_hosted]
            manifest["commands"][0]["evidence"]["behavior"].append(old_hosted)
            manifest["commands"][0]["evidence"]["behavior"].sort()
            manifest["arguments"][-1]["evidence"]["behavior"] = sorted(
                [*retained, local_ref]
            )
            write_json(head["manifest"], manifest, canonical=True)
            sync_fixture_bindings(head)
            commit_fixture(head)

            # Preserve this comparison characterization without pretending these
            # Bats declarations are runtime evidence. The public check path now
            # refuses both candidates before its unavailable Bats runner.
            captured = {}
            for fixture in (base, head):
                root = fixture["repository_root"]
                value = json.loads(fixture["manifest"].read_text())
                raw = json.loads(fixture["test_catalog"].read_text())
                sources = policy._swift_catalog(root, raw)
                sources.update(policy._bats_catalog(root, json.loads(fixture["bats_inventory"].read_text())))
                bound, _ = policy._validate_evidence(value, sources, raw["bindings"])
                captured[str(root)] = policy.CandidateDetails(root, fixture["sha"], value, bound, {})
            policy._checked_candidate_details = lambda candidate, **_kwargs: captured[str(candidate["repository_root"])]
            with self.assertRaisesRegex(policy.PolicyError, "compare-evidence-removal"):
                policy.compare_candidates(base=candidate_input(base), head=candidate_input(head), process_session=fixture_session(policy, base, head))

    def test_snapshot_cli_prints_only_canonical_draft_to_stdout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory).resolve()
            dump_path = root / "dump.json"
            write_json(dump_path, sample_dump())
            before = sorted(path.name for path in root.iterdir())

            completed = subprocess.run(
                [sys.executable, str(POLICY_PATH), "snapshot", "--dump", str(dump_path)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )

            after = sorted(path.name for path in root.iterdir())
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stderr, "")
        self.assertEqual(before, after)
        self.assertNotEqual(completed.stdout, "")
        snapshot = json.loads(completed.stdout)
        self.assertEqual(snapshot["status"], "draft")
        self.assertEqual(snapshot["contract_stage"], "command-arguments")
        policy = load_module(POLICY_PATH, "capability_policy_cli_canonical")
        self.assertEqual(completed.stdout, policy.canonical_json(snapshot))

    def test_cli_argument_errors_are_stable_and_do_not_echo_values(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            dump_path = Path(temporary_directory) / "dump.json"
            write_json(dump_path, sample_dump())
            completed = subprocess.run(
                [
                    sys.executable,
                    str(POLICY_PATH),
                    "snapshot",
                    "--dump",
                    str(dump_path),
                    "--unexpected",
                    "sensitive-candidate-value",
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 2)
        self.assertEqual(completed.stdout, "")
        self.assertEqual(
            completed.stderr,
            "capability-policy: cli-arguments-invalid\n",
        )

    def test_check_and_compare_cli_report_command_argument_stage_only(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_cli_stage")
        with tempfile.TemporaryDirectory() as base_directory, tempfile.TemporaryDirectory() as head_directory:
            base = write_candidate_fixture(Path(base_directory).resolve())
            head = write_candidate_fixture(Path(head_directory).resolve())
            check_completed = run_policy_main(
                policy,
                ["check", *candidate_cli_arguments(head)],
                process_session=fixture_session(policy, head),
            )
            compare_completed = run_policy_main(
                policy,
                [
                    "compare",
                    *candidate_cli_arguments(base, "base"),
                    *candidate_cli_arguments(head, "head"),
                ],
                process_session=fixture_session(policy, base, head),
            )

        for completed in (check_completed, compare_completed):
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(completed.stderr, "")
            report = json.loads(completed.stdout)
            self.assertEqual(report["contract_stage"], "command-arguments")
            self.assertNotIn("outputs", report)
            self.assertNotIn("validations", report)

    def test_cli_failure_diagnostics_are_deterministic_and_value_free(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_cli_diagnostics")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            sentinel = "swift:Tests/SentinelTests.swift:testDoNotEchoSentinel:1"
            mutate_manifest(
                fixture,
                lambda manifest: manifest["commands"][0]["evidence"].__setitem__(
                    "behavior", [sentinel]
                ),
            )
            completed = run_policy_main(
                policy,
                ["check", *candidate_cli_arguments(fixture)],
                process_session=fixture_session(policy, fixture),
            )

        self.assertEqual(completed.returncode, 2)
        self.assertEqual(completed.stdout, "")
        self.assertEqual(
            completed.stderr,
            "capability-policy: evidence-reference-missing\n",
        )
        self.assertNotIn("DoNotEchoSentinel", completed.stderr)

    def test_runtime_dump_rejects_duplicate_sibling_names_and_alias_collisions(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_siblings")
        dump = sample_dump()
        duplicate = dict(dump["command"]["subcommands"][0])
        dump["command"]["subcommands"].insert(1, duplicate)
        with self.assertRaisesRegex(policy.PolicyError, "dump-command-collision"):
            policy.snapshot_manifest(dump)

    def test_runtime_dump_validates_supercommands_and_default_child(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_topology")
        dump = sample_dump()
        dump["command"]["subcommands"][0]["superCommands"] = ["wrong"]
        with self.assertRaisesRegex(policy.PolicyError, "dump-supercommands-invalid"):
            policy.snapshot_manifest(dump)

        dump = sample_dump()
        dump["command"]["defaultSubcommand"] = "missing"
        with self.assertRaisesRegex(policy.PolicyError, "dump-default-child-invalid"):
            policy.snapshot_manifest(dump)

    def test_runtime_dump_rejects_unknown_command_and_argument_fields(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_runtime_fields")
        dump = sample_dump()
        dump["command"]["unexpected"] = True
        with self.assertRaisesRegex(policy.PolicyError, "dump-command-fields"):
            policy.snapshot_manifest(dump)

        dump = sample_dump()
        dump["command"]["arguments"][0]["unexpected"] = True
        with self.assertRaisesRegex(policy.PolicyError, "dump-argument-fields"):
            policy.snapshot_manifest(dump)

    def test_runtime_dump_rejects_invalid_command_types(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_command_types")
        dump = sample_dump()
        dump["command"]["abstract"] = 7
        with self.assertRaisesRegex(policy.PolicyError, "dump-command-shape-invalid"):
            policy.snapshot_manifest(dump)

        dump = sample_dump()
        dump["command"]["aliases"] = "root-alias"
        with self.assertRaisesRegex(policy.PolicyError, "dump-command-shape-invalid"):
            policy.snapshot_manifest(dump)

    def test_runtime_dump_rejects_excessive_command_depth(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_command_depth")
        dump = sample_dump()
        parent = dump["command"]["subcommands"][0]
        parent["aliases"] = []
        for index in range(20):
            name = f"nested-{index}"
            child = {
                "abstract": "Synthetic nested command.",
                "arguments": [],
                "commandName": name,
                "shouldDisplay": True,
                "superCommands": ["apple", "foo", *[f"nested-{value}" for value in range(index)]],
            }
            parent["subcommands"] = [child]
            parent = child

        with self.assertRaisesRegex(policy.PolicyError, "dump-command-depth"):
            policy.snapshot_manifest(dump)

    def test_runtime_command_and_argument_inventory_is_bounded(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_runtime_bounds")
        self.assertTrue(hasattr(policy, "MAX_COMMANDS"))
        self.assertTrue(hasattr(policy, "MAX_ARGUMENTS"))
        policy.MAX_COMMANDS = 1
        with self.assertRaisesRegex(policy.PolicyError, "dump-command-count"):
            policy.snapshot_manifest(sample_dump())

        policy.MAX_COMMANDS = 10
        policy.MAX_ARGUMENTS = 1
        with self.assertRaisesRegex(policy.PolicyError, "dump-argument-count"):
            policy.snapshot_manifest(sample_dump())

    def test_runtime_dump_rejects_invalid_argument_shape(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_argument_shape")
        dump = sample_dump()
        dump["command"]["arguments"][0]["isOptional"] = 1
        with self.assertRaisesRegex(policy.PolicyError, "dump-argument-shape-invalid"):
            policy.snapshot_manifest(dump)

        dump = sample_dump()
        dump["command"]["arguments"][0]["kind"] = []
        with self.assertRaisesRegex(policy.PolicyError, "dump-argument-shape-invalid"):
            policy.snapshot_manifest(dump)

        dump = sample_dump()
        dump["command"]["arguments"][0]["preferredName"] = {
            "kind": "long",
            "name": "absent",
        }
        with self.assertRaisesRegex(policy.PolicyError, "dump-argument-shape-invalid"):
            policy.snapshot_manifest(dump)

        dump = sample_dump()
        dump["command"]["subcommands"][0]["aliases"] = ["help"]
        with self.assertRaisesRegex(policy.PolicyError, "dump-command-collision"):
            policy.snapshot_manifest(dump)

class CapabilityPolicyHardeningTests(unittest.TestCase):
    def test_candidate_policy_inputs_cannot_come_from_external_copies(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_fixed_blobs_red")
        with tempfile.TemporaryDirectory() as repository_directory, tempfile.TemporaryDirectory() as external_directory:
            fixture = write_candidate_fixture(Path(repository_directory).resolve())
            external = Path(external_directory).resolve() / "capabilities.json"
            external.write_bytes(fixture["manifest"].read_bytes())
            fixture["manifest"] = external

            with self.assertRaisesRegex(policy.PolicyError, "artifact-path-invalid"):
                policy.check_candidate(**fixture)

    def test_compare_loads_each_candidate_artifact_once(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_single_read_red")
        with tempfile.TemporaryDirectory() as base_directory, tempfile.TemporaryDirectory() as head_directory:
            base = write_candidate_fixture(Path(base_directory).resolve())
            head = write_candidate_fixture(Path(head_directory).resolve())
            original = policy.CommitSnapshot.blob
            reads = {}

            def counted(snapshot, path, *, maximum=policy.MAX_TEXT_BYTES):
                key = (str(snapshot.root), str(path))
                cached = str(path) in snapshot._blobs
                payload = original(snapshot, path, maximum=maximum)
                if not cached:
                    reads[key] = reads.get(key, 0) + 1
                return payload

            policy.CommitSnapshot.blob = counted
            policy.compare_candidates(base=candidate_input(base), head=candidate_input(head), process_session=fixture_session(policy, base, head))

        for fixture in (base, head):
            for path in (
                "docs/capabilities.json",
                "Tests/capability-tests.json",
                "bats/tier-inventory.json",
            ):
                self.assertEqual(
                    reads[(str(fixture["repository_root"]), path)],
                    1,
                    path,
                )

    def test_each_candidate_runs_exactly_one_runtime_capture(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_runtime_single_capture")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            captures = 0

            def runner(root, sha, tree_oid, *, process_session):
                nonlocal captures
                captures += 1
                return synthetic_attestation(root, sha, tree_oid)

            policy._default_runtime_runner = runner
            policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

        self.assertEqual(captures, 1)

    def test_check_cli_exposes_no_candidate_artifact_path_escape(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_cli_fixed_inputs")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            completed = run_policy_main(
                policy,
                [
                    "check",
                    *candidate_cli_arguments(fixture),
                    "--manifest",
                    str(fixture["manifest"]),
                ],
            )

        self.assertEqual(completed.returncode, 2)
        self.assertEqual(completed.stdout, "")
        self.assertEqual(completed.stderr, "capability-policy: cli-arguments-invalid\n")

    def test_check_revalidates_checkout_after_candidate_evaluation(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_checkout_recheck_red")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            original = policy._validate_checkout
            validations = []

            def counted(root, sha, *, process_session):
                validations.append((str(root), sha))
                return original(root, sha, process_session=process_session)

            policy._validate_checkout = counted
            policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

        self.assertEqual(len(validations), 2)

    def test_runner_observes_an_exact_materialized_commit_not_the_checkout(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_materialized_sha")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            checkout_manifest = fixture["manifest"]
            original = checkout_manifest.read_bytes()

            def runner(source_root, sha, tree_oid, *, process_session):
                checkout_manifest.write_bytes(b"transient checkout mutation\n")
                try:
                    self.assertFalse((source_root / ".git").exists())
                    self.assertEqual(
                        (source_root / "docs" / "capabilities.json").read_bytes(),
                        original,
                    )
                    return synthetic_attestation(source_root, sha, tree_oid)
                finally:
                    checkout_manifest.write_bytes(original)

            policy._default_runtime_runner = runner
            report = policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

        self.assertTrue(report["ok"])

    def test_dirty_replacement_of_a_fixed_policy_blob_cannot_pass(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_fixed_blob_dirty")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            fixture["manifest"].write_text("{}\n", encoding="utf-8")

            with self.assertRaisesRegex(policy.PolicyError, "checkout-dirty"):
                policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

    def test_fixed_policy_blob_symlinks_are_rejected(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_fixed_blob_symlink")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            manifest = fixture["manifest"]
            manifest.unlink()
            manifest.symlink_to("../capability-extras.md")
            commit_fixture(fixture)

            with self.assertRaisesRegex(policy.PolicyError, "commit-blob-invalid"):
                policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

    def test_unrelated_nonregular_tree_entries_are_rejected(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_tree_nonregular")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            link = fixture["repository_root"] / "synthetic-link"
            link.symlink_to("docs/capabilities.json")
            commit_fixture(fixture)

            with self.assertRaisesRegex(policy.PolicyError, "commit-tree-nonregular"):
                policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

    def test_swift_bats_and_manual_sources_are_read_once(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_source_cache")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve(), include_bats=True)
            original = policy.CommitSnapshot.blob
            reads = {}

            def counted(snapshot, path, *, maximum=policy.MAX_TEXT_BYTES):
                normalized = str(path)
                cached = normalized in snapshot._blobs
                payload = original(snapshot, path, maximum=maximum)
                if not cached:
                    reads[normalized] = reads.get(normalized, 0) + 1
                return payload

            policy.CommitSnapshot.blob = counted
            with self.assertRaisesRegex(policy.PolicyError, "bats-execution-unavailable"):
                policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

        for path in (
            "Tests/CapabilityTests.swift",
            "bats/hosted/capability.bats",
            "docs/manual/index.md",
            "docs/manual/foo.md",
        ):
            self.assertEqual(reads[path], 1, path)

    def test_swift_source_markers_inside_comments_are_never_tests(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_swift_comment_red")
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory).resolve()
            source_path = root / "Tests" / "CommentTests.swift"
            source_path.parent.mkdir(parents=True)
            source_path.write_text(
                "/*\n@Test\n*/\nfunc helperOnly() {}\n",
                encoding="utf-8",
            )
            digest = hashlib.sha256(source_path.read_bytes()).hexdigest()
            catalog = {
                "schema_version": 2,
                "bindings": [],
                "tests": [
                    {
                        "file_sha256": digest,
                        "id": "swift:Tests/CommentTests.swift:helperOnly:1",
                        "occurrence": 1,
                        "path": "Tests/CommentTests.swift",
                        "runtime_id": "SyntheticTests::helperOnly",
                        "symbol": "helperOnly",
                        "tier": "logic",
                    }
                ],
            }

            with self.assertRaisesRegex(policy.PolicyError, "test-catalog-symbol-not-test"):
                policy._swift_catalog(root, catalog)

    def test_compare_rejects_retained_command_alias_removal(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_alias_regression_red")
        with tempfile.TemporaryDirectory() as base_directory, tempfile.TemporaryDirectory() as head_directory:
            base = write_candidate_fixture(Path(base_directory).resolve())
            head = write_candidate_fixture(Path(head_directory).resolve())
            dump = json.loads(head["dump"].read_text(encoding="utf-8"))
            dump["command"]["subcommands"][0]["aliases"] = []
            write_json(head["dump"], dump)
            manifest = json.loads(head["manifest"].read_text(encoding="utf-8"))
            child = next(command for command in manifest["commands"] if command["id"] == "apple foo")
            child["aliases"] = []
            write_json(head["manifest"], manifest, canonical=True)
            commit_fixture(head)

            with self.assertRaisesRegex(policy.PolicyError, "compare-command-structure-change"):
                policy.compare_candidates(base=candidate_input(base), head=candidate_input(head), process_session=fixture_session(policy, base, head))

    def test_compare_rejects_retained_argument_behavior_change(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_argument_regression_red")
        with tempfile.TemporaryDirectory() as base_directory, tempfile.TemporaryDirectory() as head_directory:
            base = write_candidate_fixture(Path(base_directory).resolve())
            head = write_candidate_fixture(Path(head_directory).resolve())
            dump = json.loads(head["dump"].read_text(encoding="utf-8"))
            dump["command"]["subcommands"][0]["arguments"][0]["isOptional"] = False
            write_json(head["dump"], dump)
            manifest = json.loads(head["manifest"].read_text(encoding="utf-8"))
            option = next(
                argument
                for argument in manifest["arguments"]
                if argument["id"] == "apple foo::option::--name"
            )
            option["structure"]["is_optional"] = False
            write_json(head["manifest"], manifest, canonical=True)
            commit_fixture(head)

            with self.assertRaisesRegex(policy.PolicyError, "compare-argument-structure-change"):
                policy.compare_candidates(base=candidate_input(base), head=candidate_input(head), process_session=fixture_session(policy, base, head))

    def test_compare_allows_only_additive_aliases_and_argument_names(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_additive_names")
        with tempfile.TemporaryDirectory() as base_directory, tempfile.TemporaryDirectory() as head_directory:
            base = write_candidate_fixture(Path(base_directory).resolve())
            head = write_candidate_fixture(Path(head_directory).resolve())
            dump = json.loads(head["dump"].read_text(encoding="utf-8"))
            child = dump["command"]["subcommands"][0]
            child["aliases"].append("foo-alias")
            child["arguments"][0]["names"].append({"kind": "short", "name": "n"})
            write_json(head["dump"], dump)
            manifest = json.loads(head["manifest"].read_text(encoding="utf-8"))
            command = next(item for item in manifest["commands"] if item["id"] == "apple foo")
            command["aliases"].append("foo-alias")
            argument = next(
                item
                for item in manifest["arguments"]
                if item["id"] == "apple foo::option::--name"
            )
            argument["structure"]["names"].append({"kind": "short", "name": "n"})
            write_json(head["manifest"], manifest, canonical=True)
            commit_fixture(head)

            report = policy.compare_candidates(
                base=candidate_input(base),
                head=candidate_input(head),
                process_session=fixture_session(policy, base, head),
            )

        self.assertTrue(report["ok"])

    def test_compare_rejects_default_child_changes(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_default_child")
        with tempfile.TemporaryDirectory() as base_directory, tempfile.TemporaryDirectory() as head_directory:
            base = write_candidate_fixture(Path(base_directory).resolve())
            head = write_candidate_fixture(Path(head_directory).resolve())
            dump = json.loads(head["dump"].read_text(encoding="utf-8"))
            dump["command"]["defaultSubcommand"] = "foo"
            write_json(head["dump"], dump)
            manifest = json.loads(head["manifest"].read_text(encoding="utf-8"))
            root = next(item for item in manifest["commands"] if item["id"] == "apple")
            root["default_child"] = "foo"
            write_json(head["manifest"], manifest, canonical=True)
            commit_fixture(head)

            with self.assertRaisesRegex(
                policy.PolicyError, "compare-command-structure-change"
            ):
                policy.compare_candidates(
                    base=candidate_input(base),
                    head=candidate_input(head),
                    process_session=fixture_session(policy, base, head),
                )

    def test_ordinary_compare_freezes_self_supersedes(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_supersedes_frozen_red")
        with tempfile.TemporaryDirectory() as base_directory, tempfile.TemporaryDirectory() as head_directory:
            base = write_candidate_fixture(Path(base_directory).resolve())
            head = write_candidate_fixture(Path(head_directory).resolve())
            swift_path = head["repository_root"] / "Tests" / "CapabilityTests.swift"
            swift_path.write_text(
                swift_path.read_text(encoding="utf-8").replace(
                    "@Test func testParser() {}",
                    "@Test func testParser() { let weakened = true }",
                ),
                encoding="utf-8",
            )
            digest = hashlib.sha256(swift_path.read_bytes()).hexdigest()
            catalog = json.loads(head["test_catalog"].read_text(encoding="utf-8"))
            for entry in catalog["tests"]:
                entry["file_sha256"] = digest
            write_json(head["test_catalog"], catalog, canonical=True)
            manifest = json.loads(head["manifest"].read_text(encoding="utf-8"))
            self_supersede_swift_file(
                manifest,
                "Tests/CapabilityTests.swift",
                "The candidate claims its stable evidence identities are unchanged.",
            )
            write_json(head["manifest"], manifest, canonical=True)
            commit_fixture(head)

            with self.assertRaisesRegex(policy.PolicyError, "compare-supersedes-frozen"):
                policy.compare_candidates(base=candidate_input(base), head=candidate_input(head), process_session=fixture_session(policy, base, head))

    def test_swift_catalog_reads_each_source_file_once(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_swift_cache_red")
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory).resolve()
            source_path = root / "Tests" / "CachedTests.swift"
            source_path.parent.mkdir(parents=True)
            source_path.write_text(
                "@Test func firstTest() {}\n@Test func secondTest() {}\n",
                encoding="utf-8",
            )
            digest = hashlib.sha256(source_path.read_bytes()).hexdigest()
            catalog = {
                "schema_version": 2,
                "bindings": [],
                "tests": [
                    {
                        "file_sha256": digest,
                        "id": f"swift:Tests/CachedTests.swift:{symbol}:1",
                        "occurrence": 1,
                        "path": "Tests/CachedTests.swift",
                        "runtime_id": f"SyntheticTests::{symbol}",
                        "symbol": symbol,
                        "tier": "logic",
                    }
                    for symbol in ("firstTest", "secondTest")
                ],
            }
            original = policy._read_regular_bytes
            reads = 0

            def counted(path, maximum=policy.MAX_JSON_BYTES):
                nonlocal reads
                if Path(path) == source_path:
                    reads += 1
                return original(path, maximum)

            policy._read_regular_bytes = counted
            policy._swift_catalog(root, catalog)

        self.assertEqual(reads, 1)

    def test_swift_catalog_enforces_aggregate_file_bounds(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_swift_bounds_red")
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory).resolve()
            source_path = root / "Tests" / "BoundedTests.swift"
            source_path.parent.mkdir(parents=True)
            source_path.write_text("@Test func boundedTest() {}\n", encoding="utf-8")
            digest = hashlib.sha256(source_path.read_bytes()).hexdigest()
            catalog = {
                "schema_version": 2,
                "bindings": [],
                "tests": [
                    {
                        "file_sha256": digest,
                        "id": "swift:Tests/BoundedTests.swift:boundedTest:1",
                        "occurrence": 1,
                        "path": "Tests/BoundedTests.swift",
                        "runtime_id": "SyntheticTests::boundedTest",
                        "symbol": "boundedTest",
                        "tier": "logic",
                    }
                ],
            }
            policy.MAX_SWIFT_FILES = 0

            with self.assertRaisesRegex(policy.PolicyError, "swift-catalog-too-large"):
                policy._swift_catalog(root, catalog)

    def test_swift_catalog_enforces_test_and_byte_bounds(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_swift_more_bounds")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            catalog = json.loads(fixture["test_catalog"].read_text(encoding="utf-8"))
            policy.MAX_SWIFT_TESTS = 0
            with self.assertRaisesRegex(policy.PolicyError, "swift-catalog-too-large"):
                policy._swift_catalog(fixture["repository_root"], catalog)

        policy = load_module(POLICY_PATH, "capability_policy_swift_byte_bounds")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            catalog = json.loads(fixture["test_catalog"].read_text(encoding="utf-8"))
            policy.MAX_SWIFT_BYTES = 0
            with self.assertRaisesRegex(policy.PolicyError, "swift-catalog-too-large"):
                policy._swift_catalog(fixture["repository_root"], catalog)

    def test_bats_catalog_enforces_aggregate_file_bounds(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_bats_bounds_red")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve(), include_bats=True)
            inventory = json.loads(
                fixture["bats_inventory"].read_text(encoding="utf-8")
            )
            policy.MAX_BATS_FILES = 0

            with self.assertRaisesRegex(policy.PolicyError, "bats-catalog-too-large"):
                policy._bats_catalog(fixture["repository_root"], inventory)

    def test_bats_catalog_enforces_test_and_byte_bounds(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_bats_test_bounds")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve(), include_bats=True)
            inventory = json.loads(
                fixture["bats_inventory"].read_text(encoding="utf-8")
            )
            policy.MAX_BATS_TESTS = 0
            with self.assertRaisesRegex(policy.PolicyError, "bats-catalog-too-large"):
                policy._bats_catalog(fixture["repository_root"], inventory)

    def test_unclassified_bats_files_cannot_escape_the_fixed_inventory(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_bats_inventory_closure")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            rogue = fixture["repository_root"] / "bats" / "unclassified.bats"
            rogue.write_text(
                '#!/usr/bin/env bats\n\n@test "unclassified" {\n  true\n}\n',
                encoding="utf-8",
            )
            commit_fixture(fixture)

            with self.assertRaisesRegex(
                policy.PolicyError, "bats-inventory-incomplete"
            ):
                policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

        policy = load_module(POLICY_PATH, "capability_policy_bats_byte_bounds")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve(), include_bats=True)
            inventory = json.loads(
                fixture["bats_inventory"].read_text(encoding="utf-8")
            )
            policy.MAX_BATS_BYTES = 0
            with self.assertRaisesRegex(policy.PolicyError, "bats-catalog-too-large"):
                policy._bats_catalog(fixture["repository_root"], inventory)

    def test_manual_sources_enforce_file_and_byte_bounds(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_manual_file_bounds")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            policy.MAX_MANUAL_FILES = 1
            with self.assertRaisesRegex(policy.PolicyError, "manual-sources-too-large"):
                policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

        policy = load_module(POLICY_PATH, "capability_policy_manual_byte_bounds")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            policy.MAX_MANUAL_BYTES = 0
            with self.assertRaisesRegex(policy.PolicyError, "manual-sources-too-large"):
                policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

    def test_source_materialization_has_an_aggregate_byte_bound(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_source_tree_bound")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            policy.MAX_SOURCE_TREE_BYTES = 0
            with self.assertRaisesRegex(
                policy.PolicyError, "commit-tree-content-too-large"
            ):
                policy.check_candidate(**candidate_input(fixture), process_session=fixture_session(policy, fixture))

    def test_swift_evidence_requires_a_passed_runtime_test(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_execution_receipt_red")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            catalog = json.loads(fixture["test_catalog"].read_text(encoding="utf-8"))
            passed = sorted(
                entry["runtime_id"]
                for entry in catalog["tests"]
                if entry["symbol"] != "testParser"
            )

            with self.assertRaisesRegex(policy.PolicyError, "swift-evidence-unexecuted"):
                policy._default_runtime_runner = (
                    lambda root, sha, tree_oid, *, process_session: synthetic_attestation(
                        root,
                        sha,
                        tree_oid,
                        passed_runtime_ids=passed,
                    )
                )
                policy.check_candidate(
                    repository_root=fixture["repository_root"],
                    sha=fixture["sha"],
                    process_session=fixture_session(policy, fixture),
                )

    def test_runtime_attestation_is_bound_to_the_exact_candidate_sha(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_runtime_sha_red")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())

            with self.assertRaisesRegex(policy.PolicyError, "runtime-sha-mismatch"):
                policy._default_runtime_runner = (
                    lambda root, sha, tree_oid, *, process_session: synthetic_attestation(
                        root,
                        sha,
                        tree_oid,
                        attested_sha="0" * 40,
                    )
                )
                policy.check_candidate(
                    repository_root=fixture["repository_root"],
                    sha=fixture["sha"],
                    process_session=fixture_session(policy, fixture),
                )

    def test_runtime_attestation_rejects_a_stale_tree_and_dump(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_runtime_tree")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            with self.assertRaisesRegex(policy.PolicyError, "runtime-sha-mismatch"):
                policy._default_runtime_runner = (
                    lambda root, sha, tree_oid, *, process_session: synthetic_attestation(
                        root,
                        sha,
                        tree_oid,
                        attested_tree_oid="0" * 40,
                    )
                )
                policy.check_candidate(
                    repository_root=fixture["repository_root"],
                    sha=fixture["sha"],
                    process_session=fixture_session(policy, fixture),
                )

        policy = load_module(POLICY_PATH, "capability_policy_runtime_dump")
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = write_candidate_fixture(Path(temporary_directory).resolve())
            stale_dump = sample_dump()
            stale_dump["command"]["abstract"] = "Stale runtime shape."
            with self.assertRaisesRegex(policy.PolicyError, "runtime-command-bijection"):
                policy._default_runtime_runner = (
                    lambda root, sha, tree_oid, *, process_session: synthetic_attestation(
                        root,
                        sha,
                        tree_oid,
                        dump=stale_dump,
                    )
                )
                policy.check_candidate(
                    repository_root=fixture["repository_root"],
                    sha=fixture["sha"],
                    process_session=fixture_session(policy, fixture),
                )

    def test_inactive_and_non_target_swift_markers_need_executed_ids(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_inactive_swift")
        for label, source in (
            ("Inactive", "#if false\n@Test func inactiveTest() {}\n#endif\n"),
            ("NonTarget", "@Test func nonTargetTest() {}\n"),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory).resolve()
                source_path = root / "Tests" / f"{label}Tests.swift"
                source_path.parent.mkdir(parents=True)
                source_path.write_text(source, encoding="utf-8")
                symbol = "inactiveTest" if label == "Inactive" else "nonTargetTest"
                runtime_id = f"SyntheticTests::{symbol}"
                catalog = {
                    "schema_version": 2,
                    "bindings": [],
                    "tests": [
                        {
                            "file_sha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
                            "id": f"swift:Tests/{label}Tests.swift:{symbol}:1",
                            "occurrence": 1,
                            "path": f"Tests/{label}Tests.swift",
                            "runtime_id": runtime_id,
                            "symbol": symbol,
                            "tier": "logic",
                        }
                    ],
                }
                with self.assertRaisesRegex(
                    policy.PolicyError, "swift-evidence-unexecuted"
                ):
                    policy._swift_catalog(root, catalog, frozenset())

    def test_runtime_test_identity_must_match_the_cataloged_symbol(self) -> None:
        policy = load_module(POLICY_PATH, "capability_policy_runtime_symbol")
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory).resolve()
            source_path = root / "Tests" / "IdentityTests.swift"
            source_path.parent.mkdir(parents=True)
            source_path.write_text("@Test func intendedTest() {}\n", encoding="utf-8")
            catalog = {
                "schema_version": 2,
                "bindings": [],
                "tests": [
                    {
                        "file_sha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
                        "id": "swift:Tests/IdentityTests.swift:intendedTest:1",
                        "occurrence": 1,
                        "path": "Tests/IdentityTests.swift",
                        "runtime_id": "SyntheticTests::unrelatedPassingTest",
                        "symbol": "intendedTest",
                        "tier": "logic",
                    }
                ],
            }

            with self.assertRaisesRegex(
                policy.PolicyError, "test-catalog-runtime-mismatch"
            ):
                policy._swift_catalog(
                    root,
                    catalog,
                    frozenset({"SyntheticTests::unrelatedPassingTest"}),
                )


if __name__ == "__main__":
    unittest.main()
