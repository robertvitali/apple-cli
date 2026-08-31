# apple messages recent

Recent messages across ALL chats in the last N hours (optionally by contact).

## Synopsis

```
apple messages recent [flags]
```

## Description

Returns recent Messages rows with the same JSON envelope as the rest of the CLI. Each message includes `has_attachments` and an `attachments` array. Attachment paths are derived from chat.db metadata only: `filename` is the stored value, `path` is present only when an absolute standardized path can be derived, and `exists` is true or false only after a conservative local-root probe. When probing is skipped, `exists` is null.

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

## Examples

List recent messages with attachment metadata

```console
apple messages recent --hours 6 --limit 25
```

Filter to an explicit synthetic handle

```console
apple messages recent --handle +12125550100 --hours 24
```

## Notes

`messages recent` can include attachment-only messages that have no text body. Those rows use an empty `body` and carry the file details in `attachments`; a cache flag alone does not preserve a bodyless row when no joined attachment details exist. Attachment paths are not confined to the Messages attachments directory because sent items may point elsewhere on the local machine, but existence probing is limited to conservative local roots and uses symlink-aware traversal. Relative paths are omitted; automount and mounted-volume roots such as `/net`, `/home`, `/Network/Servers`, and `/Volumes` are reported without probing.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../reference/json-contract.md) and [exit codes](../reference/exit-codes.md).

## See also

- [`apple messages`](./index.md)
