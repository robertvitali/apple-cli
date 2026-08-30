# apple-cli — GUI-gap + new-domain research (2026-07-16)

7 parallel deep-dives: one per domain (CLI vs the macOS GUI app) + one scoping new CLIs.
Every domain is a **verified strict superset of its MCP** already; these gaps are all
*beyond* the MCP — GUI features a power user relies on. "Reachable" = a real automation
surface exists (chat.db/AppleScript/EventKit/SQLite); "framework-locked" = no public API.

## ⚠ One real bug surfaced (not a gap — a correctness defect)
**Messages `recent`/`search` return reaction/tapback pseudo-rows as if normal messages**
(bodies like `Loved "…"`), because the SQL lacks an `associated_message_type = 0` filter.
Pollutes output today; fixing reactions fixes this. Worth a fix regardless of roadmap.

## Per-domain — top REACHABLE gaps (most valuable first)
| domain | verdict vs GUI | top reachable gaps to add |
|---|---|---|
| **Messages** | ~half the GUI core | attachments (receive: `attachment` tables; send: AppleScript `--file`); list ALL conversations (only named groups today); per-chat threaded history; reactions/tapbacks (assoc-message rows); read receipts (cols already present) |
| **Mail** | near-complete superset | **full-text body search** (today `--body` scans only the index *preview* snippet — use Spotlight `mdfind`); junk/not-junk (sdef bool); signatures; redirect/bounce; custom-from alias send |
| **Contacts** | verified superset | bulk vCard export (`--all`/`--group`/`--search`); Me-card get (AppleScript `my card`); vCard note+photo export fidelity; duplicate-merge (app-layer) |
| **Notes** | verified superset | tag browser + `search --tag`/`list-tags` (headline feature, read-only today); bulk list enrichment (pinned/snippet/attachment badges); `rename-folder` (settable) |
| **Calendar** | superset | **calendar CRUD** (engine already built in EventKitCore — only the subcommands are missing!); `.ics` import/export; all-time event search (today limited to a 14-day window); travel-time |
| **Reminders** | complete superset | sort/group on read (unsorted today, client-side fix); smart-list presets (Today/Scheduled/Flagged) — *flag itself is EventKit-locked* |

**Framework-locked (document, don't chase):** Messages effects; Mail smart-mailboxes/VIP/snooze/undo-send;
Contacts smart-groups/link-unlink/account-mgmt; Notes pin/checklist-write/lock/collab; Calendar
invitations/RSVP/attendee-writes (EventKit read-only); Reminders native-flag/native-tags/sections/attachments.

> **Scope note.** The verdicts above rate the CLI against the **GUI app** (features beyond the MCP).
> They are NOT a claim of 100% MCP-union parity: "Mail — near-complete superset" refers to reads +
> the now-live write surface, but a few MCP-union *writes* remain preview-only (rules-update,
> attachments-save, HTML/attachment send, draft send/open, gmail-mode move). Those write-parity
> gaps are tracked authoritatively in `CHANGELOG.md` → "Known parity gaps (Mail)".

## New CLI domains to build next (verified on macOS 26)
| candidate | why | feasibility |
|---|---|---|
| **Shortcuts** (`/usr/bin/shortcuts`) | **force-multiplier** — the ONE clean bridge to every non-scriptable thing (Focus, Home, Weather, Stocks, timers, Maps directions) | 🟢 first-party CLI |
| **Music** | playback control + library/track queries — daily agent ops | 🟢 rich AppleScript dict |
| **Safari** | tabs/open-URL (AppleScript) + history.db/bookmarks.plist (SQLite, fits existing reader) | 🟢 read/open |
| **Photos** | find + export images, albums, metadata | 🟢 scriptable read/export |
| **Finder** | tags, reveal, current-selection, Trash-not-rm, eject (genuinely not-shellable) | 🟢 |
| System-settings CLI | appearance/dark-mode (`defaults`), Night Shift, volume, Wi-Fi (`networksetup`), power (`pmset`) — **but** most Ventura+ panes are NOT scriptable; route through Shortcuts | 🟡 mixed |

**Recommended next 3 domains:** Shortcuts (unlocks everything else), Music, Safari.
Not-scriptable / poor-feasibility (skip or Shortcuts-only): Podcasts, Voice Memos, News, Stocks,
Freeform, Home, Weather, Maps, FaceTime.
