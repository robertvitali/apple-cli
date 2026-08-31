# apple calendar events create

Create an event (executes on call, like the MCP; --dry-run previews).

## Synopsis

```
apple calendar events create [flags]
```

## Options

- `--alarm` `<alarm>` *(repeatable)*
  <br>Alarm (repeatable): 15m|2h|1d before, +15m after, geo:lat,lon[,r][,enter|leave][,title], or a date.
- `--all-day`
  <br>Mark as an all-day event.
- `--availability` `<availability>`
  <br>Availability: busy|free|tentative|unavailable.
- `--end` `<end>`
  <br>End date (required).
- `--geo-lat` `<geo-lat>`
  <br>Structured-location latitude.
- `--geo-lon` `<geo-lon>`
  <br>Structured-location longitude.
- `--geo-radius` `<geo-radius>`
  <br>Structured-location radius (m).
- `--geo-title` `<geo-title>`
  <br>Structured-location title (may stand alone, no coords).
- `--location` `<location>`
  <br>Plain-text location.
- `--note` `<note>`
  <br>Notes/body.
- `--recurrence` `<recurrence>` *(repeatable)*
  <br>Recurrence spec (repeatable): freq=weekly;interval=2;byday=2,4;count=10.
- `--start` `<start>`
  <br>Start date (required).
- `--target-calendar` `<target-calendar>`
  <br>Calendar name/id to create in (default: default calendar).
- `--title` `<title>`
  <br>Event title (required).
- `--url` `<url>`
  <br>Associated URL (needs a scheme, e.g. https://…).

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
