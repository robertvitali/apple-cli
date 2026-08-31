# apple mail analytics top-senders

Most frequent senders (or domains) in a mailbox.

## Synopsis

```
apple mail analytics top-senders [flags]
```

## Options

- `--account` `<account>`
  <br>Account name or UUID.
- `--by-domain`
  <br>Group by sender domain instead of address.
- `--days` `<days>`
  <br>Look back this many days (0 = all time).
- `--mailbox` `<mailbox>`
  <br>Mailbox (default INBOX; 'All' for every mailbox).
- `--top-n` `<top-n>`
  <br>How many top senders to return.

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
