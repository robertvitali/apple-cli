# apple-mail — MCP → CLI Porting Analysis

**Domain:** Apple Mail (macOS Mail.app). The fleet runs **two** Mail MCPs; the port target is the **UNION** of both surfaces.

- **MCP A** — `github.com/s-morgan-jeffries/apple-mail-mcp` @ **v0.6.0** (`mcp__apple-mail__*`). 27 tools. Python. AppleScript bridge + optional IMAP fast path. Strong on **rules + templates + ID-precise ops + Mail-UI selection**.
- **MCP B** — `github.com/patrickfreyer/apple-mail-mcp` @ **v3.1.3** (`mcp__apple-mail-pf__*`). 24 tools. Python. AppleScript + (likely) Envelope-Index reads. Strong on **HTML/drafts + filter-based bulk ops + analytics + export**.

Verification method: live MCP tool-schema introspection (read-only; authoritative for params) cross-referenced with each repo's pinned-tag README. MCP A's 27 tools and MCP B's 24 tools each match the seed lists exactly; MCP A behavior notes (issues #72/#73/#111) confirm a v0.6.x-era build. **No binaries were installed or run.**

The two MCPs overlap heavily on the CRUD core but **diverge on almost everything advanced** — and, critically, use **different targeting models**: MCP A is **message-ID-precise**, MCP B is largely **subject-keyword / filter fuzzy**. The union needs BOTH.

---

## 1. MCP capability manifest — UNION table (across both MCPs)

Class legend: **CORE** = primitive Mail operation · **DERIVED** = computed on top of primitives (analytics/heuristics) · **DIAGNOSTIC** = introspection/health.

| # | Union capability | Provided by | Class | Key params | Behavior / notes |
|---|---|---|---|---|---|
| 1 | List accounts | A `list_accounts`, B `list_accounts` | CORE | — | A returns UUID+name+emails+type+enabled (UUID stable); B returns names only. **Overlap; A superset.** |
| 2 | List mailboxes | A `list_mailboxes(account)`, B `list_mailboxes(account?,include_counts)` | CORE | account, include_counts | A requires account; B optional (all-accounts) + counts + path form. **B superset.** DIVERGENCE: CLI `--counts` unread_count is Envelope-Index-derived (local read bit) and can diverge from both oracles' live Mail.app `unread count` on server-synced accounts (measured live: the index unread count ran slightly above the live value on All Mail and below it on Drafts, total_count identical); `unread-counts` reads live Mail.app and matches the oracle. |
| 3 | Create mailbox (nested) | A `create_mailbox`, B `create_mailbox` | CORE | account, name, parent_mailbox | Both support nesting; B also accepts full slash-path in `name`. **Overlap.** DIVERGENCE: the CLI char-validates PARENT segments too (oracle B validates only the name's segments before prepending the parent), so `--parent 'Bad:Parent'` is refused where oracle B would attempt it — stricter, deliberate (the oracle's acceptance can only yield a broken mailbox). Empty-name is judged on the NAME's segments before the parent is prepended, matching oracle B's order. |
| 4 | Search messages | A `search_messages`, B `search_emails` | CORE | subj, sender, body, date_from/to, read, flagged, has_attach, limit/offset, sort, mailbox, account | **Conflict:** A requires `account`, INBOX default, adds `is_flagged` filter, no body/pagination. B optional account (all), body_text search, offset/limit pagination, sort, `mailbox="All"`, JSON. **B near-superset EXCEPT A's `is_flagged` search filter.** DIVERGENCE: an unknown --mailbox (including the untyped INBOX default on an account with no INBOX-named mailbox, e.g. a local On-My-Mac store) is not_found/65, matching oracle A's `mailbox "X" of account` error — previously an empty success. PARITY NOTES (Q11b4, gap2): `--body --body-live` is oracle B's body_text semantics — ONE live AppleScript pass per mailbox reading the FULL `content` of each candidate with the whole condition set applied in-loop and the oracle's collectLimit/offset early-exit; values travel via argv (the oracle string-interpolates — the injection class this repo refuses) and there is NO per-field `tr` subprocess (AppleScript `contains` is already case-insensitive — the oracle's tr-per-field is its own timeout cause). The oracle's per-Apple-event 180-second timeout remains in the script. DIVERGENCE (operator-approved default): the CLI defaults to a 195-second aggregate osascript deadline so a swallowed or stalled event cannot orphan the runner indefinitely; a bounded scan whose total work crosses its configured cap fails as upstream_error/69 and discards partial output. Passing `--body-live-timeout 0` selects the untimed host runner and restores oracle B's unbounded aggregate behavior (the oracle-aligned 180-second per-event timeout remains), preserving strict-superset capability; a positive value selects another aggregate cap. With a bounded scan, narrow using --mailbox/--account (a lower --limit helps only when matches are plentiful), or use the indexed preview path. The 15-second margin is process-teardown headroom, not reserved startup time, so either timeout may fire first. Terminating osascript does not cancel an Apple event already queued in Mail, which may remain busy after the CLI exits. Fix-round disclosures: a full nested path is reduced to its LEAF for the live scan and the flattened `whose name is` then matches EVERY nesting point of that leaf (superset — the oracle's `mailbox X of account` is top-level-only); Gmail label mailboxes are honored via the index's label-aware scope check (a home-mailbox compare would reject every label hit); duplicate ids from a Gmail INBOX/All-Mail double-listing are de-duped order-preservingly; --sort IS honored — the oracle sorts the collected window then slices (_build_search_response, search.py:146-149; the first draft claimed scan order from reading only the collection half — review-caught, measured); `--mailbox All` on the live path sweeps TOP-LEVEL mailboxes only, byte-what the oracle's `every mailbox of account` does (measured: nested mailboxes are invisible to it) while the indexed path includes nested — disclosed asymmetry; date bounds are rebuilt from host-computed LOCAL calendar components, matching the oracle's local calendar-day bounds (search.py:50-56) — NOTE the INDEXED path binds UTC midnight (pre-existing divergence from the oracle, now disclosed); previews shown on live hits come from the INDEX and may not contain the needle the live body matched; `--limit 0` means ALL here (CLI-wide convention) where the oracle returns [] for limit<=0; case-insensitive `contains` equals the oracle's tr for ASCII and is a superset for non-ASCII. The default `--body` (indexed-preview match) stays a disclosed fast CLI extra. |
| 5 | Get message by ID | A `get_message(message_id, …)` | CORE | message_id, include_content, headers_only, account/mailbox (IMAP fast path) | Full structured detail by stable ID. **A-only (ID-precise).** DIVERGENCE: CLI `--account`/`--mailbox` are hard scope ASSERTIONS (not_found on mismatch); oracle A treats them as an IMAP perf hint and, on the AppleScript fallback (the state on a keychain-less Mac), still returns the message from wherever it lives. Same posture on `attachments list <id>`. |
| 6 | Get selected (Mail UI) | A `get_selected_messages(include_content)` | CORE | include_content | Reads whatever msgs the user highlighted in Mail. **A-only.** |
| 7 | List recent inbox | B `list_inbox_emails` | CORE | account?, max_emails, include_read, include_content, output_format | Recent list, read filter, content preview, JSON. **B-only (A does this via search).** PARITY NOTES (Q11b4, gap9): oracle B's max_emails caps PER ACCOUNT and counts inbox messages EXAMINED, not returned (currentIndex increments BEFORE the include_read filter, inbox.py:167-176) — `--limit-per-account` carries exactly those semantics via a pinned window helper: the newest `per` rows are windowed first and `--unread` filters INSIDE the window, so fewer rows than the cap can return (review-caught: the first cut filtered in SQL and returned strictly more); 0 = no per-account cap. DIVERGENCE (disclosed): rows are merged globally newest-first where the oracle emits grouped per account in account order; and the global `--limit` (CLI extra) still caps the merge at its DEFAULT 50 — pass `--limit 0` for the oracle's uncapped shape. |
| 8 | Get thread | A `get_thread(message_id)`, B `get_email_thread(subject_keyword)` | CORE | A: message_id (RFC5322 In-Reply-To/References) · B: subject_keyword, mailbox, max | **Conflict:** A header-precise by ID; B fuzzy by subject. Union should offer both. DIVERGENCE: a `--subject` that strips to ONLY reply/forward prefixes (e.g. 'Re: ') is rejected (validation_error) where oracle B would match everything; when an id argument and `--subject` are both given, the id takes precedence and `--subject` is silently ignored (oracle B has no id addressing to conflict with). |
| 9 | Unread counts | B `get_mailbox_unread_counts` | CORE | account?, include_zero, summary_only | Per-mailbox or per-account inbox totals. **B-only.** DIVERGENCE: an unknown `--account` is not_found (exit 65, fail-loud) where oracle B returns an empty dict as a success; documented as deliberate (extra10). Summary emits oracle B's -1 sentinel for an unreadable inbox; nested descends one sub-mailbox level with 'Parent/Child' keys, exactly the oracle's depth. |
| 10 | Send email (plain) | A `send_email`, B `compose_email` | CORE | to, subject, body, cc, bcc | A elicitation-confirm; B comma-str recipients. **Overlap.** |
| 11 | Send — HTML body | B `compose_email(body_html)` | CORE | body_html + plain fallback | **B-only.** The generated `.eml` `--out` path refuses a raw final-leaf symlink before Mail access and rechecks immediately before execute writes. Refusal is `safety_violation` / 77 and beats generic file-write failures. Narrow residual: a raw spelling with `..` through a preceding intermediate component that does not exist cannot be inspected through that exact raw spelling and may be standardized by downstream confinement; this shape is operator-controlled and narrow. A residual time-of-check race remains after the final host check and before the filesystem write. |
| 12 | Send — attachments | A `send_email_with_attachments`, B `compose_email(attachments)` | CORE | attachments[] | A separate tool; B folds into compose. **Overlap.** |
| 13 | Send — mode (send/draft/open) | B `compose_email(mode)` | CORE | mode = send\|draft\|open | Open compose window for review, or save draft silently. **B-only.** |
| 14 | Reply (plain, reply-all) | A `reply_to_message`, B `reply_to_email` | CORE | A: message_id, body, reply_all · B: subject_keyword, reply_body, reply_to_all | **Conflict:** A by ID, B by subject-keyword. PARITY NOTES (Q11b5, gap17/extra16/extra14): `--mode send/draft/open` now covers oracle B's reply modes on the NATIVE reply verb — every mode passes the SAME in-script allowlist audit before delivery; draft files via the MEASURED verb pair (open compose window + `save m`, then close WITHOUT re-saving — a saving-yes close aimed at the outgoing MESSAGE silently DISCARDS it, measured live; the oracle's own draft save is the window-close shape) and was live-verified end-to-end (draft filed to Gmail Drafts, deleted after); `open` leaves a visible compose window. BREAKING: the `--subject` lookup now scopes to INBOX by default (oracle B searches only the inbox; the old store-wide sweep could bind an archived/sent message) — `--mailbox All` restores the sweep. Forward's `--mailbox` default flipped the same way (oracle B forward_email default) and its preview/result now carry oracle B's `recipients` echo (extra14; on a live send it echoes what MAIL actually addressed). Result contract: `executed` means "mail left the machine" — a `--mode draft` reply reports `executed:false, drafted:true`, matching `mail send --mode draft` (review-aligned). Replies compose WINDOWLESS in every mode and the compose window is revealed only AFTER the in-script allowlist audit (a visible-then-refused window could leave a server auto-saved copy in remote Drafts — hardened per review); draft mode's reveal+`save m` can leave the compose window open showing the filed draft (Mail quirk, measured — disclosed in the result note). |
| 15 | Reply — HTML + attach + mode | B `reply_to_email(body_html, attachments, mode, cc, bcc)` | CORE | body_html, attachments, mode, cc/bcc | **B-only (richer reply).** PARITY NOTES (Q11b5, gap15/extra15): `--html` with `--gui-send` or `--mode draft/open` runs the ORACLE'S pasteboard flow — Mail's native `reply` verb (threading headers + replied-to state + Mail's own quoted original in the HTML layer) with the fragment inserted via NSPasteboard + Cmd-V, NEVER `set content` (which clobbers the HTML quote layer — oracle B's own engineering comment, compose.py:601-605). Requires Accessibility and steals focus, same as the oracle; a denied paste is FAIL-CLOSED (measured live with Accessibility denied: the composed draft is discarded, nothing sent, typed compose-failure error). The fragment travels by temp-file PATH read via NSString in-script (the oracle shells `cat` and interpolates the path — the injection class this repo refuses). RESIDUAL: plain `--html --mode send` without `--gui-send` keeps the reliable no-Accessibility `.eml` compose-window path (UNTHREADED — disclosed in the result note). RESOLVED (plain reply — decision-5, 2026-08-18): the PLAIN `reply` path now ALSO routes through the pasteboard flow (was `set content`), matching oracle B, which pastes even plain-text bodies — a plain reply now PRESERVES Mail's HTML quote layer instead of flattening it. Like the HTML path it needs Accessibility, steals focus, and is FAIL-CLOSED on a denied paste (draft discarded, nothing sent). `--body` is wrapped as the oracle's `<div>`+gap-div HTML fragment (`MailComposeFragment.replyPlain`, byte-exact to compose.py's `html.escape`). Pasteboard disclosures: during the paste the HTML fragment sits on the system pasteboard and is readable by any local process/clipboard manager (string layer cleared unconditionally after, restore is best-effort — hardened per review to clear on error paths too); the blind Cmd-V is nonce-bound to the compose window this call created and the paste is READBACK-verified (an unlanded keystroke refuses instead of sending an empty reply); a refusal AFTER the paste reveal may still leave a server auto-saved draft copy on IMAP/Gmail accounts (auto-save races the discard — observed once in probes). |
| 16 | Forward | A `forward_message`, B `forward_email` | CORE | A: message_id, to, cc, bcc, body-prefix (elicit) · B: subject_keyword, to, message, cc, bcc | **Conflict:** A by ID, B by subject. PARITY NOTES (decision-5, 2026-08-18): a `--body` prepend is pasted as HTML via NSPasteboard + Cmd-V (`MailComposeFragment.forwardPrepend`, byte-exact to oracle B compose.py's `{escape}<br><br>`) — NEVER `set content` — so Mail's forwarded original keeps its HTML layer. With a `--body` the forward requires Accessibility, steals focus, and is FAIL-CLOSED on a denied paste (draft discarded, nothing sent); the success note discloses the focus-steal. An EMPTY-body forward skips the paste entirely (oracle B pastes only when a message is provided) and needs no Accessibility. Same pasteboard disclosures as row 15 apply while the fragment is on the clipboard. |
| 17 | Drafts management | B `manage_drafts` | CORE | action = list\|create\|send\|open\|delete; subject/to/body/cc/bcc/draft_subject | Full draft CRUD. **B-only.** |
| 18 | Rich `.eml` draft | B `create_rich_email_draft` | CORE | account, subject, to, text_body, html_body, cc, bcc, output_path, open_in_mail, save_as_draft | Generates multipart `.eml`, opens in Mail (reliable HTML rendering). **B-only.** PARITY NOTES (Q11b5, gap19/gap20/extra17/extra18/extra19): the oracle's helpers are ported PURE and python-golden-pinned — `_safe_eml_name` (regex runs→"-", strip "-._" edges, fallback, 80 cap), `_build_html_from_text` (byte-identical incl. html.escape's &quot;/&#x27;), `_prepare_rich_bodies` (Draft-outline placeholder / HTML-wrapper / rich-content fallback) and `missing_details` (subject→to→body order); the default destination is the oracle's DETERMINISTIC subject-named path (preview names the same file execute writes) under `~/Library/Caches/apple-cli/rich-drafts/` — DIVERGENCE: the oracle writes under `apple-mail-mcp/`; same layout, different app dir. Sender resolves UNCONDITIONALLY and a failed resolution OMITS the From header (extra18) except the open path, which stays fail-loud; parent dirs are created with a typed upstream wrap (extra17); **`--open` now DEFAULTS TRUE** (D6/extra20, 2026-08-19), matching oracle B's `open_in_mail=True`; `--no-open` restores the headless write. The previously-unrecorded opt-in flip was the reason extra20 was filed. The outbound guard on the open path runs only when recipients are PRESENT — oracle B opens a recipient-less, subject-less draft and reports `missing_details` (compose.py:139-140, :178-186), so guarding unconditionally made the CLI strictly less capable than the oracle on its own default config (review-caught). The sandbox self-only allowlist still applies in full the moment a recipient is typed. `--save-as-draft` attempts oracle B's `_save_open_message_as_draft` retry save and reports `saved` HONESTLY (extra19) — ORACLE-DIFFED live: BOTH sides return saved=no on this store (a LaunchServices-opened .eml never registers as an outgoing message), so the note tells the operator to Cmd-S; the save's subject-exact match against ALL open compose windows is the oracle's verbatim selector (same-subject window race inherited, disclosed). Retention: default-path .eml files (0600, in a 0700 lstat-validated dir) are DELIBERATELY never reaped — they are operator-facing drafts, oracle-identical — and `--no-clobber` refuses overwrite (distinct subjects can sanitize to one filename). Raw final-leaf `--out` symlinks are refused before Mail access and rechecked before execute writes; that `safety_violation` / 77 beats `--no-clobber` and generic write failures. Narrow residual: a raw spelling with `..` through a preceding intermediate component that does not exist cannot be inspected through that exact raw spelling and may be standardized by downstream confinement; this shape is operator-controlled and narrow. A residual time-of-check race remains after the final host check and before the filesystem write. Preview honesty: `--account` sender resolution is EXECUTE-only (AccountDirectory drives Mail; a dry-run that launches Mail is not a preview) — `sender_address` stays null in preview, disclosed here. |
| 19 | Move messages | A `move_messages`, B `move_email` | CORE | A: message_ids, dest, account, source, gmail_mode · B: to_mailbox + filters (subject/sender/older_than/only_read), max_moves, dry_run | **Conflict:** A ID-based + gmail_mode; B filter-based + dry_run. Union needs both + dry_run + gmail_mode. PARITY NOTES (Q11b2): ids-path --account scopes per oracle A's narrow loop (out-of-scope skipped + disclosed; --source narrows only when TYPED); --max default 50 = max_moves. DIVERGENCE (extra23, measured 2026-08-17): oracle A's `mailbox X of account` reference resolves TOP-LEVEL ONLY — probed live, it errors -1728 on a bare nested leaf even when exactly one exists. The CLI resolver is a SUPERSET: a unique nested leaf resolves (flat `whose name is` single hit), a multi-hit leaf prefers the top-level match (byte-what the oracle resolves) and otherwise REFUSES with a typed validation error naming the full-path fix (the oracle would have errored -1728 there too); the >1-hit refusal branch has no live probe on this store (no ambiguous leaf exists) — verdict of record at Q17. DIVERGENCE (partial-pair): oracle A raises ValueError when exactly ONE of account/source_mailbox is provided; the CLI's --source defaults to INBOX so the pair rule keys off --account presence — --account alone scopes (account + untyped INBOX default does NOT narrow by mailbox) instead of raising. |
| 20 | Mark read/unread | A `mark_as_read`, B `update_email_status(mark_read/unread)` | CORE | A: message_ids, read, source · B: filters or message_ids, action, max_updates, apply_to_all | **Conflict:** A ID-based; B filter OR ID, with safety caps. PARITY NOTES (Q11b2): filter path seeds the action-INVERSE (oracle B) so --max budgets changes; --max default 10 = max_updates; --only-read is a CLI-extra override — NOTE `--read --only-read` composes to a zero-change target set (mark-read over only-already-read rows) and is honored as typed, not rejected. |
| 21 | Flag messages | A `flag_message(flag_color)`, B `update_email_status(flag/unflag)` | CORE | A: message_ids + 8 colors (none/orange/red/yellow/blue/green/purple/gray) · B: flag/unflag (no color) | **Conflict:** A has color palette; B binary. Union = flag with optional color. PARITY NOTES (Q11b2): same inverse seed + max_updates=10 default as row 20, EXCEPT recolor — an explicit non-none --color seeds NO flagged predicate (recoloring an already-flagged message is a real change; seeding flagged:false would exclude exactly the rows recolor exists to touch). |
| 22 | Delete → Trash | A `delete_messages`, B `manage_trash(move_to_trash)` | CORE | A: message_ids (permanent = **no-op**, always Trash) · B: filters, max_deletes, dry_run, apply_to_all | **Conflict:** A ID-based, always-Trash; B filter-based + dry_run. PARITY NOTES (Q11b2): --max default 5 = max_deletes on the trash path; ids-path scoping as row 19. |
| 23 | Permanent delete + empty trash | B `manage_trash(delete_permanent / empty_trash)` | CORE | confirm_empty, action, max_deletes | **B-only** — A explicitly cannot bypass Trash (issue #111). **PORTED with gates + a documented platform limit — see "Op 23 notes" below.** |
| 24 | List attachments | A `get_attachments(message_id)`, B `list_email_attachments(subject_keyword)` | CORE | A: message_id (+IMAP BODYSTRUCTURE fast path) · B: subject_keyword, max_results | **Conflict:** A by ID, B by subject. DIVERGENCE: `--max-results` maps oracle B's max_results and applies to --subject ONLY — on the id path (oracle A's op, uncapped by design) it is accepted and inert. Rows are emitted in Mail's LIVE order with `save_index` carrying the index-ordered position `attachments save --indices` addresses (the two orders routinely differ — measured 8/8). On the degraded index-fallback path (message not locatable live, a 30-second host deadline expires on either Message-ID spelling, or --no-live) mime_type/size/downloaded keys are ABSENT where oracle A would have errored outright — disclosed via `note`; a timeout aborts the alternate-spelling probe immediately. The `--subject` path applies the per-message bound independently, so its worst-case live cost scales with `--max-results` (up to 60 seconds per match when the first spelling returns not-found and the second stalls). `attachments save` permits this fallback for preview only and refuses execution without Mail's live positional order. |
| 25 | Save attachments | A `save_attachments(message_id, dir, indices)`, B `save_email_attachment(subject_keyword, name, path)` | CORE | A: 0-based indices or all → dir · B: single by name → path | **Conflict:** A index/all; B by-name. Union = both. Destination confinement, unresolved raw-`--out` symlink refusal, and filesystem-shape validation run before Envelope Index or Mail.app access. Immediately before an execute save, both modes verify that the destination parent still resolves to the preflight path and remains a directory, then refuse newly planted leaf symlinks; `--dir` also refuses a regular file that appears after its initial no-clobber check. This narrows symlink reparenting to the interval between the final host check and Mail.app's separate-process save. A same-path rename swap between two real directories is also outside the path-based guard. DIVERGENCE (missing/non-directory `--out` parent): the CLI returns typed `validation_error` / 64 before store access. Oracle B creates no parent and saves no file, but its bare AppleScript `try` suppresses the save failure and misleadingly reports the attachment as not found. No oracle write capability is dropped. |
| 26 | List rules | A `list_rules` | CORE | — (read-only; name+enabled) | **A-only.** |
| 27 | Create rule | A `create_rule` | CORE | name, conditions[] (from/to/subject/body/any_recipient/header_name × contains/…/equals), actions{move/copy/mark_read/mark_flagged+color/delete/forward_to}, match_logic all/any, enabled | Rich rule schema. **A-only.** PARITY NOTES (D6/gap25, 2026-08-19): `delete` (auto-trash) is **LIVE-WIRED** — `--execute` creates a rule that permanently deletes matching mail unattended and forever, matching oracle A. It was previously refused at execute (exit 77); that refusal is now an advisory `warnings` entry on both the preview and the execute envelope, and the sandbox still refuses to wire `delete` and ENABLE a rule in one command (an in-place update does not re-verify existing conditions self-scoped). **DIVERGENCE — `forward_to` is still REFUSED in both modes.** Oracle A supports it end to end (`server.py:405`, `mail_connector.py:505-511`), so this is a deliberate stricter-than-oracle stance, not a porting gap: a forward rule auto-SENDS mail to a third party unattended, which is the one destructive-rule action whose blast radius leaves the operator's own account. It is recorded here because closing gap25 removed its previous tracked home. Live coverage is unit + dry-run only — by the same ruling no agent may live-verify a delete rule, so the first live exercise is the operator's. |
| 28 | Update rule (patch) | A `update_rule` | CORE | rule_index, name/conditions/actions/match_logic/enabled (conditions & actions REPLACE wholesale; elicit; refuses run-AppleScript/redirect/reply/sound/color actions) | **A-only.** DIVERGENCE (gap32, deliberate): update with NO fields is a validation_error/64 where the oracle returns a no-op success — fail-loud kept, bats-locked. Existing-action probe failures map to the TYPED `unsupported_rule_action` (oracle A's error_type), exit 77 unchanged (extra24). |
| 29 | Delete rule | A `delete_rule(rule_index)` | CORE | 1-based index (elicit) | **A-only.** |
| 30 | Enable/disable rule | A `set_rule_enabled(rule_index, enabled)` | CORE | 1-based index | **A-only.** |
| 31 | List templates | A `list_templates` | CORE | — (files at `~/.apple_mail_mcp/templates/<name>.md`) | **A-only.** |
| 32 | Get template | A `get_template(name)` | CORE | name (alnum/_/-, 1–64) | **A-only.** |
| 33 | Save template | A `save_template(name, body, subject)` | CORE | `{placeholder}` tokens in body/subject | **A-only.** |
| 34 | Delete template | A `delete_template(name)` | CORE | name (elicit) | **A-only.** |
| 35 | Render template | A `render_template(name, message_id?, vars?)` | CORE | auto-fills recipient_name/email/original_subject/today from message_id; user vars override | No side effects; feeds send/reply/forward. **A-only.** |
| 36 | Inbox overview | B `get_inbox_overview` | **DERIVED** | — | Unread-by-account + folders + AI action suggestions. **B-only.** |
| 37 | Needs response | B `get_needs_response` | **DERIVED** | account, mailbox, days_back, max_results | Filters newsletters/noreply; ranks `?`/flagged msgs (its docstring claims a direct-To-you boost, but the implementation never inspects recipients — so neither does the CLI: parity, not divergence). **B-only.** PARITY NOTES (Q11b3): automated-sender markers are ORACLE-EXACT — the seven of smart_inbox.py:320 (noreply/no-reply/donotreply/do-not-reply/notifications@/mailer-daemon/postmaster@); the CLI's earlier 17-marker heuristic dropped support@/info@/alerts@ senders the oracle keeps (gap40; updates@/news@ stay dropped via the separate newsletter keyword filter, matching the oracle's newsletter_condition). Sent suppression reads THIS account's Sent mailbox in the oracle's probe priority (Sent Messages → Sent → Sent Items; [Gmail]/Sent Mail as a disclosed 4th probe the oracle lacks — it silently skips suppression on Gmail-backed accounts), newest-200 (gap39/extra29). Selection + ordering are the oracle's (Q11b3 review): newest max_results qualifying candidates, high bucket (question OR flagged — the HIGH*/MEDIUM labels) first in scan order then NORMAL, no urgent-keyword term. DIVERGENCE (disclosed): the body half of the question test reads the indexed `summaries` preview, not a live 500-char content fetch (gap41 — coverage stated at Analytics.hasQuestion). DIVERGENCE (disclosed, strictly better): empty subjects never match the already-replied cross-reference — AppleScript's `contains ""` is TRUE, so one empty Sent subject makes the oracle suppress EVERY candidate. |
| 38 | Awaiting reply | B `get_awaiting_reply` | **DERIVED** | account, days_back, exclude_noreply, max_results | Cross-refs Sent vs Inbox by subject+recipient. **B-only.** PARITY NOTES (Q11b3): exclude_noreply filters RECIPIENTS on exactly the oracle's four patterns (smart_inbox.py:92 — noreply/no-reply/do-not-reply/donotreply), NOT the broader sender-marker list; the reported recipient is the oracle's `name <addr>` display (bare address when Mail recorded no name); Sent mailbox resolved account-scoped in the oracle's probe order, newest-first unbounded read with the max bound applied AFTER filtering (the oracle scans past answered sends). DIVERGENCE (disclosed, TWO-WAY): the oracle keys on the FIRST To recipient only — it skips the send entirely when that one recipient is noreply, and matches replies from that one address alone; the CLI filters and matches across ALL To+CC recipients. So the CLI can SUPPRESS a send the oracle reports (a reply arriving from a CC), and can REPORT a send the oracle skips (first-To noreply with other real recipients remaining) — neither result set contains the other. The reply SUBJECT match is the oracle's bidirectional containment (smart_inbox.py:178; shared helper with needs-response — parity, fixed Q11b3 review). Remaining disclosed divergences: the reply SENDER match is an exact case-insensitive compare on the parsed address where the oracle substring-matches the full sender display (:180) — stricter, superset direction; the CLI requires the reply to be dated AT/AFTER the send where the oracle has no date test (a pre-send "reply" would count for it) — deliberate, strictly better; the received set is windowed to --days (lossless GIVEN the date test: every windowed sent item's replies are inside the window too); empty subjects/addresses never match (AppleScript `contains ""` is true — one empty Sent subject would suppress everything for the oracle); recipient display NAMES come from the index's addresses.comment where the oracle reads them live from Mail — usually identical, not guaranteed for server-side-updated contacts. |
| 39 | Top senders | B `get_top_senders` | **DERIVED** | account, mailbox, days_back, top_n, group_by_domain | Frequency ranking (sender or domain). **B-only.** |
| 40 | Statistics | B `get_statistics` | **DERIVED** | account, scope (account_overview/sender_stats/mailbox_breakdown), sender, mailbox, days_back | Volume / read-ratio / breakdowns. **B-only.** |
| 41 | Inbox dashboard (UI) | B `inbox_dashboard` | **DERIVED** | — (UIResource `ui://apple-mail/inbox-dashboard`; needs mcp-ui-server) | Interactive HTML dashboard. **B-only** (MCP-UI-specific; port as static HTML). The CLI-extra static `--out` path refuses a raw final-leaf symlink before Mail access and rechecks immediately before execute writes; refusal is `safety_violation` / 77, the broader Mail/Contacts path-confinement blocklist is unchanged. Narrow residual: a raw spelling with `..` through a preceding intermediate component that does not exist cannot be inspected through that exact raw spelling and may be standardized by downstream confinement; this shape is operator-controlled and narrow. A residual time-of-check race remains after the final host check and before the filesystem write. |
| 42 | Export emails | B `export_emails` | CORE | account, scope (single_email/entire_mailbox), subject_keyword, mailbox, save_directory, format (txt/html), max_emails | **B-only.** PARITY NOTES (Q11b4, gap45): file layout is the oracle's BY DEFAULT (verified verbatim, analytics.py:500-513/:570-585) — single_email `<dir>/<subject>.<fmt>`, entire_mailbox `<dir>/<mailbox>_export/<n>_<subject>.<fmt>` 1-based, '/'→'-' the only substitution applied to NAMES, same-name OVERWRITE like the oracle's `set eof to 0` (`--no-clobber` refuses instead); `--layout flat` keeps the legacy collision-proof `<id>-<subject:60>` names as a CLI extra. Disclosed deviations: the CLI ALSO deslashes the MAILBOX segment (the oracle interpolates it raw — a nested name would escape its export dir) and re-confines the resolved subdir against a pre-planted symlink; names cap at 150 UTF-8 BYTES (the oracle would error at the filesystem's 255-byte component limit; bytes, not graphemes); an empty subject falls back to `untitled` (the oracle writes a hidden `.txt`); an unknown --mailbox is not_found like the oracle's raise; txt/html bodies carry the CLI's superset header fields; entire_mailbox bodies use the indexed preview (documented) where the oracle reads live content; single_email SELECTION is the index's newest subject match where the oracle takes its live-scan first hit — two runs can overwrite the same subject-named path with different messages (--no-clobber guards); per-message write failures are recorded in `write_failures` and the export CONTINUES like the oracle's per-message try; `--max 0` is the oracle's empty SUCCESS; the `directory` field reports the `<mailbox>_export` dir the files actually land in, matching the oracle's Location report. Q12-A: the single_email full-body fetch is EXECUTE-only (a preview with live-AppleScript side costs is not a preview); the preview's `body_source` is therefore a PREDICTION ("full_body" whenever an RFC id exists) and can differ from execute only when the live fetch fails there and falls back to the indexed preview. |

**Union = 42 capabilities.** CORE = 35, DERIVED = 6, plus the MCP-UI dashboard. **A-only:** #5,6,26–35 (rules, templates, ID-precise get/selected — 12). **B-only:** #7,9,11,13,15,17,18,23,36–42 (HTML/drafts/analytics/export/permanent-delete — 16). **Overlap:** ~14 CORE, of which 6 carry **targeting-model conflicts** (ID vs subject/filter) and 2 carry **feature conflicts** (flag color palette; permanent-delete availability).

### Key overlaps / conflicts to reconcile in the port
- **Targeting model:** A = stable `message_id` (precise, robust); B = `subject_keyword`/sender/date **filters** (convenient, fuzzy). → Port must support **both** (ID-first for safety + `--match` filter convenience; under write-model v2 filter-based mutations execute like any other — the envelope's `filter_based` + `scope_note` disclose the sweep, and `--dry-run`/`APPLE_DRY_RUN=1` preview it).
- **Flag palette:** A = 8 named colors; B = flag/unflag only. → Union = flag `--color` (optional, default red/none) + `--unflag`.
- **Delete depth:** A always-Trash (permanent is a documented no-op); B adds `delete_permanent` + `empty_trash`. → Union includes permanent + empty (from B).

### Op 23 notes — permanent delete + empty trash (ported 2026-07-25)

Both are wired in the CLI (`mail delete --permanent`, `mail trash empty`), with gates sized to
their irreversibility and two deliberate divergences from oracle B, both in the safer direction:

- **Gating (write-model v2, 2026-08-01).** `--permanent` requires the operator-only
  `APPLE_ALLOW_PERMANENT_DELETE` env var (truthy `1`/`true`/`yes`) plus a target-label re-check
  against the CANONICAL `apple-cli-test` prefix (so an `APPLE_TEST_SANDBOX` override cannot widen
  what may be erased) — because a subject label is spoofable and must never be the sole gate on an
  irreversible op. Both gates are UNCONDITIONAL: sandbox state never scopes them, and the v1
  `--test-mode` requirement is gone (the sandbox is now the opt-in restriction, not a write
  prerequisite). `trash empty` cannot be scoped to test data at all, so it requires `--confirm`
  plus the operator-only `APPLE_ALLOW_EMPTY_TRASH` (truthy); it is never run autonomously.
  Both commands keep DRY-RUN as their default (the trash-surface carve-out). `--max` mirrors
  `max_deletes` (default 5).
- **Trash resolution DIVERGES (CLI is correct, oracle is buggy).** Oracle B hardcodes
  `mailbox "Trash" of account X`. On iCloud that is an EMPTY decoy — the real trash is
  "Deleted Messages" — so the oracle silently no-ops there. The CLI enumerates mailboxes, matches
  an exact-name allowlist in Swift, and refuses to guess when more than one trash is non-empty
  (`--trash-mailbox` disambiguates).
- **PLATFORM LIMIT, honestly reported (accepted divergence).** Mail's AppleScript `delete` on a
  message that is ALREADY in trash is a silent NO-OP on IMAP/iCloud accounts — AppleScript cannot
  drive an IMAP expunge. Verified live: the message survives, `deleted status` stays false, the
  trash count is unchanged. Oracle B issues that same `delete` and reports success regardless, so
  it CLAIMS permanent deletes that never happened. The CLI re-queries after the delete and reports
  `applied: []` + `expunge_unsupported: [<ids>]` instead, and `trash empty` returns
  `expunge_unsupported: true` rather than counting phantom erasures. Actually erasing IMAP trash
  requires Mail.app (Mailbox ▸ Erase Deleted Items) or GUI scripting, which is operator-present
  only. **This row is therefore a behavior superset of B (truthful where B is not), not a gap.**
- **Confirmation model:** A wraps send/forward/rule-delete/rule-update in **MCP elicitation** (interactive confirm); B uses `dry_run`/`confirm_empty`/`apply_to_all` **safety caps**. → Port must reproduce BOTH as `--confirm`/`--dry-run` gates.
- **Search flags:** B's search is a superset EXCEPT A's `is_flagged` filter → fold in.

### `SKIP_FOLDERS` scope — where the exclusion applies, and where it must NOT (ported 2026-07-31)

Oracle B declares a `SKIP_FOLDERS` list in `constants.py` (Trash / Junk / Junk Email / Deleted
Items / Sent / Sent Items / Sent Messages / Drafts / Spam / Deleted Messages), but **where it is
applied is per-op, and the list has two independent copies**. Re-verify against BOTH sites:

- `tools/search.py:_search_mail_records` (line 167) **inlines an identical literal** at line 236
  and never imports the constant — and only inside the `if mailbox == "All":` branch.
- `tools/analytics.py:139` is the *only* importer of `SKIP_FOLDERS`, and it interpolates the
  condition into just two of the three `get_statistics` scopes (see the table).
- `core.py:228 skip_folders_condition()` looks like the shared helper but has **zero callers** —
  dead code. Pinning a parity check to it, or to `constants.py` alone, will mislead.

Which surfaces filter is therefore a per-op fact to be copied, not a global policy to be
generalized, and getting it wrong is a correctness loss in both directions:

| Surface | Excludes `SKIP_FOLDERS`? | Why |
|---|---|---|
| `search --mailbox All` | **Yes**, by default (`--include-system-folders` opts back in) | Oracle-B parity (search.py:236, All-branch only). An `All` sweep that returned Trash/Junk/Sent hits was returning results the oracle never would. |
| `search --mailbox <named>` | No | The exclusion redefines what `All` MEANS; naming a system mailbox explicitly must still search it. |
| `analytics stats --scope account_overview` | **Yes**, by default | Oracle applies it at analytics.py:170. Verified live over a 7-day window: CLI over-counted before, matches the oracle exactly after. |
| `analytics stats --scope sender_stats` | **Yes**, by default | Oracle applies the skip at analytics.py:314 and IGNORES `mailbox` for this scope, sweeping `every mailbox of targetAccount` (analytics.py:303). **Fixed 2026-08-02** — the CLI previously scoped it to `--mailbox` (default `INBOX`) and reported INBOX-only numbers as account-wide. See the scope table below. |
| `analytics stats --scope mailbox_breakdown` | **No** (matches the oracle) | analytics.py:351-385 applies NO skip and targets ONE named mailbox (`mailbox_param = escaped_mailbox if mailbox else "INBOX"`). **Fixed 2026-08-02** — the CLI previously forced `All` and filtered anyway, discarding `--mailbox` and making per-mailbox stats for a system folder unreachable. A named mailbox is now never skip-filtered, so a Trash breakdown returns Trash. |
| `analytics top-senders` / `needs-response` / `awaiting-reply` / `overview` | **No** | No oracle counterpart applies the skip, and the CLI applies none either. |

**Resolved 2026-08-02 — the exclusion is now `All`-scoped.** `search` had always nested the check
inside `if wantAll` (EnvelopeIndex.swift:122-123) so that naming a system mailbox explicitly still
searched it; `analytics stats` filtered unconditionally, so `--scope sender_stats --mailbox Drafts`
returned `total=0` while `search --mailbox Drafts` returned 16 — two read surfaces answering the
same question differently. The exclusion is now keyed on the resolved scan scope
(`Analytics.scopePlan`), via `EnvelopeIndex.isAllWildcard` rather than a re-tested string literal,
so `all`/`All`/`ALL` behave identically. All three analytics defects in this section are closed.

| `thread` | **No — deliberately** | `get_email_thread` lives in the SAME module as the filtered path — `tools/search.py:595` (there is no `tools/thread.py`) — and builds its own mailbox script with no skip. Excluding drops the operator's own `Sent` replies out of their own conversation: measured 34 → 24 messages, all 6 `Sent Messages` hits lost. Copying the filter here is a regression wearing parity's clothes. |
| `move` / `mark` / `flag` / `delete` (bulk `All`) | **No — deliberately** | A mutation's `All` must stay wide: `delete --permanent` only ever targets messages already in Trash, so a narrowed scope would make it a permanent no-op. |

**Leaf-name matching is a SUPERSET, not alignment.** Oracle B's `All` branch enumerates only
top-level mailboxes (`every mailbox of targetAccount`, search.py:232) and compares with exact
equality (`if mailboxName is skipFolder`), where `mailboxName` is the leaf (`name of
currentMailbox`) — confirmed live, the oracle reports `Important` / `All Mail` / `INBOX`, never
`[Gmail]/All Mail`. It therefore never reaches Gmail's nested `[Gmail]/*` at all. The CLI reads
the flat Envelope Index, so it both reaches those mailboxes AND excludes the system ones among
them by leaf name (`[Gmail]/Trash`, `[Gmail]/Spam`). Wider coverage plus consistent exclusion —
an extra, and recorded as such.

The `thread` and bulk rows mean **reads and mutations disagree about what `All` means**. That
divergence is intentional but not self-evident, so both sides disclose it in the machine contract
rather than in prose the caller may never read: `search` emits `system_folders_excluded`
(`true`/`false` on an `All` sweep, absent for a named mailbox), `analytics stats` emits the same
key (always present — its exclusion is not All-scoped), and a bulk envelope emits `scope_note`
when the scope is `All` **or a system mailbox** — the latter because Drafts holds UNSENT composes,
so moving one out of Drafts removes it from Mail's compose surface. `scope_note` is emitted only
on the FILTER-BASED path; an explicit-ids mutation never consults the mailbox, so claiming a sweep
scope there would contradict `filter_based: false` in the same envelope.

Locked by `bats/mail.bats` ("discloses system_folders_excluded on an All sweep only",
"thread does NOT exclude system folders", "bulk previews disclose the All-scope divergence").

---

## 2. CLI capability manifest per candidate

### fruitmail-cli (gumadeiras) — **read-only, SQLite Envelope Index**
- **Provenance:** 18★, MIT, TypeScript (40%), latest **v1.2.0 (May 2026)**, brew tap `gumadeiras/tap` + npm + curl. Actively maintained, small.
- **Mechanism:** reads `~/Library/Mail/V{9,10,11}/MailData/Envelope Index` (SQLite) read-only (`--copy` safe mode). Body retrieval via AppleScript. ~50 ms/query on 130k mails vs 8+ min AppleScript.
- **Surface:** `search [--subject --days --unread --limit --offset --json]` · `sender <query>` · `unread` · `body <id> [--json]` · `open <id>` · `stats`.
- **Coverage:** search (subject/days/unread/sender) + body read + open + DB stats. **No writes at all** — cannot send/reply/forward/move/flag/mark/delete/create-mailbox/attachments/rules/templates/drafts/analytics/export.

### mail-app-cli (intelligrit) — **Go + AppleScript/JXA**
- **Provenance:** 10★, MIT, Go (99.9%), **no releases published**, no version tags. Intelligrit Labs. JSON-everywhere, jq-friendly, single binary.
- **Mechanism:** Go wrapping AppleScript + JXA against Mail.app.
- **Surface:** `accounts {list,show}` · `mailboxes list [--account]` · `messages {list [--account --mailbox --unread --flagged --since --limit], show, mark [--read], flag [--flagged], archive, move, delete}` · `send [--account --to --subject --body --cc]` · `search [--limit]` · `attachments {list, save [-o]}`.
- **Coverage:** accounts, mailboxes(list only), message list/show/mark/flag(binary)/archive/move/delete(→Trash), send(plain, no bcc/attach/HTML), attachments list+save. **Missing:** reply, forward, drafts, rules, templates, analytics, export, create-mailbox, HTML/attachment/mode send, get-selected, thread, unread-counts, permanent-delete. `search` has **no filter flags** beyond `--limit` (weak).

### email-cli (joshuaswanson) — **Python + AppleScript**
- **Provenance:** **0★**, Python (100%), **no releases**, license unspecified, Python 3.11+. Newest/least-proven; single-author, unproven.
- **Mechanism:** generates AppleScript → `osascript` → Python parses; body search batched + Python-filtered.
- **Surface:** `list [-a -n -f -A -u --json]` · `search [-s --sender --after --before -b -u -a -A --json]` · `read <idx|id> [--format plain|html|links --max-length]` · `open` · `open-link` · `delete [--ids --stdin --confirm]` · `move [-t --ids --stdin --confirm]` · `send [-a --to -s -b --confirm]` · `reply <id> [-b --all --confirm]` · `folder {create,delete} [--confirm]` · `account {init,list}` · `refresh`.
- **Coverage:** good **search filters** (subject/sender/date-range/body/read), read incl. HTML + link-extraction, list, send(plain), **reply**(plain), move, delete(→Trash, bulk `--ids/--stdin`), folder create/delete. **Missing:** forward, flag, mark read/unread, attachments, drafts, rules, templates, analytics, export, get-selected, thread, unread-counts, HTML/attachment send, permanent-delete.

---

## 3. CAPABILITY MATRIX (union row × CLI column)

`EXACT` = full parity · `PARTIAL(gap)` = present but narrower · `MISSING` = absent.

| # | Union capability | fruitmail | mail-app-cli | email-cli |
|---|---|---|---|---|
| 1 | List accounts | MISSING | EXACT | PARTIAL (config-file `account list`, not live Mail) |
| 2 | List mailboxes | MISSING | PARTIAL (list only, no counts) | PARTIAL (`folder`, no counts) |
| 3 | Create mailbox (nested) | MISSING | MISSING | PARTIAL (`folder create`; nesting unclear) |
| 4 | Search messages | PARTIAL (subj/days/unread/sender; no body/date-range/flag/attach/sort) | PARTIAL (`--limit` only — no filters) | PARTIAL (subj/sender/date/body/read; no flag/attach/pagination) |
| 5 | Get message by ID | PARTIAL (`body` = body only) | EXACT (`messages show`) | EXACT (`read` by idx/id) |
| 6 | Get selected (Mail UI) | MISSING | MISSING | MISSING |
| 7 | List recent inbox | PARTIAL (`unread`/`search`) | PARTIAL (`messages list`) | EXACT (`list`) |
| 8 | Get thread | MISSING | MISSING | MISSING |
| 9 | Unread counts | PARTIAL (`unread` list, no counts) | MISSING | MISSING |
| 10 | Send (plain) | MISSING | PARTIAL (no bcc) | PARTIAL (no cc/bcc) |
| 11 | Send — HTML | MISSING | MISSING | MISSING |
| 12 | Send — attachments | MISSING | MISSING | MISSING |
| 13 | Send — mode (draft/open) | MISSING | MISSING | MISSING |
| 14 | Reply (plain/all) | MISSING | MISSING | EXACT (`reply --all`) |
| 15 | Reply — HTML/attach/mode | MISSING | MISSING | MISSING |
| 16 | Forward | MISSING | MISSING | MISSING |
| 17 | Drafts management | MISSING | MISSING | MISSING |
| 18 | Rich `.eml` draft | MISSING | MISSING | MISSING |
| 19 | Move messages | MISSING | EXACT (ID; +archive) | PARTIAL (ID/bulk; no filter/dry-run) |
| 20 | Mark read/unread | MISSING | EXACT (`messages mark`) | MISSING |
| 21 | Flag (with color) | MISSING | PARTIAL (binary, no color) | MISSING |
| 22 | Delete → Trash | MISSING | EXACT (ID) | PARTIAL (ID/bulk `--confirm`) |
| 23 | Permanent delete + empty trash | MISSING | MISSING | MISSING |
| 24 | List attachments | MISSING | EXACT | MISSING |
| 25 | Save attachments | MISSING | PARTIAL (`-o`; no index/name select) | MISSING |
| 26 | List rules | MISSING | MISSING | MISSING |
| 27 | Create rule | MISSING | MISSING | MISSING |
| 28 | Update rule | MISSING | MISSING | MISSING |
| 29 | Delete rule | MISSING | MISSING | MISSING |
| 30 | Enable/disable rule | MISSING | MISSING | MISSING |
| 31 | List templates | MISSING | MISSING | MISSING |
| 32 | Get template | MISSING | MISSING | MISSING |
| 33 | Save template | MISSING | MISSING | MISSING |
| 34 | Delete template | MISSING | MISSING | MISSING |
| 35 | Render template | MISSING | MISSING | MISSING |
| 36 | Inbox overview (DERIVED) | MISSING | MISSING | MISSING |
| 37 | Needs response (DERIVED) | MISSING | MISSING | MISSING |
| 38 | Awaiting reply (DERIVED) | MISSING | MISSING | MISSING |
| 39 | Top senders (DERIVED) | MISSING | MISSING | MISSING |
| 40 | Statistics (DERIVED) | MISSING | MISSING | MISSING |
| 41 | Inbox dashboard (UI) | MISSING | MISSING | MISSING |
| 42 | Export emails | MISSING | MISSING | MISSING |

**Coverage tally (of 42):** fruitmail ~1 EXACT / 5 PARTIAL / 36 MISSING · mail-app-cli 6 EXACT / 6 PARTIAL / 30 MISSING · email-cli 2 EXACT / 8 PARTIAL / 32 MISSING. **Even the union of all three CLIs** leaves rules (26–30), templates (31–35), drafts (17–18), analytics (36–41), export (42), HTML/mode send (11,13,15), get-selected (6), thread (8), and permanent-delete (23) **entirely uncovered.**

---

## 4. VERDICT — **BUILD** (decisive)

No single CLI is a strict superset of the union — not close. The **strongest candidate, mail-app-cli, covers 6/42 EXACT** and is missing the two entire pillars that make these MCPs valuable (**rules**, **templates**) plus **all analytics, drafts, export, HTML send, and thread**. The strict 100%-coverage rule disqualifies every candidate on the first missing capability; each misses **~30 of 42**. Adopting any of them — or all three stitched together — cannot reach parity. **Build our own, folding in the CLIs' genuinely useful extras.**

---

## 5. EXTRAS INVENTORY (CLI features beyond the MCP union — fold into the build)

- **fruitmail — Envelope-Index SQLite read path** (⭐ the big one): ~50 ms vs 8+ min AppleScript on 130k mails. Makes search/list AND the analytics (#36–41, all frequency/count math) fast and Mail.app-independent. `--copy` safe-read mode; `V{9,10,11}` path auto-detection; `--offset` pagination; `stats` DB diagnostics.
- **mail-app-cli — JSON-first, jq-friendly output** on every command; `messages list --since` relative-date filter; `archive` one-shot shortcut; single-static-binary distribution model (Go) if perf demands.
- **email-cli — `read --format links` link extraction + `open-link`** (open a message's Nth link in the browser); **batched body search**; `--ids` / `--stdin` **pipeline bulk ops** (compose search → pipe → move/delete); `folder delete`; `refresh` (trigger a mail-check across accounts); index-based addressing for quick interactive use.
- **Cross-cutting:** all three prove `--json` + preview/`--confirm` gating are the right CLI ergonomics — align with MCP A's elicitation and MCP B's dry-run into one `--dry-run`/`--confirm`/`--json` convention.

---

## 6. PORT SPEC (BUILD)

**Working name:** `applemail` (binary `applemail`). **Distribution:** brew tap + the fleet's `mcp-servers.yaml`→CLI registrar; SemVer, GitHub-published, owned longevity.

### Fork-base + language + mechanism
- **Language: Python 3.11+ (uv/uvx managed)** — matches BOTH MCPs' language, the fleet's Python tooling, and the lowest-friction AppleScript-via-`osascript` bridge.
- **Fork/vendor base (greenfield shell, two vendored engines):**
  1. **Vendor MCP A's domain layer** (`s-morgan-jeffries/apple-mail-mcp`, Python) for the **hard write/manage/rules/templates/thread/attachment** logic — it already solves the Mail-rule AppleScript dictionary, the update-rule unsupported-action refusal, template render, IMAP BODYSTRUCTURE fast path, and elicitation-confirm. Wrapping its functions in a `click` CLI is the cheapest route to rules+templates+ID-precise parity. **Prereq: confirm MCP A's license permits vendoring** (README calls it AppleScript-bridge; verify LICENSE before lifting code — else reimplement its AppleScript templates clean-room).
  2. **Reimplement fruitmail's Envelope-Index SQLite reader** (fruitmail is TS → port the SQL to Python `sqlite3`) for the **fast read/search/list + analytics hot path**.
  3. **Port MCP B's analytics + HTML/`.eml` + filter-bulk logic** (Python → direct reuse) for #11–18, #23, #36–42.
- **Mechanism split:**
  - **Read/search/list/analytics** → Envelope-Index SQLite (read-only copy-to-temp), no Mail.app scripting on the hot path.
  - **Send/reply/forward/move/flag/mark/delete/mailbox/drafts/rules/templates/attachments** → AppleScript via `osascript` (Mail.app running required).
  - **HTML send** → generate multipart `.eml` + open in Mail (MCP B's proven workaround for AppleScript storing literal markup).
  - **Dashboard** → emit a **static HTML file** (drop the mcp-ui-server dependency).

### Command surface (union parity + curated extras)
```
applemail accounts list [--json]
applemail mailboxes list [--account] [--counts] [--json]
applemail mailboxes create --account --name [--parent]
applemail search [--account] [--mailbox] [--subject] [--sender] [--body]
                 [--from-date --to-date] [--read/--unread] [--flagged]
                 [--has-attachment] [--limit --offset --sort] [--json] [--copy]   # SQLite; is_flagged folded in
applemail get <message-id> [--headers-only] [--no-content] [--json]
applemail selected [--no-content] [--json]                                        # Mail UI selection (A #6)
applemail list [--account] [--unread] [--limit] [--content] [--json]              # recent inbox (B #7)
applemail thread (<message-id> | --subject KW) [--json]                           # both targeting models (#8)
applemail unread-counts [--account] [--summary] [--include-zero] [--json]         # (B #9)

applemail send --to --subject --body [--cc --bcc --attach... --html --mode send|draft|open] [--confirm]
applemail reply <message-id> --body [--all --cc --bcc --attach --html --mode] [--confirm]
applemail forward <message-id> --to [--cc --bcc --body] [--confirm]
applemail draft {list|create|send|open|delete} [--account --subject --to --body --cc --bcc --match]
applemail draft-rich --account [--subject --to --text --html --out --open/--save]  # .eml path (B #18)

applemail move (<ids...> | --match <filters>) --to <mailbox> [--gmail-mode --dry-run --confirm]
applemail mark (<ids...> | --match) (--read|--unread) [--max --dry-run --confirm]
applemail flag (<ids...> | --match) (--color <c>|--unflag) [--max --dry-run --confirm]
applemail delete (<ids...> | --match) [--permanent --dry-run --confirm]            # Trash default; permanent from B
applemail trash empty --account [--confirm]                                        # (B #23)

applemail attachments list (<message-id> | --subject KW) [--json]
applemail attachments save <message-id> --dir [--indices i,j | --name NAME]        # both selection models (#25)

applemail rules list [--json]
applemail rules create --name --condition F:OP:V ... --action K=V ... [--match all|any --disabled]
applemail rules update <index> [--name --condition... --action... --match --enabled/--disabled] [--confirm]
applemail rules delete <index> [--confirm]
applemail rules (enable|disable) <index>

applemail templates list [--json]
applemail templates get <name>
applemail templates save <name> --body [--subject]
applemail templates delete <name> [--confirm]
applemail templates render <name> [--message-id] [--var k=v ...]

applemail analytics overview [--json]                                             # inbox_overview (DERIVED #36)
applemail analytics needs-response [--account --mailbox --days --max] [--json]     # (#37)
applemail analytics awaiting-reply [--account --days --max --exclude-noreply] [--json]  # (#38)
applemail analytics top-senders [--account --mailbox --days --top-n --by-domain] [--json]  # (#39)
applemail analytics stats [--account --scope --sender --mailbox --days] [--json]  # (#40)
applemail analytics dashboard [--out inbox.html]                                  # static HTML (#41)

applemail export --account --scope single|mailbox [--subject --mailbox --dir --format txt|html --max]  # (#42)

# curated extras
applemail read <id> --format links   ·   applemail open-link <id> <n>             # email-cli link extraction
applemail open <message-id>          ·   applemail refresh                        # open in Mail / trigger mail-check
applemail doctor                                                                  # fruitmail-style DB/path diagnostics
# global: --json everywhere; --dry-run/--confirm gates mirror MCP-A elicitation + MCP-B safety caps
```

### Sent-mailbox sourcing for `needs-response` / `awaiting-reply` (corrected 2026-08-02)

Both commands cross-reference the account's Sent mailbox. The oracle resolves it
`of targetAccount` with an explicit fallback order and then walks Mail's enumeration newest-first,
bounding by count (`smart_inbox.py:274-283` for the fallback; `:286-297` and `:146-149` for the
bounds).

| aspect | oracle | CLI |
|---|---|---|
| mailbox choice | `Sent Messages` → `Sent` → `Sent Items`, of the target account | same order, plus `Sent Mail` appended as a CLI EXTRA (Gmail-only name the oracle cannot resolve, so it skips suppression there entirely) |
| order | Mail enumeration, measured newest-first | `ORDER BY COALESCE(NULLIF(date_sent,0), date_received) DESC, ROWID DESC` |
| bound | `needs-response` 200 sent subjects; `awaiting-reply` stops at `max_results` RESULTS | `.newest(200)`; `.newestFirst` unbounded then `prefix(max)` after filtering |

Live verification showed ROWID-first selection choosing a lower-priority candidate, so both
analytics commands used the wrong Sent source. Ordering was a second, masked defect:
unordered-first-200 of `sentRows` covers a much wider window than the correct newest-200.

**Known gap (Q4e):** `hasQuestion` cannot see message bodies. `analyticsRows` does not join
`summaries`, so `Row.snippet` is always nil and the check degrades to subject-only, where the oracle
scans the first 500 chars of content. `"MEDIUM (contains question)"` therefore never fires on a
body-only question.

### `analytics stats` scope semantics (corrected 2026-08-02)

Oracle B's `get_statistics` scans differently per scope, on three independent axes. Getting one
scope right proves nothing about the others.

| scope | mailboxes scanned | SKIP_FOLDERS | days_back |
|---|---|---|---|
| `account_overview` (analytics.py:142) | all of the account; `mailbox` arg ignored | excluded (:170) | applied |
| `sender_stats` (:283) | all of the account; `mailbox` arg ignored | excluded (:314) | applied |
| `mailbox_breakdown` (:351) | the ONE named mailbox, default `INBOX` (falls back to `Inbox`) | **not** applied | **ignored** |

CLI extras on top: `--mailbox All` fans a breakdown across every mailbox (no oracle counterpart),
and `--include-system-folders` opts back into the excluded folders. The exclusion is keyed on the
resolved scan scope, not on the scope name, so a mailbox the caller NAMES is never filtered away —
a Trash breakdown must return Trash. Responses report `days_back` as actually applied (0 for
`mailbox_breakdown`), not as requested.

### Oracle safety limits (ported 2026-08-02)

The two Mail oracles DISAGREE here, and the CLI replaces both — so each limit is scoped to the
oracle that owns the operation. Oracle A (s-morgan-jeffries@0.6.0) has all three limits below;
oracle B (patrickfreyer@3.1.3) has **none** (grep for
`max_recipients|rate_limit|TIER_LIMITS|max_items` = 0 hits). See `HUMAN-DECISIONS.md` D8 for the
conflict rule this adopts and its open consequences.

| Limit | Oracle A source | Applies to | Deliberately NOT applied to |
|---|---|---|---|
| Send rate limit 3/60s | `TIER_LIMITS["sends"]`, `OPERATION_TIERS` | `send`, `forward`, `draft send` | `reply` (its own `expensive_ops` tier — next row) |
| Reply rate limit 20/60s | `TIER_LIMITS["expensive_ops"]` | `reply` (D8, 2026-08-18) | the other `expensive_ops` members (`search`, `mark`, `delete`, rule ops) — tier scoped to `reply` per D8; throttling scripted reads/bulk ops would drop capability + break the bats suite |
| 100 recipients (`to+cc+bcc`) | `validate_send_operation`, server.py:898 / :1085 | `send`, `draft send` (D8, 2026-08-18) | `reply`, `forward`, `draft-rich` — A validates no recipients on those, B caps nothing |
| 100 items, by input id count | `validate_bulk_operation` (server.py:995); inline (server.py:1719) | `mark`, `delete` | `move`, `flag` — uncapped in A |

Two behaviors that are easy to get wrong and are pinned by test:

- **The refusal text differs per op.** `mark_as_read` returns `validate_bulk_operation`'s
  "Too many items (N), maximum is M"; `delete_messages` returns "Cannot delete N messages at once
  (max: 100)". MCP-diff parity compares the payload, so these are not unified.
- **The bulk cap runs BEFORE `MailContext()`**, matching the oracle's validate-before-Mail order.
  Placed after, it is unreachable on a machine with no configured Mail account (`EnvelopeIndex`
  throws exit 69 first) — i.e. unreachable in CI.

Divergence from A, stated: the window persists to `~/.apple-cli/send-rate-limit.json`
(`APPLE_SEND_RATELIMIT_STATE` overrides) and uses wall clock, because A's in-memory
`time.monotonic()` deque cannot survive a fresh process per invocation. Fails open, warns on stderr.

### Build cost: **L–XL**
Hard parts, roughly descending:
- **Mail rules AppleScript** (create/update/delete/enable + the update-rule *unsupported-action refusal*, condition/action schema, 1-based index model) — Mail's rule dictionary is finicky and partly UI-scripted. **Highest risk;** vendor MCP A to de-risk. (M–L)
- **Analytics / needs-response & awaiting-reply heuristics** — newsletter/noreply filtering, `?`-and-direct-To ranking, and the Sent↔Inbox cross-reference for awaiting-reply; must reproduce MCP B's judgment. Fast if computed over the SQLite index. (M)
- **Dual targeting model** (ID-precise [A] + subject/sender/date `--match` filters [B]) across move/mark/flag/delete/attachments/thread — filter-based bulk envelopes carry `filter_based` + `scope_note` (the v1 mandatory dry-run was lifted by write-model v2). (M)
- **HTML send via `.eml`** (multipart generation + Mail open/save) and **drafts** (list/create/send/open/delete). (M)
- **Attachment handling** — IMAP BODYSTRUCTURE fast path + AppleScript fallback; save-by-index vs save-by-name. (M)
- **Envelope-Index SQLite** — `V{9,10,11}` path + schema drift, copy-to-temp safe read, keeping search/analytics correct as the schema evolves. (M)
- **AppleScript fragility (ongoing)** — Mail.app must be running; UI-scripting for send/confirm; Gmail label-move (`gmail_mode` copy+delete); permanent-delete-is-no-op nuance; macOS Automation permission grants. Perennial maintenance tax. (M, continuous)

XL only if all of rules + templates + analytics + HTML + dual-targeting are taken to *full* parity in one release; a phased path (P1 CORE read/send/manage from SQLite+AppleScript → P2 rules+templates → P3 analytics+export+dashboard) lands as **L**.

---

## 7. Sources

- MCP A tools/params — live `mcp__apple-mail__*` schema introspection (27 tools) + README @ v0.6.0: https://github.com/s-morgan-jeffries/apple-mail-mcp (raw `v0.6.0/README.md`). Behavior notes reference issues #72/#73 (IMAP fast path), #111 (permanent-delete no-op).
- MCP B tools/params — live `mcp__apple-mail-pf__*` schema introspection (24 tools) + README @ v3.1.3: https://github.com/patrickfreyer/apple-mail-mcp (raw `v3.1.3/README.md`).
- fruitmail-cli — https://github.com/gumadeiras/fruitmail-cli (18★, MIT, TS, v1.2.0, May 2026; brew tap + npm). Skill mirror: https://github.com/openclaw/skills (`gumadeiras/apple-mail-search-safe`).
- mail-app-cli — https://github.com/intelligrit/mail-app-cli (10★, MIT, Go, no releases) + review: https://robertmelton.com/posts/mail-app-cli-automation/
- email-cli — https://github.com/joshuaswanson/email-cli (0★, Python, no releases, license unspecified).
- Envelope Index background — `~/Library/Mail/V{9,10,11}/MailData/Envelope Index` (SQLite).

## 8. Validation evidence (live write surfaces)

Value-free record of the operator-present live validations that discharged Mail's
"wired, not live-validated" asterisks (details: `HUMAN-DECISIONS.md` D3/D14 and the
Asana tasks cited there).

- `send --gui-send` — **live-validated 2026-08-27** (D3, Asana `GID-REDACTED`): one
  self-addressed HTML send executed via GUI keystroke automation with the sandbox engaged;
  delivery oracle-verified on both the sent and inbox sides (same internet message id);
  test items cleaned by exact id. Two earlier failed attempts (exit 70; exit 69
  upstream_error) preceded the `dd83be1` window-binding fix.
- `rules delete` — **first live exercise 2026-08-27** (D14, Asana `GID-REDACTED`):
  an agent-created, DISABLED, uniquely-tokened `apple-cli-test` rule was deleted by index
  operator-present; the envelope's fail-loud readback matched the rule name verbatim and
  the pre-existing real rules were untouched.
- `send --group` equivalent for Mail does not exist; the Messages-domain D4 asterisk lives
  in `messages.md` §"send_message --group".
