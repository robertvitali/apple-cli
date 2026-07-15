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
