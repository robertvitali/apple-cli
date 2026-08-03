// C2: old-vs-new regression measurement over the 133 real note bodies.
import { readFileSync } from "fs";
import { htmlToMarkdown } from "./oracle.mjs";

const bodies = JSON.parse(readFileSync(process.argv[2], "utf8"));
const rows   = JSON.parse(readFileSync(process.argv[3], "utf8"));
if (bodies.length !== rows.length) throw new Error("length mismatch");

// A "marker" is a list marker at the start of a line: `-` or `N.` (turndown's two forms).
const MARK = /^(\s*)(-|-?\d+\.|NaN\.)\s/;
const markers = (md) => md.split("\n").map(l => MARK.exec(l)).filter(Boolean)
                          .map(m => m[1].length + ":" + m[2]);

const stat = { byteExact: {old:0,new:0}, markerSeq: {old:0,new:0}, markerCount: {old:0,new:0} };
const regressions = [];
for (let i = 0; i < bodies.length; i++) {
  const want = htmlToMarkdown(bodies[i]);
  const wm = markers(want), wmj = wm.join("|");
  for (const k of ["old", "new"]) {
    const got = rows[i][k], gm = markers(got);
    if (got === want) stat.byteExact[k]++;
    if (gm.join("|") === wmj) stat.markerSeq[k]++;
    if (gm.length === wm.length) stat.markerCount[k]++;
  }
  // per-note regression = new is worse than old on any axis
  const g = (k, f) => f(rows[i][k]);
  const oldC = markers(rows[i].old).length, newC = markers(rows[i].new).length;
  const oldS = markers(rows[i].old).join("|"), newS = markers(rows[i].new).join("|");
  const worse = [];
  if (rows[i].old === want && rows[i].new !== want) worse.push("byteExact");
  if (oldS === wmj && newS !== wmj) worse.push("markerSeq");
  if (oldC === wm.length && newC !== wm.length) worse.push("markerCount");
  if (worse.length) regressions.push({ i, worse, want: want.slice(0,120), got: rows[i].new.slice(0,120) });
}
const n = bodies.length;
for (const axis of ["byteExact","markerSeq","markerCount"]) {
  const o = stat[axis].old, w = stat[axis].new;
  console.log(`${axis.padEnd(12)} old ${String(o).padStart(3)}/${n}   new ${String(w).padStart(3)}/${n}   ${w>o?"IMPROVED +"+(w-o):w===o?"SAME":"REGRESSED "+(w-o)}`);
}
console.log(`\nper-note regressions: ${regressions.length}`);
for (const r of regressions.slice(0,5)) console.log(JSON.stringify(r).slice(0,400));
