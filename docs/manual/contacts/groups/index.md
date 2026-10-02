# apple contacts groups

List/inspect/manage contact groups and membership.

## Synopsis

```
apple contacts groups
```

## Subcommands

- [`add`](./add.md) — Add a contact to a group, additive (EXECUTES; --dry-run previews).
- [`create`](./create.md) — Create a contact group (EXECUTES by default; --dry-run previews).
- [`delete`](./delete.md) — Delete a group, members persist (requires APPLE_TEST_MODE=1).
- [`list`](./list.md) — List all contact groups across all containers.
- [`members`](./members.md) — List contacts in a group (distinct not_found vs empty).
- [`remove`](./remove.md) — Remove a contact from a group (EXECUTES; --dry-run previews).
- [`rename`](./rename.md) — Rename a contact group (EXECUTES by default; --dry-run previews).

## Inherited options

- `-h`, `--help`
  <br>Show help information.
- `--version`
  <br>Show the version.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple contacts`](../index.md)
