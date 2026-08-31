# apple messages recent

Recent messages across ALL chats in the last N hours (optionally by contact).

## Synopsis

```
apple messages recent [flags]
```

## Options

- `--contact` `<contact>`
  <br>Filter by contact name, phone, or email.
- `--handle` `<handle>`
  <br>Explicit handle (phone/email) — stateless replacement for the MCP's contact:N.
- `--hours` `<hours>`
  <br>Hours to look back (default 24).
- `--limit` `<limit>`
  <br>Max messages (default 100).

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

- [`apple messages`](./index.md)
