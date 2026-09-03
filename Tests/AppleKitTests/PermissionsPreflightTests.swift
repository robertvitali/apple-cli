import Foundation
import Testing
import TestSupport
@testable import AppleKit

/// Full Disk Access preflight (`Permissions`).
///
/// Every domain's `doctor`/`health` embeds this result, and until the probe seam existed the
/// whole type had ZERO logic coverage: the only spelling was `hasFullDiskAccess()`, which
/// answers by opening the operator's real `~/Library/Messages/chat.db` and TCC database. A test
/// may not read those, so the granted / denied / absent outcomes — and the remediation copy a
/// user is shown — were unassertable.
///
/// Every outcome test supplies its own two probes, and the filesystem cases use `ScratchDirs`
/// files this suite created itself. NOTHING here calls the no-argument `hasFullDiskAccess()` or
/// `preflight()`: those answer by opening the operator's real Messages and TCC databases, which
/// this tier may not touch at any byte count. Their residue is recorded at the production site.
@Suite("Full Disk Access preflight")
struct PermissionsPreflightTests {

    private let scratch = ScratchDirs("permissions")

    @Test("a readable protected path means access is granted")
    func grantedWhenAProtectedPathOpens() {
        #expect(Permissions.hasFullDiskAccess(paths: ["/a", "/b"],
                                              exists: { _ in true },
                                              canRead: { $0 == "/b" }))
    }

    @Test("an existing but unreadable path is a denial, not a skip")
    func deniedWhenEveryExistingPathRefuses() {
        var asked: [String] = []
        let granted = Permissions.hasFullDiskAccess(
            paths: ["/a", "/b"],
            exists: { _ in true },
            canRead: { asked.append($0); return false })
        #expect(!granted)
        // Both candidates are tried: stopping at the first refusal would report "denied" on a
        // Mac whose chat.db is unreadable but whose TCC.db is not.
        #expect(asked == ["/a", "/b"])
    }

    @Test("a path that does not exist is skipped without being opened")
    func absentPathsAreNeverOpened() {
        var opened: [String] = []
        let granted = Permissions.hasFullDiskAccess(
            paths: ["/a", "/b"],
            exists: { $0 == "/b" },
            canRead: { opened.append($0); return true })
        #expect(granted)
        #expect(opened == ["/b"], "the missing candidate must not be opened at all")
    }

    @Test("no candidate paths at all reports no access rather than trapping")
    func emptyCandidateListIsADenial() {
        #expect(!Permissions.hasFullDiskAccess(paths: [], exists: { _ in true },
                                               canRead: { _ in true }))
    }

    @Test("the candidate list is the two TCC-protected stores under the given home")
    func candidateListShape() {
        let paths = Permissions.protectedPaths(home: "/Users/example")
        #expect(paths == ["/Users/example/Library/Messages/chat.db",
                          "/Users/example/Library/Application Support/com.apple.TCC/TCC.db"])
    }

    @Test("the production probes answer for a real file and for a missing one")
    func productionProbes() throws {
        let file = try scratch.directory().appendingPathComponent("readable")
        try Data("x".utf8).write(to: file)
        #expect(Permissions.pathExists(file.path))
        #expect(Permissions.openForReading(file.path))
        #expect(!Permissions.pathExists(file.path + "-does-not-exist"))
        #expect(!Permissions.openForReading(file.path + "-does-not-exist"))
    }

    @Test("a path that exists but cannot be opened reads as denied, not as absent")
    func existingButUnreadableFileIsADenial() throws {
        // Mode bits do not restrain uid 0, so as root the open below SUCCEEDS and the assertions
        // invert. Skip rather than fail: this is a statement about an unprivileged process.
        try #require(getuid() != 0, "a 0o000 file is still readable by root — run this unprivileged")

        let file = try scratch.directory().appendingPathComponent("locked")
        try Data("x".utf8).write(to: file)
        #expect(chmod(file.path, 0o000) == 0)
        defer { _ = chmod(file.path, 0o600) }

        // This is the shape of a real FDA denial: the store is there, the open is refused.
        #expect(Permissions.pathExists(file.path))
        #expect(!Permissions.openForReading(file.path))
        #expect(!Permissions.hasFullDiskAccess(paths: [file.path],
                                               exists: Permissions.pathExists,
                                               canRead: Permissions.openForReading))
    }

    @Test("a granted preflight carries no remediation note")
    func preflightGranted() {
        let result = Permissions.preflight(fullDiskAccess: true)
        #expect(result.full_disk_access)
        #expect(result.notes.isEmpty)
    }

    @Test("a denied preflight carries the System Settings remediation note verbatim")
    func preflightDenied() throws {
        let result = Permissions.preflight(fullDiskAccess: false)
        #expect(!result.full_disk_access)
        #expect(result.notes == ["Full Disk Access not detected — grant it to your terminal in "
                                 + "System Settings › Privacy & Security › Full Disk Access."])
    }

    @Test("the preflight encodes with the wire keys domains embed in doctor output")
    func preflightWireShape() throws {
        let data = try Output.encode(Permissions.preflight(fullDiskAccess: false))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"full_disk_access\" : false"))
        #expect(text.contains("\"notes\""))
    }
}
