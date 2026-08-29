---
topic: workflow
last-used: 2026-08-23
importance: pinned
uses: 1
---

# Workflow decisions

## 2026-08-23 — Consolidate all work on main

The operator directed that all apple-cli work happen directly in the primary checkout on
`main`. After the verified D9 history rewrite, the integration and six domain branches were
consolidated onto `main`, then removed locally and remotely together with every non-root
worktree. Do not recreate branches or worktrees unless the operator explicitly reverses this
repo-local ruling.

This changes only the branch topology. The independent-review, tests-green, Conventional
Commit, Asana-traceability, and frequent-push gates still apply before each direct push to
`main`.

The `1.0.0` tag and MCP retirement remain a manual operator hard stop (D2). (Closed 2026-08-29:
the audit described below ran and the gate closed with zero residual hits; the procedure text is
retained as the record of what was required.) Before that stop
can be reached, Asana subtask `GID-REDACTED` must re-audit reachable history and retained
artifacts for PII. Read its notes in full before executing; they are authoritative and include the
required verification-script rerun and repeat-the-whole-audit-on-any-hit rule. Clean up only the
`apple-cli-test` items logged in `TEST-CLEANUP.md`, by exact
ID, via the MCP oracle—never unlogged or pre-existing real data; independently review the audit;
then remove the D9 rollback bundle and scratchpad, verify both absent, and remove `START-HERE.md`
last; re-review the final state and close with value-free evidence. Do not contact GitHub Support;
the operator declined that escalation.
