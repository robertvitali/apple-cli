#!/usr/bin/env python3
"""Schema primitives for the command/argument capability manifest."""

from __future__ import annotations

import json
import re
from typing import Any, Iterable


SCHEMA_VERSION = 1
CONTRACT_STAGE = "command-arguments"
MAX_JSON_DEPTH = 64
MAX_JSON_NODES = 100_000
ROOT_FIELDS = frozenset(
    {
        "arguments",
        "commands",
        "contract_stage",
        "counts",
        "future_contracts",
        "origins",
        "schema_version",
        "status",
        "supersedes",
    }
)
COMMAND_FIELDS = frozenset(
    {
        "abstract",
        "aliases",
        "default_child",
        "evidence",
        "id",
        "manual",
        "name",
        "origin_id",
        "path",
    }
)
ARGUMENT_FIELDS = frozenset(
    {
        "command_id",
        "evidence",
        "id",
        "manual_tokens",
        "origin_id",
        "position_ordinal",
        "structure",
    }
)
ORIGIN_FIELDS = frozenset({"anchor", "document", "id", "kind"})
SUPERSEDES_FIELDS = frozenset({"new", "old", "reason"})
STRUCTURE_FIELDS = frozenset(
    {
        "abstract",
        "default_present",
        "default_value",
        "is_optional",
        "is_repeating",
        "kind",
        "names",
        "parsing_strategy",
        "preferred_name",
        "value_name",
    }
)
COMMAND_NAME = re.compile(r"^[a-z0-9][a-z0-9-]*$")
ORIGIN_ID = re.compile(r"^(?:port|extra):[a-z0-9][a-z0-9._-]*$")
EVIDENCE_REF = re.compile(
    r"^(?:swift:Tests/(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.swift:"
    r"[A-Za-z_][A-Za-z0-9_]*:[1-9][0-9]*|"
    r"bats:(?:hosted|local):bats/(?:hosted|local)/[A-Za-z0-9_.-]+\.bats:[0-9a-f]{64})$"
)


class SchemaError(ValueError):
    """Raised when capability data does not satisfy the manifest schema."""


def _strict_object(pairs: Iterable[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise SchemaError("json-duplicate-key")
        result[key] = value
    return result


def parse_json_bytes(payload: bytes) -> Any:
    """Decode one UTF-8 JSON document while rejecting duplicate object keys."""
    try:
        source = payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise SchemaError("json-invalid-utf8") from error
    try:
        def reject_constant(_value: str) -> None:
            raise SchemaError("json-invalid")

        def bounded_integer(value: str) -> int:
            if len(value.lstrip("-")) > 20:
                raise SchemaError("json-number")
            return int(value)

        def reject_float(_value: str) -> None:
            raise SchemaError("json-number")

        value = json.loads(
            source,
            object_pairs_hook=_strict_object,
            parse_constant=reject_constant,
            parse_float=reject_float,
            parse_int=bounded_integer,
        )
    except SchemaError:
        raise
    except (json.JSONDecodeError, RecursionError) as error:
        raise SchemaError("json-invalid") from error
    stack = [(value, 0)]
    nodes = 0
    while stack:
        current, depth = stack.pop()
        nodes += 1
        if nodes > MAX_JSON_NODES:
            raise SchemaError("json-nodes")
        if depth > MAX_JSON_DEPTH:
            raise SchemaError("json-depth")
        if isinstance(current, dict):
            try:
                for key in current:
                    key.encode("utf-8")
            except UnicodeEncodeError as error:
                raise SchemaError("json-invalid-unicode") from error
            stack.extend((child, depth + 1) for child in current.values())
        elif isinstance(current, list):
            stack.extend((child, depth + 1) for child in current)
        elif isinstance(current, str):
            try:
                current.encode("utf-8")
            except UnicodeEncodeError as error:
                raise SchemaError("json-invalid-unicode") from error
    return value


def validate_manifest(manifest: Any) -> None:
    """Validate the versioned manifest envelope before policy evaluation."""
    if not isinstance(manifest, dict) or set(manifest) != ROOT_FIELDS:
        raise SchemaError("manifest-root-fields")
    if type(manifest["schema_version"]) is not int or manifest["schema_version"] != SCHEMA_VERSION:
        raise SchemaError("manifest-version")
    if manifest["contract_stage"] != CONTRACT_STAGE:
        raise SchemaError("manifest-stage")
    if not isinstance(manifest["status"], str) or manifest["status"] not in {
        "draft",
        "curated",
    }:
        raise SchemaError("manifest-status")
    if manifest["future_contracts"] != {
        "output_fields": [],
        "validation_surfaces": [],
    }:
        raise SchemaError("manifest-future-contracts")
    for field in ("arguments", "commands", "origins", "supersedes"):
        if not isinstance(manifest[field], list):
            raise SchemaError("manifest-collection-type")
    counts = manifest["counts"]
    if not isinstance(counts, dict) or set(counts) != {"arguments", "commands", "origins"}:
        raise SchemaError("manifest-counts")
    expected = {
        "arguments": len(manifest["arguments"]),
        "commands": len(manifest["commands"]),
        "origins": len(manifest["origins"]),
    }
    if counts != expected or any(type(value) is not int for value in counts.values()):
        raise SchemaError("manifest-counts")
    for command in manifest["commands"]:
        if not isinstance(command, dict) or set(command) != COMMAND_FIELDS:
            raise SchemaError("manifest-command-fields")
        path = command["path"]
        aliases = command["aliases"]
        if (
            not isinstance(path, list)
            or not path
            or len(path) > 16
            or any(
                not isinstance(part, str) or COMMAND_NAME.fullmatch(part) is None
                for part in path
            )
            or path[0] != "apple"
            or not isinstance(command["id"], str)
            or command["id"] != " ".join(path)
            or command["name"] != path[-1]
            or not isinstance(command["abstract"], str)
            or not isinstance(aliases, list)
            or any(
                not isinstance(alias, str) or COMMAND_NAME.fullmatch(alias) is None
                for alias in aliases
            )
            or len(aliases) != len(set(aliases))
            or command["name"] in aliases
            or (
                command["default_child"] is not None
                and (
                    not isinstance(command["default_child"], str)
                    or COMMAND_NAME.fullmatch(command["default_child"]) is None
                )
            )
            or not isinstance(command["origin_id"], str)
            or not isinstance(command["evidence"], dict)
            or not isinstance(command["manual"], dict)
        ):
            raise SchemaError("manifest-command-shape")
    command_ids = [command["id"] for command in manifest["commands"]]
    if command_ids != sorted(command_ids) or len(command_ids) != len(set(command_ids)):
        raise SchemaError("manifest-command-order")
    command_id_set = set(command_ids)
    for argument in manifest["arguments"]:
        if not isinstance(argument, dict) or set(argument) != ARGUMENT_FIELDS:
            raise SchemaError("manifest-argument-fields")
        structure = argument["structure"]
        if not isinstance(structure, dict) or set(structure) != STRUCTURE_FIELDS:
            raise SchemaError("manifest-argument-structure")
        names = structure["names"]
        preferred = structure["preferred_name"]
        ordinal = argument["position_ordinal"]
        if (
            not isinstance(argument["id"], str)
            or not argument["id"]
            or not isinstance(argument["command_id"], str)
            or argument["command_id"] not in command_id_set
            or not isinstance(argument["origin_id"], str)
            or not isinstance(argument["evidence"], dict)
            or not isinstance(argument["manual_tokens"], list)
            or (ordinal is not None and (type(ordinal) is not int or ordinal < 1))
            or not isinstance(structure["abstract"], str)
            or type(structure["default_present"]) is not bool
            or (
                structure["default_present"]
                and not isinstance(structure["default_value"], str)
            )
            or (
                not structure["default_present"]
                and structure["default_value"] is not None
            )
            or type(structure["is_optional"]) is not bool
            or type(structure["is_repeating"]) is not bool
            or not isinstance(structure["kind"], str)
            or structure["kind"] not in {"flag", "option", "positional"}
            or not isinstance(structure["parsing_strategy"], str)
            or structure["parsing_strategy"] not in {"default", "upToNextOption"}
            or not isinstance(structure["value_name"], str)
            or not structure["value_name"]
            or not isinstance(names, list)
        ):
            raise SchemaError("manifest-argument-shape")
        normalized_names = []
        for name in names:
            if (
                not isinstance(name, dict)
                or set(name) != {"kind", "name"}
                or not isinstance(name.get("kind"), str)
                or name.get("kind") not in {"long", "short", "longWithSingleDash"}
                or not isinstance(name.get("name"), str)
                or not name["name"]
            ):
                raise SchemaError("manifest-argument-shape")
            normalized_names.append((name["kind"], name["name"]))
        if structure["kind"] == "positional":
            if names or preferred is not None or ordinal is None:
                raise SchemaError("manifest-argument-shape")
        else:
            if (
                not names
                or not isinstance(preferred, dict)
                or set(preferred) != {"kind", "name"}
                or (preferred.get("kind"), preferred.get("name")) not in normalized_names
                or ordinal is not None
            ):
                raise SchemaError("manifest-argument-shape")
        if len(normalized_names) != len(set(normalized_names)):
            raise SchemaError("manifest-argument-shape")
    argument_ids = [argument["id"] for argument in manifest["arguments"]]
    if argument_ids != sorted(argument_ids) or len(argument_ids) != len(set(argument_ids)):
        raise SchemaError("manifest-argument-order")
    for origin in manifest["origins"]:
        if not isinstance(origin, dict) or set(origin) != ORIGIN_FIELDS:
            raise SchemaError("manifest-origin-fields")
        if (
            not isinstance(origin["id"], str)
            or ORIGIN_ID.fullmatch(origin["id"]) is None
            or not isinstance(origin["kind"], str)
            or origin["kind"] not in {"port-spec", "cli-extra"}
            or not isinstance(origin["document"], str)
            or not origin["document"]
            or not isinstance(origin["anchor"], str)
            or not origin["anchor"]
        ):
            raise SchemaError("manifest-origin-shape")
    origin_ids = [origin["id"] for origin in manifest["origins"]]
    if origin_ids != sorted(origin_ids) or len(origin_ids) != len(set(origin_ids)):
        raise SchemaError("manifest-origin-order")
    for replacement in manifest["supersedes"]:
        if not isinstance(replacement, dict) or set(replacement) != SUPERSEDES_FIELDS:
            raise SchemaError("manifest-supersedes-fields")
        if (
            not isinstance(replacement["old"], str)
            or EVIDENCE_REF.fullmatch(replacement["old"]) is None
            or not isinstance(replacement["new"], str)
            or EVIDENCE_REF.fullmatch(replacement["new"]) is None
            or not isinstance(replacement["reason"], str)
            or not replacement["reason"].strip()
            or len(replacement["reason"]) > 512
            or "\n" in replacement["reason"]
        ):
            raise SchemaError("manifest-supersedes-shape")
    supersedes_order = [
        (item["old"], item["new"], item["reason"])
        for item in manifest["supersedes"]
    ]
    if supersedes_order != sorted(supersedes_order) or len(supersedes_order) != len(
        set(supersedes_order)
    ):
        raise SchemaError("manifest-supersedes-order")
