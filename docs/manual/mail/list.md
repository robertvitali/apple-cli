# apple mail list

List recent inbox messages.

## Synopsis

```
apple mail list [flags]
```

## Options

- `--account` `<account>`
  <br>Account name or UUID; omit for all accounts.
- `--content`
  <br>Include the indexed body preview (default on).
- `--limit` `<limit>`
  <br>Max messages across all accounts (default 50; 0 = all). See --limit-per-account for a per-account cap.
- `--limit-per-account` `<limit-per-account>`
  <br>Cap messages PER ACCOUNT (the cap counts inbox messages EXAMINED, so with --unread fewer rows than the cap can return; 0 = no per-account cap). Rows from all accounts are merged into one newest-first list (not grouped by account); the global --limit still applies, pass --limit 0 for all.
- `--no-content`
  <br>Include the indexed body preview (default on).
- `--unread`
  <br>Only unread messages.

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
