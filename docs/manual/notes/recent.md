# apple notes recent

Notes by modification date, newest first (default 10). CLI-only superset.

## Synopsis

```
apple notes recent [flags]
```

## Description

Returns the notes in scope ordered by modification date, newest first, cut to `--limit` (default 10). Each hit is the same `NoteSummary` shape `apple notes search` emits — `id`, `title`, `content` (always `""`), `tags` (always `[]`), `folder`, `account`, `created`, `modified` — so anything that already consumes a search hit consumes a recent hit unchanged. The envelope carries `notes`, `count`, `applied_limit`, `limit_reached`, and `sync_warning` when an iCloud sync is in progress. With no `--account` the scope is the **default account only** (iCloud), not every account; `--account` selects a different one. `--folder` narrows further and accepts a nested path (`Parent/Child`, with `\/` escaping a literal slash in a folder name).

## Options

- `--account` `<account>`
  <br>Account to enumerate.
- `--folder` `<folder>`
  <br>Limit to a folder (nested paths ok).
- `--limit` `<limit>`
  <br>Max notes to return (default 10).

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

The ten most recently modified notes

```console
apple notes recent
```

The last three changes inside one nested folder

```console
apple notes recent --limit 3 --folder 'Projects/Drafts'
```

Scope to one account and read it as text

```console
apple notes recent --account 'iCloud' --text
```

## Notes

**Notes in Recently Deleted are enumerated.** Deleting a note updates its modification date, so a note you just deleted can be the most recently modified note in the account and lead this list. A hit's `folder` identifies it, and passing `--folder` scopes past the trash. There is no exclusion flag yet: the trash folder's AppleScript name is localized and Notes exposes no "deleted" property, so filtering it needs a design rather than a name match.

`limit_reached` is true when more notes were in scope than `--limit` asked for. Read that field, not `count`: a note can be ranked and then fail to read back — deleted between the two reads, untitled, or unreadable — and nothing backfills from the next candidate, so `count` can be below `applied_limit` while the scope still holds more.

The command runs as two reads: one bulk read of every note's id and modification date in scope — two Apple events, whatever the size of the scope — then the full per-note read for the few that survive the cut. So the per-note reads track `--limit`, while the id-and-date enumeration still touches the whole scope at that fixed cost. Measured on a few-hundred-note library: 1.1s at `--limit 5`, 1.7s at the default 10, 6.4s at `--limit 50`.

The 45-second AppleScript timeout bounds a single Apple event, not the command: this command issues two scripts, each retried once on a timeout, so the worst case is roughly three minutes, and the bulk read's in-process loop is not bounded at all. On expiry the caller gets `upstream_error`, exit 69, "Notes.app timed out…".

Notes with the same modification date — second granularity makes ties ordinary — are ordered by `id`, so repeated runs return the same list; a note whose modification date Notes.app cannot report is ranked last rather than treated as just-modified. `--limit` must be greater than 0, and `--folder` must name at least one path component (both `""` and `"///"` are refused); either failure is a `validation_error`, exit 64, raised before Notes.app is contacted. `--text` renders one line per note as `modified  title  (folder)` with an ISO-8601 timestamp; a note whose container Notes.app cannot report is shown in the folder `Notes`, which is the fallback the underlying script substitutes.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../reference/json-contract.md) and [exit codes](../reference/exit-codes.md).

## See also

- [`apple notes`](./index.md)
