# apple reminders tasks create

Create a reminder (executes on call, like the MCP; --dry-run previews).

## Synopsis

```
apple reminders tasks create [flags]
```

## Options

- `--alarm` `<alarm>` *(repeatable)*
  <br>Alarm spec (repeatable): -15m|-2h|-1d, geo:lat,lon,…, or a date.
- `--completed`
  <br>Create it already completed.
- `--due` `<due>`
  <br>Due date.
- `--geo-lat` `<geo-lat>`
  <br>Location-trigger latitude.
- `--geo-lon` `<geo-lon>`
  <br>Location-trigger longitude.
- `--geo-proximity` `<geo-proximity>`
  <br>Location-trigger proximity: enter|leave (default enter).
- `--geo-radius` `<geo-radius>`
  <br>Location-trigger radius (m, default 100).
- `--geo-title` `<geo-title>`
  <br>Location-trigger title.
- `--location` `<location>`
  <br>Plain-text location (EKCalendarItem.location).
- `--note` `<note>`
  <br>Notes/body.
- `--priority` `<priority>`
  <br>Priority: 0|1|5|9 or none|high|medium|low.
- `--recurrence` `<recurrence>` *(repeatable)*
  <br>Recurrence spec (repeatable): freq=weekly;interval=2;byday=2,4;count=10.
- `--start` `<start>`
  <br>Start date.
- `--subtask` `<subtask>` *(repeatable)*
  <br>Initial subtask title (repeatable) — stored in the notes checklist.
- `--tag` `<tag>` *(repeatable)*
  <br>Tag (repeatable) — stored as [#tag] in notes.
- `--target-list` `<target-list>`
  <br>List to create in (name or id; default: default list).
- `--title` `<title>`
  <br>Reminder title (required).
- `--url` `<url>`
  <br>Associated URL.

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
