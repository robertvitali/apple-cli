import Testing
@testable import MessagesKit

/// `matchContacts` / `cleanName` against `mac_messages_mcp.fuzzy_match` (COMPLETION-LOOP Q5d).
///
/// Every expected value was read off the live oracle. All fixtures are synthetic.
///
/// This suite exists because three separate defects on the contacts path were cancelling and
/// masking each other, so no single-value check could see them:
///
///  1. `cleanName` kept combining marks the oracle deletes (`CharacterSet.alphanumerics` is
///     L*+M*+N*; Python `\w` is L*+N* plus underscore).
///  2. `cleanName` deleted the underscore the oracle KEEPS — `\w` includes it. Opposite direction
///     to (1), which is why an "accents look fine" spot-check would have passed.
///  3. `matchContacts` sized its prefix formulas with grapheme counts where Python uses `len()`.
@Suite("contact match parity with fuzzy_match")
struct ContactMatchParityTests {

    static func score(_ q: String, _ name: String) -> Double {
        Fuzzy.matchContacts(query: q, candidates: [.init(name: name, value: "v")], threshold: 0.0)
            .first?.score ?? 0.0
    }

    /// `clean_name` = `_clean_text(strip_punctuation=True)`: emoji stripped, then everything that
    /// is not `\w`, whitespace, `'` or `-` DELETED. Measured per class against the oracle.
    @Test("cleanName matches the oracle per character class")
    func cleanNameMatchesOracle() {
        let cases: [(String, String)] = [
            ("x\u{301}y", "xy"),        // combining mark DELETED (we used to keep it)
            ("x_y", "x_y"),             // underscore KEPT — `\w` includes it (we used to drop it)
            ("x\u{e9}y", "x\u{e9}y"),   // precomposed letter kept
            ("x5y", "x5y"),             // digit kept
            ("x.y", "xy"),              // punctuation deleted
            ("x'y", "x'y"),             // apostrophe kept
            ("x-y", "x-y"),             // hyphen kept
            ("x\u{431}y", "x\u{431}y"), // Cyrillic kept
            ("x\u{df}y", "x\u{df}y"),   // sharp-s kept
        ]
        for (input, expected) in cases {
            #expect(Fuzzy.cleanName(input) == expected,
                    "cleanName(\(input)) = \(Fuzzy.cleanName(input)), oracle says \(expected)")
        }
    }

    /// Latin names, including the NFC/NFD split. The oracle scores NFC "José" 0.75 and NFD
    /// "Jose"+U+0301 a clean 1.0 — because it deletes the mark, leaving an exact "jose" match.
    /// Keeping the mark scored 0.75 for a name that should have matched perfectly.
    @Test("latin contact scores match the oracle")
    func latinScoresMatchOracle() {
        let cases: [(String, String, Double)] = [
            ("jose", "Jos\u{e9}", 0.75),            // NFC — mark is part of the letter
            ("jose", "Jose\u{301}", 1.0),           // NFD — mark deleted, exact match
            ("zoe", "Zo\u{eb}", 0.666667),
            ("zoe", "Zoe\u{308}", 1.0),
            ("renee", "Ren\u{e9}e", 0.8),
            ("renee", "Rene\u{301}e", 1.0),
            ("jose", "Jose", 1.0),
            ("ana", "Ana_Mar\u{ed}a", 0.283333),    // underscore must survive cleaning
            ("ana", "Ana_Mari\u{301}a", 0.283333),
            ("bob", "Bob Smith", 0.95),
            ("li", "Li Wei", 0.95),
        ]
        for (q, name, expected) in cases {
            #expect(abs(Self.score(q, name) - expected) < 0.0001,
                    "score(\(q), \(name)) = \(Self.score(q, name)), oracle says \(expected)")
        }
    }

    /// Python `\s` is the FULL Unicode whitespace class, so these separators survive cleaning
    /// and collapse to a space. Keeping only " \t\n\r" deleted them and joined the words —
    /// "Ana" + U+00A0 + "Maria" became "AnaMaria", scoring 0.31875 against the oracle's 0.95,
    /// i.e. below the 0.6 default threshold: a contact `find-contact` could not find at all.
    @Test("the whitespace class matches Python's \\s")
    func whitespaceClassMatchesOracle() {
        for cp in [0xA0, 0x202F, 0x2003, 0x1680, 0x2028, 0x0B, 0x0C, 0x85] as [UInt32] {
            let sep = String(Unicode.Scalar(cp)!)
            #expect(Fuzzy.cleanName("Ana" + sep + "Maria") == "Ana Maria",
                    "U+\(String(cp, radix: 16)) must clean to a separating space")
            #expect(abs(Self.score("ana", "Ana" + sep + "Maria") - 0.95) < 0.0001,
                    "U+\(String(cp, radix: 16)): score = \(Self.score("ana", "Ana" + sep + "Maria")), oracle says 0.95")
        }
    }

    /// `.lowercased()` can RE-INTRODUCE a mark `cleanName` just deleted: U+0130 lowercases to
    /// "i" + U+0307. Python then sees two code points and `startswith("i")` is True; Swift's
    /// `hasPrefix` sees ONE grapheme and is false, so it fell through to `sequenceRatio` and
    /// scored 0.667 instead of the oracle's 0.094444 — pulling a contact into the results that
    /// the oracle excludes. Fixed by comparing unicodeScalars.
    @Test("lowercasing that re-adds a mark still compares by code point")
    func dottedCapitalIComparesByCodePoint() {
        #expect(abs(Self.score("i", "\u{130}stanbul") - 0.094444) < 0.0001,
                "score = \(Self.score("i", "\u{130}stanbul")), oracle says 0.094444")
    }

    /// Conjoining jamo: two code points, one grapheme cluster. These pin the CODE-POINT sizing of
    /// the prefix formulas (0.85 · q/t and 0.80 · t/q) and of `sequenceRatio`.
    @Test("jamo contact scores match the oracle")
    func jamoScoresMatchOracle() {
        let J = "\u{1100}\u{1161}"
        let cases: [(String, String, Double)] = [
            ("ga", J, 0.0),
            (J, J + J, 0.425),
            (J + "ab", J + "abc", 0.68),        // 0.85 · q/t — was 0.6375 on grapheme counts
            ("ab" + J, "ab", 0.4),              // 0.80 · t/q — was 0.533333
            (J + "\u{11a8}", J + "\u{11a8}x", 0.6375),
            ("x" + J, "x" + J + "y", 0.6375),
            // Neither string is a prefix of the other, so these reach `sequenceRatio` itself.
            (J + "x", "y" + J, 0.666667),
            (J + "xy", "zq" + J, 0.5),
            ("x" + J + "y", "y" + J + "x", 0.5),
            ("ab" + J, "cd" + J, 0.5),
        ]
        for (q, name, expected) in cases {
            #expect(abs(Self.score(q, name) - expected) < 0.0001,
                    "score = \(Self.score(q, name)), oracle says \(expected)")
        }
    }
}
