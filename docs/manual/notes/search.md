# apple notes search

Search notes by title (or body with --content); returns id/title/folder.

## Synopsis

```
apple notes search <query> [flags]
```

## Options

- `<query>`
  <br>Search query.
- `--account` `<account>`
  <br>Account to search.
- `--all`
  <br>Return every match, no limit. CLI-only superset — the MCP always caps.
- `--content`
  <br>Search note bodies instead of titles.
- `--folder` `<folder>`
  <br>Limit search to a folder.
- `--limit` `<limit>`
  <br>Max results (default 50, like the MCP).
- `--modified-since` `<modified-since>`
  <br>ISO-8601 date filter.

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

- [`apple notes`](./index.md)
