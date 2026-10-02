---
title: Home
---

# Home

One CLI for Apple's native apps — Messages, Mail, Contacts, Notes, Calendar, Reminders.

## Synopsis

```
apple
```

## Subcommands

- [`calendar`](./calendar/index.md) — Calendar — events CRUD + calendars (EventKit).
- [`contacts`](./contacts/index.md) — Contacts — CRUD, groups, vCard, notes, photos.
- [`mail`](./mail/index.md) — Mail.app — send, search, rules, templates, analytics.
- [`messages`](./messages/index.md) — iMessage / SMS — send, read, search.
- [`notes`](./notes/index.md) — Notes — notes/folders/attachments/checklists/export.
- [`reminders`](./reminders/index.md) — Reminders — tasks/lists/subtasks (EventKit).
- [`version`](./version.md) — Print version + JSON schema_version (for runtime capability detection).

## Options

- `-h`, `--help`
  <br>Show help information.
- `--version`
  <br>Show the version.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](./reference/json-contract.md) and [exit codes](./reference/exit-codes.md).
