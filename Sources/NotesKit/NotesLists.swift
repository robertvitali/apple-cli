import Foundation

/// Structural `<ul>`/`<ol>` → Markdown rendering, ported from the oracle's turndown 7.2.4 rules
/// (NOTES-M2).
///
/// WHY THIS IS NOT REGEX. The oracle (`apple-notes-mcp` 2.6.12) converts note HTML with
/// **turndown**, configured at `build/index.js:41466-41477` as
/// `{ headingStyle: "atx", codeBlockStyle: "fenced", bulletListMarker: "-" }` plus one `notesDivs`
/// rule. Turndown walks a DOM, so its list output depends on the tree shape and on an item's index
/// among its parent's ELEMENT CHILDREN. A regex cannot express either.
///
/// HOW APPLE ACTUALLY NESTS LISTS — the fact the first version of this file got wrong, and the
/// reason that version was a REGRESSION rather than a fix. Notes does NOT emit
/// `<li>a<ul>…</ul></li>` (a sublist as a child of the item). It emits the sublist as a **SIBLING
/// of the `<li>`**:
///
///     <ul><li>a</li><ul><li>b</li></ul><li>c</li></ul>
///
/// Measured over 133 real list-bearing notes from a live Notes.app store: sibling form 62,
/// child form **0**. The first corpus here had six nesting rows, ALL in the child form — the shape
/// Apple never produces — so it certified a parser that dropped bullets on 42% of real notes. On
/// marker-count-exactness against those 133 notes it scored 77/133 where the regex it replaced
/// scored 128/133. The corpus had been derived from turndown's RULE TEXT rather than from Apple's
/// OUTPUT, so it tested what the rules can express instead of what the system is actually fed.
///
/// Because a sibling sublist's parent is the LIST and not the `<li>`, turndown's `rules.list` takes
/// its `else` branch — so Apple's nesting renders VISUALLY FLAT, blank-line separated and NOT
/// indented:
///
///     -   a
///
///     -   b
///
///     -   c
///
/// Do not "fix" that to indent it.
///
/// THE RULES, transcribed verbatim from `turndown/lib/turndown.cjs.js` in the pinned 7.2.4 the
/// oracle bundles, and each MEASURED against a node harness running the oracle's exact config:
///
/// `rules.listItem`:
/// ```js
/// var prefix = options.bulletListMarker + '   ';           // "-" + THREE spaces
/// var parent = node.parentNode;
/// if (parent.nodeName === 'OL') {
///   var start = parent.getAttribute('start');
///   var index = Array.prototype.indexOf.call(parent.children, node);   // ALL element children
///   prefix = (start ? Number(start) + index : index + 1) + '.  ';      // N + "." + TWO spaces
/// }
/// var isParagraph = /\n$/.test(content);
/// content = trimNewlines(content) + (isParagraph ? '\n' : '');
/// content = content.replace(/\n/gm, '\n' + ' '.repeat(prefix.length));   // indent
/// return prefix + content + (node.nextSibling ? '\n' : '');
/// ```
///
/// `rules.list`:
/// ```js
/// if (parent.nodeName === 'LI' && parent.lastElementChild === node) return '\n' + content;
/// else return '\n\n' + content + '\n\n';
/// ```
///
/// Consequences hand-prediction gets wrong, all confirmed by running the oracle:
///
/// 1. **`index` counts ALL element children, not just `<li>`.** A sibling sublist or a stray `<p>`
///    consumes a number: `<ol><li>a</li><ol><li>b</li></ol><li>c</li></ol>` is
///    `1.  a` / `1.  b` / **`3.  c`**, and `<ol><li>a</li><p>mid</p><li>b</li></ol>` is
///    `1.  a` / `mid` / **`3.  b`**.
/// 2. **The indent is `prefix.length`, not a fixed 4** — a sublist under item `10.` indents FIVE
///    spaces. Reachable only via the child form, i.e. caller-supplied HTML, not Apple's own.
/// 3. **`start` goes through JS `Number()`**: `start="0"` → `0.`, `start="-3"` → `-3.`, `-2.`.
///    See `jsNumberPlusIndex`, which follows ECMA-262 `StringToNumber` (hex/octal/binary
///    prefixes, `Infinity`, exponents — `start="0x10"` really does render `16.`).
/// 4. **A blank `<li>` is dropped but still consumes its number** (turndown's `blankRule`; LI is a
///    block element). "Blank" is narrower than "no text" — see `isBlankItem`.
/// 5. **Bullets take three trailing spaces, not one.** Checklist enrichment is unaffected: its
///    `^(\s*[-*])\s+(.+)$` matches either and re-emits with a single space.
///
/// SCANNING IS OVER UNICODE SCALARS, not Characters, because `"<"` followed by a combining mark is
/// one Swift `Character` that does not compare equal to `"<"` — the grapheme-vs-code-unit class
/// that has bitten this project repeatedly. (That is a property of Swift's `String`. It is not a
/// claim about the oracle, which hands its input to an HTML5 parser and does no scanning at all.)
///
/// NOT MODELLED, and reachable: turndown runs a DOM-wide `collapseWhitespace` pre-pass
/// (`turndown.cjs.js:353`, `/[ \r\n\t]+/g → ' '`) before any rule fires. Nothing here models it, so
/// `<ol><li>a\nb</li></ol>` renders an indented continuation line where the oracle renders `a b`.
/// Apple's own bodies carry no inter-tag whitespace, so `get-markdown` does not hit it today;
/// caller-supplied HTML via `notes create --format html` does. Recorded rather than left absent —
/// an unmentioned missing stage reads as a covered one.
enum NotesLists {

    /// Depth ceiling for BOTH the parse and render recursions.
    ///
    /// `parseList`↔`parseItem` and `render`↔`renderItem` are mutually recursive with no natural
    /// bound, and review measured the consequence on a release build: `<ul><li>` repeated 13,000
    /// times — **104 KB**, an unremarkable note — segfaults with
    /// `EXC_BAD_ACCESS … Thread stack size exceeded due to excessive recursion`. That is worse than
    /// a failed render: SIGSEGV is not a Swift error, so `runGuarded` cannot turn it into an
    /// envelope; stdout is EMPTY and the exit code is 139, which is not in the documented matrix —
    /// the worst shape for a machine consumer. And `notes export-notes --format md`
    /// (`NotesDiagCommands.swift`) runs this over every note in every folder in every account, so
    /// ONE pathological note kills the whole export with no indication which one.
    ///
    /// The cap was FIRST set to 500 on the strength of that ~12k measurement, and the depth-cap
    /// regression test then SIGBUS'd — but only in a full `swift test` run, never when filtered to
    /// itself. The ~12k ceiling is a MAIN-thread number. swift-testing runs each test on a
    /// concurrency worker, whose stack is a fraction of the main thread's, and one nesting level
    /// costs two frames in each direction (`parseList`→`parseItem`, `render`→`renderItem`), so 500
    /// levels is ~1000 frames. A bound that only holds on the thread that was never at risk is not
    /// a bound: `export-notes` is exactly the caller most likely to be moved off the main thread
    /// later, and it is the one that runs this over every note in the store.
    ///
    /// 100 is ~10× deeper than anything Notes emits or a human nests (real notes measure ≤4), and
    /// shallow enough to be safe on the smallest stack we run on, so capping costs no realistic
    /// parity — turndown itself is DOM-bound and never sees this. Both recursions are capped: they
    /// recurse independently, so capping one leaves the other reachable.
    static let maxDepth = 100

    struct DepthExceeded: Error {}

    // MARK: - Parsed shape

    /// An element child of a list. Modelling non-`<li>` children is not pedantry: it is what makes
    /// Apple's sibling nesting AND turndown's `parent.children` indexing expressible at all.
    indirect enum Child {
        case item(Item)
        case list(List)
        /// Any other element child (`<div>`, `<p>`, …). Rendered inline, but it still occupies an
        /// index, so it shifts the numbering of every item after it.
        case other(String)
    }

    /// A fragment of an `<li>`'s content: raw inline HTML, or a sublist nested INSIDE the item.
    indirect enum Fragment {
        case html(String)
        case list(List)
    }

    struct List {
        let ordered: Bool
        /// The RAW `start` attribute, unparsed, so JS `Number()` semantics survive to render time.
        let start: String?
        var children: [Child]
    }

    struct Item {
        var fragments: [Fragment]
        /// True when any node — element OR text — follows this `<li>` in its parent. turndown tests
        /// `node.nextSibling`, which is not element-only.
        var hasNextSibling: Bool
    }

    enum Segment {
        case html(String)
        case list(List)
    }

    // MARK: - Scanning

    private struct Tag {
        let name: String
        let isClose: Bool
        /// Raw attribute text, preserved verbatim so a passthrough element can be re-emitted
        /// byte-for-byte (`parseUntilClose`). Do NOT search this for an attribute — use `attrList`.
        let attrs: String
        /// Attributes tokenized into (lowercased name, value) pairs, in source order.
        let attrList: [(name: String, value: String)]
        let end: Int
    }

    /// Read a tag at `i`. Returns nil when this `<` does not begin a well-formed tag, in which case
    /// the caller treats it as literal text — what a browser does, and why a lone `<` in note text
    /// cannot desynchronize the scan.
    ///
    /// The attribute region is TOKENIZED rather than scanned for the first `>`, because HTML permits
    /// `>` inside a quoted attribute value and the DOM parser turndown runs on honours that. Reading
    /// to the first `>` ended the tag early and leaked raw attribute text into rendered markdown:
    /// `<ol><li title="a>b">x</li><li>y</li></ol>` rendered `1.  b">x` instead of `1.  x`. The old
    /// regex had the same flaw, so this is not a regression — but it is a hand-written parser now,
    /// and the fix is local.
    private static func readTag(_ s: [Unicode.Scalar], _ i: Int, _ lastGt: Int) -> Tag? {
        // Past the final `>` no tag can be terminated. Without this the scan below runs to
        // end-of-input on EVERY `<`, which is the quadratic half of the DoS described on
        // `segments`. `lastGt` is computed once per top-level parse and threaded down.
        guard i <= lastGt else { return nil }
        guard i < s.count, s[i] == "<" else { return nil }
        var j = i + 1
        var isClose = false
        if j < s.count, s[j] == "/" { isClose = true; j += 1 }
        let nameStart = j
        while j < s.count, isNameScalar(s[j]) { j += 1 }
        guard j > nameStart else { return nil }
        let name = String(String.UnicodeScalarView(s[nameStart..<j])).lowercased()
        let attrStart = j

        var attrList: [(name: String, value: String)] = []
        while j < s.count, s[j] != ">" {
            if isSpace(s[j]) || s[j] == "/" { j += 1; continue }
            // Attribute name: everything up to whitespace, `=`, `/` or `>`. `-`, `:`, `.` and `_`
            // are NAME characters here — that is the whole point of finding 1 (see `attribute`).
            let nStart = j
            while j < s.count, !isSpace(s[j]), s[j] != "=", s[j] != ">", s[j] != "/" { j += 1 }
            guard j > nStart else { j += 1; continue }
            let aName = String(String.UnicodeScalarView(s[nStart..<j])).lowercased()
            var k = j
            while k < s.count, isSpace(s[k]) { k += 1 }
            guard k < s.count, s[k] == "=" else {          // valueless attribute
                attrList.append((aName, ""))
                continue
            }
            k += 1
            while k < s.count, isSpace(s[k]) { k += 1 }
            guard k < s.count else { j = k; break }
            if s[k] == "\"" || s[k] == "'" {
                let quote = s[k]; k += 1
                let vStart = k
                while k < s.count, s[k] != quote { k += 1 }   // `>` inside here is LITERAL
                attrList.append((aName, String(String.UnicodeScalarView(s[vStart..<min(k, s.count)]))))
                j = min(k + 1, s.count)
            } else {
                let vStart = k
                while k < s.count, !isSpace(s[k]), s[k] != ">" { k += 1 }
                attrList.append((aName, String(String.UnicodeScalarView(s[vStart..<k]))))
                j = k
            }
        }
        guard j < s.count else { return nil }
        let attrs = String(String.UnicodeScalarView(s[attrStart..<j]))
        return Tag(name: name, isClose: isClose, attrs: attrs, attrList: attrList, end: j + 1)
    }

    private static func isNameScalar(_ u: Unicode.Scalar) -> Bool {
        (u >= "a" && u <= "z") || (u >= "A" && u <= "Z") || (u >= "0" && u <= "9")
    }

    /// First attribute with EXACTLY this name, matching a browser's duplicate-attribute rule.
    ///
    /// The previous implementation substring-searched the raw attribute blob for `start`, treating
    /// any non-alphanumeric as a name boundary. Since `-`, `:`, `.` and `_` are all legal in
    /// attribute names, every attribute ENDING in `start` was accepted: `<ol data-start="9">`
    /// renumbered a list the oracle leaves at `1.`, and because the scan returned the first hit,
    /// `<ol data-start="9" start="2">` let the decoy OVERRIDE the real attribute. It also matched
    /// inside quoted values, so `<ol title="start=5">` emitted a literal `NaN.`. `data-*` on list
    /// elements is ordinary in pasted HTML, and `create-note --format html` takes arbitrary user
    /// HTML, so all of that was reachable.
    static func attribute(_ list: [(name: String, value: String)], named: String) -> String? {
        list.first { $0.name == named }?.value
    }

    private static func isSpace(_ u: Unicode.Scalar) -> Bool {
        u == " " || u == "\t" || u == "\n" || u == "\r" || u == "\u{0C}"
    }

    // MARK: - Parse

    static func segments(_ html: String) throws -> [Segment] {
        let s = Array(html.unicodeScalars)
        var out: [Segment] = []
        var raw = String.UnicodeScalarView()
        var i = 0
        // Index of the last `>` in the input. Past it no tag can be terminated, so `readTag` there
        // would scan to end-of-input only to fail — see the note below on why that matters.
        let lastGt = s.lastIndex(of: ">") ?? -1
        while i < s.count {
            if s[i] == "<", let t = readTag(s, i, lastGt) {
                if !t.isClose, t.name == "ul" || t.name == "ol" {
                    if !raw.isEmpty { out.append(.html(String(raw))); raw = String.UnicodeScalarView() }
                    let (list, next) = try parseList(s, openTag: t, depth: 0, lastGt)
                    out.append(.list(list))
                    i = next
                    continue
                }
                // A NON-list tag: copy it through WHOLE and jump past it. Appending one scalar and
                // re-entering `readTag` at the next `<` is what made this quadratic — see below.
                raw.append(contentsOf: s[i..<t.end])
                i = t.end
                continue
            }
            raw.append(s[i])
            i += 1
        }
        if !raw.isEmpty { out.append(.html(String(raw))) }
        return out
    }

    /// Parse a list subtree, keeping EVERY element child in document order.
    private static func parseList(_ s: [Unicode.Scalar], openTag: Tag, depth: Int, _ lastGt: Int) throws -> (List, Int) {
        guard depth < maxDepth else { throw DepthExceeded() }
        let ordered = openTag.name == "ol"
        let start = attribute(openTag.attrList, named: "start")
        var children: [Child] = []
        var i = openTag.end
        var trailingNodeAfterLastItem = false

        while i < s.count {
            guard s[i] == "<", let t = readTag(s, i, lastGt) else {
                if !children.isEmpty { trailingNodeAfterLastItem = true }
                i += 1
                continue
            }
            if t.isClose, t.name == "ul" || t.name == "ol" {
                i = t.end
                break
            }
            if !t.isClose, t.name == "li" {
                let (item, next) = try parseItem(s, from: t.end, depth: depth + 1, lastGt)
                children.append(.item(item))
                i = next
                trailingNodeAfterLastItem = false
                continue
            }
            if !t.isClose, t.name == "ul" || t.name == "ol" {
                // APPLE'S NESTING FORM: a sublist SIBLING of the items, not a child of one.
                // The first version of this parser had no branch here, so it fell through and
                // advanced past the OPEN TAG ONLY. That spliced the inner items into the OUTER
                // list and let the inner `</ul>` satisfy the outer list's close — so every `<li>`
                // after a sublist fell out of the list entirely and lost its marker.
                let (nested, next) = try parseList(s, openTag: t, depth: depth + 1, lastGt)
                children.append(.list(nested))
                i = next
                trailingNodeAfterLastItem = true
                continue
            }
            if t.isClose {
                i = t.end
                continue
            }
            // Any other element child. It occupies an index for `parent.children`, so a `<div>` or
            // `<p>` between items shifts the numbering of everything after it.
            let (rawHTML, next) = parseUntilClose(s, openTag: t, lastGt)
            children.append(.other(rawHTML))
            i = next
            trailingNodeAfterLastItem = true
        }

        for k in children.indices {
            if case .item(var it) = children[k] {
                it.hasNextSibling = (k < children.count - 1) || trailingNodeAfterLastItem
                children[k] = .item(it)
            }
        }
        return (List(ordered: ordered, start: start, children: children), i)
    }

    /// Consume an element and its content up to its matching close tag; return the raw HTML.
    private static func parseUntilClose(_ s: [Unicode.Scalar], openTag: Tag, _ lastGt: Int) -> (String, Int) {
        var depth = 1
        var i = openTag.end
        let contentStart = openTag.end
        while i < s.count, depth > 0 {
            guard s[i] == "<", let t = readTag(s, i, lastGt) else { i += 1; continue }
            if t.name == openTag.name { depth += t.isClose ? -1 : 1 }
            i = t.end
        }
        let inner = String(String.UnicodeScalarView(s[contentStart..<max(contentStart, i)]))
        return ("<" + openTag.name + openTag.attrs + ">" + inner, i)
    }

    private static func parseItem(_ s: [Unicode.Scalar], from: Int, depth: Int, _ lastGt: Int) throws -> (Item, Int) {
        guard depth < maxDepth else { throw DepthExceeded() }
        var fragments: [Fragment] = []
        var raw = String.UnicodeScalarView()
        var i = from
        while i < s.count {
            guard s[i] == "<", let t = readTag(s, i, lastGt) else {
                raw.append(s[i]); i += 1; continue
            }
            if t.isClose, t.name == "li" { i = t.end; break }
            // Implied end tag: an unclosed `<li>` ends at the next `<li>` or at the list's close.
            if (!t.isClose && t.name == "li") || (t.isClose && (t.name == "ul" || t.name == "ol")) {
                break
            }
            if !t.isClose, t.name == "ul" || t.name == "ol" {
                // A sublist nested INSIDE the item. Apple does not emit this, but caller-supplied
                // HTML can, and it is the branch where indentation applies.
                if !raw.isEmpty { fragments.append(.html(String(raw))); raw = String.UnicodeScalarView() }
                let (nested, next) = try parseList(s, openTag: t, depth: depth + 1, lastGt)
                fragments.append(.list(nested))
                i = next
                continue
            }
            raw.append(contentsOf: s[i..<t.end])
            i = t.end
        }
        if !raw.isEmpty { fragments.append(.html(String(raw))) }
        return (Item(fragments: fragments, hasNextSibling: false), i)
    }

    // MARK: - Render

    /// `isLastChildOfItem` selects turndown's `rules.list` branch, and is TRUE only when this list
    /// is nested inside an `<li>` AND is that item's last element child.
    static func render(_ list: List, isLastChildOfItem: Bool, depth: Int = 0,
                       inline: (String) -> String) throws -> String {
        guard depth < maxDepth else { throw DepthExceeded() }
        var content = ""
        for (index, child) in list.children.enumerated() {
            switch child {
            case .item(let item):
                content += try renderItem(item, elementIndex: index, in: list, depth: depth + 1, inline: inline)
            case .list(let sub):
                // Parent is the LIST, not an LI, so turndown takes the else branch: blank-line
                // separated, NOT indented. This is Apple's shape.
                content += try render(sub, isLastChildOfItem: false, depth: depth + 1, inline: inline)
            case .other(let raw):
                content += inline(raw)
            }
        }
        return isLastChildOfItem ? "\n" + content : "\n\n" + content + "\n\n"
    }

    private static func renderItem(_ item: Item, elementIndex: Int, in list: List, depth: Int,
                                   inline: (String) -> String) throws -> String {
        guard depth < maxDepth else { throw DepthExceeded() }
        var inner = ""
        for (k, frag) in item.fragments.enumerated() {
            switch frag {
            case .html(let h):
                inner += inline(h)
            case .list(let sub):
                // `parent.lastElementChild === node`. ELEMENT child — a bare TEXT node after the
                // sublist does NOT displace it, so `<li>a<ol>…</ol>tail</li>` still takes the
                // `'\n' + content` branch and "tail" lands flush against the sublist's last item.
                let laterHasElement = item.fragments[(k + 1)...].contains { frag in
                    switch frag {
                    case .list: return true
                    case .html(let h): return h.range(of: "<[a-zA-Z]", options: .regularExpression) != nil
                    }
                }
                inner += try render(sub, isLastChildOfItem: !laterHasElement, depth: depth + 1, inline: inline)
            }
        }

        if isBlankItem(item) { return "\n\n" }

        let prefix = itemPrefix(elementIndex: elementIndex, in: list)
        let isParagraph = inner.hasSuffix("\n")
        var content = trimNewlines(inner) + (isParagraph ? "\n" : "")
        content = content.replacingOccurrences(
            of: "\n", with: "\n" + String(repeating: " ", count: prefix.count), options: .literal)
        return prefix + content + (item.hasNextSibling ? "\n" : "")
    }

    /// `elementIndex` is the item's position among ALL of the list's element children — turndown's
    /// `Array.prototype.indexOf.call(parent.children, node)` — NOT its position among `<li>`s.
    static func itemPrefix(elementIndex: Int, in list: List) -> String {
        guard list.ordered else { return "-   " }
        guard let raw = list.start, !raw.isEmpty else { return "\(elementIndex + 1).  " }
        return "\(jsNumberPlusIndex(raw, elementIndex)).  "
    }

    /// `Number(start) + index`, following ECMA-262 `StringToNumber`.
    ///
    /// An earlier version accepted decimals only and returned `NaN` for everything else, documented
    /// as "a deliberate partial port". Measuring the boundary showed the limit was not worth
    /// keeping: the oracle renders `start="0x10"` as `16.`, `start="1e3"` as `1000.` and
    /// `start="Infinity"` as a literal `Infinity.`, and the non-decimal forms are three extra lines
    /// rather than a project. A documented divergence is still a divergence.
    ///
    /// The grammar, per spec: optional surrounding whitespace; empty-or-whitespace → `0`;
    /// `Infinity` with an optional sign; `0x`/`0o`/`0b` radix prefixes (UNSIGNED — JS gives
    /// `Number("-0x10")` = `NaN`); otherwise a decimal literal with optional exponent. Note this is
    /// `Number()`, NOT `parseInt`: it rejects trailing garbage (`"12abc"` → `NaN`) rather than
    /// stopping at it.
    ///
    /// Swift's `Double(String)` cannot stand in for the decimal case: it accepts `"0x10"` (as a
    /// hex FLOAT), `"inf"`, `"nan"` and a trailing `"f"` — none of which JS accepts — so the
    /// decimal branch stays regex-guarded to reject exactly those.
    static func jsNumberPlusIndex(_ raw: String, _ index: Int) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: Double
        if t.isEmpty {
            value = 0                                     // Number("") === 0, Number("  ") === 0
        } else if let inf = infinityLiteral(t) {
            value = inf
        } else if let r = radixLiteral(t) {
            value = r
        } else if t.range(of: "^[+-]?((\\d+\\.?\\d*)|(\\.\\d+))([eE][+-]?\\d+)?$",
                          options: .regularExpression) != nil, let d = Double(t) {
            value = d
        } else {
            return "NaN"
        }
        let v = value + Double(index)
        if v.isNaN { return "NaN" }
        if v.isInfinite { return v > 0 ? "Infinity" : "-Infinity" }
        if v == v.rounded(), abs(v) < 1e21 { return String(Int64(v)) }
        return String(v)
    }

    private static func infinityLiteral(_ t: String) -> Double? {
        switch t {
        case "Infinity", "+Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: return nil                               // case-sensitive: "infinity" is NaN in JS
        }
    }

    /// `0x`/`0o`/`0b` literals. JS does NOT allow a sign on these, so `-0x10` is `NaN`.
    ///
    /// Accumulated in `Double`, not `UInt64`: JS has no integer type here, so an overflowing
    /// literal does not fail, it goes imprecise — `Number("0x" + "f".repeat(40))` is
    /// `1.461501637330903e+48`, where a `UInt64` parse returns nil and would have produced `NaN`.
    /// Beyond 2^53 this accumulation rounds at each step where JS rounds once, so the two can
    /// differ in the last bits; the corpus pins where that starts to show rather than leaving it
    /// unmeasured.
    ///
    /// Digits are checked as ASCII explicitly. `Character.hexDigitValue` also accepts fullwidth
    /// forms like `�ffff`, which JS rejects — exactly the Unicode-tolerance-vs-oracle mismatch this
    /// project keeps hitting.
    private static func radixLiteral(_ t: String) -> Double? {
        guard t.count > 2, t.hasPrefix("0") else { return nil }
        let radix: Double
        switch t[t.index(t.startIndex, offsetBy: 1)] {
        case "x", "X": radix = 16
        case "o", "O": radix = 8
        case "b", "B": radix = 2
        default: return nil
        }
        var value = 0.0
        for u in t.dropFirst(2).unicodeScalars {
            let d: Double
            switch u {
            case "0"..."9": d = Double(u.value - 0x30)
            case "a"..."f": d = Double(u.value - 0x61 + 10)
            case "A"..."F": d = Double(u.value - 0x41 + 10)
            default: return nil
            }
            guard d < radix else { return nil }          // `0b2`, `0o9` are NaN in JS
            value = value * radix + d
        }
        return value
    }

    /// turndown's `isBlank` (`turndown.cjs.js:513`):
    /// ```js
    /// !isVoid(node) && !isMeaningfulWhenBlank(node) && /^\s*$/.test(node.textContent)
    ///   && !hasVoid(node) && !hasMeaningfulWhenBlank(node)
    /// ```
    /// BOTH sets matter. The first version modelled only the void set and omitted
    /// MEANINGFUL_WHEN_BLANK entirely, so `<li><a href="x"></a></li>` — a link whose text was
    /// deleted, entirely plausible in a real note — counted as blank and the whole item vanished.
    private static func isBlankItem(_ item: Item) -> Bool {
        for frag in item.fragments {
            switch frag {
            case .list:
                return false
            case .html(let h):
                if h.range(of: "<(\(Self.voidElements)|\(Self.meaningfulWhenBlank))\\b",
                           options: [.regularExpression, .caseInsensitive]) != nil { return false }
                let text = NotesText.stripTags(h)
                if !NotesText.decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return false
                }
            }
        }
        return true
    }

    /// turndown's void elements, verbatim — the first version omitted
    /// `command|keygen|link|meta|param`.
    private static let voidElements =
        "area|base|br|col|command|embed|hr|img|input|keygen|link|meta|param|source|track|wbr"
    /// turndown's meaningful-when-blank elements, verbatim — the first version had none of these.
    private static let meaningfulWhenBlank = "a|table|th|td|iframe|script|audio|video"

    private static func trimNewlines(_ s: String) -> String {
        var out = Substring(s)
        while out.hasPrefix("\n") { out = out.dropFirst() }
        while out.hasSuffix("\n") { out = out.dropLast() }
        return String(out)
    }
}
