---
topic: privacy-audits
last-used: 2026-09-30
importance: high
uses: 1
---

# Privacy-audit learnings

## 2026-09-30 — Pattern scans cannot find live-store text in fixtures; provenance wording can

D41 and D42 found message texts, a search term and a note fragment that live oracle runs had copied
into logic-tier tests, weeks after the D9 passes and later audit rounds had cleared the tree. Those
rounds searched by class (emails, phones, addresses, tracker identifiers) and against a denylist of
known values; arbitrary prose from a live store matches neither, so their clean results said
nothing about it. What found the samples was the tests' own provenance wording: comments such as
"measured live" or "in a real note" beside a literal.

Four lessons. A sweep for this class reads the literals that sit beside provenance markers ("live",
"real", "measured", "oracle returned", "sampled") instead of trusting a pattern negative. A known
vector has to become a sweep: D9's fifth lesson had already named live oracle output as the vector,
but the D9 passes fixed only the fixtures their pattern scans caught. A value can leave the file it
lives in: one search term was also part of a test's name, and hosted CI job logs print every test
name, so the redaction had a second carrier (D43) that no tree scan sees; when a test is renamed or
removed for privacy, scan the retained workflow logs for the old name, and search for every
redacted value directly: a clean search for one value says nothing about another (the texts were
fuzzy matches for the term, not substrings of it, so the first log scan's searches could not have
found them). And a log scan that runs while a run attempt is still in progress misses that
attempt's log: the first count was one short for exactly that reason, so rescan once every run is
complete.
