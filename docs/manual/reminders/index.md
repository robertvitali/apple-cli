---
title: Reminders
---

# apple reminders

Reminders — tasks/lists/subtasks (EventKit; ports apple-events reminders half).

## Synopsis

```
apple reminders
```

## Subcommands

- [`doctor`](./doctor.md) — Report EventKit (Reminders/Calendar) authorization + Full Disk Access.
- [`lists`](./lists/index.md) — Reminder lists — read/create/update/delete + color (ports reminders_lists).
- [`subtasks`](./subtasks/index.md) — Reminder subtasks — read/create/update/delete/toggle/reorder (ports reminders_subtasks).
- [`tasks`](./tasks/index.md) — Reminder tasks — read/create/update/delete (ports reminders_tasks).

## Inherited options

- `-h`, `--help`
  <br>Show help information.
- `--version`
  <br>Show the version.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../reference/json-contract.md) and [exit codes](../reference/exit-codes.md).

## See also

- [`apple`](../index.md)
