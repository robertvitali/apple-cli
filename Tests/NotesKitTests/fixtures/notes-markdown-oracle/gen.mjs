// Regenerates goldens.json from corpus.mjs through the oracle's exact turndown configuration.
//   npm install && node gen.mjs
// Writes the file in place (rather than printing) so that regenerating cannot half-happen via a
// forgotten shell redirect. `GoldenSyncTests` then fails if the Swift rows were not updated to
// match, which is what keeps "these values came from the oracle" true.
import { writeFileSync } from "fs";
import { htmlToMarkdown } from "./oracle.mjs";
import { CASES } from "./corpus.mjs";

const out = CASES.map(([name, html]) => ({ name, html, markdown: htmlToMarkdown(html) }));
const path = new URL("./goldens.json", import.meta.url);
writeFileSync(path, JSON.stringify(out, null, 2) + "\n");
console.error(`wrote ${out.length} goldens`);
