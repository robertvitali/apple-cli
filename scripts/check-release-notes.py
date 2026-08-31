#!/usr/bin/env python3
"""Enforce the release-notes contract in AGENTS.md against CHANGELOG `[Unreleased]`.

The CHANGELOG's `[Unreleased]` section is published verbatim as the GitHub Release
body, so it is the release note. This script is the gate that runs before a release
can be cut. Everything it checks is mechanically decidable; the judgement-only rules
("state the caller-visible effect") are left to review, deliberately, rather than
approximated by a regex that would produce false confidence.

    scripts/check-release-notes.py            # gate the [Unreleased] section
    scripts/check-release-notes.py --version 26.1.0   # gate a released section
"""
from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
CHANGELOG = REPO / "CHANGELOG.md"
PACKAGE = REPO / "Package.swift"

SUBSECTIONS = {"Added", "Changed", "Fixed", "Removed", "Security", "Deprecated"}


def section(text: str, heading: str) -> str | None:
    """Body of one `## [heading]` block, up to the next `## `."""
    pat = re.compile(
        rf"^## \[{re.escape(heading)}\][^\n]*\n(.*?)(?=^## |\Z)",
        re.S | re.M,
    )
    m = pat.search(text)
    return m.group(1) if m else None


def macos_floor(ref: str | None = None) -> str | None:
    """`.macOS(.vNN)` / `.macOS("NN.N")` from Package.swift, at HEAD or a ref."""
    if ref:
        p = subprocess.run(
            ["git", "show", f"{ref}:Package.swift"],
            cwd=REPO, capture_output=True, text=True,
        )
        if p.returncode != 0:
            return None
        src = p.stdout
    else:
        src = PACKAGE.read_text()
    m = re.search(r"\.macOS\(\s*(?:\.v(\d+)|\"([\d.]+)\")", src)
    if not m:
        return None
    return m.group(1) or m.group(2)


def last_tag() -> str | None:
    p = subprocess.run(
        ["git", "describe", "--tags", "--abbrev=0"],
        cwd=REPO, capture_output=True, text=True,
    )
    return p.stdout.strip() or None if p.returncode == 0 else None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--version", default="Unreleased",
                    help="changelog heading to check (default: Unreleased)")
    a = ap.parse_args()

    text = CHANGELOG.read_text()
    body = section(text, a.version)
    errors: list[str] = []
    warnings: list[str] = []

    if body is None:
        print(f"FAIL: no `## [{a.version}]` section in CHANGELOG.md")
        return 1

    stripped = body.strip()

    # Rule 1 -- at least one non-empty Keep-a-Changelog subsection.
    found = re.findall(r"^### +([A-Za-z]+)", body, re.M)
    known = [f for f in found if f in SUBSECTIONS]
    if not stripped:
        errors.append(
            f"[{a.version}] is EMPTY. A release with nothing to say should not be cut."
        )
    elif not known:
        errors.append(
            f"[{a.version}] has no recognised subsection. Use at least one of: "
            + ", ".join(sorted(SUBSECTIONS))
        )
    else:
        for name in known:
            sub = re.search(
                rf"^### +{name}\s*\n(.*?)(?=^### |\Z)", body, re.S | re.M
            )
            if sub and not sub.group(1).strip():
                errors.append(f"`### {name}` is present but empty.")

    # Rule 3 -- a BREAKING change must ADDRESS schema_version. Requiring a bump
    # outright is wrong: some breaks (an exit-code change) are genuinely arguable,
    # and a release note that reasons explicitly about why it is NOT stepping the
    # version is doing the right thing. Silence is the failure mode, not restraint.
    if re.search(r"^### +BREAKING", body, re.M) or "BREAKING" in body:
        if "schema_version" not in body:
            errors.append(
                "a BREAKING change is declared but `schema_version` is never "
                "mentioned. Agents branch on that integer via `apple version`, so "
                "the notes must either state the new number or say explicitly why "
                "it is not being stepped."
            )
        elif not re.search(r"schema_version[^\n]{0,120}?\b\d+\b", body) and not re.search(
            r"schema_version[^\n]{0,80}?(NOT stepped|not stepped|unchanged|not incremented)",
            body, re.I,
        ):
            warnings.append(
                "a BREAKING change mentions `schema_version` but neither states a "
                "new number nor says plainly that it is unchanged. Make it "
                "unambiguous for a machine reader."
            )

    # Rule 4 -- if the real deployment floor moved, say so explicitly. MAJOR names the
    # newest macOS VALIDATED against and is not a floor, so silence here actively
    # misleads users on older macOS.
    tag = last_tag()
    now, before = macos_floor(), macos_floor(tag) if tag else None
    if before and now and before != now:
        if not re.search(r"(minimum|requires|deployment target|macOS \d+ or)", body, re.I):
            errors.append(
                f"Package.swift's macOS floor moved {before} -> {now} since {tag}, "
                "but no deployment-minimum line appears. State it explicitly: MAJOR "
                "is not a deployment minimum and readers will assume otherwise."
            )

    # Rule 5 -- link into the manual so the Releases page is navigable.
    if not re.search(r"docs/manual|/manual/", body):
        warnings.append(
            "no link to the manual. Add one so the release notes lead into the "
            "command reference."
        )

    # Rule 6 -- release notes are public, permanent, and unreachable by any later
    # history rewrite once mirrored into the GitHub Release body.
    #
    # DESIGN NOTE, learned the hard way. The first version of this gate matched five
    # narrow shapes and EXCLUDED placeholders with an UNANCHORED lookahead. A review
    # ran it against 30 real-PII samples and 23 passed clean. The worst class: an
    # unanchored exclusion exempts any real domain that merely CONTAINS a
    # `test`/`example`/`local` label anywhere -- so a genuine corporate address with
    # such a label in a middle position sailed through. A gate that misses is worse
    # than no gate: it manufactures confidence. So the shape now is always MATCH
    # BROADLY, then exempt only on a FULLY ANCHORED placeholder.
    # (Deliberately no sample address here: any literal illustrating that bug is by
    #  construction one this very gate must flag, and it would trip the pre-commit
    #  scan on its own source. Verified -- it did.)
    #
    # This is still not exhaustive -- free-text categories (real names, message
    # bodies, note contents) are not mechanically decidable and remain a review
    # responsibility. Do not read a pass here as "no PII".

    EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})")
    PLACEHOLDER_DOMAIN = re.compile(
        r"^(?:[A-Za-z0-9-]+\.)*(?:example\.(?:com|org|net)"
        r"|[A-Za-z0-9-]+\.(?:test|invalid|example|localhost|local))$"
    )
    for m in EMAIL.finditer(body):
        if not PLACEHOLDER_DOMAIN.match(m.group(1)):
            errors.append("possible email address in the release notes.")
            break

    # Phone: find digit runs, then exempt the reserved 555-01xx range by DIGITS,
    # not by punctuation shape -- the old pattern missed bare and international forms.
    PHONE = re.compile(
        r"(?<!\d)(?:\+\d{1,3}[ .\-]?)?\(?\d{2,4}\)?[ .\-]?\d{3,4}[ .\-]?\d{3,4}(?!\d)"
    )
    for m in PHONE.finditer(body):
        digits = re.sub(r"\D", "", m.group(0))
        if len(digits) >= 7 and not re.search(r"55501\d\d$", digits):
            errors.append("possible phone number in the release notes.")
            break

    PII = {
        "street address": (
            r"(?i)\b\d{1,5}[a-z]? +(?:[A-Za-z][A-Za-z.'-]* +){0,3}"
            r"(?:st|street|ave|avenue|rd|road|dr|drive|ln|lane|blvd|boulevard|"
            r"way|court|ct|terrace|place|pl)\b"
        ),
        "home path": r"(?i)/(?:Users|home)/(?!x\b|tester\b|someone-else\b)[A-Za-z][\w.-]*",
        "coordinates": r"-?\d{1,3}\.\d{2,}\s*[,;]\s*-?\d{1,3}\.\d{2,}",
        # Repo-local ban: tracker identifiers must not appear in this repo at all.
        "tracker id": r"(?i)app\.asana\.com|(?<!\d)\d{15,}(?!\d)",
        # A leaked credential in a permanent public Release body is unrecoverable.
        "credential": (
            r"(?i)\b(?:gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}"
            r"|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY)"
        ),
    }
    for label, pat in PII.items():
        if re.search(pat, body):
            errors.append(
                f"possible {label} in the release notes. These are published to the "
                "GitHub Release body, which no history rewrite reaches."
            )

    for w in warnings:
        print(f"WARN: {w}")
    for e in errors:
        print(f"FAIL: {e}")
    if errors:
        print(f"\nrelease-notes contract: {len(errors)} failure(s). "
              "See AGENTS.md \"Release notes — required contract\".")
        return 1
    print(f"release-notes contract: [{a.version}] OK"
          + (f" ({len(warnings)} warning(s))" if warnings else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
