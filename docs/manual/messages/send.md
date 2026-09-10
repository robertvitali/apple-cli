# apple messages send

Send an iMessage/SMS (sends on call, like the MCP; --dry-run previews).

## Synopsis

```
apple messages send <recipient> [flags]
```

## Description

Sends when invoked, exactly as the MCP's `tool_send_message` does; `--dry-run` previews. `--service` picks the route for a one-to-one send: `auto` (the default, and the ported behaviour) tries iMessage and falls back to SMS for a phone-shaped recipient, `imessage` uses iMessage only and fails rather than falling back, and `sms` uses the enabled SMS account only. `--file` attaches a file and may be repeated; the message body goes out first, then each file in the order given, all in one Messages automation run. Either a message or a file is required — a send with neither is a `validation_error`.

## Options

- `<recipient>`
  <br>Recipient: phone, email, contact name, or (with --group) a chat id.
- `--file` `<file>` *(repeatable)*
  <br>Path to a file to send as an attachment. Repeat to send several; each is sent after the message body, in the order given.
- `-g`, `--group`
  <br>Treat the recipient as a group chat id.
- `-m`, `--message` `<message>`
  <br>Message body. Optional when --file is given; a send needs a body, a file, or both.
- `--service` `<service>`
  <br>Which service a one-to-one send may use: auto (default — iMessage first, then SMS for a phone number), imessage (iMessage only, no fallback), or sms (SMS only). Accepted but ignored with --group: a chat id already names the chat's own service.

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

Preview a send without sending it

```console
apple messages send +12125550100 --message "Running late" --dry-run
```

Send over iMessage only, with no SMS fallback

```console
apple messages send jane.doe@example.com --message "Deck attached" --service imessage
```

Send a message and two attachments

```console
apple messages send +12125550100 --message "Both files" --file ~/Documents/one.pdf --file ~/Documents/two.png
```

Send a file with no message body

```console
apple messages send +12125550100 --file ~/Documents/one.pdf
```

## Notes

`--service` applies to one-to-one sends only. It is accepted with `--group` and has no effect there: a chat id already names the chat's own service, and Messages offers no choice. The flag is still reported back as `service_requested` so a caller can see it was ignored rather than silently honoured.

The JSON carries `service_requested` (`auto`/`imessage`/`sms`) and `files` (absolute standardized attachment paths, `[]` when there are none) on both the dry-run and the execute envelope; the execute envelope adds `files_sent`. On a dry run, `service_plan` reads `iMessage→SMS auto`, `iMessage only`, `SMS only`, or `group chat`. A file-only send reports no `message` key.

Every `--file` path is checked before anything is dispatched: it must be an existing, readable, regular file, and it is resolved to an absolute standardized path — `.` and `..` are removed, but a symlink is left as you spelled it and the argument is never trimmed, so a filename with a leading or trailing space names that file and not its neighbour. A missing path, a directory, or an unreadable file is a `validation_error` (exit 64) and nothing is sent. A send is not atomic, though — the body and each attachment are separate transfers, so a failure partway through leaves the earlier ones delivered. That case is an `upstream_error` naming which attachment failed, how many had already gone out, and (in `error.applied`) the exact paths already delivered, which a retry must exclude because a resend is a second message rather than an update.

The opt-in sandbox (`--test-mode` / `APPLE_TEST_MODE`) is unchanged by either flag: it still confines recipients to `APPLE_TEST_RECIPIENTS` and still refuses group sends outright.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../reference/json-contract.md) and [exit codes](../reference/exit-codes.md).

## See also

- [`apple messages`](./index.md)
