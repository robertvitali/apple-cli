# Exit codes

Every `apple` command exits with one of a fixed set of codes. They follow the BSD
`sysexits.h` convention, so a caller can branch on the class of failure without parsing
any output.

| Code | Name | `error.type` | Meaning |
|-----:|------|--------------|---------|
| `0` | success | — | The command completed. `ok` is `true`. |
| `64` | usage | `validation_error` | Bad flags or arguments. The command was never attempted. |
| `65` | not found | `not_found` | The requested entity does not exist — an unknown message id, mailbox, contact, list, or calendar. |
| `69` | upstream unavailable | `upstream_error` | The Apple app or its database could not be reached: Mail not running, an AppleScript failure, a locked or missing store. |
| `70` | internal | `unknown`, `not_implemented` | An unexpected internal error. Worth reporting as a bug. |
| `77` | permission denied | `authorization_denied` | macOS TCC has not granted the access this command needs — Full Disk Access, Automation, Contacts, Calendars, or Reminders. |

`safety_violation` is also emitted as an `error.type`; it accompanies a refusal by one of
the safety gates (a sandbox restriction, a recipient allowlist, or a guard on an
irreversible operation) rather than introducing an exit code of its own.

## Branching on failures

Exit code first, `error.type` second. The code is stable and coarse; the type names the
specific condition.

```console
apple mail get "$ID" >/tmp/out.json
case $? in
  0)  jq -r '.data.message.subject' /tmp/out.json ;;
  65) echo "no such message" ;;
  77) echo "grant Full Disk Access to your terminal, then retry" ;;
  *)  jq -r '.error.message' /tmp/out.json >&2; exit 1 ;;
esac
```

## Permission failures are actionable

A `77` carries a `remediation` field naming the grant that is missing, because "permission
denied" on its own is not something a caller can act on:

```json
{
  "schema_version": 1,
  "tool": "mail",
  "ok": false,
  "error": {
    "type": "authorization_denied",
    "message": "Mail's Envelope Index is not readable.",
    "remediation": "Grant Full Disk Access to your terminal in System Settings › Privacy & Security."
  }
}
```

Each domain also ships a `doctor` subcommand that reports which grants are present without
attempting real work — `apple mail doctor`, `apple notes doctor`, and so on.

## Stability

Exit codes are part of the versioned agent contract. Changing what a code means, or
retiring one, is a breaking change: it is flagged `BREAKING` in the changelog and reasoned
about against `schema_version`. See [the JSON contract](./json-contract.md).
