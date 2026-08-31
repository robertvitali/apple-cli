# apple mail mailboxes

List and create mailboxes.

## Synopsis

```
apple mail mailboxes
```

## Subcommands

- [`create`](./create.md) — Create a mailbox/folder (EXECUTES by default; --dry-run previews; nested via '/').
- [`list`](./list.md) — List mailboxes (optionally for one account), with message counts.

## Inherited options

- `-h`, `--help`
  <br>Show help information.
- `--version`
  <br>Show the version.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple mail`](../index.md)
