import Foundation

/// Shared TCC / permission preflight + a common health/`doctor` shape, so every domain
/// reports permission state consistently (each port spec has a `doctor`/`health` in its
/// parity floor). Framework-specific authorization (EventKit, Contacts) is checked in the
/// owning domain/`EventKitCore`; this covers Full Disk Access detection + the shared result.
public enum Permissions {

    /// Probe Full Disk Access by actually opening a known TCC-protected path. If the process
    /// (or its responsible parent terminal) holds FDA, the open succeeds.
    public static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let protectedPaths = [
            home + "/Library/Messages/chat.db",
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
        ]
        for path in protectedPaths where FileManager.default.fileExists(atPath: path) {
            if let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) {
                try? handle.close()
                return true
            }
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
        let fda = hasFullDiskAccess()
        var notes: [String] = []
        if !fda {
            notes.append("Full Disk Access not detected — grant it to your terminal in "
                         + "System Settings › Privacy & Security › Full Disk Access.")
        }
        return Preflight(full_disk_access: fda, notes: notes)
    }
}
