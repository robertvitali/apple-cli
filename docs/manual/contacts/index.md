---
title: Contacts
---

# apple contacts

Contacts — CRUD, groups, vCard, notes, photos (ports apple-contacts-mcp).

## Synopsis

```
apple contacts
```

## Subcommands

- [`auth`](./auth.md) — Report Contacts TCC authorization status (never prompts). → check_authorization
- [`containers`](./containers/index.md) — List contact containers (accounts).
- [`create`](./create.md) — Create a contact (EXECUTES by default; --dry-run previews). → create_contact
- [`delete`](./delete.md) — Delete a contact (requires APPLE_TEST_MODE=1, like the MCP). → delete_contact
- [`get`](./get.md) — Fetch one contact by identifier (full P1 fields). → get_contact
- [`groups`](./groups/index.md) — List/inspect/manage contact groups and membership.
- [`list`](./list.md) — List contacts (paged, 4-field summaries). → list_contacts
- [`note`](./note/index.md) — Read/write a contact's note (AppleScript; entitlement-gated field).
- [`photo`](./photo/index.md) — Read/write a contact's photo.
- [`search`](./search.md) — Find contacts by name|phone|email|org (exactly one). → search_contacts
- [`update`](./update.md) — Update a contact, None=skip/""=clear/value=set (EXECUTES; --dry-run previews). → update_contact
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
