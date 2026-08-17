// The oracle's three rules, verbatim from apple-notes-mcp's bundle (contentWarnings.ts).
const detect = (c) =>
  /<input\b[^>]*\btype\s*=\s*["']checkbox["']/i.test(c) ||
  /^[ \t]*[-*]\s+\[[ xX]\]/m.test(c) ||
  /class\s*=\s*["'][^"']*\b(?:checklist|todo)\b/i.test(c);

// 1. The word-boundary rows the critic named as unpinned.
const named = [
  '<inputx type="checkbox">',      // <input\b — "inputx" has no boundary after "input"
  '<input-x type="checkbox">',     // ...but a hyphen IS a boundary
  '<input data-type="checkbox">',  // \btype — "-" before "type" is a boundary, so this MATCHES
  '<input mytype="checkbox">',     // ...but "mytype" does not
  '<input type="checkbox2">',      // closing quote must follow "checkbox"
  '<input type=checkbox>',         // quotes are required
  '<input\ttype="checkbox">',      // \b via tab
  '<div class="todo">x</div>',
  '<div class="xtodo">x</div>',
  '<div class="todos">x</div>',
  '<div class="a todo b">x</div>',
  '<div class = "todo">x</div>',
  '<div class="TODO">x</div>',
  '<div class="check list">x</div>',
];

// 1b. The hand-picked rows asserted inline in ChecklistWarningTests, so the checked-in corpus
//     re-derives every verdict that test carries (review: "true but unreproducible" otherwise).
//     Special chars via fromCodePoint so no editor or transport can mangle them.
const C = String.fromCodePoint;
const testRows = [
  '', 'plain text',
  '- [ ] milk', '- [x] milk', '- [X] milk', '* [ ] milk', '  - [ ] indented',
  '\t- [ ] tabbed', 'intro\n- [ ] second line', '- [] empty brackets', '- [y] wrong char',
  '-[ ] no space', 'a - [ ] mid-line only', '<ul><li>[ ] not a dash</li></ul>',
  '<input type="checkbox">', "<INPUT TYPE='CHECKBOX'>", '<input class=x type = "checkbox">',
  '<input type="text">',
  '<div class="checklist">x</div>', "<div class='todo-item'>x</div>",
  '<div class="my-checklist-thing">x</div>', '<div class="nottodo">x</div>',
];

// 1c. ECMAScript-vs-ICU divergence probes: the inputs where an inline-flag ICU transcription of
//     the three regexes disagrees with JS (no `u` flag) — line-terminator set of (?m)^, the \s
//     class, ASCII-only \b, and (?i) case folding.
const divergence = [
  'x' + C(0x0B) + '- [ ] milk', 'x' + C(0x0C) + '- [ ] milk', 'x' + C(0x85) + '- [ ] milk',
  'x' + C(0x2028) + '- [ ] milk', 'x' + C(0x2029) + '- [ ] milk', 'x\r- [ ] milk',
  '-' + C(0xFEFF) + '[ ] milk', '-' + C(0x85) + '[ ] milk', '-' + C(0xA0) + '[ ] milk',
  '-' + C(0x3000) + '[ ] milk',
  '<input' + C(0xE9) + ' type="checkbox">', '<input' + C(0x212A) + ' type="checkbox">',
  '<input' + C(0x300) + ' type="checkbox">', '<input type="chec' + C(0x212A) + 'box">',
  '<div class="todo' + C(0xE9) + '">', '<div class="todo' + C(0x301) + '">',
  '<div class="tod' + C(0xF3) + '">', '<div class="' + C(0x2713) + 'todo">',
  '<div class="todo' + C(0x1F44D) + '">',
];

// 2. Randomized differential. Deterministic LCG so the corpus is reproducible; fragments are
//    chosen to land ON each rule's boundaries rather than far from them, which is where a
//    hand-written port actually breaks.
let seed = 20260803;
const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
const pick = (a) => a[Math.floor(rnd() * a.length)];
const frag = [
  '<input', '<inputx', '<input-x', '<INPUT', ' type', ' data-type', ' mytype', ' TYPE',
  '=', ' = ', '"checkbox"', "'checkbox'", '"checkbox2"', 'checkbox', '>', '"', "'",
  'class', ' class', 'nottodo', 'todo', 'todos', 'checklist', 'checklist-x', 'my-checklist',
  '- [ ]', '- [x]', '- [X]', '- []', '-[ ]', '* [ ]', '*  [ ]', '- [y]', '[ ]',
  '\n', '\t', ' ', '  ', 'a', 'x', 'zz', '</div>', '<div', '.', '-',
  // JS-vs-ICU divergence alphabet: line-terminator candidates, \s-class edge members, non-ASCII
  // letters/marks around the ASCII-only \b, and the (?i) full-case-folding trap.
  C(0x0B), C(0x0C), C(0x85), C(0x2028), C(0x2029), '\r',
  C(0xFEFF), C(0xA0), C(0x3000),
  C(0xE9), C(0x212A), C(0x301), C(0x2713), C(0x1F44D),
];
const random = [];
for (let i = 0; i < 500; i++) {
  let s = '';
  const n = 1 + Math.floor(rnd() * 9);
  for (let j = 0; j < n; j++) s += pick(frag);
  random.push(s);
}

const all = [...new Set([...named, ...testRows, ...divergence, ...random])];
const rows = all.map((input) => ({ input, warns: detect(input) }));
console.error(`rows=${rows.length} positive=${rows.filter(r => r.warns).length}`);
process.stdout.write(JSON.stringify(rows, null, 1) + '\n');
