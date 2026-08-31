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

- [`calendar`](./calendar/index.md) — Calendar — events CRUD + calendars (EventKit; ports apple-events calendar half).
- [`contacts`](./contacts/index.md) — Contacts — CRUD, groups, vCard, notes, photos (ports apple-contacts-mcp).
- [`mail`](./mail/index.md) — Mail.app — send, search, rules, templates, analytics (union of both mail MCPs).
- [`messages`](./messages/index.md) — iMessage / SMS — send, read, search (ports mac_messages_mcp).
- [`notes`](./notes/index.md) — Notes — notes/folders/attachments/checklists/export (ports apple-notes-mcp).
- [`reminders`](./reminders/index.md) — Reminders — tasks/lists/subtasks (EventKit; ports apple-events reminders half).
- [`version`](./version.md) — Print version + JSON schema_version (for runtime capability detection).

## Options

- `-h`, `--help`
  <br>Show help information.
- `--version`
  <br>Show the version.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](./reference/json-contract.md) and [exit codes](./reference/exit-codes.md).
