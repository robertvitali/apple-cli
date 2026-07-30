import Foundation
import AppleKit

/// File-backed email templates at the SAME location MCP A uses —
/// `~/.apple_mail_mcp/templates/<name>.md` (override with `APPLE_MAIL_MCP_HOME`) — so the two
/// share a store. Both subject and body may contain `{placeholder}` tokens filled by `render`.
///
/// ON-DISK FORMAT — byte-matched to MCP A's `save_template` OPERATION (apple-mail-mcp
/// `server.py` + `templates.py`), so a template written by either tool is read by the other:
///   • With a subject: `subject: <s>\n\n<body>` — a lowercase `subject:` header line, a blank
///     separator line, then the body.
///   • Body-only (no subject): `\n<body>` — a LEADING blank line, then the body. The leading
///     blank is REQUIRED: MCP A splits header-from-body on the first blank line and rejects a
///     file that has none, so a body-only template still needs it to be readable by MCP A.
///   • The body is normalized to end with a newline, and an empty/whitespace-only body is
///     REFUSED — both mirror the oracle's `save_template`, whose parser rejects a bodyless file.
///     `nil` vs `""` is the real subject distinction: an empty subject still writes the header.
///
/// `parse` is a deliberate SUPERSET of the oracle's `parse_template_file`. Where the oracle
/// REJECTS a file, the CLI reads it **without losing content** rather than failing:
///   • no blank line at all → the whole text is the body;
///   • a header block that isn't entirely known `key: value` pairs (a missing colon, or an
///     unknown key) → there is no header block, so the whole text is the body.
/// The second rule is what keeps a body whose first line reads `Note: see below` from silently
/// losing that line, and keeps an unknown future header key (the oracle's `_KNOWN_HEADER_KEYS`
/// is documented as expanding) from being parsed-and-discarded. A CRLF file parses correctly and
/// its body keeps its `\r\n` bytes verbatim, exactly as the oracle returns them — only header
/// lines are `\r`-stripped.
///
/// Pure + filesystem-only (no Mail.app, no TCC) — fully unit-testable with a temp home.
public struct TemplateStore {
    public let root: URL

    /// Header keys the format recognizes — mirrors the oracle's `_KNOWN_HEADER_KEYS`.
    static let knownHeaderKeys: Set<String> = ["subject"]

    public init(homeOverride: String? = nil) {
        let base = homeOverride
            ?? ProcessInfo.processInfo.environment["APPLE_MAIL_MCP_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".apple_mail_mcp").path
        root = URL(fileURLWithPath: base).appendingPathComponent("templates")
    }

    // MARK: Models

    public struct Template: Encodable {
        public let name: String
        public let subject: String?
        public let body: String
        /// Sorted, deduped `{placeholder}` names across subject + body (oracle `get_template`).
        public let placeholders: [String]
    }
    public struct TemplateSummary: Encodable {
        public let name: String
        public let subject: String?
    }
    public struct TemplatesResult: Encodable { public let templates: [TemplateSummary]; public let count: Int }
    /// `save` result — carries the oracle's `created` flag (true = new, false = overwrote).
    public struct SaveResult: Encodable {
        public let name: String
        public let subject: String?
        public let body: String
        public let placeholders: [String]
        public let created: Bool
    }
    public struct RenderResult: Encodable {
        public let name: String
        public let subject: String?
        public let body: String
        /// The merged auto+user variables. `used_vars` is the oracle's wire key for this data;
        /// `variables` is the CLI's original name, kept so existing consumers don't break.
        public let variables: [String: String]
        public let used_vars: [String: String]
    }

    // MARK: Name validation (oracle: `^[a-zA-Z0-9_-]{1,64}$`)

    public static func validateName(_ name: String) throws {
        // ASCII-only, matching the oracle's regex exactly. A Unicode-named template would be
        // invisible to the oracle's `list_templates` and unreachable by its get/delete on the
        // SHARED store, so accepting one here would create files MCP A can never address.
        let ok = !name.isEmpty && name.count <= 64 && name.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                || $0 == "_" || $0 == "-"
        }
        guard ok else {
            throw AppleError.validation("template name must be 1–64 chars of ASCII letters, digits, '_' or '-'; got '\(name)'.")
        }
    }

    private func fileURL(_ name: String) -> URL { root.appendingPathComponent("\(name).md") }

    // MARK: CRUD

    public func list() throws -> [TemplateSummary] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return entries.filter { $0.hasSuffix(".md") }.sorted().compactMap { file in
            let name = String(file.dropLast(3))
            // Only list names the other verbs can actually address (the oracle filters by the
            // same name regex here) — otherwise `list` advertises entries `get` would reject.
            guard (try? TemplateStore.validateName(name)) != nil else { return nil }
            guard let (subject, _) = try? readParsed(name) else { return nil }
            return TemplateSummary(name: name, subject: subject)
        }
    }

    public func get(_ name: String) throws -> Template {
        try TemplateStore.validateName(name)
        guard FileManager.default.fileExists(atPath: fileURL(name).path) else {
            throw AppleError.notFound("no template named '\(name)'.")
        }
        let (subject, body) = try readParsed(name)
        return Template(name: name, subject: subject, body: body,
                        placeholders: TemplateStore.placeholders(subject: subject, body: body))
    }

    @discardableResult
    public func save(name: String, body: String, subject: String?) throws -> SaveResult {
        try TemplateStore.validateName(name)
        // Mirror the oracle's `save_template` validation: an empty/whitespace-only body is
        // REFUSED, because the oracle's parser rejects such a file outright — writing one would
        // poison the shared store with a template MCP A can never read back.
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppleError.validation("template body must be a non-empty string.")
        }
        // A CR/LF/NUL in the subject would smuggle extra lines into the on-disk header block —
        // the oracle then refuses the whole file (unknown header key), and our own re-read would
        // silently truncate the subject. Refuse at the write boundary instead.
        if let subject, subject.unicodeScalars.contains(where: {
            $0.value == 0x0A || $0.value == 0x0D || $0.value == 0x00
        }) {
            throw AppleError.validation("template subject must not contain CR, LF or NUL characters.")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let created = !FileManager.default.fileExists(atPath: fileURL(name).path)
        // Byte-identical to the oracle's save_template OPERATION (not just its serializer): the
        // body is normalized to end with a newline, and an empty-string subject still writes the
        // header line (the oracle branches on `subject is not None`, not on emptiness).
        // Test the trailing byte, NOT `hasSuffix("\n")`: Swift Characters are grapheme clusters and
        // "\r\n" is a SINGLE cluster, so a CRLF-terminated body fails `hasSuffix("\n")` and would
        // get a spurious second newline appended (silently mutating the stored content).
        let normalizedBody = body.utf8.last == 0x0A ? body : body + "\n"
        var contents = ""
        if let subject { contents += "subject: \(subject)\n" }
        contents += "\n" + normalizedBody
        try contents.write(to: fileURL(name), atomically: true, encoding: .utf8)
        // Report what was actually STORED (re-read), never the caller's raw input — otherwise the
        // emitted JSON could claim a subject/body the store does not hold.
        let stored = try get(name)
        return SaveResult(name: stored.name, subject: stored.subject, body: stored.body,
                          placeholders: stored.placeholders, created: created)
    }

    public func delete(_ name: String) throws {
        try TemplateStore.validateName(name)
        guard FileManager.default.fileExists(atPath: fileURL(name).path) else {
            throw AppleError.notFound("no template named '\(name)'.")
        }
        try FileManager.default.removeItem(at: fileURL(name))
    }

    // MARK: Parse

    private func readParsed(_ name: String) throws -> (String?, String) {
        let raw = try String(contentsOf: fileURL(name), encoding: .utf8)
        return TemplateStore.parse(raw)
    }

    /// Split a template file into (subject?, body) — see the type doc for the full contract.
    /// Total: never throws, so one malformed file can't fail a whole `list()`.
    static func parse(_ raw: String) -> (String?, String) {
        // Split on "\n" and keep each line's bytes AS-IS (a CRLF line keeps its trailing "\r"), so
        // rejoining reproduces the body byte-for-byte — the oracle's `splitlines(keepends=True)` +
        // `"".join` preserves CRLF in the body too, and only strips "\r" from HEADER lines.
        // Trimming uses .whitespacesAndNewlines (NOT .whitespaces, which excludes "\r"): without
        // that a CRLF file finds no blank line at all and loses its entire body.
        let lines = raw.components(separatedBy: "\n")
        func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // Header/body separator = the first blank line (the oracle's rule).
        guard let blankIdx = lines.firstIndex(where: isBlank) else {
            return (nil, raw)       // SUPERSET: no blank line (oracle rejects) → all body.
        }
        // A header block counts ONLY if every non-blank line in it is a known `key: value`.
        // Otherwise this file has no header block and the WHOLE text is the body — never discard
        // leading content that merely looks like it might be a header.
        var subject: String? = nil
        for line in lines[..<blankIdx] {
            if isBlank(line) { continue }
            guard let colon = line.firstIndex(of: ":") else { return (nil, raw) }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard knownHeaderKeys.contains(key) else { return (nil, raw) }
            // Empty value is meaningful: the oracle yields "" (not nil) for `subject: `.
            subject = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (subject, lines[(blankIdx + 1)...].joined(separator: "\n"))
    }

    // MARK: Placeholders + render

    /// ASCII identifier rules, matching the oracle's `[a-zA-Z_][a-zA-Z0-9_]*` placeholder regex.
    private static func isIdentStart(_ c: Character) -> Bool {
        c == "_" || ("a"..."z").contains(c) || ("A"..."Z").contains(c)
    }
    private static func isIdentChar(_ c: Character) -> Bool {
        isIdentStart(c) || ("0"..."9").contains(c)
    }

    /// If a `{identifier}` token opens at `start`, return its name and the index just past `}`.
    private static func scanToken(_ text: String, from start: String.Index) -> (String, String.Index)? {
        var j = text.index(after: start)                       // skip the '{'
        guard j < text.endIndex, isIdentStart(text[j]) else { return nil }
        var name = ""
        while j < text.endIndex, isIdentChar(text[j]) {
            name.append(text[j])
            j = text.index(after: j)
        }
        guard j < text.endIndex, text[j] == "}" else { return nil }
        return (name, text.index(after: j))
    }

    /// Sorted, deduped placeholder names across subject + body. Ports the oracle's
    /// `extract_placeholders` EXACTLY, including its order of operations: it REMOVES every `{{`
    /// and `}}` from the text first and only then scans for `{identifier}`. Stripping first (vs
    /// skipping escapes during the scan) is observably different — e.g. `{token}}` becomes
    /// `{token`, which yields NO placeholder — so the order is part of the contract, not a detail.
    public static func placeholders(subject: String?, body: String) -> [String] {
        let cleaned = ((subject ?? "") + "\n" + body)
            .replacingOccurrences(of: "{{", with: "")
            .replacingOccurrences(of: "}}", with: "")
        var found = Set<String>()
        var i = cleaned.startIndex
        while i < cleaned.endIndex {
            if cleaned[i] == "{", let (name, after) = scanToken(cleaned, from: i) {
                found.insert(name)
                i = after
                continue
            }
            i = cleaned.index(after: i)
        }
        return found.sorted()
    }

    /// Resolve `{token}` placeholders in `text` from `vars`, in a SINGLE forward pass — a
    /// substituted value is never re-scanned, so the result can't depend on dictionary iteration
    /// order (the previous repeated-`replacingOccurrences` version was nondeterministic across
    /// processes when a value happened to contain another token's text). `{{`/`}}` are literal
    /// `{`/`}`, matching Python `str.format`. A token with no matching var is left VERBATIM
    /// (a documented CLI-vs-oracle divergence: the oracle raises instead — see docs/port-specs).
    /// Substitute `{token}`s in `text`. `{{` / `}}` collapse to one literal brace. Every token
    /// with no entry in `vars` is inserted into `missing` (and left verbatim in the returned
    /// string, which callers that raise on `missing` never use).
    static func fill(_ text: String, vars: [String: String], missing: inout Set<String>) -> String {
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "{" || c == "}" {
                let next = text.index(after: i)
                if next < text.endIndex, text[next] == c {     // `{{` / `}}` → one literal brace
                    out.append(c); i = text.index(after: next); continue
                }
                if c == "{", let (name, after) = scanToken(text, from: i) {
                    if let v = vars[name] {
                        out.append(v)
                    } else {
                        // RECORD the unresolved token. Oracle A's `_substitute` raises
                        // MailTemplateMissingVariableError naming every missing placeholder —
                        // leaving `{token}` verbatim would let an un-substituted
                        // `{recipient_name}` flow into outbound subject/body text.
                        missing.insert(name)
                        out.append("{\(name)}")
                    }
                    i = after; continue
                }
            }
            out.append(c)
            i = text.index(after: i)
        }
        return out
    }

    /// Render a template. `autoVars` (today, recipient_name/email, original_subject) are
    /// merged UNDER `userVars` (user overrides win), matching MCP A's contract.
    public func render(name: String, autoVars: [String: String], userVars: [String: String]) throws -> RenderResult {
        let tpl = try get(name)
        var vars = autoVars
        for (k, v) in userVars { vars[k] = v }               // user overrides auto
        var missing = Set<String>()
        let subject = tpl.subject.map { TemplateStore.fill($0, vars: vars, missing: &missing) }
        let body = TemplateStore.fill(tpl.body, vars: vars, missing: &missing)
        // Oracle parity: an unresolved placeholder is an ERROR, not a silent literal. Oracle A's
        // `_substitute` collects ALL missing names and raises MailTemplateMissingVariableError
        // with them sorted; `error_type` on the wire is `missing_template_variable`.
        guard missing.isEmpty else {
            throw AppleError(type: "missing_template_variable",
                             message: "missing placeholder(s): \(missing.sorted().joined(separator: ", "))",
                             exitCode: AppleExit.usage)
        }
        return RenderResult(name: name, subject: subject, body: body, variables: vars, used_vars: vars)
    }

    /// Today's date (YYYY-MM-DD) in the machine's LOCAL calendar — MCP A auto-fills `{today}`
    /// from Python's `date.today()`, which is local, not UTC. This was UTC before, so every
    /// render made during the local-evening UTC-offset window substituted TOMORROW's date into
    /// outbound subject/body text (e.g. 20:00 in America/New_York is already the next UTC day).
    /// `Calendar.current` is deliberate: it follows the operator's locale/timezone the way
    /// `date.today()` follows the process timezone.
    public static func todayString(now: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
