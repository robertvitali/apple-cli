import Testing
import Foundation
import SQLite3
import TestSupport
@testable import AppleKit

/// `withReadSnapshotPinned` — the coherence step for `copyToTemp` (COMPLETION-LOOP Q4h).
///
/// `copyToTemp` copies the main DB, `-wal` and `-shm` at three different instants. SQLite is
/// explicit that a file-level copy of a live database can be inconsistent or corrupt, and the
/// interleaving that does it is a checkpoint RESETTING the WAL between the main-file copy and the
/// `-wal` copy — pairing a pre-checkpoint main file with a post-reset WAL of another generation.
///
/// So these tests do not assert "a transaction was begun", which would prove nothing. They assert
/// the property that makes the copy safe: **while pinned, a concurrent connection cannot truncate
/// the WAL.** That is the thing a checkpoint would have to do to break us.
@Suite("Read-snapshot pinning")
struct ReadSnapshotPinTests {

    private let scratch = ScratchDirs("readpin")

    /// A WAL-mode database with un-checkpointed content, i.e. a non-empty `-wal`.
    ///
    /// The returned connection MUST be kept alive by the caller and closed at the end. Closing the
    /// last connection to a WAL database checkpoints and deletes the `-wal`, so a fixture that tidily
    /// closed its handle had an empty WAL and nothing to protect — the control caught it.
    func walDatabase() throws -> (URL, OpaquePointer) {
        let url = try scratch.directory().appendingPathComponent("live.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        var st: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL", -1, &st, nil) == SQLITE_OK)
        #expect(sqlite3_step(st) == SQLITE_ROW)
        sqlite3_finalize(st)
        #expect(sqlite3_exec(db, "CREATE TABLE t(x)", nil, nil, nil) == SQLITE_OK)
        for i in 0..<200 { sqlite3_exec(db, "INSERT INTO t VALUES(\(i))", nil, nil, nil) }
        #expect(walSize(url) > 0, "control: the fixture really has un-checkpointed WAL content")
        return (url, db!)
    }

    func walSize(_ db: URL) -> Int {
        let a = try? FileManager.default.attributesOfItem(atPath: db.path + "-wal")
        return (a?[.size] as? Int) ?? 0
    }

    /// Attempt a TRUNCATE checkpoint from a SEPARATE connection, as a checkpointing writer would.
    /// Returns true if the WAL was actually reset to zero bytes.
    @discardableResult
    func truncateCheckpoint(_ url: URL) -> Bool {
        var w: OpaquePointer?
        guard sqlite3_open_v2(url.path, &w, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return false }
        defer { sqlite3_close(w) }
        sqlite3_busy_timeout(w, 250)
        var st: OpaquePointer?
        sqlite3_prepare_v2(w, "PRAGMA wal_checkpoint(TRUNCATE)", -1, &st, nil)
        _ = sqlite3_step(st)
        sqlite3_finalize(st)
        return walSize(url) == 0
    }

    @Test("while pinned, a concurrent TRUNCATE checkpoint cannot reset the WAL")
    func pinBlocksWalReset() throws {
        let (url, keepAlive) = try walDatabase()
        defer { sqlite3_close(keepAlive) }
        var resetWhilePinned = true

        try SQLiteReader.withReadSnapshotPinned(url.path) {
            resetWhilePinned = truncateCheckpoint(url)
        }

        #expect(!resetWhilePinned, "a reset here is exactly what makes a 3-file copy incoherent")
        #expect(walSize(url) > 0, "the WAL our copy depends on is still the one we started with")

        // POSITIVE CONTROL: the same checkpoint DOES succeed once nothing is pinning it. Without
        // this the test would pass on a machine where TRUNCATE never works for an unrelated reason.
        #expect(truncateCheckpoint(url), "unpinned, the very same call resets the WAL")
        #expect(walSize(url) == 0)
    }

    @Test("the body still runs when the store cannot be opened read-only")
    func fallsBackWhenUnpinnable() throws {
        // Best-effort by design: pinning may only improve coherence, never turn a working read into
        // a failure. A path that cannot be opened must not stop the copy.
        let missing = try scratch.directory().appendingPathComponent("no-such.sqlite").path
        var ran = false
        try SQLiteReader.withReadSnapshotPinned(missing) { ran = true }
        #expect(ran)
    }

    @Test("the body runs exactly once and its errors propagate")
    func runsOnceAndRethrows() throws {
        let (url, keepAlive) = try walDatabase()
        defer { sqlite3_close(keepAlive) }
        var calls = 0
        try SQLiteReader.withReadSnapshotPinned(url.path) { calls += 1 }
        #expect(calls == 1)

        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try SQLiteReader.withReadSnapshotPinned(url.path) { throw Boom() }
        }
        // The pin is released even when the body threw — otherwise the next caller would contend
        // with a mark nobody owns. Note this observes the CONNECTION being released, not the COMMIT
        // specifically: `close_v2` ends the transaction regardless, so an assertion aimed at the
        // COMMIT alone is vacuous. A reviewer demonstrated exactly that by deleting it and watching
        // every test still pass.
        #expect(truncateCheckpoint(url), "the read mark was released on the throwing path too")
    }

    @Test("with no -shm present the pin is skipped, and none is created next to the live store")
    func skipsPinRatherThanTouchingTheLiveStore() throws {
        // This is the only place the tool opens a LIVE store with a real connection, and such an
        // open CREATES a `-shm` beside it — inside ~/Library/Mail/, where a read-only connection
        // cannot remove it again. So the pin is gated on a `-shm` already existing. Everywhere else
        // the tool is scrupulous about not writing near the real stores; this keeps that true.
        let dir = try scratch.directory()
        let url = dir.appendingPathComponent("rollback.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE t(x)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)                                  // rollback-journal db: no -shm, no -wal
        #expect(!FileManager.default.fileExists(atPath: url.path + "-shm"), "control: no -shm yet")

        var ran = false
        let pinned = try SQLiteReader.withReadSnapshotPinned(url.path) { ran = true }

        #expect(ran, "the copy must still happen")
        #expect(!pinned, "and it must report that it did NOT pin")
        #expect(!FileManager.default.fileExists(atPath: url.path + "-shm"),
                "we must not have created one beside the real store")
    }

    @Test("with a -shm present the pin IS taken and says so")
    func reportsPinned() throws {
        let (url, keepAlive) = try walDatabase()
        defer { sqlite3_close(keepAlive) }
        #expect(FileManager.default.fileExists(atPath: url.path + "-shm"), "control: the owner mapped it")
        let pinned = try SQLiteReader.withReadSnapshotPinned(url.path) { }
        #expect(pinned)
    }

    @Test("a real reader still produces correct data through the pinned copy")
    func pinnedCopyStillReads() throws {
        let (url, keepAlive) = try walDatabase()
        defer { sqlite3_close(keepAlive) }
        let reader = try SQLiteReader(path: url.path, copyToTemp: true)
        let rows = try reader.query("SELECT COUNT(*) AS n FROM t")
        #expect((rows.first?["n"] ?? nil) == "200", "all 200 rows, including un-checkpointed ones")
        withExtendedLifetime(reader) { }
    }

    // MARK: the wiring — without these, the whole feature can be deleted from `init` silently

    @Test("a real snapshot-backed reader actually pins AND verifies")
    func initPinsAndVerifies() throws {
        // THE gap a reviewer found: `ReadSnapshotPinTests` called the helper directly, and
        // `pinnedCopyStillReads` used a quiescent database that returns the right rows with or
        // without the pin. Deleting the wrapper from `init` left every test in the repo green.
        let (url, keepAlive) = try walDatabase()
        defer { sqlite3_close(keepAlive) }
        let reader = try SQLiteReader(path: url.path, copyToTemp: true)
        #expect(try reader.query("SELECT COUNT(*) AS n FROM t").first?["n"] == "200")

        // Read from THIS reader, not a global: a shared static raced the parallel suites.
        let diag = try #require(reader.snapshotDiagnostics)
        #expect(diag.pinned, "init must take the read pin")
        #expect(diag.verified, "and must verify the WAL generation")
        #expect(diag.retries == 0, "with no reset, no retry")
        withExtendedLifetime(reader) { }
    }

    @Test("the WAL salt is what changes on a reset — the signal the verification reads")
    func saltMovesOnReset() throws {
        let (url, keepAlive) = try walDatabase()
        defer { sqlite3_close(keepAlive) }

        let before = SQLiteReader.walSalt(url.path)
        #expect(before != nil, "control: there is a WAL to read a salt from")
        #expect(before?.count == 16)

        // Reset the WAL the way a checkpointing writer would, then write again so a WAL exists.
        sqlite3_exec(keepAlive, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
        for i in 200..<260 { sqlite3_exec(keepAlive, "INSERT INTO t VALUES(\(i))", nil, nil, nil) }

        #expect(SQLiteReader.walSalt(url.path) != before,
                "a reset must be visible in the salt, or the verification detects nothing")
    }

    @Test("a store with no WAL verifies trivially rather than erroring")
    func noWalStillVerifies() throws {
        let dir = try scratch.directory()
        let url = dir.appendingPathComponent("plain.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE t(x); INSERT INTO t VALUES(1)", nil, nil, nil)
        sqlite3_close(db)
        #expect(SQLiteReader.walSalt(url.path) == nil, "control: no -wal, so no salt")

        let reader = try SQLiteReader(path: url.path, copyToTemp: true)
        #expect(try reader.query("SELECT COUNT(*) AS n FROM t").first?["n"] == "1")
        #expect(try #require(reader.snapshotDiagnostics).verified, "nil == nil is a valid verification")
        withExtendedLifetime(reader) { }
    }
}
