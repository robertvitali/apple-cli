---
topic: workflow
last-used: 2026-09-07
importance: pinned
uses: 3
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
reopened on 2026-08-31 after later rounds found additional classes, and its scoped remediation
was completed and recorded closed the same day. Publication remains blocked on readiness plus a
separate fresh, value-free pre-publication audit round that records its searched classes,
engines, commit-message coverage, object/ref/artifact surfaces, and independent cross-checks,
with zero findings for its stated scope; the repo stays private until then.

D2 parts 1–2 executed on 2026-08-30 under explicit live operator instruction: the first release
was cut as `v26.0.0` under the platform-keyed scheme, and the six MCPs were retired through the
private fleet configuration. Only Homebrew deployment remains, and the operator-present hard-stop
rule is unchanged. For cleanup, delete only `apple-cli-test` items logged in `TEST-CLEANUP.md`, by
exact ID, using the `apple` CLI's precise-ID delete surfaces. An MCP may be used only if it still
answers on a not-yet-converged host. Never delete unlogged or pre-existing real data. The D9
rollback material was removed and verified absent under the 2026-08-31 closure with value-free
evidence. The same rule governs any future rollback artifact: remove it only after fresh-clone
and zero-finding verification, verify it is absent, then close with value-free evidence. Do not
contact GitHub Support; the operator declined that escalation.

## 2026-09-07 — D15 CODEOWNERS attribution exception + D16 narrow main-only reversal ratified

The operator ratified a narrow exception to the 2026-08-23 main-only ruling, recorded as
`HUMAN-DECISIONS.md` D16: three classes of DISPOSABLE ref, and only these, may be created for
the publication-automation rehearsals (design §18 steps 8–14; removal at step 18) — the uniquely
named disposable target ref, the proposal head refs of the validation pull requests (which
target that ref, never `main`), and the Dependabot-created head refs of step 13. Never for
feature work; never merged into `main`; deleted after the rehearsal, including on abort; the
ruling is not reversed for ordinary work. The `AGENTS.md` commit that
records the reversal lands under the private main-only gate when the rehearsal step actually
begins, after an in-session re-confirmation and before the first branch is cut (a policy pull
request cannot carry it, because it would need the head branch the ruling forbids). Until that
commit lands, the main-only ruling governs in full. The later full reversal that activates the
`main` ruleset is a separate, operator-gated, in-session instruction and is not pre-authorized.

Same day, D15 ratified extending the public-attribution exception to `.github/CODEOWNERS`
(operator's exact GitHub user, control-plane paths only; `AGENTS.md` exception commit first,
CODEOWNERS commit second with its own fresh privacy scan). The D9 privacy incident is recorded
CLOSED 2026-08-31 across the tracked documents; the fresh pre-publication privacy audit is a
separate, still-pending launch gate and the repo stays private until it and readiness pass.
