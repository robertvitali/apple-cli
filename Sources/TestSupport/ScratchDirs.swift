import Foundation

/// Per-test temporary directories that actually get cleaned up.
///
/// Test-only: no product target depends on this, so it is never linked into `apple`.
///
/// WHY THIS EXISTS. The suites each grew their own `temporaryDirectory.appendingPathComponent(
/// "apple-cli-<something>-\(UUID())")` helper and none of them deleted anything, so every run left
/// more behind. Measured in the shared temp root on 2026-08-02: **~14,000 files**, growing by 25 per
/// `swift test`. That is embarrassing on its own and worse in this repo specifically, whose current
/// work is fixing exactly this defect in the product — `SQLiteReader` snapshots and generated `.eml`
/// files both leaked into the same directory, for the same reason, and both are now fixed.
///
/// Hold one as a `let` stored property on a suite. swift-testing builds a fresh suite instance per
/// test, so the instance is released when that test finishes and `deinit` removes everything it
/// vended — no `defer` at each call site, nothing to forget.
///
///     @Suite("Something")
///     struct SomethingTests {
///         private let scratch = ScratchDirs("something")
///         @Test func x() throws {
///             let dir = try scratch.directory()      // gone when this test ends
///         }
///     }
///
/// It never deletes anything it did not create: only paths it vended are tracked, and it removes
/// those by exact URL rather than by matching a name pattern in a shared directory. That
/// distinction is not pedantry — pattern-matching deletes in the shared temp root is how a test in
/// this repo destroyed a concurrently-running command's files, twice.
public final class ScratchDirs {
    private let label: String
    private let lock = NSLock()
    private var created: [URL] = []

    public init(_ label: String) { self.label = label }

    /// A fresh, existing, uniquely-named directory owned by this instance.
    public func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-cli-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        lock.lock(); created.append(url); lock.unlock()
        return url
    }

    // DELIBERATELY NO `path(_:)` CONVENIENCE. One existed and was removed: it returned
    // `<fresh dir>/<name>`, so the file was absent but its PARENT existed — and migrating the rate
    // limiter's state path onto it silently dropped the coverage of that component's own mkdir-p,
    // with every test still green. Removing the mkdir-p then made the limiter report
    // `degraded: true` and ALLOW sends past the cap, so the lost coverage was safety-relevant.
    // A caller that needs a non-existent parent must say so explicitly:
    //     try scratch.directory().appendingPathComponent("sub/state.json")

    deinit {
        lock.lock(); let all = created; created.removeAll(); lock.unlock()
        for url in all { try? FileManager.default.removeItem(at: url) }
    }
}
