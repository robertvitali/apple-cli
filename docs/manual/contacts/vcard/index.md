# apple contacts vcard

Export/import contacts as vCard.

## Synopsis

```
apple contacts vcard
```

## Subcommands

- [`export`](./export.md) — Export contacts as one atomic vCard 3.0 payload. → export_vcard
- [`import`](./import.md) — Import contacts from vCard 3.0/4.0 text, atomic (EXECUTES; --dry-run previews). → import_vcard

## Inherited options

- `-h`, `--help`
  <br>Show help information.
- `--version`
  <br>Show the version.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple contacts`](../index.md)
