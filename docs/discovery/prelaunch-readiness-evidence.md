---
title: Pre-launch readiness evidence
last-used: 2026-09-20
uses: 1
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
| 3 Full local canonical suite + independent reviews on the exact SHA | pre-visibility | Partially evidenced: Section 3 carries the suite result for `08cc984`; the result for the commit that records this revision, and the independent reviews, are recorded in the first post-flip revision (a commit cannot carry its own suite result) | Section 3 |
| 4 External-Action allowlist committed and validated | pre-visibility | Repository-level allowlist configured 2026-09-21 (see the Actions-settings row); the committed/validated form of the design is advanced past for visibility only — PENDING, owner: controller | — |
| 5 Workflow inventory: publishers converted or removed | pre-visibility | Partially evidenced: `.github/workflows/` holds `ci.yml`, `docs.yml`, `pr-metadata.yml`; no `release.yml`; all three declare `contents: read` only and none carries `workflow_dispatch`, `pages`, `id-token`, or an `environment`; no repository secrets or variables (read back 2026-09-20). Static scan of step 17 PENDING | this row (read back 2026-09-20) |
| 7 Squash-only merge with PR title/body as squash commit | pre-visibility | PENDING (not evidenced here) | — |
| 15–16 Read-only release/site rehearsal tooling exercised locally | pre-visibility (local half) | PENDING (not evidenced here) | — |
| 17 Static workflow scan + settings readbacks | pre-visibility (local half) | PENDING (not evidenced here) | — |
| Fresh pre-publication privacy audit | pre-visibility | **Round 1 complete. Its zero-findings condition was NOT met: seven findings (R1-F1 to R1-F7); the operator dispositioned F1–F5 (D17–D20), the F6 fixture fix and the F7 log deletion (D21) were pre-flip blockers, both completed 2026-09-21, and the flip was advanced on that basis. This round does not satisfy design §18 phase 1's zero-findings gate; the end-of-roadmap round must.** Owner: controller for the record, operator for the dispositions | Section 2 |
| Design §18/§3, `AGENTS.md` and ledger-preamble amendment recording the advanced visibility step (D15 precedent) | pre-visibility | Landed in the same commit as this revision (design §18 dated amendment, `AGENTS.md` privacy paragraph, ledger preamble, D2 freeze amendment) | this commit |
| 4 (repository-level part) Actions settings | pre-visibility | Read back 2026-09-20: `default_workflow_permissions` = read, `can_approve_pull_request_reviews` = false, `allowed_actions` = all. Configured 2026-09-21 and read back: `allowed_actions` = `selected`, GitHub-owned actions allowed, one third-party pattern with a wildcard ref (the SHA pins live in the workflow files; `sha_pinning_required` is false), covering the five actions the workflows use; the unused wiki flag disabled the same day; fork-PR contributor approval cannot be read while private — read back immediately after the flip, before any outside PR is allowed to run | this row |
| Surfaces that become public on the flip and were not in round 1's scan | pre-visibility | Complete. Scanned after round 1 (see Round 1 addendum): PR timelines, issue events, commit comments clean apart from the known R1-F4 identity class; all 305 hosted workflow runs' logs scanned value-free — no personal data, but 18 runs' logs carry pre-redaction tracker identifiers inside historical branch names (R1-F7). Those 18 runs' logs were deleted under D21 on 2026-09-21 (read back absent). Projects unreadable with the current token | Round 1 addendum |
| Pre-push re-scan of every commit added after `053b56e` (tree + commit message) | pre-visibility | Done for the pushes of 2026-09-21 (`053b56e`, `a52c44e`, `08cc984`: changed blobs, messages and author headers; Python `re`, `pcre2grep`, `git grep -P`; clean apart from the git-identity lines and one integer constant); repeated for the commit that records this revision before its push, with the result recorded in the first post-flip revision | this row |
| Rollback plan if a finding surfaces after the flip | pre-visibility | Recorded in D17: re-flip to private immediately (mechanically reversible; clones, caches and indexes are not), redact at HEAD, file the incident in the ledger, re-run the audit round | D17 |
| 19 This file, local portion | pre-visibility | This revision | — |
| 6, 8–14, hosted halves of 15–17, 20 | post-visibility | PENDING — appended after the flip with run-ID commitments; owner: controller | — |
| 18 Restored `dependabot.yml` state | post-visibility | PENDING — owner: controller | — |
| D18 §4.1 macOS 27 adoption-matrix amendment | pre-release | PENDING — owner: controller, gated by D18 | — |
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

## 3. Local verification for the visibility-step commit

For `08cc984` (pushed 2026-09-21, the tip before the commit that records this revision), all
stages exit 0 except where noted: swiftly toolchain Swift 6.3.3 — `swift build` exit 0 (log
sha256 `c9bc4c4ed0dbeabc…`), `swift test` exit 0, 1846 tests in 256 suites (`dfdea3b0685959d0…`);
Command Line Tools Swift 6.3.2 — `swift build` exit 0 (`ac11c36b97ac26e9…`); Python automation
tier `python -m unittest discover -s Tests/automation -p 'test_*.py'`, CPython 3.13.14, 764/764,
exit 0 (`93dda1039dd19d0a…`); bats `bats -r bats/`: first pass 451/452, exit 1 (`d9bd869ed2de1412…`,
one live-Mail transient in an attachment-enrichment test that passed alone), full rerun on the same
commit 452/452, exit 0 (`bfa4d32c2a3db24a…`). Launched through a signal-reset wrapper (see the
learnings entry). The same suite is run on the commit that records this revision before it is
pushed; its result is recorded in the first post-flip revision, because a commit cannot carry its
own suite result.

## 4. Post-visibility hosted evidence

Read back immediately after the flip, before anything else runs: repository visibility; the
`v26.0.0` Release still `draft=true`; `default_workflow_permissions` and
`can_approve_pull_request_reviews`; `allowed_actions` and the selected-actions set; fork-PR
contributor approval (unreadable while private); the wiki flag; the fork count.

PENDING — appended after the visibility change: hosted run outcomes as salted run-ID
commitments, capability and settings readbacks for the public state, and the rehearsal results
of design §18 steps 6 and 8–18, in dependency order. Nothing here is asserted before it runs.
