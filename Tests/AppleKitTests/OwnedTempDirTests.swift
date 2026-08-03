import Testing
import Foundation
@testable import AppleKit

/// `OwnedTempDir` — the private 0700 directory shared by the SQLite snapshots and the generated
/// `.eml` files, plus the age-based reaper the `.eml` side needs (COMPLETION-LOOP Q4d/Q4f).
///
/// Every test owns its `base`, so nothing here touches the real shared temp directory. That is not
/// tidiness: an earlier test in this change set deleted a live reader's files out of a shared root
/// and two reviewers reproduced it killing a concurrent command with `disk I/O error`.
@Suite("Owned temp directory")
struct OwnedTempDirTests {

    func base(_ label: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-cli-otd-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func mode(_ url: URL) throws -> Int {
        var st = stat()
        #expect(lstat(url.path, &st) == 0)
        return Int(st.st_mode & 0o777)
    }

    func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

    @discardableResult
    func file(_ dir: URL, _ name: String, ageSeconds: TimeInterval) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: u)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-ageSeconds)], ofItemAtPath: u.path)
        return u
    }

    // MARK: make

    @Test("creates the directory 0700, and re-tightens a loosened one on the next call")
    func createsAndRetightens() throws {
        let b = try base("make"); defer { try? FileManager.default.removeItem(at: b) }
        let dir = try OwnedTempDir.make("apple-cli-thing", base: b)
        #expect(dir.lastPathComponent == "apple-cli-thing")
        #expect(try mode(dir) == 0o700)

        // `createDirectory(attributes:)` applies its mode only when it CREATES, so every run after
        // the first takes the existing-directory branch and would otherwise inherit any mode.
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: dir.path)
        _ = try OwnedTempDir.make("apple-cli-thing", base: b)
        #expect(try mode(dir) == 0o700, "a pre-existing loosened directory must be tightened")
    }

    @Test("refuses a path occupied by a plain file instead of failing obscurely later")
    func refusesNonDirectory() throws {
        let b = try base("file"); defer { try? FileManager.default.removeItem(at: b) }
        try Data("x".utf8).write(to: b.appendingPathComponent("apple-cli-thing"))
        // Asserting only the TYPE would pass with the whole lstat guard deleted: `createDirectory`
        // on an occupied path throws too, and the catch-all rewraps it as AppleError. The message is
        // the half that is actually about this code — naming the tool and the remedy.
        #expect {
            _ = try OwnedTempDir.make("apple-cli-thing", base: b)
        } throws: { ($0 as? AppleError)?.message.contains("exists but is not a directory") == true }
    }

    @Test("a symlink squatting the name is refused, and its target is untouched")
    func refusesSymlink() throws {
        // `make`'s docstring names this as the headline risk ("it may be a symlink pointing
        // somewhere else entirely") and nothing tested it. `lstat` is what makes it work: `stat`
        // would report the TARGET as a directory and happily hand it back.
        let b = try base("symlink"); defer { try? FileManager.default.removeItem(at: b) }
        let elsewhere = b.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: elsewhere.appendingPathComponent("data.txt"))
        try FileManager.default.createSymbolicLink(at: b.appendingPathComponent("apple-cli-thing"),
                                                   withDestinationURL: elsewhere)

        #expect {
            _ = try OwnedTempDir.make("apple-cli-thing", base: b)
        } throws: { ($0 as? AppleError)?.message.contains("exists but is not a directory") == true }
        #expect(exists(elsewhere.appendingPathComponent("data.txt")), "nothing behind the link is touched")
    }

    @Test("restrictToOwner sets 0600")
    func restricts() throws {
        let b = try base("chmod"); defer { try? FileManager.default.removeItem(at: b) }
        let f = try file(b, "x.eml", ageSeconds: 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.path)
        #expect(try mode(f) == 0o644, "control: it really starts world-readable")
        OwnedTempDir.restrictToOwner(f)
        #expect(try mode(f) == 0o600)
    }

    // MARK: reapFiles

    @Test("reaps only files past the age, and only with our name prefix")
    func reapsByAgeAndSuffix() throws {
        let b = try base("reap"); defer { try? FileManager.default.removeItem(at: b) }
        let old = try file(b, "apple-cli-old.eml", ageSeconds: 90_000)
        let fresh = try file(b, "apple-cli-fresh.eml", ageSeconds: 60)
        let otherKind = try file(b, "someone-elses.txt", ageSeconds: 90_000)

        #expect(OwnedTempDir.reapFiles(in: b, prefix: "apple-cli-", olderThan: 86_400) == 1)
        #expect(!exists(old), "positive control: it does delete something")
        #expect(exists(fresh), "a file inside the window is a possible live hand-off")
        #expect(exists(otherKind), "a file without our prefix is not ours to delete")
    }

    @Test("a directory sharing the prefix is never removed — removeItem recurses")
    func skipsDirectories() throws {
        let b = try base("dir"); defer { try? FileManager.default.removeItem(at: b) }
        let trap = b.appendingPathComponent("apple-cli-looks-like-a-file.eml", isDirectory: true)
        try FileManager.default.createDirectory(at: trap, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: trap.appendingPathComponent("inner.txt"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-90_000)], ofItemAtPath: trap.path)
        // Positive control in the same call, so a reaper that does nothing cannot pass.
        try file(b, "apple-cli-real.eml", ageSeconds: 90_000)

        #expect(OwnedTempDir.reapFiles(in: b, prefix: "apple-cli-", olderThan: 86_400) == 1)
        #expect(exists(trap.appendingPathComponent("inner.txt")), "the directory tree survives")
    }

    @Test("a symlink is not followed and not counted")
    func skipsSymlinks() throws {
        let b = try base("sym"); defer { try? FileManager.default.removeItem(at: b) }
        let precious = try file(b, "precious.dat", ageSeconds: 90_000)
        let link = b.appendingPathComponent("apple-cli-link.eml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: precious)
        try file(b, "apple-cli-real.eml", ageSeconds: 90_000)          // positive control

        #expect(OwnedTempDir.reapFiles(in: b, prefix: "apple-cli-", olderThan: 86_400) == 1)
        #expect(exists(precious), "the link's target must survive")
        var st = stat()
        #expect(lstat(link.path, &st) == 0, "and the link itself is left alone")
    }

    // KNOWINGLY UNTESTED: the `st_uid == getuid()` guard. Creating a directory owned by another
    // uid needs root, which the suite does not have and should not want. Listed rather than left
    // to look like coverage.

    @Test("a missing directory is a no-op, not a crash")
    func missingDirIsSafe() {
        let nowhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-cli-otd-absent-\(UUID().uuidString)")
        #expect(OwnedTempDir.reapFiles(in: nowhere, prefix: "apple-cli-", olderThan: 0) == 0)
    }
}
