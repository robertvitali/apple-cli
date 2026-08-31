---
title: Mail
---

# apple mail

Mail.app — send, search, rules, templates, analytics (union of both mail MCPs).

## Synopsis

```
apple mail
```

## Subcommands

- [`accounts`](./accounts/index.md) — List configured Mail accounts.
- [`analytics`](./analytics/index.md) — Derived inbox analytics (overview, needs-response, awaiting-reply, top-senders, stats, dashboard).
- [`attachments`](./attachments/index.md) — List and save message attachments.
- [`delete`](./delete.md) — Delete messages to Trash by id or --match (dry-run by default; --permanent erases from Trash IRREVERSIBLY).
- [`doctor`](./doctor.md) — Diagnose Mail access: Full Disk Access, Envelope Index, automation.
- [`draft`](./draft.md) — Manage drafts: list | create | send | open | delete (EXECUTES by default; --dry-run previews).
- [`draft-rich`](./draft-rich.md) — Generate a multipart .eml draft (EXECUTES by default; --dry-run previews; reliable HTML); opens a Mail compose window for review by default (--no-open to skip), or save it to Drafts.
- [`export`](./export.md) — Export messages to files (txt/html) for backup or analysis (EXECUTES by default; --dry-run previews).
- [`flag`](./flag.md) — Flag/unflag messages by id or --match, with optional color (EXECUTES by default; --dry-run previews).
- [`forward`](./forward.md) — Forward a message by id or --subject (EXECUTES by default; --dry-run previews).
- [`get`](./get.md) — Get one message by ROWID, RFC Message-ID, or message:// link.
- [`list`](./list.md) — List recent inbox messages (MCP B list_inbox_emails).
- [`mailboxes`](./mailboxes/index.md) — List and create mailboxes.
- [`mark`](./mark.md) — Mark messages read/unread by id or --match (EXECUTES by default; --dry-run previews).
- [`move`](./move.md) — Move messages by id or --match to a mailbox (EXECUTES by default; --dry-run previews).
- [`reply`](./reply.md) — Reply to a message by id or --subject (EXECUTES by default; --dry-run previews).
- [`rules`](./rules/index.md) — List and manage Mail rules.
- [`search`](./search.md) — Search messages (subject/sender/body/date/read/flagged/attachment; paginated).
- [`selected`](./selected.md) — Get the message(s) currently selected in Mail.app.
- [`send`](./send.md) — Compose an email (EXECUTES by default; --dry-run previews; plain/HTML/attachments; mode send|draft|open).
- [`templates`](./templates/index.md) — Manage email templates (list/get/save/delete/render).
- [`thread`](./thread.md) — All messages in a conversation — by message id (Apple conversation) or by subject keyword.
- [`trash`](./trash/index.md) — Trash operations.
- [`unread-counts`](./unread-counts.md) — Per-mailbox or per-account unread counts.

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
