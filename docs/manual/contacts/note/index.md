# apple contacts note

Read/write a contact's note (AppleScript; entitlement-gated field).

## Synopsis

```
apple contacts note
```

## Subcommands

- [`get`](./get.md) — Read a contact's note (AppleScript; needs :ABPerson-suffixed id). → read_note
- [`set`](./set.md) — Write/replace a contact's note, --clear empties it (EXECUTES; --dry-run previews). → write_note

## Inherited options

- `-h`, `--help`
  <br>Show help information.
- `--version`
  <br>Show the version.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple contacts`](../index.md)
