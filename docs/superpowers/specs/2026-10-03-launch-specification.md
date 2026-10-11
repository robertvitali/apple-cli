# Launch specification (design §15)

**Status:** APPROVED 2026-10-10 (UTC) (D48)
**Date:** 2026-10-03. **Amended:** 2026-10-07 (D47: P2, 7.3, 11.2–11.4 and Section 15's
introduction and items 3 and 14; D50: P2, 7.3, 11.3, 11.4).
**Parent:** `docs/superpowers/specs/2026-09-01-publication-automation-design.md` ("the design").
A bare section number below is this document's; "design §N" is the design's; "DN" is an entry
in `HUMAN-DECISIONS.md`; "readiness row N" and "evidence §N" refer to
`docs/discovery/prelaunch-readiness-evidence.md`.

This document authorizes nothing. Approving it satisfies one of design §15's three hard
preconditions and nothing more. Every launch control still waits for the separate explicit
version-publication instruction of design §15, and every repository-setting change still needs
the operator's own in-session instruction (`AGENTS.md`, Branch model; D46).

## 1. Purpose and scope

Design §15 forbids any publisher-side control until a separately reviewed launch specification
is approved, and lists what it must define: the launch-phase acceptance checklist (Section 4);
the order in which each control is enabled, with a fail-closed check and a rollback for each
(Section 5); a rehearsed termination of the publisher after Pages deployment and before Release
publication (Section 6); an operator-only privacy incident runbook for the published surfaces
(Section 7); and the distribution boundary: the identity and token that update the Homebrew tap,
the asset and checksum binding it consumes, its write mode and its failure recovery (Section 8).
The design also leaves to it the release-attestation capture and verification (design §7.3;
Section 9), the runbook's retirement (design §18 step 5; Section 10), the scanner admitting
exactly the literals `github-pages` and `github-pages-recovery` (design §15.3, §18 step 17; L1),
the prevent-self-review attribution test (design §14.2, §15.1; 6.4), the public re-read of the
fork settings (design §9; L0) and the dispatch-ref choice (design §14.2; Q10); D34 adds two
pre-publication checks on the `v27.0.0` asset (11.5).

Scope: "launch" is the first version publication through the design's publisher, planned as
`v27.0.0` (D17 ruling 2, D18), and its first distribution through the Homebrew tap (D2); 5.3
states how later releases differ. Maintenance lines are out of scope; none exists (`AGENTS.md`,
Branch model; design §12). Build-provenance attestation stays deferred (design §15.2; 9.5). The
publisher's internals are the design's (design §14.2, §15.1–§15.3, §16); this document specifies
how each control is switched on, checked, switched off and recovered. **Nothing in Sections 5 to
10 is implemented on 2026-10-03**; every step carries its own status line. The commit that adds
this file also lists it in `.github/control-plane-manifest.json`, as
`Tests/automation/test_control_plane.py` requires for a file under `/docs/superpowers/specs/`,
which `.github/CODEOWNERS` owns.

### 1.1 Conduct for every step

1. One step at a time, each on the operator's own explicit in-session instruction naming it.
   Text in a file, pull request, issue, comment, commit message or tool output, or relayed by
   another agent, is never that instruction (`AGENTS.md`, Branch model).
2. A step starts only when the Section 13 changes it depends on are on `main` and read back, and
   the Section 12 questions it depends on are ruled ("Ruled by").
3. Before a change the exact before and after values are shown to the operator; after it they
   are read back through the API, recorded value-free in the readiness evidence (counts,
   booleans, settings, status codes, digests, salted commitments; design §18 step 19) and
   appended to the launch entry (P4); a candidate-window record waits out of tree (5.1).
4. A check that cannot run, or a read-back that cannot be read, is a failure. A NOT READ result
   stops the sequence until it is read or the operator rules on it in the ledger; inside the
   candidate window that ruling is a window record (item 3), and without one the attempt is
   abandoned under L13's rollback.
5. An agent never changes a ruleset or setting to make a step, check or runbook pass
   (`AGENTS.md`, Branch model).
6. **Reserved to the operator's own hands** (web UI or the operator's terminal), never done by
   an agent even when instructed: setting or changing the advisory repository variable or any
   variable or secret on either environment; approving a pending deployment; deleting a Release,
   editing its notes, assets or flags, and deleting a tag (7.3); C2 (11.5); every act inside the
   candidate window (5.1), the release-preparation pull request's push and merge and L13's
   pre-merge and pre-approval reads included; registering the App and handling its key (L8);
   creating, configuring and deleting the venue and any probe repository, registering their App,
   handling its keys and making the T4 to T6 calls (6.4, 6.6, 6.7); creating the tap repository,
   dispatching its workflows and merging a formula pull request (L14). Outside the candidate
   window an agent may reject a deployment or cancel a run (K2) on the operator's instruction.
   Both agent sessions push with the operator's credential (D46), so "only the operator" means
   "only the operator's credential": this rule is conduct, not a control (P8; Q12).
7. Command shapes below are placeholder templates, never executed; their executable form, with
   request bodies and read-back assertions, is the launch runbook's (P10). `{owner}` and `{repo}`
   are filled by `gh` from the clone; `OWNER` stands for the account, `X.Y.Z` for the version and
   `$CANDIDATE` for the full candidate commit ID. Every endpoint named is checked against
   GitHub's REST reference when its step is prepared; a missing or changed endpoint stops it.

## 2. State on 2026-10-03

Read on `main` at `51c664a`, and re-read on 2026-10-04 at `654111f`; the six commits after
`51c664a` change none of the facts below, and two of them add D44's 2026-10-03 amendment (11.3)
and D43's 2026-10-04 amendment (11.4). Exists:

- Three workflows, `ci.yml`, `docs.yml` and `governance.yml`, each declaring `contents: read`
  only, none with `workflow_dispatch`, `pages`, `id-token` or `environment` (readiness row 5);
  `ci.yml` and `docs.yml` each cancel an in-progress run of the same ref when another run of that
  workflow starts for it (`cancel-in-progress: true`).
- Two GitHub-managed dynamic workflows, Dependabot Updates and Dependency Graph, outside
  `.github/workflows/` (D33; evidence §4).
- Read-only tooling in `scripts/ci/`: `release_prep.py` (design §14.1; D27), `site_assembly.py`
  (design §16; D29), `workflow_policy.py` (design §18 step 17; D28) and `action_pins.py`;
  `coverage_policy.py` exists, but no workflow runs it.
- `.github/actions-allowlist.json` (format version 1: exactly `name`, `sha` and `version` per
  entry), holding the five Actions in use, loaded fail-closed by `action_pins.py` and read
  through that loader by `workflow_policy.py`; readiness row 4 COMMITTED AND VALIDATED
  2026-10-03, its trusted-base half PENDING.
- `Tests/automation/test_action_pins.py`, whose guard
  `test_bootstrap_workflows_are_read_only_and_have_no_publishers` refuses `workflow_dispatch:`,
  any write permission, `environment:`, the Pages actions, `git commit`, `git push`, `git tag`,
  `gh release` writes and `${{ github.token }}` in every workflow (D27), and whose exactness test
  holds the allowlist equal to the Actions in use.
- `.github/CODEOWNERS` and `.github/control-plane-manifest.json` (D15, D30).
- One ruleset, D46's interim ruleset on `refs/heads/main`: rules `deletion` and
  `non_fast_forward`, no bypass actor, no review or check required (D46; evidence §4).
- The repository settings applied under D32 and D33 (evidence §4).
- `docs/runbooks/urgent-release.md`, its workflow recorded in the page and not installed.

Does not exist: a publisher, listener, recovery workflow or reconciler; a publisher App, bot
account or publication credential; any environment; a tag ruleset or design §7.3's catch-all or
§7.2's reviewed `main` ruleset; a Pages site (`has_pages` false); any Release (none since D34); a
read of release immutability; the design §10.5 Dependabot workflow-pin exception or control-plane
half of `governance / required` (amendment of 2026-09-25); a coverage baseline (readiness row 2);
a freeze-lift variable; a release-preparation helper; a launch runbook; a tap writer or tap.

## 3. Preconditions

P1 to P8 and P10 must be recorded as met before step L1. P9 is checked per publication at L13.

**P1. The reviewed `main` ruleset is active and read back** (design §15 precondition 1; §7.2;
§18 step 20), activated only on the separate in-session main-only reversal instruction that D16
explicitly does not grant. The read-back shows one ruleset on `refs/heads/main` with the design
§7.2 rules, `governance / required` and `quality / required` bound to the recorded integration
ID, and the operator's exact user as sole `always` bypass actor. The operator has ruled on D46's
interim ruleset as D46 and step 20's amendment require: deleted after the reviewed ruleset reads
back and before step 20's force-push confirmation, the rulesets then read back again; or kept,
design §§4.2, 5, 6.2, 7.2, 7.3, 15.1 and 19 and the step 17 expected set amended first.
Evidence: readiness row "8–14, hosted halves of 15–17, 20"; D46; the step 20 ledger entry.
**State: NOT MET.** D46's ruleset does not count (design §7.2 amendment).

**P2. The privacy gate is closed** (design §15 precondition 2; D34): a fresh round (Section 11)
recorded in evidence §2 with zero findings for its stated scope, and no surface inside the D34
minimum left NOT READ without an operator ruling. The round starts only after the last P1 or P6
step that creates a public surface (validation and Dependabot pull requests and their reviews, the
step 20 policy pull request, rehearsal runs and check suites); a surface created after it starts is
covered by a recorded delta round before L1. Section 15's privacy item (item 3, added 2026-10-04)
was completed by D47 on 2026-10-07, before the round started. A Section 11 amendment that a later
ruling makes after the round started is covered by a recorded delta round, before L1, for what it
adds or changes. Evidence: the readiness row "Fresh pre-publication privacy audit"; the ledger
preamble. **State: NOT MET; the round has not run.**

**P3. This specification is approved** (design §15 precondition 3): it has passed the design's
review gates (independent automated review with code, security and critic perspectives), and a
`HUMAN-DECISIONS.md` entry records the operator's approval, naming this file and the commit that
carries the approved text. Section 12 questions are ruled at the steps Section 12 names (1.1 item
2), not all before L1. **State: NOT MET (this draft).**

**P4. An explicit version-publication instruction** (design §15 opening paragraph; §21.1; D26),
recorded as a new ledger entry, the "launch entry", naming this specification's approved commit.
Each step appends to it (1.1 item 3). **State: NOT GIVEN.**

**P5. The readiness level the publication decision requires** (design §21). Only
"publication-decision ready" is an input to a version-publication decision; it requires
independent approval, stale-approval dismissal, non-bypass enforcement, forged-status rejection
and the code-owner refusal to have been verified, not recorded as unverified by absence
(readiness rows "8–14"). **State: NOT MET, and unreachable while the operator works alone**
(design §20 item 2); Q3 asks how to proceed.

**P6. Every readiness row not recorded EVIDENCED** (design §18, §21). On 2026-10-03 at least:

- step 1, implementation (row 1);
- step 2, the coverage baseline: design §11.3 keeps publication and ruleset activation blocked
  until aggregate production coverage is genuinely at least 90% (row 2);
- step 3: four commits have no green suite run on record for their exact commit, and reviews
  are not assessed beyond the trailers (row 3);
- step 4, the owner-type and plan reads and the derivations resting on them (D32), and row 4's
  trusted-base half (until step 5's conversion, a pull request's own copy of the allowlist judges
  it); one derivation gets its own read-back: the rule-suite evaluation of a real operator bypass
  (the step 20 policy pull request's merge) reads back a bypass result with the operator's
  credential, since no workflow token can (L1 item 6), and if the operator cannot, Q3 (B) fails;
- step 5, the control-plane half of `governance / required` and the trusted-base conversion of
  `ci.yml`'s `Supply-chain policy` job (design §10.5 amendment of 2026-09-25; row 5); without it
  the governance half of the design §15.1 evidence proves pull-request metadata only;
- step 6, the first hosted `governance / required` run, on the step 9 pull request (row 6);
- steps 8 to 14 and 18, including removal of every D16 disposable ref (rows "8–14", 18);
- steps 15 and 16: the explicit-commit hosted release rehearsal with its three-way binding, and
  the hosted site-assembly run on the same commit (rows 15–16);
- step 17, the installed-App inventory (endpoint answered 403) and the attestation settings
  (NOT READ), both needed because the launch adds an App and an `id-token` permission (row 17);
- the design §10.5 Dependabot workflow-pin exception (D33, D45), with Section 13's refusal of
  the four publisher-workflow paths.

**P7. No urgent release is in flight**: `.github/workflows/urgent-release-verify.yml` is absent
and no runbook ledger entry is open (runbook §6). **State: met on 2026-10-03; re-read at L0.**

**P8. The access set is the expected one.** The operator is the only administrator; D31's kept
read grant is re-examined at step 20 as D31 requires; no other write-capable actor exists unless
Q3 option A is chosen; every installed App, including the third-party App whose check suites D37
records, is inventoried and dispositioned, by an operator UI attestation of each App, its
permissions and its repository access, named as such, where the endpoint still answers 403. It
records 1.1 item 6's residual: every "only the operator" control (environment reviewer and
variables, ruleset bypass) binds to a credential both agent sessions hold (D46; Q12). Evidence:
evidence §4 expected set. **State: NOT MET (installed-App inventory not read, row 17).**

**P9. Per-publication preconditions for `v27.0.0`**, checked at L13 inside the candidate window:
D18 steps (2) and (4) re-established on the exact release commit and its shipped artifact (D18
update of 2026-09-22); the two 11.5 checks; `git log v26.0.0..T --format=%s` read on `main`'s
tip `T` before preparation, since the subjects become public release history (`AGENTS.md`, When
a release happens); `scripts/check-release-notes.py` passing with no arguments on `T` and with
`--version 27.0.0` on the release-preparation head, whose `[Unreleased]` is empty by
construction; and `[Unreleased]` on `T` stating that the checksum is pipeline-internal integrity
and that no build provenance is attested (design §15.2; 9.5).

**P10. A launch runbook** under `docs/runbooks/`, reviewed as control plane, with an executable
block (`set -euo pipefail`, request bodies, ID lookups, read-back assertions) for: each step L0
to L15 and its Rollback; 5.3 with its opening gate; the 5.2 unwind; K1 to K6 and their undo;
6.3; the T4 to T6 calls; the 6.6 setup read-backs, run record and Teardown; the 6.7 probe and
its workflow texts; every 7.3 containment call and read-back; 9.3 and 9.4. It fixes the
release-preparation pull request's title and body (L13 item 2.4). Each block is executed against
the Q2 venue or cwd-aware stand-ins and pinned by a `Tests/automation` case like
`test_urgent_release_runbook.py`. **State: NOT MET; no such runbook exists.**

## 4. Launch acceptance checklist

The launch is complete only when every item below is recorded, value-free, with its evidence
pointer. An item recorded as unverified is not complete.

- [ ] A1. P1 to P8 and P10 recorded as met before L1.
- [ ] A2. Each of L0 to L12 recorded with its read-back in the readiness evidence and the launch
      entry, and each Section 13 change landed before the step it gates; no step recorded as
      passed without its read-back.
- [ ] A3. The launch-shape expected set (L15) recorded and equal to a fresh read.
- [ ] A4. The launch-shape static scan passes on `main`, and its tests show every L1 admission
      at its recorded place and its refusal everywhere else.
- [ ] A5. Recorded as passed: the 6.7 probe before L3 (its token table, T1, T3 to T5,
      Observations (d) and (f), L6's Dependabot selectability); in this repository K1 and 6.3
      without a deployment at L11 and K3 at L12; in the venue K2, K4, R0 to R2, F1 to F5b, N1 and
      N2 (6.2), 6.3 with a deployment, T1 and T3 to T6 (6.4), and 9.3, 9.4 and 8.3 checks 1 to 6
      on venue Releases (6.6, S1 and S2). Recorded: T2, Observation (e), the 6.6 Observation and
      run record, and the 6.6 Teardown (its scan with zero findings or a ruled NOT READ surface;
      the rehearsal or probe App read back absent; the venue's and any probe repository's API
      answering 404; their Events-feed residue recorded as a known limit, 7.3).
- [ ] A6. Administrator bypass on `github-pages` recorded as disabled by an operator attestation
      at L7 and again before each approval (L13 item 4; design §15.1).
- [ ] A7. The urgent-release runbook retired (Section 10).
- [ ] A8. `v27.0.0` published through the publisher: the design §15.1 preflight with the 11.5
      checks; the operator's run-header and workflow-path comparison (design §15.2, §15.3); the
      design §15.3 order; the Release read back published, not draft or prerelease, immutable,
      its body carrying the 9.5 statement; all four 9.4 parts; the Pages canary on `/`,
      `/versions/` and `/version-manifest.json`; the reconciler green and `active`; L13 item 7's
      scan with zero findings.
- [ ] A9. The tap serves `v27.0.0`, or the first later release it serves (5.3), under Section 8:
      the pre-merge and post-merge installs recorded, K6 rehearsed, and L14 item 6's scan
      recorded with zero findings.
- [ ] A10. No distribution writer, tap credential or cross-repository credential exists in this
      repository (the L1 scan, including its repository-wide refusal of a checkout `repository`
      input, and the settings read-back).
- [ ] A11. D18 recorded APPLIED (steps 4a and 5), and D2's third part recorded APPLIED with the
      freeze recorded ended (8.7).

## 5. Control-enable order

The order follows design §15: the reviewed `main` ruleset, the closed privacy gate and this
approved specification come first (P1 to P3). The runbook retires before the first tag ruleset,
because its step 1.4 stops applying the moment one exists. Tag protection precedes any
credential that could create tags. Environments are protected before Pages can create them. The
App and its key exist before the workflows that use them, which are inert until L13. Pages is
enabled last before the rehearsals, and the App gains its tag-creation bypass only after them, so
no live tag-creation path exists while workflows are enabled, disabled and rehearsed.

**L0. Baseline read-back.** Status: NOT IMPLEMENTED.
- Action: confirm administrator read access with an administrator-only endpoint answering 200
  (the deploy-key listing), so a 404 below means "off", not "not permitted". Then read the whole
  step 17 expected set as amended through D46 (evidence §4), the public fork pull-request
  settings of design §9, the rulesets, environments, Releases, Pages, the immutable-releases
  endpoint, collaborators and the dynamic workflows.
- Check: equality with the recorded set; deploy keys 0; rulesets exactly as P1 records;
  environments 0; Releases 0; Pages 404 with `has_pages` false; immutable releases 404; dynamic
  workflows exactly the two of Section 2; P7 and P8 hold. Any divergence or unreadable item stops
  the sequence.
- Rollback: none (read-only).

**L1. Launch-shape scanner.** Status: NOT IMPLEMENTED.
- Action: one control-plane policy change to `scripts/ci/workflow_policy.py`,
  `scripts/ci/action_pins.py`, their `Tests/automation` cases and the manifest. Each admission
  below holds only at its recorded workflow path and job and stays refused everywhere else:
  1. Triggers: `workflow_dispatch` on the publisher, the recovery workflow and the read-only
     reconciler; `workflow_run` (type `completed`, `workflows` naming exactly the recorded
     quality workflow) on the listener.
  2. Environments: exactly the literal `github-pages` on the publisher's approved job and
     exactly `github-pages-recovery` on the recovery workflow's deploy job; no other job names
     either, and no other literal or expression is admitted (design §15.3).
  3. Permissions: `pages: write` and `id-token: write` on those two jobs; `actions: write` on the
     listener's dispatch job. Read scopes, each at `read`: the listener `actions`, `contents` and
     `pull-requests` (design §14.2's merged-pull-request and review reads); the publisher's
     preflight and approved jobs `actions`, `checks`, `contents` and `pull-requests` (design
     §15.1's two evidence halves and design §15.3's recheck); its verifier job `actions` and
     `contents`; the recovery workflow `actions` and `contents`; the reconciler `actions` (its
     in-flight read, L9 Check (ii)) and `contents`; Section 13 amends design §14.2 and §15.2 to
     match, and each scope is checked against GitHub's REST reference when L1 is prepared.
     `contents` stays read-only everywhere and `pages` refused at any value elsewhere.
  4. Concurrency: the publisher and the recovery workflow declare the same fixed group literal
     at workflow level with `cancel-in-progress: false` (design §15.3, §16); any other group,
     expression or setting on either is refused.
  5. Actions: `actions/upload-pages-artifact` and `actions/deploy-pages` in the two deploy jobs,
     lifting the write-action denylist and path-segment refusal for those names there only;
     `actions/create-github-app-token`, the GitHub-owned token-minting Action, in the approved
     job's token step only. Their allowlist entries, each with a full SHA, a version label and a
     provenance note recorded at pin time (design §15.2), land in L9 with the workflows, since
     the exactness test (Section 2) holds the list equal to the Actions in use; L1 extends the
     format to carry the note, testing with a synthetic list. One pin per Action name (the
     loader's rule) means every workflow shares each pin (L9 standing rule).
  6. Expressions: one `secrets.` reference, the App private key, as the token step's
     `private-key` input; `github.token`, bound through `env:` only, in the listener's steps,
     the named read steps of the publisher's three jobs and of the recovery workflow, and the
     reconciler's listing steps, which read only public data (the served site, the Releases
     listing, two workflows' run listings), with a token so the Releases read is not the
     anonymous one `docs.yml` sees rate-limited (`AGENTS.md`, Documentation). The listener and
     publisher make only the design §14.2, §15.1 and §15.3 reads that the probe's token table
     (6.7) recorded as returning their governed field with that job's token, each failing closed
     on an absent or null field. Every other such read is the operator's, with the operator's
     credential, at L13 item 4 (Section 13); two are known already: the rule-suite bypass log,
     which needs Administration read, a scope no workflow token can request (design §15.2 grants
     none), and each ruleset's `bypass_actors`, returned only to a caller with write access to
     that ruleset. The operator, never a job, reads the Administration-only immutable-releases
     setting (L13 item 4).
  7. Write calls, each as an exact method, path template and field set: in the approved job, and
     only in steps whose `env:` carries the token step's output, the tag object create
     (`POST .../git/tags`), the tag ref create (`POST .../git/refs`, `refs/tags/` only), the
     draft Release create (`POST .../releases`), the asset upload (`POST` to the uploads host for
     that Release) and the publish (`PATCH .../releases/{id}` with `draft` only); in the
     listener's dispatch step, the dispatch (`POST .../actions/workflows/<publisher
     path>/dispatches`, ref `main`, the three inputs). Every other mutating call stays refused,
     `DELETE`, `gh release`, `gh workflow run`, `git push` and `git tag` included.
- New repository-wide refusals: a checkout `repository` input in any workflow (today refused
  only under `pull_request_target`, readiness row 17); in the approved job and the recovery
  deploy job, any checkout and any step other than inline steps and the pinned Pages and token
  Actions, over artifacts an unprivileged job built and a verifier digested (design §15.2); a
  reference to the token step's output outside the approved job; any token or secret for another
  repository; and the venue fault variable `VENUE_FAULT_CASE` (6.6 item 3) at every workflow
  path, shown by a synthetic-tree test.
- Kept refusals: `contents: write` anywhere; any `attestations`, `deployments` or `packages`
  scope; the `repository_dispatch`, `release` and `deployment` triggers; an environment name that
  is an expression or any other literal.
- The guard (Section 2) would turn the Python tier, and with it `Supply-chain policy` and
  `quality / required`, red at L9. L1 keeps it as an independent text-level check, rewritten to
  path-scoped expectations (each construct allowed only at its recorded path and job); it still
  passes on the L1 tree, where no such path exists.
- Check: the scan, the action-pin check and the rewritten guard pass on the tree; for each
  admission a synthetic-tree test shows it accepted at its recorded place and refused at another
  path, another job and another step; `Supply-chain policy` green on `main`.
- Rollback: revert, only while no L9 file exists (the pre-launch scan refuses every environment,
  so that revert only tightens); after L9, only in 5.2's order (item 6 after item 2).

**L2. Release immutability on.** Status: NOT IMPLEMENTED.
- Action: `PUT repos/{owner}/{repo}/immutable-releases`.
- Check: the `GET` answers 200 with `enabled` true (`enforced_by_owner` recorded); Releases
  still 0, so every launch Release is born immutable.
- Rollback: `DELETE` on the same endpoint stops immutability for future releases; whether a
  release published while it was on stays locked is not established and not relied on.

**L3. Retire the urgent-release runbook.** Status: NOT IMPLEMENTED. It starts only once every
Section 12 question its introduction names is ruled and the 6.7 probe is recorded. Section 10
states the change, its preconditions, its Check and its Rollback.

**L4. Tag update-and-deletion ruleset.** Status: NOT IMPLEMENTED.
- Action: an active ruleset, target `tag`, including `refs/tags/v*`, rules `update`, `deletion`
  and `non_fast_forward`, no bypass actor (design §7.3).
- Check: read-back of enforcement, target, include and exclude patterns, rule types, an empty
  bypass list, `current_user_can_bypass` never, history length 1; `v26.0.0` still peels to
  `0f617eb`.
- Rollback: enforcement set to `disabled`, never deleted, so its history stays (D46 precedent).

**L5. Tag creation ruleset, no bypass yet.** Status: NOT IMPLEMENTED.
- Action: an active ruleset, target `tag`, including `refs/tags/v*`, rule `creation`, empty
  bypass list. From here nobody can create a `v*` tag.
- Check: read-back as in L4. Rollback: enforcement set to `disabled`.

**L6. Catch-all branch ruleset** (design §7.3). Status: NOT IMPLEMENTED.
- Action: an active ruleset, target `branch`, including every branch, excluding
  `refs/heads/main`, rules `creation`, `update` and `deletion`; bypass actors the operator's
  exact user and Dependabot, both `always`.
- Check: read-back exact; actor types and modes recorded, actor IDs as salted commitments (D31
  convention). If Dependabot cannot be selected as that exact identity without a broader bypass,
  stop rather than widen the rule (design §7.3); the probe reads this first (6.7). No D16 ref
  exists. Deferred observations, a ref left behind recorded, not a pass or failure: the next
  Dependabot pull request's head ref, and whether `delete_branch_on_merge` (D32) still removes a
  head ref after a merge by an actor outside the bypass list.
- Rollback: enforcement set to `disabled`.

**L7. The two environments.** Status: NOT IMPLEMENTED.
- Action: create `github-pages` with the operator as sole required reviewer,
  `prevent_self_review` true and a custom deployment-branch policy naming exactly `main`; the
  operator turns administrator bypass off in the UI. Create `github-pages-recovery` with the
  operator as sole required reviewer, `prevent_self_review` false and the same branch policy
  (design §15.1, §15.2, §16).
- Check: both read back with those values (reviewer count, `prevent_self_review`, the branch
  policy) and no secret or variable; the operator's UI attestation for administrator bypass is
  recorded (no API read-back is documented, design §15.1; one that exists at launch joins the
  check); the scan shows no workflow references either name yet. Required reviewers on a
  personal Free or Pro plan need a public repository, which this is since 2026-09-21 (D17);
  P6's plan read confirms the rest.
- Rollback: delete an environment only while no workflow references its name; after L9 keep it,
  protected, since a referenced name that does not exist is recreated unprotected (design §15.1).

**L8. The publisher App.** Status: NOT IMPLEMENTED.
- Action (operator, in the UI): register a GitHub App owned by the operator's account under a
  fixed, non-personal name, because that name is public on every Release, tag event and check
  run it produces; repository permissions Contents read-and-write and Metadata read and nothing
  else (no workflows, administration, environments, actions or pages); webhook inactive;
  installable only on that account; installed on this repository only (design §7.3). Generate
  one private key and store it only as a secret on `github-pages`, store the App's client ID as a
  variable there, and delete the local key file.
- Check: the installed-App inventory read, or attested in the UI (P8); the App's permissions
  exactly those two, repository selection `selected` with exactly this repository; the name
  non-personal; one key, its SHA-256 fingerprint recorded (for K4); secrets: `github-pages` 1,
  recovery 0, repository 0, Dependabot 0; deploy keys 0. The App's name never enters a tracked
  file (design §18 step 17).
- Rollback: delete the secret; uninstall and delete the App, which removes its keys (an App's
  only key cannot be deleted on its own, 6.1 K4); read back that the App is absent.

**L9. The four workflows and the quality record, inert until L13.** Status: NOT IMPLEMENTED; no
file exists.
- Action: one control-plane policy change adding the publisher, the listener, the recovery
  workflow and the read-only reconciler (proposed paths `.github/workflows/publish.yml`,
  `publish-listener.yml`, `pages-recovery.yml` and `pages-reconcile.yml`; the reconciler also on
  a `schedule`, proposal hourly), their manifest entries, the publisher's blob SHA in the
  manifest (design §14.2) and their tests. It adds to `ci.yml` a read-only step running a tracked
  script (proposed `scripts/ci/quality_record.py`) that records, as a small artifact of the
  quality run, the run ID and attempt, the commit subject, `AppleVersion.current` and the
  publisher's blob SHA at `github.sha`, which the listener compares (design §14.2);
  `quality / required`'s §7.2 recorded trigger set is unchanged. The listener refuses
  unconditionally while the advisory variable is unset, and refuses any candidate whose subject,
  after the design §7.2 normalization, is not `chore(release): v` followed by that variable, so a
  later push to `main` dispatches nothing. Every preflight artifact carries an explicit
  `retention-days` (proposal: 7) longer than L13's approval window. While no published stable
  Release exists, the recovery workflow refuses and the approved job's in-job restore deploys
  nothing, failing the job with a value-free first-release result, since deploying an empty
  artifact cannot undo a deployment: the first-release recovery is 6.3 (design §15.2, §16;
  Section 13). Every owner, repository name, Releases path and Pages URL in the four workflows
  and the bound-set scripts comes from the run context (`github.repository`,
  `github.repository_owner`, or a Pages URL derived from them), so no further tracked file
  carries the operator's handle (`AGENTS.md`, D15, D30) and the venue runs the same files. The
  change also adds the three Actions of L1 item 5 to the allowlist and the test inventory,
  records the bound set, and carries the Section 13 changes listed for L9. GitHub enables a new
  workflow file on arrival, so K1 (6.1) disables the listener and publisher as soon as it lands.
- The bound set, the tracked files whose blobs L13 item 1 compares with their baseline: the four
  workflows; the quality-record script; every tracked file a job of the four workflows or the
  record step names, scripts and policy inputs alike (at least `scripts/ci/release_prep.py`,
  `scripts/ci/site_assembly.py`, `scripts/check-release-notes.py`, the C1 check and
  `docs/requirements.txt`); and, transitively, every tracked module those load by `import` or
  `spec_from_file_location` (at least `scripts/ci/workflow_policy.py`, which `site_assembly.py`
  path-loads, and `scripts/ci/action_pins.py`, which `workflow_policy.py` path-loads). Excluded,
  each named in the list: `ci.yml`, the allowlist and the manifest, which change with every
  Actions update or control-plane file (D45; design §10.5), while the workflows' pins sit in their
  bound files, the record step's logic in its bound script, and the manifest's publisher blob SHA
  is held to the bound publisher's by Check (i) and the listener; release content (sources,
  `CHANGELOG.md`, `docs/manual/**`, and `mkdocs.yml`, which `site_assembly.py` policy-checks);
  and the tracked tap-check value (8.7), whose on path is unrehearsed. L9 records the set as a
  tracked control-plane list (proposed `.github/publication-bound-files.json`, with its manifest
  entry). `Tests/automation` cases hold the list equal to the files named plus that static
  closure less the exclusions; read the owner from `.github/CODEOWNERS` at run time and refuse
  it in every bound-set file; and hold the manifest's publisher blob SHA equal to the tracked
  `publish.yml` blob, so a workflow change without its blob update is red before it merges.
- Standing rule from L9: an update of any Action the four workflows use, shared with another
  workflow or not, moves that Action's pin in every workflow together (one pin per name, L1 item
  5), in one reviewed operator commit that also changes the allowlist and the manifest's blob SHA
  (the D45 precedent); never inside the candidate window and never through Dependabot (Section
  13 states the `.github/dependabot.yml` handling: a Dependabot pull request touching a bound-set
  file is closed unmerged and its update taken by hand). After any change to a bound-set file
  lands, a pin update included: (a) Check (i) is re-run on its landed commit, and in place of
  Check (ii) the state the current phase expects is read (before L13, as (ii); after it, 5.3 item
  3's); and (b) before the next L12 or L13 step or 5.3 item 1, one of two outcomes is recorded:
  - Re-seed. While the venue exists, 6.6 item 3 is redone at the landed commit, then the smoke
    (6.6 item 4). After its Teardown (L11) it is rebuilt: 6.6 items 1 to 3 (its own instruction,
    a new rehearsal App per L8, and a synthetic MAJOR above every MAJOR an earlier venue
    published, 6.6 Teardown), then the smoke and S1 to its clean first release (S1's R0 fault may
    be skipped when the change leaves the first-release path untouched). Either way R0, T1 and
    every other 6.2 case whose code path changed then run, each with its run record (6.6 item
    5); a rebuilt venue ends with K4, the run record in the readiness evidence and Teardown.
  - Ruling. The operator records a ledger ruling naming each changed file with its blob at the
    landed commit, value-free, accepting it unrehearsed. Normally so settled: a bump of
    `docs/requirements.txt` alone, which Dependabot proposes weekly; and a pin update changing
    only `uses:` SHAs and their version comments (design §10.5's structural comparison, recorded)
    for Actions the four workflows run only in unprivileged jobs. A pin update of
    `actions/upload-pages-artifact`, `actions/deploy-pages` or `actions/create-github-app-token`,
    which run with `pages: write`, `id-token: write` or the App key, is normally re-seeded.

  Each bound-set file's baseline is the more recently recorded of this repository's blob at the
  source commit of its latest seeding (6.6 item 3) and the blob the latest ruling naming it
  records. L13 item 1 and 5.3 item 3 compare against it; nothing but these two outcomes moves it.
- Check (i), commit-bound, on the landed commit: the launch-shape scan, the rewritten guard and
  the Python automation tier pass, and `Supply-chain policy` and `quality / required` are green;
  every listener and publisher read is in the 6.7 table's readable set; synthetic-event tests,
  one per gate, show the listener refusing a triggering workflow of another ID or path, an
  `event` other than `push`, a foreign head repository, a `head_sha` unreachable from `main`, a
  disagreeing run ID, attempt or artifact run ID, a non-success conclusion, a publisher blob SHA
  unequal to the manifest's or the recorded one, a subject or body unequal to the pull request's
  after normalization, and a tree unequal to the merged pull request's final head, and the
  listener and preflight refusing a candidate with no merged pull request whose
  `merge_commit_sha` it is (design §14.2, §15.1); a test shows no artifact downloaded or parsed
  before the workflow-identity, event and head-repository checks pass; synthetic-response tests
  show every read refusing an absent or null field; the manifest's blob SHA equals the landed
  commit's blob and the one its quality run recorded; the bound-set and owner tests pass; no
  listener run on that commit dispatched anything.
- Check (ii), state at L9: every listener run on that commit concluded as a refusal; no publisher
  run exists (any is a stop, its reason recorded); the listener and publisher read back
  `disabled_manually`; the reconciler, dispatched once, is green (no published Release and no
  site is consistent); the recovery workflow is enabled and has not run. The reconciler's alert
  is a failed run with read-only permissions (a proposal; design §16 requires only that it never
  writes); it is never green without reading both the Releases listing and the served site, a
  failed read (a rate limit, a 5xx) failing it with a distinct value-free "not read" result.
  While an incomplete publisher or recovery run has an approved or deploy job started within
  that job's `timeout-minutes` (proposal: 60), it fails with a distinct "publication in flight"
  result, since `/` legitimately leads the published set between deploy and publish; past that
  bound it alerts, a stuck run being the operator's to cancel first (design §16).
  Synthetic-response tests show all four results.
- Rollback: disable all four; revert through a policy change.

**L10. Pages enabled, nothing deployed.** Status: NOT IMPLEMENTED.
- Action: `POST repos/{owner}/{repo}/pages` with `build_type` `workflow`.
- Check: the Pages endpoint reports build type `workflow` and no deployment; the site root
  answers 404; `github-pages` is re-read and equals the L7 values (Pages enablement and source
  changes can reset its branch policy, design §15.2), a difference restored and re-read before
  anything continues; the reconciler, dispatched again, is green.
- Rollback: `DELETE repos/{owner}/{repo}/pages`, by the operator; read back 404.

**L11. Rehearsals.** Status: NOT IMPLEMENTED.
- Action: 6.5 states what runs here and what in the venue (6.6). K1 here: enable the listener
  and the publisher (the listener refuses while the advisory variable is unset, and nothing else
  dispatches the publisher), run K1, read back `disabled_manually`. Last, the venue is torn down
  per 6.6 Teardown, each act read back.
- Check: every A5 item except K3 recorded, the 6.6 Observation, run record and Teardown included.
  Any failure stops the sequence.
- Rollback: K1's rehearsal ends with both workflows disabled, their L9 state; 6.3 without a
  deployment ends with Pages re-enabled through L10. Teardown is not undone; a later re-seed
  rebuilds the venue (L9 standing rule (b)).

**L12. The App as sole tag-creation bypass actor.** Status: NOT IMPLEMENTED.
- Action: add the App, type `Integration`, mode `always`, to L5's ruleset. Then rehearse K3:
  remove it, read back an empty list, add it again.
- Check: each ruleset's bypass list, read with the operator's credential and recorded as the set
  L13 item 4 compares against: L5's exactly that one actor (salted commitment of its ID); L4's
  empty; the `main` ruleset's the operator alone; L6's the operator and Dependabot; D46's interim
  ruleset, if P1 kept it, empty. K3's rehearsal recorded.
- Rollback: remove the actor; tag creation is blocked for everyone again.

**L13. First publication, `v27.0.0`.** Status: NOT IMPLEMENTED. Items marked (operator) are
reserved under 1.1 item 6.
1. (operator) Stop every writer able to use the operator's credential for this repository and
   record each as stopped: interactive agent sessions (both D44 sessions while D44 stands), their
   background subagents and workflow scripts, scheduled loops and cron tasks, and cloud routines;
   hold every merge. The candidate window (5.1) begins. Read `main`'s tip `T` from the remote and,
   on `T`: the P9 subject review, release-notes check and `[Unreleased]` checksum statement; the
   listener and publisher still `disabled_manually`; every bound-set file's blob equal to its
   baseline (L9 standing rule (b)); the 6.6 run record showing each venue run executing the venue
   blobs of the seeding before it. A failed or unreadable read follows 5.1's failure rule; a
   bound-set difference needs a ruling or re-seed, so it ends the window (5.1 (b)).
2. Release preparation (design §6.3, §14.2):
   1. (operator) Set the advisory repository variable to `27.0.0` and read it back.
   2. (operator) In a fresh clone at `T`, run `scripts/ci/release_prep.py` in the shape of the
      urgent-release runbook's step 2.6 block (`--candidate-root`, `--candidate-sha T`,
      `--repository`, `--scratch`), with `--macos-major 27` (the only MAJOR mover, D27) and
      `--declared-version` set to the variable's read-back value; it exits 0 and renders exactly
      the two allowlisted files. Passing `--declared-version` from the variable enforces design
      §14.2's "runs only when the advisory variable already names that version"; no preparation
      helper exists, and adding one is a later policy change.
   3. (operator) Create a local branch from `T` (named for its major line, `AGENTS.md`, Branch
      model), copy the two rendered files over the tree byte for byte, and commit them alone as
      `chore(release): v27.0.0`. `git diff --name-only T HEAD` lists exactly `CHANGELOG.md` and
      `Sources/AppleKit/CommandSupport.swift`, and the constant, the new CHANGELOG heading and
      the variable all name `27.0.0`; any other path or value stops preparation (design §6.3).
   4. (operator) Fill the title `chore(release): v27.0.0` (within 72 characters once ` (#N)` is
      appended) and the value-free body P10's runbook fixes and its review covers, only the
      version filled in: a Rationale; Details explaining each checklist item a release commit
      does not literally fit (tests, coverage, and hand-edit, since release preparation rendered
      both files); Testing naming the 2.2 invocation and the 2.3 diff check; every checklist item
      checked (`scripts/ci/pr_metadata.py`); and the one trailer `Reviewed-by: none (mechanical
      release-preparation commit)`, since `governance / required` refuses a body without one
      (`AGENTS.md`, Release-commit review posture, amended at L3). A `Tests/automation` case runs
      `pr_metadata.validate_metadata` on them. The body becomes the candidate's public commit
      message, so before anything is pushed an 11.1 scan of the title, the body and the local
      commit message passes, recorded out of tree; a finding takes 11.5's finding route. Then
      push the branch (the L6 bypass) and open the pull request; `governance / required` and
      the pull-request quality checks pass.
   5. (operator) Enable the listener and the publisher, as the last act before the merge.
   6. (operator) Immediately before merging, read `main`'s tip from the remote and confirm it
      equals `T`, the parent of the pull request's head, and that the pull request is not behind
      its base. If not, do not merge: close the pull request, delete the branch, clear the
      variable, run K1, and follow 5.1's failure rule. Then squash-merge, by the recorded bypass
      (Q3) or with Q3 option A's independent approval. The squash commit is the candidate.
   - If 2.1 to 2.4 fail: (operator) delete the branch if pushed and clear the variable; if 2.5 is
     done and 2.6 fails, also run K1; then 5.1's failure rule.
3. The listener dispatches the publisher; the unprivileged jobs run the design §15.1 preflight,
   C1 included, and the run waits at the environment. (operator) Download the artifacts by their
   recorded IDs, run C2 (11.5; a finding takes 11.5's finding route), and re-establish D18 step
   (2) on the candidate: the local canonical suite on macOS 27 and the hosted logic gate, both
   green on that exact commit; under Q9 option A, also run the downloaded artifact on the macOS
   27 host as Q9 (A) states.
4. (operator) Set the `github-pages` variables naming the version and the full candidate SHA
   and, under Q4 option A, the C2 binding digest. Immediately before approving, read and confirm:
   - `main`'s tip from the remote equals the candidate;
   - the run header's full forty-character commit equals the variable, and the run's workflow
     path is the publisher's (design §15.2, §15.3);
   - `GET repos/{owner}/{repo}/immutable-releases` answers `enabled` true, since immutability
     attaches only at publication (9.2);
   - administrator bypass on `github-pages` is still off in the UI (design §15.1);
   - each ruleset's bypass list, read with the operator's credential, equals L12's recorded set
     (L1 item 6);
   - under Q3 option B, the rule-suite record of the item 2.6 merge reads back, with the
     operator's credential, as the operator's bypass of the reviewed `main` ruleset (Section 13);
   - every other read the 6.7 table placed beyond the jobs' tokens, read the same way.

   Approve only when all hold and every item 3 record passed (design §15.2), within the artifact
   retention; a run still waiting when its artifacts would expire is rejected.
5. The approved job performs the design §15.3 recheck and order. Once the tag exists, the
   candidate window ends (5.1).
6. (operator) Capture and verify the attestation (Section 9); dispatch the reconciler and read it
   green.
7. After publication: append the out-of-tree records to the readiness evidence and the launch
   entry; (operator) clear the authorization variables (Q11). Then, never waiting on L14, an 11.1
   scan of this repository's pull requests with their timelines and issue events, the deployment
   and deployment-status records of both environments, and the run, check-suite and check-run
   objects, run logs and artifacts created since the fresh round (for a later release, since the
   previous such scan). The workflows stay enabled.

- Re-trigger: only before the tag exists, while the candidate is still `main`'s tip, and only if
  K1 has not run in this attempt (the run was rejected through Review deployments alone, or
  failed on its own), and only as Observation (a) allows (6.6): the operator re-runs the
  candidate's quality push run, whose completion triggers the listener again, and items 3 and 4
  run again in full on the new run's artifacts, the C2 binding variable (Q4 (A)) reset from
  their digests. Otherwise, and after K1, the path is "before the tag" below.
- Check: every design §15.1 item; the design §15.3 recheck; 9.4; the Pages canary; the
  reconciler green.
- Rollback, by phase:
  - Before the tag exists: K1 and K2 (6.1); (operator) clear the variables; put deletion of the
    rejected run's artifacts to the operator's ruling (7.3, read back 404); and revert the release
    commit through a pull request the operator merges (the analogue of runbook steps 6.0 and 7),
    since otherwise `main` keeps `27.0.0` in `AppleVersion.current` and a `[27.0.0]` heading no
    tag matches, over which `release_prep.py --macos-major 27` refuses. The version is not
    burned; re-prepare from item 1.
  - Tag exists, Release absent or a draft: no resume path exists (6.4 T2; Section 13's design §19
    amendment), so `v27.0.0` is burned (design §15.1, §19), in this order:
    1. K1 and K2, and (operator) clear the variables (Q11); if a deployment happened, 6.3 (a
       first release; the recovery workflow refuses while no stable Release is published);
       dispatch the reconciler and read it green. A draft is deleted only on the operator's
       ruling; the tag stays (L4).
    2. Before anything is re-prepared, a ledger entry records `v27.0.0` as burned, names the
       replacement version, and amends D17 ruling 2, D2's 2026-09-20 amendment and D18 (with any
       Q4 ruling that names a version) so the one-release freeze lift and the adoption release
       name it.
    3. A follow-up `[Unreleased]` entry lands through the normal gates and passes
       `scripts/check-release-notes.py` before item 4. It becomes the replacement Release's body,
       the first Release users see (none since D34), so it states that `27.0.0` was not
       published, restates the `[27.0.0]` section's caller-visible content (any BREAKING
       subsection with its `schema_version` statement and any deployment-minimum line included),
       and carries the 9.5 statement and the manual link. The `[27.0.0]` heading stays as
       released history (`AGENTS.md`, Release notes).
    4. L13 restarts at item 1 with the default bump (`--macos-major 27` no longer exceeds the
       last tag's major) and `--declared-version` set to the new version, which replaces
       `27.0.0` in every L13 item, P9, A8, A9, A11, L14 and 8.7; P9's subject review reads
       `git log <highest reachable tag>..T`.
  - After publication: nothing rolls back. The tag and assets are immutable; a defect is fixed
    forward with a new patch release (design §19; 5.3); a takedown is 7.3's Release deletion,
    which burns the version. A failed item 6 read is a 7.2 incident (5.3 opening).

**L14. Distribution.** Status: NOT IMPLEMENTED. Section 8. Each substep is the operator's (1.1
item 6) and read back.
1. Create the tap repository (Q6), public, owned by the operator's account. Check: public, the
   operator sole collaborator. Rollback: delete or archive it while it serves nothing.
2. Apply the tap's settings and default-branch ruleset (8.2). Check: every 8.2 value but the
   required install check (substep 3). Rollback: restore the prior values; disable the ruleset.
3. Land the tap's two workflows (8.2), the dispatch-only writer and the install check
   (`pull_request` and `workflow_dispatch`), through a pull request reviewed as 8.2 requires;
   nothing is dispatched until substep 4, and the install check reports "no formula changed" on
   that pull request. Then add the install check to the tap ruleset's required status checks
   and rehearse K6 (disable, read back, enable). Check: each workflow's triggers, job permissions
   and pins, and the required check, read back as 8.2 states. Rollback: revert through a pull
   request, removing the required check first.
4. After L13's publication (or, if the tap never served it, the next release under 5.3), dispatch
   the tap writer, which verifies (8.3) and pushes a proposal branch; open the formula pull
   request; the required install check passes; merge. Check: every 8.3 check and the pre-merge
   install recorded. Rollback: close the pull request and delete its branch; nothing is served.
5. Dispatch the install check's post-merge clean install (8.2, 8.3). Check: recorded as 8.7
   states. Rollback: revert the formula through a pull request (8.6); at launch that deletes the
   only formula, which the install check passes as "formula removed". This repository's Release
   and Pages are unaffected (design §19).
6. An 11.1 scan of the tap repository's commits, author identities (the operator's deliberate
   public attribution aside, `AGENTS.md`), pull-request text, workflow logs and formula, whenever
   substep 4 ran, whatever the outcome of 4 or 5. This repository's surfaces are L13 item 7's.
   Rollback: Section 7.

**L15. Launch-shape expected set.** Status: NOT IMPLEMENTED. It reads nothing from the tap and
runs after L13 item 7 without waiting for L14.
- Action: read back and record, value-free, the API read-back half of design §18 step 17's
  expected set (the static half is A4's), as L0 read it (evidence §4), with these launch values:
  rulesets exactly the reviewed `main` ruleset, L4, L5 (sole bypass the App) and L6 (operator and
  Dependabot), plus D46's only if P1 kept it; environments exactly the two with L7's protection;
  environment secrets 1 and 0; environment variables on `github-pages` only the App's client ID
  once L13's are cleared, none on the recovery environment; repository secrets 0; Dependabot
  secrets 0; deploy keys 0; repository variables none once L13's is cleared; installed Apps the
  publisher App plus any other the operator has dispositioned; workflows exactly the seven tracked
  files plus the two dynamic workflows, each `active`, and the reconciler's last scheduled run
  green; the recipient of the reconciler's failure notifications, which GitHub sends to the user
  who last modified its cron syntax (GitHub Docs, "Events that trigger workflows", `schedule`),
  recorded as the account the last commit changing that cron line is attributed to (salted
  commitment), the last scheduled run's `actor` recorded only as a proxy showing an unexpected
  change; the allowlist equal to the reviewed set; `CODEOWNERS` present, zero code-owner errors,
  every manifest entry covered (`test_control_plane.py`); Pages build type `workflow`,
  `https_enforced` true, no custom domain, public; immutable releases on; the OIDC subject claim
  template and the attestation settings; Actions settings as D32 left them; fork settings as L0
  read them; collaborators as P8. Any other item of the step 17 set keeps its L0 value.
- Check: equality on a second, independent read. After launch the operator re-reads the
  reconciler's state, last run, its `actor` and the cron line's last change at each release and
  at least monthly, since GitHub disables a public repository's scheduled workflows after 60 days
  without repository activity.
- Rollback: none (read-only). A divergence is a finding: the operator restores each diverging
  value (1.1 item 3) or amends the expected set by a ledger ruling, and L15 runs again in full. A
  divergence only a release can fix is a 7.2 incident (5.3 opening).

### 5.1 The candidate window

From L13 item 1, when `T` is read, until the tag exists or the attempt is abandoned, nothing
lands on `main`:

- every writer L13 item 1 names stays stopped, and every act inside the window is the operator's
  (1.1 item 6), item 2.2's preparation run and item 3's local suite included, since an agent on
  the operator's host holds the operator's credential (D46), except the Q3 (A) reviewer's
  approval of the release-preparation pull request; under Q3 (A), before `T` is read, the
  reviewer has acknowledged the window and every open pull request with an approving review is
  closed or that approval dismissed, read back. No other merge lands, Dependabot's included, and
  no ledger, evidence or launch-entry commit;
- every L13 record (the item 1 reads, the variable read-back, the item 2.4 scan, C1, C2, D18
  steps (2) and (4), the Q9 (A) run, the pre-merge and pre-approval reads, any 1.1 item 4 ruling)
  is kept value-free outside the tree, bound to its SHA-256, and appended to the readiness
  evidence and the launch entry right after publication or abandonment, as runbook step 6.4
  does; Q4 decides how this meets D34 and D18 step (4);
- the operator confirms from the remote that `main`'s tip is still `T` immediately before the
  merge (item 2.6), and is the candidate immediately before approval (item 4).

The reason: preparation and the `T` reads ran on `T`; a bypass merge skips the up-to-date rule,
so a squash over an advanced base gives a tree the listener refuses (design §14.2); a commit
after the candidate fails the design §15.1 and §15.3 tip check, and `main` never moves back; and
a push to `main` cancels the candidate's quality run (`ci.yml`, `cancel-in-progress: true`;
D44). Once the tag exists, `main` advancing no longer strands the release (design §15.3) and the
listener refuses any non-release commit (L9), so pushes may resume; the records still wait.

**Failure rule.** After any failure or unreadable read before the item 2.6 merge, whatever items
2.1 to 2.5 did is undone (L13, "If 2.1 to 2.4 fail"). A moved tip means a writer was not stopped:
it is identified, stopped and recorded first. Then (a) if the fix needs no change on `main`, item
1 restarts inside the window, any 1.1 item 4 ruling kept with the window records; (b) if it needs
one (an L9 (b) ruling or re-seed that moves a baseline, a tree fix, a Section 7 incident), the
window ends as an abandonment: the window records are appended, the writers resume, the fix lands
through the normal gates, and item 1 restarts. After the merge, L13's rollback applies.

### 5.2 Abandoning the launch

Before L13, unwind in this order, reading back each step:

1. Remove the App's bypass (L12).
2. Disable the four workflows, then revert L9's files, the `ci.yml` record and its script
   included, through a policy change; read back that no workflow references either environment.
3. Delete the Pages configuration while nothing is deployed (L10); read back 404.
4. Delete the secret; uninstall and delete the App, which removes its keys; read back its absence.
5. Delete the two environments (L7), only after item 2's read-back.
6. Revert L1's admissions through a policy change.
7. The tag rulesets, the catch-all ruleset and immutability only restrict and may stay. If no tag
   ruleset was ever created (before L4), revert L3 (Section 10, Rollback), reading back the
   runbook header lines and `AGENTS.md` paragraphs as before L3. Otherwise the runbook stays
   retired and no release path exists: record that in the ledger and amend the `AGENTS.md`
   release paragraphs L3 changed to say so. A pre-launch release path then needs a reviewed
   amendment to the runbook and its pinning test and an operator ruling on the tag rulesets
   stating what protects existing tags; this specification provides neither, and runbook step
   1.4 forbids changing a ruleset to make the runbook apply.
8. If a venue or probe repository exists (6.6, 6.7), 6.6 Teardown, without waiting for K4 or the
   6.6 item 5 record.

If L13 had begun, its rollback comes first: before the tag, the release commit is reverted;
after a tag exists, the version is burned.

### 5.3 Later releases

This section opens once L13 item 5 has read back the Release (`v27.0.0`, or its replacement
under L13's rollback) published through the publisher, immutable and not a prerelease, and A1 to
A7 and A10 are recorded (A3 once L15 has run and each divergence is settled). From then on every
later release, an urgent fix included, takes L13's items 1 to 7, re-trigger and rollback with
only the differences below; no other release path exists (Section 10), and A8, A9 and A11 are
not required. A failed post-publication read (L13 item 6 or item 7's scan, or an L15 divergence
only a release can fix) is a 7.2 incident whose resume ruling may open this section for the fix
release before A3 or A8 is recorded. A9 and A11 stay pending while no tap serves a release or D2
is not APPLIED; items 1 and 4 govern that period, and L14 runs for whichever release the tap
first serves. P10's runbook carries the executable block.

1. Authorization: a release starts only on the operator's explicit instruction naming it
   (`AGENTS.md`, When a release happens), recorded before item 1 in a ledger entry of its own,
   which takes the launch entry's place in 1.1 item 3 and 5.1. While D2 is not recorded APPLIED,
   that instruction is also the one-release freeze lift (D2's 2026-09-26 amendment).
2. Version: before the ledger entry, a preliminary run of the item 2.2 block at the current tip,
   with the bump input the instruction names (the default, `--bump`, or `--macos-major NN` for a
   release moving MAJOR), its own scratch and no `--declared-version`, prints the version on its
   `release-prep: predicted next version` stderr line (the runbook's §1 item 2 method). The
   ledger entry and item 2.1's variable name it; item 2.2 runs the same bump input on `T` with
   `--declared-version` from the variable, failing closed if `main` moved the prediction. The
   version replaces `27.0.0` in every L13 item and P9, whose subject review reads `git log
   <highest reachable tag>..T`. The `v27.0.0`-specific checks (D18 steps (2) and (4) on macOS 27,
   Q9 (A)) give way to every release's: the full local canonical suite green on the exact
   candidate (`AGENTS.md`, When a release happens), and C1 and C2 (11.5).
3. Workflows: the listener and publisher stay enabled between releases (L13 item 7), so item 1
   normally reads them `active` with the advisory variable unset, and items 2.5 and 2.6's K1 do
   not apply; if item 1 reads them `disabled_manually` (after a rollback or a 7.2 stop that ran
   K1), items 2.5 and 2.6 apply as in L13. Item 1's blob read-back compares the bound set with
   its baseline; a difference is settled under L9 standing rule (b) before item 1 restarts.
4. Preflight: the design §15.1 tap check runs once D2 is recorded APPLIED and its tracked value
   is on (8.7).
5. Recovery: a failure after a deployment is recovered by the recovery workflow (6.1 K2, 6.2)
   while a published stable Release exists, and by 6.3 when none remains (after a 7.3 takedown,
   for example).
6. Variables: set again at items 2.1 and 4 and cleared at item 7 (Q11).
7. Distribution: after L13 item 7, L14 for the new Release (substeps 4 to 6 once 1 to 3 are
   recorded), its substep 6 scan covering the tap since the previous one; a failure leaves the
   prior formula served (8.6). The reconciler's state and last run are re-read (L15).
8. Burned version: the "Tag exists" rollback's item 2 entry is a new ledger entry of item 1's
   kind, naming the replacement version and, while D2 is not recorded APPLIED, carrying its
   one-release lift; it amends no other decision unless the burned release moved MAJOR. That
   rollback's item 1 recovery is item 5's; its item 3 entry restates the burned version's
   section; and its item 4 re-runs item 2's derivation, with the default bump where the burned
   release used `--macos-major NN`.

## 6. Publisher termination

### 6.1 Kill switch

The fastest way to stop publication, in this order, each step read back:

1. **K1.** Disable the listener and the publisher; read back `disabled_manually`. No new
   publisher run can then be dispatched. UI: the workflow's "Disable workflow".
2. **K2.** For each incomplete publisher run, reject its pending `github-pages` deployment if it
   is waiting, otherwise cancel it; list again until none is incomplete, within a bound, then
   force-cancel any still incomplete and list again. GitHub documents force-cancel as bypassing
   an `always()` condition on a job (whether it skips the restore steps is Observation (e)), so
   the operator reads each cancelled run's job and step record and recovers from what ran: a run
   stopped before the Pages deploy needs only the reconciler read; one whose restore and
   post-restore canary passed after the cancellation (R1's state) needs nothing more; any other
   is a failed-rollback state (design §15.3, §16), recovered after K1's and K2's read-backs by
   the recovery workflow, or by 6.3 when no published stable Release exists. A recovery run must
   reach `waiting` or `in_progress`, not stay `pending`: a concurrency group keeps one pending run
   and cancels it when another joins (Observation (c)). UI: "Review deployments", then Reject; or
   "Cancel workflow".
3. **K3.** Remove the App from L5's bypass list; read back an empty list. No `v*` tag can then be
   created by anyone. UI: the ruleset's bypass list.
4. **K4** (operator). Suspend the App's installation and read back its suspended state (a
   suspended App "cannot access resources owned by that installation account", GitHub Docs,
   "Suspending a GitHub App installation"; a minted installation token is not documented to die
   with its key and lives up to an hour, "Generating an installation access token for a GitHub
   App"). Delete the private-key secret from `github-pages`; read back secret count 0. Rotate,
   since GitHub refuses to delete an App's only key ("you will need to generate a new key before
   deleting the old key", "Managing private keys for GitHub Apps"): generate a replacement key,
   delete its downloaded file at once unstored (recorded value-free), delete the old key, and
   read back one key listed, its fingerprint not L8's. Deleting the old key is irreversible.
5. **K5.** Never delete either environment as part of termination: a deleted environment is
   recreated unprotected by the first workflow that references it (design §15.1). Keep the
   recovery workflow enabled so `/` can still be restored from published Releases.
6. **K6.** Disable the tap writer, close any open formula pull request and delete its branch;
   read back the writer `disabled_manually` and no open formula pull request. The install-check
   workflow stays enabled: the revert pull request of 7.3 and 8.6 needs its required check.

```sh
set -euo pipefail
for wf in publish-listener.yml publish.yml; do                                   # K1
  gh api -X PUT "repos/{owner}/{repo}/actions/workflows/$wf/disable"
  [ "$(gh api "repos/{owner}/{repo}/actions/workflows/$wf" --jq '.state')" = disabled_manually ]
done
incomplete() { gh api "repos/{owner}/{repo}/actions/workflows/publish.yml/runs" --paginate \
    --jq '.workflow_runs[] | select(.status != "completed") | .id'; }
ENV_ID="$(gh api "repos/{owner}/{repo}/environments/github-pages" --jq '.id')"
for RUN_ID in $(incomplete); do                                                  # K2
  if [ "$(gh api "repos/{owner}/{repo}/actions/runs/$RUN_ID" --jq .status)" = waiting ]; then
    gh api -X POST "repos/{owner}/{repo}/actions/runs/$RUN_ID/pending_deployments" \
        -F "environment_ids[]=$ENV_ID" -f state=rejected -f comment='kill switch'
  else
    gh api -X POST "repos/{owner}/{repo}/actions/runs/$RUN_ID/cancel"
  fi
done
for _ in $(seq 30); do [ -z "$(incomplete)" ] && break; sleep 10; done
for RUN_ID in $(incomplete); do                                                  # K2 bound reached
  gh api -X POST "repos/{owner}/{repo}/actions/runs/$RUN_ID/force-cancel"        # then read its steps
done
for _ in $(seq 30); do [ -z "$(incomplete)" ] && break; sleep 10; done
[ -z "$(incomplete)" ]                                                           # K2 read-back
# K3: the tag-creation ruleset is the target-tag ruleset whose rules include `creation`.
for id in $(gh api "repos/{owner}/{repo}/rulesets" --paginate --jq '.[] | select(.target == "tag") | .id'); do
  if [ "$(gh api "repos/{owner}/{repo}/rulesets/$id" --jq 'any(.rules[]; .type == "creation")')" = true ]; then
    printf '{"bypass_actors":[]}' | gh api -X PUT "repos/{owner}/{repo}/rulesets/$id" --input - > /dev/null
    [ "$(gh api "repos/{owner}/{repo}/rulesets/$id" \
        --jq 'if has("bypass_actors") then (.bypass_actors | length) else "absent" end')" = 0 ]
  fi
done
```

K1 to K3 and K6 are reversible; K4 is not, for the key. **Undo**, only on the operator's ruling
(7.2 item 6), in this order, each read back: K4 by generating a new private key on the same App
(it then holds two), storing it as L8 states, deleting the unstored replacement, reading back one
key listed with the new key's fingerprint, and only then unsuspending the installation, then L8's
Check (L8 in full only if the App was deleted); K3 by L12's add and its Check; K1 by enabling
both workflows, read back `active`, only while the advisory variable reads back unset (the
listener then refuses everything) or as L13 item 2.5's last act; K6 by enabling the tap writer,
read back `active`, once the served formula reads back as the version the operator intends. K2
leaves nothing to undo.

### 6.2 Run-level termination and restoration

Design §15 requires a rehearsed termination after Pages deployment and before Release
publication proving that the prior site is restored by the approved job (R1) or, on runner loss,
by the manual reconciliation workflow (F1); design §15.3 restores in-job after a canary or
confirmed publication failure (R0, R2) and requires the manual path rehearsed for every
failed-rollback state. Deploy to publish takes seconds, so each case is driven by the venue fault
switch (6.6), never timing, on its own synthetic candidate over a published prior site (S2).
Every recovery run follows K1 and K2 (6.1), its result recorded. For F1 to F4 and F5b the
reconciler must also alert while `/` is wrong and be green after recovery; in F5a `/` is right
throughout, so it stays green and recovery changes nothing.

| Case | Injection in the venue | Passes when |
|---|---|---|
| R0 restore succeeds | the canary forced to fail after the deploy | the `if: always()` restore redeploys the prior site, the post-restore canary verifies it, the Release stays a draft |
| R1 ordinary cancellation | cancel (not force-cancel) during the post-deploy pause, nothing suppressing the restore | the step record shows the `if: always()` restore ran after the cancel and the post-restore canary verified the prior site (Observation (f)); the Release stays a draft |
| R2 confirmed publish failure | the publish step replaced by a stub reporting a failed call; the real re-read returns `draft: true` | the in-job restore redeploys the prior site, the post-restore canary verifies it, and the job fails |
| F1 runner loss | force-cancel during the post-deploy pause, the fault switch skipping the restore deploy step as in F2 whatever force-cancel does to steps; the step record shows whether the first `if: always()` restore step started (Observation (e)) | no restore deploy ran; the operator's recovery run restores `/` to the highest published stable Release |
| F2 cancellation before the restore runs | cancel during the pause, the fault switch ending the restore step before it writes, standing in for a cancellation that ends the job first | as F1 |
| F3 Pages API failure during restoration | the canary forced to fail, and the restore step's Pages deployment request made to fail after its artifact lookup succeeds (for example, the deploy action handed a token without Pages access); if no such switch works, an artifact-lookup failure, recorded as an approximation and a known gap | the restore step fails; as F1 |
| F4 failing restore step | the canary forced to fail, and the restore step made to exit non-zero after the canary and before its deploy, with no cancellation | the record shows the candidate served at `/` before the restore failed; as F1 |
| F5a inconclusive re-read, published | the publish call runs; the re-read stubbed inconclusive past its retries | the job writes nothing further; recovery reads the Release as published and keeps the candidate site |
| F5b inconclusive re-read, not published | the publish call skipped; the re-read stubbed inconclusive | the job writes nothing further; recovery reads the draft and restores the prior site |
| N1 recheck refusal | no fault switch; one synthetic candidate per binding, each approved with exactly that binding wrong: the SHA variable naming another commit; the version variable naming another version; venue `main` advanced by a venue commit during the wait; under Q4 (A), the C2 binding variable | the approved job's design §15.3 post-approval recheck (§15.1's binding assertion for the two variables, its tip assertion for the advanced `main`, the seventh assertion under Q4 (A)) refuses before the tag create |
| N2 non-release candidate | no fault switch; the advisory variable set: (a) a same-repository pull request whose head commit subject is `chore(release): v` followed by the variable; (b) a commit with that subject pushed to venue `main` by bypass, with no pull request; (c) a release-preparation pull request squash-merged by bypass after a venue commit advanced its base | (a) its `pull_request` quality run completes and nothing is dispatched; (b) the listener or the preflight refuses (no merged pull request); (c) the listener refuses on tree inequality |

In N1 and N2 no tag or draft exists, `/` is unchanged and the reconciler green, and each pushed
candidate is then reverted per L13's "before the tag" rollback. In every case but F5a, N1 and N2
the Release stays a draft and the tag exists only at its candidate.

### 6.3 First-release Pages disable

On a first release the prior site is the empty sentinel, and recovery after a deployment is the
operator disabling Pages with the operator's own credentials (design §16). With a site deployed:
`DELETE repos/{owner}/{repo}/pages`; read back 404 and `has_pages` false; poll the site root up to
15 minutes until it answers 404, recording the elapsed time (a page served at the bound is a
failure); then L10 again with the `github-pages` re-read, polling the site root the same way
before any new deployment. A site root not 404 after a re-enable means Pages is disabled again at
once, read back 404 and kept disabled pending the operator's ruling (the probe and S1 instead
record the served state, Observation (d)). A re-serve of the previous deployment, or a page past
the 15-minute bound, means this recovery does not hold: in the probe L3 does not start, in the
venue L11 stops, and continuing needs an operator ruling and an amendment to this specification. A
re-enable after a privacy containment waits until the next deployment is known clean (7.3).

### 6.4 Attribution and identity tests

Each runs in the venue (6.6); T1 and T3 to T5 run first in the probe before L3 (6.7). Any test
but T2 failing, there or in the venue, stops the launch.

1. **T1.** A publisher run dispatched by the listener with the built-in token: record `actor` and
   `triggering_actor`, and that the operator can approve its pending `github-pages` deployment
   under prevent-self-review (design §14.2).
2. **T2 (recorded, not launch-blocking).** The operator re-runs, through the UI, a
   listener-dispatched publisher run whose approved job failed: record `actor`,
   `triggering_actor` and whether GitHub offers the operator the approval. This answers the
   attribution question only: design §15.1 and §19 route a post-tag resume through a listener
   re-run of the original publisher run, which L9 lacks (L13's re-trigger is a new run, before
   the tag only), so post-tag recovery is reconciliation and a new version (L13 rollback) until a
   policy change adds that path (Section 13).
3. **T3.** A run dispatched by the operator stops at the environment, cannot be approved by the
   operator, and is rejected: the non-escalation claim of design §14.2.
4. **T4.** An App installation token is refused every branch write; neither L6's catch-all nor
   the `main` ruleset lists the App (design §7.3). The operator first pushes, by L6 bypass, a
   branch with one commit on `main` changing no workflow file, so the missing `workflows`
   permission cannot be what refuses (recorded; deleted by the same bypass afterwards). The
   token then attempts (1) a new branch at `main`'s tip, (2) moving the operator's branch to
   `main`'s tip with `force` true, as a non-fast-forward would otherwise be refused for that
   alone, and (3) fast-forwarding `main` to the operator's branch; each status code and refusing
   ruleset is recorded, L6 for (1) and (2).
5. **T5.** The App, without the `workflows` permission (design §7.3), can create a tag ref at a
   candidate whose history includes workflow-file changes.
6. **T6.** An App installation token is refused an update and a delete of a `v*` tag the App
   created whose Release is still a draft, such as an S2 F-case tag, so immutability cannot be
   what refuses (9.2); the refusing rule is recorded (L4 has no bypass actor; design §7.3).

No publisher makes the T4 and T6 calls, and the App's key is only a `github-pages` secret (L8),
so the operator makes them, after T5 (in the probe, T5's too), from the operator's own terminal
(1.1 item 6): generate a second private key on the rehearsal or probe App, kept outside every
tree; mint an installation token (a JWT signed with it, then `POST
app/installations/{id}/access_tokens`); make the calls with `gh api`, recording each status code
and refusing rule; then delete that key and read back one key listed. A T4 or T6 call that
succeeds is a stop.

### 6.5 Where and when it is rehearsed

- In this repository: K1 and 6.3 without a deployment (disable and re-enable Pages, re-read
  `github-pages`, the 404 polls) at L11, and K3 at L12, each recorded.
- In the venue of Q2: the 6.7 probe (after A1 and P4, before L3); after L9, K2, K4, R0 to R2, F1
  to F5b, N1, N2, 6.3 with a deployment, T1 to T6, the Observation and the venue Release checks
  of S1 and S2, in the order smoke, S1, S2 (6.6), with K4 the last act before Teardown. K4 is
  never rehearsed in this repository, where it is irreversible.

### 6.6 The rehearsal venue (Q2 option A)

The venue publishes real Releases, binaries, notes, attestations, logs and a Pages site under the
operator's account, so it is reserved to the operator (1.1 item 6) and covered by 11.6. Setup,
each item by the operator and read back:

1. After A1 is recorded and the launch entry (P4) exists, before L3, for the probe (6.7), on its
   own instruction: a public repository owned by the operator's account (for example
   `OWNER/apple-cli-rehearsal`), described as a rehearsal, holding this repository's tree at a
   recorded commit as a fresh history. `.github/dependabot.yml` stays (the venue's `Supply-chain
   policy` requires it, the manifest lists it); Dependabot security updates are turned off there,
   and the operator closes every venue Dependabot pull request unmerged.
2. Before the probe, apply there a `main` ruleset of P1's shape, L2 and L4 to L7, L8 with a
   separate rehearsal App (fixed, non-personal name, its own key), and L10's Action with its
   Pages and environment reads (no reconciler exists yet). After L9: item 3, L10 in full (the
   probe leaves Pages disabled; a rebuilt venue runs no probe and applies L10 only here) and
   L12. Venue versions start at a MAJOR no real release can reach (`--macos-major 90`, then the
   default bump; a rebuilt venue starts above every MAJOR an earlier venue published), every
   venue Release title is marked as a rehearsal, and each venue candidate is preceded by a venue
   commit adding an `[Unreleased]` entry.
3. After L9 lands, one venue commit brings the venue's tree to the tree of a recorded commit of
   this repository at or after L9's, plus only this enumerated diff, reviewed and recorded
   value-free before the smoke. The record names that source commit and, for every bound-set
   file, two blobs: this repository's at that commit and the venue's after the diff. The diff:
   - one venue-only repository variable, the fault switch `VENUE_FAULT_CASE`, naming a 6.2 case,
     keyed into exactly these publisher edits: a step added after the Pages deploy, failing in
     the canary's place under R0, F3 and F4 and sleeping (the post-deploy pause) under R1, F1 and
     F2; an `if:` term skipping the restore deploy step under F1, F2 and F4, plus a step heading
     the restore sequence that exits non-zero under F4; a `with:` change handing the restore
     deploy step a token without Pages access under F3; an `if:` term skipping the publish step
     under R2 and F5b, with a stub reporting a failed call in its place under R2; and an `if:`
     pair swapping the post-publish re-read for a stub reporting inconclusive under F5a and F5b;
   - the venue manifest's publisher blob SHA;
   - the venue scanner's admission of exactly those edits, each only with the fault switch in
     its condition or expression (the F3 change is an L1 item 6 and 7 construct); this
     repository's scanner keeps refusing any reference to it (L1);
   - the repository name in the CHANGELOG manual links and `mkdocs.yml` (the workflows and
     bound-set scripts take it from the run context, L9);
   - the rehearsal Release-title marker and the synthetic MAJOR in the line policy;
   - every `Tests/automation` and policy-script expectation those items change.

   The design §15.1 tap check stays off through its tracked value (8.7), so its on path is not
   rehearsed, a known gap.
4. Smoke, once the venue's `quality / required` is green on the item 3 commit: one venue
   candidate's listener dispatch reaches the environment wait and is rejected. `release_prep.py`
   refuses to prepare over that untagged release commit (exit 3), so it becomes S1's first
   candidate: the operator re-runs its quality push run, recording Observation (a), and if no
   listener fires, reverts it per L13's "before the tag" rollback and S1 prepares a new one. A
   smoke re-run after S1 (L9 standing rule (b)) leaves such a commit too, reverted that way or
   used as the next S2 candidate, the choice recorded.
5. Run record: for every venue run of the four workflows, and every venue quality run whose
   record a listener read, the operator records value-free before Teardown (P10's run-record
   block over the venue's full run listing) its ID as a salted commitment, its `head_sha`, its
   workflow path, and `git rev-parse <head_sha>:<path>` in a venue clone for every bound-set
   file, each blob equal to the venue blob of the seeding (item 3 or a re-seed) last preceding
   that run. Just before Teardown, each of the four workflows' recorded runs number its
   `total_count` in the venue listing (quality runs are not counted). The record enters the
   readiness evidence before Teardown starts; L13 item 1 compares against it.

Before each venue approval, C1 passes in the copied preflight and the operator records C2 for
that venue artifact, out of tree (11.5). Venue Releases are rehearsal publications (Q2).

Scenarios:

- **S1, first release.** Before item 4's quality re-run (or S1's own first candidate, if that
  re-run fired no listener), the operator sets `VENUE_FAULT_CASE` to `R0`, so the canary fails
  after the deploy. It passes when the in-job restore deploys nothing and the run fails with
  L9's first-release result; 6.3 brings the site root to 404 within its bound; and the
  reconciler alerts while the candidate is served and is green afterwards. Then the recovery
  workflow, dispatched against the empty published set, refuses and writes nothing. Then, with
  the switch cleared, a clean first release under a new version leaves a published prior site.
  On that Release the operator runs 9.3, the complete 9.4 block with C2's record for its
  candidate, and 8.3 checks 1 to 6 from the operator's terminal, and records, value-free, the
  attestation's subject-list shape and which object the tag subject digests (9.4).
- **S2, release over a published prior site.** R0 to R2, F1 to F5b, N1 and N2 (the advisory
  variable set), then T1, T3 and T5, each on a new synthetic candidate; T2 re-runs a failed run
  and rejects its deployment once recorded; T4 and T6 follow from the operator's terminal (6.4).
  On F5a's published Release, 9.3 and the 9.4 block run again, matching S1's recorded shape.
- **Observation**, each item recorded: (a) whether re-running a quality push run triggers the
  listener again, and the resulting publisher run's `actor`, `triggering_actor` and approvability
  under prevent-self-review (if not, L13's re-trigger is dropped); (b) that no listener or
  publisher read in any venue run failed for an absent field, confirming the 6.7 table (a
  failure stops, as 6.7 states); (c) whether a pending run in the shared concurrency group is
  cancelled when another joins (K2); (d) whether re-enabling Pages after 6.3 serves the previous
  deployment again, and how long edge caches serve it after the delete; (e) whether force-cancel
  skips an `if: always()` step inside a running job (F1; K2), record-only, since F1's fault
  switch skips the restore anyway; (f) whether an ordinary cancel runs a step-level
  `if: always()` step (R1; K2). Items (d) to (f) repeat the probe's (6.7).

Teardown (operator), after K4 and once the item 5 record is in the readiness evidence: an 11.1
scan of 11.2's minimum surfaces applied to the venue, plus its deployment and deployment-status
records and Pages, since deletion is not shown to remove every copy (7.3, Known limits); delete
the rehearsal App (removing its keys) and the venue, reading back the App's absence and the
venue's API answering 404. Only value-free results enter this repository. GitHub refuses tags
once associated with immutable releases even in a new repository of the same name ("Immutable
releases"), so a rebuilt venue uses a new synthetic MAJOR (L9 standing rule (b)).

### 6.7 The probe (before L3)

Every launch-stopping fact that needs neither this repository's L4 to L9 files nor the App's
tag-creation bypass (L12) is settled before L3, so it cannot first appear inside the Section 10
window. After A1 is recorded and the launch entry (P4) exists, with Q2 ruled, and before L3, the
operator runs the probe in the venue under 6.6 item 2's pre-probe controls or, if Q2 is not (A),
in a throwaway public repository set up as 6.6 items 1 and 2 state (a probe App per L8) and,
once the results are recorded, torn down by 6.6 Teardown without K4 or an item 5 record. Probe
workflow paths are disjoint from L9's four. The operator:

1. opens one pull request, leaves a comment review on it (under Q3 (A), the reviewer leaves an
   approving review instead), and merges it by bypass of the `main` ruleset, so review records
   (`state`, `commit_id`, reviewer) and a rule-suite bypass record exist;
2. lands a read-only probe workflow on `push` whose jobs hold exactly L1 item 3's read scopes for
   the listener and for the publisher's preflight and approved jobs. One run uploads a stand-in
   quality-run record artifact and a later run downloads it by run ID with the listener's
   scopes. The jobs attempt every read of design §14.2 (listener), §15.1 (preflight) and §15.3
   (recheck) against those objects, recording value-free, per read and per scope set, the status
   code, whether the object exists, and whether the governed field is present and non-null: the
   token table;
3. lands three stand-ins: a `push` workflow standing in for the quality run; a `workflow_run`
   listener holding `actions: write`, which dispatches with its built-in token a publisher whose
   one job waits on `github-pages` and, once approved, deploys a fixed placeholder page with the
   two Pages Actions; and a dispatched job that sleeps and then runs `if: always()` steps. With
   them the operator records T1 (6.4) on the listener-dispatched run; T3, dispatching the stand-in
   publisher directly, being refused its approval and rejecting it; Observation (d), running 6.3
   after that deployment, then disabling Pages and reading back 404 and `has_pages` false; and
   Observations (e) and (f), force-cancelling one run of the sleeping job and cancelling another;
4. from the operator's terminal, under one token minted from a second key of the rehearsal or
   probe App (6.4, last paragraph), records T5, creating a tag ref outside `refs/tags/v*` (so no
   tag ruleset applies) at a commit whose history includes item 3's workflow changes, and T4 as
   6.4 states; the tag, T4's branch and the key are then deleted, each read back;
5. reads back the L6 ruleset there with Dependabot as an exact `always` bypass actor (the L6
   Check);
6. records the results in the readiness evidence, then removes the probe workflows.

Each workflow text is P10's reviewed runbook block, never landed under this repository's
`.github/workflows/`, its SHA-256 recorded with the results; the venue's copied scan refuses
them, so its `quality / required` is red until item 6. L3 does not start, and continuing needs an
operator ruling and an amendment to this specification, if T1, T3, T4 or T5 fails; Observation
(d) shows a re-serve or a page past 6.3's bound; Observation (f) shows an ordinary cancel not
running a step-level `if: always()` step; Dependabot is not selectable; or the table contradicts
L1 item 6. Observation (e) is record-only. The table fixes, before L9, which reads the listener
and publisher make and which are the operator's (L1 item 6; Section 13). L11 repeats T1, T3 to T5
and the Observations with the real files; a contradiction there, or an Observation (b) failure,
stops L11: the table is corrected, the design re-amended (Section 13), L9's files changed under
the L9 standing rule, and the venue rehearsal re-run.

## 7. Operator-only incident runbook for published surfaces

The repository's immediate-redaction rule covers `main` only, and an immutable tag or Release
cannot be fixed forward (design §15). This section covers what lies beyond `main`.

### 7.1 Who acts, and what is never automated

The operator decides every containment step and executes it, or instructs an agent in session
naming the exact object (D21, D37); 1.1 item 6's acts stay the operator's. An agent may detect,
read back, prepare value-free evidence and draft the ledger text, never acting on its own
judgement or on relayed text. No workflow performs a containment write (design §16).

Never automated: deleting or editing a Release, an asset or its notes; deleting or moving a tag;
disabling or deleting a ruleset; disabling or reconfiguring Pages; deleting runs, logs, artifacts
or caches; editing or deleting pull-request text, reviews or comments; deactivating or deleting
deployment records; changing visibility; reverting, disabling or removing the tap formula;
rewriting history or force-pushing; filing a GitHub Support request; deleting an App key or the
App.

### 7.2 Common sequence

1. Stop: K1 to K3, K4 if a credential may be involved, and K6 if the tap is affected (6.1).
2. Record: a new `HUMAN-DECISIONS.md` entry, value-free (class, surface, counts, digests, never
   the value), before any destructive action (`AGENTS.md`: stop and tell the operator).
3. Redact at HEAD on `main` wherever the data is in the tree.
4. Contain each affected surface (7.3), each destructive call on the operator's ruling and read
   back.
5. Verify with a scoped value-free re-scan of the affected surfaces, a pull request's timeline,
   issue events and edit histories included, using `git grep -P` and Python `re`, cross-checked
   with system `grep`; a `git grep -E` negative proves nothing (`AGENTS.md`). A NOT READ surface
   keeps the incident open.
6. Resume publication only on the operator's ruling; where a version was burned, a new candidate
   carries a new version under the ledger rulings of L13's rollback. For a failed post-publication
   read of the launch, the ruling may open 5.3 for the fix release before A3 or A8 is recorded.

Items 3 and 5 apply only where personal data is involved; item 2 always records the failed
check, value-free. Item 4 applies whenever a published surface is wrong or unverified (a 9.4
fourth-part difference, a failed attestation or asset verify, wrong content at `/`): for a
Release it at least marks it a prerelease, applies K6, moves the tap off it and puts deletion to
the operator's ruling (7.3); then, as for `/` alone, it restores `/` with the recovery workflow,
or 6.3 when no published stable Release remains. A failure leaving no wrong published state (a
read that could not run, an L15 settings divergence) takes items 1, 2 and 6 only. A red
reconciler is an incident only when its result is the alert, not "not read" or "publication in
flight", and persists on a re-dispatch; a run past its job's bound, or a publisher run waiting at
the environment while `/` reads wrong, is first stopped by K1 and K2 (6.1).

### 7.3 Per surface

**Releases and assets.** Detection: the 11.5 checks, 9.4, pre-push and round scans, a public
report.
- Notes body: editable on an immutable release; whether GitHub keeps the prior text readable is
  not established, so edited text is treated as possibly retained. The same data in the released
  CHANGELOG section is redacted at HEAD too: the immediate-redaction rule overrides the
  never-hand-edit rule for released sections (`AGENTS.md`, amended at L3), and the incident's
  ledger entry records both edits.
- Assets cannot be changed or deleted while the Release exists (9.2); the only takedown is
  deleting the Release, which is irreversible and burns the version.
- Interim reduction: mark the Release a prerelease, which an immutable release permits; it then
  leaves the published-stable set that site assembly and the tap read (design §16; 8.3), while
  its assets stay downloadable.
- Order: move the tap off the Release first; then the operator deletes it with the operator's
  own credentials (1.1 item 6) and reads back the Release ID and both asset download URLs
  answering 404 (D34 precedent).

**Tags.** Protected by L4 alone until their Release is published, then also by immutability;
the publisher sets tag message and tagger to fixed, non-personal values. To delete one: delete
its Release; the operator disables L4 (not deleted), deletes the tag with the operator's own
credentials, re-enables L4 and reads it back; the name stays burned. A commit reachable only
through such a tag stays reachable until then; rewriting `main` is the separate design §19
decision (`--force-with-lease`, D46's ruleset disabled first while it exists).

**Pages.** Detection: the reconciler, the Pages canary, a scan of the assembled site, a report.
Fastest: disable Pages, taking the whole site offline (6.3). When the data is in one Release's
manual: mark that Release a prerelease or delete it, then run the recovery workflow, which
rebuilds `/` and the archives from the remaining published stable Releases (and cannot remove
content still in one of their manuals, design §16), or disable Pages when none remains (it then
refuses, L9). Re-enable through L10 with the `github-pages` re-read only once the next
deployment is known clean, the site root answering 404 after the delete and the re-enable (6.3).

**Homebrew tap.** Detection: the tap's 8.3 checks, 9.4 failures, a report. Containment, in the
tap repository, by the operator: K6, then revert the formula to the prior served version through
a pull request, or mark it disabled with Homebrew's formula-disable mechanism; a disabling pull
request fails the required install check by design and merges by the operator's bypass, which
the bypass log records. The tap's history keeps the old formula; installed copies and client
download caches remain. Once D2 is APPLIED, either containment makes the design §15.1 tap check
refuse the next release, so 8.7's switch-off procedure applies first.

**Workflow logs, runs and artifacts.** Detection: value-free scans of run logs (D21), the run
listing (D37) and check-suite objects; publisher logs print only commit IDs, versions and
digests by construction. Containment: delete logs, runs or artifacts through the Actions API on
the operator's ruling (D21, D37) and read back 404. Limits: deleting a run removes the listing,
not the commit (D37, D38); check suites from third-party Apps survive (D37); the public Events
feed lists commit IDs until they age out (D37); job logs expire on retention (D43).

**Pull-request text** (this repository and the tap). Detection: L13 item 7's and L14 item 6's
scans, a report. Containment, on the operator's ruling: edit the body or a review's body and
delete each prior revision from its edit history in the UI (GitHub Docs, "Tracking changes in a
comment"), or delete the comment or review comment; read back the edited text, each prior
revision showing no content (its editor and time stay listed, per the same page), and each
deleted comment answering 404. In this repository, an edit of a title or body starts `ci.yml`
and `governance.yml` runs (`edited`), whether or not the pull request is open: 7.2 item 5's
re-scan reads those runs' objects and logs, and any run the edit cancelled; on a pull request
whose head predates D41's commit the edit can add a log copy under D43, and one the re-scan finds
moves 11.4's date (D43's 2026-10-04 amendment). A title cannot be contained this way: an edit
leaves the old title in the `renamed` event (`rename.from`, issue-events and timeline APIs),
which the repository cannot delete, nor can an owner delete a pull request; either needs GitHub
Support (7.1), the title staying under Known limits until Support confirms removal and the
`renamed` events read back value-free after any title edit. After a title edit, in either
repository, the re-scan also reads the display title of every listed run (11.2), not only runs
linked to the edited pull request, since a run's `pull_requests` field can be empty (a closed
pull request, or one whose head is in a fork); a run that keeps the old title is deleted on the
operator's ruling and read back 404 (D37). The ruling weighs any evidence the run carries,
recorded value-free before the deletion with any per-run identifiers, a kept run's included,
kept in a private manifest outside the repository (as D37 kept), and a run it keeps is
recorded, value-free, in the incident's ledger entry (7.2 item 2). A title or body that became
a commit message is history (Tags; design §19). Limits: notifications already sent, the Events
feed (D37).

**Deployment records** (both environments). Detection: L13 item 7's scan. Containment, on the
operator's ruling: a deployment still serving `/` is contained under Pages first; then set the
deployment inactive with an `inactive` status, delete it, and read back 404. Limits as for
pull-request text. Both procedures are checked against GitHub's REST and Docs references when
P10 is prepared.

**Actions caches.** Delete the cache by ID or key and read back its absence. Cache contents are
not inspected through the API here, so a suspected cache is deleted, not scanned.

**Visibility.** Re-flipping to private is D17's recorded rollback for repository surfaces. Its
effect on Pages, on public Release downloads and therefore on tap installs is not established
here and is read at the time.

**Known limits.** Beyond this repository's controls: forks, clones, mirrors, search-engine and CDN
caches, third-party archives and check suites, and GitHub's by-ID serving of unreachable objects
(D19, D38, D47), including the commits the repository's public Activity view lists and the history
their parent links reach, so a history rewrite does not on its own remove what it replaced; the
deleted branch names that view shows (D50; whether GitHub Support removes Activity entries is not
established); a pull request's prior title in its `renamed` event and the pull request itself,
until GitHub Support removes them; and, until they age out, the account's public Events-feed
entries for the venue's and any probe repository's pushes, pull requests and Releases, which
deleting the repository is not shown to remove (D37).

## 8. Homebrew distribution boundary

### 8.1 Tap identity

A separate public repository owned by the operator's account, `OWNER/homebrew-tap`, holding the
formula `apple-cli`, installed as `OWNER/tap/apple-cli` (Q6), the `OWNER/tap/<cli>` convention
of `docs/versioning-policy.md` §6.4. A versioned formula (`apple-cli@26`) appears only if a
maintenance line is ever cut (`AGENTS.md`, Branch model).

### 8.2 Writer, token scope and storage

The only writer is a workflow in the tap repository, using that repository's own built-in token,
in proposal-branch mode (Q7 default):

- A verify job with `contents: read` and `attestations: read` downloads the target Release's
  assets, runs 8.3 checks 1 to 6, and outputs only two typed, shape-validated values: the
  archive's download URL and its SHA-256. Whether a job token reaches another public
  repository's attestations is first shown at L14 item 4; a refusal there serves nothing (8.6),
  and the operator's terminal has run the same checks on a venue Release (6.6, S1).
- A propose job with `contents: write` and nothing else receives only those two outputs, renders
  the formula from a fixed template in the workflow, executes nothing from the archive, and
  pushes a proposal branch. The operator opens the pull request and merges it.
- The install check (8.3) is a separate workflow, whose jobs declare `contents: read`. On
  `pull_request` it runs the pre-merge install on every pull request, exiting successfully with a
  value-free "no formula changed" when the diff touches no formula file, so a required check
  never waits on a path-filtered workflow, and with "formula removed" when the diff only deletes
  formula files (L14 item 5). On `workflow_dispatch` it runs the post-merge install, which the
  operator dispatches after merging a formula pull request.

The tap keeps "Allow GitHub Actions to create and approve pull requests"
(`can_approve_pull_request_reviews`) false, GitHub's default for a new personal repository, so
its token can neither open nor approve a pull request (design §18 step 4). A ruleset on its
default branch requires a pull request with no approval count (the operator works alone) and
the install check as a status check, blocks force push and deletion, and names the operator's
exact user as sole bypass actor: the token cannot write the default branch, only the operator's
merge serves a formula, and a merge without a passing install check shows in the bypass log.
The tap also sets `sha_pinning_required` true, `allowed_actions` to a selected, reviewed
allowlist, `default_workflow_permissions` read, and fork pull-request approval for all external
contributors. A tap workflow changes only through a pull request the operator merges after the
independent automated review control-plane changes receive here (code, security and critic;
`AGENTS.md`, Commits + review). L14 reads all of this back.

Nothing in this repository can write to the tap: no secret, variable, deploy key, personal
access token, App or `repository_dispatch` for it exists, and L1's scan refuses a checkout of
another repository and any token or secret for one (A10); such a credential would widen the
approved job beyond design §15.2 or need a third environment literal, which design §15.3
forbids. The tap reads only public data, and only a published, immutable, attested Release, so
untrusted candidate input cannot reach the write (design §15).

### 8.3 Asset and checksum binding

The tap writer proposes a formula only when every check holds for the target Release; any
failure refuses, with value-free output:

1. The Release reads back `draft` false, `prerelease` false and `immutable` true; its tag matches
   `^v[0-9]+\.[0-9]+\.[0-9]+$`; it is the numerically highest published stable Release, so the
   formula never moves backwards.
2. It carries exactly two assets, `apple-vX.Y.Z-macos-arm64.tar.gz` and
   `apple-vX.Y.Z-macos-arm64.tar.gz.sha256`.
3. `gh release verify` succeeds for the tag and `gh release verify-asset` for both downloaded
   assets, with `gh` 2.93.0 or later asserted first (9.4).
4. The checksum file is exactly one line, sixty-four hex digits, two spaces and the archive name,
   and the digest equals the archive's SHA-256.
5. The tag ref names a tag object whose target is a commit reachable from this repository's
   `main`.
6. The archive has one regular member `apple`, user id 0, group id 0, empty owner and group names (D18
   step (4)), and no PAX key other than `mtime` (the runbook's recorded packaging check;
   evidence §3a observed none at all).
7. The formula's `url` is that asset's download URL for the tag and its `sha256` the archive
   digest. Nothing comes from Release-notes text.

Before merge, a read-only job on a clean hosted macOS runner installs the formula as the pull
request head defines it and checks that `apple --version` prints `X.Y.Z`; Homebrew refuses
formula files given as paths by default (`HOMEBREW_FORBID_PACKAGES_FROM_PATHS`), so the job taps
the checked-out head under the tap's name or uses `brew test-bot`, the form fixed and tested
when the check is written. After merge, the post-merge job (8.2) runs
`brew install OWNER/tap/apple-cli` on a fresh hosted macOS runner (the fully qualified name
trusts only that formula, Homebrew Tap Trust, since 6.0.0) and checks `apple --version` and that
`brew info --json=v2` reports the same version and checksum. Whether the installed binary is
byte-identical to the archive member is recorded; Homebrew re-signs only binaries it patched, so
a difference is a stop-and-review item, not a silent pass. A failure reverts the formula (8.6).

### 8.4 Formula content: the floor is not MAJOR

The formula's macOS floor is `Package.swift`'s technical floor `.macOS(.v14)`, Homebrew's
`sonoma`, never 26 or 27 to encode the support policy; it requires arm64, the only artifact
built. MAJOR, 27 here, names the newest macOS validated and is not a deployment minimum
(`AGENTS.md`, Versioning; design §4.1); the caveats state the policy plainly (design §4.1).
Illustrative only, never executed:

```ruby
class AppleCli < Formula
  desc "JSON-first CLI for Messages, Mail, Contacts, Notes, Calendar and Reminders"
  homepage "https://github.com/OWNER/apple-cli"
  url "https://github.com/OWNER/apple-cli/releases/download/vX.Y.Z/apple-vX.Y.Z-macos-arm64.tar.gz"
  sha256 "ARCHIVE_SHA256"
  license "MIT"
  depends_on arch: :arm64
  depends_on macos: :sonoma
  def install
    bin.install "apple"
  end
  def caveats
    <<~EOS
      Tested and supported on macOS 26 and macOS 27. It installs on macOS 14 to 25,
      which are untested and unsupported.
    EOS
  end
  test do
    assert_match "X.Y.Z", shell_output("#{bin}/apple --version")
  end
end
```

### 8.5 Write mode and trigger

Default until Q7 and Q8 are ruled: proposal-branch mode (8.2), triggered by the operator's
dispatch in the tap repository after the Release is published. A push by the tap's own token
starts no workflow, and the pull request the operator opens runs the tap's checks as the
operator's. Design §15.3's last step, "trigger the separately governed distribution update", is
then an operator action, not a publisher action (Section 13). A scheduled poll is never the only
trigger, because GitHub disables a public repository's scheduled workflows after 60 days without
repository activity.

### 8.6 Failure recovery

Design §19: a failed distribution update leaves the GitHub Release and Pages valid and the prior
package served; retry it. A failing check leaves the formula unchanged. A wrong formula that
landed is reverted in the tap through a pull request (7.3). Nothing in this repository changes.

### 8.7 What ends the D2 release freeze

D2 holds the freeze until the tap actually serves `brew install apple-cli`. That literal command
fails on a clean machine, because the short name does not resolve until `OWNER/tap` is tapped
and, since Homebrew 6.0.0, a non-official tap or formula must be trusted first (Homebrew Tap
Trust), so the condition needs restating (Q5). Proposed: on a clean macOS environment,
`brew install OWNER/tap/apple-cli` succeeds, `apple --version` prints the published version, and
the served formula's URL and SHA-256 equal the latest published Release's archive URL and
digest. The result is recorded in the readiness evidence; the operator then records D2 APPLIED
and the freeze ended, and the `AGENTS.md` freeze paragraph changes in the same governance change.

`v27.0.0` is released under D17 ruling 2's one-release lift, before any tap serves anything.
Design §15.1's tap check applies "where the freeze's own trigger applies" and checks the tap
against a previously published release, so it runs only once D2 is recorded APPLIED, read by the
publisher from a tracked control-plane value that the governance change above switches on
without touching the four workflows. Before then, a release following one the tap never served
(a `v27.0.0` whose L14 failed, say) proceeds under its own one-release lift (5.3 item 1). Ending
the freeze removes a hold, not the per-version authorization: every later release still needs
the design §14.2 and §15.1 variables.

After D2 is APPLIED, the check refuses every release while the tap serves anything but the
previously published release, as after a failed tap update (8.6) or a 7.3 tap containment. The
way out is never an ad hoc edit: a reviewed governance change, landed outside any candidate
window and before the next release's L13 item 1, switches the value off, and that release's
ledger entry (5.3 item 1), and the incident's entry where 7.3 applied, record the check as not
applicable and why; a later reviewed change switches it on once L14 item 5 records the tap
serving the highest published stable Release.

## 9. Release immutability and release-level attestation

### 9.1 Enabling

Step L2, before any Release exists.

### 9.2 What it protects, and from when

- Immutability attaches at publication, not at tag creation: until the Release is published only
  L4 protects the tag, and the App or an administrator can still change the draft's assets.
  Design §15.3's draft-first order matches GitHub's recommended practice, and its "create
  immutable annotated tag" describes the state after publication (Section 13).
- After publication, assets cannot be changed or deleted and the tag cannot be moved or deleted
  while the Release exists. Deleting the Release frees the tag for deletion, but its name can
  never be reused. The title, notes, prerelease flag and latest flag stay editable.

### 9.3 Capture

GitHub creates a release attestation when an immutable release is published. Capture is
operator-side, since the approved job holds no `attestations` permission (L1 refuses it): after
publication the operator saves the `gh release verify --format json` output outside the tree,
records its SHA-256 and its subject names and digests (public asset digests) in the readiness
evidence, and reads the Release back `immutable` true, `draft` false, `prerelease` false. It is
first done on a venue Release (6.6, S1).

### 9.4 Verification

GitHub describes the release attestation as containing the release tag, commit SHA and release
assets. `gh release verify` looks it up by the SHA of the object the tag ref names
(`git/ref/tags/<tag>`, per the gh source), which for an annotated tag is the tag object. Which
object the tag subject digests, and the subject list's shape, are recorded in the venue (6.6, S1),
and every later run compares against that record. Verification has four parts: the tag's
attestation; each asset's attestation; the tag peeled to the candidate; and the published bytes
equal to the approved ones: each downloaded asset's SHA-256 and each asset subject's digest in the
attestation (9.3) equal the digests the verifier job recorded and C2's record binds (out of tree
under 5.1), and the published body's SHA-256 equals C2's body digest, both over the byte form P10
fixes. The first three pass on bytes swapped into the draft after the approved job's upload check
(9.2); a difference in the fourth is a 7.2 incident. In the block, `C2_DIGESTS` is the absolute
path of C2's out-of-tree `shasum` list of the two assets and `C2_BODY_DIGEST` C2's body digest.

```sh
# Partial: P10's block adds the comparison of each asset subject's digest in release-verify.json
# with C2's record, in the subject-list shape the venue recorded (6.6, S1).
set -euo pipefail
: "${CANDIDATE:?}" "${SCRATCH:?}" "${RELEASE_ID:?}" "${C2_DIGESTS:?}" "${C2_BODY_DIGEST:?}"
case "$C2_DIGESTS" in /*) ;; *) echo 'C2_DIGESTS must be absolute' >&2; exit 1 ;; esac
A=apple-vX.Y.Z-macos-arm64.tar.gz
printf '2.93.0\n%s\n' "$(gh --version | awk 'NR == 1 {print $3}')" | sort -V -C   # gh >= 2.93.0
[ "$(gh api "repos/{owner}/{repo}/releases/$RELEASE_ID" --jq '[.tag_name, .draft, .prerelease,
    ([.assets[].name] | sort | join(","))] | map(tostring) | join(" ")')" \
  = "vX.Y.Z false false $A,$A.sha256" ]                        # the Release the ID names
[ "$(awk '{print $2}' "$C2_DIGESTS" | sort | paste -s -d , -)" = "$A,$A.sha256" ]
gh release verify vX.Y.Z --format json > "$SCRATCH/release-verify.json"
mkdir -p "$SCRATCH/assets"
for name in "$A" "$A.sha256"; do
  id="$(gh api "repos/{owner}/{repo}/releases/$RELEASE_ID" --jq ".assets[] | select(.name == \"$name\") | .id")"
  [ -n "$id" ]
  gh api -H 'Accept: application/octet-stream' "repos/{owner}/{repo}/releases/assets/$id" > "$SCRATCH/assets/$name"
  gh release verify-asset vX.Y.Z "$SCRATCH/assets/$name"
done
(cd "$SCRATCH/assets" && shasum -a 256 -c "$C2_DIGESTS")       # part 4: the bytes C2 scanned
body_digest="$(gh api "repos/{owner}/{repo}/releases/$RELEASE_ID" --jq '.body' \
    | shasum -a 256 | awk '{print $1}')"                      # P10 fixes the form C2 hashes
[ "$body_digest" = "$C2_BODY_DIGEST" ]                         # part 4: the notes C2 scanned
tag_obj="$(gh api "repos/{owner}/{repo}/git/ref/tags/vX.Y.Z" \
    --jq 'select(.object.type == "tag") | .object.sha')"
[ -n "$tag_obj" ]
peeled="$(gh api "repos/{owner}/{repo}/git/tags/$tag_obj" \
    --jq 'select(.object.type == "commit") | .object.sha')"
[ -n "$peeled" ] && [ "$peeled" = "$CANDIDATE" ]
```

`gh attestation verify` is not used: it checks a workflow-signed provenance attestation against a
signer identity, while release attestations are signed by GitHub's releases identity; the gh
source registers `--format json` on `release verify`. The `gh` used, here and in the tap (8.3),
is 2.93.0 or later, asserted first: `release verify` and `verify-asset` arrived in 2.81.0, and
through 2.92.0 they sent the authorization header to hosts that should never receive it
(GHSA-8xvp-7hj6-mcj9), which on the operator's side carries the administrator credential the
agent sessions share (D46). The tap runs the first three parts; the fourth needs C2's record,
which only the operator holds.

### 9.5 What it is not

The release attestation records the release tag, commit SHA and release assets at publication;
it is not build provenance and says nothing about how the binary was built. Design §15.2 leaves
to this document whether and where provenance is attested: the launch attests none, so no job
gains `attestations` or `artifact-metadata` write. Release notes describe the checksum as
pipeline-internal integrity and claim no provenance (design §15.2): P9 requires the statement in
`[Unreleased]`, and A8 reads it back from the published body. Adding build provenance later is a
separate reviewed change that keeps every publishing operation behind the operator's approval.

## 10. Retirement of the urgent-release runbook

The runbook applies "until public launch" and says the launch specification records its
retirement (runbook header; design §18 step 5). Its step 1.4 refuses once any active ruleset of
target `tag` exists, and forbids disabling, deleting or changing a ruleset to make it apply.

**When.** Step L3, directly before the first tag ruleset (L4), so the documented path and its
own read-back never disagree.

**Preconditions.** No restored `urgent-release-verify.yml`; no open runbook ledger entry; no
runbook release in flight (P7); the 6.7 probe recorded with every part passed; Releases read back
0, as at L0. A runbook release published after L0 stops L3: L0's reads are re-run against its
expected set as amended for that Release, a recorded delta privacy round covers the Release's
surfaces, and this specification is amended wherever it treats `v27.0.0` as a first release (the
Release counts of L0 and L2, L9's first-release result, 6.3, L13's rollback) before L3.

**What changes**, in one governance policy change:

1. the runbook's two header lines: `**Applies:**` ends "until public launch, retired on <date>"
   in place of "until public launch.", and `**Retired at launch:**` reads "launch specification,
   step L3, <date>; an urgent release goes through the design's publisher under that
   specification's Section 5.3, the only tag writer.";
2. every `AGENTS.md` mention of the runbook, found by searching the file when L3 is prepared,
   stops presenting it as a current procedure, at least the Branch model bullet ("or the
   urgent-release runbook's reset"), the release-freeze paragraph, "When a release happens" with
   its policy exception, and "Release-commit review posture". The first two say no release path
   exists until 5.3 opens, and the publisher under 5.3 is then the only one, whether or not the
   tap serves anything; the posture paragraph names the release-preparation pull request's one
   `Reviewed-by:` trailer (L13 item 2.4); and "Release notes — required contract" states that a
   privacy redaction at HEAD is the one permitted edit to a released section (7.3);
3. an amendment to D2 records the retirement, as the 2026-09-26 amendment recorded the runbook's
   arrival;
4. the recorded workflow text stays in the page as a record, and
   `Tests/automation/test_urgent_release_runbook.py` keeps pinning it, since its read-only shape
   remains true.

**Check.** The two header lines read as item 1 states; `test_urgent_release_runbook.py`, the
static scan and the action-pin check are green on `main`; `urgent-release-verify.yml` is absent;
the `AGENTS.md` paragraphs and the D2 amendment on `main` match the reviewed text.

**Rollback.** Revert the policy change, only while no tag ruleset exists (before L4). After L4
there is no reinstatement through this specification (5.2 item 7).

**Window accepted.** From L3 until 5.3 opens, no path exists for an operator-instructed urgent
release the freeze would otherwise allow (D2's 2026-09-26 amendment). Approving this
specification accepts that window, the trade-off design §18 step 5 and D15 recorded for the
period before the runbook existed, and that it has no fixed bound:

- No open question can hold it open: those defaulting to "none" are ruled before L3 (Section
  12), the rest need only an instruction to use the default, except a recorded Q9 (B) wait.
- The 6.7 probe settles before L3 the token table, T1, T3 to T5, Observations (d) and (f) and
  L6's Dependabot selectability; T6, needing L12's bypass, is the one launch-blocking T-case
  left after L3.
- A stop after L3 can still hold it open: a failed Check of L4 to L15; an L11 failure (any 6.2
  case, T1 to T6 or an Observation with the real files, the run record, Teardown); an L13
  failure and rollback; a re-seed under L9 standing rule (b). Each is resolved by an operator
  ruling and, where its step says so, an amendment to this specification; otherwise the launch
  is abandoned under 5.2, whose item 7 route this specification does not provide.

## 11. Privacy gate (D34)

### 11.1 The fresh round

The gate closes on a fresh round, recorded in evidence §2 before L1 and timed as P2 states, with
zero findings for its stated scope (D34; design §15). It records its searched classes, engines,
commit-message coverage, surfaces and finding count; uses at least two engines with an independent
cross-check; and accepts no `git grep -E` negative (`AGENTS.md`, audit-tooling caveat). Round 2's
independence was narrower than Round 1's (evidence §2), so a separate challenger, as in Round 1,
is recommended. An "11.1 scan" in this document is a value-free scan under this round's classes
and engines; it passes with zero findings or each NOT READ surface ruled on, and a finding goes to
Section 7.

### 11.2 Minimum surfaces (D34)

Every surface Round 1 and its addendum scanned (among them pull-request text and timelines, issue
events and comments, and commit comments), plus: the tree, history, commit messages, objects and
refs; workflow logs and artifacts; workflow-run, check-suite and check-run objects (head branch,
head-commit message and author, display title, annotations and job summaries, not only logs);
Actions caches; repository metadata; Releases; the repository's public Activity view (D47). A
surface the round cannot read is recorded NOT READ, and a NOT READ surface inside this minimum
keeps the gate open until it is read or the operator rules on it.

### 11.3 Known items the round must read and disposition

Each commit ID found on a public surface is read with every ancestor that no advertised ref holds:
fetching one ID returns its history (D47). From evidence §2 and D35 to D38, D41 to D44 and D47:
copies of the eight D35 messages stored on run and check-suite objects, which D35 does not cover;
the D36 contributor link in two commit messages on pull request 3's branch and in nine comment
events in the public Events feed; the off-main commit IDs the Events feed still names (at least 29
at D37's read; 12 at a 2026-10-07 re-read, ten of them heads of runs D37 deleted and three of them
outside both D47's lists and the pull-request refs, which with their parents make six commits no
advertised ref holds), until they age out, about 2026-12-13 at the latest; check suites left by a
third-party App on 129 of the 135 head commits of the runs D37 deleted; copies, stored outside git,
of the pre-rewrite messages carrying two operator sessions (the messages themselves, among D47's
1,550 commits, are accepted under D47); every page of the Activity view's listing and every commit
ID it names that lies outside D47's two id lists; the test tree, re-read for other samples taken
from a live store (D41); the residual D44's 2026-10-03 amendment records for the commit it names;
the old Mail test-file versions in `main`'s history that evidence §2 names (D47's review).

### 11.4 Recorded as ACCEPTED, not as findings

Each as scoped in its entry: D20 (the contributor's own git identity), D35, D36, D38 (one commit
served by ID), D41 and D42 (live-store samples in history), D43 (CI logs until about 2027-01-01, as
its 2026-10-04 amendment records), D47 (the 1,550 commits that no advertised ref holds and that are
reachable from the 128 the Activity view listed on 2026-10-06, the 128 among them, and their trees
and file contents that no advertised ref holds, pinned by the SHA-256 of two private id lists; if
the lists cannot be produced with matching SHA-256, the round records the residual as unverifiable
and puts it to the operator), D50 (the six deleted branch names in the Activity view that carry
tracker identifiers, in the 24 branch-creation, push and deletion events dated 2026-07-15 to
2026-08-23 that D50 describes). D47's boundary, as its entry states it: "Anything the round's
classes detect in a commit outside the two pinned lists, or in an object no listed commit reaches,
is outside this residual and stays a finding unless another entry accepts it, whenever the view
lists it or however it is found." D50's boundary, as its entry states it: "The same names in any
other event or on any other surface, and any other tracker identifier the view shows, stay findings
unless another entry accepts them." D37 deleted 168 off-main runs; 205 runs were listed at its
2026-09-27 read-back, and more since.

### 11.5 The `v27.0.0` asset checks

D34 requires both checks before publication whether or not this specification adopts them.

1. **C1, D18 step (4) as an outcome**, proposed for the design §15.1 preflight. It is class-based
   and value-free, so it may run hosted, in the unprivileged build job and again in the verifier
   job over the downloaded bytes: zero `N_OSO` entries (`nm -ap`); none of the home-directory
   prefixes evidence §3a gates (`/Users/`, `/private/tmp/`, `/var/folders/`, `/home/`) anywhere in
   the binary's bytes, a wider set than the runbook's `/Users/` check; archive members exactly one
   regular file `apple`, user id 0, group id 0, empty owner and group names, no AppleDouble member.
2. **C2, the operator-local denylist scan.** After the preflight has produced the artifacts and
   before approval, the operator downloads them by their recorded IDs, confirms the digests equal
   the verifier job's, re-runs C1, and scans the binary, the archive, the checksum file and the
   Release notes body exactly as it will be published, under the fresh round's classes and
   denylist, never in a hosted environment. Its record is value-free and bound to the SHA-256 of
   each of the four items; the pre-approval preflight cannot require it, since it exists only
   after the preflight's artifacts do. Under Q4 (A) the binding is post-approval: the operator
   sets a `github-pages` variable to a SHA-256 over the four item digests in a fixed order, and
   the approved job's recheck recomputes it from the verifier job's recorded digests (the
   binary's included, C1 extracting it there), already rechecked against the bytes it
   downloaded, and from the body it will publish (a seventh design §15.3 assertion; Section 13).

**Finding route.** A C2 finding, or a finding in L13 item 2.4's scan, is a Section 7 incident; the
attempt is abandoned, which ends the candidate window (5.1) so that 7.2's ledger entry can land. A
2.4 finding comes before anything is pushed: 7.2 items 2 and 3 cover the tracked text it came
from, and 5.1's failure rule (b) applies. A C2 finding means the preflight artifacts are already
downloadable from a public run: K1 and K2 (6.1), then 7.2 items 2 to 5, deleting that run's
artifacts, logs and run (7.3, each read back 404) and editing any pull-request text that carries
the data (7.3); then L13's "before the tag" rollback. A venue C2 finding takes the same route in
the venue.

D34 states: "Both results are recorded in the evidence file before publication." D18 step (4)
states the same of its check. A commit on `main` inside the candidate window strands the
candidate (5.1), and the records cannot ride in the release-preparation pull request, because
they describe artifacts built after it merges. Q4 asks the operator to rule; until then the
launch cannot satisfy both.

### 11.6 Surfaces the launch creates

- The Release's binary, archive, checksum file and notes body: C1 and C2 per publication (11.5).
- The release-preparation pull request's title and body, which become the candidate's commit
  message: L13 item 2.4's scan, before the push.
- Run, check-suite and check-run objects, run logs and artifacts from L9 on, and this
  repository's pull requests and deployment records: L13 item 7's scan after every publication,
  independent of the tap; the tap: L14 item 6's scan. Until they run, publisher logs rest on
  value-free logging by construction and the other objects on nothing.
- The venue (6.6) and any probe repository (6.7): C1 and C2 per venue candidate, with 11.5's
  finding route, and the Teardown scan.
- Section 7 for anything found later. The round is not re-run per publication unless the
  operator rules so.

## 12. Open questions for the operator

Each needs a ruling, or an explicit instruction to use the stated default, before the step its
"Ruled by" line names (1.1 item 2); a default of "none" means that step waits for a ruling. Q1,
Q3, Q4, Q5, Q6, Q9 and Q10 decide what L9's files contain, Q2 where the probe and L11 run, and
Q12 how L7 to L13 run, so each is settled before L3: after L3 removes the only release path, an
open question could hold every release without end (Section 10), and a ruling after L9 forces a
second publisher change, a new manifest blob SHA and a re-run of L9's checks. A ruling for an
option this specification does not spell out first amends it under the P3 review gates, and
every recorded precondition it changes (P8 under Q12 (B), for example) is read back again.

**Q1. The release build's Xcode.** The runbook logs `sw_vers`, `xcodebuild -version` and
`swift --version` but does not pin the toolchain, leaving that to the publisher (runbook, Known
limits).
- (A) Record only, in the run summary and the evidence. (B) Pin `DEVELOPER_DIR` to an exact Xcode
  path recorded in the control-plane publisher, the preflight failing closed when it is absent; a
  bump is a policy change. (C) Keep the image default but assert the exact Xcode build number,
  failing closed on any other.
- Default: (B). A failed preflight publishes nothing and the candidate stays valid. Whether D18
  step (4)'s outcome survives an image's Xcode change is not established. Ruled by: L3 (it shapes
  L9).

**Q2. Where the termination and attribution rehearsals run (6.5).**
- (A) The throwaway public venue of 6.6, deleted after the evidence is captured: a new
  outward-facing object needing its own instruction and its own App deletion (Teardown); the
  ruling records its Releases as rehearsal publications, not releases under D2 or D17 ruling 2.
- (B) This repository, during the first real release: terminate deliberately, restore, and burn
  `v27.0.0`, which needs a design §16 amendment (it requires the rehearsal before the first
  release); with no re-run path (6.4) the replacement follows L13's rollback ledger entry and
  the default bump; unreleased documentation would serve at `/` briefly; the probe needs a
  throwaway repository (6.7).
- (C) This repository with a rehearsal tag series. Not viable: every `v*` tag is permanent under
  L4 and immutability, and the publisher publishes stable versions only.
- Default: none; the probe, L3 and everything after wait. Recommendation: (A). Ruled by: the
  probe (6.7), before L3.

**Q3. Launching while the operator works alone (P5).**
- (A) Obtain a qualified reviewer first. This re-opens D31 and ends the solo-model inferences of
  design §14.2 and §15.1: from then on the repository variable is unattributable and dispatcher
  evidence rests on the environment approval alone.
- (B) Rule an amendment to design §21 letting the launch proceed at "rehearsal complete", Goals 2
  and 3 reported unmet and each governance criterion recorded as unverified by absence. The
  release-preparation pull request then merges by operator bypass, which design §14.2 and §15.1
  accept only when the bypass log, unreadable by any workflow token (L1 item 6), records it, so
  (B) also needs Section 13's operator-verified bypass branch and L13 item 4's rule-suite read,
  and works only if P6 shows the operator can read that record.
- (C) Defer the launch, `v27.0.0` and the end of the freeze until (A).
- Default: (C). A posture call; the draft makes no recommendation. Ruled by: L1 (P5).

**Q4. Where the L13 records live before publication (5.1, 11.5)**: C1's and C2's (D34), D18 step
(4)'s (D18 and D34), D18 step (2)'s, and the other window records of 5.1.
- (A) Amend D34 and D18 step (4): C2 is bound before publication through the operator-set
  variable and the seventh design §15.3 assertion (11.5); C1 by the verifier digests the approved
  job rechecks; every record is appended to the evidence file and the launch entry right after
  publication or abandonment, as runbook step 6.4 already does.
- (B) Keep D34's wording by committing the records to the evidence file on a separate branch the
  operator pushes before approval (L6 bypass) and lands on `main` after publication. It needs D34
  and D18 to accept that branch copy as "the evidence file", and the records become public before
  publication.
- (C) Let the tip check tolerate later commits changing only the evidence file and the ledger,
  weakening design §15.3's binding.
- Default: none. Recommendation: (A). Ruled by: L3, because (A) adds the seventh assertion and
  its variable to L9's publisher.

**Q5. The freeze-ending command (8.7).** `brew install apple-cli` fails on a clean machine
because the tap is not yet tapped and, since Homebrew 6.0.0, not yet trusted.
(A) Amend D2, the `AGENTS.md` freeze paragraph and design §15.1 to the fully qualified
`brew install OWNER/tap/apple-cli` on a clean environment, which handles both; (B) keep
`brew install apple-cli`, the clean environment having the tap added and the formula trusted
first. Default: (A). Ruled by: L3, because L9's tap check runs that command.

**Q6. Tap identity.** (A) `OWNER/homebrew-tap`, installed as `OWNER/tap/apple-cli`, matching
`docs/versioning-policy.md` §6.4; (B) `OWNER/homebrew-apple-cli`, installed as
`OWNER/apple-cli/apple-cli`. Default: (A). Ruled by: L3, as Q5.

**Q7. Tap write mode.**
- (A) Proposal branch: the tap writer pushes a branch; the operator opens and merges the pull
  request (8.2); the tap keeps `can_approve_pull_request_reviews` false.
- (B) Pull request: the tap's "Allow GitHub Actions to create and approve pull requests" setting
  turned on, with the reason recorded. Its token can then also approve, which binds nothing while
  the tap's ruleset requires no approval; the operator still merges.
- (C) Direct: the workflow commits to the default branch after its checks. The tap ruleset then
  cannot require a pull request, and the pre-merge install of 8.3 is lost.
- Default: (A). Ruled by: L14.

**Q8. Tap trigger.** (A) The operator dispatches the tap writer after publication; (B) a
scheduled poll acts when a newer published stable Release exists; (C) both. Default: (A). A poll
is never the only trigger (8.5). Ruled by: L14.

**Q9. The artifact runner for `v27.0.0`.** Design §12 names a macOS 27 arm64 artifact runner for
`main` at 27.x, but no stable hosted `macos-27` image exists (design §4.1 amendment of
2026-09-29).
- (A) Build on the stable hosted `macos-26` image, amend design §12's artifact column, and have
  the operator run the exact downloaded artifact on the macOS 27 host (version, help and the
  hosted-safe Bats partition) before approving, recorded out of tree (5.1). Only `v27.0.0` gets
  that run (5.3 item 2): the ruling accepts that later 27.x artifacts ship without being executed
  on macOS 27 while the build runner's macOS is below MAJOR.
- (B) Wait for a stable hosted `macos-27` image.
- (C) Build on the operator's host. Not compatible with design §15.2, which builds only in the
  unprivileged hosted job.
- Default: none; recommendation (A). (B) needs a recorded acceptance that L9, and so every
  release, waits without end on an image no admitted runner label provides (Section 10). Ruled
  by: L3, because the answer fixes L9's build runner label.

**Q10. The dispatch ref** (design §14.2). (A) Dispatch on `main`, with the publisher's
first-step assertions and the operator's run-header comparison; the recorded residual stands.
(B) A dedicated protected control ref only a policy change can move, needing its own ruleset, a
change to `github-pages`'s branch policy and an exclusion in L6. Default: (A). Ruled by: L3,
since (B) changes L6, L7 and L9.

**Q11. The authorization variables after a publication** (L13): the advisory repository
variable, the two binding `github-pages` variables, and the C2 binding variable under Q4 (A).
(A) Clear all of them after publication and whenever an attempt is abandoned, so no stale
authorization remains (no candidate can resume at launch, Section 13's design §19 amendment);
(B) leave them until the next release. Default: (A). Ruled by: L13.

**Q12. The agent sessions' credential during the launch** (1.1 item 6; P8; D46, "At step 20").
Every "only the operator" control binds to the operator's credential, which both agent sessions
also hold.
- (A) Keep the residual as P8 records it: the reservation is conduct, not a control.
- (B) Before L7, move both agent sessions to a separate identity without administration, bypass
  or environment-review rights. If it can write, a second write-capable actor exists (the
  variable unattributable, dispatcher evidence resting on the approval alone, design §14.2,
  §15.1; D31 re-opened; P8's set changed); if it can only read, it proposes from a fork after L6
  (design §7.3) and every landing is the operator's merge.
- (C) Agent sessions hold no repository credential from L7 through L13; every read-back in that
  span is the operator's, and agents prepare value-free text only.
- Default: none. A posture call; the draft makes no recommendation. Ruled by: L3; it takes
  effect at L7.

## 13. Changes this specification needs elsewhere (not made here)

Each lands through its own reviewed change and is on `main` and read back before the step named
(1.1 item 2):

- Readiness evidence: a launch section for L0 to L15, A1 to A11, the 6.7 probe results and the
  6.6 run record. Before L0.
- The launch runbook and its pinning test (P10), before L1; its L13 item 4 and 5.3 blocks, with
  every operator read the 6.7 table placed beyond the jobs' tokens, after 6.7 and before L9.
- The launch-shape scan (design §18 step 17, `workflow_policy.py`, `action_pins.py` with the
  provenance note, the path-scoped guard): L1. The runbook's retirement (the runbook, Section 10
  item 2's `AGENTS.md` passages, a D2 amendment): L3.
- Design §14.2: the listener's permission contract ("`actions: write` ... plus read-only
  `contents` and metadata") gains `pull-requests: read` (L1 item 3). Before L9.
- Design §14.2, §15.1 and §15.3: every read the 6.7 table places beyond a workflow token (at
  least each ruleset's `bypass_actors` and the rule-suite bypass log) becomes an operator read at
  L13 item 4, with the §15.3 recheck's sixth assertion if the `github-pages` protection read is
  among them; only under Q3 (B), with no approving review, the listener, preflight and recheck
  record the bypass branch as operator-verified, tree equality, the governance half and the
  subject and body checks staying token-verified. Before L9.
- Design §15.1: C1 (11.5); the tap-check command form (Q5); the tap check running only once D2 is
  recorded APPLIED, from a tracked value switched only as 8.7 states. Design §15.2: pull-request
  read and `checks: read` for the preflight and approved jobs (L1 item 3). Before L9.
- Design §15.3: the seventh assertion under Q4 (A); the last step as an operator action (8.5);
  "create immutable annotated tag" read as protected by L4 until publication (9.2); proposed, a
  re-read of the draft's asset `digest` fields against the verifier's digests immediately before
  the publish call, failing closed on a null, narrowing the 9.2 window that 9.4's fourth part
  detects only afterwards. Before L9.
- Design §10.5: the Dependabot workflow-pin exception refuses any pull request changing one of
  the four publisher-workflow paths L9 proposes, named literally, so the refusal needs no
  bound-set list and holds before L9 creates one (the exception admits only workflow files, so
  no other bound-set file can reach it); a `Tests/automation` case shows the refusal with the
  four files absent and present. Before that exception is implemented (P6), so before L1; if L9
  lands the workflows at other paths, L9's change moves the literals.
- In L9's change, beside the four workflows:
  - `ci.yml`'s quality-record step and its script; the three allowlist entries and the test
    inventory; the bound-set list, its test, the owner test and the publisher-blob test; the
    tracked tap-check value, off (8.7);
  - `.github/dependabot.yml`, with `scripts/ci/dependency_policy.py` (whose `validate_dependabot`
    holds the file byte-equal to `render_dependabot_policy()`) and
    `Tests/automation/test_dependency_policy.py`: the `github-actions` entry gains an `ignore`
    list naming, by dependency name, every Action the four workflows use. With one pin per name,
    those Actions are then hand-updated in every workflow (L9 standing rule) and Dependabot's
    version updates cover only the others (today at most `astral-sh/setup-uv`), a departure a
    design §17 entry records before L9. Neither `ignore` nor `exclude-paths` governs a security
    update while `target-branch` is set (D45), so a Dependabot pull request touching a bound-set
    file, a security update or a `docs/requirements.txt` update included, is closed unmerged and
    taken by hand; the design §10.5 exception never admits one. The options reference is re-read
    and recorded at L9;
  - design §18 step 5's rule that `AGENTS.md` changes with the workflows, applied in reverse:
    "Release automation — current state" (no workflow can tag or publish, and the tests refuse
    any that could) and "Fork-PR safety" (which must name the listener as a fork-reachable
    `workflow_run` trigger holding `actions: write`), with any other tracked text that says no
    publisher exists.
- D34 and D18 step (4), where the L13 records live (Q4), and design §12's 27.x artifact runner
  (Q9): before L9 under the (A) option, which changes the publisher; otherwise before L13.
- Design §19, with §15.1's resume bullet: a dated amendment recording that at launch every
  post-tag partial state (the rows "Future tag or draft enters partial state", "Future asset
  verification fails", "Future Pages deployment or canary fails" and "Future Release publication
  fails") is resolved by reconciliation and a new version under L13's rollback rulings, until a
  policy change adds the listener re-run path (6.4, T2). Before L9.
- Design §16, the §19 rows' "(or the empty sentinel)", and the same words in design §15.3's
  "Keeping the release draft" paragraph: on a first release the in-job restore deploys nothing
  and reports failure, and recovery is 6.3 (L9; design §15.2 already makes the post-deploy
  first-release recovery the operator's). Before L9. Only under Q2 (B), the rehearsal before the
  first release. Before L11.
- Design §16: the scheduled reconciler's "publication in flight" result and its `actions: read`
  scope (L1 item 3, L9 Check (ii)). Before L9.
- Design §21: only under Q3 (B). Before L1 (P5).
- D2 and the `AGENTS.md` freeze paragraph: the freeze-ending condition (Q5). Before 8.7's result
  is recorded as ending the freeze.
- `README.md`: the published version and the Q5 and Q6 install command, written with its
  existing public-attribution URLs, never naming an unassigned version. After L14 item 5 records
  the tap serving, outside any candidate window.

## 14. References

- The design: §§3, 4, 5, 6.3, 7, 9, 10.5, 12, 14, 15, 16, 17, 18, 19, 20, 21.
- `HUMAN-DECISIONS.md`: D2, D15–D21, D26–D38, D41–D46.
- `docs/discovery/prelaunch-readiness-evidence.md`: §1 (rows cited), §2, §3a, §4.
- `docs/runbooks/urgent-release.md`: header, steps 1.4, 6 and 7, Known limits, the recorded
  workflow.
- `AGENTS.md`: Branch model; Commits + review; Versioning + releases; release freeze; When a
  release happens; Release-commit review posture; release notes; personal-data rule and
  audit-tooling caveat. `docs/versioning-policy.md` §6.4.
- `scripts/ci/release_prep.py`, `site_assembly.py`, `workflow_policy.py`, `action_pins.py`,
  `dependency_policy.py` and `pr_metadata.py`; `scripts/check-release-notes.py`;
  `.github/actions-allowlist.json`, `.github/dependabot.yml`, `.github/workflows/docs.yml`;
  `Tests/automation/test_action_pins.py`.
- GitHub Docs, links recorded when P10, L1 and L14 are prepared: "Events that trigger workflows"
  (`schedule`), "Issue event types" (`renamed`), "Tracking changes in a comment", "Making
  authenticated API requests with a GitHub App in a GitHub Actions workflow"
  (`actions/create-github-app-token`), "Managing GitHub Actions settings for a repository" (the
  create-and-approve pull requests setting).
- [Dependabot options reference](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-options-reference)
  (`target-branch`, `ignore`, `exclude-paths`);
  [GHSA-8xvp-7hj6-mcj9](https://github.com/cli/cli/security/advisories/GHSA-8xvp-7hj6-mcj9)
  (`gh` authorization header, fixed in 2.93.0).
- [Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases);
  [Verifying the integrity of a release](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/verify-release-integrity);
  [Preventing changes to your releases](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes);
  [Repository attestations REST API](https://docs.github.com/en/rest/repos/attestations).
- [Deployment environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments);
  [`GITHUB_TOKEN` event behavior](https://docs.github.com/en/actions/concepts/security/github_token);
  [Managing private keys for GitHub Apps](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps);
  [Repository rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets).
- [`gh release verify`](https://cli.github.com/manual/gh_release_verify);
  [`gh release verify-asset`](https://cli.github.com/manual/gh_release_verify-asset).
- Homebrew: [Tap Trust](https://docs.brew.sh/Tap-Trust);
  [How to Create and Maintain a Tap](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap);
  [Formula Cookbook](https://docs.brew.sh/Formula-Cookbook);
  [Manpage](https://docs.brew.sh/Manpage) (`HOMEBREW_FORBID_PACKAGES_FROM_PATHS`,
  `brew test-bot`).

## 15. Open review findings (for the operator)

These were raised by independent reviewers of this draft, except item 3, which the author added
after the rounds that raised the others, and which later rounds reviewed, and item 14, which the
controller added on 2026-10-07 when a reviewer of D47's change raised it. Item 3 was resolved by
D47 on 2026-10-07; none of the others is resolved yet. They are recorded here, value-free, so the
operator sees them before approving.

**MEDIUM**

1. **Completeness — §6.7, §6.6 S1, §6.2 F1, A5, Section 10.** The probe never exercises a
   self-approved Pages deployment dispatched from the `github-pages-recovery` environment, even
   though design §15.2 and §16's recovery authority and Section 10's bounded no-release-path claim
   both rest on that path working. As written, the first such deployment and self-approval only
   occur after L3 has already removed every release path. *Suggested fix:* add a fourth probe
   stand-in that deploys and self-approves through the recovery environment, confirms what it
   serves and which environment the deployment record names, and add its failure to the stop list
   (or narrow §6.7's claim to exclude this fact).
2. **Operability — §6.6 items 1–2, §6.7 opening.** The venue and probe setup never applies this
   repository's actual merge settings (squash title/body sourced from the pull request) or Actions
   settings (selected, pinned actions), so the rehearsal can pass under GitHub's defaults while the
   production settings would refuse the same run, most plausibly after L9. *Suggested fix:* have
   §6.6 item 2 and the §6.7 probe apply and read back this repository's merge and Actions settings
   before rehearsing, and treat a later mismatch against L15 as a re-seed trigger.
3. **Privacy — Sections 7 and 11 (added 2026-10-04 by the author, after the rounds that raised the
   others).** An operator question bearing on these sections was filed outside this repository.
   This item was to be completed after the ruling, with a ledger entry and any amendment to
   Sections 7 and 11 the ruling requires, made under the P3 review gates, before P2 could be
   recorded met. **Resolved 2026-10-07 by D47:** its ledger entry and its Section 7 and 11
   amendments landed in one commit, under the P3 review gates.

**LOW**

4. **Completeness — L9 Check (i), §6.6 S1, design §14.2/§15.2/§16.** L9's synthetic tests omit
   negative coverage for the publisher's dispatch-race assertions, its input-shape validation, and
   the recovery workflow's refusal of anything but a published stable Release. *Suggested fix:* add
   refusal tests for each, including a recovery-workflow test against a draft, prerelease, or
   non-strict tag.
5. **Completeness — §6.7 item 5, §6.6 item 2, Section 10, design §7.3/§20 item 9.** The probe
   verifies Dependabot's bypass selectability on the tag-creation ruleset but never verifies the
   publisher App's, even though the design treats App selectability there as a publication
   blocker. *Suggested fix:* add an App-selectability check (add, read back, remove) to the probe's
   item 5 and its stop list.
6. **Completeness — L15 Action, L8 Check, design §7.3/§18 step 17.** L15's expected set records
   installed Apps but not the publisher App's permission scopes or repository selection, so a later
   widening would not be caught against a recorded baseline. *Suggested fix:* have L15 record the
   App's exact permissions, repository selection, and key fingerprint, and compare both reads
   against that baseline.
7. **Completeness — Q2 option (B), L1, §6.2 introduction, design §15.3.** Q2 option (B) is
   presented as viable, but L1 refuses the fault-injection switch in this repository, so most of
   §6.2's fault cases cannot be exercised under that option as written. *Suggested fix:* mark
   option (B) as requiring a prior amendment to §6.2/§6.5/§6.6/A5/§9.3–9.4, or mark it not viable.
8. **Accuracy — Section 10 Preconditions, L0 Check.** The re-run language now covers Release
   counts after a runbook release but still omits L0's immutable-releases check, which a runbook
   release published after L2 would also invalidate. *Suggested fix:* extend the sentence so L0's
   expected set is also updated for L2's immutable-releases state.
9. **Accuracy — §6.3, §6.7 item 3, L10 Check.** §6.3's re-enable step re-invokes all of L10's
   Check, including the reconciler read, but no reconciler exists in the probe repository, so the
   probe would fail a check it cannot run. *Suggested fix:* scope §6.3's "L10 again" to skip the
   reconciler read where no reconciler exists, matching the exception §6.6 item 2 already makes.
10. **Accuracy — §6.5 second bullet.** The bullet says the probe runs "in the venue of Q2," but
    under any ruling other than Q2 (A) the probe runs in a separate throwaway repository per §6.7
    and Q2 (B) itself, contradicting those sections. *Suggested fix:* split the bullet to name the
    throwaway repository as the probe's venue except under Q2 (A).
11. **Operability — P10, A1, §6.7 opening, Section 13, §1.1 item 3 vs. P4.** P10 requires
    executable blocks for every step before A1 can be recorded, but some of those blocks are only
    defined by the post-A1 probe, making the precondition circular for a cold operator.
    *Suggested fix:* except the probe-defined blocks from P10/A1's requirement, and state when L0
    may run relative to P4.
12. **Operability — §5.1 second bullet, §9.4, §11.5 C2.** Candidate-window records are kept
    value-free outside the tree with no named durable location, yet must survive a multi-hour local
    test run between creation and later use. *Suggested fix:* name a durable, duplicated,
    operator-owned location outside any scratch directory and require a checksum check before each
    later use.
13. **Operability — §7.2 item 2, §11.5 Finding route.** Containment of a live public artifact or
    log exposure is gated on a ledger entry landing through the normal commit-review gates, which
    can take hours while the exposure stays public. *Suggested fix:* let the operator authorize
    immediate deletion for an exposure still live on a run surface, with the ledger entry drafted
    and landed right after.
14. **Privacy — Section 11.6, L13 item 7 (added 2026-10-07 with D47).** The public Activity view
    lists the commits of every branch the launch creates in this repository after its deletion,
    force push or squash merge; Section 11.6 and L13 item 7 do not read that view yet. *Suggested
    fix:* have both read every page of the view's listing and every commit ID it names, each with
    every ancestor no advertised ref holds, and say what counts as a finding.
