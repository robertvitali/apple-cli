# apple mail send

Compose an email (EXECUTES by default; --dry-run previews; plain/HTML/attachments; mode send|draft|open).

## Synopsis

```
apple mail send [flags]
```

## Options

- `--account` `<account>`
  <br>Sending account (name or UUID).
- `--attach` `<attach>` *(repeatable)*
  <br>Attachment file path (repeatable).
- `--bcc` `<bcc>` *(repeatable)*
  <br>BCC recipient (repeatable).
- `--body` `<body>`
  <br>Plain-text body (fallback when --html is set).
- `--cc` `<cc>` *(repeatable)*
  <br>CC recipient (repeatable).
- `--gui-send`
  <br>Auto-send an --html message via GUI keystroke automation (needs Accessibility, steals focus, fragile). Opt-in.
- `--html` `<html>`
  <br>HTML body. Default opens a rendered compose window for review (reliable); add --gui-send to auto-send.
- `--mode` `<mode>`
  <br>Delivery mode: send | draft | open.
- `--out` `<out>`
  <br>Write the generated .eml to this path (html/attachment sends).
- `--subject` `<subject>`
- `--to` `<to>` *(repeatable)*
  <br>Recipient (repeatable; comma-joined ok).

## Inherited options

- `--dry-run`
  <br>Preview a write/destructive operation without performing it (always wins — over --execute, APPLE_DRY_RUN, and any surface default).
- `--execute`
  <br>Explicitly perform the write (write-model-v2 domains execute by default; this also overrides APPLE_DRY_RUN and any remaining dry-run defaults).
- `-h`, `--help`
  <br>Show help information.
- `--test-mode`
  <br>Engage the opt-in SANDBOX: writes restricted to apple-cli-test-labeled items and self-only allowlisted recipients (APPLE_TEST_RECIPIENTS). Domains not yet on write-model v2 additionally require it (with APPLE_TEST_MODE=1) for live writes.
- `--text`
  <br>Emit human-readable text instead of the default JSON output.
- `--version`
  <br>Show the version.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../reference/json-contract.md) and [exit codes](../reference/exit-codes.md).

## See also

- [`apple mail`](./index.md)
