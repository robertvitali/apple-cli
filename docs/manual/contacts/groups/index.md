# apple contacts groups

List/inspect/manage contact groups and membership.

## Synopsis

```
apple contacts groups
```

## Subcommands

- [`add`](./add.md) — Add a contact to a group, additive (EXECUTES; --dry-run previews). → add_contact_to_group
- [`create`](./create.md) — Create a contact group (EXECUTES by default; --dry-run previews). → create_group
- [`delete`](./delete.md) — Delete a group, members persist (requires APPLE_TEST_MODE=1, like the MCP). → delete_group
- [`list`](./list.md) — List all contact groups across all containers. → list_groups
- [`members`](./members.md) — List contacts in a group (distinct not_found vs empty). → get_contacts_in_group
- [`remove`](./remove.md) — Remove a contact from a group (EXECUTES; --dry-run previews). → remove_contact_from_group
- [`rename`](./rename.md) — Rename a contact group (EXECUTES by default; --dry-run previews). → rename_group

## Inherited options

- `-h`, `--help`
  <br>Show help information.
- `--version`
  <br>Show the version.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple contacts`](../index.md)
