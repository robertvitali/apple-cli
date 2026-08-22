import Testing
@testable import MessagesKit

/// `partialRatio` against rapidfuzz's own output (COMPLETION-LOOP Q5).
///
/// GOLDEN VALUES, read off the oracle itself — `rapidfuzz.fuzz.partial_ratio` — over a WHOLLY
/// SYNTHETIC corpus, not hand-written expectations. Hand-written numbers would only re-encode
/// whatever the port already did; these fail if the port and rapidfuzz disagree by more than
/// floating-point noise, which is the actual parity claim.
///
/// The corpus is invented, but selected rather than arbitrary — see the note on `golden` for how
/// the rows were chosen and why synthetic is not weaker here. Between them the tables cover exact
/// hits, the prefix/suffix alignments the old single-loop port could not see, the full-length
/// window loop, the 75-100 band, digit-bearing inputs, and ordinary non-matches. `"a"` and `"ok"`
/// are included because a 1-2 character needle degenerates the loop bounds.
@Suite("partial_ratio parity with rapidfuzz")
struct PartialRatioParityTests {

    /// (needle, haystack, rapidfuzz partial_ratio)
    ///
    /// WHOLLY SYNTHETIC haystacks. The first version of this table was generated from the
    /// operator's real message bodies and committed to this PUBLIC repository, which is a straight
    /// violation of the project's own rule that real content never lands in a tracked file. It was
    /// replaced; see the incident entry in HUMAN-DECISIONS.md.
    ///
    /// Synthetic does not mean weaker. Each row was SELECTED by computing both rapidfuzz and the
    /// old single-fixed-window port and keeping the pairs where they disagree, so the table still
    /// fails if either restored loop is deleted — the property real bodies were only incidentally
    /// providing. The vocabulary is chosen to force prefix and suffix alignments ("ol", "wolf",
    /// "gulf", "enrol" against a "golf" needle).
    ///
    /// That criterion has one KNOWN BIAS, named here so the next reader does not have to rederive
    /// it: selecting for disagreement with the old port selects AGAINST loop 2, because the old
    /// port WAS loop 2. Rows chosen only that way leave the full-length-window loop — the one
    /// carrying the bulk of production scoring, and the only capped one — thinly covered. The
    /// second block below is therefore selected by a different criterion: pairs where rapidfuzz
    /// disagrees with a loop-2-DELETED variant. The third block fills the 75-100 band and adds
    /// digit-bearing inputs, which `fullProcess` preserves and which the first block had none of.
    static let golden: [(String, String, Double)] = [
        ("golf", "enrol", 66.66666666666667),
        ("golf", "gopher", 66.66666666666667),
        ("golf", "olive", 66.66666666666667),
        ("golf", "cargo", 66.66666666666667),
        ("golf", "ripple enrol", 66.66666666666667),
        ("golf", "nimbus oyster harbor bravo", 40.0),
        ("dinner", "enrol", 57.14285714285714),
        ("dinner", "oyster", 50.0),
        ("dinner", "quartz folio wolf gulf oyster golfer puzzle sundial gulf", 33.333333333333336),
        ("flight", "falcon", 50.0),
        ("flight", "olive jolt", 50.0),
        ("flight", "delta solo jolt", 50.0),
        ("flight", "cargo jolt kettle", 33.333333333333336),
        ("flight", "falcon tundra", 44.44444444444444),
        ("tomorrow", "jolt", 40.0),
        ("tomorrow", "delta", 33.333333333333336),
        ("tomorrow", "quartz", 28.57142857142857),
        ("tomorrow", "log", 40.0),
        ("tomorrow", "solo", 50.0),
        ("address", "delta mango nimbus", 44.44444444444444),
        ("address", "solo", 40.0),
        ("address", "ripple enrol", 30.76923076923077),
        ("address", "alpha log", 25.0),
        ("thanks", "harbor tundra", 50.0),
        ("thanks", "puzzle alpha", 50.0),
        ("thanks", "harbor quartz", 50.0),
        ("thanks", "jolt alpha", 50.0),
        ("thanks", "mango cargo alpha", 50.0),
        ("thanks", "solo", 40.0),
        ("meeting", "bravo falcon jolt lumen", 60.0),
        ("meeting", "kettle gopher echo echo puzzle lumen", 60.0),
        ("meeting", "log", 50.0),
        ("meeting", "enrol bravo puzzle", 44.44444444444444),
        ("meeting", "solo folio", 22.22222222222222),
        ("meeting", "wolf ripple gopher", 28.57142857142857),
        ("weekend", "tundra", 50.0),
        ("weekend", "sundial", 44.44444444444444),
        ("weekend", "kettle log", 44.44444444444444),
        ("weekend", "enrol bravo puzzle", 44.44444444444444),
        ("weekend", "sundial delta bravo", 36.36363636363637),
        ("weekend", "folio sundial echo solo", 28.57142857142857),
        ("ok", "oyster", 66.66666666666667),
        ("ok", "solo", 66.66666666666667),
        ("ok", "mango gulf mango", 66.66666666666667),
        ("ok", "quartz folio wolf gulf oyster golfer puzzle sundial gulf", 50.0),
        ("a", "alpha harbor gulf delta puzzle log", 100.0),
        ("a", "ol", 0.0),

        // LOOP-2 WITNESSES — selected against a loop-2-deleted variant, not against the old port.
        // Each of these changes value when the full-length-window loop is removed.
        ("cargo", "cargo 512", 100.0),
        ("bravo", "cargo 512", 40.0),
        ("delta", "gopher log", 40.0),
        ("alpha", "golf cart", 40.0),
        ("delta", "dinner", 40.0),
        ("cargo", "meeting 2 pm", 19.999999999999996),

        // 75-100 BAND at unequal lengths — the shape `wRatio` actually routes to `partialRatio`
        // (it gates on lenRatio >= 1.5). Without these the table straddled the 60.0 production
        // threshold by under 7 points and never exercised a strong match at all.
        ("golf", "the wolf", 85.71428571428572),
        ("meetings", "meeting 2 pm", 93.33333333333333),
        ("harbor", "harbour", 90.9090909090909),
        ("log", "solo", 80.0),

        // DIGIT-BEARING — `fullProcess` preserves digits, so dates/times/order numbers reach
        // `partialRatio` in production. The synthetic vocabulary above is [a-z ] only.
        ("flight", "flight 88", 100.0),
        ("order", "order 4417 shipped", 100.0),
        ("puzzle", "puzzles 90210", 100.0),
        ("oyster", "oysters 12", 100.0),
    ]

    /// EQUAL-LENGTH pairs. The table this replaced contained none, which is exactly why the
    /// `len1 == len2` early return survived that commit's first draft with every test green.
    /// (The synthetic table above now happens to contain three equal-length rows — "dinner"/
    /// "oyster", "flight"/"falcon", "weekend"/"sundial" — but incidental coverage is not a
    /// substitute for rows chosen to exercise the swapped second pass, so these stay.)
    /// rapidfuzz runs its impl twice here, arguments swapped, and the prefix/suffix loops still
    /// apply; a shortcut to plain `ratio` under-scores every one of these.
    static let equalLength: [(String, String, Double)] = [
        ("thanks", "thanka", 90.9090909090909),
        ("meeting", "meetinh", 92.3076923076923),
        ("abcd", "xbcd", 85.71428571428572),
        ("golf", "olfx", 85.71428571428572),
        ("ok", "kx", 66.66666666666667),
        ("weekend", "weekemd", 85.71428571428572),
        ("a", "b", 0.0),
        ("dinner", "dinnet", 90.9090909090909),
        ("flight", "flighd", 90.9090909090909),
        ("ab", "ba", 66.66666666666667),
    ]

    @Test("equal-length pairs still go through the full alignment, both orderings")
    func equalLengthPairsMatchOracle() {
        for (a, b, expected) in Self.equalLength {
            #expect(abs(Fuzzy.partialRatio(a, b) - expected) < 0.01,
                    "partial_ratio(\(a), \(b)) = \(Fuzzy.partialRatio(a, b)), rapidfuzz says \(expected)")
            // NOT asserting symmetry here: `partialRatio` canonicalises (shorter, longer) before
            // any work, so partialRatio(x,y) == partialRatio(y,x) holds for ALL inputs by
            // construction — including when every loop is deleted and both sides return 0. An
            // expectation on it passes with the function body removed, which is worse than no
            // test. The oracle comparison above is what carries the weight.
        }
    }

    @Test("every golden pair matches rapidfuzz within floating-point noise")
    func matchesOracle() {
        var worst = 0.0
        var worstCase = ""
        for (needle, hay, expected) in Self.golden {
            let got = Fuzzy.partialRatio(needle, hay)
            let delta = abs(got - expected)
            if delta > worst { worst = delta; worstCase = "\(needle) vs \(hay.prefix(48))" }
            #expect(delta < 0.01, "partial_ratio(\(needle), …) = \(got), rapidfuzz says \(expected)")
        }
        #expect(Self.golden.count >= 40, "control: the table is populated")
        #expect(worst < 0.01, "worst divergence \(worst) at \(worstCase)")
    }

    @Test("the shorter-than-needle alignments the single-loop port could not see")
    func coversPrefixAndSuffixLoops() {
        // The measured failure that motivated Q5: 2*LCS/(|a|+|b|) means a window SHORTER than the
        // needle can beat every full-length window, because the denominator shrinks. The old port slid one
        // fixed length and returned 50.0 here. Haystack is synthetic — see the note on the table.
        #expect(abs(Fuzzy.partialRatio("golf", "a quiet symbol") - 66.66666666666667) < 0.01)
        // A genuine prefix-loop witness. The previous line here asserted
        // partialRatio("abcd","ab") == partialRatio("ab","abcd"), which tested nothing: the
        // function canonicalises its arguments, so that holds by construction even with every
        // loop deleted. This one is load-bearing — it fails by 66.67 when loop 1 alone is removed.
        #expect(abs(Fuzzy.partialRatio("golf", "gopher") - 66.66666666666667) < 0.01)
        // And a full-length-window witness, so all three loops have a named case here.
        #expect(abs(Fuzzy.partialRatio("cargo", "cargo 512") - 100.0) < 0.01)
    }
}
