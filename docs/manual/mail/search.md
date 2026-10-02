# apple mail search

Search messages (subject/sender/body/date/read/flagged/attachment; paginated).

## Synopsis

```
apple mail search [flags]
```

## Options

- `--account` `<account>`
  <br>Account name or UUID; omit to search all accounts.
- `--body` `<body>`
  <br>Substring match on the message body. Default: fast match on the indexed body preview (Mail caches previews for only some messages). Add --body-live for a live Mail.app scan of the FULL content of every candidate message (slow; the underlying script keeps its per-Apple-event 180s timeout; the CLI's default 195s aggregate host deadline fails as upstream_error/69 with no partial results; pass --body-live-timeout 0 to disable the aggregate deadline; Mail may remain busy with an in-flight event; narrow with --mailbox/--account — a lower --limit helps only when matches are plentiful — or drop --body-live).
- `--body-live`
  <br>With --body: scan live full message content via Mail.app instead of the indexed preview. Paging follows Mail's scan order: --offset skips that many matches, and the window collected after them is sorted per --sort and cut to --limit before being returned, so --sort orders matches within a page, not across all matches.
- `--body-live-timeout` `<body-live-timeout>`
  <br>Overall --body-live host deadline in seconds (default 195; positive values customize it; 0 disables the host deadline, allowing an unbounded aggregate scan). Requires --body-live; maximum 86400 seconds.
- `--content`
  <br>Include the indexed body preview (default on).
- `--flagged`
  <br>Only flagged messages.
- `--from-date` `<from-date>`
  <br>Lower bound on date received (YYYY-MM-DD).
- `--has-attachment`
  <br>Only messages with attachments.
- `--include-system-folders`
  <br>With --mailbox All, also sweep the system mailboxes normally skipped. Excluded by leaf name: Trash, Junk, Junk Email, Deleted Items, Deleted Messages, Sent, Sent Items, Sent Messages, Drafts, Spam. Provider-specific names outside that list (notably Gmail's '[Gmail]/Sent Mail' and '[Gmail]/All Mail') are NOT excluded.
- `--limit` `<limit>`
  <br>Max results per page (default 50; 0 = all).
- `--mailbox` `<mailbox>`
  <br>Mailbox name (default INBOX; use 'All' for every mailbox).
- `--max-content-length` `<max-content-length>`
  <br>Truncate each included body preview to N chars (0 = unlimited).
- `--no-attachment`
  <br>Only messages without attachments.
- `--no-content`
  <br>Include the indexed body preview (default on).
- `--offset` `<offset>`
  <br>Results to skip (pagination).
- `--read`
  <br>Only read messages.
- `--sender` `<sender>`
  <br>Substring match on sender name/email.
- `--sort` `<sort>`
  <br>Sort order: date_desc (default) or date_asc.
- `--subject` `<subject>` *(repeatable)*
  <br>Substring match on subject (repeatable — matches ANY).
- `--to-date` `<to-date>`
  <br>Upper bound on date received (YYYY-MM-DD, inclusive).
- `--unflagged`
  <br>Only unflagged messages.
- `--unread`
  <br>Only unread messages.

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

- [`apple mail`](./index.md)
