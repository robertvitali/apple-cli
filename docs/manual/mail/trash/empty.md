# apple mail trash empty

Empty an account's Trash (IRREVERSIBLE; dry-run by default; operator-gated — see --confirm).

## Synopsis

```
apple mail trash empty [flags]
```

## Options

- `--account` `<account>`
- `--confirm`
  <br>Required confirmation for the destructive empty (oracle `confirm_empty`).
- `--max` `<max>`
  <br>Safety cap on how many messages to erase (oracle `max_deletes`).
- `--trash-mailbox` `<trash-mailbox>`
  <br>Which trash mailbox to empty (required when the account has more than one non-empty).

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

- [`apple mail trash`](./index.md)
