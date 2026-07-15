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

    /// Standardize + resolve `.`/`..` without requiring the path to exist.
    static func resolvedPath(_ p: String) -> String {
        var s = (p as NSString).standardizingPath
        // standardizingPath may leave a trailing slash on roots; normalize (except bare "/").
        if s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Fail-closed path guard: absolute + resolved must be exactly a root or nested under one.
    @discardableResult
    static func assertSafeSavePath(_ p: String, roots: [String]? = nil) throws -> String {
        let trimmed = p.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw FSError.pathRequired }
        guard (trimmed as NSString).isAbsolutePath else { throw FSError.notAbsolute(p) }
        let abs = resolvedPath(trimmed)
        let allowed = roots ?? allowedSaveRoots()
        let ok = allowed.contains { root in
            let r = resolvedPath(root)
            return abs == r || abs.hasPrefix(r.hasSuffix("/") ? r : r + "/")
        }
        guard ok else { throw FSError.outsideAllowed(abs) }
        return abs
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
