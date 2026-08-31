# apple mail attachments

List and save message attachments.

## Synopsis

```
apple mail attachments
```

## Subcommands

- [`list`](./list.md) — List attachments by message id or subject keyword.
- [`save`](./save.md) — Save attachments from a message to a directory or an exact path (EXECUTES by default; --dry-run previews).

## Inherited options

- `-h`, `--help`
  <br>Show help information.
- `--version`
  <br>Show the version.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple mail`](../index.md)
