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
- **Mail rule live-actions `move_to` / `copy_to` / `flag_color`** (audit gap B):
  `rules create` and in-place `rules update` now WIRE these actions (previously
  refused), matching the MCP oracle's `create_rule`/`update_rule` action set.
  Correctness details, each verified live against the oracle:
  - **`should move/copy message` is the activate/clear primitive.** Setting the
    `move/copy message` target alone leaves the action INACTIVE; the paired
    `should move/copy message` boolean is what turns it on. To CLEAR a move/copy
    action, `set should move message … to false` — Mail refuses
    `set move message … to missing value` (`-1700`) and `delete move message …`
    is a silent no-op. (The former mapping set targets that never fired and
    "cleared" via a no-op; now fixed.)
  - **In-place `--action` is a true wholesale replace** (matching op 28): the
    modeled action set (`should move`/`should copy`/`mark read`/`mark flagged`/
    `mark flag index`/`delete message`) is RESET, then the new plan reapplied — so
    dropping an action by omitting it from `--action` clears it. Ordering mirrors
    the oracle's Tahoe workarounds: `enabled` is set AFTER the action reset (an
    earlier set is silently reverted) and a rename is applied LAST (renaming
    invalidates the rule reference for later property writes).
  - **`_check_supported_actions` parity + safety refusal:** an update to a rule
    whose EXISTING actions include something the CLI can't model (run-script /
    redirect / reply-text / play-sound / forward-text / highlight / color-message)
    is REFUSED (`safety_violation`), never silently preserved-and-misrepresented
    (in place) or dropped (recreate) — mirroring the oracle's refusal and closing a
    run-script (RCE-on-incoming-mail) survival path on hand-made labeled rules. The
    probe FAILS CLOSED (an unreadable property or script error refuses the update,
    not proceeds blind). **Deliberate safety-stricter divergence:** the CLI ALSO
    refuses a rule carrying a `forward message` (auto-forward-to-others — a named
    dangerous action per AGENTS.md); the oracle instead clears it on an
    action-update, but that would leave it live on an enable-only update, so the
    CLI refuses any update to such a rule (edit it in Mail.app). A CLI-authored
    rule never carries any of these, so normal flow is unaffected.
  - **Flag-color index parity fix:** `MailFlagColor` now uses macOS Mail's ACTUAL
    (non-obvious) `mark flag index` order — `orange=0, red=1, yellow=2, blue=3,
    green=4, purple=5, gray=6` — matching the oracle's `get_flag_index`. The prior
    enum used the intuitive-but-wrong `red=0` order, so `flag --color red|orange|
    green|blue` (and rule `flag_color`) set the WRONG color and the read path named
    flags wrong; corrected in one place (write + read share the table) and pinned
    to the oracle's literal values by a parity test. **BREAKING (0.x):** the
    `flag_color` integer for those four colors changes.
  - **Safety:** wiring `move_to`/`copy_to` on an in-place update cannot also
    `--enabled` the rule in the same command (its existing conditions aren't
    re-verified self-scoped) — activation must be a separate `rules enable`.
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
- **Mail `move --gmail-mode`** (gap 5, parity with s-morgan `move_messages(gmail_mode=True)`):
  routes the live move through the Gmail copy+delete dance — `duplicate` the located message into
  the destination mailbox, then `delete` the ORIGINAL to Trash (recoverable; verb-for-verb the
  oracle's action list). Runs inside the SAME gated mutation closure as a plain move (two-factor
  test gate + per-message `apple-cli-test` subject-label check, all-or-nothing) — no gate weakened;
  dry-run previews carry `gmail_mode` in the detail. Documented semantics (both oracle-identical):
  the two verbs are NOT atomic — a failure between them can leave the copy in place with the
  original untouched, and a retry re-duplicates (surfaced via the `applied`/`not_found` lists,
  which are richer than the oracle's bare count); the destination is resolved WITHIN the message's
  own account (same model as plain `move`; the oracle resolves against a caller-given account —
  observable only for cross-account moves, which the per-message locator scopes away). Live
  observation on a real label-backed account: the server can COLLAPSE the same-Message-ID copy (Trash
  wins), so the end state may be "in Trash only" — inherent to the verb sequence and identical
  under the oracle; validated on a non-label-backed account (no dedup) that the duplicate genuinely lands.
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

CLOSED (`draft send` + `draft create` sender/cc/bcc — 2026-07-22): `draft send` now delivers an
existing Drafts item (`manage_drafts action=send`), and `draft create` honors `--account` (the
draft's sender identity) + `--cc` / `--bcc`.
- **The -1708 mechanism (a CLI-exceeds-oracle win):** Mail throws `-1708` ("doesn't understand the
  send message") on `send <stored Drafts message>`; the patrickfreyer oracle's `manage_drafts
  action=send` hits the SAME bug and returns the error string. The working path: `open` the draft
  (which registers a sendable `outgoing message`), locate that outgoing message by its UNIQUE
  labeled subject (an id-diff snapshot FAILS — re-opening an already-open draft reuses its outgoing
  message with no new id, and Mail can populate the outgoing subject lazily), re-verify recipients,
  `send` it, then best-effort delete the draft (action=send consumes a draft).
- **Recipient safety:** a draft's recipients are PRE-SET, so `draft send` reads the stored draft's
  own to/cc/bcc and verifies EVERY address against the self-only allowlist BEFORE opening anything —
  a draft addressed to any non-self recipient is refused fail-closed (`exit 77`), never opened or
  sent. Mail's outgoing store is SHARED with the operator's live compose windows, so the send only
  targets an outgoing message carrying the unique test subject AND re-verifies its recipients before
  dispatch (defense in depth).
- Live-validated self-only: a draft created with `an explicit non-default --account` (≠ the default
  send account) + a `--cc` to a second self address was sent, and delivery confirmed `From` the
  --account address to BOTH the `to` and the `cc` mailbox; the draft was consumed. Negative case: a
  draft to a non-self address refused fail-closed before any open.
- Review hardening (OMC code/security/critic fan-out + an adversarial verification workflow): the
  in-script allowlist helper fails CLOSED on empty/`missing value` recipient addresses (an empty
  address can no longer masquerade as the all-clear return); its comparison uses `considering
  diacriticals but ignoring case` to match Swift `guardOutbound`'s `.lowercased()` exact semantics
  (previously AppleScript `is` folded diacritics too, making this self-only gate strictly more
  permissive than every other outbound path); `open`/`send` throws now surface as a distinct
  `senderror:` result instead of being swallowed into a misleading `not_found`; the recipient-report
  is built BEFORE `send` so nothing that can throw runs after dispatch (no misleading "retry" →
  duplicate-send); the safety-critical stdout→result mapping is extracted to a pure
  `DraftSendResult.parse` with a logic-tier regression lock (`WriteSafetyTests`); and a successful
  `draft send` reports the verified recipients in the envelope's `to`.
- Test-coverage note (tracked as a live-tier check): the recipient allowlist verification itself
  (`firstDisallowed`) lives in AppleScript and CANNOT run in CI — only its string→enum plumbing is
  logic-locked. It is exercised by the on-device positive+negative live runs; a future edit to the
  in-script allowlist logic must be re-validated live. The envelope `to` on `draft send` lists ALL
  verified dispatched recipients (to + cc + bcc merged), not only the `to`-class — every one is
  allowlist-verified self, so no leak, but the field's meaning is "verified recipients", not "--to".
- Behaviour notes / known divergences (contained by the self-only gate): `--draft-subject` matches the
  EXACT (case-insensitive) subject for send/open/delete, NOT a keyword like the oracle's
  `manage_drafts` — deliberate (timestamp-unique test subjects make keyword-find moot, and exact is
  safer for a send); `draft send --account` filters by account NAME (vs `draft create --account`,
  which resolves to the send ADDRESS), so a name works but a UUID does not; the best-effort
  post-send draft delete removes ALL exact-subject labeled matches (one, in the unique-subject test
  flow); and attachment preservation across the open-then-send of an attachment-bearing draft is
  untested (CLI-created drafts have no attachments).

Still open (contained by the self-only gate; not safety-critical) — tracked follow-ups:
- `forward` re-composes a plain-text quote via `send()` instead of Mail's native `forward` verb
  (loses original formatting/attachments).
