# Publication Automation Design

**Status:** Approved for private implementation on 2026-09-01; sequencing amended
on 2026-09-10. The operator's 2026-09-06 conditional visibility authorization
continues: finish the pre-visibility implementation, review, full local gates,
and fresh privacy audit, then change visibility. Mandatory hosted validation and
its dependent rehearsals follow public visibility, rather than waiting for the
previous October 1 quota-reset date. This is not an immediate visibility change
or authorization to publish a release, tag, Pages site, or Homebrew artifact.
References below to the future publisher's public-launch phase mean separately
authorized version-publication work, not the earlier visibility-only transition.
**Amended 2026-09-20 (HUMAN-DECISIONS D17):** the operator advanced the visibility step ahead of
the unevidenced pre-visibility items; see the §18 amendment for the exact pre-flip blockers.

## 1. Purpose

Prepare `apple-cli` for a later public launch with enforceable contribution,
testing, documentation, dependency, and release controls. The system must bind
the protected-branch content tree to one exact post-merge candidate Git object
ID, then make the tested commit, tag, released binary, and published manual
trace to that candidate. During a later authorized public launch, the separate
deployment approval names that exact candidate.

This design makes reviewed pull requests the normal replacement for the private,
owner-operated direct-to-`main` workflow only after the bootstrap, including
post-visibility hosted rehearsals, proves the replacement works. It deliberately
retains an exact-user operator bypass.
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
- install or enable a write-capable publisher workflow;
- configure or claim a required-reviewer deployment environment;
- publish or modify a Homebrew formula or tap;
- dispatch the existing release workflow;
- hand-edit `AppleVersion.current`;
- lift the release freeze;
- create a maintenance branch before a real compatibility divergence exists;
- execute untrusted fork code on a self-hosted, TCC-enabled, or persistent
  runner;
- create a bot account, GitHub App, personal access token, or deploy key for
  publication;
- add an Actions or Dependabot secret, or a repository or environment variable
  that grants or authorizes an outward write;
- configure an OIDC or artifact-attestation trust relationship;
- add unrelated product functionality.

The conditional visibility step is authorized only after the pre-visibility
gates in Section 18 pass. All other outward publication actions remain subject
to separate explicit instructions. The approved continuation stops before
Homebrew distribution and does not lift the release freeze. Public visibility
alone grants no publisher, deployment, collaborator-write, or bypass authority.
**Amended 2026-09-20 (HUMAN-DECISIONS D17):** the "only after the pre-visibility gates in
Section 18 pass" ordering was advanced by the operator; the visibility step now waits on the
exact blockers named in the §18 amendment, and everything else in this section stands.

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
- The operator's exact GitHub user is the sole `always` bypass actor on `main`.
  This lets the operator deliberately merge without approval, push directly, or
  force push when necessary. No collaborator role, administrator role, or App
  receives bypass authority on `main`; on tags the only bypass actor is the
  launch-phase publisher principal of Section 7.3, on tag creation alone.
  Dependabot holds exactly one narrow bypass, on the catch-all branch ruleset
  of Section 7.3, whose mechanically enforced boundary is every branch except
  `main` (a bypass actor applies to every ref the ruleset matches, Section 7.3;
  confinement to its own proposal branches is Dependabot's behaviour, not a
  rule); it has no bypass on `main`, on tags, or on any environment. Section 18
  step 13 exercises the review-path half of that boundary; the branch, tag, and
  environment halves are launch-phase controls.
- Every pull request is squash-merged. Its final PR title becomes the exact
  Conventional Commit header on `main`, and its final PR description becomes
  the commit body.
- Native repository settings make squash the only enabled merge method and use
  `PR_TITLE` plus `PR_BODY` as the default commit message. GitHub permits
  editing that default during merge, so protected-branch CI verifies the result
  before any release can proceed.
- No non-operator contributor can bypass the pull-request, review, CI, or
  force-push rules.

### 4.3 Deployment model

Deployment has two deliberately separate phases:

- During private implementation and post-visibility hosted validation, release
  and Pages automation is rehearsal-only.
  It receives one explicit full commit ID, checks out and verifies that object,
  runs the release preflight, and builds release and complete-site artifacts
  without an environment, deployment, tag, Release, Pages, or branch-write
  permission. Before visibility changes the repository must contain no
  write-capable publisher. At the original design baseline, `release.yml`
  carried `workflow_dispatch`, `contents: write`, an atomic push of `main` and
  the version tag, and GitHub Release creation, and `docs.yml`
  carried a `pages` job with `pages: write` and `id-token: write` behind a
  repository variable. A conduct rule ("agents never dispatch it") and a
  variable gate are not technical controls. Converting those existing write
  paths to the read-only rehearsal shape, or removing them, is a required
  bootstrap step (Section 18), and the readiness scan covers every workflow
  under `.github/workflows/`, not only the rehearsal workflows.
- After separately authorized version-publication work, a dedicated bot-initiated
  publisher may be added. Release preparation is then an ordinary protected
  pull request, the publisher never edits source or pushes a branch, and its
  outward-write job waits in an operator-reviewed production environment.

Required environment reviewers are not a private-bootstrap control. Whether a
private user-owned repository on the account's plan can enforce them is a
plan-dependent claim this document does not settle; Section 20 item 5 has the
bootstrap read the actual capability from the API and record it. Either way,
private read-only rehearsals do not create, claim, or simulate that approval;
the real environment and bot path are public-launch work.

## 5. Trust and identity model

| Identity | Allowed | Forbidden |
|---|---|---|
| Operator | Author PRs; review others' PRs; merge; administer settings; bypass branch rules; force push; after public-launch authorization, approve production deployment | Self-approve a PR through GitHub's review UI; publication of a candidate that has not passed the full Section 15.1 gate (the recorded operator bypass substitutes for the approval only) |
| Trusted maintainer/reviewer | Review and approve PRs; merge only after every normal protection passes; contribute through fork branches after launch (repository-hosted branches only before it) | Bypass rules; direct-push or force-push `main`; deploy; publish; merge a control-plane change without the operator's code-owner approval |
| PR `GITHUB_TOKEN` | Read source; upload non-sensitive checks and artifacts | Write repository contents; receive ordinary secrets; deploy; publish |
| Read-only release/Pages rehearsal | Read one exact commit; run tests and preflight; build local release and complete-site artifacts | Environments; write tokens; tags; Releases; Pages deployment; branch mutation; Homebrew |
| Future public publisher | After launch authorization and environment approval, create the exact version tag, draft/release assets, and Pages deployment | Exist as a write-capable private workflow; mutate branches; generate source changes; retarget or delete published tags |
| Dependabot | Open dependency PRs; create and update its own proposal branches under the one Section 7.3 catch-all bypass | Auto-merge, approve, deploy, access ordinary Actions secrets, or hold any bypass on `main`, tags, or environments |
| Outside contributor | Open fork PRs and receive public CI results | Secrets, write tokens, TCC/live runners, release authority |

The repository owner remains the GitHub control-plane root. Repository settings
cannot cryptographically prevent the owner from deliberately removing a rule.
These controls prevent accidental or routine bypass and provide an auditable
normal path; they do not claim protection against an owner-account compromise.

## 6. Native pull-request flow and operator bypass

### 6.1 Ordinary change

```text
operator or contributor prepares and pushes a proposal branch
  (a fork branch for any human other than the operator after launch)
  -> author opens a pull request with the repository template
  -> secret-free required CI runs
  -> one qualified independent reviewer approves the final code
  -> author or maintainer squash-merges with the native GitHub controls
  -> protected-branch CI verifies the resulting tree and commit metadata
```

GitHub does not let an author approve their own pull request. An
operator-authored PR therefore receives its ordinary required approval from
another trusted collaborator with sufficient repository permission.
Outside-contributor and Dependabot PRs follow the same review and CI rules.

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
`--force-with-lease`, after rechecking the remote ref. Plain force still
requires a separate operator confirmation explaining why lease protection
cannot work.

The repository owner remains the control-plane root and can also edit or delete
the ruleset. The design prevents accidental and non-owner bypass; it does not
claim that a personal-repository owner can be made unable to change their own
settings.

### 6.3 Future public release-preparation change

After public-launch authorization, the trusted release preparer (the operator,
or a maintainer working from a fork under Section 7.3) creates and pushes an
ordinary proposal branch. A strict allowlist limits its diff to the version
constant, CHANGELOG promotion, and version-dependent generated documentation
when needed. Any other changed path fails preparation before the branch is
pushed.

## 7. Repository protection

### 7.1 Reviewer policy

The normal path requires one approval from a trusted collaborator whose
repository permission is sufficient for GitHub to count the review. The design
does not require a repository-wide CODEOWNER approval: that would make an
operator-authored PR impossible to satisfy without using the bypass on every
change. It does require a scoped one: `.github/CODEOWNERS` names the operator
for every enforcement-control-plane path of Section 10.5, and the ruleset
requires code-owner review, so a policy PR that changes a workflow, the
manifest, or a driver cannot merge on a non-operator approval, while ordinary
product PRs remain satisfiable by any counted reviewer; because GitHub does not
count an author's own approval and the operator is the sole code owner, an
operator-authored control-plane PR is satisfied only by the operator's sole
ruleset bypass (defined in Sections 6.2 and 7.2, applied in Section 10.5),
permanently and not merely while no reviewer exists; the rule's protection is
therefore specifically against a trusted maintainer merging a control-plane
change, not a source of independent review on operator-authored policy changes,
and Section 20 item 2 records the bypass log as the control plane's audit
record by design. The operator chooses which collaborators receive
review-capable access and does not grant them ruleset bypass.

### 7.2 `main` and active maintenance lines

After public visibility and the successful push-triggered runs of Section 18
step 6, the bootstrap first installs this rule set as an **active** ruleset that
targets one exact disposable validation-branch name. It exercises real accepts
and rejects there, then removes the disposable ref and rehearsal ruleset. It
does not rely on or claim ruleset `evaluate` mode. Only after the active
rehearsal, hosted checks, bypass tests, and rollback path pass may the same
reviewed rule shape be activated for `main` or an active maintenance line.
The disposable ruleset in step 8 precedes the validation PR in step 9, which
produces the first hosted `governance / required` evidence. That first governance
pass is not a prerequisite for installing the disposable rehearsal ruleset.

Rulesets require:

- a pull request;
- one approving review;
- dismissal of stale approvals after code changes;
- conversation resolution;
- the stable `governance / required` check, bound to the expected GitHub
  Actions integration ID so a status of the same name posted by any other App
  or by a person does not satisfy it, and, because any workflow in this
  repository runs under that same App identity, the readiness scan additionally
  requires every check name to be produced by exactly one workflow (a second
  workflow emitting `governance / required` or `quality / required` is a
  control-plane violation), and the publisher accepts a check only from the
  exact workflow ID and path recorded for it, and, because GitHub's required
  checks do not distinguish event or trigger types and are satisfied by a run
  of the workflow under any trigger it declares, the recorded trigger set below
  is a repository governance invariant enforced by the readiness scan and not a
  GitHub enforcement, and the readiness scan records each required workflow's
  trigger set at activity-type granularity (this parenthetical is the normative
  recorded set the Section 18 step 17 scan compares against, so a trigger
  change edits it: `governance / required` runs only under
  `pull_request_target` with the activity types of Section 8, and never under
  `pull_request` or `pull_request_review`, for distinct reasons: GitHub runs a
  `pull_request` workflow from the pull request's merge commit, so a proposal
  supplies its own copy of the file and could emit the required check name from
  it, while `pull_request_review` is excluded without relying on either reading
  of its file-source semantics (GitHub runs it against the pull request merge
  commit with fork restrictions applied, and the two independent reviews of
  this document disagreed on which copy of the workflow file it executes): it
  is an additional review-fired surface any actor able to submit a review can
  trigger, and both the forgery concern and the surface-widening concern point
  the same way; `quality / required` under `pull_request` with its declared
  activity types and under `push` with its declared branch filter, since `push`
  has no activity types and a widened filter is the equivalent change) so that
  a new or dropped trigger, activity type, or branch filter is a control-plane
  change;
- the stable `quality / required` check, bound the same way (Section 18
  step 11 posts a forged same-name status and verifies it is ignored, and
  reads back the `integration_id` of each required check; the expected ID is
  the `app.id` reported on the successful step 6 and step 9 check runs);
- required review from the code owners named in `.github/CODEOWNERS`, which
  lists the operator for every enforcement-control-plane path (Section 7.1), so
  a control-plane change merges only on the operator's approval or through the
  operator's sole bypass (code owners on a private personal-account repository
  are Pro-only; if Section 18 step 4 reads a plan without them, enforcement
  verification waits for the post-visibility readback under Section 20 item 5
  rather than the rule being dropped);
- strict up-to-date status checks before merge;
- linear history;
- force pushes blocked for every non-bypass actor;
- no deletion;
- one bypass entry: the operator's exact GitHub user in `always` mode.

No repository role, team, GitHub App, Dependabot identity, deploy key, or other
user receives bypass on `main` (Dependabot's one bypass is on the Section 7.3
catch-all branch ruleset only). The operator's bypass is deliberately broad
enough to merge without approval, push directly, and force push. Release
automation never treats bypass as quality evidence: at future public launch, an
exact candidate still must pass the full publisher preflight before any
outward-facing action.

Repository merge settings permit squash merge only: merge commits and rebase
merges are disabled. The configured squash title source is `PR_TITLE`, and the
squash message source is `PR_BODY`. GitHub permits editing the proposed merge
message, so a required governance check verifies the repository settings and
protected-branch CI verifies that each resulting `main` commit header and body
equal the merged PR title and description after normalizing Git's terminal
newline and after stripping the ` (#N)` pull-request-number suffix that GitHub
appends to a `PR_TITLE`-sourced squash header. Section 18 step 12 verifies that
suffix behaviour empirically and records the exact normalization; the metadata
check caps the PR title so that the final squash header, suffix included, fits
the 72-character limit of Section 8. A mismatch makes `main` red and blocks
every later merge and release until a corrected candidate passes the protected
checks. An operator bypass may land a corrective commit or perform an
explicitly authorized history repair, but it never makes a red or
metadata-mismatched candidate eligible to publish.

The repository is user-owned. At the time of writing GitHub documents merge
queues for organization-owned repositories, not user-owned ones; no capability
field exists to read, so Section 18 step 4 derives merge-queue availability
from the observed owner type and plan and records that derivation before
anything relies on it. Therefore the launch design uses strict up-to-date
required checks. The quality workflow may later support `merge_group` for a
future organization migration, which is a control-plane change that edits the
Section 7.2 recorded trigger set, but the bootstrap must not claim merge-queue
enforcement that the current ownership model cannot provide.

### 7.3 Tags and releases

Tag protection is a future version-publication control, not a visibility-change
prerequisite. Once version publication is separately authorized, two layered
`v*` tag rulesets apply,
because a single ruleset that grants the publisher bypass for creation would
also let it bypass that ruleset's update and deletion rules. The creation
ruleset names the publisher principal as its only bypass actor, and that
principal is stated exactly, because ruleset bypass is granted to users, teams,
Apps, or integrations, never to an individual workflow, and the built-in
`GITHUB_TOKEN` authenticates as the repository-wide GitHub Actions App shared
by every workflow: the publisher principal is a dedicated GitHub App installed
on this repository, whose private key exists only as a secret on the protected
`github-pages` environment, so only the approved job can mint its installation
token and no other workflow can act as it. The listener still dispatches with
the built-in token, which has no bypass. Each outward write is bound to its
token explicitly: the tag create and the Release and its assets use the App's
installation token, whose installation permissions are `contents: write` and
nothing else (no `workflows`, `administration`, or `environments`), and the
Pages deployment uses the built-in token's `pages` and `id-token` writes.
Because an installation token with `contents: write` is repository-wide, a
catch-all branch ruleset targeting `refs/heads/**` with `main` excluded by
pattern (rulesets support exclusion patterns, and a bypass actor applies to
every ref a ruleset matches, so the scope is carried by the ruleset's target
and not by a per-actor condition) restricts branch creation, update, and
deletion to a bypass list that names the operator's exact user and, for the
proposal branches its PRs need, Dependabot (the only non-operator bypass on a
branch ruleset in the design, the tag-creation publisher principal above being
the other non-operator bypass actor; confined to this ruleset by Section 4 and
exercised in step 13), and that excludes the App; `main` keeps its own ruleset
with the operator as sole bypass actor (so PR merges to `main`, the
disposable-branch rehearsals, and ref cleanup still work while the App's write
can reach tags and Release assets only) and "no branch-write operation" is
enforced by rules rather than by intention; a consequence stated plainly is
that after launch every human contributor other than the operator, trusted
maintainers included, proposes from a fork, because the catch-all leaves
repository-hosted branch creation to the operator and Dependabot alone (Section
9). Step 17 records the App's permission scopes among its read-backs. A
separate update-and-deletion ruleset forbids tag update, force-update, and
deletion with no bypass actor at all, so not even the publisher can retarget or
remove a tag it created. Neither grants any branch authority. If the account
cannot select that exact identity without granting a broader bypass,
publication remains blocked rather than weakening the rule. Release
immutability is then enabled for future releases so published assets and their
tag cannot be silently replaced. Immutable releases also carry the release
attestation GitHub generates automatically; the launch specification records
how that release-level attestation is captured and verified, which is distinct
from the build-provenance attestation this design defers, so the design does
not claim that no attestation exists.

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

The metadata job runs for PR creation, synchronization, reopening,
ready-for-review, and title or description edits, the same activity types the
tracked metadata workflow declares today, and the recorded trigger set of
Section 7.2 is kept at activity-type granularity so that dropping one is a
control-plane change. It verifies the four headings exist exactly once and in
order, the PR title is a valid Conventional Commit header short enough that the
squash header, including the ` (#N)` suffix for this PR's number, fits the
header limit this design enforces, 72 characters (the value Section 7.2 relies
on), required template content is not left as placeholder text, the description
ends in a valid contiguous provenance trailer block, and, because the final
title and description become a public commit on `main` where post-merge
detection is too late, the title and body pass the repository's personal-data
scan (the same classes and engines the tracked audit tooling uses, run from
trusted base code with value-free failure output that names the class and never
the value). Its result is recomputed for the final title/body pair, and because
GitHub does not dismiss approvals on a title or description edit, the check
fails on any such edit until an approving review submitted after that edit
exists, so the final metadata is bound to a fresh approval before the merge
rather than only verified after the squash lands; re-evaluation after the fresh
approval is a manual re-run of the governance run by the merger immediately
before merging, a step this design makes an unconditional merge precondition
for every pull request (Section 10.5), and not an additional trigger; every
checkout step in the governance workflow also sets an explicit `ref` to the
protected base, and the readiness scan asserts that rather than relying on the
head-reference denylist alone. GitHub offers no pre-insertion hook for the
merge dialog's own message field, so a merger's edit there is caught only after
landing, by the protected-branch verification that makes `main` red; the
fresh-approval binding covers the title and description path, which is the only
one a contributor without merge rights can reach. Checkboxes communicate
readiness; they never replace the required independent review or Actions
result. Because GitHub does not make its generated squash message immutable,
protected-branch CI compares the resulting commit with the final PR metadata
before any release.

## 9. Outside-contributor and dependency PR safety

Outside-fork CI uses `pull_request` with a read-only token and no secrets.
First-time contributor runs require maintainer approval after the diff is
inspected, especially changes to `Package.swift`, dependency locks, scripts,
and workflow files. Those properties are read back rather than assumed: Section
18 step 17 records, through the Actions permissions API, that fork pull-request
workflows receive no write token and no secrets or variables and that the
fork-run approval policy requires approval for outside collaborators, and
Section 21 requires those recorded values, because a misconfigured repository
setting would hand both to untrusted fork code no matter what the workflows
declare. Because a private repository cannot receive outside forks (a
collaborator fork is possible where private forking is enabled, which the solo
model does not use, so the setting's write-token and secrets halves are live
only for that case), that private read-back is an assertion about a largely
inert control: the launch specification re-reads the settings that govern the
public repository after the visibility change (the fork-pull-request
contributor-approval policy and whichever write-token and secrets toggles the
public surface exposes, through the endpoints documented for that state, since
the private-repository toggles are a different control surface) and records
those values, since visibility changes both the defaults and the set of actors
who can fork, so the private recording is a precondition and not a substitute.

No workflow may:

- check out or execute fork code under any base-context trigger
  (`pull_request_target`, or any other event that runs with the base
  repository's token);
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

- the deterministic quality drivers (metadata and PR-template policy belong to
  `governance / required` after step 5 folds them in);
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

A recursive inventory derived from `apple --experimental-dump-help` (an
experimental ArgumentParser interface, so the toolchain is pinned and the
inventory builder refuses, rather than silently degrading, when the dump's
shape changes) maps every visible command and parameter to:

- parser and help coverage;
- invalid-input and exit-code coverage;
- JSON-envelope coverage;
- at least one behavior test classified as `logic`, `hosted-smoke`, or
  `local-tcc`;
- its port-spec row or a documented deliberate CLI-only extra.

The manifest keys each entry on the command path plus the flag or field name
only, never on help prose, because every `help:` string is user-facing
documentation that changes often. A regeneration caused solely by help-text
edits is permitted in the same PR as the edit and is not a control-plane
change. A new command, flag, output field, or validation surface fails CI until
the mapping and required tests are present. This prevents a stable aggregate
percentage from hiding untested functionality growth.

### 10.5 Trusted policy and tamper resistance

`governance / required` is the sole `pull_request_target` workflow once the
bootstrap completes. Today the tracked `pr-metadata.yml` (`metadata /
required`) is a second one, and `AGENTS.md` names it as the current exception;
Section 18 step 5 folds it into `governance / required` and updates `AGENTS.md`
in the same commit, so the steady state is exactly one such workflow,
unconditionally, and the readiness scan counts exactly one. It runs only the
protected base branch's workflow code with explicit read-only metadata,
contents, pull-request, checks, and actions permissions (the last two for the
check-run and workflow-run listings it performs; explicit `permissions` sets
every unnamed scope to none) and no secrets. It never checks out, imports,
sources, or executes the proposal ref. Because GitHub's required checks are
satisfied by any check run of the required name from the same App, and a
proposal can rename a job in its own copy of an ordinary `pull_request`
workflow to a required name, the trusted governance run also lists the check
runs on the proposal head through the checks API with `filter=all` (the
endpoint's `latest` default returns only the newest run per name and would hide
a genuine run behind a forged one), resolves each check run's originating
workflow through its check-suite ID (the workflow-runs listing accepts a
`check_suite_id` filter and returns the run's workflow ID and path, so
`details_url` parsing is never relied on), and fails if any check run with a
required name was produced by a workflow other than the recorded one. Because
GitHub resolves a required context to the most recent check run of that name on
the head SHA and the proposal controls when its own job posts, that enumeration
binds only the state at the instant governance ran; a forged check created
afterwards is not caught by it, so the merge-time re-run of `governance /
required` that Section 8 describes is an unconditional merge precondition and
not only a post-edit step, and the residual after that re-run is the interval
between it and the merge, bounded by the code-owner approval of this section.
It reads changed paths and blobs as untrusted data through the API.

The enforcement control plane includes:

- `.github/workflows/**`, `.github/actions/**`, the PR template,
  `.github/CODEOWNERS`, and `.github/dependabot.yml` plus
  `.github/actions-allowlist.json`;
- the coverage policy, parser, exclusions, target inventory, capability-test
  manifest, and PR metadata validator;
- every deterministic quality driver, privacy/secret policy, release builder,
  Pages builder, and action pin/allowlist validator under `scripts/**`;
- the pinned documentation dependency manifests and locks;
- the governance documents themselves: `AGENTS.md`, `HUMAN-DECISIONS.md`, this
  specification, the urgent-release runbook of Section 18 step 5, and the
  readiness evidence file, so a change to a governance claim or to recorded
  evidence is a dedicated policy PR rather than an ordinary edit.

Membership is defined by exact path, not by role: a committed manifest lists
every control-plane file, the manifest is itself in the plane, and any new or
renamed file under `.github/**`, `scripts/**`, `Tests/automation/**`, or
`bats/helpers/**` is treated as control plane until the manifest is updated by
a dedicated policy PR. The last two trees are included because the regression
tests that guard the drivers and the enforcement predicates the Bats tier
executes live there today. More generally, any script, module, data file, or
fixture that an in-plane file reads, imports, or executes as policy is in the
plane, excluding the product artifacts it merely builds, generates from, or
tests (the manual generator executes the built binary, which does not make
`Sources/**` control plane). Such a path outside the four deny-by-default trees
is added to the manifest in a dedicated policy PR that carries only the helper,
its manifest entry, and the matching `.github/CODEOWNERS` pattern (so the newly
registered path has a code owner from the same PR onward; `governance /
required` rejects a manifest whose entries are not all effectively owned by the
operator under CODEOWNERS last-match-wins resolution, which turns step 17's
one-time coverage read-back into a per-PR check) and no product code, which is
what keeps the registration from being circular: the helper cannot arrive as
product code in one PR and be promoted by a later import, because the import
itself is an in-plane driver edit that needs its own policy PR, and that PR
must carry the manifest entry for the helper (already present, or added in that
same policy PR under the union rule below). The trusted check derives nothing
and reads only the manifests, and the in-plane drivers read their policy inputs
only through a loader that refuses any path not listed in the manifest, so an
unlisted input is a runtime failure of the driver rather than a silent read
that widens the plane. A helper cannot join the plane by being added as product
code and then imported by the driver. The trusted check classifies paths
against the union of the base branch's manifest and the proposal's manifest, so
the registering PR is a policy PR by construction (its manifest edit is
in-plane, and the helper it lists is in-plane from that PR onward) and is not
rejected by a base manifest that does not yet list the helper; a proposal that
removes or renames an entry is a policy PR for the same reason, and the loader
in any run reads the manifest at the ref that run executes from.

An ordinary product, documentation, or dependency PR fails if it changes an
enforcement-control-plane path. A control-plane change must be a dedicated
policy PR with no product-source, product-documentation, version, or
release-note change, and it merges only with the operator's code-owner approval
or the operator's sole bypass: `.github/CODEOWNERS` is itself in the plane and
lists the operator for every control-plane tree and manifest entry, so a
trusted maintainer's approval alone can never change the publisher, the
listener, the recovery workflow, a driver, or the manifest. The current base
policy remains the blocking policy for that PR; the proposed policy runs
separately without secrets as advisory evidence. The trusted check rejects a
lower aggregate or changed-line floor, a lower target baseline, an expanded
exclusion without an exact reviewed reason, a broader token permission, a newly
privileged trigger, a floating Action ref, or mixing policy and product
changes.

The only automated control-plane exception is a Dependabot-authored GitHub
Actions pin-update PR. It may change only workflow files. A trusted-base
structural comparison must prove that the parsed workflows are identical except
for allowlisted `uses:` commit SHAs and their adjacent version comments. Every
new ref must be a full commit SHA that the trusted check verifies through the
API as reachable from a tag or the default branch of the same allowlisted
Action's repository (a SHA that exists only on a fork or an unmerged proposal
ref is rejected even though `uses:` would resolve it); triggers, permissions,
expressions, inputs, shell commands, and all other nodes must be unchanged.
"Dependabot-authored" is asserted as the PR author login being
`dependabot[bot]` and the head repository being this repository, never as a
branch-name prefix. The base policy remains blocking, the proposed pins run
only in the secret-free advisory lane, one qualified approval is required, and
auto-merge is forbidden. Any broader Dependabot workflow diff fails and must be
recreated as a dedicated human-authored policy PR.

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

Before visibility, two fresh clean-head local SwiftPM coverage measurements on
the same exact SHA must have identical production totals and satisfy the
aggregate, changed-line, and per-target policies against the recorded baseline.
The full canonical local gate remains separate and required before every push.
After visibility, the recorded validated hosted lane (macOS 26 once a stable
hosted image exists; until then the `macos-15` lane recorded under Section 18
step 5) runs
SwiftPM with code coverage enabled and exports LLVM's machine-readable
coverage data. A line enters the denominator only when
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

The table names the intended lanes. Until a stable `macos-26` hosted image
exists, the `main` row's hosted matrix is the recorded `macos-15` lane of
Section 18 step 5, and the macOS 26 "tested and supported" claim of Goal 7 and
Section 21 rests on the operator's local macOS 26 canonical run recorded in the
readiness evidence. `macos-latest` is not used as a compatibility claim. A
macOS 27 adoption cannot complete while only preview tooling exists; it
requires a stable hosted image or a separately reviewed, hardened alternative.

Before accepting macOS 27, first run the full path-confinement test file
(`Tests/AppleKitTests/PathConfinementTests.swift`) on that stable environment,
including `acceptsSymlinkedParentDotDotWhenFoundationSelectsTheLexicalLeaf`.
That canary asserts which destination Foundation selects through a symlinked
parent and `..`; the guard's `fileExists` branch predicate is measured macOS 26
behavior, not a cross-version API guarantee. Record any changed destination or
refusal behavior and review the guard before accepting the new major. Carry
this check into the macOS 27 adoption checklist when that checklist is created.

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

### 14.1 Read-only exact-SHA preparation rehearsal

The pre-publication workflow is a read-only rehearsal, not a release-preparation or
publisher workflow. It accepts one explicit full commit ID, verifies the
checkout and every generated artifact against that ID, and runs with only the
read permissions required to fetch source and check metadata. It has no
environment, secrets, tag, Release, Pages, attestation, deployment, or branch-
write authority.

Version calculation and release-file transformation run in a fresh temporary
tree or isolated scratch clone. The rehearsal may report the predicted next
version in its run log, clearly labelled as unassigned, while tracked evidence
records only the pass result and never the number itself (a digest of a handful
of candidate versions would be reversed by enumeration) (because the release
freeze forbids committing, tagging, or describing shipped work by a version
that has not been given, not computing it), the exact file allowlist, and
deterministic artifact digests, but it cannot push the transformed tree, modify
`main`, create a proposal ref, or call an outward- write API. A source-level
guard rejects write permissions and deployment or publication steps in every
private rehearsal workflow.

### 14.2 Future public release preparation

After public launch is separately authorized, release preparation calculates
the next version from branch-reachable Conventional Commit subjects. It runs
only when the advisory operator-set freeze-lift repository variable of Section
15.1 (the binding environment variables are unreadable outside the gated job)
already names that version, and a computed version that differs from the
declared one fails closed rather than auto-correcting, so the release freeze
gates the version bump itself and not only the later publisher. It creates an
ordinary PR whose allowed source changes are:

- `AppleVersion.current`;
- moving `[Unreleased]` into the dated version heading;
- version-dependent generated documentation only when generation proves it is
  necessary.

The normal path passes one independent approval and the full required gate. An
operator bypass is permitted but is not quality evidence. The exact commit that
lands on the protected target branch becomes the only release candidate, and
the future publisher reruns the full gate on that candidate. The publisher may
not amend it or make a follow-up source commit.

Protected PRs are squash-merged. Because squash creates a new commit object,
the trusted listener verifies that the candidate tree exactly equals the merged
pull request's final `head.sha` tree unconditionally (the bypass never relaxes
tree equality, because a bypass also skips the up-to-date rule and a squash
over an advanced base can produce a tree governance never classified), and that
either the approving review still applied to that head or the exact operator
bypass is positively recorded in the ruleset bypass log; where Section 18 step
4 found that log unavailable or unreadable on the plan, the bypass substitution
is unavailable and only the approval branch proceeds. It also verifies that the
candidate subject equals the final PR title and the candidate body equals the
final PR description, each after the Section 7.2 normalization (the ` (#N)`
strip and the terminal-newline normalization). Post-merge quality tests the
candidate object itself. At public launch, the later operator environment
approval explicitly approves that candidate SHA for publication.

The bot listener and publisher are absent during private implementation. At a
separately authorized public launch, exact protected-branch quality may feed a
trusted default-branch listener that validates the run without checking out
untrusted PR content. Because `workflow_run` jobs receive a write-capable token
and secrets even when the triggering run could not, the listener gates on
provenance, never on a branch-name string: the triggering workflow's ID and
path must be the expected quality workflow, its `event` must be `push`, its
head repository must be this repository (a fork-originated run whose head
branch happens to be named `main` is rejected), its `head_sha` must be
reachable from `refs/heads/main` via the API, and the run ID, run attempt, and
artifact run ID it records must all agree, along with the commit subject
(compared after the Section 7.2 normalization that strips the ` (#N)` suffix),
version, and workflow conclusion. It then uses the built-in token's documented
`workflow_dispatch` exception to start the publisher on the protected `main`
ref with the full candidate SHA, version, and target line. The publisher
workflow file is control plane, so it changes only through a dedicated policy
PR, and the listener gates on it rather than merely recording it: it reads the
blob SHA of the publisher workflow at the dispatched ref, asserts that it
equals the value committed in the control-plane manifest and also equals the
publisher-workflow blob SHA that the candidate's successful quality run
recorded in its own outputs (so a policy merge landing between the candidate's
quality run and dispatch cannot change privileged publication behaviour
unnoticed), and refuses to dispatch on either mismatch. Because the dispatch
API accepts only a branch or tag ref, never a commit, `main` can still move
between that check and execution, so the publisher closes the race itself: the
first step of every job in the publisher workflow asserts that `github.sha`
(the commit the dispatch resolved the `main` ref to, which is also the commit
whose workflow file is executing) equals the candidate SHA input, and that the
publisher workflow's blob at that commit equals the recorded reviewed blob, and
exits otherwise; the approved job repeats both assertions as its own first step
after the environment wait (this backs the tip assertion of the Section 15.3
recheck, whose live remote re-read confirms the same commit is still the tip;
it is not a seventh item). That closes the race for any workflow that still
carries the assertions; a replacement merged into `main` in the same window
that omits them is not caught by its own first step, so the operator's
environment approval is the remaining gate for that case (Section 15.2: the
operator approves only a run whose GitHub-rendered run-page commit equals the
candidate SHA named in the environment variables), and the residual is bounded
by the review path, because a replacement can reach `main` only through a
merged control-plane PR under the Section 10.5 code-owner rule; in the solo
model that path is the operator's own authorship and bypass, so the bound is
the operator's review discipline rather than an independent approval; every job
before the environment wait runs with read-only permissions, no secrets, and no
environment, so altered pre-approval workflow code in that window can execute
nothing privileged; the launch specification may remove the race entirely by
dispatching on a dedicated protected control ref that only a policy PR can
move, and this document records the residual rather than assuming that choice.
The expected value is read from the manifest at the same dispatched `main` ref,
so the property this buys is stated precisely: the publisher YAML and the
manifest changed together through a dedicated, reviewed control-plane PR, which
is a guarantee about the review path, not immunity to a compromised `main`. The
run summary records that blob SHA as audit on top. The listener's own
permissions contract is explicit because `workflow_run` jobs can receive
secrets and write tokens their triggering run could not: it runs with `actions:
write` (the one permission dispatch needs) plus read-only `contents` and
metadata, declares no environment, receives no secrets, and has no `contents`,
`pages`, `id-token`, or `attestations` write. The operator therefore did not
initiate the publisher and remains eligible to approve a prevent-self-review
environment, an assumption the launch specification confirms empirically as a
launch-blocking test, because GitHub blocks the user who initiated the
deployment and the attribution of a token-dispatched run between `actor` and
`triggering_actor` is not documented. GitHub does not restrict who may
dispatch: any token with `actions: write` can queue the publisher. That is
non-escalating rather than prevented: a run queued by anyone else still stops
at the operator's environment approval, still fails unless the environment
variables name its candidate SHA and version, and the run summary records the
dispatching actor, so an unexpected dispatcher is visible evidence; that
evidence claim holds only in the solo model, where the collaborator read-back
shows that no other write-capable actor exists at all, and once a write-capable
reviewer exists it is re-derived from the environment approval alone, since the
same `actions: write` permission can delete runs and logs and a user-owned
repository has no organization audit log.

## 15. Future public-launch publisher

Nothing in this section is installed or activated during private implementation
or post-visibility hosted validation. A later explicit version-publication
instruction adds the bot
identity, listener, write-capable publisher, tag rulesets, and protected
environment together. Until then, Section 14.1 is the only release/Pages
execution surface.

That launch is a privilege jump, and this document does not pretend to verify
it privately. Three hard preconditions apply: the `main` ruleset of Section 18
step 20 must be active and read back through the API before
the publisher credentials, the listener, or any environment exist
(otherwise a write-capable collaborator could push directly to `main` while
publication controls are being provisioned). Repository visibility changes
earlier, under Section 18, while the main-only rule and publication-write
prohibitions remain in force; the fresh pre-publication privacy
audit gate recorded in `AGENTS.md` and `HUMAN-DECISIONS.md` (distinct from the
D9 closure; one fresh value-free audit round with zero findings for its stated
scope) must be closed, and a separate
launch specification, reviewed under the same gates as this one, must define an
operator-only privacy incident runbook for the published surfaces (Pages
containment, Release and asset takedown, tag and history remediation under the
immutability rules, and the known limits of caches, forks, and mirrors), since
the repository's immediate-redaction rule covers `main` only and an immutable
tag or Release cannot be fixed forward, together with the launch-phase
acceptance checklist, the order in which each control is enabled, a fail-closed
check after each step, and the rollback for each, including a rehearsed
termination of the publisher after Pages deployment but before Release
publication that proves the prior site is restored by the approved job or, on
runner loss, by the protected manual reconciliation workflow of Section 16,
which is the independently runnable writer for that case. The same
specification defines the distribution boundary that this document only names:
the identity and token that update the Homebrew tap, the exact release-asset
and checksum binding it consumes, whether it writes through a pull request or
directly, and its failure recovery, so distribution is never a write that
untrusted candidate input can reach by default. No launch control is enabled
before that specification is approved, and no distribution writer of any kind
(a tap-updating workflow, token, or App) exists in this repository or its
workflows until it is; Section 18 step 17 verifies that absence and Section 21
requires it.

### 15.1 Read-only preflight

After public-launch authorization and before requesting deployment approval,
the publisher verifies:

- the release freeze recorded in `AGENTS.md` is lifted for this exact version.
  The publisher verifies this from sources the dispatching bot cannot write.
  Before approval it reads an operator-set repository variable that names the
  authorized version, because environment variables are injected only into the
  job that waits on the environment and so cannot be read pre-approval. That
  pre-approval read is advisory and never the authoritative gate: repository
  variables can be written by any write-capable collaborator, and no endpoint
  reports a variable's write boundary; in the solo model the collaborator
  read-back that shows no other write-capable actor proves nobody else could
  have set it, and once a write-capable reviewer exists the repository-variable
  read is recorded as unattributable and the freeze-lift provenance rests on
  the post-approval environment-variable assertion alone; the publisher records
  that inference rather than claiming an API check; the binding assertion is
  the post-approval one, repeated against environment variables on the
  protected environment, which only the operator can set: one naming the
  authorized version and one naming the authorized candidate SHA, so approval
  is bound to a specific commit and not only to a job, because GitHub's
  environment approval approves the run, not a SHA the operator independently
  confirmed. Where the freeze's own trigger applies, the publisher additionally
  verifies that `brew install apple-cli` from the tap succeeds in a clean
  environment and that the served formula's version and checksum link to the
  previously published release, not merely that the formula resolves.
  Public-launch authorization alone, and any input the listener supplies,
  therefore never publishes a version;
- the `github-pages` environment still exists and still carries its protection,
  read through the API on every publication and not only before the first:
  required reviewer set to the operator, prevent-self-review enabled, and the
  deployment-branch policy limited to the protected target branch. The
  `github-pages-recovery` environment is read back on the same cadence for its
  own expected values: required reviewer set to the operator, the same
  deployment-branch policy, and prevent-self-review absent, which Section 16
  requires there and the scan asserts as absence rather than omitting the
  property, so a silently reconfigured recovery environment is detected in
  either direction; administrator bypass is not separately required to be
  disabled on it, because operator self-approval is already permitted there by
  design. On `github-pages`, administrator bypass is checked separately because
  it has no documented API read-back at the time of writing (if one exists it
  joins the checked set): the operator confirms it disabled in the UI and
  records that confirmation in the runbook evidence. Exclusivity is made a
  testable launch prerequisite rather than an assumption: the collaborator
  read-back must show the operator as the repository's only administrator and
  only environment reviewer, and the ruleset read-back must show, per ruleset,
  exactly the Section 7.3 expectations: the operator as sole bypass actor on
  `main`, the exact publisher principal as sole bypass actor on the
  tag-creation ruleset, no bypass actor on the tag update-and-deletion ruleset,
  the operator plus Dependabot on the catch-all branch ruleset, and, when an
  active maintenance line exists, that line's own ruleset with the operator as
  sole bypass actor (the line still falls inside the catch-all's
  `refs/heads/**` target, the boundary Section 4 discloses); write-capable
  reviewers may exist (Section 7.1), because write permission alone cannot
  bypass the ruleset, alter an environment, or set an environment variable, so
  nobody else can bypass or alter the environment; the API-verifiable required
  reviewer and prevent-self-review are the controls that stop automation, while
  the operator is the one actor the environment exists to ask. A deleted
  environment is recreated unprotected by the first workflow that references
  it, so both read-backs fail closed before approval is requested, and the
  `github-pages` read-back is the one repeated in the post-approval recheck
  (the recovery environment is preflight-only there, because the approved job
  never writes through it);
- candidate SHA is still the target branch tip, unless the exact tag already
  exists at this candidate, in which case the run is an idempotent resume
  anchored on the tag (Section 15.3), performed by re-running the original run,
  including the approved job, rather than by a new dispatch, and initiated by
  the listener path rather than by the operator, because `github-pages` enables
  prevent-self-review with the operator as sole reviewer (whether GitHub keys
  that rule on the original `actor` or on the re-running `triggering_actor` is
  not documented, so the launch specification confirms it empirically before
  the first publication, and until it does the reconciliation-and-new-candidate
  path of Section 19 is the assumed resume);
- the candidate's evidence is complete in its two halves, because `governance /
  required` runs only on pull request events and never on the post-squash
  commit: `quality / required` succeeded on the push run for that exact SHA,
  and the pull request whose squash produced it (a merged pull request,
  `merged: true` with the target branch as its base, whose `merge_commit_sha`
  equals the candidate; an open or unmerged PR's field holds a transient
  test-merge commit and never qualifies) carried a successful `governance /
  required` on its final `head.sha` and either the required approval or the
  exact operator bypass positively recorded in the ruleset bypass log (Section
  14.2; the bypass substitutes for the approval only, never for the governance
  half or for tree equality, and is unavailable where that log cannot be read),
  the check resolved as in Section 10.5 (`filter=all`, each check run's
  originating workflow resolved through its check-suite ID, and any run of a
  required name produced by a workflow other than the recorded one refusing the
  publication), with the quality half resolved the same way against the
  recorded quality workflow and the `push` event, so the publication gate links
  PR-gate evidence to post-merge evidence through that merge commit rather than
  expecting a PR-only check on a commit that has no pull request event; a
  candidate that reached `main` by a direct bypass push with no merged pull
  request at all has no such link and is refused publication, fail closed;
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

All outward write steps of the publisher workflow execute in the protected
`github-pages` production environment; the one outward write by any workflow
outside it is the recovery workflow's bounded redeploy of already-published
content under the `github-pages-recovery` environment of Section 16 (the
first-release Pages-disable step of that section is an operator runbook action,
not a workflow write). The `github-pages` environment's deployment-ref policy
allows only the protected target branch: `main`, plus an exact active
maintenance-branch name after that branch is separately created and protected.
It accepts no wildcard release, proposal, or tag ref. The `github-pages`
environment lists only the operator as required reviewer, enables
prevent-self-review, and disables administrator bypass. The job cannot start or
receive its write token until the operator approves it, and the operator
approves only a run whose commit as rendered by GitHub itself on the run page
(the ref and commit GitHub resolved for the dispatch, which is the commit the
workflow file was loaded from; the pending-deployment dialog shows no SHA, so
the runbook step reads the run header, expanding or following the commit link
to the full forty-character object ID, since the abbreviated rendering can be
collided cheaply by an actor who already writes to `main`) equals the candidate
SHA named in the environment variables, and never compares against the
preflight job's own summary, which in the replacement case is written by the
workflow under suspicion; a run showing any other commit is rejected, which is
the operator-side backstop for a publisher workflow replaced between the
listener's blob check and GitHub's resolution of the `main` ref (Section 14.2).

This control is configured and tested only after the repository is public.
Private implementation does not substitute a manual input, fake approval, or
unprotected environment for the unavailable required-reviewer gate. Because
`github-pages` is a GitHub-managed environment that Pages enablement creates
automatically with no protection, and a later Pages source change can reset
its deployment-branch policy, the launch specification applies the required
reviewer, prevent-self-review, and branch policy before Pages is first
enabled and re-reads the environment's protection through the API after any
Pages settings change and before the first deployment.

The approved job is the only job in the publisher workflow with the combined
narrow permissions needed for the exact version tag, draft/published release,
and Pages deployment: `contents: read` on the built-in token (the App
installation token of Section 7.3 is the only contents writer, for the tag, the
Release, and its assets) plus the built-in token's `pages` and `id-token`
writes plus read-only Actions metadata. It receives no workflow, pull-request,
issue, administration, or environment-management permission and has no
branch-write operation. Artifact attestation is deliberately absent from this
design: attesting in the approved job would name a job that executed no build
as the builder, and attesting in the pre-approval build job would publish an
attestation (a publishing operation that itself needs `id-token: write`) for a
candidate the operator may never approve. Neither job therefore carries
`attestations` or `artifact-metadata` write, the release ships a binary and a
checksum, and whether and where provenance is attested is decided by the launch
specification, which must keep every publishing operation behind the operator's
approval; until it does, release notes state that the checksum is
pipeline-internal integrity and do not imply that provenance attestation
exists.

The approved job is also code-free in the sense that it executes no candidate
code; the pinned Actions it does run (Pages packaging and deployment, App token
minting) are privileged third-party code whose sources are reviewed at pin time
and recorded in the allowlist with a provenance note, and each credential is
confined to the minimal inline step that needs it. Every step that checks out
the candidate, builds the binary, runs tests, runs the preflight, or renders
the site executes in a separate unprivileged job with read-only permissions,
which records the SHA-256 digest and the artifact ID of every artifact it
produces as a job output. The same unprivileged job also rebuilds the currently
published complete site (not only its manifest) from the published releases,
exactly as the Section 16 builder does, and packages it as a separate restore
artifact, digested and recorded the same way, so the approved job can redeploy
the whole prior site rather than a pointer to it (on the first-ever release,
when no published site exists, the restore artifact is an explicit empty
sentinel and restoration means leaving Pages undeployed for a failure before
the deploy step; after the deploy step the first-release recovery is the
operator action described in Section 16). The approved job never checks out the
repository, never sources or executes a script from the candidate tree, and
runs only inline workflow steps and full-SHA-pinned Actions. It downloads each
artifact by the recorded artifact ID (never by name), first confirming through
the artifacts API that the record with that ID belongs to this workflow run
(the artifact record exposes its workflow-run association but not the attempt
or the uploading job, so the attempt is not bindable from the record at all and
the binding rests on the same-run association plus the artifact ID and name the
preflight job recorded in its trusted output; an ID that resolves to any other
run, or a name that differs, is refused), recomputes the digests, compares them
to the recorded outputs, and refuses to write anything on a mismatch. The
recorded digests themselves are produced not in the job that ran candidate code
but in a separate verifier job on a fresh runner that never executes candidate
code: it downloads each artifact by ID, hashes the bytes, and is the only job
whose output the workflow references for those digests, because a candidate
command on the same runner could alter later steps through the workflow-command
environment files; the approved job hashes the bytes again itself. Because the
Pages deploy action selects its input by artifact name rather than ID, the
approved job bridges that gap itself: after the digest check and the extraction
checks it re-packages the verified site directory with the pinned Pages
packaging action (which produces the `artifact.tar` the deploy action expects
and uploads it through the artifact service) under a name that includes a
random nonce generated inside the approved job (collision avoidance is what
matters, and a value the preflight job could compute, such as the run ID, would
not provide it), and the deploy step consumes that name, so the name-to-ID
binding never leaves the approved job; artifact upload goes through the
runner's artifact service and needs no additional Actions permission. The
property this buys is precise: candidate-controlled code never executes while a
write token is present, and an artifact cannot be swapped in the artifact store
between the two jobs. It is not a provenance claim about the artifact's
content, which is whatever the reviewed candidate built, so the approved job
treats every artifact as untrusted input: artifact names and internal file
names are fixed by the workflow, the manifest is validated against a fixed
schema, extraction rejects symbolic links, absolute paths, and path traversal,
and no value read from an artifact is ever interpolated into a shell command or
an API call other than as a checked, typed field. The same rule covers the
`workflow_dispatch` inputs the listener supplies (candidate SHA, version,
target line): each is validated by shape before use (forty hex characters, a
strict `MAJOR.MINOR.PATCH`, and a member of a fixed enum respectively), bound
through `env:` rather than written inline as `${{ }}` inside a `run:` block,
and rejected on mismatch, because an expression interpolated into a shell step
is script injection under a write token.

### 15.3 Publication order

```text
operator environment approval
  -> post-approval recheck: candidate is still the target-branch tip
     (unless the exact tag already exists at this candidate), both
     evidence halves of Section 15.1 still hold (re-read the same way),
     tag still absent (or already at the same candidate), artifact
     digests match preflight, the
     operator-set environment variables name this exact version and this
     exact candidate SHA, and the `github-pages` environment still exists
     with its full protection
  -> create immutable annotated tag at the exact candidate
  -> create or resume draft GitHub Release
  -> upload and verify binary and checksum
  -> deploy the complete Pages artifact
  -> canary /, /version/, archive paths, and manifest
  -> publish the immutable GitHub Release
  -> trigger the separately governed distribution update
```

Approval is not a snapshot. `main` can advance while the environment waits for
the operator, so the approved job performs the post-approval recheck shown
above before its first outward write. That recheck is exactly the six inline,
code-free assertions listed in the sequence (tip, checks, tag, digests, the
operator-set freeze-lift variables naming the version and the candidate SHA,
and the `github-pages` environment's protection) made through the API and the
job's environment; it never re-runs the quality driver, the archive, or the
binary, because those execute only in the unprivileged preflight job before
approval and reach the approved job as recorded digests. Tip equality is
required only until the tag exists: every write step before tag creation
re-reads the remote ref and refuses if the candidate is no longer the tip or
either evidence half no longer reports success, and the tag create is atomic
(it fails if the ref already exists at a different object), so a concurrent
publication cannot retarget it. The claim is stated precisely: reading the tip
and creating the tag are two operations, so the re-read is a freshness check
and not an atomic binding of the tag to the branch; what the tag binds is the
candidate SHA that passed preflight, which is the immutable object the operator
approved, and publication is serialized by the shared concurrency group so two
publishers cannot interleave. Once the immutable tag exists, the tag-to-SHA
binding becomes the anchor for every later step and for resume; `main`
advancing after that point does not strand the release, which is what keeps a
post-tag failure recoverable. So that the operator approves a specific
candidate rather than a run, the candidate-bound evidence is produced where it
can actually run: an environment-protected job is not sent to a runner until
approval passes, so no step of the approved job can render anything before the
wait. The unprivileged preflight job therefore writes the full candidate SHA,
the requested version, and the artifact digests to its own job summary, and the
approved job's deployment `url` carries the same SHA and version, so the
approval prompt and the run page both reference immutable evidence that exists
before the operator is asked; for the workflow-replacement case of Section 14.2
that summary is not the source of the operator's commit comparison, which reads
GitHub's own run-header commit as Section 15.2 requires. The publisher's
environment `name` is always the fixed literal `github-pages`, and the recovery
workflow's is always the fixed literal `github-pages-recovery`, with no
expression in either: GitHub binds required-reviewer and prevent-self-review
protection to the environment name and creates an unprotected environment on
the fly for any name that does not exist, so a SHA-bearing name would skip
approval entirely. The launch specification's scanner asserts that every
`environment.name` in every workflow is one of the two fixed literals, and that
exactly one workflow, the publisher at its recorded path, references
`github-pages` while exactly one, the recovery workflow, references
`github-pages-recovery`, because an environment's protection gates whichever
job on an allowed ref references it and a fixed-name check alone does not
establish that singleton ownership; the operator approves only a pending
deployment whose workflow path is the publisher's (the private readiness scan
of Section 18 step 17 permits none at all).

Keeping the release draft until Pages passes prevents a published release from
pointing at stale documentation. There is no transaction spanning Git refs,
Releases, and Pages; idempotent resume rules handle partial state. An ambiguous
result from the publish call (a timeout or a lost response) is not treated as
failure: the job re-reads the authoritative Release state first, with a bounded
retry with backoff, treats the Release as published only when the read returns
it with `draft: false`, keeps the candidate site in that case, and lets only a
confirmed failure trigger restoration, so `/` cannot fall behind a Release that
actually landed; a re-read that is still inconclusive after the bounded retries
is the fifth documented failed-rollback state, in which the job writes nothing
further and reconciliation resolves it. If the Pages canary or Release
publication fails after the candidate site is deployed, the same approved job
automatically redeploys the complete prior site (or the empty sentinel) from
the restore artifact before it exits. That restoration runs as an `if:
always()` step so an ordinary cancellation still triggers it, which is
best-effort rather than a durable execution guarantee, because a cancellation
can also terminate the job before the restore completes, so rollback counts as
successful only when the restore step finished and the post-restore canary
verified the prior site; anything short of that is one of the failed-rollback
states below and goes to reconciliation. A runner loss runs no step at all, so
that case leaves `/` stale until the manual reconciliation workflow of Section
16 is run; the scheduled reconciler detects and alerts on that state but never
writes. A failed transaction may leave only the exact tag and draft Release; it
must not leave `/` pointing at an unpublished candidate, except in the
documented failed-rollback states (runner loss, a cancellation that arrives
before the restore step runs, a Pages API failure during restoration, the
restore step itself failing, or an inconclusive post-publish re-read after
bounded retries), each of which Section 16 covers with the same recovery
authority: the manual reconciliation path is required and rehearsed for every
one of them, not only for runner loss.

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

Outside the bounded publication transaction, `/` must always match the highest
published stable Release. The approved candidate may occupy that route only
between its successful Pages deployment and immediate Release publication. Any
failure in that interval triggers redeployment of the complete prior site (or
the empty sentinel) before the workflow reports failure. This design does not
claim that rollback is automatic in every case: the documented exceptions are
the failed-rollback states inside that interval (runner loss, cancellation
before the restore step, a Pages API failure during restoration, a failing
restore step, or an inconclusive post-publish re-read after bounded retries),
after any of which `/` serves the unpublished candidate until the operator runs
the protected manual reconciliation workflow, which is the named recovery
authority; it is not a second, less-gated path to publishing new content,
because every byte it writes comes from an already-published stable Release: it
can restore `/` and the archive routes, and it can select an older published
stable tag as `/`, but it can neither publish a new version nor deploy content
that was never released, and it does not depend on the bot path, because a
broken listener must not leave `/` serving an unpublished candidate
indefinitely: the reconciliation workflow is dispatched by the operator
directly and waits on a separate `github-pages-recovery` environment whose
required reviewer is the operator without prevent-self-review (the operator may
approve a run they started here because the worst outcome a single actor can
reach through this path is `/` serving an older published stable Release, which
the scheduled read-only reconciler alerts on, whereas nothing unreleased can be
deployed through it), so recovery is independently runnable while every
publication of new content still needs the prevent-self-review `github-pages`
gate; the guaranteed recovery state is "the highest published stable Release is
restored at `/`", never "the candidate is retroactively unpublished". On a
first release, where the sentinel stands in for a prior site, recovery from
that state is the operator disabling Pages through the Pages API with the
operator's own credentials, because a completed Pages deployment cannot be
undone by deploying an empty artifact and the approved job holds no
administration permission; that action is an operator runbook step, not a
workflow, and the launch specification rehearses it before the first release.

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

During private implementation, this builder writes only to a fresh local or
runner-temporary directory. Tests serve that directory on loopback when needed
and assert `/`, `/version/`, archive paths, and the manifest without creating a
Pages deployment or referencing the `github-pages` environment. The exact input
commit and every output digest appear in value-free rehearsal evidence.

After public launch, a protected manual reconciliation workflow can rebuild the
complete site from published releases or select a previously published stable
tag as `/` for recovery, and a scheduled read-only reconciler asserts that `/`
equals the highest published stable Release and raises an alert (never a write)
when it does not. Release and reconciliation use one shared concurrency group
with `cancel-in-progress: false`, so recovery never runs concurrently with a
publication; a publisher run stuck without a terminal state is cancelled by the
operator first (cancellation is itself a documented failed-rollback trigger,
which recovery then resolves), so recovery never waits indefinitely while `/`
serves an unpublished candidate.

## 17. Dependabot and supply-chain updates

`.github/dependabot.yml` enables weekly, staggered update PRs for:

- `github-actions` at repository root;
- the tracked Python documentation dependency manifest;
- SwiftPM after an empirical Swift tools-version 6 update check succeeds during
  the post-visibility hosted rehearsals.

Minor and patch updates are grouped per ecosystem. Major updates remain
individual. Open PR counts are bounded, titles remain Conventional Commit-
compatible, and unattended auto-merge is disabled. Every dependency PR requires
ordinary secret-free CI and one qualified independent approval unless the
operator deliberately uses the exact-user bypass.

Before activation:

- every third-party Action is pinned to a verified full commit SHA;
- `.github/actions-allowlist.json` records every permitted external Action
  identity and replaces the list embedded in `scripts/ci/action_pins.py`, and
  trusted-base policy rejects any `uses:` owner/repository not in that
  committed allowlist, at step level and at job level (reusable workflows)
  alike, and rejects `docker://` references outright because
  `sha_pinning_required` does not pin an image tag;
- repository Actions permissions set `sha_pinning_required` to `true`, and a
  read-back assertion proves the server accepted it;
- dependency graph, vulnerability alerts, and security updates are enabled.

Private bootstrap does not set `allowed_actions` to `selected` or claim a
server-side `patterns_allowed` allowlist. Whether that server-side pattern list
is enforceable on this private repository and plan is not asserted here;
Section 18 step 4 reads the repository's current Actions settings, owner type,
and plan from the API and records them. The committed allowlist plus the
repository `sha_pinning_required` control is the private enforceable pair, with
one stated limit: GitHub documents that `sha_pinning_required` does not require
reusable workflows (`jobs.*.uses`) to use commit SHAs, so the committed
validator enforces full-SHA pins for reusable-workflow references itself. The
same committed allowlist remains the source of truth after launch.

A `github-actions` Dependabot PR uses only the narrow workflow-pin exception in
Section 10.5. It cannot change triggers, permissions, commands, inputs, or any
non-workflow file and receives no bypass authority on `main` or on tags (its
sole bypass is the Section 7.3 catch-all branch entry).

If native Swift 6 updates fail empirically, Dependabot remains active for
Actions and documentation while a scheduled read-only Swift dependency
freshness check reports available updates. It does not auto-merge or publish.

## 18. Bootstrap, visibility transition, and hosted validation

**Amendment 2026-09-20 (HUMAN-DECISIONS D17).** The operator advanced the conditional
visibility step ahead of the phase-1 items not yet evidenced in
`docs/discovery/prelaunch-readiness-evidence.md`, because hosted Actions stopped allocating
runners for the private repository. The pre-flip privacy audit round ran and its zero-findings
condition was NOT met; the operator dispositioned findings 1–5 (D17–D20) and gated the flip on
exactly: the written GitHub Support purge confirmation of D19 (request prepared; operator filing PENDING; confirmation PENDING); the R1-F6 fixture fix; the R1-F7 log deletion authorized and executed (D21, OPEN); the repository-level external-Action allowlist configured; the pre-push re-scan of every commit added after `053b56e`; and the local canonical suite green on the exact pushed commit (R1-F6 and R1-F7 are the two undispositioned findings, both in that list). Every other
phase-1 item of this section not in that list is advanced past for visibility only — it remains
required before any later publication step and stays PENDING in the evidence file. Every other
requirement of this section apart from the visibility ordering amended here, of §3 (as amended
the same day), and of the freeze (as amended in D2 for one release) stands as written; the end-of-roadmap audit must return zero findings for its
scope. Section 4.1's macOS 26 baseline is unchanged until the D18 adoption matrix passes.

Implementation begins while the repository is private. Its very first commit,
before step 1 and before any other hosted run, neutralizes the two tracked
write paths (removing `release.yml`'s `workflow_dispatch` trigger and
`contents: write` and `docs.yml`'s `pages` deployment job) and reads back that
no dispatchable or Pages-writing workflow remains; step 5 then completes the
conversion to the read-only rehearsal shape. Conduct rules and repository
variables are not technical gates, so the write paths are removed before
anything else runs.

The 2026-09-10 ordering amendment preserves the numbered steps below so their
cross-references remain stable, but separates their execution into two phases:

1. Before visibility, finish steps 1–5 and 7, implement and locally exercise the
   read-only release/Pages tooling of steps 15–16, complete the step 17 scan and
   applicable settings readbacks, and capture the local portion of step 19.
   Finish the capability, inventory, coverage, governance, dependency, and
   contributor-documentation implementation, independent reviews, exact-SHA
   full local gates, and fresh pre-publication privacy audit. The audit must
   include the history, commit-message, ref, object, and retained-artifact
   surfaces required by the repository rules, with zero findings for its stated
   scope. Record hosted and actor-dependent results as pending, not passed.
2. Only when those pre-visibility gates pass, perform the conditional visibility
   change authorized on 2026-09-06 and reaffirmed on 2026-09-10. Do not wait for
   October 1 and do not run hosted acceptance while private. No immediate flip,
   publication writer, release, tag, Pages deployment, or Homebrew action is
   authorized by starting implementation.
3. After public visibility, re-read Actions/fork/settings capabilities for the
   public state, then execute step 6, steps 8–14, the hosted evidence portions
   of steps 15–16, and steps 17–19 in their dependency order. Local rehearsals
   do not replace hosted evidence. Step 8 still requires the D16 in-session
   first-ref reconfirmation and preceding policy commit; qualified-actor
   constraints remain unchanged. Step 20 requires its separate main-only
   reversal instruction. Final `main` or maintenance ruleset activation requires
   every mandatory job to have allocated a runner and passed. The active
   disposable ruleset in step 8 is the rehearsal prerequisite for the first
   governance run on the step 9 PR; it does not require that run in advance.
   Stop before Homebrew distribution;
   version-publication controls remain separately authorized future work.

Numbered implementation and verification requirements:

1. Implement the design in reviewed, test-green logical commits under the
   existing private main-only rule.
2. Measure and record the actual production-coverage baseline per target from
   the SwiftPM lane (the local Bats tier contributes no profile data and is
   not merged), then add tests until aggregate coverage is genuinely at least
   90%. The recorded baseline is part of the readiness evidence; a target that
   cannot yet reach the floor blocks readiness until tests are added, never
   an exclusion.
3. Run the full local canonical suite and independent code, security, and critic
   review on every sensitive commit.
4. Commit and validate the exact external-Action allowlist
   (`.github/actions-allowlist.json`, which replaces the list embedded in
   `scripts/ci/action_pins.py`; the script reads the file rather than carrying
   a second list), pin every Action to a full commit SHA, set repository
   `sha_pinning_required` to `true`, `default_workflow_permissions` to `read`,
   and `can_approve_pull_request_reviews` to `false` (the one server-side
   switch that would let a workflow token satisfy the required-approval rule;
   it also governs Actions creating pull requests), and read all three settings
   back, all before the first hosted run in step 6, and do not configure or
   claim private server-side selected-action patterns; instead read the
   repository's current Actions settings from the API (`allowed_actions`, and
   `sha_pinning_required` after it is set) and the owner type from the
   repository API, and read the plan from the user API with a token that
   carries the scope that exposes it (an absent `plan` field is recorded as a
   failure to read, never as "free"); selected-action patterns, merge-queue
   availability, code-owner enforcement on a private repository, and the
   availability and retention of ruleset bypass logging are then derived from
   those documented owner and plan facts, not from a capability field, which
   does not exist; record all of it (names and booleans only) in the readiness
   evidence, so every plan-dependent claim in this document rests on an
   observed value.
5. Inventory every workflow under `.github/workflows/` and convert or remove
   every existing write path: replace the tracked `release.yml` (dispatchable,
   `contents: write`, branch and tag push, Release creation) with the read-only
   exact-SHA rehearsal of Section 14.1; delete the `docs.yml` `pages`
   deployment job rather than leaving it behind a repository variable; fold the
   tracked `pr-metadata.yml` (`metadata / required`, today's second
   `pull_request_target` workflow) into `governance / required` and update the
   stated exception in `AGENTS.md` in the same commit, so exactly one
   `pull_request_target` workflow remains; author `.github/CODEOWNERS` naming
   the operator's exact user for every control-plane path of Section 10.5, only
   once the operator has recorded in `HUMAN-DECISIONS.md` the decision to
   extend the attribution exception to that file (an agent cannot make the
   design compliant by a policy PR alone; until that decision is recorded
   CODEOWNERS is not authored and private readiness stays blocked), and, in a
   distinct reviewed commit that lands before the CODEOWNERS commit, the
   extension of the attribution exception in `AGENTS.md` that records the
   operator's handle in that one file as deliberate public attribution
   alongside LICENSE, README, and git author metadata (the file cannot work
   without it, and the personal-data rule is bright-line, so the exception
   lands before the identifier does and the CODEOWNERS commit gets its own
   fresh privacy scan), and confirm through the code-owners errors API that
   GitHub parses it without error; and rename the required checks to their
   stable names `governance / required` and `quality / required`. Record the
   trade-off this creates: from this step until public launch no release can be
   cut, so the urgent-fix clause of the release freeze is satisfiable only by a
   reviewed, operator-authorized, temporary restoration of a write-capable
   release workflow, recorded as an explicit exception and removed again
   afterwards. That exception is written down before it is ever needed: the
   same change adds the policy exception to `AGENTS.md` and a tracked runbook
   under `docs/runbooks/` that names the authorization required, the exact
   reviewed workflow to restore, the verification it must pass, and the removal
   step; the restored workflow builds and verifies only, and the tag push and
   Release creation in that path are performed by the operator with the
   operator's own bypass-capable credentials, which is possible only in the
   private window before the Section 7.3 tag rulesets exist (after launch the
   operator holds no tag-creation bypass, the publisher is the only tag writer,
   and an urgent release goes through the publisher itself, so the runbook is
   retired at launch and the launch specification records that retirement),
   because Section 3 permits no write-capable publisher workflow in the private
   phase whatever rulesets exist, and no identity is added to any bypass list
   for the exception (after step 20 the `main` and tag rulesets reinforce the
   same rule, since the built-in identity is not a bypass actor under them), so
   an urgent release under the freeze is a documented procedure rather than an
   improvisation against the hard stop. The window in which `main` cannot be
   released is stated as a decision, not discovered later: the release freeze
   already forbids cutting a release until the Homebrew tap serves the formula,
   so removing the release writer changes nothing in practice while the freeze
   holds, and the operator's approval recorded in this document's status line
   is the explicit ruling that accepts the window and names the runbook as the
   sole urgent-fix path. A restoration under that runbook is a separately
   authorized operation outside this readiness program: while a restored
   write-capable workflow exists, neither readiness level is claimable, and it
   is removed and the step 17 scan re-run before readiness is asserted. In the
   same inventory, convert `ci.yml` so that every blocking policy check
   executes from the trusted base checkout and any policy run from the proposal
   checkout is advisory only; today the supply-chain policy job runs
   `scripts/ci` and `Tests/automation` from the PR checkout on the required
   path, which lets a proposal alter the policy it is measured against. Confirm
   the hosted runner lane: every current macOS job runs on `macos-15` (the
   remaining jobs run on Ubuntu); adopt a stable `macos-26` hosted image if one
   exists, otherwise record `macos-15` as the validated hosted lane until it
   does, in which case the macOS 26 support-baseline claim rests on the
   operator's local macOS 26 canonical run recorded in the readiness evidence
   (Sections 11.2 and 12). Update every tracked document that describes the
   replaced release workflow or the Pages job (`AGENTS.md`, `CHANGELOG.md`,
   `docs/DESIGN.md`, and the versioning policy) in the same change, so
   canonical documentation never describes a publisher that no longer exists
   (at step 5 this lands under the private main-only gate as three ordered
   commits, the attribution-exception record first (the `HUMAN-DECISIONS.md`
   decision and the `AGENTS.md` extension together), the remaining
   control-plane files including CODEOWNERS and the `AGENTS.md` governance
   edits second, and the product documentation third, so the split Section 10.5
   later enforces is already the shape of the change; once Section 10.5 is
   enforced, a governance-document edit and a product-documentation edit are
   paired PRs, never one). Re-run the static scan of step 17 against the whole
   directory afterwards.
6. After public visibility, obtain at least one successful hosted Actions run of
   every push-triggered mandatory job. The PR-triggered mandatory job (`governance /
   required`, which runs only on a pull request event) obtains its first
   successful hosted run on the step 9 validation PR, and the readiness
   evidence records that run's commitment (step 19). A job that never receives
   a runner is not evidence.
7. Configure squash-only merging with PR title and PR body as the squash commit
   title and body; disable merge commits and rebase merges.
8. Create a uniquely named disposable branch at a recorded commit that already
   contains the step 5 `.github/CODEOWNERS` (GitHub resolves code owners from
   the pull request's base branch, so a file that lands later leaves the rule
   matching nothing for every validation PR while a `main` read-back still
   reports it present) and install an **active** ruleset targeting only that
   exact branch name. Use the intended required checks, one-review rule,
   code-owner review rule, and sole exact-user operator bypass. Do not use or
   claim `evaluate` mode. Every validation PR in steps 9 through 13 targets
   this disposable branch, never `main`. Because the standing main-only ruling
   forbids creating branches, the disposable branch and its validation PRs are
   created only after an in-session operator instruction that explicitly and
   narrowly reverses the main-only ruling for the disposable rehearsal refs,
   recorded in `AGENTS.md` by a reviewed direct commit on `main` under the
   still-binding main-only gate before the first branch is created (a policy pull
   request cannot carry it, because a pull request needs the head branch the
   ruling forbids; this is the ordering step 20 uses as well), and recorded in
   the readiness evidence; that reversal names the disposable target ref, the
   proposal head refs the validation PRs need, and the Dependabot-created head
   refs of step 13, and it does not reverse the ruling for ordinary work (step
   20 does that separately).
9. Against the active disposable ruleset, open an operator-authored validation
   PR and verify that one qualified independent approval satisfies the normal
   rule. The readiness evidence records only the pass/fail result, a role
   label such as `reviewer-A`, and a run-local salted digest of the review,
   never a login, a name, or a review API ID (an API ID resolves to the
   reviewer's login for any reader once the repository is public, and a
   collaborator's account identifier is personal data under the repository
   rule; the operator's own attribution is the only standing exception). The
   API ID and the real reviewer identity stay in the operator's out-of-tree
   notes.
10. Push another proposal commit and verify the old approval becomes stale;
    then edit the title and verify `governance / required` returns to failing
    until an approving review newer than the edit exists and passes again after
    the merger re-runs the failed governance run once one does, per Section 8
    (recorded as unverified by absence when no qualified reviewer exists).
11. Verify that an intentionally failing required job blocks a non-bypass
    merge, that strict up-to-date status is enforced, and that the exact check
    names `governance / required` and `quality / required` are the ones the
    ruleset requires. In the same step open a deliberate mixed
    policy-and-product PR and a deliberate control-plane edit in an ordinary PR
    and verify that `governance / required` rejects both, and open a validation
    PR that adds a second workflow producing a check named `governance /
    required` from the same Actions App and verify that the trusted governance
    run rejects it by workflow ID and path under the Section 10.5 provenance
    resolution (the forged-status test below covers a different App; this
    covers the same-App collision the design treats as the primary ambiguity).
    Also post a forged status with a required check's exact name from an
    ephemeral fine-grained personal access token created for this step with
    only commit-status write permission on this repository (plus the mandatory
    read-only metadata scope every fine-grained token carries), held outside
    the tree, revoked immediately after the observation with its absence
    re-confirmed before readiness is asserted as an operator account-level
    attestation recorded in the runbook evidence, since no repository-scoped
    endpoint enumerates a user's tokens (it is a test credential, not one of
    the publication credentials Section 21.1 forbids), and represented in the
    evidence only by the pass/fail result, onto the intentionally-failing PR
    created earlier in this step (never onto a PR whose genuine check already
    succeeded, where the observation would be meaningless) and verify that the
    required check's state on that PR remains unsatisfied (an observation the
    operator can make alone, so it never falls into the unverified-by-absence
    carve-out), and read back the `integration_id` each required check is bound
    to. Read back that the disposable ruleset carries the code-owner review
    rule and that `.github/CODEOWNERS` names only the operator for every
    control-plane path. Then open one conforming dedicated policy PR (a
    control-plane-only change with no product edit, so that `governance /
    required` passes and the code-owner rule is the only requirement left
    unsatisfied; the two deliberately malformed PRs above cannot serve, because
    their failing required check masks the observation exactly as a failed
    check masks the forged-status test) and verify on it that a non-operator
    approval alone does not satisfy the ruleset, reading the
    code-owner-specific mergeability reason, and that the operator's bypass
    does, the refusal read from the pull request's API state and the bypass
    acceptance recorded as an operator-attested observation of the merge
    affordance GitHub shows the bypass actor, without merging (no documented
    API field distinguishes a caller's bypass eligibility), so step 12's single
    squash merge remains the only one before the operator-gated step 20; this
    is also the one rehearsal of the accept path for a policy PR. Where no
    non-bypass write actor exists, the blocked-merge assertion and the
    code-owner refusal are recorded as unverified by absence exactly as in step
    14.
12. Squash-merge one validation PR into the disposable branch with the native
    squash mechanism (through either an independent approval or the recorded
    exact operator bypass, as in step 20), record the resulting commit header
    and body, and verify empirically that the header equals the final PR title
    after stripping the ` (#N)` suffix GitHub appends and that the body equals
    the final PR description after normalizing the terminal newline; record the
    exact normalization observed. This is the only squash merge on a disposable
    ref and the only one before the operator-gated step 20; the same property
    on `main` is confirmed only there.
13. Enable and validate governed Dependabot updates while the rehearsal
    ruleset is still active: set Dependabot's `target-branch` to that same
    disposable branch (the step 8 authorization names Dependabot-created head
    refs explicitly, and this control-plane edit goes through the still-binding
    main-only review gate), verify that its PR receives the
    ordinary secret-free checks and requires the ordinary approval, and
    verify that the narrow workflow-pin exception of Section 10.5 accepts a
    conforming pin update and rejects any broader diff.
14. Against the same active disposable ruleset, prove that a non-bypass actor
    cannot direct-push or force-push and that the operator can use the
    exact-user bypass and a lease-protected force push. If no non-bypass write
    actor exists on the repository, this step and the matching criterion in
    Section 21 are recorded as unverified by absence, on the same footing as
    Goal 2, never as passed. Restore the branch to its recorded commit, then
    remove the rehearsal ruleset; the disposable refs themselves are removed
    in step 18.
15. After public visibility, run the hosted release rehearsal against an explicit
    full commit ID with read-only permissions. The evidence binds three
    identities together: the exact commit
    ID given to the rehearsal and the step 19 commitments of the hosted
    `quality / required` run that succeeded for that same commit and of the
    rehearsal run; a rehearsal of a commit without its own successful hosted
    quality run is not hosted acceptance evidence. The earlier local rehearsal
    remains required pre-visibility evidence of the tooling, not a substitute.
    Verify the predicted release-file changes,
    archive contents, checksums, linkage, runtime version, and refusal of any
    outward-write step.
16. Run complete-site assembly against the same exact commit, verify `/`,
    `/version/`, archive routes, manifest, the temporary-artifact restore
    path, and deterministic digests from the temporary artifact, and keep
    Pages disabled. The post-launch reconciliation workflow of Section 16 is
    not exercised by this read-only program and is not claimed. Local assembly
    and restore checks run before visibility; the hosted run follows visibility.
17. Statically verify every workflow under `.github/workflows/`, rehearsal or
    otherwise: none contains an environment, deployment, tag, Release, Pages,
    branch-write, or write-capable permission path, and every workflow and
    every job declares an explicit `permissions` block (an omitted block
    inherits the repository default, which parsed YAML cannot prove is
    read-only, so omission fails the scan and the step 4
    `default_workflow_permissions: read` read-back is the backstop); none uses
    a `workflow_run` trigger or a self-hosted runner label; no configured
    secret is referenced outside the approved job (every job still receives its
    ephemeral least-privilege built-in token), verified on the parsed YAML
    rather than by text search (no `secrets.` context reference in any
    expression, whether under `env`, `with`, `run`, or `if`, no `secrets:`
    mapping, and no `secrets: inherit` on a reusable workflow call); every
    checkout sets `persist-credentials: false` explicitly (the Action's default
    is `true`, so absence of `true` proves nothing); no workflow declares an
    `environment` at all, because Section 3 permits none before launch and
    GitHub creates an unprotected environment automatically for any referenced
    name (the launch specification's scanner is the one that later permits
    exactly the two fixed literals `github-pages` and `github-pages-recovery`
    and reads back their protection); no two workflows produce a check with the
    same name; each required workflow's trigger set equals the recorded one
    (Section 7.2); exactly one `pull_request_target` workflow exists
    (`governance / required`, after step 5 folded the metadata check into it
    and `AGENTS.md` was updated to match) and it does not reference the
    proposal head (`head.sha`, `head.ref`, a head-ref checkout, artifact
    download, or PR checkout) in any step, and every checkout step in it sets
    an explicit `ref` resolving to the protected base (the default branch or
    `base.sha`), because an unpinned checkout is trusted under
    `pull_request_target` and proposal-controlled under any event GitHub runs
    from the merge commit; and no publisher, listener, or distribution-writing
    workflow is installed. Then read back through the API, and record as
    value-free expected sets (counts, scopes, booleans, and non-reversible
    digests only; never a secret, environment, key, or App name, which the
    repository rule treats as private infrastructure detail), the repository
    and environment secrets, the repository and environment Actions variables,
    the Dependabot secrets, the environments, the deploy keys, the installed
    GitHub Apps with their permission scopes (listed through the operator's own
    account-installations endpoint together with each installation's repository
    list, which is the complete inventory for a user-owned repository; the
    per-repository installation endpoint answers only for the calling App and
    is not used), the fork pull-request workflow settings (no write token, no
    secrets or variables, approval required for outside-collaborator runs), the
    workflow-permissions settings (`default_workflow_permissions` read,
    `can_approve_pull_request_reviews` false), and, before visibility, the
    private-forking setting (disabled), replacing that private-state observation
    with the public fork-policy readbacks of Section 9 after visibility;
    the Pages configuration (the Pages endpoint must report no site
    and no deployment, since a site configured outside any workflow is
    invisible to the static scan), the `.github/CODEOWNERS` file (present,
    naming only the operator, covering every control-plane path of Section 10.5
    with the operator as effective owner under last-match-wins resolution, and
    reported error-free by the code-owners errors API, since a pattern GitHub
    cannot resolve yields no owner and a code-owner rule with no matching owner
    is trivially satisfied), the collaborator and outside-collaborator lists
    (counts and roles only), and the GitHub-side OIDC and attestation settings
    (workflow `id-token` permissions and repository settings; an external cloud
    provider's trust policy cannot be enumerated from GitHub and is audited
    separately at the provider), so the credential non-goals of Section 3 are
    detectable rather than merely declared.
18. Restore `.github/dependabot.yml` by removing the disposable
    `target-branch` set in step 13, through the still-binding main-only review gate
    that is the reviewed path at this point (the rehearsal ruleset is gone
    and the `main` ruleset is not yet active), verify the committed file
    through the contents API, and record that no endpoint exposes
    Dependabot's effective target. The step completes on the contents-API
    verification plus that recorded limitation; the base ref of the next
    Dependabot PR is logged in the evidence as a deferred confirming
    observation when it arrives. Only then close and remove validation PRs
    and disposable refs after evidence is captured.
19. Capture phased readiness evidence as one tracked, value-free file at
    `docs/discovery/prelaunch-readiness-evidence.md` containing only commands
    written as placeholder-only templates (repository owner, local paths, URLs,
    environment names, and infrastructure identifiers replaced by fixed
    placeholders, and scanned for those classes before commit), digests,
    counts, run-ID commitments (a salted non-reversible digest of each run ID
    and attempt, with the raw IDs and the salt both retained out of tree,
    because a raw run ID resolves to run and actor metadata and a short
    sequential integer under a known salt would be reversed by enumeration),
    role labels, salted digests, operator attestations named as such (including
    the step 11 test-token revocation), and pass/fail results (never a
    collaborator's login, name, or a review API ID that resolves to a person),
    including the restored `dependabot.yml` state from step 18. Before visibility,
    record local verification, the fresh privacy audit, and explicitly pending
    hosted/actor-dependent criteria. After visibility, append the actual hosted
    and rehearsal evidence; never relabel a pending result as passed. Stop before
    environment, publisher, tag-ruleset, Pages, release, Homebrew, credential,
    or freeze changes.
20. Operator-gated, outside the implementation's control: only on an in-session
    operator instruction that explicitly reverses the standing main-only ruling
    in `AGENTS.md`, activate the reviewed `main` ruleset, confirm that
    non-operator direct and force pushes fail (recorded as unverified by
    absence when no non-operator write actor exists, exactly as in step 14),
    then native-squash exactly one validation PR: the policy PR that updates
    `AGENTS.md` to record the reversal and reconcile it with the now-active
    ruleset. That PR is the genuinely useful change (so no throwaway commit
    lands on `main`), and its resulting commit title, body, tree, and check
    provenance are verified to be exact after the step 12 recorded
    normalization, and its review provenance is verified as either an
    independent approval or the recorded exact operator bypass (Section 14.2).
    Until that instruction, the main-only ruling stands and every earlier step
    exercises only disposable refs.

Read-only release preparation may transform a temporary exact-SHA tree and
compute the predicted next version from branch-reachable Conventional Commit
subjects, displaying it inside rehearsal artifacts and evidence clearly
labelled as unassigned. That is what lets the rehearsal exercise the existing
drift gate (constant, changelog heading, and tag must agree). The release
freeze forbids committing that version, tagging it, or describing shipped work
by it, not computing it. The rehearsal does not change `AppleVersion.current`
on `main`, promote `[Unreleased]`, push a ref, create a tag, create or edit a
Release, or deploy Pages.

The later version-publication transaction is a new, explicitly authorized phase.
It adds the bot identity and listener, write-capable publisher, operator-reviewed
environment, `v*` tag ruleset, release immutability, and Pages deployment before
the first publication. None of those controls is treated as privately verified.

If the current account plan cannot enforce a required private-repository
feature, implementation prepares and validates everything possible but does not
weaken the design. Activation waits until the repository is public or the plan
supports the control. Required checks on `main` or a maintenance line must not
be activated until every mandatory hosted job has allocated a runner and passed,
or they could lock the repository behind checks that cannot start. The disposable
active rehearsal ruleset follows Section 18 steps 6 and 8–9, including the first
governance run after its installation.

## 19. Failure and recovery

| Failure | Preserved state | Recovery |
|---|---|---|
| Proposal branch or PR creation failure | No protected-ref change | Correct the proposal operation; retry without touching `main` |
| PR CI failure | PR remains open | Fix through proposal branch; stale approval requires re-review |
| Native squash metadata mismatch | `main` is red; release remains blocked | Correct through a reviewed PR or an explicit operator history-repair decision |
| Exact-branch CI failure | No outward write | Fix through another approved PR |
| Active disposable-ruleset rehearsal blocks the branch | `main` and publication state are unchanged | Use only the exact-user operator bypass to restore the recorded disposable ref, remove its ruleset, and correct the design without weakening `main` |
| Read-only exact-SHA release or Pages rehearsal fails | No outward write exists | Fix through reviewed code, rerun the new exact candidate read-only, and do not add a publisher, environment, deployment, or write permission |
| Private Action pin or allowlist validation fails | No untrusted Action is accepted | Correct the committed workflow or allowlist; keep `sha_pinning_required` enabled |
| Future public publisher preflight fails | No outward write | Correct through PR; retry the exact candidate |
| Future operator rejects deployment | No outward write | Run stops rejected |
| Future tag or draft enters partial state | Only the exact candidate may resume | Resume idempotently; never retarget the tag |
| Future asset verification fails | Release remains draft | Correct draft assets before publication |
| Future Pages deployment or canary fails | Release remains draft; exact tag may exist | Automatically restore the complete prior site (or the empty sentinel); resume only after re-verification |
| Future Release publication fails | Exact tag and draft may exist | Automatically restore the complete prior site (or the empty sentinel); resume publication only after re-verification |
| Future post-publish re-read inconclusive after bounded retries | Release may or may not be published; `/` serves the candidate | Write nothing further; operator runs the Section 16 reconciliation, which reads the authoritative Release state and restores or confirms |
| Future distribution update fails | GitHub Release and Pages remain valid; prior package stays served | Retry the downstream update |
| Future published binary is defective | Published release remains immutable | Fix forward with a new patch release |
| Dependabot ecosystem rejection | Other ecosystems remain active | Disable only failing entry; use freshness monitor |
| Required check can never allocate a runner after ruleset activation | `main` is locked behind a check that cannot start | Exact-user operator bypass lands a dedicated policy PR that fixes or relabels the runner; the ruleset is not weakened and the bypass use is logged |
| Hosted Actions unavailable while the repository is private | Reviewed main-only implementation continues under exact-SHA full local gates; required rulesets remain inactive | Defer mandatory hosted runs and dependent rehearsals until after the conditional visibility transition, not a quota-reset date; preserve every pending criterion, use steps 6 and 8–9 for disposable-rule rehearsals, and require every mandatory hosted job to allocate and pass before final `main` or maintenance ruleset activation |
| A merged policy PR breaks `governance / required` so the fix PR is itself blocked | `main` is red; releases and merges stop | Exact-user operator bypass lands the corrective policy PR; post-merge exact quality must pass before any later merge |
| Personal data discovered in already-merged `main` history | Published-history rules (linear history, no force push) collide with the remediation | Redact at HEAD immediately; a history rewrite is an operator decision that uses the exact-user bypass with `--force-with-lease`, recorded in `HUMAN-DECISIONS.md`, and never reaches forks or existing clones |
| No qualified independent reviewer is available for a change | The normal path cannot complete | The exact-user bypass is the recorded normal path for that change, each use is logged, and Goal 2 is reported as unmet until a reviewer exists |

The future public publisher's resume path refuses:

- a tag pointing to a different commit;
- a candidate no longer at target branch tip while the tag does not yet exist
  (once the immutable tag exists, the tag-to-SHA binding is the anchor and
  `main` advancing no longer blocks resume, so a post-tag failure stays
  recoverable; that resume is a re-run of the original run that includes the
  approved job, initiated by the listener path and never by the operator,
  because the operator cannot approve a run they started under the
  prevent-self-review `github-pages` environment (whether GitHub keys that rule
  on the original `actor` or on the re-running `triggering_actor` is not
  documented; the launch specification confirms it empirically, and until then
  the reconciliation-and-new-candidate path below is the assumed resume), so
  environment approval is requested afresh and the operator re-approves the
  candidate SHA rather than inheriting the earlier attempt's approval, executes
  the same workflow commit with the same `github.sha`, and is never a fresh
  dispatch on `main`, which after `main` advanced would fail the Section 14.2
  first-step assertion by design; GitHub permits a re-run only within a bounded
  window after the original run, so a post-tag failure left unresolved past
  that window has no completion path other than reconciliation of `/` and a new
  candidate under a new version, with the burned version recorded);
- a missing or stale required check;
- an already-published asset with a different checksum;
- mutation or overwrite of published immutable assets.

## 20. Known prerequisites, not design exceptions

1. Every mandatory hosted job must allocate a runner and pass before final
   `main` or maintenance ruleset activation or a claim of hosted verification.
   The disposable active ruleset is installed after the step 6 push-triggered
   runs and before the first governance run on the step 9 validation PR.
2. At least one trusted collaborator must have enough repository permission for
   GitHub to count their review before the independent-review path can be
   proven. The repository is user-owned and the operator works alone by
   default, so the day-to-day model is stated plainly: when no qualified
   reviewer is available, the exact-user bypass is the recorded normal path for
   that change, each use is logged, and Goal 2 is reported as unmet until a
   reviewer exists. For control-plane changes the gap is structural rather than
   temporary: the operator is the sole code owner (Section 7.1), so every
   operator-authored control-plane merge, including edits to `AGENTS.md`, this
   specification, and the readiness evidence file, is a logged bypass event,
   and that bypass log is the control plane's audit record by design, complete
   for as long as the ruleset itself is not administered around (an
   administrator can disable a rule, merge, and restore it without a bypass
   entry, an operator-discipline bound of the same kind Section 14.2 states);
   whether GitHub exposes and retains bypass logging for a user-owned private
   repository is itself plan-dependent and is read back in Section 18 step 4
   with the other plan facts. The same absence makes the negative tests of
   Section 18 steps 11 and 14 (a non-bypass actor blocked from merging and
   pushing) unverifiable, and it makes the positive approval and
   stale-dismissal tests of steps 9 and 10 unverifiable too; all of them are
   then recorded as unverified by absence rather than passed, and the matching
   Section 21 criteria read the same way. The readiness evidence records only a
   role label, a run-local salted digest, and the pass/fail result for the
   reviewer used in Section 18 step 9, never a login, a name, or a resolvable
   review API ID.
3. Swift 6 Dependabot compatibility requires an empirical check during the
   post-visibility hosted rehearsals; local configuration validation alone does
   not satisfy it.
4. A future macOS 27 line requires a stable hosted runner or a separately
   reviewed hardened alternative.
5. Active rulesets for a private repository depend on the account plan. If the
   plan cannot enforce the exact disposable-branch rehearsal and final `main`
   ruleset, record the private limitation and perform those checks after public
   visibility. Hosted and governance readiness remain incomplete until the
   public-state readbacks and rehearsals pass; no unavailable rule is silently
   omitted. Every plan-dependent claim in this document (required environment
   reviewers, selected-action patterns, private rulesets, and code-owner
   enforcement on a private repository, which GitHub documents as available to
   personal accounts only from Pro upward) is written for a user-owned
   repository on a personal GitHub Free or Pro account; Team and Enterprise are
   organization plans whose private-repository capabilities differ, so the
   bootstrap records the actual owner type and plan and reads the actual
   account capability from the API before relying on any such claim.
6. The repository must accept and return `sha_pinning_required: true`,
   `default_workflow_permissions: read`, and `can_approve_pull_request_reviews:
   false`. The committed external-Action allowlist is additionally required;
   neither control substitutes for the other.
7. Required environment reviewers are not a private-phase prerequisite or
   proof point. Whether the account's plan offers that protection on a private
   repository is recorded from the API under item 5 rather than asserted here;
   regardless of the answer, the environment is configured and tested only
   during the separately authorized public-launch phase.
8. Live Pages deployment cannot be exercised before the separately authorized
   public-launch phase. Private evidence is limited to deterministic temporary
   site assembly and route tests.
9. Before separately authorized version publication, the tag-creation ruleset
   must identify only the newly provisioned environment-gated publisher, and the tag update-and-deletion
   ruleset must name no bypass actor. If it cannot, publication waits for a
   safely selectable publisher identity.

## 21. Acceptance criteria

The visibility checkpoint and the completed hosted readiness levels are distinct.
Before visibility changes, the private phase in Section 18 must satisfy all
implementation, independent review, full local test and coverage gates, static
and applicable settings checks, and the fresh privacy audit. It records hosted
and actor-dependent criteria as pending. The conditional visibility authorization
permits proceeding only at that checkpoint, without calling pending checks
passed or waiving them. **Amended 2026-09-20 (HUMAN-DECISIONS D17):** the operator advanced
the visibility checkpoint ahead of the unevidenced phase-1 items on the blockers named in the
§18 amendment; pending checks are still not called passed — they stay PENDING in the evidence
file until evidenced.

After visibility, readiness has two levels. Every criterion below belongs to
both; where a criterion
carries an "unverified by absence" clause, that fallback satisfies only the
first level, and the second level requires the criterion itself to be verified.
"Rehearsal complete" is the implementation-owned state and may carry criteria
recorded as unverified by absence (no qualified reviewer, no non-bypass write
actor) as long as each is named as such in the evidence. "Publication-decision
ready" is stricter: it requires every governance criterion (independent
approval, stale dismissal, non-bypass enforcement, forged-status rejection) to
have been verified rather than recorded as absent, because Goals 2 and 3 are
not met while they are unverified. "Publication-decision ready" additionally
requires the fresh pre-publication privacy audit gate of Section 15 to be
closed, with value-free evidence of that fresh audit round (searched classes,
engines, commit-message coverage, zero findings for the stated scope) recorded, and
requires the code-owner refusal of Section 18 step 11 to have been verified
rather than recorded as absent, and requires that no distribution writer exists
until the launch specification defining it is approved; this level is therefore
unreachable while the operator works alone, because the code-owner refusal and
the independent approval need an actor who does not yet exist, and reachable
once a qualified reviewer with counted-review permission exists (Section 20
item 2). Both levels stop at the Section 21.1 hard stop; only the second is the
input to a later version-publication decision. Neither level is a prerequisite
for the earlier visibility-only transition, and neither authorizes a publisher,
release, tag, Pages deployment, or Homebrew action. The automation program's
post-visibility readiness criteria are:

- macOS 26 is documented as the current tested and supported baseline, future
  majors become supported only after validation, macOS 14 through 25 are
  documented as untested and unsupported, and the technical package deployment
  floor remains macOS 14;
- the PR template contains exactly Rationale, Details, Testing, and Checklist
  as its four top-level sections;
- every mandatory hosted job allocates a runner and passes after public
  visibility on the recorded exact candidate; elapsed time or the former
  October 1 date is not evidence;
- trusted-base governance rejects policy tampering and mixed policy/product
  PRs, demonstrated on the disposable branch in Section 18 step 11 by a
  deliberate mixed PR and a deliberate control-plane edit in an ordinary PR,
  both rejected, and by a forged same-name status that the bound required
  checks ignore;
- aggregate and changed-line coverage are each at least 90%;
- every production target is present and non-regressing;
- new commands and contract surfaces cannot enter without mapped tests;
- hosted-safe CLI tests run in Actions and live/TCC tests remain isolated;
- operator-authored PR creation and qualified independent approval are
  verified, or, for rehearsal-complete only, recorded as unverified by
  absence under Section 20 item 2 when no qualified reviewer exists;
- stale approval dismissal on a code push, and the fresh-approval rebinding on
  a title or description edit (including the merger's re-run that turns it
  green), are verified, or, for rehearsal-complete only, recorded as unverified
  by absence on the same footing;
- the code-owner review rule is present in the disposable rehearsal ruleset
  read back in Section 18 step 11 (and carried into the prepared `main`
  ruleset), `.github/CODEOWNERS` names only the operator for every
  control-plane path, and a non-operator approval alone was shown not to
  satisfy a control-plane validation PR, or, for rehearsal-complete only, that
  last assertion is recorded as unverified by absence under Section 20 item 2;
- squash is the only enabled merge method, and the one validation PR
  squash-merged into the disposable protected branch in Section 18 step 12
  produced a commit whose header and body exactly equal the final PR title
  and description after the recorded normalization (the same property on
  `main` is confirmed only in the operator-gated step 20);
- the operator's exact user is the sole always-bypass actor of the reviewed
  ruleset, and on the disposable protected branch every non-operator write
  actor was shown unable to direct-push or force-push, or, for
  rehearsal-complete only, when no non-operator write actor exists, that
  criterion is recorded as unverified by absence rather than passed (the same
  property on `main` itself is confirmed only in the operator-gated step 20);
- the operator bypass and lease-protected force-push capability are verified on
  a disposable branch protected by an active exact-name ruleset, rather than by
  rewriting `main` or relying on ruleset `evaluate` mode;
- the disposable ref and its rehearsal ruleset are removed after evidence is
  captured, and the reviewed `main` ruleset is prepared and fully rehearsed
  on the disposable exact-name ruleset (its activation on `main` is the
  separate operator-gated step 20 of Section 18, recorded alongside the
  Section 21.1 hard stop, and is not authorized by the visibility transition);
- an explicit full commit ID passes the read-only release rehearsal, including
  predicted release-file changes, archive contents, checksums, linkage, and
  runtime version;
- Pages `/`, `/version/`, prior-series paths, manifest, the
  temporary-artifact restore path, and canaries validate from an exact-SHA
  temporary artifact without a Pages deployment;
- Dependabot works for every enabled ecosystem and never auto-merges;
- all Actions use full commit SHA references;
- the committed external-Action allowlist rejects an unlisted Action identity;
- repository Actions settings read back `sha_pinning_required: true`,
  `default_workflow_permissions: read`, and `can_approve_pull_request_reviews:
  false`;
- the repository's Actions settings, owner type, and plan were read from the
  API and recorded, selected-action and merge-queue availability were derived
  from those documented facts, and no claim in the readiness evidence relies on
  a setting the read-back did not show;
- neither phase relies on unverified server-side selected-action patterns;
- static inspection of every workflow under `.github/workflows/` proves that
  none has a deployment environment, tag, Release, Pages deployment,
  branch-write, write-capable permission, listener, publisher, or
  distribution-writing path, none uses a `workflow_run` trigger, a `secrets:`
  reference, or a self-hosted runner label, every checkout sets
  `persist-credentials: false` explicitly, no workflow declares an
  `environment`, no two workflows produce a check with the same name, each
  required workflow's trigger set matches the recorded one, exactly one
  `pull_request_target` workflow exists, it does not reference the proposal
  head in any step, and every checkout step in it sets an explicit `ref`
  resolving to the protected base, every workflow and every job declares an
  explicit `permissions` block, no secret-context reference or `secrets:
  inherit` survives parsed-YAML inspection, the API read-back of secrets,
  Actions variables, Dependabot secrets, environments, deploy keys, installed
  GitHub Apps (with their permission scopes), fork pull-request workflow
  settings, workflow-permissions settings (default read, workflow approvals
  disabled), Pages configuration (no site, no deployment), `CODEOWNERS`
  effective-ownership coverage and parse errors, collaborator lists, and the
  GitHub-side OIDC and attestation settings matches the recorded expected sets,
  and the previously tracked dispatchable release workflow and Pages deployment
  job have been converted or removed;
- the phased readiness evidence exists as the single tracked value-free file
  named in Section 18 step 19;
- the pre-visibility gates and conditional visibility change are recorded,
  followed by actual public-state hosted and rehearsal evidence;
- no Pages deployment, release, tag, Homebrew change, version deployment, or
  release-freeze lift occurred as part of this program.

### 21.1 Stop before distribution and version publication

Meeting these criteria establishes post-visibility readiness, not authorization
for version publication or distribution. The approved continuation must stop
before Homebrew distribution, with Pages undeployed, the release freeze intact,
and no publisher bot, event listener, protected
deployment environment, `v*` tag ruleset, GitHub Release, Homebrew update,
version publication, bot account, GitHub App, personal access token, deploy
key, write-granting secret or variable, or OIDC or attestation trust
relationship created for publication (the ephemeral status-only test token of
Section 18 step 11 is revoked and its absence re-confirmed before readiness is
asserted). Before the conditional visibility checkpoint passes, the repository
remains private. After it passes, mandatory hosted validation and its dependent
rehearsals proceed while the release freeze and publication-write prohibitions
remain in force. The future publisher controls remain intentionally unverified
until the operator separately authorizes that transaction.

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
- [GitHub Actions permissions REST API](https://docs.github.com/en/rest/actions/permissions)
- [Custom Pages workflows](https://docs.github.com/en/enterprise-cloud@latest/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)
- [Reusable workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations)
- [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [SwiftPM test coverage](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/SwiftTest.md)
- [Dependabot configuration](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-options-reference)
- [Dependabot on Actions](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-on-actions)
- [Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
- [Artifact attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations)
