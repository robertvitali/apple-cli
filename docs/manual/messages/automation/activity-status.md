# apple messages automation activity-status

Read pending Messages automation state, including typing activity.

## Synopsis

```
apple messages automation activity-status
```

## Description

Read the pending Messages automation operation and its recovery receipts, including pending typing operations.

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

Check the journal for a pending typing operation

```console
apple messages automation activity-status
```

## Notes

Upgrade status readers before enabling a typing writer. Older builds from main refuse a pending typing record. Before downgrading, use this command to verify that no typing operation is pending. The action is messages-automation-activity-status. A pending operation has an operation_id, operation_type and phase. A null pending value means the journal has no unresolved operation. The phase describes the recorded handoff. A typing record does not establish that another device saw a typing indicator. This command acquires the journal lock and can time out while another process holds it.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple messages automation`](./index.md)
