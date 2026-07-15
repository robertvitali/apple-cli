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
| `tool_get_recent_messages` | **CORE** | `hours:int=24`, `contact:str=None` | Reads `message` table, `CAST(date AS TEXT) > <apple-ns-epoch>`, `ORDER BY date DESC LIMIT 100`, **across ALL chats**. `contact` optional: fuzzy name→handle, or phone/email, or stateful `"contact:N"` selection. Extracts body from `text` **or** `attributedBody` (hand-rolled NSArchiver typedstream parser). Resolves sender name via AddressBook; annotates group-chat name. Output: lines `[YYYY-MM-DD HH:MM:SS] [group?] <You|Name>: <body>`. |
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
- **Attachment metadata** + optional **CAF→M4A / GIF→PNG** conversion (imsg) — model-consumable media.
- **Explicit service control** `--service imessage|sms|auto` + `--no-sms-fallback` (imsg) — MCP's routing is implicit/uncontrollable.
- **`send --file`** attachments (imsg) — MCP is text-only.
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
