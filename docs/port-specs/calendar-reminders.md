# MCP → CLI Porting Analysis: apple-events (Calendar + Reminders)

**Domain:** Apple Calendar AND Reminders (one MCP covers both)
**MCP under test:** `mcp-server-apple-events` — npm, registered via `npx -y mcp-server-apple-events` (effectively LATEST)
**Version analyzed:** **1.4.0** (current latest on npm; `npm view … version` = 1.4.0)
**Source repo:** https://github.com/FradSer/mcp-server-apple-events (author: Frad LEE / FradSer)
**License:** **MIT**
**Mechanism:** **EventKit** (native macOS), via a bundled Swift binary `EventKitCLI` compiled at install (`postinstall` → `swiftc … -framework EventKit`). The TS MCP layer shells out with an args array (`execFile`, no shell).

### HEADLINE FINDING — the port largely already exists as the same author's standalone CLI

The MCP's own backend is a **standalone, pure-Swift CLI named `event`** (github.com/FradSer/event, MIT, `brew tap FradSer/brew && brew install event`, **v0.5.0 / June 2026**, Swift 6.2, macOS 14+), vendored into the MCP as a git submodule at `vendor/event`. `event` is modular (libraries `EventModels`, `EventSync` + `event` executable), reads the **full** MCP data model (alarms, recurrenceRules, attendees, availability, structuredLocation, locationTrigger), outputs **JSON + Markdown**, ships an "Agent Skill", and adds a **cross-device Cloudflare-D1/SQLite encrypted Sync** feature the MCP has no equivalent of. **It is the natural fork-base / adopt-target** — see verdict.

The published npm 1.4.0 tarball still *inlines* an older `--action <verb>`-style `EventKitCLI.swift` with the mature full write surface; the newer standalone `event` uses a cleaner `event <noun> <verb>` ArgumentParser interface but, at v0.5.0, exposes a **subset** of write flags (details below). So the capability delta to a full drop-in is a modest, well-scoped set of command-layer write-flags — the Swift models/backends already exist.

### Architecture that matters for porting (the MCP's own layering)

1. **Swift EventKit layer** (`EventKitCLI.swift` in the npm build / `event` standalone) — raw EventKit CRUD (events, reminders, lists), alarms, recurrence, structuredLocation, geofence, availability, span, timezone handling.
2. **TypeScript synthesis layer** (MCP-only, faked on the reminder **notes field**):
   - **Subtasks** (`subtaskUtils.ts`): a `---SUBTASKS---` block in notes, `[ ] {8-hex-id} title`; all 6 ops (read/create/update/delete/toggle/reorder) are notes-string edits. **NOT native EventKit.**
   - **Tags** (`tagUtils.ts`): `[#tag]` markers in notes. **NOT native.**
   - **Client-side filters** (filterPriority/filterTags/filterRecurring/filterLocationBased/dueWithin) + priority word↔int (0/1/5/9) + URL-in-notes mirroring + SSRF URL validation.
   > Note: the standalone `event` instead uses **native** tags/URL and **native parent/child subtasks (via Apple Shortcuts)** — arguably higher-fidelity, but NOT byte-compatible with the MCP's notes-field storage. A port must pick one model (see §6).

---

## 1. MCP capability manifest

5 tools (multiplexed by `action`), plus 4 MCP *prompt* templates (scaffolding). Class: **CORE** = fundamental CRUD; **DERIVED** = filter/enrichment on CORE; **DIAGNOSTIC** = scaffolding.

### `reminders_tasks` (read | create | update | delete)

| Sub-op | Class | Key params | Behavior |
|---|---|---|---|
| read | CORE | `id?`, `filterList`, `showCompleted`(def false), `search`, `dueWithin`(today/tomorrow/this-week/overdue/no-date), `filterPriority`, `filterRecurring`, `filterLocationBased`, `filterTags[]` | Native filters (list/completed/search/dueWithin) in Swift; priority/tags/recurring/location filters in TS. |
| create | CORE | `title`(req), `startDate`, `dueDate`, `note`, `location`, `url`, `completed`, `priority`(0/1/5/9), `alarms[]`, `recurrence`\|`recurrenceRules[]`, `locationTrigger`, `tags[]`, `subtasks[]`, `targetList` | Full create. |
| update | CORE | `id`(req)+create fields + `completionDate`, `addTags[]`, `removeTags[]`, `clearAlarms`, `clearRecurrence`, `clearLocationTrigger` | `targetList` = cross-list move. |
| delete | CORE | `id`(req) | — |

Write fields: title, startDate, dueDate, completionDate, note, location(text), url, completed, priority(0/1/5/9), alarms(exactly one of relativeOffset|absoluteDate|geofence{title,lat,lon,radius,proximity enter/leave}), recurrence(freq daily/weekly/monthly/yearly, interval, endDate, occurrenceCount, daysOfWeek[1–7], daysOfMonth[1–31], monthsOfYear[1–12]), locationTrigger(geofence), tags, subtasks, targetList.

### `reminders_lists` (read | create | update | delete)
CORE. `name`, `newName`, `color`(#RRGGBB). Create/rename/**recolor**/delete lists.

### `reminders_subtasks` (read | create | update | delete | toggle | reorder)
CORE. `reminderId`(req), `subtaskId`(hex), `title`, `completed`, `order[]`. 6 ops, all notes-field string manipulation.

### `calendar_events` (read | create | update | delete)

| Sub-op | Class | Key params | Behavior |
|---|---|---|---|
| read | CORE | `id?`, `filterCalendar`, `filterAccount`, `search`, `availability`, `startDate`, `endDate` | ±14d default window. Returns calendars+events (event JSON incl. organizer/attendees/status — READ-only). ORACLE BUG, not ported (Q12 [8], measured 2026-08-17 during CAL-08): oracle filterAccount naming a KNOWN source with NO event calendars silently returns the FULL unfiltered window (its calendar-set filters to [] → predicate over all calendars). The CLI matches the oracle's fail-loud on an UNKNOWN account (both throw not_found naming the known accounts — EventKitCLI.swift:925-929) and diverges ONLY on the known-but-event-less case, returning an honestly-empty set rather than the full window. Deliberate: reproducing the bug would hand back exactly the events the caller asked to exclude. WIRE (Q12 batch A, BREAKING, both measured on the installed oracle): recurrence `end_date` renders the oracle's bare LOCAL `yyyy-MM-dd` (shared RecurrenceRule — applies to events AND reminders payloads); `structured_location.radius` is OMITTED when not positive (previously a spurious 0), preview and execute agreeing. |
| create | CORE | `title`,`startDate`,`endDate`(req)+`note`,`location`,`structuredLocation`{title,lat,lon,radius},`url`,`isAllDay`,`availability`(busy/free/tentative/unavailable),`alarms[]`,`recurrenceRules[]`,`targetCalendar` | Writes alarms/recurrence/structuredLocation/availability/isAllDay (confirmed in Swift `createEvent`). |
| update | CORE | `id`+create fields+`structuredLocation:null`,`clearAlarms`,`clearRecurrence`,`span`(this-event/future-events),`targetCalendar`(cross-cal move) | — |
| delete | CORE | `id`, `span?` | — |

Attendees/organizer/status = **READ-only** (EventKit cannot write attendees).

### `calendar_calendars` (read)
CORE. All event calendars (id/title/account/accountType).

### MCP prompts (DIAGNOSTIC, not tools)
`daily-task-organizer`, `smart-reminder-creator`, `reminder-review-assistant`, `weekly-planning-workflow` — LLM templates. No port surface.

---

## 2. CLI capability manifest per candidate

### ★ F. FradSer/event — EventKit · Swift 6.2 · MIT · v0.5.0 (Jun 2026) · brew `FradSer/brew` · JSON+Markdown *(THE pivotal candidate — the MCP's own backend; source read directly)*
Modular: `EventModels` (models: Reminder, CalendarEvent, ReminderList, RecurrenceRule, Alarm, LocationTrigger, Participant — models READ the full surface incl. attendees/availability/recurrence/alarms), `EventSync` (Cloudflare D1 + SQLite + encryption; Linux sync service), `event` exe.
- **`event reminders list` [--list --completed --json]**; **search** [--keyword --list --completed --json]; **create** [--title --list --due --priority(0-9) --notes --url --tags(csv, **native**) --parent(subtask via Shortcuts) --flagged --location-name/--location-latitude/--location-longitude/--location-radius/--location-trigger(enter|leave) --no-shortcut --json]; **update** [--id --title --completed --priority --due --clear-due --start --clear-start --notes --tags --url --parent --flagged --location-* --clear-location --no-shortcut --json]; **delete** [--id]; **lists** list|create(--name)|update(--id --name)|delete(--id).
- **`event calendar list` [--start --end --calendar --json]**; **create** [--title --start --end --calendar --location --notes --json] (all-day inferred from `yyyy-MM-dd` vs timed format); **update** [--id --title --start --end --location --notes --json]; **delete** [--id --span this|future|all].
- **`event sync`** / `sync push --type all|calendar|reminders` / `sync pull` (encrypted cross-device — EXTRA).
- **Confirmed GAPS vs MCP (write command-layer only; models already read these):** reminders — no recurrence SET flag, no time/absolute alarm SET (geofence only), no completionDate SET (only `--completed` bool), no cross-list move on update, **no list color** (`createList(color:nil)` hardcoded), no dueWithin/priority/tags/recurring/location read filters (has keyword search), startDate only on update (not create); **subtasks = single `--parent` linkage (native, via Shortcuts), NOT the MCP's 6 explicit subtask ops**; tags replace-only (no add/remove granularity). Calendar — create/update expose only title/start/end/calendar/location/notes: **missing url/availability/alarms/recurrence/structuredLocation SET, cross-calendar move**; list-events missing `--account`/`--search`/`--availability` filters; **no `calendars` collection-listing** command (`calendar list` = events). Delete `--span this|future|all` is a SUPERSET of the MCP.

### A. schappim/ekctl — EventKit · Swift · MIT · macOS 13+ · JSON/CSV/text *(source/README read)*
Both domains. Events: `add/update/delete event` (--title/--start/--end/--location/--notes/--alarms MINUTES/--recurrence-frequency/--recurrence-days/--recurrence-end-count/--travel-time; update adds --availability/--url); `list events --calendar --from --to [--search --availability]`; `today/tomorrow/next`; calendar-collection `list calendars`, `calendar create/update/delete --color`, `alias`. Reminders: `list/show/add/update/complete/delete reminder` (--list/--title/--due/--priority(0/1/5/9)/--notes/--completed).
- **Explicit NON-support (its README):** structured/geo location; geofence reminder triggers; absolute/location alarms (relative-minutes only); FULL recurrence (only freq+days+end-count); span (this vs future); post-create cross-calendar move; reminder list create/rename/delete/color; tags; subtasks; reminder url/location/startDate/alarms/recurrence/cross-list-move.

### B. keith/reminders-cli — EventKit · Swift · MIT · ~892★ · mature
Reminders ONLY, no Calendar. `show-lists`, `show`, `show-all`, `add`, `complete`, `uncomplete`, `delete`, `edit`, `new-list`; flags `--due-date`(NL), `--priority`, `--notes`, `--only-completed`, `--include-overdue`, `--format json|plain`, `--sort`. NO subtasks/tags/recurrence/geofence/alarms/url/cross-list-move/list-rename-delete-color; no Calendar.

### C. AungMyoKyaw/apple-reminders-cli — EventKit · Swift · Reminders-only *(README/source read)*
`reminder list/create/update/complete/delete/search/show/stats`. Has priority/due/notes/complete/delete + search filters (--tag/--priority/--completed/--completed-after/before). **Repo tagline claims subtasks/recurring/location, but the README command reference shows NO commands/flags for them → subtasks=NO, recurrence=NO, geofence=NO, alarms=NO.** Tags = inline title `#hashtag` (not `[#tag]`-in-notes; no add/remove). `update` thin (priority+due only). No list create/rename/delete/color. No Calendar.

### Read-only (auto-disqualified — MCP does full CRUD)
- **itspriddle/ical-guy** — Swift 6 · MIT · macOS 14 · v0.13.0 (Apr 2026), ACTIVE. Rich read/query of events+reminders (`events`, `reminders`, `calendars`, `meeting`, `conflicts`, `free`, `birthdays`), JSON. **Read-only** (icalBuddy successor). Good READ/query donor; no writes.
- **icalBuddy** (ali-rantakari + icalBuddy64 forks) — Objective-C, read-only display, no JSON, upstream abandoned ~2014.
- **zigotica/macos-calendar-events** — Swift/EventKit, `calendar_events [days]`, events-only read, 6★.

### Alternative (not a pure CLI)
- **PsychQuant/che-ical-mcp** — a competing *MCP* (different author) with a `--cli` mode, 29 tools, Developer-ID-signed+notarized; feature superset (events+reminders CRUD, recurring, **batch ops, conflict & duplicate detection, undo/redo**, #tags, per-event timezone, `--self-update`). Notable feature-DONOR / alternative, but adopting a rival MCP's CLI mode doesn't serve the "own, versioned, single-source CLI" goal like forking same-author `event` does.

---

## 3. CAPABILITY MATRIX

Cell vs MCP capability = EXACT / PARTIAL(gap) / MISSING. Columns: the 4 write-capable candidates. Read-only tools (ical-guy, icalBuddy, zigotica) = MISSING on every write row (auto-disqualified); che-ical-mcp is an MCP (excluded from CLI matrix).

### 3a. CALENDAR

| MCP capability | **event** | ekctl | keith | AungMyoKyaw |
|---|---|---|---|---|
| List calendar collections (calendar_calendars) | MISSING | EXACT | MISSING | MISSING |
| Read events (date-range) | EXACT | EXACT | MISSING | MISSING |
| — filter by calendar | EXACT | EXACT | — | — |
| — filter by account | MISSING | MISSING | — | — |
| — search / availability filter | MISSING | EXACT | — | — |
| Create event (title/start/end) | EXACT | EXACT | MISSING | MISSING |
| — note / location(text) | EXACT | EXACT | — | — |
| — isAllDay | EXACT (inferred) | MISSING | — | — |
| — url | MISSING | MISSING (upd only) | — | — |
| — availability | MISSING | PARTIAL (upd only) | — | — |
| — structuredLocation (geo) | MISSING | MISSING | — | — |
| — alarms (relative) | MISSING | PARTIAL | — | — |
| — alarms (absolute/geofence) | MISSING | MISSING | — | — |
| — recurrence (full RRULE) | MISSING | PARTIAL | — | — |
| Update event | PARTIAL | PARTIAL | MISSING | MISSING |
| — span this/future | EXACT+ (this/future/all) | MISSING | — | — |
| — cross-calendar move | MISSING | MISSING | — | — |
| Delete event (+span) | EXACT+ | PARTIAL (no span) | MISSING | MISSING |
| Read attendees/organizer/status | PARTIAL (modeled; read) | MISSING | — | — |

**Calendar:** `event` reads events well and does basic create/update/delete + best-in-class delete span, but its event **write** surface omits url/availability/alarms/recurrence/structuredLocation/cross-calendar-move + account/search/availability read-filters + collection-listing. ekctl is broader on some (availability/recurrence-lite/collections) but gapped elsewhere. **No 100% superset.**

### 3b. REMINDERS

| MCP capability | **event** | ekctl | keith | AungMyoKyaw |
|---|---|---|---|---|
| List reminders (by list) | EXACT | EXACT | EXACT | EXACT |
| — completed/search filter | EXACT | EXACT | PARTIAL | EXACT |
| — dueWithin filter | MISSING | MISSING | PARTIAL | MISSING |
| — priority/tags/recurring/location filter | MISSING | MISSING | MISSING | PARTIAL |
| Create reminder | PARTIAL | PARTIAL | PARTIAL | PARTIAL |
| — due date | EXACT | EXACT | EXACT | EXACT |
| — start date | PARTIAL (update only) | MISSING | MISSING | MISSING |
| — priority (0/1/5/9) | EXACT | EXACT | PARTIAL | EXACT |
| — notes | EXACT | EXACT | EXACT | EXACT |
| — url | EXACT | MISSING | MISSING | MISSING |
| — location (text) | PARTIAL (geofence name) | MISSING | MISSING | MISSING |
| — geofence/location trigger | EXACT | MISSING | MISSING | MISSING |
| — time/absolute alarms | MISSING | MISSING | MISSING | MISSING |
| — recurrence | MISSING (modeled, no SET flag) | MISSING | MISSING | MISSING |
| — tags | PARTIAL (native, replace-only) | MISSING | MISSING | PARTIAL (title #tag) |
| — subtasks | PARTIAL (native --parent, no 6-ops) | MISSING | MISSING | MISSING |
| Update/edit reminder | PARTIAL | PARTIAL | PARTIAL | PARTIAL (pri+due) |
| — completionDate set | MISSING | MISSING | MISSING | MISSING |
| — cross-list move | MISSING | MISSING | MISSING | MISSING |
| Complete / uncomplete | PARTIAL (via --completed bool) | PARTIAL (complete) | EXACT | PARTIAL (complete) |
| Delete reminder | EXACT | EXACT | EXACT | EXACT |
| **Subtasks 6 ops** (read/create/update/delete/toggle/reorder) | PARTIAL (create-as-child only) | MISSING | MISSING | MISSING |
| Lists: read | EXACT | EXACT | EXACT | PARTIAL |
| Lists: create | EXACT | MISSING | PARTIAL | MISSING |
| Lists: rename | EXACT | MISSING | MISSING | MISSING |
| Lists: delete | EXACT | MISSING | MISSING | MISSING |
| Lists: set color | MISSING | MISSING | MISSING | MISSING |

**Reminders:** `event` is by far the closest — native tags, geofence, url, list CRUD, most fields — but lacks recurrence-SET, time-alarms, completionDate, cross-list-move, list-color, rich read-filters, and models subtasks as a single native `--parent` link rather than the MCP's 6 explicit subtask ops. **No 100% superset.**

---

## 4. VERDICT

### CALENDAR → **BUILD** (by forking/extending `FradSer/event`)
No CLI is a strict superset. `event` (same author, the MCP's own engine) is the right base but its event **write** surface is currently a subset (missing url/availability/alarms/recurrence/structuredLocation set, cross-calendar move, account/search/availability read-filters, and calendar-collection listing). ekctl covers a different partial subset. Read-only tools auto-disqualified. → BUILD.

### REMINDERS → **BUILD** (by forking/extending `FradSer/event`)
No CLI is a strict superset. `event` is closest (native tags/geofence/url/list-CRUD/most fields) but lacks recurrence-set, time-alarms, completionDate, cross-list-move, list-color, and the MCP's 6 subtask ops (it uses a single native `--parent`). No other candidate is closer. → BUILD.

**Strategic framing (important):** this is a *near-adopt*. `event` is same-author, MIT, actively developed (v0.5.0), brew-installable, single-binary spanning both domains, and its Swift **models/backends already read the entire MCP surface** — the gap is a well-scoped set of **command-layer write flags**. The cheapest, longevity-aligned path is to **fork `event` (or contribute the missing flags upstream)** rather than greenfield or forking the frozen `EventKitCLI.swift`. If `event` closes these gaps (plausible in 1–2 focused releases), the verdict flips to **ADOPT**.

**Single-binary target:** one binary covering calendar+reminders (as both the MCP and `event` already are) → trivial cross-CLI parity (Claude/Codex/agy each shell out; `event` already ships an Agent Skill).

---

## 5. EXTRAS INVENTORY

**Worth including (already in `event` — free on fork):**
- **Cross-device Sync** (Cloudflare D1 + SQLite + AES encryption; Linux sync service) — big differentiator; keep if desired, or gate behind a subcommand (out of MCP-parity scope but low cost to retain).
- **Markdown output** alongside JSON.
- **`flagged`** reminder support.
- **Native tags + native parent/subtask via Shortcuts** — higher fidelity than the MCP's notes-field hack.
- **delete `--span this|future|all`** (superset of MCP's this/future).
- Reusable library split (`EventModels`, `EventSync`) — good for embedding.

**Worth including (from ekctl — feature donor):** `today`/`tomorrow`/`next` convenience event queries; `--travel-time` (EKEvent.travelTime); calendar-ID `alias`; csv/text output.

**Worth including (from che-ical-mcp — donor ideas):** conflict/duplicate detection, batch ops, `--self-update`, Developer-ID signing + notarization (matters for TCC/Gatekeeper on a distributed binary).

**Worth including (from ical-guy — donor):** rich read/query (`conflicts`, `free`, `meeting`-URL detection, `birthdays`).

**Noise (skip):** icalBuddy human-format text; the 4 MCP prompt templates (LLM scaffolding); AungMyoKyaw's inline-hashtag tags (inferior to native).

---

## 6. PORT SPEC (BUILD — single binary, both domains, fork of `FradSer/event`)

**Fork-base:** **`FradSer/event`** (MIT, Swift 6.2, modular, brew tap, actively developed, JSON+Markdown, already the MCP's engine). NOT the frozen inlined `EventKitCLI.swift`. Secondary donors: ekctl (travel-time, today/next, aliases), che-ical-mcp (conflict/dup detection, notarization), ical-guy (query commands).

**Language / mechanism:** Swift + EventKit (unchanged). Keep ArgumentParser subcommand UX + native tags/Shortcuts-subtasks.

**Command surface = `event` today + the parity delta below** (models already exist; mostly wiring @Option flags into create/update + a couple of new subcommands):
- **Reminders write flags to ADD:** `--recurrence`(freq/interval/end/count/daysOfWeek/daysOfMonth/monthsOfYear — RecurrenceRule model already exists), `--alarms`(relative + absolute — Alarm model exists), `--completion-date`, `--list` on `update` (cross-list move), `lists create/update --color` (unhardcode `color:nil`), read filters `--due-within/--priority/--tags/--recurring/--location-based`, `--start` on `create`.
- **Reminders subtask decision (the one real design fork):** either (a) KEEP `event`'s superior **native `--parent`** model and add read/toggle/reorder/detach subcommands for parity of *operations* (recommended — native, not notes-pollution), OR (b) additionally implement the MCP's **notes-field `---SUBTASKS---` 6-ops** if byte-compatibility with existing MCP-created data is required. Since the goal is to REPLACE the MCP, (a) is preferred; note explicitly it is NOT a drop-in of the MCP's notes storage.
- **Calendar write flags to ADD:** event create/update `--url/--availability/--alarms/--recurrence/--structured-location(geo)/--target-calendar(cross-move)/--clear-alarms/--clear-recurrence`; list-events `--account/--search/--availability`; add a **`calendars list`** (collections) subcommand. Keep existing delete `--span` (already superset).
- **Preserve:** permission preflight + embedded Info.plist usage strings (TCC dialog); tags-native; sync (optional).

**Build cost:** **S–M** (smaller than a from-scratch or `EventKitCLI.swift` fork). ~70–80% of the surface + ALL models/backends already exist; the delta is ≈a dozen create/update write-flags wired to already-modeled fields, one `calendars list` command, list-color unhardcoding, and the subtask-ops decision. **Hard parts:** (1) subtask model reconciliation (native-parent-via-Shortcuts vs MCP notes-field 6-ops — a design call + the Shortcuts dependency's reliability); (2) deciding whether to carry/retire the Cloudflare Sync subsystem; (3) date/timezone + all-day-inference parity; (4) Developer-ID signing/notarization for fleet distribution (borrow che-ical-mcp's approach). Attendee-write is intentionally out of scope (EventKit can't).

**Why not L/XL:** we are not writing an EventKit engine or even a new CLI skeleton — we extend a same-author MIT CLI whose models already read everything, adding the missing write flags.

---

## 7. Sources

- **MCP source** (npm tarball `mcp-server-apple-events@1.4.0`, read locally): `package.json`, `src/tools/definitions.ts`, `src/validation/schemas.ts`, `src/swift/EventKitCLI.swift` (1619 lines: `main()` arg surface + create/update event/reminder), `src/utils/subtaskUtils.ts`, `src/utils/tagUtils.ts`, `src/utils/cliExecutor.ts`, `scripts/build-swift.mjs`, `LICENSE` (MIT). `npm view` → v1.4.0, github.com/FradSer/mcp-server-apple-events.
- **FradSer/event** (github tarball read locally): `Package.swift`, `Sources/event/Commands/{ReminderCommands,CalendarCommands,ListCommands}.swift` (exact @Option/@Flag surface), `Sources/EventModels/Models/{Reminder,CalendarEvent}.swift` (read-surface incl. attendees/availability/recurrence/alarms), `Sources/EventSync/*` (Cloudflare/SQLite sync). MCP `.gitmodules` → `vendor/event` = https://github.com/FradSer/event.git. v0.5.0, MIT, brew `FradSer/brew`.
- **schappim/ekctl** — https://github.com/schappim/ekctl (README command reference + explicit unsupported list; EventKit/Swift/MIT).
- **keith/reminders-cli** — https://github.com/keith/reminders-cli.
- **AungMyoKyaw/apple-reminders-cli** — https://github.com/AungMyoKyaw/apple-reminders-cli (README command reference; subtasks/recurrence/geofence claimed in tagline, absent from commands).
- **itspriddle/ical-guy** — https://github.com/itspriddle/ical-guy (read-only, v0.13.0, MIT).
- **PsychQuant/che-ical-mcp** — https://github.com/PsychQuant/che-ical-mcp (rival MCP w/ --cli mode; feature-donor).
- icalBuddy (ali-rantakari + icalBuddy64 forks), zigotica/macos-calendar-events — read-only.

> **Verdict robustness:** both = **BUILD**, single binary, **fork-base `FradSer/event`**. No candidate is a verified 100% superset today (`event` is closest — a near-adopt with a scoped write-flag delta; ekctl/keith/AungMyoKyaw are further; read-only tools auto-disqualified). If `event` lands the missing write flags, re-evaluate as **ADOPT**.

### Write model (v2 — behaves like the MCP; see `docs/write-model-v2.md`)

All 14 writes across both halves — Calendar's `events create/update/delete` and Reminders'
`lists`/`tasks`/`subtasks` ops — **EXECUTE when invoked**, exactly as calling the equivalent
`calendar_events` / `reminders_*` action does. `--dry-run` previews; `APPLE_DRY_RUN=1` restores
dry-run-by-default globally. This replaced the v1 posture (dry-run default plus an `--execute` +
`APPLE_TEST_MODE=1` two-factor gate), which had no oracle counterpart on ANY op.

**Oracle evidence.** Unlike the Notes package, this one ships both `src/` (58 `.ts` files) and
`dist/`; both were confirmed non-empty before any negative was believed. The only runtime
`process.env` reads in non-test sources are `NODE_ENV`, `DEBUG` and `SWIFT_BINARY_HASH`
(`utils/errorHandling.ts`, `utils/projectUtils.ts`, `utils/binaryValidator.ts`) — none of them a
write gate. `tools/index.ts` is a pure action→handler router; the repositories shell straight to
the Swift binary (`deleteEvent` → `executeCli(['--action','delete-event','--id',id])`); and
`src/swift/EventKitCLI.swift` (1619 lines) reads no environment and self-gates nothing.

- **The sandbox is opt-in**: `APPLE_TEST_MODE` truthy **or** `--test-mode`, either alone. Inside
  it, writes stay confined to `apple-cli-test…`-labeled events, reminders and lists; refusals are
  `validation_error` / exit 64 (the Calendar/Reminders refusal type, not Mail/Contacts' 77).
  Outside the sandbox none of it applies, per oracle parity. Sandboxed success envelopes carry
  `"sandbox": true`.
- **Destinations are checked, not just subjects**: `--target-list` (tasks create/update) and
  `--new-name` (lists update) must also be labeled inside the sandbox — creating a labeled item
  inside a REAL list still modifies real user data.
- **Deferred checks are disclosed**: an item's EXISTING title is not argv-computable, so on any
  by-id update/delete — and on all five subtask ops, which are addressed by parent reminder id —
  the sandbox label check can only run after the fetch, i.e. on the execute path. Those previews
  emit `sandbox_target_unchecked: true` rather than letting a silent non-refusal read as approval.

**The oracle's input-validation layer is deliberately NOT mirrored** (`src/validation/schemas.ts`:
`SafeIdSchema.min(1)`, `RequiredListNameSchema.min(1)`, title/note/location length caps, a
printable-Unicode charset, an SSRF URL blocklist). A strict superset must ACCEPT everything the
oracle accepts; accepting more is valid. There is no injection or SSRF sink on this path — writes
go to EventKit, never AppleScript/shell/SQL, and a stored URL is never dereferenced. Crucially,
this is not the class of bug the Notes flip hit: EventKit is id-based, so `event(withIdentifier:
"")` / `reminder(withIdentifier: "")` return nil → `not_found` and `calendar(matching: "")` matches
only a literally-empty title. There is no analogue of Notes' empty folder specifier collapsing to
a bare `delete` bound to the account container. See `RemindersSupport.swift:35-42`.
