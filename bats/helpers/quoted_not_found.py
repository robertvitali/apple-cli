#!/usr/bin/env python3
"""Lint: every Contacts not-found message must quote the identifier, like the oracle's !r.

`apple-contacts-mcp` formats identifiers with Python `!r` at fifteen not-found sites
(server.py 258/479/1309; contacts_connector.py 146/175/370/401/570/652/676/710/748/786/793/1013),
so a caller sees `Contact not found: 'X'`. Sixteen of our eighteen sites are only reachable past
the Contacts authorization gate, so no CLI-tier test can pin them on a machine without TCC —
this source lint is what keeps them from silently regressing (CONTACTS-L2).

Fails on a not-found message that interpolates a bare \\(ident) with no surrounding single quotes.
"""
import re
import sys
import pathlib

SRC = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "Sources/ContactsKit")
# A not-found message line carrying at least one interpolation.
MSG = re.compile(r'(?:notFound\(|notFoundMessage:)\s*"([^"]*)"')

quoted, violations = 0, []
for f in sorted(SRC.rglob("*.swift")):
    for n, line in enumerate(f.read_text().splitlines(), 1):
        for msg in MSG.findall(line):
            interps = re.findall(r"\\\((\w+)\)", msg)
            if not interps:
                continue
            for name in interps:
                if f"'\\({name})'" in msg:
                    quoted += 1
                else:
                    violations.append(f"{f}:{n}: unquoted \\({name}) in {msg!r}")

for v in violations:
    print("VIOLATION:", v)
# "Scanned nothing" must not pass: the known-good corpus is 18 interpolated sites.
if quoted < 18 and not violations:
    print(f"VIOLATION: only {quoted} quoted sites found, expected >= 18 — did the scan break?")
    sys.exit(1)
if violations:
    sys.exit(1)
print(f"OK: 0 unquoted not-found identifiers ({quoted} quoted sites checked)")
