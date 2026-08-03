#!/usr/bin/env python3
"""Lint: every `| Qn |` row in docs/COMPLETION-LOOP.md must have exactly 5 columns.

A raw `|` anywhere in the prose — including inside a code span, which GFM does NOT exempt —
silently adds a column and DROPS the trailing cells from the rendered table. That is invisible in
a diff and has now happened three times in this file: twice from an appended sentence, and twice
pre-existing inside `flock(LOCK_EX|LOCK_NB)` and `2*LCS/(|a|+|b|)`. The evidence column is the one
that disappears, which is the column that carries the parity proof.

Pipes escaped as `\\|` are correct and are not counted.
"""
import re
import sys
import pathlib

DOC = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "docs/COMPLETION-LOOP.md")
CELLS = 7  # leading empty + 5 columns + trailing

rows, bad = 0, []
for n, line in enumerate(DOC.read_text().splitlines(), 1):
    if not re.match(r'^\| Q[0-9]', line):
        continue
    rows += 1
    got = len(re.split(r'(?<!\\)\|', line))
    if got != CELLS:
        bad.append(f"{DOC}:{n}: {line.split('|')[1].strip()} has {got - 2} columns, expected {CELLS - 2}")

for b in bad:
    print("VIOLATION:", b)
if rows < 20 and not bad:
    print(f"VIOLATION: only {rows} queue rows scanned — did the match break?")
    sys.exit(1)
if bad:
    sys.exit(1)
print(f"OK: {rows} queue rows, all {CELLS - 2} columns")
