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
| 2 | List mailboxes | A `list_mailboxes(account)`, B `list_mailboxes(account?,include_counts)` | CORE | account, include_counts | A requires account; B optional (all-accounts) + counts + path form. **B superset.** |
| 3 | Create mailbox (nested) | A `create_mailbox`, B `create_mailbox` | CORE | account, name, parent_mailbox | Both support nesting; B also accepts full slash-path in `name`. **Overlap.** |
| 4 | Search messages | A `search_messages`, B `search_emails` | CORE | subj, sender, body, date_from/to, read, flagged, has_attach, limit/offset, sort, mailbox, account | **Conflict:** A requires `account`, INBOX default, adds `is_flagged` filter, no body/pagination. B optional account (all), body_text search, offset/limit pagination, sort, `mailbox="All"`, JSON. **B near-superset EXCEPT A's `is_flagged` search filter.** |
| 5 | Get message by ID | A `get_message(message_id, …)` | CORE | message_id, include_content, headers_only, account/mailbox (IMAP fast path) | Full structured detail by stable ID. **A-only (ID-precise).** |
| 6 | Get selected (Mail UI) | A `get_selected_messages(include_content)` | CORE | include_content | Reads whatever msgs the user highlighted in Mail. **A-only.** |
| 7 | List recent inbox | B `list_inbox_emails` | CORE | account?, max_emails, include_read, include_content, output_format | Recent list, read filter, content preview, JSON. **B-only (A does this via search).** |
| 8 | Get thread | A `get_thread(message_id)`, B `get_email_thread(subject_keyword)` | CORE | A: message_id (RFC5322 In-Reply-To/References) · B: subject_keyword, mailbox, max | **Conflict:** A header-precise by ID; B fuzzy by subject. Union should offer both. |
| 9 | Unread counts | B `get_mailbox_unread_counts` | CORE | account?, include_zero, summary_only | Per-mailbox or per-account inbox totals. **B-only.** |
| 10 | Send email (plain) | A `send_email`, B `compose_email` | CORE | to, subject, body, cc, bcc | A elicitation-confirm; B comma-str recipients. **Overlap.** |
| 11 | Send — HTML body | B `compose_email(body_html)` | CORE | body_html + plain fallback | **B-only.** |
| 12 | Send — attachments | A `send_email_with_attachments`, B `compose_email(attachments)` | CORE | attachments[] | A separate tool; B folds into compose. **Overlap.** |
| 13 | Send — mode (send/draft/open) | B `compose_email(mode)` | CORE | mode = send\|draft\|open | Open compose window for review, or save draft silently. **B-only.** |
| 14 | Reply (plain, reply-all) | A `reply_to_message`, B `reply_to_email` | CORE | A: message_id, body, reply_all · B: subject_keyword, reply_body, reply_to_all | **Conflict:** A by ID, B by subject-keyword. |
| 15 | Reply — HTML + attach + mode | B `reply_to_email(body_html, attachments, mode, cc, bcc)` | CORE | body_html, attachments, mode, cc/bcc | **B-only (richer reply).** |
| 16 | Forward | A `forward_message`, B `forward_email` | CORE | A: message_id, to, cc, bcc, body-prefix (elicit) · B: subject_keyword, to, message, cc, bcc | **Conflict:** A by ID, B by subject. |
| 17 | Drafts management | B `manage_drafts` | CORE | action = list\|create\|send\|open\|delete; subject/to/body/cc/bcc/draft_subject | Full draft CRUD. **B-only.** |
| 18 | Rich `.eml` draft | B `create_rich_email_draft` | CORE | account, subject, to, text_body, html_body, cc, bcc, output_path, open_in_mail, save_as_draft | Generates multipart `.eml`, opens in Mail (reliable HTML rendering). **B-only.** |
| 19 | Move messages | A `move_messages`, B `move_email` | CORE | A: message_ids, dest, account, source, gmail_mode · B: to_mailbox + filters (subject/sender/older_than/only_read), max_moves, dry_run | **Conflict:** A ID-based + gmail_mode; B filter-based + dry_run. Union needs both + dry_run + gmail_mode. |
| 20 | Mark read/unread | A `mark_as_read`, B `update_email_status(mark_read/unread)` | CORE | A: message_ids, read, source · B: filters or message_ids, action, max_updates, apply_to_all | **Conflict:** A ID-based; B filter OR ID, with safety caps. |
| 21 | Flag messages | A `flag_message(flag_color)`, B `update_email_status(flag/unflag)` | CORE | A: message_ids + 8 colors (none/orange/red/yellow/blue/green/purple/gray) · B: flag/unflag (no color) | **Conflict:** A has color palette; B binary. Union = flag with optional color. |
| 22 | Delete → Trash | A `delete_messages`, B `manage_trash(move_to_trash)` | CORE | A: message_ids (permanent = **no-op**, always Trash) · B: filters, max_deletes, dry_run, apply_to_all | **Conflict:** A ID-based, always-Trash; B filter-based + dry_run. |
| 23 | Permanent delete + empty trash | B `manage_trash(delete_permanent / empty_trash)` | CORE | confirm_empty, action, max_deletes | **B-only** — A explicitly cannot bypass Trash (issue #111). **PORTED with gates + a documented platform limit — see "Op 23 notes" below.** |
| 24 | List attachments | A `get_attachments(message_id)`, B `list_email_attachments(subject_keyword)` | CORE | A: message_id (+IMAP BODYSTRUCTURE fast path) · B: subject_keyword, max_results | **Conflict:** A by ID, B by subject. |
| 25 | Save attachments | A `save_attachments(message_id, dir, indices)`, B `save_email_attachment(subject_keyword, name, path)` | CORE | A: 0-based indices or all → dir · B: single by name → path | **Conflict:** A index/all; B by-name. Union = both. |
| 26 | List rules | A `list_rules` | CORE | — (read-only; name+enabled) | **A-only.** |
| 27 | Create rule | A `create_rule` | CORE | name, conditions[] (from/to/subject/body/any_recipient/header_name × contains/…/equals), actions{move/copy/mark_read/mark_flagged+color/delete/forward_to}, match_logic all/any, enabled | Rich rule schema. **A-only.** |
| 28 | Update rule (patch) | A `update_rule` | CORE | rule_index, name/conditions/actions/match_logic/enabled (conditions & actions REPLACE wholesale; elicit; refuses run-AppleScript/redirect/reply/sound/color actions) | **A-only.** |
| 29 | Delete rule | A `delete_rule(rule_index)` | CORE | 1-based index (elicit) | **A-only.** |
| 30 | Enable/disable rule | A `set_rule_enabled(rule_index, enabled)` | CORE | 1-based index | **A-only.** |
| 31 | List templates | A `list_templates` | CORE | — (files at `~/.apple_mail_mcp/templates/<name>.md`) | **A-only.** |
| 32 | Get template | A `get_template(name)` | CORE | name (alnum/_/-, 1–64) | **A-only.** |
| 33 | Save template | A `save_template(name, body, subject)` | CORE | `{placeholder}` tokens in body/subject | **A-only.** |
| 34 | Delete template | A `delete_template(name)` | CORE | name (elicit) | **A-only.** |
| 35 | Render template | A `render_template(name, message_id?, vars?)` | CORE | auto-fills recipient_name/email/original_subject/today from message_id; user vars override | No side effects; feeds send/reply/forward. **A-only.** |
| 36 | Inbox overview | B `get_inbox_overview` | **DERIVED** | — | Unread-by-account + folders + AI action suggestions. **B-only.** |
| 37 | Needs response | B `get_needs_response` | **DERIVED** | account, mailbox, days_back, max_results | Filters newsletters/noreply; ranks direct-To-you + `?` msgs. **B-only.** |
| 38 | Awaiting reply | B `get_awaiting_reply` | **DERIVED** | account, days_back, exclude_noreply, max_results | Cross-refs Sent vs Inbox by subject+recipient. **B-only.** |
| 39 | Top senders | B `get_top_senders` | **DERIVED** | account, mailbox, days_back, top_n, group_by_domain | Frequency ranking (sender or domain). **B-only.** |
| 40 | Statistics | B `get_statistics` | **DERIVED** | account, scope (account_overview/sender_stats/mailbox_breakdown), sender, mailbox, days_back | Volume / read-ratio / breakdowns. **B-only.** |
| 41 | Inbox dashboard (UI) | B `inbox_dashboard` | **DERIVED** | — (UIResource `ui://apple-mail/inbox-dashboard`; needs mcp-ui-server) | Interactive HTML dashboard. **B-only** (MCP-UI-specific; port as static HTML). |
| 42 | Export emails | B `export_emails` | CORE | account, scope (single_email/entire_mailbox), subject_keyword, mailbox, save_directory, format (txt/html), max_emails | **B-only.** |

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
| `analytics stats --scope account_overview` | **Yes**, by default | Oracle applies it at analytics.py:170. Verified live: 7-day window: over-counted before, exact match after. |
| `analytics stats --scope sender_stats` | **Yes**, by default — but see the `--mailbox` defect | Oracle applies the skip at analytics.py:314. **Oracle IGNORES `mailbox` for this scope** — it sweeps `every mailbox of targetAccount` (analytics.py:303) and `escaped_mailbox` is referenced at only two places in the whole file (128 assignment, 352 `mailbox_breakdown`). The CLI instead scopes to `--mailbox` (default `INBOX`), so it reports INBOX-only sender stats where the oracle reports account-wide — a **known defect / parity DROP**, tracked with the `mailbox_breakdown` fix. |
| `analytics stats --scope mailbox_breakdown` | **Oracle: NO.** CLI currently: yes — **known defect** | analytics.py:351-385 applies NO skip and targets ONE named mailbox (`mailbox_param = escaped_mailbox if mailbox else "INBOX"`). The CLI forces `mbx = "All"` for this scope and filters anyway, so `--mailbox` is silently discarded and per-mailbox stats for a system folder are unreachable by any flag combination. That is a DROPPED oracle capability. Tracked for its own fix; do not read this row as parity. |
| `analytics top-senders` / `needs-response` / `awaiting-reply` / `overview` | **No** | No oracle counterpart applies the skip, and the CLI applies none either. |

**Third known analytics defect — the exclusion is NOT `All`-scoped there.** `search` nests the
check inside `if wantAll` (EnvelopeIndex.swift:122-123), so naming a system mailbox explicitly
still searches it. `AnalyticsCommands.swift:92-97` has no `isAllWildcard` guard and filters by
leaf name unconditionally on `!includeSystemFolders`. Measured live on iCloud:
`analytics stats --scope sender_stats --mailbox Drafts` → `total=0` and `--mailbox Trash` → `0`,
while `search --mailbox Drafts` → 16. So per-mailbox analytics for ANY system folder is
unreachable without `--include-system-folders`, and the two read surfaces answer the same
question differently. Grouped with the other two analytics defects for a single fix.
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
