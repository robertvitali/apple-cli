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

    /// How a DIRECT (non-copied) open treats the live store's `-wal`.
    public enum DirectOpenMode {
        /// `immutable=1` — skips locking and WAL bookkeeping. Cheap and lock-error-proof, but
        /// reads the main DB file as-is and MISSES un-checkpointed WAL writes.
        case immutable
        /// `mode=ro` — a normal read-only connection that APPLIES the `-wal`, so it sees exactly
        /// what the (WAL-aware) oracle sees. Costs the locking the `immutable` mode avoids.
        case walAware
    }

    public init(path: String, copyToTemp: Bool = false,
                directOpen: DirectOpenMode = .immutable) throws {
        var openPath = path
        var temp: URL?
        var diagnostics: SnapshotDiagnostics?
        if copyToTemp {
            // Everything this process writes goes inside its OWN locked directory, which is removed
            // wholesale at exit. Nothing here needs tracking, stamping, or naming carefully: a
            // partially-copied file, a sidecar, a file we never got to open — all of it lives under
            // the one directory and dies with it.
            let dest = try SnapshotSession.shared.newSnapshotURL()
            diagnostics = try SQLiteReader.copyCoherentSnapshot(from: path, to: dest)
            openPath = dest.path
            temp = dest
        }
        self.tempURL = temp
        self.snapshotDiagnostics = diagnostics

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
        //   is possible. Tolerated because the direct callers are best-effort reads that degrade
        //   rather than fail, and every correctness-critical read passes `copyToTemp: true`.
        //   NOTE (Q6/MSG-3): `immutable` is no longer the only direct mode. AddressBook now asks
        //   for `.walAware` FIRST — its per-source counts must match the WAL-aware oracle — and
        //   falls back to `.immutable` on failure, so the justification above now describes the
        //   FALLBACK, not the only path.
        let (openArg, openFlags): (String, Int32)
        if temp != nil {
            (openArg, openFlags) = (openPath, SQLITE_OPEN_READONLY)
        } else {
            switch directOpen {
            case .immutable:
                (openArg, openFlags) = (SQLiteReader.immutableURI(forPath: openPath),
                                        SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
            case .walAware:
                (openArg, openFlags) = (SQLiteReader.readOnlyURI(forPath: openPath),
                                        SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
            }
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

    /// What a snapshot attempt observed. Observability, not decoration: the pin and the
    /// verification are otherwise invisible, so both could be deleted from `init` with every test
    /// still green — a reviewer demonstrated exactly that, and it was the largest gap in this change.
    ///
    /// Carried PER READER, never in a global. The first version was a mutable static, which
    /// swift-testing's parallel suites promptly raced: another suite's reader overwrote it between
    /// this one's `init` and its assertion, giving a 2-in-12 flake. Shared mutable state for test
    /// observability is the same mistake this change set has already paid for three times.
    struct SnapshotDiagnostics: Sendable {
        var pinned = false
        var verified = false
        var retries = 0
    }

    /// Set when this reader took a `copyToTemp` snapshot; nil for a direct open.
    let snapshotDiagnostics: SnapshotDiagnostics?

    /// Copy `src` (+ its `-wal`) to `dest` so the two belong to the SAME generation.
    ///
    /// Two independent mechanisms, deliberately layered — and the order of trust matters:
    ///
    /// 1. **VERIFY (the guarantee).** The `-wal` header's salt-1/salt-2 at bytes 16..32 change
    ///    whenever the WAL is reset. Reading them before the main-file copy and again after the
    ///    `-wal` copy detects the exact failure this whole routine exists to prevent — a main file
    ///    paired with a foreign-generation WAL — for two 32-byte reads, depending on zero SQLite
    ///    internals and surviving any future SQLite. On mismatch the snapshot is discarded and
    ///    retried once; the pin's argument says at most one reset can occur, so one retry converges.
    /// 2. **PIN (an optimization).** `withReadSnapshotPinned` makes the mismatch vanishingly rare in
    ///    the first place. Its reasoning rests on SQLite WAL internals, which is precisely why it is
    ///    NOT the guarantee: a reviewer already falsified the first version of that reasoning.
    ///
    /// WHY VERIFY AT ALL, given the window is tiny. The failure is asymmetric. If this is wrong the
    /// dominant outcome is not a crash — WAL recovery validates the salt against the WAL's own
    /// frames, never against the main file, so a foreign WAL is ACCEPTED and the command returns a
    /// silently wrong answer. For a tool whose premise is strict-superset parity, silent-wrong is
    /// the worst failure class available, and it is not something to trade for latency.
    @discardableResult
    static func copyCoherentSnapshot(from src: String, to dest: URL) throws -> SnapshotDiagnostics {
        var diag = SnapshotDiagnostics()
        for attempt in 0...1 {
            let before = SQLiteReader.walSalt(src)
            diag.pinned = try SQLiteReader.withReadSnapshotPinned(src) {
                try FileManager.default.copyItem(atPath: src, toPath: dest.path)
                SQLiteReader.restrictToOwner(dest)
                // `-wal` only. Copying `-shm` was measured INERT — a current one, a deliberately
                // stale one, and none at all yield identical correct reads, because SQLite rebuilds
                // the wal-index from the `-wal`. Omitting it removes one more way for the snapshot
                // to disagree with itself. (It is not a privacy win: a `-shm` holds no mail, and
                // SQLite creates one in the snapshot directory on first read anyway.)
                let wal = src + "-wal"
                if FileManager.default.fileExists(atPath: wal) {
                    try? FileManager.default.copyItem(atPath: wal, toPath: dest.path + "-wal")
                    SQLiteReader.restrictToOwner(URL(fileURLWithPath: dest.path + "-wal"))
                }
            }
            let after = SQLiteReader.walSalt(src)
            if before == after { diag.verified = true; return diag }

            // The WAL was reset inside the window. Throw this snapshot away and take another.
            diag.retries = attempt + 1
            SQLiteReader.removeTempDB(dest)
            if attempt == 1 {
                throw DBError.open("could not take a coherent snapshot of \(src): the write-ahead "
                                   + "log was reset twice while copying")
            }
        }
        return diag
    }

    /// Salt-1/salt-2 from the `-wal` header (bytes 16..32), or nil when there is no WAL.
    /// SQLite rewrites these on every WAL reset, which is exactly the event worth detecting.
    static func walSalt(_ src: String) -> Data? {
        guard let fh = FileHandle(forReadingAtPath: src + "-wal") else { return nil }
        defer { try? fh.close() }
        try? fh.seek(toOffset: 16)
        return try? fh.read(upToCount: 16)
    }

    /// Run `body` while holding a read transaction on the live store at `path`.
    ///
    /// THE COHERENCE STEP. `copyToTemp` copies the main DB and its `-wal` at two different instants.
    /// SQLite is explicit that a file-level copy of a live database can be inconsistent or corrupt,
    /// and the interleaving that does it here is a checkpoint RESETTING the WAL between those two
    /// copies: we would pair a pre-checkpoint main file with a post-reset WAL of a different
    /// generation, and the outcomes run from a silently stale read to `SQLITE_CORRUPT`.
    ///
    /// WHY A READ MARK CLOSES IT — via one of TWO locks, depending on the state at pin time. The
    /// first draft of this comment claimed only the first of them and was measurably wrong; a
    /// reviewer reproduced a `TRUNCATE` checkpoint succeeding while pinned, so the distinction is
    /// recorded here rather than rediscovered:
    ///   * **WAL has un-backfilled frames** (the common case): our reader occupies read-mark slot
    ///     1..N-1, and `RESTART`/`TRUNCATE` require that slot exclusively, so the reset is blocked
    ///     outright.
    ///   * **WAL already fully backfilled at pin time**: SQLite puts the reader in slot 0, which
    ///     the restart path does not contend, so ONE reset is permitted. That is harmless — in that
    ///     state the main file already contains every frame, so a main-file copy needs nothing from
    ///     the WAL. A *second* reset would hurt, and cannot happen: getting back to
    ///     `nBackfill == mxFrame` requires backfilling, and the checkpointer must take read-lock 0
    ///     exclusively to backfill at all, which our shared slot-0 lock denies.
    /// Either way: **the WAL can never be reset while our main-file copy still depends on it.** A
    /// PASSIVE checkpoint may still backfill frames at or below our mark, which is harmless because
    /// those frames remain in the un-reset WAL we copy.
    ///
    /// COST, measured on a real few-hundred-MB Envelope Index and chat.db: warm
    /// end-to-end A/B showed no measurable difference (42 vs 41 ms, 63 vs 63 ms). The coherent
    /// alternatives were measured and rejected on that basis: `sqlite3_backup` +
    /// `journal_mode=DELETE` costs 337/493 ms and `VACUUM INTO` costs 692/747 ms, either of which
    /// would make every snapshot-backed command 13–26x slower. (Raw `sqlite3_backup` output is also
    /// unreadable by our read-only open: it inherits WAL mode and a read-only connection cannot
    /// create the `-shm`.)
    ///
    /// SIDE-EFFECT GATE: this is the only place the tool opens a LIVE store with a real connection,
    /// and such an open CREATES a `-shm` next to the store if none exists — inside the operator's
    /// `~/Library/Mail/`, where a read-only connection cannot remove it again. So the pin is taken
    /// ONLY when a `-shm` is already present, which means the owning app has the store mapped and
    /// we are merely attaching. With no `-shm` there is also no concurrent writer to race, so
    /// skipping the pin costs nothing. Stated precisely, because the weaker claim is tempting and
    /// wrong: the gate prevents CREATING a `-shm`, it does not make us read-only towards the store.
    /// Attaching takes a read-mark slot and may run wal-index recovery, and both MODIFY the
    /// existing `-shm` — that one file, and nothing else.
    ///
    /// COST UNDER CONTENTION, which is the only state where the pin does anything and which the
    /// warm A/B above does NOT cover: measured against a writer inserting continuously and
    /// TRUNCATE-checkpointing every 200 rows, 40 snapshots ran at median 0.3 ms, p90 0.5 ms, max
    /// 0.7 ms. The 500 ms busy timeout never bit.
    ///
    /// BEST EFFORT: on any failure to pin, `body` still runs unpinned, exactly as before. This step
    /// can only improve coherence, never turn a working read into a failure.
    @discardableResult
    static func withReadSnapshotPinned(_ path: String, _ body: () throws -> Void) rethrows -> Bool {
        guard FileManager.default.fileExists(atPath: path + "-shm") else {
            try body()                      // no live writer to race; do not create a -shm
            return false
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            try body()
            return false
        }
        // `close_v2` rather than `close`: `close` REFUSES to close while a statement or transaction
        // is outstanding and returns SQLITE_BUSY, which would leak the connection with its read mark
        // still held. `close_v2` always releases.
        defer { sqlite3_exec(db, "COMMIT", nil, nil, nil); sqlite3_close_v2(db) }

        // The default busy timeout is 0, and `walTryBeginRead` can legitimately return SQLITE_BUSY
        // while the wal-index header is unstable — precisely when a writer is active, which is
        // exactly when the pin matters. Without this the pin silently did not happen.
        sqlite3_busy_timeout(db, 500)

        var pinned = false
        if sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK {
            // BEGIN alone is DEFERRED and takes no lock; the read mark is acquired only once a
            // statement actually reads. This SELECT is load-bearing — removing it is red-proofed to
            // fail the WAL-reset test.
            var st: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master LIMIT 1", -1, &st, nil) == SQLITE_OK {
                let rc = sqlite3_step(st)
                pinned = (rc == SQLITE_ROW || rc == SQLITE_DONE)
            }
            sqlite3_finalize(st)
        }
        try body()
        return pinned
    }

    /// Build a `file:` URI carrying `query` for a direct open. The path is percent-encoded so
    /// spaces (e.g. "Application Support") and other reserved characters survive SQLite's URI
    /// parser; `/` is preserved as the path separator. A non-absolute path is returned unchanged
    /// (falls back to a plain filename open) rather than producing a malformed URI.
    ///
    /// The query is a PARAMETER rather than a string substitution on a built URI. An earlier
    /// version derived the `mode=ro` form by replacing "immutable=1" in the immutable URI, which
    /// had two failure modes: a non-absolute path containing the literal "immutable=1" would be
    /// silently rewritten into a DIFFERENT filename, and any change to the URI's shape would make
    /// the replace a no-op — silently reverting `.walAware` to `immutable=1` and reinstating the
    /// stale-read bug this exists to fix, with nothing failing.
    private static func uri(forPath path: String, query: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "/-._~")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return "file:" + encoded + "?" + query
    }

    /// `immutable=1` — skips locking and WAL bookkeeping; may read stale (pre-checkpoint) data.
    static func immutableURI(forPath path: String) -> String {
        uri(forPath: path, query: "immutable=1")
    }

    /// `mode=ro` — read-only but WAL-aware, unlike `immutable=1`.
    static func readOnlyURI(forPath path: String) -> String {
        uri(forPath: path, query: "mode=ro")
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
        ///
        /// Single-flight under `lock` for the whole create-and-arm sequence. Holding the lock across
        /// the `mkdir` costs nothing here (a CLI creates this once) and it buys the invariant the
        /// arm-before-create ordering below depends on: exactly ONE path is ever armed. The earlier
        /// unlock-during-mkdir shape let a losing thread arm a directory it then discarded, which
        /// would leave the winner's directory — the one with the operator's mail in it — unarmed.
        func directory(base: URL? = nil) throws -> URL {
            let (mine, root, isNew) = try createLocked(base: base)
            // The reap runs OUTSIDE the session lock, deliberately. It is the slowest thing in this
            // lifecycle — a directory listing plus per-entry lstat/open/flock/removeItem — and the
            // `atexit` hook registered below calls `remove()`, which takes this same lock. A thread
            // calling `exit()` while another sat inside a lock-held reap would deadlock at exit.
            // Unreachable today (readers are main-thread only), but the arm-before-create invariant
            // only needs the lock from the `if let dir` check through `dir = mine`, so holding it
            // any longer buys nothing and costs that hazard. Raised by review as N-H.
            if isNew, installsExitHook {
                SQLiteReader.reapDeadSessions(in: root, skipping: mine)
            }
            return mine
        }

        /// The part that must be single-flight: everything from the existence check through
        /// publishing `dir`. Returns `isNew == false` when another caller already won.
        private func createLocked(base: URL?) throws -> (mine: URL, root: URL, isNew: Bool) {
            lock.lock()
            defer { lock.unlock() }
            if let dir { return (dir, dir.deletingLastPathComponent(), false) }

            let root = try SQLiteReader.snapshotsRoot(base: base)
            let mine = root.appendingPathComponent("s-\(getpid())-\(UUID().uuidString)", isDirectory: true)

            // ARM BEFORE THE DIRECTORY EXISTS. Arming afterwards leaves a window in which the
            // directory is on disk with no handler installed, and that window is not theoretical:
            // review reproduced it 6/6 by signalling the instant the directory became visible. An
            // earlier bash-shaped measurement of mine reported it clean only because polling with
            // `find | wc | tr` is far too slow to land inside it. `unlink`/`rmdir` on a path that
            // was never created is a harmless ENOENT, so arming early costs nothing.
            var armedAtCount: Int32 = 0
            if installsExitHook {
                armedAtCount = SignalSafeCleanup.arm(directory: mine,
                                                     lockFile: mine.appendingPathComponent(".lock"))
            }

            // If setting the directory up fails, UNDO the arm. `arm` is one-shot, so leaving it
            // armed for a directory that never came into being would pin the registry to a dead
            // path: a later reader in the same process gets a fresh UUID directory, `arm` returns
            // early, and that second directory — the one that actually holds mail — is never
            // `rmdir`d on a signal. Narrow in a CLI, much less so in a test process opening
            // hundreds of readers. Raised by review as N1.
            func undoArmOnFailure<T>(_ body: () throws -> T) throws -> T {
                do { return try body() } catch {
                    if installsExitHook { SignalSafeCleanup.disarmForRetry(armedAtCount: armedAtCount) }
                    throw error
                }
            }

            try undoArmOnFailure {
                try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            // Take the liveness lock BEFORE the directory is usable, so a reaper can never see a
            // populated directory that is not yet claimed.
            let fd = open(mine.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
            if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) != 0 {
                close(fd)
                if installsExitHook { SignalSafeCleanup.disarmForRetry(armedAtCount: armedAtCount) }
                throw DBError.open("could not lock snapshot directory")
            }
            guard fd >= 0 else {
                if installsExitHook { SignalSafeCleanup.disarmForRetry(armedAtCount: armedAtCount) }
                throw DBError.open("could not create snapshot lock in \(mine.path)")
            }

            dir = mine; lockFD = fd

            // Collecting what earlier crashed runs left behind happens in `directory()` — once per
            // process, after our own directory is locked so it is skipped by name as well as by
            // lock, and outside this lock for the reason recorded there.
            if installsExitHook { atexit { SnapshotSession.shared.remove() } }
            return (mine, root, true)
        }

        func newSnapshotURL(base: URL? = nil) throws -> URL {
            let url = try directory(base: base).appendingPathComponent("\(UUID().uuidString).sqlite")
            // Pre-render now, while allocation is still legal. A signal handler may not malloc, so
            // the paths it will unlink have to exist as C strings before the signal arrives. The
            // sidecars are included because SQLite creates a `-shm` (and may create a `-wal`) in the
            // snapshot directory on first read — files we never wrote but must still remove.
            //
            // Gated on the session's OWN flag, matching `arm`. Only the shared session arms, so a
            // test-owned session's paths must not enter the process-global set the handler walks —
            // the handler would unlink files in a directory it is not going to remove, breaking the
            // isolation invariant documented on `init` above. Relying on "the registry is nil for a
            // private session" is NOT enough: in a test process the shared session has usually armed
            // already, so the private paths would be recorded after all.
            guard installsExitHook else { return url }
            SignalSafeCleanup.track(url.path)
            for suffix in ["-wal", "-shm"] { SignalSafeCleanup.track(url.path + suffix) }
            return url
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
