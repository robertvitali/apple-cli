# apple messages reaction remove

Remove an outgoing reaction from an exact message.

## Synopsis

```
apple messages reaction remove [flags]
```

## Description

Removes an outgoing reaction from one exact Messages target. Select the target with the same exact chat/message/native-part selectors as `reaction set`. Pass `--reaction` for a standard reaction or `--emoji` for explicit custom-emoji removal. Omit both only when database evidence resolves exactly one outgoing standard reaction. Explicit custom removal is experimental and requires an exact native picker button. A bounded settling interval precedes the single press, with exact-state revalidation after the wait. Implicit custom removal remains refused outside dry run.

## Options

- `--chat-guid` `<chat-guid>`
  <br>Conversation GUID from chat.guid.
- `--chat-rowid` `<chat-rowid>`
  <br>Local conversation ROWID from chat.ROWID.
- `--emoji` `<emoji>`
  <br>Custom emoji reaction to remove. Explicit custom emoji removal is experimental; implicit custom removal remains refused.
- `--experimental-ui-handoff`
  <br>Allow a modal handoff route when the Tapback picker hides the transcript; cannot prove original message continuity after modal, so keep Messages untouched during automation.
- `--message-guid` `<message-guid>`
  <br>Message GUID from message.guid.
- `--message-rowid` `<message-rowid>`
  <br>Local message ROWID from message.ROWID.
- `--part-index` `<part-index>`
  <br>Native Messages part index to mutate.
- `--reaction` `<reaction>`
  <br>Standard reaction to remove: heart, like, dislike, laugh, emphasize, question.

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

Preview removing a like reaction

```console
apple messages reaction remove --chat-rowid 42 --message-rowid 123 --reaction like --dry-run
```

Execute an explicit removal with handoff opt-in

```console
APPLE_TEST_MODE=1 apple messages reaction remove --chat-rowid 42 --message-rowid 123 --reaction like --experimental-ui-handoff
```

## Notes

The same exact-target, dry-run, sandbox, pending-operation and UI verification rules as `reaction set` apply. An explicit requested reaction is removed only if its native button is selected; an unselected button is a verified no-change result with `reaction_changed: false`. Database outgoing absence alone never proves local UI absence. When the database cannot resolve one reaction for implicit removal, specify `--reaction` or `--emoji` explicitly; the command refuses instead of guessing or reporting a false no-op. The `--experimental-ui-handoff` flag only opts into transcript-hidden picker transitions; retained-picker `.present` proof and restored-route `.absent` proof are post-press verification branches available under the same identity rules described for `reaction set`. Results report `reaction_changed` and `verification_source: ui_selected_state_and_database_identity` while retaining raw database authorship. The experimental handoff opt-in cannot prove original-message continuity during the modal transition, cancellation quiescence inside Messages or durable sync completion. Leave Messages untouched during execution. Post-verification cannot undo a reaction redirected by desktop interference. Custom emoji identifiers are matched byte-for-byte, including variation selectors, skin tones and ZWJ sequences; the command never substitutes a base emoji. A repeated custom removal is a verified no-op only when the exact button is still exposed and unselected. A missing button is not evidence of absence. If the button disappears after a press, verification fails and the operation remains pending instead of claiming success. General custom-removal idempotency and live reliability are not established.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple messages reaction`](./index.md)
