---
title: Contacts
---

# apple contacts

Contacts — CRUD, groups, vCard, notes, photos.

## Synopsis

```
apple contacts
```

## Subcommands

- [`auth`](./auth.md) — Report Contacts TCC authorization status; prompts only with --request.
- [`containers`](./containers/index.md) — List contact containers (accounts).
- [`create`](./create.md) — Create a contact (EXECUTES by default; --dry-run previews).
- [`delete`](./delete.md) — Delete a contact (requires APPLE_TEST_MODE=1).
- [`get`](./get.md) — Fetch one contact by identifier (--niche adds dates, social profiles, relations and instant messages).
- [`groups`](./groups/index.md) — List/inspect/manage contact groups and membership.
- [`list`](./list.md) — List contacts (paged, 4-field summaries).
- [`note`](./note/index.md) — Read/write a contact's note (AppleScript; entitlement-gated field).
- [`photo`](./photo/index.md) — Read/write a contact's photo.
- [`search`](./search.md) — Find contacts by name|phone|email|org (exactly one).
- [`update`](./update.md) — Update a contact: omit a field to keep it, "" clears it, a value sets it (EXECUTES; --dry-run previews).
- [`vcard`](./vcard/index.md) — Export/import contacts as vCard.

## Inherited options

- `-h`, `--help`
  <br>Show help information.
- `--version`
  <br>Show the version.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../reference/json-contract.md) and [exit codes](../reference/exit-codes.md).

## See also

- [`apple`](../index.md)
