import Foundation
import Testing
import TestSupport
@testable import AppleKit

/// `OwnedTempDir` guarantees a real directory, owned by this uid, at mode 0700 — because what
/// goes inside it is copies of the operator's mail and messages. The guarantee is only worth
/// something if the REFUSALS work, and those were the uncovered half: the paths where the
/// directory cannot be created, and where it exists but cannot be secured.
///
/// Every path here is under a `ScratchDirs` directory this suite created. Nothing touches the
/// shared temp root, and the one test that has to defeat `chmod` clears the flag it set before
/// it can leave anything undeletable behind.
@Suite("Owned temp directory refusals")
struct OwnedTempDirFailureTests {

    private let scratch = ScratchDirs("ownedtemp")

    private func message(_ error: any Error) -> String {
        ((error as? AppleError)?.message) ?? String(describing: error)
    }

    @Test("a base that is a regular file cannot hold a directory, and says so")
    func refusesWhenTheDirectoryCannotBeCreated() throws {
        let base = try scratch.directory().appendingPathComponent("a-file")
        try Data("not a directory".utf8).write(to: base)

        let error = #expect(throws: AppleError.self) {
            _ = try OwnedTempDir.make("child", base: base)
        }
        #expect(try #require(error).type == AppleErrorType.upstream)
        #expect(message(try #require(error)).hasPrefix("could not create "))
    }

    // A plain file at the destination, a symlink at the destination, and re-tightening a loosened
    // directory are `OwnedTempDirTests.refusesNonDirectory` / `refusesSymlink` /
    // `createsAndRetightens`. Restating them here was strictly weaker in one place — the symlink
    // version omitted `refusesSymlink`'s "nothing behind the link is touched" assertion, which is
    // the half that distinguishes a refusal from a refusal-after-clobbering — so the older,
    // stronger spellings are the ones kept.

    @Test("a directory whose mode cannot be changed is refused, quoting the mode it is stuck at")
    func refusesWhenTheModeCannotBeSecured() throws {
        let base = try scratch.directory()
        let target = base.appendingPathComponent("immutable", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])

        // `UF_IMMUTABLE` makes `chmod` fail with EPERM without needing another uid, which is how
        // the "silently-failed chmod" case this guard exists for is reproduced. Cleared before
        // anything else can run, or the scratch directory would be undeletable.
        #expect(chflags(target.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(target.path, 0) }

        let error = #expect(throws: AppleError.self) {
            _ = try OwnedTempDir.make("immutable", base: base)
        }
        let text = message(try #require(error))
        #expect(text.contains("could not be secured to 0700"))
        #expect(text.contains("(it is 755)"), "the refusal names the mode it is stuck at: \(text)")
    }

    @Test("`path` reports where the directory would go without creating or touching anything")
    func pathIsAPurePreview() throws {
        let base = try scratch.directory()
        let planned = OwnedTempDir.path("preview", base: base)
        #expect(planned.path == base.appendingPathComponent("preview").path)
        #expect(!FileManager.default.fileExists(atPath: planned.path))
    }

    // The reaper's own behaviour — age window, name prefix, directories skipped, symlinks neither
    // followed nor counted, a missing directory answering zero — is `OwnedTempDirTests`
    // (`reapsByAgeAndSuffix`, `skipsDirectories`, `skipsSymlinks`, `missingDirIsSafe`), which
    // additionally covers the symlink case this file never had. Not restated.
}
