import Testing
import Foundation
import TestSupport
@testable import AppleKit

/// The two review-hardenings of `RateLimitStore` (2026-08-18): the cross-process advisory lock that
/// closes the parallel read-modify-write race, and the `.corrupt` load signal that stops a garbage
/// state file from silently resetting the cap. Both drive an INJECTED state URL so they never touch
/// the operator's real budget and cannot race the other suites.
@Suite("Rate limit store — cross-process lock + corrupt-state signal")
struct RateLimitConcurrencyTests {
    private let scratch = ScratchDirs("ratelimitlock")

    func tmpState(_ label: String) -> URL {
        try! scratch.directory().appendingPathComponent("\(label)/state.json")
    }

    /// The `flock` `consume` holds across the whole load→check→append→save serializes concurrent
    /// invocations, so even under parallel fan-out (the runaway-loop shape D8 targets) EXACTLY
    /// `maxCalls` are allowed — never the K-way excess a lock-free read-modify-write lets through
    /// (K processes all read the same pre-write window, all pass, all send). Revert-red: drop the
    /// `acquireLock`/`flock` and this over-admits on a multi-core host.
    @Test("parallel consumes are bounded to exactly maxCalls (flock serializes the RMW)")
    func parallelConsumeBoundedToMaxCalls() {
        let url = tmpState("parallel")
        let now = Date()               // fixed instant ⇒ the window never slides mid-test
        let maxCalls = 3
        let iterations = 64
        let lock = NSLock()
        var allowed = 0
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            let d = RateLimitStore.consume(now: now, stateURL: url,
                                           maxCalls: maxCalls, windowSeconds: 60)
            if d.allowed { lock.lock(); allowed += 1; lock.unlock() }
        }
        #expect(allowed == maxCalls,
                "flock must serialize the read-modify-write so exactly \(maxCalls) of \(iterations) pass")
    }

    /// A corrupt/garbage state file resets the window to empty (still allowed) but MUST flag
    /// `degraded` so the caller warns on stderr — a persistently-unparseable file must not silently
    /// reset the cap to zero with no operator-visible signal. Revert-red: without the `.corrupt`
    /// branch (the old `?? []`), `degraded` is false here.
    @Test("a corrupt state file is allowed but flagged degraded (not silent)")
    func corruptStateFlagsDegraded() throws {
        let url = tmpState("corrupt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: url)
        let d = RateLimitStore.consume(now: Date(), stateURL: url, maxCalls: 3, windowSeconds: 60)
        #expect(d.allowed == true)
        #expect(d.degraded == true)
    }

    /// A clean first run (no file yet) must NOT be flagged degraded — `degraded` is reserved for the
    /// unreadable/corrupt paths, so an ordinary empty window stays silent.
    @Test("a clean first run is not degraded")
    func cleanFirstRunNotDegraded() {
        let d = RateLimitStore.consume(now: Date(), stateURL: tmpState("clean"),
                                       maxCalls: 3, windowSeconds: 60)
        #expect(d.allowed == true)
        #expect(d.degraded == false)
    }
}
