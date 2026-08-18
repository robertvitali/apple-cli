import Foundation

/// Terminal-output safety for `--text` mode (Q12 [17]).
///
/// Every human `--text` rendering interpolates store-derived, remote-controlled strings —
/// message subjects and senders, contact names and notes, template bodies, event titles —
/// straight into the terminal. An embedded ESC / CSI sequence in any of those can move the
/// cursor, clear the screen, recolor, or (on some terminals) drive a title-set or
/// paste-bracket escape — rewriting what the operator SEES relative to what the tool
/// actually did. JSON output is unaffected (control bytes are `\uXXXX`-escaped by the
/// encoder); this is the text path's equivalent guarantee.
///
/// The JSON envelope remains the machine contract and is NEVER routed through this — it must
/// stay byte-exact. This is for the non-contractual `--text` convenience path only.
public enum TextSanitize {

    /// Neutralize control bytes that can drive a terminal, preserving `\n` and `\t` (legitimate
    /// layout) and every printable/Unicode character. A neutralized byte becomes a visible
    /// caret/hex token so information is disclosed, never silently dropped:
    ///   * ESC (0x1B) and every other C0 control except TAB/newline → `^X` caret notation;
    ///   * DEL (0x7F) → `^?`;
    ///   * C1 controls (U+0080…U+009F, incl. the 8-bit CSI U+009B) → `\u00XX`;
    ///   * Unicode bidi/RTL overrides (LRM/RLM/ALM, U+202A…U+202E, U+2066…U+2069) → `\uXXXX`
    ///     — not terminal-DRIVING but they REORDER displayed text (Trojan-Source,
    ///     CVE-2021-42574), the same "seen ≠ done" threat, so neutralized too.
    /// CR (0x0D) is neutralized too — a bare CR returns the cursor to column 0 and overwrites
    /// the line, the simplest visible-output forgery.
    ///
    /// DELIBERATELY out of scope (both reviewers, non-blocking): zero-width / line-separator
    /// scalars (U+200B–200D, U+FEFF, U+2028/U+2029) and homoglyph / combining-mark
    /// display-spoofing are NOT neutralized. None can drive a terminal or reorder text the way
    /// an escape or a bidi override can, and neutralizing every Unicode confusable would corrupt
    /// legitimate content (accented text, ZWJ emoji, non-Latin scripts). The injection threat
    /// this guards — a store string moving the cursor or forging what the operator sees — is
    /// fully covered by killing every ESC / C0 / C1 introducer plus the bidi set; a confusable
    /// that merely *looks* like another glyph is a different, lower-severity problem left to the
    /// human reader.
    public static func neutralizeForTerminal(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x09, 0x0A:                     // TAB, LF — legitimate layout, kept
                out.unicodeScalars.append(scalar)
            case 0x00...0x1F:                    // C0 controls (incl. ESC 0x1B, CR 0x0D)
                out.append("^")
                out.unicodeScalars.append(Unicode.Scalar(v ^ 0x40)!)   // caret notation: ^[ , ^M , …
            case 0x7F:                           // DEL
                out.append("^?")
            case 0x80...0x9F:                    // C1 controls (incl. 8-bit CSI 0x9B)
                out.append(String(format: "\\u%04X", v))
            case 0x200E, 0x200F, 0x061C,         // LRM / RLM / Arabic Letter Mark
                 0x202A...0x202E,                // LRE RLE PDF LRO RLO (bidi embeddings/overrides)
                 0x2066...0x2069:                // LRI RLI FSI PDI (bidi isolates)
                // Trojan-Source (CVE-2021-42574): these REORDER displayed text, so a subject/
                // name/filename can render in an order that differs from the logical string —
                // the same "what the operator SEES ≠ what the tool DID" threat this exists for.
                // Not terminal-DRIVING, but display-spoofing, so neutralized to visible text.
                out.append(String(format: "\\u%04X", v))
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
