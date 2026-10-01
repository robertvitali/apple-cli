---
title: Pre-launch readiness evidence
last-used: 2026-09-30
uses: 5
---

# Pre-launch readiness evidence

This is the single tracked, value-free readiness file the publication-automation design
(step 19) prescribes. It records, per phase, what has been verified and what is still
**PENDING**, with digests, counts, engine names, role labels and salted commitments in place of
any raw identifier. Commands, when quoted, use fixed placeholders (`<owner>`, `<repo>`,
`<local-path>`). A pending result is never relabelled as passed; later phases append.

It also carries every pre-publication privacy audit round required by `AGENTS.md` ("No personal
data in this repo"): searched classes, regex engines, commit-message coverage, object/ref/artifact
surfaces, independent cross-checks, and the finding count for the stated scope. Raw hit lists and
the operator's private identifier denylist live outside the repository and appear here only by
digest or salted commitment.

## 1. Phase status

**Visibility step advanced by operator ruling (D17, 2026-09-20).** The design's phase 1 lists
the items to finish before the visibility change. Hosted Actions stopped allocating runners for
the private repository, and the operator directed the flip ahead of the items below that are not
yet evidenced, conditioned on a fresh privacy audit; that audit's zero-findings condition was NOT met and the
operator dispositioned findings 1–5 and named the remaining two as pre-flip blockers (Section 2).
The rows say exactly what is evidenced in this file today; everything else is PENDING and stays
so until evidence is appended.

| Design §18 item | Phase | Status in this file | Evidence |
|---|---|---|---|
| 1 Implementation in reviewed, test-green commits | pre-visibility | PENDING (not evidenced here) | — |
| 2 Production-coverage baseline per target | pre-visibility | PENDING (not evidenced here) | — |
| 3 Full local canonical suite + independent reviews on the exact SHA | pre-visibility | Suite: evidenced for 38 of the 42 commits pushed from `053b56e` (2026-09-21) through `675eebb` (2026-09-30 UTC). Eleven were recorded at the time: `08cc984`, the visibility-step commit `bdbbe9d`, the two hosted-CI fixes `7b46b8d` and `0ff7442`, the Round 2 record `3e46e82`, `3b1fbef`, `8ba43b1`, `dd2114f`, `e011d83`, `1f8f3ab` and `675eebb`. Three more, `53eae85`, `ca4392d` and `a4de516`, were recorded late but the same day, from retained run outputs, together with `675eebb` in the commit after it, because none of their successors (`ca4392d`, `a4de516`, `675eebb`) touched this file. The other 24, `7953268` included, were backfilled on 2026-09-26 from retained run outputs (Section 3, backfill table). Four have no green run on record for their exact commit: `053b56e` and `a52c44e` ran red and reached `origin` in the same push as `08cc984`, whose suite is recorded green across a run and a full Bats re-run; `7049736` has no retained outputs and `19f48a2` only partial logs, and the controller's private notes record both red in Bats on two live-Mail cases (Section 3). Reviews: not assessed here beyond the trailers, which name codex plus the code, security and critic reviewers on 38 of the 42, codex and the security reviewer only on `afc6779` and `3e46e82`, and codex only on `7049736` and on `675eebb` (22 added and 4 removed lines, changing one test's timing constants and the hosted-CI learnings; its message records codex only). (Correction 2026-09-26: this row previously said all five commits then recorded at the time carried the four review lanes; `3e46e82` carries codex and the security reviewer only.) | Section 3 |
| 4 External-Action allowlist committed and validated | pre-visibility | Repository-level allowlist configured 2026-09-21 (see the Actions-settings row); the committed/validated form of the design is advanced past for visibility only — PENDING, owner: controller | — |
| 5 Workflow inventory: publishers converted or removed | pre-visibility | Partially evidenced: `.github/workflows/` holds `ci.yml`, `docs.yml`, `governance.yml` (the metadata check folded into `governance / required` on 2026-09-25 — the fold half of step 5; the check still runs only the base-owned metadata validator, the design's control-plane enforcement for that name is not implemented, and the urgent-release runbook with its `AGENTS.md` exception, owed since `release.yml` was removed on 2026-09-07, landed on 2026-09-26 as `docs/runbooks/urgent-release.md` (the build-and-verify workflow it records is checked on every Python-tier run by `Tests/automation/test_urgent_release_runbook.py`: it parses, passes the static scan and the action-pin check beside the tracked workflows, and keeps a read-only-token shape whose one write is its own run's artifact; a restored copy must be byte-identical to it; it cannot cut a release from current `main` until the operator decides how a release relates to the macOS 27 adoption, which the runbook's step 2 names); the check will need `checks` and `actions` read permissions when its control-plane half lands (the workflow scan already accepts any read scope outside its forbidden set, so what refuses a new scope today is `test_pr_metadata.py`, which pins the whole workflow as parsed by the scan's own parser (so the pin is exactly as faithful to GitHub's reading as that parser), both `permissions` blocks at exactly `contents: read` included, and the edits then fall to that expectation and the AGENTS.md `contents: read` policy sentence); no pull request has run the renamed check yet, so it has no hosted first-run evidence; separately from step 5, the `Supply-chain policy` lane is still a proposal checkout on pull requests, see row 17); no `release.yml`; all three declare `contents: read` only and none carries `workflow_dispatch`, `pages`, `id-token`, or an `environment`; no repository secrets or variables (read back 2026-09-20). 2026-09-23: `docs.yml` gained `release-prep-rehearsal`, a read-only job (`contents: read`, no secrets, no artifact upload) that runs `scripts/ci/release_prep.py` — the design §14.1 rehearsal — in a throwaway clone against the commit the workflow builds (on `push`, the commit on `main`; on `pull_request`, the synthetic merge commit); only the script's nothing-to-release status is advisory, every other failure fails the job; it covers the default-bump path, the macOS-adoption shape being exercised locally before a cut. This is a smoke check toward step 15, not step 15 itself: the explicit-SHA hosted rehearsal with its three-way evidence binding is still PENDING. Static scan of step 17 EVIDENCED 2026-09-23 (step 17 row). Hosted runner lane: every macOS job (`build-test`, `hosted-bats-build`, `hosted-bats`, the Docs `manual-fresh` job, and the urgent-release runbook's recorded workflow) moved from `macos-15` to the stable `macos-26` image on 2026-09-29 (design §4.1 amendment), with no extra `macos-15` lane; GitHub's runner-images catalogue (the `actions/runner-images` README, read 2026-09-29) lists macOS 26 Arm64 as generally available under that label. The hosted macOS 26 baseline is RECORDED (Section 4): the Docs half from the first push run after the move (`1f8f3ab`), and the CI half from `53eae85`, whose CI run passed all six jobs on its first attempt; `1f8f3ab`'s CI run had failed its first attempt in `build-test` on a macOS 26 Foundation difference and did not qualify, and `53eae85` fixed it forward. The definition: for each workflow, the first push run on `main` after the move whose first attempt completes with every job green (CI six, Docs four; a red, cancelled or re-run attempt does not qualify and is recorded as such; the two may come from different commits), recorded in Section 4 with the runner image name, image version and OS version from the job log's "Set up job" section and the default Xcode, Swift and `python3` versions from the Included Software page that log links for that image version. No local macOS 26 canonical run is recorded in this file: every canonical run it records, from 2026-09-21 on, ran on the operator's macOS 27 host. Before `53eae85` the macOS 26 claim therefore had no recorded per-commit basis; from `53eae85` on it rests on the hosted lane, where each commit's own hosted run is its per-commit basis and a red one is recorded as such and fixed forward (design §4.1 amendments). One commit in that range, `ca4392d`, has no green hosted CI run: attempt 1 passed every Swift test and then failed its cleanup, attempt 2 failed one timing test; it changes no product source, so its product is the one `53eae85`'s run covered. An image failure is handled by reverting the move | this row (read back 2026-09-20) |
| 7 Squash-only merge with PR title/body as squash commit | pre-visibility | **SETTINGS APPLIED 2026-09-26 (D32)** — read back: `allow_merge_commit` false, `allow_rebase_merge` false, `allow_squash_merge` true, `squash_merge_commit_title` PR_TITLE, `squash_merge_commit_message` PR_BODY, `delete_branch_on_merge` true (Section 4, D32 read-back). Configuration half only: the empirical half — that a native squash merge produces a commit header equal to the final PR title after the ` (#N)` suffix and a body equal to the description after terminal-newline normalisation — is design step 12 and remains PENDING, with the same property on `main` confirmed only in step 20 | Section 4 |
| 15–16 Read-only release/site rehearsal tooling exercised | pre-visibility (local half); post-visibility (hosted runs) | Step 15 tooling: `scripts/ci/release_prep.py` (2026-09-23, rows above); the explicit-SHA hosted rehearsal with its three-way binding remains PENDING. Step 16 local half EVIDENCED IN PART 2026-09-23 with `scripts/ci/site_assembly.py`, run against throwaway clones of `eb728d3` with the pinned MkDocs toolchain (`docs/requirements.txt`, pure-Python wheels installed with hashes required on macOS; the hosted lane is the manifest's compiled target) — run 1, empty published set (the only tag, `v26.0.0`, was then a draft Release, deleted 2026-09-27 under D34, and its commit carries no manual tree, so it is excluded by the caller, as the design amendment records): PASS, routes `/`, `/versions/`, `/version-manifest.json`, 205 files, content-manifest sha256 `1a0ad6ab60f4da8d…`, artifact sha256 `4eafe5304a1214fa…`; run 2, a SYNTHETIC `v26.0.0` tag placed inside the clone on an older manual-bearing commit (`4f8776a`) to exercise an archive route with real renderer output, executed twice: both PASS with identical reports, routes `/`, `/versions/`, `/versions/26.0/`, `/version-manifest.json`, 409 files, content-manifest sha256 `28294a96d44722ce…`, artifact sha256 `bf67c4d16022c96d…`, renderer version 1.6.1, artifact restore verified, per-run double render byte-equal (directories included). No digested byte carries the unassigned candidate version: the scratch manifest records the candidate's version and series as null and the archive index names published series only, so the report's digests cannot be enumerated back to a version. The same inputs with the original `/version/` root were REFUSED (collision with the `apple version` page) — the finding behind D29. Not yet exercised against a REAL published archive (none exists): the multi-series case and the maintenance-patch case are covered hermetically only. `Tests/automation/test_site_assembly.py`: 28 hermetic cases (the tracked `mkdocs.yml` pinned against the config policy; synthetic tagged repositories for series selection, maintenance-patch candidate, candidate below its series tip refused, config-policy refusals, non-deterministic renderer refused, determinism across runs, artifact restore, loopback serving of every route, manifest-path collision, mistagged commit, refusals for missing manual, symlinks, bad tags, dirty checkout, unsafe paths, renderer failure) plus one real-renderer case (clone, synthetic tag, two runs compared) that is local-only — env-gated, run by no CI job. A published tag whose commit carries no tracked manual (`v26.0.0` would be one; it has had no Release since D34) is a refusal by design, so the first archive-able tag is the macOS 27 re-cut; the run log names no version either. Hosted half: `docs.yml` gained `site-assembly-rehearsal` (read-only; no token; published set from the public Releases listing, drafts invisible; candidate version derived, never printed; only the value-free report printed). Scope of the hosted run today: with no published Release the published set is empty, so the hosted job exercises the single-series candidate-serves-root path plus the artifact pack/restore/digest proof; the archive and maintenance-patch paths stay hermetic and local-synthetic. A green Docs check is NOT by itself evidence — a rate-limited listing warns and skips the assembly — so the §4 row for a hosted rehearsal cites the printed report, not the check conclusion. Loopback serving of the routes is a test-tier check, not part of the hosted run (a knowing omission). First hosted run: `72112c3` (Docs, run commitment `64eecb98351486a2`) — listing at HTTP 200, assembly PASS with an empty published set; §4 run table | `scripts/ci/site_assembly.py`; `Tests/automation/test_site_assembly.py`; `.github/workflows/docs.yml` |
| 17 Static workflow scan + settings readbacks | pre-visibility (static scan); post-visibility (API read-backs) | **EVIDENCED IN PART 2026-09-25 — settings read-backs recorded; two read-backs not performed (installed Apps — endpoint 403; attestation settings — NOT READ); collaborator list ruled on 2026-09-25 (D31: one read grant removed, one kept; read back collaborators 2 — admin 1, read 1, outside 1; the design's stated collaborator expectations remain satisfied); CODEOWNERS present and error-free 2026-09-25 (authored in `e48ec1e`; code-owners errors API 200 with 0 errors on `main` and at that commit; contents API 200). Two residuals stand: §10.5 coverage and effective ownership are checked by `Tests/automation/test_control_plane.py` under its documented subset of GitHub's last-match-wins resolution, not by any GitHub API; and with rulesets 0 the file binds no merge until the step 20 `main` ruleset is active. Static scan: the two block-scalar parser differentials recorded OPEN on 2026-09-26 were fixed the same day (see below).** Static scan EVIDENCED 2026-09-23: `scripts/ci/workflow_policy.py` parses each workflow with a hand-rolled block-YAML subset parser (anchors, tags, flow mappings, tab indentation and multi-document files are refused, and a refusal is a violation, not a pass) and checks the step's list on the parsed document — explicit `permissions` on every workflow and job (nine jobs gained `contents: read` in the same change), no forbidden trigger (`workflow_run`, `workflow_dispatch`, `repository_dispatch`, `release`, `deployment`), no `environment`, no `secrets.` context in any expression, no `secrets:` mapping or `secrets: inherit`, no `github.token`, hosted runner labels only, `persist-credentials: false` on every checkout, none of the recorded publish/deploy/attest actions and none of the recorded `git`/`gh`/REST/registry write commands (a recorded-list check: a write reachable only through a remote action's own code is bounded by the read-only permissions and the absence of secrets, not detected), every `uses:` a remote action pinned to a full SHA, no `container`/`services` image, unique check names, recorded trigger sets for `quality / required` and `governance / required`, exactly one `pull_request_target` workflow that references the proposal head nowhere (workflow-level `env` included), downloads no artifact (any `download-artifact` action or `gh run download`), names no checkout `repository` and pins every checkout `ref` to the base. Runs in CI's `Supply-chain policy` job, which, unlike `build-test` and `hosted-bats-build`, checks out without an explicit `ref` and so executes the proposal's copy of the scanner and of `Tests/automation` on a pull request (those two jobs also check out the proposal, at its head commit, but run their policy script from a separate checkout of the base commit; the trusted-base conversion of that lane belongs to the unimplemented design §10.5 trusted check, not to the step 5 fold); `Tests/automation/test_workflow_policy.py` (53 cases) exercises each rule on synthetic trees plus the real tree. The recorded set names `governance / required`, the sole `pull_request_target` check since the step 5 fold of 2026-09-25 (it ran as `metadata / required` before that). The rename was free only because no ruleset binds any check name yet (§4, rulesets 0); once the step 20 ruleset exists, renaming a required check breaks its binding. The scan was re-run on the renamed tree on 2026-09-25 and exited 0. 2026-09-26: the scan's parser and the action-pin check now refuse whitespace other than space, tab and line feed, a byte-order mark, bidirectional controls and any character outside YAML's printable set, in a workflow's text and (the scan) after decoding double-quoted escapes, and the runner-label and checkout-ref allowlists compare values exactly (the pin shape as a full match) and a padded job name is refused; before that, a no-break space before `#` ended a comment for the parser but not for YAML or the runner's shell, so a write command after it passed the scan (found by codex in review of the step 5 fold), and an escaped one (`"ubuntu-latest\_"`) was stripped to an admitted runner label (found in review of the first fix). The same no-break space also let `uses: …@<approved SHA><NBSP>#<NBSP><version>` read as the approved pin in both this scan and the action-pin check, while GitHub reads a ref that is not a SHA (bounded since 2026-09-26 by `sha_pinning_required`, D32). A literal carriage return, U+0085 or U+2028 could also hide a whole key from the parser that a YAML loader reads (the security review reproduced this against libyaml). All reproduced as passing scans before the fix and refused after; both scanners re-run on the fixed tree exited 0. A carriage return is refused although YAML reads it as a line break, since the parser splits on line feeds only (the site-assembly path reads `mkdocs.yml` as text, which turns a carriage return into a line feed first). Every verdict still rests on this parser reading a file as GitHub's loader does; the refusals narrow that residual, they do not prove it away. Recorded OPEN in that commit and fixed in the next, the same day: a block-scalar differential in this parser (it took a block's indentation from the first non-comment line, so a line a YAML loader reads could go unread, and it trimmed the value, so a block scalar could read as an admitted label, check name or ref; it now uses the first non-empty line, `#` lines included, applies YAML's value rules for leading empty lines, chomping and folding, and refuses explicit indentation indicators, a leading empty line deeper than the first content line, and a tab in the leading whitespace of any line, empty and comment-looking lines included); a block-scalar skip in the action-pin check (for a block scalar opened by a sequence item's key it measured from the dash, not the key; it now measures from the key, and the scan also checks every parsed `uses`, name and SHA, against the pin allowlist, one source of truth); and violation messages that echoed decoded values or file names verbatim (this scan, the action-pin check and the site-assembly rehearsal now escape non-printable characters in what they print). The first two each reproduced as a passing scan before the fix, with the YAML reading confirmed against libyaml, and are refused after; the third reproduced as a raw `::error::` line in the printed output and is escaped after. A seeded differential of this parser against libyaml 0.2.1 (Ruby Psych 3.1) over 32,000 generated block-scalar documents (15,161 of them accepted by both), lines holding tabs and files ending without a final line feed included, found 0 differences in value or structure where both accept, and none that only this parser accepts; the parser before the fix differed on 983 of 4,000. Settings/API read-backs recorded 2026-09-24 in §4 as the value-free expected set: repository secrets, Actions variables, Dependabot secrets, environments and deploy keys all zero; no Pages site; workflow token read-only; external-contributor approval on; no rulesets yet. Not performed: the installed-App inventory (endpoint answered 403, cause not established — retry with a token of the documented class, else an operator UI read); attestation settings (no repository surface queried — NOT READ). Ruled on 2026-09-25 (D31): of the two outside read grants the operator had one removed (HTTP 204; read back collaborators 2 — admin 1, read 1, outside 1) and kept the other — a conforming state under the design's stated collaborator expectations (only administrator, only environment reviewer, no other write-capable actor), which is the expected set from 2026-09-25, with a salted commitment over the kept account's numeric id recorded in D31. CODEOWNERS: step 17 expects it present and error-free; authored under D15 (RATIFIED 2026-09-07; an earlier revision of this cell called that decision unrecorded) with the D30 go-ahead (2026-09-24), on 2026-09-25 in `e48ec1e` together with `.github/control-plane-manifest.json` and `Tests/automation/test_control_plane.py`, which checks, under a documented subset of GitHub's last-match-wins resolution, that every manifest path is effectively owned by the single user named there; the code-owners errors API remains the authority and was read back on 2026-09-25 once `e48ec1e` was on `main`: status 200, 0 errors on the default branch and at the exact commit, file present — the present-and-error-free halves are SATISFIED; the coverage half rests on the local model and the file is not yet binding (rulesets 0); recorded in §4; 2026-09-26 (D33): vulnerability alerts and Dependabot security updates turned on and read back, and two GitHub-managed dynamic workflows (Dependabot Updates, Dependency Graph) found running outside the step 17 scan and the row 5 inventory, recorded in §4 | `scripts/ci/workflow_policy.py`; `Tests/automation/test_workflow_policy.py` |
| Fresh pre-publication privacy audit | pre-visibility | **Round 1 complete. Its zero-findings condition was NOT met: seven findings (R1-F1 to R1-F7); the operator dispositioned F1–F5 (D17–D20), the F6 fixture fix and the F7 log deletion (D21) were pre-flip blockers, both completed 2026-09-21, and the flip was advanced on that basis. This round does not satisfy design §18 phase 1's zero-findings gate; the end-of-roadmap round must.** Owner: controller for the record, operator for the dispositions. Round 2 (end-of-roadmap, 2026-09-22): **zero NEW findings; the gate is NOT yet closed — R1-F1 recurs in the unchanged draft asset as a deferred finding under OPEN D18 (rebuild, re-cut, re-scan), while the D20 identity class recurs as accepted. It was to close on the appended scan of the rebuilt asset (superseded by D34, below).** Rebuild rehearsal 2026-09-22 (D23/D24): the path-free build and packaging PASS every gate on the operator's macOS 27 host — zero R1-F1 to R1-F3 carriers in the rehearsal binary and archive (Section 3a); D18 steps (2) and (4) are thereby demonstrated on `3e46e82`, to be re-established on the exact release commit and its shipped artifact. **Closure condition amended 2026-09-26 (D34):** the gate named the published rebuilt asset, which needs the publisher, while design §15 makes a closed gate a precondition of the launch that adds it; on the operator's ruling the `v26.0.0` draft Release was deleted on 2026-09-27T01:32Z (Section 2). The gate will close on a fresh round over at least the surfaces D34 names with zero findings for its stated scope; that round has not run. **PENDING:** the rebuilt asset's pre-publication checks that D34 requires (D18 step (4) plus a value-free scan under the round's classes and denylist over the binary, archive, checksum file and Release notes body; the denylist scan operator-local, recorded against the sha256 digest of each covered item), which D34 requires until an approved launch specification adds them to the §15.1 preflight. Pre-round dispositions (Section 2): D35 and D36 accepted classes; D37 deleted 168 workflow runs on commits outside `main` after one was found storing personal data; D38 accepts that commit, still fetchable by id, as a residual; D41 accepts two message texts and a search term sampled from a live store into a test, replaced at HEAD, as a residual in history; D42 accepts a note fragment taken from a live store into a test on the same terms; known items listed for the fresh round. | Sections 2, 3a |
| Design §18/§3, `AGENTS.md` and ledger-preamble amendment recording the advanced visibility step (D15 precedent) | pre-visibility | Landed in the same commit as this revision (design §18 dated amendment, `AGENTS.md` privacy paragraph, ledger preamble, D2 freeze amendment) | this commit |
| 4 (repository-level part) Actions settings | pre-visibility | Read back 2026-09-20: `default_workflow_permissions` = read, `can_approve_pull_request_reviews` = false, `allowed_actions` = all. Configured 2026-09-21 and read back: `allowed_actions` = `selected`, GitHub-owned actions allowed, one third-party pattern with a wildcard ref (the SHA pins live in the workflow files; `sha_pinning_required` was false until D32 turned it on 2026-09-26, Section 4), covering the five actions the workflows use; the unused wiki flag disabled 2026-09-21; fork-PR contributor approval could not be read while private; read back `all_external_contributors` on 2026-09-21 15:08Z and again on 2026-09-24 (step 17 read-backs, §4), unchanged | this row |
| Surfaces that become public on the flip and were not in round 1's scan | pre-visibility | Complete. Scanned after round 1 (see Round 1 addendum): PR timelines, issue events, commit comments clean apart from the known R1-F4 identity class; all 305 hosted workflow runs' logs scanned value-free — no personal data, but 18 runs' logs carry pre-redaction tracker identifiers inside historical branch names (R1-F7). Those 18 runs' logs were deleted under D21 on 2026-09-21 (read back absent); on 2026-09-27 D37 deleted outright 18 runs whose branch names carry tracker identifiers, a count matching these. Projects unreadable with the current token | Round 1 addendum |
| Pre-push re-scan of every commit added after `053b56e` (tree + commit message) | pre-visibility | Done for the pushes of 2026-09-21 (`053b56e`, `a52c44e`, `08cc984`: changed blobs, messages and author headers; Python `re`, `pcre2grep`, `git grep -P`; clean apart from the git-identity lines and one integer constant); repeated before each later push the same day for `bdbbe9d`, `7b46b8d` and `0ff7442` (changed blobs at the commit via `git grep -P`, message via Python `re`): clean apart from the AI co-author trailer address and, at `0ff7442`, one pre-existing reserved-domain placeholder in an old CHANGELOG entry. Later commits: Section 3, "Pre-push scans after `0ff7442`" (backfilled 2026-09-26) — six have no pre-push scan record and are covered only by the Round 2 audit, read after they were public; one push was not chained to its scan; the scan used from `ec28b26` on is narrower than the scans before it; and five first attempts stopped and were re-run after a change to the scan | this row |
| Rollback plan if a finding surfaces after the flip | pre-visibility | Recorded in D17: re-flip to private immediately (mechanically reversible; clones, caches and indexes are not), redact at HEAD, file the incident in the ledger, re-run the audit round | D17 |
| 19 This file, local portion | pre-visibility | This revision | — |
| 6 One successful hosted run of every push-triggered mandatory job | post-visibility | Satisfied for the push-triggered jobs 2026-09-21 by the `0ff7442` CI and Docs runs (Section 4); the PR-triggered job waits for step 9 | Section 4 |
| 8–14, hosted halves of 15–17, 20 | post-visibility | PENDING — appended with run-ID commitments as each runs; owner: controller. When the step 20 `main` ruleset is authored, `governance / required` may be required only on the understanding that it validates the pull request's title and body and nothing more until the design §10.5 enforcement lands (design §10.5 amendment of 2026-09-25) | — |
| 18 Restored `dependabot.yml` state | post-visibility | PENDING — owner: controller | — |
| D18 §4.1 macOS 27 adoption-matrix amendment | pre-release | **Applied 2026-09-22** (D25 accepted the local run plus the rebuild rehearsal as the §12 alternative; design §4.1 and §12 amended, `[Unreleased]` baseline note added, in the commit that records this row) | Section 3 |
| External-state readbacks (controller, via the API) and operator attestations, each named as such | all phases | Round 1 carries two controller readbacks: the hosted-run failure shape (five runs, zero steps, billing annotation; no run-ID commitments taken) and the Release-to-draft conversion (draft=true, prerelease=false, 2 assets, tag unchanged, 2026-09-20). Operator attestations so far: none required by this round | Section 2 |

## 2. Privacy audit rounds

### Round 1 — 2026-09-20 — pre-visibility-flip audit

**Purpose.** The operator authorized flipping the repository from private to public ahead of the
remaining readiness gates so that hosted GitHub Actions minutes are available again (the private
repository's allotment was exhausted; the last five `CI` and `Docs` runs failed with every job
finishing in under fifteen seconds and zero steps executed). The operator's condition was that a
fresh privacy audit run first and return zero findings for its stated scope. This round is that
audit. It does **not** replace the end-of-roadmap pre-publication audit, which the operator has
directed must still run after the remaining readiness items complete; that later round appends to
this file.

#### Inputs

| Surface | What was covered | Identity |
|---|---|---|
| Origin mirror | Full mirror clone of the GitHub remote: every ref (main, one dependabot branch, six `refs/pull/N/head`, four `refs/pull/N/merge`, the `v26.0.0` tag) and every object present in the mirror, reachable or dangling — which is not every object the host holds (see R1-F5) | main tip `a0186b8`; 3726 packed objects: 1864 blobs, 1627 trees, 234 commits, 1 annotated tag; 13 refs |
| Local checkout | The same classes over the local repository, which is one commit ahead of origin (`053b56e`, not yet pushed) — a superset only with respect to that one unpushed commit; it is not a superset of the mirror, which additionally holds the pull-request refs | 1969 blobs, 1589 trees, 224 commits, 1 tag; 11 refs |
| Commit metadata | Every commit's author and committer name/email, full message body, and the annotated tag object | 234 commits + 1 tag |
| Tree entry names | Every path name in every tree object | all trees |
| GitHub-side text | Repository description; all issues (6) and issue comments (11); all PR review comments (24) and PR reviews (3) across PRs 1–6; discussions (0); wiki (enabled flag set, but no wiki repository exists — clone returns not-found); fork list (1 fork, itself private, created after the D9 remediation) | fetched 2026-09-20 |
| Release | The single GitHub Release (`v26.0.0`; state at audit time: published, not draft or prerelease — converted to a draft later the same day, see Findings): body text, both assets, the extracted Mach-O arm64 binary scanned as raw bytes | tarball sha256 `16d687a0…78c629` (2 753 186 B); extracted binary sha256 `aa3a3f9e…5e0074` (10 450 472 B) |
| Actions | Repository secrets and variables: none defined | listed 2026-09-20 |

Not covered, by design or by access: GitHub Projects (the token lacks `read:project`; no
project is known to exist); traffic/insights pages; any third party's clone, cache, or the
one private fork (a fork's contents are not this repository's to audit and, per D9, are not
reached by remediation here); the private evidence directories on the operator's machine, which
are outside the repository and are never published.

#### Classes searched

email address · phone number (NANP and `+`-prefixed shapes) · street address · geographic
coordinate pair · public IPv4 address · home-directory path (`/Users/<name>`, `/home/<name>`,
`/private/var/...` and `/var/folders/...` user paths) · secret shapes (AWS access key, GitHub
token, Slack token, private-key PEM header, Google API key, bearer strings) · tracker identifiers
(16-digit numbers, tracker web-host URLs) · provider mailbox names (real consumer/provider
domains paired with a local part) · embedded image or binary media (by magic bytes, in every
blob) · operator identifiers (a private denylist of the operator's name variants, handle and
address — matched case-insensitively; see commitments below).

#### Repository-rule banned classes → search coverage

| `AGENTS.md` banned class | Search class(es) | Engines |
|---|---|---|
| real phone numbers | phone | primary, git grep -P, pcre2grep, challenger |
| street addresses | street address; postal city/state/ZIP pairing | primary, git grep -P; challenger (pairing) |
| geocoordinates | geocoordinate | primary, pcre2grep, challenger |
| email addresses | email; provider mailbox | primary, git grep -P, pcre2grep, challenger |
| real names | operator identifier denylist; capitalised name-pair census | primary (denylist); challenger (census, 247 → 87 inspected) |
| message / mail bodies | body markers (`Sent from my`, `wrote:`, forwarded/original-message headers, `X-Apple-`) | challenger only |
| contact / calendar / reminder records, note contents | mailbox-name census; iMessage handle shapes; Apple-account terms; embedded binary/image fixtures | challenger only |
| account identifiers | iCloud/Apple-ID address shapes; UUID/device-id shapes; secret shapes | primary (secrets); challenger (the rest) |
| screenshots | image/binary media by magic bytes and extension | primary, challenger |
| tracker identifiers (repo ruling) | 16-digit ids; tracker URLs | primary, git grep -P, pcre2grep, challenger |

#### Engines and independence

| Engine | Version | Applied to |
|---|---|---|
| Python `re` over raw bytes (primary; script `pii_audit.py`, sha256 `e3b39c4d…1554c`) | CPython 3.13.14 | every object streamed from `git cat-file --batch-all-objects --batch`; commit headers and messages; tag object; tree entry names; ref names; all GitHub JSON/text; release body; release asset bytes |
| `git grep -P` (cross-check for trees) | git 2.50.1 (Apple Git-155), PCRE2 | the tree of **every** ref in the mirror, per class |
| `pcre2grep` (cross-check for non-tree surfaces; script `grepP-crosscheck.sh`, sha256 `5ac0839d…627d2`) | PCRE2 10.47 | all commit messages (`git log --all --format=%B`), GitHub text, release body, release binary bytes |
| Independent challenger (separate reviewer, own regexes, own engines, no access to the primary patterns) | see "Independent challenge" | all surfaces above |

Engine caveats confirmed on this host and worked around, recorded so the next round does not
repeat them: the system `grep` is BSD and has no `-P` (it errors, it does not silently match
nothing); the system `bash` is 3.2 and has no associative arrays; macOS `strings` skips Mach-O
link-edit data unless `-a` is given and even then missed the binary's embedded paths, so binary
scans must be over raw bytes; `pcre2grep` needs `--max-buffer-size` above 1 MiB for the binary.
As `AGENTS.md` already records, `git grep -E` with `\b` matches nothing and was not used.

#### Results (raw hits, then triage)

Raw hit counts are pattern matches before triage. A raw hit is not a finding; the triage
column says what every hit in the class turned out to be. **Units differ by engine:** the primary
column is a match count over every object; `git grep -P` reports matching lines per ref tree;
`pcre2grep` reports matching lines. The engines also used different pattern breadth by design
(independence), so counts are not expected to agree — each disagreement is reconciled in its row.

| Class | Primary raw hits (mirror) | Cross-check (git grep -P, all refs / pcre2grep, messages) | Triage outcome |
|---|---|---|---|
| email | 4596 | 5897 lines / 257 (the cross-check counted every ref's tree separately, so blobs shared by 13 refs count up to 13 times) | All tree hits are on reserved or fixture domains (`example.*`, `*.test`, `*.example`, `*.invalid`, single-letter test domains, `host.local`) or are synthetic-local fixtures on real newsletter/vendor domains used by the Mail newsletter-detection tests. Commit-message hits are `Co-Authored-By` bot/reviewer addresses and `example.com` fixtures named in subjects. GitHub-text hits: 6, all `example.com`. Zero natural-person addresses. |
| phone | 3 | 750 lines / 2 (cross-check pattern counted the `555-01xx` placeholder lines that the primary excluded before counting; the primary's 3 are the non-`555` shapes) | Every value is a `555-01xx` reserved number or the integer `2147483647` (INT_MAX in a bounds test). Both commit-message hits are `555-01xx`. |
| street address | 104 | 151 / 0 (per-ref tree counting again; both engines resolve to the same two fixture strings) | Two fixture strings only: a fictional television address and `1 Main St`. |
| home path | 362 (mirror + release) / 91 (local tree) | 0 / 0 (the cross-check pattern excluded the fixture user names and `/private/tmp`, `/var/folders` roots that the primary counted, and covered trees and messages only, not the release) | Tree and message hits are all fixture users (`/Users/x`, `/Users/tester`, `/Users/example`, `/Users/someone-else`, `/home/example`) or non-user temp roots. **The remaining 270 are in the release binary — see Findings.** |
| operator identifier | 1556 | 0 for the address; name/handle hits are the exception set | Every hit is in LICENSE, NOTICE, README, CODEOWNERS, authorship prose, or git author/committer metadata — the deliberate public-attribution exception recorded in `AGENTS.md` and D15. The operator's email address appears **only** in git author/committer metadata (also within that exception) and nowhere in any blob, message body, GitHub text, or the release. |
| provider mailbox | 452 | (subsumed by email) | Same fixture population as email. |
| tracker | 1979 | 0 / 0 (16-digit ids and tracker URLs that still carry a numeric id) | The primary pattern also counted the literal `GID-REDACTED` markers left by the authorized 2026-08-30 history rewrite and 10-digit GitHub object ids; no live tracker identifier or URL remains in the round-1 surfaces (hosted run logs are a post-round surface: see R1-F7). |
| geocoordinate, public IP, secret shape, image/binary media | 0 | 0 | No hits by any engine on the round-1 surfaces (repository trees and objects, messages, GitHub text, release body); the image/binary negative is about embedded repository fixtures — the release Mach-O is an audited surface, not a fixture. |

Third-party identities: eighteen commits by an outside contributor exist only in GitHub's
`refs/pull/N/head` and `refs/pull/N/merge` refs (zero are reachable from `main`); they carry
that contributor's own chosen git identity, which is their public GitHub attribution and not
this repository's data. Recorded here by the primary pass; the independent challenge raised it as R1-F4 and the operator
dispositioned it in D20.

#### Findings

| # | Surface | Class | Count | Disposition |
|---|---|---|---|---|
| R1-F1 | Release asset `apple-v26.0.0-macos-arm64.tar.gz` → binary `apple` | home-directory path: build-time source and `.build` paths embedded by the Swift toolchain; one distinct user segment | 270 path strings (the challenger counts 135 `N_OSO` debug-map entries; each entry carries an object path and a source path, hence two strings per entry) | **Operator (D17/D18): rebuild with path remapping and no debug map, re-cut as `v27.0.0` after the flip; the `v26.0.0` Release was converted to a draft on 2026-09-20 (asset collaborator-visible only; tag, commit and assets otherwise unchanged).** The token is the operator's account short name (same string as the public handle covered by the attribution exception); no third party; the operator chose removal over exception. |
| R1-F2 | Same tarball, tar member headers | build account user and group names and numeric ids | 2 members | Same as R1-F1 (drafted now; D18 repackaging normalises ownership). Raised by the independent challenge. |
| R1-F3 | Same tarball, AppleDouble `._apple` member | macOS resource-fork metadata (one provenance attribute, no text) | 1 member, 163 B | Same as R1-F1 (D18 packaging sets `COPYFILE_DISABLE=1`). LOW. Raised by the independent challenge. |
| R1-F4 | `refs/pull/3,4,5/head` and `/merge` in the mirror (not reachable from `main`) | outside contributor's display name and plaintext personal mailbox address as author and committer | 15 commits | **Operator (D20): accepted as that contributor's own public attribution for now; PRs to be squash-merged when convenient with the squash author identity read back first; the pull refs are reachable, so they are outside D19's unreachable-object purge and persist until the PRs are closed or the contributor rewrites the branch.** Raised by the independent challenge. |
| R1-F5 | GitHub host, commits API | orphaned pre-rewrite commits still served by id, carrying pre-redaction tracker identifiers | 7 probed ids, all HTTP 200 | **Operator (D19, superseded 2026-09-21): the Support purge was withdrawn; residual by-id reachability of orphaned pre-rewrite objects is accepted because every published surface is clean or operator-dispositioned (pull refs under D20; the drafted release asset pending D18), with the uncovered surfaces (Projects, traffic pages, the private third-party fork, third-party clones) scoped out. No request was filed.** Raised by the independent challenge, verified by the controller. |
| R1-F7 | Hosted workflow-run logs (18 of 305 runs) | tracker identifiers inside historical branch names echoed by checkout steps | 144 hits in 18 runs | **Done (D21, 2026-09-21): the 18 runs' log archives deleted via the Actions API, 18 × 204, read back 18 × 404; no personal data was involved.** Raised by the post-round log scan. |
| R1-F6 | Tracked tree, test fixtures | postal fixture pairing a fictional street with a real US city/state/ZIP (identifies no person; off-standard placeholder) | 81 occurrences, 1 value | **Fixed at HEAD in the commit that records this revision (one source comment, four test lines now use an invented locality). The value remains in the released `v26.0.0` section of the tracked CHANGELOG, which the release-notes rule forbids editing, and in the reachable history blobs of the pre-fix commits; both are accepted under the repository's redact-at-HEAD posture (it identifies no person).** Raised by the independent challenge as informational; promoted to a finding because the rule requires invented values. |

Every other raw hit was resolved to a reserved placeholder, a synthetic
fixture, an integer constant, a GitHub object id, a redaction marker, or the recorded attribution
exception.

#### Independent challenge

A separate reviewer (security-review role) ran its own scanner — 35 pattern classes of its own
design, Python 3.13 `re` over bytes, `pcre2grep` 10.47 and system `grep -aoE` as
cross-engines — over the same mirror (confirming 1864 blobs / 234 commits / 1627 trees / 1 tag /
13 refs, `git fsck --unreachable --dangling` = 0, no `refs/notes` or `refs/replace`), the GitHub
text, and the release (tarball bytes, gzip header, tar member headers, AppleDouble member, raw
Mach-O). It did not read the primary patterns. Its report is retained privately; the value-free
substance:

- **Agrees on every primary class** and adds evidenced negatives: IPv6, MAC-48, iCloud/Apple-ID
  addresses, JWTs, GitHub/AWS/Slack/Google/OpenAI token shapes, private-key headers, URL query
  secrets, message/mail body markers, embedded binary or image fixtures in the repository trees (extension sweep over
  all 792 tree paths plus NUL-in-first-8K over all 1864 blobs; the release Mach-O is an audited
  surface in its own right, not a fixture, and is excluded from this negative), and real personal name pairs
  (247 distinct capitalised pairs reduced to 87 after technical/placeholder subtraction, all 87
  inspected in context: technical bigrams or synthetic fixtures). Tracker URL shapes of any form: 74 hits, all
  three distinct forms end in the `GID-REDACTED` marker (the primary cross-check counted only
  URLs still carrying a numeric id, hence its 0); 16-digit runs: all inside hex digests or
  mangled symbols.
- **R1-F1 mechanism (new detail):** the 270 paths are 135 `N_OSO` debug-map entries in the
  `LC_SYMTAB` string table inside `__LINKEDIT`, one per object file — outside every mapped
  section, which is why `strings` (even `-a`) reports zero. Remediation for the D18 build:
  compile without the debug map (`-gnone`) or `strip -S` the artifact, in addition to path
  remapping.
- **R1-F2 (new, same token, second surface):** the tarball's two member headers carry the
  build account's user and group names and numeric ids — readable with
  `tar -tvf` without extracting. Same disposition as R1-F1 (the Release was then made a draft; it was deleted 2026-09-27 under D34);
  the D18 repackaging must use `--uid 0 --gid 0 --uname '' --gname ''`.
- **R1-F3 (new, LOW):** the tarball contains an AppleDouble `._apple` member (163 bytes,
  one `com.apple.provenance` attribute, no text). D18 packaging sets `COPYFILE_DISABLE=1`.
- **R1-F4 (new, operator ruling D20):** an outside contributor's display name and plaintext
  personal mailbox address are author and committer on 15 commits reachable from
  `refs/pull/3,4,5/head` and `/merge` only (the same person uses a no-reply address on 3 other
  commits). Accepted as that contributor's own public attribution; to be resolved by
  squash-merging the PRs (with the squash author identity read back first); the pull refs are
  reachable, so they are outside the R1-F5 unreachable-object purge and persist until the PRs
  close or the contributor rewrites the branch, after which a served-or-not probe decides whether
  a separate purge request is needed.
- **R1-F5 (new, HIGH — operator ruling D19):** a mirror cannot see objects the host still
  holds after a history rewrite. The controller probed seven pre-rewrite commit ids formerly
  cited in `HUMAN-DECISIONS.md`: all seven are absent from the mirror and all seven returned
  HTTP 200 from the commits API on 2026-09-20, their payloads carrying pre-redaction tracker
  identifiers. The operator ruled: request a purge of unreachable objects and cached views from
  GitHub Support while the repository is private, and flip only after confirmation. The stale
  citations were re-pointed to the rewritten commits the same day.
- **R1-F6:** one fixture postal line pairs a fictional street with a real US city/state/ZIP
  (81 occurrences, one value). Identifies no person; promoted to a finding, fixed at HEAD on 2026-09-21.
- **Not covered by either reviewer:** PR timeline events, commit comments, outdated review
  revisions, Actions logs/artifacts, gists, Projects; non-Latin-script identifiers; semantics
  reachable only by decoding the binary; a distributed store fingerprint across prose.
- **Challenger verdict:** BLOCK until (1) the release artifact's account token is removed
  from both surfaces and (2) the host-side orphan question is closed **before** the flip. Both
  are now operator-dispositioned (D17/D18 rebuild + draft; D19 purge-before-flip, later withdrawn on
  2026-09-21 in favour of accepting the residual).

#### Round 1 addendum — surfaces fetched after the challenge

Fetched and scanned 2026-09-20 with the primary engine (same classes), value-free:

| Surface | Items | Result |
|---|---|---|
| Commit comments | 0 | nothing to scan |
| Issue events (all issues/PRs) | 9 pages | no email, home path, tracker id; phone-shaped hits are JSON ids |
| PR timelines 1–6 | 6 timelines | email hits only on PRs 3–5: placeholder, reviewer no-reply, and the operator's own git identity (attribution exception); the R1-F4 identity class is the same population; no home path or tracker id |
| Commit ids referenced by timelines/events | 60 distinct, 38 absent from the mirror | 35 of the 38 return HTTP 422 (not served); **3 are still served** and are added to the D19 purge request as examples |
| Repository Actions settings | — | `default_workflow_permissions` read; `can_approve_pull_request_reviews` false; `allowed_actions` all (allowlist pending); fork-PR approval unreadable while private |
| Hosted workflow run logs | 305 runs (484 log files, 245 MB), 0 artifacts | Scanned with the primary engine after download (each archive deleted after scanning): email 0, phone 0, home path other than the hosted runner's 0, tracker URL 0, secret shapes 0; handle hits only inside repository URLs (attribution exception); **16-digit tracker identifiers: 144 hits in 18 runs, all inside the names of historical `asana-<id>` branches that the runs checked out** — R1-F7, deletion of those 18 runs' logs pending operator authorization (D21) |
| Wiki | flag enabled, no wiki repository exists | recommendation: disable the flag before the flip (one setting, no content) |
| `pr-metadata.yml` (renamed `governance.yml`, check `governance / required`, 2026-09-25) | uses `pull_request_target` | base-owned metadata validator only, `contents: read`, no PR-code checkout (per `AGENTS.md`); becomes fork-reachable on the flip, which is its designed use |

**Superseded 2026-09-21.** The rows above are dated observations. Re-dispositions since: F5 — the Support purge was withdrawn by the operator, no request was filed, the three still-served timeline ids stay reachable by id under the accepted residual; F6 — fixed at HEAD; F7 — the 18 runs' logs deleted and read back absent (D21); the external-Action allowlist configured; the wiki flag disabled.

#### Commitments (value-free)

- Operator identifier denylist: 5 entries. Salted SHA-256 commitments (first 16 hex digits;
  salt held privately with the evidence): `93c1cebe1bda95b6`, `04c7aa8c282777b2`,
  `88fffad40837d7d6`, `59ce0deae15640ad`, `5d49bb904b369b4d`. Salt commitment
  `67473db6a1d04f92`; the salt is 128 random bits generated for this round, so the commitment
  does not make the low-entropy entries guessable.
- Raw hit lists, triage files (mode 0600), the mirror clone, the fetched GitHub text and the
  release download are retained in the session evidence directory outside the repository and
  are not published.

#### Verdict for this round

Stated scope: the origin mirror (all refs and objects), the local checkout (one commit beyond the
mirror, without its pull refs), commit metadata and messages, tree names, GitHub-side text, PR
timelines, issue events and commit comments, all 305 hosted workflow-run logs, the release and its
assets, plus the host-side reachability probe. Findings for that scope: **seven** — the primary
pass found R1-F1, the independent challenge added R1-F2 to R1-F6, and the post-round hosted-log
scan added R1-F7. **The operator's stated zero-findings condition was NOT met.** The operator
dispositioned R1-F1 to R1-F5 (D17–D20), named the R1-F6 fix and the R1-F7 deletion (D21) as
pre-flip blockers (both completed 2026-09-21), and advanced the flip on that basis. This round therefore does not satisfy
design §18 phase 1's zero-findings gate; the end-of-roadmap round must, for its own stated scope.
Done before any flip: the `v26.0.0` Release converted to a draft (read back draft=true), which
contains F1–F3 on the public surface but does not remediate them — remediation is the D18
rebuild; F4 accepted under D20. Still required before the flip (two items): the pre-push re-scan of the commit that records this revision and the local canonical suite green on that exact pushed commit (the D19 Support gate was withdrawn by the operator on 2026-09-21; the R1-F6 fixture fix, the R1-F7 log deletion under D21 and the repository-level external-Action allowlist were completed the same day).

### Round 2 — 2026-09-22 — end-of-roadmap audit

**Purpose.** The round the operator required after the advanced visibility step: the same
searched classes and the same two engines as Round 1, run against the repository as it
stands after the outside pull requests, the maintainer follow-ups and the Dependabot merge
landed, plus the surfaces that only exist after the flip (post-flip hosted run logs). Its
zero-findings condition is stated for its own scope below.

#### Inputs

- The local checkout at `4f8776a` (tree clean, 12 refs including the four fetched pull refs) and a
  fresh mirror clone of `origin` taken at 08:48 UTC (8 refs). Objects: local 2281 blobs, 255
  commits, 1856 trees, 1 tag; mirror 1966 / 246 / 1755 / 1.
- GitHub-side text (24 files): repository metadata, description, forks, issues, issue comments,
  pull-request review comments, commit comments, releases, the six pull requests' reviews and
  timelines, wiki probe, branches, Actions secrets/variables counts.
- The post-flip hosted workflow-run logs: 25 runs created at or after 2026-09-21T14:00Z
  (24 scanned; one still in progress had no log archive).
- The `v26.0.0` draft Release asset: the same bytes as Round 1 (asset digest unchanged, read
  back from the Releases API), scanned again raw-byte with the primary engine.
- The denylist: the same five private entries as Round 1 (same salted commitments; salt
  commitment `67473db6a1d04f92`).

#### Engines and results

Primary: Python `re` (3.13.14), value-free outputs, over every object, ref name, tree-entry
name, commit header and message, GitHub text field, and release byte. Cross-check: `git grep -P`
(git 2.50.1) over every ref's tree plus `pcre2grep` 10.47 over messages, GitHub text and the
release bytes. Controller scripts hashed before the run and held with the private evidence.
**Independence in this round is narrower than in Round 1:** the two engines were run by the same
controller and there was no separate independent challenger; the independent reviews this round
(a security reviewer and codex) examined the RECORD and its framing, not the scan itself. Units
differ by engine exactly as in Round 1: the primary column counts matches over every object and
surface; the cross-check reports matching lines per ref tree (`git grep -P`) or per file
(`pcre2grep`), so the columns are not expected to agree — each row's triage reconciles them.

| Class | Primary raw hits (local, all surfaces / mirror) | Cross-check | Triage outcome |
|---|---|---|---|
| email | 4810 / 4681 | tree lines 3527; messages 277 | placeholders and provider addresses; the operator's address only in commit-header attribution; 50 other author headers and 30 PR-timeline addresses = the outside contributor's own commit identity (D20); every other address non-personal: placeholder domains (`x.io`, `example.invalid`, …) plus the newsletter-platform classifier patterns and their test fixtures (real platform domains, invented local parts) |
| phone | 33 / 8 | tree lines 472; messages 2 | 2 reserved `555-01xx` in messages; every other match is the integer `2147483647` (Int32.max) in code and docs |
| home_path | 532 / 137 | trees 0; messages 0; release `strings` 0 | 270 raw-byte matches in the draft asset = R1-F1, unchanged; blobs are `/Users/<placeholder>`, `/private/tmp`, `/var/folders` and `/home` fixtures with no session markers; one commit message carries the literal `/private/tmp/...` |
| tracker | 2616 / 2131 | 16-digit 0; tracker URL 0 | the word "asana" (a tool name in docs, `AGENTS.md`, `CHANGELOG.md`, the ledger) and the `GID-REDACTED` markers; no identifier |
| operator_identifier | 1758 / 1653 | operator email 0 outside author metadata | author headers, `github.com/<handle>` URLs, LICENSE/README/NOTICE, the tap slug, `mkdocs` repo name, CODEOWNERS handles in the design, one `Reviewed-by: <handle> (maintainer…)` line — attribution exception throughout |
| street_address | 177 / 120 | tree lines 92 | the two fixtures (`1 Main St`, `742 Evergreen Terrace`) |
| provider_mailbox | 500 / 484 | — | domain fragments inside patterns and prose, no addresses beyond the email class |
| geocoordinate, public_ip, secret_shape, image_or_binary_media | 0 | 0 | — |
| post-flip run logs | — | 0 email / phone / 16-digit / non-runner home path / secret in 24 runs | the handle appears only inside the repository slug, URL and runner path (`Syncing repository:`, `job defined at:`) |
| GitHub text | 4 operator-identifier | 2 email / 2 phone lines (placeholders) | handle and surname as release author and wiki URL; repository public, wiki off, discussions off, forks 0, Actions secrets 0, variables 0 |

#### Verdict for this round

Stated scope: the local checkout and a fresh origin mirror (all refs and objects, commit metadata
and messages, tree names), GitHub-side text including all six pull requests' reviews and
timelines, the 24 post-flip hosted run logs with archives, and the draft Release asset. Result
for that scope: **zero new findings, one recurring in-scope detection.** The two classes that
recur are not alike and are recorded separately. The outside contributor's own commit identity
on pull refs and PR timelines is an ACCEPTED class (D20, ratified and applied) and is not a
finding. R1-F1 — the draft asset's embedded build paths, byte-identical to Round 1 — is a
DEFERRED finding, not an accepted one: the operator chose rebuild-and-re-cut over acceptance
(D17 ruling 2), and D18 remains OPEN until the rebuilt binary and archive are verified free of
every R1-F1 to R1-F3 carrier. **The end-of-roadmap zero-findings gate is therefore NOT yet
closed by this round.** It closes when the D18 rebuild lands, the rebuilt asset is scanned
under the same classes and engines, and that scan is appended here with zero findings; the
draft Release stays a draft until then. Everything else in scope is clean. This round does not
extend to surfaces that did not exist at run time (later commits carry their own pre-push
scans, recorded in Section 3).

**Rehearsal scan appended 2026-09-22 (D23/D24).** The D18 step (4) rehearsal rebuilt the binary
path-free on the operator's macOS 27 host and scanned the rehearsal binary and archive under the
Round 1/2 gated classes (home-directory path prefixes, the denylist terms, the runtime identity
terms) plus the debug-map and archive-header checks: zero hits in every gated class, zero
`N_OSO` entries, one archive member with uid 0, gid 0 and empty owner names, no AppleDouble
member (details in Section 3a). This demonstrates step (4)'s recipe on `3e46e82` — it removes
every R1-F1 to R1-F3 carrier there, to be re-established on the shipped artifact — but the
zero-findings gate still names the published asset: it closes when a publisher
exists (D18 step 4a), the release is cut through it (step 5), and that published asset is scanned
under the same classes with the same result. The draft `v26.0.0` Release is unchanged.

**Closure condition amended 2026-09-26 (D34).** As written above, the gate could not close: it
named the published rebuilt asset, which needs the phase-3 publisher, while design §15 adds the
publisher together with its credentials, listener and environment at a launch whose three hard
preconditions include this gate closed. The operator ruled the `v26.0.0` draft Release deleted.
Before deleting, the controller read the Release back (a draft, not a prerelease, two assets
recorded by name and size only) and kept a private copy of both assets outside the repository, the
archive verified against its published checksum. The Release was deleted through the API at
2026-09-27T01:32Z (`DELETE` 204); its id then answers 404, the repository lists zero Releases,
both assets' public download URLs answered 404 when read at 04:16Z, and the `v26.0.0` tag still
peels to `0f617eb`. Asset ids were not captured, so no asset was read back by id. No workflow
artifact from the legacy release workflow remains: the seven unexpired artifacts, read at 01:51Z,
are hosted CI's own test binaries from 2026-09-26. The gate will close when a fresh round,
recorded here before that launch, finds zero findings for its stated scope; that round has not
run. Its scope is at least every surface Round 1 and its addendum scanned (among them pull-request
text and timelines, issue events and comments, and commit comments), plus the tree, history,
commit messages, objects, refs, workflow logs and artifacts, workflow-run, check-suite and
check-run objects (head branch, head-commit message and author, display title, annotations and job
summaries, not only their logs), Actions caches, repository metadata and Releases, with any
surface it cannot read recorded as NOT READ rather than clean; a NOT READ surface inside that
minimum keeps the gate open until it is read or the operator rules on it in the ledger. The
rebuilt `v27.0.0` asset leaves that scope and keeps the full check the condition above gave it:
before publication, the exact artifact to be published must pass D18 step (4)'s verified-outcome
check and a value-free scan under the round's classes and denylist over the binary, the archive,
the checksum file and the Release notes body, both recorded here first (D34); the denylist scan
stays operator-local, recorded value-free against the sha256 digest of each covered item, the
Release notes body as it will be published included.

**Dispositions and a remediated surface before the fresh round (D35–D38).** Two classes the fresh
round records as ACCEPTED, not as findings, each scoped exactly: the `Claude-Session` lines in
eight operator commit messages on `main` dated 2026-09-07 to 2026-09-14, naming two sessions
(D35); and one session link of the outside contributor's own, in the descriptions of pull requests
3 to 5 and their edit histories (D36). Separately, the D34 review found that the public
workflow-run listing stores each run's head-commit message and head branch, a surface neither
round read. A controller scan of all 373 runs, under the Round 1/2 classes and the denylist with
both engines, found one run from 2026-07-23 whose stored pre-rewrite message carried two denylist
terms, a provider mailbox and two personal email addresses, and 90 further runs on commits outside
`main` carrying tracker identifiers (18 in branch names) or session links (three distinct
sessions: the D36 contributor's and two operator sessions outside D35); the phone and coordinate
detections were a fictional 555 area code, a reserved placeholder and a ratio list. On the
operator's ruling (D37) the controller deleted all 168 runs whose head commit is not on `main` on
2026-09-27, the legacy 2026-08-30 Release run among them (each `DELETE` answering 204, after
re-confirming the approved set and each head commit's absence from `main`), and read back 205 runs
listed, none off-main, and each deleted id answering 404; none of the 168 was cited in this file.
A re-scan of the remaining listing found no personal data, denylist term or tracker identifier;
what remains mirrors commit messages already on `main`. The deletion removed the listing, not the
commits. The personal-data commit still answers by id (read 2026-09-28); it was public 2026-07-23
to 2026-08-19 (the D9 period), and its message was readable in the run listing 2026-09-21 to
2026-09-27. The operator accepted it as a recorded residual under D19 (D38), re-confirming on
corrected facts after a first brief understated both points. A private manifest of the deleted
runs and the per-call results are kept outside the repository. **Known items the fresh round must
read and disposition:** the D36 contributor link in two of the five commit messages on pull
request 3's branch, and in copies of the descriptions embedded in nine comment events in the
public Events feed; the copies of the eight D35 messages stored on run and check-suite objects,
which D35 does not cover as asked; at least 29 off-main commit ids listed in that feed (21 through
push events dated 2026-08-29 to 2026-09-08, 20 of them deleted-run heads, and 8 more, all
deleted-run heads, only through pull-request and review events dated 2026-09-07 to 2026-09-14)
until they age out, about 2026-12-13 at the latest (the feed lists these commits by id only, not
their messages; of the 21 push-listed commits' messages, served by id, nine carry tracker
identifiers, and their email detections are AI co-author addresses and Dependabot's sign-off
address); check suites from a third-party GitHub App (Cursor) on 129 of the 135 deleted runs' head
commits, three of them the head commits of the closed Dependabot pull requests 1, 2 and 6, each
storing its commit message by commit id and all queued with no check runs, the App also a lead for
row 17's installed-App read-back; and the two operator sessions above, in pre-rewrite messages
served by id. The review's other email leads were classified: Dependabot's sign-off address, an AI
co-author address and a reserved example address in pull-request branch commits, and an SSH clone
URL in the fork event; the feed's other email-shaped strings are reserved example addresses and
version pins.

**A committed-data disposition found after those (D41, 2026-09-30).** While rewording test
comments, the controller found that the Messages WRatio tests carried two message texts and a
search term sampled from the operator's Messages store during a live oracle run; the term was also
part of one test's name. They were committed on 2026-07-15, were public from their first push until
the 2026-08-19 containment, and were publicly in the default branch's tree from the 2026-09-21
visibility change until the redaction. The operator confirmed they are real and ruled (D41):
replaced at HEAD with synthetic text, the originals accepted in history as a recorded residual (as
D38 accepted its commit), no history rewrite. The fresh round records every version of that test
file that carries them as ACCEPTED under D41, and must still read the test tree for other samples
of the same class: message, mail, note or contact text taken from a live store into a fixture.

**The review of that redaction found a second sample (D42, 2026-09-30).** The NOTES-L1 test in the
Notes logic tier quoted a three-word fragment of one of the operator's real notes. It was measured
live and committed on 2026-08-19, the containment day (whether it was pushed before the containment
is not established), and was public in the default branch's tree from the 2026-09-21 visibility
change until the redaction. The operator ruled (D42) on D41's terms: replaced at HEAD with
synthetic words, the original accepted in history as a recorded residual, no history rewrite. The
fresh round records every version of that test file that carries it as ACCEPTED under D42.

## 3. Local verification for the visibility-step commit and its successors

The five commits below each ran the full local canonical suite through the signal-reset launcher
before their push (two before the visibility change, three after it); the suite that gates a commit
necessarily runs before that commit's successor records it here.

- `08cc984` (pushed 2026-09-21, before the flip): swiftly toolchain Swift 6.3.3 — `swift build`
  exit 0 (log sha256 `c9bc4c4ed0dbeabc…`), `swift test` exit 0, 1846 tests in 256 suites
  (`dfdea3b0685959d0…`); Command Line Tools Swift 6.3.2 — `swift build` exit 0
  (`ac11c36b97ac26e9…`); Python automation tier, CPython 3.13.14, 764/764, exit 0
  (`93dda1039dd19d0a…`); bats: first pass 451/452, exit 1 (`d9bd869ed2de1412…`, one live-Mail
  transient in an attachment-enrichment test that passed alone), full rerun on the same commit
  452/452, exit 0 (`bfa4d32c2a3db24a…`).
- `bdbbe9d` (the visibility-step commit, pushed 2026-09-21 before the flip): swiftly build
  (`f89b8ad4c23d175b…`) and test, 1846/256 (`e6cc7fcf678c7d85…`); CLT build (`e1b1108a988c9df3…`);
  Python 764/764 on a rerun after a first-pass timing flake in the app-lifecycle module
  (`4ae0758542beecf8…`, rerun `e4fb8d854e105ce2…`); bats 452/452 after one live-Mail transient
  (`041847b6fed3c753…`, `52aac20fc85167dd…`). Pushed on the basis of every test green on the
  commit across those runs.
- `7b46b8d` (first hosted-CI fix, pushed 2026-09-21 15:30Z): one pass, exit 0 end to end —
  swiftly build (`463694d3e514e12c…`) and test 1846/256 (`03bf637cb87ecc90…`); CLT build (`e8bd3deb3ce658f4…`); Python 767/767
  (`12a3fa3778b40658…`); bats 452/452 (`5272ec826afa6a9b…`).
- `0ff7442` (macOS-15 Foundation fix, pushed 2026-09-21 16:17Z): one pass, exit 0 end to end —
  swiftly build (`a686569dc36deb28…`) and test 1847/256 (`2082d571d6ed5ba0…`); CLT build
  (`6d07bf426161a025…`); Python 767/767 (`fd156dac3c992bf4…`); bats 452/452 (`820ab4b0defc6883…`).
- `3e46e82` (Round 2 record, pushed 2026-09-22): run 1 red in the bats tier only — two live-Mail
  attachment-enrichment cases on a degraded host (load above 9, Mail's LaunchServices record
  absent); swiftly build (`038b04726214e542…`) and test 1968/261 (`593663fc0f0fc260…`); CLT build
  (`c26ef3eac0d03ddb…`); Python 767/767 (`c4279016495e14b6…`); bats 450/452 (`dfc1aef66bf6a710…`).
  After the container runtime was stopped and load fell below 8, one bounded rerun on the same
  commit passed end to end, exit 0 at 10:02Z: swiftly build (`91df719f6e4c0de1…`) and test
  1968/261 (`fe9515e9d0e09274…`); CLT build (`21843017eaee8d52…`); Python 767/767
  (`5fb3af480c5ecb83…`); bats 452/452 (`5272ec826afa6a9b…` — byte-identical TAP output to the
  `7b46b8d` bats log above: the bats log carries no timestamps, so an identical pass produces an
  identical file; the four other logs of this run are distinct). Host: macOS 27.0 (26A428) arm64. This
  is the macOS 27 adoption-matrix run the design §4.1 amendment cites (D25), and it includes the
  §12 canary `acceptsSymlinkedParentDotDotWhenFoundationSelectsTheLexicalLeaf`, passed.

**Backfill, 2026-09-26.** Of the 27 commits pushed after `0ff7442`, only `3e46e82` was recorded
here at the time. The table below backfills 24 of the other 26 from the retained outputs of their
canonical runs. Every run went through the canonical runner script, which refuses a commit other
than the one it is given and a tree that is not clean; from `72112c3` on it ran behind a load
gate. That script was lost to a temporary-directory sweep and recreated from its in-session copy
on 2026-09-25; no digest of the earlier bytes was recorded, so the runs before then are not tied
to exact runner bytes. The signal-reset launcher was recreated the same way on 2026-09-26. The
outputs, the tier logs and the salt behind the run commitments now sit in a private directory
outside the repository and outside temporary storage. Each run's output names the full commit it
ran on, that commit matches the row, and each run ended with exit 0. Counts: `swift test`
tests/suites under the swiftly toolchain; Python automation tests run (CPython 3.13.14); Bats
cases passed and skipped out of the planned total (the earlier records in this section count a
skipped case as passed). Each digest is the first 16 hex digits of the SHA-256 of that tier's log.
A log that carries no timestamps is byte-identical across passes that print the same lines, the
Bats log above all, and a commit that changes no Swift source leaves a five-line no-op build log
that repeats whenever its rounded duration coincides, so repeated digests are expected. The run
column gives the run's start (UTC, 2026). Each run ended before the first hosted push run for its
commit was created, checked against the Actions run list.

| Commit | Run start | swiftly build | swiftly test | CLT build | Python | Bats |
|---|---|---|---|---|---|---|
| `7fc4a49` | 09-22 03:45:06Z | `3ce74cb748ea82a9` | 1870/256 `03c5d20f5acbca04` | `937bbcb0d5039ac9` | 767 run, all passed `32e638b2b1e12b0c` | 450 passed, 2 skipped, of 452 `5272ec826afa6a9b` |
| `6f8b852` | 09-22 04:06:20Z | `faa13eb4adfb943c` | 1925/259 `2b4fbac5a9b9770c` | `84472fe48f3b99fe` | 767 run, all passed `37dda8254cc7eb84` | 450 passed, 2 skipped, of 452 `5272ec826afa6a9b` |
| `57984cf` | 09-22 04:24:54Z | `ecfb92c3a685b701` | 1958/260 `4e1a8235b31d1194` | `1e2dc36db24653b1` | 767 run, all passed `dab8b3c56b6a8254` | 450 passed, 2 skipped, of 452 `5272ec826afa6a9b` |
| `9a86125` | 09-22 05:06:52Z | `75ec0fe3a60c25bc` | 1958/260 `52d9511a12c945b0` | `a4700420e2785ac6` | 767 run, all passed `cc8bc99bdae91d15` | 450 passed, 2 skipped, of 452 `5272ec826afa6a9b` |
| `8e9be32` | 09-22 06:38:55Z | `e44f0b056c96c95b` | 1966/261 `0e9b7d08fd13c728` | `3655c79971b064f2` | 767 run, all passed `d46ab8c390985149` | 450 passed, 2 skipped, of 452 `5272ec826afa6a9b` |
| `afc6779` | 09-22 07:12:54Z | `553067e2c938664b` | 1966/261 `559508ef4f90a94a` | `7e15481acb1a3986` | 767 run, all passed `91f841f8f5431f3b` | 450 passed, 2 skipped, of 452 `5272ec826afa6a9b` |
| `098e784` | 09-22 07:40:52Z | `c88e164042eb6e82` | 1966/261 `064a22798932eb46` | `ac11c36b97ac26e9` | 767 run, all passed `8a7bd970fe678ace` | 450 passed, 2 skipped, of 452 `5272ec826afa6a9b` |
| `4f8776a` | 09-22 08:31:11Z | `b71d7c382ba9e4ba` | 1968/261 `38de45662ed42230` | `8ec6a65c6a351162` | 767 run, all passed `fa93d16081dd8a75` | 450 passed, 2 skipped, of 452 `5272ec826afa6a9b` |
| `ec28b26` | 09-22 17:17:07Z | `4ab897f42354c48b` | 1968/261 `00f3b904145631b9` | `95268768f9ee8c74` | 767 run, all passed `675a595e085a4d84` | 450 passed, 2 skipped, of 452 `5272ec826afa6a9b` |
| `b94cc80` | 09-23 04:26:51Z | `6b1bad5cd5d42fd1` | 1968/261 `4322dafac4ef04dd` | `9d13216546ddfd7d` | 808 run, all passed `6e46dfb0d24e1c34` | 450 passed, 2 skipped, of 452 `5272ec826afa6a9b` |
| `6e06af4` | 09-23 05:17:29Z | `e4062a4746203926` | 1968/261 `c664bc62019e2700` | `221be07ae6d6844f` | 810 run, all passed `dc57fca3c2e1fa40` | 450 passed, 2 skipped, of 452 `5272ec826afa6a9b` |
| `eb728d3` | 09-23 16:20:43Z | `fdb8ebf9a06bc117` | 1968/261 `c960910d76164ed0` | `6a3eb3f08895abef` | 852 run, all passed `6c1ae18194ca3532` | 450 passed, 2 skipped, of 452 `5272ec826afa6a9b` |
| `c8b8288` | 09-24 03:44:29Z | `80b7f20e8e2d1987` | 1968/261 `25924f85eae2152c` | `221be07ae6d6844f` | 874 run, 1 skipped `05ebaaa8e73ee480` | 450 passed, 2 skipped, of 452 `5272ec826afa6a9b` |
| `72112c3` | 09-24 05:16:03Z | `2bceab4bc24e8597` | 1968/261 `caa0624025d4def5` | `17b88ab957fac4ca` | 880 run, 1 skipped `97e20a59b6c189da` | 450 passed, 2 skipped, of 452 `5272ec826afa6a9b` |
| `1920b2a` | 09-24 06:23:16Z | `b307aa6497c5d3cf` | 1968/261 `7c614ecefa33f9cb` | `63af02ed8c63bedf` | 880 run, 1 skipped `af07cc989096affd` | 450 passed, 2 skipped, of 452 `5272ec826afa6a9b` |
| `723f2dc` | 09-25 03:50:04Z | `05c213712f889d7e` | 1968/261 `b90e01d3432600a5` | `9ab38e7bdf4f124a` | 880 run, 1 skipped `dc85af02d13c569b` | 448 passed, 4 skipped, of 452 `d201823cc437a76d` |
| `e48ec1e` | 09-25 23:06:58Z | `ce17ab6bbf23d990` | 1968/261 `4dbbd432adc88243` | `63af02ed8c63bedf` | 896 run, 1 skipped `dc451c4809e76c29` | 448 passed, 4 skipped, of 452 `d201823cc437a76d` |
| `056fcd2` | 09-26 00:08:04Z | `0bbf9e51908dad4b` | 1968/261 `d33b33ff7ca2d179` | `7e15481acb1a3986` | 896 run, 1 skipped `be81a1cc5de2297f` | 448 passed, 4 skipped, of 452 `d201823cc437a76d` |
| `d5c1c34` | 09-26 01:56:19Z | `ca7eacda5201f59c` | 1968/261 `51ec73c231e923db` | `95eb93d0f888ab32` | 896 run, 1 skipped `6df264911a9d78fe` | 448 passed, 4 skipped, of 452 `d201823cc437a76d` |
| `cd7a46f` | 09-26 04:12:36Z | `d4c2b04a79a23d48` | 1968/261 `102c6d38ea95d3cb` | `461ddee478e5138b` | 896 run, 1 skipped `07a71124e1e057eb` | 448 passed, 4 skipped, of 452 `d201823cc437a76d` |
| `609147a` | 09-26 05:13:40Z | `d90b02f488782440` | 1968/261 `42aee0b576ce44c4` | `21843017eaee8d52` | 904 run, 1 skipped `bacdc9474c68886b` | 448 passed, 4 skipped, of 452 `d201823cc437a76d` |
| `40eb229` | 09-26 06:31:27Z | `1b3cf9d8d7db09ba` | 1968/261 `3243d79bb4f8419a` | `e7d0fe294176a04d` | 913 run, 1 skipped `a761ed356fbfa1cc` | 448 passed, 4 skipped, of 452 `d201823cc437a76d` |
| `bdb6a86` | 09-26 09:45:43Z | `60914beedfb99951` | 1968/261 `47190f9a12ab685f` | `f5f3ffb6402a7800` | 954 run, 1 skipped `1cddfac113358848` | 448 passed, 4 skipped, of 452 `d201823cc437a76d` |
| `7953268` | 09-26 11:26:09Z | `310b6839873a475e` | 1968/261 `7b0ee8acbda1fdba` | `e01bd8d7d1886375` | 954 run, 1 skipped `bbc4994f6b8ceb52` | 448 passed, 4 skipped, of 452 `d201823cc437a76d` |

Runs that did not pass, and gaps. `ec28b26`'s first run (16:09Z) failed one test, the wall-clock
bound in "parser is linear, not quadratic, in tag count" (5.9 s against a 5.0 s bound, on a loaded
host); the recorded second run on the same commit passed every tier. A first run on `cd7a46f`
ended during its Command Line Tools build without writing an exit line, after the swiftly tiers
had passed and before any tier reported a failure; it is not evidence either way. `e48ec1e`'s
first launch failed before any tier ran, because the runner script had been swept from the
temporary directory; the recorded run is the relaunch. From `723f2dc` on, two further live-Mail
thread cases skip on a local store-state precondition, which is why the Bats skip count rises from
two to four. No outputs were retained for `7049736`; the controller's private notes record its run
red in Bats on two live-Mail attachment cases, with a Mail-only Bats re-run passing on the same
tree, so it has no single green run, and it was the head of its own push. For `19f48a2`, the Swift
and Python tier logs survive under that commit's name, but neither a Bats log nor the runner
output that names the commit, so it is not recorded as evidence; the notes record its Bats stage
red on the same two live-Mail cases, and it reached `origin` in the same push as `7fc4a49`.
`053b56e` and `a52c44e` (2026-09-21) have no green run on their exact commits and no retained
logs. The notes record `053b56e` red in the Python and Bats tiers, and `a52c44e` red in the Python
tier on its first run and in Bats teardown on its second. The Python failures were a launcher
artefact (signals ignored at shell entry), fixed by the signal-reset launcher rather than by a
commit, and the Bats teardown failure was fixed in `08cc984`. Both commits reached `origin` in the
same push as `08cc984`, whose suite is recorded above as green across a run and a full Bats
re-run.

**Pre-push scans after `0ff7442` (backfilled 2026-09-26).** `7049736` through `4f8776a` were read
by the Round 2 audit (2026-09-22, 08:48–08:53Z; the checkout and a fresh origin mirror at
`4f8776a`) after they were already public, for up to nearly sixteen hours: post-push coverage,
with zero new findings. Before their pushes, the controller's private notes record clean pre-push
scans for `8e9be32` (Python `re` and `pcre2grep` named), `afc6779`, `098e784` and `4f8776a`, whose
scan inputs are retained, and privacy scans of the pull-request additions before the squash merges
`7fc4a49`, `6f8b852` and `57984cf`, which did not cover the squash messages or conflict
resolutions; no pre-push scan record is retained for `7049736`, `19f48a2`, `7fc4a49`, `6f8b852`,
`57984cf` or `9a86125`. `3e46e82`, the Round 2 record, postdates that audit. Its pre-push scan
reported four raw hits, all fixture literals the record quotes (a 32-bit integer maximum, two
placeholder street addresses and a temporary-directory path), and the push was not chained to that
scan, so it went ahead regardless: a process defect. The four were cleared only by reading them at
review time; the `ec28b26`-era pattern set has no class for any of them, so re-running it over the
retained input verifies nothing, while the hardened scanner described below, run over that input
on 2026-09-26, finds those four and two word-form tracker matches, and nothing else. From
`ec28b26` on, each push ran through a controller script that puts the scan and the push in one
`&&` chain. The scan reads the added lines of `origin/main..HEAD` and the commit messages, with
`pcre2grep` for standalone 16-digit numbers, the local temporary-directory marker, the operator's
home path, e-mail-shaped strings other than `noreply` addresses, and `noreply` addresses outside
the co-author domain, and with a Python substring match against the operator's private denylist.
That set is narrower than the pre-push scans before it: it excluded the `+++` path lines, so
changed file names were not scanned, and it has no phone, street-address, geocoordinate,
secret-shape or public-IP class, so those reach the chained scan only through the denylist's exact
substrings, and a third party's value would pass it. The controller adopted it after `3e46e82`,
without separate review, instead of the recorded plan to allowlist the fixture literals. Neither
half checks that the scan input was built completely, a `pcre2grep` engine error would have read
as clean because the scripts negate its exit status, and the Python half fails closed only on a
read error (an empty denylist would pass). The first attempt stopped for five of the sixteen
pushes, and each was re-run after a change to the scan made at that push: `ec28b26` (the address
pattern matched the required co-author trailer; it now excepts `noreply` addresses), `b94cc80` (a
reserved example-domain fixture; example domains are now excepted), `c8b8288` (a decorator matched
the address shape; a word-character lookbehind was added) and `bdb6a86` (a sixteen-zero fixture;
that run is now excepted), each a pattern change the controller made without separate review; and
`e48ec1e` (the sanctioned CODEOWNERS handle lines), whose re-run removed exactly the 14 lines of
the CODEOWNERS rule shape from the denylist match only, failing on any other count, while
`pcre2grep` still read the full input. That exemption ran under an in-session operator
authorization on 2026-09-25 that is recorded only in the controller's private notes (D15 and D30
authorize the handle in CODEOWNERS, not a scan exemption), after a harness safety check had
refused a first combined attempt. Push outputs are retained for `bdb6a86` and `7953268`; for the
other fourteen, that each push went through its script rests on the retained scripts, which pin
`HEAD` to the commit and `origin/main` to its parent, and on each script predating its commit's
first hosted push run. The commit that records this paragraph is to be pushed through a hardened
chain, whose actual output the next revision records, including any stop and re-run: the audit's
nine regex classes (tracker and home-path broadened) plus a session-link class; a denylist match
that also runs over normalised text (format characters removed, NFKC, whitespace collapsed), with
lines ending in a hyphen joined both without and with the hyphen; the names of every changed file,
and a check that the number of added lines in the scan input equals git's own numstat total plus
one header line per file with content; both engines required to report clean by exact exit status,
each under a time limit; the push refused unless the range is exactly one commit with no binary
change; the scanner, denylist and exemption files pinned by digest; and the commit pushed by its
id and read back. That push is configured with two count-bounded tracker-class exemptions, for
word mentions of the tracker's name and, on one re-added line, the repository's redaction
placeholder for tracker identifiers, and an exemption can no longer cover the denylist. Residuals:
the regex classes are ASCII-only and run over the raw input, where each added line keeps its diff
marker, so a value split across lines is caught only if it is a denylist term; a denylist term
whose first half sits on an unchanged line is not seen; and author identity is not scanned.

**Recorded at the time from `3b1fbef` on.** `3b1fbef` (first hosted push run created 2026-09-26
23:44Z): one run, exit 0, started 23:28:01Z — swiftly build `a494a9b96da07f39` and test 1968/261
`bb00f9712ae46573`; CLT build `63af02ed8c63bedf`; Python 954 run, 1 skipped `baeca389bd8bba65`;
Bats 448 passed, 4 skipped, of 452 `d201823cc437a76d`. A first launch on the same commit was
stopped about 30 seconds after it began, once its swiftly build and test tiers had completed,
because its log-directory argument named `7953268`'s retained logs; the two logs it had
overwritten were restored from the durable copy and re-verified against the digests in the table
above before the relaunch. Its push ran through the hardened chain described above on the first
attempt, with no stop: `pcre2grep` exit 1, the scanner exit 0 with the two configured exemptions,
pushed by commit id and read back as `origin/main`; the push output is retained. `8ba43b1` (first
hosted push run created 2026-09-27 02:23Z): two runs. Run 1, started 02:01:00Z, stopped at the
Python tier (exit 3) after the swiftly and CLT tiers had passed: one of 954 Python tests failed,
the app-lifecycle umask test's `setup` subtest, which reported status 124 from the Bats helper's
phase-timer cleanup. The log does not show which of the three conditions that end that cleanup in
status 124 held; the suspected one is its TERM-to-KILL window of ten 0.1-second polls, which host
load can overrun (the run's load gate opened at a one-minute load average of 4.04 on six cores,
and the relaunch's gate read 6.52 six minutes later). The commit changes no code, and the flake is
filed for a fix; run 1's output and logs are retained. Run 2, started 02:07:05Z, exit 0: swiftly
build `130773d91361f916` and test 1968/261 `000c349763e30819`; CLT build `764fdbcd2f48a095`;
Python 954 run, 1 skipped `fd2350795d25088f`; Bats 448 passed, 4 skipped, of 452
`d201823cc437a76d`. Its push ran through the same chain on the first attempt, with no stop and no
exemptions: `pcre2grep` exit 1, the scanner exit 0, read back as `origin/main`. `dd2114f` (first
hosted push run created 2026-09-27 05:53Z): three runs. Runs 1 and 2, started 04:53:28Z and
05:10:50Z, passed the swiftly, CLT and Python tiers and stopped at Bats (exit 4), each on one of
the two live-Mail attachment cases this row's history already names: run 1 on "mail attachments
list <id> carries live metadata on the wire", run 2 on "mail attachments save --dry-run previews
the LIVE attachment order", both reporting that live Mail.app enrichment returned its degraded
fallback on an oracle-confirmed message. Three isolated re-runs of those two cases on the same
binary failed once and passed twice, so the degrade is intermittent; the commit changes no code,
and the flake is filed for a fix. Both runs' outputs and logs are retained. Run 3, started
05:36:43Z, exit 0: swiftly build `17aac0e973a5c32b` and test 1968/261 `5e364f1c023aabcd`; CLT
build `f5f3ffb6402a7800`; Python 954 run, 1 skipped `69aaf51678358549`; Bats 448 passed, 4
skipped, of 452 `d201823cc437a76d`. Its push ran through the same chain on the first attempt, with
no stop and no exemptions: `pcre2grep` exit 1, the scanner exit 0, read back as `origin/main`.
`e011d83` (first hosted push run created 2026-09-28 05:44Z): one run, exit 0, started 05:28:28Z —
swiftly build `bdd5637c5f4573cd` and test 1968/261 `56b54f4fddfb021b`; CLT build
`63af02ed8c63bedf`; Python 954 run, 1 skipped `050d22db84d42e9d`; Bats 448 passed, 4 skipped, of
452 `d201823cc437a76d`. Its push ran through the same chain on the first attempt, with no stop and
no exemptions: `pcre2grep` exit 1, the scanner exit 0, read back as `origin/main`. The codex
review of its final text ran after one round was unavailable (model at capacity), which the OMC
fan-out covered.
`1f8f3ab` (first hosted push run created 2026-09-30 05:31Z): five runs. Runs 1, 2 and 4, started
02:27:10Z, 04:08:57Z and 04:51:33Z, passed the swiftly, CLT and Python tiers and every Bats case,
and stopped at Bats (exit 4) on 3, 5 and 3 `teardown_file` failures, each `info-fields-missing`:
the Bats app-lifecycle helper cannot parse the relative-age check-in line (`N seconds ago,
<timestamp>`) that macOS 27's `lsappinfo` prints for an app checked in within about five minutes,
so a file whose tests launch Notes or Messages fresh fails its teardown, and every later file
fails with it. It reproduced in isolation from a clean state, is filed for a fix, and run 5 worked
around it by opening Notes and Messages beforehand until their check-in lines printed the plain
form. Run 3, started 04:50:19Z, stopped at the swiftly test tier (exit 1) on 8 issues in the
owned-process-cleanup suite's start-up-deadline tests, the residual the hosted-CI learnings
already name; that suite passed in runs 1, 2, 4 and 5 on the same commit, and the flake is filed
for a fix. The commit changes no Swift source and no Bats helper. All four runs' outputs and logs
are retained. Run 5, started 05:14:01Z, exit 0: swiftly build `f5c0b5e6af3add97` and test
1968/261 `267a4c6ed6cc916a`; CLT build `9ab38e7bdf4f124a`; Python 955 run, 1 skipped
`f0fb361edda35de4`; Bats 450 passed, 2 skipped, of 452 `5272ec826afa6a9b` (two fewer skips than
`e011d83`'s run, with Notes and Messages open). Its push ran through the same chain on the first
attempt, with no stop and no exemptions: `pcre2grep` exit 1, the scanner exit 0, read back as
`origin/main`.
`53eae85` (first hosted push run created 2026-09-30 06:44Z): one run, exit 0, started 06:27:35Z,
with Notes and Messages opened beforehand as the `1f8f3ab` workaround required: swiftly build
`133043380a4b26c2` and test 1968/261 `7c33faa2cdeb3e76`; CLT build `abc0ebc90ab114fe`; Python 955
run, 1 skipped `b48cb9b5d8256834`; Bats 450 passed, 2 skipped, of 452 `5272ec826afa6a9b`. Its push
ran through the same chain on the first attempt, with no stop and no exemptions: `pcre2grep` exit
1, the scanner exit 0, read back as `origin/main`.
`ca4392d` (first hosted push run created 2026-09-30 07:18Z): one run, exit 0, started 07:02:28Z,
with none of the six apps open beforehand, so every Bats file that needs one launched it fresh:
swiftly build `ee6bb2d654046d28` and test 1968/261 `77fd8ee1ff706c6d`; CLT build
`5972bb0e19e41640`; Python 957 run, 1 skipped `ae66a684bd40fb61`; Bats 450 passed, 2 skipped, of
452 `5272ec826afa6a9b`. Afterwards `lsappinfo` found no record of any of the six apps, so no app
the run launched was left running. With no app open beforehand it skipped two Bats cases, as
`1f8f3ab`'s run 5 and `53eae85`'s did with Notes and Messages open, so the two fewer skips than
`e011d83`'s run noted for `1f8f3ab` are not explained by those apps being open; the live-Mail
store-state precondition recorded above for the two-to-four change is the likelier account. Its push ran through the same chain on the first
attempt, with no stop and no exemptions: `pcre2grep` exit 1, the scanner exit 0, read back as
`origin/main`.
`a4de516` (first hosted push run created 2026-09-30 08:56Z): one run, exit 0, started 08:40:16Z:
swiftly build `fd1dc3e1ca999a66` and test 1968/261 `4f98abe5380c84dc`; CLT build
`63af02ed8c63bedf`; Python 983 run, 1 skipped `fd1aefbed8bbfe43`; Bats 450 passed, 2 skipped, of
452 `5272ec826afa6a9b`. Its push ran through the same chain on the first attempt, with no stop:
`pcre2grep` exit 1, and the scanner exit 0 with one exemptions file of six exact literals, each
with its count pinned, all of them the synthetic isolated-HOME segment (a directory named `home`
inside the driver's `hosted-build` and `hosted-test` stage roots) that the scanner's home-path
class matches in the new tests and learnings; read back as `origin/main`. The controller wrote
that file for this push and pinned it by digest (SHA-256 prefix `748691e970f4fcf3`); it had no
operator authorization and no separate review, the same standing as the pattern changes above.
`675eebb` (first hosted push run created 2026-09-30 09:15Z): one run, exit 0, started 08:59:52Z:
swiftly build `6975a9a8489bb15e` and test 1968/261 `23ef78d1d233ebb5`; CLT build
`cbc928fd8001388e`; Python 983 run, 1 skipped `2311b5ad0c4fc597`; Bats 450 passed, 2 skipped, of
452 `5272ec826afa6a9b`. Its push ran through the same chain on the first attempt, with no stop and
no exemptions: `pcre2grep` exit 1, the scanner exit 0, read back as `origin/main`.

### 3a. D18 step (4) rebuild rehearsal — 2026-09-22 (D23 grant, D24 exact command)

**What ran.** A one-shot controller ran a frozen invocation on the operator's host against
`3e46e82` (clean tree asserted before and after): `swift build -c release` with resolution
disabled (the pinned dependency pre-checked in the local SwiftPM cache), `-Xswiftc -gnone`,
`-file-prefix-map`/`-ffile-prefix-map` for the repository and scratch prefixes, `-Xlinker
-oso_prefix` on the scratch prefix, `strip -S` followed by ad-hoc `codesign --force --sign -`
and `codesign --verify`, then `COPYFILE_DISABLE=1 bsdtar --uid 0 --gid 0 --uname '' --gname ''
--no-xattrs --no-mac-metadata`. Combined recipe, no ablation: the outcome is not attributed to
any single flag, and `-gnone` forfeits DWARF (a publisher decision to revisit). The packet
(README, invocation, controller) was reviewed over six rounds (codex; security reviewer; critic)
and its digests were frozen before the grant; the controller re-hashed the copy it ran and the
as-run digests equal the reviewed ones (README `46cf8018ae95eb9a`, invocation
`aec133cdf3e01715`, controller `793841dde16545c5`). Wall time about two minutes under a
2400-second bound. PATH was pinned to the system directories for the whole run.

**Toolchain.** Command Line Tools Swift 6.3.2 (swift-driver 1.148.6), ld-1267, bsdtar 3.5.3 /
libarchive 3.7.4, CPython 3.13.14 for the scanner, macOS 27.0 (26A428) arm64.

**Result — PASS on every gate.** `nm -ap`: 0 `N_OSO` entries (the Round 1 asset had 135).
`strings -a`: 0 home-directory lines. Raw-byte scan of the binary and of the decompressed archive
(plus the gzip container's own bytes): 0 hits in every gated class — home-directory prefixes
(`/Users/`, `/private/tmp/`, `/var/folders/`, `/home/`), the five denylist terms of Rounds 1–2,
and the runtime identity terms (account short name and gecos words, derived at run time). Both
scanner processes exited 0. Informational classes, reviewed and expected: 5 `~/` and 1 `$HOME`
(the product's own credential-directory list and `--allow-outside-home` help text), 1
`/Volumes/` (same help text); 0 `/tmp/`, `/opt/homebrew/`, `workspace/apple-cli`, `.build/`,
`/src/`, `/build/`. Archive: exactly one member `apple`, uid 0, gid 0, owner and group names
empty, no PAX keys, no global PAX header, no AppleDouble member. Zero network fetches (one
SwiftPM fetch line, satisfied from cache). `apple --version` reports `26.0.0` — the constant is
frozen by design and untouched by the run; the publisher sets the release number. Binary
8,804,144 bytes, sha256 `79f5bca6c9a6f545…`; archive 2,417,542 bytes, sha256 `6f13cbdd8fda3b22…`.

**What this does and does not settle.** It demonstrates D18 step (4) on `3e46e82`: this recipe,
on this toolchain, removes every R1-F1 to R1-F3 carrier, as a verified outcome. It does not
produce a release: no publisher path exists (step 4a; the design's phase 3 bot publisher is
unbuilt), so no asset was published and the end-of-roadmap gate above stays open on the published
asset. **Disposition of the rehearsal artifacts:** the rehearsal binary and archive were never
published, are not a release input, and are not retained beyond the session scratchpad (the
0700 packet directory under the session's private temporary root, deleted with the session); the
two digests above identify that rehearsal artifact only — no reproducible-build claim is made,
and the publisher builds and scans its own artifact on the exact release commit, re-establishing
steps (2) and (4) there. Only the value-free record above enters the repository.

## 4. Post-visibility hosted evidence

**Visibility change:** 2026-09-21 14:31Z, by the controller through the API, after the D17
blocker list closed (R1-F6 fixture fix in `bdbbe9d`, D21 log deletion read back as 18 × 404 at
13:19Z; the D19 Support gate withdrawn by the operator the same day). Readbacks immediately after:
visibility public; wiki disabled; forks 0; the `v26.0.0` Release still a draft.

**Actions settings, read back 2026-09-21 15:08Z:** `default_workflow_permissions` read;
`can_approve_pull_request_reviews` false; `allowed_actions` selected, GitHub-owned allowed,
verified-creator allowed false, pattern allowlist exactly one entry (the pinned `setup-uv`
publisher, any ref; at that read-back SHA pinning was enforced only by the committed `action_pins.py`
policy, the repository setting being off; the setting was turned on 2026-09-26 under D32, below); fork-PR contributor approval `all_external_contributors`. Open pull
requests at the flip: three outside contributions and one Dependabot Actions bump; none were run,
approved or merged as part of this step.

**Step 17 API read-backs, 2026-09-24 05:49Z** (a read-only controller retained in the private
scratchpad alongside the raw responses; controller SHA-256 prefix `7bebd4bdc5c44a04`, raw-response
digest prefix `72c4d665eca2e20d`; values below are counts, booleans, settings, status codes and
digests only). Endpoints walked, all GET: repository; Actions secrets and variables; Dependabot
secrets; environments; deploy keys; the account-installations listing; Actions permissions,
selected actions, workflow permissions, outside-access, fork-PR contributor approval and the
private-repository fork-PR toggles; OIDC subject customization; Pages; code-owners errors;
collaborators (all and outside); rulesets. Results: repository Actions secrets 0, Actions
variables 0, Dependabot secrets 0; environments 0, so no environment secret, variable or
protection rule exists to read; deploy keys 0; the Pages endpoint answers 404 and `has_pages` is
false (no site configured); `default_workflow_permissions` read and
`can_approve_pull_request_reviews` false, unchanged since 2026-09-21; `allowed_actions` selected,
GitHub-owned allowed, verified-creator allowed false, one allowlist pattern, and the
repository-level `sha_pinning_required` setting off at that read-back (pinning enforced by the
committed policy; the setting was turned on 2026-09-26 under D32, recorded below); fork pull-request contributor approval
`all_external_contributors`; the private-repository fork-PR write-token/secrets toggle endpoint
answers 404 and the outside-access endpoint 422 on the public repository, as documented for that
state — the public surface exposes no separate fork write-token or fork-secrets toggle, so §9's
write-token and secrets halves are discharged by `default_workflow_permissions` read plus the
zero secret and variable counts above, and that substitution is recorded here rather than
inferred; `allow_forking` true, forks 0, wiki off, Pages off, discussions off; OIDC subject claim
left on the default template (`use_default` true) with the immutable subject on, and the static
scan refuses any workflow permission for `id-token` or `attestations` (both are in its forbidden
scope set), while no repository-level attestation setting was queried and the release-level
attestation GitHub generates on its own is out of this read-back's reach — attestation settings
are recorded NOT READ; rulesets 0 (the active `main` ruleset remains a §15 precondition);
`.github/CODEOWNERS` absent from the tree and the code-owners errors endpoint 404 at the time of
this read-back — step 17 expects the file to be present, to name only the operator, to cover every
§10.5 control-plane path and to be error-free; none of that held on 2026-09-24, so the read-back
was NOT SATISFIED; the file was then authored under D15 (RATIFIED 2026-09-07; an earlier revision
of this sentence wrongly called that decision unrecorded) with the D30 go-ahead (2026-09-24) in the
design §18 step 5 CODEOWNERS commit, and the errors-API read-back was to be re-run against it once
that commit was on `main`; performed 2026-09-25 after `e48ec1e` landed (read-only controller, SHA-256
prefix `b300299e93d30618`, raw responses in the private scratchpad): code-owners errors API status 200
with 0 errors on the default branch and again at the exact commit, contents API status 200 for the
file — the present-and-error-free read-back is satisfied, with single-user ownership and manifest coverage checked by
`Tests/automation/test_control_plane.py` under its stated residual, and no ruleset yet requiring
code-owner review, so the file parses but binds nowhere until step 20; collaborators were 3 by count on
2026-09-24, roles admin 1 and read 2, of which outside collaborators 2; the grants' dates were not
read back and they were surfaced for an operator ruling before any change. Superseded by D31
(2026-09-25): on the operator's in-session instruction naming the account, the controller issued
the collaborator `DELETE` interactively through the CLI — the only mutating call in this read-back
set, no controller script, response HTTP 204 — then re-read the list read-only: collaborators 2 by
count, roles admin 1 and read 1, of which outside collaborators 1. That post-removal reading is
the expected set from 2026-09-25; the 2026-09-24 counts above are history, not the comparison
baseline, and a salted commitment over the kept account's numeric id under a dedicated collaborator salt
(D31) lets a later read-back check identity as well as count. The design's stated collaborator expectations (only administrator, only
environment reviewer, no other write-capable actor) are satisfied by the kept read grant, and the
two interactions that made the ruling worth taking are discharged for it: fork pull-request
contributor approval read back as `all_external_contributors`, which covers users without write
access, so that collaborator's fork runs require approval as design §9 expects; and code-owner
eligibility requires write access, which a read grant does not confer — and the tracked CODEOWNERS
file names the operator alone (single-user ownership checked by `Tests/automation/test_control_plane.py`,
not by the errors API, which reports only that the file parses with 0 errors); installed GitHub Apps
and their permission scopes NOT READ — the account-installations endpoint answered 403 to the
token in use, the cause was not established from the response alone (GitHub's documentation for
the endpoint names GitHub App user tokens; an insufficient scope produces the same code), so the
inventory (the installations together with each installation's repository list, as step 17 asks)
is OPEN and is retried with a token of the documented class before falling back to an operator UI
read-back; the pre-visibility private-forking observation the design lists is retired by design
after visibility in favour of these public read-backs. These values — with the collaborator set as amended by D31 (collaborators 2,
admin 1, read 1, outside 1), the CODEOWNERS item as read back on 2026-09-25, and the merge-method
and `sha_pinning_required` values as applied and read back under D32 on 2026-09-26T01:40Z (paragraph
below) — are the recorded
expected set for step 17: any later divergence is a finding, and the set is re-read (the CODEOWNERS
trigger fired 2026-09-25) when the `main` ruleset activates, whenever a collaborator grant changes,
whenever a repository merge-method or Actions-permissions setting changes (this trigger fired
2026-09-26 under D32), and before the §15 preconditions are asserted.

**CODEOWNERS commit privacy scan, 2026-09-25** (the fresh scan D15's sequence step (2) requires;
controller read-back over the staged diff of the commit that adds `.github/CODEOWNERS`, the
control-plane manifest and their test): two engines, Python `re` and `pcre2grep`, searched the
added lines for e-mail shapes, RFC-shaped phone numbers, sixteen-digit identifiers, coordinate
pairs and `@`-prefixed handles. No unexpected hit in any class: phone, identifier and coordinate
classes had zero hits; the only e-mail-shaped hit is the `alice@example.com` placeholder inside
the test's hermetic cases (an example-domain value the repository rule prescribes); every handle
hit is a CODEOWNERS pattern line naming the operator (the one occurrence D15 admits), a Python
decorator, an `@alice`/`@bob` placeholder in those same hermetic cases, or one of the two literal
tokens in the AGENTS.md bullet (`@handle`, the placeholder for the code-owner form, and
`@AGENTS.md`, the import directive's name). The whole-tree state after the commit is
the one the AGENTS.md attribution sentence describes: the code-owner form of the handle in
CODEOWNERS only, the repository-owner URL segments under the standing exception.

**D32 repository settings, applied and read back 2026-09-26T01:40Z** (controller, through the
API, on the operator's option-A answer; values are settings and status codes only): merge
settings before → after: `allow_merge_commit` true → false, `allow_rebase_merge` true → false,
`allow_squash_merge` true → true, `squash_merge_commit_title` COMMIT_OR_PR_TITLE → PR_TITLE,
`squash_merge_commit_message` COMMIT_MESSAGES → PR_BODY, `delete_branch_on_merge` false → true;
Actions permissions `sha_pinning_required` false → true with `enabled` true and `allowed_actions`
selected unchanged (HTTP 204); selected-actions read back unchanged (GitHub-owned allowed,
verified-creator allowed false, one pattern). The before-values come from the repository endpoint captured
in the 2026-09-24 read-back's raw response (digest prefix `72c4d665eca2e20d`), not previously
transcribed: `allow_merge_commit` true, `allow_squash_merge` true, `allow_rebase_merge` true,
`squash_merge_commit_title` COMMIT_OR_PR_TITLE, `squash_merge_commit_message` COMMIT_MESSAGES,
`delete_branch_on_merge` false. The calls were made interactively through the CLI (no controller script; a `PATCH` on the
repository sending exactly the six merge keys above, and a `PUT` on Actions permissions sending
`enabled`, `allowed_actions` and `sha_pinning_required`); `allow_auto_merge` false,
`allow_update_branch` false and `web_commit_signoff_required` false read back unchanged
(`allow_auto_merge` is recorded because an auto-merge would squash a description before the
merger adds the trailer block AGENTS.md requires), and `merge_commit_title`/`merge_commit_message`
were left at their defaults, which are inert with merge commits disabled. These are the step 7
values and the last step 4 setting; the step 17 expected set is amended to them. Step 4 is not
thereby complete: the committed allowlist file that replaces the list inside
`scripts/ci/action_pins.py` is still unwritten (row 4 stays PENDING), and the owner-type and
account-plan reads step 4 requires, with the derivations that rest on them, have not been
performed. Step 4 also requires these settings before the first hosted run of step 6; the D17
visibility advance overtook that ordering, so every hosted run to date executed with the
repository-level switch off and pinning enforced only by the committed `action_pins.py` policy —
the switch's effect is prospective, and no earlier run is evidence of server-side enforcement.
Whether GitHub's enforcement passes the existing workflows, and how it composes with the one
wildcard-ref pattern in the selected-actions allowlist (two rules of opposite shape over the same
set), is shown by the first hosted runs on a commit pushed after 2026-09-26T01:40Z; the two
`056fcd2` rows below ran at roughly 00:10Z and predate the change, so they are not that evidence;
the `d5c1c34` rows are: both workflows ran to success under the switch on 2026-09-26 ~02:20Z.

**D33 security settings, applied and read back 2026-09-26T20:03Z** (controller, through the API,
on the operator's ruling that day). Vulnerability alerts off → on (`PUT` 204; the read-back `GET`
answers 204, meaning enabled); automated security fixes, which is Dependabot security updates read
through a second endpoint, `enabled` false → true and `paused` false, reported enabled in
`security_and_analysis` too; the Dependabot alerts listing answers with zero open alerts. The
dependency graph's SBOM export answered HTTP 500 at that read-back; a re-read at 2026-09-27T01:43Z
answered 200 with 36 packages (29 pip, 5 GitHub Actions, 1 npm, and the repository itself) and no
Swift package, so the alerts and security updates cover the three workflows' Actions, the
documentation toolchain's `docs/requirements.txt` and a test fixture's npm manifest
(`Tests/NotesKitTests/fixtures/notes-markdown-oracle/package.json`, neither in §17's list nor
configured in `.github/dependabot.yml`), but not the product's SwiftPM dependency. This turns on
the security switches of design §17's before-activation list, beside D32's `sha_pinning_required`;
the list's committed Action allowlist stays PENDING (row 4). The SwiftPM ordering is a separate
§17 condition: the `swift` ecosystem in `.github/dependabot.yml` stays on, a deviation D33
records, and Dependabot version updates have run weekly for all three ecosystems since 2026-09-01,
ahead of §17's list; the controller intends to settle the §20 item 3 check during the step 13
hosted Dependabot rehearsal (the weekly Swift update jobs have succeeded without opening a pull
request, so showing a Swift 6 update may need a deliberately down-pinned disposable branch; §17's
read-only freshness fallback applies only if native Swift 6 updates fail empirically). Because
`target-branch` names the default branch, GitHub documents that each configured ecosystem's
commit-message pattern also governs its security-update pull requests; that stops holding once
step 13 points `target-branch` at the disposable ref. It does not reach the unconfigured npm
fixture, whose security-update pull requests would carry Dependabot's default title. Two
GitHub-managed dynamic workflows run on this repository outside `.github/workflows/`: "Dependabot
Updates", since 2026-09-01, and "Dependency Graph", first run on 2026-09-26 at 20:03Z, when the
alerts were switched on. GitHub defines them, not a tracked file, so the step 17 static scan does
not see them and the row 5 inventory covers the tracked workflows only. Their job logs show a
token with contents, metadata and packages read and no secrets; Dependabot's branches and pull
requests are created by Dependabot's own GitHub App identity, not that token (three such pull
requests to date, all closed). Both run a GitHub-owned action at the floating ref `@main`,
admitted by the selected-actions policy's GitHub-owned allowance; the Dependency Graph run fetched
it at 20:03Z, after D32 had turned `sha_pinning_required` on at 01:40Z, so that requirement did
not stop it.

**Hosted runs on `main` since the flip** (each named by a salted SHA-256 commitment over the
run id and attempt, first 16 hex digits, under a dedicated run-ID salt kept outside the repository — distinct from
the Round 1 denylist salt — whose own SHA-256 commitment is `450869584cbaa726`):

| Commit | Workflow | Commitment | Outcome |
|---|---|---|---|
| `bdbbe9d` | Docs | `e38acbc2ab3deb6a` | success |
| `bdbbe9d` | CI | `235a8fd2c3c038c8` | failure — three hosted-only defects, none reproducible locally: the pinned Bats step assumed an npm bin link the runner did not create; the coverage policy hard-coded a macOS-only temp root and one runtime-bindings test read a macOS-only clock constant (the Python tier runs on Ubuntu); a test expression exceeded the macos-15 toolchain's type-check budget. Fixed in `7b46b8d`. |
| `7b46b8d` | Docs | `52c333db7570bc2e` | success |
| `7b46b8d` | CI | `27d6dd53c56704bf` | failure — Supply-chain policy, hosted-bats-build, hosted-bats and commit-lint green; build-test red on two logic tests whose expectations depended on macOS-27 Foundation behaviour (directory flag on a resolved symlink URL; unknown `~user` expansion). Fixed in `0ff7442`; the Notes attachment guard now refuses other users' `~user` spellings before expansion, a real defect on macOS 15 recorded under CHANGELOG `[Unreleased]`. |
| `0ff7442` | Docs | `7bfc75cef643f225` | success |
| `0ff7442` | CI | `c188d356233ffb0a` | success — every job (Supply-chain policy, build-test, hosted-bats-build, hosted-bats, commit-lint, quality / required) green; the first fully green hosted run since 2026-09-02. |
| `7049736` | Docs | `3ac359711d414e5f` | success (row backfilled 2026-09-26; the post-flip evidence record) |
| `7049736` | CI | `3ce7fd254dafab53` | failure (row backfilled 2026-09-26) — build-test, and the quality / required aggregate that depends on it: "a drain timeout stops the descendant after the root has exited" missed its timing margin on the loaded macos-15 runner; the margin was replaced by an event-order check in `19f48a2` |
| `7fc4a49` | Docs | `30ef3ed273e5093b` | success |
| `7fc4a49` | CI | `577cf803fc77680e` | success (squash merge of PR 3) |
| `6f8b852` | Docs | `2124a4e7399f037a` | success |
| `6f8b852` | CI | `017b890421194cc0` | success (squash merge of PR 4) |
| `57984cf` | Docs | `a5157d7eaf89bf0d` | success |
| `57984cf` | CI | `d29ba6108e2e0cbd` | success (squash merge of PR 5) |
| `9a86125` | Docs | `52fb0a1ddef442a9` | success |
| `9a86125` | CI | `b517718a3c4ede2a` | failure — commit-lint, and the quality / required aggregator that gates on it: the header scope carried a comma (`docs(messages,notes)`), which the lint regex forbids; Supply-chain policy, build-test, hosted-bats-build and hosted-bats green. The lint covers only the pushed range, so the next push is unaffected; the lesson is recorded in `docs/learnings/hot/hosted-ci.md`. |
| `8e9be32` | Docs | `14052ae772450ee0` | success |
| `8e9be32` | CI | `bb0639fa1bc5aedd` | success — all six CI jobs green (Supply-chain policy, build-test, hosted-bats-build, hosted-bats, commit-lint, quality / required); with the Docs run's manual-fresh and release-notes, eight green jobs for the commit. |
| `afc6779` | Docs | `1542086f7569df97` | success |
| `afc6779` | CI | `c8dbf2fedb6d8e60` | success (evidence and D20 record revision) |
| `098e784` | Docs | `9e2a63f7ef9cd7cf` | success |
| `098e784` | CI | `7895d4c6b06b1bce` | success (Dependabot PR 6 squash: `setup-uv` 9.0.0 → 10.1.0 with the committed pin policy moved in the same commit; GitHub closed PR 6, and no superseded Dependabot branch remains) |
| `4f8776a` | Docs | `5a394c4cd1881cd6` | success |
| `4f8776a` | CI | `6c18c6f8013b63bf` | success (third maintainer follow-up; D22 filed) |
| `3e46e82` | Docs | `9a72e145e66a6bcd` | success |
| `3e46e82` | CI | `365d2d84f740993b` | success — all six CI jobs green (Round 2 audit record) |
| `ec28b26` | Docs | `10393f6196e3bde5` | success (macOS 27 adoption + D18 rehearsal record) |
| `ec28b26` | CI | `aff229d70341401e` | success |
| `b94cc80` | Docs | `644ff99123d0339b` | success (read-only release-preparation rehearsal script + tests) |
| `b94cc80` | CI | `941b8df292aad623` | success |
| `6e06af4` | Docs | `ecb69c3e07efda65` | success — first hosted run of the `release-prep-rehearsal` job: the rehearsal step passed (exit 0: commits since `v26.0.0` exist, `[Unreleased]` is non-empty, the scratch renderings agreed), with no advisory notice emitted |
| `6e06af4` | CI | `4b58ff9b58d6d68d` | success |
| `eb728d3` | Docs | `80a18d6962b67e71` | success (first run under the parsed-YAML workflow scan) |
| `eb728d3` | CI | `68343b242d01a6be` | success — Supply-chain policy now runs `workflow_policy.py`; all six jobs green |
| `c8b8288` | Docs | `3a670839541f22c0` | success (site-assembly script, tests, D29 amendment) |
| `c8b8288` | CI | `296b46181ad9978b` | success |
| `72112c3` | Docs | `64eecb98351486a2` | success — first hosted run of the `site-assembly-rehearsal` job: the Releases listing was read at HTTP 200 (no rate-limit warning), the assembly ran and passed with the published set empty (the root manual plus the empty archive index and the manifest; 205 files; restore verified; renderer version 1.6.1; content-manifest sha256 `1a0ad6ab60f4da8d…`, equal to local run 1 on `eb728d3`, consistent with the direct check that `docs/manual/**` and `mkdocs.yml` are byte-identical between the two commits, and obtained across a macOS renderer locally and an `ubuntu-latest` renderer hosted), so step 16's hosted half is exercised in its empty-published-set scope |
| `72112c3` | CI | `38e81889a02dd468` | success — all six CI jobs green; the Supply-chain policy scan admits `docs.yml`'s new `site-assembly-rehearsal` job |
| `1920b2a` | Docs | `c1bbd35895ab5af9` | success (step 17 read-back record; second site-assembly run: listing HTTP 200, pass, published set empty, 205 files, content-manifest sha256 `1a0ad6ab60f4da8d…` unchanged from `72112c3`) |
| `1920b2a` | CI | `6b31543bfb46b97c` | success — all six CI jobs green |
| `723f2dc` | Docs | `b6773864dbf30697` | success (D15 sequence commit 1: attribution exception extended; third site-assembly run, pass, published set empty, content-manifest sha256 `1a0ad6ab60f4da8d…` unchanged) |
| `723f2dc` | CI | `e6bd8800280feca4` | success — all six CI jobs green |
| `e48ec1e` | Docs | `eef45af8d4171b03` | success (D15 sequence commit 2: CODEOWNERS, control-plane manifest and their test; fourth site-assembly run: listing at HTTP 200, pass, published set empty, content-manifest sha256 `1a0ad6ab60f4da8d…` unchanged) |
| `e48ec1e` | CI | `7647c026043fb000` | success — all six CI jobs green; the Python tier now carries the 16 control-plane tests |
| `056fcd2` | Docs | `cae9ecda12846410` | success (D31 record; fifth site-assembly run: listing at HTTP 200, pass, published set empty, content-manifest sha256 `1a0ad6ab60f4da8d…` unchanged) |
| `056fcd2` | CI | `21f37e24b6359b28` | success — all six CI jobs green (completed before the D32 pinning switch; not evidence for it) |
| `d5c1c34` | Docs | `e41f64ea0376cf61` | success — first Docs run after the D32 `sha_pinning_required` switch: all four jobs ran and passed, so GitHub's pinning enforcement admits the workflow (every `uses:` at a full SHA) with the one wildcard-ref allowlist pattern also active; how the two rules compose is exercised only over the actions these workflows use; sixth site-assembly run: listing at HTTP 200, pass, published set empty, content-manifest sha256 `1a0ad6ab60f4da8d…` unchanged |
| `d5c1c34` | CI | `f01924e1c3d05a11` | success — first CI run after the pinning switch; all six jobs green |
| `cd7a46f` | Docs | `b10dbaa95dd9544a` | success — all four jobs; seventh site-assembly run: listing at HTTP 200, pass, published set empty, content-manifest sha256 `1a0ad6ab60f4da8d…` unchanged, restore verified |
| `cd7a46f` | CI | `de3992a21467cd26` | success — first CI run on the step 5 fold; all six jobs green; `governance / required` runs only on pull requests, so this push has no run of it |
| `609147a` | Docs | `8e984636fedd9c7e` | success — all four jobs; eighth site-assembly run: listing at HTTP 200, pass, published set empty, content-manifest sha256 `1a0ad6ab60f4da8d…` unchanged, restore verified |
| `609147a` | CI | `5839aa1027b80a9f` | success — first CI run with the scan's character refusals; all six jobs green |
| `40eb229` | Docs | `e0f1566f1a109b4e` | success — all four jobs; ninth site-assembly run: listing at HTTP 200, pass, published set empty, content-manifest sha256 `1a0ad6ab60f4da8d…` unchanged, restore verified |
| `40eb229` | CI | `12fa664563b7fe17` | success — first CI run with YAML's block-scalar rules and the scan's pin-allowlist check; all six jobs green |
| `bdb6a86` | Docs | `29dd7a2dc587b7a3` | success — all four jobs; tenth site-assembly run: the listing read succeeded and the assembly ran and passed, published set empty, content-manifest sha256 `1a0ad6ab60f4da8d…` unchanged, restore verified; the release-preparation rehearsal took its normal path (exit 0) on the runbook commit |
| `bdb6a86` | CI | `3ebd0c9ce4d078de` | success on attempt 2 — attempt 1 (`1bd99076510cb058`) failed one Swift test the commit does not touch, "a drain timeout stops the descendant after the root has exited", at its root-exit order check (the same test failed hosted CI on 2026-09-21, at the timing margin that `19f48a2` removed); a re-run of the two failed jobs passed, and attempt 2 shows all six green, four carried over from attempt 1. The commit carrying this row is designed to keep that scenario reachable under hosted load (a readiness gate before the deadline and the launcher's own exit observation) and re-runs an attempt that still misses it; not yet observed on hosted CI |
| `7953268` | Docs | `e27703c5216cbcc6` | success — all four jobs; eleventh site-assembly run: the listing read succeeded with no rate-limit warning, and the assembly ran and passed, published set empty, 205 files, content-manifest sha256 `1a0ad6ab60f4da8d…` unchanged, restore verified; the release-preparation rehearsal took its normal path (pass, no outward writes) |
| `7953268` | CI | `3ac785773bccacd2` | success on attempt 1 (the run's attempt number as read from the API) — all six jobs green. The deflaked "a drain timeout stops the descendant after the root has exited" passed in the hosted build-test job, whose log carries no "drain-timeout scenario missed" line, so the test needed no retry of its scenario: the first hosted observation of the change the `bdb6a86` row above anticipates |
| `3b1fbef` | Docs | `bab4893708b7a7a7` | success — all four jobs; twelfth site-assembly run: the listing read succeeded with no rate-limit warning, and the assembly ran and passed, published set empty, 205 files, content-manifest sha256 `1a0ad6ab60f4da8d…` unchanged, restore verified; the release-preparation rehearsal took its normal path (pass, no outward writes) |
| `3b1fbef` | CI | `3f81d8ff29c06606` | success on attempt 1 (the run's attempt number as read from the API) — all six jobs green; the build-test log again carries no "drain-timeout scenario missed" line |
| `8ba43b1` | Docs | `b0ffdf9175ef764b` | success — all four jobs; thirteenth site-assembly run: the listing read succeeded with no rate-limit warning, and the assembly ran and passed, published set empty, 205 files, content-manifest sha256 `1a0ad6ab60f4da8d…` unchanged, restore verified; the release-preparation rehearsal took its normal path (pass, no outward writes) |
| `8ba43b1` | CI | `9ea50d8db3947b22` | success on attempt 1 (the run's attempt number as read from the API) — all six jobs green; the build-test log again carries no "drain-timeout scenario missed" line |
| `dd2114f` | Docs | `5db01719ef9f7e29` | success — all four jobs; fourteenth site-assembly run: the listing read succeeded with no rate-limit warning, and the assembly ran and passed, published set empty, 205 files, content-manifest sha256 `1a0ad6ab60f4da8d…` unchanged, restore verified; the release-preparation rehearsal took its normal path (pass, no outward writes) |
| `dd2114f` | CI | `b48f8c213af7167c` | success on attempt 1 (the run's attempt number as read from the API) — all six jobs green; the build-test log again carries no "drain-timeout scenario missed" line |
| `e011d83` | Docs | `faa9f267d10fcd24` | success on attempt 1 (the run's attempt number as read from the API) — all four jobs; fifteenth site-assembly run: the listing read succeeded with no rate-limit warning, and the assembly ran and passed, published set empty, 205 files, content-manifest sha256 `1a0ad6ab60f4da8d…` unchanged, restore verified; the release-preparation rehearsal took its normal path (pass, no outward writes) |
| `e011d83` | CI | `90b8fc128ac353f0` | success on attempt 1 (the run's attempt number as read from the API) — all six jobs green; the build-test log again carries no "drain-timeout scenario missed" line. This run and the Docs run above are the last push runs before the move to `macos-26`: CI's three macOS jobs and Docs' `manual-fresh` ran on `macos-15` |
| `1f8f3ab` | Docs | `aa8fd102813f270a` | success on attempt 1 (the run's attempt number as read from the API) — all four jobs; the Docs half of the macOS 26 baseline (design §4.1 amendment): `manual-fresh` ran on image `macos-26-arm64` version 20260907.0351.1 (release tag `macos-26-arm64/20260907.0351`), macOS 26.6.2 (25G83), as its job log's "Set up job" section reports, and the Included Software page that log links (`actions/runner-images` at that release tag, whose own Image Version line also reads 20260907.0351.1; read 2026-09-30) lists default Xcode 26.6 (17F113) and Python3 3.14.7 and no separate Swift version (the toolchain ships with the default Xcode); sixteenth site-assembly run: the listing read succeeded with no rate-limit warning, and the assembly ran and passed, published set empty, 205 files, content-manifest sha256 `1a0ad6ab60f4da8d…` unchanged, restore verified; the release-preparation rehearsal took its normal path (pass, no outward writes) |
| `1f8f3ab` | CI | `2a1e83bb52c5345b` | failure on attempt 1 (the run's attempt number as read from the API) — the first CI push run on `macos-26`, recorded as not qualifying for the baseline: `build-test` failed on 3 issues in one test, "a foreign ~user destination is never expanded before confinement sees it", where `AttachmentsSave.normalizeDestinationPath` returned the process home for a foreign `~user` spelling because `URL(fileURLWithPath:)` expanded it on macOS 26 (every production caller confines first, and the confinement refusals in the same test passed); fixed forward in the commit carrying this row. All three macOS jobs ran on image `macos-26-arm64` version 20260907.0351.1, macOS 26.6.2, as each job log's "Set up job" section reports, so that is the build the observation belongs to. `hosted-bats-build`, `hosted-bats`, `Supply-chain policy` and `commit-lint` passed; `quality / required` failed because it aggregates `build-test` |
| `53eae85` | Docs | `a3518a268625fb09` | success on attempt 1 (the run's attempt number as read from the API) — all four jobs; `manual-fresh` ran on image `macos-26-arm64` 20260907.0351.1, macOS 26.6.2 (25G83); seventeenth site-assembly run: the listing read succeeded with no rate-limit warning, and the assembly ran and passed, published set empty, 205 files, content-manifest sha256 `1a0ad6ab60f4da8d…` unchanged, restore verified; the release-preparation rehearsal took its normal path (pass, no outward writes) |
| `53eae85` | CI | `59e8bde088a93ff7` | success on attempt 1 (the run's attempt number as read from the API) — all six jobs green: the CI half of the macOS 26 baseline (design §4.1 amendments), the first CI push run after the move whose first attempt completed with every job green. `build-test`, `hosted-bats-build` and `hosted-bats` each ran on image `macos-26-arm64` version 20260907.0351.1, macOS 26.6.2 (25G83), as each job log's "Set up job" section reports: the image the Docs half ran on, so the default Xcode 26.6 (17F113) with its bundled Swift toolchain and Python3 3.14.7 recorded there apply. The `build-test` log carries no "drain-timeout scenario missed" line |
| `ca4392d` | Docs | `4581a8af3e411ed7` | success on attempt 1 (the run's attempt number as read from the API) — all four jobs; `manual-fresh` on image `macos-26-arm64` 20260907.0351.1, macOS 26.6.2; eighteenth site-assembly run: the listing read succeeded with no rate-limit warning, and the assembly ran and passed, published set empty, 205 files, content-manifest sha256 `1a0ad6ab60f4da8d…` unchanged, restore verified; the release-preparation rehearsal took its normal path (pass, no outward writes) |
| `ca4392d` | CI | `56f2705295dfbb11` | failure on attempt 2 (the run's attempt number as read from the API) — attempt 1 (`ad652bfc3e09da1d`) failed `build-test` after every Swift test had passed (1968 in 261 suites): the quality driver's temporary-directory cleanup then died with `OSError: [Errno 30] Read-only file system` under the isolated HOME's `Library/Developer/DVTDownloads/MetalToolchain/mounts/`, most likely a Metal toolchain image mounted by Xcode's lookup (hosted-CI learnings item 7; addressed in `a4de516`, where a hosted cleanup failure is now a warning and a disk image is detached first, a path that has not yet met a hosted mount). Attempt 2 re-ran the two failed jobs and failed `build-test` on one logic-tier timing test, "overflow aborts while stdin is pending and the empty sibling stream remains open", at 3.35 s against a 3 s bound with the overflow correctly reported (learnings item 8; fixed in `675eebb`); the other four jobs carried over from attempt 1. `hosted-bats-build`, `hosted-bats`, `Supply-chain policy` and `commit-lint` passed; `quality / required` failed both times because it aggregates `build-test`. Every macOS job in both attempts ran on image `macos-26-arm64` 20260907.0351.1, macOS 26.6.2 |
| `a4de516` | Docs | `f0f0a0f4e5aa0024` | success on attempt 1 (the run's attempt number as read from the API) — all four jobs; `manual-fresh` on image `macos-26-arm64` 20260907.0351.1, macOS 26.6.2; nineteenth site-assembly run: the listing read succeeded with no rate-limit warning, and the assembly ran and passed, published set empty, 205 files, content-manifest sha256 `1a0ad6ab60f4da8d…` unchanged, restore verified; the release-preparation rehearsal took its normal path (pass, no outward writes) |
| `a4de516` | CI | `d3c8a2dda29227d2` | success on attempt 1 (the run's attempt number as read from the API) — all six jobs green, every macOS job on image `macos-26-arm64` 20260907.0351.1, macOS 26.6.2: the first hosted run of the mount-aware cleanup. No job log carries a "quality: detaching" line or a cleanup warning, so no mount appeared under the driver's temporary root on this run |
| `675eebb` | Docs | `cb12632ee2edfba0` | success on attempt 1 (the run's attempt number as read from the API) — all four jobs; `manual-fresh` on image `macos-26-arm64` 20260907.0351.1, macOS 26.6.2; twentieth site-assembly run: the listing read succeeded with no rate-limit warning, and the assembly ran and passed, published set empty, 205 files, content-manifest sha256 `1a0ad6ab60f4da8d…` unchanged, restore verified; the release-preparation rehearsal took its normal path (pass, no outward writes) |
| `675eebb` | CI | `3b46166b28341ae5` | success on attempt 1 (the run's attempt number as read from the API) — all six jobs green, every macOS job on image `macos-26-arm64` 20260907.0351.1, macOS 26.6.2; the widened "overflow aborts while stdin is pending and the empty sibling stream remains open" passed in `build-test`, and no job log carries a "quality: detaching" line or a cleanup warning |

**Outside pull requests 3–5 (D20), 2026-09-21/22.** Each was squash-merged LOCALLY onto `main`
(not through the GitHub merge button) so the squash could be reviewed and tested as an ordinary
commit: the PR head was fetched under a forced refspec and asserted equal to the API's
`headRefOid` before review; the review gate (codex plus the code, security and critic
reviewers) ran on the squash; the sanitised PR body became the commit body (session links and
store-ratio phrasing removed); the contributor's own git author identity was read back and kept
as the squash author per D20; the full local canonical suite ran on each squash before its push;
and GitHub closed each PR on push. Three maintainer follow-ups (`9a86125`, `8e9be32`, `4f8776a`)
then landed the reviewers' findings that the maintainer had accepted as their own to fix; two
further proposals that would narrow parity with the retired oracles were pulled before landing
and filed for the operator as D22. The reachable
`refs/pull/*` copies named in D20 lose their reason to exist once the PRs are closed; their
retention is GitHub's, not this repository's.

Design §18 step 6 (one successful hosted run of every push-triggered mandatory job): satisfied for
the push-triggered jobs by the `0ff7442` CI and Docs runs above. The PR-triggered mandatory job
obtains its first successful run on the step 9 validation PR, still PENDING.
Learnings from the hosted runs are in `docs/learnings/hot/hosted-ci.md`.

PENDING — appended as each runs: capability readbacks that change after the first outside
contribution, and the rehearsal results of design §18 steps 8–18, in dependency order. Nothing
here is asserted before it runs.
