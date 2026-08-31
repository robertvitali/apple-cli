# apple mail reply

Reply to a message by id or --subject (EXECUTES by default; --dry-run previews).

## Synopsis

```
apple mail reply [<id>] [flags]
```

## Options

- `<id>`
  <br>Message id to reply to (ROWID / RFC Message-ID); or use --subject.
- `--account` `<account>`
  <br>Account (name or UUID) — used for --subject lookup AND as the send-from identity.
- `--all`
  <br>Reply to all recipients.
- `--attach` `<attach>` *(repeatable)*
  <br>Attachment file path (repeatable).
- `--bcc` `<bcc>` *(repeatable)*
- `--body` `<body>`
- `--cc` `<cc>` *(repeatable)*
- `--gui-send`
  <br>Auto-send an --html reply THREADED via Mail's native reply verb + pasteboard paste (needs Accessibility, steals focus). Opt-in; without it --html --mode send opens an unthreaded .eml compose window.
- `--html` `<html>`
  <br>HTML reply body. Default opens a rendered compose window for review; add --gui-send to auto-send.
- `--mailbox` `<mailbox>`
  <br>Mailbox to scope the --subject lookup (default INBOX — oracle B searches only the inbox; use 'All' for the previous store-wide sweep).
- `--mode` `<mode>`
  <br>Delivery mode: send | draft | open.
- `--subject` `<subject>`
  <br>Reply to the newest message matching this subject keyword.

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
