import Foundation

/// Oracle-mirrored SEND rate limit — the anti-spam cap from oracle A
/// (`apple_mail_mcp/security.py`: `TIER_LIMITS["sends"] = (3, 60.0)`, enforced by
/// `RateLimiter.check` / `check_rate_limit`).
///
/// BUCKET 1 (oracle-mirrored ⇒ applies UNCONDITIONALLY, sandbox or not).
///
/// ## Why this is a persistent file and not an in-memory deque
///
/// The oracle is a LONG-LIVED server process: its sliding window is an in-memory `deque` that
/// naturally spans many tool calls. This CLI is a FRESH PROCESS PER INVOCATION, so a literal
/// transcription of that design would start every `apple mail send` with an empty window and
/// **never once fire** — a limiter that exists in the code, passes its tests, and enforces
/// nothing. That is worse than not porting it, because it reads as protection. Cross-invocation
/// persistence is what makes the ported behavior real.
///
/// ## Divergence, stated rather than hidden: wall clock, not monotonic
///
/// The oracle uses `time.monotonic()`. A monotonic clock is per-boot and per-process and cannot be
/// compared across invocations, so a persistent port MUST use wall time. Consequence: a backward
/// system-clock jump can let extra sends through, and a forward jump can retire the window early.
/// Both are strictly less likely than the failure this guards (a runaway agent loop), and neither
/// is reachable by the loop itself.
///
/// ## Only the SENDS tier is ported. That is deliberate.
///
/// The oracle also defines `cheap_reads = (60, 60.0)` and `expensive_ops = (20, 60.0)`. Those exist
/// because ONE server process multiplexes an entire LLM session. Ported persistently to a CLI they
/// would throttle ordinary scripted use — and would break this repo's own bats suite, which runs
/// 300+ commands in well under a minute. Rate-limiting reads would remove capability the operator
/// legitimately has, which fails strict-superset in the opposite direction from dropping a gate.
/// The `sends` tier is the one whose stated purpose ("prevent spam") survives the process-model
/// change intact, and 3 sends/60s burdens no legitimate use.
///
/// ## The `expensive_ops` tier is UNRESOLVED, not settled (HUMAN-DECISIONS.md D8)
///
/// The paragraph above is airtight for `cheap_reads` and does NOT carry over to `expensive_ops`,
/// which is nine writes plus `search_messages` and `reply_to_message` (security.py:130-140). Two
/// consequences follow, and they are recorded rather than quietly resolved:
///   - `reply` is a real wire-send with NO limit here, where the oracle allows 20/60s. A runaway
///     loop — the stated threat — can simply use `reply` instead of `send`. 20 replies/60s would
///     burden nothing and no test replies twice, so "it would break the bats suite" does not
///     justify the omission; that argument lets a test-harness constraint set a product contract.
///   - `delete_messages` / `create_rule` in a loop are at least as damaging as `send_email`.
/// Against porting: under `AGENTS.md`'s asymmetry ("capabilities the CLI adds are welcome;
/// capabilities it drops are failures") a limit the oracle has and the CLI lacks means the CLI
/// permits MORE, which is ADDED capability and therefore allowed. So this is a SAFETY question,
/// not a parity question — which is exactly why it is the operator's call and not this file's.
///
/// ## `validate_email` deliberately NOT ported
///
/// `validate_send_operation` also rejects malformed addresses (security.py:83-86) before counting
/// them. That is not ported, and the omission is a decision rather than an oversight: the oracle's
/// regex is narrower than RFC 5321 (it rejects quoted local-parts and bare-TLD domains), so
/// transcribing it would REFUSE addresses both Mail.app and oracle B accept — dropping capability
/// to gain a check Mail itself performs at send time.
///
/// ## Only REAL sends consume budget
///
/// A `--dry-run` preview sends nothing, so it must not consume the window; otherwise previewing
/// four messages would block the first real one. Callers invoke `consume` on the EXECUTE path only.
public enum SendRateLimiter {
    /// `TIER_LIMITS["sends"]` verbatim: 3 calls per 60 seconds.
    public static let maxCalls = 3
    public static let windowSeconds: TimeInterval = 60.0

    /// Overridable so the logic tier never touches the operator's real state file, and so parallel
    /// swift-testing suites cannot race each other through a shared path.
    ///
    /// `APPLE_SEND_RATELIMIT_STATE` exists because the Swift-parameter override alone is not
    /// reachable from the CLI tier: `homeDirectoryForCurrentUser` reads the passwd entry and
    /// IGNORES `$HOME`, so a bats test cannot redirect this file by exporting `HOME` (verified —
    /// `HOME=$(mktemp -d)` still resolves the operator's real home). Without an env seam the
    /// limiter is untestable end-to-end and any CLI-tier test would consume the operator's real
    /// send budget. Precedence: explicit parameter (logic tier) → env var (CLI tier) → real home.
    public static func stateURL(override: URL? = nil) -> URL {
        if let override { return override }
        if let env = ProcessInfo.processInfo.environment["APPLE_SEND_RATELIMIT_STATE"],
           !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".apple-cli", isDirectory: true)
        return base.appendingPathComponent("send-rate-limit.json")
    }

    public struct Decision: Sendable {
        public let allowed: Bool
        /// Seconds until the oldest in-window call retires. Only meaningful when `!allowed`.
        public let retryAfter: TimeInterval
        /// True when the limiter could not read/write its state and FAILED OPEN.
        public let degraded: Bool
    }

    /// Record a send attempt and report whether it is allowed, pruning the sliding window first.
    ///
    /// FAIL-OPEN, loudly. If the state file cannot be read or written (read-only HOME, exotic
    /// sandbox), this permits the send and sets `degraded`, and the caller warns on stderr.
    /// Fail-CLOSED was considered and rejected: it would make the CLI unable to send at all on a
    /// machine where only the state directory is unwritable, which is a worse failure for the
    /// operator than a missing rate limit — and the runaway-loop case this guards always has a
    /// writable HOME.
    @discardableResult
    public static func consume(now: Date = Date(), stateURL url: URL? = nil) -> Decision {
        let path = stateURL(override: url)
        let cutoff = now.timeIntervalSince1970 - windowSeconds

        guard var stamps = load(path) else {
            return Decision(allowed: true, retryAfter: 0, degraded: true)
        }
        // Prune, exactly as the oracle's `while q and q[0] <= now - window: q.popleft()` — plus an
        // upper bound the oracle does not need. The oracle's `time.monotonic()` cannot run ahead of
        // itself; wall clock can. A FUTURE-dated stamp (forward clock jump, VM snapshot restore,
        // dead RTC, manual `date`) never satisfies `<= now - window`, so without this bound it
        // pins the window full and refuses EVERY send until the operator finds and deletes a JSON
        // file they have never heard of — permanently failing CLOSED in a component that
        // deliberately fails open, and precisely the outcome the corrupt-state note below rejects.
        // Discarding future stamps is safe: a stamp that has not happened yet cannot evidence a
        // send that already went out. (Review-caught.)
        let nowTS = now.timeIntervalSince1970
        stamps = stamps.filter { $0 > cutoff && $0 <= nowTS }.sorted()

        if stamps.count >= maxCalls {
            let retry = (stamps.first ?? cutoff) + windowSeconds - nowTS
            // Persist the pruned window even on refusal so the file cannot grow without bound.
            let wrote = save(stamps, to: path)
            // Clamp: with the future-stamp bound above, `retry` cannot exceed the window, but the
            // clamp keeps the reported figure sane even if a stamp lands in the same instant.
            return Decision(allowed: false,
                            retryAfter: min(max(0, retry), windowSeconds),
                            degraded: !wrote)
        }
        stamps.append(nowTS)
        let wrote = save(stamps, to: path)
        return Decision(allowed: true, retryAfter: 0, degraded: !wrote)
    }

    /// The oracle's refusal text, adapted: `"Rate limit exceeded: {max} calls per {window}s for
    /// {tier} operations"` (security.py:192).
    public static func refusal(_ d: Decision) -> String {
        "Rate limit exceeded: \(maxCalls) calls per \(Int(windowSeconds))s for sends operations"
            + " — retry in \(Int(d.retryAfter.rounded(.up)))s."
    }

    // MARK: - State I/O (nil return == could not read ⇒ fail open)

    private static func load(_ path: URL) -> [TimeInterval]? {
        let fm = FileManager.default
        let dir = path.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            catch { return nil }
        }
        guard fm.fileExists(atPath: path.path) else { return [] }   // first run: empty window
        guard let data = try? Data(contentsOf: path) else { return nil }
        // A corrupt/hand-edited file resets the window rather than bricking sends, because the
        // alternative (refusing every send until the operator deletes a JSON file) is worse.
        //
        // THIS IS NOT A SECURITY BOUNDARY against a process that can write `$HOME`. Such a process
        // can `rm` this file, or write `[]`, before every call and reset the window each time — so
        // do not read the cap as a guarantee bounding a hostile local process. It is not one, and
        // it cannot be: the state has to live somewhere that process can reach. What it bounds is
        // the ACCIDENTAL case this was ported for — a runaway agent loop calling `apple mail send`
        // repeatedly, which does not tamper because it is not trying to. (An earlier draft of this
        // comment claimed corruption "cannot be used to EXCEED the cap beyond one window", which is
        // simply false; review-caught.)
        return (try? JSONDecoder().decode([TimeInterval].self, from: data)) ?? []
    }

    private static func save(_ stamps: [TimeInterval], to path: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(stamps) else { return false }
        // Atomic write: a torn file on a crash would otherwise decode as corrupt and reset the
        // window.
        //
        // It is NOT an inter-process lock, and the concurrency bound is worse than it looks: this
        // is a read-modify-write, so if K processes all read before any of them writes, all K see
        // the same pre-write window and all K are allowed. The excess is K, not one. (An earlier
        // draft of this comment claimed "worst case one extra send per window", which understated
        // it; review-caught.) That matters because parallel fan-out is a plausible shape for the
        // very runaway loop this guards — sequential loops, the common case, are bounded correctly.
        // Accepted for now rather than fixed because the correct fix is an advisory `flock` around
        // load→save, which is a behavior change deserving its own commit and test; the oracle's
        // single-threaded deque offers no cross-process precedent to copy.
        do { try data.write(to: path, options: .atomic); return true } catch { return false }
    }
}
