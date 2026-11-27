# apple messages watch

Observe Messages changes as newline-delimited JSON and resume from a saved cursor.

## Synopsis

```
apple messages watch [flags]
```

## Description

Write one versioned JSON record per line. A fresh stream takes a baseline, then reports observed changes. A resumed stream replays events after the supplied cursor before reconciling changes observed while the watcher was offline.

## Options

- `--conversation` `<conversation>` *(repeatable)*
  <br>Exact conversation GUID. Repeat for each conversation.
- `--duration` `<duration>` *(repeatable)*
  <br>Stop observing after this many seconds. Omit to keep watching.
- `--poll-interval` `<poll-interval>` *(repeatable)*
  <br>Minimum wait between polls in seconds, from 0.25 to 60 (default 1). Slow cycles increase the wait.
- `--resume` `<resume>` *(repeatable)*
  <br>Resume strictly after this event cursor.

## Inherited options

- `-h`, `--help`
  <br>Show help information.
- `--version`
  <br>Show the version.

## Examples

Watch an exact conversation for five seconds

```console
apple messages watch --conversation "$CHAT_GUID" --duration 5
```

Resume after the last event you processed

```console
apple messages watch --resume "$CURSOR"
```

## Notes

Event records include exact conversation and message identifiers. A conversation identifier can contain a phone number or email address. A cursor identifies the stream, its filter digest, and the sequence, so someone with two cursors can link activity from the same stream. Treat saved records and cursors as private.

For a new stream, save `data.last_committed_cursor` from `stream_started` as the initial checkpoint. After that, advance the checkpoint only after processing a complete `event` record, using its `data.cursor`. The `last_committed_cursor` on `stream_resumed` and `observation_restored` describes the journal head and can include events you have yet to receive. If the pipe closes mid-line, discard that line and use your saved checkpoint. An event delivered before its cursor was saved can appear again.

A resumed stream keeps its original conversation filter. If you supply the filter again, it must identify the same conversations. Polling observes snapshots and can coalesce intermediate changes. The watcher waits at least the requested poll interval between observations. If a cycle takes longer to capture and deliver changes, the watcher waits at least four times that cycle’s duration before polling again.

A control record has `data.record_type` such as `stream_started` or `stream_resumed`. An event has `data.record_type` equal to `event`, a `data.cursor`, and a `data.event` object with a sequence and change categories. Its `data.delivery_mode` is `live` or `replay`.

Each stream tracks up to 250,000 message-to-conversation memberships to compare observations. If the selected conversations exceed that limit, the watcher reports a capacity error. To watch a smaller set, start a new stream with a narrower conversation filter. The stream database can grow to 512 MiB, with a separate limit of 768 MiB for its SQLite rollback journal.

Each stream retains at most 100,000 events and 64 MiB of event payload. If your checkpoint expires, the command reports `resynchronization_required`. Reconcile the current Messages state for your filter, then start a fresh stream and save its initial checkpoint. Events evicted from the old journal cannot be replayed.

Streams persist after the watcher exits. The local registry holds up to four streams, including ones being created or retired. Run `apple messages event-streams list` to inspect their IDs and retention bounds.

If a new baseline fails before `stream_started` and the error includes `stream_id=<id>`, look up that exact ID. If that ID is listed as `incomplete`, it occupies a slot and has no usable cursor. To reclaim that slot, set `STREAM_ID` to the ID from the error and preview retirement with `apple messages event-streams retire "$STREAM_ID" --dry-run`. The preview leaves the slot occupied. After checking the ID in the preview, free that slot with `apple messages event-streams retire "$STREAM_ID" --execute`. Correct the original baseline error before starting a fresh stream.

If startup returns `streamRegistryFull`, list the streams and use the same preview and retirement steps for one you no longer need. Retiring a stream invalidates its saved cursors.

Every control carries `stream_id` and `last_committed_cursor`. `stream_started` reports head sequence `"0"` and a null oldest sequence. `stream_resumed` includes the requested `resume_after_cursor`, the current `head_sequence`, and `oldest_retained_sequence` (null when no events are retained). Sequence fields are decimal strings. For example, if you resume after sequence 2 and the control reports head 10, keep your sequence-2 checkpoint until you process event 3.

`observation_gap` reports a temporary interruption reading the source. `observation_restored` announces successful reconciliation before its events are delivered. `schema_changed` and `capacity_exceeded` end observation and are followed by an error envelope when output is writable. The capacity control can include a `limit` field. Keep your last processed checkpoint on errors.

An event includes `event_id`, `stream_id`, `source_epoch`, `sequence`, `observed_at`, `capture_mode`, `conversation_guid`, `message_guid`, `message_rowid`, `change_categories`, `availability` and `association` inside `data.event`. The row ID is null for a disappeared membership. Availability records why a facet is missing or unreadable. Association can have null target, part or native type when unknown or inapplicable.

An `attachment` event reports a change to stored attachment metadata or membership. If only the local file appears or disappears, its download status can change without a watch event.

One event can have several change categories. For example, retracting an attachment can change its membership, the message content, and the edit timestamp. A change to the binary encoding of summary metadata alone is reported as `native_context` when the decoded edit and retraction fields are unchanged.

When the requested duration ends, resume from your saved checkpoint. A change committed just before the deadline can appear on the next run. Startup validation, recovery and output failures still return errors.

## Output

`stdout` carries one JSON record per line. `stderr` carries human-readable diagnostics. See [the JSON contract](../reference/json-contract.md) and [exit codes](../reference/exit-codes.md).

## See also

- [`apple messages`](./index.md)
