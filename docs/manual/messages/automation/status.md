# apple messages automation status

Read pending Messages automation state.

## Synopsis

```
apple messages automation status
```

## Description

Reads the shared Messages automation journal state without driving Messages or clearing anything. It reports the pending operation, if any, plus bounded receipts for resolved or recovered operations.

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

Check for a pending Messages automation operation

```console
apple messages automation status
```

## Notes

A pending record gates new Messages UI writes until the original operation reaches observed state or is explicitly recovered. The status output includes `pending` as null or `{operation_id, operation_type, phase}` and `receipts` as `{operation_id, disposition}` records. It does not expose message bodies, recipient addresses or other target values. Reads use the same locked private state root as reaction writes.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple messages automation`](./index.md)
