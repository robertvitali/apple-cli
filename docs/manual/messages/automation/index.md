# apple messages automation

Read or recover shared Messages automation state.

## Synopsis

```
apple messages automation
```

## Description

Reads or explicitly recovers the shared Messages UI automation journal used by experimental reaction writes.

## Subcommands

- [`recover`](./recover.md) — Explicitly recover a pending Messages automation operation.
- [`status`](./status.md) — Read pending Messages automation state.

## Inherited options

- `-h`, `--help`
  <br>Show help information.
- `--version`
  <br>Show the version.

## Examples

Read the shared automation state

```console
apple messages automation status
```

Preview explicit recovery

```console
apple messages automation recover --op-id 00000000-0000-0000-0000-000000000000 --acknowledge-possible-late-effects --dry-run
```

## Notes

Reaction writes record pending state before handing work to the UI worker. A timeout, cancellation, failed verification or crash after possible handoff leaves that state unresolved and blocks later Messages UI writes. Status is read-only. Recovery is explicit and requires acknowledgement of possible late effects; it is not a proof that Messages cancelled or quiesced the original request.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple messages`](../index.md)
