import Testing
import Foundation
@testable import AppleKit

/// Q12 [17]/[10]/CAL-05: terminal-safety of the `--text` path. The JSON envelope is the
/// machine contract and stays byte-exact (control bytes are \uXXXX-escaped by the encoder);
/// these pins cover the human text path's equivalent guarantee.
@Suite("TextSanitize (terminal-output safety)")
struct TextSanitizeTests {

    @Test func neutralizesEscAndCsi() {
        // A full SGR color sequence: ESC [ 3 1 m … ESC [ 0 m → visible caret notation, no ESC.
        let got = TextSanitize.neutralizeForTerminal("\u{1B}[31mRED\u{1B}[0m")
        #expect(got == "^[[31mRED^[[0m")
        #expect(!got.unicodeScalars.contains { $0.value == 0x1B })
    }

    @Test func neutralizesCarriageReturnAndOtherC0() {
        // CR is the simplest visible-output forgery (return to column 0 + overwrite).
        #expect(TextSanitize.neutralizeForTerminal("safe\rEVIL") == "safe^MEVIL")
        // NUL and BEL become caret notation too.
        #expect(TextSanitize.neutralizeForTerminal("a\u{00}b\u{07}c") == "a^@b^Gc")
    }

    @Test func preservesTabNewlineAndUnicode() {
        // TAB + LF are legitimate layout, kept verbatim; printable Unicode passes through.
        #expect(TextSanitize.neutralizeForTerminal("col1\tcol2\nline2") == "col1\tcol2\nline2")
        #expect(TextSanitize.neutralizeForTerminal("café 日本語 😀") == "café 日本語 😀")
    }

    @Test func neutralizesBidiOverrides() {
        // Trojan-Source: RLO (U+202E) reorders the visible text — neutralized to \u202E.
        let got = TextSanitize.neutralizeForTerminal("file\u{202E}gpj.exe")
        #expect(got == "file\\u202Egpj.exe")
        #expect(!got.unicodeScalars.contains { $0.value == 0x202E })
        // The isolates and marks too.
        for cp: UInt32 in [0x200E, 0x200F, 0x061C, 0x202A, 0x2066, 0x2069] {
            let scalar = Unicode.Scalar(cp)!
            let out = TextSanitize.neutralizeForTerminal("a\(Character(scalar))b")
            #expect(!out.unicodeScalars.contains { $0.value == cp }, "U+\(String(cp, radix: 16))")
        }
    }

    @Test func neutralizesDelAndC1() {
        #expect(TextSanitize.neutralizeForTerminal("x\u{7F}y") == "x^?y")
        // 8-bit CSI (U+009B) and a C1 control render as \u00XX, never a raw driving byte.
        let got = TextSanitize.neutralizeForTerminal("a\u{9B}31mb")
        #expect(got == "a\\u009B31mb")
        #expect(!got.unicodeScalars.contains { (0x80...0x9F).contains($0.value) })
    }

    /// The shared text-aware emit renders human `key: value` lines with EVERY string value
    /// neutralized — so a store-derived string reaching `--text` can never carry an escape.
    @Test func humanTextNeutralizesStringValues() throws {
        struct P: Encodable { let title: String; let count: Int }
        let out = try Output.humanText(P(title: "hi\u{1B}[2Jclear", count: 3))
        #expect(out.contains("title: hi^[[2Jclear"))
        #expect(out.contains("count: 3"))
        #expect(!out.unicodeScalars.contains { $0.value == 0x1B })
    }

    /// Regression (review MEDIUM): `JSONSerialization` bridges JSON booleans AND JSON 0/1
    /// all to `NSNumber`, and `NSNumber(0/1) as? Bool` SUCCEEDS. An `as? Bool` test placed
    /// before the NSNumber branch would render a numeric count of 0/1 (moved_count, unread,
    /// deleted_count) as "false"/"true". A count of 1 must stay `1`; a real boolean must
    /// still render true/false.
    @Test func humanTextRendersNumericZeroOneAsNumberNotBool() throws {
        struct P: Encodable { let moved_count: Int; let unread: Int; let flagged: Bool; let archived: Bool }
        let out = try Output.humanText(P(moved_count: 1, unread: 0, flagged: true, archived: false))
        #expect(out.contains("moved_count: 1"))
        #expect(out.contains("unread: 0"))
        #expect(out.contains("flagged: true"))
        #expect(out.contains("archived: false"))
    }

    /// A nested container's inner string values are SAFE: JSONSerialization renders the
    /// compact blob with control bytes already `\uXXXX`-escaped to literal text, so no raw
    /// driving ESC byte survives (the renderer's wholesale pass is belt-and-suspenders for
    /// any C1 byte the JSON form might carry). The guarantee under test is "no raw ESC
    /// reaches the terminal", not the caret shape.
    @Test func humanTextNestedStringsCarryNoRawEsc() throws {
        struct Inner: Encodable { let name: String }
        struct P: Encodable { let items: [Inner] }
        let out = try Output.humanText(P(items: [Inner(name: "a\u{1B}[31mb")]))
        #expect(!out.unicodeScalars.contains { $0.value == 0x1B })
        #expect(!out.unicodeScalars.contains { (0x80...0x9F).contains($0.value) })
        #expect(out.contains("\\u001b") || out.contains("\\u001B"))   // escaped to literal text, safe
    }
}
