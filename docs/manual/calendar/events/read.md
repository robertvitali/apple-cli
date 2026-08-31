# apple calendar events read

Read events in a window (default today … +14d) or a single event by --id.

## Synopsis

```
apple calendar events read [flags]
```

## Options

- `--account` `<account>`
  <br>Filter by account (source) name, e.g. iCloud.
- `--availability` `<availability>`
  <br>Filter by availability: busy|free|tentative|unavailable.
- `--calendar` `<calendar>`
  <br>Filter by calendar name or id.
- `--end` `<end>`
  <br>Window end.
- `--id` `<id>`
  <br>Read a single event by its identifier.
- `--search` `<search>`
  <br>Substring filter over title/notes/location.
- `--start` `<start>`
  <br>Window start (yyyy-MM-dd, 'yyyy-MM-dd HH:mm:ss', or ISO-8601).

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

- [`apple calendar events`](./index.md)
