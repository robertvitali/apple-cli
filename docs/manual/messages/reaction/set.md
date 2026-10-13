# apple messages reaction set

Set or replace the outgoing reaction on an exact message.

## Synopsis

```
apple messages reaction set [flags]
```

## Description

Sets or replaces the outgoing reaction on one exact Messages target. Supply exactly one conversation selector (`--chat-guid` or `--chat-rowid`) and one message selector (`--message-guid` or `--message-rowid`); `--part-index` selects a decoded native part. Use exactly one of `--reaction` for a standard reaction or `--emoji` for a custom reaction. The approved scope covers standard and custom set/replace, but the current candidate executes standard set/replace only; custom emoji set/replace is refused outside dry run.

## Options

- `--chat-guid` `<chat-guid>`
  <br>Conversation GUID from chat.guid.
- `--chat-rowid` `<chat-rowid>`
  <br>Local conversation ROWID from chat.ROWID.
- `--emoji` `<emoji>`
  <br>Custom emoji reaction. Accepted for preview; execution is refused until AX support is proven.
- `--experimental-ui-handoff`
  <br>Allow a modal handoff route when the Tapback picker hides the transcript; cannot prove original message continuity after modal, so keep Messages untouched during automation.
- `--message-guid` `<message-guid>`
  <br>Message GUID from message.guid.
- `--message-rowid` `<message-rowid>`
  <br>Local message ROWID from message.ROWID.
- `--part-index` `<part-index>`
  <br>Native Messages part index to mutate.
- `--reaction` `<reaction>`
  <br>Standard reaction: heart, like, dislike, laugh, emphasize, question.

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

Preview setting a heart reaction

```console
apple messages reaction set --chat-rowid 42 --message-rowid 123 --reaction heart --dry-run
```

Execute a standard reaction with explicit modal handoff opt-in

```console
APPLE_TEST_MODE=1 apple messages reaction set --chat-rowid 42 --message-rowid 123 --reaction heart --experimental-ui-handoff
```

## Notes

Dry run resolves the exact target and sandbox policy without driving UI or creating journal state. Execution checks the requested native picker button before deciding whether to press; an already-selected reaction performs no reaction click. The `--experimental-ui-handoff` flag only opts into the native picker transition that can hide the transcript; it does not choose the post-press verification branch. In either strict or experimental mode, the `.present` branch verifies the requested selected state on the same retained picker and button, then cancels that owned picker and verifies dismissal before ACK. If the picker disappears before state proof, the same `.absent` branch restores the exact original process, root, window, transcript and message identity route, confirms the picker is absent immediately before opening the canonical menu from that retained message, then verifies the requested selected state and owned cleanup. If the disappearance comes from a hidden-transcript transition, `--experimental-ui-handoff` must have been supplied. The fallback does not require the message to remain selected and does not deep-link or navigate to another message. Changed identities, unavailable controls, ambiguous ownership, a failed state check or cleanup failure leave the result uncertain. No branch repeats the reaction click. The parent accepts ACK only when bound to the pending operation and records observed state only after fresh database target identity and eligibility verification. Results report `reaction_changed` and `verification_source: ui_selected_state_and_database_identity`. `executed` means UI automation ran; it does not imply a reaction changed. Raw database author fields remain unchanged and may differ from local picker state in self-chats. The experimental handoff opt-in cannot prove original-message continuity during the modal transition, cancellation quiescence inside Messages or durable sync completion. Leave Messages untouched during execution. Preview and result identify `targeting_mode`; opt-in output explains the limitation. The flag does not enable custom emoji set/replace.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple messages reaction`](./index.md)
