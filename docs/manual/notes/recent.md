# apple notes recent

Notes by modification date, newest first (default 10). CLI-only superset.

## Synopsis

```
apple notes recent [flags]
```

## Description

Returns the notes in scope ordered by modification date, newest first, cut to `--limit` (default 10). Each hit is the same `NoteSummary` shape `apple notes search` emits — `id`, `title`, `content` (always `""`), `tags` (always `[]`), `folder`, `account`, `created`, `modified` — so anything that already consumes a search hit consumes a recent hit unchanged. The envelope carries `notes`, `count`, `applied_limit`, and `sync_warning` when an iCloud sync is in progress. `--account` and `--folder` scope the enumeration the way `apple notes list` does; `--folder` accepts a nested path (`Parent/Child`, with `\/` escaping a literal slash in a folder name).

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

Ranking is done over the whole scope rather than by stopping early, so the newest note is never the one dropped, and a `count` below `applied_limit` means the scope was exhausted. It runs as two passes: one bulk read of every note's id and modification date — two Apple events, whatever the size of the scope — then the full per-note read for the few that survive the cut. So the cost tracks `--limit`, not the size of the library: measured on a ~210-note account, 1.1s at `--limit 5`, 1.7s at the default 10, and 6.4s at `--limit 50`, against the 45-second timeout every Notes command shares. Notes with the same modification date — second granularity makes ties ordinary — are ordered by `id`, so repeated runs return the same list; a note whose modification date Notes.app cannot report is ranked last rather than treated as just-modified, and a note deleted between the two passes simply drops out. `--limit` must be greater than 0, and `--folder` must name at least one path component; either failure is a `validation_error`, exit 64, raised before Notes.app is contacted. `--text` renders one line per note as `modified  title  (folder)` with an ISO-8601 timestamp; the folder is omitted on a note whose container Notes.app cannot report.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../reference/json-contract.md) and [exit codes](../reference/exit-codes.md).

## See also

- [`apple notes`](./index.md)
