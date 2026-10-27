# apple messages attachment retrieve

Request attachment loading through Messages and verify local availability.

## Synopsis

```
apple messages attachment retrieve [flags]
```

## Description

Requests native attachment loading for an exact message and native attachment part. Select exactly one chat ROWID or GUID and exactly one message ROWID or GUID, then pass the attachment part index reported by messages get. Execution requires --experimental-ui-handoff.

## Options

- `--chat-guid` `<chat-guid>`
- `--chat-rowid` `<chat-rowid>`
- `--experimental-ui-handoff`
  <br>Allow bounded Messages UI attachment loading.
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

Preview attachment retrieval

```console
apple messages attachment retrieve --chat-rowid 42 --message-rowid 123 --part-index 0 --dry-run
```

## Notes

Dry run resolves the target and test policy without launching a UI worker or creating journal state. Execution uses the shared Messages automation journal, including when all attachments are already downloaded. A pending operation blocks later writes until inspected and recovered. The worker binds the selected native attachment GUID and the complete attachment membership; it attempts at most one native press and verifies finished native transfer state plus confined local file readability for every bound attachment. Results describe observed local availability, not proof that this request caused a download or that another device synchronized. Missing, malformed, failed or changed observations cannot verify success. Timeout, cancellation or verification failure may leave a pending operation; inspect messages automation status and recover before retrying. No geometry, body-text, latest-message or same-contact fallback selects another target. Test mode requires a labeled target and one allowed direct recipient. Live retrieval reliability has not yet been established.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple messages attachment`](./index.md)
