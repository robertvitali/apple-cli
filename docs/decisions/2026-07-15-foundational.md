# Foundational decisions — 2026-07-15 (scaffold)

Decisions locked at scaffold time, before the six domain worktrees branch.

## Code review: OMC reviewers only, skip codex
This repo uses the OMC reviewers (`oh-my-claudecode:code-reviewer` + `security-reviewer` +
`critic`) for every review and **deliberately skips codex** — an explicit, standing local
override of the fleet's global codex-first review gate (HARD-GATE 1), chosen by the operator
for this project. Re-review per the standard rules (loop until material findings resolved);
this is not a one-pass exception for the domain builds.

## Output: JSON by default; property names are the wire keys; ISO-8601 dates
`stdout` is the JSON envelope by default (the machine contract). `--text` (`GlobalOptions`)
is a human opt-out, NOT part of the versioned contract. No key-case conversion — payload
struct property names are the wire keys verbatim (snake_case). Dates serialize as ISO-8601.
Resolves the DESIGN-vs-port-spec "JSON default vs `--json` flag" ambiguity.

## Error contract: unified `AppleError` + `runGuarded` boundary
One `AppleError { type, message, exitCode }` thrown from a `runGuarded(tool:) { … }` body
emits the JSON error envelope AND sets the contractual exit code atomically, so no thrown
error escapes to a non-JSON stderr/exit-1. Domains throw `AppleError.*`, never hand-pair
`emitError` + `throw ExitCode`.

## Safety: track-and-cleanup, not a sandbox
No dedicated sandbox. Live tests + MCP-parity writes go to real stores as clearly-labeled
(`apple-cli-test*`) test items, logged to `TEST-CLEANUP.md`, deleted via the MCP afterward.
`TestMode` provides the write-model-v2 sandbox primitives (`sandboxActive(flag:)`, the
`truthyEnv` fail-loud env readers); each domain applies its own fail-closed label guard
(`requireLabeled` / `requireLabeledReminder` / `ContactsLabel.isLabeled`) threaded with
`sandboxActive`.
Messages send only to the operator's own number; Mail drafts/self only. Never a dangerous
action (real-recipient send, deleting/mutating pre-existing real data) autonomously.

## Toolchain: swiftly + swift-testing, no Xcode
Tests use swift-testing (`import Testing`), run via the swiftly-managed swift.org toolchain
(`PATH="$HOME/.swiftly/bin:$PATH"`). macOS XCTest needs full Xcode, which we avoid. Fleet
toolchain management is tracked in the private fleet-config repo repo.

## EventKitCore: build once, Calendar-first
Calendar and Reminders share `EventKitCore`. Land the real engine first in the Calendar
worktree; Reminders branches/rebases onto it. Open option (see critic): an interface-first
`EventKitCore` landed as a tiny first commit could let both run fully parallel against a
frozen API — revisit if the serialization proves costly.

## Deferred hardening (follow-ups, not blockers)
- SHA-pin `actions/checkout` + Dependabot (CI currently `@v4`).
- Per-domain living parity tracker (`<domain>.PARITY.md`) + golden-JSON snapshot / exit-code
  matrix test helpers + a sandbox/test-data bootstrap command.
- Confirm a subagent-driven-development lane can actually reach the deferred `mcp__apple-*`
  oracle tools; if not, the MCP-diff acceptance gate needs a different mechanism.
- No pre-commit trailer hook in this fresh repo — trailer discipline is convention-only here.
