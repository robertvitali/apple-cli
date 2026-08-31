# apple reminders tasks

Reminder tasks — read/create/update/delete (ports reminders_tasks).

## Synopsis

```
apple reminders tasks
```

## Subcommands

- [`create`](./create.md) — Create a reminder (executes on call, like the MCP; --dry-run previews).
- [`delete`](./delete.md) — Delete a reminder (executes on call, like the MCP; --dry-run previews).
- [`read`](./read.md) — Read reminders (lists + reminders) with filters, or a single reminder by --id.
- [`update`](./update.md) — Update a reminder (executes on call, like the MCP; --dry-run previews).

## Inherited options

- `-h`, `--help`
  <br>Show help information.
- `--version`
  <br>Show the version.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple reminders`](../index.md)
