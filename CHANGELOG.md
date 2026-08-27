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

- **`mail rules` can now create rules with a live `delete` (auto-trash) action.** Previously
  `--execute` refused this with exit 77; it is now wired for full parity with oracle A
  (operator ruling D6/gap25, 2026-08-19). **Read this before using it:** a Mail rule is a
  standing, unattended order — once the rule exists and is enabled, every future message matching
  its conditions is deleted with no agent involved, no confirmation, and no undo, and an
  over-broad condition applies to mail you never intended. The dry-run preview and the execute
  envelope both carry an advisory `warnings` entry naming the action; the sandbox additionally
  refuses to wire `delete` and ENABLE a rule in the same command. `forward_to` remains refused in
  both modes (see Divergences). Automated coverage is unit + dry-run only: by the same ruling, no
  agent may live-verify a delete rule, so **the first live exercise is yours**. (Completed
  2026-08-27: the first live exercise ran operator-present against an agent-created disabled
  `apple-cli-test` rule; readback matched and the pre-existing rules were untouched — D14.)
- `notes search`, `notes selected`, and `notes shared` now emit the oracle's `content` and `tags`
  keys (hardcoded `""` / `[]`, exactly as `apple-notes-mcp@2.7.5` emits them). Strict-parity
  ruling D6/NOTES-M1; zero added cost — the oracle never fetches these either.

### Changed

- **BREAKING (exit code):** expected `--gui-send` UI refusals now surface as
  `upstream_error` / exit 69 instead of the generic `unknown` / exit 70. This corrects the error
  classification for a focus loss, a nonce-window timeout, a subject-restore refusal, or a caught
  Accessibility/System Events failure; no send is reported on the three proven-refusal paths, and
  the GUI-failure path reports delivery as unconfirmed. This is a pre-1.0 contract disclosure and
  does not bump or tag a release.
- **BREAKING (file-output safety):** Mail `send --out`, Mail `draft-rich --out`,
  Mail `analytics dashboard --out`, Contacts `vcard export --out`, Contacts `photo get --out`,
  and Notes `save-attachment --path` now refuse an operator-supplied raw final-leaf symlink before
  touching Mail, Contacts, or Notes. The same guard re-runs immediately before execute-path writes
  where those six surfaces write bytes. The refusal is `safety_violation` / exit 77 and
  intentionally beats generic write failures and `draft-rich --no-clobber`; the existing
  Mail/Contacts confinement and Notes AttachmentFS root policy are unchanged. This closes the
  redirect class on those six raw operator-supplied leaves only; it does not claim every file
  writer. Mail export `--dir` remains out of this task because it uses derived leaf names plus
  atomic writes. Narrow residual: a raw spelling with `..` through a preceding intermediate
  component that does not exist cannot be inspected through that exact raw spelling and may be
  standardized by downstream confinement. That shape is operator-controlled and narrow. The normal
  time-of-check/time-of-use race after the final host check and before the filesystem or AppleScript
  write still exists. Mail attachment-save keeps the same `safety_violation` / 77 contract, but its
  symlink-refusal message now uses the shared helper's `raw destination` wording.
- **BREAKING (error precedence):** `mail attachments save` now validates destination
  confinement, filesystem shape, and a raw `--out` symlink before resolving the source message.
  An unsafe or invalid destination therefore returns `safety_violation` / exit 77 or
  `validation_error` / exit 64 even when message resolution would previously have returned
  `not_found` / exit 65 or `upstream_error` / exit 69. This keeps previews fail-closed and avoids
  Envelope Index or Mail.app access for deterministic destination refusals. Immediately before a
  live save, both `--dir` and `--out` also revalidate that the destination parent still resolves
  to the preflight path and remains a directory, plus refuse a newly planted leaf symlink. This
  narrows symlink reparenting to the interval between the final host check and Mail.app's separate-
  process save. A same-path rename swap between two real directories also remains outside the
  path-based guard. A missing or non-directory `--out` parent now returns `validation_error` /
  exit 64 before store access instead of the previous exit-0 `not_saved` result. Oracle B also
  creates no parent and saves no file for this input; it suppresses Mail's save error and reports
  the attachment as not found.
- **BREAKING (exit code):** `mail rules create --action "delete=true" --execute` returned exit 77
  (`safety_violation`) and now succeeds. Any script relying on the refusal will change behavior.
- `mail draft-rich` now opens the generated `.eml` in a Mail compose window **by default**,
  matching oracle B's `open_in_mail=True` (ruling D6/extra20). Pass `--no-open` for the previous
  headless behavior. The command still cannot send anything — it writes a draft and, optionally,
  shows it to you.
- New optional `warnings` wire key on `mail rules` create/update envelopes (additive; MINOR).

### Error envelopes carry `sandbox` on a sandbox refusal (Q14)

**Added**

- The JSON ERROR envelope now carries `error.sandbox: true` when the opt-in sandbox (write-model
  v2) REFUSED a write — an unlabeled target, a non-self recipient, a sandbox-incompatible rule. It
  is the error-envelope counterpart of the SUCCESS envelope's `sandbox: true`: on success it means
  "this write executed under the sandbox", on a refusal it means "the sandbox is why this write did
  NOT execute". Present across all six domains' sandbox gates. `encodeIfPresent` keeps the key
  ABSENT (never `false`/`null`) on every error the sandbox did not cause — including the
  path-confinement `safety_violation`, which fires regardless of sandbox state — so a consumer can
  distinguish a sandbox refusal from any other failure. Additive / MINOR; no other envelope changes
  shape, and each domain's refusal keeps its existing `error.type` / exit code (the fleet's
  sandbox refusals are heterogeneous — Mail/Contacts `safety_violation`/77, Notes/Reminders/
  Calendar/Messages `validation_error`/64 — and Q14 marks them without normalizing that, which is a
  separate change).
- The Mail OUTBOUND refusals (`manage_drafts action=send` `.blocked`, reply/forward `.refused`) are
  DATA-dependent: under an active sandbox they can fire for a real allowlist miss (sandbox-caused) OR
  for an always-on reason that fires identically whether the sandbox is on or off — an
  `<empty-address>` blank recipient, or any of the parenthesized audit trips the in-script checks
  emit (`(no recipients populated)`, `(recipients vanished before send)`, `(unrecognized script
  result …)`). Only the allowlist miss stamps `error.sandbox`; the always-on reasons stay unmarked
  even under the sandbox. A single-sourced `mailOutboundRefusalIsSandboxCaused` predicate treats a
  real disallowed address (never `(`/`<`-prefixed) as the only sandbox-caused case, and
  `refusalMessage` mirrors that partition, so the flag and wording never disagree. Marking an
  always-on reason as a sandbox refusal would tell a consumer to retry unsandboxed into the very same
  block — the false positive `sandbox` exists to eliminate.
- `false → nil` is normalized at the `Output.encodeError`/`emitError` boundary, so the structured
  (`encodeIfPresent`) and hand-rolled-fallback encode paths cannot diverge — the key is only ever
  emitted (as `true`) on an actual sandbox refusal, never as `"sandbox": false`.

### Contacts `--out` writes are path-confined (Q13)

**Fixed**

- **Security:** the Contacts `vcard export --out` and `photo get --out` writes (a CLI superset
  extra — the Contacts MCP returns the vCard text / photo bytes inline and takes no output path)
  wrote to the raw operator-supplied path with no guard, so `--out ~/.ssh/authorized_keys` would
  overwrite an SSH key with vCard/photo bytes — the exact hazard the Mail attachment-save fix
  closed. Both now route through the write-destination guard, bound UP FRONT (before the store
  touch, so a bad path fails fast and the check runs without TCC): it rejects control characters
  and credential/config directories (`.ssh` / `.gnupg` / `.aws` / `.config` / `.claude` /
  `Library/Keychains` / `LaunchAgents` / `LaunchDaemons`) absolutely, with `allowOutsideHome` so
  legitimate `/tmp` / external-volume exports still work. Refusal is `error.type =
  "safety_violation"`, exit 77. **Not universal:** Notes `save-attachment` still uses its own
  oracle-ported guard (`AttachmentFS`, home/temp/`/Volumes`, no credential blocklist — matching
  `apple-notes-mcp`); adding the blocklist there would narrow the strict-superset, so it is tracked
  as a separate parity-vs-safety decision, not folded in here.

**Changed (internal)**

- `confineWriteDestination` + `sensitiveWriteDir` (renamed from the Mail-flavored
  `sensitiveAttachmentDir`) were promoted from MailKit to `AppleKit` so Contacts can share the
  exact guard — no second copy to drift. The `safety_violation` error factory is now the single
  `AppleError.safetyViolation` in AppleKit; MailKit's `mailSafety` delegates to it and the
  duplicate ContactsKit `safetyViolation` was removed. No output-shape or exit-code change.

### Bulk mutation reports already-applied ids on a mid-loop failure (Q12 batch C, part 2 — extra33)

**Fixed**

- A Mail bulk mutation (`mail move` / `mark` / `flag` / `delete`) applies per id; if one id
  HARD-failed partway (a thrown AppleScript execution error, distinct from an unlocatable id,
  which was already collected non-fatally into `not_found`), the error discarded the list of ids
  already mutated. A retry then re-targeted them — and `move` / `delete` are not idempotent, so
  a message could be moved twice or an already-trashed one re-processed (surfaced by the Q11b2
  security review, SEC-M2). The error now carries an `error.applied` array of the ids mutated
  before the failure, so a retry can exclude them. Threaded through a new optional `applied`
  field on `AppleError` and the JSON error envelope (`encodeIfPresent` — absent, never `null`, on
  every other error, so no other envelope changes shape; additive/MINOR). The failure still
  aborts with the underlying error's type and exit code unchanged — only the previously-lost
  partial-mutation record is now surfaced. `error.applied` is primarily an explicit-ids retry
  affordance (re-run excluding those ids); on the `--match` filter path a retry re-resolves the
  filter, and the already-mutated ids largely self-exclude because the filter seeds the
  action-inverse (a moved/marked/flagged message no longer matches).

### Space-separated negative option values (Q12 batch C, part 1 — CAL-11 / REM-10)

**Fixed**

- The natural space-separated negative-value form — `--geo-lon -122.4`, `--geo-lat -33.8`
  (southern/western hemisphere coordinates), and the Reminders `--alarm -15m` / `-2h` / `-1d`
  before-offset — now parses. ArgumentParser reads a `-`-prefixed token as an option, so it
  previously failed these with "Missing value for '--geo-lon'" and only the attached
  `--geo-lon=-122.4` form worked; REM-10 is sharper, since `--alarm -15m` is documented in the
  CLI's OWN `--help`. The oracle (`mcp-server-apple-events`) receives these as JSON numbers and
  has no such restriction, so the CLI must accept the natural form to stay a strict superset. A
  pure `AppleKit.ArgvPreprocess.mergeNegativeValues` rewrites exactly `--<name> <neg>` →
  `--<name>=<neg>` for the three negative-accepting options (`geo-lat` / `geo-lon` / `alarm`),
  only when the value is unambiguously `-<digit/dot>` — no other option, positional, or
  already-attached form is touched, and rewriting stops at a bare `--`. Applied to a local copy
  of the args; `CommandLine.arguments` is unchanged (parse-failure `tool` attribution unaffected).
  The parse-failure `tool`-attribution half of CAL-11 landed earlier in `8f1c849`.

### --text honesty + terminal-injection defense (Q12 batch B)

**Fixed**

- **Security:** `--text` output now NEUTRALIZES terminal control sequences in every
  store-derived string (message subjects/senders, contact names/notes, template
  bodies, event/reminder titles). An embedded ESC/CSI/CR could previously rewrite what
  the operator SAW relative to what the tool did (Q12 [17]); a shared
  `AppleKit.TextSanitize.neutralizeForTerminal` renders C0/C1/ESC/DEL/CR as visible
  caret / `\uXXXX` tokens — plus the Unicode bidi/RTL overrides that reorder displayed
  text (Trojan-Source, CVE-2021-42574) — while preserving TAB/LF and all printable
  Unicode, routed through every `--text` sink INCLUDING the Mail read renderers
  (subjects/senders/bodies/templates), Calendar/Reminders, and the six domain choke
  points. The JSON envelope — the machine contract — is unchanged (the JSON encoder
  `\uXXXX`-escapes C0 bytes; C1 safety on the text path comes from the neutralizer,
  not the encoder).
- `--text` is now HONORED by every Mail WRITE path — including the `trash empty` dry-run
  preview / empty-account branches and `draft list` (which previously emitted JSON even in
  `--text` mode) — the Mail analytics read surface (top-senders / stats / thread-activity /
  sent-activity / inbox-overview, all of which ignored the flag), and the whole Calendar and
  Reminders surfaces read+write (Q12 [10] / CAL-05): all previously emitted JSON regardless of
  the globally-advertised flag. A shared text-aware `Output.emit(…text:…)` overload renders a
  neutralized `key: value` view; the calendar/reminders write choke points carry the preference
  on their `Gate`. `--text` remains a non-contractual human convenience; the JSON default is
  untouched.
- The shared `--text` renderer now distinguishes a numeric `0`/`1` from a boolean: `JSONSerialization`
  bridges JSON booleans AND JSON `0`/`1` all to `NSNumber`, and `NSNumber(0/1) as? Bool` succeeds, so a
  count of `1` (e.g. `moved_count`, `unread`) previously rendered as `true` in `--text`. Fixed by
  detecting a real JSON boolean via its `CFBoolean` type id. JSON output was never affected.

### Cross-domain HEAD-defect closures (Q12 batch A)

**Changed — BREAKING**

- **BREAKING:** `mail attachments save` refuses a SYMLINK destination in PREVIEW
  too (exit 77 where a --dry-run previously returned ok:true for a destination
  --execute refuses) — and `--out` gained the symlink check it never had (a
  pre-planted symlink at the exact --out path would have redirected attachment
  bytes anywhere), with a pre-write re-check on BOTH branches as the TOCTOU
  backstop. Success→error on a preview is an exit-code contract change, hence
  BREAKING.
- **BREAKING:** calendar `structured_location.radius` is OMITTED when not positive,
  matching the oracle's key-absence (`radius > 0 ? radius : nil`,
  EventKitCLI.swift:169 — measured); it previously emitted a spurious `0`. Field
  retyped Double → Double? (MAJOR-class retype, pre-1.0).
- **BREAKING:** calendar AND reminders recurrence `end_date` renders as the
  oracle's bare LOCAL `yyyy-MM-dd` (recurrenceRuleToJSON, measured — a
  DateFormatter with no zone = device zone; the oracle calls it from BOTH
  EKEvent.toJSON and EKReminder.toJSON), not the envelope's ISO-UTC instant.
  `RecurrenceRule` is the shared EventKitCore type, so `reminders tasks`
  output changes too.

**Fixed**

- Write-model v2 normalization: every execute-path envelope across ALL SIX domains
  now emits `dry_run: false` explicitly (the v2 rule Contacts and most of Mail
  already followed). A shared `AppleKit.ExecutedWrite` wrapper stamps the key FLAT
  into the payload's own top-level object (additive, MINOR) so read-path models
  (calendar's Event, reminders' Reminder/ReminderList/SubtasksData) don't grow a
  permanent field. Covered: 14 Notes emit sites, 9 Reminders (tasks/lists
  create+update, all five subtask mutations), calendar create/update, messages
  send, and Mail `templates save` — 23 write COMMANDS via 27 emit sites (a
  command can emit from more than one execute branch), inventoried by a full
  sweep and re-swept independently in review; wire shape pinned + revert-red
  proved, per-domain source-lint pins added in the review round, and a bats pin
  covers a real execute envelope end-to-end; live-verified on sandboxed notes
  and reminders create/delete round-trips. SCOPE: the rule (and this sweep)
  covers willExecute-bearing WRITE commands; read-surface exports that offer an
  optional `--out` convenience (contacts vcard/photo export) are Q13's
  confinement item, and `notes export` writes nothing to disk (measured — it
  emits the content in the envelope).

- `mail export --scope single_email --dry-run` no longer pays the live AppleScript
  full-body fetch (a preview with side costs is not a preview); the preview's
  `body_source` is therefore a PREDICTION ("full_body" whenever an RFC id
  exists) that can differ from execute only when the live fetch fails there and
  falls back — disclosed on port-spec row 42.
- Stale v1 doc comment on Notes' DryRunPreview corrected (writes execute by
  default under v2; the payload is preview-only).
- Port-spec honesty: messages §8 parity counts date-anchored as point-in-time
  measurements (live values had drifted); contacts §6.1 annotated as the
  design-era sketch (no `--csv`/`--all`/`--force` were ever built — measured);
  calendar read row now discloses the ORACLE BUG (filterAccount naming an
  event-less source returns the FULL unfiltered window) and why the CLI
  deliberately diverges (fail-loud not_found / honestly-empty set).

### Mail compose/reply/forward parity (Q11 batch 5)

**Fixed — CRITICAL**

- Native reply/forward AppleScripts were syntactically INVALID since the shared
  guard-tail extraction (bbc5f26, 2026-07-30): Swift multiline literals drop the
  newline before the closing delimiter, so `""" + guardAndSendTail` merged the
  fragment's closing `end try` and the tail's first `set` onto one line — every
  `mail reply`/`mail forward` --execute since then failed at script compile
  (measured via osacompile; the last live reply/forward proof predates the
  regression). The join now inserts an explicit newline, all four compose
  scripts are osacompile-verified, and a seam pin fails the suite if any
  assembled script ever carries text after an `end try` again.

**Changed — BREAKING**

- **BREAKING:** `mail reply --subject` and `mail forward --subject` scope the
  lookup to INBOX by default (oracle B searches only the inbox; the old
  store-wide sweep could bind an archived/sent message to the keyword) —
  `--mailbox All` restores the sweep (extra16).
- **BREAKING:** `mail reply --html --gui-send` changed semantics: it now performs a
  THREADED native reply with the fragment pasted via NSPasteboard (previously an
  unthreaded fresh compose window via `sendHtmlViaGui` carrying our own quoted HTML).
  Threading is preserved and the in-script re-read allowlist audit now covers the path
  (it previously relied on the Swift-side predicted-recipient guard alone); the pasted
  fragment no longer embeds a quoted copy of the original (Mail's native quote carries
  it) and `--body` is not carried on this path (oracle parity, disclosed in the note).
- **BREAKING:** `mail draft-rich` fills oracle B's placeholder bodies when
  `--text-body`/`--html` are omitted (Draft-outline / HTML-wrapper / rich-content
  fallback), writes to the oracle's DETERMINISTIC subject-named default path
  (`~/Library/Caches/apple-cli/rich-drafts/<safe>.eml` — preview and execute name
  the SAME file; previously a fresh temp-UUID path per run), and OMITS the From
  header when the sender identity cannot be resolved instead of failing
  (extra18; the --open path stays fail-loud). `--no-clobber` refuses an existing
  default-path file.

**Added**

- `mail reply --mode send|draft|open` (gap17): oracle B's delivery modes on
  Mail's NATIVE reply verb — threading headers, replied-to state and Mail's own
  quoted original are preserved in every mode, and every mode passes the SAME
  in-script self-allowlist audit before delivery. Draft mode files via the
  MEASURED verb pair — an open compose window + `save m`, then a close WITHOUT
  re-saving — because a saving-yes close aimed at the outgoing MESSAGE silently
  DISCARDS it (measured live on this store; the oracle's own draft save is the
  window-close shape). Live-verified end-to-end: the reply draft landed in
  the account's Drafts with `drafted: true` + `reply_id`, then was deleted via the MCP
  oracle.
- `mail reply --html` threaded modes (gap15/extra15): with `--gui-send` or
  `--mode draft|open`, the reply runs the ORACLE's NSPasteboard flow — native
  reply window + Cmd-V paste of the HTML fragment, never `set content` (which
  clobbers the HTML layer of Mail's own quote — the oracle's engineering comment
  is explicit about this). Requires Accessibility and steals focus, like the
  oracle. FAIL-CLOSED measured live with Accessibility denied: the composed
  draft is discarded, nothing is sent, and the error is a typed compose failure.
  The fragment travels by temp-file path read via NSString in-script (the oracle
  shells `cat` with an interpolated path). Plain `--html --mode send` keeps the
  reliable no-Accessibility `.eml` compose-window path (unthreaded, disclosed).
- `mail forward` preview/result now carries oracle B's `recipients` echo
  (extra14), and `mail reply`'s result gains additive `drafted` + the rich-draft
  result gains `account`/`cc`/`bcc`/`missing_details`/`saved` fields.
- `mail draft-rich --save-as-draft` (extra19): attempts oracle B's
  `_save_open_message_as_draft` retry save and reports `saved` HONESTLY —
  oracle-diffed live: BOTH sides return saved=no on this store (a
  LaunchServices-opened .eml never registers as an outgoing message), so the
  note tells the operator to press Cmd-S. gap19: `missing_details` reports
  subject→to→body in the oracle's order; the safe-name/html-wrapper/body
  helpers are pure ports pinned against python-executed goldens (incl.
  html.escape's `&quot;`/`&#x27;` entities the first draft missed).
- Compose failures are a TYPED outcome (`composeFailed`) with their own honest
  message class (upstream error, never the allowlist-refusal wording — measured
  live: an Accessibility-denied paste previously read as "recipients outside
  the allowlist"), while the in-script guard's own sentinels ("no recipients
  populated" / "recipients vanished before send") KEEP the refusal framing —
  they are genuine audit trips (review-caught: a broad prefix match swallowed
  them).
- Review-round hardening on the pasteboard flow (all pinned): the blind Cmd-V
  is NONCE-BOUND to the compose window this call created (subject-tagged,
  front-window polled, refused if unbound — the same hazard sendHtmlViaGui's
  nonce guard documents); the paste is READBACK-verified so an unlanded
  keystroke refuses instead of sending an empty reply; the fragment read is
  fail-closed (measured: `missing value as text` coerces without erroring —
  an unreadable fragment now refuses rather than pasting the literal text
  "missing value"); the clipboard is cleared unconditionally on success AND
  error paths (the email HTML never lingers, even when the prior clipboard
  had no string flavor — sendHtmlViaGui's twin fixed too); replies compose
  WINDOWLESS in every mode with the reveal AFTER the allowlist audit (a
  visible-then-refused window could leave a server auto-saved copy with a
  non-allowlisted recipient in remote Drafts); the delivery-mode ladder fails
  CLOSED (an unrecognized mode refuses instead of falling through to send);
  and the paste runs BEFORE the recipient re-verify so its multi-second delays
  cannot widen the TOCTOU window the re-verify exists to close.
- `mail draft-rich` review fixes: `--no-clobber` implemented; `--account`
  sender resolution gated to execute (a dry-run no longer launches Mail);
  default-path directories go through the validated 0700/lstat primitive (a
  pre-planted symlink cannot redirect drafts); user-chosen `--out` files keep
  their mode (the unconditional 0600 chmod contradicted the pinned contract);
  subject trimming uses Python `str.strip()`'s full whitespace set (VT/FF/the
  C0 separators/NEL/LINE SEPARATOR — measured divergence vs the executed
  oracle, the repo's recurring API-set class).
- The bats osacompile harness now reads the script-assembly SEAM from the
  Swift source instead of synthesizing the newline itself (the false-green
  that let the invalid-seam regression ship), compile-checks
  nativeReplyHtmlScript with the full helper set, and tracks the new argv
  arity/holes; the plain reply/forward scripts carry a fail-loud stub of the
  paste handler so the harness can statically prove every called handler
  exists.

### Mail search/list/export parity (Q11 batch 4)

**Changed — BREAKING**

- **BREAKING:** `mail export` writes the ORACLE's file layout by default (gap45, verified
  verbatim from analytics.py): single_email saves `<dir>/<subject>.<fmt>` (no id prefix;
  same-name runs OVERWRITE, like the oracle's `set eof to 0`), entire_mailbox saves into
  `<dir>/<mailbox>_export/` as 1-based `<n>_<subject>.<fmt>`, with '/'→'-' the only
  character substitution. The legacy collision-proof `<id>-<subject:60>` flat naming
  remains under `--layout flat`. Disclosed deviation: names cap at 150 chars before the
  extension (the oracle would error at the filesystem's 255-byte limit mid-export).
- **BREAKING:** a negative `--limit` on `search`/`list` (and a negative
  `--limit-per-account`, and `export --max`) is a typed validation error (64) — it was
  previously clamped to `LIMIT 0` at the query boundary and returned an EMPTY SUCCESS
  while echoing the negative value back, indistinguishable from an empty store
  (git-verified against the base commit; the first draft of this entry misattributed the
  mechanism to SQL `LIMIT -n` — review-caught, the same inverted-claim class batch 3
  corrected).

**Added**

- `mail search --body-live` (gap2): oracle B's body_text semantics — one live AppleScript
  pass per mailbox that reads the FULL content of every candidate message and applies the
  whole condition set (subject/sender/read/flagged/dates/attachments + body) in-loop with
  the oracle's collectLimit/offset early exit. Ported semantics, not the oracle's defects:
  values travel via argv (the oracle string-interpolates the needle into script source),
  and there is no `tr` subprocess per field (AppleScript `contains` is already
  case-insensitive — the shell-out-per-message is the oracle's own timeout cause). The
  collected window is SORTED per --sort and sliced, exactly as the oracle's response
  builder does (_build_search_response, search.py:146-149 — the first draft claimed scan
  order from reading only the collection half; review-caught and measured). Live matches
  missing from the Envelope Index are counted in a `note`. The default `--body` stays the
  fast indexed-preview match (CLI extra, disclosed).
- `mail list --limit-per-account` (gap9): oracle B's max_emails caps PER ACCOUNT and
  counts inbox messages EXAMINED, not returned (its counter increments BEFORE the
  include_read filter) — the CLI windows the newest `per` rows first and applies
  `--unread` INSIDE the window via a pinned helper, so fewer rows than the cap can
  return, exactly like the oracle (review-caught: the first cut filtered in SQL and
  returned strictly more). 0 = no per-account cap; merged globally newest-first (the
  oracle groups per account — disclosed); cap echoed as `limit_per_account`. The global
  `--limit` stays a disclosed CLI extra that still caps the merge at its default 50.

**Fixed (batch-4 review round — security + code review, pre-commit)**

- The live body-search return channel neutralizes the RS wire delimiter inside the
  REMOTE-chosen RFC Message-ID in-script, and the Swift parser drops any token still
  carrying a C0/DEL byte — a crafted `Message-ID:` header could otherwise forge extra
  result rows, and a NUMERIC forgery would resolve as an arbitrary Envelope-Index ROWID
  (attacker-chosen message emitted as a "match"). Same defense as the batch-1
  attachment-name sink; pinned both layers.
- Live-path rows are scope-checked with the index's OWN label-aware resolution before
  emission (a forged or mismatched id can never surface a row outside the requested
  --account/--mailbox; a plain home-mailbox compare would have wrongly rejected every
  Gmail LABEL hit). A FULL nested mailbox path now works on the live path (leaf reduction
  — it silently returned an empty success), measured on the real store.
- The live paging arithmetic is a pure, pinned helper (LiveBodyPage): operator-sized
  --offset/--limit SATURATE instead of overflow-trapping with no envelope; the collect
  bound handed to AppleScript stays inside its 32-bit integer range; the page cursor
  advances by CONSUMED scan positions (skipped ids no longer repeat rows on the next
  page); and a scan truncated at the collect bound reports has_more (it previously claimed
  a silently truncated result was complete).
- Live date bounds are rebuilt from host-computed LOCAL calendar components — the
  epoch-arithmetic form compared instants 4-5h off the index path's SQL bound (1970-vs-now
  UTC-offset delta). One failing mailbox now degrades (per-mailbox try) instead of
  aborting the whole sweep; Gmail INBOX/All-Mail double-listings de-dupe; the envelope
  honors --sort by sorting the collected window like the oracle's response builder
  (initially mislabeled "scan order" — the oracle sorts in body mode too);
  --max-content-length is honored on live rows; C0 control characters in live-path
  needles/terms are refused (they would re-split the argv wire protocol); the live date
  bounds now match the oracle's LOCAL calendar-day semantics (the indexed path's UTC
  binding is a disclosed pre-existing divergence).
- Export hardening: the resolved `<mailbox>_export` subdirectory is re-confined per write
  (a pre-planted symlink inside the export dir could route message bodies outside the
  confined tree); name caps count UTF-8 BYTES, not graphemes (150 CJK characters are 450
  bytes — the cap exists for the filesystem's 255-byte component limit); an empty subject
  falls back to `untitled` instead of a hidden dotfile; `--no-clobber` refuses the
  oracle-parity silent overwrite; an unknown --mailbox is not_found like the oracle's
  raise; a per-message write failure is recorded in `write_failures` and the export
  CONTINUES like the oracle's per-message try (one bad name no longer aborts mid-export);
  `--max 0` is the oracle's empty success; the `directory` field reports the
  `<mailbox>_export` dir files actually land in.

### Mail analytics parity (Q11 batch 3)

**Changed — BREAKING**

- **BREAKING:** `analytics needs-response` filters automated senders on EXACTLY oracle B's
  seven markers (smart_inbox.py:320 — noreply, no-reply, donotreply, do-not-reply,
  notifications@, mailer-daemon, postmaster@), verified verbatim against the installed
  oracle source. The CLI's earlier 17-marker heuristic was over-broad: `support@` /
  `info@` / `alerts@` / bare `notification` senders — real correspondence the oracle
  keeps — were silently dropped from the results (gap40). (`updates@`/`news@` senders are
  still dropped, by the separate newsletter keyword filter — matching the oracle's own
  newsletter_condition, not the automated-sender markers.)
- **BREAKING:** `analytics awaiting-reply --exclude-noreply` filters RECIPIENTS on exactly
  the oracle's four patterns (smart_inbox.py:92 — noreply, no-reply, do-not-reply,
  donotreply), not the automated-SENDER marker list: a follow-up sent to `notifications@`
  or `postmaster@` is no longer suppressed (gap44). The reported `recipient` is now the
  oracle's `Name <addr>` display string (bare address when Mail recorded no name) instead
  of the bare address (gap44).

**Changed — BREAKING** (continued)

- **BREAKING:** `analytics needs-response` selection + ordering are now the oracle's
  (review): the result is the NEWEST `--max` qualifying candidates, emitted high-priority
  bucket first (question OR flagged — the HIGH*/MEDIUM labels) then NORMAL, each in scan
  order. The old global score-sort ranked a MEDIUM question-only item ABOVE a HIGH flagged
  one — contradicting its own labels — and ranked on an urgent-keyword term the oracle
  does not have; both are gone, so result sets and ordering change.
- **BREAKING:** `analytics awaiting-reply` matches reply subjects with the oracle's
  BIDIRECTIONAL containment (shared helper with needs-response) instead of exact equality
  on the normalized subject — a reply whose subject gained words now counts as a reply, so
  fewer sends are reported as awaiting (this was a silently-stricter parity gap).
- **BREAKING:** an unknown `--mailbox` on `analytics needs-response` / `top-senders` is
  now `not_found` (exit 65) like the oracle's "Mailbox not found" raise — it previously
  returned a confident ok:true zero, indistinguishable from an empty mailbox (measured;
  `stats` already behaved correctly, the guard is now shared).

- **BREAKING (error class):** an account selector that fails to resolve because the Mail
  account directory itself could not be read (Mail stalled, automation denied, AppleScript
  timeout) now reports `upstream_error` (exit 69) instead of a misleading "unknown
  account" `not_found` (exit 65) — the account may exist; the CLI just couldn't ask Mail.
  Blast radius: every name-based `--account` on every Mail command, on any machine where
  Mail automation is unavailable (headless/CI, TCC not yet granted). The message carries
  the failure CLASS only (osascript launch-failed vs exited-N — stderr is deliberately
  suppressed, so stall vs automation-denied is not distinguished). A raw account UUID
  still resolves headless from the index (extra31).

**Added**

- `analytics needs-response` / `awaiting-reply` emit `sent_mailbox` — the Sent mailbox
  actually scanned for reply suppression, OMITTED when none resolved (an absent key is the
  signal that suppression silently did nothing).

**Fixed**

- A negative `--max` on `analytics needs-response`/`awaiting-reply` (and `--top-n` on
  `top-senders`) reached Swift's `.prefix` and CRASHED with no JSON envelope (measured:
  exit 133); it is now a typed validation error (64), matching extra6's negative --offset
  precedent.
- `analyticsRows` computes attachment counts with one grouped join instead of a correlated
  per-row subquery (measured identical results on all the full account-wide count rows of the live
  store; ~3-5x faster on the account-wide sweep and marginally slower — 4ms absolute — on
  LIMIT-bounded slices, where the correlated form deliberately remains in queryMessages)
  (extra31). A fixture pin locks the 0/1/multi attachment counts.
- extra31 is PARTIAL, not closed: the error-class half landed (pinned pure both ways); the
  filed defect's TIMEOUT half — `AppleScriptRunner` has no deadline, so a genuinely
  STALLED Mail still blocks instead of reaching the new upstream error path — remains open
  on the worklist.
- Port-spec rows 37/38 carry the batch-3 PARITY NOTES incl. the disclosed supersets: the
  Gmail `[Gmail]/Sent Mail` 4th Sent-probe (the oracle silently skips suppression on
  Gmail-backed accounts), and awaiting-reply matching across all To+CC recipients where
  the oracle keys on the FIRST To recipient only.

(gap39/gap41/extra29 — Sent-mailbox probe order, account scoping, newest-first bounds, and
the summaries-preview body-question join — landed in earlier commits `6b79190`/`3a2c46c`
with their pins; this batch closes their worklist entries with the port-spec disclosures
above.)

### Mail bulk-targeting + rules/templates parity (Q11 batch 2)

**Changed — BREAKING**

- **BREAKING:** bulk `--max` defaults are now per-operation, mirroring oracle B's caps —
  `mark`/`flag` 10 (max_updates), `delete` 5 (max_deletes); `move` keeps 50 (max_moves). The
  old shared 50 left mark/flag 5x and delete-to-trash 10x looser than the oracle.
- **BREAKING:** `mark`/`flag` filter targeting seeds the ACTION-INVERSE predicate first
  (oracle B: mark_read matches `read status is false`, flag matches unflagged, …), so `--max`
  budgets CHANGES, not matches. The CLI-extra `--only-read` remains an explicit override
  (`--read --only-read` composes to a zero-change target set and is honored as typed).
  EXCEPTION: a recolor (an explicit non-none `--color`) seeds NO flagged predicate —
  recoloring an already-flagged message is a real change, so pre-filtering to unflagged
  would exclude exactly the rows recolor exists to touch (port-spec row 21).
- **BREAKING:** on the explicit-ids path of move/mark/flag/delete, `--account` now scopes the
  ids (oracle A's narrow-loop semantics): an id outside the account/mailbox scope is SKIPPED
  with a disclosure note and counted 0 — previously both flags were silently ignored
  (`move <id> --account NoSuchAccount` returned ok:true, matched 1). The mailbox
  (`--source` on move, `--mailbox` on mark/flag/delete) narrows that scope ONLY when TYPED —
  the silent INBOX default never narrows, so `--account` alone still reaches non-INBOX ids.
  DIVERGENCE (disclosed, port-spec row 19): oracle A raises ValueError when exactly one of
  account/source_mailbox is given; the CLI's mailbox flag has a default, so the pair rule
  keys off `--account` presence — `--account` alone scopes instead of raising.
- **BREAKING:** `move --to <leaf>` on a leaf name matching SEVERAL nesting points now prefers
  the top-level mailbox — MEASURED byte-what oracle A's `mailbox X of account` reference
  resolves (probed live: that form is top-level-only and errors -1728 on a bare nested leaf) —
  and REFUSES with a validation error naming the full-path fix when no top-level match
  exists (the oracle would have errored -1728 there too; the CLI previously picked an
  arbitrary same-named mailbox as the mutation destination). A UNIQUE nested leaf still
  resolves — a disclosed superset over the oracle's -1728 (port-spec row 19).
- **BREAKING:** `attachments save` builds its positional master from the LIVE Mail.app
  enumeration and REFUSES to execute from the index fallback (extra32): the AppleScript
  selects `item (i+1)` in Mail's own order, and the old index-ordered master was measured
  disagreeing on 8/8 multi-attachment messages — `--name X` could write a different
  attachment's bytes into a file named X. NOTE the dry-run preview therefore depends on
  live Mail too: when the message can't be enumerated live, the preview falls back to the
  index-ordered list and says so in `note` (with the concrete cause — not-locatable vs
  enumeration-failed vs no RFC Message-ID), and `--execute` refuses from that fallback with
  the same cause. A `--name` that matches nothing on a live-resolved message is now a
  not_found (65), never an ok:true no-op.
- **BREAKING (error-type strings):** rule/template errors carry oracle A's TYPED classes —
  `unsupported_rule_action` (was safety_violation; exit stays 77), `template_not_found` (was
  not_found; exit stays 65), `invalid_template_name` (was validation_error; exit stays 64).
- **BREAKING:** `rules create`/`update` validate `forward_to` entries with oracle A's email
  regex at parse time (exit 64) — `forward_to=notanemail` previously parsed and previewed ok.
- **BREAKING:** `templates render` now implements the full STRING-value subset of Python's
  format mini-language via a verbatim-semantics port (`PyFormat`) pinned against a 91-row
  golden corpus generated by EXECUTING `string.Formatter` itself (35 of the rows are error
  cases): specs (`{x:>5}`, `{x:.3}`, `{x:{width}}`), conversions (`!r`/`!a`), index access
  (`{x[0]}`, Unicode-digit indices included). A spec-bearing token with a missing variable
  now raises `missing_template_variable` (it previously leaked the literal token into
  outbound text, bypassing the guard); evaluation errors — malformed fields, bad format
  codes, attribute/index misuse — reproduce Python's exact messages and map to oracle A's
  class for them (error_type "unknown", exit 70). Disclosed divergences from Python:
  (1) a lone `{` never followed by `}` is copied as a LITERAL where Python raises
  "Single '{' encountered" — the one deliberate, pinned divergence (pre-existing templates
  with stray braces keep rendering); (2) a spec width above 1,000,000 is refused with
  Python's own "Invalid format specifier" message — a disclosed DoS bound (Python would
  allocate the padding); (3) the `placeholders` listing on save/get keeps oracle A's
  `extract_placeholders` semantics verbatim, which can desync from what render actually
  requires (e.g. nested-spec variables) — an oracle-faithful desync, not a defect.

**Fixed**

- Rules previews validate `move_to`/`copy_to` SHAPE unconditionally — a malformed target
  paired with a sandbox blocker used to skip the checks entirely and preview ok (extra25).
- `--text` is honored by all five `templates` subcommands (it was declared and silently
  ignored; `--text` remains outside the versioned contract) (extra27).
- An empty/whitespace message id argument is a typed validation error (exit 64) on every
  id-resolving command instead of falling through to a store query.
- Stale parity docs corrected: the tracker's closed render-template claim and the fill()
  doc contradiction (extra28); port-spec rows 19/20/21/22/28 carry the batch-2 PARITY
  NOTES + DIVERGENCE disclosures (measured top-level-only oracle mailbox resolution,
  partial-pair scoping, inverse-seed recolor exemption, per-op caps, gap32 fail-loud
  no-op update lock).


### Mail read surface + accounts/mailboxes parity (Q11 batch 1)

**Changed — BREAKING** (per docs/versioning-policy.md, every user-visible default/exit-code
change is flagged even though 0.x cannot signal it)

- **BREAKING:** `mail attachments list --subject` default match scope narrowed from `All` to
  the account's INBOX (oracle B's scope). Existing callers silently receive INBOX-only
  results; pass `--mailbox All` to restore the old sweep.
- **BREAKING:** `mail attachments list --max-results` default dropped from 10 to 1 (oracle
  B's default). Each match now costs a live Mail.app locator scan, so the old default made
  the command routinely exceed agent timeouts; raise it deliberately, or pass `--no-live`
  for fast Envelope-Index rows.
- **BREAKING:** `mail thread <id>` default changed from a 50-message cap to UNCAPPED (oracle
  A's get_thread has no cap; the old shared default silently truncated long threads with no
  signal). The `--subject` path keeps oracle B's default of 50. A consumer relying on the
  ≤50 bound must pass `--limit 50`.
- **BREAKING:** unknown `--mailbox` on `search` / `thread --subject` / `attachments list
  --subject` now exits 65 (`not_found`) instead of returning an empty success
  indistinguishable from an empty mailbox (the unknown-ACCOUNT path already failed loud).
- **BREAKING:** `mail search` rejects a negative `--offset` (exit 64) instead of silently
  clamping to 0 while echoing the negative value; `mail thread` likewise rejects a negative
  `--limit` (it previously reached SQLite as `LIMIT -n`, meaning unlimited).
- **BREAKING:** `mail selected --no-content` no longer emits `snippet`/`content_preview`
  (the same body text under two other wire names — a disclosure leak, but a key removal for
  any consumer reading them under `--no-content`).
- **BREAKING:** `mail attachments list <id>` `--account`/`--mailbox` are now scope
  assertions (exit 65 on mismatch); they were declared and silently IGNORED. `--mailbox
  All` is the wildcard (no-op) on the id path, and `get` gained the same `All` short-circuit
  (it previously asserted `All` literally, a guaranteed not_found).
- **BREAKING:** `mail mailboxes create` echoes NORMALIZED `mailbox`/`parent` wire keys
  (matching `path`, which callers reconstruct from them); the raw inputs moved to
  `mailbox_raw`/`parent_raw`.

**Added**

- `mail attachments list` rows now carry oracle A's full metadata — `mime_type`, `size`,
  `downloaded` — read live from Mail.app in Mail's own attachment order (the same positional
  space `attachments save` addresses), with the Envelope-Index rows kept as a disclosed
  degraded path (`note`) when the message is not locatable live. A per-property failure
  degrades that FIELD, not the row (measured: this store's Mail throws on `MIME type of att`,
  which costs oracle A the entire message).
- `mail attachments list --subject` is now oracle B's grouped shape: per-email `emails[]` rows
  (subject/sender/date/attachment_count), zero-attachment matches included (previously
  structurally unreachable), and `matched_email_count`. Default match scope is the account's
  INBOX (oracle B); `--mailbox All` restores the old sweep. The flat `attachments[]`/`count`
  keys are unchanged.
- `mail attachments list` rows carry `save_index` — the position in the INDEX-ordered list
  that `attachments save --indices` selects from. Rows are emitted in Mail's LIVE order,
  which measurement shows routinely differs from the index order (8/8 multi-attachment
  messages sampled), so `attachment_id` joins by NAME (a duplicated name yields nil), never
  by position. A `--no-live` flag skips the live enrichment for fast index-only rows.
- `mail thread` reports a truncation signal (`total`, `has_more`) whenever a `--limit` caps
  the thread (the default-change itself is in the BREAKING section above).
- `mail get` / `mail selected` always emit the `content` key ("" when suppressed) — oracle A's
  key-presence contract; callers ported from it KeyError'd on the dropped key.
- `mail unread-counts` non-summary now descends one sub-mailbox level with oracle B's
  "Parent/Child" keys (nested rows like Vendor/Newsletters were silently missing), and the summary
  emits oracle B's `-1` error sentinel (with INBOX/"Inbox" fallback) instead of silently
  dropping an account whose inbox is unreadable. The sentinel never poisons `total_unread`.

**Fixed**

- `mail mailboxes create` normalizes the path like oracle B (trim each segment, DROP empty
  ones): `'A//B'` and `' A / B '` both create `A/B` — previously the first was rejected and the
  second created literal whitespace-named folders. `--parent` gets the same normalization and
  the sandbox label gate now tests the normalized FIRST segment of the full path.

**Docs**

- docs/port-specs/mail.md rows for get/thread/mailboxes/unread-counts gained explicit
  DIVERGENCE notes (scope assertions vs oracle-A hints; thread argument divergences;
  index-derived `unread_count` vs live Mail; unknown-account fail-loud vs oracle B empty dict).

### BREAKING — Reminders date I/O rebuilt on the oracle's own pipeline (Q10)

The whole date path — parsing, storage, timezone pinning, rendering — now runs through a
verbatim port of the oracle's functions (`EventKitCore.OracleDates`), verified by a 39-row
golden corpus produced by EXECUTING the oracle's own code (copied verbatim into
`Tests/EventKitCoreTests/fixtures/oracle-dates/`, only `TimeZone.current` pinned for
machine-independence).

**Behaviour changes for consumers:**

- **REM-02 (BREAKING value format):** `due_date`, `start_date`, `completion_date`,
  `creation_date`, and `last_modified` on reminder payloads are still JSON strings, but the
  value moved from a fixed UTC ISO instant to the oracle's rendering: due/start come from the
  stored COMPONENTS — timed (`yyyy-MM-dd'T'HH:mm:ssZZZZZ`) iff the input carried a time,
  date-only (`yyyy-MM-ddZZZZZ`) otherwise, in the components' own zone — so a date-only
  reminder is finally distinguishable from a timed one; the other three render like the
  Calendar dates, in the reminder's zone.
- **REM-03:** the 9 oracle-valid input shapes the CLI hard-rejected now parse
  (`2026-09-01-04:00`, `2026-09-01Z`, `2026-09-01+0200`, minute-precision times, offset-bearing
  space forms, …). Two measured oracle quirks are matched exactly: granularity keys off the RAW
  input containing `:`/`T` (so `…-04:00` is timed-at-midnight while `…+0200` is date-only with
  a pinned zone), and a day past month's end ROLLS (Feb 30 → Mar 2) while month 13 rejects.
  Genuine garbage still exits 64 — a documented STRICTER divergence (the oracle silently nulls
  the date instead).
- **REM-04:** `reminder.timeZone` is pinned from the parsed input (`startTz ?? dueTz`) — an
  offset-bearing date pins its fixed zone instead of always `TimeZone.current` — and a
  same-call start/due zone mismatch is now a validation rejection, both matching the oracle.
- **REM-06:** recurrence end precedence un-inverted: `end_date` wins over `occurrence_count`
  when a spec carries both (the oracle checks endDate first).
- **REM-08:** `tasks update` gains `--clear-start` / `--clear-due` (conflicting with
  `--start`/`--due`), matching every sibling clear flag. Security review rejected the first
  design (an empty-string sentinel): `--due "$UNSET_VAR"` would have silently destroyed a due
  date where the old code failed closed — so `""` and garbage still exit 64, only the explicit
  flags clear, and the flags echo in the `--dry-run` preview. (The oracle clears on ANY
  unparseable input; the explicit flag is our documented fail-closed divergence.)
- **REM-09:** reminder lists return in EventKit's native order — the user's manual
  Reminders.app ordering — instead of being re-sorted alphabetically.
- **REM-12:** a syntactically invalid `--url` on update is a no-op instead of silently WIPING
  the reminder's existing URL; `--url ""` still clears.
- `--dry-run` previews now speak the SAME wire format as execute for reminder dates (REM-02
  strings, date-only vs timed preserved) — review caught the preview still emitting UTC
  instants. Start/due timezone conflicts also surface on the preview now, not only at execute.
- **Calendar side of the shared parser widening (disclosure):** `calendar events
  create/update --start/--end` and recurrence `until=` accept the same widened format set, the
  same Feb-30-rolls/month-13-rejects split applies, and read-window bounds now honor an
  offset-bearing date-only's OWN midnight (`--start 2026-09-01+0200` binds at 22:00Z Aug 31,
  the oracle's instant — the old startOfDay floor would have shifted it by the zone gap).
- REM-05/REM-07 (geofence titles, `until=` noon anchor) were closed at the root by the shared
  Q9 fixes and are now pinned from the Reminders side too. REM-13's key-rename doc claim is
  corrected in place (four keys are renames, not re-casings — documented, not renamed: that
  would be its own MAJOR).

### BREAKING — Calendar event dates now render in the event's zone; all-day events are date-only

The oracle emits every event date through its `formatEventDate`: rendered in the EVENT's own
timezone (`event.timeZone ?? current`), with all-day start/end as date-only-plus-offset
(`2026-07-28-04:00`) and occurrence/creation/last-modified always timed. We emitted UTC
instants (`2026-07-28T04:00:00Z`) for everything — a live diff on every all-day event and on
every event in a non-UTC zone. Closes CAL-03.

**Behaviour changes for consumers:** `start_date`, `end_date`, `occurrence_date`,
`creation_date`, `last_modified`, and `alarms[].absolute_date` (the sixth date site — review
caught the first pass covering only five) on `calendar events read`/`create`/`update` payloads
are still JSON strings, but the VALUE format changed from a UTC ISO instant to the oracle's
event-zone rendering (`yyyy-MM-dd'T'HH:mm:ssZZZZZ`, or `yyyy-MM-ddZZZZZ` for all-day
start/end; GMT renders with the formatter's `Z` suffix). Reminders alarms render the same way
in the reminder's zone, matching the oracle's shared `alarmToJSON`. Any agent parsing the old
fixed `…Z` shape must adapt — which is precisely why this is BREAKING under
`docs/versioning-policy.md` (an output-value change any agent might parse), not MINOR.
The `--dry-run` preview payloads (a CLI extra with no oracle counterpart) keep their shape,
with `--alarm` absolute dates now echoed in the oracle format too.

### Fixed — six more Calendar parity gaps (Q9), one of them shared with Reminders

- **CAL-02** — a bare `yyyy-MM-dd` start/end anchored at NOON local; the oracle's
  `DateFormatter` mechanism anchors at MIDNIGHT. Every bare create/update date and recurrence
  end sat 12 hours off (read windows were already floored and are unchanged). The fix uses the
  formatter's own default, so even the nonexistent-midnight DST edge rolls forward exactly as
  the oracle does. Shared `EventKitCore.DateParsing`, so the same 12-hour skew in Reminders
  recurrence end dates (REM-07) is fixed at the root, pending Q10's own verification.
- **CAL-04 / REM-05** — the `geo:` alarm parser existed as two divergent per-domain copies,
  BOTH of which truncated a comma-bearing title to its last fragment
  (`…,742 Evergreen Terrace, Springfield, OR 97475` → title `OR 97475`); the Reminders copy also let
  any later numeric overwrite the radius and skipped lat/lon range validation. There is now
  ONE parser (`EventKitCore.GeofenceSpec`) with a documented grammar: radius and proximity in
  either order after lat/lon, then the title verbatim — commas, spacing and all. A numeric
  title is expressible after an explicit radius; a keyword after the title has started is part
  of the title.
- **CAL-06** — `events update` derived the event timezone from `--start` only (and skipped
  bare dates). Oracle rules now ported exactly (`EventTZUpdate.resolve`): start always
  re-derives the zone (bare dates → local), end derives it only when the event has none, and
  start+end with different zone identifiers in one update is a validation rejection.
- **CAL-07** — `--calendar ""` / `--target-calendar ""` hard-failed with `not_found`; the
  oracle's `findCalendar` treats nil OR empty as "the default calendar", on read, create, and
  update alike.
- **CAL-09** — `structured_location.title` was omitted for a titleless location; the oracle
  guarantees the key with its `"Location"` fallback. Review then found the ALARM geofence site
  needed the same treatment with the oracle's OWN alarm-site shape, which differs: alarm
  triggers get `title ?? "Location"` AND `radius > 0 ? radius : 100` (the structured-location
  site omits a zero radius instead — the two sites genuinely diverge in the oracle and now
  diverge identically here).
- **CAL-10** — calendar collections were re-sorted alphabetically; the oracle returns
  EventKit's native source-grouped order. The re-sorts are gone from both `calendars list`
  and the `events read` envelope.

### Added — `notes create`/`update` warn when the body looks like a checklist

Apple Notes checklists cannot be created through AppleScript: `<input type="checkbox">` is
stripped, checklist CSS classes are dropped, and markdown `- [ ]` lines arrive as literal text.
An agent that wrote a checklist therefore got `ok: true` and a note that silently was not one.
The oracle appends a warning in that case; we did not. That was NOTES-M8.

- `notes create` and both `notes update` branches now run the oracle's three detection rules
  (HTML checkbox input, markdown `- [ ]`/`* [x]` line, `checklist`/`todo` CSS class) over the NEW
  body and, on a hit, add a `warning` string to the JSON payload and append the same text to the
  `--text` line, including the Format → Checklist (⇧⌘L) conversion hint.
- The rules are ported to ECMAScript semantics, not transliterated into ICU flags: review probes
  showed 10/14 non-ASCII inputs diverging under an inline-flag transcription (`(?m)^`'s
  line-terminator set, the `\s` class, JS's ASCII-only `\b`, ICU's full case folding under
  `(?i)`), so the port spells each construct out (see `NotesText.detectChecklistAttempt`).
- The oracle's HTML rule (`<input\b[^>]*\btype…`) is quadratic on repeated unterminated `<input`
  — measured 29.6 s at 48 KB against a 5 MiB `--content` budget, on the write path. The port
  detects the same language with a linear two-phase scan instead
  (`NotesText.htmlCheckboxAttempt`); matching the oracle's hang is not parity worth having.
- `notes append` never warns — the oracle calls the detector from `create-note` and the two
  `update-note` paths only (exactly three call sites in its bundle), and warning on append would
  invent behaviour the oracle does not have.
- The `warning` key is OMITTED, not `null`, when there is nothing to say: `if "warning" in data`
  is the natural client test and a `null` would satisfy it wrongly.
- Adding an optional field is MINOR under `docs/versioning-policy.md`; the human `--text` line is
  not part of the versioned contract.

Detection is pinned to the oracle two ways: 42 hand-picked boundary rows (23 ASCII + the
JS-vs-ICU divergence probes) plus a 536-row generated corpus, 366 rows carrying non-ASCII or
control characters (`Tests/NotesKitTests/fixtures/checklist-warning-oracle/`, deterministic seed,
every verdict produced by executing the oracle's own regexes, row counts pinned in the test). The
wiring is covered at the envelope level — responses are built in
`NotesText.createResponse`/`updateResponse` and encoded through the real `Output.encodeSuccess`
path — and a 9-mutant sweep (rule drops, boundary/multiline/case degradations, the two
reviewer-named wiring mutants) kills every mutant behaviorally. Closes NOTES-M8.

### BREAKING — a wholly-failed `notes batch-delete` / `batch-move` is now an error

When NO id in a batch succeeded, both commands emitted a success envelope and exit 0. The oracle
returns an error in that case — its handlers end
`succeeded > 0 ? successResponse(...) : errorResponse(lines)`, so its behaviour is three-way:
all-succeeded is a success with `ok:true`, PARTIAL is a success with `ok:false`, and zero-succeeded
is an error. We matched the first two and got the third wrong.

The payload's `data.ok` was already `false` and `succeeded` already `0`; what was wrong is the
ENVELOPE `ok` and the exit code — the pair the output contract designates for "did this command
work". An agent testing the documented signal was told a delete succeeded when nothing was deleted.

**Behaviour changes for consumers:**

- A batch in which every id failed now exits **69** (`upstream_error`) with `ok:false`. It
  previously exited 0 with envelope `ok:true`.
- A PARTIAL batch is UNCHANGED — still exit 0, still `data.ok:false`, still carrying the full
  per-item `results` array.
- On the wholly-failed path the structured `results` array is not emitted; every per-item reason
  appears verbatim in `error.message`. This matches the oracle, whose `errorResponse` takes only a
  message and has no `structured` parameter at all.

One error type is used, not a per-reason classification, deliberately — see the note on
`requireAnyBatchSuccess`. Closes NOTES-L3.


### BREAKING — authorization failures now carry `error.status` and `error.remediation`

`apple contacts` (and any future domain whose oracle reports one) now emits the TCC state and the
how-to-fix copy as their own keys on the error envelope, instead of folding them into the message:

```json
{ "ok": false,
  "error": { "type": "authorization_denied",
             "message": "Contacts access not granted (status=denied).",
             "status": "denied",
             "remediation": "Contacts access was denied. Open System Settings → …" } }
```

This matches `apple_contacts_mcp/server.py:113-126`, whose own docs tell a client to branch on
`status` — `notDetermined` can succeed after a prompt, `denied` needs System Settings, `restricted`
is MDM and will never succeed. Closes CONTACTS-M2.

**Behaviour changes for consumers:**

- `error.message` on a denial NO LONGER has the remediation sentence appended; it is now the
  oracle's string verbatim. Read `error.remediation` for that copy. This is the breaking half:
  parsing the message was previously the only way to obtain it.
- `status` and `remediation` are **omitted, not `null`**, on errors with no authorization
  dimension, so `if "status" in error` is a valid test.
- Adding the two fields is itself additive (MINOR); the entry is flagged BREAKING for the message
  change alone, per `docs/versioning-policy.md:229` and its round-up rule at `:233`.

Only `contacts` populates these today, and that is complete rather than partial: of the installed
oracles, only `apple_contacts_mcp` returns them — `apple-notes-mcp` and `mcp-server-apple-events`
return neither. The fields live in `AppleKit` so the shape stays uniform if that changes.


### BREAKING — a pre-dispatch parse failure is now attributed to its domain, not to `apple`

**Why BREAKING and not Fixed.** `docs/versioning-policy.md:229` makes the test explicit: correcting
a wrong output value is only a PATCH when *no reasonable agent could have depended on the broken
value* — "if any agent might parse the old value, it's MAJOR, not PATCH", and the `:244` table lists
"change status/enum string value" as MAJOR. The consumer note below asserts that agents may indeed
have keyed on `tool == "apple"`, which is that trigger, so filing this under `### Fixed` would have
contradicted its own body. Repo precedent: `### BREAKING — not-found now exits 65 (was 69)` cites
the same policy.

**`schema_version` is NOT stepped, and the policy does not cleanly say whether it should.** Two
rules in `docs/versioning-policy.md` disagree for this exact case — a field's VALUE changed while
the envelope's SHAPE did not:

- `:342-344` — "`schema_version` is an **integer**, incremented **only** on a breaking output
  change (i.e. it steps in lockstep with the CLI **MAJOR** for output-affecting MAJORs)." By the
  `:244` row cited above, this change's `break` sits in the JSON-output column, so under this rule
  it steps.
- `:492` — "if the JSON output changed shape **incompatibly**, bump the integer." The shape is
  unchanged, so under this rule it does not.

This entry follows `:492`. The reason is `:345` — "Agents can hard-assert `schema_version == N` and
fail fast/loudly" — which cuts both ways: stepping the integer breaks every such assert, including
for agents that never read `tool` at all, to signal a change in one field's value; not stepping
leaves an agent that hard-asserts unaware. Breaking every consumer to signal a change that affects
only consumers routing on `tool` is the larger harm, and those consumers are addressed directly in
the note below.

An earlier draft of this paragraph cited `docs/DESIGN.md:33` for the word "SHAPE". That line does
not contain it — it reads "steps only on a breaking output change", which is the `:342-344` rule,
i.e. the one arguing the other way. The conflict is real and is filed as `HUMAN-DECISIONS.md` D11
rather than settled here by paraphrase.

`AGENTS.md` and `docs/DESIGN.md` both specify `"tool": "<domain>"` on the ERROR envelope as well
as the ok envelope, with no parse-failure carve-out. The binary emitted `"tool": "apple"` for
every failure that happened before a subcommand resolved, so `apple notes --bogus` reported
`"apple"` — a consumer routing on `tool` was misrouted at exactly the moment something went
wrong, uniformly across all six domains.

`argv[1]` names the intended domain even when the parse failed, so it now resolves the envelope's
`tool`. **The value is matched against the registered subcommand names and never echoed**, because
it lands on the stdout machine channel — the same reason the detailed message is confined to
stderr. An unknown `argv[1]` (`apple --bogus`, `apple nosuchdomain`) still reports `"apple"`, which
is the honest answer when no domain resolved. A BARE `apple` emits no envelope at all: it prints
help to stdout and exits 0, which is pre-existing behaviour this change did not touch and is
tracked separately as its own contract question (help text on the stdout machine channel).

The same resolution applies to the non-parse `internal error` path (exit 70), not only to
validation failures (exit 64) — both `Output.emitError` call sites in `main()` were changed
identically.

Resolution covers all three ways ArgumentParser lets a subcommand be named — `_commandName`
(which derives a snake-cased type name when `commandName` is nil) plus each declared alias —
because an earlier version read `configuration.commandName` alone and silently dropped any
subcommand that did not set one. The lookup resolves to the SUBCOMMAND and emits its primary
name, so every spelling maps to the one domain name the contract enumerates: an intermediate
version flattened the names into one list and returned the matched spelling, which emitted
`"tool": "<alias>"` for an alias invocation — a value absent from the domain enum, i.e. the same
wrong-routing-key defect reached by a different spelling.

Both of those misses are latent, not live: every subcommand registered today sets `commandName`
explicitly and none declares an alias. Since no runtime test can reach either,
`bats/helpers/subcommand_allowlist.py` pins the helper's body against the one correct
implementation — an exact match modulo comments and whitespace, rather than a list of forbidden
spellings, because the set of wrong spellings is unbounded while the set of right ones is one. It
separately pins ArgumentParser's own matcher, so a dependency bump that changes how subcommands are
named fails there instead of silently re-breaking attribution in a file nobody edited. Note the
lint covers the HELPER, not the two call sites that consume it; reverting those is caught by the
behavioural tests instead, so the two halves of the change have disjoint coverage.

`_commandName` is `public` but underscore-prefixed — SPI, not a stability guarantee — so the
`Package.resolved` pin on swift-argument-parser is load-bearing here rather than incidental.

**Behaviour changes for consumers:**

- Anything keying on `tool == "apple"` to detect a usage error should key on
  `error.type == "validation_error"` and exit code 64 instead.
- `tool` no longer distinguishes a PRE-DISPATCH failure from one raised inside a command body —
  `apple notes --bogus` and a validation error thrown by `notes list` now both report
  `"tool": "notes"`. Only the message string differs (`invalid arguments (see stderr for details)`
  vs the command's own text), so a consumer that needs that distinction should use exit code and
  `error.type` rather than matching on the message.

  > **Corrected 2026-08-03.** This bullet originally read "message text is not part of the
  > versioned contract". That was too broad, and a later change caught it: `docs/versioning-policy.md:229`
  > makes an output-value correction breaking "if any agent might parse the old value", which no
  > blanket exemption for `error.message` can override. The narrow claim above — don't use message
  > text to tell these two failure modes apart — is what this entry actually needed. See the
  > `error.status` / `error.remediation` entry under [Unreleased], which is called out as BREAKING
  > precisely because parsing a message was the only way to get that information.

Closes CONTACTS-L3(a), which was cross-domain rather than contacts-specific.


### Fixed — `notes update --format html` reported a title Notes would never show

Notes derives a note's title from the first rendered line of its body. The oracle mirrors that:
`resolveUpdateResponseTitle` DERIVES the response title from the new HTML and ignores `--new-title`
entirely in html format, falling back to the current title only when the body renders nothing.
This port returned `newTitle ?? currentTitle` unconditionally, so `update --format html
--new-title X` reported `X` while Notes showed the body's first line.

Ported `firstVisibleHtmlLine`: script/style blocks removed, `<br>` and block-closing
tags become line breaks BEFORE tags are stripped, HTML entities decoded, then the first non-blank
line wins after internal whitespace is collapsed. The entity decoder is a second, separate one
because THE ORACLE SHIPS TWO: this one, and an inline decoder in `htmlToPlaintext` that
`get-note-markdown` uses. Unifying them would regress the markdown path. Plaintext format keeps
the oracle's JS truthiness: an EMPTY `--new-title` falls back to the current title rather than
blanking it.

EIGHT ICU-vs-JS regex divergences were found across two review rounds. Round 1 found five: a
shared helper forced `.anchorsMatchLines`, so `$` matched at every line end and a lazy match
stopped at the first newline INSIDE a `<script>` body, leaking script source into the note title
for ordinary multi-line HTML; `\b` (ICU derives it from a Unicode word class, JS from ASCII);
`\s` (JS includes U+FEFF and excludes U+0085, ICU does the opposite); ICU full case folding
widening `[0-9a-z]` to match U+212A and U+017F; and a capture-group helper that reindexed groups
when one did not participate.

Round 2 found three MORE — and they are the same three classes again, at the sibling sites the
round-1 fixes did not sweep. `.anchorsMatchLines: false` turns out to be necessary but NOT
sufficient: ICU matches `$` before a FINAL line terminator regardless of that flag, so a trailing
U+0085 was reported as a note's entire title (`\z` is the correct ICU spelling of JS's
non-multiline `$`, now documented on the shared helper). ICU case folding also reached the
`(script|style)` alternation and its backreference, so `<ſcript>` opened a block and `</ſcript>`
closed an ASCII one. And the `<br>` regex still used ICU `\s`, so `<br` + U+FEFF + `>` merged two
rendered lines while `<br` + U+0085 + `>` invented a break.

Rather than patch those three individually, the script/style strip is now a scanner
(`stripNonRenderedBlocks`). `NSRegularExpression` genuinely cannot express the oracle here, and
the proof is a three-way squeeze: `<script>x</ſcript>AFTER` needs case-SENSITIVE matching to
behave, while `<SCRIPT>x</script>AFTER` and `<script>x</SCRIPT>AFTER` both need case-INSENSITIVE —
because JS's backreference is ASCII-case-insensitive and ICU's folding is not. No option set
satisfies all three; the round-2 regex with both patches applied still diverged from the oracle on
25.9% of one reviewer's corpus, where the scanner diverges on 0%.

The scanner also removes this site's quadratic behaviour — but only after review caught that the
first version did NOT. It derived "no `>` remains after this point", then `continue`d and let the
next `<script` rescan to end-of-input, reproducing the exact O(N²) it was written to remove, in
the sibling of the function (`stripTags`) that had already derived and acted on the same
invariant. Measured on `<script` repeated with no `>` anywhere, through the real post-write entry
point. **All three columns are M6's OWN iterations** — before M6 this path did no HTML parsing at
all (`displayTitle = newTitle ?? note.title`, O(1)), so there is no pre-existing regression here;
M6 introduced this work and these are the stages of getting it right:

| input | M6 round 1 (regex) | M6 round 2 (scanner, no bail-out) | shipping |
|---|---|---|---|
| 54.7 KiB | 2.00 s | 0.063 s | 0.0049 s |
| 136.7 KiB | 12.49 s | 0.369 s | 0.0098 s |
| 273.4 KiB | 50.06 s | 1.454 s | 0.0198 s |
| 1,025 KiB (at ARG_MAX) | — | 20.26 s | 0.0732 s |

A second quadratic was introduced in this work and caught by the same review: the `<br>` fix above
used `[jsSpace]*/?[jsSpace]*`, two adjacent unbounded quantifiers around an optional element, which
backtracks polynomially on `<br` followed by a long whitespace run that never reaches `>` — 0.018 /
0.070 / 0.282 s at 2 / 4 / 8 KiB, and stack-exhausting outright at larger sizes. The file's two
other `<br` sites kept the single-quantifier form and stayed linear. Possessive quantifiers (`*+`)
fix it exactly — `[jsSpace]`, `/` and `>` are pairwise disjoint, so no backtrack can expose a match
the greedy form would find — verified over an exhaustive 4-token sweep, 14,641 inputs, 0
divergences.

The title-addressed branch additionally reported the user's `--title` argument rather than the
fetched note's title, which differ whenever the case does. (NOTES-M6)

### Fixed — HTML tag stripping was quadratic; a large note body could hang the process

`<[^>]*>` as a global regex replace is O(N²): the engine attempts a match at every `<` and each
attempt scans to end-of-input before failing. Measured here at 0.41 s / 1.64 s / 6.54 s for 10k /
20k / 40k characters of unmatched `<` — 4× per doubling, so ~1 s at 15 KB and ~60 s at 121 KB.
`notes update --format html` ran it AFTER the note was already written, so the caller waited on a
mutation that had already happened; `notes get-plaintext` and `notes get-markdown` run it on
stored bodies, which have no argv ceiling at all. Replaced with a linear scanner at all FOUR
`<[^>]*>` sites — including `notes get`'s hashtag extraction, which review caught being left
behind because it substitutes a space rather than deleting, so the first scanner was not a
drop-in. 200k unmatched `<` completes in 0.0031 s (the earlier "0.006 s" was conservative but did
not reproduce). That benchmark is deliberately no longer quoted alone: review pointed out it was
the one shape that showed linearity while its neighbour — the same byte count of `<script` — was
still quadratic, and now measures 0.0141 s. Equivalence is established differentially
against the regex itself over 20,000 generated bodies plus hand-picked adversarial shapes, with
reach controls asserting the generator actually produced each discriminating shape — including a
combining mark adjacent to a delimiter, which is the ONLY shape that distinguishes a correct
scalar-based scanner from a `Character`-based one that would silently retain every such tag.

NINE `[^>]*` sites with the same shape remain on read paths — my census said three until all
three reviewers independently enumerated the rest, and the worst per byte (`<a href>` inline-link
conversion, ~78 s on a 128 KiB stored body) was not on my list at all. They are tracked in the
queue rather than swept here: most live in `htmlToMarkdown`, which has no oracle counterpart at
all (the oracle delegates to turndown in one line) and is slated for wholesale replacement, so
hand-fixing them now would likely be discarded work.


### BREAKING — `notes search` now returns at most 50 results by default (was unbounded)

The installed oracle (2.6.12) defaults `search-notes` to 50 (`DEFAULT_SEARCH_LIMIT`); this port
passed `limit` straight through, so an absent `--limit` meant *no cap*. Measured on the live
store: an uncapped CLI search exceeded the oracle's default result limit; both now apply that
limit. The oracle side of that diff was observed on `query:"e", one account`; review could not re-run it (the live MCP timed out at its own 30s ceiling), which is consistent with the 28.1s measured below sitting right against that ceiling. The equality was real but the comparison is marginal on this store — a narrower query is the reliable way to re-check it.

The justification is parity, not performance. An earlier draft of this entry claimed an unbounded
search "timed out at two minutes"; that was wrong and review caught it against the captured probe.
The two minutes was the harness budget for a three-command block, the unbounded search is the one
probe that *completed*, and the command still running when the block died was the most tightly
bounded of the three. Measured properly afterwards: `--limit 5` 8.3s, default-50 28.1s, unbounded
30.2s — a 7% difference, because `set matchingNotes to notes where name contains …` filters the
whole store *before* the loop, so `exit repeat` never bounds the expensive step at all.

Any caller relying on a bare `search` to enumerate every match can pass the new `--all` flag,
which restores the unbounded query as an explicit CLI-only superset (the MCP always caps). The applied limit is disclosed rather than silent: `applied_limit`,
`limit_reached` and `limit_was_default` are new optional payload fields (additive, MINOR), and `--text` gains the
oracle's ` (limit: N, default)` info on every response plus its "showing the first N; there may be
more" note when the limit is reached. The field is `limit_reached`, not `truncated`: at
count == limit we cannot know a further match exists, so "truncated" would assert more than the
data supports. `list` also discloses `applied_limit` when `--limit` is passed. The oracle carries this information
only in its prose response; on a JSON-first contract it belongs in the payload.

`list` deliberately keeps NO default — `resolveSearchLimit` is absent from the oracle's
list-notes handler, so an unbounded `list` is the correct parity.

### Fixed — `--limit 0` returned one result instead of an error

The oracle's schema declares `"limit": {"exclusiveMinimum": 0}` for both `search-notes` and
`list-notes`, so a non-positive limit is refused at the MCP boundary. This port had no such
check, and the generated AppleScript put its `exit repeat` guard *after* the append — so
`--limit 0` returned exactly one note on both commands. Both now reject it with exit 64.
An empty query is likewise refused, matching the schema's `minLength: 1`, and one over 2000
characters is refused too — the `.max(MAX.QUERY)` half of the same zod line, which the first pass
ported only halfway. (NOTES-L2)

One known nick, recorded rather than fixed: `--limit 99999999999999999999` exits 64 from
ArgumentParser's `Int` parsing, where the oracle's schema has no `maximum` and accepts it. Both
spellings mean "unbounded", and `--all` now expresses that intent properly.


### Added — `notes get-link`, the last unmapped oracle tool

`get-note-link` had no CLI subcommand at all — the one oracle tool the HEAD reconciliation found
unmapped. `apple notes get-link --id <id>` (or `--title`) now returns the `notes://showNote?identifier=…`
deep link, reading `ZIDENTIFIER` straight from `NoteStore.sqlite` and falling back to AppleScript's
`note link` property on macOS 12–15 — the same order the oracle uses. Verified against the live
oracle on a purpose-created `apple-cli-test` note: byte-identical on both the id and title paths,
including the oracle's asymmetry where the title path omits `id`.

Two behaviours worth naming. A malformed id (`--id garbage`) returns the oracle's distinct
`Invalid note ID format: "…". Expected CoreData URL (x-coredata://...) or temp ID.` rather than
collapsing into not-found — the oracle runs `sanitizeId` before any lookup, and this repo already
had the regex ported with no callers outside the batch paths. And an empty `--id` is treated as
absent, matching the oracle's JS truthiness: `--id "" --title "Real"` resolves by title, where a
naive `if let` would have failed on the empty id and never tried.

On **macOS 26.5.1 the AppleScript `note link` property no longer exists** (`The variable link is
not defined. (-2753)`), so the SQLite read is the only path that can succeed there; the fallback
is retained because the oracle keeps it for macOS 12–15 where it is reachable. Without Full Disk
Access on macOS 26 the command can only fail, which is why the failure is classified
`authorization_denied` rather than a generic internal error.

### BREAKING — not-found now exits 65 (was 69) on every AppleScript-backed Notes lookup

AppleScript says `Notes got an error: Can’t get note id "…". (-1728)` with a CURLY apostrophe
(U+2019). The error mapper tested for the ASCII `can't`, so that branch never fired and real
not-founds surfaced as `upstream_error` with exit 69 instead of `not_found` with exit 65.

The affected set was MEASURED by building both ways and diffing, not enumerated by inspection —
an earlier draft of this entry listed six and was wrong. Eight existing commands change exit code:
`get`, `get-by-id`, `get-details`, `get-markdown`, **`get-plaintext`**, `attachments`, **`list`**
and `folders` (the two bolded were missing from that draft). The new `get-link` returns 65 from
the start. Five commands checked and unchanged. The SQLite-backed `get-metadata` returned 65
correctly the whole time, which is what made the inconsistency visible.

**This is a breaking change under `docs/versioning-policy.md`** ("Reassign or repurpose an exit
code" is MAJOR; "if any agent might parse the old value, it's MAJOR"). An agent branching on 69
to mean "note missing" will not match any more — branch on `error.type == "not_found"` or exit 65.
The mapper now normalises the apostrophe and also matches AppleScript's `-1728` (errAENoSuchObject)
so a localised Notes.app still classifies correctly. (NOTES-M3)


### Fixed — `notes append` silently corrupted note bodies and could not prepend

`append-to-note` is an oracle tool that this port shipped without three of its parameters. The
tempting explanation — that the docs mislabelled it "an apple-cli extra (MCP lacks)" — is wrong:
that note was accurate when written, because `append-to-note` did not exist in the pinned oracle
version (2.5.12, 34 tools) and only arrived in the installed one (2.6.12, 36 tools). Nothing
checks a spec's pinned oracle version against what is actually installed, on any of the six
domains. Four defects followed:

- **`--position` was absent entirely**, so prepending was impossible. The oracle has
  `position: enum(["after","before"]).default("after")`.
- **`--separator` was absent AND no separator was inserted at all** — appended content was
  concatenated straight onto the previous body with nothing between. The oracle has
  `separator: string().max(20).default("\n\n")`.
- **No title-div split.** Notes stores a note's title as the body's first `<div>`. The oracle
  splits at the first `</div>` and always re-emits that div first; without it a prepend would
  have overwritten the note's title.
- **Plaintext was not escaped for `<`/`>`.** The old path reused `updateEscape`, which escapes
  `&` and newlines but passes `<`/`>` through, so `--content "<b>x</b>"` was injected as live
  HTML instead of appearing literally. Multi-line plaintext was also emitted as ONE `<div>`
  where the oracle emits one per line.

Review then found the first fix incomplete in three more places, all one root cause: Swift's
default string APIs work on grapheme clusters with canonical equivalence, while the oracle's work
on UTF-16 code units. `split(separator: "\n")` never breaks `\r\n` (one Character in Swift), so
CRLF content still collapsed into a single `<div>`; `range(of: "</div>")` slid the title-div
boundary past a combining mark, so `--position before` could overwrite the note's *title*; and
`replacingOccurrences` left `&`/`<`/`>` unescaped when followed by a combining mark. All now use
scalar splitting and `options: .literal`, verified at 0 divergences across a 3,528-case corpus
generated from the oracle itself.

Also restored the oracle's `content` minimum (`.min(1, "Content to append is required")`) —
`--content ""` was silently accepted — and its `separator` maximum of 20, measured in UTF-16
code units to match zod's `.max()`.

A separator beginning with `-` needs the equals form (`--separator=---`); the space form parses
as an option. The whole value domain stays reachable, same convention the spec already records
for `--limit=-1`.


### Fixed — Contacts rejected a parameter the oracle accepts on every write op

`apple-contacts-mcp` takes `group_identifier` on all eleven of its `DESTRUCTIVE_OPERATIONS`
(`security.py:33-47`). This CLI accepted a group on only seven of the eleven and exited **64**
on `update`, `note set`, `photo set`, `groups create`, `groups rename` and `groups delete` —
a narrowed parameter domain, which the project treats as a capability drop regardless of
whether the parameter does anything. All eleven now accept `--group`: functional (a real
group-add, echoed as `group_id` on success) on `create` and `vcard import` as before, and
accepted-and-echoed-in-preview on the other nine.

It is deliberately **not enforced**, and deliberately not called "inert": `check_test_mode_safety`
(`security.py:83-101`) compares the value to `CONTACTS_TEST_GROUP` and never to the target, so
honoring it would add no *target* scoping — this CLI restricts the target itself instead, which
the oracle does not. The two are consequently not a superset in either direction, and that
asymmetry is now written down in `docs/port-specs/contacts.md` rather than left implicit.

### Fixed — not-found messages dropped the oracle's quoting around the identifier

The oracle formats identifiers with Python `!r` at fifteen not-found sites, so a caller sees
`Contact not found: 'X'`. This CLI emitted them bare, and two sites additionally inverted the
oracle's word order (`contact 'X' not found`). All eighteen sites now match the oracle's shape.
Message text is not part of the versioned wire contract (`AGENTS.md` scopes that to property
names, enums and exit codes), so this is a behavior-parity fix, not a breaking change.


### Fixed — a signalled run stranded a snapshot of the operator's mail on disk

`atexit` does not run when a process dies of a signal, so Ctrl-C during a slow read — the most
likely abnormal exit this tool will ever see — left the whole session directory behind, holding
copies of the operator's mail and messages at 0600, until some later run's liveness sweep reaped
it. Measured before the fix: SIGTERM exit 143, SIGHUP 129, SIGQUIT 131, one directory stranded
each time.

`SIGINT`, `SIGQUIT`, `SIGTERM` and `SIGHUP` now remove it. The handler re-raises with the default
disposition rather than `_exit`ing, so the shell still sees the conventional 130/131/143/129.

Two things this went through review to get right, both of which had the first version wrong:

- **The handler now touches no Swift variables.** Reading a Swift `Array` static compiles to
  `swift_beginAccess` plus retain/release that can reach `free()`; none of that is async-signal-safe.
  Review disassembled the binary and reproduced the consequence — `track`'s append holds a `Modify`
  access across a `malloc`, so a signal in that window aborted the process at exit 134 *before* any
  cleanup, stranding the directory anyway. All handler state now lives behind one immutable pointer,
  verified in both build configurations by disassembly: no exclusivity checks, no refcounting and
  no allocation, with `unlink`/`rmdir`/`open`/`close`/`signal`/`raise` the only libc calls. (The
  handler does emit three further branches — two thin Swift overlay shims and the addressor for its
  one static, whose `swift_once` path is unreachable because arming resolves it first.)
- **An inherited `SIG_IGN` is left alone.** `nohup` and a POSIX shell's background-job setup hand a
  child `SIG_IGN` precisely so it survives; installing over it killed `nohup apple …` at 129 where
  it used to run to completion. Measured 3/3, and pinned by a test.

`SIGKILL`/`SIGSTOP` remain uncatchable, and the fatal-fault signals (`SIGABRT`, `SIGSEGV`, `SIGBUS`,
`SIGILL`) are declined on purpose — running even this handler on a possibly-corrupt heap is its own
hazard. Each of those leaves a directory that still has its `.lock`, which is the state the liveness
reaper collects on the next run.

### Fixed — snapshots of Apple's live stores were not guaranteed to be coherent

`copyToTemp` snapshots the Envelope Index / chat.db / NoteStore by copying the main database and its
`-wal` — two files, two instants. SQLite is explicit that a file-level copy of a live database can be
inconsistent, and the interleaving that does it is a checkpoint resetting the WAL between the two
copies, pairing a pre-checkpoint main file with a WAL of a different generation.

The failure is why this is worth fixing rather than documenting: WAL recovery validates the salt
against the WAL's own frames, never against the main file, so an incoherent pair is **accepted** and
the command returns a silently wrong answer instead of an error.

Two layers now, and the order of trust matters. The guarantee is a **verification**: the `-wal`
header's salt changes on every reset, so it is read before the main-file copy and again after the
`-wal` copy, and a mismatch discards the snapshot and retries. That costs two 32-byte reads, depends
on no SQLite internals, and survives any future SQLite. On top of it, a held **read transaction**
makes a mismatch vanishingly rare — an optimization, not the proof, because review falsified the
first version of its rationale: a read mark does not always block a truncate checkpoint, and the
property actually holds through two different locks depending on which read-mark slot the reader
lands in.

Chosen after measuring the alternatives on a real few-hundred-MB store pair, against a
warm end-to-end command baseline of 42 ms and 63 ms: the pinned clone costs nothing measurable
(42 vs 41 ms, 63 vs 63 ms; 0.3 ms median under a writer with periodic truncate checkpoints), whereas
`sqlite3_backup` + `journal_mode=DELETE` costs 337/493 ms and `VACUUM INTO` costs 692/747 ms — either
would make every snapshot-backed command 13–26x slower.

Two smaller results from the same work: the `-shm` copy was measured inert and dropped (SQLite
rebuilds the wal-index from the `-wal`), and the pin is taken only when a `-shm` already exists,
because opening a live store creates one inside `~/Library/Mail/` that a read-only connection cannot
remove again.

### Fixed — the test suite leaked ~25 temp directories per run into the shared temp root

Closing out the temp-file work, the shared temp root turned out to hold **~14,000 `apple-cli-*`
files, growing by 25 on every `swift test`**. The product leaks were the smaller half: the suites
themselves each had a hand-rolled helper that minted
`temporaryDirectory.appendingPathComponent("apple-cli-<label>-\(UUID())")` per call and never
deleted it.

A test-only `TestSupport` target now provides `ScratchDirs`, which vends unique directories, tracks
the exact URLs it created, and removes them in `deinit` — swift-testing builds a fresh suite
instance per test, so holding one as a stored property reclaims everything when that test ends. It
deletes only what it vended, by exact URL, never by matching a name pattern in a shared directory:
pattern-matching deletes there is how a test in this repo twice destroyed a concurrently-running
command's files. Three suites migrated; measured growth afterwards is 0 per run, with the suites
fixed earlier as the control that did not grow either way.

**Not done, left for the operator:** the ~14,000 existing files are not removed. Deleting files a
run did not create is out of bounds autonomously, and that directory is shared with other
applications. Clear this project's own with
`find "$TMPDIR" -maxdepth 1 -name 'apple-cli-*' -exec rm -rf {} +`.

### Fixed — generated `.eml` files left complete message bodies in the shared temp directory

`mail send` / `reply` / `draft-rich` build an RFC-822 `.eml` and hand it to Mail. Without `--out`
that file went loose into the shared temp root at mode 0644 and was never deleted. Measured: 244
files, 976 KB, oldest 11 days — full messages, headers and bodies, world-readable.

They cannot simply be deleted when the command ends: `openEml` runs `/usr/bin/open -a Mail <path>`,
which returns immediately and leaves Mail to read the file after the process is gone. (The sibling
`--gui-send` HTML temp IS deleted on exit, because that path is synchronous.)

The two call sites now get different answers, which is the substance of the fix. An explicit
`--out` is operator-facing output: the path is honoured exactly, the mode is left at their umask,
and nothing ever deletes it. Without `--out` the file is an internal temp: it goes in an owned 0700
directory at mode 0600 and is reaped after 24 hours by a later run. The `--gui-send` HTML temps
moved there too — they were `defer`-deleted on the happy path but survived any crash, in the shared
root where nothing would ever collect them.

Age is a weaker predicate than the `flock` liveness check used for the SQLite snapshots, and that is
deliberate rather than an oversight: there the owner is one of our own processes and the kernel can
answer exactly, whereas here the consumer is Mail.app, which cannot be locked or interrogated. The
hand-off completes in seconds, so 24 hours is orders of magnitude more slack than it needs, and the
worst case is a visible compose window rather than a corrupted read.

The owned-directory logic is now one shared `AppleKit/OwnedTempDir` rather than two copies, so the
snapshots and the `.eml` files get the same guarantees: validated on every call (must be a
directory, must be owned by this uid, mode re-asserted to 0700 and verified, symlinks refused) on
both the already-exists and the just-created paths. Path computation is separate from
materialisation, so `--dry-run` reports its planned destination without creating a directory,
without deleting anything, and without acquiring a failure mode a preview never had.

**Not done, left for the operator:** the 244 pre-existing files are not removed. Deleting files the
run did not create is out of bounds for an autonomous change, and the shared temp root belongs to
other applications too. Clear them with
`find "$TMPDIR" -maxdepth 1 -name 'apple-cli-*.eml' -delete`.

### Fixed — question detection never looked at message bodies

Oracle B scores a message as containing a question if the subject OR the first 500 characters of the
message content contain `?`. `analyticsRows` selected no body text at all, so `Analytics.Row.snippet`
was nil for every row and the body half of that test was unreachable: `"MEDIUM (contains question)"`
could not fire on a body-only question, and `priorityScore` permanently lost its 2-point body term.

`analyticsRows` now joins the Envelope Index `summaries` table (`messages.summary` is an integer key
into it) and selects the first 500 characters, the same window the oracle reads. Measured on the
live store with `needs-response --days 90 --max 200`: the same 43 rows come back either way,
but 7 now score as questions versus 3 before, and 4 of those are body-only detections that were
structurally impossible.

This narrows the divergence without closing it, so the limit is stated rather than implied. The
oracle reads the body live over AppleScript and therefore has one for every message it scores; we
read Mail's cached preview, which exists for only some. On this store that is a small fraction of all
messages, but the figures are ratios over different populations and coverage concentrates in the
recent window these commands score: roughly a third of the messages from the last 7 and last 30 days, and
well over half of the newest 200 by date — the oracle's own bound. Where
no preview exists the test falls back to subject-only and can under-score. It can also over-score:
`summaries` holds a preview Mail generates at index time — whitespace-normalised, boilerplate
collapsed — not a literal substring of the body, so a `?` at preview character 480 may sit past raw
character 500 and outside the window the oracle reads. Both directions of error are possible.
Closing the gap means a per-message AppleScript body fetch, which is a latency decision rather than
a defect and is tracked separately.

The join is gated behind a probe for the table and the `messages.summary` column. The Envelope Index
is Apple's private schema and varies by Mail version; a hard-coded join would turn every analytics
query into `no such table: summaries` on a store that lacks it, which is a far worse failure than
the weaker detection the join exists to improve.

### Fixed — snapshot copies of the operator's mail and messages accumulated in `$TMPDIR`

`SQLiteReader(copyToTemp:)` copies the Envelope Index / `chat.db` / `NoteStore.sqlite` so reads see
a consistent, WAL-applied view, and deleted the copy in `deinit`. `deinit` essentially never ran:
ArgumentParser ends a command with `exit()`, which tears the process down without releasing the
reader. Measured before the fix: **>150 snapshot files totalling multiple GB, mode 0644** — real subjects,
senders and recipients, left readable in `$TMPDIR` indefinitely and never collected.

Cleanup is now keyed to **process liveness rather than to a clock**. Each process creates
`$TMPDIR/apple-cli-snapshots/s-<pid>-<uuid>/` (0700, snapshots inside at 0600), holds
`flock(LOCK_EX|LOCK_NB)` on a `.lock` in that directory for its whole life, and removes the
directory wholesale from an `atexit` handler. Anything a crash strands is collected on the next run
by asking the kernel, not a timer: the reaper tries the lock on each sibling directory — acquired
means the owner is gone and the directory is removed; `EWOULDBLOCK` means a reader is alive and it
is skipped. The snapshots root is re-validated on every call (must be a directory, must be owned by
this uid, mode re-tightened to 0700), because `createDirectory(attributes:)` applies its mode only
when it creates and every run after the first takes the existing-directory path.

Three earlier designs were measured and rejected; `docs/COMPLETION-LOOP.md` Q4d records them so they
are not re-derived. Two tried to delete the snapshot early and both fail because SQLite reads the
file lazily — unlinking after `sqlite3_open_v2` dies on the copied `-wal` with `disk I/O error`, and
checkpoint-then-unlink survives a warm read but fails once a later query faults in a page. The third
collected orphans **by file age**: it shipped and was reverted, because `FileManager.copyItem`
preserves the source's mtime, so a snapshot of a store idle for an hour is born already past the
threshold and a concurrent `apple` deletes a live reader's files. Stamping each copy fresh repairs
that specific case but not the predicate — age only ever estimates whether an owner is still there,
so a laptop asleep mid-command reopens the same hole. Liveness answers the question age was guessing
at, and the kernel releases an `flock` on any process death including `SIGKILL`.

Not covered, and tracked: `atexit` does not run on `SIGINT`/`SIGTERM` (Q4i), the reaper only looks
inside its own root so pre-fix leaks on other machines are not collected (Q4g), and the main DB and
its sidecars are still copied at three separate instants, which SQLite does not guarantee to be
coherent (Q4h).

Also fixed: `EnvelopeIndexTests` leaked one fixture per test into `$TMPDIR` — 979 files, ~42 MB on
the machine where it was found — the same class of defect as the bug above, in this repo's own
tests. A full suite run now leaves nothing behind.

### Fixed — `needs-response` and `awaiting-reply` read the wrong Sent mailbox, in the wrong order

Two analytics commands sourced their Sent data through the same two defects. Neither raised an
error; both commands returned plausible output and quietly stopped doing their filtering job.

- **Wrong mailbox (the one that actually bit).** Sent selection used
  `first(where: isSentMailbox)` — whichever candidate came first in ROWID order — ignoring the
  oracle's fallback priority `Sent Messages` → `Sent` → `Sent Items` (smart_inbox.py:274-283).
  Measured on the live store: one account owned BOTH `Sent` (near-empty) and `Sent Messages` (populated). So `needs-response` suppressed against
  a single stale subject, and `awaiting-reply` analysed one sent email. `awaiting-reply`'s
  `leaf.contains("sent")` additionally matched unrelated names merely containing "sent".
- **Wrong order, masked behind it.** `analyticsRows` had no `ORDER BY`, so `.prefix(200)` and
  `prefix(max)` kept insertion order. This goes live the moment the mailbox fix lands and the real
  populated mailbox is read: unordered-first-200 spans a much wider window where the newest-200 the
  oracle reads is far narrower. The oracle walks Mail's enumeration — measured
  newest-first (checked at both ends) — bounded by
  `if sentIdx > 200 then exit repeat` for needs-response and `resultCount >= max_results` for
  awaiting-reply.

Sent selection moved into a pure, unit-tested `Analytics.preferredSentMailbox` mirroring the
oracle's priority, with `Sent Mail` appended as a documented CLI extra so Gmail-backed accounts
(which expose only that name, and which the oracle therefore skips entirely) are not left with a
filter that does nothing. `analyticsRows` gained a `slice:` parameter — `.all`, `.newestFirst`,
`.newest(n)` — replacing separate `order:`/`limit:` arguments so that the dangerous combination
(bounded but unordered, i.e. the shipped bug) is unrepresentable rather than merely discouraged. A
non-positive bound now returns no rows instead of silently meaning unlimited.

Also corrected: the account filter added here is correctness-hardening, not the thing that broke
this store — `resolveMailboxes` already skipped foreign accounts, so a cross-account leak was never
possible; the unfiltered lookup could only pick a name the account lacked and return nothing. And
the doc comments claiming `hasQuestion` covers message bodies were false — `analyticsRows` never
joins `summaries`, so that branch is dead. The comments now say so; the gap is tracked as Q4e.

### Fixed — `analytics stats` scanned the wrong mailboxes for two of its three scopes

Oracle B scopes each `get_statistics` analysis differently (`tools/analytics.py`), and the CLI
collapsed that into one inverted ternary, getting three things wrong at once:

| scope | oracle | was | now |
|---|---|---|---|
| `account_overview` | whole account, skip-folders excluded, days applied | correct | unchanged |
| `sender_stats` | whole account (`mailbox` ignored) | scoped to `--mailbox`, default INBOX | whole account |
| `mailbox_breakdown` | the named mailbox, default INBOX | `--mailbox` discarded, spanned everything | honors `--mailbox` |

Two filters were also applied where the oracle applies none. `mailbox_breakdown` counts
`every message of targetMailbox` — no `whose date received` clause and no SKIP_FOLDERS check
(interpolated only at :170 and :314, the two broad scans) — so the CLI was date-filtering it and
could filter a named system folder down to nothing. Asking for a breakdown of Trash returned zeroes.

Practical effect: `sender_stats` silently reported INBOX-only numbers as if they were account-wide,
and `mailbox_breakdown` could not answer the question it exists to answer.

`--days` is now reported as applied rather than as requested — `mailbox_breakdown` responses carry
`days_back: 0`, because echoing `30` over an all-time count is a claim the caller cannot check.
`--mailbox All` remains a CLI extra for the cross-mailbox breakdown, and `account_overview` still
emits the same array, so honoring a named mailbox adds the oracle behavior without removing either.

The semantics now live in one tested function (`Analytics.scopePlan`) instead of an inline ternary
behind a live `MailContext`, which is why nothing caught this: the logic was unreachable from any
test that did not have the operator's Mail store.

Three further defects, all reachable only *because* `--mailbox` now works, were found in review and
fixed in the same change:

- **`--mailbox all` and `--mailbox All` returned different totals** (thousands of messages apart on the
  measured account). `EnvelopeIndex.isAllWildcard` is case-insensitive and documents itself as the
  single authority precisely so callers cannot desync; the new code re-tested the string with `==`,
  so a lowercase spelling took the resolver's every-mailbox branch while the system-folder exclusion
  silently switched off. Now asks `isAllWildcard`.
- **A named breakdown reported the backing store's path.** Both named scopes could resolve to
  a backing identifier that named neither request. A named breakdown is now one entry labelled with the
  mailbox the caller asked for.
- **An unknown mailbox returned `ok:true, total:0`** where the oracle raises `"Mailbox not found"`
  (analytics.py:362-370). Now a `not_found` error. The check is on mailbox EXISTENCE, not row count,
  so a real-but-empty mailbox still reports zero rather than erroring.

`StatisticsResult` also gained an optional `mailbox` field echoing the scope actually scanned —
additive, MINOR — because with `--mailbox` honored it is the only way a caller can distinguish an
empty result for the mailbox they meant from one for a mailbox they mistyped.


### Added — oracle-A safety ports (rate limiter, recipient cap, bulk cap)

Three limits oracle A (`apple-mail-mcp` s-morgan-jeffries@0.6.0) enforces are now carried by the
CLI. Under write-model v2 these are BUCKET 1 (oracle-mirrored ⇒ they apply unconditionally, sandbox
or not); v2 lifts CLI-only restrictions, not limits the oracle itself imposes.

- **Send rate limit — 3 sends / 60s** (`TIER_LIMITS["sends"]`), on `mail send` and `mail forward`
  only, matching `OPERATION_TIERS` exactly. Only real sends consume budget; `--dry-run` never does.
  Because the CLI is a fresh process per invocation where the oracle is a long-lived server, the
  window persists to `~/.apple-cli/send-rate-limit.json` (override with
  `APPLE_SEND_RATELIMIT_STATE`) and uses wall clock rather than `time.monotonic()` — a documented
  divergence, since a monotonic clock cannot be compared across processes. Fails OPEN and warns on
  stderr if that state is unwritable.
- **100-recipient cap** on `mail send` only, counting `to + cc + bcc` combined, mirroring
  `validate_send_operation` (server.py:898, :1085). **Not** applied to reply/forward/draft-rich:
  oracle A's `forward_message` checks only `if not to:`, `reply_to_message` validates nothing, and
  oracle B caps nothing — capping them would refuse input both oracles accept.
- **100-item bulk cap** on `mail mark` and `mail delete` only, bounding the input id count, with
  each op's own oracle wording (`mark_as_read` via `validate_bulk_operation`; `delete_messages`
  inline). `move` and `flag` stay uncapped because the oracle does not cap them.

**BEHAVIOR CHANGE:** input previously accepted is now refused on the three capped surfaces, and
three real sends inside 60s now refuse with `Rate limit exceeded` (this affects
`bats/live/mail-writes.sh`, which performs a real send).

**Known gaps, deliberately not closed — see `HUMAN-DECISIONS.md` D8.** `reply` carries no rate
limit though oracle A allows 20/60s via the unported `expensive_ops` tier, and `draft send`
delivers with neither cap. Both are oracle-faithful under the "each oracle owns its operations"
reading this change adopts, and both are real safety gaps under any other reading; resolving that
is an operator posture call, not a parity fact.


### BREAKING — Calendar + Reminders write-model v2: writes EXECUTE by default

Fourth and fifth domains flipped to write-model v2 (`docs/write-model-v2.md`), in the two
coordinated module edits the spec called for. **`EventKitCore` holds no write guard of any kind**
— its `EventStore.swift` documents that callers gate and enforces nothing itself — so the two
domains are genuinely independent edits, not a contended core change. Its WRITE-GUARD CONTRACT
comment block is updated (comment-only, no behavior change) because it still specified the v1
posture that v2 removes.

**Evidence (`mcp-server-apple-events@1.4.0`).** Unlike the Notes package, this one ships BOTH
`src/` (58 `.ts` files) and `dist/`, and both were confirmed non-empty before any negative was
believed. The only runtime `process.env` reads in non-test sources are `NODE_ENV`, `DEBUG` and
`SWIFT_BINARY_HASH` — none a write gate, so unlike Contacts there is no env-keyed oracle gate to
preserve. `tools/index.ts` is a pure action→handler router; `calendarRepository.deleteEvent` /
`reminderRepository.deleteReminder` / `deleteReminderList` shell straight to the Swift CLI; and
the oracle's own `src/swift/EventKitCLI.swift` (1619 lines) reads no environment and self-gates
nothing. All 14 write ops are CLI-only restrictions (bucket 3).

- **BREAKING (behavior): all 14 Calendar + Reminders writes execute when invoked** — Calendar
  `events create/update/delete`; Reminders `lists create/update/delete`, `tasks
  create/update/delete`, `subtasks create/update/delete/toggle/reorder`. `--dry-run` previews;
  `APPLE_DRY_RUN=1` restores dry-run-by-default. **Any script or shell-history invocation that
  relied on the old dry-run default now mutates the real Calendar/Reminders store.** The v1 gate
  (`--execute` plus `--test-mode` plus `APPLE_TEST_MODE=1`) is gone.
- **The sandbox is opt-in and single-signal**: `APPLE_TEST_MODE` truthy or `--test-mode`, either
  alone. Inside it, writes stay confined to `apple-cli-test…`-labeled events/reminders/lists;
  refusals remain `validation_error` / exit 64 (the Calendar/Reminders refusal type, not
  Mail/Contacts' 77). Sandboxed success envelopes carry `"sandbox": true`.
- **NEW sandbox coverage — destinations, not just subjects.** `--new-name` (lists update) and the
  rename targets (`tasks update --title`, `events update --title`) are now label-checked, so a
  sandboxed run cannot walk a test item out of the sandbox by renaming it. `--target-list` is
  vetted too, but post-resolution: the flag takes a name OR an opaque id, so a labeled NAME is
  settled from argv while anything else defers to the resolved list's title (a labeled list's id
  carries no prefix, and refusing it would break the id-based flow this repo's own conduct rules
  prescribe). Calendar's `--target-calendar` is DELIBERATELY not checked: the CLI exposes
  `calendars list` only — no calendar create/update/delete exists — so no `apple-cli-test…`
  calendar can be named, and a check would permanently refuse every explicit destination. The
  default list/calendar is exempt for the same reason. This applies forward the finding the Notes
  flip's review surfaced on `move --folder`, with the per-surface differences it turns out to need.
- **Preview honesty.** Argv-computable checks run on the preview path. The genuinely deferred ones
  — the EXISTING item's title on any by-id update/delete, and the parent reminder's title on all
  five subtask ops — now emit `sandbox_target_unchecked: true` in the preview instead of letting a
  silent non-refusal read as approval.
- **Contract:** `DeleteData`, `ReminderDeleteData` and `ListDeleteData` gain an explicit
  `dry_run: false` on the execute path (MINOR — an added optional field). It was deliberately NOT
  added to the shared read models an execute path also returns (`EventMapping.event`,
  `SubtasksData`), which would have leaked a write-only key into `events read` / `subtasks read`.
  Known inconsistency across landed flips: Contacts' result DTOs carry `dry_run: false`, Notes' do
  not; normalising all six is a tracked follow-up, not a silent in-flight change.
- **The oracle's input-validation layer stays deliberately un-mirrored** (`validation/schemas.ts`:
  `.min(1)` id/name bounds, length caps, printable-Unicode charset, SSRF URL blocklist). A strict
  superset must accept everything the oracle accepts. This was checked explicitly against the Notes
  CRITICAL rather than assumed: EventKit is id-based, so an empty id yields `not_found` and an
  empty list name matches only a literally-empty title — there is no analogue of Notes'
  `folderRefExpr([])` collapsing to a bare `delete` bound to the account container.

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
