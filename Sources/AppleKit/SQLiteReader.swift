import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Read-only, WAL-aware SQLite reader shared by domains that read Apple's local stores
/// (Messages `chat.db`, Mail Envelope Index, Notes `NoteStore.sqlite`). Opens read-only;
/// callers MUST use parameter binds (never string-interpolated SQL). `copyToTemp` snapshots
/// the DB (+ `-wal`/`-shm`) to a temp file first — prefer it for hot/locked stores.
public final class SQLiteReader {
    public enum DBError: Error, CustomStringConvertible {
        case open(String), prepare(String), step(String)
        public var description: String {
            switch self {
            case .open(let m): return "sqlite open failed: \(m)"
            case .prepare(let m): return "sqlite prepare failed: \(m)"
            case .step(let m): return "sqlite step failed: \(m)"
            }
        }
    }

    private var db: OpaquePointer?
    /// The snapshot this reader opened, if any. Internal rather than private so a test can assert
    /// on ITS OWN file: the alternative is diffing the shared session directory, which races a
    /// parallel suite whose reader deinits between the listing and the stat — observed as a 1-in-12
    /// flake before this was exposed.
    let tempURL: URL?

    public init(path: String, copyToTemp: Bool = false) throws {
        var openPath = path
        var temp: URL?
        if copyToTemp {
            // Everything this process writes goes inside its OWN locked directory, which is removed
            // wholesale at exit. Nothing here needs tracking, stamping, or naming carefully: a
            // partially-copied file, a sidecar, a file we never got to open — all of it lives under
            // the one directory and dies with it.
            let dest = try SnapshotSession.shared.newSnapshotURL()
            try FileManager.default.copyItem(atPath: path, toPath: dest.path)
            SQLiteReader.restrictToOwner(dest)
            for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
                try? FileManager.default.copyItem(atPath: path + suffix, toPath: dest.path + suffix)
                SQLiteReader.restrictToOwner(URL(fileURLWithPath: dest.path + suffix))
            }
            openPath = dest.path
            temp = dest
        }
        self.tempURL = temp

        // Open mode depends on whether we copied first:
        // • copyToTemp — the snapshot is a PRIVATE file with its `-wal`/`-shm` copied alongside,
        //   so a plain read-only open applies the WAL and yields the freshest state.
        // • direct (live store) — open with `immutable=1` (URI). The live store is held open by
        //   its app (Messages/…); `immutable=1` ASSERTS to SQLite that the file won't change under
        //   us, so it SKIPS locking and the `-wal`/`-shm` bookkeeping a read-only connection can't
        //   perform — turning "database is locked" / "unable to open database file" into a clean
        //   read. Trade-offs, both consciously accepted: (a) it reads the main DB file as-is and may
        //   miss the newest un-checkpointed WAL writes; (b) per SQLite's immutable contract the file
        //   CAN in fact change (the app may checkpoint mid-read), so a torn read / `SQLITE_CORRUPT`
        //   is possible. Tolerated because the ONLY direct callers are best-effort `try?` reads
        //   (AddressBook sender-name resolution, ChatDB diagnostics) that degrade to empty/nil;
        //   every correctness-critical read passes `copyToTemp: true` (snapshot + WAL, freshest).
        let (openArg, openFlags): (String, Int32)
        if temp != nil {
            (openArg, openFlags) = (openPath, SQLITE_OPEN_READONLY)
        } else {
            (openArg, openFlags) = (SQLiteReader.immutableURI(forPath: openPath),
                                    SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(openArg, &handle, openFlags, nil) == SQLITE_OK, let opened = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open \(openPath)"
            sqlite3_close(handle)
            if let temp { SQLiteReader.removeTempDB(temp) }
            throw DBError.open(msg)
        }
        self.db = opened
    }

    /// Build a `file:` URI with `?immutable=1` for a direct open. The path is percent-encoded so
    /// spaces (e.g. "Application Support") and other reserved characters survive SQLite's URI
    /// parser; `/` is preserved as the path separator. A non-absolute path is returned unchanged
    /// (falls back to a plain filename open) rather than producing a malformed URI.
    static func immutableURI(forPath path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "/-._~")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return "file:" + encoded + "?immutable=1"
    }

    deinit {
        if let db { sqlite3_close(db) }
        // Best-effort prompt reclaim for a reader that IS released normally; the session directory
        // removal at exit is what actually guarantees it.
        if let tempURL { SQLiteReader.removeTempDB(tempURL) }
    }

    // MARK: - Snapshot lifetime
    //
    // `copyToTemp` snapshots the Envelope Index / chat.db / NoteStore so reads see a consistent,
    // WAL-applied view. `deinit` deleted the snapshot and essentially never ran: ArgumentParser
    // ends a command with `exit()`, which tears the process down without releasing the reader.
    // Measured before this change: >150 snapshot files totalling multiple GB, mode 0644 — real subjects,
    // senders and recipients left in `$TMPDIR` indefinitely.
    //
    // THE MODEL: each process owns ONE directory, holds an `flock` on a `.lock` inside it for its
    // whole life, and removes the directory at exit. Anything a crash strands is collected by the
    // next run, which asks the kernel — not a clock — whether the owner is still alive.
    //
    // WHY LIVENESS AND NOT AGE. Three designs were tried and measured to fail before this one; the
    // full write-up is in docs/COMPLETION-LOOP.md Q4d. Two were about deleting the file early:
    //   * Unlink right after `sqlite3_open_v2`. The read-only open needs the copied `-wal`, which
    //     SQLite opens LAZILY → first query dies with `disk I/O error`.
    //   * Checkpoint the copy, open `immutable=1`, unlink immediately. `wal_checkpoint(TRUNCATE)`
    //     does fold the WAL in and a warm read succeeds, but SQLite keeps faulting pages in from
    //     the file as later queries touch them, so `sqlite3_step` fails once it is gone. (A Python
    //     probe suggested otherwise only because `sqlite3.connect()` reads eagerly where
    //     `sqlite3_open_v2` does not — it was measuring something this code does not do.)
    // The third shipped and was REVERTED: collect orphans by mtime. `copyItem` preserves the
    // source's mtime, so a snapshot of a store idle for an hour was born already past the
    // threshold and a concurrent `apple` deleted a LIVE reader's files. Stamping the copy fresh
    // repairs that specific case but not the predicate: age only ever ESTIMATES whether an owner
    // is still there, so every threshold trades "reap a live reader" against "keep orphans", and a
    // laptop asleep mid-command re-opens the same hole from a different direction.
    // `flock(LOCK_EX|LOCK_NB)` answers exactly the question age was guessing at, and the kernel
    // releases it on ANY death including SIGKILL. Measured (scratchpad/flockcheck.swift): owner
    // alive → EWOULDBLOCK (skip); owner SIGKILLed → ACQUIRED (reap); a second `flock` from the
    // SAME process → EWOULDBLOCK, so a process can never reap itself even by accident.
    //
    // KNOWN AND ACCEPTED: `atexit` does not run on SIGKILL, so a hard-killed process leaves its
    // directory until the next `apple` run reaps it (0600 files inside a 0700 directory in the
    // meantime, and macOS ages `/var/folders/*/T` out daily as a further backstop).

    /// The parent directory all per-process session directories live in, created 0700.
    ///
    /// `base` exists so tests exercise creation in a directory they own — asserting the mode of the
    /// real shared one passes when the code is wrong (it is create-time only, so a pre-existing
    /// directory keeps whatever mode it has) and fails when the code is right (any stray `chmod`).
    static func snapshotsRoot(base: URL? = nil) throws -> URL {
        try OwnedTempDir.make("apple-cli-snapshots", base: base)
    }

    /// 0600 on a snapshot. Defense in depth only — the enclosing directory is already 0700 — so
    /// unlike the reverted age-based design nothing about correctness rides on this succeeding.
    static func restrictToOwner(_ url: URL) { OwnedTempDir.restrictToOwner(url) }

    /// This process's snapshot directory: created on first use, `flock`ed for the process lifetime,
    /// removed at `exit()` — the path `deinit` misses.
    final class SnapshotSession: @unchecked Sendable {
        static let shared = SnapshotSession(installsExitHook: true)
        private let lock = NSLock()
        private var dir: URL?
        private var lockFD: Int32 = -1
        private let installsExitHook: Bool

        /// Only the shared instance installs the process-wide `atexit` hook and reaps. A test builds
        /// its own session so `remove()` can never reach the live snapshots of a suite running
        /// alongside it — swift-testing runs every suite in one process, and an earlier version of
        /// this test suite really did delete another suite's files that way.
        init(installsExitHook: Bool = false) { self.installsExitHook = installsExitHook }

        /// The locked directory, created on first call.
        func directory(base: URL? = nil) throws -> URL {
            lock.lock()
            if let dir { lock.unlock(); return dir }
            lock.unlock()

            let root = try SQLiteReader.snapshotsRoot(base: base)
            let mine = root.appendingPathComponent("s-\(getpid())-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // Take the liveness lock BEFORE the directory is usable, so a reaper can never see a
            // populated directory that is not yet claimed.
            let fd = open(mine.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
            if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd) ; throw DBError.open("could not lock snapshot directory") }
            guard fd >= 0 else { throw DBError.open("could not create snapshot lock in \(mine.path)") }

            lock.lock()
            if let existing = dir {          // another thread won the race; keep theirs, drop ours
                lock.unlock()
                close(fd)
                try? FileManager.default.removeItem(at: mine)
                return existing
            }
            dir = mine; lockFD = fd
            let hook = installsExitHook
            lock.unlock()

            if hook {
                atexit { SnapshotSession.shared.remove() }
                // Collect what earlier crashed runs left behind. Once per process, after our own
                // directory is locked, so it is skipped by name as well as by lock.
                SQLiteReader.reapDeadSessions(in: root, skipping: mine)
            }
            return mine
        }

        func newSnapshotURL(base: URL? = nil) throws -> URL {
            try directory(base: base).appendingPathComponent("\(UUID().uuidString).sqlite")
        }

        /// Drop the whole directory. Idempotent; safe to call from `atexit`.
        func remove() {
            lock.lock(); let mine = dir; let fd = lockFD; dir = nil; lockFD = -1; lock.unlock()
            guard let mine else { return }
            try? FileManager.default.removeItem(at: mine)
            if fd >= 0 { close(fd) }         // after the unlink: the lock guards the directory's life
        }
    }

    /// Remove session directories whose owning process is gone, returning how many were removed.
    ///
    /// The predicate is the kernel's, not a clock's: if `flock(LOCK_EX|LOCK_NB)` succeeds the owner
    /// no longer exists, because the kernel releases the lock on any process death. A live owner
    /// yields `EWOULDBLOCK` and is skipped — including this process, which cannot acquire its own
    /// lock a second time even from a fresh descriptor.
    ///
    /// Internal rather than public: it defaults to a real directory and deletes. Tests reach it
    /// through `@testable`.
    @discardableResult
    static func reapDeadSessions(in root: URL, skipping: URL? = nil,
                                 unclaimedGrace: TimeInterval = 3600, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return 0 }
        var reaped = 0
        for name in names where name.hasPrefix("s-") {
            let entry = root.appendingPathComponent(name, isDirectory: true)
            if let skipping, entry.standardizedFileURL == skipping.standardizedFileURL { continue }
            var st = stat()
            // `lstat`, and a directory: never follow a symlink out of the tree, and never recurse
            // into something that only looks like a session.
            guard lstat(entry.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }

            let lockPath = entry.appendingPathComponent(".lock").path
            if !fm.fileExists(atPath: lockPath) {
                // Created but killed before it could lock. Nothing can ever claim it, so fall back
                // to age — this is the one place a clock is still involved, and it guards a
                // directory that by construction holds no successfully-opened snapshot.
                let attrs = try? fm.attributesOfItem(atPath: entry.path)
                guard let m = attrs?[.modificationDate] as? Date,
                      now.timeIntervalSince(m) > unclaimedGrace else { continue }
                if (try? fm.removeItem(at: entry)) != nil { reaped += 1 }
                continue
            }

            let fd = open(lockPath, O_RDWR)
            guard fd >= 0 else { continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                if (try? fm.removeItem(at: entry)) != nil { reaped += 1 }
            }
            close(fd)                        // releases the lock if we took it
        }
        return reaped
    }

    /// Remove a temp DB copy AND its `-wal`/`-shm` sidecars. `copyToTemp` snapshots
    /// all three, but a read-only connection can't checkpoint the WAL on close, so
    /// deleting only the main file would orphan the (potentially large) sidecars on
    /// every invocation.
    private static func removeTempDB(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    /// Run a parameter-bound query. `binds` bind as positional text params (?1, ?2, …).
    /// Rows come back as `[columnName: value?]` (text; callers convert types).
    @discardableResult
    public func query(_ sql: String, _ binds: [String] = []) throws -> [[String: String?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), value, -1, SQLITE_TRANSIENT)
        }
        let columnCount = Int(sqlite3_column_count(stmt))
        var rows: [[String: String?]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DBError.step(String(cString: sqlite3_errmsg(db))) }
            var row: [String: String?] = [:]
            for column in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(stmt, Int32(column)))
                if let text = sqlite3_column_text(stmt, Int32(column)) {
                    row[name] = String(cString: text)
                } else {
                    row[name] = String?.none
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// A typed row that preserves column type — crucially exposing BLOB columns as
    /// `Data`. The text-only `query(_:_:)` above routes every column through
    /// `String(cString:)`, which truncates a BLOB at its first NUL byte; that makes
    /// it unusable for binary columns (Messages `attributedBody`, Notes protobuf,
    /// Mail data blobs). This ADDITIVE method leaves `query` untouched for existing
    /// callers. Binds are still positional TEXT params (?1, ?2, …), matching `query`.
    public struct Row {
        public let values: [String: Value]
        public enum Value: Equatable {
            case null, integer(Int64), real(Double), text(String), blob(Data)
        }
        public init(values: [String: Value]) { self.values = values }

        /// Text accessor — also stringifies INTEGER/REAL so numeric columns read
        /// the same as they did under the text-only `query`.
        public func text(_ column: String) -> String? {
            switch values[column] {
            case .text(let s)?: return s
            case .integer(let i)?: return String(i)
            case .real(let d)?: return String(d)
            default: return nil
            }
        }
        public func int(_ column: String) -> Int64? {
            switch values[column] {
            case .integer(let i)?: return i
            case .real(let d)?: return Int64(d)
            case .text(let s)?: return Int64(s)
            default: return nil
            }
        }
        public func data(_ column: String) -> Data? {
            if case .blob(let d)? = values[column] { return d }
            return nil
        }
    }

    @discardableResult
    public func rows(_ sql: String, _ binds: [String] = []) throws -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), value, -1, SQLITE_TRANSIENT)
        }
        let columnCount = Int(sqlite3_column_count(stmt))
        var out: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DBError.step(String(cString: sqlite3_errmsg(db))) }
            var values: [String: Row.Value] = [:]
            for column in 0..<columnCount {
                let col = Int32(column)
                let name = String(cString: sqlite3_column_name(stmt, col))
                switch sqlite3_column_type(stmt, col) {
                case SQLITE_INTEGER: values[name] = .integer(sqlite3_column_int64(stmt, col))
                case SQLITE_FLOAT:   values[name] = .real(sqlite3_column_double(stmt, col))
                case SQLITE_TEXT:
                    if let t = sqlite3_column_text(stmt, col) { values[name] = .text(String(cString: t)) }
                    else { values[name] = .null }
                case SQLITE_BLOB:
                    if let b = sqlite3_column_blob(stmt, col) {
                        values[name] = .blob(Data(bytes: b, count: Int(sqlite3_column_bytes(stmt, col))))
                    } else { values[name] = .null }
                default: values[name] = .null
                }
            }
            out.append(Row(values: values))
        }
        return out
    }
}
