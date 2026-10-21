# apple messages reply send

Send a text or attachment reply to an exact message in a direct chat.

## Synopsis

```
apple messages reply send [flags]
```

## Description

Sends a bounded text reply or one single-file attachment reply to one exact message in a direct Messages conversation. Select the conversation with exactly one of `--chat-rowid` or `--chat-guid`; select the message with exactly one of `--message-rowid` or `--message-guid`; pass `--part-index` for the decoded native part and exactly one of `--body` or `--file` for reply content.

## Options

- `--body` `<body>`
  <br>Reply text. Must be nonempty and no more than 2048 UTF-8 bytes. Mutually exclusive with --file.
- `--chat-guid` `<chat-guid>`
  <br>Conversation GUID from chat.guid.
- `--chat-rowid` `<chat-rowid>`
  <br>Local conversation ROWID from chat.ROWID.
- `--experimental-ui-handoff`
  <br>Allow the bounded Messages UI handoff required to send the reply.
- `--file` `<file>`
  <br>Single attachment file to send as the reply. Mutually exclusive with --body.
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

Preview a sandboxed exact text reply

```console
apple messages reply send --chat-rowid 42 --message-rowid 123 --part-index 2 --body 'apple-cli-test reply' --dry-run --test-mode
```

Preview a sandboxed exact attachment reply

```console
apple messages reply send --chat-rowid 42 --message-rowid 123 --part-index 2 --file ./apple-cli-test.png --dry-run --test-mode
```

Execute a text reply with explicit UI handoff opt-in

```console
APPLE_TEST_MODE=1 apple messages reply send --chat-rowid 42 --message-rowid 123 --part-index 2 --body 'apple-cli-test reply' --experimental-ui-handoff
```

Execute an attachment reply with explicit UI handoff opt-in

```console
APPLE_TEST_MODE=1 apple messages reply send --chat-rowid 42 --message-rowid 123 --part-index 2 --file ./apple-cli-test.png --experimental-ui-handoff
```

## Notes

Pass exactly one of `--body` or `--file`. Text replies must be nonempty and at most 2048 UTF-8 bytes; `--body` is used instead of `--text` because `--text` is the global output-format flag. Attachment replies accept one local regular file through the shared attachment source policy, capped at 25 MiB. The private draft copy retains the resolved source filename and extension. Its filename must be at most 255 UTF-8 bytes and cannot contain a slash, NUL, or ASCII control character. Verification requires unchanged file content: if Messages transforms or reencodes the attachment, a size or hash mismatch leaves the operation uncertain even if the file was sent. Do not resend to resolve that uncertainty. Execution copies that file into an operation-owned private draft location before the UI handoff, pastes exactly once, accepts only the observed native attachment marker shape as pre-send UI readiness, posts one Return key pair, and then requires strict database proof for one fresh outgoing reply row in the selected chat with integer `is_sent = 1` and `error = 0`, plus one attachment join whose safe Messages attachment file matches the copied content hash and size. Pending send status is polled within the operation deadline; unavailable, malformed or failed status cannot verify success. This is local observed state, not a recipient-delivery or cross-device synchronization guarantee. Draft UI metadata is not treated as file identity proof. Successful text results report `verification_source: ui_clean_state_and_database_correspondence`; successful attachment results report `verification_source: ui_clean_state_database_correspondence_and_attachment_content` and an `attachment` object with `attachment_rowid`, `attachment_guid`, `attachment_filename`, `attachment_sha256`, `attachment_size`, and `copy_cleanup`. The private copy is reclaimed only after the journal durably records observed success. `copy_cleanup: complete` means reclamation finished; `incomplete` means some private staging content may remain, with `copy_directory` identifying its directory for inspection. Incomplete copy cleanup does not reverse a verified send and must not prompt a resend. A process crash between journal resolution and reclamation can also leave staging content behind. Both modes report `sent_message_rowid`, `sent_message_guid`, `parent_message_guid`, `parent_native_part`, and the exact target. Dry run performs no UI work, creates no journal entry, and for attachments creates no draft copy. If Messages already restored the clean main composer after send, no cancel is sent; if an owned reply composer remains empty, exactly one `AXCancel` closes it. The command preserves nonempty drafts on failure because the native marker cannot prove attachment ownership. After the first send dispatch, it never retries Return. Database thread-originator metadata alone never authorizes a write; the parent accepts the worker ACK only after strict same-chat new-row proof. If verification or UI/clipboard cleanup fails after handoff, the command reports uncertainty and acknowledges the send may have occurred. Nested targets require one unambiguous, single-part selected message linked to one unique single-part root in the same direct conversation. Multi-hop chains and group replies remain unsupported. The selected message and resolved root are bound independently through preflight and final verification. The target includes selected `is_from_me` and a `thread_root` object; `root_is_from_me` continues to describe the root. Messages may persist the thread root instead of the selected reply as the new row's originator. Such a result requires the verified UI ACK, an unchanged bound relationship, and exactly one fresh owned outgoing row in the bounded scan, including unrelated outgoing text or attachments when checking ambiguity. Both strict and thread-root judges use that same scan. The result adds `observed_thread_originator`, `persisted_parent_matches_requested`, and `reply_relationship` (`requested-target` or `thread-root`). Existing `parent_message_guid` and `parent_native_part` always describe the observed native pair. A thread-root result establishes thread correspondence, not a database-proven immediate parent. Existing `verification_source` values remain unchanged; `verification` explicitly describes thread-root correspondence when applicable. Dry-run previews contain no observed relationship result. A verification-stage window or relationship drift may include a value-free reason suffix; it remains a refusal and never causes a retry.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple messages reply`](./index.md)
