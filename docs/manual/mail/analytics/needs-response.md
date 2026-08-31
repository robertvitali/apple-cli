# apple mail analytics needs-response

Unread messages likely needing a reply (skips newsletters/noreply).

## Synopsis

```
apple mail analytics needs-response [flags]
```

## Options

- `--account` `<account>`
  <br>Account name or UUID.
- `--days` `<days>`
  <br>Look back this many days.
- `--mailbox` `<mailbox>`
  <br>Mailbox (default INBOX).
- `--max` `<max>`
  <br>Max results.

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

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple mail analytics`](./index.md)
