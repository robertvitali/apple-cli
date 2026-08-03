#!/usr/bin/env python3
"""Lint EVERY GitHub-Flavored-Markdown table in the given files for cell-count drift.

WHY THIS EXISTS. Two separate table corruptions shipped into this repo's records and BOTH were
caught by human/LLM review rather than by tooling:

  1. A stray unescaped `|` inside queue-row prose silently dropped the entire evidence column
     from the rendered COMPLETION-LOOP table.
  2. A prose paragraph fused onto the end of a CHANGELOG perf table produced a 5-cell row against
     a 4-column header; GFM discards the excess cell, so a documented fix vanished from the
     rendered CHANGELOG while looking fine in the source diff.

Both are invisible in review-by-eyeball because the SOURCE reads fine — only the RENDERED output
loses content. `bats/helpers/queue_table_wellformed.py` covers case 1 for one table in one file.
This generalizes it to every table in every file it is pointed at, which is what would have caught
case 2 as well.

GFM semantics implemented here:
  - a table is a header row, a delimiter row (`---`/`:--`/`--:`/`:-:`), then body rows;
  - the delimiter row defines the column count;
  - a body row with MORE cells than the header has its excess cells DISCARDED (silent data loss);
  - a body row with FEWER cells is padded with empties (usually benign, flagged as a warning);
  - `\\|` is an escaped literal pipe and does NOT split a cell — but a `|` inside a CODE SPAN is
    NOT exempt in GFM, which is the trap that produced case 1.
  - fenced code blocks are skipped entirely.
"""
import re
import sys

DELIM = re.compile(r'^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$')


def split_cells(line: str) -> list:
    """Split a GFM table row into cells, honouring `\\|` escapes only."""
    line = line.strip()
    if line.startswith('|'):
        line = line[1:]
    if line.endswith('|') and not line.endswith(r'\|'):
        line = line[:-1]
    cells, buf, i = [], [], 0
    while i < len(line):
        ch = line[i]
        if ch == '\\' and i + 1 < len(line) and line[i + 1] == '|':
            buf.append('|')
            i += 2
            continue
        if ch == '|':
            cells.append(''.join(buf))
            buf = []
            i += 1
            continue
        buf.append(ch)
        i += 1
    cells.append(''.join(buf))
    return cells


def lint(path: str) -> list:
    problems = []
    lines = open(path, encoding='utf-8').read().split('\n')
    in_fence = False
    i = 0
    tables = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if stripped.startswith('```') or stripped.startswith('~~~'):
            in_fence = not in_fence
            i += 1
            continue
        if in_fence or '|' not in line:
            i += 1
            continue
        # a table starts where the NEXT line is a delimiter row
        if i + 1 < len(lines) and DELIM.match(lines[i + 1]) and '|' in lines[i + 1]:
            ncols = len(split_cells(lines[i + 1]))
            header = len(split_cells(line))
            tables += 1
            if header != ncols:
                problems.append(f'{path}:{i+1}: header has {header} cells, delimiter declares {ncols}')
            j = i + 2
            while j < len(lines) and '|' in lines[j] and lines[j].strip():
                got = len(split_cells(lines[j]))
                if got > ncols:
                    problems.append(
                        f'{path}:{j+1}: row has {got} cells, table declares {ncols} — '
                        f'GFM DISCARDS the excess, so content is silently lost when rendered')
                elif got < ncols:
                    problems.append(
                        f'{path}:{j+1}: row has {got} cells, table declares {ncols} — '
                        f'padded with empties when rendered')
                j += 1
            i = j
            continue
        i += 1
    return problems, tables


def main(argv):
    if len(argv) < 2:
        print('usage: md_tables_wellformed.py <file.md> [file.md ...]', file=sys.stderr)
        return 2
    all_problems, total_tables = [], 0
    for path in argv[1:]:
        problems, tables = lint(path)
        all_problems += problems
        total_tables += tables
    if all_problems:
        for p in all_problems:
            print(f'VIOLATION: {p}')
        return 1
    print(f'OK: {total_tables} markdown tables across {len(argv)-1} file(s), all rows well-formed')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
