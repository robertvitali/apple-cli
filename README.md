# apple

One CLI for Apple's native apps — **Messages, Mail, Contacts, Notes, Calendar,
Reminders** — on macOS. A single Swift binary (`apple`) with JSON-first output,
built so AI CLIs (and humans) can drive Apple apps from the command line instead
of a stack of always-on MCP servers.

> Status: **released — `v26.0.0`** (2026-08-30). Every domain is a verified strict
> superset of the Apple MCP server it replaced; the six MCPs are retired. See
> [Versioning](#versioning) below and the
> [releases page](https://github.com/robertvitali/apple-cli/releases).

## Domains

| Command | Covers |
|---|---|
| `apple messages` | iMessage / SMS — send, read, search, chats |
| `apple mail` | Mail.app — send, search, rules, templates, drafts, analytics |
| `apple contacts` | Contacts — CRUD, groups, vCard, notes, photos |
| `apple notes` | Notes — notes/folders/attachments/checklists/export |
| `apple calendar` | Calendar (EventKit) — events + calendars |
| `apple reminders` | Reminders (EventKit) — tasks, lists, subtasks |

## Build

Requires a Swift 6 toolchain. On a machine with only Xcode Command Line Tools
(no full Xcode), use [`swiftly`](https://github.com/swiftlang/swiftly) — the
open-source toolchain bundles `swift-testing`, which the tests use (macOS XCTest
needs full Xcode; this project deliberately avoids it):

```sh
brew install swiftly && swiftly init --assume-yes && swiftly install --use latest
export PATH="$HOME/.swiftly/bin:$PATH"

swift build            # build the `apple` binary
swift test             # logic-tier unit tests (swift-testing)
bats -r bats/          # CLI smoke tests
```

## Versioning

Versions are **platform-keyed**, not classic SemVer (tags carry a `v` prefix:
`v26.0.0`):

| Digit | Meaning | Example |
|---|---|---|
| **MAJOR** | The macOS major this release is built and validated against | `26.x.y` = macOS 26; `27.0.0` lands when macOS 27 support is adopted |
| **MINOR** | Feature additions (and any breaking-flagged change) | `26.1.0` |
| **PATCH** | Bug fixes, docs, small non-feature updates | `26.0.1` |

MAJOR is a validation target, not a deployment minimum — the binary currently
runs on macOS 14+ (`Package.swift` declares the minimum independently). Breaking
changes to the agent-facing JSON contract never bump MAJOR — they bump the
envelope's `schema_version` and ship in at least a MINOR flagged `BREAKING:` in
the [CHANGELOG](./CHANGELOG.md). At runtime, `apple version` emits both
`version` and `schema_version` as JSON (`apple --version` prints the bare
string). Release binaries are attached to
[GitHub Releases](https://github.com/robertvitali/apple-cli/releases). Full
policy: [`docs/versioning-policy.md`](./docs/versioning-policy.md).

## Output contract

`stdout` carries only a JSON envelope; human/diagnostic text goes to `stderr`.

```json
{ "schema_version": 1, "tool": "messages", "ok": true, "data": { ... } }
```

`schema_version` bumps only on a breaking output change. Consumers must ignore
unknown keys (tolerant reader). Exit codes are contractual (see `docs/DESIGN.md`).

## License

MIT — see [LICENSE](./LICENSE) and [NOTICE](./NOTICE) (attribution to the
MIT-licensed references this ports from).
