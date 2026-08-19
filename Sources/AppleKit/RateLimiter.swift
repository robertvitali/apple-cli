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
/// ## The `expensive_ops` tier — RESOLVED for `reply` (HUMAN-DECISIONS.md D8, 2026-08-18)
///
/// `expensive_ops` is nine writes plus `search_messages` and `reply_to_message` (security.py:130-140).
/// D8 ruled SAFETY WINS: oracle A's 20/60s `expensive_ops` limit is now ported for `reply`
/// specifically (see `ReplyRateLimiter` below), closing the runaway-loop hole where a loop could
/// route around the `sends` cap by calling `reply` instead of `send`. 20 replies/60s burdens no
/// legitimate use and no test replies twice. Only `reply` is wired to this tier — the other
/// `expensive_ops` members (`search_messages`, `mark_as_read`, `delete_messages`, the rule ops …)
/// stay UNLIMITED for the same reason `cheap_reads` is not ported: throttling scripted reads/bulk
/// ops would remove capability the operator legitimately has and would break the bats suite, which
/// runs 300+ commands in well under a minute. The scoped D8 rule is: on an A-vs-B SAFETY-limit
/// disagreement (send rate, recipient caps, bulk caps on destructive ops), the stricter limit wins;
/// this is applied narrowly to the two surfaces that actually put unbounded mail on the wire.
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

    /// Kept as a member alias so existing `SendRateLimiter.Decision` references (and the CLI call
    /// sites reading `.allowed`/`.retryAfter`/`.degraded`) resolve unchanged after the sliding-window
    /// mechanism was single-sourced into `RateLimitStore`.
    public typealias Decision = RateLimitStore.Decision

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

    /// Record a send attempt and report whether it is allowed. Delegates the sliding-window
    /// mechanism to `RateLimitStore` so the `sends` and `expensive_ops` tiers share ONE
    /// implementation of the subtle edge cases (future-stamp prune, fail-open, atomic write).
    @discardableResult
    public static func consume(now: Date = Date(), stateURL url: URL? = nil) -> Decision {
        RateLimitStore.consume(now: now, stateURL: stateURL(override: url),
                               maxCalls: maxCalls, windowSeconds: windowSeconds)
    }

    /// The oracle's refusal text, adapted: `"Rate limit exceeded: {max} calls per {window}s for
    /// {tier} operations"` (security.py:192).
    public static func refusal(_ d: Decision) -> String {
        RateLimitStore.refusal(d, maxCalls: maxCalls, windowSeconds: windowSeconds, tier: "sends")
    }
}

/// Oracle A's `expensive_ops` tier (`TIER_LIMITS["expensive_ops"] = (20, 60.0)`), ported for
/// `reply` ONLY per HUMAN-DECISIONS.md D8 (2026-08-18, SAFETY WINS). `reply_to_message` is the
/// one `expensive_ops` member that puts UNBOUNDED mail on the wire, so leaving it uncapped let a
/// runaway loop route around `SendRateLimiter` by replying instead of sending. Same persistent
/// cross-invocation window as `SendRateLimiter` (a fresh CLI process per call — an in-memory deque
/// would never fire), in its OWN state file so a reply and a send do not share a budget (they are
/// different oracle tiers). 20/60s burdens no legitimate use and no test replies twice.
public enum ReplyRateLimiter {
    /// `TIER_LIMITS["expensive_ops"]` verbatim: 20 calls per 60 seconds.
    public static let maxCalls = 20
    public static let windowSeconds: TimeInterval = 60.0

    public typealias Decision = RateLimitStore.Decision

    /// Separate state file (`reply-rate-limit.json`) + separate env seam
    /// (`APPLE_REPLY_RATELIMIT_STATE`) so the reply window is independent of the send window —
    /// they are distinct oracle tiers with distinct caps. Precedence mirrors `SendRateLimiter`:
    /// explicit parameter (logic tier) → env var (CLI tier) → real home.
    public static func stateURL(override: URL? = nil) -> URL {
        if let override { return override }
        if let env = ProcessInfo.processInfo.environment["APPLE_REPLY_RATELIMIT_STATE"],
           !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".apple-cli", isDirectory: true)
        return base.appendingPathComponent("reply-rate-limit.json")
    }

    @discardableResult
    public static func consume(now: Date = Date(), stateURL url: URL? = nil) -> Decision {
        RateLimitStore.consume(now: now, stateURL: stateURL(override: url),
                               maxCalls: maxCalls, windowSeconds: windowSeconds)
    }

    /// Oracle's refusal text with the `expensive_ops` tier name, matching `check_rate_limit`'s
    /// `f"...for {tier} operations"` (security.py:192).
    public static func refusal(_ d: Decision) -> String {
        RateLimitStore.refusal(d, maxCalls: maxCalls, windowSeconds: windowSeconds,
                               tier: "expensive_ops")
    }
}

/// The single sliding-window implementation both `SendRateLimiter` (sends tier) and
/// `ReplyRateLimiter` (expensive_ops tier) delegate to. Extracted so the subtle, review-hardened
/// edge cases — the future-stamp prune, the loud fail-open, the atomic write, the refusal clamp —
/// live in ONE place rather than being copied per tier and drifting. The tier-specific constants
/// (`maxCalls`, `windowSeconds`), state-file path, and refusal tier name stay with each limiter.
public enum RateLimitStore {
    public struct Decision: Sendable {
        public let allowed: Bool
        /// Seconds until the oldest in-window call retires. Only meaningful when `!allowed`.
        public let retryAfter: TimeInterval
        /// True when the limiter could not read/write its state and FAILED OPEN.
        public let degraded: Bool
    }

    /// Record an attempt against `stateURL`'s sliding window and report whether it is allowed,
    /// pruning first.
    ///
    /// FAIL-OPEN, loudly. If the state file cannot be read or written (read-only HOME, exotic
    /// sandbox), this permits the operation and sets `degraded`, and the caller warns on stderr.
    /// Fail-CLOSED was considered and rejected: it would make the CLI unable to send at all on a
    /// machine where only the state directory is unwritable, which is a worse failure for the
    /// operator than a missing rate limit — and the runaway-loop case this guards always has a
    /// writable HOME.
    @discardableResult
    public static func consume(now: Date, stateURL path: URL,
                               maxCalls: Int, windowSeconds: TimeInterval) -> Decision {
        let cutoff = now.timeIntervalSince1970 - windowSeconds
        let nowTS = now.timeIntervalSince1970

        // Serialize the whole load→check→append→save across concurrent CLI PROCESSES with an
        // advisory lock. Without it this is a read-modify-write with no inter-process lock, so if
        // K processes all read the window before any of them writes it back, all K observe the same
        // pre-write count, all pass the `>= maxCalls` check, and all are allowed — the excess is K,
        // not one. Parallel fan-out is a plausible shape for the very runaway loop these caps exist
        // to bound (HUMAN-DECISIONS.md D8, security review 2026-08-18), so the sequential-only bound
        // the atomic write alone gives is not enough. Held across the whole critical section below;
        // released by `defer`. Best-effort: `acquireLock` returns -1 if the lock fd can't be opened
        // (unwritable state dir — already the fail-open case), and we then proceed UNLOCKED, which
        // reverts to the prior single-process-only bound rather than failing closed.
        let lockFD = acquireLock(path)
        defer { releaseLock(lockFD) }

        let stamps0: [TimeInterval]
        let loadDegraded: Bool
        switch load(path) {
        case .unreadable:
            return Decision(allowed: true, retryAfter: 0, degraded: true)
        case .corrupt:
            // Present but unparseable: reset to an empty window (below) but flag degraded so the
            // caller warns on stderr — a persistently-corrupt file must not SILENTLY reset the cap.
            stamps0 = []
            loadDegraded = true
        case .ok(let s):
            stamps0 = s
            loadDegraded = false
        }

        // Prune, exactly as the oracle's `while q and q[0] <= now - window: q.popleft()` — plus an
        // upper bound the oracle does not need. The oracle's `time.monotonic()` cannot run ahead of
        // itself; wall clock can. A FUTURE-dated stamp (forward clock jump, VM snapshot restore,
        // dead RTC, manual `date`) never satisfies `<= now - window`, so without this bound it
        // pins the window full and refuses EVERY call until the operator finds and deletes a JSON
        // file they have never heard of — permanently failing CLOSED in a component that
        // deliberately fails open, and precisely the outcome the corrupt-state note below rejects.
        // Discarding future stamps is safe: a stamp that has not happened yet cannot evidence an
        // operation that already went out. (Review-caught.)
        var stamps = stamps0.filter { $0 > cutoff && $0 <= nowTS }.sorted()

        if stamps.count >= maxCalls {
            let retry = (stamps.first ?? cutoff) + windowSeconds - nowTS
            // Persist the pruned window even on refusal so the file cannot grow without bound.
            let wrote = save(stamps, to: path)
            // Clamp: with the future-stamp bound above, `retry` cannot exceed the window, but the
            // clamp keeps the reported figure sane even if a stamp lands in the same instant.
            return Decision(allowed: false,
                            retryAfter: min(max(0, retry), windowSeconds),
                            degraded: !wrote || loadDegraded)
        }
        stamps.append(nowTS)
        let wrote = save(stamps, to: path)
        return Decision(allowed: true, retryAfter: 0, degraded: !wrote || loadDegraded)
    }

    /// The oracle's refusal text, adapted: `"Rate limit exceeded: {max} calls per {window}s for
    /// {tier} operations"` (security.py:192), plus the CLI's own `retry in Ns` addendum.
    public static func refusal(_ d: Decision, maxCalls: Int, windowSeconds: TimeInterval,
                               tier: String) -> String {
        "Rate limit exceeded: \(maxCalls) calls per \(Int(windowSeconds))s for \(tier) operations"
            + " — retry in \(Int(d.retryAfter.rounded(.up)))s."
    }

    // MARK: - State I/O

    /// Outcome of reading the state file. `.unreadable` ⇒ fail OPEN (allow, degraded); `.corrupt`
    /// ⇒ reset to an empty window BUT flag degraded (loud); `.ok` ⇒ the decoded window.
    private enum LoadResult {
        case ok([TimeInterval])
        case unreadable
        case corrupt
    }

    private static func load(_ path: URL) -> LoadResult {
        let fm = FileManager.default
        let dir = path.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            catch { return .unreadable }
        }
        guard fm.fileExists(atPath: path.path) else { return .ok([]) }   // first run: empty window
        guard let data = try? Data(contentsOf: path) else { return .unreadable }
        guard let stamps = try? JSONDecoder().decode([TimeInterval].self, from: data) else {
            // A corrupt/hand-edited/torn file resets the window rather than bricking sends, because
            // the alternative (refusing every call until the operator deletes a JSON file) is
            // worse. It is now flagged `.corrupt` so `consume` sets `degraded` and the caller warns
            // on stderr — a persistently-unparseable file must not silently reset the cap to zero on
            // every call with NO operator-visible signal (review-caught 2026-08-18). Legitimate
            // state is always the atomic write of a non-empty JSON array (`"[]"` at minimum), so a
            // 0-byte or garbage file only arises from a torn write or external tampering.
            //
            // THIS IS NOT A SECURITY BOUNDARY against a process that can write `$HOME`. Such a
            // process can `rm` this file, or write `[]`, before every call and reset the window each
            // time — so do not read the cap as a guarantee bounding a hostile local process. It is
            // not one, and it cannot be: the state has to live somewhere that process can reach.
            // What it bounds is the ACCIDENTAL case this was ported for — a runaway agent loop
            // calling `apple mail send` (or `reply`) repeatedly, which does not tamper because it is
            // not trying to. (An earlier draft claimed corruption "cannot be used to EXCEED the cap
            // beyond one window", which is simply false; review-caught.)
            return .corrupt
        }
        return .ok(stamps)
    }

    // MARK: - Cross-process advisory lock (serializes the read-modify-write)

    /// Acquire an exclusive advisory lock on a SIDECAR file next to the state file, so concurrent
    /// CLI processes serialize their whole `consume` critical section. Returns the held fd, or -1
    /// when the lock could not be taken (unwritable dir — caller then proceeds unlocked, reverting
    /// to the prior sequential-only bound rather than failing closed).
    ///
    /// A sidecar (`<state>.lock`) rather than the state file itself: opening the state file with
    /// `O_CREAT` would leave a 0-byte file that `load` reads as `.corrupt`. The lock file's content
    /// is irrelevant — it is purely a cross-process mutex handle. `flock` is per-open-description, so
    /// even two threads in ONE process that each `open()` it contend correctly. The sidecar is
    /// deliberately NEVER unlinked (removing it while a peer holds the lock re-opens the classic
    /// flock-unlink race — a new opener would lock a fresh inode while the holder still holds the
    /// old one); two tiny empty `.lock` files persisting in `~/.apple-cli/` is the cheap price.
    private static func acquireLock(_ statePath: URL) -> Int32 {
        let lockPath = statePath.appendingPathExtension("lock")
        let dir = lockPath.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // O_NOFOLLOW: belt-and-suspenders against a pre-planted symlink at the lock path (nothing
        // is ever written through this fd, so following one is harmless anyway — refusing is
        // cheaper than reasoning about it; a symlink here then just means "proceed unlocked").
        let fd = open(lockPath.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return -1 }
        // Blocking exclusive lock: peers serialize here. The held section is a tiny read+write, so
        // contention is brief; no LOCK_NB/timeout is needed. Retry EINTR — a signal landing during
        // the blocking wait must not silently drop this call to the unlocked (over-admitting) path.
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { close(fd); return -1 }
        }
        return fd
    }

    private static func releaseLock(_ fd: Int32) {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }

    private static func save(_ stamps: [TimeInterval], to path: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(stamps) else { return false }
        // Atomic write: a torn file on a crash would otherwise decode as corrupt and reset the
        // window. The cross-process read-modify-write race (K processes all reading before any
        // writes, all seeing the same pre-write count, all allowed) is now closed by the advisory
        // `flock` `consume` holds across the whole load→check→append→save — the excess-of-K
        // parallel-fan-out shape the D8 caps target is serialized to one-at-a-time (review-caught
        // 2026-08-18). `flock` is advisory and machine-local; the state dir is `$HOME/.apple-cli`
        // (local FS), where advisory locks are honored. This atomic write remains the crash-safety
        // half — the lock serializes writers, the atomic write keeps each writer's file un-torn.
        do { try data.write(to: path, options: .atomic); return true } catch { return false }
    }
}
