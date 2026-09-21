import Foundation

/// Filesystem guards for attachment save/fetch, ported from `apple-notes-mcp@2.5.12`
/// `attachmentFs.ts`. The path-traversal guard (`assertSafeSavePath`) is the security-critical
/// piece: Notes writes wherever it is told, so we confine writes to the home dir, temp dirs, or
/// `/Volumes` before AppleScript runs. Pure/`FileManager`-only — the traversal guard is
/// unit-testable without touching Notes.
enum AttachmentFS {
    enum FSError: Error, CustomStringConvertible {
        case pathRequired
        case notAbsolute(String)
        case outsideAllowed(String)
        case tooLarge(size: Int, max: Int)
        var description: String {
            switch self {
            case .pathRequired: return "A destination path is required."
            case .notAbsolute(let p): return "Destination path must be absolute: \"\(p)\""
            case .outsideAllowed(let p): return "Refusing to write outside allowed locations (home, temp, /Volumes): \"\(p)\""
            case .tooLarge(let size, let max):
                return "Attachment is \(size) bytes, exceeding the \(max)-byte fetch limit. Use save-attachment to export it to disk instead."
            }
        }
    }

    static let defaultMaxAttachmentBytes = 25 * 1024 * 1024

    static func allowedSaveRoots() -> [String] {
        [
            resolvedPath(NSHomeDirectory()),
            resolvedPath(NSTemporaryDirectory()),
            "/Volumes",
            "/private/var/folders",
            "/tmp",
            "/private/tmp",
        ]
    }

    /// Existence-INDEPENDENT lexical normalization. Expands a leading tilde (`~` / `~user` — though
    /// `assertSafeSavePath` refuses every `~user` form but the current account's own, rewritten to
    /// `~`, before calling here), collapses
    /// repeated slashes, resolves `.` and `..` component-wise without ever escaping `/`, drops a
    /// trailing slash, and canonicalizes the macOS `/private` aliases the allowed roots use
    /// (`/private/tmp`, `/private/var`) to their short spellings so both sides of the guard compare
    /// in ONE form.
    ///
    /// Deliberately not `NSString.standardizingPath`: that strips a leading `/private` only when the
    /// stripped path EXISTS, so an existing `/private/tmp/dir` compared as `/tmp/dir` while an absent
    /// `/private/tmp/dir/new.bin` kept the long form and fell outside every (short-form) root — a
    /// valid `save-attachment --dry-run` destination was refused (exit 64) purely because the leaf
    /// did not exist yet. This function never consults the filesystem. Symlink resolution is NOT
    /// done here by design; `assertResolvedParentContained` does that once the parent exists.
    /// Tilde expansion is kept on purpose: `NSString.isAbsolutePath` (the caller's precheck) accepts
    /// `~…` spellings, which `standardizingPath` used to expand, so dropping it would silently turn
    /// `~/…` destinations into refusals (and half-reverse D12's `~/.ssh` parity). CONTRACT: callers
    /// MUST reject relative input before calling (`assertSafeSavePath` does, via `isAbsolutePath`) —
    /// this function silently anchors a relative path at `/`, which is NOT fail-closed: `tmp/x`
    /// would come back as `/tmp/x` and pass the root check.
    static func resolvedPath(_ p: String) -> String {
        let expanded = (p as NSString).expandingTildeInPath
        // Split on the U+002F SCALAR, never on Characters: a `/` followed by a combining mark forms
        // one grapheme cluster that a Character-level split does not treat as a separator, so
        // `/tmp/../<U+0301>/x` would keep its `..` inside a single bogus component, read as still
        // under `/tmp`, and escape under the kernel's byte-wise interpretation.
        var components: [String] = []
        for part in expanded.unicodeScalars.split(separator: "/", omittingEmptySubsequences: true) {
            let comp = String(part)
            switch comp {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(comp)
            }
        }
        var s = "/" + components.joined(separator: "/")
        for alias in privateAliases {
            let short = String(alias.dropFirst("/private".count))
            if s == alias { s = short; break }
            if s.hasPrefix(alias + "/") { s = short + String(s.dropFirst(alias.count)); break }
        }
        return s
    }

    /// The `/private` symlink aliases the allowed roots actually use. `/tmp` → `/private/tmp` and
    /// `/var` → `/private/var` are real symlinks on macOS, so folding is an equivalence, not a guess.
    /// `standardizingPath` folds these only when the target exists; here they fold unconditionally so
    /// absent and existing paths compare alike. Deliberately NOT `/private/etc`: no allowed root is
    /// under `/etc`, so it changes no decision today, and folding it would silently extend reach if a
    /// future caller injected such a root. The fold is exact-case on purpose (as before): a
    /// case-variant spelling such as `/PRIVATE/TMP` is not folded and is refused — the safe direction.
    private static let privateAliases = ["/private/tmp", "/private/var"]

    /// Fail-closed path guard: absolute + resolved must be exactly a root or nested under one.
    @discardableResult
    static func assertSafeSavePath(_ p: String, roots: [String]? = nil) throws -> String {
        let trimmed = p.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw FSError.pathRequired }
        guard (trimmed as NSString).isAbsolutePath else { throw FSError.notAbsolute(p) }
        // `isAbsolutePath` admits `~…`. Only the operator's own home is a spelling this guard
        // accepts: `~`, `~/…`, and the same home named by the current account (`~name`,
        // `~name/…`), which is rewritten to the bare form so both expand through the same
        // home directory. Any other `~user` form is refused outright rather than handed to
        // `expandingTildeInPath`, whose treatment of an unknown user differs by macOS release
        // (observed unchanged on macOS 27 and silently replaced by the process home on
        // macOS 15) — either way it names a destination the operator did not spell.
        let own = ownHomeSpelling(trimmed)
        guard let spelled = own else { throw FSError.notAbsolute(p) }
        let expanded = (spelled as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw FSError.notAbsolute(p) }
        let abs = resolvedPath(expanded)
        let allowed = roots ?? allowedSaveRoots()
        let ok = allowed.contains { root in
            let r = resolvedPath(root)
            return abs == r || abs.hasPrefix(r.hasSuffix("/") ? r : r + "/")
        }
        guard ok else { throw FSError.outsideAllowed(abs) }
        return abs
    }

    /// `nil` for a `~user` spelling that is not the current account; otherwise the spelling with
    /// the current account's own `~name` collapsed to `~`, and any non-tilde path unchanged.
    ///
    /// Works on UNICODE SCALARS, never Characters: `isAbsolutePath` and `expandingTildeInPath`
    /// both see a leading U+007E even when a combining mark, ZWJ or variation selector follows
    /// it and turns the pair into one grapheme cluster that `hasPrefix("~")` would not match.
    /// (The same hazard class as the `/` split in `resolvedPath`.)
    static func ownHomeSpelling(_ trimmed: String) -> String? {
        let scalars = trimmed.unicodeScalars
        guard scalars.first == "~" else { return trimmed }
        let rest = scalars.dropFirst()
        if rest.isEmpty || rest.first == "/" { return trimmed }
        let name = Array(NSUserName().unicodeScalars)
        guard !name.isEmpty, rest.count >= name.count, Array(rest.prefix(name.count)) == name else { return nil }
        let tail = rest.dropFirst(name.count)
        guard tail.isEmpty || tail.first == "/" else { return nil }
        var own = String.UnicodeScalarView()
        own.append("~")
        own.append(contentsOf: tail)
        return String(own)
    }

    /// The spelling downstream RAW-path checks must inspect: the operator's input with its
    /// whitespace trimmed and the current account's `~name` collapsed to `~`, so a raw check
    /// expands through the same home as the normalized write. Call only after
    /// `assertSafeSavePath` accepted the same input (a refused `~user` form comes back unchanged).
    static func rawSpellingForChecks(_ p: String) -> String {
        let trimmed = p.trimmingCharacters(in: .whitespaces)
        return ownHomeSpelling(trimmed) ?? trimmed
    }

    static func ensureParentDir(_ abs: String) throws {
        let dir = (abs as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    /// Second, symlink-aware containment check run AFTER the parent dir exists. `assertSafeSavePath`
    /// is lexical (`standardizingPath` does not resolve symlinks), so a symlinked parent could point
    /// outside the allowed roots; this resolves the real parent path and re-asserts containment,
    /// also narrowing the create→save TOCTOU window. Both sides are symlink-resolved so the macOS
    /// `/tmp`→`/private/tmp` and `/var`→`/private/var` aliases don't cause false rejections.
    static func assertResolvedParentContained(_ abs: String, roots: [String]? = nil) throws {
        let parent = (abs as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: parent) else { return }
        let realParent = URL(fileURLWithPath: parent).resolvingSymlinksInPath().path
        let allowed = (roots ?? allowedSaveRoots()).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let ok = allowed.contains { r in realParent == r || realParent.hasPrefix(r.hasSuffix("/") ? r : r + "/") }
        guard ok else { throw FSError.outsideAllowed(realParent) }
    }

    static func fileExists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

    static func fileSize(_ p: String) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: p) else { return 0 }
        return (attrs[.size] as? Int) ?? 0
    }

    static func readFileBase64Capped(_ p: String, maxBytes: Int = defaultMaxAttachmentBytes) throws -> String {
        let size = fileSize(p)
        if size > maxBytes { throw FSError.tooLarge(size: size, max: maxBytes) }
        let data = try Data(contentsOf: URL(fileURLWithPath: p))
        return data.base64EncodedString()
    }

    static func makeTempDir() throws -> String {
        let dir = resolvedPath(NSTemporaryDirectory()) + "/apple-notes-att-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cleanupTempDir(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }
}
