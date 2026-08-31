# apple calendar events

Calendar events — read/create/update/delete (ports calendar_events).

## Synopsis

```
apple calendar events
```

## Subcommands

- [`create`](./create.md) — Create an event (executes on call, like the MCP; --dry-run previews).
- [`delete`](./delete.md) — Delete an event (executes on call, like the MCP; --dry-run previews).
- [`read`](./read.md) — Read events in a window (default today … +14d) or a single event by --id.
- [`update`](./update.md) — Update an event (executes on call, like the MCP; --dry-run previews).

## Inherited options

- `-h`, `--help`
  <br>Show help information.
- `--version`
  <br>Show the version.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple calendar`](../index.md)
