# apple notes list

List note titles in an account/folder (supports --modified-since, --limit).

## Synopsis

```
apple notes list [flags]
```

## Description

Lists note titles across the account, or within one folder with `--folder`. `--folder` must name at least one path component: `""` and separators-only values such as `"///"` are refused as a `validation_error` (exit 64) rather than silently widening the listing to the whole account. Omit `--folder` to list every folder.

## Options

- `--account` `<account>`
  <br>Account to list from.
- `--folder` `<folder>`
  <br>Filter to a folder (nested paths ok).
- `--limit` `<limit>`
  <br>Max results.
- `--modified-since` `<modified-since>`
  <br>ISO-8601 date; only notes modified on/after.

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

List every note title

```console
apple notes list
```

List one folder, at most 20 titles

```console
apple notes list --folder 'Projects' --limit 20
```

## Notes

Nested folders are addressed with `/` between components. Titles come back in the order Notes.app returns them, not sorted by date; use `apple notes recent` for newest-first.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../reference/json-contract.md) and [exit codes](../reference/exit-codes.md).

## See also

- [`apple notes`](./index.md)
