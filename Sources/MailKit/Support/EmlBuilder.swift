import Foundation

/// Generates a multipart RFC-5322 / MIME `.eml` message. Used for reliable HTML sending +
/// rich drafts: Mail.app renders `.eml` content correctly, whereas setting raw HTML through
/// AppleScript stores literal markup (MCP B's documented workaround).
///
/// Pure string generation (no I/O, no Mail.app) — fully unit-testable. The caller writes the
/// result to disk and/or opens it in Mail behind the `--execute`/test-mode guards.
public struct EmlBuilder {
    public struct Attachment { public let filename: String; public let mimeType: String; public let data: Data
        public init(filename: String, mimeType: String, data: Data) { self.filename = filename; self.mimeType = mimeType; self.data = data } }

    public var from: String?
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    public var textBody: String?
    public var htmlBody: String?
    public var attachments: [Attachment]
    public var date: Date
    public var messageID: String
    /// Emit a `Bcc:` header. SAFE ONLY for an `.eml` that will be OPENED in a Mail compose window
    /// (Mail populates the bcc field from it and strips the header on send) — NEVER for an `.eml`
    /// delivered on the wire, where a `Bcc:` header leaks the blind-copy list to every recipient.
    /// Defaults false (safe); the open paths set it true so `--bcc` reaches the compose window.
    public var emitBcc: Bool

    public init(from: String? = nil, to: [String] = [], cc: [String] = [], bcc: [String] = [],
                subject: String = "", textBody: String? = nil, htmlBody: String? = nil,
                attachments: [Attachment] = [], date: Date = Date(), messageID: String? = nil,
                emitBcc: Bool = false) {
        self.from = from; self.to = to; self.cc = cc; self.bcc = bcc; self.subject = subject
        self.textBody = textBody; self.htmlBody = htmlBody; self.attachments = attachments; self.date = date
        self.messageID = messageID ?? "<\(UUID().uuidString)@apple-cli.local>"
        self.emitBcc = emitBcc
    }

    /// RFC-2822 date, e.g. "Tue, 02 Jan 2026 16:00:45 +0000".
    static func rfc2822Date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }

    public enum EmlError: Error, CustomStringConvertible {
        case headerInjection(String)
        public var description: String {
            switch self { case .headerInjection: return "header value contains a CR/LF/NUL control character (injection attempt)" }
        }
    }

    /// Reject CR/LF/NUL in any header value — email header injection (CWE-93): a subject or
    /// recipient containing `\r\n` would otherwise smuggle extra headers (Bcc exfil, From spoof)
    /// into the generated `.eml`. No legitimate address/subject contains these bytes. Checks
    /// Unicode SCALARS, not Characters: Swift folds a "\r\n" pair into ONE grapheme cluster, so
    /// a per-Character `== "\r"` check would miss the combined sequence.
    static func sanitizeHeader(_ value: String) throws -> String {
        guard !value.unicodeScalars.contains(where: { $0.value == 0x0D || $0.value == 0x0A || $0.value == 0x00 }) else {
            throw EmlError.headerInjection(value)
        }
        return value
    }

    /// Encode a header value: reject control chars, then RFC-2047 Base64-encode when non-ASCII
    /// is present, else pass the (sanitized) value through.
    static func encodeHeader(_ value: String) throws -> String {
        let v = try sanitizeHeader(value)
        if v.allSatisfy({ $0.isASCII }) { return v }
        return "=?UTF-8?B?\(Data(v.utf8).base64EncodedString())?="
    }

    /// Best-effort MIME type from a filename extension (falls back to octet-stream).
    public static func mimeType(forFilename name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        let map: [String: String] = [
            "pdf": "application/pdf", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
            "gif": "image/gif", "txt": "text/plain", "html": "text/html", "htm": "text/html",
            "csv": "text/csv", "json": "application/json", "zip": "application/zip",
            "doc": "application/msword", "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "xls": "application/vnd.ms-excel", "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "ppt": "application/vnd.ms-powerpoint", "svg": "image/svg+xml", "ics": "text/calendar",
        ]
        return map[ext] ?? "application/octet-stream"
    }

    static func base64Lines(_ data: Data) -> String {
        let b64 = data.base64EncodedString()
        var out = ""
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: 76, limitedBy: b64.endIndex) ?? b64.endIndex
            out += b64[idx..<end] + "\r\n"
            idx = end
        }
        return out
    }

    public func build() throws -> String {
        // Sanitize every header value against CR/LF injection before interpolation.
        let fromH = try from.map { try EmlBuilder.sanitizeHeader($0) }
        let toH = try to.map { try EmlBuilder.sanitizeHeader($0) }
        let ccH = try cc.map { try EmlBuilder.sanitizeHeader($0) }
        // Always validate bcc (defense in depth). Emit a Bcc: header ONLY when emitBcc is set —
        // safe solely for a compose-window `.eml` (Mail moves it to the bcc field + strips it on
        // send). For a wire-sent `.eml` a Bcc header would leak the blind-copy list, so the default
        // (emitBcc=false) omits it; bcc is then an envelope concern for the AppleScript send API.
        let bccH = try bcc.map { try EmlBuilder.sanitizeHeader($0) }
        var headers: [String] = []
        if let fromH { headers.append("From: \(fromH)") }
        if !toH.isEmpty { headers.append("To: \(toH.joined(separator: ", "))") }
        if !ccH.isEmpty { headers.append("Cc: \(ccH.joined(separator: ", "))") }
        if emitBcc && !bccH.isEmpty { headers.append("Bcc: \(bccH.joined(separator: ", "))") }
        headers.append("Subject: \(try EmlBuilder.encodeHeader(subject))")
        headers.append("Date: \(EmlBuilder.rfc2822Date(date))")
        headers.append("Message-ID: \(messageID)")
        headers.append("MIME-Version: 1.0")
        // X-Unsent:1 marks the message as an editable OUTGOING draft, so opening the .eml in
        // Mail (`open`) yields a compose window / outgoing message the send path can then deliver,
        // rather than a read-only received-message viewer. Matches the parity oracle
        // (patrickfreyer apple-mail-mcp `create_rich_email_draft`, which always sets X-Unsent:1).
        headers.append("X-Unsent: 1")

        let text = textBody ?? htmlBody.map { EmlBuilder.stripHTML($0) } ?? ""
        let boundaryAlt = "alt-\(UUID().uuidString)"
        let boundaryMixed = "mixed-\(UUID().uuidString)"

        func bodyPartAlternative() -> String {
            if let htmlBody {
                var s = "Content-Type: multipart/alternative; boundary=\"\(boundaryAlt)\"\r\n\r\n"
                s += "--\(boundaryAlt)\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n\(text)\r\n"
                s += "--\(boundaryAlt)\r\nContent-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n\(htmlBody)\r\n"
                s += "--\(boundaryAlt)--\r\n"
                return s
            } else {
                return "Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n\(text)\r\n"
            }
        }

        var out = headers.joined(separator: "\r\n") + "\r\n"
        if attachments.isEmpty {
            out += bodyPartAlternative()
        } else {
            out += "Content-Type: multipart/mixed; boundary=\"\(boundaryMixed)\"\r\n\r\n"
            out += "--\(boundaryMixed)\r\n" + bodyPartAlternative()
            for att in attachments {
                // Sanitize + strip quotes so filename can't break out of the quoted-string or
                // inject a header line.
                let fname = try EmlBuilder.sanitizeHeader(att.filename).replacingOccurrences(of: "\"", with: "")
                let mime = try EmlBuilder.sanitizeHeader(att.mimeType)
                out += "--\(boundaryMixed)\r\n"
                out += "Content-Type: \(mime); name=\"\(fname)\"\r\n"
                out += "Content-Transfer-Encoding: base64\r\n"
                out += "Content-Disposition: attachment; filename=\"\(fname)\"\r\n\r\n"
                out += EmlBuilder.base64Lines(att.data)
            }
            out += "--\(boundaryMixed)--\r\n"
        }
        return out
    }

    /// Escape the HTML metacharacters so plain text (e.g. a quoted original in a reply) can be
    /// embedded into an HTML body WITHOUT injecting markup. Pure — unit-tested.
    public static func escapeHTML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Very small HTML→text fallback for the plain alternative part.
    static func stripHTML(_ html: String) -> String {
        var s = html
        for (tag, repl) in [("<br>", "\n"), ("<br/>", "\n"), ("<br />", "\n"), ("</p>", "\n\n"), ("</div>", "\n")] {
            s = s.replacingOccurrences(of: tag, with: repl, options: .caseInsensitive)
        }
        // Strip remaining tags.
        var out = ""; var inTag = false
        for ch in s {
            if ch == "<" { inTag = true } else if ch == ">" { inTag = false } else if !inTag { out.append(ch) }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
