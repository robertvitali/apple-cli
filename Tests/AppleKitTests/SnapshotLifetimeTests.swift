import Testing
import Foundation
import SQLite3
@testable import AppleKit

/// Lifetime of the `copyToTemp` snapshots.
///
/// `deinit` removed them and essentially never ran — ArgumentParser ends a command with `exit()`.
/// Measured before the fix: >150 snapshot files totalling multiple GB, of real mail content in `$TMPDIR`.
///
/// Two earlier attempts here were unsound, and the fixes are the shape of this suite:
///   * An age-based design was reverted in production because `copyItem` preserves the source
///     mtime, so a snapshot could be born already sweep-eligible. The replacement asks the kernel
///     whether the owner process is alive rather than guessing from a clock — so **the tests that
///     matter spawn a REAL second process**, because in-process state proves nothing about the
///     cross-process property that actually broke.
///   * A test called `removeAll()` on a shared singleton and deleted another suite's live
///     snapshots mid-run (swift-testing puts every suite in one process), surfacing as unrelated
///     `disk I/O error` failures. **Nothing here mutates shared state**: every test owns its base
///     directory, and session tests construct a private `SnapshotSession`.
@Suite("Snapshot lifetime")
struct SnapshotLifetimeTests {

    func tmpDir(_ label: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-cli-lifetest-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A real SQLite DB. `walMode` matters: the `-wal`/`-shm` copy path only runs for a source that
    /// actually has sidecars, and no earlier test ever created one.
    @discardableResult
    func sourceDB(_ dir: URL, walMode: Bool = false, ageSeconds: TimeInterval = 0) throws -> URL {
        let url = dir.appendingPathComponent("source.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        if walMode {
            var stmt: OpaquePointer?
            #expect(sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL", -1, &stmt, nil) == SQLITE_OK)
            #expect(sqlite3_step(stmt) == SQLITE_ROW)
            sqlite3_finalize(stmt)
        }
        #expect(sqlite3_exec(db, "CREATE TABLE t(x TEXT); INSERT INTO t VALUES('hello')",
                             nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        if ageSeconds > 0 {
            for p in [url.path, url.path + "-wal", url.path + "-shm"]
            where FileManager.default.fileExists(atPath: p) {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(-ageSeconds)], ofItemAtPath: p)
            }
        }
        return url
    }

    func mode(_ url: URL) throws -> Int {
        var st = stat()
        #expect(lstat(url.path, &st) == 0)
        return Int(st.st_mode & 0o777)
    }

    func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

    func kids(_ u: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: u.path)) ?? []).sorted()
    }

    // MARK: the root directory

    @Test("the snapshots root is created 0700, and a loosened mode is repaired on the next call")
    func rootIsPrivate() throws {
        let base = try tmpDir("root"); defer { try? FileManager.default.removeItem(at: base) }

        let root = try SQLiteReader.snapshotsRoot(base: base)
        #expect(root.lastPathComponent == "apple-cli-snapshots")
        #expect(try mode(root) == 0o700, "created 0700")

        // The bug this catches: `createDirectory(attributes:)` applies the mode only when it
        // CREATES. Every run after the first takes the existing-directory path, so without the
        // re-assert a directory holding copies of the operator's mail keeps whatever mode it has.
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
        _ = try SQLiteReader.snapshotsRoot(base: base)
        #expect(try mode(root) == 0o700, "a pre-existing loosened directory must be tightened")
    }

    @Test("a non-directory at the root path is refused, not silently used")
    func rootRejectsNonDirectory() throws {
        let base = try tmpDir("rootfile"); defer { try? FileManager.default.removeItem(at: base) }
        try Data("x".utf8).write(to: base.appendingPathComponent("apple-cli-snapshots"))
        #expect(throws: SQLiteReader.DBError.self) { _ = try SQLiteReader.snapshotsRoot(base: base) }
    }

    // MARK: the session directory (what replaces `deinit`)

    @Test("a session directory is created 0700, locked, and holds the snapshot")
    func sessionDirectoryIsLocked() throws {
        let base = try tmpDir("sess"); defer { try? FileManager.default.removeItem(at: base) }
        let session = SQLiteReader.SnapshotSession()
        let dir = try session.directory(base: base)
        defer { session.remove() }

        #expect(try mode(dir) == 0o700)
        #expect(kids(dir) == [".lock"], "the lock is taken before the directory is usable")
        #expect(try session.directory(base: base) == dir, "created once, not per call")

        // The lock is genuinely held: a fresh descriptor cannot take it, which is exactly what a
        // reaper in another process tries.
        let fd = open(dir.appendingPathComponent(".lock").path, O_RDWR)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX | LOCK_NB) != 0, "a held lock must not be re-acquirable")
        close(fd)
    }

    @Test("remove() drops the whole directory and is idempotent")
    func sessionRemoveIsIdempotent() throws {
        let base = try tmpDir("rm"); defer { try? FileManager.default.removeItem(at: base) }
        let session = SQLiteReader.SnapshotSession()
        let dir = try session.directory(base: base)
        try Data("x".utf8).write(to: dir.appendingPathComponent("stray.sqlite"))

        session.remove()
        #expect(!exists(dir), "everything inside goes with the directory, tracked or not")
        session.remove()                       // must not crash
        #expect(!exists(dir))
    }

    // MARK: the reaper — REAL processes, because the property is cross-process

    /// A session-shaped directory owned by a real child process that holds the lock.
    func liveForeignSession(in root: URL) throws -> (URL, Process) {
        let dir = root.appendingPathComponent("s-99999-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lock = dir.appendingPathComponent(".lock").path
        try Data("payload".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).sqlite"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", "import fcntl,sys,time;f=open(sys.argv[1],'w');"
                            + "fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB);print('locked',flush=True);"
                            + "time.sleep(120)", lock]
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run()
        // Wait until the child confirms it holds the lock, or the test races the reaper.
        var got = ""
        let deadline = Date().addingTimeInterval(15)
        while !got.contains("locked") && Date() < deadline {
            got += String(data: pipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        }
        #expect(got.contains("locked"), "control: the child must actually hold the lock")
        return (dir, p)
    }

    @Test("a session whose owner is ALIVE is never reaped")
    func reaperSkipsLiveOwner() throws {
        let base = try tmpDir("live"); defer { try? FileManager.default.removeItem(at: base) }
        let root = try SQLiteReader.snapshotsRoot(base: base)
        let (dir, child) = try liveForeignSession(in: root)
        defer { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }

        #expect(SQLiteReader.reapDeadSessions(in: root) == 0)
        #expect(exists(dir), "reaping a live reader's snapshot is the exact bug that was reverted")
    }

    @Test("a session whose owner DIED is reaped, even after SIGKILL")
    func reaperCollectsDeadOwner() throws {
        let base = try tmpDir("dead"); defer { try? FileManager.default.removeItem(at: base) }
        let root = try SQLiteReader.snapshotsRoot(base: base)
        let (dir, child) = try liveForeignSession(in: root)

        #expect(SQLiteReader.reapDeadSessions(in: root) == 0, "control: alive first")
        kill(child.processIdentifier, SIGKILL)          // the one exit `atexit` can never cover
        child.waitUntilExit()

        #expect(SQLiteReader.reapDeadSessions(in: root) == 1)
        #expect(!exists(dir), "the kernel drops the lock on death, so the directory is collectable")
    }

    @Test("the reaper never collects the calling process's own session")
    func reaperSkipsSelf() throws {
        let base = try tmpDir("self"); defer { try? FileManager.default.removeItem(at: base) }
        let session = SQLiteReader.SnapshotSession()
        let mine = try session.directory(base: base)
        defer { session.remove() }
        let root = try SQLiteReader.snapshotsRoot(base: base)

        // Protected twice: by name, and because a second `flock` from the same process also fails.
        // Assert BOTH — the name check alone would hide a regression in the lock behaviour.
        #expect(SQLiteReader.reapDeadSessions(in: root, skipping: mine) == 0)
        #expect(exists(mine))
        #expect(SQLiteReader.reapDeadSessions(in: root, skipping: nil) == 0, "self-lock also protects it")
        #expect(exists(mine))
    }

    @Test("a directory created but never locked is collected only once it is old")
    func reaperAgesOutUnclaimed() throws {
        let base = try tmpDir("unclaimed"); defer { try? FileManager.default.removeItem(at: base) }
        let root = try SQLiteReader.snapshotsRoot(base: base)
        let dir = root.appendingPathComponent("s-1234-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        #expect(SQLiteReader.reapDeadSessions(in: root) == 0, "fresh and unclaimed: leave it")
        #expect(exists(dir))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: dir.path)
        #expect(SQLiteReader.reapDeadSessions(in: root) == 1)
        #expect(!exists(dir))
    }

    @Test("entries outside the session name shape are left alone, however old")
    func reaperLeavesForeignEntries() throws {
        let base = try tmpDir("foreign"); defer { try? FileManager.default.removeItem(at: base) }
        let root = try SQLiteReader.snapshotsRoot(base: base)
        let keep = root.appendingPathComponent("someone-elses-data", isDirectory: true)
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        let keepFile = root.appendingPathComponent("s-not-a-directory.txt")
        try Data("x".utf8).write(to: keepFile)
        // Positive control in the same call, so a reaper that does nothing cannot pass.
        let victim = root.appendingPathComponent("s-1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        for u in [keep, keepFile, victim] {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-99_999)], ofItemAtPath: u.path)
        }

        #expect(SQLiteReader.reapDeadSessions(in: root) == 1)
        #expect(!exists(victim), "positive control: it does reap")
        #expect(exists(keep), "a directory not named like a session is not ours to delete")
        #expect(exists(keepFile), "nor is a plain file")
    }

    @Test("a symlink shaped like a session directory is neither followed nor removed")
    func reaperIgnoresSymlinks() throws {
        let base = try tmpDir("sym"); defer { try? FileManager.default.removeItem(at: base) }
        let root = try SQLiteReader.snapshotsRoot(base: base)
        let precious = base.appendingPathComponent("precious", isDirectory: true)
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: precious.appendingPathComponent("data.txt"))
        // An UNHELD `.lock` inside the target is what makes this test discriminating. A reaper that
        // followed the link would find that lock through it, acquire it (nobody holds it), conclude
        // the owner is dead and unlink the entry. Without this the target has no lock, the mutated
        // reaper falls through to the unclaimed-age branch, reads the LINK's own fresh mtime via
        // `attributesOfItem` (which does not follow symlinks) and skips — so the test passed
        // against a build mutated from `lstat` to `stat`. Verified: it now fails against it.
        try Data().write(to: precious.appendingPathComponent(".lock"))
        // Age the TARGET, not the link. That is what discriminates `lstat` from `stat`: a reaper
        // that followed the link would see an old, lock-less directory and reap it. The earlier
        // version of this test asserted only that the target's DATA survived, which is a property
        // of `removeItem` (it unlinks a symlink, never traverses it) rather than of this guard —
        // so it passed even against a build mutated from `lstat` to `stat`. Verified vacuous.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-99_999)], ofItemAtPath: precious.path)
        let link = root.appendingPathComponent("s-2-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: precious)

        #expect(SQLiteReader.reapDeadSessions(in: root) == 0, "a symlink is not a session directory")
        var st = stat()
        #expect(lstat(link.path, &st) == 0, "the link itself must survive — reaping it is the regression")
        #expect(exists(precious.appendingPathComponent("data.txt")), "and nothing behind it is touched")
    }

    // MARK: end to end, through a real SQLiteReader

    @Test("a real reader snapshots into the session directory, WAL sidecars included")
    func readerSnapshotsWithSidecars() throws {
        let dir = try tmpDir("e2e"); defer { try? FileManager.default.removeItem(at: dir) }
        // 24h-stale AND WAL-mode: the exact source shape the reverted design mishandled, and the
        // sidecar copy path no earlier test executed.
        let src = try sourceDB(dir, walMode: true, ageSeconds: 86_400)
        #expect(exists(URL(fileURLWithPath: src.path + "-wal")), "control: the source really is WAL-mode")

        // This test uses the SHARED session directory, because only the real `SQLiteReader.init`
        // path is under test and it has no base-directory seam. So assert ONLY about the files this
        // test created: another suite running in parallel owns the rest, and asserting over the
        // whole directory would make this test's verdict depend on their files.
        let session = try SQLiteReader.SnapshotSession.shared.directory()
        let before = Set(kids(session))
        let reader = try SQLiteReader(path: src.path, copyToTemp: true)
        #expect(try reader.query("SELECT x FROM t").first?["x"] == "hello")
        let mine = Set(kids(session)).subtracting(before)

        #expect(mine.contains { $0.hasSuffix(".sqlite") }, "the snapshot lands in the locked session directory")
        #expect(mine.contains { $0.hasSuffix(".sqlite-wal") }, "the -wal sidecar is copied too")
        for name in mine {
            #expect(try mode(session.appendingPathComponent(name)) == 0o600, "0600, not the source's 0644")
        }
        withExtendedLifetime(reader) { }
    }

    @Test("stale age no longer makes a snapshot collectable — the reverted bug cannot recur")
    func staleSourceIsNotCollectable() throws {
        let dir = try tmpDir("stale"); defer { try? FileManager.default.removeItem(at: dir) }
        let base = try tmpDir("stalebase"); defer { try? FileManager.default.removeItem(at: base) }
        let src = try sourceDB(dir, walMode: true, ageSeconds: 86_400)
        let root = try SQLiteReader.snapshotsRoot(base: base)

        let session = SQLiteReader.SnapshotSession()
        let sdir = try session.directory(base: base)
        defer { session.remove() }
        let dest = sdir.appendingPathComponent("\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(atPath: src.path, toPath: dest.path)
        let born = try #require(
            FileManager.default.attributesOfItem(atPath: dest.path)[.modificationDate] as? Date)
        #expect(Date().timeIntervalSince(born) > 3600,
                "control: the copy really did inherit a day-old mtime — this is what broke attempt #3")

        // Under the old design this was deleted out from under a live reader. Age is not consulted
        // for a locked session, so it survives.
        #expect(SQLiteReader.reapDeadSessions(in: root, skipping: nil) == 0)
        #expect(exists(dest))
    }
}
