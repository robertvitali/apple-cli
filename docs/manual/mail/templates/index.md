# apple mail templates

Manage email templates (list/get/save/delete/render).

## Synopsis

```
apple mail templates
```

## Description

Templates are `*.md` text files, one per template, in `~/.apple-cli/mail-templates/`. Set `APPLE_MAIL_TEMPLATES_DIR` to use another folder: it names the template folder itself, so `save` and `delete` act directly on the `*.md` files in it, and it should be a folder used only for templates. A leading `~` follows the same rules as the CLI's other path settings: `~`, `~/…` and `~yourname/…` mean your home folder, any other `~` form is refused as a `validation_error` (exit 64), and any other relative value is under the working directory.

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
