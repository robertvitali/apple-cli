import Foundation
import Testing
@testable import NotesKit

/// `NotesText.stripTags` replaces a global `<[^>]*>` regex replace that was O(N²) — measured at
/// 0.41 s / 1.64 s / 6.54 s for 10k / 20k / 40k characters of unmatched `<` (4× per doubling),
/// so ~60 s at 121 KB. `notes update --format html` runs it AFTER the note has already been
/// written, so the hang stranded a caller mid-write; `get-note-plaintext` / `get-note-markdown`
/// run it on stored bodies, which have no argv ceiling at all.
///
/// The scanner is only safe if it is EXACTLY equivalent to the regex, so equivalence is
/// established differentially against the regex itself rather than against hand-written
/// expectations — the regex is the thing being replaced, so it is the correct oracle here.
@Suite("stripTags is a linear equivalent of the <[^>]*> regex")
struct StripTagsEquivalenceTests {

    /// The single-pass `<[^>]*>` -> `" "` form, which is what `htmlToTextForHashtags` actually
    /// replaced (`:143` ran ONE pass, not a fixed point). Kept separate from the fixed-point
    /// helper so the space form is pinned against the construct it really replaced.
    static func regexStripOnce(_ input: String, replacement: String) -> String {
        let re = try! NSRegularExpression(pattern: "<[^>]*>", options: [.anchorsMatchLines])
        let ns = input as NSString
        return re.stringByReplacingMatches(
            in: input, range: NSRange(location: 0, length: ns.length), withTemplate: replacement)
    }

    /// The construct being replaced, run to a fixed point exactly as the call sites did.
    ///
    /// `.anchorsMatchLines` is set because the production call sites went through
    /// `NotesText.regexReplace`, which always inserted it. It is inert for an anchorless pattern —
    /// but this suite claims to pin against the construct that was removed, so it must actually
    /// BE that construct rather than a simplified reconstruction of it.
    static func regexStripFixedPoint(_ input: String) -> String {
        let re = try! NSRegularExpression(pattern: "<[^>]*>", options: [.anchorsMatchLines])
        var text = input, previous: String
        repeat {
            previous = text
            let ns = text as NSString
            text = re.stringByReplacingMatches(
                in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        } while text != previous
        return text
    }

    /// Deterministic PRNG (SplitMix64) so a failure is reproducible from the seed alone.
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func pick<T>(_ xs: [T]) -> T { xs[Int(next() % UInt64(xs.count))] }
    }

    /// Atoms chosen so the generator can REACH the shapes that discriminate: bare `<` with no
    /// closing `>` (the quadratic trigger and the "copy the remainder verbatim" branch), `>`
    /// with no opener, nested `<` inside a tag, and astral scalars that would break any
    /// implementation doing UTF-16 index arithmetic by hand.
    static let atoms = ["<", ">", "<div>", "</div>", "<a href=\"x\">", "<b", "b>", "text", " ",
                        "\n", "<>", "<<", ">>", "\u{1F600}", "\u{0301}", "&amp;", "<script>",
                        "</script>", "\r\n", "\u{2028}", "<\u{1F600}>", "e\u{0301}"]

    @Test("differential: 20,000 generated bodies agree with the regex exactly")
    func differentialAgainstRegex() {
        var rng = Rng(state: 0xC0FF_EE12_3456_789A)
        var sawTrailingUnclosed = 0, sawAstralInDeletedSpan = 0, sawMarkAfterBracket = 0
        for _ in 0..<20_000 {
            let n = Int(rng.next() % 24) + 1
            var s = ""
            for _ in 0..<n { s += rng.pick(Self.atoms) }
            let linear = NotesText.stripTags(s)
            let regex = Self.regexStripFixedPoint(s)
            #expect(linear == regex, "input \(s.debugDescription): linear \(linear.debugDescription) vs regex \(regex.debugDescription)")

            // The space-substituting overload feeds `notes get`'s hashtag extraction, where a
            // wrong join would INVENT or LOSE hashtags. The record calls this site out as "not a
            // drop-in", and review found it had zero coverage — the one site flagged as
            // behaviourally distinct was the one the differential never exercised.
            let spaced = NotesText.stripTags(s, replacement: " ")
            let spacedRegex = Self.regexStripOnce(s, replacement: " ")
            #expect(spaced == spacedRegex, "space form, input \(s.debugDescription): \(spaced.debugDescription) vs \(spacedRegex.debugDescription)")

            // Reach controls: a clean differential is only as strong as what the generator hit.
            if let lt = s.lastIndex(of: "<"), !s[lt...].contains(">") { sawTrailingUnclosed += 1 }
            // An astral scalar ANYWHERE is a weak proxy — the discriminating property is one
            // INSIDE a span that gets deleted, which is where UTF-16 index arithmetic would slip.
            if let lt = s.firstIndex(of: "<"), let gt = s[lt...].firstIndex(of: ">"),
               s[lt...gt].unicodeScalars.contains(where: { $0.value > 0xFFFF }) {
                sawAstralInDeletedSpan += 1
            }
            // The class this repo keeps re-hitting: a combining mark adjacent to a delimiter.
            // `<` + U+0301 is ONE grapheme, so a `Character`-based scanner would silently retain
            // every such tag. This is the ONLY shape that kills that mutant — the hand-picked
            // list scores zero on it — so if the atom producing it is ever removed, fail loudly.
            var prevWasBracket = false
            for u in s.unicodeScalars {
                if prevWasBracket && (0x0300...0x036F).contains(u.value) { sawMarkAfterBracket += 1; break }
                prevWasBracket = (u == "<" || u == ">")
            }
        }
        #expect(sawTrailingUnclosed > 100, "reach control: the unclosed-`<` branch must be exercised (saw \(sawTrailingUnclosed))")
        #expect(sawAstralInDeletedSpan > 100, "reach control: astral scalars INSIDE a deleted span (saw \(sawAstralInDeletedSpan))")
        #expect(sawMarkAfterBracket > 100, "reach control: combining mark adjacent to `<`/`>` (saw \(sawMarkAfterBracket))")
    }

    @Test("hand-picked shapes where the two could plausibly disagree")
    func adversarialShapes() {
        let cases = [
            "", "<", ">", "<>", "<<>", "<<<", ">>>", "a<b", "a>b", "<a<b>c",
            "<div>x</div", "x</div>", "<\u{1F600}>after", "<a\u{1F600}b>after", "\u{1F600}<a>\u{1F600}",
            "<a><b><c>", "no tags at all", "<unclosed attr=\"", "text<", "<\n>", "<\r\n>",
            "<script>x</script>", "<a>b<c", "e\u{0301}<x>e\u{0301}",
        ]
        for s in cases {
            #expect(NotesText.stripTags(s) == Self.regexStripFixedPoint(s), "shape \(s.debugDescription)")
        }
    }

    @Test("the quadratic blowup is gone")
    func linearOnPathologicalInput() {
        // 200,000 unmatched `<` — the regex form needs minutes here (extrapolating the measured
        // 4×-per-doubling curve from 6.54 s at 40k). A generous ceiling keeps this from being a
        // flaky timing test while still failing loudly if the regex ever comes back.
        let pathological = String(repeating: "<", count: 200_000)
        let started = Date()
        let out = NotesText.stripTags(pathological)
        let elapsed = Date().timeIntervalSince(started)
        #expect(out == pathological, "unmatched `<` must survive verbatim")
        #expect(elapsed < 5.0, "stripTags took \(elapsed)s on 200k unmatched `<` — quadratic behaviour is back")
    }
}
