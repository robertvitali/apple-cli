# apple messages get

Read one message by exact conversation identity and exact message identity.

## Synopsis

```
apple messages get [flags]
```

## Description

Fetches one message using exactly one conversation selector (`--chat-guid` or `--chat-rowid`) and exactly one message selector (`--message-guid` or `--message-rowid`). Both identities and their membership are checked in the read-only database snapshot. Duplicate GUIDs, missing rows and a message outside the selected conversation are refused. Identical text in another conversation does not affect selection.

## Options

- `--chat-guid` `<chat-guid>`
  <br>Conversation GUID from chat.guid.
- `--chat-rowid` `<chat-rowid>`
  <br>Local conversation ROWID from chat.ROWID.
- `--message-guid` `<message-guid>`
  <br>Message GUID from message.guid.
- `--message-rowid` `<message-rowid>`
  <br>Local message ROWID from message.ROWID.

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

Fetch one message in its selected conversation

```console
apple messages get --chat-rowid 42 --message-rowid 123
```

## Notes

GUIDs are opaque, persistent identifiers when available; positive ROWIDs are local to this database. The result retains caller-selected chat membership even when the message also belongs to another conversation. Message, attachment, native-part and `thread_originator` fields use the same shape as `messages history`, including explicit body availability, explicit native-part null-versus-array states and explicit nullable thread-originator keys. This command reads database state only; it does not select a Messages window, mark a chat read or mutate a message.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../reference/json-contract.md) and [exit codes](../reference/exit-codes.md).

## See also

- [`apple messages`](./index.md)
