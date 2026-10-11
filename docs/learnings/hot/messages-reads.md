---
topic: messages-reads
last-used: 2026-10-11
importance: high
uses: 1
---

# Messages read learnings

## 2026-10-11 — Give computed SQLite cursor keys numeric affinity

`SQLiteReader` binds its string parameters with `sqlite3_bind_text`. A table
column's numeric affinity can coerce such a parameter, but a computed `CASE`
expression has no column affinity. In a synthetic in-memory database,
`(CASE WHEN 1 THEN 100 END) < ?` with the text parameter `50` returns true;
comparing against `CAST(? AS INTEGER)` correctly returns false.

Normalized Messages date expressions therefore compare cursor parameters using
explicit integer casts. Otherwise a descending page can repeatedly satisfy the
same predicate and return its first rows forever. Pagination regression tests
must bound their page loops and check progress, so that failure reports an
assertion instead of hanging the test process.

Use a seconds/nanoseconds pair for normalized Apple dates. Multiplying every
legacy seconds value by one billion can overflow Int64; saturating it loses
chronological order. Keep a nonnegative nanosecond remainder for negative dates,
and include the transition to undated rows in descending cursor predicates.
