import Testing
@testable import NotesKit

/// `append-to-note` body assembly against apple-notes-mcp 2.6.12 (NOTES-H4).
///
/// GOLDEN VALUES, produced by running the ORACLE'S OWN JavaScript — `contentToHtml`,
/// `separatorToHtml` and the title-div split transcribed verbatim out of `build/index.js` and
/// executed under node — not by hand-predicting what the port should emit. Hand-written
/// expectations would only re-encode whatever this port already does; these fail if the port and
/// the oracle disagree at all, which is the actual parity claim.
///
/// Before this change the port did `current + appendFragment`: no separator, no title-div split,
/// no per-line division, prepend impossible, and `<`/`>` left unescaped in plaintext.
@Suite("append-to-note assembly parity")
struct AppendAssemblyParityTests {

    /// (existingHtml, content, separator, prepend, html, oracle output)
    static let golden: [(String, String, String, Bool, Bool, String)] = [
        ("<div>Title</div><div>Body</div>", "hello", "\n\n", false, false,
         "<div>Title</div><div>Body</div><div><br></div><div>hello</div>"),
        ("<div>Title</div><div>Body</div>", "hello", "\n\n", true, false,
         "<div>Title</div><div>hello</div><div><br></div><div>Body</div>"),
        // Multi-line plaintext becomes one div PER LINE — the old single-div fragment did not.
        ("<div>Title</div><div>Body</div>", "a\nb", "\n\n", false, false,
         "<div>Title</div><div>Body</div><div><br></div><div>a</div><div>b</div>"),
        ("<div>Title</div><div>Body</div>", "a\n\nb", "\n\n", false, false,
         "<div>Title</div><div>Body</div><div><br></div><div>a</div><div><br></div><div>b</div>"),
        // Plaintext markup is ESCAPED. `updateEscape` (the old helper) leaves <> intact, so this
        // row is what stops a caller's literal "<b>x</b>" from rendering as live bold.
        ("<div>Title</div><div>Body</div>", "<b>x</b>", "\n\n", false, false,
         "<div>Title</div><div>Body</div><div><br></div><div>&lt;b&gt;x&lt;/b&gt;</div>"),
        // html format passes BOTH content and separator through untouched.
        ("<div>Title</div><div>Body</div>", "<b>x</b>", "\n\n", false, true,
         "<div>Title</div><div>Body</div>\n\n<b>x</b>"),
        ("<div>Title</div><div>Body</div>", "hello", "---", false, false,
         "<div>Title</div><div>Body</div><div>---</div><div>hello</div>"),
        ("<div>Title</div><div>Body</div>", "hello", "<hr>", false, false,
         "<div>Title</div><div>Body</div><div>&lt;hr&gt;</div><div>hello</div>"),
        ("<div>Title</div><div>Body</div>", "hello", "<hr>", false, true,
         "<div>Title</div><div>Body</div><hr>hello"),
        ("<div>Title</div><div>Body</div>", "hello", "", false, false,
         "<div>Title</div><div>Body</div><div></div><div>hello</div>"),
        // No </div> anywhere: whole body is body, title div is empty. Prepend then lands FIRST.
        ("no divs at all", "hello", "\n\n", false, false,
         "no divs at all<div><br></div><div>hello</div>"),
        ("no divs at all", "hello", "\n\n", true, false,
         "<div>hello</div><div><br></div>no divs at all"),
        ("<div>Only title</div>", "hello", "\n\n", true, false,
         "<div>Only title</div><div>hello</div><div><br></div>"),
        ("<div>T</div><div>B</div>", "a & b < c > d", "\n\n", false, false,
         "<div>T</div><div>B</div><div><br></div><div>a &amp; b &lt; c &gt; d</div>"),
        // Unreachable through the CLI (and through the oracle) because both reject empty content
        // up front; kept because it pins the pure function's faithfulness independent of the guard.
        ("<div>T</div><div>B</div>", "", "\n\n", false, false,
         "<div>T</div><div>B</div><div><br></div><div><br></div>"),
        ("<div>T</div><div>B</div>", "x", "&<>", false, false,
         "<div>T</div><div>B</div><div>&amp;&lt;&gt;</div><div>x</div>"),

        // ── The rows the FIRST version of this table structurally could not catch. ──────────
        // All three reviewers independently found the same root cause: Swift's default string
        // APIs are grapheme-cluster + canonical-equivalence, the oracle's are UTF-16 code units.
        // Every row below is ASCII-invisible, which is exactly why an all-ASCII table missed it.
        //
        // CRLF: "\r\n" is ONE Character in Swift, so a Character-based split never breaks the
        // pair — the very "collapsed into one <div>" defect this suite was written to prevent,
        // surviving for Windows-authored content.
        ("<div>Title</div><div>Body</div>", "a\r\nb", "\n\n", false, false,
         "<div>Title</div><div>Body</div><div><br></div><div>a\r</div><div>b</div>"),
        ("<div>Title</div><div>Body</div>", "a\r\nb\nc\r\n\r\nd", "\n\n", false, false,
         "<div>Title</div><div>Body</div><div><br></div><div>a\r</div><div>b</div><div>c\r</div><div>\r</div><div>d</div>"),
        // Combining mark / VS16 right after the first </div>: default range(of:) slides the match
        // to a LATER </div>, so --position before overwrote the note's real TITLE. Only observable
        // on the prepend path — for append the mis-split is a no-op, which is the other reason the
        // original table could not see it.
        ("<div>Title</div>\u{0301}rest", "X", "\n\n", true, false,
         "<div>Title</div><div>X</div><div><br></div>\u{0301}rest"),
        ("<div>T</div>\u{FE0F}<div>B</div>", "X", "\n\n", true, false,
         "<div>T</div><div>X</div><div><br></div>\u{FE0F}<div>B</div>"),
        // Escaping: `&` followed by a combining mark is not the grapheme `&`, so a default
        // replacingOccurrences left it RAW where JS .replace(/&/g) escapes it.
        ("<div>T</div><div>B</div>", "&\u{0301}x", "\n\n", false, false,
         "<div>T</div><div>B</div><div><br></div><div>&amp;\u{0301}x</div>"),
        ("<div>T</div><div>B</div>", "<\u{0301}b>x", "\n\n", false, false,
         "<div>T</div><div>B</div><div><br></div><div>&lt;\u{0301}b&gt;x</div>"),
    ]

    @Test("every assembled body matches the oracle byte-for-byte")
    func matchesOracle() {
        for (existing, content, sep, prepend, html, expected) in Self.golden {
            let got = NotesText.assembleAppend(existingHtml: existing, content: content,
                                               separator: sep, prepend: prepend, html: html)
            #expect(got == expected,
                    "assembleAppend(\(existing), \(content), sep=\(sep), prepend=\(prepend), html=\(html)) = \(got), oracle says \(expected)")
        }
        #expect(Self.golden.count >= 22, "control: the table is populated")
    }

    @Test("prepend and append genuinely differ, and both keep the title div first")
    func positionIsLoadBearing() {
        let existing = "<div>Title</div><div>Body</div>"
        let after = NotesText.assembleAppend(existingHtml: existing, content: "X",
                                             separator: "\n\n", prepend: false, html: false)
        let before = NotesText.assembleAppend(existingHtml: existing, content: "X",
                                              separator: "\n\n", prepend: true, html: false)
        #expect(after != before, "position must change the output")
        // The title div staying first is the invariant that stops `before` rewriting the title.
        #expect(after.hasPrefix("<div>Title</div>"))
        #expect(before.hasPrefix("<div>Title</div>"))
    }

    @Test("position parses exactly the oracle's two values, everything else is an error")
    func positionValidation() throws {
        #expect(try AppendCmd.validatePosition("after") == false)
        #expect(try AppendCmd.validatePosition("before") == true)
        for bad in ["AFTER", "Before", "end", "start", "", "after "] {
            #expect(throws: (any Error).self) { try AppendCmd.validatePosition(bad) }
        }
    }
}
