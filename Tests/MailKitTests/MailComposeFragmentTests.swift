import Testing
@testable import MailKit

/// D8 item 5: oracle B's reply/forward HTML-fragment wrappers (`tools/compose.py`), ported PURE.
/// The fragment is what preserves Mail's HTML quote layer on a PLAIN reply/forward, and it is pasted
/// into a live compose window (there is no MCP-diff over this exact string), so these byte-exact
/// pins lock the oracle's shape directly. Escaping is Python `html.escape` with quote=True: `&`
/// first, then `<` `>` `"` `'`, with the apostrophe as `&#x27;` (NOT `EmlBuilder.escapeHTML`'s
/// `&#39;`). Revert-red: flip a wrapper and one of these fails.
@Suite("MailComposeFragment (oracle B reply/forward wrappers)")
struct MailComposeFragmentTests {
    @Test("htmlEscape matches Python html.escape: & first, and ' → &#x27;")
    func htmlEscapeMatchesPython() {
        #expect(MailComposeFragment.htmlEscape("a & b < c > d \" e ' f")
                == "a &amp; b &lt; c &gt; d &quot; e &#x27; f")
        // `&` is escaped FIRST, so an existing entity is (correctly) double-escaped, exactly as
        // Python's html.escape does — never left half-escaped.
        #expect(MailComposeFragment.htmlEscape("<b>&amp;</b>") == "&lt;b&gt;&amp;amp;&lt;/b&gt;")
    }

    @Test("replyPlain wraps in <div> + newline→<br> + the gap divs (compose.py:527-530)")
    func replyPlainShape() {
        #expect(MailComposeFragment.replyPlain("hello")
                == "<div>hello</div><div><br></div><div><br></div>")
        // Escaping happens BEFORE the newline substitution (oracle order), and `\n` → `<br>`.
        #expect(MailComposeFragment.replyPlain("a\nb <x>")
                == "<div>a<br>b &lt;x&gt;</div><div><br></div><div><br></div>")
    }

    @Test("replyHtml appends the gap divs to the raw HTML, unescaped (compose.py:524-525)")
    func replyHtmlShape() {
        #expect(MailComposeFragment.replyHtml("<p>hi</p>")
                == "<p>hi</p><div><br></div><div><br></div>")
    }

    @Test("forwardPrepend: escape + newline→<br> + <br><br>, NO div wrapper, NO gap (compose.py:1033-1035)")
    func forwardPrependShape() {
        #expect(MailComposeFragment.forwardPrepend("see below") == "see below<br><br>")
        #expect(MailComposeFragment.forwardPrepend("l1\nl2 & <b>") == "l1<br>l2 &amp; &lt;b&gt;<br><br>")
    }
}
