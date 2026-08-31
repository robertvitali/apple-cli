# apple mail analytics stats

Volume/read-ratio/breakdown statistics.

## Synopsis

```
apple mail analytics stats [flags]
```

## Options

- `--account` `<account>`
  <br>Account name or UUID.
- `--days` `<days>`
  <br>Look back this many days (0 = all time). Ignored by mailbox_breakdown, which the oracle counts over all time; the response's days_back reports what was actually applied.
- `--include-system-folders`
  <br>Include Trash/Junk/Sent/Drafts/Spam in the totals (MCP B excludes them; CLI extra).
- `--mailbox` `<mailbox>`
  <br>Mailbox — mailbox_breakdown only (default INBOX; 'All' is a CLI extra spanning every mailbox). Ignored by account_overview/sender_stats, which always span the account as the oracle does.
- `--scope` `<scope>`
  <br>Scope: account_overview | sender_stats | mailbox_breakdown.
- `--sender` `<sender>`
  <br>Sender filter (for sender_stats).

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
