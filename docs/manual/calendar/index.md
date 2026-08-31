---
title: Calendar
---

# apple calendar

Calendar — events CRUD + calendars (EventKit; ports apple-events calendar half).

## Synopsis

```
apple calendar
```

## Subcommands

- [`calendars`](./calendars/index.md) — Calendar collections (ports calendar_calendars).
- [`doctor`](./doctor.md) — Report EventKit (Calendar/Reminders) authorization + Full Disk Access.
- [`events`](./events/index.md) — Calendar events — read/create/update/delete (ports calendar_events).

## Inherited options

- `-h`, `--help`
  <br>Show help information.
- `--version`
  <br>Show the version.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../reference/json-contract.md) and [exit codes](../reference/exit-codes.md).

## See also

- [`apple`](../index.md)
