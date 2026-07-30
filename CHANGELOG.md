# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pre-1.0: the CLI surface and JSON output are not yet stable; a MINOR (`0.x`) may
include breaking changes, which are flagged `BREAKING:` in the notes below. The
binary cuts `1.0.0` when all six domains reach verified strict-superset parity
with the Apple MCP servers they replace.

## [Unreleased]

### Parity audit (2026-07-30) — Mail is NOT yet a strict superset
A full re-audit of Mail against BOTH oracles (27 tools in s-morgan-jeffries@0.6.0 +
24 in patrickfreyer@3.1.3, 101 capability rows, every claimed gap put through an
adversarial refutation pass that defaulted to "refuted") returned **45 confirmed
gaps**, 16 refuted. Mail therefore does NOT meet this repo's one rule yet, and the
1.0.0 tag stays blocked. The confirmed list is tracked in the Asana Mail parent;
the batches landed so far are below. Earlier notes in this section that implied Mail
was one item away from parity were understated.

### Fixed — Mail compose is now a real reply/forward (confirmed gaps)
- **BREAKING (behavior):** `mail reply` now uses Mail's native `reply` / `reply to
  all` verb instead of composing a new "Re: " message, and `mail forward` uses the
  native `forward` verb. Only the native verbs set the `In-Reply-To` / `References`
  threading headers, mark the original's replied-to / forwarded-to state, and (for
  forward) carry the original's **attachments** and rich formatting — a re-composed
  plain-text quote silently dropped all of that. Both oracles use the native verbs.
  The reply body is PREPENDED to Mail's own quoted original (the s-morgan oracle
  overwrites `content`, losing its quote, so the CLI keeps more than the oracle).
- `mail reply` / `mail forward` now return `reply_id` / `forward_id` — the id of the
  newly-created message (oracle A wire keys). Additive.
- `mail reply`'s emitted `to`/`cc`/`bcc` now report what MAIL actually addressed,
  not the CLI's pre-send prediction. On this one command the CLI does not choose the
  recipients, so the prediction could differ (Reply-To, reply-all expansion,
  self-dedupe) from where the mail really went.
- **BREAKING (behavior):** `mail flag --color none` now UNFLAGS. Oracle A derives
  `flagged_status = flag_color != "none"` and maps `none` to flag index -1, so a
  caller porting `flag_message(ids, flag_color="none")` expected an unflag; the CLI
  previously set a colourless flag — the opposite of the caller's intent. Unflagging
  now also resets `flag index` to -1, so a stale colour cannot be resurrected by a
  later re-flag in the Mail UI. `flag_color` is emitted alongside the pre-existing
  `color` key.
- `mail move` / `mail move --gmail-mode` accept a nested `"Parent/Child"`
  destination (oracle B `to_mailbox`). The exact flat name is resolved FIRST, so a
  mailbox whose own name contains a slash — Gmail's `[Gmail]/All Mail` — is still
  addressable; oracle B splits unconditionally and cannot reach those. An
  unresolvable destination is now a precise `not_found` instead of an opaque
  AppleScript error.

### Fixed — Mail templates render (confirmed gaps)
- **BREAKING (behavior):** `mail templates render` now FAILS on an unresolved
  placeholder with `error.type = "missing_template_variable"` (oracle A's wire
  string), naming every missing name sorted and de-duplicated across subject and
  body. It previously left `{token}` literal, so an un-substituted
  `{recipient_name}` could flow into outbound mail.
- `mail templates render --message-id` with an unresolvable id is now
  `error.type = "message_not_found"` (oracle A raises `MailMessageNotFoundError`)
  instead of silently rendering with only `today`.
- `recipient_email` / `recipient_name` / `original_subject` now follow the oracle's
  fallback chain (parsed address → raw sender field; display name → email) and are
  always present once a message resolves, instead of being omitted for an empty
  column.
- **BREAKING (behavior):** `{today}` is now the LOCAL calendar date, matching
  Python's `date.today()`. It was UTC, so every render made in the local-evening
  UTC-offset window substituted TOMORROW's date into outbound text.

### Fixed — Mail rules + input validation (confirmed gaps)
- `rules create` / `update` / `enable` / `disable` / `delete` now emit the oracle's
  wire names alongside the CLI's originals: `rule_index`, `name`, `enabled`,
  `deleted_name`. `rules create` reports the new rule's index (previously absent).
- A missing rule index is now `error.type = "rule_not_found"` (oracle A's typed
  error) rather than the generic `not_found`, so a consumer can tell a bad rule
  index from a missing message or mailbox. Exit code is unchanged (65).
- `mail search --sort` now rejects anything but `date_desc` / `date_asc` (oracle B
  raises here). It previously accepted any token, silently sorted `date_desc`, and
  echoed the bogus token back as `sort` — reporting a sort it had not applied.
- `mail mailboxes create` now rejects an empty `--name`, an empty path segment, and
  the AppleScript-hostile character set oracle B blocks (`\ " < > | ? * :` and
  control characters). `--name ""` previously returned `ok: true` with an empty path.

### Fixed — outbound safety hardening (found in review of the above)
- The self-only outbound guard is now ONE implementation shared by every script that
  dispatches a message. The native-compose path had grown a second, weaker
  comparator that folded diacritics (so an allowlisted `me@sélf.test` would match a
  real `me@self.test`) and treated an unreadable recipient address as all-clear.
  Both are fail-OPEN bugs the existing `collectAddrs` / `firstDisallowed` pair
  already closed; that pair is now the only comparator.
- A native reply's recipients are chosen by MAIL, not the caller, so the guard
  re-reads the created message's real to/cc/bcc. That readback now: polls (Mail can
  populate recipient collections lazily, and an empty read must never read as "no
  disallowed recipients"), refuses a ZERO-recipient message ("all allowlisted" is
  vacuously true of the empty set), and re-verifies immediately before `send`,
  after attachments are added (attaching delays ~1s per file, so the earlier check
  is stale by dispatch time).
- A refused draft is discarded with `close … saving no`. `outgoing message`
  responds-to is exactly `save`/`close`/`send` in `Mail.sdef` — `delete` is NOT
  declared for it, so the previous `delete` either no-opped or threw into a
  swallowing `try`, leaving a fully-composed message addressed to a non-self
  recipient in Mail's outgoing store while the CLI reported it discarded. Whether
  the discard succeeded is now REPORTED: on failure the error tells the operator to
  delete it manually rather than claiming cleanup that did not happen.
- Any throw between creating the draft and the guard now closes the draft and
  returns a distinct outcome, instead of orphaning a real-recipient message.
- `send`'s boolean result is no longer discarded. `Mail.sdef` declares
  `send -> boolean`; a false result previously still reported `executed: true` with
  a `reply_id` for mail that was never sent.
- `emptyTrashScript` used `set before to …`; `before` is an AppleScript reserved
  word, so that script could never compile — the empty-trash path would have failed
  at runtime on first use. Found by the new compile harness below, not by a live
  fire (it is operator-gated and had never been run).

### Added
- `bats/helpers/applescript_syntax_check.py` — compiles every AppleScript embedded
  in `MailScript.swift` with `osacompile` (parse, no execute). These bodies are
  Swift string literals, so `swift build` and the logic tier cannot see them at all
  and a syntax error only surfaces at runtime on a live Mail mutation — the one tier
  CI cannot exercise. It found two real defects on introduction (`repeat with it in
  …`, `it` being reserved; and the `emptyTrashScript` bug above) and is wired into
  `bats` so neither can regress.

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
- **Mail `delete --permanent` + `trash empty`** (audit gap I): both were previously hard-refused
  stubs; they are now really wired, behind gates sized to how irreversible they are.
  - **`delete --permanent`** erases messages that are ALREADY in trash. It is scoped inside the
    AppleScript to trash mailboxes only, so it physically cannot erase a message that has not been
    trashed first (verified live: a target in INBOX comes back `applied: []`). Gating is
    deliberately layered, because a subject label is SPOOFABLE — anyone can mail you a message
    titled `apple-cli-test …` — and the codebase's own invariant says that check must never be the
    sole gate on an irreversible op: it needs the all-or-nothing label gate, an up-front
    `--test-mode` + `APPLE_TEST_MODE=1` check (so a filter matching nothing can't exit 0 outside
    test-mode), a re-check against the CANONICAL prefix that ignores any `APPLE_TEST_SANDBOX`
    override (so widening that env var cannot widen what may be erased — verified live: with
    `APPLE_TEST_SANDBOX="Re:"` set, a real email matched the filter and was refused), and the
    operator-only `APPLE_ALLOW_PERMANENT_DELETE=1` as an independent second factor.
  - **`trash empty`** is wired with the oracle's `confirm_empty`/`max_deletes` equivalents
    (`--confirm`, `--max`, default 5). Because emptying trash CANNOT be scoped to test data, the
    usual label gate has nothing to bite on, so it additionally requires the operator-only
    `APPLE_ALLOW_EMPTY_TRASH=1`. An autonomous run never sets it, which keeps the destructive path
    unreachable without a deliberate human act while leaving the code fully wired and testable.
  - **Trash mailbox resolution is explicit and fail-closed.** There is no per-account trash
    property in Mail's AppleScript API (`trash mailbox` exists only on the application and resolves
    to the unified "All Trash"), and the obvious `mailbox "Trash" of account X` is WRONG on iCloud,
    which carries both an empty "Trash" and the real "Deleted Messages". The CLI enumerates
    trash-like mailboxes and refuses to guess when more than one is non-empty, asking for
    `--trash-mailbox` instead. The parity oracle hardcodes `"Trash"` and therefore silently
    no-ops on iCloud.
  - **BEHAVIOR THE ORACLE GETS WRONG — the CLI now verifies its own erase.** Mail's `delete` on a
    message that is already in trash is a SILENT NO-OP on IMAP/iCloud accounts (AppleScript cannot
    drive an IMAP expunge). Verified live: the message survives, `deleted status` stays false, and
    the trash count is unchanged. The oracle issues that same `delete` and reports success
    unconditionally, so it claims permanent deletes that never happened. The CLI re-queries after
    the delete and reports `applied: []` with an explanatory note instead; `trash empty` likewise
    counts after each erase, stops the moment one has no effect, and returns
    `expunge_unsupported: true` rather than reporting phantom deletions. Erasing IMAP trash for
    real still requires Mail.app (Mailbox ▸ Erase Deleted Items).
- **Mail templates: on-disk format + dropped MCP fields** (audit gap H). The CLI and
  MCP A share `~/.apple_mail_mcp/templates/<name>.md`, so the format is an interop
  contract. `TemplateStore` is now byte-matched to MCP A's `save_template`
  **operation** (not merely its `serialize_template` helper): identical inputs to
  either tool now produce a **byte-identical file**, verified live on the shared store.
  - **Format fixes:** the header line is the lowercase `subject:` MCP A writes (was
    `Subject:`); a body-only template carries the LEADING blank line MCP A's parser
    requires (the prior file was rejected as "no blank line separating headers from
    body"); the body is normalized to end with a newline, as `save_template` does;
    and `nil` vs `""` is now the real subject distinction (an empty subject writes
    the header, matching the oracle's `subject is not None` branch).
  - **Write validation, mirroring the oracle:** an empty/whitespace-only body is
    refused, and a CR/LF/NUL in the subject is refused — both would otherwise write a
    file MCP A permanently refuses to parse, silently poisoning the shared store.
    `save` now reports what was STORED (re-read) rather than the caller's raw input,
    and returns the oracle's `created` flag (true = new, false = overwrote).
  - **Dropped MCP fields restored:** `templates get` now returns `placeholders` (the
    oracle's sorted, deduped, escape-aware placeholder list) and `templates render`
    returns `used_vars` alongside the CLI's original `variables` key.
  - **`parse` is a deliberate superset that never loses content:** where the oracle
    REJECTS a file, the CLI reads it as all-body rather than failing — this covers a
    file with no blank line, and a header block that isn't entirely known `key: value`
    pairs. That second rule is what keeps a body whose first line reads `Note: see
    below` from losing that line, and stops an unknown future header key from being
    parsed-and-discarded. CRLF input is normalized first (the oracle handles CR
    deliberately; without this a CRLF file lost its entire body).
  - **`render` placeholder substitution is now single-pass**, so a substituted value is
    never re-scanned — the previous repeated-replacement version could produce
    different output run-to-run depending on dictionary iteration order. `{{`/`}}` are
    now literal braces, matching Python `str.format`.
  - **Known open gap (tracked, not closed here):** render-time *error* behavior still
    diverges — the oracle raises `missing_template_variable` naming every unresolved
    placeholder, while the CLI leaves an unknown `{token}` verbatim. That is an
    error-contract change with its own exit code and test matrix, deliberately out of
    scope for this format commit.
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

### Known parity gaps (Mail) — superseded by the 2026-07-30 audit
This section previously listed a single item (`reply`/`forward` quoting the
Envelope-Index snippet instead of the original body). That item is now FIXED — both
commands use Mail's native verbs, see "Mail compose is now a real reply/forward"
above — but the section as a whole was badly understated: the 2026-07-30 re-audit
found **45 confirmed strict-superset gaps** across compose, rules, templates, reads,
analytics, and bulk mutation, of which the batches above close 14. The authoritative
open list lives on the Asana Mail parent (`GID-REDACTED`); it is deliberately not
duplicated here, so that one source cannot drift from the other.

Mail is therefore NOT a strict superset yet, and per this repo's one rule
("Missing *any* MCP capability = not done") neither the Mail Asana parent nor the
1.0.0 tag can close until the remaining gaps land or are explicitly accepted as
documented divergences.

Accepted divergences so far (capability NOT lost — the CLI is stricter or more
correct): the `--execute` + `--test-mode` + `APPLE_TEST_MODE=1` + subject-label gate
on every mutation, which by design prevents acting on real unlabeled data the run did
not create; operator-env gating on permanent-delete / empty-trash; refusing live rule
actions that auto-delete or auto-forward; and `update_rule` with no fields returning
exit 64 where the oracle returns a no-op success (turning a likely caller mistake
into a silent success would be a regression, so the stricter behavior is kept).

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
