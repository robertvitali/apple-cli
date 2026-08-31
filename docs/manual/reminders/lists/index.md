# apple reminders lists

Reminder lists — read/create/update/delete + color (ports reminders_lists).

## Synopsis

```
apple reminders lists
```

## Subcommands

- [`create`](./create.md) — Create a reminder list (executes on call, like the MCP; --dry-run previews).
- [`delete`](./delete.md) — Delete a reminder list AND its items (executes on call, like the MCP; --dry-run previews).
- [`read`](./read.md) — List all reminder lists (id/title/account/account_type/color/…).
- [`update`](./update.md) — Rename/recolor a reminder list (executes on call, like the MCP; --dry-run previews).

## Inherited options

- `-h`, `--help`
  <br>Show help information.
- `--version`
  <br>Show the version.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple reminders`](../index.md)
