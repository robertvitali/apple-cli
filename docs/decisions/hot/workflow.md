---
topic: workflow
last-used: 2026-08-31
importance: pinned
uses: 2
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

The 2026-08-29 audit closure is historical and covered only the classes then known. D9 was
reopened on 2026-08-31 after later rounds found additional classes. Publication remains blocked
until the approved private remediation is complete and one fresh, value-free audit round records
its searched classes, engines, commit-message coverage, object/ref/artifact surfaces, and
independent cross-checks, with zero findings for that stated scope.

D2 parts 1–2 executed on 2026-08-30 under explicit live operator instruction: the first release
was cut as `v26.0.0` under the platform-keyed scheme, and the six MCPs were retired through the
private fleet configuration. Only Homebrew deployment remains, and the operator-present hard-stop
rule is unchanged. For cleanup, delete only `apple-cli-test` items logged in `TEST-CLEANUP.md`, by
exact ID, using the `apple` CLI's precise-ID delete surfaces. An MCP may be used only if it still
answers on a not-yet-converged host. Never delete unlogged or pre-existing real data. Remove D9
rollback material only after fresh-clone and zero-finding verification, verify it is absent, then
close with value-free evidence. Do not contact GitHub Support; the operator declined that
escalation.
