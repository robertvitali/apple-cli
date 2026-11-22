# apple messages event-streams

Inspect and retire local Messages event journals.

## Synopsis

```
apple messages event-streams
```

## Subcommands

- [`list`](./list.md) — List local event streams and retention bounds.
- [`retire`](./retire.md) — Retire one exact local event stream.

## Inherited options

- `-h`, `--help`
  <br>Show help information.
- `--version`
  <br>Show the version.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple messages`](../index.md)
