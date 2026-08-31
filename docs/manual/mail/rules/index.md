# apple mail rules

List and manage Mail rules.

## Synopsis

```
apple mail rules
```

## Subcommands

- [`create`](./create.md) — Create a rule (EXECUTES by default; --dry-run previews).
- [`delete`](./delete.md) — Delete a rule by index (irreversible; EXECUTES by default; --dry-run previews).
- [`disable`](./disable.md) — Disable a rule by index (EXECUTES by default; --dry-run previews).
- [`enable`](./enable.md) — Enable a rule by index (EXECUTES by default; --dry-run previews).
- [`list`](./list.md) — List Mail rules (1-based index, name, enabled).
- [`update`](./update.md) — Update a rule by index (patch; EXECUTES by default; --dry-run previews).

## Inherited options

- `-h`, `--help`
  <br>Show help information.
- `--version`
  <br>Show the version.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple mail`](../index.md)
