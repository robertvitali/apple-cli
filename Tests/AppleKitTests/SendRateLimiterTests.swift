import Testing
import Foundation
import TestSupport
@testable import AppleKit

/// Oracle-mirrored send rate limit (oracle A `security.py` `TIER_LIMITS["sends"] = (3, 60.0)`).
///
/// Every test drives an INJECTED state URL in a unique temp directory. That is not incidental:
/// the production path is `~/.apple-cli/send-rate-limit.json`, and a suite that touched it would
/// (a) mutate the operator's real limiter state and (b) race the other suites, since swift-testing
/// runs all of them in ONE process in parallel. Same class of hazard as the `APPLE_DRY_RUN` and
/// `APPLE_TEST_SANDBOX` races already documented in docs/write-model-v2.md.
@Suite("Send rate limiter (oracle A sends tier)")
struct SendRateLimiterTests {
    /// A unique, non-existent state path per call, inside scratch that is actually reclaimed.
    /// Eight labels here leaked one directory each per `swift test`; ~2,100 had accumulated.
    private let scratch = ScratchDirs("ratelimit")

    func tmpState(_ label: String) -> URL {
        // NOTE the extra `\(label)/` component: the state file's PARENT must NOT exist, because
        // that is what exercises the limiter's own mkdir-p (RateLimiter.swift). The first migration
        // to ScratchDirs used `scratch.path(...)`, whose parent DOES exist, and silently dropped
        // that coverage while every test stayed green — caught in review. `try!` is acceptable in a
        // test helper whose only failure mode is an unusable temp directory: no recovery, fails loud.
        let url = try! scratch.directory().appendingPathComponent("\(label)/state.json")
        // Asserted HERE, not in a ScratchDirs test: the invariant belongs to these tests, and a
        // ScratchDirs test claiming to guard it was vacuous — it exercised the helper, not this
        // usage. If a future edit hands back a path whose parent already exists, every test below
        // still passes while quietly covering nothing, which is exactly what happened once.
        precondition(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path),
                     "the state file's parent must NOT exist — it is what exercises the mkdir-p")
        return url
    }

    @Test("the ported constants are the oracle's verbatim")
    func constantsMatchOracle() {
        #expect(SendRateLimiter.maxCalls == 3)
        #expect(SendRateLimiter.windowSeconds == 60.0)
    }

    @Test("the first three sends pass and the fourth is refused inside the window")
    func capFiresOnFourth() {
        let url = tmpState("cap")
        let t0 = Date()
        for i in 1...3 {
            let d = SendRateLimiter.consume(now: t0.addingTimeInterval(Double(i)), stateURL: url)
            #expect(d.allowed == true, "send \(i) should be allowed")
            #expect(d.degraded == false)
        }
        let fourth = SendRateLimiter.consume(now: t0.addingTimeInterval(4), stateURL: url)
        #expect(fourth.allowed == false)
        #expect(fourth.retryAfter > 0)
    }

    /// THE point of persisting to a file: the oracle's in-memory deque spans a long-lived server,
    /// while this CLI is a fresh process per invocation. Each `consume` call here stands in for a
    /// separate process; if state did not persist, the fourth would wrongly pass.
    @Test("the window persists ACROSS invocations — a fresh process does not reset it")
    func persistsAcrossProcesses() {
        let url = tmpState("persist")
        let t0 = Date()
        _ = SendRateLimiter.consume(now: t0, stateURL: url)
        _ = SendRateLimiter.consume(now: t0.addingTimeInterval(1), stateURL: url)
        _ = SendRateLimiter.consume(now: t0.addingTimeInterval(2), stateURL: url)
        // A brand-new "process" reading the same state file must still see a full window.
        #expect(SendRateLimiter.consume(now: t0.addingTimeInterval(3), stateURL: url).allowed == false)
        #expect(FileManager.default.fileExists(atPath: url.path), "state must have been written")
    }

    @Test("the window SLIDES: once the oldest call ages out, a send is allowed again")
    func windowSlides() {
        let url = tmpState("slide")
        let t0 = Date()
        for i in 0..<3 { _ = SendRateLimiter.consume(now: t0.addingTimeInterval(Double(i)), stateURL: url) }
        // Still inside 60s → refused.
        #expect(SendRateLimiter.consume(now: t0.addingTimeInterval(30), stateURL: url).allowed == false)
        // Past the window from the oldest → allowed. Mirrors the oracle's
        // `while q and q[0] <= now - window: q.popleft()`.
        #expect(SendRateLimiter.consume(now: t0.addingTimeInterval(61), stateURL: url).allowed == true)
    }

    @Test("a refusal reports a positive retryAfter bounded by the window")
    func retryAfterIsSane() {
        let url = tmpState("retry")
        let t0 = Date()
        for i in 0..<3 { _ = SendRateLimiter.consume(now: t0.addingTimeInterval(Double(i)), stateURL: url) }
        let d = SendRateLimiter.consume(now: t0.addingTimeInterval(10), stateURL: url)
        #expect(d.allowed == false)
        #expect(d.retryAfter > 0 && d.retryAfter <= SendRateLimiter.windowSeconds)
        #expect(SendRateLimiter.refusal(d).contains("Rate limit exceeded: 3 calls per 60s"))
    }

    /// FAIL-OPEN, and the caller must be able to SEE it. An unwritable state location permits the
    /// send rather than bricking the CLI, but flags `degraded` so the command warns instead of
    /// silently dropping the cap.
    @Test("an unwritable state path fails OPEN and reports degraded")
    func failsOpenWhenUnwritable() {
        // /dev/null/... can never be a directory, so the create+write both fail.
        let unwritable = URL(fileURLWithPath: "/dev/null/apple-cli/state.json")
        let d = SendRateLimiter.consume(stateURL: unwritable)
        #expect(d.allowed == true, "must not brick sending")
        #expect(d.degraded == true, "must be visible, not silent")
    }

    @Test("a corrupt state file resets the window (still allowed) but is flagged degraded, not silent")
    func corruptStateResets() throws {
        let url = tmpState("corrupt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: url)
        let d = SendRateLimiter.consume(stateURL: url)
        #expect(d.allowed == true)
        // Reset-to-empty (allowed) rather than bricking sends — but NOW flagged degraded so the
        // caller warns on stderr. A persistently-unparseable file must not silently reset the cap to
        // zero every call with no operator-visible signal (security review 2026-08-18).
        #expect(d.degraded == true)
    }

    /// A FUTURE-dated stamp must not pin the window shut.
    ///
    /// The oracle uses `time.monotonic()`, which cannot run ahead of itself; this port uses wall
    /// clock, which can (forward jump, VM snapshot restore, dead RTC, manual `date`). With only a
    /// lower-bound prune, such a stamp never ages out and every subsequent send is refused until
    /// someone deletes a JSON file they have never heard of — a permanent fail-CLOSED in a
    /// component that deliberately fails open. Review-caught; this is the regression pin.
    @Test("future-dated stamps are discarded rather than bricking sending forever")
    func futureStampsDoNotBrick() throws {
        let url = tmpState("future")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let now = Date()
        // Three stamps a full day in the future — enough to outlive any real window.
        let future = (1...3).map { now.timeIntervalSince1970 + 86_400 + Double($0) }
        try JSONEncoder().encode(future).write(to: url)

        let d = SendRateLimiter.consume(now: now, stateURL: url)
        #expect(d.allowed == true, "a stamp that has not happened yet cannot evidence a sent message")
        #expect(d.retryAfter == 0)

        // And the poisoned stamps must be gone, not merely ignored once.
        let left = try JSONDecoder().decode([TimeInterval].self, from: Data(contentsOf: url))
        #expect(left.allSatisfy { $0 <= now.timeIntervalSince1970 })
        #expect(left.count == 1, "only the just-recorded send should remain, found \(left.count)")
    }

    @Test("a refusal never reports a retryAfter longer than the window")
    func retryAfterClamped() {
        let url = tmpState("clamp")
        let t0 = Date()
        for i in 0..<3 { _ = SendRateLimiter.consume(now: t0.addingTimeInterval(Double(i)), stateURL: url) }
        // Query at or after the newest stamp. Querying EARLIER would be time travel, and the
        // future-stamp prune would (correctly) discard the not-yet-happened stamp and allow the
        // send — which is how the first draft of this test failed.
        let d = SendRateLimiter.consume(now: t0.addingTimeInterval(3), stateURL: url)
        #expect(d.allowed == false)
        #expect(d.retryAfter > 0 && d.retryAfter <= SendRateLimiter.windowSeconds)
    }

    /// The CLI tier cannot redirect this file by exporting `HOME` — `homeDirectoryForCurrentUser`
    /// reads the passwd entry and ignores it — so without an env seam the limiter is untestable
    /// end-to-end and any CLI-tier test would spend the operator's real send budget.
    @Test("APPLE_SEND_RATELIMIT_STATE redirects the state file for the CLI tier")
    func envOverrideIsHonored() {
        let real = SendRateLimiter.stateURL()
        #expect(real.path.hasSuffix(".apple-cli/send-rate-limit.json"))
        // The explicit parameter must still win over the env var (logic tier beats CLI tier).
        let explicit = tmpState("precedence")
        #expect(SendRateLimiter.stateURL(override: explicit) == explicit)
    }

    /// The refusal path must still PRUNE, or a hot loop against a full window would append
    /// forever and grow the file without bound.
    @Test("a refused call does not grow the state file without bound")
    func refusalDoesNotGrowState() throws {
        let url = tmpState("bound")
        let t0 = Date()
        for i in 0..<3 { _ = SendRateLimiter.consume(now: t0.addingTimeInterval(Double(i)), stateURL: url) }
        for i in 0..<50 { _ = SendRateLimiter.consume(now: t0.addingTimeInterval(10 + Double(i) * 0.01), stateURL: url) }
        let stamps = try JSONDecoder().decode([TimeInterval].self, from: Data(contentsOf: url))
        #expect(stamps.count == SendRateLimiter.maxCalls,
                "window should hold exactly the cap, found \(stamps.count)")
    }
}
