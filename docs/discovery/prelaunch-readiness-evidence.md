---
title: Pre-launch readiness evidence
last-used: 2026-09-21
uses: 2
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
| 3 Full local canonical suite + independent reviews on the exact SHA | pre-visibility | Evidenced for five commits: `08cc984`, the visibility-step commit `bdbbe9d`, the two hosted-CI fixes `7b46b8d` and `0ff7442`, and the Round 2 record `3e46e82` (Section 3; the earlier same-day pushes `053b56e` and `a52c44e` carry no suite record here); each also carried codex plus code, security and critic review provenance in its trailers | Section 3 |
| 4 External-Action allowlist committed and validated | pre-visibility | Repository-level allowlist configured 2026-09-21 (see the Actions-settings row); the committed/validated form of the design is advanced past for visibility only — PENDING, owner: controller | — |
| 5 Workflow inventory: publishers converted or removed | pre-visibility | Partially evidenced: `.github/workflows/` holds `ci.yml`, `docs.yml`, `pr-metadata.yml`; no `release.yml`; all three declare `contents: read` only and none carries `workflow_dispatch`, `pages`, `id-token`, or an `environment`; no repository secrets or variables (read back 2026-09-20). 2026-09-23: `docs.yml` gained `release-prep-rehearsal`, a read-only job (`contents: read`, no secrets, no artifact upload) that runs `scripts/ci/release_prep.py` — the design §14.1 rehearsal — in a throwaway clone against the commit the workflow builds (on `push`, the commit on `main`; on `pull_request`, the synthetic merge commit); only the script's nothing-to-release status is advisory, every other failure fails the job; it covers the default-bump path, the macOS-adoption shape being exercised locally before a cut. This is a smoke check toward step 15, not step 15 itself: the explicit-SHA hosted rehearsal with its three-way evidence binding is still PENDING. Static scan of step 17 EVIDENCED 2026-09-23 (step 17 row) | this row (read back 2026-09-20) |
| 7 Squash-only merge with PR title/body as squash commit | pre-visibility | PENDING (not evidenced here) | — |
| 15–16 Read-only release/site rehearsal tooling exercised | pre-visibility (local half); post-visibility (hosted runs) | Step 15 tooling: `scripts/ci/release_prep.py` (2026-09-23, rows above); the explicit-SHA hosted rehearsal with its three-way binding remains PENDING. Step 16 local half EVIDENCED IN PART 2026-09-23 with `scripts/ci/site_assembly.py`, run against throwaway clones of `eb728d3` with the pinned MkDocs toolchain (`docs/requirements.txt`, pure-Python wheels installed with hashes required on macOS; the hosted lane is the manifest's compiled target) — run 1, empty published set (the only tag, `v26.0.0`, is a draft Release whose commit carries no manual tree, so it is excluded by the caller, as the design amendment records): PASS, routes `/`, `/versions/`, `/version-manifest.json`, 205 files, content-manifest sha256 `1a0ad6ab60f4da8d…`, artifact sha256 `4eafe5304a1214fa…`; run 2, a SYNTHETIC `v26.0.0` tag placed inside the clone on an older manual-bearing commit (`4f8776a`) to exercise an archive route with real renderer output, executed twice: both PASS with identical reports, routes `/`, `/versions/`, `/versions/26.0/`, `/version-manifest.json`, 409 files, content-manifest sha256 `28294a96d44722ce…`, artifact sha256 `bf67c4d16022c96d…`, renderer version 1.6.1, artifact restore verified, per-run double render byte-equal (directories included). No digested byte carries the unassigned candidate version: the scratch manifest records the candidate's version and series as null and the archive index names published series only, so the report's digests cannot be enumerated back to a version. The same inputs with the original `/version/` root were REFUSED (collision with the `apple version` page) — the finding behind D29. Not yet exercised against a REAL published archive (none exists): the multi-series case and the maintenance-patch case are covered hermetically only. `Tests/automation/test_site_assembly.py`: 21 hermetic cases (the tracked `mkdocs.yml` pinned against the config policy; synthetic tagged repositories for series selection, maintenance-patch candidate, candidate below its series tip refused, config-policy refusals, non-deterministic renderer refused, determinism across runs, artifact restore, loopback serving of every route, manifest-path collision, mistagged commit, refusals for missing manual, symlinks, bad tags, dirty checkout, unsafe paths, renderer failure) plus one real-renderer case (clone, synthetic tag, two runs compared) that is local-only — env-gated, run by no CI job. A published tag whose commit carries no tracked manual (today's `v26.0.0`) is a refusal by design, so the first archive-able tag is the macOS 27 re-cut; the run log names no version either. Hosted half: `docs.yml` gained `site-assembly-rehearsal` (read-only; no token; published set from the public Releases listing, drafts invisible; candidate version derived, never printed; only the value-free report printed). Scope of the hosted run today: with no published Release the published set is empty, so the hosted job exercises the single-series candidate-serves-root path plus the artifact pack/restore/digest proof; the archive and maintenance-patch paths stay hermetic and local-synthetic. A green Docs check is NOT by itself evidence — a rate-limited listing warns and skips the assembly — so the §4 row for a hosted rehearsal cites the printed report, not the check conclusion. Loopback serving of the routes is a test-tier check, not part of the hosted run (a knowing omission). First hosted run: `72112c3` (Docs, run commitment `64eecb98351486a2`) — listing at HTTP 200, assembly PASS with an empty published set; §4 run table | `scripts/ci/site_assembly.py`; `Tests/automation/test_site_assembly.py`; `.github/workflows/docs.yml` |
| 17 Static workflow scan + settings readbacks | pre-visibility (static scan); post-visibility (API read-backs) | **EVIDENCED IN PART 2026-09-24 — settings read-backs recorded; two read-backs not performed (installed Apps — endpoint 403; attestation settings — NOT READ) and two performed but not satisfied (collaborator list — awaiting an operator ruling; CODEOWNERS — absent until the design §18 step 5 bootstrap lands).** Static scan EVIDENCED 2026-09-23: `scripts/ci/workflow_policy.py` parses each workflow with a hand-rolled block-YAML subset parser (anchors, tags, flow mappings, tabs and multi-document files are refused, and a refusal is a violation, not a pass) and checks the step's list on the parsed document — explicit `permissions` on every workflow and job (nine jobs gained `contents: read` in the same change), no forbidden trigger (`workflow_run`, `workflow_dispatch`, `repository_dispatch`, `release`, `deployment`), no `environment`, no `secrets.` context in any expression, no `secrets:` mapping or `secrets: inherit`, no `github.token`, hosted runner labels only, `persist-credentials: false` on every checkout, none of the recorded publish/deploy/attest actions and none of the recorded `git`/`gh`/REST/registry write commands (a recorded-list check: a write reachable only through a remote action's own code is bounded by the read-only permissions and the absence of secrets, not detected), every `uses:` a remote action pinned to a full SHA, no `container`/`services` image, unique check names, recorded trigger sets for `quality / required` and `metadata / required`, exactly one `pull_request_target` workflow that references the proposal head nowhere (workflow-level `env` included), downloads no artifact (any `download-artifact` action or `gh run download`), names no checkout `repository` and pins every checkout `ref` to the base. Runs in CI's `Supply-chain policy` job; `Tests/automation/test_workflow_policy.py` (42 cases) exercises each rule on synthetic trees plus the real tree. The recorded set names today's `metadata / required` job; it moves to `governance / required` when step 5's fold lands. Settings/API read-backs recorded 2026-09-24 in §4 as the value-free expected set: repository secrets, Actions variables, Dependabot secrets, environments and deploy keys all zero; no Pages site; workflow token read-only; external-contributor approval on; no rulesets yet. Not performed: the installed-App inventory (endpoint answered 403, cause not established — retry with a token of the documented class, else an operator UI read); attestation settings (no repository surface queried — NOT READ). Performed but not satisfied: the collaborator list (two outside read grants where the design expects the operator alone — operator ruling); `.github/CODEOWNERS` (step 17 expects it present and error-free; absent until the design §18 step 5 bootstrap lands, itself gated on a not-yet-recorded operator decision; this read-back is then re-run) | `scripts/ci/workflow_policy.py`; `Tests/automation/test_workflow_policy.py` |
| Fresh pre-publication privacy audit | pre-visibility | **Round 1 complete. Its zero-findings condition was NOT met: seven findings (R1-F1 to R1-F7); the operator dispositioned F1–F5 (D17–D20), the F6 fixture fix and the F7 log deletion (D21) were pre-flip blockers, both completed 2026-09-21, and the flip was advanced on that basis. This round does not satisfy design §18 phase 1's zero-findings gate; the end-of-roadmap round must.** Owner: controller for the record, operator for the dispositions. Round 2 (end-of-roadmap, 2026-09-22): **zero NEW findings; the gate is NOT yet closed — R1-F1 recurs in the unchanged draft asset as a deferred finding under OPEN D18 (rebuild, re-cut, re-scan), while the D20 identity class recurs as accepted. Closes on the appended scan of the rebuilt asset.** Rebuild rehearsal 2026-09-22 (D23/D24): the path-free build and packaging PASS every gate on the operator's macOS 27 host — zero R1-F1 to R1-F3 carriers in the rehearsal binary and archive (Section 3a); D18 steps (2) and (4) are thereby demonstrated on `3e46e82`, to be re-established on the exact release commit and its shipped artifact. **Still not closed:** the gate names the PUBLISHED rebuilt asset, and no publisher exists yet (D18 steps 4a/5); the draft `v26.0.0` asset is unchanged. | Sections 2, 3a |
| Design §18/§3, `AGENTS.md` and ledger-preamble amendment recording the advanced visibility step (D15 precedent) | pre-visibility | Landed in the same commit as this revision (design §18 dated amendment, `AGENTS.md` privacy paragraph, ledger preamble, D2 freeze amendment) | this commit |
| 4 (repository-level part) Actions settings | pre-visibility | Read back 2026-09-20: `default_workflow_permissions` = read, `can_approve_pull_request_reviews` = false, `allowed_actions` = all. Configured 2026-09-21 and read back: `allowed_actions` = `selected`, GitHub-owned actions allowed, one third-party pattern with a wildcard ref (the SHA pins live in the workflow files; `sha_pinning_required` is false), covering the five actions the workflows use; the unused wiki flag disabled the same day; fork-PR contributor approval could not be read while private; read back `all_external_contributors` on 2026-09-21 15:08Z and again on 2026-09-24 (step 17 read-backs, §4), unchanged | this row |
| Surfaces that become public on the flip and were not in round 1's scan | pre-visibility | Complete. Scanned after round 1 (see Round 1 addendum): PR timelines, issue events, commit comments clean apart from the known R1-F4 identity class; all 305 hosted workflow runs' logs scanned value-free — no personal data, but 18 runs' logs carry pre-redaction tracker identifiers inside historical branch names (R1-F7). Those 18 runs' logs were deleted under D21 on 2026-09-21 (read back absent). Projects unreadable with the current token | Round 1 addendum |
| Pre-push re-scan of every commit added after `053b56e` (tree + commit message) | pre-visibility | Done for the pushes of 2026-09-21 (`053b56e`, `a52c44e`, `08cc984`: changed blobs, messages and author headers; Python `re`, `pcre2grep`, `git grep -P`; clean apart from the git-identity lines and one integer constant); repeated before each later push the same day for `bdbbe9d`, `7b46b8d` and `0ff7442` (changed blobs at the commit via `git grep -P`, message via Python `re`): clean apart from the AI co-author trailer address and, at `0ff7442`, one pre-existing reserved-domain placeholder in an old CHANGELOG entry | this row |
| Rollback plan if a finding surfaces after the flip | pre-visibility | Recorded in D17: re-flip to private immediately (mechanically reversible; clones, caches and indexes are not), redact at HEAD, file the incident in the ledger, re-run the audit round | D17 |
| 19 This file, local portion | pre-visibility | This revision | — |
| 6 One successful hosted run of every push-triggered mandatory job | post-visibility | Satisfied for the push-triggered jobs 2026-09-21 by the `0ff7442` CI and Docs runs (Section 4); the PR-triggered job waits for step 9 | Section 4 |
| 8–14, hosted halves of 15–17, 20 | post-visibility | PENDING — appended with run-ID commitments as each runs; owner: controller | — |
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
  `tar -tvf` without extracting. Same disposition as R1-F1 (the Release is now a draft);
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
| `pr-metadata.yml` | uses `pull_request_target` | base-owned metadata validator only, `contents: read`, no PR-code checkout (per `AGENTS.md`); becomes fork-reachable on the flip, which is its designed use |

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
publisher, any ref; SHA pinning is enforced by the committed `action_pins.py` policy rather than
the repository setting); fork-PR contributor approval `all_external_contributors`. Open pull
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
repository-level `sha_pinning_required` setting off (pinning is enforced by the committed policy;
turning the setting on is an open operator candidate); fork pull-request contributor approval
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
`.github/CODEOWNERS` absent from the tree and the code-owners errors endpoint 404 — step 17
expects the file to be present, to name only the operator, to cover every §10.5 control-plane
path and to be error-free; none of that holds today, so the read-back is NOT SATISFIED; the file is created by the
design §18 step 5 bootstrap, itself gated on a not-yet-recorded operator decision, and this
read-back is re-run against it then; collaborators 3 by count,
roles admin 1 and read 2, of which outside collaborators 2 — the design expects the operator
alone, the grants' dates were not read back, and they are surfaced for an operator ruling rather
than changed; the ruling is not cosmetic: read access confers nothing on a public repository, but
collaborator status interacts with the fork-run approval policy and with code-owner eligibility
once CODEOWNERS lands, which step 17 requires to name the operator alone; installed GitHub Apps
and their permission scopes NOT READ — the account-installations endpoint answered 403 to the
token in use, the cause was not established from the response alone (GitHub's documentation for
the endpoint names GitHub App user tokens; an insufficient scope produces the same code), so the
inventory (the installations together with each installation's repository list, as step 17 asks)
is OPEN and is retried with a token of the documented class before falling back to an operator UI
read-back; the pre-visibility private-forking observation the design lists is retired by design
after visibility in favour of these public read-backs. These values are the recorded expected set for step 17: any later
divergence is a finding, and the set is re-read when the `main` ruleset activates, when
CODEOWNERS lands, and before the §15 preconditions are asserted.

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
