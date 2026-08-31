# apple mail attachments list

List attachments by message id or subject keyword.

## Synopsis

```
apple mail attachments list [<id>] [flags]
```

## Options

- `<id>`
  <br>Message id (ROWID / RFC Message-ID / message:// link).
- `--account` `<account>`
  <br>Account name or UUID. With an id: scope assertion (rejects if the message is elsewhere — same posture as `get`, see docs/port-specs/mail.md; oracle A treats it as a perf hint). With --subject: which account to search.
- `--mailbox` `<mailbox>`
  <br>Mailbox. With an id: scope assertion (oracle A's mailbox param, hint there; 'All' is the no-op wildcard). With --subject: where to match (default INBOX, oracle B's scope; 'All' widens). Ignored-with-an-id note: --max-results applies to --subject only (the id path is oracle A's get_attachments, which has no cap).
- `--max-results` `<max-results>`
  <br>Max messages to inspect for --subject (default 1, oracle B's default — each match costs a live Mail.app locator scan, bounded at 30s per Message-ID spelling / 60s per match; raise deliberately). Inert on the id path.
- `--no-live`
  <br>Skip the live Mail.app metadata enrichment (fast Envelope-Index rows only; mime_type/size/downloaded omitted, disclosed via note).
- `--subject` `<subject>`
  <br>Subject keyword to find messages.

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
