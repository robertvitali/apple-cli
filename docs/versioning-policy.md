# Versioning Policy for the MCP → CLI Ports

Scope: a suite of published, macOS-native command-line tools that port existing
MCP-server capabilities to the command line, consumed primarily by three AI CLIs
(Claude Code, Codex, Antigravity). Each tool's public contract is **(a)** its
command / subcommand / flag surface, **(b)** its output format (primarily
agent-parsed JSON), and **(c)** its runtime behavior (including exit codes). They
target macOS and lean on EventKit / AppleScript / chat.db / REST APIs.

This policy is derived from two existing fleet projects that already define
versioning — **gstack** and **ollama-marshal** — plus SemVer 2.0.0 and
Keep-a-Changelog 1.1.0 best practice. Sections 1–2 quote what each project
actually says (with file paths); sections 3–7 are the synthesized recommendation.

---

## 1. What gstack defines

gstack is installed on this machine as a Claude Code / cross-CLI skill suite. Its
release contract lives in the **`ship` skill**:
`~/.claude/skills/gstack/ship/SKILL.md`.

### 1.1 Four-digit version scheme

gstack does **not** use plain 3-digit SemVer. It uses a **4-digit
`MAJOR.MINOR.PATCH.MICRO`** string, stored in a `VERSION` file (and mirrored into
`package.json`). From `ship/SKILL.md:2498`:

> 1. Read the current `VERSION` file (4-digit format: `MAJOR.MINOR.PATCH.MICRO`)

### 1.2 Auto-decided bump level (diff-size + feature signals)

The bump level is inferred from the diff rather than declared by the author.
`ship/SKILL.md:2500-2506`:

> 2. **Auto-decide the bump level based on the diff:**
>    - Count lines changed (`git diff origin/<base>...HEAD --stat | tail -1`)
>    - Check for feature signals: new route/page files (e.g. `app/*/page.tsx`, `pages/*.ts`), new DB migration/schema files, new test files alongside new source files, or branch name starting with `feat/`
>    - **MICRO** (4th digit): < 50 lines changed, trivial tweaks, typos, config
>    - **PATCH** (3rd digit): 50+ lines changed, no feature signals detected
>    - **MINOR** (2nd digit): **ASK the user** if ANY feature signal is detected, OR 500+ lines changed, OR new modules/packages added
>    - **MAJOR** (1st digit): **ASK the user** — only for milestones or breaking changes

So gstack's definitions are **size/heuristic-driven**, not contract-driven:
MAJOR = "milestones or breaking changes" (human-gated), MINOR = feature signal or
500+ lines (human-gated), PATCH = 50+ lines no-feature, MICRO = trivial. The two
lower tiers auto-pick silently; the two upper tiers stop and ask
(`ship/SKILL.md:744`: "MINOR or MAJOR version bump needed (ask — see Step 12)").

### 1.3 The 4th "MICRO" digit is a private queue-coordination artifact

The MICRO digit exists for **workspace-aware parallel shipping**, not for external
consumers. `ship/SKILL.md:2510` ("Queue-aware version pick") calls
`bin/gstack-next-version` to see "what's already claimed by open PRs + active
sibling Conductor worktrees" and allocates the next free slot so parallel PRs
don't collide on a version number. The pattern is validated hard
(`ship/SKILL.md:2539`): `grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'`. This is an
internal CI/queue mechanism — it is not a SemVer-meaningful signal to a downstream
installer.

### 1.4 Release flow (Keep-a-Changelog style, auto-generated)

- **CHANGELOG** (`ship/SKILL.md` Step 13): read the header for format, enumerate
  `git log <base>..HEAD`, group commits by theme, write an entry with
  `### Added / ### Changed / ### Fixed / ### Removed`, "Insert after the file
  header (line 5), dated today", format `## [X.Y.Z.W] - YYYY-MM-DD`. Voice rule:
  "Lead with what the user can now **do** that they couldn't before." Cross-check:
  "Every commit must map to at least one bullet point."
- **Idempotency** (`ship/SKILL.md:2441`): compares `VERSION` vs base branch and
  `package.json` — states FRESH / ALREADY_BUMPED / DRIFT_STALE_PKG /
  DRIFT_UNEXPECTED — so re-running `/ship` never double-bumps.
- **Full ship pipeline**: detect+merge base → tests → coverage audit → plan
  verification → multi-specialist review → version bump → CHANGELOG → push → PR.
  Version bump is Step 12 of ~19.

**Takeaway for the ports:** borrow gstack's *auto-generated Keep-a-Changelog +
idempotent bump + tests-and-review-gate-before-bump* release flow, but **drop the
4th MICRO digit** — it is a private parallel-PR-queue artifact with no meaning to
a published CLI's installers (brew, go-install, git-cliff all assume 3-digit
SemVer). gstack's size-heuristic bump levels are a decent *tie-breaker* but are the
wrong *primary* definition for a tool with a real external contract (a 30-line diff
can rename a flag = MAJOR; a 900-line diff can be pure internal refactor = PATCH).

---

## 2. What ollama-marshal defines

ollama-marshal is a published fleet CLI (git repo at
`~/path/to/local/resource`). It defines a **contract-driven, strict
SemVer 2.0.0** policy — the right model for the ports. Sources:
`CLAUDE.md` (the "Versioning" + "Bright-line Bug Patterns" sections), `CHANGELOG.md`
(header), `pyproject.toml` (`version = "0.6.5"`), and git tags
`v0.1.0 … v0.6.6`.

### 2.1 Single source of truth + SemVer declaration

`ollama-marshal/CLAUDE.md:257-260`:

> This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
> Single source of truth: `pyproject.toml` (`[project] version = "X.Y.Z"`).
> Referenced from `src/ollama_marshal/__init__.py` (`__version__`) and
> CHANGELOG.md release headings. All three must agree at release time.

### 2.2 Pre-1.0 vs post-1.0 table (verbatim, `CLAUDE.md:262-269`)

> **Pre-1.0 (current state):** the public API is not yet stable. Minor bumps may include breaking changes.
>
> | Bump | Pre-1.0 (0.X.Y) | Post-1.0 (X.Y.Z) |
> |---|---|---|
> | Major (X.0.0) | Reserved for the 1.0 stable-API commitment | Breaking change to public API, config schema, or CLI |
> | Minor (0.X.0 / X.Y.0) | New feature, may include breaking changes | New backwards-compatible feature or notable behavior change |
> | Patch (0.0.X / X.Y.Z) | Backwards-compatible bug fix or doc-only change | Backwards-compatible bug fix or doc-only change |

### 2.3 The 1.0.0 commitment (verbatim, `CLAUDE.md:271-274`)

> **1.0.0 commitment.** Cutting 1.0.0 means the public Python API
> (`from ollama_marshal import ...`), the HTTP endpoint paths and shapes,
> the YAML config schema, and the CLI flags are stable. Breaking any of
> those post-1.0 requires a major-version bump and a deprecation cycle.

### 2.4 "What counts as breaking" (verbatim, `CLAUDE.md:283-289`)

> - Removing or renaming a public function, class, or method
> - Removing or renaming a config field, CLI flag, or env var
> - Changing the YAML config schema in backwards-incompatible ways
> - Changing HTTP endpoint paths, request shapes, or response shapes
> - Raising the minimum Python version
> - Removing a previously-stable behavior users depended on

Note `CLAUDE.md:287` — **"Changing HTTP endpoint paths, request shapes, or
response shapes"** is called out as breaking. For the ports, the JSON **output**
shape is the exact analogue (agents parse it the way clients parse marshal's
responses). This is the single most important line to carry forward.

### 2.5 Per-PR workflow + release-time bump (verbatim, `CLAUDE.md:276-281`)

> **Per-PR workflow.** Don't bump the version in feature PRs. Add your change
> under `## [Unreleased]` in CHANGELOG.md (Added / Changed / Deprecated / Removed /
> Fixed / Security). Version bumps happen at release time: `[Unreleased]` moves to
> `## [X.Y.Z] - YYYY-MM-DD`, `pyproject.toml` and `__init__.py` get updated in the
> same release commit, and the commit gets tagged `vX.Y.Z`.

This is the **opposite** of gstack (which bumps per-PR/per-ship). ollama-marshal
batches an accumulating `[Unreleased]` section and bumps at a deliberate release
boundary. For an independently-published CLI consumed by agents, the
ollama-marshal batched-release model is cleaner (fewer version churn events, each
release is a considered contract statement).

### 2.6 Drift + wrong-bump are hard-gated (verbatim, `CLAUDE.md:331-337`)

> 13. **Version drift** — at release time, `pyproject.toml`,
>     `src/ollama_marshal/__init__.py`, and the latest `## [X.Y.Z]` heading in
>     CHANGELOG.md must all agree. Mismatches are blockers.
> 14. **Wrong bump for the change** — a release PR that adds a feature must be at
>     least a minor bump; a release PR that breaks public API/CLI/config must be a
>     major bump (post-1.0) or call out the break clearly (pre-1.0).

### 2.7 CHANGELOG header (verbatim, `CHANGELOG.md:1-8`)

> All notable changes to this project will be documented in this file.
> The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
> and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
> ## [Unreleased]

**Takeaway:** ollama-marshal is the model to follow almost verbatim — 3-digit
SemVer 2.0.0, contract-driven definitions, an explicit "what counts as breaking"
list, response-shape-is-contract, batched `[Unreleased]` releases, `vX.Y.Z` tags,
single-source-of-truth version + a drift gate. The ports adopt this and **extend
it** for (i) JSON-output-as-agent-contract specifics and (ii) the MCP-parity → 1.0
milestone.

---

## 3. Proposed policy for the new CLIs — MAJOR / MINOR / PATCH

**Adopt strict [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html), 3-digit
`MAJOR.MINOR.PATCH`** (ollama-marshal's model), **not** gstack's 4-digit scheme.
Reasons: these tools are published to GitHub and consumed by third-party agent
CLIs, so they need the industry-standard contract every installer/tooling
understands; the 4th "MICRO" digit is a gstack-private parallel-PR-queue artifact
(§1.3) meaningless to `brew` / `go install` / `git-cliff`.

**The contract has three surfaces** — CLI surface, JSON output schema, runtime
behavior + exit codes. A bump is the **maximum** of the three surfaces' individual
verdicts (if any surface breaks, it's a MAJOR).

### MAJOR (`X`.0.0) — a breaking change to any contract surface

Any change that could break an existing agent invocation or a script/agent that
parses the output. Triggers:

**CLI surface**
- Remove or rename a command, subcommand, or flag (e.g. `events list` → `events ls`).
- Remove or rename a flag's short/long form, or change a flag from taking a value to boolean (or vice-versa).
- Change a flag's meaning/semantics while keeping its name (e.g. `--since` switches from "relative duration" to "absolute date").
- Make a previously-optional flag required, or remove a default that callers relied on.
- Change the meaning of a positional argument or its order.

**JSON output schema** (the agent-facing contract — highest-risk surface)
- Remove or rename a field in the JSON output.
- Change a field's type (`string` → `object`, scalar → array, `"3"` → `3`).
- Change the top-level shape (array-of-objects → object-with-`items`, or add/remove an envelope).
- Change enum/status string values an agent matches on (e.g. `"status":"done"` → `"completed"`).
- Change date/time serialization format or timezone semantics of an existing field.
- Tighten output such that a previously-present field can now be absent (unless it was already documented nullable/optional).

**Runtime behavior**
- Change a default behavior in a user-visible incompatible way (e.g. `send` now requires a confirmation flag it didn't before; a read command now writes).
- Reassign or repurpose an exit code (e.g. `2` meant "not found", now means "auth error").
- Raise the minimum macOS version, or require a new OS permission (Full Disk Access, Automation, Contacts) that a prior version didn't — this can silently break unattended agent use, so treat as MAJOR.
- Remove or change a stable stdout/stderr separation contract (see §5.4).

### MINOR (0.`X`.0 / X.`Y`.0) — backward-compatible capability additions

- Add a new command, subcommand, or flag (existing invocations unchanged).
- Add a new **optional** field to JSON output (agents using the tolerant-reader rule — ignore unknown keys — are unaffected; see §5.2).
- Add a new output *mode* behind a flag (`--format ndjson`) while the default stays stable.
- Add a new capability / data source / MCP-parity feature.
- Add a new distinct non-zero exit code for a case that previously returned a *generic* failure (net-new signal, doesn't repurpose an existing code).
- **Deprecate** (but do NOT remove) a command/flag/field — mark it deprecated in `--help`, docs, and CHANGELOG `### Deprecated`; actual removal waits for the next MAJOR.
- Broaden accepted input (accept a new value where it used to error).

### PATCH (0.0.`X` / X.Y.`Z`) — no contract change

- Bug fix that makes behavior match its documented contract (e.g. a field that was supposed to be populated but was empty).
- Performance improvement with identical surface and output.
- Fix a crash, a race, an AppleScript/EventKit edge case, a chat.db parsing bug — output shape unchanged.
- Docs-only, help-text wording (non-semantic), internal refactor, dependency bump with no surface change, test-only changes.
- Correct a *clearly wrong / undocumented* output value where no reasonable agent could have depended on the broken value (judgment call — if any agent might parse the old value, it's MAJOR, not PATCH).

**Bright-line rule (carry ollama-marshal `CLAUDE.md:334` forward):** *a release that
adds a feature is at least MINOR; a release that breaks any contract surface is
MAJOR (post-1.0) or is explicitly called out as breaking (pre-1.0).* When unsure
between two levels, **round up** — for an agent-consumed contract, an
unexpected break is far more expensive than an over-cautious bump.

### 3.1 Bump-decision quick table

| Change | CLI surface | JSON output | Behavior/exit | Bump |
|---|---|---|---|---|
| Rename/remove command or flag | break | — | — | MAJOR |
| Change flag meaning | break | — | — | MAJOR |
| Remove/rename/retype output field | — | break | — | MAJOR |
| Change status/enum string value | — | break | — | MAJOR |
| Repurpose exit code / change default | — | — | break | MAJOR |
| Raise min macOS / new OS permission | — | — | break | MAJOR |
| Add command / subcommand / flag | additive | — | — | MINOR |
| Add optional output field | — | additive | — | MINOR |
| Deprecate (not remove) surface | additive-mark | additive-mark | — | MINOR |
| New non-zero code for generic failure | — | — | additive | MINOR |
| Bugfix, perf, docs, refactor | none | none | none | PATCH |

---

## 4. Pre-1.0 (0.x) semantics + the MCP-parity → 1.0 mapping

### 4.1 0.x semantics

Follow SemVer item 4 verbatim: *"Major version zero (0.y.z) is for initial
development. Anything MAY change at any time. The public API SHOULD NOT be
considered stable."* Concretely, during 0.x each CLI runs as **`0.MINOR.PATCH`**:

- **`0.MINOR.0`** — features AND breaking changes both land here (breaking is
  allowed pre-1.0, per ollama-marshal `CLAUDE.md:262`, "Minor bumps may include
  breaking changes"). MAJOR stays pinned at `0`.
- **`0.0.PATCH`** — backward-compatible fixes / docs.
- Every breaking change in 0.x is still **loudly documented** in the CHANGELOG
  `### Changed` / `### Removed` with a "BREAKING:" prefix, even though the version
  number can't signal it — agents pinned to a 0.x need the human-readable warning.
- **Recommend pinning consumers to `0.MINOR`** (or an exact `0.MINOR.PATCH`) during
  0.x, precisely because minor is allowed to break. The fleet's pin machinery (§6)
  already does exact pinning, so this is free.

### 4.2 The parity → 1.0 mapping (the headline recommendation)

**A CLI cuts `1.0.0` exactly when it reaches 100% parity with the MCP server it
replaces — i.e. it is a *strict superset* of that MCP.** Until then it stays 0.x.

Define "strict superset / 100% parity" as a **testable checklist**, not a vibe:

1. **Capability parity** — every MCP tool the server exposed has a CLI
   command/subcommand equivalent (map each `mcp__<server>__<tool>` to a CLI
   invocation; zero unmapped tools).
2. **Output parity** — for each capability, the CLI's JSON output contains **every
   field** the MCP tool returned (renamed is fine if documented; *missing* is a
   parity gap). Superset = the CLI MAY return more, MUST NOT return less.
3. **Input parity** — every meaningful MCP tool parameter has a CLI flag/arg.
4. **Behavioral parity** — same authorization model, same destructive-op guards,
   same error semantics; no capability regression.
5. **No open parity gaps** — a tracked parity matrix (per §7) shows 0 red cells.

**Why tie 1.0 to parity rather than a date or "feels done":**

- **It matches the fleet's actual decision point.** The fleet's whole reason to
  build these ports is to *retire the MCP servers*. The decision "is it safe to
  drop the MCP?" is identical to "is the CLI a strict superset?". Making that the
  1.0 line means the version number directly answers the retire question — `1.0.0`
  literally *means* "safe to retire the MCP." (The fleet already treats
  MCP-capability loss as serious: `PRIVATE-PATH-REDACTED` — dropping
  apple-contacts "breaks the graph at the most-referenced node.")
- **It matches SemVer's own 1.0 guidance.** SemVer FAQ: *"If you have a stable API
  on which users have come to depend, you should be 1.0.0."* Agents (the users)
  depend on the output contract; once it's a stable superset of the MCP they
  already depended on, the criterion is met.
- **It gives a crisp, non-arbitrary, *verifiable* milestone.** Parity is a
  checklist you can test in CI (the parity matrix), unlike "we feel confident."
- **Pre-parity honestly reads as 0.x.** While the CLI still lacks MCP capabilities,
  its surface is *still changing to catch up* — which is the exact situation
  "anything MAY change" (0.x) describes. Shipping 1.0 before parity would lie about
  stability and would force a premature MAJOR when the missing capabilities land.

**Corollary — sequencing with MCP retirement:** do **not** retire/unregister an MCP
server until its replacement CLI has shipped `1.0.0` (parity proven) AND all three
agent CLIs have been repointed at the tool. `1.0.0` is the *gate* for the retire
step, not a consequence of it. Keep the MCP and the CLI co-installed across the 0.x
→ 1.0 window (the ports run alongside the MCPs they replace until parity lands).

**HARD STOP — operator-present only (HUMAN-DECISIONS D2).** Parity is necessary but does not
authorize release: no agent may tag `1.0.0` or unregister any MCP server. The pre-1.0 PII re-audit
gate (Asana `GID-REDACTED`) must also be verified and closed first.

### 4.3 Post-1.0

Once at 1.0.0, the §3 contract-driven definitions bind strictly, with a
**deprecation cycle** (ollama-marshal `CLAUDE.md:274`): deprecate in a MINOR (mark
in `--help` + `### Deprecated`), remove no earlier than the next MAJOR. Give agents
at least one MINOR of overlap where both old and new surface work.

---

## 5. Output schema as a versioned contract (agent-parsed JSON)

Because the primary consumer is an AI agent parsing `stdout`, the **JSON output is
the highest-value, highest-risk part of the contract** — treat it as a first-class
versioned artifact, more carefully than the flag surface.

### 5.1 Embed an explicit `schema_version`

Every JSON output carries a top-level integer **`schema_version`** in a stable
envelope, e.g.:

```json
{ "schema_version": 1, "tool": "apple-events", "ok": true, "data": [ ... ] }
```

- `schema_version` is an **integer**, incremented **only** on a breaking change to
  the output's **SHAPE** — a key added-as-required, removed, renamed, or retyped,
  or an enum/exit-code change. Adding optional fields does **not** bump it, and
  neither does a **value-level** break (same keys, same types, a corrected value):
  those ride the CLI **MAJOR** + the CHANGELOG instead. Operator ruling D11-A
  (2026-08-19): `schema_version` answers exactly one question — *"can my parser
  still read this?"* — so it must not churn on value fixes, or it stops being a
  usable parse-compatibility signal. It therefore does NOT step in lockstep with
  every output-affecting MAJOR; only with shape-affecting ones.
- Agents can hard-assert `schema_version == N` and fail fast/loudly on an
  unexpected shape instead of silently misparsing — the single biggest robustness
  win for machine consumers.
- Keep it an integer (not the full SemVer string) so the parse-time check is a
  cheap equality, and so PATCH/MINOR churn never trips a consumer's guard.

### 5.2 Document the tolerant-reader contract

State explicitly in each CLI's README that its JSON output follows the
**tolerant-reader / must-ignore-unknowns** rule, so additive fields stay MINOR:

- Consumers MUST ignore unknown/extra keys (lets the tool add optional fields
  without a MAJOR).
- Key ordering is NOT guaranteed; consumers MUST NOT depend on it.
- A field documented as "optional/nullable" MAY be absent or `null`; consumers
  MUST handle both.
- Only fields listed in the documented schema are contractual; anything
  undocumented is unstable and MAY change in a MINOR/PATCH.

This mirrors ollama-marshal's care with response shapes (`CLAUDE.md:287`) and is
what makes "add an optional field = MINOR" (§3) safe.

### 5.3 Offer a schema selector for graceful MAJOR transitions (optional but recommended)

Support **`--schema-version N`** (and/or honor an env `CLI_SCHEMA_VERSION=N`). When
a MAJOR reshapes the output, keep emitting the previous schema for **one MAJOR of
overlap** on request, so the fleet can migrate all three agent CLIs one at a time
instead of same-day. Default (no flag) = latest schema. Announce the old schema as
deprecated in the MAJOR that introduces the new one; drop it in the following
MAJOR. This turns an output MAJOR from a fleet-wide breakage into a staged rollout.

### 5.4 Stream / exit-code / stdout-vs-stderr contract

These are part of behavior (§3) and also belong in the documented schema:

- **stdout = machine JSON only; stderr = human/diagnostic text.** Never interleave
  progress logs into stdout JSON. Changing this separation is a MAJOR.
- **Exit codes are contractual.** Enumerate them in each README (`0` success;
  distinct non-zero for not-found / auth-denied / permission-missing / upstream
  error / usage error). Repurposing a code = MAJOR; adding a new code for a
  previously-generic failure = MINOR.
- If NDJSON/streaming output is offered, its per-line schema is versioned by the
  same `schema_version` field on each record.
- Recommend a `--json` (or make JSON the default for these agent tools) plus a
  documented **`version --json`** subcommand emitting
  `{ "version": "X.Y.Z", "schema_version": N }` so agents can capability-detect at
  runtime.

---

## 6. Changelog, git-tag, and pin conventions + fleet fit

### 6.1 CHANGELOG — Keep a Changelog 1.1.0 (match both projects)

Both projects already use it. Each CLI's `CHANGELOG.md` header (verbatim from
ollama-marshal `CHANGELOG.md:1-8`) declares Keep-a-Changelog 1.1.0 + SemVer 2.0.0.

- **`## [Unreleased]` at the top; per-PR entries accumulate there** (ollama-marshal
  model, `CLAUDE.md:276`) — do NOT bump per-PR. Subsections:
  `### Added / Changed / Deprecated / Removed / Fixed / Security`.
- Prefix breaking bullets with **`BREAKING:`** (essential during 0.x where the
  number can't signal it).
- **Release-time promotion**: `[Unreleased]` → `## [X.Y.Z] - YYYY-MM-DD`; update
  the single-source version field + tag in the same commit.
- Borrow gstack's **cross-check** (`ship` Step 13): every commit `base..HEAD` maps
  to ≥1 CHANGELOG bullet; lead each bullet with what the agent can now *do*.

### 6.2 Conventional Commits → git-cliff (already the fleet standard)

The fleet already standardizes Conventional Commits and notes git-cliff can
auto-generate a changelog (repo `AGENTS.md`). For the ports:

- `feat:` → MINOR candidate, `fix:` → PATCH candidate, `feat!:` / `fix!:` /
  `BREAKING CHANGE:` footer → MAJOR candidate. This lets **git-cliff derive the
  bump and draft the CHANGELOG** mechanically; a human still confirms the final
  level against the §3 contract table (Conventional-Commit type is a *hint*, the
  contract surface is *authoritative* — a `fix:` that changes an output field is
  still a MAJOR).
- Keep the fleet's existing commit trailers (`Reviewed-by:`, `Co-Authored-By:`) —
  the ports live under the same review gates.

### 6.3 Git tags

- Annotated tag **`vMAJOR.MINOR.PATCH`** per release (matches ollama-marshal's
  `v0.1.0 … v0.6.6` and gstack's `vX.Y.Z.W` shape minus the 4th digit).
- The tag is the immutable release anchor: everything downstream (brew formula,
  go module, pinned clone) references the tag and its commit SHA.
- One tag per release commit; the release commit is the one that promotes
  `[Unreleased]` and bumps the single-source version (drift-gate per §7).

### 6.4 Pin / distribution story — reuse the fleet's existing converge rails

The fleet already pins dependencies three ways, all SHA/version-deterministic and
converged via chezmoi: **Brewfile** (`brew-bundle` + cooldown, software lane),
**`.chezmoidata/skill-repo-pins.yaml`** (cloned repos pinned by 40-hex `sha` +
mandatory `fetch_ref`, converged by `lib/skill-pin-converge.sh`), and
**`.chezmoidata/plugin-pins.yaml`** (marketplace `sha` + `realized_version`). Pick
the rail by how the CLI is built:

**Primary recommendation — Homebrew tap (cleanest fit):** publish each CLI as a
formula in a personal tap (e.g. `robertvitali/tap`) and add
`brew "robertvitali/tap/<cli>"` to `Brewfile.tmpl`. Why this is cleanest:

- **Zero new machinery** — it rides the *existing* `brew-bundle` software-lane
  converge, the dependency-cooldown primitive, and HARD-GATE 7's Brewfile handling.
- **Version + SHA determinism** — the formula pins the release tarball by
  `url` (the `vX.Y.Z` tag) + `sha256`. The git tag ↔ formula map is 1:1; a moved
  tag can't change what installs (sha256 mismatch fails closed). The Brewfile line
  itself is SHA-pinned by the private fleet-config repo commit that edits it (the whole
  repo is chezmoi-source-controlled).
- **macOS-native** — brew is already the fleet package manager on the
  `/opt/homebrew` Apple-Silicon path; these are macOS-only tools.
- To pin an *exact* version fleet-wide, the formula's `version` (and an optional
  `@X.Y` versioned formula for the 0.MINOR pinning of §4.1) is the pin; bumps land
  through the normal gated flow.

**Fallback for pre-1.0 fast iteration or build-from-source — a `cli-pins.yaml`
rail** mirroring `skill-repo-pins.yaml`: a new `.chezmoidata/cli-repo-pins.yaml`
with the same `source` / `sha` / `fetch_ref` / `pin_epoch` schema, converged by a
thin reuse of `lib/skill-pin-converge.sh`'s clone-checkout-health-rollback logic.
Use this only if a CLI must be built from a pinned SHA on each machine (heavier —
needs the build toolchain everywhere). During 0.x, pin to an exact `sha` (matches
§4.1's "pin to 0.MINOR.PATCH because minor may break").

**If a CLI is written in Go:** `go install <mod>@vX.Y.Z` is version-pinnable, but
the fleet has **no** go-install converge rail today — it would need a new pin file
anyway, so the Homebrew tap (a `go_resource`/pre-built bottle formula) is still the
cleaner published path. Don't invent a go-install rail just for these.

**Net:** tag `vX.Y.Z` → tap formula (`url`@tag + `sha256`, `version=X.Y.Z`) →
`Brewfile.tmpl` line → existing `brew-bundle` converge. One release action, one
existing rail, full version+SHA determinism, no new convergence machinery.

---

## 7. Per-CLI release checklist

A deliberate, batched release (ollama-marshal model) gated by the fleet's existing
review/test gates. Run per CLI at each release boundary:

**Pre-release (contract review)**
1. **Classify the bump** against the §3 contract table (CLI surface / JSON schema /
   behavior+exit) — take the max; when unsure, round up. Pre-1.0: a break is a
   MINOR but must be `BREAKING:`-flagged.
2. **Parity check (0.x only)** — update the MCP↔CLI parity matrix. If this release
   completes 100% strict-superset parity, this is the **1.0.0** release (§4.2);
   otherwise stay 0.x.
3. **`schema_version`** — if the JSON output changed **SHAPE** incompatibly (key
   added-as-required / removed / renamed / retyped, or an enum or exit code
   changed), bump the integer and (if supported) wire the `--schema-version`
   fallback for the prior schema (§5.3). A **value-level** break with an unchanged
   shape does NOT bump it — record it in the MAJOR + CHANGELOG (operator ruling
   D11-A, 2026-08-19; this line and the `schema_version` bullet above previously
   contradicted each other, one saying "output change" and the other "shape").

**Verify (tests + review — HARD-GATEs)**
4. Canonical test suite green on the release SHA (HARD-GATE 6): unit + integration,
   including a **golden-output/JSON-schema snapshot test** and an **exit-code
   matrix test** so an accidental output/behavior break fails CI, not an agent.
5. Run the repo-mandated independent review gate and trailer hook. In apple-cli, the three-reviewer
   OMC fan-out replaces codex per `docs/decisions/hot/foundational.md`.
6. Verify OS-permission posture unchanged (or, if changed, it's flagged MAJOR +
   documented) — EventKit / Full-Disk-Access / Automation / Contacts prompts.

**Cut the release**
7. Promote CHANGELOG `[Unreleased]` → `## [X.Y.Z] - YYYY-MM-DD` (Keep-a-Changelog);
   cross-check every `base..HEAD` commit maps to a bullet.
8. Bump the **single source of truth** version (one file — e.g. the manifest /
   `version --json` string) in the **same** release commit.
9. **Drift gate** (ollama-marshal `CLAUDE.md:331`): version string, `--version` /
   `version --json` output, and the latest CHANGELOG heading all agree — mismatch
   is a blocker.
10. Commit (Conventional Commit + fleet trailers), annotated tag **`vX.Y.Z`**, push
    (tests green — HARD-GATE 6).
    **For `1.0.0`, stop before this step and wait for the operator in the live session (D2).**

**Distribute (fleet converge)**
11. Update the tap formula (`url`@`vX.Y.Z` + new `sha256`, `version=X.Y.Z`); bump the
    `brew "…/<cli>"` line (or the `cli-repo-pins.yaml` `sha`+`fetch_ref`) in
    private fleet-config repo. This edit rides the normal commit-gates + HARD-GATE 7
    apply confirmation.
12. Repoint / smoke-test all three agent CLIs (Claude Code, Codex, Antigravity)
    against the new version.
13. **If this is the 1.0.0 parity release:** only now schedule the replaced MCP
    server's retirement (unregister from `.chezmoidata/mcp-servers.yaml`), as a
    separate gated change — never bundled with the CLI release. **Operator-present only:** no
    agent performs this step; D2 and Asana `GID-REDACTED` must both be closed first.

---

## 8. Sources

**Local — gstack** (installed skill suite)
- `~/.claude/skills/gstack/ship/SKILL.md` — Step 12 version bump
  (4-digit `MAJOR.MINOR.PATCH.MICRO`, lines 2498–2560), auto-decide bump levels
  (2500–2506), stop-conditions (744, 754), queue-aware pick (2510–2534),
  idempotency (2441), Step 13 CHANGELOG generation, `## [X.Y.Z.W] - YYYY-MM-DD`.
- `~/.claude/skills/gstack/CHANGELOG.md` (format reference).

**Local — ollama-marshal** (`~/path/to/local/resource`)
- `CLAUDE.md:255-337` — "Versioning" section (SemVer declaration, pre/post-1.0
  table, 1.0.0 commitment, per-PR workflow, "what counts as breaking") + "Bright-line
  Bug Patterns" #13 version-drift and #14 wrong-bump.
- `CHANGELOG.md:1-8` — Keep-a-Changelog 1.1.0 + SemVer 2.0.0 header + `[Unreleased]`.
- `pyproject.toml` — `version = "0.6.5"`, `requires-python = ">=3.11"` (single
  source of truth).
- Git tags `v0.1.0 … v0.6.6` (`git -C ~/path/to/local/resource tag`).

**Local — fleet pin/converge machinery** (`private fleet-config repo`)
- `.chezmoidata/skill-repo-pins.yaml` — SHA (`sha`, 40-hex) + `fetch_ref` +
  `pin_epoch` pin schema; converged by `lib/skill-pin-converge.sh`.
- `.chezmoidata/plugin-pins.yaml` — marketplace `sha` + `realized_version`
  (H1 pin-the-marketplace / H2 verify-realized, fail-closed).
- `Brewfile.tmpl` + `brew-bundle` software-lane converge;
  `private fleet-config repo:docs/decisions/hot/mcp.md`
  (apple-suite parity rationale — dropping an MCP "breaks the graph"),
  `PRIVATE-PATH-REDACTED` (parity-superset precedent).
- `AGENTS.md` — Conventional Commits → git-cliff; cross-CLI parity north star
  (Claude ↔ Codex ↔ agy from one canonical source).

**Web — standards**
- Semantic Versioning 2.0.0 — https://semver.org/spec/v2.0.0.html — item 4
  ("Major version zero (0.y.z) is for initial development. Anything MAY change at
  any time. The public API SHOULD NOT be considered stable."), item 5 ("Version
  1.0.0 defines the public API. The way in which the version number is incremented
  after this release is dependent on this public API and how it changes."), FAQ
  "How do I know when to release 1.0.0?" ("If you have a stable API on which users
  have come to depend, you should be 1.0.0.").
- Keep a Changelog 1.1.0 — https://keepachangelog.com/en/1.1.0/ — `[Unreleased]`
  section + `Added/Changed/Deprecated/Removed/Fixed/Security` types.
