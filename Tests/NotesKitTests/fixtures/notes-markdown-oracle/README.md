# notes-markdown-oracle — ground truth for `notes get-markdown` list rendering

`ListMarkdownParityTests.swift` asserts that this port's HTML→Markdown list rendering is
byte-identical to the MCP server it replaces. The expected values in that file are **not
hand-written** — they are produced by running the oracle's own conversion engine, and this
directory is that generator, checked in so the claim is reproducible rather than a story.

## What the oracle actually is

`apple-notes-mcp` 2.6.12 converts note HTML with **turndown 7.2.4**, configured in its bundle at
`build/index.js:41466-41477`:

```js
new TurndownService({ headingStyle: "atx", codeBlockStyle: "fenced", bulletListMarker: "-" })
  .addRule("notesDivs", { filter: "div", replacement: (content) => content + "\n" })
// htmlToMarkdown(html) { return this.turndownService.turndown(html).trim(); }
```

`oracle.mjs` reproduces exactly that. `package.json` pins turndown to `7.2.4` **exactly** (not
`^7.2.4`) — a minor bump would silently regenerate different goldens and the parity claim would
quietly come to mean "matches whatever turndown does now" instead of "matches the version the
oracle ships".

Turndown walks a DOM, so its output depends on tree shape and on an item's index among its
siblings. That is why this port needs a parser (`Sources/NotesKit/NotesLists.swift`) and why the
regex it replaced could not be correct in principle, not merely in detail.

## Files

| File | Role |
|---|---|
| `oracle.mjs` | the oracle's exact turndown configuration; exports `htmlToMarkdown` |
| `corpus.mjs` | the 56 input cases — the single source of the input list |
| `gen.mjs` | runs the corpus through the oracle and writes `goldens.json` |
| `goldens.json` | generated: `[{name, html, markdown}]`, the checked-in ground truth |
| `c2.mjs` | old-vs-new regression measurement over a real-note corpus (see below) |

## Regenerating

```sh
cd Tests/NotesKitTests/fixtures/notes-markdown-oracle
npm install          # installs turndown 7.2.4 exactly
node gen.mjs         # rewrites goldens.json
```

`goldens.json` is a **generated artifact that is checked in on purpose**: `swift test` must not
require node, and CI must not depend on npm being reachable. `GoldenSyncTests.swift` asserts the
Swift arrays and `goldens.json` still agree, so regenerating without updating the Swift rows (or
vice versa) fails the suite. That test — not this README — is what actually prevents drift.

## The two corpora, and why `c2.mjs` is separate

`corpus.mjs` is **synthetic**: hand-built shapes chosen to isolate one rule each (`start="abc"`,
an item blank but for an anchor, a sublist that is a sibling rather than a child). It is what the
byte-exact assertions run on, and it is committable because none of it is anyone's data.

`c2.mjs` measures old-vs-new against **real note bodies**, which is the only way to know a change
is not a regression on content that actually exists — a synthetic corpus proves the new code is
right about the cases you thought of, not that it beats the old code on the cases you did not.
It takes the bodies as an argument and **no real note content is committed here**: this repo is
public, and note bodies are personal data.

To re-run it, dump bodies to a JSON array of HTML strings and a matching
`[{old, new}]` from the two implementations, then:

```sh
node c2.mjs /path/to/bodies.json /path/to/oldnew.json
```

Result recorded when NOTES-M2 landed (n=133 real notes, oracle = turndown 7.2.4):

```
byteExact    old   0/133   new  22/133   IMPROVED +22
markerSeq    old 105/133   new 133/133   IMPROVED +28
markerCount  old 128/133   new 133/133   IMPROVED +5
per-note regressions: 0
```

`byteExact` stays low because non-list rules (hard breaks, `<img>`, tables) still diverge — those
are tracked as the `divergent` rows in `ListMarkdownParityTests.swift` and belong to NOTES-L1.
The list-structure axes, which are what this change is about, are exact.
