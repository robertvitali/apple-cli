import Foundation

// Process-teardown cleanup for temporary files holding the operator's data.
//
// This lived inside `SQLiteReader` while the SQLite snapshot directory was its only client, and
// review asked whether it belonged there. A second client answered the question: Mail's
// `--gui-send` HTML temp has the same shape of problem — a file holding the operator's message
// body, removed by a `defer` that a signal death skips — and it lives in another module, so the
// type had to become top-level and public regardless. See COMPLETION-LOOP Q4i (the handler) and
// Q4k (the second client, whose row records which Mail temps must NOT be registered here, and why
// registering them would destroy a live hand-off rather than clean up a leak).

/// Removes this process's snapshot directory on SIGINT/SIGQUIT/SIGTERM/SIGHUP — the exits
/// `atexit` misses.
///
/// Ctrl-C during a slow read is the most likely abnormal exit this tool will ever see, and
/// measured, a SIGTERM mid-command strands a session directory (exit 143, one directory left
/// behind) until some later run reaps it. In the meantime it holds copies of the operator's mail
/// at 0600.
///
/// EVERYTHING HERE IS CONSTRAINED BY ASYNC-SIGNAL-SAFETY. A handler may only call functions from
/// a short POSIX-defined list: `unlink`, `rmdir`, `open`, `close`, `signal` and `raise` are on
/// it; `FileManager`, Swift string interpolation, `malloc` and anything that takes a lock are
/// NOT. So the paths are rendered to C strings in advance, at `track` time, and the handler
/// walks a raw buffer of them calling `unlink(2)` before removing the directory.
///
/// (Two of those six go through a thin Swift overlay shim rather than the raw libc symbol —
/// `Darwin.open(_:_:_:)` and the `SIG_DFL` getter. Both live in the dyld shared cache and were
/// NOT disassembled, so they are believed-safe rather than verified-safe. Recorded because the
/// rest of this file is verified.)
///
/// It then RE-RAISES with the default disposition rather than `_exit`ing, so the process still
/// dies of the signal it was sent and the shell sees the conventional 130/143 rather than a
/// fabricated status.
///
/// Best effort by construction: if `rmdir` fails because something unexpected is in the
/// directory, the handler puts `.lock` back so the next run's liveness sweep reaps it — the same
/// backstop that covers SIGKILL, which no handler can intercept.
///
/// NOT COVERED, deliberately: `SIGKILL`/`SIGSTOP` (uncatchable) and the fatal-fault signals
/// `SIGABRT`/`SIGSEGV`/`SIGBUS`/`SIGILL`/`SIGTRAP`, which a Swift `precondition` or trap can
/// raise. Running even this handler on a heap that may already be corrupt is its own hazard, so
/// those are left to the reaper on purpose rather than by oversight. Each strands a directory
/// that keeps its `.lock`, which is the reapable state.
public enum SignalSafeCleanup {
    /// Starting capacity. The set GROWS rather than saturating — see `track`.
    ///
    /// THIS WHOLE DESIGN ASSUMES A SHORT-LIVED PROCESS. The tracked set is monotonic: entries
    /// are never removed, not even when `removeTempDB` deletes the file a slot names. For a CLI
    /// that is free — a command tracks 3-9 paths and exits. A daemon or `--watch` mode would
    /// turn the deliberate buffer leak unbounded AND make the handler an O(every reader ever)
    /// unlink loop, so that change needs a reclaim strategy, not just more capacity.
    ///
    /// A fixed cap looked safe (a command opens one or two readers) and was not: the logic test
    /// that asserts the tracked set covers the directory went red 1-in-12, naming three
    /// untracked `.sqlite` files, because a test process opens hundreds of readers and silently
    /// overflowed. Dropping a path is not cosmetic — an untracked file makes `rmdir` fail, which
    /// is exactly the failure this whole change exists to remove.
    private static let initialCapacity = 64
    private static let lock = NSLock()

    /// EVERY byte the handler reads lives in ONE raw allocation, not in Swift variables.
    ///
    /// That is the whole design, and it is not stylistic. Reading a Swift `static var` compiles
    /// to `swift_beginAccess`; reading a Swift `Array` additionally emits retain/release that
    /// can transitively reach `free()`, and in debug builds instantiates type metadata once per
    /// loop iteration. None of those are on the POSIX async-signal-safe list, and the first
    /// version of this code did all three. Review disassembled the built binary and reproduced
    /// the consequence: `track`'s `append` holds a `Modify` access across a `malloc`, so a
    /// signal landing in that window made the handler's `Read` a same-thread exclusivity
    /// violation — `Simultaneous accesses … but modification requires exclusive access`,
    /// SIGABRT, exit 134, zero unlinks, and the directory stranded after all.
    ///
    /// Loads and stores through a raw pointer emit none of that machinery.
    private struct Registry {
        /// Written only after `slots[count]` is initialized, so a reader can never observe a
        /// slot that has not been filled in yet.
        var count: Int32
        var capacity: Int32
        var dir: UnsafeMutablePointer<CChar>?
        var lockFile: UnsafeMutablePointer<CChar>?
        var slots: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    }

    /// The one Swift static the handler touches — and it is a `let`, which is the point.
    ///
    /// A `static var` would be mutable memory, so every read compiles to `swift_beginAccess`;
    /// that call maintains a thread-local access set and is not on the async-signal-safe list.
    /// Verified rather than assumed: with this as a `var`, the debug build — the one `bats`
    /// actually runs — emitted `swift_beginAccess`/`swift_endAccess` inside the handler, while
    /// release elided them. A `let` is immutable, so there is no dynamic exclusivity check in
    /// either configuration; the mutable state lives behind the pointer, where loads and stores
    /// are raw and emit no runtime machinery at all.
    ///
    /// Its lazy-initialization `swift_once` is resolved by `arm` before the first `signal()`
    /// call, so the handler can never be the first toucher.
    nonisolated(unsafe) private static let cell: UnsafeMutablePointer<UnsafeMutablePointer<Registry>?> = {
        let p = UnsafeMutablePointer<UnsafeMutablePointer<Registry>?>.allocate(capacity: 1)
        p.initialize(to: nil)
        return p
    }()

    /// Directories whose contents `track` will accept, each stored WITH a trailing separator.
    ///
    /// An ordinary Swift array is correct here even though everything else in this type is raw
    /// memory: the handler never reads this. It is consulted only by `track`, in normal context,
    /// under `lock`. The raw-buffer discipline exists for what a signal handler touches; applying
    /// it where it buys nothing would be cargo cult.
    ///
    /// A root is NOT a claim of exclusive ownership, and since Q4k one of them is not exclusive:
    /// Mail's `apple-cli-eml` directory is shared with every concurrent `apple` invocation. The
    /// guard therefore proves less than it did when the only root was this process's own
    /// `s-<pid>-<uuid>` session — it proves "inside a directory this tool owns", not "inside a
    /// directory this PROCESS owns". That is still the property that matters, because what the
    /// handler removes is individual files this process created and named with a UUID, never the
    /// directory. It is only ever `rmdir`-safe for the one directory `arm` names.
    ///
    /// It also grows monotonically and is never pruned, so a root whose directory was since deleted
    /// stays. Harmless — it only ever widens what `track` will accept, and only to paths under a
    /// directory this tool made — but worth knowing before treating it as a live inventory.
    nonisolated(unsafe) private static var roots: [String] = []

    /// Permit `track` to accept files inside `url`, WITHOUT making that directory removable.
    ///
    /// This is the split review demanded before a second caller arrived: "paths to unlink" and
    /// "the one directory to remove" are now different things. `arm` still names the single
    /// directory the handler `rmdir`s — the snapshot session, which this process owns exclusively.
    /// A root registered here is only a containment boundary. That distinction is what lets Mail's
    /// `.eml` directory be used at all: it is SHARED and long-lived, has no `.lock`, and `rmdir`ing
    /// it would be a bug.
    public static func registerRoot(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        // ARMS THE PROCESS, which is the point. A `mail send --gui-send` opens no SQLite snapshot,
        // so nothing else would ever call `arm`, the registry would stay nil, and `track` plus the
        // handler would both silently do nothing — the file would strand exactly as before. A root
        // with no handler behind it is decoration.
        ensureRegistryLocked(dir: nil, lockFile: nil)
        // Standardized to match `track`, which standardizes its argument. Comparing a normalized
        // value against an unnormalized one is a defect on its own terms: a root carrying `.` or
        // `..` — a `base:` in a test, or a `TMPDIR` like `/tmp/foo/../foo` — would make every
        // legitimate path miss the prefix, hit `assertionFailure`, and in a debug build raise the
        // no-cleanup SIGTRAP death this whole area already documents.
        let std = URL(fileURLWithPath: url.path).standardized.path
        let p = std.hasSuffix("/") ? std : std + "/"
        if !roots.contains(p) { roots.append(p) }
    }

    /// Create the registry and install the handlers if that has not happened yet, and adopt
    /// `dir`/`lockFile` if they are being supplied for the first time. Caller holds `lock`.
    ///
    /// The registry can exist with NO removable directory: that is the file-only shape Mail uses.
    /// `dir` and `lockFile` are set at most once, by whichever `arm` gets there first, and the
    /// handler already tolerates both being nil (it skips the `unlink`/`rmdir`/restore tail).
    private static func ensureRegistryLocked(dir: URL?, lockFile: URL?) {
        if let existing = cell.pointee {
            // Adopt a directory onto an already-armed file-only registry. A single pointer store
            // each, so a signal here sees either nil (skip the tail) or the complete path.
            if existing.pointee.dir == nil, let dir, let lockFile {
                // `dir` FIRST, mirroring the handler's own "the liveness marker goes last" rule.
                // A signal between the two stores then sees dir-set/lockFile-nil: `rmdir` is
                // attempted, fails on a non-empty directory, and the restore branch no-ops — and
                // crucially the `.lock` was never unlinked, so the directory keeps it and the
                // reaper collects it next run. The reverse order leaves lockFile-set/dir-nil,
                // which unlinks the liveness marker and then never restores it.
                existing.pointee.dir = strdup(dir.path)
                existing.pointee.lockFile = strdup(lockFile.path)
            }
            return
        }
        let slots = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: initialCapacity)
        slots.initialize(repeating: nil, count: initialCapacity)
        let r = UnsafeMutablePointer<Registry>.allocate(capacity: 1)
        r.initialize(to: Registry(count: 0, capacity: Int32(initialCapacity),
                                  dir: dir.map { strdup($0.path) } ?? nil,
                                  lockFile: lockFile.map { strdup($0.path) } ?? nil,
                                  slots: slots))
        publish(r)
        for sig in [SIGINT, SIGQUIT, SIGTERM, SIGHUP] where !isIgnored(sig) {
            signal(sig, SignalSafeCleanup.handle)
        }
    }

    /// Pre-render one path. Safe to call at any time EXCEPT from a handler.
    ///
    /// A session that does not install handlers (every test-owned one) never arms, so `registry`
    /// is nil and this is a no-op. That keeps the isolation invariant on `installsExitHook`
    /// intact: a test's paths cannot enter the process-global set the handler walks.
    /// Undo an `arm` whose directory never came into being, so the next attempt can arm its own.
    /// Call with the value `arm` returned: it clears only if THIS arm's session tracked nothing in
    /// the meantime. A handler that observes the nil does nothing, which is correct — there is
    /// nothing to clean up yet.
    ///
    /// It does NOT uninstall the signal dispositions, despite the name. That is deliberate and
    /// harmless: the handler sees a nil registry, does nothing, restores `SIG_DFL` and re-raises,
    /// so the process still dies of the signal it was sent. Re-arming re-queries `isIgnored`,
    /// and an inherited `SIG_IGN` was never overwritten in the first place, so it still reads as
    /// ignored.
    static func disarmForRetry(armedAtCount: Int32) {
        lock.lock(); defer { lock.unlock() }
        // Scoped to the arm being undone, NOT to `count == 0`. `count` is shared across clients
        // now, so a zero-check is defeatable by the other module: Mail tracks one file, a snapshot
        // session then arms and fails to create its directory, the guard sees Mail's count and
        // refuses to clear, and `dir` stays pinned to a directory that never existed — after which
        // the directory that DOES hold the operator's mail is neither tracked nor removable. That
        // is exactly the regression this function was written to prevent, re-entering through a
        // counter it does not own.
        guard let r = cell.pointee, r.pointee.count == armedAtCount else { return }
        // Clear ONLY the directory, not the registry. Nilling the whole thing would also drop any
        // roots another module registered and leave its files untracked — and would uninstall
        // nothing, since the handlers stay put either way. The strdup'd strings are leaked, as
        // everywhere else here.
        r.pointee.dir = nil
        r.pointee.lockFile = nil
    }

    public static func track(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        guard let old = cell.pointee else { return }

        // Containment check at the registration point: the handler unlinks these blind, so a
        // path outside a directory we own would be someone else's file — the exact failure class
        // this design exists to prevent, and one this repo has already hit.
        //
        // It REFUSES rather than traps, which is the whole design of it. The obvious spelling is
        // `precondition`, and review showed why that is wrong here: a trap raises SIGILL/SIGTRAP,
        // which is in the set of fatal-fault signals this handler deliberately does NOT install
        // — so a firing guard would kill the process WITHOUT cleanup and strand the very
        // directory it exists to protect. A defensive check whose failure mode is the defect is
        // worse than no check. Declining to track degrades into `rmdir` failing and the `.lock`
        // being restored, which is the designed path and leaves the directory reapable.
        //
        // The trailing separator matters: a bare prefix test would accept `<session>-EVIL/x`
        // as being "inside" `<session>`.
        // Lexically standardized FIRST: the guard is a prefix test, and `<root>/../../etc/x` has
        // the root as a prefix while pointing outside it.
        //
        // LEXICAL, not `resolvingSymlinksInPath`, and the first version of this comment gave the
        // wrong reason (it claimed resolution would ADD a TOCTOU; review measured the opposite —
        // resolution closes one, since the handler unlinks the stored string). The actual reason is
        // that `resolvingSymlinksInPath` silently no-ops on a path that does not exist yet, and the
        // dominant caller tracks BEFORE creating the file. A guard that resolves only sometimes is
        // worse than one that never does. Security reviewed the residual symlinked-intermediate
        // case as unreachable: every tracked string is tool-generated, leaf names carry a fresh
        // UUID, and the roots are re-validated 0700/uid-owned via `lstat` on every call.
        let path = URL(fileURLWithPath: path).standardized.path
        guard roots.contains(where: { path.hasPrefix($0) }) else {
            assertionFailure("tracked path is in no registered owned root: \(path)")
            return
        }
        guard let c = strdup(path) else { return }

        guard old.pointee.count == old.pointee.capacity else {
            old.pointee.slots[Int(old.pointee.count)] = c  // initialize the slot FIRST
            old.pointee.count += 1                         // publish it SECOND
            // …but do NOT rely on that ordering as the guarantee. These are two non-aliasing
            // stores with no barrier, and LLVM is free to reorder them. WHAT ACTUALLY MAKES A
            // TORN READ HARMLESS IS THE NIL-PREFILL of `slots` (in `arm` and on every grow): a
            // slot published before it is written reads `nil`, the handler's `if let` skips it,
            // and the worst case degrades to one path not unlinked -> `rmdir` fails -> `.lock`
            // restored -> the reaper collects it. Both reviewers landed on this independently:
            // deleting the nil-prefill would silently reintroduce v1's wild-pointer `unlink`,
            // so it is load-bearing and must not be optimized away as redundant.
            return
        }

        // GROW BY REPLACEMENT, never in place. A handler could be walking the current buffer
        // right now, so the old one is neither reallocated nor freed: a complete new `Registry`
        // is built off to the side and published with a single pointer store, which is the only
        // thing the handler reads. Whichever it sees is internally consistent.
        //
        // The old `Registry` and its slots are deliberately LEAKED. Freeing them would race the
        // handler, and the cost is bounded by doubling — a handful of 40-byte structs and
        // pointer arrays over the life of a process, against a signal-safety hazard.
        //
        // WHAT THE PUBLICATION DOES AND DOES NOT CLAIM. A signal is delivered at an instruction
        // boundary on the interrupted thread, so a handler firing anywhere inside this function
        // reads `cell.pointee` either before or after the single pointer store and therefore
        // sees one complete registry — the old one, missing at most the path being added (whose
        // file does not exist yet: `newSnapshotURL` tracks before it creates), or the new one,
        // fully built. Program order is sufficient for that and no barrier is required.
        //
        // It does NOT claim cross-THREAD publication, which would need release/acquire.
        //
        // Do not justify that with "the process is single-threaded" — review MEASURED 2 threads
        // for `apple messages chats` and 3 for `apple mail list`, and a process-directed signal
        // goes to whichever thread has it unblocked, so the handler genuinely can run on a
        // thread other than the one inside `track`. The two reasons it is nonetheless safe in
        // the shipping binary are narrower, and both are worth knowing because either could be
        // broken by an ordinary change:
        //   1. THE GROW PATH NEVER RUNS IN THE CLI. A command tracks 3-9 paths against an
        //      initial capacity of 64, so `arm`'s publication is the only one that happens.
        //   2. `arm` publishes and THEN makes `signal()` syscalls before any handler can exist;
        //      the kernel round-trip serializes the preceding stores.
        // Add a background-thread reader, or a caller that tracks past 64 paths in production,
        // and this store plus the `count` bump above must become release/acquire atomics.
        let newCapacity = old.pointee.capacity * 2
        let slots = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: Int(newCapacity))
        slots.initialize(repeating: nil, count: Int(newCapacity))
        slots.update(from: old.pointee.slots, count: Int(old.pointee.count))
        slots[Int(old.pointee.count)] = c

        let r = UnsafeMutablePointer<Registry>.allocate(capacity: 1)
        r.initialize(to: Registry(count: old.pointee.count + 1, capacity: newCapacity,
                                  dir: old.pointee.dir, lockFile: old.pointee.lockFile,
                                  slots: slots))
        publish(r)
    }

    /// Make `r` the live registry. `@inline(never)` is load-bearing, not a hint.
    ///
    /// The two steps above — initializing the new `Registry`, then storing the pointer that
    /// makes it reachable — are ordinary stores to distinct allocations, and nothing in the
    /// language stops the initialization being sunk below the publication. Review raised this
    /// (N2) and it is the one place in this design where a mis-ordered observation is NOT
    /// benign: a handler seeing `r` before its fields were written would read a garbage `count`
    /// and `slots` pointer and `unlink()` wild addresses. Everywhere else the nil-prefilled
    /// slots make a stale read harmless.
    ///
    /// An opaque call the optimizer will not inline keeps the field stores above it, and the
    /// emitted code was checked rather than assumed: fields at `stp/stur/str [x0…]`, then
    /// `bl publish`, in release.
    ///
    /// HONESTLY, THOUGH: this is an observation, not a contract. Under whole-module optimization
    /// LLVM can see this body — it is `private` and already signature-specialized — so nothing
    /// stops a future compiler proving it never reads `*r` and sinking the stores. The exact
    /// primitive is `atomic_signal_fence(memory_order_release)`, a compiler-only fence defined
    /// for precisely this handler-vs-interrupted-code case, with zero hardware cost and no
    /// deployment-target requirement. It needs a small C target, which this package does not
    /// have; adding one is the right follow-up if this code grows. (`Synchronization.Atomic`
    /// would also work but needs macOS 15, and this package targets 14.)
    @inline(never)
    private static func publish(_ r: UnsafeMutablePointer<Registry>) {
        cell.pointee = r
    }

    /// Is this signal already set to be ignored?
    ///
    /// NEVER catch a signal inherited as ignored. `nohup` and a POSIX shell's background-job
    /// setup both hand a child `SIG_IGN` precisely so it survives, and installing over it
    /// silently took that away — measured 3/3, a `nohup`-posture run died at 129 (SIGHUP) and
    /// 130 (SIGINT) where the pre-change binary ran to completion. `sigaction` is used to QUERY
    /// rather than `signal`-then-restore, because the restore shape has its own window: a
    /// signal arriving between installing and putting `SIG_IGN` back would still be caught.
    private static func isIgnored(_ sig: Int32) -> Bool {
        var current = sigaction()
        guard sigaction(sig, nil, &current) == 0 else { return false }
        return unsafeBitCast(current.__sigaction_u.__sa_handler, to: UnsafeRawPointer?.self)
            == unsafeBitCast(SIG_IGN, to: UnsafeRawPointer?.self)
    }

    /// Install the handlers and remember the directory to remove last.
    /// Returns the tracked-path count observed at arm time, which `disarmForRetry` needs.
    @discardableResult
    static func arm(directory url: URL, lockFile: URL) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        // The root goes in UNCONDITIONALLY. An earlier version skipped it whenever a removable
        // directory already existed, which conflated the two things this split exists to separate:
        // "we already have a directory to rmdir" is a fine reason to decline a second one as
        // REMOVABLE, and never a reason to decline it as a CONTAINMENT ROOT — its files are still
        // ours and still need unlinking. When that fired, every `track` for the new directory was
        // refused, and in a debug build the refusal's `assertionFailure` raised SIGTRAP — a signal
        // this handler deliberately does not install — so the process died with no cleanup at all,
        // stranding the directory the guard was there to protect. The one-removable-directory rule
        // is enforced inside `ensureRegistryLocked`, where it belongs.
        let rootPath = url.path.hasSuffix("/") ? url.path : url.path + "/"
        if !roots.contains(rootPath) { roots.append(rootPath) }
        ensureRegistryLocked(dir: url, lockFile: lockFile)
        return cell.pointee?.pointee.count ?? 0
    }

    /// Test-only view of what will be removed. Exists so a logic test can assert the set is
    /// COMPLETE — that every file a live session directory can hold is tracked. That is the
    /// property whose absence produced the first version's failure, where the handler fired
    /// correctly and the directory survived anyway because `.lock` was untracked and `rmdir`
    /// will not remove a non-empty directory. It needs no signals to check.
    static var trackedPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        guard let r = cell.pointee else { return [] }
        var out: [String] = []
        if let l = r.pointee.lockFile { out.append(String(cString: l)) }
        for i in 0..<Int(r.pointee.count) where r.pointee.slots[i] != nil {
            out.append(String(cString: r.pointee.slots[i]!))
        }
        return out
    }

    /// Test-only view of the containment roots.
    static var registeredRoots: [String] {
        lock.lock(); defer { lock.unlock() }
        return roots
    }

    /// Test-only view of the ONE directory the handler will `rmdir`, if any. Nil is the file-only
    /// shape — the one Mail uses, and the one that must stay nil for a shared directory.
    static var removableDirectory: String? {
        lock.lock(); defer { lock.unlock() }
        guard let d = cell.pointee?.pointee.dir else { return nil }
        return String(cString: d)
    }

    /// The handler. The only LIBC calls it makes are `unlink`, `rmdir`, `open`, `close`,
    /// `signal` and `raise` — all six on the POSIX async-signal-safe list.
    ///
    /// Do not read that as "six `bl`s". Disassembling the debug handler finds NINE: those six
    /// (two of them via thin Swift overlay shims, `Darwin.open` and the `SIG_DFL` getter) plus
    /// the addressor for `cell`. The addressor is the one worth knowing about, because it has a
    /// visible branch to `swift_once` and looks alarming: its fast path is branch-only
    /// (`ldr`/`adds`/`b.ne`/`adrp`/`ret`) and the `swift_once` slow path is UNREACHABLE, because
    /// `arm` touches `cell` before it installs any handler. Verified in both configurations.
    /// Stated precisely because the next person to audit this will disassemble it.
    ///
    /// It takes no lock, deliberately: locking in a handler risks deadlocking against the
    /// interrupted thread that already holds it. It does not need one — see `Registry`.
    private static let handle: @convention(c) (Int32) -> Void = { sig in
        if let r = SignalSafeCleanup.cell.pointee {
            let n = r.pointee.count
            var i: Int32 = 0
            while i < n {
                if let p = r.pointee.slots[Int(i)] { _ = unlink(p) }
                i += 1
            }
            // THE LIVENESS MARKER GOES LAST, and comes back if the directory outlives us.
            // `reapDeadSessions` keys entirely on `.lock`: present plus owner dead means the
            // kernel hands the directory to the very next run. Absent, it falls into the
            // hour-long unclaimed-age branch — and our own unlinks just reset that clock. So
            // removing `.lock` first, as this did originally, made a partial failure strictly
            // slower to clean up than installing no handler at all.
            if let l = r.pointee.lockFile { _ = unlink(l) }
            if let d = r.pointee.dir, rmdir(d) != 0, let l = r.pointee.lockFile {
                // `O_EXCL` is semantically exact — we unlinked it two lines ago — and
                // `O_NOFOLLOW` refuses a symlink planted on the final component. Neither is
                // reachable today (same UID, 0700 parent); both are strictly tighter.
                let fd = open(l, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
                if fd >= 0 { _ = close(fd) }
            }
        }
        signal(sig, SIG_DFL)
        raise(sig)
    }
}
