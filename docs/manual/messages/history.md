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

Each message exposes `message_guid` and the selected chat identity alongside its local ROWID and message/attachment fields. Bodyless and undecodable records are retained; `body_availability` distinguishes them from available text. Exact reads also decode a constrained, data-only subset of `attributedBody` native-part metadata. `native_parts_available` is true when the archive is decoded; `native_parts` is an array of `{index, utf16_ranges, attachment_guid}` records. Each index is scoped to the enclosing message GUID; neither attachment order nor a text offset is used as native identity. The array is empty with `native_parts_reason: "empty-known"` when a supported archive has no native-part keys. `utf16_ranges` are offsets into the archived attributed-string text, not necessarily the emitted `body` value, because the database `text` column still has body precedence. Missing archives report `native_parts_available: false`, `native_parts: null`, `native_parts_reason: "absent-blob"`; malformed, keyed, or richer unsupported archives also report false/null with a bounded reason rather than partial metadata. Exact reads also include an always-present `thread_originator` object. When both native originator columns exist and both values are null or empty, it reports `available: true` and `reason: "no-linkage"`; when either column is absent, it reports `available: false`, `reason: "missing-schema"` and explicit null values. Valid linkage preserves the raw GUID and raw part marker and parses only a canonical ASCII nonnegative integer prefix before the first colon. Partial metadata, wrong SQLite storage types, noncanonical prefixes, overflows and the UInt64.max marker are unavailable rather than guessed, and the field does not claim an immediate parent/root or authorize mutation. Missing required schema, failed queries and missing conversation identities fail clearly. Reading history does not mark the conversation read. Exact reads include an always-present `native_status` object with `error`, `is_delivered`, `is_read`, `date_delivered` and `date_read`. Each field has `status` and nullable integer `raw`; error adds nullable `is_error`, flags add nullable `value`, and timestamps add nullable `normalized_seconds`, `normalized_nanoseconds`, `date` (UTC) and `date_local`. All listed keys are explicitly encoded, including nulls. Missing columns report `missing-schema`, SQL NULL reports `null`, and noninteger storage reports `wrong-type` without coercing its bytes. Error integers are preserved and `is_error` means only raw != 0; no error-name dictionary is inferred. Flags accept only integer 0/1; other integers retain raw with `invalid-boolean` and null value. Timestamp 0 is `zero-sentinel`; negatives report `negative`; parsed fields are null in both cases. Positive values use the existing compatibility heuristic: at most 9,999,999,999 means seconds since 2001-01-01 UTC, larger values mean nanoseconds since that Apple epoch. Normalized values are whole seconds plus a nonnegative subsecond remainder, not total nanoseconds. Strings use whole-second Gregorian/POSIX formatting; raw and remainder preserve precision. Unrepresentable formatting reports `invalid-timestamp` with raw retained and parsed fields null. Valid values report `available`. Flags and dates are independent observations and never inferred from one another. Their interpretation depends on message direction and native Messages behavior; these row-level fields are not per-recipient group receipts, a cross-device synchronization guarantee, or proof for sending or other mutations.

Exact reads also include `native_edit_context` with independent `date_edited`, `date_retracted`, and `summary_info` observations. Dates follow the native-status column rules; edit-history event timestamps instead accept INTEGER or finite REAL signed Apple-epoch seconds, with zero and negative seconds valid within the supported calendar range. History timestamps preserve integer evidence in `raw` and REAL evidence in additive nullable `raw_real`; all keys remain explicit, and an available timestamp has exactly one raw evidence field. REAL normalization uses binary64 floor plus a nonnegative fractional remainder rounded to nanoseconds, ties away from zero, carrying a billion nanoseconds before calendar validation. Date strings remain whole-second renderings. This is floating-point normalization, not a clock-precision guarantee or exact decimal arithmetic. Four-byte REAL values widen to Double; JSON numbers may have integral spelling and consumers need not preserve signed zero. Nonfinite REAL values report `invalid-timestamp` with raw fields null; finite raw evidence survives invalid calendar formatting. Strings, booleans, and plist dates are not coerced. Summary containers preserve original part indexes, raw coordinates, malformed siblings, and available history text; these indexes do not identify current native parts. Missing, null, malformed, unsupported, limited, changed, and failed observations remain distinct, with explicit nulls rather than invented empty histories. No whole-message edit/Undo Send flag, mutation eligibility, or cross-device guarantee is inferred. Only bounded binary summaries and constrained attributed-string bodies are decoded; the exact ASCII data-URL form never fetches a URL. Per-request and per-summary budgets account for copied/decoded data, preserve existing fields and pagination when exhausted, and propagate cancellation. Only visible history rows are enriched. Synthetic decoding tests and one outgoing direct-message edit on macOS 27 verify original/revised text, native part mappings, the edit date, and fractional history timestamps against an independent plist decoder. Group, partial-Undo-Send, and cross-device compatibility remain unverified. The source version is unpublished 27.0.0; the minimum remains macOS 14 and JSON schema remains 1.

`native_mentions` reports supported confirmed native mention attributes with explicit `status`, nullable `reason`, nullable `text`, `range_encoding: "utf-16"`, and nullable `entries`. Available entries contain opaque `identifier` and `utf16_range: {location, length}`. Ranges refer exclusively to the full original attributed text in this object, which can differ from the legacy `body`; no normalization, merging or recipient resolution occurs. Supported archives with no mentions report available entries[] and text:null. Unavailable observations have entries:null and text:null: absent-blob, wrong-type, unsupported, corrupt, resource-limit, or request-limit with a fixed reason. Optional malformed mention metadata does not erase existing native parts. Limits are 256 entries per message, 1024 UTF-8 bytes per identifier, and per request 2048 entries plus 4 MiB of retained text/identifier UTF-8 content. This is a content budget, not a serialized-JSON byte bound. Whole messages are admitted in page order; after the first budget miss, all later requested rows report request-limit without collecting mentions. Empty known observations cost zero before exhaustion. Each invocation resets these budgets; pagination and existing fields remain available. Only visible history rows collect mentions. Compatibility is supported by inspected native-format source and synthetic fixtures; live group mention compatibility is unverified. Mention metadata never authorizes sending, recipient selection, or a mutation. This additive observation can be ignored; clients supporting older binaries must tolerate its absence. Existing fields and schema_version remain unchanged.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../reference/json-contract.md) and [exit codes](../reference/exit-codes.md).

## See also

- [`apple messages`](./index.md)
