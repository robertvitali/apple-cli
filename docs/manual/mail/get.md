# apple mail get

Get one message by ROWID, RFC Message-ID, or message:// link.

## Synopsis

```
apple mail get <id> [flags]
```

## Options

- `<id>`
  <br>Message id (Envelope Index ROWID, RFC-5322 Message-ID, or message:// link).
- `--account` `<account>`
  <br>Scope the lookup to this account (name or UUID; MCP A account param). Rejects if the message is elsewhere.
- `--content`
  <br>Fetch the full body via Mail.app (slow AppleScript scan; default returns the indexed preview).
- `--headers-only`
  <br>Return headers/metadata only (skip recipients + preview).
- `--mailbox` `<mailbox>`
  <br>Scope the lookup to this mailbox (MCP A mailbox param). Rejects if the message is elsewhere.
- `--no-content`
  <br>Alias/compat: never fetch the full body (default behavior).

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
