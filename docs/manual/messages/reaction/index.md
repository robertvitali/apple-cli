# apple messages reaction

Inspect or mutate an exact message reaction.

## Synopsis

```
apple messages reaction
```

## Description

Groups exact Messages reaction inspection and experimental standard reaction writes. Reads are database-only; writes execute by default unless `--dry-run` or `APPLE_DRY_RUN=1` is active and always report `experimental: true`.

## Subcommands

- [`inspect`](./inspect.md) — Inspect outgoing and incoming reactions for an exact message.
- [`remove`](./remove.md) — Remove an outgoing reaction from an exact message.
- [`set`](./set.md) — Set or replace the outgoing reaction on an exact message.

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

Inspect reactions for one message

```console
apple messages reaction inspect --chat-rowid 42 --message-rowid 123
```

Preview setting a standard reaction

```console
apple messages reaction set --chat-rowid 42 --message-rowid 123 --reaction heart --dry-run
```

## Notes

Reaction writes use exact conversation, message and native-part identity. Agent-run live writes must use the sandbox. The sandbox requires the target message text to start with `apple-cli-test`, requires exactly one selected participant, and confines that participant to the allowed test recipients; sandbox reaction writes refuse group conversations. Production writes may target exact group chat GUIDs or ROWIDs. Standard reactions are `heart`, `like`, `dislike`, `laugh`, `emphasize` and `question`. Custom emoji reactions are accepted for preview with `--emoji`, but execution is refused until the native UI path is proven. Successful writes require native picker selected-state verification plus fresh database target identity and eligibility; raw database authorship is returned as recorded and is not used alone to prove the current user’s reaction.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple messages`](../index.md)
