# apple mail export

Export messages to files (txt/html) for backup or analysis (EXECUTES by default; --dry-run previews).

## Synopsis

```
apple mail export [flags]
```

## Options

- `--account` `<account>`
  <br>Account name or UUID.
- `--dir` `<dir>`
  <br>Directory to save exports (default ~/Desktop).
- `--format` `<format>`
  <br>Format: txt or html.
- `--layout` `<layout>`
  <br>File layout: 'oracle' (default, oracle B's — single_email: <dir>/<subject>.<fmt>; entire_mailbox: <dir>/<mailbox>_export/<n>_<subject>.<fmt>, 1-based, '/' replaced by '-') or 'flat' (legacy CLI extra: <dir>/<id>-<subject:60>.<fmt>, collision-proof). NOTE: like the oracle, an existing file of the same name is OVERWRITTEN — the single_email name comes from the matched message's subject; pass --no-clobber to refuse instead.
- `--mailbox` `<mailbox>`
  <br>Mailbox to export from (default INBOX).
- `--max` `<max>`
  <br>Max messages for entire_mailbox (safety cap).
- `--no-clobber`
  <br>Refuse to overwrite an existing file (the oracle, and the default, overwrite silently — oracle parity).
- `--scope` `<scope>`
  <br>Scope: single_email (needs --subject) or entire_mailbox.
- `--subject` `<subject>`
  <br>Subject keyword (required for single_email).

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
