# apple-messages (iMessage/SMS) — MCP→CLI porting analysis

**Domain:** iMessage / SMS
**MCP under test:** `mac_messages_mcp` — github.com/carterlasalle/mac_messages_mcp @ `99388d252459745fb6779557149ad43be89dfc6e` (v0.7.x line; merge of PR #45, dated 2026-05-04)
**Mechanism:** reads `~/Library/Messages/chat.db` (SQLite) for reads + `~/Library/Application Support/AddressBook/**/AddressBook-v22.abcddb` (SQLite) for contacts; drives Messages.app via `osascript` (AppleScript) for sends.
**Primary candidate CLI:** `imsg` (Peter Steinberger / steipete) — **canonical repo `github.com/openclaw/imsg` @ v0.13.0**.
**Verdict (TL;DR):** **BUILD-OUR-OWN, forking `imsg` as the base.** No single CLI is a strict superset — `imsg` misses/parts several MCP cells (standalone fuzzy contact search + scores, contact enumeration, fuzzy message search w/ threshold+time-window, cross-chat "recent", DB/AddressBook diagnostics). But `imsg` is an outstanding fork base and feature-donor (same author, MIT, Swift, chat.db+AppleScript already built, JSON/JSON-RPC first-class, actively maintained).

---

## 0. Provenance resolution (flagged discrepancy — RESOLVED)

Prior research cited both `github.com/openclaw/imsg` and `brew install steipete/tap/imsg`. **These are the same tool; not a conflict, not a hijack.**

- `curl -sI https://github.com/steipete/imsg` → **`HTTP/2 301 → https://github.com/openclaw/imsg`**. The `steipete/imsg` path is a GitHub rename/transfer redirect. `gh api repos/steipete/imsg` and `gh api repos/openclaw/imsg` return **byte-identical metadata** (`full_name: openclaw/imsg`, created 2025-12-05, 1236★, MIT, homepage imsg.sh, `fork:false`, `parent:null`, `source:null`).
- The repo was authored by steipete and **transferred into his own `openclaw` org**. The "claw" naming theme is steipete's own micro-tool ecosystem — his Homebrew tap `steipete/homebrew-tap` ships `imsg.rb` alongside `clawdex.rb`, `birdclaw.rb`, `peekaboo.rb`, `poltergeist.rb`, `oracle.rb`, etc. `imsg.rb` → `homepage github.com/openclaw/imsg`, `url .../openclaw/imsg/releases/download/v0.13.0/imsg-macos.zip`, `license MIT`, `depends_on macos: :sonoma`.
- **`openclaw` is NOT a suspicious third party here.** It is steipete's personal org. Provenance is clean and consistent across GitHub API, redirect, homepage, and the Homebrew formula. (The recurrence of "openclaw" across this project's other tools is the same author's ecosystem, not a shared-attacker signal — worth confirming per-domain, but for apple-messages it checks out.)
- `github.com/R80R/imsg` ("Fork of steipete/imsg with reply context resolution", 0★, last push 2026-02-07) is a stale third-party fork — **not** a preferred base over upstream.

**Maintenance/trust signal (strong):** 1236★, `pushed 2026-07-11` (v0.13.0 released 4 days before this analysis; v0.13.1 already in-progress), multiple external contributors in the changelog (@omarshahine, @chiedo), MIT, structured docs site (imsg.sh), test suite, CI. Actively and healthily maintained.

---

## 1. MCP capability manifest (`mac_messages_mcp`, from pinned source)

9 tools + 2 resources. All outputs are **human-formatted strings** (no structured JSON) — a key weakness the CLI port should fix.

| Tool | Class | Key params | Behavior / output notes |
|---|---|---|---|
| `tool_get_recent_messages` | **CORE** | `hours:int=24`, `contact:str=None` | Reads `message` table, `CAST(date AS TEXT) > <apple-ns-epoch>`, `ORDER BY date DESC LIMIT 100`, **across ALL chats**. `contact` optional: fuzzy name→handle, or phone/email, or stateful `"contact:N"` selection. Extracts body from `text` **or** `attributedBody` (hand-rolled NSArchiver typedstream parser). Resolves sender name via AddressBook; annotates group-chat name. Output: lines `[YYYY-MM-DD HH:MM:SS] [group?] <You\|Name>: <body>`. |
| `tool_send_message` | **CORE** | `recipient:str`, `message:str`, `group_chat:bool=False` | `recipient`= phone \| email \| contact-name (fuzzy) \| `"contact:N"` \| group chat id. iMessage-first with **automatic SMS/RCS fallback** for phone numbers. Group send via `chat id "<guid>"`. File-based AppleScript send (writes msg to tempfile, `read POSIX file … as «class utf8»`) with a direct-AppleScript fallback path. Output: success/error string incl. service used. |
| `tool_find_contact` | **DERIVED** | `name:str` | Fuzzy match over AddressBook (full name **+ nickname**), token-based scoring (exact token 0.95, prefix 0.85/0.80, `difflib.SequenceMatcher` fallback), dedup by phone. Output: ranked list `N. <name> (<phone>) - confidence <score>`, top 10. **Returns candidates WITH confidence scores.** |
| `tool_get_chats` | **CORE** (narrow) | — | `SELECT chat_identifier, display_name FROM chat WHERE display_name IS NOT NULL` → **only NAMED group chats**. Output: `N. <display_name> (ID: <chat_identifier>)`. Used to obtain group chat ids for `group_chat=True` sends. |
| `tool_fuzzy_search_messages` | **CORE** | `search_term:str`, `hours:int=720`, `threshold:float=0.6` | SQL `LIKE` pre-filter + Python two-pass: exact substring → score 1.0, else `thefuzz.WRatio ≥ threshold*100`. `hours=0`=all time; soft cap 10 000. Output: `Found N…` + `[date] (Score: x.xx) [group?] <dir>: <body>`, score-sorted. **True similarity + tunable threshold + time window.** |
| `tool_check_imessage_availability` | **DERIVED** | `recipient:str` | History-based (NOT live IDS): groups `handle`×`message`, returns True iff a handle with `service∈{iMessage,iMessageLite}` and `errors < text_count`. Output: `✅ … iMessage` / `📱 … fall back to SMS/RCS` / `❌ … email`. |
| `tool_check_db_access` | **DIAGNOSTIC** | — | Verifies `chat.db` exists/readable/connectable + `message`/`handle` tables present. Output: multi-line status (or FDA-grant instructions). |
| `tool_check_contacts` | **DIAGNOSTIC**/DERIVED | — | Enumerates cached AddressBook contacts: count + first 10 `number -> name`. |
| `tool_check_addressbook` | **DIAGNOSTIC** | — | Verifies AddressBook `*.abcddb` access + `ZABCDRECORD`/`ZABCDPHONENUMBER` tables + contact count. |
| `messages://recent/{hours}` (resource) | CORE | `hours` | = `get_recent_messages(hours)`. |
| `messages://contact/{contact}/{hours}` (resource) | CORE | `contact`,`hours` | = `get_recent_messages(hours, contact)`. |

Notable MCP behaviors the port must respect for parity: (a) **stateful `"contact:N"` disambiguation** via in-process globals — an anti-pattern for a stateless CLI; the port should instead return ranked candidates as JSON and accept an explicit handle. (b) contact source is the **AddressBook `.abcddb` SQLite** (needs only Full Disk Access, no Contacts TCC prompt). (c) all outputs are unstructured strings.

---

## 2. CLI capability manifests

### 2a. `imsg` — openclaw/imsg v0.13.0 (PRIMARY)

- **Language/mechanism:** Swift (SwiftPM). Reusable core `Sources/IMsgCore` (`MessageStore`, `ContactResolver`), CLI `Sources/imsg`, injected helper `Sources/IMsgHelper`. Reads `chat.db` **read-only, WAL-aware** (deliberately not `immutable=1`); sends via **public AppleScript** Messages automation. Contacts via **`Contacts.framework` (CNContactStore)** — *different from the MCP's abcddb SQLite read*.
- **Install:** `brew install steipete/tap/imsg` (formula → openclaw releases) or `make build`. Requires **macOS 14+ (Sonoma)**, Full Disk Access, Automation (for send/react), optional Contacts permission, optional `ffmpeg`.
- **JSON:** `--json` on every read/list/watch command emits **JSONL** (one object/line; `jq -s` to arrayify). Rich, documented, stable schemas. Human progress→stderr, data→stdout.
- **No-SIP command surface** (Full Disk Access + Automation only):
  - `imsg chats [--limit 20] [--json]` — lists **ALL** chats (`store.listChats(limit,unreadOnly)`), JSON incl. `id,name,identifier,guid,service,last_message_at,display_name,contact_name,is_group,participants,account_*`.
  - `imsg group --chat-id <id> [--json]`
  - `imsg history --chat-id <id> [--limit 50] [--attachments] [--convert-attachments] [--participants <handles>] [--start <iso>] [--end <iso>] [--json]` — **`--chat-id` REQUIRED** (`HistoryCommand.swift:47` `throw missingOption("chat-id")`).
  - `imsg watch [--chat-id <id>] [--since-rowid <id>] [--debounce <dur>] [--attachments] [--convert-attachments] [--reactions] [--participants] [--start/--end] [--json]` — live stream (fs events + poll).
  - `imsg search --query <text> [--match contains|exact] [--limit 50] [--json]` — **substring or exact only** (`MessageStore+Search.swift`: `exact = match=="exact"`, else SQL `LIKE`). **No fuzzy score, no threshold, no time window.**
  - `imsg stats [--chat-id <id>] [--time-zone <IANA>] [--media] [--json]`
  - `imsg scheduled list [--limit] [--json]` — Send-Later rows (no bridge).
  - `imsg chat-background status --chat-id <id> [--json]`
  - `imsg send (--to <handle|contact-name> | --chat-id <id> | --chat-identifier <id> | --chat-guid <guid>) [--text <t>] [--file <path>] [--service imessage|sms|auto] [--no-sms-fallback] [--region US] [--json]` — iMessage/SMS auto-route + **explicit override** + **file attachments** + group-by-guid. Contact-name→handle resolution is **substring** (`ContactResolver.swift:89` `.contains`); on **multiple matches it ERRORS** ("Specify a phone number or email instead", `ChatTargetResolver.swift:129`) — no ranked-candidate output.
  - `imsg react --chat-id <id> --reaction love|like|dislike|laugh|emphasis|question` — standard tapbacks.
  - `imsg rpc` — **JSON-RPC 2.0 over stdio** (`chats.list, messages.history, messages.stats, messages.scheduled, watch.subscribe/unsubscribe, message.send_status, send, poll.send, handles.check`).
  - `imsg completions bash|zsh|fish|llm`.
- **SIP-disabled IMCore bridge** (requires `imsg launch` w/ SIP off + dylib injection — **out of scope for a SIP-on fleet**): `read` (read receipts), `typing`, `status`, `send-rich`/`send-multipart`/`send-attachment`/`send-sticker`/`tapback`, `edit`/`unsend`/`delete-message`/`notify-anyways`, `chat-create/name/photo/add-member/remove-member/leave/delete/mark`, `account`, **`whois --address <a> --type phone|email [--local]`**, `nickname`, `name-photo status|share`, poll `send|vote`.
  - **`whois`**: default path is bridge (SIP-off) live availability (`action:.checkImessageAvailability`, returns `available`+`id_status`). **BUT `--local` runs `store.preferredService(forHandle:)` against chat.db with NO bridge/SIP** → `service imessage|sms|unknown`, `source=local`. This local path is the no-SIP analogue of the MCP availability check.
- **Contact search in core lib (unexposed as CLI):** `ContactResolving.searchByName(query)->[ContactMatch]` exists but is **substring-only** and only wired into send-disambiguation; there is **no `imsg contacts`/`find-contact` command** and no confidence-scored ranking.

### 2b. `danewalton/imessage-cli` (Go) — secondary

- Commands: `list/read/send/chat/search/tui/status` (`-n` count, `-y` skip-confirm). chat.db reads + AppleScript send.
- **No JSON output, no group-chat support, no advanced filtering** (per README). Cobra + go-sqlite3 + tview TUI.
- **Provenance/maintenance:** author danewalton, MIT, **1★, 0 releases, ~19 commits, dormant.** Interactive TUI chat mode is its only distinctive extra (irrelevant for headless agents).
- **Assessment: DISQUALIFIED** as a drop-in (no JSON, no groups, dormant). Not a viable base.

### 2c. `ReagentX/imessage-exporter` (Rust) — read-side donor only

- Purpose-built **read/export/diagnostics**: exports chat.db → txt/html, attachments, group chats, **edited-message + 30-day deleted-message recovery**, and an **iMessage Diagnostics** mode. Ships the well-regarded `imessage-database` crate (the most battle-tested chat.db/typedstream parser in the ecosystem). Homebrew + prebuilt binaries; actively maintained.
- **No send, no react, no watch-stream, no live availability** → **cannot cover `tool_send_message` (CORE)**. **DISQUALIFIED** as a drop-in.
- **Value:** best-in-class read-robustness reference/donor (attributedBody/typedstream parsing, edited/deleted handling) and a proven diagnostics model.

---

## 3. Capability matrix (row = MCP capability; cell = EXACT / PARTIAL(gap) / MISSING)

| # | MCP capability (class) | `imsg` v0.13.0 | `imessage-cli` (Go) | `imessage-exporter` |
|---|---|---|---|---|
| C1 | Send msg; resolve phone/email/**contact-name**; **iMessage→SMS auto-fallback** (CORE) | **EXACT+** superset: +`--file`, +`--service`, +`--no-sms-fallback`, +`--chat-guid/identifier`, +`--region` | PARTIAL (sends; no fallback control; substring name only) | **MISSING** |
| C2 | Send to **group chat by chat id** (CORE) | **EXACT+** (`--chat-id/--chat-guid/--chat-identifier`) | MISSING | MISSING |
| C3 | **Recent messages, last N hours, ALL chats** (no contact) (CORE) | **MISSING** — `history` requires `--chat-id`; `watch` is live-only; no cross-chat merged historical fetch | PARTIAL (`list`/`read` per-conversation) | PARTIAL (bulk export, not "last N h" ergonomic) |
| C4 | Recent messages **filtered by contact name** (CORE) | **PARTIAL** — must resolve contact→chat manually; `history` keyed by chat rowid; `--participants` filters *within* a chat only | PARTIAL (`read <number>`) | PARTIAL |
| C5 | Message search — **fuzzy similarity + threshold + time-window** (CORE) | **PARTIAL** — `--match contains\|exact` only; **no fuzzy, no `--threshold`, no time window** | PARTIAL (`search`, contains, no fuzzy/window) | MISSING (search via export only) |
| C6 | Message search — substring/exact | EXACT (`search --match contains\|exact`) | EXACT | PARTIAL |
| C7 | **Fuzzy contact search → ranked candidates + confidence scores** (standalone) (DERIVED) | **MISSING** as a CLI command — core `searchByName` is unexposed **substring** (no scores); send **errors** on ambiguity | MISSING | MISSING |
| C8 | **iMessage availability check**, no-SIP, history-based (DERIVED) | **PARTIAL** — `whois --local` (chat.db, no SIP) gives `imessage/sms/unknown`; different output semantics; live path needs SIP-off bridge | MISSING | PARTIAL (diagnostics, not per-recipient) |
| C9 | **List (named group) chats** (CORE) | **EXACT+** — `chats` lists ALL chats + rich JSON (superset) | PARTIAL (list, no JSON) | PARTIAL (export lists chats) |
| C10 | **Enumerate AddressBook contacts** (DIAGNOSTIC) | **MISSING** — no contacts-list command | MISSING | MISSING |
| C11 | **Diagnose Messages DB access** (DIAGNOSTIC) | **PARTIAL** — inline errors + troubleshooting docs; no explicit no-SIP command (`imsg status` is bridge/SIP) | PARTIAL (`status`) | EXACT-ish (iMessage Diagnostics) |
| C12 | **Diagnose AddressBook/Contacts access** (DIAGNOSTIC) | **MISSING** — no command | MISSING | MISSING |

---

## 4. VERDICT

**BUILD-OUR-OWN (fork `imsg`).** One MISSING cell disqualifies a strict drop-in; `imsg` has several: **C3, C7, C10, C12 MISSING** and **C4, C5, C8, C11 PARTIAL**. So `imsg ⊉ mac_messages_mcp` — it is **not** a strict superset, despite dominating on send/read-richness/JSON.

- No candidate is a strict superset. `imessage-cli` (Go) and `imessage-exporter` (Rust) are further away (the latter can't send at all).
- **`imsg` is the correct fork base / engine.** It already implements the two CORE hard parts (WAL-aware chat.db reads + AppleScript send with iMessage/SMS routing), is JSON/JSON-RPC-first (context-frugal — the whole point of the port), MIT, same-author-maintained, and its `IMsgCore` (`MessageStore`, `ContactResolver`, `searchByName`) gives us 80% of the missing pieces to *wire up* rather than build.
- The missing cells are **small, additive** commands over an existing engine — not a reason to go greenfield.

---

## 5. EXTRAS INVENTORY (capabilities beyond the MCP)

**WORTH-INCLUDING (harvest into our port):**
- **JSONL output on every read command** + **stderr/stdout split** (imsg) — the core reason to port off MCP; keep as default `--json`.
- **JSON-RPC 2.0 stdio server** `imsg rpc` (imsg) — single long-running process for agents; effectively an MCP replacement transport we own.
- **Live stream** `imsg watch` (fs-events + poll, WAL-aware) (imsg) — MCP has no streaming; high value.
- **Structured message schema** (imsg): `reply_to_guid/text/sender`, `thread_originator_guid`, `url_preview`, `reactions`, per-chat **unread counts** + **read timestamps** — far richer than MCP's flat strings.
- **Chat identity on message reads** (CLI-only JSON extra, this port): `chat_identifier`,
  `chat_guid` and `is_group` on every `recent`/`search` message, so a caller can tell an unnamed
  group from a 1:1 conversation and has an id to reply to. The MCP exposed only `group_name`, a
  display name, which is absent for both.
- **`--direct-only` on `recent`/`search`** (CLI-only, this port): exclude group-chat messages,
  applied in SQL ahead of `--limit`, with `direct_only` / `direct_only_applied` reporting what was
  requested and what actually ran.
- **Chat activity + participants on `chats`** (CLI-only JSON extra, this port): `last_activity`,
  `last_activity_timestamp` and `participants`, so a caller can pick a chat without a second
  command. **Deviates in `--text`** — see the `get_chats` row in §8.
- **`chats --name` / `chats --limit`** (CLI-only, this port): case-insensitive substring filter on
  the display name (echoed as `name_filter`) and a result cap. Neither changes the default
  listing or its order.
- **Attachment metadata** (implemented as a CLI-only JSON extra) + optional
  **CAF→M4A / GIF→PNG** conversion (imsg) — model-consumable media.
- **Explicit service control** `--service imessage|sms|auto` + `--no-sms-fallback` (imsg) — MCP's routing is implicit/uncontrollable. **BUILT** as `apple messages send --service auto|imessage|sms` (see §8 "Send service control and attachments"). `--no-sms-fallback` was NOT ported as a separate flag: it is `--service imessage`, and two spellings of one routing decision is a second place to declare it.
- **`send --file`** attachments (imsg) — MCP is text-only. **BUILT** as a repeatable `apple messages send --file <path>` (see §8).
- **`stats`** (tz-aware message statistics) + **`scheduled list`** (Send-Later, no bridge) (imsg) — both no-SIP, useful, cheap to keep.
- **Standard tapbacks** `react` (imsg) — no-SIP, useful.
- **`completions llm`** (imsg) — in-context CLI help for agents.
- **Read-robustness patterns** from `imessage-exporter`: edited-message + deleted-message (30-day) recovery, hardened typedstream parsing — adopt as correctness reference for our reader.

**NOISE / out-of-scope (keep optional or drop):**
- **All SIP-disabled IMCore bridge features** (imsg): `edit/unsend/delete`, `typing`, read receipts, `send-rich/-multipart/-sticker`, chat management, polls, `name-photo`. Powerful but require **disabling SIP + dylib injection into Messages.app** — a security posture the fleet should not adopt by default. Keep documented/optional behind an explicit opt-in; not part of the parity floor.
- **Linux read-only preview** (imsg) — fleet is macOS; irrelevant.
- **`chat-background status`** (imsg) — niche.
- **Interactive TUI chat mode** (imessage-cli Go) — irrelevant for headless agents.
- **Full txt/html export** (imessage-exporter) — not an MCP capability; not a CLI-tool concern.

---

## 6. PORT SPEC (BUILD)

**Base:** **Fork `openclaw/imsg`** (MIT, Swift, macOS 14+). Reuse `IMsgCore` (`MessageStore`, `ContactResolver`, WAL-aware reader, AppleScript send). Keep imsg's entire existing surface (it's a strict *plus* over the MCP for send/read/JSON) and **add the parity layer** below.

**Language/mechanism:** Swift; **chat.db read-only (WAL-aware) for reads + AppleScript (Messages.app) for sends** — identical to the MCP's mechanism, already in the base. Contacts: keep `Contacts.framework`, but see the hard part on the data-source/permission difference vs the MCP's abcddb read.

**Target command surface = MCP parity floor + curated extras:**
1. `imsg recent [--hours N=24] [--contact <name|handle>] [--limit 100] [--json]` — **fills C3/C4.** Cross-chat, time-ranged, reverse-chron merge; `--contact` resolves name→handles→messages across chats. (New; composes `MessageStore` queries the base already has per-chat.)
2. `imsg contacts find <name> [--json]` + `imsg contacts list [--json]` — **fills C7/C10.** Expose `searchByName` as a command **and upgrade its matcher** from substring to the MCP's token-based fuzzy scoring (exact 0.95 / prefix 0.85·0.80 / sequence-ratio fallback) **emitting confidence scores + nickname matching**.
3. `imsg search … --match fuzzy --threshold <0-1> [--hours N | --start/--end]` — **fills C5.** Add a fuzzy mode (WRatio-equivalent) + threshold + time-window to the existing `search`.
4. `imsg doctor [--json]` — **fills C11/C12.** No-SIP chat.db + Contacts/AddressBook access + required-tables diagnostic (model on imessage-exporter's diagnostics + the MCP's `check_*`).
5. Keep `imsg whois --local` for **C8** (already ~covers it); optionally add a `--fallback-hint` output to match the MCP's ✅/📱/❌ semantic exactly.
6. Retain all curated extras from §5 (JSONL, `rpc`, `watch`, `stats`, `scheduled`, `react`, attachments, service control).

**Replace the MCP's stateful `"contact:N"`** disambiguation with stateless JSON candidate lists (from cmd 2) + explicit handle selection — better fit for CLI/agents.

**Publish/version:** SemVer, GitHub releases + our own Homebrew tap; register the one CLI for all three agents (Claude/Codex/agy) via the fleet's existing `mcp-servers.yaml`→registrar path (or a skills-canonical entry) — zero per-CLI MCP registration, the parity goal.

**Build-cost estimate: M (Medium).** The engine (the two genuinely-hard parts — WAL-aware chat.db reads and AppleScript send with iMessage/SMS routing) already exists in the fork base; we add ~4 commands + a fuzzy matcher + a diagnostic. **Hard parts:**
- (a) **Porting the MCP's fuzzy semantics to Swift** — no `thefuzz`/`difflib`; a WRatio/token-ratio-equivalent must be written or vendored. Byte-for-byte score parity with the MCP is unlikely, so define parity as "behavioral" not "identical scores."
- (b) **Cross-chat `recent` merge + contact→handles→chats resolution** (C3/C4) — the base is chat-rowid-centric; this is new query/merge logic.
- (c) **Contact data-source decision** — imsg uses `Contacts.framework` (needs Contacts TCC) vs the MCP's direct `abcddb` SQLite (needs only Full Disk Access, no prompt); pick one and document the permission-model change (recommend Contacts.framework + fuzzy scoring; note the extra TCC prompt).
- (d) **Swift toolchain + universal build + tap packaging + SemVer release plumbing** (the program's build/publish/version requirement) — mechanical but real.

Greenfield (non-fork) would be **L** (reimplement the whole engine); forking `imsg` is the clear win → **M**.

---

## 7. Sources

- MCP (pinned): https://github.com/carterlasalle/mac_messages_mcp/tree/99388d252459745fb6779557149ad43be89dfc6e — `mac_messages_mcp/server.py`, `mac_messages_mcp/messages.py`, `README.md` (read locally at the pinned commit).
- imsg canonical: https://github.com/openclaw/imsg (v0.13.0; `README.md`, `CHANGELOG.md`, `Sources/imsg/Commands/*`, `Sources/IMsgCore/ContactResolver.swift`, `Sources/IMsgCore/MessageStore+Search.swift`, `Sources/imsg/Commands/HistoryCommand.swift`, `BridgeIntroCommands.swift` — read locally at `HEAD b5b7464`).
- imsg redirect proof: `HTTP/2 301 https://github.com/steipete/imsg → https://github.com/openclaw/imsg`; `gh api repos/{steipete,openclaw}/imsg` (identical `full_name: openclaw/imsg`, 1236★, pushed 2026-07-11).
- imsg Homebrew formula: https://github.com/steipete/homebrew-tap `Formula/imsg.rb` (homepage+url → openclaw/imsg v0.13.0, MIT, macOS Sonoma).
- imsg docs: https://imsg.sh/ (quickstart, json, rpc).
- Secondary: https://github.com/danewalton/imessage-cli (Go; 1★, dormant, no JSON/groups).
- Read-side donor: https://github.com/ReagentX/imessage-exporter (Rust; read/export/diagnostics only, no send) + crate https://crates.io/crates/imessage-exporter.
- Third-party fork (not used): https://github.com/R80R/imsg (0★, stale).

---

## 8. Parity verification (live oracle diffs) — as-built

The `apple messages` CLI was diffed against the live `mac_messages_mcp` MCP (the
oracle) on this fleet. Read ops compared freely; no write/send was diffed. The
send row below records a validation-evidence limitation, not a live diff result.

**Every count below is a POINT-IN-TIME measurement from the verification run — the
live store drifts continuously.** Re-measured twice on 2026-08-18 the per-source
counts had already moved (and moved AGAIN between two runs minutes apart), while
the STABLE invariants held both times: the contacts-with-handles total and the presence of
the top-level `AddressBook-v22.abcddb` source. Specific per-source
figures are deliberately NOT re-embedded here — they are stale on arrival. The
parity claim each row records is "CLI == oracle ON THE SAME RUN", not that any
absolute number still holds; a future re-audit must diff both sides fresh, never
against a historical value (Q12 [1]).

| Tool | Result |
|---|---|
| `check_db_access` | 134 tables, message/handle/chat present — match (CLI superset adds `message_count`, `path`, `readable`). |
| `check_contacts` | **CLI count == oracle count on the verification run**. Sample ordering aligned to the oracle's `ORDER BY ZLASTNAME, ZFIRSTNAME`. |
| `check_addressbook` | Per-source counts matched CLI==oracle on the verification run, source-for-source and in total (see the point-in-time note above). CLI also reports the top-level `AddressBook-v22.abcddb` the MCP's *diagnostic* omits (its contact loader reads it) — superset, not a drop. |
| `find_contact` | A common first name → **count 30 == 30**, all 0.95 (exact-token) — scores byte-exact. |
| `check_imessage_availability` | 2125550142 → `available=true`, recommendation string **byte-identical**. |
| `get_chats` | **CLI == oracle** on named-chat count (superset fields: guid, room_name, service_name, group_id, style; later also last_activity, last_activity_timestamp, participants). **`--text` deviates deliberately, as it does for `get_recent_messages`:** each listed chat now carries an appended `— last activity …; participants: …` when the store has those facts for it. The default listing (no `--name`, no `--limit`) still returns the same named chats in the same order, and the JSON key set and its ordering are unchanged. |
| `send_message --group` | Validation-evidence asterisk: the `--group` path accepts the oracle group-chat identifier and dispatches via chat id, but it has never been exercised against a live group. No live group was created or messaged, and no live group send is authorized. The same asterisk now covers `--group --file`: the group script builds the identical attachment loop, so every participant would receive each file, and that path has never been run against a live group either — it is pinned at the command layer and compile-checked, nothing more. This limits validation evidence; it does not mark the capability missing. |
| `get_recent_messages` | hours=6 cross-chat: every MCP output line reproduced **byte-verbatim** (attributedBody-decoded bodies, group names, sender resolution, timestamps). **This claim is bounded to the pre-attachment build and is deliberately no longer true of `--text`** — see "Attachment metadata" below for the two intentional deviations (an appended `[N attachments: …]` suffix, and a row set that now includes attachment-only messages the oracle drops). The JSON body/group/sender/timestamp shaping the claim was really about is unchanged. |
| `fuzzy_search_messages` | See the WRatio boundary note below. |

### Send service control and attachments

Two CLI-only extras on the send path, both listed as WORTH-INCLUDING in §5. Neither
narrows the parity floor: the defaults are the ported `tool_send_message` behaviour
exactly, so a caller that passes neither flag gets what the oracle gave.

**`--service auto|imessage|sms`** (default `auto`). `auto` is the ported
`_send_message_direct` routing verbatim — iMessage first, then the enabled SMS account,
and only when the recipient contains a digit (the oracle refuses to fall back for an
email address, and so does this). `imessage` and `sms` are single-service: the send is
attempted on that service alone and a failure is a failure, which is the point of asking
for one. The flag governs 1:1 sends. It is **accepted and inert on `--group`** — a chat
id already names the chat's own service and Messages offers no choice — and is echoed
back as `service_requested` so a caller can see it was ignored rather than honoured.

**`--file <path>`, repeatable.** The body (when there is one) is sent first, then each
attachment in the order given, **in one `osascript` run**: splitting them across runs
would mean a second Messages automation prompt mid-batch, and a partial batch no single
result line could describe. `--message` is therefore optional, and a send with neither a
body nor a file is a `validation_error`. Paths reach osascript as **argv**, never
interpolated into the script source — the same contract the recipient and body already
had; only the SHAPE of a send (has a body, which service) varies the emitted source, and
that shape comes from the CLI's own flags. `--file` works with `--group`, and every
participant in the chat then receives each file.

**Attachment containment is the SHARED `AppleKit.AttachmentSource.resolve`**, promoted
out of `MailKit` when this flag landed rather than reimplemented (AGENTS.md: shared
helpers live in `AppleKit`). The first draft of `--file` checked existence and
readability only, which under write-model v2 — where an unsandboxed send reaches any
recipient — meant `messages send <number> --file ~/.ssh/id_ed25519` was accepted and
delivered unrecallably from one command line, while Mail's sibling surface had refused
exactly that for months.

The guard, in order: control characters (C0/DEL) → `safety_violation`; symlinks resolved,
then must be an existing regular file → `not_found`; over 25 MB → `validation_error`;
executable/script extension → `validation_error`; under a credential/config directory →
`safety_violation`, tested against BOTH the resolved path (defeats a symlink INTO one)
and the tilde-expanded literal (defeats a credential directory that is itself a symlink).
`--dry-run` refuses identically to execute.

**The two policy questions this raised, decided rather than left silent.** The
executable-extension blocklist and the 25 MB cap are ADOPTED for Messages, not just
inherited by accident. Neither narrows parity — `mac_messages_mcp` is text-only and
cannot send a file at all, so no refusal here drops an oracle capability — and the
alternative was a second, laxer content policy on the repo's other outbound surface,
which is the divergence the promotion exists to end. The cap also bounds a send's
duration, which matters while the osascript run behind it still has no host deadline.
The Notes D12 carve-out does not apply: that one exists because the Notes oracle PERMITS
the write in question.

**Paths are symlink-RESOLVED, and that is what is reported.** `files` and
`error.applied` carry the resolved location, not the operator's spelling, because that is
the file actually being sent; the check has to run on the resolved path anyway. The
argument is never trimmed — `report ` (one trailing space) is a legal macOS filename, and
trimming would silently substitute a neighbouring `report` that also exists.

**What the guard does NOT stop, stated so nobody reads it as more than it is.** It is a
PATH check. A HARD LINK to a credential file is a second name for the same inode with no
trace of the first, so the denylist cannot see it — an operator who can hard-link a file
can equally `cp` it, which this never claimed to stop either. And the check is not atomic
with the send: `POSIX file` follows the path again inside Messages, so a path that passed
here can be replaced in the window before delivery (TOCTOU). Both are inherited from the
Mail resolver and are NOT widened by this change; closing either needs an
open-then-send-the-descriptor design that the AppleScript route cannot express.

**`--service sms` to a digit-less recipient is refused up front** (`validation_error`,
exit 64) using the oracle's own phone-shaped test — the same test that stops the `auto`
fallback trying SMS for an email address. `auto` and `imessage` reach email addresses
normally; only the arm that is knowably impossible is pre-validated.

**A multi-part send is not atomic**, and the CLI says so rather than pretending
otherwise. Body and attachments are separate transfers, so a failure WITH AN
ATTACHMENT IN FLIGHT is an `upstream_error` naming which attachment failed, how many
preceded it, and — in `error.applied`, the field a partial bulk Mail mutation already
uses — the exact paths already delivered, which a retry must exclude. A failure with no
attachment in flight (the body went out, then the SMS account lookup failed) carries the
generic message and the body note only, because there is no attachment to name. `filesSent` counts attachments only, so
the result grammar carries a separate **body-delivered** bit and the error says
explicitly when the body has to be omitted from a retry; without it a caller following
the advice re-sent the body to a real person. The same fact bounds the `auto` fallback:
it may only re-run a batch of which NOTHING was delivered, or the recipient would receive
the delivered part twice.

**`schema_version` stays 1, and the two changes that resemble contract breaks are stated
rather than assumed** (this repo treats an enum change or a retype as BREAKING, so
silence would be the failure). `service_plan` gains `iMessage only` / `SMS only`, but
those values are reachable ONLY through `--service imessage` / `--service sms` — a flag
that did not exist before. Every command line that was valid before this change still
produces `iMessage→SMS auto` or `group chat`: its `service_plan` VALUE is unchanged, so a
consumer switching exhaustively on that field meets a new value only once it starts
requesting one. The payload around it is not byte-identical, and deliberately so — `message` becomes omissible, but only on a file-only send, a shape that
could not previously exist because `--message` was required; wherever `message` appeared
before it appears now, same type, same value. `service_requested` and `files` are emitted
UNCONDITIONALLY on both envelopes, and `files_sent` on every execute envelope, whether or
not the new flags were passed. That is additive for a tolerant reader, which the contract
requires consumers to be. Nothing is removed, renamed, retyped, and no exit code moved.

**Verification, and its bound.** All eight emitted shapes (3 services x with/without a
body, group x with/without a body) are compile-checked against `/usr/bin/osacompile` by
`Tests/MessagesKitTests/SendScriptCompilationTests.swift` — the Messages counterpart of
Mail's `bats/helpers/applescript_syntax_check.py`, placed in the Swift tier because
`bats/` files are frozen against branch work by the trusted-catalog gate in
`scripts/ci/bats_inventory.py`. That test COMPILES and never executes: the same script
under `osascript` would drive Messages.app and reach a real person. The `auto` arm's
two-tier `try` nesting is pinned structurally, not by substring, because that nesting is
what keeps the routing claim above true. Routing, ordering, validation and failure
reporting are pinned in the logic tier. Like the `--group` row above, what remains is a
validation-evidence limitation rather than a capability gap: no attachment has been sent
to a live recipient — 1:1 or group — and no live send is authorized.

### Attachment metadata

The CLI intentionally adds a read-only attachment metadata extra beyond the MCP
surface. `messages recent` and `messages search` emit `attachments` arrays; each
attachment carries row id, stored filename, standardized absolute path when one
can be derived, tri-state local existence from a conservative local-root probe,
MIME/UTI hints, transfer name, byte count, sticker state, and
hidden-attachment state. `messages search` also emits
`has_attachments`, matching the `recent` shape. This is additive for tolerant
readers and keeps `schema_version = 1`: no existing key is removed, renamed, or
retyped, and pre-attachment consumers must ignore unknown keys.

There is one deliberate row-set divergence. `messages recent` now keeps
attachment-only rows by returning an empty `body` when authoritative join rows
exist; a cache flag alone still cannot preserve a bodyless row because there are
no file details to return. `messages search` still cannot discover
attachment-only rows with no searchable body, because its SQL prefilter is
text/attributedBody-based before scoring. If such a row is otherwise selected in
the future, it should use the same attachment shape.

### Chat identity

A second read-only extra beyond the MCP surface. Every message emitted by
`messages recent` and `messages search` now carries `chat_identifier`
(`string|null`), `chat_guid` (`string|null`) and `is_group` (bool), derived by
joining `chat_message_join` → `chat`; `is_group` is `chat.style == 43`. A message
joined to several chats reports the LOWEST chat ROWID, and a message joined to no
chat reports nulls with `is_group: false`. `--direct-only` on both commands
excludes group-chat messages using that same first-chat-by-ROWID rule, applied in
SQL: on `recent` that means `--limit N` still yields up to N direct messages
rather than N-minus-the-groups, and on `search`, which has no `--limit`, it means
the filter runs before the `fuzzySoftCap` prefilter so the cap is spent on
candidates that can actually match. `direct_only` echoes the flag in the
`RecentData`/`SearchData` payloads.

**`--direct-only` excludes group chats, not "everything that is not a 1:1".** A
message joined to NO chat row is kept: it has no style, and a message in no chat
is not in a group chat. Those rows are identifiable by `chat_identifier: null`. A
message joined to several chats is judged by its lowest-ROWID chat, so a message
in both a 1:1 and a group survives the filter when the 1:1 chat has the lower row
id and is excluded when the group does.

`messages chats` gains `last_activity` (ISO-8601 UTC of the chat's newest
message, or null), `last_activity_timestamp` and `participants` (handle ids from
`chat_handle_join` → `handle.id`, possibly empty), alongside a `--name` substring
filter (case-insensitive, echoed as `name_filter`, with an empty value normalized
to null so the echo cannot claim a filter that did not run) and `--limit`, which
accepts 1-10000 and rejects anything outside that with a validation error (exit
64), the same bound `recent --limit` uses.

`participants` are RAW handle ids — phone numbers and email addresses exactly as
chat.db stores them, not contact-resolved the way a message's `sender` is. The
account owner is not among them: `chat_handle_join` records the other parties
only, so a 1:1 chat lists just the person on the other end. That is a count of
PEOPLE, not of entries — the array is not deduplicated, and the schema permits
one person to occupy more than one entry when a store holds separate handle rows
per service for them, so even a 1:1 chat is not guaranteed to be a single-element
array. Treat it as a list rather than a set.

`last_activity_timestamp` is the RAW `message.date` value chat.db stores, and is
NOT a fixed unit: nanoseconds since the Apple epoch on modern rows and SECONDS on
legacy ones, the same greater-than-10-digit heuristic message `timestamp` uses.
Be precise about what that does and does not rule out, because the two are easy
to conflate. **Ordering is sound**, within a chat and across chats: a nanosecond
value (~7.8e17) always exceeds a seconds value (~7.8e8) and the ns rows are
always the newer ones, so a larger raw value always means a more recent message.
That is the same premise `chatLastActivity` relies on to take `MAX()` of the raw
column at all. **Arithmetic is not sound**: dividing by 1e9 yields a 1970 date on
a chat whose newest message is legacy, and differences between two raw values are
meaningless when they straddle the two modes. Sort on `last_activity_timestamp`
if you want the raw value; use `last_activity` for anything that treats it as a
time.

`--direct-only` reports whether it ran. `direct_only` echoes the request and
`direct_only_applied` says whether the predicate was actually applied; the two
differ exactly when the store cannot classify chats, in which case group messages
are still present. The capability is resolved ONCE per invocation and threaded,
so the filter, the stderr warning and the field cannot disagree. This matters
because stdout JSON is the versioned interface and stderr is not: a filter that
silently failed open would be invisible to the only channel an agent is told to
trust.

Any `chat.style` other than 43, including an absent or unrecognized one, is
reported and filtered as non-group.

This is additive and keeps `schema_version = 1`: no existing key is removed,
renamed, or retyped. Two shapes are deliberate and worth stating, because they
differ. The new nullable keys are ALWAYS PRESENT with an explicit JSON `null` —
Swift's synthesized encoder omits a nil optional entirely, so present-and-null is
what lets a consumer distinguish "this message is in no chat" from "a binary that
predates the field". The PRE-EXISTING optionals (`group_name`, `handle`,
`service`, and the `chat` row's `guid`/`room_name`/`service_name`/`group_id`/
`style`) keep their omit-when-nil shape unchanged; `group_name` in particular is
the oracle's deliberate two-state absent-or-name field (see §8's `get_recent_messages`
row, the Python-truthiness comment on the `group_name` binding in `ChatDB.swift`,
and the `emptyChatDisplayNameEmitsNoGroup` test), and giving it a third state
would re-introduce exactly the defect that was fixed there.

`messages chats` resolves activity and participants for the chats it is actually
returning, not for the whole store: the `--name`/`--limit` selection runs first
and the two lookups are keyed on that chat-ROWID set. The one-pass shape it
replaced grouped over every message row on every invocation — measured on one
large real store, the whole-store grouping took ~28x as long as the same lookup
restricted to that store's named chats, and far longer than the lookup for a
`--limit 5` selection. Treat that multiplier as an illustration from a single
store rather than a constant: what remains scales with the number of messages
held by the chats actually RETURNED, so a selection covering many busy chats is
still substantial work, and `--limit` is the lever on a large store. The listing's
`ORDER BY ROWID` is stated in SQL rather than left to a bare SELECT's incidental
scan order, because `--limit` makes the ordering decide WHICH chats a caller
receives.

`group_name` and `is_group` are not the same fact: `group_name` is a display name
and is absent for an unnamed group, while `is_group` reads `chat.style` and so
still reports such a chat as a group. A chat.db lacking `chat_message_join`
degrades to null identifiers and `is_group: false` rather than failing the read —
the posture the attachment join already takes — and `--direct-only` then excludes
nothing, since nothing is known to be a group. The filter and the fields are
gated on the IDENTICAL capability check for that reason: a schema that could
answer one but not the other would drop rows while reporting every survivor as
`is_group: false`. When the filter cannot be applied the commands say so on
stderr, so it never fails open silently — and, more importantly, the payload
itself says so: `direct_only` and `direct_only_applied` are both new keys on
`RecentData`/`SearchData`, and the stderr warning is a human-channel addition on
top of them, not the record of it. The JSON gained keys; nothing in it was
removed, renamed or retyped, so `schema_version` stays 1.

### WRatio fuzzy-search boundary (behavioral, per §6 / §7)

The message fuzzy scorer is `thefuzz.WRatio` (rapidfuzz-backed). This port
reimplements WRatio on a normalized-Indel/LCS `ratio` plus a **faithful port of
rapidfuzz's three-loop `partial_ratio`** (`_partial_ratio_impl` in `fuzz_py.py`):
growing prefixes of the haystack, then full-length windows, then shrinking
suffixes, each over the same Indel kernel.

**This section previously claimed the opposite, and understated the gap it was
describing.** It said the port used a fixed-length sliding window, called the
result "an accepted behavioral-parity boundary" affecting only "low-relevance
matches at the threshold floor", and cited a 25→21 measurement. Two things were
wrong. The divergence was far larger than 4 marginal hits — re-measured on 768
real message bodies across 10 query terms at the default 0.6 threshold, the
oracle matched 276 and the port matched 204, i.e. **73.9% recall, roughly a
quarter of fuzzy matches dropped**. And the cause was not scoring noise: because
`ratio` is `2·LCS/(|a|+|b|)`, a window *shorter* than the needle can outscore
every full-length window, since the denominator shrinks. `partial_ratio("golf",
"a quiet symbol")` is 66.7 via the two-character suffix `"ol"`, where the
best four-character window reaches only 50.0. A single fixed length cannot see
that alignment at all, so the missing recall was structural.

**Now measured at parity.** A fixed probe-term search over `--hours 72` returns the same 12
messages as `tool_fuzzy_search_messages`, with identical scores in identical
order. A 60-pair golden table generated from rapidfuzz itself — regenerated WHOLLY SYNTHETIC
after the D9 scrub (see the test header) — is asserted in `Tests/MessagesKitTests/PartialRatioParityTests.swift`;
deleting either of the two restored loops fails it.

One deliberate bound remains, and it is not the one this section used to
describe: the full-length-window loop is capped at `Fuzzy.windowScanCap` (1200
characters of the haystack), because it is the only one of the three whose
iteration count grows with message length, and search runs it about five times
per candidate over up to 10k rows. The prefix and suffix loops are bounded by the
*query* length and are uncapped, so a long message still has its tail examined.
On the measured corpus (768 bodies, longest 1416 characters) two messages exceed
the cap.
