import Foundation
import SQLite3
import Testing
import TestSupport
@testable import AppleKit

/// Error and degradation paths in `SQLiteReader`.
///
/// The happy paths are well covered by the snapshot suites; what was not covered is what happens
/// when the store is missing, the SQL is wrong, the read-pin cannot be taken, or the session
/// directory cannot be created. Each of those is a "degrade, do not lie" contract — the reader
/// either reports a typed failure or continues unpinned — so an untested one is a contract with
/// nothing behind it.
///
/// Every database here is built by this suite inside a `ScratchDirs` directory. Nothing opens an
/// Apple store.
@Suite("SQLite reader error paths")
struct SQLiteReaderErrorPathTests {

    private let scratch = ScratchDirs("sqliteerr")

    /// A tiny on-disk database with one table and one row.
    private func database(_ name: String = "src.sqlite") throws -> URL {
        let url = try scratch.directory().appendingPathComponent(name)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, """
            CREATE TABLE t(id INTEGER, label TEXT, weight REAL, payload BLOB, absent TEXT);
            INSERT INTO t VALUES(7, 'seven', 1.5, x'00FF00', NULL);
            """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        return url
    }

    @Test("opening a store that is not there is a typed open failure, not a crash")
    func missingStoreFailsToOpen() throws {
        let missing = try scratch.directory().appendingPathComponent("nope.sqlite").path
        let error = #expect(throws: SQLiteReader.DBError.self) {
            _ = try SQLiteReader(path: missing)
        }
        guard case .open = try #require(error) else { Issue.record("expected .open"); return }
        #expect(try #require(error).description.hasPrefix("sqlite open failed:"))
    }

    @Test("a file that is not a database never yields rows")
    func malformedStoreNeverYieldsRows() throws {
        let junk = try scratch.directory().appendingPathComponent("junk.sqlite")
        try Data(repeating: 0x41, count: 4096).write(to: junk)
        // `sqlite3_open_v2` is lazy, so the header is usually not read until the first statement
        // and the failure lands at prepare time — but either boundary is a correct refusal. What
        // must never happen is a successful read of nonsense.
        do {
            let reader = try SQLiteReader(path: junk.path)
            #expect(throws: SQLiteReader.DBError.self) {
                _ = try reader.query("SELECT 1 FROM sqlite_master")
            }
        } catch let error as SQLiteReader.DBError {
            guard case .open = error else { Issue.record("expected .open, got \(error)"); return }
        }
    }

    @Test("unparseable SQL is a prepare failure on both row APIs")
    func prepareFailureOnBothQueryShapes() throws {
        let reader = try SQLiteReader(path: try database().path)
        let textError = #expect(throws: SQLiteReader.DBError.self) {
            _ = try reader.query("SELEC nonsense FROM t")
        }
        guard case .prepare = try #require(textError) else {
            Issue.record("expected .prepare"); return
        }
        let typedError = #expect(throws: SQLiteReader.DBError.self) {
            _ = try reader.rows("SELEC nonsense FROM t")
        }
        guard case .prepare = try #require(typedError) else {
            Issue.record("expected .prepare"); return
        }
        #expect(try #require(typedError).description.hasPrefix("sqlite prepare failed:"))
    }

    @Test("the three DBError cases render with their own prefixes")
    func errorDescriptions() {
        #expect(SQLiteReader.DBError.open("a").description == "sqlite open failed: a")
        #expect(SQLiteReader.DBError.prepare("b").description == "sqlite prepare failed: b")
        #expect(SQLiteReader.DBError.step("c").description == "sqlite step failed: c")
    }

    @Test("binds are positional parameters, not interpolated text")
    func boundParametersSelectRows() throws {
        let reader = try SQLiteReader(path: try database().path)
        let matched = try reader.query("SELECT label FROM t WHERE id = ?1 AND label = ?2",
                                       ["7", "seven"])
        #expect(matched.count == 1)
        let label = try #require(matched.first?["label"])
        #expect(label == "seven")

        // A bind carrying SQL text is DATA. If it were interpolated this would return the row.
        let hostile = try reader.query("SELECT label FROM t WHERE label = ?1",
                                       ["seven' OR '1'='1"])
        #expect(hostile.isEmpty)

        // The typed API binds the same way.
        #expect(try reader.rows("SELECT id FROM t WHERE label = ?1", ["seven"]).count == 1)
        #expect(try reader.rows("SELECT id FROM t WHERE label = ?1",
                                ["seven' OR '1'='1"]).isEmpty)
    }

    @Test("the typed row API preserves column types, including BLOBs the text API truncates")
    func typedRowsPreserveTypes() throws {
        let reader = try SQLiteReader(path: try database().path)
        let row = try #require(try reader.rows("SELECT * FROM t").first)
        #expect(row.values["id"] == .integer(7))
        #expect(row.values["label"] == .text("seven"))
        #expect(row.values["weight"] == .real(1.5))
        #expect(row.values["payload"] == .blob(Data([0x00, 0xFF, 0x00])))
        #expect(row.values["absent"] == .null)

        // Accessors: numeric columns still read as text, and a BLOB is only reachable as Data.
        #expect(row.text("id") == "7")
        #expect(row.text("weight") == "1.5")
        #expect(row.text("payload") == nil)
        #expect(row.int("id") == 7)
        #expect(row.int("weight") == 1)
        #expect(row.data("payload") == Data([0x00, 0xFF, 0x00]))
        #expect(row.data("label") == nil)
        #expect(row.text("no-such-column") == nil)
        #expect(row.int("no-such-column") == nil)
    }

    @Test("a NULL text column reads back as a present key holding nil")
    func textQueryDistinguishesNullFromMissing() throws {
        let reader = try SQLiteReader(path: try database().path)
        let row = try #require(try reader.query("SELECT absent FROM t").first)
        #expect(row.keys.contains("absent"))
        let value = try #require(row["absent"])   // the key is present …
        #expect(value == nil)                     // … holding nil
    }

    // The URI-shape assertions that used to live here (absolute vs relative, percent-encoding,
    // `mode=ro` never mentioning `immutable`) were a restatement of `SQLiteReaderURITests` in
    // SQLiteReaderTests.swift, which covers the same ground and additionally pins the
    // query-parameter injection case. Removed rather than kept in two places.

    @Test("the WAL-aware direct mode opens the same store the immutable mode does")
    func walAwareDirectOpen() throws {
        let url = try database("walaware.sqlite")
        let reader = try SQLiteReader(path: url.path, directOpen: .walAware)
        let row = try #require(try reader.query("SELECT COUNT(*) AS n FROM t").first)
        #expect(try #require(row["n"]) == "1")
    }

    @Test("the salt probe is nil when the store has no write-ahead log")
    func walSaltAbsentWithoutAWAL() throws {
        #expect(SQLiteReader.walSalt(try database("nowal.sqlite").path) == nil)
    }

    // The no-`-shm` skip is `ReadSnapshotPinTests.skipsPinRatherThanTouchingTheLiveStore`, which
    // asserts the same two things plus that no `-shm` is created. Not restated here.

    @Test("a store that cannot be opened for the pin still runs the body unpinned")
    func pinDegradesWhenTheStoreCannotBeOpened() throws {
        // `-shm` present (so the gate lets us try) but nothing to open: the pin must fail soft.
        let dir = try scratch.directory()
        let absent = dir.appendingPathComponent("vanished.sqlite")
        try Data().write(to: dir.appendingPathComponent("vanished.sqlite-shm"))

        var ran = false
        let pinned = SQLiteReader.withReadSnapshotPinned(absent.path) { ran = true }
        #expect(ran, "best effort: a failed pin may never turn a working read into a failure")
        #expect(!pinned)
    }

    @Test("a body that throws WHILE PINNED propagates, and the pin is released after it")
    func pinRethrowsBodyFailuresWhilePinned() throws {
        // The pin is gated on an existing `-shm`, so this store must be WAL-mode with a live
        // connection held open for the duration: close the last connection and the `-shm`
        // disappears, the pin is skipped, and this silently asserts rethrow from the UNPINNED
        // branch — leaving the pinned teardown (the `defer` that ends the read transaction and
        // closes the connection) untested while staying green.
        let url = try scratch.directory().appendingPathComponent("rethrow.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }   // held open: closing the last connection deletes the -shm
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL", -1, &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        sqlite3_finalize(statement)
        #expect(sqlite3_exec(db, "CREATE TABLE t(x); INSERT INTO t VALUES(1)",
                             nil, nil, nil) == SQLITE_OK)
        #expect(FileManager.default.fileExists(atPath: url.path + "-shm"),
                "control: without a -shm the pin is skipped and this tests the wrong branch")

        // Control, and the discriminating one: a HELD pin must block a TRUNCATE checkpoint.
        // Taking a second pin afterwards would prove nothing — SQLite allows any number of
        // concurrent readers, so that assertion survives deleting the teardown entirely. A
        // truncating checkpoint is the operation a live read mark actually blocks, so it can
        // tell "released" from "still held".
        var busyWhilePinned: Int32?
        #expect(SQLiteReader.withReadSnapshotPinned(url.path) {
            busyWhilePinned = truncatingCheckpoint(url.path)?.busy
        }, "control: this store really is pinnable, so the throwing call below took that branch")
        // Without this control, the assertion after the throw cannot tell a released pin from a
        // dangling one — it would pass against a checkpoint nothing was ever able to block.
        #expect(busyWhilePinned == 1, "control: a held pin must block a TRUNCATE checkpoint")

        struct Boom: Error {}
        #expect(throws: Boom.self) {
            _ = try SQLiteReader.withReadSnapshotPinned(url.path) { throw Boom() }
        }

        // The teardown ran: a pin left dangling would hold a read transaction on a connection
        // nobody owns, and this checkpoint would report busy and leave the WAL in place.
        let after = try #require(truncatingCheckpoint(url.path))
        #expect(after.busy == 0, "the pin was not released on the throwing path")
        #expect(after.framesLeft == 0, "a completed TRUNCATE checkpoint empties the WAL")
    }

    /// `PRAGMA wal_checkpoint(TRUNCATE)` on a connection of its own: `busy` is 1 when a reader
    /// held it back, and `framesLeft` is how many WAL frames remain (0 once it truncated).
    /// `nil` only if the store could not be opened or the pragma did not answer at all.
    private func truncatingCheckpoint(_ path: String) -> (busy: Int32, framesLeft: Int32)? {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        // Bounded, and short: this must report `busy` rather than wait out a pin that is
        // deliberately being held while the checkpoint runs.
        sqlite3_busy_timeout(db, 200)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA wal_checkpoint(TRUNCATE)", -1,
                                 &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return (sqlite3_column_int(statement, 0), sqlite3_column_int(statement, 1))
    }

    @Test("a snapshot session whose directory cannot be created reports the failure")
    func sessionSurfacesADirectoryCreationFailure() throws {
        let base = try scratch.directory()
        // Pre-create the snapshots root at the mode `OwnedTempDir` demands, then make it
        // immutable so the per-process session directory inside it cannot be created. This is a
        // private session (`installsExitHook: false`), so it never touches the process-global
        // signal registry or the shared session other suites are using.
        let root = base.appendingPathComponent("apple-cli-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        #expect(chflags(root.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(root.path, 0) }

        let session = SQLiteReader.SnapshotSession()
        #expect(throws: (any Error).self) { _ = try session.directory(base: base) }
    }

    // Session lifecycle (0700, locked, single-flight, idempotent `remove()`) and the reaper's
    // predicate (live vs dead owner, self, unclaimed-young vs unclaimed-old, foreign entries) are
    // `SnapshotLifetimeTests`. Restating them here was strictly weaker: that suite drives a real
    // second PROCESS for the live/dead owner distinction, and additionally covers the symlink
    // case — a link shaped like a session directory must be neither followed nor removed — which
    // the version here dropped, and which is the assertion that catches an `lstat` → `stat`
    // mutation. What is left below is the boundary that suite does not cover.

    @Test("reaping a root that does not exist is zero rather than a throw")
    func reapMissingRoot() throws {
        let missing = try scratch.directory().appendingPathComponent("absent", isDirectory: true)
        #expect(SQLiteReader.reapDeadSessions(in: missing) == 0)
    }
}
