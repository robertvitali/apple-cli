import Testing
import Foundation
@testable import NotesKit

@Suite("NotesText — escaping + body construction")
struct NotesTextEscapingTests {
    @Test("plaintext body escapes entities and converts whitespace")
    func plaintextBody() {
        #expect(NotesText.plaintextToHtmlBody("a & b < c > d") == "a &amp; b &lt; c &gt; d")
        #expect(NotesText.plaintextToHtmlBody("line1\nline2") == "line1<br>line2")
        #expect(NotesText.plaintextToHtmlBody("a\tb") == "a<br>b")
        #expect(NotesText.plaintextToHtmlBody("back\\slash") == "back&#92;slash")
    }

    @Test("title escape covers & < > only")
    func titleEscape() {
        #expect(NotesText.htmlTitleEscape("A & B <tag>") == "A &amp; B &lt;tag&gt;")
    }

    @Test("create body always prepends <h1> title (both formats)")
    func createBody() {
        #expect(NotesText.createNoteBody(title: "Hi", content: "body", html: false) == "<h1>Hi</h1>body")
        #expect(NotesText.createNoteBody(title: "Hi", content: "<p>x</p>", html: true) == "<h1>Hi</h1><p>x</p>")
        // plaintext content is entity-escaped; html content is verbatim.
        #expect(NotesText.createNoteBody(title: "T", content: "a<b", html: false) == "<h1>T</h1>a&lt;b")
    }

    @Test("update body wraps title+content in divs (plaintext) or uses html verbatim")
    func updateBody() {
        #expect(NotesText.updateNoteBody(effectiveTitle: "Title", content: "Body", html: false)
            == "<div>Title</div><div>Body</div>")
        #expect(NotesText.updateNoteBody(effectiveTitle: "ignored", content: "<p>x</p>", html: true) == "<p>x</p>")
    }

    @Test("update escape does NOT escape < > (reference asymmetry)")
    func updateEscape() {
        #expect(NotesText.updateEscape("a & <b>") == "a &amp; <b>")
        #expect(NotesText.updateEscape("x\ny") == "x<br>y")
    }
}

@Suite("NotesText — hashtags")
struct HashtagTests {
    @Test("parses distinct hashtags, dedupes case-insensitively")
    func parse() {
        #expect(NotesText.parseHashtags("<p>#work and #Work and #home</p>") == ["work", "home"])
    }
    @Test("ignores pure-numeric and empty hashes")
    func ignoresNumeric() {
        // The regex requires at least one letter in the tag.
        #expect(NotesText.parseHashtags("#123 #a1b").contains("a1b"))
        #expect(!NotesText.parseHashtags("#123 #a1b").contains("123"))
    }
    @Test("empty body → no tags")
    func empty() { #expect(NotesText.parseHashtags("") == []) }
}

@Suite("NotesText — plaintext + markdown")
struct HtmlConversionTests {
    @Test("htmlToPlaintext converts blocks to newlines and decodes entities")
    func plaintext() {
        let html = "<div>Line 1</div><div>Line 2</div>a &amp; b"
        let text = NotesText.htmlToPlaintext(html)
        #expect(text.contains("Line 1"))
        #expect(text.contains("Line 2"))
        #expect(text.contains("a & b"))
    }

    @Test("htmlToMarkdown renders headings, lists, bold, links")
    func markdown() throws {
        let html = "<h1>Title</h1><div>para</div><ul><li>one</li><li>two</li></ul><b>bold</b> <a href=\"http://x.com\">link</a>"
        let md = try NotesText.htmlToMarkdown(html)
        #expect(md.contains("# Title"))
        // Three spaces after the bullet: turndown's `bulletListMarker + '   '`. This said
        // `"- one"` until NOTES-M2 measured the oracle. See ListMarkdownParityTests.
        #expect(md.contains("-   one"))
        #expect(md.contains("-   two"))
        #expect(md.contains("**bold**"))
        #expect(md.contains("[link](http://x.com)"))
    }

    /// This replaces a test titled *"markdown list items render as `- ` so checklist enrichment can
    /// match"*, whose PREMISE was false in both halves.
    ///
    /// The oracle renders bullets as `-` + THREE spaces and ordered items as `N.` + two, and its
    /// enrichment regex is `^(\s*[-*])\s+(.+)$` — which matches either spacing, and matches an
    /// ordered item not at all. So (a) the one-space marker was never required for enrichment, and
    /// (b) rendering `<ol>` as `-` did not "let enrichment match" the way the old title claimed; it
    /// created enrichment the oracle never produces, while destroying the numbering it does.
    ///
    /// What is actually worth pinning is the end-to-end property: the oracle's marker survives
    /// enrichment, and enrichment re-emits with a single space (`prefix + " " + mark + " " + text`).
    @Test("the oracle's bullet spacing still enriches, and ordered items are left alone")
    func markerAndEnrichment() throws {
        #expect(try NotesText.htmlToMarkdown("<ul><li>Eggs</li></ul>") == "-   Eggs")
        #expect(try NotesText.htmlToMarkdown("<ol><li>Eggs</li></ol>") == "1.  Eggs")

        let bullets = try NotesText.htmlToMarkdown("<ul><li>Eggs</li><li>Milk</li></ul>")
        let enriched = NotesText.enrichMarkdownWithChecklists(bullets, items: [
            .init(text: "Eggs", done: true), .init(text: "Milk", done: false),
        ])
        #expect(enriched == "- [x] Eggs\n- [ ] Milk")

        // An ordered item is NOT a checklist line for the oracle's regex, so it passes through.
        let ordered = try NotesText.htmlToMarkdown("<ol><li>Eggs</li></ol>")
        #expect(NotesText.enrichMarkdownWithChecklists(ordered, items: [.init(text: "Eggs", done: true)])
                == "1.  Eggs")
    }

    @Test("decodeEntities handles named, numeric, and ampersand-last ordering")
    func entities() {
        #expect(NotesText.decodeEntities("a &amp; b") == "a & b")
        #expect(NotesText.decodeEntities("&lt;tag&gt;") == "<tag>")
        #expect(NotesText.decodeEntities("&#65;&#66;") == "AB")
        #expect(NotesText.decodeEntities("&#x41;") == "A")
    }

    /// NOTES-L1, measured live 2026-08-19: Notes.app serialized a literal unterminated "&amp "
    /// mid-sentence in a real note ("coolers &amp mugs"), and the oracle's markdown — turndown
    /// over a real DOM, whose HTML5 tokenizer decodes named refs in text content by longest match
    /// with or without semicolons — yielded "& mugs" where the old semicolon-required decode left
    /// "&amp mugs" (user text corrupted on read). Revert-red: restore the strict `"&amp;"`-only
    /// replace and these fail.
    @Test("decodeEntities decodes HTML5 legacy names without semicolons (DOM behavior)")
    func legacyEntitiesWithoutSemicolon() {
        #expect(NotesText.decodeEntities("coolers &amp mugs") == "coolers & mugs")
        // nbsp → U+00A0, NOT U+0020: the DOM's textContent carries U+00A0 and turndown's
        // collapseWhitespace folds only [ \r\n\t], so U+00A0 survives into the oracle's markdown
        // (measured). htmlToPlaintext's U+0020 is the OTHER path's parity, pinned separately.
        #expect(NotesText.decodeEntities("a &nbsp b") == "a \u{00A0} b")
        #expect(NotesText.decodeEntities("a&nbsp;b") == "a\u{00A0}b")
        #expect(NotesText.decodeEntities("x &lt y &gt z") == "x < y > z")
        #expect(NotesText.decodeEntities("say &quot hi") == "say \" hi")
        #expect(NotesText.decodeEntities("end&amp") == "end&")            // end-of-string counts
        // NOT a legacy NAME: a DOM leaves bare `&apos` verbatim (measured), so must we.
        #expect(NotesText.decodeEntities("it&apos s") == "it&apos s")
        // Double-escape still decodes exactly once (amp last).
        #expect(NotesText.decodeEntities("&amp;lt;") == "&lt;")
    }

    /// The `(?![0-9A-Za-z])` lookahead is load-bearing OVER-DECODE PROTECTION, not the DOM rule:
    /// the DOM decodes by longest match over its full ~2231-name table, so naive per-name
    /// replacement without the guard would corrupt every longer entity sharing a legacy prefix
    /// ("&notin;" → "¬in;", "&ltimes;" → "<imes;"). Revert-red: remove the lookahead and these
    /// fail. Do NOT "fix" the guard away — the faithful fix is a full-table longest-match scanner.
    @Test("the legacy-name lookahead protects longer entities from prefix corruption")
    func legacyGuardProtectsLongerEntities() {
        #expect(NotesText.decodeEntities("&notin;") == "&notin;")
        #expect(NotesText.decodeEntities("&ltimes;") == "&ltimes;")
        #expect(NotesText.decodeEntities("&gtcc;") == "&gtcc;")
        // The guard's cost, accepted: bare legacy name + alphanumeric stays whole where the
        // DOM's longest-match would decode the prefix ("&amplt" → DOM "&lt"). Known residual.
        #expect(NotesText.decodeEntities("&amplt") == "&amplt")
    }

    /// Known one-directional under/mis-decodes vs the DOM, pinned so they are DELIBERATE
    /// divergences (NOTES-L1 residuals), not silent ones. Each names the oracle's value.
    @Test("documented NOTES-L1 residuals: bare numerics, uppercase names, two-pass artifact")
    func documentedEntityResiduals() {
        // Bare NUMERIC refs: the DOM decodes them unconditionally (measured "&#39 s" → "' s");
        // this decoder's numeric pass is semicolon-required, so they survive verbatim.
        #expect(NotesText.decodeEntities("bare &#39 stays") == "bare &#39 stays")
        #expect(NotesText.decodeEntities("bare &#65 stays") == "bare &#65 stays")
        // UPPERCASE legacy forms: the DOM decodes "&AMP;" → "&"; this path is exact-lowercase.
        #expect(NotesText.decodeEntities("&AMP;") == "&AMP;")
        // Two-pass artifact: numeric pass synthesizes "&", the separate amp pass rescans it and
        // eats the literal "amp" — CLI "&", oracle/DOM "&amp". Reordering cannot fix it
        // ("&amp;#38;" must stay "&#38;", pinned below); the fix is a single scanner.
        #expect(NotesText.decodeEntities("&#38;amp") == "&")
        #expect(NotesText.decodeEntities("&amp;#38;") == "&#38;")
    }

    @Test("checklist enrichment annotates matching list items once")
    func enrich() {
        let md = "- Eggs\n- Milk\n- Bread"
        let items = [
            NotesStore.ChecklistItem(text: "Eggs", done: true),
            NotesStore.ChecklistItem(text: "Milk", done: false),
        ]
        let out = NotesText.enrichMarkdownWithChecklists(md, items: items)
        #expect(out.contains("- [x] Eggs"))
        #expect(out.contains("- [ ] Milk"))
        #expect(out.contains("- Bread")) // no state → unchanged
    }

    @Test("large inline images are replaced with a placeholder; small ones kept")
    func stripImages() {
        let big = String(repeating: "A", count: 400_000)
        let html = "<img src=\"data:image/png;base64,\(big)\">keep"
        let stripped = NotesText.stripLargeInlineImages(html, maxBytes: 256 * 1024)
        #expect(stripped.count == 1)
        #expect(stripped.html.contains("[inline image omitted"))
        #expect(stripped.html.contains("keep"))

        let small = "<img src=\"data:image/png;base64,QUJD\">x"
        let kept = NotesText.stripLargeInlineImages(small, maxBytes: 256 * 1024)
        #expect(kept.count == 0)
        #expect(kept.html == small)
    }
}
