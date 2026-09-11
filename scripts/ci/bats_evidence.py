"""Pure, bounded Bats source plans and direct-TAP evidence validation.

These types carry no execution authority. A later trusted runner must bind source,
formatter, process status and captures; parsing cannot authenticate test assertions.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import Path, PurePosixPath
import re
import sys
import unicodedata

SCRIPT_DIRECTORY = Path(__file__).resolve().parent
if str(SCRIPT_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIRECTORY))

import bats_inventory


DECODER_CONTRACT = "bats-double-quoted-literal-v1"
MAX_BATS_FILES = 4096
MAX_BATS_TESTS = 20000
MAX_REPORT_BYTES = 8 * 1024 * 1024
# Match the canonical inventory's per-file source admission limit.
MAX_SOURCE_BYTES = bats_inventory.MAX_BATS_BYTES
_DIGEST = re.compile(r"[0-9a-f]{64}")


class BatsEvidenceError(ValueError):
    """A fixed, value-free diagnostic; never includes source or report text."""


@dataclass(frozen=True)
class BatsFilePlan:
    tier: str
    path: str
    content_sha256: str
    raw_titles: tuple[str, ...]
    raw_title_sha256: tuple[str, ...]
    runtime_titles: tuple[str, ...]
    runtime_title_sha256: tuple[str, ...]
    decoder: str


@dataclass(frozen=True)
class BatsFileResult:
    plan: BatsFilePlan
    passed_numbers: tuple[int, ...]


def _require(condition: bool, code: str) -> None:
    if not condition:
        raise BatsEvidenceError(code)


def _digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _is_digest(value: object) -> bool:
    return type(value) is str and len(value) == 64 and _DIGEST.fullmatch(value) is not None


def _utf8(value: object, maximum: int, code: str) -> bytes:
    _require(type(value) is str and len(value) <= maximum, code)
    try:
        encoded = value.encode("utf-8", errors="strict")
    except UnicodeError:
        raise BatsEvidenceError(code) from None
    _require(len(encoded) <= maximum, code)
    return encoded


def _location(tier: object, path: object, code: str) -> None:
    _require(type(tier) is str and tier in ("hosted", "local"), code)
    _require(type(path) is str and 0 < len(path) <= 512, code)
    _utf8(path, 2048, code)
    _require(not any(unicodedata.category(c) == "Cc" for c in path), code)
    pure = PurePosixPath(path)
    _require(not pure.is_absolute() and pure.as_posix() == path
             and pure.parts[:2] == ("bats", tier) and pure.suffix == ".bats"
             and not any(part in ("", ".", "..") for part in pure.parts), code)


def decode_literal_title(raw: str) -> str:
    """Decode only the specified double-quoted literal subset, never shell code."""
    code = "bats-title-invalid"
    _utf8(raw, MAX_SOURCE_BYTES, code)
    _require(bool(raw) and '"' not in raw
             and not any(unicodedata.category(c) == "Cc" for c in raw), code)
    pieces: list[str] = []
    position = 0
    while position < len(raw):
        character = raw[position]
        _require(character not in ("$", "`"), code)
        if character == "\\":
            _require(position + 1 < len(raw), code)
            following = raw[position + 1]
            pieces.append(following if following in ("$", "`", "\\") else "\\" + following)
            position += 2
        else:
            pieces.append(character)
            position += 1
    return "".join(pieces)


def build_file_plan(
    source: bytes, *, tier: str, path: str, content_sha256: str,
    ordered_title_sha256: tuple[str, ...],
) -> BatsFilePlan:
    """Build a plan from one verified blob and its ordered raw inventory hashes."""
    code = "bats-plan-invalid"
    _require(type(source) is bytes and len(source) <= MAX_SOURCE_BYTES, code)
    _location(tier, path, code)
    _require(_is_digest(content_sha256), code)
    _require(type(ordered_title_sha256) is tuple
             and 0 < len(ordered_title_sha256) <= MAX_BATS_TESTS, code)
    _require(all(_is_digest(value) for value in ordered_title_sha256), code)
    _require(len(set(ordered_title_sha256)) == len(ordered_title_sha256), code)
    # Verify the complete blob before asking the canonical extractor to inspect it.
    _require(_digest(source) == content_sha256, code)
    try:
        raw_titles = bats_inventory._parse_bats_source(source.decode("utf-8"), path)
    except (UnicodeError, bats_inventory.InventoryError):
        raise BatsEvidenceError(code) from None
    # The existing extractor is source-byte bounded. Check its count before any
    # expanded title/hash plan, including when the supplied inventory was false.
    _require(len(raw_titles) == len(ordered_title_sha256), code)
    actual_hashes = tuple(_digest(title.encode("utf-8")) for title in raw_titles)
    _require(actual_hashes == ordered_title_sha256, code)
    try:
        runtime_titles = tuple(decode_literal_title(title) for title in raw_titles)
    except BatsEvidenceError:
        raise BatsEvidenceError(code) from None
    return BatsFilePlan(
        tier=tier, path=path, content_sha256=content_sha256, raw_titles=raw_titles,
        raw_title_sha256=actual_hashes, runtime_titles=runtime_titles,
        runtime_title_sha256=tuple(_digest(title.encode("utf-8")) for title in runtime_titles),
        decoder=DECODER_CONTRACT,
    )


def _plan_count(plan: object, code: str) -> int:
    _require(type(plan) is BatsFilePlan and type(plan.raw_titles) is tuple, code)
    count = len(plan.raw_titles)
    _require(0 < count <= MAX_BATS_TESTS, code)
    return count


def _validate_plan(plan: BatsFilePlan, code: str) -> None:
    """Check immutable shape and internal identities, not source provenance."""
    count = _plan_count(plan, code)
    _location(plan.tier, plan.path, code)
    _require(_is_digest(plan.content_sha256), code)
    _require(type(plan.decoder) is str and plan.decoder == DECODER_CONTRACT, code)
    for values in (plan.raw_titles, plan.raw_title_sha256,
                   plan.runtime_titles, plan.runtime_title_sha256):
        _require(type(values) is tuple and len(values) == count, code)
        _require(all(type(value) is str for value in values), code)
    _require(all(_is_digest(value) for value in plan.raw_title_sha256), code)
    _require(all(_is_digest(value) for value in plan.runtime_title_sha256), code)
    seen: set[str] = set()
    total_raw_bytes = 0
    for raw, raw_hash, title, title_hash in zip(
        plan.raw_titles, plan.raw_title_sha256, plan.runtime_titles, plan.runtime_title_sha256
    ):
        raw_bytes = _utf8(raw, MAX_SOURCE_BYTES - total_raw_bytes, code)
        total_raw_bytes += len(raw_bytes)
        title_bytes = _utf8(title, len(raw_bytes), code)
        _require(raw_hash not in seen and _digest(raw_bytes) == raw_hash
                 and _digest(title_bytes) == title_hash, code)
        seen.add(raw_hash)
        try:
            expected = decode_literal_title(raw)
        except BatsEvidenceError:
            raise BatsEvidenceError(code) from None
        _require(title == expected, code)


def parse_tap(stdout: bytes, status: int, plan: BatsFilePlan) -> BatsFileResult:
    """Validate one complete direct-TAP report; any failure yields no result."""
    code = "bats-report-invalid"
    _require(type(status) is int and status == 0, code)
    _require(type(stdout) is bytes and 0 < len(stdout) <= MAX_REPORT_BYTES, code)
    _validate_plan(plan, code)
    try:
        text = stdout.decode("utf-8", errors="strict")
    except UnicodeError:
        raise BatsEvidenceError(code) from None
    _require(not text.startswith("\ufeff") and text.endswith("\n"), code)
    _require(not any(unicodedata.category(c) == "Cc" and c != "\n" for c in text), code)
    # LF is the only record separator. No decimal conversion is necessary: the
    # trusted plan supplies every canonical index, including its exact spelling.
    lines = text.split("\n")
    count = len(plan.runtime_titles)
    _require(lines[0] == f"1..{count}", code)
    number = 1
    passed: list[int] = []
    for line in lines[1:-1]:
        if line.startswith("#"):
            continue
        _require(number <= count, code)
        expected = f"ok {number} {plan.runtime_titles[number - 1]}"
        if line == expected:
            passed.append(number)
        else:
            # Interpret directives only after matching the complete trusted title.
            _require(line.startswith(expected + " # skip "), code)
        number += 1
    _require(number == count + 1, code)
    return BatsFileResult(plan=plan, passed_numbers=tuple(passed))


def validate_file_results(
    plans: tuple[BatsFilePlan, ...], results: tuple[BatsFileResult, ...],
) -> frozenset[str]:
    """Derive references only from the complete, ordered trusted plan collection.

    Empty collections are valid for a caller with no Bats declarations. They do
    not assert that any Bats file ran. Skipped rows never enter the returned set.
    """
    code = "bats-record-invalid"
    _require(type(plans) is tuple and type(results) is tuple, code)
    _require(len(plans) == len(results) and len(plans) <= MAX_BATS_FILES, code)
    total = 0
    # Bound the entire declaration/result collection before expanding references.
    for plan, result in zip(plans, results):
        count = _plan_count(plan, code)
        total += count
        _require(total <= MAX_BATS_TESTS, code)
        _require(type(result) is BatsFileResult, code)
        _require(_plan_count(result.plan, code) == count, code)
        _require(type(result.passed_numbers) is tuple
                 and len(result.passed_numbers) <= count, code)
    references: set[str] = set()
    previous_file = None
    for plan, result in zip(plans, results):
        _validate_plan(plan, code)
        _validate_plan(result.plan, code)
        _require(result.plan == plan, code)
        identity = (plan.tier, plan.path)
        _require(previous_file is None or identity > previous_file, code)
        previous_file = identity
        previous_number = 0
        for number in result.passed_numbers:
            _require(type(number) is int and previous_number < number <= len(plan.raw_titles), code)
            previous_number = number
            references.add(f"bats:{plan.tier}:{plan.path}:{plan.raw_title_sha256[number - 1]}")
    return frozenset(references)
