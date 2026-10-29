# apple messages edit

Edit an eligible own sent text part and verify persisted content and history.

## Synopsis

```
apple messages edit [flags]
```

## Description

Edits one exact native text part of an eligible own sent iMessage. Select exactly one chat ROWID or GUID, exactly one message ROWID or GUID, and the native part index from messages get. Pass the new text with --replacement-text; --text remains the global output-format flag. Execution requires --experimental-ui-handoff.

## Options

- `--chat-guid` `<chat-guid>`
- `--chat-rowid` `<chat-rowid>`
- `--experimental-ui-handoff`
  <br>Allow bounded Messages UI editing.
- `--message-guid` `<message-guid>`
- `--message-rowid` `<message-rowid>`
- `--part-index` `<part-index>`
  <br>Exact native text part index from messages get.
- `--replacement-text` `<replacement-text>`
  <br>Replacement text for the selected native part.

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

Preview an exact-part edit

```console
apple messages edit --chat-rowid 42 --message-rowid 123 --part-index 0 --replacement-text 'Revised text' --dry-run
```

## Notes

Use --dry-run to inspect previous_text and replacement_text without a UI worker or journal mutation. Eligibility is provisional until execution: the command requires an own sent iMessage, available native history, fewer than five recorded edits across the message, and a send time within fifteen minutes. Conservative timestamp handling can expire eligibility slightly early. SMS/MMS/RCS and native attachment parts are not supported. Unchanged replacement text is refused. The original selected text must fit the editor readback limit of 4,096 UTF-8 bytes; larger originals are refused before navigation. The entire encoded worker request, including target binding and replacement, must fit 4 KiB; the usable text budget is smaller.

Execution uses the shared Messages automation lease and journal. It refuses existing drafts or edit controls before navigation, requires the exact selected native part and an owned editor, and attempts each native mutation once. It does not clear or cancel a user draft. Missing or ambiguous native evidence fails closed. Both the worker and parent require persisted replacement content and a matching appended native history transition before success. This proves the observed local state, not delivery or synchronization to other devices. Older recipients may see different edit behavior.

An uncertain result may leave a pending operation or an editor containing text. Inspect messages automation status and the native UI, then recover before retrying; the command does not automatically retry a send or clean up uncertain UI state. Test mode requires a labeled target, one allowed direct recipient, and a replacement that preserves the label. Native edit reliability and editor ownership across supported systems have not yet been qualified.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../reference/json-contract.md) and [exit codes](../reference/exit-codes.md).

## See also

- [`apple messages`](./index.md)
