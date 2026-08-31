# The JSON contract

`apple` is built to be driven by programs. **JSON on `stdout` is the default and the
versioned interface**; human-readable text is an opt-out via `--text` and is explicitly
*not* part of the contract.

The split is absolute: `stdout` carries the JSON envelope and nothing else, `stderr`
carries human-facing text. A caller can pipe `stdout` straight into a parser without
filtering.

## The envelope

Every command — success or failure — emits exactly one envelope.

```json
{
  "schema_version": 1,
  "tool": "mail",
  "ok": true,
  "data": { }
}
```

```json
{
  "schema_version": 1,
  "tool": "mail",
  "ok": false,
  "error": {
    "type": "not_found",
    "message": "No message with that id."
  }
}
```

| Field | Always present | Meaning |
|---|---|---|
| `schema_version` | yes | Integer. Bumps **only** on a breaking output-shape change. |
| `tool` | yes | What produced the envelope: `messages`, `mail`, `contacts`, `notes`, `calendar`, `reminders`, or `version`. Treat this as **open-ended** — do not validate against a fixed set, or a future surface will make your parser reject a valid envelope. |
| `ok` | yes | `true` on success, `false` on failure. Branch on this, not on the presence of a key. |
| `data` | on success | The payload. Shape varies per command. |
| `error` | on failure | `type`, `message`, and sometimes `remediation` / `status`. See [exit codes](./exit-codes.md). |

## Rules a consumer can rely on

- **Property names are wire keys, verbatim.** No case conversion is applied, so payload
  fields are `snake_case` as written.
- **Dates are ISO-8601.**
- **Unknown fields must be ignored.** New optional fields are added in MINOR releases
  without bumping `schema_version`; a consumer that rejects unknown keys will break on a
  routine release, and that breakage is the consumer's.
- **`ok` is authoritative.** Do not infer failure from an empty `data` — an empty result
  set is a success.

## Versioning

`schema_version` is the machine contract and it is what agents should key on. It is
independent of the release number: the CLI's MAJOR tracks the newest macOS validated
against, not the output shape.

Read it at runtime for capability detection:

```console
apple version
```

Adding an optional field is a MINOR release and leaves `schema_version` alone. Removing,
renaming, or retyping a field — or changing an enum or an exit code — is breaking: it is
flagged `BREAKING` in the changelog, reasoned about against `schema_version` explicitly,
and ships in at least a MINOR. It never bumps MAJOR.

## Worked example

```console
apple mail search --subject invoice --limit 5 | jq -r '.data.messages[].subject'
```

Guarding properly, using both halves of the contract:

```console
if out=$(apple contacts get "$ID"); then
  echo "$out" | jq -r '.data.contact | .given_name + " " + .family_name'
else
  echo "$out" | jq -r '.error.message' >&2
fi
```

Two things to copy from that, both of which cost real debugging time to learn. The
payload is nested under `contact`, and a contact has **no `name` key** — names are
`given_name` / `family_name` / `middle_name` and the rest. Check the command's page for
the actual field list rather than guessing, because `jq` prints `null` and still
**exits 0** for a path that does not exist, so a wrong path fails silently.

Both branches parse `stdout` as JSON, because the envelope is emitted on failure too.
