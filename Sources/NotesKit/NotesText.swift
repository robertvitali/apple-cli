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
        s = regexReplace(s, "<[^>]*>", " ")
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
        var prev: String
        repeat { prev = text; text = regexReplace(text, "<[^>]*>", "") } while text != prev
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

    /// Pragmatic HTML→Markdown for Apple Notes' constrained HTML. Not byte-identical to the
    /// reference's `turndown` (a full DOM→md engine), but covers the elements Notes emits:
    /// headings, div/p blocks, `<br>`, ul/ol lists (as `-` so checklist enrichment can match),
    /// bold/italic, and links. Inline conversions run before block conversions so their
    /// markdown survives the final tag-strip.
    static func htmlToMarkdown(_ html: String) -> String {
        var s = html
        s = regexReplace(s, "<!--.*?-->", "", dotMatchesLineSeparators: true)
        s = regexReplace(s, "<(head|style|script)\\b[^>]*>.*?</\\1>", "", caseInsensitive: true, dotMatchesLineSeparators: true)

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

        // List items → `- inner` (both ul and ol render `-` so checklist enrichment matches).
        s = regexReplace(s, "<li\\b[^>]*>(.*?)</li>", "\n- $1", caseInsensitive: true, dotMatchesLineSeparators: true)
        s = regexReplace(s, "</?(ul|ol)\\b[^>]*>", "\n", caseInsensitive: true)

        // Block separators.
        s = regexReplace(s, "</(div|p)>", "\n", caseInsensitive: true)
        s = regexReplace(s, "<(div|p)\\b[^>]*>", "", caseInsensitive: true)

        // Strip whatever tags remain.
        s = regexReplace(s, "<[^>]*>", "")

        // Decode entities.
        s = decodeEntities(s)

        // Whitespace: trim each line, collapse blank runs.
        let lines = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        s = lines.joined(separator: "\n")
        s = regexReplace(s, "\n{3,}", "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: regex helpers

    static func regexReplace(_ input: String, _ pattern: String, _ template: String,
                             caseInsensitive: Bool = false, dotMatchesLineSeparators: Bool = false) -> String {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        if dotMatchesLineSeparators { options.insert(.dotMatchesLineSeparators) }
        // Default anchors match at line boundaries for `^`/`$` usage in enrichment.
        options.insert(.anchorsMatchLines)
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return input }
        let ns = input as NSString
        return re.stringByReplacingMatches(in: input, range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }

    /// Regex replace with a Swift closure computing each replacement (for numeric entities).
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
