#!/usr/bin/env python3
"""Enforce write-model v2: every EXECUTE-path envelope emits `dry_run: false`.

WHY THIS EXISTS (review H3): the fix that stamped `dry_run:false` across 27 execute
sites is convention-only — `emitNotesWrite` / `emitRemindersWrite` / `emitCalendarWrite`
remain callable with an execute payload, compile clean, and silently omit the key. That
is exactly how the key drifted across 27 sites unnoticed. Nothing pins it back.

The rule this locks: the PLAIN write-emit helpers may ONLY be handed a PREVIEW payload
(self-carrying `dry_run: true`) or a delete DTO that declares `dry_run = false` itself.
Any execute-path payload MUST go through the `…ExecutedWrite` variant (which stamps the
key). So the lint asserts: every argument to a plain emit helper is a whitelisted
preview/delete type. Contacts / Mail don't use these choke points (each site sets
`dry_run` inline or in a dedicated DTO) and are covered by their own logic-tier pins.
"""
import re
import sys
import os

ROOT = os.path.join(os.path.dirname(__file__), "..", "..", "Sources")

# helper name -> the payload type-name prefixes allowed on the PLAIN (non-executed) emit.
RULES = {
    # `ExecutedWrite` is always allowed: it IS the stamping wrapper (the executed helpers
    # call `emitNotesWrite(ExecutedWrite(...))`; calendar wraps at the emit site directly).
    # The lint's teeth: a BARE read/domain payload (CreatedNote / Reminder / CalendarEvent /
    # …) on a plain emit is the drift this catches.
    "NotesKit": ("emitNotesWrite", ("DryRunPreview", "ExecutedWrite")),
    "RemindersKit": ("emitRemindersWrite",
                     ("ReminderWritePreview", "ListWritePreview", "SubtaskWritePreview",
                      "ReminderDeleteData", "ListDeleteData", "ExecutedWrite")),
    "CalendarKit": ("emitCalendarWrite", ("EventWritePreview", "DeleteData", "ExecutedWrite")),
}


def first_token(arg: str) -> str:
    """The constructor/type name that opens the first argument to the emit call."""
    m = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)", arg)
    return m.group(1) if m else ""


def check_domain(domain: str, plain: str, allowed: tuple) -> list:
    violations = []
    executed = plain.replace("emit", "emit", 1)  # sanity anchor; not used directly
    ddir = os.path.join(ROOT, domain)
    for fn in sorted(os.listdir(ddir)):
        if not fn.endswith(".swift"):
            continue
        path = os.path.join(ddir, fn)
        src = open(path, encoding="utf-8").read()
        # Match the plain helper but NOT the executed variant (…ExecutedWrite) or the
        # helper's own definition (`func emit…`). Word-boundary before the name.
        for m in re.finditer(r"(?<![A-Za-z0-9_])" + re.escape(plain) + r"\(", src):
            start = m.start()
            # skip the `func <plain>(` definition line
            line_start = src.rfind("\n", 0, start) + 1
            if "func " in src[line_start:start]:
                continue
            # skip …ExecutedWrite( (the plain name is a prefix of the executed name)
            after = src[m.end() - 1:]
            payload = first_token(after[1:])
            if payload not in allowed:
                lineno = src.count("\n", 0, start) + 1
                violations.append(f"{domain}/{fn}:{lineno}: {plain}(...) is handed "
                                  f"'{payload}', not a preview/delete type {allowed} — "
                                  f"an execute payload must use the ExecutedWrite variant")
    return violations


def main() -> int:
    all_v = []
    for domain, (plain, allowed) in RULES.items():
        all_v += check_domain(domain, plain, allowed)
    if all_v:
        for v in all_v:
            print(f"FAIL - {v}")
        return 1
    print(f"ok - plain write-emits across {', '.join(RULES)} carry only preview/delete payloads")
    return 0


if __name__ == "__main__":
    sys.exit(main())
