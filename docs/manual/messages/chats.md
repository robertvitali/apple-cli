# apple messages chats

List named group chats (chat_identifier, display_name, last activity, participants).

## Synopsis

```
apple messages chats [flags]
```

## Description

Lists named chats with the id needed to send to them, plus how recently each was active and who is in it. `last_activity` is the ISO-8601 UTC date of the newest message in the chat; `last_activity_timestamp` is the RAW value chat.db stores for it, which is not a fixed unit — nanoseconds since the Apple epoch (2001-01-01 UTC) on modern rows but SECONDS on legacy ones, the same greater-than-10-digit heuristic a message's `timestamp` uses. Sorting on it is safe, between chats as well as within one, because a nanosecond value always exceeds a seconds value and the nanosecond rows are always the newer ones — a larger number is always a more recent message. Arithmetic on it is not: dividing by 1e9 gives a 1970 date on a chat whose newest message is old, and the difference between two of these values is meaningless when one is in each mode. Use `last_activity` for anything that treats the value as a time. Both are null for a chat with no messages. `participants` is the chat's handle ids (phone numbers or email addresses), possibly empty. They are raw, as chat.db stores them — not resolved to contact names the way a message's `sender` is — and they do not include you, since the store records only the other parties. The list is not deduplicated: one person can appear twice if the store holds a separate handle for them per service, so read it as a list rather than a set. `--name` keeps only chats whose display name contains the given text, case-insensitively, and is echoed back as `name_filter`; an EMPTY `--name` is treated as no filter at all and echoes null, so the field never claims a filter that did not narrow anything; `--limit` caps how many are returned and accepts 1-10000, rejecting anything outside that range with a validation error. Without either flag the listing is exactly what it always was: named chats only, in chat row order.

## Options

- `--limit` `<limit>`
  <br>Max chats to return (default: all).
- `--name` `<name>`
  <br>Keep only chats whose display name contains this text (case-insensitive).

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

List every named chat with its activity and members

```console
apple messages chats
```

Find a chat by part of its name

```console
apple messages chats --name "book club"
```

The first five named chats

```console
apple messages chats --limit 5
```

## Notes

Only NAMED chats are listed — a chat whose `display_name` is empty or absent (every 1:1 conversation, and any group nobody has named) does not appear, which is the behavior this command has always had. Ordering follows the chat table's own row order and `--name` and `--limit` do not change it: the filter is applied first, then the limit, so `--name X --limit 1` is the first chat matching X and not the first chat overall. A store that cannot be joined to its messages reports null activity rather than failing.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../reference/json-contract.md) and [exit codes](../reference/exit-codes.md).

## See also

- [`apple messages`](./index.md)
