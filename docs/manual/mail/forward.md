# apple mail forward

Forward a message by id or --subject (EXECUTES by default; --dry-run previews).

## Synopsis

```
apple mail forward [<id>] [flags]
```

## Options

- `<id>`
  <br>Message id to forward; or use --subject.
- `--account` `<account>`
  <br>Account (name or UUID) — used for --subject lookup AND as the send-from identity.
- `--bcc` `<bcc>` *(repeatable)*
- `--body` `<body>`
  <br>Text to prepend before the forwarded content.
- `--cc` `<cc>` *(repeatable)*
- `--mailbox` `<mailbox>`
  <br>Mailbox to scope the --subject lookup (default INBOX — oracle B forward_email's default; use 'All' for a store-wide sweep).
- `--subject` `<subject>`
  <br>Forward the newest message matching this subject keyword.
- `--to` `<to>` *(repeatable)*
  <br>Recipient (repeatable).

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
