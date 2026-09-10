import Foundation

// Fixtures whose correctness is a property of the whole TEST PROCESS rather than of one suite:
// a lock over the process environment, and scratch directories that satisfy the CLI's own
// home-confinement guard. Both live here so there is exactly ONE implementation of each — the
// same reasoning `ScratchDirs` records for temp directories.
//
// Test-only: no product target depends on this target, so none of it is linked into `apple`.

/// A lazy first-touch snapshot of this test process's environment. Despite the historical
/// `atStartup` name, this is not a capture made at OS process startup. It represents the inherited
/// shell only if no raw environment mutation occurred before first touch.
///
/// WHY A SNAPSHOT AND NOT `getenv`. Live reads inside a `TestEnvironment` window observe its
/// pinned values, which can mask an operator export. `TestEnvironment.with` forces this snapshot
/// before opening its first window; subsequent managed windows cannot change the captured values.
/// The canary reads the snapshot only to report ambient posture. Product behavior must continue
/// to read the live environment.
///
/// Route test mutations through `TestEnvironment.with`. Raw mutation before first touch corrupts
/// inherited-shell fidelity; raw mutation afterward can make the live table disagree with this
/// immutable snapshot. Managed windows save and restore their enclosing state.
///
/// The snapshot and recursive lock each belong to ONE process. Sharded test workers have separate
/// snapshots and locks; a worker excluding AppleKitTests has no canary. A sole-reporter result in
/// one process cannot certify the environments or pin coverage of other workers.
public enum AmbientEnvironment {
    public static let atStartup: [String: String] = ProcessInfo.processInfo.environment
}

/// Process-wide serialization for tests that must mutate REAL environment variables.
///
/// WHY THIS EXISTS. `setenv`/`unsetenv` mutate one process-global table, and several MailKit
/// suites have to use it because the production code reads `APPLE_TEST_RECIPIENTS`,
/// `APPLE_TEST_SANDBOX`, `APPLE_ALLOW_EMPTY_TRASH` and `APPLE_SEND_RATELIMIT_STATE` directly, with
/// no injectable seam. A `.serialized` trait orders tests WITHIN one suite and says nothing about
/// other suites, which swift-testing still runs concurrently — so two suites each doing
/// save → mutate → restore on the same variable can interleave, and the later restore writes back
/// a value captured before the other's write. On a safety gate (the self-only outbound allowlist,
/// the irreversible empty-trash gate) that is a red — or, worse, a spuriously green — assertion.
///
/// Every save-mutate-restore helper in the test tree routes through THIS lock, so mutation windows
/// are ordered cross-suite rather than per-suite. Suites that call it should ALSO be `.serialized`:
/// the lock makes each mutation window atomic, while `.serialized` keeps a suite from queueing on
/// itself.
///
///     try TestEnvironment.with(["APPLE_TEST_RECIPIENTS": "me@example.com"]) {
///         …                       // the variable is set for exactly this block
///     }                           // previous value (or absence) restored before the lock drops
///
/// `nil` means "unset for the duration". The lock is RECURSIVE so nested windows on one thread
/// compose (`with(A) { with(B) { … } }`), which is how the compose suite layers a rate-limit-state
/// path inside a recipient allowlist.
///
/// WHAT THE LOCK DOES **NOT** DO — read this before assuming a suite is isolated. It serializes
/// MUTATORS against each other. It does nothing for a test that merely READS one of these
/// variables (directly via `TestMode.sandboxPrefix` / `TestMode.allowedRecipients`, or indirectly
/// by driving a command whose safety gates read them) while standing outside a window: such a test
/// races every open mutation window and additionally inherits whatever the OPERATOR exported into
/// the test process. Both were observed — a Mail suite failed 17 of 20 full runs against another
/// suite's `APPLE_TEST_SANDBOX=qa-fixture` window.
///
/// So the rule for the whole test tree is: **any test that reads an `APPLE_*` variable — including
/// through product code — runs inside a `TestEnvironment.with` window that PINS the variables it
/// depends on** (`withoutSandboxOverrides` pins the sandbox set to absent), or takes the value
/// through an injectable seam (a `prefix:`/`allowed:`/`envVar:` parameter) so no process-global is
/// consulted at all. Prefer the seam where one exists; the window is the fallback for the readers
/// that have none.
public enum TestEnvironment {
    /// The process-global variables that engage or widen the write sandbox. `APPLE_TEST_SANDBOX`
    /// redefines the required test-item label, `APPLE_TEST_MODE` engages the sandbox on its own
    /// (the env half of `TestMode.sandboxActive`), and `APPLE_TEST_RECIPIENTS` is the self-only
    /// outbound allowlist. A test asserting on a sandbox gate has to pin all three: any one of them
    /// arriving from another suite's window — or from the operator's shell — changes the verdict.
    static let sandboxVariables = ["APPLE_TEST_SANDBOX", "APPLE_TEST_MODE", "APPLE_TEST_RECIPIENTS"]

    /// Run `body` with every sandbox-engaging variable pinned ABSENT, so the gates under test see
    /// the canonical label, an unsandboxed default, and an empty allowlist regardless of what the
    /// ambient process environment or a concurrent suite holds. Nest a `with(...)` inside it to set
    /// one of them deliberately — the lock is recursive and the inner window restores to "absent".
    @discardableResult
    public static func withoutSandboxOverrides<T>(_ body: () throws -> T) rethrows -> T {
        try with(Dictionary(uniqueKeysWithValues: sandboxVariables.map { ($0, String?.none) }), body)
    }

    /// The variables that move a command's WRITE POSTURE: the sandbox set above plus
    /// `APPLE_DRY_RUN`. `APPLE_DRY_RUN` is deliberately not one of `sandboxVariables` — it moves
    /// `willExecute`, not `sandboxActive` — but a test asserting on a resolved write gate depends
    /// on all four, so the pair is named once here rather than re-spelled per suite (the four
    /// Calendar/Reminders helpers each had their own copy, and a fifth variable would have had to
    /// be added in four places).
    public static let writeModeVariables = sandboxVariables + ["APPLE_DRY_RUN"]

    /// Run `body` with every write-posture variable pinned ABSENT, so the gate under test resolves
    /// from the FLAGS the command parsed and nothing else — not an operator's exported
    /// `APPLE_TEST_MODE=1`/`APPLE_DRY_RUN=1`, and not a concurrent suite's open window.
    @discardableResult
    public static func withoutWriteModeOverrides<T>(_ body: () throws -> T) rethrows -> T {
        try with(Dictionary(uniqueKeysWithValues: writeModeVariables.map { ($0, String?.none) }), body)
    }

    /// The two rate-limiter state-file redirects. A test that asserts on the AMBIENT
    /// `stateURL()` must pin these absent for the duration, or a concurrent compose test's
    /// scratch redirect (opened under the same lock) becomes its accidental input.
    static let rateLimitVariables = ["APPLE_SEND_RATELIMIT_STATE", "APPLE_REPLY_RATELIMIT_STATE"]

    /// Run `body` with both rate-limiter redirects pinned to absent.
    public static func withoutRateLimitOverrides<T>(_ body: () throws -> T) rethrows -> T {
        try with(Dictionary(uniqueKeysWithValues: rateLimitVariables.map { ($0, String?.none) }), body)
    }

    /// One lock for the whole test process. `NSRecursiveLock` so nested windows on the same thread
    /// do not deadlock.
    private static let lock = NSRecursiveLock()

    /// Run `body` with `values` applied to the process environment, restoring the prior state
    /// (including absence) afterwards. Serialized process-wide against every other caller.
    @discardableResult
    public static func with<T>(_ values: [String: String?], _ body: () throws -> T) rethrows -> T {
        // Force the lazy snapshot before this process's first managed window can mutate the
        // table. This prevents capturing a pin as ambient state; it cannot recover the inherited
        // shell if raw mutation already occurred before first touch.
        _ = AmbientEnvironment.atStartup
        lock.lock()
        // `updateValue`, not `previous[key] = …`: on a `[String: String?]` the subscript treats a
        // nil value as REMOVE, so a variable that was unset would silently drop out of the restore
        // set and stay set after the block.
        var previous: [String: String?] = [:]
        for key in values.keys {
            previous.updateValue(getenv(key).map { String(cString: $0) }, forKey: key)
        }
        for (key, value) in values { apply(key, value) }
        defer {
            for (key, value) in previous { apply(key, value) }
            lock.unlock()
        }
        return try body()
    }

    private static func apply(_ key: String, _ value: String?) {
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
    }
}

/// Per-test scratch directories for commands that REFUSE to write outside the home directory.
///
/// `ScratchDirs` vends under `$TMPDIR`, which on macOS is `/var/folders/...` — outside `$HOME`, so
/// `AppleKit.confineWriteDestination` rejects it with exit 77. `mail export` and the other
/// home-confined write surfaces therefore cannot be tested against a `ScratchDirs` path at all.
/// This type is `ScratchDirs` with the one difference that matters: a root inside the home
/// directory, so the guard under test passes on its merits instead of being bypassed with
/// `--allow-outside-home` (which would stop exercising the default path).
///
/// Root selection: `<cwd>/.build-test-scratch` when the working directory is inside the home
/// directory — true under `swift test`, where cwd is the package root, and the repo ignores
/// `.build-*/` BY CLASS so nothing here can be swept into a commit. Otherwise a hidden directory in
/// the home directory itself. Same ownership contract as `ScratchDirs`: hold one as a `let` stored
/// property on a suite, take directories from it, and its `deinit` removes exactly the URLs it
/// vended — never a pattern match against a shared directory.
public final class ConfinedScratchDirs {
    private let label: String
    private let lock = NSLock()
    private var created: [URL] = []

    public init(_ label: String) { self.label = label }

    private static func root() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
        if cwd.path == home.path || cwd.path.hasPrefix(home.path + "/") {
            return cwd.appendingPathComponent(".build-test-scratch", isDirectory: true)
        }
        return home.appendingPathComponent(".apple-cli-test-scratch", isDirectory: true)
    }

    /// A fresh, existing, uniquely-named directory owned by this instance, inside the home
    /// directory so home-confined write commands accept it.
    public func directory() throws -> URL {
        let root = Self.root()
        // The root is created as its OWN step so `0700` lands on it too. A single
        // `createDirectory(withIntermediateDirectories: true, attributes:)` applies the attributes
        // to the leaf and leaves any intermediate it had to create at the process umask — which is
        // how the root ended up world-readable while the leaf under it was 0700.
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("apple-cli-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        lock.lock(); created.append(url); lock.unlock()
        return url
    }

    deinit {
        lock.lock(); let all = created; created.removeAll(); lock.unlock()
        for url in all { try? FileManager.default.removeItem(at: url) }
        // Reclaim the root too, so a checkout OUTSIDE the home directory (CI, a container, a /tmp
        // clone) does not leave `~/.apple-cli-test-scratch` behind — unlike a `$TMPDIR` scratch,
        // nothing ever reaps it. POSIX `rmdir`, deliberately NOT `removeItem`: `rmdir` fails with
        // ENOTEMPTY, so a root another live instance still owns directories under is left alone,
        // whereas `removeItem` is recursive and would delete them.
        _ = rmdir(Self.root().path)
    }
}
