import Foundation

/// Shared write-destination confinement (Q13). The **Mail** attachment-save / export surfaces and
/// the **Contacts** `vcard export` / `photo get` `--out` writes resolve the operator-supplied path
/// through `confineWriteDestination` first.
///
/// Promoted to `AppleKit` from its original Mail-only home so the Contacts `--out` writes (a CLI
/// superset extra — the Contacts MCP returns the bytes in its response and never takes an output
/// path) get the same guards; without them a `contacts photo … --out ~/.ssh/authorized_keys` would
/// overwrite an SSH key with photo bytes, the exact hazard the Mail `save_email_attachment` fix
/// closed (patrickfreyer manage.py:197-220 / analytics.py:428-443 refuse two path classes before
/// touching the store: outside `$HOME`, and at/under a credential-config directory).
///
/// NOT (yet) universal: **Notes `save-attachment`** deliberately uses its OWN guard
/// (`NotesKit.AttachmentFS.assertSafeSavePath`), a verbatim port of `apple-notes-mcp@2.5.12`
/// `attachmentFs.ts` that confines to home / temp / `/Volumes` but has NO credential-dir blocklist —
/// so `notes save-attachment --path ~/.ssh/authorized_keys` is currently accepted, MATCHING that
/// oracle. Routing it through `sensitiveWriteDir` would add the blocklist but NARROW the
/// strict-superset (drop a write the Notes oracle permits), so it is a separate parity-vs-safety
/// decision (HUMAN-DECISIONS.md D12) — not silently folded in here. Do not extend this doc's
/// coverage claim to Notes until that lands.

/// Directories whose contents are credentials/config and must never be a write destination,
/// regardless of mode. Returns the matched sensitive dir (for the refusal message) or nil.
/// The match is case-insensitive and boundary-aware: `~/.ssh/id_rsa` and `~/.ssh` match, but
/// `~/.sshfoo/x` does not (prefix, not a path boundary).
public func sensitiveWriteDir(_ resolvedPath: String, home: String) -> String? {
    let dirs = [".ssh", ".gnupg", ".config", ".aws", ".claude",
                "Library/Keychains", "Library/LaunchAgents", "Library/LaunchDaemons"]
        .map { home + "/" + $0 }
    let lowered = resolvedPath.lowercased()
    return dirs.first(where: {
        let d = $0.lowercased()
        return lowered == d || lowered.hasPrefix(d + "/")
    })
}

/// Lexically reduce only terminal slash / dot spellings before checking the raw final leaf.
/// This deliberately does NOT standardize the whole path: `..` components, interior dots, and
/// symlinked parents stay exactly the operator's spelling for the final-leaf lstat check.
public func rawFinalLeafPath(_ raw: String) -> String {
    // Keep this expansion identical to `confineWriteDestination`; the guard and eventual write
    // must address the same tilde-spelled path. ASCII slash/dot suffixes that do not match
    // literally fail toward non-reduction.
    // A foreign `~user` spelling is never expanded here (Foundation would resolve a KNOWN
    // user's home): `confineWriteDestination` refuses it first, and a raw lstat of the literal
    // spelling is harmless.
    var path = TildeSpelling.ownHome(raw).map { ($0 as NSString).expandingTildeInPath } ?? raw
    while true {
        let before = path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        if path.count > 2 && path.hasSuffix("/.") {
            path.removeLast(2)
            continue
        }
        if path == before {
            return path
        }
    }
}

/// Refuse an operator-supplied destination whose raw final leaf is a symlink.
///
/// `confineWriteDestination` resolves symlinks so it can check the real target against home and
/// credential-directory policy. That is correct for containment, but it also means a planted final
/// symlink can redirect the bytes to its target. This helper is intentionally narrower: it checks
/// only the final raw leaf, including dangling symlinks, and leaves broader path policy to callers.
/// `destinationOfSymbolicLink` errors are deliberately treated as "not a link": an inaccessible
/// parent cannot be written by the later write path, while ENOENT is required for legitimate new
/// leaves. Do not widen this helper into an errno-specific filesystem policy check.
///
/// "Raw" names the probe (an lstat of exactly the string given, no normalization), not the
/// caller's spelling: `refuseFinalLeafSymlink` also feeds it Foundation's constructed and
/// resolved spellings, and some callers pass an already-resolved destination.
public func refuseRawFinalLeafSymlink(_ raw: String, action: String) throws {
    let path = rawFinalLeafPath(raw)
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
        throw AppleError.safetyViolation("cannot \(action) raw destination '\(path)' because it is a symlink — refusing.")
    }
}

/// Refuse a final-leaf symlink at the spelling Foundation actually selects for the write.
///
/// `confineWriteDestination` constructs `URL(fileURLWithPath:)` and calls
/// `resolvingSymlinksInPath()`. Measured on macOS 26: resolution is PHYSICAL only when every
/// component of the constructed path, the leaf included, exists (`fileExists(atPath:)` is exactly
/// that predicate — it follows links, so a dangling leaf or an absent component fails it);
/// otherwise Foundation falls back to the LEXICAL collapse of the constructed path. So:
///
/// - on the physical branch, lstat the constructed path: the kernel resolves a symlinked parent
///   before `..`, matching Foundation, and an existing final-leaf link is what the write would
///   follow (resolution already replaced it with its target, so the resolved path cannot show it);
/// - on both branches, lstat the resolved path: on the lexical branch it is the destination
///   itself, which a missing component before `..` hid from the constructed spelling, and a
///   dangling leaf link survives resolution there.
///
/// The operator's raw spelling is deliberately NOT probed: for a relative path, URL construction
/// collapses `..` lexically before any link is consulted, and for an absolute path whose physical
/// leaf is absent or dangling Foundation writes the lexical leaf — in both cases a kernel lstat of
/// the raw spelling reaches an unrelated `physical/leaf` and would refuse a write Foundation never
/// makes there. `refuseRawFinalLeafSymlink` remains for callers that already hold the exact
/// spelling a later write or AppleScript receives.
public func refuseFinalLeafSymlink(_ raw: String, action: String) throws {
    guard let spelled = TildeSpelling.ownHome(raw) else {
        throw AppleError.safetyViolation("cannot \(action) " + TildeSpelling.refusalMessage(raw))
    }
    let expanded = (spelled as NSString).expandingTildeInPath
    let destination = URL(fileURLWithPath: expanded)
    if FileManager.default.fileExists(atPath: destination.path) {
        try refuseRawFinalLeafSymlink(destination.path, action: action)
    }
    try refuseRawFinalLeafSymlink(destination.resolvingSymlinksInPath().path, action: action)
}

/// Resolve and confine an operator-supplied write path, or throw `AppleError.safetyViolation`
/// (exit 77 — a deliberate refusal, not a bug, so callers apply it on the DRY-RUN path too and a
/// preview never promises a write `--execute` would refuse).
///
/// Guards, in order:
///  1. CONTROL CHARACTERS (C0 + DEL), unconditionally. A confined path is later serialized into an
///     RS(0x1E)/US(0x1F)-delimited blob for AppleScript; a path carrying those bytes passes every
///     check as one string then re-parses downstream as TWO records, the second targeting a
///     destination that never passed confinement. Rejecting the whole C0 range also covers NUL and
///     newline injection. (Verified as a live bypass before this guard existed.)
///  2. `$HOME` confinement, UNLESS `allowOutsideHome` — an opt-out for surfaces whose oracle has no
///     confinement at all (Mail's `save_attachments`; Contacts `--out`, a CLI extra), so `/tmp` and
///     `/Volumes/*` stay legitimate destinations. `$HOME` itself is allowed.
///  3. The credential/config blocklist — ABSOLUTE, never opt-out-able. Checked against the resolved
///     path AND the pre-resolution literal, so a sensitive dir that is itself a symlink is caught.
///
/// Symlinks are resolved before comparing (the oracles use `realpath`).
///
/// - Parameter action: verb for the refusal message, e.g. "save attachments into" / "write the vCard to".
/// - Parameter allowOutsideHome: opt out of the `$HOME` rule ONLY. The credential blocklist and the
///   control-character rejection are absolute and cannot be disabled.
public func confineWriteDestination(_ raw: String, action: String,
                                    allowOutsideHome: Bool = false) throws -> URL {
    if let bad = raw.unicodeScalars.first(where: { $0.value < 0x20 || $0.value == 0x7F }) {
        throw AppleError.safetyViolation(
            "cannot \(action) a path containing a control character (U+\(String(format: "%04X", bad.value))) — refusing.")
    }
    // Refuse another user's `~user` spelling before expansion (see TildeSpelling): on macOS 15
    // Foundation would silently rewrite an unknown user to the process home, turning a path the
    // operator did not spell into an accepted, in-home destination.
    guard let spelled = TildeSpelling.ownHome(raw) else {
        throw AppleError.safetyViolation("cannot \(action) " + TildeSpelling.refusalMessage(raw))
    }
    let expanded = (spelled as NSString).expandingTildeInPath
    let resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
    let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
    let path = resolved.path
    if !allowOutsideHome {
        let l = path.lowercased(), h = home.lowercased()
        guard l == h || l.hasPrefix(h + "/") else {
            throw AppleError.safetyViolation("cannot \(action) a path outside your home directory (\(home)); got: \(path)")
        }
    }
    if let dir = sensitiveWriteDir(path, home: home) ?? sensitiveWriteDir(expanded, home: home) {
        throw AppleError.safetyViolation("cannot \(action) a sensitive directory (\(dir)) — refusing.")
    }
    return resolved
}
