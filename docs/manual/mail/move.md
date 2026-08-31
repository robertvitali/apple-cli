# apple mail move

Move messages by id or --match to a mailbox (EXECUTES by default; --dry-run previews).

## Synopsis

```
apple mail move [<ids>...] [flags]
```

## Options

- `<ids>`
  <br>Message ids (or use --match).
- `--account` `<account>`
  <br>Source account (name or UUID).
- `--all`
  <br>Operate on the WHOLE mailbox with no subject/sender filter required (MCP B apply_to_all); if a --match filter is also given, that filter still narrows the set. Bounded by --max. MUTATES REAL MAIL when unsandboxed — preview with --dry-run first. Inside the sandbox it stays per-message label-gated: a batch containing any unlabeled real message aborts before mutating anything.
- `--gmail-mode`
  <br>Gmail label-move handling (copy + delete).
- `--match-sender` `<match-sender>`
  <br>Match sender substring.
- `--match-subject` `<match-subject>` *(repeatable)*
  <br>Match subject keyword (repeatable — matches ANY, MCP B subject_keywords).
- `--max` `<max>`
  <br>Max messages to affect (safety cap). Per-op defaults mirror MCP B: move 50 (max_moves), mark/flag 10 (max_updates), delete 5 (max_deletes).
- `--older-than-days` `<older-than-days>`
  <br>Only messages older than N days.
- `--only-read`
  <br>Only already-read messages.
- `--source` `<source>`
  <br>Source mailbox (default INBOX for filter targeting; on the explicit-ids path it narrows the scope ONLY when typed, with --account).
- `--to` `<to>`
  <br>Destination mailbox (use '/' for nested).

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

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../reference/json-contract.md) and [exit codes](../reference/exit-codes.md).

## See also

- [`apple mail`](./index.md)
