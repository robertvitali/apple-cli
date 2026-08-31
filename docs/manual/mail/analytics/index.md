# apple mail analytics

Derived inbox analytics (overview, needs-response, awaiting-reply, top-senders, stats, dashboard).

## Synopsis

```
apple mail analytics
```

## Subcommands

- [`awaiting-reply`](./awaiting-reply.md) — Sent messages with no reply yet (Sent↔Inbox cross-ref).
- [`dashboard`](./dashboard.md) — Write a static HTML inbox dashboard (EXECUTES by default; --dry-run previews).
- [`needs-response`](./needs-response.md) — Unread messages likely needing a reply (skips newsletters/noreply).
- [`overview`](./overview.md) — Inbox overview: unread-by-account, recent messages, suggested actions.
- [`stats`](./stats.md) — Volume/read-ratio/breakdown statistics.
- [`top-senders`](./top-senders.md) — Most frequent senders (or domains) in a mailbox.

## Inherited options

- `-h`, `--help`
  <br>Show help information.
- `--version`
  <br>Show the version.

## Output

`stdout` carries the JSON envelope; `stderr` carries human text. See [the JSON contract](../../reference/json-contract.md) and [exit codes](../../reference/exit-codes.md).

## See also

- [`apple mail`](../index.md)
