---
title: Messages
---

# apple messages

iMessage / SMS — send, read, search (ports mac_messages_mcp).

## Synopsis

```
apple messages
```

## Subcommands

- [`chats`](./chats.md) — List named group chats (chat_identifier + display_name).
- [`check-addressbook`](./check-addressbook.md) — Diagnose AddressBook *.abcddb access + required tables + contact counts.
- [`check-availability`](./check-availability.md) — Check (history-based) whether a recipient has iMessage, else SMS fallback.
- [`check-contacts`](./check-contacts.md) — Enumerate AddressBook contacts (count + sample number→name entries).
- [`check-db`](./check-db.md) — Diagnose Messages chat.db access + required tables.
- [`doctor`](./doctor.md) — One-shot health check: FDA + chat.db + AddressBook diagnostics.
- [`find-contact`](./find-contact.md) — Fuzzy-search contacts by name/nickname; ranked candidates with confidence scores.
- [`recent`](./recent.md) — Recent messages across ALL chats in the last N hours (optionally by contact).
- [`search`](./search.md) — Search messages: fuzzy (WRatio) + threshold + time window (or contains/exact).
- [`send`](./send.md) — Send an iMessage/SMS (sends on call, like the MCP; --dry-run previews).

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

- [`apple`](../index.md)
