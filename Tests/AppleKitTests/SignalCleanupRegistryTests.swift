import Testing
import Foundation
import SQLite3
import TestSupport
@testable import AppleKit

/// The signal-teardown registry (COMPLETION-LOOP Q4i).
///
/// Whether a handler runs on a real SIGINT can only be shown in a real process dying of a real
/// signal, and that lives in `bats/smoke.bats`. But the bug that actually bit did NOT need a signal
/// to find: `.lock` was missing from the tracked set, so the handler fired exactly as designed,
/// `rmdir` refused a non-empty directory, and the session survived anyway. That is a completeness
/// property of a data structure, and this is where it belongs — review pointed out there was zero
/// logic-tier coverage of any of it, so "635 tests green" was evidence about other code.
@Suite("Signal-cleanup registry")
struct SignalCleanupRegistryTests {

    private let scratch = ScratchDirs("sigreg")

    /// A tiny on-disk SQLite database for a reader to snapshot.
    func sourceDatabase() throws -> URL {
        let url = try scratch.directory().appendingPathComponent("src.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE t(x); INSERT INTO t VALUES(1)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        return url
    }

    @Test("every file a live session directory holds is in the set the handler will remove")
    func trackedSetCoversTheDirectory() throws {
        let reader = try SQLiteReader(path: try sourceDatabase().path, copyToTemp: true)
        _ = try reader.query("SELECT COUNT(*) AS n FROM t")     // force the -shm/-wal sidecars
        let dir = try SQLiteReader.SnapshotSession.shared.directory()

        // Listing FIRST, tracked set SECOND. Other suites share this session directory, and a file
        // that appears between the two reads is one that was tracked before it was created — so
        // this ordering cannot produce a false failure, while the reverse could.
        let present = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let tracked = Set(SignalSafeCleanup.trackedPaths)

        // Positive controls. Without these the assertion below passes on an empty directory, which
        // is precisely the vacuous shape this change set has already shipped once.
        #expect(present.contains(".lock"), "control: the session is claimed")
        #expect(present.contains { $0.hasSuffix(".sqlite") }, "control: a snapshot really landed")
        #expect(!tracked.isEmpty, "control: the shared session armed and tracked something")

        let untracked = present.filter { !tracked.contains(dir.appendingPathComponent($0).path) }
        #expect(untracked.isEmpty,
                "these would survive the handler and make `rmdir` fail: \(untracked)")
        withExtendedLifetime(reader) { }
    }

    @Test("the tracked set names files inside the session directory and nothing else")
    func trackedSetStaysInsideTheSession() throws {
        let reader = try SQLiteReader(path: try sourceDatabase().path, copyToTemp: true)
        let dir = try SQLiteReader.SnapshotSession.shared.directory()
        let tracked = SignalSafeCleanup.trackedPaths
        #expect(!tracked.isEmpty, "control")

        // The handler unlinks these paths blind, so every one must sit inside a directory this
        // process owns. That used to mean the snapshot session specifically; since Q4k it means ANY
        // registered root, because Mail registers its own. Asserting the old, narrower invariant
        // would pass today only because no Mail test has materialised a temp yet, and would turn
        // into a flake the day one does.
        let roots = SignalSafeCleanup.registeredRoots
        #expect(roots.contains(dir.path + "/"), "control: the session directory is a root")
        let escaped = tracked.filter { p in !roots.contains(where: { p.hasPrefix($0) }) }
        #expect(escaped.isEmpty, "tracked paths in no owned root: \(escaped)")
        #expect(dir.lastPathComponent.hasPrefix("s-\(getpid())-"))
        withExtendedLifetime(reader) { }
    }

    @Test("the set grows past its initial capacity instead of silently dropping paths")
    func registryGrowsRatherThanSaturating() throws {
        // Found by the completeness test going red 1-in-12 with three untracked `.sqlite` files:
        // the set was a fixed 64 slots, a test process opens hundreds of readers, and everything
        // past the cap was dropped without a word. A dropped path is not cosmetic — it is a file
        // left in the directory, so `rmdir` fails and the session survives the signal after all.
        let armer = try SQLiteReader(path: try sourceDatabase().path, copyToTemp: true)
        let dir = try SQLiteReader.SnapshotSession.shared.directory()

        // Paths inside our own session directory, so the "never escapes the session" invariant that
        // the other tests assert stays true. They are never created on disk; `unlink` on a missing
        // path is a harmless ENOENT, which is the same thing the handler already tolerates.
        let probes = (0..<200).map { dir.appendingPathComponent("growth-probe-\(UUID())-\($0)").path }
        for p in probes { SignalSafeCleanup.track(p) }

        let tracked = Set(SignalSafeCleanup.trackedPaths)
        let missing = probes.filter { !tracked.contains($0) }
        #expect(missing.isEmpty, "\(missing.count)/200 paths past the initial capacity were dropped")
        #expect(tracked.count > 64, "control: we really did push past the initial capacity")
        withExtendedLifetime(armer) { }
    }

    @Test("disarmForRetry refuses when the count has moved since the arm it is undoing")
    func disarmOnlyUndoesItsOwnArm() throws {
        // `disarmForRetry` exists so a session whose directory failed to be created lets the NEXT
        // attempt arm its own. Its guard is the safety-critical half — clearing when the session
        // DID track something drops a live directory's cleanup on the floor.
        //
        // The guard is scoped to the arm being undone, not to `count == 0`. Review found the
        // zero-check defeatable once a second client shares the counter: Mail tracks one file, a
        // snapshot session then fails to create its directory, the guard sees Mail's count and
        // refuses, and `dir` stays pinned to a directory that never existed — leaving the one that
        // really holds the operator's mail neither tracked nor removable.
        let armer = try SQLiteReader(path: try sourceDatabase().path, copyToTemp: true)
        let session = try SQLiteReader.SnapshotSession.shared.directory()
        let before = SignalSafeCleanup.trackedPaths
        #expect(!before.isEmpty, "control: the shared registry is armed and non-empty")
        #expect(SignalSafeCleanup.removableDirectory == session.path, "control: a directory is armed")

        // A count that does not match this arm must be refused, whoever moved it.
        //
        // HONEST LIMIT, measured: this does NOT discriminate the fix. Reverting the guard to the
        // old shared `count == 0` proxy leaves this test green, because with a non-empty registry
        // both versions refuse. The case that separates them — the session tracked nothing while
        // the OTHER client did, so a correct guard clears and the old one wrongly refuses — needs
        // the shared session's removable directory to actually be cleared, and every other suite
        // in this process depends on it. There is no second-registry seam, and adding one would be
        // a worse footgun than the gap. So the scoping fix rests on review plus reasoning, not on
        // a red-proof, and saying so beats a test that looks like coverage and is not.
        SignalSafeCleanup.disarmForRetry(armedAtCount: Int32.max)

        #expect(SignalSafeCleanup.removableDirectory == session.path,
                "a mismatched arm-count must leave the removable directory alone")
        #expect(SignalSafeCleanup.trackedPaths == before,
                "and must not disturb the tracked set")
        withExtendedLifetime(armer) { }

        // KNOWINGLY UNTESTED: the other half — that a FAILED `createDirectory` re-arms on the next
        // attempt — needs a fresh process-global registry, and there is no reset seam by design
        // (one would be a footgun far worse than the gap). Listed rather than left to look covered.
    }

    @Test("a session that installs no handlers contributes nothing to the global set")
    func privateSessionsStayOutOfTheRegistry() throws {
        // Test-owned sessions pass `installsExitHook: false` so `remove()` can never reach a
        // parallel suite's snapshots. The registry has to honour the same boundary: if a private
        // session's paths entered the process-global set, the handler would unlink files belonging
        // to a directory it is not going to remove. `track` is a no-op until `arm` runs, and only
        // the shared session arms — this pins that.
        // ARM THE SHARED SESSION FIRST — this line is what makes the test mean anything. Without it
        // the registry may still be nil when the private session runs, `track` no-ops for an
        // unrelated reason, and the assertion passes while the isolation gate is absent: verified
        // by deleting the gate and watching this test stay green until this line was added.
        let armer = try SQLiteReader(path: try sourceDatabase().path, copyToTemp: true)
        let before = Set(SignalSafeCleanup.trackedPaths)
        #expect(!before.isEmpty, "control: the shared session is armed, so `track` would record")

        let session = SQLiteReader.SnapshotSession(installsExitHook: false)
        let base = try scratch.directory()
        let url = try session.newSnapshotURL(base: base)
        try Data("x".utf8).write(to: url)
        defer { session.remove() }

        let after = Set(SignalSafeCleanup.trackedPaths)
        #expect(!after.contains(url.path), "a private session's path reached the global registry")
        // Deliberately not `before == after`: suites run in parallel in one process, so the shared
        // session may legitimately grow between the two reads. The claim is about THIS path.
        #expect(after.isSuperset(of: before), "the registry only ever grows")
        withExtendedLifetime(armer) { }
    }

    // MARK: Q4k — a second client, whose directory must NEVER be removed

    @Test("a file in a registered root is tracked even though the root is not the session")
    func tracksFilesInOtherOwnedRoots() throws {
        // The capability Q4k needed: Mail's `--gui-send` HTML temp lives in `apple-cli-eml`, not in
        // the snapshot session, and before this it was silently refused by the containment guard.
        _ = try SQLiteReader(path: try sourceDatabase().path, copyToTemp: true)   // arm
        let other = try scratch.directory()
        SignalSafeCleanup.registerRoot(other)
        let f = other.appendingPathComponent("apple-cli-test-gui.html").path
        SignalSafeCleanup.track(f)
        #expect(SignalSafeCleanup.trackedPaths.contains(f))
    }

    @Test("registering a root does NOT make that directory removable")
    func rootsAreNotRemovable() throws {
        // THE SAFETY-CRITICAL HALF of the split. `apple-cli-eml` is shared with other invocations
        // and long-lived; the handler `rmdir`s exactly one directory and it must never be this one.
        let reader = try SQLiteReader(path: try sourceDatabase().path, copyToTemp: true)
        let session = try SQLiteReader.SnapshotSession.shared.directory()
        let shared = try scratch.directory()
        SignalSafeCleanup.registerRoot(shared)

        #expect(SignalSafeCleanup.registeredRoots.contains(shared.path + "/"), "control: it is a root")
        #expect(SignalSafeCleanup.removableDirectory == session.path,
                "the removable directory must still be the session, never a registered root")
        withExtendedLifetime(reader) { }
    }

    // KNOWINGLY UNTESTED, and the first version of this WAS a vacuous test that pretended
    // otherwise: that `track` REFUSES a path in no registered root. It cannot be exercised from
    // this tier, because the refusal calls `assertionFailure`, which traps in a debug build and
    // takes the whole test process with it — observed while red-proofing, where a mutation that
    // tracked an unrooted path aborted the run mid-suite rather than failing one case. The version
    // removed here "asserted" the outsider was absent from the set without ever calling `track`,
    // so it would have passed with the containment guard deleted entirely. Release behaviour
    // (refuse, return, carry on) is what ships; the debug trap is the fail-fast that found this.
}
