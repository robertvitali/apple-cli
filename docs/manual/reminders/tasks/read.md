# apple reminders tasks read

Read reminders (lists + reminders) with filters, or a single reminder by --id.

## Synopsis

```
apple reminders tasks read [flags]
```

## Options

- `--due-within` `<due-within>`
  <br>Due-date window: today|tomorrow|this-week|overdue|no-date.
- `--filter-list` `<filter-list>`
  <br>Only reminders in this list (name or id).
- `--filter-location-based`
  <br>Only geofence/location-trigger reminders.
- `--filter-priority` `<filter-priority>`
  <br>Only this priority: high|medium|low|none.
- `--filter-recurring`
  <br>Only recurring reminders.
- `--filter-tag` `<filter-tag>` *(repeatable)*
  <br>Only reminders with ALL these tags (repeatable).
- `--id` `<id>`
  <br>Read a single reminder by its identifier.
- `--search` `<search>`
  <br>Substring filter over title/notes.
- `--show-completed`
  <br>Include completed reminders (default: hide them).

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

- [`apple reminders tasks`](./index.md)
