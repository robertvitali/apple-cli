# apple messages history

Read one conversation by exact chat GUID or local chat ROWID.

## Synopsis

```
apple messages history [flags]
```

## Description

Reads one exact conversation with bounded results. Supply exactly one of `--chat-guid` or `--chat-rowid`. GUIDs are opaque database identifiers; ROWIDs are positive identifiers local to this Messages database. Ambiguous GUIDs are refused. A message linked to several chats retains the selected conversation's identity, rather than silently switching to its first chat.

## Options

- `--chat-guid` `<chat-guid>`
  <br>Conversation GUID from chat.guid.
- `--chat-rowid` `<chat-rowid>`
  <br>Local conversation ROWID from chat.ROWID.
- `--cursor` `<cursor>`
  <br>Opaque cursor returned by a previous history page.
- `--limit` `<limit>`
  <br>Max messages to return (default 100, max 1000).
- `--order` `<order>`
  <br>Sort order by normalized message date and ROWID: desc (default) or asc.

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

Read an explicitly selected local conversation

```console
apple messages history --chat-rowid 42 --limit 25
```

Continue that conversation's history

```console
apple messages history --chat-rowid 42 --cursor '<next_cursor>' --limit 25
```

## Notes

Pages default to 100 rows, with a maximum of 1000. Messages sort by normalized Apple timestamp and message ROWID, newest first unless `--order asc` is supplied. Undated rows remain discoverable. `timestamp` retains the raw Apple value; `normalized_seconds` and `normalized_nanoseconds` form an exact pair since the Apple epoch (2001-01-01 UTC), with a nonnegative nanosecond remainder. Both normalized fields are null for undated rows. Reuse `next_cursor` unchanged with the same resolved conversation and order; null marks the end. Cursors are limited to 4 KiB. A first-page message ROWID upper bound excludes later inserts even when their dates are older. Each page reads a fresh snapshot: edits, deletions and membership changes remain visible, so this is not snapshot isolation across invocations or a resume/replay event stream. Output limits do not bound snapshot cost.

Each message exposes `message_guid` and the selected chat identity alongside its local ROWID and message/attachment fields. Bodyless and undecodable records are retained; `body_availability` distinguishes them from available text. Exact reads also decode a constrained, data-only subset of `attributedBody` native-part metadata. `native_parts_available` is true when the archive is decoded; `native_parts` is an array of `{index, utf16_ranges, attachment_guid}` records. Each index is scoped to the enclosing message GUID; neither attachment order nor a text offset is used as native identity. The array is empty with `native_parts_reason: "empty-known"` when a supported archive has no native-part keys. `utf16_ranges` are offsets into the archived attributed-string text, not necessarily the emitted `body` value, because the database `text` column still has body precedence. Missing archives report `native_parts_available: false`, `native_parts: null`, `native_parts_reason: "absent-blob"`; malformed, keyed, or richer unsupported archives also report false/null with a bounded reason rather than partial metadata. Exact reads also include an always-present `thread_originator` object. When both native originator columns exist and both values are null or empty, it reports `available: true` and `reason: "no-linkage"`; when either column is absent, it reports `available: false`, `reason: "missing-schema"` and explicit null values. Valid linkage preserves the raw GUID and raw part marker and parses only a canonical ASCII nonnegative integer prefix before the first colon. Partial metadata, wrong SQLite storage types, noncanonical prefixes, overflows and the UInt64.max marker are unavailable rather than guessed, and the field does not claim an immediate parent/root or authorize mutation. Missing required schema, failed queries and missing conversation identities fail clearly. Reading history does not mark the conversation read.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../reference/json-contract.md) and [exit codes](../reference/exit-codes.md).

## See also

- [`apple messages`](./index.md)
