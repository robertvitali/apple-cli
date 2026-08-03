import Testing
import Foundation
import TestSupport

/// `ScratchDirs` — the shared test-scratch helper that actually reclaims what it vends.
///
/// Worth testing rather than trusting, because the failure is invisible: a suite using it looks
/// identical whether or not cleanup happens, and that is exactly how ~14,000 files accumulated in
/// the shared temp root before anyone measured it.
@Suite("ScratchDirs")
struct ScratchDirsTests {

    func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

    @Test("a vended directory exists while the instance lives and is gone once it dies")
    func reclaimsOnDeinit() throws {
        var dir: URL?
        do {
            let scratch = ScratchDirs("selftest")
            let d = try scratch.directory()
            try Data("x".utf8).write(to: d.appendingPathComponent("inner.txt"))
            #expect(exists(d), "control: it exists while the owner is alive")
            #expect(exists(d.appendingPathComponent("inner.txt")))
            dir = d
        }                                    // scratch released here
        let d = try #require(dir)
        #expect(!exists(d), "the whole directory goes with its owner, contents included")
    }

    @Test("each call is a distinct directory")
    func vendsUniquePaths() throws {
        let scratch = ScratchDirs("selftest-unique")
        let a = try scratch.directory(), b = try scratch.directory()
        #expect(a != b)
        #expect(exists(a) && exists(b))
    }

    @Test("it reclaims only what it vended, never a sibling it merely resembles")
    func neverTouchesForeignPaths() throws {
        // The distinction that matters: tracking exact URLs, not matching a name pattern in a
        // shared directory. Pattern-matching deletes in the temp root is how a test in this repo
        // destroyed a concurrently-running command's files.
        let foreign = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-cli-selftest-foreign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: foreign) }

        do {
            let scratch = ScratchDirs("selftest-foreign")   // same prefix shape as `foreign`
            _ = try scratch.directory()
        }
        #expect(exists(foreign), "a look-alike it did not create must survive")
    }
}
