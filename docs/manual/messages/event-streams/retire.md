# apple messages event-streams retire

Retire one exact local event stream.

## Synopsis

```
apple messages event-streams retire <stream-id>
```

## Description

Retire one private event stream by its exact lowercase stream ID. Its saved cursors become unusable. Other streams and native Messages data are preserved.

## Options

- `<stream-id>`
  <br>Exact lowercase stream ID returned by watch or event-streams list.

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

Preview the journal files that would be removed

```console
apple messages event-streams retire "$STREAM_ID" --dry-run
```

Retire the inspected stream

```console
apple messages event-streams retire "$STREAM_ID" --execute
```

## Notes

A busy stream must release its lease before retirement. Dry-run takes precedence over execute. Sandbox mode permits preview only. If delivery of the result is interrupted, inspect the stream list before deciding whether to retry.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple messages event-streams`](./index.md)
