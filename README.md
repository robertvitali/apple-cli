# apple

One CLI for Apple's native apps — **Messages, Mail, Contacts, Notes, Calendar,
Reminders** — on macOS. A single Swift binary (`apple`) with JSON-first output,
built so AI CLIs (and humans) can drive Apple apps from the command line instead
of a stack of always-on MCP servers.

> Status: **pre-release, in active development.** Each domain is built to a
> strict superset of the Apple MCP server it replaces. Versioning is
> platform-keyed: the binary cuts `v26.0.0` (macOS 26) as its first release once
> all six domains reach verified parity; MINOR = features, PATCH = fixes.

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
