# apple-notes — MCP → CLI Porting Analysis

**Domain:** apple-notes
**MCP under test:** `apple-notes-mcp` (npm), registered via `npx -y apple-notes-mcp`
**Version analyzed:** **2.5.12** (published 2026-07-14; latest at analysis time 2026-07-15)
**Source repo:** https://github.com/sweetrb/apple-notes-mcp (tag `v2.5.12`, MIT, author Rob Sweet)
**Analysis basis:** Clean TypeScript source read at tag `v2.5.12` (not the bundled `build/index.js`); published tarball verified to match. No binaries executed.
**Verdict (TL;DR): BUILD.** No candidate CLI covers even half the surface. The strongest (memo) reaches ~12/34 and uses an interactive-picker UX unsuitable for agent scripting. Attachments-to-disk, checklist state, note metadata, sync status, full-library JSON export, batch ops, and account/selection/diagnostic tools are absent across every candidate.

---

## 0. Mechanism map (how the MCP actually works)

Two bridges, split by capability:

| Bridge | Used for | Permission |
|---|---|---|
| **AppleScript** via `osascript` (`execSync`, one-shot) | ~28 of 34 tools: all CRUD, folders, accounts, move, search, list, **attachments (list/save/fetch/show)**, JSON export, selection, show-in-UI, default-location, health | **Automation/Apple Events** (control Notes.app) — prompted once |
| **`NoteStore.sqlite` direct read** (`sqlite3 -readonly`, never writes) | `get-checklist-state`, `get-note-metadata`, `get-sync-status`, checklist enrichment inside `get-note-markdown` | **Full Disk Access (FDA)** on the launching process |

Key mechanism facts (load-bearing for the port):
- **Body read** = AppleScript `body of note` → returns **HTML**; `plaintext of note` → returns plain text. `name` = title (first `<h1>`/line).
- **Body write** = AppleScript sets `body` to HTML. `format:"plaintext"` escapes `& < > \`, converts `\n`/`\t`→`<br>`; `format:"html"` passes through. Title is prepended as `<h1>`; `name` is never set directly (Notes derives title from first body line).
- **Attachments** = AppleScript `save theAttachment in (POSIX file ...)`. `fetch-attachment` saves to a temp file then base64-reads it (25 MB cap). **Link-preview attachments have no file payload and fail to save** — this is the same wall any AppleScript CLI hits.
- **Checklist state** = read `ZICNOTEDATA.ZDATA` (gzipped **protobuf**) from `NoteStore.sqlite`, decompress, decode protobuf, walk attribute runs: `paragraph_style.style_type == 103` (checklist), `checklist.done` field (0/1). Bundles a hand-rolled protobuf decoder (`src/utils/protobuf.ts`). **AppleScript cannot read checklist done-state at all** — `body` strips it.
- **Note metadata** (`get-note-metadata`, BETA) = plain `SELECT` of scalar columns on `ZICCLOUDSYNCINGOBJECT`: `ZISPINNED, ZHASCHECKLIST, ZHASCHECKLISTINPROGRESS, ZISRECOVERINGFROMTRASH, ZISPASSWORDPROTECTED, ZPASSWORDHINT, ZSNIPPET, ZWIDGETSNIPPET, ZSMARTFOLDERQUERYJSON`. Schema-versioned/guarded (columns vary by macOS). Resolves trashed notes AppleScript can't.
- **Markdown** = `turndown` (npm) on the HTML body, then checklist enrichment from SQLite (`- [x]`/`- [ ]`).
- **Sync status** = `ZICCLOUDSTATE` pending count + WAL-file mtime.
- **JXA** was researched and **rejected** (`docs/JXA_RESEARCH.md`): no performance or reliability advantage over AppleScript. Confirms AppleScript is the correct bridge.

**Documented hard limits (constrain the MCP AND any CLI equally):** pinned read/write not scriptable (metadata read-only via SQLite; no write path); note-to-note links not exposed; tags are body `#hashtags` only (no scriptable `tags` property; `create-note` `tags` param is echo-only, not persisted); smart folders not scriptable; true checklists cannot be *created* via AppleScript (only read); password-protected notes must be unlocked in the UI.

---

## 1. MCP Capability Manifest (34 tools)

Class tags: **C**=CORE (read/write data), **D**=DERIVED (convenience/aggregate over core), **X**=DIAGNOSTIC.

| # | Tool | Class | Key params | Behavior / output |
|---|---|---|---|---|
| 1 | create-note | C | `title`, `content`, `format`(plaintext\|html), `tags[]`, `folder`(nested `A/B`), `account` | Make note, title as `<h1>`; returns `{ok,id,title,folder,account}`. `tags` echo-only. Nested folder path auto-target. |
| 2 | update-note | C | `id`\|`title`, `newTitle?`, `newContent`, `format`, `account` | **Replaces** entire body (not append). Warns if shared. Password-protected → refused. |
| 2b | append-to-note | C | `id`\|`title`, `content`(min 1), `position`(after\|before, def. after), `separator`(max 20, def. `\n\n`), `format`, `account` | Adds to the body WITHOUT replacing it. Splits the existing HTML at the first `</div>` so the note's title div always stays first — a `before` that skipped this would rewrite the title. Plaintext content is escaped (`&<>`) and split into one `<div>` per line; the default `\n\n` separator renders as `<div><br></div>`. In `html` format content AND separator pass through raw. Returns `{ok,id,title,shared}`. |
| 2c | get-note-link | C | `id`\|`title`, `account` | notes:// deep link. SQLite `SELECT ZIDENTIFIER FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK = ?` first, AppleScript `note link` as the macOS 12–15 fallback — the oracle's own order. Password-protected notes are refused before the lookup. **Payload differs by path, matching the oracle:** the id path returns `{id,title,url}`, the title path `{title,url}` with NO `id`. |
| 2d | search-notes (limit semantics) | C | `limit` | **Defaults to 50** (`DEFAULT_SEARCH_LIMIT`), not unbounded. Measured: a bare search returned **245** here vs the oracle's **50**. The oracle's schema cites timeout risk as ITS reason; that is not reproduced here and is not the justification — measured 8.3s at `--limit 5`, 28.1s at 50, 30.2s unbounded, because the `notes where name contains …` filter scans the whole store before the loop, so the limit never bounds the expensive step. Parity is the reason. **`--all` is a CLI-only superset** restoring the unbounded total query the default would otherwise retire with no replacement (the MCP has no equivalent and no pagination). `limit` is `exclusiveMinimum: 0`, so a non-positive value is a validation error on **search AND list**. The applied limit is disclosed: the oracle puts it in its PROSE response, and this JSON-first port additionally carries `applied_limit` / `limit_reached` / `limit_was_default` as optional payload fields (additive = MINOR). The field is `limit_reached`, NOT `truncated` — at count == limit we cannot know a further match exists. `query` is `minLength 1` and `maxLength 2000`. **`list` keeps NO default** — `resolveSearchLimit` is absent from the oracle's list-notes handler, so unbounded `list` is the parity. |
| 2e | update-note (response title) | C | `format`, `newTitle`, `newContent` | In **html** format the reported title is DERIVED from the new body via `firstVisibleHtmlLine` and `newTitle` is IGNORED — Notes takes a note's title from its first rendered line, so reporting `newTitle` would name something Notes never shows. Falls back to the current title when the body renders nothing. **plaintext** keeps JS truthiness: an empty `newTitle` falls back rather than blanking. Uses a separate oracle-faithful entity decoder (optional semicolon, two sequential whole-string passes hex-then-decimal, surrogate/range rejection). The split mirrors the ORACLE, which itself ships two decoders — this one and the inline decoder in `htmlToPlaintext` that `get-note-markdown` uses; unifying them would regress the markdown path. Measured deltas of the existing `decodeEntities` vs this one: semicolon required (`a&nbsp b`), one interleaved pass instead of two (`&#x26;#65;` → `"&#65;"` vs oracle `"A"`), and a `[0-9a-fA-F]` decimal class that drops `&#1F;`. Surrogate rejection is NOT a delta — `Unicode.Scalar` already nils. Those three are `get-note-markdown`'s, tracked under NOTES-L1. **Porting note (earned the hard way, two review rounds):** `NSRegularExpression` is NOT a drop-in for a JS regex. ICU applies FULL case folding under `.caseInsensitive` (U+017F folds to `s`, U+212A to `k`) where JS `/i` without `u` folds ASCII only; ICU matches `$` before a final line terminator regardless of `.anchorsMatchLines` where JS `$` without `m` matches at absolute end (`\z` is the correct spelling); ICU `\s` includes U+0085 and excludes U+FEFF where JS's does the opposite; and ICU `\b` derives from a Unicode word class where JS's is ASCII. Each of these must be swept across EVERY site in a ported function, not fixed only where first noticed — that omission is what round 2 caught. Where the semantics cannot be expressed at all (JS's backreference is ASCII-case-insensitive; ICU's cannot be), the port uses a scanner. |
| 3 | delete-note | C | `id`\|`title`, `account` | Permanent delete of one note; warns if was shared. Returns `{ok,id,title,wasShared}`. |
| 4 | move-note | C | `id`\|`title`, `folder`, `account` | Native move preserving id/created/attachments. Dest folder must exist. |
| 5 | get-note-content | C | `id`\|`title`, `account` | Full **HTML** body + parsed `hashtags[]`. Caps huge inline base64 images. Password → refused. |
| 6 | get-note-plaintext | C | `id`\|`title`, `account` | Native `plaintext` (no HTML→text conversion). |
| 7 | get-note-markdown | D | `id`\|`title`, `account` | `turndown(html)` + checklist `[x]`/`[ ]` when FDA granted (else plain lists). |
| 8 | get-note-by-id | C | `id` | Metadata by id: `{id,title,created,modified,shared,passwordProtected}` (ISO dates). |
| 9 | get-note-details | C | `title`, `account` | Same metadata by title (+`account`). |
| 10 | get-note-metadata | X/C | `id` | **BETA, SQLite read (FDA).** `{pinned,hasChecklist,hasChecklistInProgress,recoveringFromTrash,passwordProtected,passwordHint,snippet,widgetSnippet,smartFolderQuery}`; fields vary by macOS; works on trashed notes. |
| 11 | get-checklist-state | C | `id` | **SQLite protobuf read (FDA).** Per-item `{text,done}` + `checked`/`total`. AppleScript-impossible. |
| 12 | list-notes | C | `account`, `folder`, `modifiedSince`(ISO), `limit` | Titles only (no ids/content). Sync-warns. |
| 13 | search-notes | C | `query`, `searchContent`(bool), `account`, `folder`, `modifiedSince`, `limit` | Title (or body) search; returns `{id,title,content:"",tags:[],created,modified,folder,account}[]` — apple-cli emits all but the `content`/`tags` placeholders (see Output-field deviations). Flags `Recently Deleted`. Sync-aware. |
| 14 | get-selected-notes | C | — | Reads Notes.app **UI selection** → `{title,id}[]`. |
| 15 | list-folders | C | `account` | All folders with nested paths. Sync-warns. |
| 16 | create-folder | C | `name`(nested `A/B/C`), `account` | Creates intermediate folders; skips existing. |
| 17 | delete-folder | C | `name`, `account` | **Cascades**: deletes the folder AND every note in it. The oracle source only ever HEDGED this ("may fail if the folder contains notes"); its tool description upgraded the hedge to an assertion and this port inherited the assertion. Measured 2026-08-02: a non-empty folder was deleted, and the contained note did NOT reach Recently Deleted — it was destroyed permanently. |
| 18 | show-folder | X | `id`, `separately?` | Reveals folder in Notes UI. |
| 19 | list-accounts | C | — | Accounts (iCloud/Gmail/Exchange…) + defaultFolder + upgraded flag. |
| 20 | get-default-location | D | — | Default `{account,folder}` where new notes land (with ids). |
| 21 | show-account | X | `id`, `separately?` | Reveals account in Notes UI. |
| 22 | list-shared-notes | C | — | Notes shared with collaborators → `{title,account,id}[]`. |
| 23 | show-note | X | `id`, `separately?` | Reveals a note in Notes UI. |
| 24 | list-attachments | C | `id`\|`title`, `account` | Per-attachment `{id,name,contentType,contentId,url,created,modified,shared}`. |
| 25 | save-attachment | C | `noteId`, `attachmentId`, `savePath`(abs, home/temp/`/Volumes`) | AppleScript `save` to disk; path-traversal-guarded; link-previews rejected with hint. |
| 26 | fetch-attachment | C | `noteId`, `attachmentId` | Bytes inline as **base64** (temp-file round-trip, 25 MB cap) + `{name,contentType,bytes}`. |
| 27 | show-attachment | X | `noteId`, `attachmentId`, `separately?` | Reveals attachment in Notes UI. |
| 28 | batch-delete-notes | D | `ids[]` (≤500) | Bulk delete; per-id `{success,error}` + counts. |
| 29 | batch-move-notes | D | `ids[]` (≤500), `folder`, `account` | Bulk move to one folder; per-id results. |
| 30 | export-notes-json | D | — | **Entire library** → structured JSON (accounts→folders→notes + summary). |
| 31 | get-notes-stats | D | — | Totals, per-account/folder counts, recent 24h/7d/30d, partial-coverage diagnostics. |
| 32 | get-sync-status | X | — | **SQLite/WAL read.** `{syncDetected,pendingUpload,secondsSinceLastChange,recentActivity}`. |
| 33 | health-check | X | — | Quick pass/fail: Notes reachable + FDA probe. |
| 34 | doctor | X | — | Detailed setup diagnostics (automation perm, account state, FDA) + structured fields. |

Also ships **MCP resources + prompts** (`registerResourcesAndPrompts`) and env config (`APPLE_NOTES_MCP_*`, file-config fallback) — not CLI-portable surface, noted for completeness.

**Surface totals:** 34 tools. CORE ≈ 20, DERIVED ≈ 7, DIAGNOSTIC ≈ 7. Dual id-or-title addressing on ~11 tools is itself a behavioral requirement.

---

## 2. CLI Capability Manifests (per candidate)

### 2a. Piesson/apple-notes-cli — Shell, **0★**, 2 commits, last push 2026-01-07, effectively abandoned
Single `notes-cli` bash script + `lib/{core,styling,utils}.sh` (~1.1k lines). AppleScript `body of theNote`.
**Commands:** `list [--folder]`, `get <title> [--html]`, `create <title> <content> [styling]`, `update <title> <content>`, `append <title> <content>`, `delete <title>`, `search <keyword>`, folder list/create, `move`. Rich-text styling flags (`--bold/--italic/--color/--size/--highlight/--html`).
**Absent:** attachments (any), accounts, by-id addressing, markdown, JSON export, batch, checklist-state, metadata, sync, selection, stats, doctor, shared-notes, default-location, show-in-UI, delete-folder. Title-only addressing (no CoreData ids). Has an `append` extra (MCP lacks). *(true at 2.5.12; the installed oracle 2.6.12 ADDED `append-to-note`, so this is stale — NOTES-M10)* A `create_checklist_item` helper only emits HTML that won't render as a real checklist (same AppleScript wall).

### 2b. xwmx/notes-app-cli — Shell, **83★**, last push 2025-09-16 (~10 mo stale), mature but dormant
Single 3.3k-line `notes-app` script. Homebrew-installable. Uses `id`/normalized selectors.
**Commands:** `accounts [show] [--properties]`, `add [name] [--account --body --folder]`, `attachments <note> [--properties]`, `count`, `delete`, `edit` (opens `$EDITOR`), `export <path> [--account --folder --note]`, `folders [show] [--properties]`, `list`, `show`, `sync`, `update`, `env`, `version`.
**Notable:** `attachments` lists attachment **properties only** — no save/fetch/show of bytes. `export` writes **text files** (not JSON, not markdown). `sync` triggers/awaits iCloud sync (not the MCP's read-only sync *status*).
**Hard blocker:** "Attachments are not supported… editing a note that contains an attachment results in the attachment being removed… `notes-app` does not allow editing or updating notes that have attachments." So `update`/`edit` **refuse** any note with attachments.
**Absent:** attachment bytes, move, folder create/delete, markdown, JSON export, batch, checklist-state, metadata, sync-status(read), selection, stats, doctor/health, shared-notes, default-location, show-in-UI. First-line formatting not preserved (documented quirk).

### 2c. antoniorodr/memo — Python (`click`), **308★**, last push 2026-07-11, **actively maintained**, covers Notes **+ Reminders**
`memo notes` / `memo rem` command groups. AppleScript bridge; `md_converter` for HTML→Markdown; image placeholders `[MEMO_IMG_N]` on edit.
**`memo notes` surface:** `--folder`, `--add`, `--edit`, `--delete`, `--move`, `--flist` (list folders/subfolders), `--remove` (folder), `--search` (fuzzy), `--export` (HTML + convert to Markdown), id-search, md-convert. Reminders CRUD in `memo rem`.
**UX problem:** selection is **interactive/keyboard-driven** (`pick_note`/`pick_reminder`, fuzzy pickers) — the task notes this is "poor for scripted structured output." An agent can't deterministically address a note without a TTY picker in the common paths.
**Absent:** attachment save/fetch/show to disk (only preserves images in-place on edit), checklist done-state, note metadata (pinned etc.), sync status, batch ops (scripted), list-accounts, structured full-library JSON export, get-selected, default-location, health/doctor/stats, list-shared, show-in-UI. Reminders coverage is out-of-scope scope-creep, not parity.

### 2d. kzaremski/apple-notes-exporter — Swift **GUI app**, **615★**, last push 2026-05-12
Bulk **export only** (HTML/MD/PDF/TXT/etc.) preserving folder structure, including iCloud. It is a `.app`, not a scriptable CLI. Covers ~1 of 34 capabilities (a fragment of export). Not a CRUD/parity candidate.

### 2e. pRizz/apple-notes-exporter-rs — Rust **crate/library**, **0★**, last push 2026-01-13
Recursive bulk export via AppleScript, delivered as a Rust library crate (not a packaged CLI). Export-only. ~1 of 34. Not a parity candidate.

---

## 3. Capability Matrix

Cell = coverage of the MCP capability. `EXACT` = operation+params+behavior met or superset; `PARTIAL(gap)` = related but missing params/behavior; `MISSING` = absent.

| MCP capability | Piesson | xwmx | memo | kzaremski | pRizz |
|---|---|---|---|---|---|
| create-note (+format,tags,nested folder,account) | PARTIAL (no account/id-return/nested-verified; +styling) | PARTIAL (`add`; no format/nested) | PARTIAL (interactive; no format/account) | MISSING | MISSING |
| update-note (id\|title, replace, format) | PARTIAL (title-only) | PARTIAL (blocks attachment notes) | PARTIAL (interactive; editor-based) | MISSING | MISSING |
| delete-note (id\|title) | PARTIAL (title-only) | EXACT-ish (id/selector) | PARTIAL (interactive) | MISSING | MISSING |
| move-note (id\|title→folder) | PARTIAL (title-only) | MISSING | PARTIAL (interactive) | MISSING | MISSING |
| get-note-content (HTML + hashtags) | PARTIAL (`get --html`; no hashtags) | PARTIAL (`show`; no hashtag parse) | PARTIAL (interactive) | MISSING | MISSING |
| get-note-plaintext (native plaintext) | PARTIAL (HTML-strip, not native) | PARTIAL (`show`) | PARTIAL | MISSING | MISSING |
| get-note-markdown (+checklist state) | MISSING | MISSING | PARTIAL (md, **no checklist state**) | PARTIAL (bulk md, no per-note/checklist) | PARTIAL (bulk export) |
| get-note-by-id (metadata) | MISSING | PARTIAL (props by id) | PARTIAL (id-search) | MISSING | MISSING |
| get-note-details (metadata by title) | MISSING | PARTIAL (`show --properties`) | MISSING | MISSING | MISSING |
| get-note-metadata (pinned/snippet… SQLite/FDA) | MISSING | MISSING | MISSING | MISSING | MISSING |
| get-checklist-state (done/undone, SQLite/FDA) | MISSING | MISSING | MISSING | MISSING | MISSING |
| list-notes (+modifiedSince,limit) | PARTIAL (no modifiedSince/limit) | PARTIAL (no modifiedSince/limit) | PARTIAL (interactive list) | MISSING | MISSING |
| search-notes (title/content, filters) | PARTIAL (basic) | MISSING (no search cmd) | PARTIAL (fuzzy, interactive) | MISSING | MISSING |
| get-selected-notes (UI selection) | MISSING | MISSING | MISSING | MISSING | MISSING |
| list-folders (nested paths) | PARTIAL (flat) | PARTIAL (props) | PARTIAL (`--flist`) | MISSING | MISSING |
| create-folder (nested, skip-existing) | PARTIAL (basic) | MISSING | MISSING | MISSING | MISSING |
| delete-folder (guard non-empty) | MISSING | MISSING | PARTIAL (`--remove`) | MISSING | MISSING |
| list-accounts (+defaultFolder,upgraded) | MISSING | PARTIAL (`accounts`) | MISSING | MISSING | MISSING |
| get-default-location | MISSING | MISSING | MISSING | MISSING | MISSING |
| list-shared-notes | MISSING | MISSING | MISSING | MISSING | MISSING |
| list-attachments (id,name,type,dates,url,shared) | MISSING | PARTIAL (props list only) | MISSING | MISSING | MISSING |
| save-attachment (bytes→disk, path-guard) | MISSING | MISSING | MISSING | PARTIAL (bulk export of embedded files) | PARTIAL (bulk) |
| fetch-attachment (base64 inline) | MISSING | MISSING | MISSING | MISSING | MISSING |
| show-attachment (reveal in UI) | MISSING | MISSING | MISSING | MISSING | MISSING |
| batch-delete-notes (ids[]) | MISSING | MISSING | MISSING | MISSING | MISSING |
| batch-move-notes (ids[]→folder) | MISSING | MISSING | MISSING | MISSING | MISSING |
| export-notes-json (full library, structured) | MISSING | PARTIAL (text export) | PARTIAL (per-note HTML/md) | PARTIAL (bulk, non-JSON structured) | PARTIAL (bulk) |
| get-notes-stats (aggregate) | MISSING | PARTIAL (`count` only) | MISSING | MISSING | MISSING |
| get-sync-status (read-only, SQLite/WAL) | MISSING | MISSING | MISSING | MISSING | MISSING |
| health-check | MISSING | PARTIAL (`env`) | MISSING | MISSING | MISSING |
| doctor | MISSING | MISSING | MISSING | MISSING | MISSING |
| show-note / show-folder / show-account (reveal UI) | MISSING | PARTIAL (`show` note) | MISSING | MISSING | MISSING |
| **id-or-title dual addressing** (behavioral) | MISSING (title-only) | PARTIAL (id/selector) | PARTIAL | — | — |
| **structured machine output** (JSON/structuredContent) | MISSING | PARTIAL (props text) | MISSING (interactive prose) | MISSING | MISSING |

**EXACT count vs. 34 MCP tools:** Piesson 0, xwmx ~1, memo 0, kzaremski 0, pRizz 0. No candidate is anywhere near a superset.

---

## 4. VERDICT — **BUILD**

The strict rule (viable drop-in ⇔ 100% capability coverage at operation+parameter+behavior granularity) **disqualifies every candidate**, decisively:

- **Piesson** — abandoned (0★/2 commits), title-only, no ids, ~7/34 partial, zero attachments/accounts/diagnostics. Not a base worth forking.
- **xwmx** — mature but dormant (~10 mo), and structurally opposed to parity: **lists attachments but cannot read their bytes, and actively refuses to edit any note that has attachments** — a permanent blocker against the MCP's read/update-with-attachments contract. No move, no folder create/delete, no markdown/JSON, no batch, no SQLite tools.
- **memo** — best-maintained, best CRUD, and has an HTML→Markdown converter, but its **interactive-picker selection model is fundamentally wrong for an agent CLI**, and it still lacks attachments-to-disk, checklist state, metadata, sync, batch, accounts, structured JSON export, and every diagnostic. Reaches ~12/34 partial.
- **kzaremski / pRizz** — export-only (a GUI app and a Rust crate respectively); ~1/34. Not CRUD CLIs at all.

Beyond the checklist: **no candidate emits stable structured JSON output** (the MCP's `structuredContent` on every tool). An agent-facing CLI must default to machine-parseable output; retrofitting that onto memo's interactive TUI or xwmx's property-dump text is as much work as building fresh. And **none touch `NoteStore.sqlite`** — the four FDA-gated tools (checklist-state, metadata, sync-status, markdown-checklist-enrichment) require the protobuf/SQLite machinery that only `apple-notes-mcp` implements.

**Build our own `apple-notes` CLI.** Fork nothing; greenfield is cleaner than bending any candidate. `apple-notes-mcp` itself is the reference implementation and is MIT-licensed — its AppleScript templates, protobuf decoder, SQLite queries, and safety guards can be lifted/ported directly (same author-ecosystem intent: its keywords already include `codex`, and it ships `.agents/`/`codex`/`.antigravity-plugin` manifests, signaling multi-CLI ambition we can align with).

---

## 5. Extras Inventory (capabilities beyond the MCP worth folding into the build)

From the candidates:
- **Piesson:** `append <title> <content>` (add to a note without full-body replace — MCP only replaces at 2.5.12; 2.6.12 ships `append-to-note`); inline rich-text styling flags (`--bold/--italic/--color/--size/--highlight`) as ergonomic sugar over HTML.
- **xwmx:** `edit` opens the note in `$EDITOR` (interactive round-trip); `--properties` selector to project arbitrary AppleScript properties; explicit `sync` **trigger** (vs. the MCP's read-only status); `count` as a cheap cardinality op.
- **memo:** HTML→Markdown converter with image-placeholder preservation (`[MEMO_IMG_N]`) enabling non-destructive edit of image notes; fuzzy search; optional **Reminders** coverage (adjacent domain — out of scope here but note the shared AppleScript plumbing).
- **kzaremski/pRizz:** batched whole-library export to **multiple formats** (PDF/HTML/MD/TXT) preserving folder tree — a richer `export` than the MCP's JSON-only.

From `apple-notes-mcp` itself (already-built extras to preserve): env/file config fallback, inline-image capping, sync-awareness wrappers on reads, partial-coverage diagnostics in stats, MCP resources/prompts.

**Curated extras to fold into the port:** ~~`append`~~ (NOT an extra — `append-to-note` exists in oracle 2.6.12; ported to parity as NOTES-H4), an `--editor` interactive edit mode, richer multi-format `export` (json **+** md/txt/pdf), and a `sync --trigger` companion to `sync-status`.

---

## 6. PORT SPEC (BUILD)

**Name:** `apple-notes` (binary), publish to GitHub under the fleet org, SemVer.
**Base:** Greenfield. **Port** logic directly from MIT `apple-notes-mcp@2.5.12` (AppleScript templates, `protobuf.ts` decoder, `checklistParser.ts`, `noteMetadata.ts`, `syncDetection.ts`, `attachmentFs.ts` guards, `turndown` markdown).
**Language:** **TypeScript on Node ≥20** (bun-runnable), matching the reference so the AppleScript strings, protobuf decoder, and zod schemas transfer 1:1 and the same code can back both a CLI and a thin MCP shim. (A single-file compiled binary via `bun build --compile` also addresses the TCC/cdhash re-prompt issue documented in `docs/NODE-RUNTIME-AND-TCC-PERMISSIONS.md` — a signed, stable binary keeps FDA/Automation grants across updates, a real win over `npx node`.)
**Mechanism:** AppleScript via `osascript` for all CRUD/attachments/folders/accounts/selection/export/show; **`sqlite3 -readonly`** on `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite` for checklist-state/metadata/sync-status + markdown checklist enrichment (gzip + hand-rolled protobuf decode, style_type 103).

**Command surface (MCP parity — every tool a subcommand; `--json` default machine output, `--text` for humans):**
- Notes: `create` (`--format --tags --folder --account`), `update` (`--id|--title --new-title --format`), `delete` (`--id|--title`), `move` (`--id|--title --folder`), `get` (`--id|--title` → HTML+hashtags), `get-plaintext`, `get-markdown`, `get-by-id`, `get-details`, `get-metadata` (FDA), `get-checklist` (FDA), `list` (`--modified-since --limit`), `search` (`--content --folder --limit`), `selected`.
- Folders: `folders` (list), `create-folder` (nested), `delete-folder`.
- Accounts: `accounts`, `default-location`, `shared`.
- Attachments (**the hard set**): `attachments` (list), `save-attachment` (`--note-id --attachment-id --path`, path-guard home/temp/`/Volumes`), `fetch-attachment` (base64, size cap), `show-attachment`.
- Batch: `batch-delete` (`--ids`), `batch-move` (`--ids --folder`).
- Bulk/diag: `export` (json **+ curated** md/txt), `stats`, `sync-status`, `health`, `doctor`.
- Reveal-in-UI: `show-note`, `show-folder`, `show-account`.
- **Curated extras:** `edit --editor`, `sync --trigger`, multi-format `export`. (`append` was listed here as an extra; it is an oracle tool at 2.6.12 — NOTES-H4.)

Ship a thin **MCP-server mode** (`apple-notes mcp`) wrapping the same core so all three CLIs (Claude Code, Codex, agy) get identical behavior from one source — the fleet's cross-CLI-parity north star.

**Build cost: L** (large — not XL, because the reference implementation is MIT and directly portable). Hard parts, in order of risk:
1. **Checklist state + metadata (SQLite protobuf)** — porting `protobuf.ts` + `checklistParser.ts` + `noteMetadata.ts` and keeping them robust across macOS schema drift (BETA in the MCP for a reason). **M within L.**
2. **Attachment access** — AppleScript `save` round-trip, link-preview rejection, temp-file base64, path-traversal guards. Mechanically clear (reference exists) but macOS-version-fragile. **M.**
3. **Body HTML/markdown fidelity** — HTML in/out via `body`, title-as-`<h1>`, plaintext-vs-html escaping, `turndown` conversion, checklist enrichment. Round-trip fidelity is the classic Notes pain (first-line/name quirk, Notes' own re-tagging). **M.**
4. **AppleScript fragility** — escaping, field/record separators, nested-folder reference resolution (`-1728`), sync-timing partial reads. Reference has hardened patterns to lift. **S–M.**
5. **Structured-output + dual id/title addressing across ~34 subcommands** — mechanical but broad. **S.**

FDA/Automation permissions and the signed-binary/TCC-stability story are **operational**, not code-hard, but must be documented (port `docs/FULL-DISK-ACCESS.md` + `NODE-RUNTIME-AND-TCC-PERMISSIONS.md`).

**Immovable limits to document (no CLI can beat them):** cannot *set* pinned, cannot *create* real checklists, no note-to-note links, no smart folders, tags only as body `#hashtags`, password-protected notes need UI unlock, link-preview attachments have no saveable payload.

---

## 7. Sources

- **MCP source (authoritative):** `github.com/sweetrb/apple-notes-mcp` @ tag `v2.5.12` — `src/index.ts` (34 tool registrations, zod schemas), `src/services/appleNotesManager.ts` (3072 lines: AppleScript ops, attachments, markdown), `src/utils/{checklistParser,noteMetadata,syncDetection,protobuf,attachmentFs,hashtags,inlineImages}.ts`, `src/tools/doctor.ts`.
- **MCP docs:** `docs/APPLESCRIPT-LIMITATIONS.md`, `docs/FULL-DISK-ACCESS.md`, `docs/NODE-RUNTIME-AND-TCC-PERMISSIONS.md`, `docs/JXA_RESEARCH.md`, `docs/STABILITY-PERF-AUDIT-2026-06-19.md`.
- **npm:** `apple-notes-mcp@2.5.12` (tarball verified against source; `npm view` metadata; version history 1.1.0→2.5.12).
- **Candidate CLIs (source/README read; none executed):** `Piesson/apple-notes-cli` (0★, Shell), `xwmx/notes-app-cli` (83★, Shell, `notes-app` 3281 lines + README limitations), `antoniorodr/memo` (308★, Python/click, `src/memo/memo.py` + `memo_helpers/*`), `kzaremski/apple-notes-exporter` (615★, Swift GUI), `pRizz/apple-notes-exporter-rs` (0★, Rust crate). GitHub API metadata for provenance/maintenance (stars, last-push, archived).

---

## 8. Swift port — implementation notes + deviations (as built)

Implemented in `Sources/NotesKit/` as `apple notes <subcommand>` — mapped against the INSTALLED oracle, **2.6.12**, which registers 36 tools (this spec was originally written against 2.5.12 and still carries stale counts elsewhere — tracked as NOTES-M10). `append` is NOT an apple-cli extra TODAY, though it was not a mislabel when written: `append-to-note` did not exist at 2.5.12 (34 tools, zero hits) and arrived in 2.6.12, so the older "MCP lacks" note was correct and went stale. The port therefore shipped it without `position`/`separator` (NOTES-H4). **Root cause is the missing pin-vs-installed drift check, not the doc string** — the reconciliation found H4 with the stale label still in place. `get-note-link` was the last oracle tool the HEAD reconciliation identified as having no CLI subcommand; ported 2026-08-03 (NOTES-H1). **Scope of that claim, stated precisely:** it closes the one unmapped tool the audit found — it is NOT an independently re-verified 1:1 map of all 36. The binary registers 36 Notes subcommands against the oracle's 36 tools, but the counts coinciding is not proof (the CLI also ships genuine extras such as multi-format `export`), and most commands carry no `→ <tool>` annotation to check against. A per-tool re-map is NOTES-M10's job. See the mapping in `NotesCommand.swift`; multi-format `export` IS a genuine apple-cli extra. The AppleScript templates, protobuf/gzip/checklist decoder, metadata/sync SQLite queries, and attachment guards are ported from MIT `apple-notes-mcp@2.5.12`.

### Naming — camelCase → snake_case (deliberate, information-preserving)
The MCP emits camelCase keys; apple-cli emits snake_case per `docs/DESIGN.md` ("name payload fields in snake_case"). The map is 1:1: `passwordProtected→password_protected`, `hasChecklist→has_checklist`, `hasChecklistInProgress→has_checklist_in_progress`, `wasShared→was_shared`, `savedPath→saved_path`, `contentType→content_type`, `secondsSinceLastChange→seconds_since_last_change`, `totalNotes→total_notes`, `last24h→last_24h`, `widgetSnippet→widget_snippet`, `smartFolderQuery→smart_folder_query`, etc. Every field's *information* is preserved.

### Output-field deviations (the only places the payload set differs from the MCP)
- **search / selected / shared** drop the MCP's placeholder `content:""` and `tags:[]` (never populated for these list ops). **search** emits the note's real `created`/`modified` — the MCP reads both per-hit in its search loop and `new Date()` is only its unreadable-date fallback, so these are REAL fields the superset rule requires. (An earlier revision of this line claimed the MCP fabricated them at response time and dropped them on that basis; a review pass disproved the claim against the oracle source — `build/index.js` search loop emits `createdParts`/`modifiedParts` per row via `asDatePartsExpr` — and the fields were ported.) The **real** `account` value the MCP returns on search IS emitted (`NoteSummary.account`). Rationale: propagating empty placeholder fields is worse than omitting them; every field apple-cli emits carries real information.
- Optional fields are omitted (not `null`) when absent — matching the MCP's "field absent when unavailable" for `get-metadata` (schema-drift columns), attachment `url`, etc.

### Superset improvements (capabilities BEYOND the MCP)
- **`get-checklist` / `get-metadata` are SQLite-only** — they do NOT require the MCP's AppleScript existence-guard, so they resolve notes AppleScript can't (trashed, or when Notes.app automation is slow/unavailable). Verified live: the MCP oracle failed `get-checklist-state` on a real note whose checklist apple-cli read correctly.
- **`sync_warning`** — a structured field on `search`/`list`/`folders` (the MCP's `withSyncAwareness` warning was text-only).
- **Write model (v2 — behaves like the MCP; see `docs/write-model-v2.md`)**: every write
  **EXECUTES when invoked**, exactly as calling the equivalent apple-notes-mcp tool does.
  `--dry-run` previews; `APPLE_DRY_RUN=1` restores dry-run-by-default globally. This replaced
  the v1 posture (dry-run default plus an `--execute` + `APPLE_TEST_MODE=1` gate), which had no
  oracle counterpart on ANY op: the shipped bundle `apple-notes-mcp/build/index.js` reads only
  `DEBUG`/`VERBOSE` from the environment, issues no elicitation, and runs `delete-note` straight
  through with no gate — its "requires explicit user confirmation" text is advisory prose to the
  calling model, not enforcement. So all 9 writes are bucket 3.
  - **The sandbox is opt-in**: `APPLE_TEST_MODE` truthy **or** `--test-mode`, either alone.
    Inside it, writes are confined to `apple-cli-test…`-labeled targets and `batch-*` verify
    EVERY id resolves to a labeled test note before touching anything. Refusals are
    `validation_error` / exit 64 (the Notes refusal type). Outside the sandbox none of this
    applies, per oracle parity. Sandboxed success envelopes carry `"sandbox": true`.
  - **Recoverability is PER-OP, measured, not assumed.** `delete` and `batch-delete` use
    `delete <noteRef>`; the note lands in Recently Deleted and stays findable there, so no
    operator-affordance env var is warranted. **`delete-folder` is different**: it cascades to
    every note in the folder and the cascade is PERMANENT (the notes do not reach Recently
    Deleted). It therefore keeps a **per-surface dry-run default** — it previews unless
    `--execute` is passed, the same shape Mail's trash surface uses. That is a knowing deviation
    from strict oracle parity (the oracle cascades on call), justified by the spec's own
    `APPLE_ALLOW_EMPTY_TRASH` rule: an op that irreversibly destroys an unbounded amount of
    unlabeled real data in ONE flagless invocation warrants a control the caller reaches for.
  - **Preview honesty**: the argv-computable label checks run on BOTH paths — `create` title,
    `update --new-title`, `create-folder`/`delete-folder` name, `batch-move` AND `move`
    destinations, and any `--title`-addressed target. Only `--id` addressing needs Automation to
    learn the target's title, and only there does a sandboxed preview disclose an unchecked gate.
  - `save-attachment` writes to the filesystem and honours `--dry-run` like any other write.
  - Input bounds mirror the MCP's zod limits (title ≤2000, content ≤5 MiB, folder ≤1000,
    account ≤200) and are checked BEFORE the write gate.
- **Hardening** (from the OMC review pass): gzip inflate clamps the attacker-controllable ISIZE to a 64 MiB cap (decompression-bomb defense); the attachment path guard adds a symlink-aware post-mkdir re-check; the protobuf checklist line-mapping counts UTF-16 code units (correct for emoji/non-BMP text, matching Apple's run lengths); SQLite PKs are bound positionally.

### Security posture
User data reaches `osascript` ONLY as argv (`on run argv` → `item N of argv`), never string-interpolated into script source (AppleScript injection is RCE-class; the reference interpolated with escaping — this port does not). SQLite is read-only + param-bound + column-allowlisted. Confirmed by the security-reviewer pass (0 Critical/High).

### Validated live vs. blocked
- **Validated against the live MCP oracle:** `get-metadata` (field-for-field match on multiple notes), `get-checklist` (protobuf decode on real ZDATA), `sync-status`.
- **Implemented + guarded + unit-tested but NOT exercised live:** all AppleScript ops (CRUD/folders/accounts/attachments/export/selection) — Notes.app automation timed out (`-1712`) on this large store during the build session, so live AppleScript testing is deferred to a machine where Notes.app scripting is responsive. The argv-safety, parsing, and guard logic are unit-tested.
