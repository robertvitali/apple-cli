# apple messages send

Send an iMessage/SMS (sends on call; --dry-run previews).

## Synopsis

```
apple messages send <recipient> [flags]
```

## Description

Sends when invoked. Use `--dry-run` to preview. For one-to-one sends, `--service auto` tries the iMessage account first and can retry through SMS for a phone-shaped recipient. The explicit `imessage` and `sms` modes each select one account. Messages resolves the final transport when it sends. `--file` attaches a file and may be repeated; the message body goes out first, then each file in the order given, all in one Messages automation run. Either a message or a file is required — a send with neither is a `validation_error`, reported after the recipient has been resolved, so an unknown recipient or a sandbox refusal comes first.

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
  <br>Account selection for one-to-one sends. auto tries iMessage first and can retry through SMS for a phone number. imessage and sms each select one account. Messages determines the delivery transport. Group sends use the specified chat.

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

Select the iMessage account and disable the CLI’s SMS retry

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

For a one-to-one send, `service_used` identifies the account branch that returned success. It cannot confirm which transport carried the message. With `--group`, the CLI addresses the chat directly and omits `service_used`. Both modes report the supplied `service_requested`. `--service sms` to a recipient with no digits in it is refused up front as a `validation_error` (exit 64), because SMS cannot reach one. The test is literally "does this contain a digit", the same one the `auto` fallback uses, so an address like `jane.doe1@example.com` passes it and fails later inside Messages instead; `auto` and `imessage` reach email addresses normally.

`--file` works with `--group` too, and each file then goes to the whole chat rather than to one person. That path is pinned at the command layer and its AppleScript is compile-checked, but it has never been run against a live group, so treat the delivery behaviour as designed and unverified. The sandbox (`--test-mode` / `APPLE_TEST_MODE`) refuses group sends outright and still confines one-to-one recipients to `APPLE_TEST_RECIPIENTS`; neither flag changes that.

The JSON carries `service_requested` (`auto`/`imessage`/`sms`) and `files` (the attachment paths, `[]` when there are none) on both the dry-run and the execute envelope; the execute envelope adds `files_sent`, which is absent from a dry run because nothing was sent. On a dry run, `service_plan` reads `iMessage→SMS auto`, `iMessage only`, `SMS only`, or `group chat`. A file-only send reports no `message` key.

Every `--file` path goes through the same guard `mail send --attach` uses, and the whole batch is checked before anything is dispatched. A path is resolved to an absolute, SYMLINK-RESOLVED location — a link is sent, and reported in `files`, as the file it points at — and it must be an existing regular file (`not_found`, exit 65, otherwise; that is also what an `.app` bundle gets, since a bundle is a directory). Refused outright: anything inside a credential or config directory (`~/.ssh`, `~/.gnupg`, `~/.config`, `~/.aws`, `~/.claude`, `~/Library/Keychains`, `~/Library/LaunchAgents`, `~/Library/LaunchDaemons`), checked after symlinks are resolved so a link into one cannot slip past; executable and script file types (`.sh`, `.command`, `.exe`, `.app` as a single file, and the rest of the same list Mail blocks); anything over 25 MB; any path containing a control character; and a path spelled as another user's home (`~user/…`, any account but your own — a `validation_error`, exit 64, decided before the path is expanded; your own account's `~name/…` means the same as `~/…`). The credential and control-character refusals are `safety_violation` (exit 77), the type and size refusals `validation_error` (exit 64). The argument is never trimmed, so a filename with a leading or trailing space names that file and not its neighbour. `--dry-run` refuses exactly what an execute would.

The check is path-based, and it is worth knowing what that excludes: a hard link to a credential file is a second name for the same bytes and is not detected (no more than `cp` would be), and the file is read by Messages after the check rather than during it, so a path can be swapped in between. Both are inherited from the Mail attachment guard.

A send is not atomic: the body and each attachment are separate transfers, so a failure partway through leaves the earlier ones delivered. When an attachment was in flight, that is an `upstream_error` naming which attachment failed, how many had already gone out, and the paths already delivered (in `error.applied`). When none was — the body went out and then, say, the SMS account lookup failed — the error is the generic one, with no attachment named and no `applied` list. Either way, if the message body itself had already gone out, the error says so explicitly and tells you to omit `--message` from the retry. If Messages returns a result this version cannot read, the error says that what was delivered is unknown — the message and any attachments may have gone in full — and asks you to check the conversation before retrying, because the retry advice above cannot be derived from counters that were never observed; the error envelope's `remediation` field then begins `delivery unknown:` so a script can detect the state without parsing the message.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../reference/json-contract.md) and [exit codes](../reference/exit-codes.md).

## See also

- [`apple messages`](./index.md)
