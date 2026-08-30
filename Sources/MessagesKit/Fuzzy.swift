import Foundation

/// Fuzzy-matching + text-normalization primitives ported from `mac_messages_mcp`
/// (the parity oracle). Two independent algorithms, because the MCP uses two:
///
///  - **Contacts** (`find_contact`): Python `difflib.SequenceMatcher.ratio()`
///    (Ratcliff/Obershelp) wrapped in token-based scoring rules. Ported EXACTLY —
///    `SequenceMatcher.ratio` is deterministic, so unit tests match Python values.
///  - **Message search** (`fuzzy_search_messages`): `thefuzz.WRatio` (which wraps
///    rapidfuzz). Ported faithfully (rapidfuzz `ratio` = normalized Indel/LCS
///    similarity; the WRatio length-scaling assembly is reproduced from thefuzz).
///    Parity is BEHAVIORAL, not byte-identical, per docs/port-specs/messages.md §6.
///
/// All types here are pure (no I/O) so they are unit-testable without TCC.
public enum Fuzzy {

    // MARK: - Text normalization

    /// Emoji ranges the MCP's `_EMOJI_PATTERN` strips before matching.
    private static func stripEmoji(_ s: String) -> String {
        String(s.unicodeScalars.filter { scalar in
            let v = scalar.value
            let inEmoji =
                (0x1F600...0x1F64F).contains(v) || (0x1F300...0x1F5FF).contains(v) ||
                (0x1F680...0x1F6FF).contains(v) || (0x1F700...0x1F77F).contains(v) ||
                (0x1F780...0x1F7FF).contains(v) || (0x1F800...0x1F8FF).contains(v) ||
                (0x1F900...0x1F9FF).contains(v) || (0x1FA00...0x1FA6F).contains(v) ||
                (0x1FA70...0x1FAFF).contains(v) || (0x2702...0x27B0).contains(v) ||
                (0x24C2...0x1F251).contains(v)
            return !inEmoji
        }.map(Character.init))
    }

    /// Collapse internal whitespace runs to a single space + trim. Uses full Unicode
    /// whitespace (matching Python's `re.sub(r'\s+', ' ')`), not just ASCII.
    private static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Port of the MCP's `clean_name` (`_clean_text(strip_punctuation=True)`):
    /// strip emoji, drop every char that is not word-char / whitespace / `'` / `-`,
    /// collapse whitespace, trim. Used for CONTACT-name matching.
    public static func cleanName(_ name: String) -> String {
        let noEmoji = stripEmoji(name)
        let filtered = String(noEmoji.unicodeScalars.filter { scalar in
            // Python's `\w` is `str.isalnum()` PLUS underscore — so this must be the L*+N*
            // `alnum` set, NOT `CharacterSet.alphanumerics` (L*+M*+N*), and it must keep "_".
            // Both halves were wrong and they failed in opposite directions, measured against
            // the oracle's `clean_name`:
            //   "x" + U+0301 + "y" -> oracle "xy"  (mark DELETED; we kept it)
            //   "x_y"              -> oracle "x_y" (underscore KEPT;  we deleted it)
            // The mark half is the one that matters: an NFD "José" cleaned to "José" instead of
            // "Jose" scores 0.75 against a "jose" query where the oracle scores a clean 1.0.
            alnum.contains(scalar) || scalar == "_" ||
            // `\s`, not a hand-listed four. Python's `\s` is the full Unicode whitespace class,
            // so U+00A0/U+202F/U+2003/U+1680/U+2028/U+0085 all survive into the whitespace
            // collapse and become a separating space. Keeping only " \t\n\r" DELETED them,
            // joining the words: "Ana" + U+00A0 + "Maria" cleaned to "AnaMaria" and scored
            // 0.31875 against a "ana" query where the oracle scores 0.95 — below the 0.6
            // threshold, i.e. a contact `find-contact` simply could not find. This function also
            // already used full-Unicode `isWhitespace` in `collapseWhitespace`, so the two halves
            // disagreed with each other. Python's `\s` additionally covers U+001C...U+001F.
            isPythonSpace(scalar) ||
            scalar == "'" || scalar == "-"
        }.map(Character.init))
        return collapseWhitespace(filtered)
    }

    /// Python `\s` = Unicode whitespace PLUS the C1-adjacent separators U+001C...U+001F.
    private static func isPythonSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
    }

    /// Port of the MCP's `_clean_text(strip_punctuation=False)`: strip emoji +
    /// collapse whitespace only. Used for MESSAGE fuzzy search pre-cleaning.
    public static func cleanText(_ text: String) -> String {
        collapseWhitespace(stripEmoji(text))
    }

    /// Port of `thefuzz.utils.full_process(force_ascii=True)` used inside WRatio:
    /// replace every non-ASCII-alphanumeric char with a SPACE, then `.strip().lower()`
    /// (rapidfuzz `default_process` does NOT collapse internal runs — reproduced faithfully).
    ///
    /// The `force_ascii` step is NOT "drop everything non-ASCII". thefuzz's table is literally
    ///
    ///     translation_table = {i: None for i in range(128, 256)}   # ascii dammit!
    ///
    /// so it deletes ONLY U+0080...U+00FF (the Latin-1 supplement). Every code point at U+0100 and
    /// above survives into `default_process`, which replaces non-alphanumerics with a SPACE and
    /// keeps Unicode letters as-is. Verified per character class against the oracle:
    ///
    ///     "x" + U+00E9 + "y" -> "xy"    (Latin-1: DELETED, length shrinks)
    ///     "x" + U+2019 + "y" -> "x y"   (above Latin-1, punctuation: SPACE, length preserved)
    ///     "x" + U+1F600 + "y" -> "x y"  (emoji: SPACE)
    ///     "x" + U+3042 + "y" -> "xあy"  (Unicode LETTER: KEPT verbatim)
    ///
    /// Both halves are load-bearing, because `wRatio` branches on `lenRatio` and every one of
    /// these changes the length differently. On the real message behind the 19-vs-18 probe-term    /// divergence, dropping made the processed body 9 characters where the oracle saw 10: that
    /// moved `lenRatio` from the oracle's 1.429 (10/7) to 1.286 (9/7) — both under 1.5, so the
    /// same branch — while `ratio` went from 58.82 to 62.5, crossing the 60 threshold and adding a
    /// message the oracle excluded. (Direction, since it is easy to misread: 1.286 and 62.5 are
    /// the BUGGY values, 1.429 and 58.82 the oracle's.)
    ///
    /// `alnum` is L* + N* only — deliberately NOT `CharacterSet.alphanumerics`, which is
    /// L* + M* + N*. Those two sets disagree on ~14,450 code points, 2,210 of them combining
    /// marks, and rapidfuzz keeps only letters and numbers. Using the stdlib set kept combining
    /// marks that the oracle turns into spaces: `full_process("a" + U+0301 + "b")` is `"a b"`,
    /// not `"áb"`, and `wRatio("ok", "ok" + U+FE0F)` is 100 where keeping the selector gives 50 —
    /// across the 60 threshold. No body in the current corpus retains a mark after `cleanText`,
    /// so this was latent rather than measurable; it fires on NFD text (a macOS paste), Vietnamese,
    /// Devanagari, and Hebrew/Arabic diacritics.
    private static let alnum = CharacterSet.alphanumerics.subtracting(.nonBaseCharacters)

    static func fullProcess(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if scalar.value >= 128 && scalar.value <= 255 { continue } // thefuzz ascii_only
            out.append(alnum.contains(scalar) ? scalar : " ")
        }
        // Trim on SCALARS, not Characters: " " + U+FE0F is a single grapheme that is not in the
        // trim set, so a Character-based trim leaves the selector behind where the oracle yields
        // an empty string — which then skips the empty short-circuit in `wRatio`.
        var lo = out.startIndex, hi = out.endIndex
        let ws: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r", "\u{0b}", "\u{0c}"]
        while lo < hi, ws.contains(out[lo]) { lo = out.index(after: lo) }
        while hi > lo { let p = out.index(hi, offsetBy: -1); if ws.contains(out[p]) { hi = p } else { break } }
        return String(String.UnicodeScalarView(out[lo..<hi])).lowercased()
    }

    /// Digits-only phone normalization (`normalize_phone_number`).
    public static func normalizePhone(_ phone: String) -> String {
        String(phone.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }.map(Character.init))
    }

    // MARK: - difflib.SequenceMatcher.ratio() (Ratcliff/Obershelp)

    /// Exact port of Python `difflib.SequenceMatcher(None, a, b).ratio()` with no
    /// junk heuristic (autojunk only triggers on sequences ≥ 200 elements, which
    /// contact tokens never are). Returns `2*M / T`, M = matched chars, T = |a|+|b|.
    public static func sequenceRatio(_ a: String, _ b: String) -> Double {
        let aChars = Array(a.unicodeScalars), bChars = Array(b.unicodeScalars)
        let total = aChars.count + bChars.count
        if total == 0 { return 1.0 }
        let matches = matchingBlocksTotal(aChars, bChars)
        return 2.0 * Double(matches) / Double(total)
    }

    /// Sum of matching-block sizes (the `M` in difflib's ratio).
    private static func matchingBlocksTotal(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        // b2j: char -> sorted indices in b.
        var b2j: [Unicode.Scalar: [Int]] = [:]
        for (j, ch) in b.enumerated() { b2j[ch, default: []].append(j) }

        // find_longest_match over a[alo..<ahi] × b[blo..<bhi].
        func longestMatch(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (Int, Int, Int) {
            var besti = alo, bestj = blo, bestsize = 0
            var j2len: [Int: Int] = [:]
            for i in alo..<ahi {
                var newj2len: [Int: Int] = [:]
                if let js = b2j[a[i]] {
                    for j in js {
                        if j < blo { continue }
                        if j >= bhi { break }
                        let k = (j2len[j - 1] ?? 0) + 1
                        newj2len[j] = k
                        if k > bestsize { besti = i - k + 1; bestj = j - k + 1; bestsize = k }
                    }
                }
                j2len = newj2len
            }
            return (besti, bestj, bestsize)
        }

        var total = 0
        var queue = [(0, a.count, 0, b.count)]
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let (i, j, k) = longestMatch(alo, ahi, blo, bhi)
            if k > 0 {
                total += k
                if alo < i && blo < j { queue.append((alo, i, blo, j)) }
                if i + k < ahi && j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
            }
        }
        return total
    }

    // MARK: - Contact token-scoring (MCP `fuzzy_match`)

    public struct ContactCandidate { public let name: String; public let value: String }
    public struct ScoredCandidate { public let name: String; public let value: String; public let score: Double }

    /// Exact port of the MCP `fuzzy_match(query, candidates, threshold)`.
    /// Token rules: exact-full 1.0 · exact-token .95 · query-prefix-of-token
    /// .85·(|q|/|t|) · token-prefix-of-query .80·(|t|/|q|) · else SequenceMatcher.
    /// Multi-word query OR sub-threshold also tries full-name SequenceMatcher.
    public static func matchContacts(query rawQuery: String,
                                     candidates: [ContactCandidate],
                                     threshold: Double = 0.6) -> [ScoredCandidate] {
        let query = cleanName(rawQuery).lowercased()
        if query.isEmpty { return [] }
        var results: [ScoredCandidate] = []

        for cand in candidates {
            let clean = cleanName(cand.name).lowercased()
            // Scalar-exact, for the same reason as the token compares below.
            if Array(query.unicodeScalars) == Array(clean.unicodeScalars) {
                results.append(.init(name: cand.name, value: cand.value, score: 1.0))
                continue
            }
            let tokens = clean.split(separator: " ").map(String.init)
            var best = 0.0
            let qCount = query.unicodeScalars.count
            let qs = Array(query.unicodeScalars)
            for token in tokens {
                let ts = Array(token.unicodeScalars)
                let tCount = ts.count
                // Compare SCALARS. Swift `==`/`hasPrefix` are canonical-equivalence and
                // grapheme-based; Python compares code points exactly. `.lowercased()` can
                // re-introduce a mark that `cleanName` just removed — U+0130 lowercases to
                // "i" + U+0307 — and there Python's startswith("i") is True (score 0.425,
                // excluded at threshold) while Swift's hasPrefix is false, because "i"+U+0307
                // is ONE grapheme. That flipped a contact into the results at 0.667.
                if qs == ts {
                    best = max(best, 0.95)
                } else if ts.starts(with: qs) {
                    best = max(best, 0.85 * (Double(qCount) / Double(tCount)))
                } else if qs.starts(with: ts) {
                    best = max(best, 0.80 * (Double(tCount) / Double(qCount)))
                } else {
                    best = max(best, sequenceRatio(query, token))
                }
            }
            if query.contains(" ") || best < threshold {
                best = max(best, sequenceRatio(query, clean))
            }
            if best >= threshold {
                results.append(.init(name: cand.name, value: cand.value, score: best))
            }
        }
        return results.sorted { $0.score > $1.score }
    }

    // MARK: - rapidfuzz-style ratios (for message WRatio)

    /// Longest-common-subsequence length over scalar slices (for normalized
    /// Indel similarity). Slice-based so the hot `partialRatio` sliding window
    /// needs no per-window `Array`/`String` allocation.
    private static func lcsLength(_ a: ArraySlice<Unicode.Scalar>, _ b: ArraySlice<Unicode.Scalar>) -> Int {
        let n = a.count, mm = b.count
        if n == 0 || mm == 0 { return 0 }
        let aBase = a.startIndex, bBase = b.startIndex
        var prev = [Int](repeating: 0, count: mm + 1)
        var curr = [Int](repeating: 0, count: mm + 1)
        for i in 1...n {
            let ai = a[aBase + i - 1]
            for j in 1...mm {
                if ai == b[bBase + j - 1] { curr[j] = prev[j - 1] + 1 }
                else { curr[j] = max(prev[j], curr[j - 1]) }
            }
            swap(&prev, &curr)
            for k in 0...mm { curr[k] = 0 }
        }
        return prev[mm]
    }

    private static func ratioChars(_ a: ArraySlice<Unicode.Scalar>, _ b: ArraySlice<Unicode.Scalar>) -> Double {
        let total = a.count + b.count
        if total == 0 { return 100.0 }
        return 100.0 * 2.0 * Double(lcsLength(a, b)) / Double(total)
    }

    /// rapidfuzz `ratio` = normalized Indel similarity = 100·2·LCS/(|a|+|b|).
    static func ratio(_ a: String, _ b: String) -> Double {
        let ac = Array(a.unicodeScalars), bc = Array(b.unicodeScalars)
        return ratioChars(ac[...], bc[...])
    }

    /// `partial_ratio`: rapidfuzz's optimal-alignment search, ported faithfully.
    ///
    /// THREE bounded loops over the same normalized-Indel kernel `ratioChars`, mirroring
    /// `_partial_ratio_impl` in rapidfuzz's `fuzz_py.py`: growing PREFIXES of the longer string,
    /// then full-length WINDOWS, then shrinking SUFFIXES. Each is guarded by "the newly-entering
    /// character appears in the needle at all", which is rapidfuzz's own cheap skip.
    ///
    /// WHY ALL THREE, measured rather than argued. The previous port implemented only the middle
    /// loop, and the missing two are not an edge case: on 768 real message bodies x 10 query terms
    /// at the default 0.6 threshold, the oracle matched 276 and this matched 204 — **73.9% recall,
    /// a quarter of fuzzy matches dropped**. The reason is the denominator. `ratio` is
    /// 2*LCS/(|a|+|b|), so a window SHORTER than the needle can score higher than any full-length
    /// window: `partial_ratio("golf", "a quiet symbol")` is 66.7 via the two-character suffix
    /// "ol" (2*2/(4+2)), where the best 4-character window manages only 50.0. Sliding one fixed
    /// length can never see that.
    ///
    /// `best` doubles as rapidfuzz's running `score_cutoff` in spirit — it only ever rises, and an
    /// exact alignment short-circuits at 100.
    /// Upper bound on loop-2 window offsets. See the long note at the loop itself: 14x the
    /// longest real message, chosen to keep oracle parity on every body that occurs while
    /// preventing an unbounded scan on a planted one.
    static let maxScanWindows = 20_000

    static func partialRatio(_ s1: String, _ s2: String) -> Double {
        let a = Array(s1.unicodeScalars), b = Array(s2.unicodeScalars)
        if a.isEmpty || b.isEmpty { return 0.0 }
        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        // NO EQUAL-LENGTH SHORTCUT. There was one — `if len1 == len2 { return ratioChars(...) }` —
        // and it was the same defect this function exists to fix, surviving in the one branch the
        // new loops are skipped on. rapidfuzz does not shortcut: at equal length loop 2 is a single
        // window but loops 1 and 3 still run, and a shorter prefix/suffix can beat the full
        // alignment. Both reviewers caught it independently, against the oracle:
        // `("thanks","thanka")` is 90.91 in rapidfuzz and was 83.33 here; `("abcd","xbcd")` 85.71
        // vs 75.0. Unreachable from `search` today — `wRatio` gates its call on `lenRatio >= 1.5` —
        // but `partialRatio` is internal, directly tested, and reachable from three ungated sites.
        var best = partialRatioImpl(shorter, longer)
        // rapidfuzz runs the impl a SECOND time with the arguments swapped when the lengths are
        // equal and the first pass was not exact (`fuzz_py.py` `partial_ratio`), because "shorter"
        // and "longer" are then arbitrary and the two orderings are not symmetric.
        if best <= 99.5, shorter.count == longer.count {
            best = max(best, partialRatioImpl(longer, shorter))
        }
        return best
    }

    private static func partialRatioImpl(_ shorter: [Unicode.Scalar], _ longer: [Unicode.Scalar]) -> Double {
        let len1 = shorter.count, len2 = longer.count
        let needleChars = Set(shorter)
        let sShort = shorter[...]
        var best = 0.0

        // Returns true when the alignment is exact and the caller should stop.
        func consider(_ window: ArraySlice<Unicode.Scalar>) -> Bool {
            let r = ratioChars(sShort, window)
            if r > best { best = r }
            return r > 99.5
        }

        // 1. Growing prefixes: longer[0..<i] for i < len1.
        if len1 > 1 {
            for i in 1..<len1 where needleChars.contains(longer[i - 1]) {
                if consider(longer[0..<i]) { return 100.0 }
            }
        }

        // 2. Full-length windows, bounded by `maxScanWindows` — far above any real message, so
        //    parity with rapidfuzz (which has no bound) is exact for every body that occurs.
        //
        //    The old bound was 1200 windows, and it BIT: across the corpus (10,115 bodies) the
        //    longest body is 1431 characters and 3 exceed 1200. Loop 3 only ever covers the last
        //    len1 characters, so offsets between the bound and the tail were evaluated by nothing
        //    and a match living there was unreachable — the last structural divergence from the
        //    oracle.
        //
        //    Removing the bound entirely was worse. This is the only O(len2) loop, `wRatio` runs
        //    5 `partialRatio` calls per candidate, search scans up to 10k rows, and NOTHING caps a
        //    message body (the search term is capped at 1024 by MessagesCommand; `messageBody`
        //    returns text/attributedBody untruncated). Cost grows linearly in body length, so a
        //    single long message — plantable by anyone who can iMessage the operator — stalls the
        //    whole search. Measured, release build, 1024-char term: a 1424-char body takes 0.42s
        //    per call, a 10,000-char body 2.95s; times 5 scorers, times however many such rows.
        //
        //    20,000 windows is 14x the longest real body and ~6s of worst-case work per call. It
        //    is a DEVIATION, not parity: a body over ~20k characters scores below the oracle. No
        //    such body exists in the corpus, and the alternative to bounding it is a bit-parallel
        //    LCS (what rapidfuzz actually does) rather than this O(len1^2)-per-window kernel.
        let cap = min(len2, len1 + Fuzzy.maxScanWindows)
        var i = 0
        while i + len1 <= cap {
            if needleChars.contains(longer[i + len1 - 1]), consider(longer[i..<(i + len1)]) {
                return 100.0
            }
            i += 1
        }

        // 3. Shrinking suffixes: longer[i...] for i >= len2 - len1.
        for i in max(len2 - len1, 0)..<len2 where needleChars.contains(longer[i]) {
            if consider(longer[i..<len2]) { return 100.0 }
        }

        return best
    }

    private static func tokenSort(_ s: String) -> String {
        s.split(separator: " ").map(String.init).sorted().joined(separator: " ")
    }

    static func tokenSortRatio(_ s1: String, _ s2: String) -> Double {
        ratio(tokenSort(s1), tokenSort(s2))
    }

    static func partialTokenSortRatio(_ s1: String, _ s2: String) -> Double {
        partialRatio(tokenSort(s1), tokenSort(s2))
    }

    /// token_set_ratio: intersection + remainder recombination, max of 3 ratios.
    static func tokenSetRatio(_ s1: String, _ s2: String, partial: Bool = false) -> Double {
        let t1 = Set(s1.split(separator: " ").map(String.init))
        let t2 = Set(s2.split(separator: " ").map(String.init))
        let inter = t1.intersection(t2).sorted()
        let diff1 = t1.subtracting(t2).sorted()
        let diff2 = t2.subtracting(t1).sorted()
        let sortedSect = inter.joined(separator: " ")
        let combined1 = (sortedSect + " " + diff1.joined(separator: " "))
            .trimmingCharacters(in: .whitespaces)
        let combined2 = (sortedSect + " " + diff2.joined(separator: " "))
            .trimmingCharacters(in: .whitespaces)
        let f = partial ? partialRatio : ratio
        return max(f(sortedSect, combined1), f(sortedSect, combined2), f(combined1, combined2))
    }

    static func partialTokenSetRatio(_ s1: String, _ s2: String) -> Double {
        tokenSetRatio(s1, s2, partial: true)
    }

    /// Faithful port of `thefuzz.WRatio` (force_ascii=True, full_process=True):
    /// full_process both, length-scaled partial/token blend, integer-rounded 0–100.
    public static func wRatio(_ s1: String, _ s2: String) -> Double {
        let p1 = fullProcess(s1), p2 = fullProcess(s2)
        if p1.isEmpty || p2.isEmpty { return 0.0 }

        let unbaseScale = 0.95
        var partialScale = 0.90
        var tryPartial = true

        let base = ratio(p1, p2)
        // CODE POINTS, not grapheme clusters — Python's len() counts code points, and the
        // difference changes lenRatio and therefore which wRatio branch runs. See Q5c.
        let len1 = p1.unicodeScalars.count, len2 = p2.unicodeScalars.count
        let lenRatio = Double(max(len1, len2)) / Double(min(len1, len2))
        if lenRatio < 1.5 { tryPartial = false }
        if lenRatio > 8 { partialScale = 0.6 }

        if tryPartial {
            let partial = partialRatio(p1, p2) * partialScale
            let ptsor = partialTokenSortRatio(p1, p2) * unbaseScale * partialScale
            let ptser = partialTokenSetRatio(p1, p2) * unbaseScale * partialScale
            // Python `int(round(...))` is banker's rounding (half-to-even) — match it
            // so scores landing exactly on x.5 don't flip in/out at a threshold boundary.
            return (max(base, partial, ptsor, ptser)).rounded(.toNearestOrEven)
        } else {
            let tsor = tokenSortRatio(p1, p2) * unbaseScale
            let tser = tokenSetRatio(p1, p2) * unbaseScale
            return (max(base, tsor, tser)).rounded(.toNearestOrEven)
        }
    }
}
