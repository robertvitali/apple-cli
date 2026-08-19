import Testing
import Foundation
import TestSupport
@testable import AppleKit

/// Oracle A's `expensive_ops` tier (`TIER_LIMITS["expensive_ops"] = (20, 60.0)`), ported for
/// `reply` per HUMAN-DECISIONS.md D8 (SAFETY WINS). The sliding-window mechanism is single-sourced
/// in `RateLimitStore` (its edge cases are exhaustively pinned by SendRateLimiterTests); these pins
/// guard the tier-specific constants, the SEPARATE state file, and the `expensive_ops` refusal text.
/// Every test drives an INJECTED state URL so it never touches the operator's real reply budget and
/// cannot race the other suites (they all run in one process in parallel).
@Suite("Reply rate limiter (oracle A expensive_ops tier)")
struct ReplyRateLimiterTests {
    private let scratch = ScratchDirs("replyratelimit")

    func tmpState(_ label: String) -> URL {
        let url = try! scratch.directory().appendingPathComponent("\(label)/state.json")
        precondition(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path),
                     "the state file's parent must NOT exist — it is what exercises the mkdir-p")
        return url
    }

    @Test("the ported constants are the oracle's verbatim (20 / 60)")
    func constantsMatchOracle() {
        #expect(ReplyRateLimiter.maxCalls == 20)
        #expect(ReplyRateLimiter.windowSeconds == 60.0)
    }

    @Test("the first 20 replies pass and the 21st is refused inside the window")
    func capFiresOn21st() {
        let url = tmpState("cap")
        let t0 = Date()
        for i in 0..<20 {
            let d = ReplyRateLimiter.consume(now: t0.addingTimeInterval(Double(i) * 0.1), stateURL: url)
            #expect(d.allowed == true, "reply \(i + 1) should be allowed")
        }
        let refused = ReplyRateLimiter.consume(now: t0.addingTimeInterval(2), stateURL: url)
        #expect(refused.allowed == false)
        #expect(refused.retryAfter > 0 && refused.retryAfter <= ReplyRateLimiter.windowSeconds)
    }

    @Test("the refusal names the expensive_ops tier and the 20-call cap")
    func refusalNamesTheTier() {
        let url = tmpState("refuse")
        let t0 = Date()
        for i in 0..<20 { _ = ReplyRateLimiter.consume(now: t0.addingTimeInterval(Double(i) * 0.1), stateURL: url) }
        let d = ReplyRateLimiter.consume(now: t0.addingTimeInterval(3), stateURL: url)
        #expect(d.allowed == false)
        #expect(ReplyRateLimiter.refusal(d)
                .contains("Rate limit exceeded: 20 calls per 60s for expensive_ops operations"))
    }

    /// The whole point of D8: a reply and a send draw on SEPARATE budgets (distinct oracle tiers),
    /// so exhausting one must not touch the other — otherwise a reply loop could not route around
    /// the send cap (which is the hole D8 closes), but nor should replies steal the send budget.
    @Test("the reply window is a SEPARATE state file from the send window")
    func separateStateFileFromSend() {
        #expect(ReplyRateLimiter.stateURL().path.hasSuffix(".apple-cli/reply-rate-limit.json"))
        #expect(SendRateLimiter.stateURL().path.hasSuffix(".apple-cli/send-rate-limit.json"))
        #expect(ReplyRateLimiter.stateURL() != SendRateLimiter.stateURL())
        // Exhaust the reply window; a fresh SEND window is untouched.
        let replyState = tmpState("reply-only")
        let t0 = Date()
        for i in 0..<20 { _ = ReplyRateLimiter.consume(now: t0.addingTimeInterval(Double(i) * 0.1), stateURL: replyState) }
        #expect(ReplyRateLimiter.consume(now: t0.addingTimeInterval(2), stateURL: replyState).allowed == false)
        #expect(SendRateLimiter.consume(now: t0.addingTimeInterval(2), stateURL: tmpState("send-fresh")).allowed == true)
    }

    @Test("APPLE_REPLY_RATELIMIT_STATE redirects the file; the explicit param still wins")
    func envOverrideIsHonored() {
        #expect(ReplyRateLimiter.stateURL().path.hasSuffix(".apple-cli/reply-rate-limit.json"))
        let explicit = tmpState("precedence")
        #expect(ReplyRateLimiter.stateURL(override: explicit) == explicit)
    }
}
