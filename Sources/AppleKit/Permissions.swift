import Foundation

/// Shared TCC / permission preflight + a common health/`doctor` shape, so every domain
/// reports permission state consistently (each port spec has a `doctor`/`health` in its
/// parity floor). Framework-specific authorization (EventKit, Contacts) is checked in the
/// owning domain/`EventKitCore`; this covers Full Disk Access detection + the shared result.
public enum Permissions {

    /// A yes/no question about one path.
    ///
    /// The seam exists because the production probe reads the operator's real TCC-protected
    /// stores, which a logic test must never touch — so before this split the preflight's
    /// granted / denied / no-such-file outcomes could not be exercised at all, and the whole
    /// type sat at zero coverage. `hasFullDiskAccess(paths:exists:canRead:)` takes the two
    /// probes; the no-argument `hasFullDiskAccess()` binds the live ones and is the only
    /// spelling production uses.
    /// Internal, like every consumer: the probe-taking overload at `hasFullDiskAccess(paths:
    /// exists:canRead:)` is module-internal, so exporting the alias would only invite a public
    /// overload that let an outside caller answer the FDA question however it liked.
    typealias PathProbe = (String) -> Bool

    /// The TCC-protected paths whose readability answers the FDA question, for a given home.
    /// Named separately so the list itself is assertable without opening anything.
    static func protectedPaths(home: String) -> [String] {
        [home + "/Library/Messages/chat.db",
         home + "/Library/Application Support/com.apple.TCC/TCC.db"]
    }

    /// The production `exists` probe.
    static func pathExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// The production `canRead` probe: can this process actually open `path` for reading?
    static func openForReading(_ path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return false
        }
        try? handle.close()
        return true
    }

    /// Probe Full Disk Access by actually opening a known TCC-protected path. If the process
    /// (or its responsible parent terminal) holds FDA, the open succeeds.
    public static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return hasFullDiskAccess(paths: protectedPaths(home: home),
                                 exists: pathExists, canRead: openForReading)
    }

    /// The decision, with both filesystem questions supplied. A path that does not exist is
    /// skipped rather than counted as a denial (a Mac with no Messages history has no
    /// `chat.db`), so "no candidate path existed" and "every candidate refused to open" both
    /// report `false` — which is what the remediation note in `preflight` addresses.
    static func hasFullDiskAccess(paths: [String], exists: PathProbe, canRead: PathProbe) -> Bool {
        for path in paths where exists(path) {
            if canRead(path) { return true }
        }
        return false
    }

    /// Shared preflight result — domains embed this in their `doctor` output.
    public struct Preflight: Encodable {
        public let full_disk_access: Bool
        public let notes: [String]
        public init(full_disk_access: Bool, notes: [String] = []) {
            self.full_disk_access = full_disk_access
            self.notes = notes
        }
    }

    public static func preflight() -> Preflight {
        // KNOWINGLY UNTESTED: this forwarding, and `hasFullDiskAccess()`'s own, cannot be pinned
        // without reading the operator's live TCC and Messages stores, which the logic tier may
        // not do. The injected overloads below carry every bit of the logic; both no-argument
        // spellings are kept to a single trivial expression so there is nothing else to get wrong.
        preflight(fullDiskAccess: hasFullDiskAccess())
    }

    /// The envelope-shaping half of `preflight()`, with the probe result supplied. Keeps the
    /// note text — which is user-facing copy in every domain's `doctor` output — checkable
    /// without a machine whose FDA state happens to be the one the assertion wants.
    static func preflight(fullDiskAccess fda: Bool) -> Preflight {
        var notes: [String] = []
        if !fda {
            notes.append("Full Disk Access not detected — grant it to your terminal in "
                         + "System Settings › Privacy & Security › Full Disk Access.")
        }
        return Preflight(full_disk_access: fda, notes: notes)
    }
}
