# apple mail templates

Manage email templates (list/get/save/delete/render).

## Synopsis

```
apple mail templates
```

## Subcommands

- [`delete`](./delete.md) — Delete a template (irreversible; EXECUTES by default; --dry-run previews).
- [`get`](./get.md) — Read a template by name.
- [`list`](./list.md) — List stored templates.
- [`render`](./render.md) — Render a template into ready-to-send subject + body.
- [`save`](./save.md) — Create or overwrite a template (EXECUTES by default; --dry-run previews).

## Inherited options

- `-h`, `--help`
  <br>Show help information.
- `--version`
  <br>Show the version.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple mail`](../index.md)
