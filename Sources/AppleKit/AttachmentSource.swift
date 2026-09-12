import Foundation

/// The shared guard for a file the CLI is about to SEND OUT — a Mail attachment, a Messages
/// `--file`. It is the read-side counterpart of `confineWriteDestination`: that one bounds where
/// bytes may LAND, this one bounds which bytes may LEAVE.
///
/// **Why it is shared.** It began as `MailKit`'s `resolveAttachmentPath` and was promoted here
/// when Messages grew `--file`, per AGENTS.md ("Shared helpers live in `AppleKit` — never
/// reinvent per-domain"). A per-domain copy is how two outbound surfaces end up with two
/// containment policies, which is exactly what the first draft of the Messages flag did: it
/// checked existence and readability and nothing else, so
/// `apple messages send <number> --file ~/.ssh/id_ed25519` was accepted and delivered
/// unrecallably from one command line, on a surface that (matching the MCP, per write-model v2)
/// reaches any recipient outside the sandbox.
///
/// **CONTAINMENT NOTE (write-model v2).** Outside the sandbox recipients are unrestricted, so the
/// sensitive-directory blocklist and the executable-extension blocklist below ARE the containment
/// for attachment CONTENT. They are absolute and fire in both modes. Inside the sandbox the
/// per-domain recipient allowlist additionally bounds where an attachment can go.
///
/// **Not `confineWriteDestination`.** That guard confines a WRITE and refuses anything outside
/// `$HOME`; an attachment is read, and an operator may legitimately send a file from `/tmp` or a
/// mounted volume. Only the parts that are about CONTENT — the credential blocklist and the
/// control-character rule — carry over.
///
/// **No parity is narrowed by this.** For Mail the blocklists ARE the oracle's behaviour
/// (s-morgan `validate_attachment_type` + its 25 MB cap, patrickfreyer `sensitive_dirs`). For
/// Messages, `mac_messages_mcp` is text-only — it cannot send a file at all — so a refusal here
/// cannot drop a capability the oracle had. The Notes D12 carve-out does not reach this surface
/// either: that one exists because the Notes oracle PERMITS the write being discussed.
public enum AttachmentSource {

    /// Executable / script extensions refused by default (mirrors s-morgan
    /// `validate_attachment_type`'s `dangerous_extensions`). Blocking is the parity default for
    /// Mail; there is no allow-executables override yet, and Messages adopts the same list rather
    /// than keeping a second, laxer policy on the other outbound surface.
    public static let dangerousExtensions: Set<String> = [
        "exe", "bat", "cmd", "com", "scr", "pif", "vbs", "vbe", "js", "jse", "wsf", "wsh",
        "msi", "msp", "scf", "lnk", "inf", "reg", "ps1", "psm1", "app", "deb", "rpm", "sh",
        "bash", "csh", "ksh", "zsh", "command",
    ]

    /// The s-morgan `send_email_with_attachments` default cap, applied to both domains: a clean
    /// pre-send refusal instead of an opaque hang inside Mail or Messages. It also bounds the
    /// send's duration, which matters because the osascript run behind it has no host deadline.
    public static let maxBytes = 25 * 1024 * 1024

    /// Resolve and vet one operator-supplied path, or throw.
    ///
    /// Returns the SYMLINK-RESOLVED absolute path, and that is the path the caller attaches,
    /// sends, and reports back. Resolving before the checks is the whole point: a symlink into
    /// `~/.ssh` would otherwise walk straight past the credential blocklist (patrickfreyer's
    /// `realpath` ordering). A caller that wants to echo the operator's own spelling must still
    /// run the CHECK on this resolved path.
    ///
    /// The argument is never trimmed. `report ` (one trailing space) is a legal macOS filename,
    /// and trimming would stat, resolve and send a neighbouring `report` instead — a silently
    /// substituted file. Empty and whitespace-only arguments still fail, at the existence check.
    ///
    /// Refusal classes, in order:
    ///  1. control characters (C0 + DEL) → `safety_violation` (77). Resolved paths are joined
    ///     into an RS/US-delimited AppleScript blob on the Mail route, so a path CONTAINING one
    ///     of those bytes passes every check as one string and re-splits in-script as TWO,
    ///     the second never vetted. The same rule also covers the NUL that would truncate a path
    ///     between this `stat` and the `osascript` argv that carries it.
    ///  2. missing / not a regular file → `not_found` (65).
    ///  3. over `maxBytes` → `validation_error` (64).
    ///  4. executable/script extension → `validation_error` (64).
    ///  5. under a credential/config directory → `safety_violation` (77), checked against BOTH
    ///     the resolved path (defeats a symlink INTO a sensitive dir) AND the tilde-expanded
    ///     literal (defeats a sensitive dir that is ITSELF a symlink, e.g. a stow-managed
    ///     `~/.ssh` -> `~/dotfiles/ssh`).
    /// - Parameter home: the home directory the credential blocklist is measured against. A SEAM,
    ///   not a policy knob: production takes the default on both call sites, and it exists so the
    ///   containment cases can be proven against a SYNTHETIC `~/.ssh` built in a scratch directory.
    ///   The alternative — `setenv("HOME", …)` — is process-wide, and swift-testing runs suites in
    ///   parallel, so it would change the answer for every other reader in the run (the failure
    ///   mode AGENTS.md documents for the sandbox variables).
    public static func resolve(_ raw: String,
                               home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> String {
        if let bad = raw.unicodeScalars.first(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw AppleError.safetyViolation(
                "cannot attach a path containing a control character (U+\(String(format: "%04X", bad.value))) — refusing.")
        }
        let expanded = (raw as NSString).expandingTildeInPath
        let path = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            throw AppleError.notFound("attachment not found or not a regular file: \(raw)")
        }
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber,
           size.intValue > maxBytes {
            throw AppleError.validation("attachment exceeds the 25 MB send limit (\(size.intValue) bytes): \(raw)")
        }
        // Matched on the filename's SUFFIX, not `NSString.pathExtension`, so a file named
        // literally `.command` (no basename) is blocked too — the oracle matches the same way.
        let base = (path as NSString).lastPathComponent.lowercased()
        if let blockedExt = dangerousExtensions.first(where: { base.hasSuffix(".\($0)") }) {
            throw AppleError.validation("attachment type '.\(blockedExt)' is blocked (executable/script); refusing: \(raw)")
        }
        if let dir = sensitiveWriteDir(path, home: home) ?? sensitiveWriteDir(expanded, home: home) {
            throw AppleError.safetyViolation("cannot attach a file from a sensitive directory (\(dir)) — refusing.")
        }
        return path
    }
}
