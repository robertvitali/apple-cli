# apple reminders tasks update

Update a reminder (executes on call, like the MCP; --dry-run previews).

## Synopsis

```
apple reminders tasks update [flags]
```

## Options

- `--add-tag` `<add-tag>` *(repeatable)*
  <br>Add a tag (repeatable, merges with existing).
- `--alarm` `<alarm>` *(repeatable)*
  <br>Alarm spec (repeatable) — replaces ALL existing alarms.
- `--clear-alarms`
  <br>Remove all alarms.
- `--clear-due`
  <br>Clear the due date (conflicts with --due).
- `--clear-location-trigger`
  <br>Remove only location-trigger alarms.
- `--clear-recurrence`
  <br>Remove recurrence.
- `--clear-start`
  <br>Clear the start date (conflicts with --start).
- `--clear-tags`
  <br>Remove ALL tags (conflicts with --tag).
- `--completed`
  <br>Mark completed/uncompleted (--completed / --no-completed).
- `--completion-date` `<completion-date>`
  <br>Set the completion date/time.
- `--due` `<due>`
  <br>New due date.
- `--geo-lat` `<geo-lat>`
  <br>Location-trigger latitude (replaces the location alarm).
- `--geo-lon` `<geo-lon>`
  <br>Location-trigger longitude.
- `--geo-proximity` `<geo-proximity>`
  <br>Location-trigger proximity: enter|leave.
- `--geo-radius` `<geo-radius>`
  <br>Location-trigger radius (m, default 100).
- `--geo-title` `<geo-title>`
  <br>Location-trigger title.
- `--id` `<id>`
  <br>Reminder identifier (required).
- `--location` `<location>`
  <br>New plain-text location.
- `--no-completed`
  <br>Mark completed/uncompleted (--completed / --no-completed).
- `--note` `<note>`
  <br>New notes/body.
- `--priority` `<priority>`
  <br>Priority: 0|1|5|9 or none|high|medium|low.
- `--recurrence` `<recurrence>` *(repeatable)*
  <br>Recurrence spec (repeatable) — replaces existing rules.
- `--remove-tag` `<remove-tag>` *(repeatable)*
  <br>Remove a tag (repeatable).
- `--start` `<start>`
  <br>New start date.
- `--tag` `<tag>` *(repeatable)*
  <br>Replace ALL tags with these (repeatable).
- `--target-list` `<target-list>`
  <br>Move to this list (cross-list move; name or id).
- `--title` `<title>`
  <br>New title.
- `--url` `<url>`
  <br>New URL (empty string clears it).

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
