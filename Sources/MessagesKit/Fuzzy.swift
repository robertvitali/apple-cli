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
            CharacterSet.alphanumerics.contains(scalar) ||
            scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" ||
            scalar == "'" || scalar == "-"
        }.map(Character.init))
        return collapseWhitespace(filtered)
    }

    /// Port of the MCP's `_clean_text(strip_punctuation=False)`: strip emoji +
    /// collapse whitespace only. Used for MESSAGE fuzzy search pre-cleaning.
    public static func cleanText(_ text: String) -> String {
        collapseWhitespace(stripEmoji(text))
    }

    /// Port of `thefuzz.utils.full_process(force_ascii=True)` used inside WRatio:
    /// drop non-ASCII, replace every non-alphanumeric char with a space, then
    /// `.strip().lower()` (rapidfuzz `default_process` does NOT collapse internal
    /// runs — reproduced faithfully).
    static func fullProcess(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            if scalar.value >= 128 { continue } // ascii_only
            let isAlnum = (scalar.value >= 48 && scalar.value <= 57) ||
                          (scalar.value >= 65 && scalar.value <= 90) ||
                          (scalar.value >= 97 && scalar.value <= 122)
            out.unicodeScalars.append(isAlnum ? scalar : " ")
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\u{0b}\u{0c}"))
            .lowercased()
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
        let aChars = Array(a), bChars = Array(b)
        let total = aChars.count + bChars.count
        if total == 0 { return 1.0 }
        let matches = matchingBlocksTotal(aChars, bChars)
        return 2.0 * Double(matches) / Double(total)
    }

    /// Sum of matching-block sizes (the `M` in difflib's ratio).
    private static func matchingBlocksTotal(_ a: [Character], _ b: [Character]) -> Int {
        // b2j: char -> sorted indices in b.
        var b2j: [Character: [Int]] = [:]
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
            if query == clean {
                results.append(.init(name: cand.name, value: cand.value, score: 1.0))
                continue
            }
            let tokens = clean.split(separator: " ").map(String.init)
            var best = 0.0
            let qCount = query.count
            for token in tokens {
                let tCount = token.count
                if query == token {
                    best = max(best, 0.95)
                } else if token.hasPrefix(query) {
                    best = max(best, 0.85 * (Double(qCount) / Double(tCount)))
                } else if query.hasPrefix(token) {
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

    /// Longest-common-subsequence length over character slices (for normalized
    /// Indel similarity). Slice-based so the hot `partialRatio` sliding window
    /// needs no per-window `Array`/`String` allocation.
    private static func lcsLength(_ a: ArraySlice<Character>, _ b: ArraySlice<Character>) -> Int {
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

    private static func ratioChars(_ a: ArraySlice<Character>, _ b: ArraySlice<Character>) -> Double {
        let total = a.count + b.count
        if total == 0 { return 100.0 }
        return 100.0 * 2.0 * Double(lcsLength(a, b)) / Double(total)
    }

    /// rapidfuzz `ratio` = normalized Indel similarity = 100·2·LCS/(|a|+|b|).
    static func ratio(_ a: String, _ b: String) -> Double {
        let ac = Array(a), bc = Array(b)
        return ratioChars(ac[...], bc[...])
    }

    /// `partial_ratio`: best `ratio` of the shorter string against the best-aligned
    /// window of the longer. rapidfuzz aligns optimally; we approximate that with an
    /// exhaustive fixed-length-`m` sliding window (much closer to rapidfuzz than the
    /// classic matching-block-anchored fuzzywuzzy variant, which missed real matches).
    /// The scan is bounded to the first `windowScanCap` chars of the longer string —
    /// a short fuzzy term that only aligns beyond that in a long message would have
    /// already been caught by the exact-substring short-circuit upstream, so the cap
    /// is safe and bounds worst-case cost. Operates on shared character arrays (no
    /// per-window allocation) since search runs this ~5×/candidate over up to 10k rows.
    static let windowScanCap = 1200
    static func partialRatio(_ s1: String, _ s2: String) -> Double {
        let a = Array(s1), b = Array(s2)
        if a.isEmpty || b.isEmpty { return 0.0 }
        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        let m = shorter.count
        if m == longer.count { return ratioChars(shorter[...], longer[...]) }
        let cap = min(longer.count, windowScanCap)
        let sShort = shorter[...]
        var best = 0.0
        var start = 0
        while start + m <= cap {
            let r = ratioChars(sShort, longer[start..<(start + m)])
            if r > 99.5 { return 100.0 }
            if r > best { best = r }
            start += 1
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
        let len1 = p1.count, len2 = p2.count
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
