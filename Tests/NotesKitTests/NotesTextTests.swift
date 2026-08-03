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
