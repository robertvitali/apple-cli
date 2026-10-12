# apple messages automation recover

Explicitly recover a pending Messages automation operation.

## Synopsis

```
apple messages automation recover [flags]
```

## Description

Explicitly clears a pending Messages automation operation after the operator acknowledges possible late effects. It is for uncertain post-handoff states such as timeout, cancellation, failed verification or crash after a request may have reached Messages.

## Options

- `--acknowledge-possible-late-effects`
  <br>Acknowledge possible late effects before clearing pending state.
- `--op-id` `<op-id>`
  <br>Pending operation id from `messages automation status`.

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

Preview recovery for one pending operation

```console
apple messages automation recover --op-id 00000000-0000-0000-0000-000000000000 --acknowledge-possible-late-effects --dry-run
```

Recover after acknowledging possible late effects

```console
apple messages automation recover --op-id 00000000-0000-0000-0000-000000000000 --acknowledge-possible-late-effects
```

## Notes

Recovery requires `--acknowledge-possible-late-effects`; without it the command refuses. Dry run verifies that the named operation exists and is in an uncertain-after-handoff phase but does not clear it. Execution records a recovered receipt and removes the pending gate. Recovery does not prove cancellation, quiescence, sync completion or correctness of the original UI action; it only acknowledges the risk so later writes can proceed. Use `messages automation status` first and recover only the exact operation id it reports.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple messages automation`](./index.md)
