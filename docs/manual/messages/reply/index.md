# apple messages reply

Send an exact threaded reply in Messages.

## Synopsis

```
apple messages reply
```

## Description

Groups experimental exact threaded reply sends for Messages. The current subcommand sends a text reply to a proven root message in a direct conversation.

## Subcommands

- [`send`](./send.md) — Send a text reply to an exact root message in a direct chat.

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

Preview an exact text reply

```console
apple messages reply send --chat-rowid 42 --message-rowid 123 --part-index 2 --body 'apple-cli-test reply' --dry-run
```

## Notes

Reply sends are experimental UI handoffs. Dry run resolves the exact root target and sandbox policy without driving Messages UI or creating journal state. Execution requires `--experimental-ui-handoff`, the shared Messages automation journal, Accessibility trust and a direct one-recipient conversation. Group replies and attachment replies are not enabled in this unit. Agent-run live writes must use the sandbox and target only operator-approved test recipients.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple messages`](../index.md)
