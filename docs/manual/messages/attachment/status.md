# apple messages attachment status

Inspect the transfer and local readability of one exact attachment part.

## Synopsis

```
apple messages attachment status [flags]
```

## Description

Read the current load state of one exact native attachment part. Select the conversation, message and part as for retrieval. To check an attachment from an earlier read, pass its GUID with `--expected-attachment-guid`. A changed target produces an error.

## Options

- `--chat-guid` `<chat-guid>`
- `--chat-rowid` `<chat-rowid>`
- `--expected-attachment-guid` `<expected-attachment-guid>` *(repeatable)*
  <br>Require the selected part to still have the attachment GUID reported by messages get.
- `--message-guid` `<message-guid>`
- `--message-rowid` `<message-rowid>`
- `--part-index` `<part-index>`
  <br>Exact native attachment part index from messages get.

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

Inspect a selected attachment part

```console
apple messages attachment status --chat-rowid 1 --message-rowid 123 --part-index 0
```

## Notes

The read-only worker checks the selected attachment’s stored transfer and inspects its file under the Messages attachment directory with automatic materialization disabled. It checks the database binding again after file inspection. The state describes that observation and may subsequently change.

`downloaded` requires a finished transfer and a confined, locally readable regular file. `pending` means Messages reports an unfinished transfer. `missing` means a finished transfer’s file is absent. `failed` covers native failure and rejection states. `unavailable` covers insufficient or unsafe evidence, including a finished transfer with a dataless placeholder. The command does not request a download or open Messages.

On success, `data.chat_rowid` and `data.message_rowid` identify the resolved database rows. `data.native_part` is the native part index and `data.state` is one of the five states above. With `--text`, stdout contains only the state.

If the resolved part has a different GUID from any `--expected-attachment-guid`, the command returns `validation_error` (exit 64) before calling the worker. If the worker times out or cannot verify the target after inspecting the file, the command returns `upstream_error` (exit 69). A successful `unavailable` result describes the file evidence for a verified target.

Test mode requires a direct conversation with exactly one allowlisted participant and a message caption beginning with the test prefix (default `apple-cli-test`). In test mode, a file-only message with a labeled filename returns `safety_violation` (exit 77).

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple messages attachment`](./index.md)
