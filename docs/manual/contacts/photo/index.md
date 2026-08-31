# apple contacts photo

Read/write a contact's photo.

## Synopsis

```
apple contacts photo
```

## Subcommands

- [`get`](./get.md) — Read a contact's photo (base64 + detected format). → read_photo
- [`set`](./set.md) — Set/clear a contact's photo, --file|--base64|--clear (EXECUTES; --dry-run previews). → write_photo

## Inherited options

- `-h`, `--help`
  <br>Show help information.
- `--version`
  <br>Show the version.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple contacts`](../index.md)
