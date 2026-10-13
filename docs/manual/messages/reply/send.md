# apple messages reply send

Send a text reply to an exact root message in a direct chat.

## Synopsis

```
apple messages reply send [flags]
```

## Description

Sends a bounded text reply to one exact root message in a direct Messages conversation. Select the conversation with exactly one of `--chat-rowid` or `--chat-guid`; select the root message with exactly one of `--message-rowid` or `--message-guid`; pass `--part-index` for the decoded native part and `--body` for the reply text.

## Options

- `--body` `<body>`
  <br>Reply text. Must be nonempty and no more than 2048 UTF-8 bytes.
- `--chat-guid` `<chat-guid>`
  <br>Conversation GUID from chat.guid.
- `--chat-rowid` `<chat-rowid>`
  <br>Local conversation ROWID from chat.ROWID.
- `--experimental-ui-handoff`
  <br>Allow the bounded Messages UI handoff required to send the reply.
- `--message-guid` `<message-guid>`
  <br>Message GUID from message.guid.
- `--message-rowid` `<message-rowid>`
  <br>Local message ROWID from message.ROWID.
- `--part-index` `<part-index>`
  <br>Native Messages part index to reply to.

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

Preview a sandboxed exact reply

```console
apple messages reply send --chat-rowid 42 --message-rowid 123 --part-index 2 --body 'apple-cli-test reply' --dry-run --test-mode
```

Execute with explicit UI handoff opt-in

```console
APPLE_TEST_MODE=1 apple messages reply send --chat-rowid 42 --message-rowid 123 --part-index 2 --body 'apple-cli-test reply' --experimental-ui-handoff
```

## Notes

The reply body must be nonempty and at most 2048 UTF-8 bytes; the encoded worker payload is capped at 4096 bytes. `--body` is used instead of `--text` because `--text` is the global output-format flag. Execution opens the exact native Messages URL, retains the original process/window/transcript and normal composer identities, opens one owned Reply composer, writes the body once, snapshots exact UTF-8 text with UTF-16 character-count consistency, posts one Return key pair to Messages and then verifies both UI cleanup and fresh database correspondence before clearing the pending operation. A successful result reports `verification_source: ui_clean_state_and_database_correspondence`, `sent_message_rowid`, `sent_message_guid`, `parent_message_guid`, `parent_native_part`, and the exact target. If Messages already restored the clean main composer after send, no cancel is sent; if an owned reply composer remains empty, exactly one `AXCancel` closes it. After the first send dispatch, the command never retries Return and never clears a nonempty composer. Database thread-originator metadata alone never authorizes a write; the parent accepts the worker ACK only after strict same-chat new-row proof. Dry run performs no UI work and creates no journal entry.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple messages reply`](./index.md)
