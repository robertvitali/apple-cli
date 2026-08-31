# apple calendar events update

Update an event (executes on call, like the MCP; --dry-run previews).

## Synopsis

```
apple calendar events update [flags]
```

## Options

- `--alarm` `<alarm>` *(repeatable)*
  <br>Alarm (repeatable, replaces existing): 15m|2h|1d before, +15m after, geo:…, or a date.
- `--all-day`
  <br>Set/unset all-day (--all-day / --no-all-day).
- `--availability` `<availability>`
  <br>Availability: busy|free|tentative|unavailable.
- `--clear-alarms`
  <br>Remove all alarms.
- `--clear-recurrence`
  <br>Remove recurrence.
- `--clear-structured-location`
  <br>Remove the structured location.
- `--end` `<end>`
  <br>New end date.
- `--geo-lat` `<geo-lat>`
- `--geo-lon` `<geo-lon>`
- `--geo-radius` `<geo-radius>`
- `--geo-title` `<geo-title>`
- `--id` `<id>`
  <br>Event identifier (required).
- `--location` `<location>`
  <br>New location.
- `--no-all-day`
  <br>Set/unset all-day (--all-day / --no-all-day).
- `--note` `<note>`
  <br>New notes/body.
- `--recurrence` `<recurrence>` *(repeatable)*
  <br>Recurrence spec (repeatable) — replaces existing rules.
- `--span` `<span>`
  <br>Recurring-edit scope: this-event|future-events (default this-event).
- `--start` `<start>`
  <br>New start date.
- `--target-calendar` `<target-calendar>`
  <br>Move to this calendar (cross-calendar move).
- `--title` `<title>`
  <br>New title.
- `--url` `<url>`
  <br>New URL ('' clears; needs a scheme otherwise).

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
