import Foundation
import AppleKit

/// File-backed email templates at the SAME location MCP A uses —
/// `~/.apple_mail_mcp/templates/<name>.md` (override with `APPLE_MAIL_MCP_HOME`) — so the two
/// share a store. A template may carry an optional `Subject:` header line; the remainder is
/// the body. Both subject and body may contain `{placeholder}` tokens filled by `render`.
///
/// NOTE on interop: on this fleet the templates dir is empty (MCP A `list_templates` → []),
/// so MCP A's exact on-disk serialization could not be introspected against a real file. The
/// `Subject:`-header + body convention here is chosen for human-readability; if a future MCP A
/// template on disk uses a different framing, adjust `parse`/`save` to match (a self-contained
/// change — round-trip covered by tests).
///
/// Pure + filesystem-only (no Mail.app, no TCC) — fully unit-testable with a temp home.
public struct TemplateStore {
    public let root: URL

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
    }
    public struct TemplateSummary: Encodable {
        public let name: String
        public let subject: String?
    }
    public struct TemplatesResult: Encodable { public let templates: [TemplateSummary]; public let count: Int }
    public struct RenderResult: Encodable {
        public let name: String
        public let subject: String?
        public let body: String
        public let variables: [String: String]
    }

    // MARK: Name validation (MCP A: alnum / underscore / hyphen, 1–64)

    public static func validateName(_ name: String) throws {
        let ok = !name.isEmpty && name.count <= 64 &&
            name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        guard ok else {
            throw AppleError.validation("template name must be 1–64 chars of letters, digits, '_' or '-'; got '\(name)'.")
        }
    }

    private func fileURL(_ name: String) -> URL { root.appendingPathComponent("\(name).md") }

    // MARK: CRUD

    public func list() throws -> [TemplateSummary] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return entries.filter { $0.hasSuffix(".md") }.sorted().compactMap { file in
            let name = String(file.dropLast(3))
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
        return Template(name: name, subject: subject, body: body)
    }

    @discardableResult
    public func save(name: String, body: String, subject: String?) throws -> Template {
        try TemplateStore.validateName(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var contents = ""
        if let subject, !subject.isEmpty { contents += "Subject: \(subject)\n\n" }
        contents += body
        try contents.write(to: fileURL(name), atomically: true, encoding: .utf8)
        return Template(name: name, subject: subject, body: body)
    }

    public func delete(_ name: String) throws {
        try TemplateStore.validateName(name)
        guard FileManager.default.fileExists(atPath: fileURL(name).path) else {
            throw AppleError.notFound("no template named '\(name)'.")
        }
        try FileManager.default.removeItem(at: fileURL(name))
    }

    // MARK: Parse + render

    /// Split a template file into (subject?, body). A leading `Subject:` line (followed by an
    /// optional blank line) is the subject; everything else is the body.
    private func readParsed(_ name: String) throws -> (String?, String) {
        let raw = try String(contentsOf: fileURL(name), encoding: .utf8)
        return TemplateStore.parse(raw)
    }

    static func parse(_ raw: String) -> (String?, String) {
        var lines = raw.components(separatedBy: "\n")
        guard let first = lines.first, first.lowercased().hasPrefix("subject:") else {
            return (nil, raw)
        }
        let subject = String(first.dropFirst("subject:".count)).trimmingCharacters(in: .whitespaces)
        lines.removeFirst()
        if lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        return (subject.isEmpty ? nil : subject, lines.joined(separator: "\n"))
    }

    /// Replace `{token}` occurrences in `text` from `vars`. Unknown tokens are left as-is.
    static func fill(_ text: String, vars: [String: String]) -> String {
        var out = text
        for (k, v) in vars { out = out.replacingOccurrences(of: "{\(k)}", with: v) }
        return out
    }

    /// Render a template. `autoVars` (today, recipient_name/email, original_subject) are
    /// merged UNDER `userVars` (user overrides win), matching MCP A's contract.
    public func render(name: String, autoVars: [String: String], userVars: [String: String]) throws -> RenderResult {
        let tpl = try get(name)
        var vars = autoVars
        for (k, v) in userVars { vars[k] = v }               // user overrides auto
        let subject = tpl.subject.map { TemplateStore.fill($0, vars: vars) }
        let body = TemplateStore.fill(tpl.body, vars: vars)
        return RenderResult(name: name, subject: subject, body: body, variables: vars)
    }

    /// Today's date (YYYY-MM-DD, UTC) — MCP A auto-fills `{today}`.
    public static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }
}
