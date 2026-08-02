# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pre-1.0: the CLI surface and JSON output are not yet stable; a MINOR (`0.x`) may
include breaking changes, which are flagged `BREAKING:` in the notes below. The
binary cuts `1.0.0` when all six domains reach verified strict-superset parity
with the Apple MCP servers they replace.

## [Unreleased]

### BREAKING — Notes write-model v2: writes EXECUTE by default

Third domain flipped to write-model v2 (`docs/write-model-v2.md`). Notes is the simplest
mapping of the six: the oracle ENFORCES no write gate of any kind. **Evidence (re-derived — the first
version of this note cited a grep of `dist/` and `src/`, directories the shipped package does
not contain, so it matched nothing *vacuously* and proved nothing; reviewers caught it):** the
package ships one bundle, `apple-notes-mcp/build/index.js`; the only `process.env` reads in it
are `DEBUG` and `VERBOSE`, so there is no test-mode variable to mirror; every `elicit*` hit is
bundled MCP-SDK protocol schema rather than server code; and `delete-note`'s handler runs
`getNoteById` → `deleteNoteById` with no gate. Its description does say "Safety: requires
explicit user confirmation before deleting", but that is advisory prose aimed at the calling
model, not server-side enforcement.
So every Notes write op is a CLI-only restriction (bucket 3) with no oracle-mirrored gate to
keep — unlike Contacts, which keeps two.

- **BREAKING (behavior): all 9 Notes writes execute when invoked** — `create`, `update`,
  `append`, `delete`, `move`, `batch-delete`, `batch-move`, `create-folder`, `delete-folder`.
  `--dry-run` previews; `APPLE_DRY_RUN=1` restores dry-run-by-default. **Any script or
  shell-history invocation that relied on the old dry-run default now mutates real notes.**
  The v1 gate (`--execute` plus `APPLE_TEST_MODE=1`) is gone.
- **The sandbox is opt-in and single-signal**: `APPLE_TEST_MODE` truthy or `--test-mode`,
  either alone. Inside it, writes stay confined to `apple-cli-test…`-labeled notes and folders;
  refusals remain `validation_error` / exit 64 (the Notes refusal type, not Mail/Contacts' 77).
- **Recoverability is per-op, and `delete-folder` is the exception.** `delete` and
  `batch-delete` move the note to Recently Deleted, where it stays recoverable — no
  operator-affordance env var warranted. **`notes delete-folder` CASCADES to every note in the
  folder, and the cascade is PERMANENT** (measured: the contained note did not reach Recently
  Deleted, while a control note deleted the other way did). It also does **not** refuse a
  non-empty folder — this port's own help text and port-spec claimed it did, inheriting an
  assertion the oracle's source only hedged as "may fail".
- **BREAKING (behavior): `notes delete-folder` PREVIEWS by default** — a per-surface default,
  the same shape Mail's trash surface uses; pass `--execute` to perform it. This is a knowing
  deviation from strict oracle parity (the oracle cascades on call), taken under the spec's own
  `APPLE_ALLOW_EMPTY_TRASH` rule: an op that irreversibly destroys an unbounded amount of
  unlabeled real data in one flagless invocation warrants a control the caller must reach for.
  One line (`DeleteFolderCmd.surfaceDefaultDryRun`) restores strict parity if preferred.
- **Fix: an empty or separator-only folder name is now refused everywhere.**
  `notes delete-folder ""` built an EMPTY AppleScript specifier, so the emitted script was a bare
  `delete` inside `tell account …` — binding the direct object to the whole account container
  rather than a folder. v1 refused it only incidentally (the label gate rejected `""`), and the
  v2 lift removed that accident; the oracle is not vulnerable because its schema carries
  `.min(1)`, so this was a dropped oracle-mirrored input bound. Guarded now at both the command
  layer and the `NotesScript.deleteFolder` sink (`createFolder` already had the sink guard).
- **BREAKING (contract): envelope change.** Sandboxed write envelopes carry `"sandbox": true`
  (key absent otherwise); `--text` write output shows a `[sandbox]` prefix.
- **Preview honesty.** Every argv-computable label check runs on BOTH paths — `create`'s title,
  `update --new-title`, `create-folder`/`delete-folder`'s name, `batch-move`'s destination, and
  (per review) `move`'s destination plus any `--title`-addressed target. Only `--id` addressing
  genuinely needs Automation to learn the target's title, and only then does a sandboxed preview
  disclose an unchecked gate — the first cut disclosed it for `--title` too, which was both a
  missed check and a false explanation.
- **Fix (found in review): `notes move` never label-checked its `--folder` destination** on
  either path, while `batch-move` did — so a sandboxed move could drop a labeled test note into
  a REAL folder.
- **Fix (found in review): `save-attachment` ignored `--dry-run`** and wrote the file anyway. It
  mutates the filesystem rather than Notes.app, and shipped with no `willExecute` branch at all;
  it now previews, and inherits the fail-loud env contract. Its home/temp/Volumes path
  confinement — the only safety check it has, and pure argv string math — was also hoisted to run
  on BOTH paths, so a preview can no longer report clean for a destination the execute path
  refuses; an out-of-roots path is now `validation_error` on both rather than `unknown`.
- **Fix (found in review): `notes create --folder` never label-checked its destination**, so a
  sandboxed create wrote into a REAL folder while the identical `move` was refused.

### BREAKING — Contacts write-model v2: writes EXECUTE by default

Second domain flipped to write-model v2 (`docs/write-model-v2.md`), same principle as the
Mail flip below: `apple contacts <write>` behaves like calling the equivalent
apple-contacts-mcp tool, which mutates the real address book on call.

- **BREAKING (behavior): all 11 Contacts writes execute when invoked** — `create`, `update`,
  `delete`, `note set`, `photo set`, `vcard import`, `groups create|rename|delete|add|remove`.
  `--dry-run` previews; `APPLE_DRY_RUN=1` restores dry-run-by-default globally. **Any script
  or shell-history invocation that relied on the old dry-run default now mutates real
  contacts.** The v1 gate (`--execute --test-mode` AND `APPLE_TEST_MODE=1`) is gone from 9 of
  the 11 ops: it was a CLI-only restriction the oracle does not have.
- **The sandbox is now opt-in and single-signal**: `APPLE_TEST_MODE` truthy (`1`/`true`/`yes`)
  **or** `--test-mode`, either alone. Inside it, writes stay confined to `apple-cli-test`-
  labeled items — the CLI's analogue of the oracle's own test-mode `CONTACTS_TEST_GROUP`
  confinement (`check_test_mode_safety`, security.py:56, which likewise ALLOWS everything when
  test mode is off).
- **KEPT unconditionally (oracle-mirrored): `delete` and `groups delete` still require
  `APPLE_TEST_MODE=1` in the ENVIRONMENT** — mirroring `require_test_mode_for`
  (security.py:161) at `delete_contact` (server.py:965) / `delete_group` (server.py:1715).
  A `--test-mode` FLAG deliberately does NOT satisfy it. The reason is PARITY: the oracle keys
  that gate to an environment variable, so the replacement does too. It is **not** a security
  boundary — anything that can pass argv can equally set the environment of the process it
  spawns — and an earlier draft of this note claiming otherwise was wrong. Refusal stays
  `safety_violation` / exit 77.
- **BREAKING (contract): envelope changes.** Sandboxed write envelopes carry `"sandbox": true`
  (key absent otherwise). Every executed write result now states `"dry_run": false` explicitly
  (`create`, `update`, `delete`, `note set`, `photo set`, `vcard import`, and all five group
  ops) so a caller can tell "previewed" from "done" under execute-by-default. Previews gain an
  optional `gate_note`.
- **Preview honesty.** Dry-runs now run every gate computable from argv, so a preview refuses
  exactly what execute refuses: `groups rename`'s new-name label check and `vcard import`'s
  per-card label check were hoisted above the store (both are pure/static), and the create
  label check already applied to both paths. The fetched-target label checks need a TCC-bearing
  store read a preview does not take — a sandboxed preview names them in `gate_note` instead of
  implying they passed. A `delete` preview likewise names the env gate that will refuse it.
- **Fix (sandbox coherence): `create --group` now label-checks its group target inside the
  sandbox**, as `vcard import --group` already did. Previously a sandboxed create could attach
  a labeled test contact to a REAL group.
- Fail-loud env parsing applies here as everywhere: `APPLE_TEST_MODE=ture` or
  `APPLE_DRY_RUN=off` is a `validation_error` (exit 64), never a silently-guessed "off".
- **`--text` write output now shows `sandbox: true`** when the sandbox is engaged. `--text` is
  still not part of the versioned contract, but a human reading it has the same need to know
  the write was confined as a machine reading the envelope.
- **Test-infrastructure fix (AppleKit, additive):** `GlobalOptions.willExecute` gained an
  `envVar:` parameter, defaulted to `APPLE_DRY_RUN`, matching the seam
  `TestMode.sandboxActive(flag:envVar:)` already had. swift-testing runs suites in parallel in
  ONE process, so a test that `setenv`s a real v2 variable races every domain that reads it.
  That was harmless while all domains were pre-flip; making Contacts the first reader of
  `APPLE_DRY_RUN` turned it into a **6-in-12 red rate** on the full suite. Each domain flip adds
  another reader, so tests now own unique variables through the seams instead.

### BREAKING — Mail write-model v2: writes EXECUTE by default (operator decision 2026-08-01)

The Mail domain is the first flipped to write-model v2 (`docs/write-model-v2.md`): the CLI
replaces the MCP servers, and the oracles execute writes on call, so the CLI now does too.

- **BREAKING (behavior): every general Mail write executes when invoked** — `send`, `reply`,
  `forward`, `draft` (create/send/open/delete), `draft-rich`, `move`, `mark`, `flag`, `rules`
  (create/update/delete/enable/disable), `templates` (save/delete), `mailboxes create`,
  `attachments save`, `export`, `analytics dashboard`. `--dry-run` previews. **Migration:** any
  script or shell-history invocation that relied on dry-run-by-default now executes; pass
  `--dry-run`, or set `APPLE_DRY_RUN=1` to restore dry-run-by-default globally (precedence:
  `--dry-run` > `--execute` > `APPLE_DRY_RUN` > surface default).
- **The TRASH surface keeps dry-run as its default** (`mail delete`, `mail trash empty`) —
  oracle B's `manage_trash` defaults `dry_run=True`, so keeping it IS parity. Pinned by tests.
- **The v1 two-factor write gate is replaced by an opt-in SANDBOX**: `APPLE_TEST_MODE` truthy
  (`1`/`true`/`yes`) OR `--test-mode` — either signal alone — restricts targets to
  `apple-cli-test`-labeled items and recipients to the self-only `APPLE_TEST_RECIPIENTS`
  allowlist (empty allowlist = refuse all; a literal `*` entry is ignored — it is the script
  layer's out-of-sandbox sentinel, never operator data). Unsandboxed, writes operate on real
  data as addressed (the oracle model).
- **Unconditional gates that survive in BOTH modes:** `APPLE_ALLOW_PERMANENT_DELETE` +
  canonical-label check on `delete --permanent`; `APPLE_ALLOW_EMPTY_TRASH` + `--confirm` on
  `trash empty`; path confinement + sensitive-dir blocklists; attachment size/type limits.
- **BREAKING (contract): envelope changes.** Sandboxed write envelopes carry `"sandbox": true`;
  unsandboxed envelopes OMIT the key (the `sandbox` key itself is the only conditional — an
  envelope with no other v2 additions is byte-identical to pre-v2). Executed writes emit
  `dry_run: false` explicitly — exception: `templates save --execute` keeps its pre-v2 bare
  template object (the shape it shares with `templates get`); its preview's
  `would_save_template` + `dry_run: true` is the discriminator. Commands that gained a
  `dry_run` field on ALL paths: `draft-rich`, `analytics dashboard`, `templates delete`.
  `draft` actions missing a subject (or passing an empty/whitespace one) are now
  `validation_error` exit 64 (was `safety_violation` 77 under the label gate). A junk value in
  `APPLE_TEST_MODE` / `APPLE_DRY_RUN` / `APPLE_ALLOW_*` is a fail-loud `validation_error` 64 —
  never a guess (the operator vars also now accept `true`/`yes` alongside `1`).
- **BREAKING (behavior): `mail send --dry-run` no longer writes the generated `.eml`**
  (`--out` included) — the preview reports the planned path; bytes land only on execute. Same
  fix for `draft-rich --dry-run` and `templates save --dry-run`, which previously wrote
  despite `--dry-run` (the spec's bucket-2 defects). `analytics dashboard` gains the same
  `--dry-run` honesty plus `confineWriteDestination` on `--out` (a credential-dir destination
  now refuses, 77 — previously it would write HTML anywhere, `~/.ssh/authorized_keys` included).
- **`rules` correctness under the lifted gate** (review-caught): `rules create` refuses a
  duplicate rule name at `--execute` in both modes (Mail silently mangles a duplicate-name
  create, and the post-create verification could previously have deleted the PRE-EXISTING
  rule) — the DRY-RUN cannot report this blocker (it would need a Mail read previews
  deliberately avoid), so a colliding name previews clean and refuses at execute; `rules
  create` now creates DISABLED, verifies the conditions attached, and only then enables (a
  silently-condition-less rule matches ALL mail); a condition-replacing `rules update` now
  PRESERVES the rule's OR/AND match logic (was hardcoded to AND) and honors `--match any` on
  the in-place path (was a silent no-op reported as executed).
- **BREAKING (behavior): empty/whitespace `--subject` keywords now refuse (exit 64) on
  `reply`, `forward`, `attachments save`, and every `draft` action.** EnvelopeIndex skips an
  empty subject filter, so `--subject ""` silently resolved to the NEWEST message in the
  store — under v2 an unsandboxed `forward --subject "$UNSET_VAR" --to x` would have
  dispatched an arbitrary real message, body and attachments included. Shell-substitution
  accidents now fail loud.
- **BREAKING (behavior): previews refuse exactly what execute would.** Dry-runs across the
  Mail write surfaces now run the same Mail-free gates as execute (sandbox allowlist and
  label checks — incl. `mailboxes create` — subject/mode validation, `reply --mode
  draft|open`'s not_implemented, `--out` path confinement on the plain-body `send --mode
  open` route) — e.g. a sandboxed `--dry-run` to a non-allowlisted recipient exits 77 where
  it previously exited 0 with a clean preview, and the sandboxed `rules create` preview
  reports `enabled: false` (the force-disable execute performs). Sandboxed bulk previews
  (move/mark/flag/delete-to-trash) run the same per-target label gate execute runs. The
  divergences that remain are of two disclosed CLASSES, both fail-closed (the preview is the
  permissive side; execute refuses). **(a) Gates needing a fresh Mail/account read the preview
  deliberately avoids**, so a dry-run stays store-independent and CI-runnable: the rules
  duplicate-NAME refusal, the target-RULE label check and `checkSupportedActions` (all need
  `rules list`); `--account` send-address resolution on send/reply/forward/draft-create (an
  unknown account is `not_found` 65 only at execute — `draft-rich` resolves on both paths
  because its `--open` route needs the address to build the `.eml`); and the RFC-Message-ID
  addressability check on bulk targets. Also in this class by nature: `attachments save`'s
  per-destination symlink refusal, which needs a filesystem read of paths the preview never
  composes. **(b) The two IRREVERSIBLE trash-surface commands**,
  whose previews still render the plan (oracle B's `manage_trash dry_run=True` previews
  ungated) while NAMING the unmet gates in the envelope note — `delete --permanent` (the
  operator env var; any unlabeled targets) and `trash empty` (`--confirm` + its operator var).
- **BREAKING (behavior): blank/whitespace filter values now refuse (exit 64)** instead of
  silently widening scope: `--match-sender` and `--match-subject` on move/mark/flag/delete
  (a blank keyword satisfied the filter-presence gate while contributing NO predicate — the
  mutation widened to whatever the other filters alone selected; a whitespace-only one bound
  a near-universal `% %` LIKE); whitespace-only `--subject` on `export --scope single_email`;
  and a blank `--account` on `draft send/delete/open`, `trash empty`, and `delete` (an empty
  string reached the AppleScript account filter as "match every account").
- **Injection hardening on the AppleScript argv boundary** (review-caught). Every AppleScript
  call is argv-fed RS(0x1E)/US(0x1F)-delimited blobs that the script re-splits, so any value
  carrying those bytes turns one vetted field into two. All four channels are now closed:
  - **attachment paths** (`--attach`) refuse control characters exactly like
    `confineWriteDestination` — a US byte would re-split into a second, never-vetted path, and
    the sensitive-dir blocklist is the sole unsandboxed containment;
  - **recipient lists** (`--to`/`--cc`/`--bcc`) refuse them too (`validation_error` 64): an
    embedded US would split one vetted address into two, the second never seen by the
    allowlist comparison. `reply --all` additionally reduces every index-sourced recipient to
    its bare addr-spec, discarding the REMOTE display name (a hostile sender's decoded name
    could otherwise inject an extra auto-sent recipient on the `--gui-send` route);
  - **sandboxed recipient allowlists** DROP any entry containing a control character (a US
    byte inside an `APPLE_TEST_RECIPIENTS` entry would materialize extra entries after the
    in-script split — including the out-of-sandbox `*` sentinel);
  - **the `--gui-send` window locator** no longer trusts the subject. It bound the frontmost
    Mail window by title substring, safe only while every gui-send subject was a unique
    `apple-cli-test` label; under v2 `reply --html --gui-send` composes "Re: &lt;real subject&gt;",
    the likeliest title for a window the operator already has open on that thread — so the
    blind Cmd-A/Cmd-V/Cmd-Shift-D could overwrite and send THEIR message. The compose window is
    now created under a per-call nonce, matched on it, and its real subject restored (and
    verified) before the send keystroke; a failed restore refuses rather than mailing a marked
    subject. (The GUI keystroke route stays operator-verify-only — it needs Accessibility and
    steals focus, so it is never exercised autonomously; this change is reviewed and
    osacompile-checked, not live-run.)
  - **attachment filenames from the sender's MIME headers** — remote data — are SCRUBBED
    before path composition, with a hard refusal backstop in `saveAttachments`: an embedded US
    would truncate the destination in-script (past the symlink and pre-existing-file checks,
    which ran on the full path), and an RS would inject an entire extra save record with an
    attacker-chosen relative destination.
- **`draft delete` now honors `--account`** (it was accepted and ignored — an unsandboxed
  delete swept matching drafts across EVERY account). The shared `--execute`/`--test-mode`
  help strings now describe v2 semantics (`--test-mode` previously claimed it was "required
  for live writes" — inverted under v2).
- **`draft send` hardening:** the outgoing-message locator requires recipient-MULTISET
  equality with the stored draft, so a compose window sharing the subject but carrying ANY
  differing recipient set is never dispatched (`wrongwindow` refusal, exit 77 when only
  mismatches were seen). Residual, by construction: a window sharing BOTH the exact subject
  and the exact recipient multiset is indistinguishable from the draft's own outgoing copy.
  Post-send cleanup now deletes only the one sent draft (by stable id), never other
  same-subject drafts. The envelope note only claims "recipients verified self-only" when the
  sandbox's allowlist actually ran.

### Security — operator-supplied write destinations are now confined
- **`mail attachments save` had NO path confinement.** Its source documented the operator-chosen
  path as "TRUSTED — save verbatim". Live before the fix: `--dir ~/.ssh` and `--dir /private/etc`
  both returned `ok:true`, and `--out ~/.ssh/authorized_keys --execute` would have overwritten an
  SSH key with attachment bytes. Both oracles refuse these path classes before touching Mail
  (patrickfreyer `manage.py:197-220`, `analytics.py:428-443`). A shared
  `confineWriteDestination()` now guards `attachments save`, `export`, `send --out`,
  `reply`/`forward` HTML `.eml`, and `draft-rich --out`; refusals are exit 77.
  Three properties the first attempt got wrong, each live-confirmed as an accepted bypass and now
  regression-tested:
  - the blocklist is **case-insensitive** — on case-insensitive APFS,
    `resolvingSymlinksInPath()` only canonicalizes case for components that already exist, so
    `~/.SSH/authorized_keys` was accepted while `~/.ssh/authorized_keys` was refused. It failed
    open exactly for files that do not exist yet.
  - **control characters are rejected** — the confined path is later serialized into an
    ASCII-delimited AppleScript blob (RS `0x1E` / US `0x1F`), so a path carrying those bytes
    passed as one string and was re-parsed downstream as TWO save records, the second never
    confined.
  - the guard is applied to **every** operator write sink, not just the two first found;
    at the time `send --out` wrote on the then-default dry-run path with no `--execute`
    (superseded by write-model v2 above: `--dry-run` no longer writes the `.eml`, and the
    default posture is execute).
- **BREAKING (behavior):** `mail export` now honours `--dry-run`, which was advertised in `--help`
  and silently ignored — it unconditionally created the directory and wrote one file per message.
  A `--dry-run` export writes nothing. (Superseded in part by write-model v2 above: the default
  posture is now execute, so a FLAGLESS export writes — pass `--dry-run` or set `APPLE_DRY_RUN=1`
  to preview.)
- `attachments save --allow-outside-home` (new) restores oracle A's reach: its `save_attachments`
  has no confinement, so `/tmp` and `/Volumes/*` are legitimate destinations and refusing them
  unconditionally would DROP a capability. The credential blocklist and the control-character
  rejection are absolute and survive the opt-out.
- `export` reports `total_in_mailbox` + `capped` (oracle B emits both, `analytics.py:627-628`) so a
  capped run is distinguishable from a complete one — `entire_mailbox` only, since that is the
  only scope `--max` applies to. `attachments save` reports oracle A's `saved` count.

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

### Fixed — Mail reads + analytics (confirmed gaps, batches 4-5)
- **Regression fix.** Reply/forward locate through the bounded `findMsg`, which skips "[Gmail]"
  mailboxes (scanning Gmail's All Mail archive by message-id hangs) — so the previous batch made
  ARCHIVED messages unreachable, where both oracles reply to/forward any message. A new hinted
  locator takes the mailbox the Envelope Index already resolved and looks THERE first, which is a
  targeted lookup rather than a scan, so the archive is reachable without the hang.
- `findMsg` now FAILS CLOSED on an unresolvable `--account`. It previously left the account list
  as EVERY account, silently widening a scoped mutation into an unbounded cross-account scan —
  and the native outbound verbs had made that an outbound concern.
- `content_preview` (MCP B's name for the indexed preview) is emitted alongside `snippet`, per
  this repo's own A/B dual-key rule. Both are one value, so `--no-content` and
  `--max-content-length` now apply to both — clearing only `snippet` left the same text exposed
  under the other name.
- `thread --limit 0` returns the COMPLETE thread (oracle A's `get_thread` is uncapped). 0 used to
  reach SQL literally, return no rows, and fall through to the singleton fallback — so asking for
  the whole thread returned exactly one message.
- `thread --subject` strips `Re:`/`RE:`/`Fwd:`/`FW:`/`Fw:` before matching, as oracle B does;
  `--subject "Re: Budget"` previously missed the thread's original message. Stacked prefixes
  (`"Re: Fwd: Re: X"`) reduce fully, and matching is case-insensitive (a superset of B's
  fixed-case list).
- `selected` reads `date received`; oracle A always returns it, and the CLI's non-index fallback
  path emitted a null date.
- `mailboxes create` emits `mailbox` + `parent` (oracle A keys). The joined `path` alone is lossy
  when the name itself contains a `/`.
- **Statistics now match the oracle exactly.** MCP B excludes `SKIP_FOLDERS`
  (Trash/Junk/Junk Email/Deleted Items/Sent*/Drafts/Spam/Deleted Messages) from broad scans; the
  CLI counted them, so every volume metric diverged. Verified live against the oracle on
  2026-07-30 (7-day window): the CLI over-counted before the filter and matches exactly after — with unread, read,
  flagged and with_attachments all matching too. `--include-system-folders` opts back in.
- **BREAKING (behavior):** `search --mailbox All` now EXCLUDES the same `SKIP_FOLDERS` set by
  default, matching oracle B's `search_emails`. An `All` sweep that used to surface Trash, Junk,
  Sent, Drafts and Spam hits now does not; pass `--include-system-folders` for the old set.
  Naming a system mailbox explicitly (`--mailbox Trash`) is unaffected — the change is only to
  what "All" MEANS. The filter matches on the mailbox LEAF name, so Gmail's `[Gmail]/Trash`,
  `[Gmail]/Spam` and `[Gmail]/Drafts` are covered, but `[Gmail]/All Mail` is not a system folder
  in either oracle's list and is still searched.
- The exclusion is now disclosed in the payload: `search` emits `system_folders_excluded`
  (`true`/`false` on an `All` sweep, absent otherwise), and `analytics stats` emits the same key
  (always present — its exclusion is not `All`-scoped). Silent filtering is indistinguishable
  from an empty store, so the count alone was not enough for a caller to trust; on `analytics`
  the counts ARE the whole payload, so it mattered more there. Under `--text`, `search` prints
  the same warning to stderr next to the pagination hint.
- **`analytics stats --scope mailbox_breakdown` is a KNOWN DEFECT, not parity** (newly
  documented, fix tracked separately). Oracle B applies the skip per-scope — `account_overview`
  (analytics.py:170) and `sender_stats` (:314) yes, `mailbox_breakdown` (:351) **no** — and that
  scope targets ONE named mailbox (`mailbox_param = escaped_mailbox if mailbox else "INBOX"`).
  The CLI forces `All` for it and filters anyway, so `--mailbox` is silently discarded and
  per-mailbox stats for a system folder are unreachable by any flag combination. Verified live:
  `--scope mailbox_breakdown --mailbox Trash --days 0` returns every non-system mailbox with no
  Trash row.
- **`thread` deliberately does NOT apply the exclusion.** Oracle B applies `SKIP_FOLDERS` in
  `search_emails` and the analytics tools only — `get_email_thread` has no such filter. Excluding
  there drops the operator's own `Sent` replies out of their own conversation (measured: 34
  thread lost a quarter of its messages), which is a correctness loss, not parity.
- **Bulk mutations keep the WIDE meaning of `All`, and now say so.** `move`/`mark`/`flag`/`delete`
  resolve `All` across every mailbox INCLUDING the system folders — `delete --permanent` targets
  messages that are in Trash by definition, so narrowing the mutation scope would break it. That
  makes reads and mutations disagree about what `All` means, so a bulk envelope now carries a
  `scope_note` stating the divergence. It is emitted only on the FILTER-BASED path: an
  explicit-ids mutation never consults the mailbox, so a sweep note there would contradict
  `filter_based: false` in the same envelope.
- `scope_note` also fires when the scope IS a system mailbox, even though that is not a
  divergence from `search`. **Drafts is the reason**: its entries are UNSENT composes, so moving
  one out of Drafts removes it from Mail's compose surface — a different kind of operation from
  re-filing a received message, and worth saying out loud before an `--execute`.
- `analytics stats` validates `--scope` and requires `--sender` for `sender_stats`; it previously
  accepted an unknown scope silently and reported whole-account numbers as though they were one
  sender's. `export --scope` is validated too — an unknown scope used to fall through and export
  the ENTIRE mailbox.
- **needs-response** now matches oracle B: the four exact priority labels (`HIGH (flagged +
  question)`, `HIGH (flagged)`, `MEDIUM (contains question)`, `NORMAL` — the MEDIUM bucket had no
  CLI counterpart and unflagged questions were reported as HIGH), the full
  `NEWSLETTER_PLATFORM_PATTERNS` + `NEWSLETTER_KEYWORD_PATTERNS` suppression lists, and the
  already-replied cross-reference against recent Sent subjects. Without these the CLI surfaced
  Substack/Mailchimp blasts and threads you had already answered as mail awaiting a reply.
- **`export --dir` is confined.** Export writes message bodies to disk and previously accepted any
  path; it now resolves symlinks first, then requires the destination to be under `$HOME` and
  refuses oracle B's sensitive-directory list (`~/.ssh`, `~/.gnupg`, `~/.config`, `~/.aws`,
  `~/.claude`, `~/Library/{Keychains,LaunchAgents,LaunchDaemons}`). The blocklist is the same
  helper the attachment reader uses, so the two surfaces cannot drift.

### Fixed — Mail rules conditions + preview honesty (confirmed gaps, batch 6)
- **`any_recipient` built the wrong rule.** It mapped to Mail's `to or cc header`, but
  `Mail.sdef`'s `RuleType` enum has a distinct `any recipient` — and they differ: `any recipient`
  covers Bcc, `to or cc header` does not. A rule created from an oracle `any_recipient` condition
  therefore silently missed Bcc'd mail. Now mapped correctly.
- **`header_name` conditions are wired for live mutation.** `RuleType` has `header key` and the
  rule-condition class has a `header` ("Rule header key") property; the CLI set neither, so these
  conditions were refused outright. Both are now set, and the safety refusal is lifted — the
  self-scoping invariant still holds, because the rule remains an AND-rule carrying the test-label
  subject condition, so a header condition can only NARROW what it matches.
- An unknown rule-condition field now **fails loudly** instead of silently becoming a
  `from header` rule — building a different rule than the caller asked for, then acting on real
  mail, is the worst available outcome.
- **BREAKING (contract):** a rules dry-run now DESCRIBES a rule the live path would refuse and
  reports `live_blockers`, instead of exiting 77. `delete`, `forward_to` and `--match any` are
  real oracle capabilities; a preview that cannot represent them drops the capability from the CLI
  surface entirely, which is exactly what strict-superset parity forbids. Previews still fail on
  genuinely MALFORMED input (e.g. `move_to` without its `Account/Mailbox` slash), so a dry-run
  keeps predicting the execute outcome. **The live refusals are unchanged** — `--execute` still
  returns `safety_violation` for all three, and that is regression-locked separately.

### Fixed — rules preview/execute honesty + create verification (review findings)
- A rules dry-run now reports EVERY refusal the live path would raise, not just the three
  relaxations. Moving the dry-run guard above the live chain had dropped the self-scoping refusal
  from the preview entirely: `rules update 1 --condition "from:contains:boss@example.com"` printed
  `live_blockers: []` and `note: null` — an affirmative claim that `--execute` would accept a rule
  it refuses with exit 77. The self-scoping test is now a shared predicate (`isSelfScoped`) used
  by BOTH the preview and the execute path, so the two cannot drift; unlabeled `--name` is
  reported the same way, and create/update previews no longer disagree about which refusals they
  surface.
- A live `rules create` now VERIFIES its conditions attached, as the recreate path already did.
  Mail's `make new rule condition` sits in a bare `try` that swallows every error while the script
  still returns "ok", so a silently-dropped condition left a labeled rule MISSING its test-label
  conjunct — and `rules enable` trusts the NAME alone, so force-disabling only deferred it. A
  0-condition rule matches ALL mail. On a count mismatch the malformed rule is deleted.
- Condition **header names** are now covered by the RS/US control-character guard. `header_name`
  became the 4th US-delimited field of each RS-delimited condition record and is taken verbatim
  from the final colon-segment of user input, so a delimiter in it shifted every following field —
  appending an attacker-shaped condition, or (with a 2-field remainder) aborting the script
  mid-recreate AFTER the old rule was deleted.
- An **empty condition value** is rejected (oracle A: "condition.value must be a non-empty
  string"). An empty `contains` matches every message. The check runs after the `header_name`
  split, which is what produces the empty value: `header_name:contains::X-Foo` arrives with a
  non-empty raw segment and only becomes empty once the header is peeled off.

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
