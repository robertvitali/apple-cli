---
title: Notes
---

# apple notes

Notes — notes/folders/attachments/checklists/export (ports apple-notes-mcp).

## Synopsis

```
apple notes
```

## Subcommands

- [`accounts`](./accounts.md) — List Notes accounts (iCloud, Gmail, Exchange…) with default folder + upgraded flag.
- [`append`](./append.md) — Add to a note's body without replacing it. → append-to-note (EXECUTES; --dry-run previews).
Safety: reads the existing body, concatenates, then writes the WHOLE body back; that rewrite can drop embedded attachments, so run `notes attachments list` first if unsure.
- [`attachments`](./attachments.md) — List a note's attachments (name, content type, id), by --id or --title.
- [`batch-delete`](./batch-delete.md) — Delete multiple notes by id to Recently Deleted, ≤500 (EXECUTES; --dry-run previews).
- [`batch-move`](./batch-move.md) — Move multiple notes by id to one folder, ≤500 (EXECUTES; --dry-run previews).
- [`create`](./create.md) — Create a note, title prepended as <h1> (EXECUTES; --dry-run previews).
- [`create-folder`](./create-folder.md) — Create a folder, nested paths create intermediates (EXECUTES; --dry-run previews).
- [`default-location`](./default-location.md) — The default account + folder where Notes.app creates new notes.
- [`delete`](./delete.md) — Delete ONE note to Recently Deleted, by --id or --title (EXECUTES; --dry-run previews).
- [`delete-folder`](./delete-folder.md) — Delete a folder AND EVERY NOTE IN IT, permanently (previews by default; --execute performs it).
- [`doctor`](./doctor.md) — Detailed setup diagnostics (automation permission, accounts, Full Disk Access, binary signature).
- [`export`](./export.md) — Export the whole library. --format json (structured, default) | md | txt (curated extras).
- [`fetch-attachment`](./fetch-attachment.md) — Return one attachment's bytes inline as base64 (25 MB cap).
- [`folders`](./folders.md) — List all folders (with full nested paths) for an account.
- [`get`](./get.md) — Full HTML body of a note (by --id or --title) plus parsed hashtags.
- [`get-by-id`](./get-by-id.md) — Note metadata by id (id, title, dates, shared, password_protected).
- [`get-checklist`](./get-checklist.md) — Read a note's checklist items + done-state from NoteStore.sqlite (needs Full Disk Access).
- [`get-details`](./get-details.md) — Note metadata by title (adds account).
- [`get-link`](./get-link.md) — notes:// deep link for a note, by id (preferred) or title. → get-note-link
- [`get-markdown`](./get-markdown.md) — Note as Markdown, checklist items annotated [x]/[ ] when Full Disk Access is granted.
- [`get-metadata`](./get-metadata.md) — [BETA] Read note metadata AppleScript can't expose (pinned, snippet, flags) from NoteStore.sqlite.
- [`get-plaintext`](./get-plaintext.md) — Native plaintext body of a note (by --id or --title).
- [`health`](./health.md) — Quick pass/fail: Notes.app reachable + Full Disk Access for checklist features.
- [`list`](./list.md) — List note titles in an account/folder (supports --modified-since, --limit).
- [`move`](./move.md) — Move ONE note to a folder, by --id or --title (EXECUTES; --dry-run previews).
- [`save-attachment`](./save-attachment.md) — Write one attachment to disk, path must be under home/temp/Volumes (EXECUTES; --dry-run previews).
- [`search`](./search.md) — Search notes by title (or body with --content); returns id/title/folder.
- [`selected`](./selected.md) — Notes currently selected in the Notes.app UI.
- [`shared`](./shared.md) — Notes shared with collaborators (title, account, id).
- [`show-account`](./show-account.md) — Reveal an account in the Notes.app UI by id.
- [`show-attachment`](./show-attachment.md) — Reveal an attachment in the Notes.app UI.
- [`show-folder`](./show-folder.md) — Reveal a folder in the Notes.app UI by id.
- [`show-note`](./show-note.md) — Reveal a note in the Notes.app UI by id.
- [`stats`](./stats.md) — Library totals: per-account/folder counts + recent-activity, with partial-coverage flags.
- [`sync-status`](./sync-status.md) — Whether iCloud sync is in progress (pending count + seconds since last change).
- [`update`](./update.md) — REPLACE a note's body (and optional title), by --id or --title (EXECUTES; --dry-run previews).

## Inherited options

- `--dry-run`
  <br>Preview a write/destructive operation without performing it (always wins — over --execute, APPLE_DRY_RUN, and any surface default).
- `--execute`
  <br>Explicitly perform the write (write-model-v2 domains execute by default; this also overrides APPLE_DRY_RUN and any remaining dry-run defaults).
- `-h`, `--help`
  <br>Show help information.
- `--test-mode`
  <br>Engage the opt-in SANDBOX: writes restricted to apple-cli-test-labeled items and self-only allowlisted recipients (APPLE_TEST_RECIPIENTS). Domains not yet on write-model v2 additionally require it (with APPLE_TEST_MODE=1) for live writes.
- `--text`
  <br>Emit human-readable text instead of the default JSON output.
- `--version`
  <br>Show the version.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../reference/json-contract.md) and [exit codes](../reference/exit-codes.md).

## See also

- [`apple`](../index.md)
