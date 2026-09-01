# Publication Automation Design

**Status:** Approved for private implementation on 2026-09-01. Publication is
not authorized by this document.

## 1. Purpose

Prepare `apple-cli` for a later public launch with enforceable contribution,
testing, documentation, dependency, and release controls. The system must bind
the PR-approved content tree to one exact post-merge candidate Git object ID,
then make the tested commit, tag, released binary, and published manual trace to
that candidate. The separate deployment approval names that exact candidate.

This design replaces the private, owner-operated direct-to-`main` workflow only
after a private bootstrap proves the replacement works. Until that activation
point, the repository's existing main-only rule remains authoritative.

## 2. Goals

1. Require every post-bootstrap `main` change to arrive through a pull request.
2. Require the repository operator's GitHub approval before every pull request
   can merge.
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

- After bootstrap activation, every `main` update requires a pull request.
- A repository-scoped GitHub App opens operator-directed pull requests so the
  App, rather than the operator, is the pull-request author.
- The operator is the sole repository-wide CODEOWNER and supplies the required
  GitHub approval.
- Outside contributors and Dependabot open pull requests under their native
  identities and require the same operator approval.
- Every pull request is squash-merged. Its final PR title becomes the exact
  Conventional Commit header on `main`, and its final PR description becomes
  the commit body.
- A separate repository-scoped merge App performs the mechanical merge only
  after the operator's approval and every required check apply to the exact
  head SHA and final title/body pair.
- No authoring identity can approve, merge, deploy, or bypass required checks;
  the merge App cannot approve, author changes, deploy, or bypass rules.
- There is no routine direct-to-`main`, pull-request-only, administrator, App,
  or Dependabot bypass after bootstrap.

GitHub does not let a pull-request author approve their own pull request. If an
operator-directed pull request is accidentally opened under the operator's
identity, it must be closed and recreated by the authoring App before it can
satisfy the approval rule.

### 4.3 Deployment model

- Release preparation is an ordinary App-authored pull request.
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
| Operator | Review and approve PRs; approve production deployment; administer settings | Self-authored PR approval; routine direct `main` push; unreviewed publication |
| Authoring App | Open/update proposal PRs for existing same-repository branches | Approve, merge, write repository contents or refs, edit workflows, bypass rules, tag, release, deploy, change settings |
| Merge App | Squash-merge an approved, checked exact PR head using its final title and body | Author changes or PRs; approve; bypass rules; direct-push; tag; release; deploy; change settings |
| PR `GITHUB_TOKEN` | Read source; upload non-sensitive checks and artifacts | Write repository contents; receive ordinary secrets; deploy; publish |
| Publisher | After environment approval, create the exact version tag, draft/release assets, and Pages deployment | Mutate branches; generate new source changes; retarget or delete published tags |
| Dependabot | Open dependency PRs | Auto-merge, approve, deploy, or access ordinary Actions secrets |
| Outside contributor | Open fork PRs and receive public CI results | Secrets, write tokens, TCC/live runners, release authority |

The repository owner remains the GitHub control-plane root. Repository settings
cannot cryptographically prevent the owner from deliberately removing a rule.
These controls prevent accidental or routine bypass and provide an auditable
normal path; they do not claim protection against an owner-account compromise.

## 6. Pull-request and merge Apps

### 6.1 Installation and permissions

The App is private and installed on this repository only. It receives only:

- repository metadata read access;
- pull-request write access.

It receives no repository-contents, Actions, checks, workflows, administration,
environments, deployments, release, Pages, approval, merge, ruleset-bypass,
visibility, or cross-repository authority. It cannot create or update a branch,
tag, file, Release, or workflow; its only write surface is pull-request metadata.

The App private key is stored outside the repository behind a trusted
preparation environment. Each use mints a repository-scoped installation token
with a one-hour lifetime and the smallest required permission subset. Tokens
must never be printed, uploaded, cached, or written to the checkout.

### 6.2 Ordinary operator-directed change

The privileged opener runs only trusted default-branch code. Before minting an
App token, it validates the proposal repository, full ref, and immutable head
object ID through the API. It treats branch names, titles, and body text as
untrusted data, constructs the body from the default-branch template, and never
checks out, sources, interpolates into a shell, or executes proposal-branch
content while App credentials are available. It passes the short-lived token
directly to the PR API and never logs, persists, caches, or uploads it.

```text
operator or trusted agent prepares and pushes a proposal branch
  -> trusted default-branch PR-opener mints an App token
  -> App opens the PR with the repository template
  -> secret-free required CI runs
  -> operator reviews and approves the final diff
  -> merge controller revalidates the exact head, metadata, approval, and checks
  -> merge App supplies the exact PR title/body to GitHub's squash API
```

The App need not push ordinary proposal commits. The operator may push them to
the proposal branch, because GitHub's self-approval prohibition is based on the
pull-request author. Stale-review dismissal ensures any later commit removes the
prior approval and requires the operator to approve again.

The design deliberately does not require approval from someone other than the
latest branch pusher. That GitHub option would deadlock an operator-pushed branch
when the operator is also the required reviewer.

### 6.3 Merge controller

The merge App is private and installed only on this repository. It receives
repository metadata read access and repository contents write access, the
permission GitHub's pull-request merge API requires. The `main` and `v*`
rulesets grant it no bypass. It has no administration, Actions, checks,
workflows, environments, deployments, Pages, approval, or cross-repository
authority. GitHub exposes pull-request merging through repository-contents write
permission, which also technically authorizes other contents endpoints. That
unavoidable permission breadth is contained by the no-bypass `main` and `v*`
rulesets, short-lived tokens minted only inside trusted controller code, and a
separate publisher identity; it must not be described as endpoint-level least
privilege that GitHub does not offer.

A trusted default-branch controller, never proposal-branch code, mints the
short-lived merge token. Immediately before merging, it re-fetches and verifies:

- the pull request is open, non-draft, and targets the expected protected line;
- the exact current head SHA is strictly up to date;
- every required check succeeded for that SHA;
- the current title and description satisfy the metadata contract;
- the latest valid operator approval applies to that SHA and was submitted
  after the current metadata-policy check completed;
- the PR is mergeable without bypassing any ruleset.

The controller then calls GitHub's pull-request merge API with the verified head
SHA, `merge_method: squash`, the final PR title as `commit_title`, and the final
PR description as `commit_message`. Supplying the head SHA makes a concurrent
source update fail rather than merge a different tree. A title or description
edit reruns metadata policy; the resulting check completes after the old review,
so the controller requires a new operator approval before merging. The
controller treats an API response as provisional until it verifies the new
`main` commit's tree, header, body, PR association, approval, and check
provenance.

The repository owner remains able to alter settings or deliberately use the
GitHub merge UI because this is a user-owned repository. That control-plane
caveat cannot be removed technically. The merge controller is the only supported
normal merge path, and the protected-branch backstop makes any divergent result
red and blocks later merges and releases.

### 6.4 Release-preparation change

The trusted release preparer creates and pushes the proposal branch using the
operator's normal branch credentials. The App only opens the PR. A strict
allowlist limits the resulting diff to the version constant, CHANGELOG
promotion, and version-dependent generated documentation when needed. Any other
changed path fails preparation before the branch is pushed.

## 7. Repository protection

### 7.1 CODEOWNERS

The base branch carries `.github/CODEOWNERS`. The operator is the only owner for
the full tree. High-authority surfaces are repeated for visibility even though
the global rule already covers them:

```text
*                                @robertvitali
/.github/CODEOWNERS              @robertvitali
/.github/workflows/              @robertvitali
/scripts/                        @robertvitali
/Package.swift                   @robertvitali
/Package.resolved                @robertvitali
/docs/manual-prose.json          @robertvitali
```

Adding another owner to the global rule is a policy change because GitHub
accepts approval from any matching code owner.

### 7.2 `main` and active maintenance lines

Rulesets require:

- a pull request;
- one approving review;
- review from CODEOWNERS;
- dismissal of stale approvals after code changes;
- conversation resolution;
- the stable `governance / required` check;
- the stable `quality / required` check;
- strict up-to-date status checks before merge;
- linear history;
- no force pushes;
- no deletion;
- no bypass actor.

Repository merge settings permit squash merge only: merge commits and rebase
merges are disabled. The configured squash title source is `PR_TITLE`, and the
squash message source is `PR_BODY`; these are defense-in-depth defaults rather
than the enforcement boundary because GitHub permits editing the proposed merge
message. A required governance check verifies those settings and the merge-App
configuration. The merge controller supplies the final title/body explicitly,
and protected-branch CI verifies that each resulting `main` commit header and
body equal the merged PR title and description after normalizing Git's terminal
newline. A mismatch makes `main` red and blocks every later merge and release
until corrected through the protected PR path.

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
App-created PRs populate the same template explicitly; API-created PRs must not
omit or replace it.

The completed description is also the future squash-commit body. Its final
lines carry the contiguous `Reviewed-by:` and applicable `Co-Authored-By:`
trailer block required by repository policy, with no internal tracker trailer.
The operator reviews the final title and description before approval.

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
recomputed for the final title/body pair. The merge controller requires the
operator's approval to be newer than that successful metadata result, binding
approval to the title and body that will become the commit. Checkboxes
communicate readiness; they never replace the operator approval or required
Actions result.

## 9. Outside-contributor and dependency PR safety

Outside-fork CI uses `pull_request` with a read-only token and no secrets.
First-time contributor runs require maintainer approval after the diff is
inspected, especially changes to `Package.swift`, dependency locks, scripts, and
workflow files.

No workflow may:

- check out or execute fork code under `pull_request_target`;
- treat a fork artifact as trusted executable input in a privileged
  `workflow_run`;
- expose App keys, release credentials, environment secrets, or write tokens;
- run fork code on self-hosted, persistent, live-store, or TCC-enabled runners;
- grant fork code tag, Release, Pages, or distribution authority.

Workflow-file changes are ordinary untrusted code until merged through the
operator-approved path. Every external Action, including GitHub-authored
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

- `.github/workflows/**`, `.github/actions/**`, `.github/CODEOWNERS`, the PR
  template, and `.github/dependabot.yml`;
- the coverage policy, parser, exclusions, target inventory, capability-test
  manifest, and PR metadata validator;
- every deterministic quality driver, privacy/secret policy, release builder,
  Pages builder, and action pin/allowlist validator under `scripts/**`;
- the pinned documentation dependency manifests and locks.

An ordinary product, documentation, or dependency PR fails if it changes an
enforcement-control-plane path. A control-plane change must be an App-authored,
dedicated policy PR with no product-source, product-documentation, version, or
release-note change. The current base policy remains the blocking policy for
that PR; the proposed policy runs separately without secrets as advisory
evidence. The trusted check rejects a lower aggregate or changed-line floor, a
lower target baseline, an expanded exclusion without an exact reviewed reason,
a broader token permission, a newly privileged trigger, a floating Action ref,
or mixing policy and product changes.

The only non-App control-plane exception is a Dependabot-authored GitHub Actions
pin-update PR. It may change only workflow files, and a trusted-base structural
comparison must prove that the parsed workflows are identical except for
allowlisted `uses:` commit SHAs and their adjacent version comments. Every new
ref must be a verified full commit SHA for the same allowlisted Action; triggers,
permissions, expressions, inputs, shell commands, and all other nodes must be
unchanged. The base policy remains blocking, the proposed pins run only in the
secret-free advisory lane, operator approval is required, and auto-merge is
forbidden. Any broader Dependabot workflow diff fails and must be recreated as a
dedicated App-authored policy PR.

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
reachable Conventional Commit subjects. It creates an App-authored PR whose
allowed source changes are:

- `AppleVersion.current`;
- moving `[Unreleased]` into the dated version heading;
- version-dependent generated documentation only when generation proves it is
  necessary.

The PR passes ordinary operator approval and the full required gate. The exact
commit that lands on the protected target branch becomes the only release
candidate. The publisher may not amend it or make a follow-up source commit.

Protected PRs are squash-merged. Because squash creates a new commit object,
the trusted listener verifies that the candidate tree exactly equals the final
approved, up-to-date PR head tree and that the approving review still applied to
that head. It also verifies that the candidate subject equals the final PR title
and the candidate body equals the final PR description. Post-merge quality tests
the candidate object itself; the later operator environment approval explicitly
approves that candidate SHA for publication.

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
ordinary secret-free CI and operator approval.

Before activation:

- every third-party Action is pinned to a verified full commit SHA;
- repository policy requires full-SHA Action references;
- allowed Actions are restricted to the reviewed allowlist;
- dependency graph, vulnerability alerts, and security updates are enabled.

A `github-actions` Dependabot PR uses only the narrow workflow-pin exception in
Section 10.5. It cannot change triggers, permissions, commands, inputs, or any
non-workflow file and never bypasses operator approval.

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
5. Provision the authoring and merge Apps with their separate approved
   permissions and validate short-lived token handling without printing
   secrets.
6. Configure squash-only merging with PR title and PR body as the squash commit
   title and body; disable merge commits and rebase merges.
7. Create an App-authored validation PR and verify operator CODEOWNER approval.
8. Push another proposal commit and verify the old approval becomes stale.
9. Verify an intentionally failing required job blocks merge.
10. Verify strict up-to-date checks and exact protected-branch checks.
11. Activate the no-bypass `main` rulesets and confirm direct pushes fail for
    both operator and App.
12. Have the merge App squash-merge a successful App-authored validation PR and
    verify the `main` commit title, body, tree, approval, and check provenance
    exactly. Confirm that a metadata edit after approval requires reapproval.
13. Activate the `v*` tag ruleset, full-SHA Action policy, and allowed-Action
    policy.
14. Enable and validate governed Dependabot updates.
15. Exercise release preparation, publisher preflight, Pages assembly, and
    recovery in non-publishing mode.
16. Verify the complete Pages artifact without enabling Pages.
17. Capture private readiness evidence and stop before visibility, Pages,
    release, Homebrew, or freeze changes.

Bootstrap release-preparation exercises use an isolated clone or an
App-authored proposal PR that is never merged. They may compute and display a
synthetic candidate in value-free evidence, but they do not change
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
| App token or proposal failure | No protected-ref change | Mint a new token; retry branch or PR operation |
| PR CI failure | PR remains open | Fix through proposal branch; stale approval requires re-review |
| Merge-controller validation or API failure | PR remains open; no protected-ref change | Re-fetch the exact PR state; reapprove or rerun checks as required; retry without bypass |
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
2. The authoring and merge Apps must be provisioned and installed before the
   protected PR lifecycle can be exercised.
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
- App-authored PR creation and sole operator approval are verified;
- stale approval dismissal is verified;
- squash is the only enabled merge method, and a merged PR's final title and
  description exactly become the `main` commit header and body through the
  exact-SHA merge controller;
- direct `main` pushes are rejected after bootstrap;
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
- [CODEOWNERS](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners)
- [Pull-request review limitations](https://docs.github.com/en/pull-requests/how-tos/review-pull-requests/reviewing-proposed-changes-in-a-pull-request)
- [GitHub App permissions](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app)
- [GitHub App installation authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation)
- [Configuring squash commits](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/configuring-commit-squashing-for-pull-requests)
- [Pull-request merge API](https://docs.github.com/en/rest/pulls/pulls#merge-a-pull-request)
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
