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

## Output = versioned contract

`stdout` carries only the JSON envelope; `stderr` carries human/diagnostic text.

```json
{ "schema_version": 1, "tool": "<domain>", "ok": true,  "data":  { ... } }
{ "schema_version": 1, "tool": "<domain>", "ok": false, "error": { "type": "...", "message": "..." } }
```

Consumers must ignore unknown keys (tolerant reader); key order is not
guaranteed (we sort keys for snapshot stability). `schema_version` is an integer
that steps only on a breaking output change.

### Exit codes (contractual)

`0` success · `64` usage · `65` not-found · `69` upstream/app-unavailable ·
`70` unknown/internal · `77` permission-denied (TCC). Repurposing a code = MAJOR;
adding a new code for a previously-generic failure = MINOR.

## Versioning + retirement

Full policy in [`versioning-policy.md`](./versioning-policy.md). Summary:

- One SemVer for the whole binary. Contract = CLI surface + JSON output schema +
  behavior/exit codes; a bump is the **max** of the three (any break → MAJOR).
- Pre-1.0 (`0.x`): surface may change; breaking changes flagged `BREAKING:`.
- **`1.0.0` = all six domains at verified strict-superset MCP parity.**
- **Retirement gate:** the old Apple MCP servers stay registered until the binary
  hits `1.0.0` AND agent-driven end-to-end validation proves every domain works;
  then they're retired together (unregistered from private fleet-config repo
  `.chezmoidata/mcp-servers.yaml`). Do not retire per-domain.

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
