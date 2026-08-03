// Ground-truth generator for NOTES-M2: the oracle's HTML -> Markdown conversion.
//
// Replicates apple-notes-mcp 2.6.12 `NotesManager.htmlToMarkdown` EXACTLY, transcribed from the
// installed bundle at
//   ~/.npm/_npx/67daf39574608aa2/node_modules/apple-notes-mcp/build/index.js:41464-41487
// which is:
//
//   new TurndownService({ headingStyle: "atx", codeBlockStyle: "fenced", bulletListMarker: "-" })
//   .addRule("notesDivs", { filter: "div", replacement: (content) => content + "\n" })
//   ...
//   htmlToMarkdown(html) { return this.turndownService.turndown(html).trim(); }
//
// turndown version pinned to 7.2.4, the version the oracle bundles (bundle comment at :23564
// "node_modules/.pnpm/turndown@7.2.4/...").
//
// NOTE the deliberate omission: the oracle ALSO has `enrichMarkdownWithChecklists`, which annotates
// `- ` list items with [x]/[ ] using protobuf state from NoteStore.sqlite. That is a separate
// concern (and separate gap surface); this harness covers the pure HTML->Markdown step only, which
// is what NOTES-M2 is about.
import TurndownService from "turndown";

const svc = new TurndownService({
  headingStyle: "atx",
  codeBlockStyle: "fenced",
  bulletListMarker: "-",
});
svc.addRule("notesDivs", {
  filter: "div",
  replacement: (content) => content + "\n",
});

export function htmlToMarkdown(html) {
  return svc.turndown(html).trim();
}

if (process.argv[2] === "--stdin") {
  let buf = "";
  process.stdin.on("data", (d) => (buf += d));
  process.stdin.on("end", () => process.stdout.write(htmlToMarkdown(buf)));
}
