# apple mail attachments save

Save attachments from a message to a directory or an exact path (EXECUTES by default; --dry-run previews).

## Synopsis

```
apple mail attachments save [<id>] [flags]
```

## Options

- `<id>`
  <br>Message id (ROWID / RFC Message-ID); or use --subject.
- `--account` `<account>`
- `--allow-outside-home`
  <br>Allow a destination outside $HOME (e.g. /tmp, /Volumes/...). Oracle A's save_attachments has no confinement, so this restores that reach. Credential directories (~/.ssh, ~/.aws, ...) stay blocked either way.
- `--dir` `<dir>`
  <br>Destination directory for multiple attachments (mutually exclusive with --out).
- `--indices` `<indices>`
  <br>0-based attachment indices to save (comma-separated); default all. Mutually exclusive with --name.
- `--name` `<name>`
  <br>Save only the attachment with this name. Mutually exclusive with --indices.
- `--out` `<out>`
  <br>Exact destination file path — rename-on-save; requires exactly one selected attachment (mutually exclusive with --dir).
- `--subject` `<subject>`
  <br>Subject keyword to find the message.

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

- [`apple mail attachments`](./index.md)
