# apple reminders subtasks

Reminder subtasks — read/create/update/delete/toggle/reorder (ports reminders_subtasks).

## Synopsis

```
apple reminders subtasks
```

## Subcommands

- [`create`](./create.md) — Add a subtask (executes on call, like the MCP; --dry-run previews).
- [`delete`](./delete.md) — Remove a subtask (executes on call, like the MCP; --dry-run previews).
- [`read`](./read.md) — List a reminder's subtasks + completion progress.
- [`reorder`](./reorder.md) — Reorder subtasks (executes on call, like the MCP; --dry-run previews).
- [`toggle`](./toggle.md) — Flip a subtask's completion (executes on call, like the MCP; --dry-run previews).
- [`update`](./update.md) — Update a subtask's title/completion (executes on call, like the MCP; --dry-run previews).

## Inherited options

- `-h`, `--help`
  <br>Show help information.
- `--version`
  <br>Show the version.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple reminders`](../index.md)
