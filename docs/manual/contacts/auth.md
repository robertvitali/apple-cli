# apple contacts auth

Report Contacts TCC authorization status; prompts only with --request.

## Synopsis

```
apple contacts auth [flags]
```

## Description

Reports the current Contacts TCC state without prompting unless `--request` is passed. Add `--request` to ask macOS for Contacts permission explicitly without reading contact records or mutating the address book; if the executable lacks embedded Contacts usage metadata, the command refuses with an authorization error before making the request.

## Options

- `--request`
  <br>Request Contacts permission if it has not been requested yet; never reads contact records.

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

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../reference/json-contract.md) and [exit codes](../reference/exit-codes.md).

## See also

- [`apple contacts`](./index.md)
