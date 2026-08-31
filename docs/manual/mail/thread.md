# apple mail thread

All messages in a conversation — by message id (Apple conversation) or by subject keyword.

## Synopsis

```
apple mail thread [<id>] [flags]
```

## Options

- `<id>`
  <br>A message id in the thread (ROWID / RFC Message-ID / message:// link).
- `--account` `<account>`
  <br>Account name or UUID (for subject-based lookup).
- `--limit` `<limit>`
  <br>Max messages. Default: by id, the COMPLETE thread (oracle A get_thread is uncapped); by --subject, 50 (oracle B max_messages). 0 = the complete thread.
- `--mailbox` `<mailbox>`
  <br>Mailbox for subject-based lookup (default All).
- `--references`
  <br>Thread by RFC References/In-Reply-To headers (MCP A get_thread) instead of Apple's conversation grouping.
- `--subject` `<subject>`
  <br>Subject keyword identifying the thread.

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
