# apple messages recent

Recent messages across ALL chats in the last N hours (optionally by contact).

## Synopsis

```
apple messages recent [flags]
```

## Description

Returns recent Messages rows with the same JSON envelope as the rest of the CLI. Each message says which conversation it came from — `chat_identifier` and `chat_guid` (both `string|null`: null when the message maps to no chat row) and `is_group` (true when that chat's `style` is 43). A message joined to several chats reports the one with the lowest chat row id. `--direct-only` drops group-chat messages; the filter runs in SQL, before `--limit`, so a request for N messages still returns up to N rather than N-minus-the-groups. It excludes group chats specifically, not everything that is not a 1:1: a message belonging to no chat row at all is KEPT, because it is not in a group chat, and those are the ones with a null `chat_identifier`. A message that belongs to several chats is judged by the same lowest-row-id chat its `is_group` comes from, so a message in both a 1:1 and a group survives when the 1:1 chat has the lower row id and is excluded when the group does. The `direct_only` field echoes the flag back, and `direct_only_applied` says whether the filter actually ran — they differ only when the store cannot say which chat a message belongs to, in which case group messages are still present. Each message also includes `has_attachments` and an `attachments` array. Attachment paths are derived from chat.db metadata only: `filename` is the stored value, `path` is present only when an absolute standardized path can be derived, and `exists` is true or false only after a conservative local-root probe. When probing is skipped, `exists` is null.

## Options

- `--contact` `<contact>`
  <br>Filter by contact name, phone, or email.
- `--direct-only`
  <br>Only 1:1 conversations — exclude messages sent in a group chat.
- `--handle` `<handle>`
  <br>Explicit handle (phone/email) — stateless replacement for the MCP's contact:N.
- `--hours` `<hours>`
  <br>Hours to look back (default 24).
- `--limit` `<limit>`
  <br>Max messages (default 100).

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

List recent messages with attachment metadata

```console
apple messages recent --hours 6 --limit 25
```

Filter to an explicit synthetic handle

```console
apple messages recent --handle +12125550100 --hours 24
```

Read only 1:1 conversations, skipping group chats

```console
apple messages recent --hours 24 --direct-only
```

## Notes

`messages recent` can include attachment-only messages that have no text body. Those rows use an empty `body` and carry the file details in `attachments`; a cache flag alone does not preserve a bodyless row when no joined attachment details exist. Attachment paths are not confined to the Messages attachments directory because sent items may point elsewhere on the local machine, but existence probing is limited to conservative local roots and uses symlink-aware traversal. Relative paths are omitted; automount and mounted-volume roots such as `/net`, `/home`, `/Network/Servers`, and `/Volumes` are reported without probing.

`group_name` and `chat_identifier` answer different questions and are not interchangeable: `group_name` is the chat's display name and is absent both for a 1:1 conversation and for a group that was never named, whereas `is_group` reports the chat's style directly, so an unnamed group still reads as a group. Any `chat.style` other than 43, including an absent or unrecognized one, is reported and filtered as non-group. A store old or pruned enough to lack `chat_message_join` reports null identifiers and `is_group: false` rather than failing the read, and `--direct-only` then excludes nothing, because nothing is known to be a group — that case sets `direct_only_applied: false` in the JSON and writes a warning to stderr, so a filter that could not be applied never passes silently on either channel.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../reference/json-contract.md) and [exit codes](../reference/exit-codes.md).

## See also

- [`apple messages`](./index.md)
