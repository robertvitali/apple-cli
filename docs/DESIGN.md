# apple — design

One Swift binary, `apple`, that ports the fleet's Apple-app MCP servers to the
command line. Motivation: cross-CLI parity (one binary works in Claude Code,
Codex, agy with zero per-CLI registration) + context savings (no MCP tool schemas
loaded every session) + owned longevity.

## Architecture

- **Executable `apple`** (`Sources/apple`) composes six domain subcommands via
  swift-argument-parser.
- **`AppleKit`** — shared core every domain uses: `Output` (the JSON envelope +
  `schema_version`), `AppleError` (contractual exit codes + `error.type` strings),
  `AppleScriptRunner` (osascript with stdin closed), `TestMode` (sandbox gate).
- **`EventKitCore`** — one EventKit engine shared by Calendar + Reminders (models,
  `EKEventStore` access, recurrence/alarms, permission preflight). Built once.
- **`{Domain}Kit`** — each domain's command tree + domain logic. Mechanisms:
  Messages = chat.db + AppleScript; Mail = Envelope-Index SQLite + AppleScript +
  `.eml`; Contacts = Contacts.framework; Notes = AppleScript + NoteStore.sqlite
  (gzip+protobuf checklist); Calendar/Reminders = EventKit.

## Write model

Writes EXECUTE by default (oracle parity); `--dry-run` / `APPLE_DRY_RUN=1` preview, and
`APPLE_TEST_MODE` / `--test-mode` engages an opt-in SANDBOX policy — a label + self-recipient
restriction on the real store, surfaced as `sandbox: true` in the success envelope and
`error.sandbox: true` on a sandbox-policy refusal. Full spec: [`write-model-v2.md`](./write-model-v2.md).

## Output = versioned contract

`stdout` carries only the JSON envelope; `stderr` carries human/diagnostic text.

```json
{ "schema_version": 1, "tool": "<domain>", "ok": true,  "data":  { ... } }
{ "schema_version": 1, "tool": "<domain>", "ok": false, "error": { "type": "...", "message": "..." } }
```

On an **authorization failure** the error object carries two further keys, matching what the
MCP servers return so a client can act on the failure instead of parsing prose:

```json
{ "schema_version": 1, "tool": "contacts", "ok": false,
  "error": { "type": "authorization_denied",
             "message": "Contacts access not granted (status=denied).",
             "status": "denied",
             "remediation": "Contacts access was denied. Open System Settings → …" } }
```

- `status` — the TCC state: `denied`, `restricted`, or `notDetermined`. Branch on it: retrying
  after a prompt can succeed for `notDetermined`, is pointless for `restricted` (MDM), and needs
  a visit to System Settings for `denied`.
- `remediation` — user-facing copy describing how to grant access. Absent when there is nothing
  useful to say — notably the permission-prompt-timeout case, where the dialog is already on
  screen.

Both keys are **omitted, not `null`**, on errors with no authorization dimension, so
`if "status" in error` is a valid test. Only `contacts` populates them today.

Consumers must ignore unknown keys (tolerant reader); key order is not
guaranteed (we sort keys for snapshot stability). `schema_version` is an integer
that steps only on a breaking output change.

### Exit codes (contractual)

`0` success · `64` usage · `65` not-found · `69` upstream/app-unavailable ·
`70` unknown/internal · `77` permission-denied (TCC). Repurposing a code = MAJOR;
adding a new code for a previously-generic failure = MINOR.

## Versioning + retirement

Full policy in [`versioning-policy.md`](./versioning-policy.md) (see its 2026-08-29
platform-keyed amendment) and AGENTS.md "Versioning + releases". Summary:

- One version for the whole binary, **platform-keyed**: MAJOR = the supported macOS
  major (first release `26.0.0` for macOS 26; MAJOR moves only on macOS adoption),
  MINOR = feature additions, PATCH = fixes/docs/small updates.
- Contract = CLI surface + JSON output schema + behavior/exit codes. A breaking
  change to any of them bumps the envelope `schema_version`, is flagged `BREAKING:`
  in the changelog, and ships in (at least) a MINOR — never MAJOR.
- Pre-release (until the first tag): surface may change; breaking changes flagged.
- **`v26.0.0` (the first release) = all six domains at verified strict-superset MCP
  parity** — the milestone previously named `1.0.0`.
- Releases are cut by `.github/workflows/release.yml` (workflow_dispatch,
  operator-instructed only).
- **Retirement gate — EXECUTED 2026-08-30:** both conditions were met (v26.0.0 cut;
  e2e validation complete) and the six MCPs were retired together on explicit live
  operator instruction (private fleet-config repo `REVISION-REDACTED`; hosts converge on their next
  whole-tree apply). The gate's rule stands for any future re-add/re-retire cycle:
  never per-domain, and **operator-present only (HUMAN-DECISIONS D2)** — no agent may
  cut a release or unregister an MCP server without a direct in-session instruction.

## Testing

Three tiers (see AGENTS.md): logic (swift-testing), CLI smoke (bats), and live
(real Apple frameworks against a sandbox, gated by `APPLE_TEST_MODE`). Parity is
verified by diffing CLI output against the live MCP tool output (the oracle) —
reads freely, writes only in the sandbox.

## Per-domain specs

See [`port-specs/`](./port-specs/): `messages.md`, `mail.md`, `contacts.md`,
`notes.md`, `calendar-reminders.md` — each has the full MCP capability manifest,
the CLI capability matrix, the fork/reference base, the parity delta to build,
and a build-cost estimate.
