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
  `mailboxes create`, `rules` create/update/enable/disable/delete, `draft`
  create/list/delete. Permanent-delete and empty-trash are hard-refused.
  Live-created rules are self-scoped to the test label, non-destructive, and
  force-disabled so an enabled test rule can never act on real mail.
- **Mail `rules update`** (live patch): metadata (name/enabled/match/actions) is
  modified in place; a condition change is applied as a whole-rule
  delete-and-recreate, because Mail's `delete rule condition` AppleScript crashes
  Mail (`-609`) and `make new rule` with a duplicate name silently drops
  conditions. The rebuilt rule is created disabled, its conditions are VERIFIED to
  have attached (a 0-condition rule would match all mail), then re-enabled only if
  it was enabled. The self-scoping + non-destructive-action invariant is shared
  with `rules create` via `RuleLiveGuards`. **Two documented divergences from the
  MCP's in-place `update_rule`** (unavoidable given the Mail bugs above): a
  condition-only update (a) **moves the rule to the end of the rules list**, and
  (b) **resets its actions** to the carried `mark_read`/`mark_flagged` set — a
  non-mark action set manually in Mail.app is not preserved. Both are surfaced in
  the command's JSON `note`; on a recreate failure the envelope includes the full
  rule spec needed to rebuild it by hand (the old rule is deleted first).
- **Mail `attachments save`** (live export): saves a message's attachment bytes to
  disk via AppleScript (a read/export — nothing in Mail is mutated; gates on
  `--execute` only). Selection is POSITIONAL (`--indices` addresses
  `item i of mail attachments`, matching MCP A — never a name-collapse that would
  mis-save duplicate-named attachments); `--name` selects by exact name; both
  default to all. `--dir` saves multiple (basename-safe, zip-slip-guarded, and
  de-collided so same-named siblings never overwrite); `--out` renames a single
  selected attachment to an exact path (MCP B `save_path`). A pre-existing file is
  skipped (never clobbered) and a symlink at a destination refuses the export; the
  `not_saved` field + `note` reconcile requested-vs-saved so a short save is never
  a silent success. Byte-parity verified against the on-disk attachment.
- **Mail HTML / attachment `send` + `reply`** (Option A). **Attachment send** (plain body +
  file attachments) delivers via AppleScript `make new outgoing message` + `make new
  attachment … at after the last paragraph` + `send` — matching s-morgan
  `send_email_with_attachments` exactly; verified live self-only (delivered, attachment
  received). **HTML** has two paths, because Mail's AppleScript `content` is plain-text only
  (assigning HTML stores literal markup): the reliable DEFAULT (`--html` alone) builds a
  multipart `.eml` (`X-Unsent: 1`, plain + HTML alternative) and OPENS it as a rendered,
  ready-to-send compose window via `/usr/bin/open -a Mail` (matches patrickfreyer
  `create_rich_email_draft` `open_in_mail`) — the operator clicks Send; and an explicit opt-in
  `--gui-send` flag performs the GUI-keystroke AUTO-send (NSPasteboard HTML injection → visible
  compose window → System Events Tab/Cmd-A/Cmd-V/Cmd-Shift-D), matching patrickfreyer
  `compose_email` `body_html`. `--gui-send` is NEVER the default: it needs Accessibility
  permission, steals focus, and is timing-fragile, so it is quarantined behind the flag. Every
  path — plain, attachment, HTML open, HTML gui-send — passes the SAME self-only `guardOutbound`
  before any Mail action; recipients are set programmatically before any window is shown, so even
  the GUI Cmd-Shift-D send can only reach a self-allowlisted address. The `send`/`reply` preview
  gains an additive `opened` field (true when the reliable HTML path opened a compose window).
- **Mail draft / compose-mode surface** (gap 4, parity with patrickfreyer `manage_drafts` +
  `compose_email(mode)` + `create_rich_email_draft`): `send --mode open` (build the `.eml` and open
  a rendered compose window for review — any body type, no send); `send --mode draft` (plain /
  attachment bodies save DIRECTLY to Drafts via AppleScript `save`; **HTML** writes the rendered
  `.eml` + a note on how to file it, because Mail can't save an HTML draft headlessly — see below);
  `draft open` (open an EXISTING labeled draft, located by subject with stable indexed refs, no
  send); `draft-rich --open` / `--save-as-draft` (open the generated `.eml` in a review window).
  Every compose-window open is self-only `guardOutbound`-gated (test-mode + allowlist), matching
  `send --mode open`; draft saves require test-mode + a labeled subject. No draft/open path reaches
  an AppleScript `send`. `send` gains an additive `drafted` field.
  - **HTML-draft limitation (matches the reference):** Mail's AppleScript `content` is plain-text
    only, and a LaunchServices-opened `.eml` window never surfaces in `outgoing messages` to be
    saved — so an HTML draft can't be filed to Drafts headlessly. `send --mode draft --html` and
    `draft-rich --save-as-draft` therefore write the rendered `.eml` and tell the operator to open
    it + Cmd-S (rather than force-open a window that can't auto-save and can't be closed
    programmatically). Plain/attachment `--mode draft` files a real Drafts entry.
  - **Deliberate over-restriction vs the oracle (tracked for 1.0):** the reference opens a compose
    window to any recipient; the CLI's opens are self-only-gated in the pre-1.0 fail-closed posture.
    Relaxing non-sending opens to any recipient (they're draft-equivalent per the Safety model) is a
    tracked 1.0 decision.
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
- `draft send` (deliver an EXISTING Drafts item — `manage_drafts action=send`) is not yet wired
  (deferred; needs recipient-verification since a draft's recipients are pre-set)
- `move --gmail-mode` (Gmail copy+delete label semantics — rejected as unwired)
- `reply`/`forward` quote the Envelope-Index snippet, not the full original body

### Validation status (Mail HTML/attachment send)
- Attachment send + HTML **open** path: verified live (self-only) — delivered attachment
  confirmed; compose window opened + closed clean.
- HTML `--gui-send` (GUI-keystroke auto-send): implemented, build-green, and self-only-guard
  regression-locked in `bats`; its live keystroke-send is a **live-tier, operator-present**
  check (needs Accessibility permission + steals focus), pending — like other TCC-gated live
  paths, it is not CI-validatable. A review-hardening guard asserts the frontmost Mail window is
  the compose window this call created (subject-title match) before the Send keystroke, and
  refuses fail-closed otherwise, so the blind Cmd-Shift-D can never fire on a stray compose
  window carrying a non-self recipient.

### Parity items from the OMC review (2026-07-20)
CLOSED in the follow-up batch (each verified):
- **`--account` sender-selection** now honored on the plain / attachment / `--gui-send` paths
  (resolves `--account` → the account's address and `set sender`; the open path uses it as the
  `.eml` `From:`). Live-validated: a send with `--account` set delivered with that account's
  address as `From`, not the default account. New `sender_address` preview field; an unknown
  account is `not_found` before any send.
- **Attachment type + sensitive-dir validation** folded into `resolveAttachmentPath`: dangerous
  executable/script extensions blocked (s-morgan `validate_attachment_type`), sensitive dirs
  (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.claude`, `~/.config`, `Library/{Keychains,LaunchAgents,
  LaunchDaemons}`) refused, with symlink resolution first so a link can't bypass the check
  (patrickfreyer). The 25 MB size cap already landed.
- **`--bcc` on the reliable HTML-open path**: `EmlBuilder` gains an opt-in `emitBcc` (default
  false — safe for a wire send); the open paths (`send`, `reply`, and `draft-rich`) pass it true so
  the compose-window `.eml` carries a `Bcc:` header (Mail moves it to the bcc field and strips it on
  send). The `.eml` is never wire-sent, so no leak.

Review hardening (second OMC pass): the dangerous-extension match uses filename `endswith` (so a
file named literally `.sh` is blocked, matching s-morgan); the sensitive-dir check runs against
both the resolved and the tilde-expanded path (so a symlinked sensitive dir can't bypass it).

CLOSED in a later batch: `reply` / `forward` now honor `--account` as the send-from identity
(resolved to the account's address on the live path, mirroring `send`; new `sender_address`
preview field on both), and `draft-rich`'s live-open path resolves `--account` to a real From
ADDRESS (a raw account name is a malformed `From:` Mail ignores; the headless default keeps the
raw fallback so it never launches Mail).

Still open (contained by the self-only gate; not safety-critical) — tracked follow-ups:
- `forward` re-composes a plain-text quote via `send()` instead of Mail's native `forward` verb
  (loses original formatting/attachments).
- `draft send` (send an existing Drafts item) — deferred (see Known gaps above).
- `draft create` ignores `--account` as the draft's sender identity (the oracle's
  `manage_drafts` create sets it) and drops `--cc`/`--bcc` (declared but not passed to
  `createDraft`).
