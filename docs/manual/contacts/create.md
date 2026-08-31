# apple contacts create

Create a contact (EXECUTES by default; --dry-run previews). → create_contact

## Synopsis

```
apple contacts create [flags]
```

## Options

- `--birthday` `<birthday>`
  <br>Birthday as YYYY-MM-DD or MM-DD.
- `--container` `<container>`
  <br>Create in this container id (default: the default container).
- `--department` `<department>`
  <br>Department.
- `--email` `<email>` *(repeatable)*
  <br>Email as label:value (repeatable).
- `--first`, `--given` `<first>`
  <br>Given name.
- `--group` `<group>`
  <br>Add the new contact to this group id.
- `--json` `<json>`
  <br>Full contact object as a JSON blob (overrides flat flags).
- `--last`, `--family` `<last>`
  <br>Family name.
- `--middle` `<middle>`
  <br>Middle name.
- `--nickname` `<nickname>`
  <br>Nickname.
- `--org`, `--organization` `<org>`
  <br>Organization.
- `--phone` `<phone>` *(repeatable)*
  <br>Phone as label:value (repeatable).
- `--prefix` `<prefix>`
  <br>Name prefix.
- `--suffix` `<suffix>`
  <br>Name suffix.
- `--title`, `--job-title` `<title>`
  <br>Job title.
- `--url` `<url>` *(repeatable)*
  <br>URL as label:value (repeatable).

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

- [`apple contacts`](./index.md)
