# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pre-1.0: the CLI surface and JSON output are not yet stable; a MINOR (`0.x`) may
include breaking changes, which are flagged `BREAKING:` in the notes below. The
binary cuts `1.0.0` when all six domains reach verified strict-superset parity
with the Apple MCP servers they replace.

## [Unreleased]

### Added
- Project scaffold: Swift package with the `apple` executable and six domain
  command stubs (Messages, Mail, Contacts, Notes, Calendar, Reminders); shared
  `AppleKit` (JSON output envelope + `schema_version`, error/exit-code taxonomy,
  AppleScript runner, test-mode) and shared `EventKitCore` (Calendar + Reminders).
- CI (GitHub-hosted macOS): `swift build` + `swift test` + `bats` smoke tests.
- Design + per-domain port specs under `docs/`.
- **Read parity** across all six domains, verified against the live Apple MCP oracles
  (CLI JSON is a field-superset of every MCP field).
- **Mail live write surface**, wired behind a fail-closed safety model
  (`--execute` + `--test-mode` flag + `APPLE_TEST_MODE=1` env, self-only recipient
  allowlist for outbound, and a subject-label check that lets a run mutate only
  `apple-cli-test…`-labeled data it created): `send`, `reply`, `forward`,
  `mark` read/unread, `flag`/unflag (+color), `move`, `delete`-to-Trash,
  `mailboxes create`, `rules` create/enable/disable/delete, `draft`
  create/list/delete. Permanent-delete and empty-trash are hard-refused.
  Live-created rules are self-scoped to the test label, non-destructive, and
  force-disabled so an enabled test rule can never act on real mail.
- Mail write-safety **tests**: logic-tier gate tests (`Tests/MailKitTests/WriteSafetyTests.swift`),
  CLI-tier refusal tests (`bats/mail.bats`), and a repeatable self-cleaning live
  e2e (`bats/live/mail-writes.sh`).
- `SQLiteReader` opens live (non-copied) Apple stores with `immutable=1`, so reading
  a store another app holds open no longer errors "database is locked".

### Changed
- **BREAKING:** Mail write commands (`move`/`mark`/`flag`/`delete`/`rules`/`draft`/`send`/
  `reply`/`forward`) now perform real Mail.app mutations under `--execute`; they were
  preview-only before. `--execute` WITHOUT the two-factor test gate now returns
  `exit 77` (`safety_violation`) instead of a `exit 0` preview envelope. Executed
  envelopes add `applied` / `not_found` / `executed` fields (additive → MINOR).

### Known parity gaps (Mail — still preview-only vs the MCP union)
These MCP-union write capabilities are intentionally NOT yet wired to live mutation
(they emit a preview/note); they must land before Mail is a 100% strict superset:
- `rules update` (in-place patch of an existing rule)
- `attachments save` (live AppleScript content fetch to disk)
- HTML / attachment **send** (the `.eml` is generated but not delivered)
- `send --mode draft|open`, `draft send|open` (routed to notes)
- `move --gmail-mode` (Gmail copy+delete label semantics — rejected as unwired)
- `reply`/`forward` quote the Envelope-Index snippet, not the full original body
