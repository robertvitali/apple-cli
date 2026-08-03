import Testing
@testable import MessagesKit

/// `wRatio` + `fullProcess` against the ORACLE'S OWN scorer (COMPLETION-LOOP Q5b).
///
/// The oracle for message search is `thefuzz.fuzz.WRatio` — NOT rapidfuzz directly — called by
/// `mac_messages_mcp.fuzzy_search_messages` on `_clean_text(x).lower()`. Every expected value
/// below was read off `thefuzz.fuzz.WRatio` (0.22.1) on this machine. All inputs are synthetic.
///
/// These exist because an end-to-end diff against the live oracle over 10 terms was returning 2
/// extra messages the oracle excluded, and the `partial_ratio` unit table could not see why: the
/// bug was not in `partialRatio` at all, it was one character of length difference in
/// `fullProcess` moving `lenRatio` across a `wRatio` branch boundary.
@Suite("WRatio parity with thefuzz")
struct WRatioParityTests {

    /// `full_process` has THREE outcomes per code point, not one — an earlier version of this
    /// comment said "replaces non-ASCII with a space", which its own cases 2 and 4 contradict:
    ///
    ///   * U+0080...U+00FF (Latin-1)      -> DELETED       (thefuzz's `ascii_only` table)
    ///   * other non-alphanumeric         -> SPACE         (length preserved)
    ///   * Unicode letter or number       -> KEPT verbatim
    ///
    /// Which one applies decides the processed LENGTH, and `wRatio` branches on `lenRatio`, so
    /// getting any of the three wrong moves scores across the match threshold. That is exactly
    /// what the 19-vs-18 probe-term divergence was.
    ///
    /// Oracle: `thefuzz.utils.full_process(s, force_ascii=True)`.
    @Test("fullProcess: Latin-1 deleted, other non-alphanumerics spaced, letters kept")
    func fullProcessMatchesOracle() {
        let cases: [(String, String)] = [
            ("ab\u{2019}cd", "ab cd"),                              // U+2019 -> SPACE (len preserved)
            ("caf\u{e9} golf", "caf golf"),                         // U+00E9 -> DELETED (Latin-1)
            ("meeting\u{2019}s", "meeting s"),                      // U+2019 -> SPACE
            ("\u{e9}\u{e9}\u{e9}", ""),                             // all Latin-1 -> all deleted
            ("x\u{3042}y", "x\u{3042}y"),                           // Unicode LETTER -> kept verbatim
            ("x\u{1f600}y", "x y"),                                 // emoji -> SPACE
            ("\u{100}bc", "\u{101}bc"),                             // U+0100: just above the delete
                                                                    // range, kept AND lowercased
            ("x\u{ff}y", "xy"),                                     // U+00FF: last deleted code point
            ("\u{431}\u{432}\u{433}", "\u{431}\u{432}\u{433}"),     // Cyrillic letters kept
            ("a\u{6f3}b", "a\u{6f3}b"),                             // Arabic-Indic DIGIT kept
            // COMBINING MARKS (Unicode M*). rapidfuzz keeps L* + N* only, so a mark becomes a
            // SPACE. `CharacterSet.alphanumerics` is L* + M* + N* and would keep them — the two
            // sets disagree on ~14,450 code points. Every row below fails against the stdlib set.
            ("a\u{301}b", "a b"),                                   // combining acute -> space
            ("x\u{301}y", "x y"),
            ("ok\u{fe0f}", "ok"),                                   // variation selector -> space,
                                                                    // then trimmed away entirely
            ("cafe\u{301}", "cafe"),                                // NFD "café" (a macOS paste)
        ]
        for (input, expected) in cases {
            #expect(Fuzzy.fullProcess(input) == expected,
                    "fullProcess(\(input)) = \(Fuzzy.fullProcess(input)), oracle says \(expected)")
        }
        // The property the score depends on, stated directly: a dropping implementation returns 4.
        #expect(Fuzzy.fullProcess("ab\u{2019}cd").count == 5)
        // ...and a Latin-1 char really does shorten it, which is the other half of the rule.
        #expect(Fuzzy.fullProcess("caf\u{e9} golf").count == 8)
    }

    /// (s1, s2, thefuzz.WRatio) — chosen to straddle both `lenRatio` branch boundaries.
    ///
    /// The 8.000/9.000 pair is the one that matters most: rapidfuzz switches the partial scale
    /// from 0.9 to 0.6 at `lenRatio >= 8` in some readings of its source, and at `> 8` in others.
    /// The oracle settles it — at EXACTLY 8.000 the scale is still 0.9 (90.0, not 60.0), so a
    /// `>= 8` implementation is wrong. This row exists so nobody "fixes" that boundary from
    /// memory again; it is a genuine trap, and it caught me mid-Q5b.
    static let golden: [(String, String, Double)] = [
        // These three have the non-ASCII char INTERIOR, so delete-vs-space changes the processed
        // string ("a meeting here" vs "ameeting here") and the score with it. Every row that had
        // a TRAILING apostrophe scores the same either way — the space is trimmed — so the
        // original table could not discriminate the very fix it was written for. Verified: these
        // fail under a delete-all-non-ASCII build.
        ("meeting", "a\u{2019}meeting here", 90.0),
        ("golf", "go\u{2019}lf cart", 68.0),
        ("home", "ho\u{2019}me sweet", 68.0),

        ("meeting", "a meeting\u{2019}", 95.0),                                  // lenRatio 1.286
        ("home", "the wolf gulf oyster harbor sundial\u{2019}", 34.0),           // lenRatio 8.750
        ("golf", "golfing", 90.0),                                               // lenRatio 1.750
        ("abcd", "abcd" + String(repeating: "zyxw", count: 7), 90.0),            // lenRatio 8.000 -> x0.9
        ("abcd", "abcd" + String(repeating: "zyxw", count: 8), 60.0),            // lenRatio 9.000 -> x0.6
        ("meeting", "meetings", 93.0),                                           // lenRatio 1.143
        ("ok", "okay then", 90.0),                                               // lenRatio 4.500
        ("thanks", "thanka", 83.0),                                              // lenRatio 1.000
    ]

    @Test("every wRatio pair matches thefuzz")
    func matchesOracle() {
        for (a, b, expected) in Self.golden {
            let got = Fuzzy.wRatio(a, b)
            #expect(abs(got - expected) < 0.01,
                    "wRatio(\(a), \(b.prefix(24))) = \(got), thefuzz says \(expected)")
        }
        // Not a `count >= N` tautology (that passes with the production code deleted). This asserts the
        // table still contains rows whose non-ASCII char is INTERIOR, the only shape that
        // discriminates delete-vs-space on wRatio.
        #expect(Self.golden.contains { $0.1.contains("\u{2019}") && !$0.1.hasSuffix("\u{2019}") },
                "control: at least one row has an interior non-ASCII char")
    }

    /// The full-length-window scan reaches far past the old 1200-window cap.
    ///
    /// The only occurrence of the needle sits at offset 1300 — past the old cap, and outside
    /// loop 3, which only ever covers the final `len1` characters (here the last 5, all "b"). So
    /// it is reachable by loop 2 alone, and only if loop 2 runs well beyond 1200. A build with the
    /// old cap scores under 100 here.
    @Test("loop 2 scans past the old 1200 cap")
    func fullLengthScanReachesPastOldCap() {
        let needle = "zqxjv"
        let hay = String(repeating: "a", count: 1300) + needle + String(repeating: "b", count: 50)
        #expect(abs(Fuzzy.partialRatio(needle, hay) - 100.0) < 0.01,
                "partialRatio = \(Fuzzy.partialRatio(needle, hay)), rapidfuzz says 100.0")
        #expect(abs(Fuzzy.wRatio(needle, hay) - 60.0) < 0.01,
                "wRatio = \(Fuzzy.wRatio(needle, hay)), thefuzz says 60.0")
    }

    /// The scan IS still bounded, at `maxScanWindows` — removing the bound entirely made a single
    /// long message (plantable by anyone who can iMessage the operator) stall the whole search.
    ///
    /// Two halves, and both matter. Parity holds far past any real message: the longest body in
    /// the corpus is 1431 characters and a match at offset 15,000 is still found exactly. Beyond
    /// the bound the score degrades instead of the process hanging — an honest, documented
    /// deviation from rapidfuzz, which has no bound.
    @Test("the scan is bounded, but only far beyond any real message")
    func scanIsBoundedWellAboveRealMessages() {
        let needle = "zqxjv"
        #expect(Fuzzy.maxScanWindows == 20_000)
        #expect(Fuzzy.maxScanWindows > 10 * 1431, "must clear the longest real body by a wide margin")

        // Inside the bound: exact parity with rapidfuzz.
        let reachable = String(repeating: "a", count: 15_000) + needle + String(repeating: "b", count: 50)
        #expect(abs(Fuzzy.partialRatio(needle, reachable) - 100.0) < 0.01,
                "a match at offset 15000 must still be found exactly")

        // Past the bound: the deviation is real, and this pins it rather than pretending otherwise.
        let beyond = String(repeating: "a", count: 40_000) + needle + String(repeating: "b", count: 50)
        #expect(Fuzzy.partialRatio(needle, beyond) < 100.0,
                "past maxScanWindows the scan stops; rapidfuzz would return 100.0 here")
    }
}
