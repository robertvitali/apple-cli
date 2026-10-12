# apple messages reaction inspect

Inspect outgoing and incoming reactions for one exact message.

## Synopsis

```
apple messages reaction inspect [flags]
```

## Description

Inspects the current reaction state for one exact Messages target. Supply exactly one conversation selector (`--chat-guid` or `--chat-rowid`) and exactly one message selector (`--message-guid` or `--message-rowid`). The command reads chat.db only; it does not open Messages, mark a conversation read or mutate a reaction.

## Options

- `--chat-guid` `<chat-guid>`
  <br>Conversation GUID from chat.guid.
- `--chat-rowid` `<chat-rowid>`
  <br>Local conversation ROWID from chat.ROWID.
- `--message-guid` `<message-guid>`
  <br>Message GUID from message.guid.
- `--message-rowid` `<message-rowid>`
  <br>Local message ROWID from message.ROWID.
- `--part-index` `<part-index>`
  <br>Native Messages part index to inspect.
- `--row-limit` `<row-limit>`
  <br>Maximum reaction rows to inspect (default 512, max 10000).

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

Inspect reactions on one local message

```console
apple messages reaction inspect --chat-rowid 42 --message-rowid 123
```

Inspect one native message part with a smaller row cap

```console
apple messages reaction inspect --chat-rowid 42 --message-rowid 123 --part-index 2 --row-limit 50
```

## Notes

`--part-index` selects one native Messages part index decoded from `attributedBody`. Without it, a message with exactly one decoded native part uses that part; a message with several decoded parts reports `multiple-native-parts-require-explicit-part`, and a message whose native parts are unavailable reports why the part could not be proven. `--row-limit` defaults to 512 and accepts 1 through 10000. If more matching reaction rows exist than the cap, the JSON reports `rows_capped: true`, includes `reaction-row-limit-exceeded` in `unknown_reasons`, and treats the fold as unknown rather than pretending the partial scan is authoritative.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple messages reaction`](./index.md)
