import Foundation

/// Text/HTML transforms ported from `apple-notes-mcp@2.5.12` (`hashtags.ts`,
/// `inlineImages.ts`, the manager's `htmlToPlaintext`/`htmlToMarkdown`/checklist enrichment,
/// and the body-escaping helpers). Pure functions — fully unit-testable.
///
/// IMPORTANT distinction vs. the reference: these helpers do the CONTENT transformation
/// (HTML-entity escaping, `<br>` conversion, `<h1>` wrapping) only. They do NOT do the
/// reference's AppleScript *injection* escaping (`\"`, `\\`), because apple-cli passes every
/// user value to osascript as argv (`on run argv`), never interpolated into script source —
/// so injection escaping is unnecessary and would corrupt the data.
enum NotesText {

    // MARK: Body construction (create/update)

    /// create-note plaintext body transform: `& \ < > \n \t` → entities/`<br>`. Matches the
    /// reference's inline `content.replace(...)` chain for `format: "plaintext"`.
    static func plaintextToHtmlBody(_ content: String) -> String {
        var s = content
        s = s.replacingOccurrences(of: "&", with: "&amp;")
        s = s.replacingOccurrences(of: "\\", with: "&#92;")
        s = s.replacingOccurrences(of: "<", with: "&lt;")
        s = s.replacingOccurrences(of: ">", with: "&gt;")
        s = s.replacingOccurrences(of: "\n", with: "<br>")
        s = s.replacingOccurrences(of: "\t", with: "<br>")
        return s
    }

    /// Title → HTML-safe `<h1>` inner text: `& < >` only (matches `htmlTitle`).
    static func htmlTitleEscape(_ title: String) -> String {
        title.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// update-note plaintext escape (`escapeForAppleScript` minus the injection part): `& \ \n \t`.
    /// Note it does NOT escape `< >` — matching the reference asymmetry with create-note.
    static func updateEscape(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "&", with: "&amp;")
        s = s.replacingOccurrences(of: "\\", with: "&#92;")
        s = s.replacingOccurrences(of: "\n", with: "<br>")
        s = s.replacingOccurrences(of: "\t", with: "<br>")
        return s
    }

    // MARK: append-to-note assembly (oracle: build/index.js `append-to-note`, 2.6.12)

    /// Oracle `contentToHtml`. NOT `updateEscape`: the oracle escapes `&`, `<` and `>` and splits
    /// on newlines into one `<div>` per line (`<br>` for an empty line), where `updateEscape`
    /// leaves `<`/`>` intact and turns `\n` into a bare `<br>`. Reusing `updateEscape` here would
    /// inject caller plaintext as live HTML — `--content "<b>x</b>"` would render bold.
    static func appendContentToHtml(_ text: String, html: Bool) -> String {
        if html { return text }
        // Split on SCALARS, and escape with .literal. Both are the same lesson: JS operates on
        // UTF-16 code units, Swift's defaults on grapheme clusters with canonical equivalence.
        // "\r\n" is ONE Character, so a Character split never breaks a CRLF pair the oracle does
        // break; and `&` followed by a combining mark is not the grapheme `&`, so a default
        // replacingOccurrences leaves it unescaped where JS .replace(/&/g) does not.
        return text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let escaped = String(String.UnicodeScalarView(line))
                .replacingOccurrences(of: "&", with: "&amp;", options: .literal)
                .replacingOccurrences(of: "<", with: "&lt;", options: .literal)
                .replacingOccurrences(of: ">", with: "&gt;", options: .literal)
            return "<div>\(escaped.isEmpty ? "<br>" : escaped)</div>"
        }.joined()
    }

    /// Oracle `separatorToHtml`. The default "\n\n" is special-cased to a single blank line
    /// rather than going through the per-line path (which would yield two empty divs).
    static func appendSeparatorToHtml(_ sep: String, html: Bool) -> String {
        if html { return sep }
        if sep == "\n\n" { return "<div><br></div>" }
        let escaped = sep
            .replacingOccurrences(of: "&", with: "&amp;", options: .literal)
            .replacingOccurrences(of: "<", with: "&lt;", options: .literal)
            .replacingOccurrences(of: ">", with: "&gt;", options: .literal)
        return "<div>\(escaped)</div>"
    }

    /// Oracle body assembly. Notes stores the title as the note's FIRST `<div>`, so a prepend has
    /// to land after it — otherwise "before" silently rewrites the note's title. Splitting on the
    /// first `</div>` is the oracle's own rule; when there is none the whole body is treated as
    /// body with an empty title div, which is what the oracle does too.
    static func assembleAppend(existingHtml: String, content: String, separator: String,
                               prepend: Bool, html: Bool) -> String {
        let marker = "</div>"
        let titleDiv: String, bodyHtml: String
        // .literal is load-bearing: without it a combining mark / ZWJ / VS16 immediately after
        // the first `</div>` forms one grapheme with the `>`, the match slides to a LATER
        // `</div>`, and a --position before then overwrites the note's real title.
        if let r = existingHtml.range(of: marker, options: .literal) {
            titleDiv = String(existingHtml[existingHtml.startIndex..<r.upperBound])
            bodyHtml = String(existingHtml[r.upperBound...])
        } else {
            titleDiv = ""
            bodyHtml = existingHtml
        }
        let newBlock = appendContentToHtml(content, html: html)
        let sepHtml = appendSeparatorToHtml(separator, html: html)
        return prepend ? titleDiv + newBlock + sepHtml + bodyHtml
                       : titleDiv + bodyHtml + sepHtml + newBlock
    }

    /// Full create-note body: `<h1>title</h1>` + (html→raw | plaintext→escaped). The title is
    /// ALWAYS prepended, even in html format (matches the reference).
    static func createNoteBody(title: String, content: String, html: Bool) -> String {
        let body = html ? content : plaintextToHtmlBody(content)
        return "<h1>\(htmlTitleEscape(title))</h1>\(body)"
    }

    /// Full update-note body. html format → content verbatim (newTitle ignored, must be in the
    /// HTML). plaintext → `<div>title</div><div>content</div>`.
    static func updateNoteBody(effectiveTitle: String, content: String, html: Bool) -> String {
        if html { return content }
        return "<div>\(updateEscape(effectiveTitle))</div><div>\(updateEscape(content))</div>"
    }

    // MARK: Hashtags

    /// Strip tags + `#tag` regex, deduped case-insensitively (port of `parseHashtags`).
    static func parseHashtags(_ body: String) -> [String] {
        if body.isEmpty { return [] }
        let text = htmlToTextForHashtags(body)
        let pattern = "(?<![\\p{L}\\p{N}_])#([\\p{L}\\p{N}_]*\\p{L}[\\p{L}\\p{N}_]*)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range(at: 1))
            let key = tag.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                result.append(tag)
            }
        }
        return result
    }

    private static func htmlToTextForHashtags(_ html: String) -> String {
        var s = html
        s = stripTags(s, replacement: " ")   // linear; `" "` so words never join across a tag
        s = regexReplace(s, "&#x?[0-9a-fA-F]+;", " ")
        s = regexReplace(s, "&[a-zA-Z]+;", " ")
        return s
    }

    // MARK: Inline image stripping

    struct StrippedImages {
        var html: String
        var count: Int
        var bytes: Int
    }

    /// Replace oversized inline `data:` images with a placeholder div (port of
    /// `stripLargeInlineImages`); default cap 256 KB of base64 chars.
    static func stripLargeInlineImages(_ html: String, maxBytes: Int = 256 * 1024) -> StrippedImages {
        let pattern = "<img\\b[^>]*\\bsrc\\s*=\\s*([\"'])data:([^;'\"]+);base64,([^\"']*)\\1[^>]*/?>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return StrippedImages(html: html, count: 0, bytes: 0)
        }
        let ns = html as NSString
        var result = ""
        var last = 0
        var count = 0
        var bytes = 0
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let mediaType = ns.substring(with: m.range(at: 2))
            let b64 = ns.substring(with: m.range(at: 3))
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if b64.count <= maxBytes {
                result += ns.substring(with: m.range) // keep as-is
            } else {
                let decoded = b64.count * 3 / 4
                count += 1
                bytes += decoded
                result += "<div>[inline image omitted: \(mediaType), ~\(formatBytes(decoded)); "
                    + "use list-attachments and save-attachment or fetch-attachment to export it]</div>"
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return StrippedImages(html: result, count: count, bytes: bytes)
    }

    static func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        if bytes >= 1024 { return "\(Int((Double(bytes) / 1024).rounded())) KB" }
        return "\(bytes) B"
    }

    // MARK: HTML → plaintext (export)

    /// Port of the manager's `htmlToPlaintext`: block tags → newlines, strip remaining tags,
    /// decode a fixed entity set, collapse blank runs.
    static func htmlToPlaintext(_ html: String) -> String {
        var text = html
        text = regexReplace(text, "<br\\s*/?>", "\n", caseInsensitive: true)
        text = regexReplace(text, "</div>", "\n", caseInsensitive: true)
        text = regexReplace(text, "</p>", "\n", caseInsensitive: true)
        text = stripTags(text)   // linear equivalent of the `<[^>]*>` fixed point
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#92;", with: "\\")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = regexReplace(text, "\n{3,}", "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: HTML → Markdown (turndown-equivalent, pragmatic)

    /// ECMAScript `\s`, spelled out as an ICU class BODY (interpolate as `[\(jsSpace)]`): JS `\s`
    /// includes U+FEFF and EXCLUDES U+0085; ICU's `\s` is the opposite on BOTH. Shared by the
    /// checklist detector below and `firstVisibleHtmlLine` (whose `<br>` rule needs the same set —
    /// the oracle's BREAK_RE is `/<br\s*\/?\s*>/gi`, so its whitespace is ECMAScript's, not ICU's).
    static let jsSpace = "\t\n\u{0b}\u{0c}\r \u{a0}\u{1680}\u{2000}-\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}"

    /// ECMAScript `\w`, for `\b` emulation: JS `\b` without the `u` flag is ASCII-only.
    private static let jsWord = "0-9A-Za-z_"

    /// The oracle's `detectChecklistAttempt` (`src/utils/contentWarnings.ts`) — the warning to
    /// append, or nil.
    ///
    /// WHY IT EXISTS. Apple Notes checklists cannot be created through AppleScript at all:
    /// `<input type="checkbox">` is stripped, checklist CSS classes are dropped, and markdown
    /// `- [ ]` arrives as literal text. An agent that writes a checklist therefore gets `ok: true`
    /// and a note that silently is not one. The oracle warns; we did not. That is NOTES-M8.
    ///
    /// The three rules are OR'd. The oracle's source:
    ///
    ///     const htmlCheckbox     = /<input\b[^>]*\btype\s*=\s*["']checkbox["']/i.test(content);
    ///     const markdownCheckbox = /^[ \t]*[-*]\s+\[[ xX]\]/m.test(content);
    ///     const checklistClass   = /class\s*=\s*["'][^"']*\b(?:checklist|todo)\b/i.test(content);
    ///
    /// They are deliberately NOT transcribed as inline-flag ICU patterns: four ICU constructs
    /// silently diverge from ECMAScript (no `u` flag) on non-ASCII input — a review probe found
    /// 10 of 14 targeted inputs disagreeing with the oracle. Each is spelled out instead:
    ///
    ///   - `(?m)^` — ICU's line-terminator set adds U+000B/U+000C/U+0085 to JS's {LF CR LS PS}.
    ///     Ported as `(?:\A|[\n\r\u2028\u2029])`; consuming the terminator is harmless for a
    ///     boolean test.
    ///   - `\s` — JS includes U+FEFF and excludes U+0085; ICU the opposite on both. Ported as
    ///     `[jsSpace]`, the same fix `firstVisibleHtmlLine` already carries.
    ///   - `\b` — JS without `u` is ASCII `[0-9A-Za-z_]`; ICU's is Unicode-aware (é or a combining
    ///     mark counts as word-internal). Ported as `(?<![jsWord])` / `(?![jsWord])` lookarounds.
    ///   - `(?i)` — ICU applies full Unicode case folding (U+212A KELVIN SIGN matches `k`); JS
    ///     canonicalization never maps a non-ASCII character onto an ASCII one. Ported as explicit
    ///     `[cC]`-style classes.
    ///
    /// Two details that are easy to lose in translation: `markdownCheckbox` is MULTILINE, so it
    /// fires on a `- [ ]` line anywhere in the body rather than only at the very start; and
    /// `[ xX]` accepts a space, `x` or `X` but NOT an empty `[]`.
    ///
    /// SCOPE — create and the two update paths only. The gap was filed as "create / update /
    /// append", but the oracle calls this from `create-note` and both `update-note` branches and
    /// NOT from `append-to-note` (exactly three call sites in its bundle). Warning on append would
    /// be inventing behaviour the oracle does not have, so append is left alone.
    private static let markdownCheckboxPattern =
        #"(?:\A|[\n\r\u2028\u2029])[ \t]*[-*][\#(jsSpace)]+\[[ xX]\]"#
    private static let checklistClassPattern =
        #"[cC][lL][aA][sS][sS][\#(jsSpace)]*=[\#(jsSpace)]*["'][^"']*(?<![\#(jsWord)])(?:[cC][hH][eE][cC][kK][lL][iI][sS][tT]|[tT][oO][dD][oO])(?![\#(jsWord)])"#

    static func detectChecklistAttempt(_ content: String) -> String? {
        if content.isEmpty { return nil }
        guard htmlCheckboxAttempt(content)
            || content.range(of: markdownCheckboxPattern, options: .regularExpression) != nil
            || content.range(of: checklistClassPattern, options: .regularExpression) != nil
        else { return nil }
        return "\n\n\u{26A0}\u{FE0F} Your content looks like a checklist, but Apple Notes checklists "
            + "cannot be created via AppleScript \u{2014} `<input type=\"checkbox\">` is stripped, "
            + "checklist CSS classes are dropped, and markdown `- [ ]` lines arrive as literal text. "
            + "The note was created with the surrounding structure (list items or paragraphs) intact. "
            + "To convert it to a real Apple Notes checklist, open the note, select the items, and "
            + "press \u{21E7}\u{2318}L (Format \u{2192} Checklist)."
    }

    /// `/<input\b[^>]*\btype\s*=\s*["']checkbox["']/i` as a LINEAR two-phase scan.
    ///
    /// The regex form is quadratic on repeated unterminated `<input`: every start position scans
    /// `[^>]*` to end-of-input before failing — review measured 0.46 / 1.82 / 7.48 / 29.6 s at
    /// 6 / 12 / 24 / 48 KB (clean 4x per doubling), against a 5 MiB `--content` budget, on a
    /// WRITE path — and the detector runs after the AppleScript write, so a hang would leave the
    /// note created while the command appeared dead, inviting an agent retry to duplicate it.
    /// The oracle's engine backtracks the same way, but matching a hang is not parity worth
    /// having, and this repo already treats the `[^>]*` shape as a defect class (COMPLETION-LOOP
    /// Q25; this site is linear at birth and does not join that census).
    ///
    /// EQUIVALENCE. The regex matches iff some `<input` (ASCII boundary after) is followed, with
    /// no `>` in between, by `type\s*=\s*["']checkbox["']` — and neither the gap (`[^>]*`) nor
    /// the tail can contain `>`. So split at `>` (a plain UTF-16 unit scan; `>` cannot occur
    /// inside a surrogate pair) and, inside each `>`-free segment, find the FIRST `<input`, then
    /// the tail anywhere after it. The first `<input` suffices: any tail position that works for
    /// a later `<input` in the segment also works for an earlier one. Each segment is scanned a
    /// bounded number of times, so the whole scan is linear; red-proofed by the perf test in
    /// `ChecklistWarningTests`.
    private static let htmlInputOpen = try! NSRegularExpression(
        pattern: "<[iI][nN][pP][uU][tT](?![\(jsWord)])")
    private static let htmlCheckboxTail = try! NSRegularExpression(
        pattern: "(?<![\(jsWord)])[tT][yY][pP][eE][\(jsSpace)]*=[\(jsSpace)]*[\"'][cC][hH][eE][cC][kK][bB][oO][xX][\"']")

    private static func htmlCheckboxAttempt(_ content: String) -> Bool {
        let ns = content as NSString
        let n = ns.length
        var segStart = 0
        while segStart < n {
            var segEnd = segStart
            while segEnd < n, ns.character(at: segEnd) != 0x3E { segEnd += 1 }   // 0x3E = ">"
            if let open = htmlInputOpen.firstMatch(
                in: content, range: NSRange(location: segStart, length: segEnd - segStart)) {
                let afterOpen = open.range.location + open.range.length
                // Transparent bounds so the tail's lookbehind sees the character before the
                // sub-range (guaranteed non-word by the open's lookahead — same verdict either
                // way, but the transparent form is what JS actually evaluates).
                if htmlCheckboxTail.firstMatch(
                    in: content, options: .withTransparentBounds,
                    range: NSRange(location: afterOpen, length: segEnd - afterOpen)) != nil {
                    return true
                }
            }
            segStart = segEnd + 1
        }
        return false
    }

    /// The `create` response, with the checklist warning applied to BOTH the JSON field and the
    /// human line.
    ///
    /// THIS EXISTS TO BE TESTABLE. The three wired sites used to build their result inline, which
    /// put the wiring — detector → `warning:` field → human suffix — behind an AppleScript call and
    /// so out of reach of every tier but live. The surviving mutant a reviewer named was exactly
    /// that: compute the warning correctly, emit `warning: nil`, and nothing notices. Building the
    /// response here puts that mutant inside a unit-tested function instead.
    static func createResponse(id: String, title: String, folder: String?, account: String?,
                               content: String) -> (note: CreatedNote, human: String) {
        let warning = detectChecklistAttempt(content)
        return (CreatedNote(ok: true, id: id, title: title, folder: folder, account: account,
                            warning: warning),
                "Created \"\(title)\" [\(id)].\(warning ?? "")")
    }

    /// The `update` response — see `createResponse`. `id` is nil on the by-title branch, matching
    /// the oracle. `title` is the already-resolved display title (`resolveUpdateResponseTitle`),
    /// and the warning is computed from the REPLACEMENT body, never the note's existing text.
    static func updateResponse(id: String?, title: String, shared: Bool,
                               newContent: String) -> (note: UpdatedNote, human: String) {
        let warning = detectChecklistAttempt(newContent)
        return (UpdatedNote(ok: true, id: id, title: title, shared: shared, warning: warning),
                "Updated \"\(title)\".\(warning ?? "")")
    }

    /// Pragmatic HTML→Markdown for Apple Notes' constrained HTML. Covers the elements Notes emits:
    /// headings, div/p blocks, `<br>`, ul/ol lists, bold/italic, and links. Inline conversions run
    /// before block conversions so their markdown survives the final tag-strip.
    ///
    /// **Lists are handled structurally by `NotesLists`, not by regex** — see that file for the
    /// transcribed turndown rules and for what the old `<li\b[^>]*>(.*?)</li>` spelling corrupted.
    /// Everything else is still the regex pipeline, so this is NOT yet byte-identical to the
    /// oracle's turndown across all constructs; NOTES-L1 tracks the remaining fidelity gaps.
    static func htmlToMarkdown(_ html: String) throws -> String {
        var pre = html
        pre = regexReplace(pre, "<!--.*?-->", "", dotMatchesLineSeparators: true)
        pre = regexReplace(pre, "<(head|style|script)\\b[^>]*>.*?</\\1>", "", caseInsensitive: true, dotMatchesLineSeparators: true)

        // Split lists out FIRST. Their rendered markdown carries significant leading indentation,
        // which the per-line trim at the end of the non-list pipeline would destroy, so list output
        // never passes through it.
        var out = ""
        for segment in try NotesLists.segments(pre) {
            switch segment {
            case .html(let raw):
                out += nonListToMarkdown(raw)
            case .list(let list):
                out += try NotesLists.render(list, isLastChildOfItem: false, inline: { nonListToMarkdown($0) })
            }
        }

        out = regexReplace(out, "\n{3,}", "\n\n")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The non-list half of the pipeline: inline markup, `<br>`, headings, block separators, tag
    /// strip, entity decode, per-line trim. Runs on document text and on each list item's content.
    private static func nonListToMarkdown(_ html: String) -> String {
        var s = html

        // Inline (wrap with markdown, keep inner text).
        s = regexReplace(s, "<a\\b[^>]*\\bhref\\s*=\\s*[\"']([^\"']*)[\"'][^>]*>(.*?)</a>", "[$2]($1)",
                         caseInsensitive: true, dotMatchesLineSeparators: true)
        s = regexReplace(s, "<(b|strong)\\b[^>]*>(.*?)</\\1>", "**$2**", caseInsensitive: true, dotMatchesLineSeparators: true)
        s = regexReplace(s, "<(i|em)\\b[^>]*>(.*?)</\\1>", "*$2*", caseInsensitive: true, dotMatchesLineSeparators: true)

        // Line breaks.
        s = regexReplace(s, "<br\\s*/?>", "\n", caseInsensitive: true)

        // Headings (atx). Level from the tag; inner text kept (may already carry inline md).
        for level in 1...6 {
            let hashes = String(repeating: "#", count: level)
            s = regexReplace(s, "<h\(level)\\b[^>]*>(.*?)</h\(level)>", "\n\(hashes) $1\n",
                             caseInsensitive: true, dotMatchesLineSeparators: true)
        }

        // Block separators.
        s = regexReplace(s, "</(div|p)>", "\n", caseInsensitive: true)
        s = regexReplace(s, "<(div|p)\\b[^>]*>", "", caseInsensitive: true)

        // Strip whatever tags remain.
        s = stripTags(s)

        // Decode entities.
        s = decodeEntities(s)

        // Whitespace: trim each line.
        return s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    // MARK: update-note response title (NOTES-M6, oracle 2.6.12)

    /// Oracle `decodeHtmlEntities` (index.js:41844). Deliberately SEPARATE from `decodeEntities`
    /// above — and the reason is STRUCTURAL, not scheduling: the oracle itself ships two decoders.
    /// `decodeEntities` above mirrors the inline one in `htmlToPlaintext` (index.js:41394) —
    /// semicolon REQUIRED, fixed named list including `&#92;`, no optional-semicolon lookahead,
    /// `&amp;` last — which is what `get-note-markdown` must keep. Unifying the two would be a
    /// parity REGRESSION on the markdown/plaintext path, so two decoders is fidelity, not
    /// duplication.
    ///
    /// Measured differences between the two (both verified against the real 2.6.12 oracle):
    /// `decodeEntities` requires the trailing semicolon (`a&nbsp b` → oracle `"a  b"`, ours
    /// unchanged); it makes ONE interleaved left-to-right pass where this one makes two sequential
    /// whole-string passes (`&#x26;#65;` → oracle `"A"`, `decodeEntities` `"&#65;"`); and its
    /// numeric class is `[0-9a-fA-F]` for BOTH radixes, so `&#1F;` fails `UInt32(radix: 10)` and
    /// survives verbatim where the oracle yields U+0001 + `"F;"`. Surrogate/range handling is NOT
    /// a difference — `Unicode.Scalar(cp)` already returns nil and the match is kept. The
    /// `decodeEntities` deltas are `get-note-markdown`'s to fix under NOTES-L1.
    ///
    /// Faithful points: the semicolon is OPTIONAL when the entity is not followed by `[0-9a-z]`;
    /// hex runs BEFORE decimal; `&amp` runs LAST so `&amp;lt;` decodes once to `&lt;`; and a code
    /// point that is a surrogate (U+D800–U+DFFF) or above U+10FFFF is left VERBATIM.
    static func decodeHtmlEntitiesOracle(_ text: String) -> String {
        func decodeCodePoint(_ match: String, _ value: String, _ radix: Int) -> String {
            guard let cp = UInt32(value, radix: radix), cp <= 0x10FFFF,
                  !(0xD800...0xDFFF).contains(cp), let scalar = Unicode.Scalar(cp) else { return match }
            return String(scalar)
        }
        var s = text
        s = regexReplaceFunc2(s, "&#x([0-9a-f]+);?", caseInsensitive: true) { m, g in
            decodeCodePoint(m, g[0], 16)
        }
        s = regexReplaceFunc2(s, "&#([0-9]+);?", caseInsensitive: false) { m, g in
            decodeCodePoint(m, g[0], 10)
        }
        // The NAME is matched case-insensitively but the lookahead is spelled with both cases
        // under a case-SENSITIVE pattern: ICU full case folding makes `[0-9a-z]` match U+212A
        // (Kelvin) and U+017F (long s), which JS `/i` without `u` refuses to fold onto ASCII.
        for (name, repl) in [("nbsp", " "), ("quot", "\""), ("apos", "'"),
                             ("lt", "<"), ("gt", ">"), ("amp", "&")] {
            let anyCase = name.map { "[\($0.lowercased())\($0.uppercased())]" }.joined()
            s = regexReplace(s, "&\(anyCase)(?:;|(?![0-9A-Za-z]))", repl)
        }
        return s
    }

    /// Oracle `firstVisibleHtmlLine` (index.js:41854). Returns nil when nothing renders.
    ///
    /// The script/style strip runs to a FIXED POINT, exactly as the oracle does — a single pass
    /// would leave `<scr<script>X</script>ipt>`-style splices behind. The TAG strip does not need
    /// a loop (see `stripTags`). `<br>` and block-closing tags become newlines BEFORE tags are
    /// stripped, which is what makes "first line" mean the first rendered line, not the first tag.
    static func firstVisibleHtmlLine(_ html: String) -> String? {
        // JS `\s` — spelled out because ICU's `\s` is NOT the same set (see below). Bound here
        // rather than at the collapse site because `<br>` needs the SAME class: the oracle's
        // BREAK_RE is `/<br\s*\/?\s*>/gi`, so its whitespace is ECMAScript's, not ICU's.
        let jsSpace = "\t\n\u{0b}\u{0c}\r \u{a0}\u{1680}\u{2000}-\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}"

        var text = stripNonRenderedBlocks(html)
        // `[\(jsSpace)]` not `\s`: JS `\s` includes U+FEFF and EXCLUDES U+0085, ICU's does the
        // opposite on BOTH. Getting this wrong here either merges two rendered lines into one
        // title (`<br` + U+FEFF + `>`) or invents a break and truncates it (`<br` + U+0085 + `>`).
        // POSSESSIVE (`*+`), not greedy. Two adjacent unbounded quantifiers around an
        // optional element is the classic polynomial-backtracking shape: on `<br` + a long
        // whitespace run that never reaches `>`, the first run gives back one position at a
        // time and the second re-scans from each. Measured 0.018 / 0.070 / 0.282 s at 2 / 4 /
        // 8 KiB (4x per doubling) and it can exhaust the stack outright at larger sizes.
        // This is MY regression, introduced by the round-3 `\s` fix in this very line, while
        // the file's two OTHER `<br` sites kept the single-quantifier form and stayed linear.
        // Possessive is safe here because `[jsSpace]`, `/` and `>` are pairwise disjoint, so
        // no backtrack into either run can expose a match the greedy form would have found —
        // verified over an exhaustive 4-token sweep, 14,641 inputs, 0 divergences.
        text = regexReplace(text, "<br[\(jsSpace)]*+/?[\(jsSpace)]*+>", "\n", caseInsensitive: true)
        text = regexReplace(text, "</(?:div|h[1-6]|p|li)>", "\n", caseInsensitive: true)
        text = stripTags(text)   // linear equivalent of the oracle's `<[^>]*>` fixed point
        let decoded = decodeHtmlEntitiesOracle(text)
        // Oracle splits on /[\r\n\u2028\u2029]+/, collapses internal whitespace, trims, and
        // takes the first TRUTHY line — i.e. the first non-empty one, not simply line 0.
        let jsSpaceSet = CharacterSet(charactersIn: "\t\n\u{0b}\u{0c}\r \u{a0}\u{1680}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}")
            .union(CharacterSet(charactersIn: Unicode.Scalar(0x2000)!...Unicode.Scalar(0x200a)!))
        // Splitting per-character rather than on runs is SAFE and deliberate: JS splits on maximal
        // runs giving P1,P2,…; this gives the same pieces with empty strings interleaved, and the
        // consumer takes the first piece non-empty after collapse+trim, so the survivor is identical.
        for raw in decoded.components(separatedBy: CharacterSet(charactersIn: "\r\n\u{2028}\u{2029}")) {
            let line = regexReplace(raw, "[\(jsSpace)]+", " ")
                .trimmingCharacters(in: jsSpaceSet)
            if !line.isEmpty { return line }
        }
        return nil
    }

    /// Oracle `resolveUpdateResponseTitle` (index.js:41868). In HTML format the response title is
    /// DERIVED from the new body and `newTitle` is ignored entirely — the port previously returned
    /// `newTitle ?? current` unconditionally, so an html update reported a title Notes would not
    /// show. Plaintext keeps JS truthiness: an EMPTY newTitle falls back to the current one.
    static func resolveUpdateResponseTitle(current: String, newTitle: String?,
                                           html: Bool, newContent: String) -> String {
        if html { return firstVisibleHtmlLine(newContent) ?? current }
        if let newTitle, !newTitle.isEmpty { return newTitle }
        return current
    }

    static func decodeEntities(_ input: String) -> String {
        var s = input
        let named: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&#92;", "\\"),
        ]
        for (e, r) in named { s = s.replacingOccurrences(of: e, with: r) }
        // Numeric decimal/hex entities.
        s = regexReplaceFunc(s, "&#(x?)([0-9a-fA-F]+);") { groups in
            let isHex = !groups[1].isEmpty
            guard let code = UInt32(groups[2], radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) else {
                return nil
            }
            return String(scalar)
        }
        s = s.replacingOccurrences(of: "&amp;", with: "&") // last, so "&amp;lt;" → "&lt;"
        return s
    }

    /// Annotate markdown list items with `[x]`/`[ ]` from checklist done-state (port of
    /// `enrichMarkdownWithChecklists`). Each checklist item is consumed once (map delete).
    static func enrichMarkdownWithChecklists(_ markdown: String, items: [NotesStore.ChecklistItem]) -> String {
        if items.isEmpty { return markdown }
        var map: [String: Bool] = [:]
        for item in items { map[item.text.trimmingCharacters(in: .whitespaces)] = item.done }
        guard let re = try? NSRegularExpression(pattern: "^(\\s*[-*])\\s+(.+)$") else { return markdown }
        let out = markdown.components(separatedBy: "\n").map { line -> String in
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return line }
            let prefix = ns.substring(with: m.range(at: 1))
            let text = ns.substring(with: m.range(at: 2))
            let key = text.trimmingCharacters(in: .whitespaces)
            guard let done = map[key] else { return line }
            map.removeValue(forKey: key)
            return "\(prefix) \(done ? "[x]" : "[ ]") \(text)"
        }
        return out.joined(separator: "\n")
    }

    /// Linear-time equivalent of a global `<[^>]*>` replace-with-empty.
    ///
    /// The regex form is O(N²): the engine tries a match at EVERY `<`, and each attempt scans
    /// `[^>]*` to end-of-input before failing, so a body of unmatched `<` costs quadratic time —
    /// measured on this machine at 0.41 s / 1.64 s / 6.54 s for 10k / 20k / 40k characters (4×
    /// per doubling), i.e. ~1 s at 15 KB and ~60 s at 121 KB. The oracle's JS engine has the same
    /// asymptotic shape but a ~10× smaller constant; parity is about behaviour, not about
    /// inheriting a pathological constant, and this scanner is behaviourally identical.
    ///
    /// Equivalence argument: `<[^>]*>` always matches from a `<` to the FIRST following `>`, and
    /// matches are non-overlapping and left-to-right — exactly what this scan does. When no `>`
    /// follows a `<`, no match can start at that `<` or at any later position (any later `<` would
    /// need a `>` further right, and there is none), so the remainder is copied verbatim. Both `<`
    /// and `>` are ASCII, so scalar boundaries and the regex engine's UTF-16 boundaries coincide;
    /// no surrogate pair can be split. A single global pass is already a fixed point: a `<` in the
    /// gap BEFORE a match would itself have matched to that same `>` and been chosen first (the
    /// regex is leftmost-first and non-overlapping), so every surviving `<` lies in the final
    /// tail with no `>` after it, and concatenation cannot manufacture a tag. Confirmed
    /// empirically by the differential in `StripTagsEquivalenceTests`, which compares against
    /// the regex run to a FIXED POINT and finds no input where one pass differs.
    /// `replacement` is what each matched tag becomes. `nil` drops it (the `<[^>]*>` → `""`
    /// form); a scalar substitutes it (the `<[^>]*>` → `" "` form used for hashtag extraction,
    /// where joining words across a tag boundary would invent hashtags that are not there).
    static func stripTags(_ s: String, replacement: Unicode.Scalar? = nil) -> String {
        let src = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(src.count)
        var i = 0
        while i < src.count {
            guard src[i] == "<" else { out.append(src[i]); i += 1; continue }
            var j = i + 1
            while j < src.count && src[j] != ">" { j += 1 }
            if j < src.count {                                   // `<…>` → drop or substitute
                if let replacement { out.append(replacement) }
                i = j + 1
                continue
            }
            while i < src.count { out.append(src[i]); i += 1 }   // no `>` left: nothing can match
        }
        return String(out)
    }

    /// Linear-time equivalent of the oracle's NON_RENDERED_BLOCK_RE fixed point
    /// (`/<(script|style)\b[^>]*>[\s\S]*?(?:<\/\1>|$)/gi`, index.js:41843 + :41859).
    ///
    /// This is a SCANNER rather than a regex because `NSRegularExpression` cannot express the
    /// oracle's semantics — three separate ICU-vs-JS divergences meet in that one pattern:
    ///
    /// 1. `.caseInsensitive` applies ICU FULL case folding, which maps U+017F (ſ) onto `s` and
    ///    U+212A (K) onto `k`. That makes `<ſcript>` match `(script|style)`, makes `</ſcript>`
    ///    close an ASCII `<script>` via the backreference, and widens the ASCII-only
    ///    `(?![A-Za-z0-9_])` boundary so `<script` + U+212A + `>` stops being recognised. JS `/i`
    ///    without `u` canonicalises via `toUpperCase`, and neither scalar upcases to ASCII, so JS
    ///    folds ASCII only. Spelling the names case-sensitively is NOT a fix either — the three
    ///    cases SQUEEZE any single option set, which is why this is a scanner and not a regex:
    ///
    ///        input                      oracle    ICU .caseInsensitive   ICU case-sensitive
    ///        <script>x</ſcript>AFTER    ""        "AFTER"  WRONG         ""       right
    ///        <SCRIPT>x</script>AFTER    "AFTER"   "AFTER"  right         unchanged WRONG
    ///        <script>x</SCRIPT>AFTER    "AFTER"   "AFTER"  right         ""       WRONG
    ///
    ///    Row 1 demands case-sensitive; rows 2-3 demand case-insensitive. No `NSRegularExpression`
    ///    option set satisfies all three, because JS's backreference is ASCII-case-insensitive
    ///    while ICU's folding is full. The patched regex still diverged on ~26% of a reviewer's
    ///    corpus; this scanner diverges on 0%.
    /// 2. ICU `$` matches at end-of-input OR before a final line terminator, whatever
    ///    `anchorsMatchLines` says; JS `$` without `m` matches only at absolute end. `\z` is the
    ///    correct ICU spelling (see `regexReplace`).
    /// 3. `[^>]*` attempted at every `<` is O(N²) — the same shape `stripTags` exists to avoid.
    ///
    /// Verified against the oracle's own regex over 60,028 generated bodies whose alphabet
    /// deliberately reaches U+017F, U+212A, U+0085, trailing line terminators, mixed-case tags and
    /// splice fragments: 0 divergences, where the regex form diverges on 11,170 of the same
    /// inputs. Three independent reviewers reproduced this over a further ~430,000 inputs
    /// (random, exhaustive-by-depth, and full-scalar case-folding sweeps) with 0 divergences.
    ///
    /// The fixed-point loop terminates: a pass sets `changed` only after advancing `i` past a span
    /// it does not append, so a changed pass strictly shrinks the array — at most N passes. Note
    /// the pass count IS an O(N) multiplier on deeply left-nested splices — a re-forming chain
    /// (`Lk = "<sty" + L(k-1) + "le></style>"`) needs one pass per level and each pass copies the
    /// whole array. The oracle runs ITS regex to a fixed point too, so the shape is inherited
    /// rather than introduced — but do not read that as "no worse than the oracle": measured
    /// against the live oracle on byte-identical payloads this port is ~45x slower on that shape
    /// (46 s vs ~35 min extrapolated at ARG_MAX), so an oracle annoyance is a port hang. Tracked
    /// in the queue, NOT fixed here. An earlier version of this comment claimed "the regex form is
    /// slower still on the identical payload"; that was FALSE — review measured the regex form
    /// 3.4x FASTER on the re-forming chain (0.069 / 0.428 / 2.259 s vs 0.137 / 1.247 / 7.775 s at
    /// 14 / 36 / 90 KiB). The scanner's win is on the unclosed-tag shapes, not this one.
    static func stripNonRenderedBlocks(_ s: String) -> String {
        let names: [[Unicode.Scalar]] = [Array("script".unicodeScalars), Array("style".unicodeScalars)]

        /// ASCII-only case-insensitive compare against a lowercase ASCII `name`.
        func asciiCaseMatches(_ src: [Unicode.Scalar], _ from: Int, _ name: [Unicode.Scalar]) -> Bool {
            if from + name.count > src.count { return false }
            for k in 0..<name.count {
                var c = src[from + k].value
                if c >= 65 && c <= 90 { c += 32 }
                if c != name[k].value { return false }
            }
            return true
        }
        func isAsciiWord(_ s: Unicode.Scalar) -> Bool {
            let v = s.value
            return (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v == 95
        }

        func onePass(_ src: [Unicode.Scalar]) -> (out: [Unicode.Scalar], changed: Bool) {
            var out: [Unicode.Scalar] = []
            out.reserveCapacity(src.count)
            let n = src.count
            var i = 0, changed = false
            outer: while i < n {
                if src[i] == "<" {
                    for name in names {
                        guard asciiCaseMatches(src, i + 1, name) else { continue }
                        let afterName = i + 1 + name.count
                        // JS `\b`: the scalar after the name must not be an ASCII word scalar.
                        if afterName < n && isAsciiWord(src[afterName]) { continue }
                        var j = afterName                       // `[^>]*>`
                        while j < n && src[j] != ">" { j += 1 }
                        if j == n {
                            // No `>` at or after `afterName`, and `[i, afterName)` is `<` plus the
                            // literal tag name (letters only), so there is no `>` at or after `i`
                            // AT ALL. A match starting at any p >= i needs a `>` strictly right of
                            // p, so none can start here OR LATER: copy the tail and stop.
                            //
                            // `continue` here instead re-scans to end-of-input at every subsequent
                            // `<script`, which is the very O(N^2) this scanner exists to remove —
                            // measured 0.036/0.142/0.564/2.252 s at 43k/87k/175k/350k scalars, a
                            // clean 4x per doubling. `stripTags` already derived this same fact and
                            // acted on it; this function derived it and threw it away. Carrying an
                            // invariant across siblings is the whole lesson of this file.
                            while i < n { out.append(src[i]); i += 1 }
                            break outer
                        }
                        // Lazy `[\s\S]*?(?:</name>|$)` — earliest literal `</name>`, else end.
                        var k = j + 1, end = n
                        while k < n {
                            if src[k] == "<", k + 1 < n, src[k + 1] == "/",
                               asciiCaseMatches(src, k + 2, name),
                               k + 2 + name.count < n, src[k + 2 + name.count] == ">" {
                                end = k + 3 + name.count
                                break
                            }
                            k += 1
                        }
                        i = end
                        changed = true
                        continue outer
                    }
                }
                out.append(src[i])
                i += 1
            }
            return (out, changed)
        }

        // The fixed point IS load-bearing here (unlike `stripTags`): removing an inner block can
        // splice its neighbours into a NEW tag, e.g. `<scr<script>X</script>ipt>SECRET</script>`.
        var src = Array(s.unicodeScalars)
        while true {
            let (out, changed) = onePass(src)
            if !changed { break }
            src = out
        }
        var view = String.UnicodeScalarView()
        view.reserveCapacity(src.count)
        for c in src { view.append(c) }
        return String(view)
    }

    // MARK: regex helpers

    /// `anchorsMatchLines` defaults to true for the markdown callers that want `^`/`$` per line.
    ///
    /// PORTING A JS REGEX: `anchorsMatchLines: false` is NECESSARY BUT NOT SUFFICIENT to reproduce
    /// a non-multiline JS `$`. ICU (Java semantics) matches `$` at end-of-input OR immediately
    /// before a FINAL line terminator — U+000A, U+000B, U+000C, U+000D, U+0085, U+2028, U+2029 —
    /// no matter how this flag is set. JS `$` without `m` matches at absolute end only. The exact
    /// ICU spellings of JS's non-multiline anchors are `\z` (for `$`) and `\A` (for `^`); use
    /// those, not `$`/`^`, or a lazy `[\s\S]*?…(?:X|\z)` stops one scalar early on a trailing NEL.
    /// This bit us for real: `firstVisibleHtmlLine` reported a bare U+0085 as a note's title.
    static func regexReplace(_ input: String, _ pattern: String, _ template: String,
                             caseInsensitive: Bool = false, dotMatchesLineSeparators: Bool = false,
                             anchorsMatchLines: Bool = true) -> String {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        if dotMatchesLineSeparators { options.insert(.dotMatchesLineSeparators) }
        // Default anchors match at line boundaries for `^`/`$` usage in enrichment.
        if anchorsMatchLines { options.insert(.anchorsMatchLines) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return input }
        let ns = input as NSString
        return re.stringByReplacingMatches(in: input, range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }

    /// Regex replace with a Swift closure computing each replacement (for numeric entities).
    /// Like `regexReplaceFunc` but hands the transform the FULL match too, which the oracle's
    /// `decodeCodePoint` needs in order to return the original text verbatim when it rejects.
    /// CONTRACT: `pattern` must have at least one capture group, and callers index `g` by
    /// GROUP ORDER (`g[0]` = group 1). A non-participating group yields `""` rather than shifting
    /// the indices, but a zero-group pattern makes `g[0]` trap. NOTE the sibling
    /// `regexReplaceFunc` below uses the OPPOSITE convention — it passes `0..<numberOfRanges`, so
    /// its `groups[0]` is the WHOLE match. Check which helper you are calling before indexing.
    static func regexReplaceFunc2(_ input: String, _ pattern: String, caseInsensitive: Bool,
                                  _ transform: (String, [String]) -> String) -> String {
        let opts: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return input }
        let ns = input as NSString
        var out = "", last = 0
        for m in re.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var groups: [String] = []
            // Append "" for a non-participating group rather than skipping it — skipping shifts
            // every later group down, which `regexReplaceFunc` below already gets right.
            for i in 1..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            out += transform(ns.substring(with: m.range), groups)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func regexReplaceFunc(_ input: String, _ pattern: String, _ transform: ([String]) -> String?) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return input }
        let ns = input as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var groups: [String] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result += transform(groups) ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
