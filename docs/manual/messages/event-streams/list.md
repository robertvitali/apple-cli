# apple messages event-streams list

List local event streams and retention bounds.

## Synopsis

```
apple messages event-streams list
```

## Description

List private event streams for the current account, including streams that are busy or require recovery. An account with no registry returns an empty array.

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

Inspect the local streams

```console
apple messages event-streams list
```

## Output

Each JSON row identifies a stream, its status, filter digest, oldest retained sequence and head sequence. Some fields are null when the journal cannot be inspected. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple messages event-streams`](./index.md)
