# Publication Automation Design

**Status:** Approved for private implementation on 2026-09-01. Publication is
not authorized by this document.

## 1. Purpose

Prepare `apple-cli` for a later public launch with enforceable contribution,
testing, documentation, dependency, and release controls. The system must bind
the protected-branch content tree to one exact post-merge candidate Git object
ID, then make the tested commit, tag, released binary, and published manual
trace to that candidate. The separate deployment approval names that exact
candidate.

This design makes reviewed pull requests the normal replacement for the private,
owner-operated direct-to-`main` workflow only after a private bootstrap proves
the replacement works. It deliberately retains an exact-user operator bypass.
Until that activation point, the repository's existing main-only rule remains
authoritative.

## 2. Goals

1. Make pull requests the normal path for every post-bootstrap `main` change.
2. Require one qualified independent GitHub approval on the normal PR path while
   preserving an explicit exact-user bypass for the repository operator.
3. Require a second, explicit operator approval before any version is
   published.
4. Keep outside-contributor and Dependabot workflows secret-free and unable to
   publish, deploy, or reach live Apple data.
5. Enforce at least 90% aggregate production-source line coverage, at least 90%
   changed-line coverage, and non-regressing coverage for every production
   target.
6. Make tests and documentation growth mandatory when functionality grows.
7. Treat macOS 26 as the current tested and supported baseline, add newer stable
   majors after validation, and do not block installation on earlier technically
   compatible macOS versions.
8. Preserve branch-owned test policy when future macOS product lines appear.
9. Publish the newest released documentation automatically at `/`.
10. Retain one documentation archive under `/version/` for every previous
    `MAJOR.MINOR` series, representing that series' highest published patch.
11. Enable governed dependency updates for GitHub Actions, SwiftPM when
    empirically supported, and the pinned Python documentation toolchain.
12. Keep releases, tags, Pages, and distribution blocked on the exact required
    quality gate.

## 3. Non-goals and publication boundary

Private implementation of this design must not:

- change repository visibility;
- enable or deploy GitHub Pages;
- create, move, or delete a release tag;
- create, publish, edit, or delete a GitHub Release or its assets;
- publish or modify a Homebrew formula or tap;
- dispatch the existing release workflow;
- hand-edit `AppleVersion.current`;
- lift the release freeze;
- create a maintenance branch before a real compatibility divergence exists;
- execute untrusted fork code on a self-hosted, TCC-enabled, or persistent
  runner;
- add unrelated product functionality.

Every outward-facing action remains subject to a later, explicit publication or
release instruction.

## 4. Locked product and governance decisions

### 4.1 Platform support

- macOS 26 is the current tested and supported runtime baseline. A newer macOS
  major joins the supported set only after its adoption matrix passes.
- `Package.swift` retains macOS 14 as the technical deployment minimum. This
  keeps installation possible on macOS 14 through 25 when the binary and used
  frameworks happen to work there.
- macOS 14 through 25 are untested and unsupported. Documentation, diagnostics,
  release notes, and package-manager metadata must say so plainly; compatibility
  reports from those versions are welcome but do not create a support promise.
- Distribution metadata must not raise its installation floor to macOS 26 solely
  to encode the support policy.
- Product `MAJOR` continues to name the newest macOS major validated by that
  release. It does not encode the deployment minimum.
- `[Unreleased]` release notes must state the macOS 26 support baseline while
  making clear that the technical macOS 14 deployment floor is unchanged.
- `AppleVersion.current` remains workflow-owned and stays frozen until an
  explicitly authorized release.

### 4.2 Contribution model

- After bootstrap activation, pull requests are the normal path to `main`.
- The operator, outside contributors, and Dependabot open pull requests under
  their native identities.
- The normal path requires one approval from a trusted reviewer whose repository
  permission is sufficient for GitHub to count the review.
- The operator's exact GitHub user is the sole `always` bypass actor. This lets
  the operator deliberately merge without approval, push directly, or force
  push when necessary. No collaborator role, administrator role, App, or
  Dependabot identity receives bypass authority.
- Every pull request is squash-merged. Its final PR title becomes the exact
  Conventional Commit header on `main`, and its final PR description becomes
  the commit body.
- Native repository settings make squash the only enabled merge method and use
  `PR_TITLE` plus `PR_BODY` as the default commit message. GitHub permits editing
  that default during merge, so protected-branch CI verifies the result before
  any release can proceed.
- No non-operator contributor can bypass the pull-request, review, CI, or
  force-push rules.

### 4.3 Deployment model

- Release preparation is an ordinary protected pull request.
- The publisher never edits source, creates a new source commit, or pushes a
  branch.
- A bot, not the operator, initiates the exact-SHA publisher.
- A protected production environment lists only the operator as required
  reviewer and prevents self-review and administrator bypass.
- Only after the operator approves that waiting environment job can the job
  receive tag, release, and Pages authority.

## 5. Trust and identity model

| Identity | Allowed | Forbidden |
|---|---|---|
| Operator | Author PRs; review others' PRs; merge; administer settings; bypass branch rules; force push; approve production deployment | Self-approve a PR through GitHub's review UI; unreviewed publication |
| Trusted maintainer/reviewer | Review and approve PRs; merge only after every normal protection passes; contribute through branches | Bypass rules; direct-push or force-push `main`; deploy; publish |
| PR `GITHUB_TOKEN` | Read source; upload non-sensitive checks and artifacts | Write repository contents; receive ordinary secrets; deploy; publish |
| Publisher | After environment approval, create the exact version tag, draft/release assets, and Pages deployment | Mutate branches; generate new source changes; retarget or delete published tags |
| Dependabot | Open dependency PRs | Auto-merge, approve, deploy, or access ordinary Actions secrets |
| Outside contributor | Open fork PRs and receive public CI results | Secrets, write tokens, TCC/live runners, release authority |

The repository owner remains the GitHub control-plane root. Repository settings
cannot cryptographically prevent the owner from deliberately removing a rule.
These controls prevent accidental or routine bypass and provide an auditable
normal path; they do not claim protection against an owner-account compromise.

## 6. Native pull-request flow and operator bypass

### 6.1 Ordinary change

```text
operator or contributor prepares and pushes a proposal branch
  -> author opens a pull request with the repository template
  -> secret-free required CI runs
  -> one qualified independent reviewer approves the final code
  -> author or maintainer squash-merges with the native GitHub controls
  -> protected-branch CI verifies the resulting tree and commit metadata
```

GitHub does not let an author approve their own pull request. An operator-authored
PR therefore receives its ordinary required approval from another trusted
collaborator with sufficient repository permission. Outside-contributor and
Dependabot PRs follow the same review and CI rules.

A trusted non-owner maintainer may perform the squash merge only after every
required review, conversation, and check has passed. This is ordinary merge
authority, not bypass authority. The maintainer cannot merge a deficient PR,
push directly, or force-push `main`.

### 6.2 Operator bypass and force-push authority

The branch ruleset names only the operator's exact GitHub user as an `always`
bypass actor. It does not grant bypass to the repository-admin role because a
future admin collaborator would inherit that role. The operator can use the
bypass to merge without the required approval, push directly, or force push;
all non-operator contributors remain subject to every rule.

Force-pushing `main` rewrites shared history. It can remove commits, invalidate
existing clones, and corrupt open pull-request ancestry. It is an explicit
emergency and history-repair capability, not the routine approval override. A
routine override uses the operator bypass to merge the PR or push normally. A
necessary history rewrite uses an exact expected remote object ID and
`--force-with-lease`, after rechecking the remote ref. Plain force still requires
a separate operator confirmation explaining why lease protection cannot work.

The repository owner remains the control-plane root and can also edit or delete
the ruleset. The design prevents accidental and non-owner bypass; it does not
claim that a personal-repository owner can be made unable to change their own
settings.

### 6.3 Release-preparation change

The trusted release preparer creates and pushes an ordinary proposal branch. A
strict allowlist limits its diff to the version constant, CHANGELOG promotion,
and version-dependent generated documentation when needed. Any other changed
path fails preparation before the branch is pushed.

## 7. Repository protection

### 7.1 Reviewer policy

The normal path requires one approval from a trusted collaborator whose
repository permission is sufficient for GitHub to count the review. The design
does not require a repository-wide CODEOWNER approval: that would make an
operator-authored PR impossible to satisfy without using the bypass on every
change. The operator chooses which collaborators receive review-capable access
and does not grant them ruleset bypass.

### 7.2 `main` and active maintenance lines

Rulesets require:

- a pull request;
- one approving review;
- dismissal of stale approvals after code changes;
- conversation resolution;
- the stable `governance / required` check;
- the stable `quality / required` check;
- strict up-to-date status checks before merge;
- linear history;
- force pushes blocked for every non-bypass actor;
- no deletion;
- one bypass entry: the operator's exact GitHub user in `always` mode.

No repository role, team, GitHub App, Dependabot identity, deploy key, or other
user receives bypass. The operator's bypass is deliberately broad enough to
merge without approval, push directly, and force push. Release automation never
treats bypass as quality evidence: an exact candidate still must pass the full
publisher preflight before any outward-facing action.

Repository merge settings permit squash merge only: merge commits and rebase
merges are disabled. The configured squash title source is `PR_TITLE`, and the
squash message source is `PR_BODY`. GitHub permits editing the proposed merge
message, so a required governance check verifies the repository settings and
protected-branch CI verifies that each resulting `main` commit header and body
equal the merged PR title and description after normalizing Git's terminal
newline. A mismatch makes `main` red and blocks every later merge and release
until a corrected candidate passes the protected checks. An operator bypass may
land a corrective commit or perform an explicitly authorized history repair,
but it never makes a red or metadata-mismatched candidate eligible to publish.

The repository is user-owned. GitHub merge queues are currently available for
public organization-owned repositories, not user-owned public repositories.
Therefore the launch design uses strict up-to-date required checks. The quality
workflow may support `merge_group` for a future organization migration, but the
bootstrap must not claim merge-queue enforcement that the current ownership
model cannot provide.

### 7.3 Tags and releases

A `v*` tag ruleset allows creation only through the environment-gated publisher
identity and forbids tag update, force-update, and deletion. It grants no branch
authority. If the account cannot select that exact identity without granting a
broader bypass, publication remains blocked rather than weakening the rule.
Once the repository is public and publication is authorized, release
immutability is enabled for future releases so published assets and their tag
cannot be silently replaced.

## 8. Pull-request template and metadata contract

The recognized template path is `.github/PULL_REQUEST_TEMPLATE.md`. It renders
exactly four top-level sections, in this order:

```markdown
## Rationale

## Details

## Testing

## Checklist
```

Hidden HTML comments guide authors without introducing more top-level headings.
API-created PRs populate the same template explicitly and must not omit or
replace it.

The completed description is also the future squash-commit body. Its final
lines carry the contiguous `Reviewed-by:` and applicable `Co-Authored-By:`
trailer block required by repository policy, with no internal tracker trailer.
Authors and reviewers inspect the final title and description before merge.

### 8.1 Rationale

The author describes:

- the user-visible problem or opportunity;
- why the change belongs in `apple-cli`;
- the expected caller benefit;
- a related public issue or discussion when one exists.

Private tracker identifiers and internal URLs are prohibited.

### 8.2 Details

The author describes:

- implementation shape and affected domains or commands;
- CLI, JSON, exit-code, schema, permission, workflow, or dependency impact;
- compatibility, macOS support-baseline, and deployment-floor impact;
- deliberate non-goals;
- the reason any checklist item is not applicable.

### 8.3 Testing

The template includes a command/result table and prompts for:

- Swift logic tests;
- hosted-safe CLI or Bats tests;
- local Apple-state or TCC tests when relevant;
- manual-generation and release-note checks;
- coverage results;
- tests not run and the reason.

Guidance forbids pasting personal, account, message, mail, contact, note,
calendar, reminder, or other live-store values. Test evidence uses commands,
counts, hashes, field names, and pass/fail results only.

### 8.4 Checklist

Every PR author confirms:

- [ ] The PR title follows Conventional Commits.
- [ ] The change is focused, and the final diff contains no unrelated files.
- [ ] Tests cover every new or changed behavior.
- [ ] Exact test commands and results are included above; omitted tests are
      explained.
- [ ] Aggregate and changed-line production coverage remain at least 90%, and
      no production target regresses.
- [ ] New or changed commands, flags, JSON fields, error envelopes, and exit
      codes have contract coverage.
- [ ] Write, dry-run, sandbox, and irreversible-operation behavior is covered
      where applicable.
- [ ] Curated manual prose and generated documentation are updated and fresh
      where applicable.
- [ ] `[Unreleased]` describes every caller-visible change.
- [ ] Breaking behavior, `schema_version`, macOS support-baseline, and
      deployment-minimum effects are disclosed.
- [ ] Examples, fixtures, and evidence are synthetic and contain no personal
      data, secrets, private infrastructure details, or internal identifiers.
- [ ] Dependency changes include their lockfiles, and GitHub Actions remain
      pinned to full commit SHAs.
- [ ] `AppleVersion.current` and released CHANGELOG sections were not manually
      edited.
- [ ] Generated manual pages came from the generator rather than a hand edit.
- [ ] Every inapplicable item is explained under Details.
- [ ] The author reviewed the final diff after the latest push.

The metadata job runs for PR creation, synchronization, reopening, and title or
description edits. It verifies the four headings exist exactly once and in
order, the PR title is a valid Conventional Commit header of at most 72
characters, required template content is not left as placeholder text, and the
description ends in a valid contiguous provenance trailer block. Its result is
recomputed for the final title/body pair. Checkboxes communicate readiness; they
never replace the required independent review or Actions result. Because GitHub
does not make its generated squash message immutable, protected-branch CI
compares the resulting commit with the final PR metadata before any release.

## 9. Outside-contributor and dependency PR safety

Outside-fork CI uses `pull_request` with a read-only token and no secrets.
First-time contributor runs require maintainer approval after the diff is
inspected, especially changes to `Package.swift`, dependency locks, scripts, and
workflow files.

No workflow may:

- check out or execute fork code under `pull_request_target`;
- treat a fork artifact as trusted executable input in a privileged
  `workflow_run`;
- expose release credentials, environment secrets, or write tokens;
- run fork code on self-hosted, persistent, live-store, or TCC-enabled runners;
- grant fork code tag, Release, Pages, or distribution authority.

Workflow-file changes are ordinary untrusted code until merged through the
protected review path. Every external Action, including GitHub-authored
Actions, is pinned to a full commit SHA.

## 10. Quality architecture

### 10.1 One deterministic test core

A repository-owned deterministic quality driver is the source of truth for
commands. A same-repository reusable workflow wraps it for GitHub Actions. On a
pull request, a trusted-base governance check proves that an ordinary PR did not
change the enforcement control plane; the blocking driver is then executed from
a separate base-ref checkout against the untrusted proposal checkout. On a
protected-branch or release-candidate run, the exact candidate supplies the
driver and workflow. Future maintenance branches therefore retain their own
reviewed test policy instead of importing mutable policy from `main`.

Callers include:

- pull-request CI;
- protected-branch CI;
- future merge-group CI if ownership later supports a merge queue;
- exact release-candidate verification;
- local verification.

### 10.2 Required jobs

The required graph has two independent stable roots. `governance / required`
runs the trusted-base policy. `quality / required` aggregates at least:

- metadata and PR-template policy;
- privacy and secret scanning of the proposed public surface;
- dependency review;
- macOS build and Swift tests with a nonzero test-count assertion;
- production-source coverage;
- hosted-safe CLI contract tests;
- manual freshness, strict MkDocs build, Markdown-table validation, and
  release-note validation;
- command/capability test inventory;
- package/runtime smoke tests;
- `quality / required` aggregate.

`quality / required`:

- uses `if: always()`;
- depends on every mandatory quality job;
- explicitly fails unless every mandatory dependency result is `success`;
- never uses path filters or an event condition that can skip the required
  result;
- retains one stable check name across supported event types.

The ruleset requires both stable checks: `governance / required` and
`quality / required`. Optional or advisory jobs are not included in either
success expression.

### 10.3 Hosted and local test tiers

The existing Bats suite is partitioned into:

- hosted-safe synthetic and fixture tests;
- local Apple-state tests;
- live/TCC tests.

Hosted CI runs parser, help, JSON, exit-code, source-lint, fixture, manual, and
other tests that need no real Apple state. Local/TCC suites remain an operator
release prerequisite and never execute on fork PRs. The full canonical local
suite remains required before every bootstrap push and before an authorized
release.

### 10.4 Functionality-growth manifest

A recursive inventory derived from `apple --experimental-dump-help` maps every
visible command and parameter to:

- parser and help coverage;
- invalid-input and exit-code coverage;
- JSON-envelope coverage;
- at least one behavior test classified as `logic`, `hosted-smoke`, or
  `local-tcc`;
- its port-spec row or a documented deliberate CLI-only extra.

A new command, flag, output field, or validation surface fails CI until the
mapping and required tests are present. This prevents a stable aggregate
percentage from hiding untested functionality growth.

### 10.5 Trusted policy and tamper resistance

`governance / required` is the sole permitted `pull_request_target` workflow.
It runs only the protected base branch's workflow code with explicit read-only
metadata, contents, and pull-request permissions and no secrets. It never checks
out, imports, sources, or executes the proposal ref. It reads changed paths and
blobs as untrusted data through the API.

The enforcement control plane includes:

- `.github/workflows/**`, `.github/actions/**`, the PR template, and
  `.github/dependabot.yml`;
- the coverage policy, parser, exclusions, target inventory, capability-test
  manifest, and PR metadata validator;
- every deterministic quality driver, privacy/secret policy, release builder,
  Pages builder, and action pin/allowlist validator under `scripts/**`;
- the pinned documentation dependency manifests and locks.

An ordinary product, documentation, or dependency PR fails if it changes an
enforcement-control-plane path. A control-plane change must be a dedicated
policy PR with no product-source, product-documentation, version, or release-note
change. The current base policy remains the blocking policy for that PR; the
proposed policy runs separately without secrets as advisory evidence. The
trusted check rejects a lower aggregate or changed-line floor, a lower target
baseline, an expanded exclusion without an exact reviewed reason, a broader
token permission, a newly privileged trigger, a floating Action ref, or mixing
policy and product changes.

The only automated control-plane exception is a Dependabot-authored GitHub
Actions pin-update PR. It may change only workflow files. A trusted-base
structural comparison must prove that the parsed workflows are identical except for
allowlisted `uses:` commit SHAs and their adjacent version comments. Every new
ref must be a verified full commit SHA for the same allowlisted Action; triggers,
permissions, expressions, inputs, shell commands, and all other nodes must be
unchanged. The base policy remains blocking, the proposed pins run only in the
secret-free advisory lane, one qualified approval is required, and auto-merge is
forbidden. Any broader Dependabot workflow diff fails and must be recreated as a
dedicated human-authored policy PR.

`Package.swift`, `Package.resolved`, and any future executable dependency lock
are governed execution surfaces rather than policy implementations. A trusted
base check evaluates their diff, target inventory, resolved pins, and coverage
effects. Dependency-only updates remain dedicated PRs. A structural package
change that must accompany a new target is allowed only when the trusted generic
inventory discovers every new production source and applies the new-target 90%
floor; it cannot supply its own denominator or exclusions.

After a policy PR merges, exact protected-branch quality exercises the new
policy before it can govern a later product PR. A red main result blocks all
release preparation and subsequent merges until a new dedicated policy PR fixes
it. No PR is allowed to provide both weaker enforcement and product code that
benefits from it.

## 11. Coverage policy

### 11.1 Included production sources

Coverage includes Swift sources under:

```text
Sources/AppleKit/**
Sources/EventKitCore/**
Sources/MessagesKit/**
Sources/MailKit/**
Sources/ContactsKit/**
Sources/NotesKit/**
Sources/CalendarKit/**
Sources/RemindersKit/**
Sources/apple/**
```

Coverage excludes test targets, `Sources/TestSupport/**`, fixtures, dependency
checkouts, generated build trees, and system frameworks. No production target
may be excluded wholesale.

### 11.2 Measurement

The canonical macOS 26 lane runs SwiftPM with code coverage enabled and exports
LLVM's machine-readable coverage data. A line enters the denominator only when
LLVM reports an executable region for that line. Comments, blank lines,
non-executable declarations, tests, and excluded support sources do not enter
the denominator.

Paths are normalized to repository-relative paths before evaluation. Coverage
comparisons use integer cross-multiplication rather than rounded display
percentages.

### 11.3 Hard gates

For each pull request:

- head aggregate production coverage is at least 90%;
- changed coverable production lines are at least 90% covered;
- each existing production target's head ratio is not lower than its base
  ratio;
- each new production target is at least 90% covered;
- every expected production target appears in the report.

A diff with no coverable changed lines reports `N/A (0 coverable lines)`, not a
manufactured 100%.

The first implementation measurement may reveal coverage below 90%. That does
not lower or defer the approved threshold: publication and ruleset activation
remain blocked while tests are added until the genuine aggregate reaches 90%.

Exclusions require exact paths or ranges, a reason, and independent review.
Coverage, target floors, and exclusions cannot be weakened by an ordinary PR.

## 12. macOS and version-line policy

| Product state | Required hosted matrix | Artifact runner |
|---|---|---|
| `main` at 26.x | macOS 26 | macOS 26 arm64 |
| macOS 27 adoption PR | macOS 26 plus stable macOS 27 | no publish |
| `main` at 27.x | macOS 26 plus stable macOS 27 | macOS 27 arm64 |
| Optional 26.x maintenance line | macOS 26 | macOS 26 arm64 |

`macos-latest` is not used as a compatibility claim. A macOS 27 adoption cannot
complete while only preview tooling exists; it requires a stable hosted image
or a separately reviewed, hardened alternative.

`main` remains the newest product line. Adopting macOS 27 while continuing to
support macOS 26 does not automatically create `26.x`. A maintenance branch is
created lazily only after real runtime or behavior divergence. Each active line
owns its workflow, test driver, action pins, coverage comparison, and runner
policy. No maintenance workflow references policy from `main`.

Maintenance release tag discovery is branch-reachable, not repository-global.
Maintenance releases are non-latest. Pages `/` remains the numerically newest
stable release even when an older line receives a later patch.

## 13. Manual and Pages sources

The existing manual pipeline remains authoritative:

```text
binary command definitions
  + docs/manual-prose.json
  + docs/manual-static/**
        -> scripts/gen-manual.py
        -> tracked docs/manual/**
        -> pinned MkDocs toolchain
        -> Pages artifact
```

Pull requests verify generated-manual freshness, run `mkdocs build --strict`,
and may upload a downloadable preview artifact. They never deploy. Protected
branch pushes validate only and do not publish unreleased documentation.

The Python documentation toolchain is pinned in a tracked dependency manifest
before Pages or Dependabot is enabled for it.

## 14. Release preparation and exact candidate

The release-preparation workflow calculates the next version from branch-
reachable Conventional Commit subjects. It creates an ordinary PR whose allowed
source changes are:

- `AppleVersion.current`;
- moving `[Unreleased]` into the dated version heading;
- version-dependent generated documentation only when generation proves it is
  necessary.

The normal path passes one independent approval and the full required gate. An
operator bypass is permitted but is not quality evidence. The exact commit that
lands on the protected target branch becomes the only release candidate, and
the publisher reruns the full gate on that candidate. The publisher may not
amend it or make a follow-up source commit.

Protected PRs are squash-merged. Because squash creates a new commit object,
the trusted listener verifies that the candidate tree exactly equals the final
approved, up-to-date PR head tree and that the approving review still applied to
that head, or records that the exact operator bypass was used. It also verifies
that the candidate subject equals the final PR title and the candidate body
equals the final PR description. Post-merge quality tests the candidate object
itself; the later operator environment approval explicitly approves that
candidate SHA for publication.

After exact protected-branch quality succeeds, a trusted default-branch
listener validates the branch, commit subject, version, and workflow conclusion
without checking out untrusted PR content. It uses the built-in token's
documented `workflow_dispatch` exception to start the publisher with the full
candidate SHA, version, and target line. The operator therefore did not initiate
the publisher and remains eligible to approve a prevent-self-review environment.

## 15. Publisher

### 15.1 Read-only preflight

Before requesting deployment approval, the publisher verifies:

- candidate SHA is still the target branch tip;
- required checks succeeded for that exact SHA;
- version constant, CHANGELOG heading, requested version, and line policy agree;
- the prior release tag is branch-reachable and series-correct;
- the new tag is absent, or already points to the same candidate during an
  idempotent resume;
- release notes and generated manual satisfy their contracts;
- the full deterministic quality driver passes on the exact candidate;
- the release archive extracts cleanly;
- checksum, architecture, linkage, and runtime version agree;
- the Pages artifact and version manifest are deterministic and coherent.

### 15.2 Operator deployment approval

All outward write steps execute in the protected `github-pages` production
environment. Its deployment-ref policy allows only the protected target branch:
`main`, plus an exact active maintenance-branch name after that branch is
separately created and protected. It accepts no wildcard release, proposal, or
tag ref. The environment lists only the operator as required reviewer, enables
prevent-self-review, and disables administrator bypass. The job cannot start or
receive its write token until the operator approves it.

The approved job is the only job with the combined narrow permissions needed
for the exact version tag, draft/published release, artifact attestation, and
Pages deployment: only the required `contents`, `pages`, `id-token`, and
`attestations` writes plus read-only Actions metadata. It receives no workflow,
pull-request, issue, administration, or environment-management permission and
has no branch-write operation.

### 15.3 Publication order

```text
operator environment approval
  -> create immutable annotated tag at the exact candidate
  -> create or resume draft GitHub Release
  -> upload and verify binary, checksum, and provenance
  -> deploy the complete Pages artifact
  -> canary /, /version/, archive paths, and manifest
  -> publish the immutable GitHub Release
  -> trigger the separately governed distribution update
```

Keeping the release draft until Pages passes prevents a published release from
pointing at stale documentation. There is no transaction spanning Git refs,
Releases, and Pages; idempotent resume rules handle partial state. If the Pages
canary or Release publication fails after the candidate site is deployed, the
same approved job automatically restores the prior verified manifest before it
exits. A failed transaction may leave only the exact tag and draft Release; it
must not leave `/` pointing at an unpublished candidate.

## 16. Pages version model

Published, non-draft, non-prerelease GitHub Releases are the durable archive
source. The explicit candidate is added only while assembling the pending
release artifact.

Selection rules:

```text
current = numerically highest stable release, including the approved candidate
group stable releases by MAJOR.MINOR
series_tip = highest patch in each series
archives = every series_tip except the current series
```

Routes:

```text
/                              newest released documentation
/version/                      prior-series archive index
/version/MAJOR.MINOR/          highest patch of each prior series
/version-manifest.json         machine-readable selection and digests
```

A patch release updates `/` without creating a patch path. When a newer
minor becomes current, the displaced minor's highest patch becomes its archive.
A later maintenance patch on an older series replaces that series' stable
archive path without displacing `/`.

Outside the bounded publication transaction, `/` must always match the
highest published stable Release. The approved candidate may occupy that route
only between its successful Pages deployment and immediate Release publication.
Any failure in that interval triggers restoration of the prior manifest before
the workflow reports failure.

The manifest records, without wall-clock nondeterminism:

- schema version;
- current and archived series;
- selected semantic version and tag;
- exact commit ID;
- public path;
- content-manifest digest.

The builder starts from an empty temporary directory, validates semantic tags,
rejects path traversal, links, collisions, drafts, and prereleases, and verifies
every tag-to-commit mapping. It copies tracked generated manual inputs from
trusted release tags and renders them with the current SHA-pinned documentation
toolchain. It does not execute historical binaries or scripts and does not use
retention-limited historical Actions artifacts as the archive.

A protected manual reconciliation workflow can rebuild the complete site from
published releases or select a previously published stable tag as `/`
for recovery. Release and reconciliation use one shared concurrency group with
`cancel-in-progress: false`.

## 17. Dependabot and supply-chain updates

`.github/dependabot.yml` enables weekly, staggered update PRs for:

- `github-actions` at repository root;
- the tracked Python documentation dependency manifest;
- SwiftPM after a private empirical Swift tools-version 6 update check succeeds.

Minor and patch updates are grouped per ecosystem. Major updates remain
individual. Open PR counts are bounded, titles remain Conventional Commit-
compatible, and unattended auto-merge is disabled. Every dependency PR requires
ordinary secret-free CI and one qualified independent approval unless the
operator deliberately uses the exact-user bypass.

Before activation:

- every third-party Action is pinned to a verified full commit SHA;
- repository policy requires full-SHA Action references;
- allowed Actions are restricted to the reviewed allowlist;
- dependency graph, vulnerability alerts, and security updates are enabled.

A `github-actions` Dependabot PR uses only the narrow workflow-pin exception in
Section 10.5. It cannot change triggers, permissions, commands, inputs, or any
non-workflow file and receives no bypass authority.

If native Swift 6 updates fail empirically, Dependabot remains active for
Actions and documentation while a scheduled read-only Swift dependency
freshness check reports available updates. It does not auto-merge or publish.

## 18. Private bootstrap and migration

The bootstrap proceeds while the repository is private:

1. Implement the design in reviewed, test-green logical commits under the
   existing private main-only rule.
2. Measure production coverage and add tests until aggregate coverage is
   genuinely at least 90%.
3. Run the full local canonical suite and independent code, security, and critic
   review on every sensitive commit.
4. Obtain at least one successful private hosted Actions run of every mandatory
   job. A job that never receives a runner is not evidence.
5. Configure squash-only merging with PR title and PR body as the squash commit
   title and body; disable merge commits and rebase merges.
6. Create an operator-authored validation PR and verify that one qualified
   independent approval satisfies the normal rule.
7. Push another proposal commit and verify the old approval becomes stale.
8. Verify an intentionally failing required job blocks a non-bypass merge.
9. Verify strict up-to-date checks and exact protected-branch checks.
10. Activate the `main` ruleset with only the operator's exact user in `always`
    bypass mode. Confirm non-operator direct and force pushes fail.
11. Exercise the operator bypass on a disposable branch protected by the same
    rule, including a lease-protected force-push rehearsal. Do not rewrite
    `main` merely to prove the capability.
12. Native-squash a successful validation PR and verify the resulting `main`
    commit title, body, tree, review, and check provenance exactly.
13. Activate the `v*` tag ruleset, full-SHA Action policy, and allowed-Action
    policy.
14. Enable and validate governed Dependabot updates.
15. Exercise release preparation, publisher preflight, Pages assembly, and
    recovery in non-publishing mode.
16. Verify the complete Pages artifact without enabling Pages.
17. Capture private readiness evidence and stop before visibility, Pages,
    release, Homebrew, or freeze changes.

Bootstrap release-preparation exercises use an isolated clone or an ordinary
proposal PR that is never merged. They may compute and display a synthetic
candidate in value-free evidence, but they do not change
`AppleVersion.current` on `main`, promote `[Unreleased]`, create a tag, create or
edit a Release, or deploy Pages. Any validation PR and proposal ref are closed
and removed after evidence is captured.

If the current account plan cannot enforce a required private-repository
feature, implementation prepares and validates everything possible but does not
weaken the design. Activation waits until the repository is public or the plan
supports the control. Required branch checks must not be activated until hosted
Actions can allocate runners and pass, or they could lock the repository behind
checks that cannot start.

## 19. Failure and recovery

| Failure | Preserved state | Recovery |
|---|---|---|
| Proposal branch or PR creation failure | No protected-ref change | Correct the proposal operation; retry without touching `main` |
| PR CI failure | PR remains open | Fix through proposal branch; stale approval requires re-review |
| Native squash metadata mismatch | `main` is red; release remains blocked | Correct through a reviewed PR or an explicit operator history-repair decision |
| Exact-branch CI failure | No release enqueue | Fix through another approved PR |
| Publisher preflight failure | No outward write | Correct through PR; retry exact candidate |
| Operator rejects deployment | No outward write | Run stops rejected |
| Tag or draft partial state | Only exact candidate may resume | Resume idempotently; never retarget tag |
| Asset verification failure | Release remains draft | Correct draft assets before publication |
| Pages deployment or canary failure | Release remains draft; exact tag may exist | Automatically restore prior verified manifest; resume only after re-verification |
| Release publication failure | Exact tag and draft may exist | Automatically restore prior verified manifest; resume publication only after re-verification |
| Distribution update failure | GitHub Release and Pages remain valid; prior package stays served | Retry downstream update |
| Published binary defect | Published release remains immutable | Fix forward with a new patch release |
| Dependabot ecosystem rejection | Other ecosystems remain active | Disable only failing entry; use freshness monitor |

Publisher resume refuses:

- a tag pointing to a different commit;
- a candidate no longer at target branch tip;
- a missing or stale required check;
- an already-published asset with a different checksum;
- mutation or overwrite of published immutable assets.

## 20. Known prerequisites, not design exceptions

1. Hosted Actions must successfully allocate runners before required checks are
   activated or claimed as verified.
2. At least one trusted collaborator must have enough repository permission for
   GitHub to count their review before the independent-review path can be proven.
3. Swift 6 Dependabot compatibility requires a private empirical check.
4. A future macOS 27 line requires a stable hosted runner or a separately
   reviewed hardened alternative.
5. Private-repository ruleset and environment features depend on the account
   plan; no unavailable control may be silently omitted.
6. Live Pages behavior cannot be exercised before the separately authorized
   publication stage.
7. The tag ruleset must be able to identify only the environment-gated
   publisher. If it cannot, publication waits for a safely selectable publisher
   identity.

## 21. Acceptance criteria

The private automation program is ready for a later publication decision only
when:

- macOS 26 is documented as the current tested and supported baseline, future
  majors become supported only after validation, macOS 14 through 25 are
  documented as untested and unsupported, and the technical package deployment
  floor remains macOS 14;
- the PR template contains exactly Rationale, Details, Testing, and Checklist
  as its four top-level sections;
- every mandatory private hosted job allocates a runner and passes;
- trusted-base governance rejects policy tampering and mixed policy/product PRs;
- aggregate and changed-line coverage are each at least 90%;
- every production target is present and non-regressing;
- new commands and contract surfaces cannot enter without mapped tests;
- hosted-safe CLI tests run in Actions and live/TCC tests remain isolated;
- operator-authored PR creation and qualified independent approval are verified;
- stale approval dismissal is verified;
- squash is the only enabled merge method, and a merged PR's final title and
  description exactly become the `main` commit header and body;
- the operator's exact user is the sole always-bypass actor and every
  non-operator contributor is unable to direct-push or force-push `main`;
- the operator bypass and lease-protected force-push capability are verified on
  a disposable protected branch rather than by rewriting `main`;
- the exact release candidate passes the full publisher preflight;
- bot-triggered, operator-approved environment gating is verified without
  publishing;
- Pages `/`, `/version/`, prior-series paths, manifest, reconciliation,
  and canaries validate in non-deploying tests;
- Dependabot works for every enabled ecosystem and never auto-merges;
- all Actions use full commit SHA references;
- the repository is still private;
- no Pages deployment, release, tag, Homebrew change, visibility change,
  version deployment, or release-freeze lift occurred.

## 22. Primary references

- [GitHub Actions fork settings](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository)
- [Secure use of GitHub Actions](https://docs.github.com/en/actions/reference/security/secure-use)
- [Protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)
- [Repository rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)
- [Pull-request review limitations](https://docs.github.com/en/pull-requests/how-tos/review-pull-requests/reviewing-proposed-changes-in-a-pull-request)
- [Creating repository rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository)
- [Rulesets REST API](https://docs.github.com/en/rest/repos/rules)
- [Configuring squash commits](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/configuring-commit-squashing-for-pull-requests)
- [`GITHUB_TOKEN` event behavior](https://docs.github.com/en/actions/concepts/security/github_token)
- [Deployment environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
- [Custom Pages workflows](https://docs.github.com/en/enterprise-cloud@latest/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)
- [Reusable workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations)
- [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [SwiftPM test coverage](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/SwiftTest.md)
- [Dependabot configuration](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-options-reference)
- [Dependabot on Actions](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-on-actions)
- [Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
- [Artifact attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations)
