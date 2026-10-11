# apple messages conversations

List all conversations: 1:1 chats, named groups, and unnamed groups.

## Synopsis

```
apple messages conversations [flags]
```

## Description

Discovers direct conversations, named groups and unnamed groups. Each row includes `chat_rowid`, `chat_guid`, `chat_identifier`, available display/service metadata, participants and last activity. `last_activity_normalized_seconds` and `last_activity_normalized_nanoseconds` provide the normalized Apple-epoch time as an exact pair, while `last_activity_timestamp` retains the raw database value. Use `chat_guid` or the local `chat_rowid` with `messages history` and `messages get`; display names and message text are not exact selectors. The existing `messages chats` command continues to list named chats only.

## Options

- `--cursor` `<cursor>`
  <br>Opaque cursor returned by a previous conversations page.
- `--limit` `<limit>`
  <br>Max conversations to return (default 100, max 1000).
- `--order` `<order>`
  <br>Sort order by last activity, then chat ROWID: desc (default) or asc.

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

Discover conversations of every kind

```console
apple messages conversations --limit 25
```

Continue the same discovery traversal

```console
apple messages conversations --cursor '<next_cursor>' --limit 25
```

## Notes

Pages default to 100 rows and accept limits from 1 to 1000. Ordering is by normalized last activity, then chat ROWID; `--order desc` is the default and `--order asc` reverses it. Pass the returned `next_cursor` unchanged with the same order; null means there is no next page in this traversal. Cursors are limited to 4 KiB and are bound to the operation and ordering. Initial message and chat ROWID upper bounds exclude later inserts, including backdated messages, and conversation activity is computed only from messages within that bound. Each invocation reads a fresh snapshot, so edits, deletions and changed memberships can still affect later pages; this is not an immutable snapshot or event replay. The result limit does not bound database snapshot or discovery scan cost. Missing required schema or failed queries are errors rather than empty results. Reads do not drive Messages UI or mark conversations read.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../reference/json-contract.md) and [exit codes](../reference/exit-codes.md).

## See also

- [`apple messages`](./index.md)
