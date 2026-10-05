import Darwin
import Foundation
import Testing
import TestSupport
@testable import AppleKit

/// Synthetic process fixtures only. No AppleScript or Apple applications run here.
/// Every descendant self-expires, including on the old launcher's expected RED paths.
/// These tests never signal a PID read from a file and do not use launchBounded's kill watchdog.
@Suite("owned process group cleanup")
struct OwnedProcessCleanupTests {
    private let scratch = ScratchDirs("owned-process-cleanup")

    private enum StopProbeFailure: Error, Equatable { case callLimit, clockRead }

    /// Signed milliseconds from `origin` to `stamp` for failure messages; never traps on order.
    private static func offset(_ stamp: UInt64, from origin: UInt64) -> String {
        stamp >= origin ? "\((stamp - origin) / 1_000_000) ms"
            : "-\((origin - stamp) / 1_000_000) ms"
    }

    /// The tenth of a second the drain test keeps in hand where it infers, from the decorator's
    /// stamp of the root's exit, that the launcher saw that exit before its two-second deadline
    /// (`insideDeadline`). The stamp and the deadline read one clock (`CLOCK_UPTIME_RAW`, which
    /// `DispatchTime` reads), so the margin is not for rounding: it covers the gap between the
    /// stamp and the launcher's next deadline check. The decorator stamps the exit as its `observe`
    /// returns and the launch loop checks its deadline right after that observation, so a correct
    /// launcher spends microseconds there; a runner that withholds the launcher's thread for most
    /// of a tenth between the two can still make the inference wrong, a residual.
    /// `ScriptLauncherTests` keeps the same margin for the same inference.
    ///
    /// Every other place in this file where a stamp is held to an event the launcher or the kernel
    /// timed on that clock (`starvedGate`, `signalledAtDeadline` and the completion tests' liveness
    /// set-aside) keeps only `DeschedulingProbe.clockRoundingNanoseconds`; the completion margins,
    /// the cleanup tests' margins (`returnedAt + cleanupMarginNanoseconds < expiresAt`),
    /// `cleanupSetAside`, `stopWindow` and `startMiss` keep none.
    private static let drainScenarioMargin: UInt64 = 100_000_000

    /// Why an attempt missed its scenario before the launcher's deadline started, or nil when it
    /// did not. Every gated test shares it. An attempt misses when the readiness gate released
    /// without readiness in a shape only starvation produces (`starvedGate`), or when the gate saw
    /// the descendant's file but the fixture had less than `lifeNeeded` seconds of life left at the
    /// spawn stamp, the time the attempt's checks may use after that stamp. On attempts 1 and 2,
    /// which call it, a correct launcher whose checks finish inside `lifeNeeded` therefore cannot
    /// be failed by a process dying of its own alarm. It reads only the gate's stamps and the arm
    /// stamps the fixture published before the gate released, all fixed while the launcher was
    /// still inside `spawn`, before its deadline started, so a miss says nothing about the
    /// launcher's deadline, delivery or cleanup. It is not blind to the launcher, though. The life
    /// left is measured to the spawn stamp, which the decorator takes only after the product's own
    /// `spawn` has returned, so it also spends whatever time that `spawn` takes to return after the
    /// root armed; and an alarm shape `starvedGate` accepts can follow a `spawn` that returned only
    /// after the root's alarm. An intermittently slow `spawn` can therefore be re-run on attempts 1
    /// and 2. A steady one reaches the last attempt, which does not call this and runs every
    /// check, so one that leaves too little life fails the margin or the readiness check there.
    /// Callers print a miss and re-run it at most twice.
    ///
    /// A gate that released without readiness in any other shape returns nil. The product's `spawn`
    /// sets up the child's descriptors, signal mask and defaults and process group before the gate
    /// begins, so such an exit may be the product's doing; the caller's readiness `#require`, which
    /// names the exit, then fails the attempt on whichever attempt it happens.
    ///
    /// The last attempt does not call it: it requires readiness and runs every product check
    /// whatever the life left, so there a gate that released late can still fail a correct
    /// launcher's margin, stop-window or liveness check (a residual).
    private static func startMiss(_ children: SpawnStampingChildren, _ fixture: Fixture,
                                  spawnedAt: UInt64, lifeNeeded seconds: UInt64) throws -> String? {
        guard children.readyAt != nil else {
            let gate = starvedGate(children, fixture)
            guard gate.starved else { return nil }
            return "\(children.readinessMiss) (\(gate.reason)); \(fixture.startupProgress())"
        }
        let expiresAt = try fixture.earliestNaturalExpiry()
        guard expiresAt < spawnedAt || expiresAt - spawnedAt < seconds * 1_000_000_000 else {
            return nil
        }
        let rootArmed = try fixture.armedAt("root")
        return "the gate released \(offset(spawnedAt, from: rootArmed)) after the root armed, "
            + "leaving \(offset(expiresAt, from: spawnedAt)) of fixture life, "
            + "under the \(seconds) s the checks need"
    }

    /// Requires, on every attempt whose gate saw readiness, that the fixture's arm stamps fall in
    /// the window the decorator's own stamps bound, as they do by construction when both read one
    /// clock: the call into `spawn` precedes the root's start, so its arm stamp; the root arms
    /// before it forks the descendant, which arms after the fork; and the descendant publishes its
    /// arm stamp before the identity file the gate waits for, so before `spawnedAt`. The decorator
    /// reads `CLOCK_UPTIME_RAW`; a fixture stamp on another clock (a partial migration, such as
    /// `time.CLOCK_MONOTONIC`) is off by the host's accumulated sleep or slew and lands outside the
    /// window whenever that offset exceeds the window's own slack. That is a harness defect, not a
    /// launcher fault, so it fails the attempt on any attempt, before `startMiss` or a timed check
    /// can misread the stamps. A gate that released without readiness is left to `starvedGate`.
    private static func requireOneClock(_ children: SpawnStampingChildren, _ fixture: Fixture,
                                        spawnedAt: UInt64,
                                        sourceLocation: SourceLocation = #_sourceLocation) throws {
        guard children.readyAt != nil, let called = children.gateRecord.called else { return }
        let rootArmed = try fixture.armedAt("root")
        let descendantArmed = try fixture.armedAt("descendant")
        let ordered = called <= rootArmed && rootArmed <= descendantArmed
            && descendantArmed <= spawnedAt
        try #require(ordered, """
            the fixture's arm stamps and the decorator's stamps are not on one clock: expected \
            the spawn call <= the root's arm stamp <= the descendant's <= the spawn return, got \
            the root armed \(offset(rootArmed, from: called)) and the descendant armed \
            \(offset(descendantArmed, from: called)) after the spawn call, which returned \
            \(offset(spawnedAt, from: called)) after it; the decorator reads CLOCK_UPTIME_RAW, \
            so the fixture must read time.CLOCK_UPTIME_RAW
            """, sourceLocation: sourceLocation)
    }

    /// Whether a gate that released without readiness did so in a shape only starvation produces,
    /// and the evidence either way. Two shapes qualify. The bound ran out while every observation
    /// found the root alive: start-up was still running. Or the exit was a fixture alarm firing on
    /// time: the root killed by SIGALRM no sooner than its expiry after it armed, or the root
    /// exiting 91 (its handshake read EOF: the descendant died before its ready byte) no sooner
    /// than the descendant's expiry after the descendant armed. Each arm time is bounded from below
    /// by a stamp read before it: the process's own arm stamp when published, else the root's arm
    /// stamp (the descendant forks after it) or the moment `spawn` was called (the root arms after
    /// it). Any other exit, and any failed observation, is not starvation: it may come from the
    /// product's `spawn`, which set the child up before the gate began. The launch result is not
    /// consulted: against a root that is still starting or already dead, a correct launcher can
    /// time out, fail its delivery or report the alarm's status, so the result cannot tell
    /// starvation from a regression.
    ///
    /// "No sooner" keeps `DeschedulingProbe.clockRoundingNanoseconds` in hand. These stamps and the
    /// kernel's alarm timer read one clock (uptime), but per XNU's published source the kernel arms
    /// the alarm from the uptime truncated to whole microseconds, so a genuine alarm can fire up to
    /// about a microsecond before its computed due time, and a hard comparison could fail a correct
    /// launcher on attempt 1 or 2. No exit the product's `spawn` causes lands that close to a
    /// twelve- or thirty-second alarm, so the allowance re-runs nothing a regression produces.
    private static func starvedGate(_ children: SpawnStampingChildren, _ fixture: Fixture)
        -> (starved: Bool, reason: String) {
        let gate = children.gateRecord
        if gate.observeFailed {
            return (false, "an observation of the root failed while the gate held")
        }
        guard let exited = gate.rootExited else {
            return (true, "every observation found the root alive")
        }
        let second: UInt64 = 1_000_000_000
        let rootArmed = try? fixture.armedAt("root")
        if gate.code == CLD_KILLED && gate.status == SIGALRM {
            guard let armed = rootArmed ?? gate.called else {
                return (false, "the root died of SIGALRM, but no stamp bounds when it armed")
            }
            let due = armed + UInt64(fixture.expiry(of: "root")) * second
            guard exited + DeschedulingProbe.clockRoundingNanoseconds >= due else {
                return (false, "SIGALRM seen \(offset(due, from: exited)) before the root's "
                    + "alarm was due")
            }
            return (true, "the root's own alarm, seen \(offset(exited, from: due)) after it "
                + "was due")
        }
        if gate.code == CLD_EXITED && gate.status == 91 {
            guard let armed = (try? fixture.armedAt("descendant")) ?? rootArmed else {
                return (false, "the handshake failed, but no stamp bounds the descendant's arming")
            }
            let due = armed + UInt64(fixture.expiry(of: "descendant")) * second
            guard exited + DeschedulingProbe.clockRoundingNanoseconds >= due else {
                return (false, "the handshake failed \(offset(due, from: exited)) before the "
                    + "descendant's alarm was due")
            }
            return (true, "the descendant's own alarm ended the handshake, seen "
                + "\(offset(exited, from: due)) after it was due")
        }
        return (false, "not an exit starvation produces")
    }

    /// The failure message for an attempt that requires readiness the gate never saw.
    private static func unready(_ children: SpawnStampingChildren, _ fixture: Fixture) -> String {
        "the fixture never published readiness (\(children.readinessMiss); "
            + "\(starvedGate(children, fixture).reason); \(fixture.startupProgress()))"
    }

    /// Whether the launcher's pause after SIGTERM ended at its `seconds`, judged from the
    /// launcher's own turns as `ProcessResourceTests.eventualReapTransfer` judges its windows. The
    /// pause checks its deadline before each observation, so the first observation follows the
    /// moment the deadline was set, and every observation before the last precedes a check that
    /// found the deadline unexpired: the second-to-last is less than `seconds` after the first
    /// under any load, because a stall can only drop turns from that span. The check rests on one
    /// observation per pause turn, as the launcher makes.
    ///
    /// Residual: fewer than three turns leave it unmeasured, which in a correct launcher only a
    /// stall nearly as long as the pause causes; a wait outside the loop, or one turn as long as
    /// the pause, is still caught only by the ten-second bound. Records an issue unless cleanup
    /// sent SIGTERM and then SIGKILL.
    @discardableResult
    private static func pauseEnded(_ children: SpawnStampingChildren,
                                   within seconds: Double) -> Bool {
        guard let pause = children.termPause else {
            Issue.record("cleanup must signal the owned group with SIGTERM, then SIGKILL")
            return false
        }
        return windowEnded(pause, within: seconds, "the pause after SIGTERM")
    }

    /// Whether the launcher's deadline ended at its `seconds`, judged from its own turns as
    /// `pauseEnded` judges the pause. The launch loop sets its deadline before its first
    /// observation and checks it after each one, so every loop observation before the last
    /// (`deadlineTurns` already leaves out the check `signal` makes before SIGTERM) preceded a
    /// check that found the deadline unexpired: the second-to-last is less than `seconds` after the
    /// first under any load. The reported seconds are the configured value whatever the deadline
    /// was, and the drain's checks are lower bounds, so without this check only the ten-second
    /// bound would limit the deadline, and a deadline three times as long would pass it.
    ///
    /// Residual: fewer than three turns, a wait before the deadline is set, or one turn as long as
    /// the deadline is still caught only by the ten-second bound. Records an issue unless cleanup
    /// sent SIGTERM.
    @discardableResult
    private static func deadlineEnded(_ children: SpawnStampingChildren,
                                      within seconds: Double) -> Bool {
        guard let deadline = children.deadlineTurns else {
            Issue.record("cleanup must signal the owned group with SIGTERM when the deadline ends")
            return false
        }
        return windowEnded(deadline, within: seconds, "the launcher's deadline")
    }

    /// Whether a window of the launcher's own turns ended at `seconds`: its second-to-last turn
    /// came less than `seconds` after its first. `pauseEnded` and `deadlineEnded` share it. Under
    /// three turns it is unmeasured and true. Records an issue naming `what` when the window ran
    /// long.
    private static func windowEnded(_ window: [DispatchTime], within seconds: Double,
                                    _ what: String) -> Bool {
        guard window.count >= 3 else { return true }
        let first = window[0]
        let last = window[window.count - 2]
        let span = (Double(last.uptimeNanoseconds) - Double(first.uptimeNanoseconds)) / 1e9
        let ended = last < first + seconds
        #expect(ended, Comment(rawValue: "\(what) must end at \(seconds) s "
                + "(still observing after \(span) s)"))
        return ended
    }

    /// Test-only decorator over the real child operations that stamps, on `CLOCK_UPTIME_RAW` (the
    /// clock the fixture's own observations use), when `spawn` returned, when the launcher first
    /// observed the root's exit, and when cleanup first signalled the group. Timing assertions then
    /// compare event order on one clock instead of a stopwatch that also measures process start-up
    /// on a loaded runner. It also stamps each observation and group signal on `DispatchTime`, the
    /// clock the launcher's deadline and pause read, so `deadlineEnded` and `pauseEnded` judge them
    /// from the launcher's own turns.
    ///
    /// With `readyFile`, `spawn` also holds the launcher, whose deadline starts when `spawn`
    /// returns, until the fixture has published that file, so start-up falls outside the deadline.
    /// The gated tests wait for the descendant's file, which the fixture publishes before the root
    /// reads stdin, so the fork and the descendant's start-up are outside the deadline too. While
    /// the gate holds, the launcher is still inside `spawn`: it has not started its deadline,
    /// delivered stdin, observed the root or signalled, so a gate that expires says nothing about
    /// it. `readyAt` records when the file was seen and stays nil otherwise; `readinessMiss` says
    /// why.
    ///
    /// The hold ends early once the root has exited without the descendant's file, since that root
    /// can never publish. The exit is read through the real backend's `waitid(WNOWAIT)`, the same
    /// non-consuming observation the launcher makes, so the root stays waitable for the launcher
    /// and this decorator's own exit stamp is untouched. The descendant publishes before the root
    /// can pass its handshake, so the file is checked once more after an exit is seen; a root that
    /// finished after readiness (a completion test on `/dev/null` stdin) still counts as ready. The
    /// gate also records when `spawn` was called, the exit's `si_code` (also read with `WNOWAIT`)
    /// and any failed observation, so `starvedGate` re-runs only the shapes starvation produces:
    /// the product's `spawn` sets up the child's descriptors, signal mask and defaults and process
    /// group before the gate begins, so an exit it caused must fail the attempt rather than be
    /// discarded with it.
    ///
    /// The hold is bounded at sixty seconds (`readinessLimitSeconds`). A re-run starts a fresh
    /// interpreter and discards the start-up already done, so under sustained starvation a long
    /// hold on a live root is worth more than another short attempt, and because a dead root
    /// releases at once, the bound only ever waits on live start-up. A longer bound would not help:
    /// every gated root arms its thirty-second alarm before `import ctypes`, and that alarm's exit
    /// already releases the gate, so a longer hold would only wait on an interpreter that has not
    /// reached the script. Raising the alarms past a longer bound would lengthen every red path's
    /// teardown, and every miss would pay the longer hold on each attempt.
    ///
    /// Nothing after a successful spawn can throw, the clock read included, so the child is never
    /// hidden from the launcher.
    private final class SpawnStampingChildren: ScriptProcessChildren, @unchecked Sendable {
        static let readinessLimitSeconds: UInt64 = 60
        private let real = DarwinScriptProcessChildren()
        private let readyFile: String?
        private let lock = NSLock()
        private var stamps: (spawned: UInt64?, pid: pid_t?, group: pid_t?, ready: UInt64?,
                             exitObserved: UInt64?, firstSignal: UInt64?)
            = (nil, nil, nil, nil, nil, nil)
        /// When `spawn` was called and when it returned to the gate; when the gate ended early,
        /// when it saw the root's exit, the status the backend reported (an exit code or a signal
        /// number) and the `si_code` that tells the two apart; and whether an observation failed
        /// while the gate held. All are fixed before the launcher's deadline.
        typealias GateRecord = (called: UInt64?, opened: UInt64?, rootExited: UInt64?,
                                status: Int32?, code: Int32?, observeFailed: Bool)
        private var gate: GateRecord = (nil, nil, nil, nil, nil, false)
        /// Each observation and group signal the launcher made, in order, stamped on
        /// `DispatchTime`.
        private var turns: [(signal: Int32?, at: DispatchTime)] = []
        var reaper: any ScriptProcessReaping { real.reaper }

        init(readyFile: String? = nil) { self.readyFile = readyFile }

        /// Nanoseconds on `CLOCK_UPTIME_RAW`, as `RecordedChildren` reads them. It cannot throw, so
        /// nothing between a successful spawn and its return can strand the child; a failed read
        /// returns zero, which fails the elapsed checks instead of passing.
        private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

        /// The `si_code` of the root's exit (`CLD_EXITED`, `CLD_KILLED`, ...), read with `WNOWAIT`
        /// like the backend's observation, so the root stays waitable for the launcher; nil when
        /// the read fails.
        private static func exitCode(of pid: pid_t) -> Int32? {
            var information = siginfo_t()
            while waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT) != 0 {
                guard errno == EINTR else { return nil }
            }
            return information.si_pid == pid ? information.si_code : nil
        }

        /// A production launcher whose child operations run through this decorator.
        var launcher: OsascriptLauncher {
            var dependencies = ScriptProcessDependencies()
            dependencies.children = self
            return OsascriptLauncher(dependencies: dependencies)
        }

        var spawnedAt: UInt64? { lock.withLock { stamps.spawned } }
        var spawnedPID: pid_t? { lock.withLock { stamps.pid } }
        /// The process group the root led when `spawn` returned (read while it is alive).
        var spawnedGroup: pid_t? { lock.withLock { stamps.group } }
        /// When the readiness gate saw `readyFile`; nil when its bound ran out, or the root exited,
        /// first (`readinessMiss` says which).
        var readyAt: UInt64? { lock.withLock { stamps.ready } }
        var exitObservedAt: UInt64? { lock.withLock { stamps.exitObserved } }
        var firstSignalAt: UInt64? { lock.withLock { stamps.firstSignal } }
        /// What the gate recorded (see `GateRecord`), for `starvedGate`.
        var gateRecord: GateRecord { lock.withLock { gate } }

        /// The launcher's pause after SIGTERM as its own turns: the observations it made between
        /// its first SIGTERM and its first SIGKILL, less the last, which is the check `signal`
        /// makes after the pause has ended, just before it sends SIGKILL. Nil unless SIGTERM came
        /// first.
        var termPause: [DispatchTime]? {
            lock.withLock {
                guard let term = turns.firstIndex(where: { $0.signal == SIGTERM }),
                      let kill = turns.firstIndex(where: { $0.signal == SIGKILL }), term < kill
                else { return nil }
                return Array(turns[(term + 1)..<kill].filter { $0.signal == nil }
                    .map { $0.at }.dropLast())
            }
        }

        /// The launcher's deadline as its own turns: the observations it made before its first
        /// SIGTERM, less the last, which is the check `signal` makes just before it sends SIGTERM.
        /// Nil unless SIGTERM was sent.
        var deadlineTurns: [DispatchTime]? {
            lock.withLock {
                guard let term = turns.firstIndex(where: { $0.signal == SIGTERM }) else {
                    return nil
                }
                return Array(turns[..<term].filter { $0.signal == nil }
                    .map { $0.at }.dropLast())
            }
        }

        /// Why the gate released without readiness, for scenario-miss reports and failure messages.
        var readinessMiss: String {
            lock.withLock {
                guard let exited = gate.rootExited, let opened = gate.opened else {
                    return "readiness gate expired after \(Self.readinessLimitSeconds) s"
                }
                let status: String = gate.status.map { "\($0)" } ?? "?"
                let how: String = gate.code == CLD_EXITED ? "exited with status \(status)"
                    : gate.code == CLD_KILLED ? "was killed by signal \(status)"
                    : "ended (wait status \(status))"
                let after: String = OwnedProcessCleanupTests.offset(exited, from: opened)
                return "readiness gate released early: the root \(how) \(after) after spawn, "
                    + "before the descendant published"
            }
        }

        func spawn(_ invocation: ScriptInvocation, input: Int32, output: Int32, error: Int32) throws -> pid_t {
            let called = Self.now()
            let pid = try real.spawn(invocation, input: input, output: output, error: error)
            // Nothing below can throw, so a spawned root always reaches the launcher.
            var ready: UInt64?
            if let readyFile {
                let opened = Self.now()
                lock.withLock {
                    if gate.opened == nil { (gate.called, gate.opened) = (called, opened) }
                }
                let limit = opened + Self.readinessLimitSeconds * 1_000_000_000
                while true {
                    if FileManager.default.fileExists(atPath: readyFile) {
                        ready = Self.now()
                        break
                    }
                    // An observation error is not an exit: keep waiting, and let the bound decide.
                    // The error is recorded, and a gate that saw one is not a starvation miss.
                    let observed: Int32?
                    do { observed = try real.observe(pid) } catch {
                        lock.withLock { gate.observeFailed = true }
                        observed = nil
                    }
                    if let status = observed {
                        if FileManager.default.fileExists(atPath: readyFile) {
                            ready = Self.now()
                        } else {
                            let at = Self.now()
                            let code = Self.exitCode(of: pid)
                            lock.withLock {
                                if gate.rootExited == nil {
                                    (gate.rootExited, gate.status, gate.code) = (at, status, code)
                                }
                            }
                        }
                        break
                    }
                    guard Self.now() < limit else { break }
                    usleep(5_000)
                }
            }
            let group = getpgid(pid)
            let at = Self.now()
            lock.withLock {
                if stamps.spawned == nil {
                    (stamps.spawned, stamps.pid, stamps.group, stamps.ready) =
                        (at, pid, group, ready)
                }
            }
            return pid
        }

        func observe(_ pid: pid_t) throws -> Int32? {
            let turn = DispatchTime.now()
            lock.withLock { turns.append((signal: nil, at: turn)) }
            let status = try real.observe(pid)
            if status != nil {
                let at = Self.now()
                lock.withLock { if stamps.exitObserved == nil { stamps.exitObserved = at } }
            }
            return status
        }

        func signal(group: pid_t, signal: Int32) throws {
            let turn = DispatchTime.now()
            let at = Self.now()
            lock.withLock {
                turns.append((signal: signal, at: turn))
                if stamps.firstSignal == nil { stamps.firstSignal = at }
            }
            try real.signal(group: group, signal: signal)
        }
    }

    @Test("a forward wall-clock jump cannot shorten fixture expiry observation")
    func forwardWallJumpDoesNotShortenExpiryWait() throws {
        // Every effectful endpoint below is synthetic. No directory is created.
        let fixture = Fixture(directory: URL(fileURLWithPath: "/synthetic/unused"))
        let expected = Fixture.Identity(pid: 123, seconds: 456, microseconds: 789)
        var wall: TimeInterval = 1000
        var elapsed: TimeInterval = 100
        var pauses = 0
        var observations = 0
        var matchingIdentity = true
        var result: Bool?
        do {
            result = try fixture.stops(expected, within: 16,
                wallNow: { wall }, monotonicNow: { elapsed },
                observe: { identity in
                    observations += 1
                    guard observations <= 20 else { throw StopProbeFailure.callLimit }
                    matchingIdentity = matchingIdentity && identity.pid == expected.pid
                        && identity.seconds == expected.seconds
                        && identity.microseconds == expected.microseconds
                    return elapsed < 110
                }, pause: {
                    pauses += 1
                    guard pauses <= 16 else { throw StopProbeFailure.callLimit }
                    elapsed += 1
                    wall = 2000
                })
        } catch StopProbeFailure.callLimit {
            // A bounded fixture guard is never the expected helper outcome.
        }
        #expect(result == true)
        #expect(pauses == 10)
        #expect(observations == 11)
        #expect(matchingIdentity)
    }

    @Test("a backward wall-clock jump cannot extend fixture expiry observation")
    func backwardWallJumpDoesNotExtendExpiryWait() throws {
        let fixture = Fixture(directory: URL(fileURLWithPath: "/synthetic/unused"))
        let expected = Fixture.Identity(pid: 123, seconds: 456, microseconds: 789)
        var wall: TimeInterval = 1000
        var elapsed: TimeInterval = 100
        var pauses = 0
        var observations = 0
        var matchingIdentity = true
        var result: Bool?
        do {
            result = try fixture.stops(expected, within: 16,
                wallNow: { wall }, monotonicNow: { elapsed },
                observe: { identity in
                    observations += 1
                    guard observations <= 4 else { throw StopProbeFailure.callLimit }
                    matchingIdentity = matchingIdentity && identity.pid == expected.pid
                        && identity.seconds == expected.seconds
                        && identity.microseconds == expected.microseconds
                    return true
                }, pause: {
                    pauses += 1
                    guard pauses <= 2 else { throw StopProbeFailure.callLimit }
                    elapsed += 8
                    wall = 900
                })
        } catch StopProbeFailure.callLimit {
            // A prolonged wait reaches this guard instead of its elapsed deadline.
        }
        #expect(result == false)
        #expect(pauses == 2)
        #expect(observations == 3)
        #expect(matchingIdentity)
    }

    @Test("fixture expiry retains its final observation at the exact elapsed deadline")
    func exactElapsedDeadlineRetainsFinalObservation() throws {
        let fixture = Fixture(directory: URL(fileURLWithPath: "/synthetic/unused"))
        let expected = Fixture.Identity(pid: 123, seconds: 456, microseconds: 789)
        var elapsed: TimeInterval = 100
        var pauses = 0
        var observations = 0
        var wallReads = 0
        var matchingIdentity = true
        let result = try fixture.stops(expected, within: 16,
            wallNow: { wallReads += 1; return 1000 }, monotonicNow: { elapsed },
            observe: { identity in
                observations += 1
                guard observations <= 3 else { throw StopProbeFailure.callLimit }
                matchingIdentity = matchingIdentity && identity.pid == expected.pid
                    && identity.seconds == expected.seconds
                    && identity.microseconds == expected.microseconds
                return elapsed < 116
            }, pause: {
                pauses += 1
                guard pauses <= 2 else { throw StopProbeFailure.callLimit }
                elapsed += 8
            })
        #expect(result)
        #expect(pauses == 2)
        #expect(observations == 3)
        #expect(elapsed == 116)
        #expect(wallReads == 0)
        #expect(matchingIdentity)
    }

    @Test("fixture expiry propagates elapsed-clock errors without wall-clock fallback",
          arguments: [false, true])
    func elapsedClockErrorsPropagate(afterPause: Bool) throws {
        let fixture = Fixture(directory: URL(fileURLWithPath: "/synthetic/unused"))
        let expected = Fixture.Identity(pid: 123, seconds: 456, microseconds: 789)
        var clockReads = 0
        var wallReads = 0
        var pauses = 0
        var observations = 0
        var matchingIdentity = true
        #expect(throws: StopProbeFailure.clockRead) {
            _ = try fixture.stops(expected, within: 16,
                wallNow: { wallReads += 1; return 1000 },
                monotonicNow: {
                    clockReads += 1
                    if !afterPause || clockReads == 2 { throw StopProbeFailure.clockRead }
                    guard clockReads <= 2 else { throw StopProbeFailure.callLimit }
                    return 100
                }, observe: { identity in
                    observations += 1
                    guard observations <= 1 else { throw StopProbeFailure.callLimit }
                    matchingIdentity = matchingIdentity && identity.pid == expected.pid
                        && identity.seconds == expected.seconds
                        && identity.microseconds == expected.microseconds
                    return true
                }, pause: {
                    pauses += 1
                    guard pauses <= 1 else { throw StopProbeFailure.callLimit }
                })
        }
        #expect(clockReads == (afterPause ? 2 : 1))
        #expect(observations == (afterPause ? 1 : 0))
        #expect(pauses == (afterPause ? 1 : 0))
        #expect(wallReads == 0)
        #expect(matchingIdentity)
    }

    /// The elapsed bound of the tests whose subject is that cleanup stops the owned group (the
    /// output-overflow, timeout and drain-timeout tests), from the spawn stamp to the return. Each
    /// test's comment gives its derivation.
    private static let cleanupBoundNanoseconds: UInt64 = 10_000_000_000

    /// How long before the fixture's earliest natural expiry those tests' launches must return, so
    /// a launcher that waits for natural expiry fails however long start-up took.
    private static let cleanupMarginNanoseconds: UInt64 = 1_000_000_000

    /// The most of one recorded stall a `DeschedulingProbe` misses: a lapse counts from when its
    /// tick should have ended, so up to one 50 ms tick of the stall before that goes unseen. The
    /// completion tests keep the same tick inside their thresholds; `cleanupSetAside` grants it
    /// once, and only when the probe recorded a stall in the span. The cleanup bound keeps six
    /// seconds or more above the launcher's own worst case, which absorbs the tick the probe can
    /// miss of each further stall.
    private static let stallUndercountNanoseconds: UInt64 = 50_000_000

    /// What the probe must see withheld from the spawn stamp to cleanup's first group signal (to
    /// the return when cleanup sent none) before the output-limit test's `TimeoutError` is set
    /// aside on attempt 1 or 2, as `completionTimeoutWithheldNanoseconds` is for the completion
    /// tests. A correct launcher sees the overflow within milliseconds of the spawn stamp: the
    /// root's stdin is `/dev/null` or one byte, and its overflowing write follows its read at once,
    /// or the descendant's follows its 10 ms poll for the root's exit. The launch loop checks the
    /// deadline before the output, so a correct launcher reports the thirty-second deadline instead
    /// of the overflow only when nearly all of the deadline was withheld before it saw the
    /// overflow: thirty seconds less one for its own work before that observation and for the
    /// probe's undercount. The span ends at that signal, which the decorator stamps just before
    /// sending it, after the timeout was thrown, so a stall in the cleanup that follows, which
    /// cannot explain a timeout already thrown, is not counted.
    private static let overflowTimeoutWithheldNanoseconds: UInt64 = 29_000_000_000

    /// Why an attempt of a cleanup test (output overflow, timeout, drain timeout) is set aside, or
    /// nil when it is not. Callers ask only on attempts 1 and 2, and only after every product
    /// check has run and held. Nil when no timed check failed, and nil when any failed timed check
    /// lacks its own evidence. A crossed bound or margin (`returnHeld` false) needs the probe to
    /// have recorded a stall from the spawn stamp to the return, and the time from the spawn stamp
    /// to the return that it did not see withheld (`withheld` covers that same span) to stay
    /// inside both checks: under `cleanupBoundNanoseconds`, and `cleanupMarginNanoseconds` before
    /// the earliest natural expiry, each granted `stallUndercountNanoseconds`. The probe never
    /// observes the launcher, so a launcher that waits too long on a runner that is running the
    /// test crosses the bound by time the probe did not see withheld and still fails. `timeout`,
    /// the output-limit test's `TimeoutError` with its own evidence (`overflowTimeout`), joins as a
    /// reason of its own. Each reason carries its elapsed and withheld seconds.
    private static func cleanupSetAside(returnHeld: Bool, spawnedAt: UInt64, returnedAt: UInt64,
                                        expiresAt: UInt64, withheld: UInt64,
                                        timeout: String? = nil) -> String? {
        var reasons: [String] = []
        if !returnHeld {
            guard spawnedAt <= returnedAt, withheld > 0 else { return nil }
            let elapsed = returnedAt - spawnedAt
            let covered = withheld + stallUndercountNanoseconds
            guard elapsed < cleanupBoundNanoseconds + covered,
                  returnedAt + cleanupMarginNanoseconds < expiresAt + covered else { return nil }
            let expiry = side(of: expiresAt, from: spawnedAt)
            reasons.append("the \(DeschedulingProbe.seconds(cleanupBoundNanoseconds)) s bound or "
                + "the \(DeschedulingProbe.seconds(cleanupMarginNanoseconds)) s margin before "
                + "natural expiry was crossed (\(DeschedulingProbe.seconds(elapsed)) s from the "
                + "spawn stamp to the return, \(DeschedulingProbe.seconds(withheld)) s of it "
                + "withheld by the runner, earliest natural expiry "
                + "\(DeschedulingProbe.seconds(expiry.gap)) s \(expiry.word) the spawn stamp)")
        }
        if let timeout { reasons.append(timeout) }
        return reasons.isEmpty ? nil : reasons.joined(separator: "; ")
    }

    /// The output-limit test's `TimeoutError` as a reason to set its attempt aside, or nil when it
    /// is not one. It is one only on attempt 1 or 2, for a launch that timed out while the probe
    /// saw at least `overflowTimeoutWithheldNanoseconds` withheld from the spawn stamp to
    /// `firstSignalAt`, cleanup's first group signal, or to the return when cleanup sent none; the
    /// reason carries the elapsed and withheld seconds of that span. Nil for every other result,
    /// which the caller then requires to be the overflow. The reason sets the attempt aside only
    /// through `cleanupSetAside`, after every product check has run and held; otherwise the caller
    /// records it as a failure.
    private static func overflowTimeout(_ result: Result<ScriptOutcome, any Error>,
                                        _ runner: DeschedulingProbe, spawnedAt: UInt64,
                                        firstSignalAt: UInt64?, returnedAt: UInt64,
                                        lastAttempt: Bool) -> String? {
        guard !lastAttempt, case .failure(let error) = result,
              let timeout = error as? AppleScriptRunner.TimeoutError else { return nil }
        let end = firstSignalAt ?? returnedAt
        let withheld = runner.lapsed(from: spawnedAt, to: end)
        guard withheld >= overflowTimeoutWithheldNanoseconds else { return nil }
        let elapsed = spawnedAt <= end ? end - spawnedAt : 0
        let threshold = DeschedulingProbe.seconds(overflowTimeoutWithheldNanoseconds)
        let ending = firstSignalAt == nil ? "the return" : "cleanup's first group signal"
        return "the launch timed out (\(timeout)) instead of reporting the overflow while the "
            + "runner withheld at least the \(threshold) s threshold "
            + "(\(DeschedulingProbe.seconds(elapsed)) s from the spawn stamp to \(ending), "
            + "\(DeschedulingProbe.seconds(withheld)) s of it withheld by the runner)"
    }

    @Test("output overflow stops inheriting descendants during live output and after root exit",
          arguments: ["live-capture", "live-pipe", "after-exit"])
    func outputLimitStopsOwnedDescendants(phase: String) throws {
        // The overflow is the subject; the thirty-second deadline only has to be one the overflow
        // reaches first. The launcher starts its deadline when `spawn` returns, and the decorator
        // holds `spawn` until the descendant has published, so the root's Python start-up, the fork
        // and the descendant's start-up fall outside both the deadline and the elapsed bound, which
        // starts at the decorator's spawn stamp, taken after the gate released. The bound therefore
        // measures overflow cleanup: stdin delivery, the overflowing write, the fixed 0.5 s TERM
        // pause and up to 1 s reaping the root, each wake-up possibly starved.
        //
        // The bound is ten seconds and both fixture processes expire at thirty, so the bound keeps
        // more than 2x headroom below the expiry it stands in for; cleanup stops both on a green
        // run, so only a red path's teardown pays for the long expiry. The launch must also return
        // at least a second before either process could expire on its own, read from the arm stamps
        // the fixture publishes, so a launcher that waited for natural expiry fails however long
        // start-up took. The launcher reaps only the root, so a starved descendant may need more
        // than half a second to act on SIGKILL: the stop windows are three seconds, cut short to
        // close a second before natural expiry, so a process cleanup never signalled is still live
        // when they close. The pause after SIGTERM is checked from the launcher's own turns
        // (`pauseEnded`), which no stall can stretch; the ten-second bound alone would pass a pause
        // of several seconds.
        //
        // `startMiss` decides before any product check whether an attempt missed its scenario. It
        // misses when the gate released without readiness in a shape only starvation produces
        // (`starvedGate`): the deadline would then start with start-up still running, and a root
        // its own alarm killed never overflows at all. It also misses when the gate released with
        // under fourteen seconds of fixture life left (the ten-second bound, the one-second margin
        // and the three-second stop window), because the arm stamps that set natural expiry are
        // read before `import ctypes`, the fork and the descendant's start-up, so a late gate
        // spends fixture life before the deadline starts, and a correct launcher could then fail
        // the expiry margin or a stop window cut short. Both are read from the gate and arm stamps
        // alone, fixed while the launcher was still inside `spawn`, so a miss cannot hide a
        // regression in overflow cleanup; the one launcher time they include is the product's own
        // `spawn` (see `startMiss`). A miss prints why and is re-run, at most twice; the last
        // attempt requires readiness and runs every check. A gate released by any other early root
        // exit fails the attempt, and an attempt that reached readiness with enough fixture life
        // runs every product check below, so any failed product check fails the test.
        //
        // Hosted runners can also withhold the test process after the spawn stamp, and a stall
        // there lands on the bound and the margin. A `DeschedulingProbe`, started before the
        // launch, records how long the runner withheld the process. On attempts 1 and 2, after
        // every product check has run and held, a crossed bound or margin is set aside only when
        // the probe recorded a stall from the spawn stamp to the return and the time it did not
        // see withheld stays inside both, granted one probe tick (`cleanupSetAside`); the attempt
        // prints the elapsed and withheld seconds and re-runs. A long stall in the milliseconds
        // before the launcher sees the overflow can also let the thirty-second deadline fire
        // first. Such a `TimeoutError` is set aside the same way, and only when the probe saw 29 s
        // withheld from the spawn stamp to cleanup's first group signal
        // (`overflowTimeoutWithheldNanoseconds`); otherwise it fails as any wrong error does. The
        // limit and after-exit checks do not apply to that timeout, which reached neither, but it
        // must still stop both processes, after the timeout's one-second pause. The probe never
        // observes the launcher, so a launcher that waits too long, or misses the overflow, on a
        // runner that is running the test still fails at once, and the last attempt sets nothing
        // aside.
        //
        // Residuals: a stall the probe does not see (of the test thread alone, of the fixture
        // after the gate, which can hold the overflow back past the deadline, or in lapses under
        // its tolerance) and any stall on the last attempt can still fail a correct launcher. The
        // stop windows stay product checks: a stall that lands the return near natural expiry cuts
        // them short, and a starved descendant slow to act on SIGKILL can then fail them with the
        // product correct. In the other direction, the evidence counts time withheld, not time the
        // launcher had, so an intermittent regression that coincides with enough withheld time is
        // re-run on attempt 1 or 2; a steady one still fails on the last attempt.
        for attempt in 1...3 {
            if try outputLimitStopsGroup(phase: phase, attempt: attempt,
                                         lastAttempt: attempt == 3) { return }
        }
        // The last attempt never misses or sets aside, so reaching here is a defect in the
        // attempt, never a pass.
        Issue.record("the last attempt returned without a verdict")
    }

    /// One attempt of the scenario above. Returns true once its product checks have run (their
    /// recorded issues fail the test); returns false only when another attempt remains and either
    /// the scenario was missed before the deadline started (a readiness-gate miss, or a gate
    /// released with too little fixture life left) or every product check held and each failed
    /// timed check was set aside with its own evidence (`cleanupSetAside`).
    private func outputLimitStopsGroup(phase: String, attempt: Int,
                                       lastAttempt: Bool) throws -> Bool {
        let fixture = try Fixture(directory: scratch.directory(),
                                  rootExpiry: 30, descendantExpiry: 30)
        defer { fixture.waitForNaturalExpiry() }
        let delivery: ScriptDelivery = phase == "live-capture"
            ? .timed(seconds: 30) : .timedStdin(script: "x", seconds: 30)
        let mode = phase == "after-exit" ? "overflow-after-exit" : "overflow-live"
        let children = SpawnStampingChildren(readyFile: fixture.path("descendant"))
        // Started before the launch, as in `completedCapture`.
        let runner = DeschedulingProbe()
        defer { runner.stop() }
        let result = Result<ScriptOutcome, any Error> {
            try children.launcher.launch(fixture.invocation(
                mode: mode, status: 0, delivery: delivery, maximumOutputBytes: 32))
        }
        let returnedAt = try fixture.uptimeNanoseconds()
        let spawnedAt = try #require(children.spawnedAt,
                                     "the stamping decorator must have spawned the root")
        let missed = "output-limit scenario missed on attempt \(attempt) of 3 (phase \(phase))"
        try Self.requireOneClock(children, fixture, spawnedAt: spawnedAt)
        if !lastAttempt, let miss = try Self.startMiss(children, fixture,
                                                       spawnedAt: spawnedAt, lifeNeeded: 14) {
            print("\(missed): \(miss)")
            return false
        }
        _ = try #require(children.readyAt, Comment(rawValue: Self.unready(children, fixture)))
        // A timeout with its own evidence waits for `cleanupSetAside` below; every other result
        // must be the overflow.
        let timedOut = Self.overflowTimeout(result, runner, spawnedAt: spawnedAt,
                                            firstSignalAt: children.firstSignalAt,
                                            returnedAt: returnedAt, lastAttempt: lastAttempt)
        var failure: ScriptOutputLimitExceeded?
        if timedOut == nil {
            failure = try #require(#expect(throws: ScriptOutputLimitExceeded.self) {
                _ = try result.get()
            })
        }
        let expiresAt = try fixture.earliestNaturalExpiry()

        // Product checks, on every attempt that reached readiness and left the fixture enough
        // life, and on the last attempt regardless. The overflow must report its limit and, in the
        // after-exit phase, follow the root's exit; a timeout held above reached neither, so those
        // two do not apply to it. Either way cleanup must stop both processes, and its pause after
        // SIGTERM is the overflow's half second or the timeout's second.
        var productHeld = true
        if let failure {
            let limitReported = failure.maximumOutputBytes == 32
            #expect(limitReported, Comment(rawValue: "the overflow must report the configured "
                    + "32 bytes, not \(failure.maximumOutputBytes)"))
            productHeld = limitReported
            if phase == "after-exit" {
                let afterExit = FileManager.default.fileExists(
                    atPath: fixture.path("root-observed-exited"))
                #expect(afterExit, "the descendant must see the root's exit before it overflows")
                productHeld = productHeld && afterExit
            }
        }
        let rootStopped = try fixture.stops(fixture.identity("root"),
                                            within: fixture.stopWindow(3))
        #expect(rootStopped, "cleanup must stop the root")
        let descendantStopped = try fixture.stops(fixture.identity("descendant"),
                                                  within: fixture.stopWindow(3))
        #expect(descendantStopped,
                "cleanup must stop the inheriting descendant, not just the root")
        let pauseHeld = Self.pauseEnded(children, within: timedOut == nil ? 0.5 : 1.0)
        productHeld = productHeld && rootStopped && descendantStopped && pauseHeld

        // Timed checks: the bound and the margin, and a timeout held above. On attempts 1 and 2
        // each is set aside only with its own evidence, and only when every product check held.
        let elapsed = spawnedAt <= returnedAt ? returnedAt - spawnedAt : 0
        let returnHeld = spawnedAt <= returnedAt && elapsed < Self.cleanupBoundNanoseconds
            && returnedAt + Self.cleanupMarginNanoseconds < expiresAt
        let withheld = runner.lapsed(from: spawnedAt, to: returnedAt)
        if !lastAttempt, productHeld, let stall = Self.cleanupSetAside(
            returnHeld: returnHeld, spawnedAt: spawnedAt, returnedAt: returnedAt,
            expiresAt: expiresAt, withheld: withheld, timeout: timedOut) {
            print("\(missed): \(stall)")
            return false
        }
        if let timedOut {
            Issue.record(Comment(rawValue: "overflow cleanup must report the overflow: "
                                 + timedOut))
        }
        #expect(returnHeld, Comment(rawValue:
                "overflow cleanup must finish well inside the fixture's 30-second natural expiry "
                + "(returned \(Self.offset(returnedAt, from: spawnedAt)) after the spawn stamp, "
                + "earliest natural expiry \(Self.offset(expiresAt, from: spawnedAt)) after it, "
                + "\(DeschedulingProbe.seconds(withheld)) s of the span withheld by the runner)"))
        return true
    }

    @Test("a timeout stops the TERM-ignoring root and its TERM-ignoring descendant",
          arguments: [false, true])
    func timeoutStopsOwnedGroup(stdin: Bool) throws {
        // The two-second timeout is the subject, and it must be reported as two. The launcher
        // starts its deadline when `spawn` returns. A root still in Python start-up when SIGTERM
        // arrives has not yet ignored it, so it dies and never publishes its identity. The
        // readiness gate therefore holds the launcher inside `spawn` until the descendant has
        // published its identity. The root arms its handlers and publishes its own identity before
        // it forks, so both TERM-ignoring processes exist before the deadline starts. The elapsed
        // bound starts at the spawn stamp, which the decorator takes when the gate releases.
        //
        // After the gate the product spends the two-second deadline, a fixed one-second TERM pause
        // and up to a second reaping the root, and each stage can overshoot by one starved wake-up.
        // The bound is therefore ten seconds from the spawn stamp, which leaves six seconds for
        // those overshoots. Both fixture processes expire at thirty seconds, so the bound keeps
        // more than 2x headroom below the expiry it stands in for. The launch must also return at
        // least a second before either process could expire on its own, read from the arm stamps
        // the fixture publishes, so a launcher that waits for natural expiry fails however long
        // start-up took. The launcher reaps only the root, so the stop windows after the return are
        // three seconds, cut short to close a second before natural expiry. A process that cleanup
        // never signalled is therefore still live when they close. The reported seconds are the
        // configured value whatever the deadline was, and the ten-second bound alone would pass a
        // deadline or a TERM pause several times too long (a deadline three times as long returns
        // at about seven seconds). So `deadlineEnded` checks the two-second deadline and
        // `pauseEnded` checks the one-second pause from the launcher's own turns, which no stall
        // can stretch. To red-check the bound, stall cleanup by eight seconds; seven lands on its
        // edge (2 + 1 + 7).
        //
        // On attempts 1 and 2, an attempt is a miss, printed and re-run, when `startMiss` finds
        // either of two cases. In the first, the gate released without readiness in a shape only
        // starvation produces (`starvedGate`); any other early root exit fails the attempt. In the
        // second, the gate released with under fourteen seconds of fixture life left (the
        // ten-second bound, the one-second margin and the three-second stop window). The arm stamps
        // that set natural expiry are read before `import ctypes`, the fork and the descendant's
        // start-up, so a starved start-up can spend the fixture's life before the deadline starts.
        // Both decisions read only the gate and arm stamps, which were fixed while the launcher was
        // still inside `spawn` and before any product check, so a miss cannot hide a regression in
        // the deadline or cleanup; the one launcher time they include is the product's own `spawn`
        // (see `startMiss`). A failed product check on any attempt fails the test. The last
        // attempt requires readiness and runs every check whatever the life left, so there a gate
        // released late can still fail a correct launcher's margin or stop window.
        //
        // Hosted runners can also withhold the test process after the spawn stamp, and a stall
        // there lands on the bound and the margin. A `DeschedulingProbe`, started before the
        // launch, records how long the runner withheld the process. On attempts 1 and 2, after
        // every product check has run and held, a crossed bound or margin is set aside only when
        // the probe recorded a stall from the spawn stamp to the return and the time it did not
        // see withheld stays inside both, granted one probe tick (`cleanupSetAside`); the attempt
        // prints the elapsed and withheld seconds and re-runs. The probe never observes the
        // launcher, so a cleanup stall like the red check's above still fails at once, and the
        // last attempt sets nothing aside. A stall cannot stretch the deadline or the pause, which
        // `deadlineEnded` and `pauseEnded` judge from the launcher's own turns, so they stay
        // product checks with the reported seconds and the stop windows.
        //
        // Residuals: a stall the probe does not see (of the test thread alone, or in lapses under
        // its tolerance) and any stall on the last attempt can still fail a correct launcher's
        // bound or margin. The stop windows stay product checks: a stall that lands the return
        // near natural expiry cuts them short, and a starved descendant slow to act on SIGKILL can
        // then fail them with the product correct. In the other direction, the evidence counts
        // time withheld, not time the launcher had, so an intermittent regression that coincides
        // with enough withheld time is re-run on attempt 1 or 2; a steady one still fails on the
        // last attempt.
        for attempt in 1...3 {
            if try timeoutStopsGroup(stdin: stdin, attempt: attempt,
                                     lastAttempt: attempt == 3) { return }
        }
        // The last attempt never misses or sets aside, so reaching here is a defect in the
        // attempt, never a pass.
        Issue.record("the last attempt returned without a verdict")
    }

    /// One attempt of the scenario above. Returns true once its product checks have run (their
    /// recorded issues fail the test); returns false only when another attempt remains and either
    /// the scenario was missed before the deadline started (a readiness-gate miss, or a gate
    /// released with too little fixture life left) or every product check held and a crossed
    /// bound or margin was set aside with its own evidence (`cleanupSetAside`).
    private func timeoutStopsGroup(stdin: Bool, attempt: Int, lastAttempt: Bool) throws -> Bool {
        let fixture = try Fixture(directory: scratch.directory(),
                                  rootExpiry: 30, descendantExpiry: 30)
        defer { fixture.waitForNaturalExpiry() }
        let children = SpawnStampingChildren(readyFile: fixture.path("descendant"))
        // Started before the launch, as in `completedCapture`.
        let runner = DeschedulingProbe()
        defer { runner.stop() }
        let result = Result<ScriptOutcome, any Error> {
            try children.launcher.launch(fixture.invocation(
                mode: "wait", status: 0,
                delivery: stdin ? .timedStdin(script: "x", seconds: 2) : .timed(seconds: 2)))
        }
        let returnedAt = try fixture.uptimeNanoseconds()
        let spawnedAt = try #require(children.spawnedAt,
                                     "the stamping decorator must have spawned the root")
        let missed = "timeout scenario missed on attempt \(attempt) of 3 (stdin \(stdin))"
        try Self.requireOneClock(children, fixture, spawnedAt: spawnedAt)
        if !lastAttempt, let miss = try Self.startMiss(children, fixture,
                                                       spawnedAt: spawnedAt, lifeNeeded: 14) {
            print("\(missed): \(miss)")
            return false
        }
        _ = try #require(children.readyAt, Comment(rawValue: Self.unready(children, fixture)))
        // Set by stamps the fixture wrote before the gate released, so it is fixed before the
        // launcher's deadline started and says nothing about the launcher.
        let expiresAt = try fixture.earliestNaturalExpiry()
        let error = #expect(throws: AppleScriptRunner.TimeoutError.self) { _ = try result.get() }
        let seconds = try #require(error).seconds

        // Product checks, on every attempt that reached readiness and left the fixture enough life,
        // and on the last attempt regardless.
        let timeoutReported = seconds == 2
        #expect(timeoutReported,
                "the timeout must report the configured two seconds, not \(seconds)")
        // Readiness is the descendant's identity, published after the root's own, so both are here;
        // the expectation below guards the gate's choice of file.
        let published = ["root", "descendant"]
            .filter { FileManager.default.fileExists(atPath: fixture.path($0)) }
        var stoppedPublished = true
        for name in published {
            let stopped = try fixture.stops(fixture.identity(name), within: fixture.stopWindow(3))
            #expect(stopped, name == "descendant"
                    ? "the descendant survived cancellation; stopping only the root is insufficient"
                    : "the root survived cancellation")
            stoppedPublished = stoppedPublished && stopped
        }
        let deadlineHeld = Self.deadlineEnded(children, within: 2.0)
        let pauseHeld = Self.pauseEnded(children, within: 1.0)
        let bothPublished = published == ["root", "descendant"]
        #expect(bothPublished, "both fixture processes must have published their identity")
        let productHeld = timeoutReported && stoppedPublished && deadlineHeld && pauseHeld
            && bothPublished

        // The timed check: the bound and the margin, set aside on attempts 1 and 2 only with their
        // own evidence, and only when every product check held.
        let elapsed = spawnedAt <= returnedAt ? returnedAt - spawnedAt : 0
        let endedBeforeExpiry = spawnedAt <= returnedAt && elapsed < Self.cleanupBoundNanoseconds
            && returnedAt + Self.cleanupMarginNanoseconds < expiresAt
        let withheld = runner.lapsed(from: spawnedAt, to: returnedAt)
        if !lastAttempt, productHeld, let stall = Self.cleanupSetAside(
            returnHeld: endedBeforeExpiry, spawnedAt: spawnedAt, returnedAt: returnedAt,
            expiresAt: expiresAt, withheld: withheld) {
            print("\(missed): \(stall)")
            return false
        }
        #expect(endedBeforeExpiry, Comment(rawValue:
                "timeout cleanup must complete well inside the fixture's 30-second natural expiry "
                + "(returned \(Self.offset(returnedAt, from: spawnedAt)) after the spawn stamp, "
                + "earliest natural expiry \(Self.offset(expiresAt, from: spawnedAt)) after it, "
                + "\(DeschedulingProbe.seconds(withheld)) s of the span withheld by the runner)"))
        return true
    }

    @Test("a drain timeout stops the descendant after the root has exited")
    func timeoutAfterRootExitStopsOwnedGroup() throws {
        // The scenario is the launcher's drain state: the root has exited on its own, the
        // descendant still holds the inherited output pipes, and the two-second drain deadline then
        // stops the owned group. The readiness gate holds the deadline until the descendant has
        // published its identity. The fixture forks the descendant before the root reads stdin, so
        // Python start-up, the fork and the descendant's start-up stay outside the deadline. What
        // remains inside it is stdin delivery, the root's voluntary exit and the launcher's
        // observation of that exit. The order check reads the launcher's own observation
        // (`exitObservedAt`) rather than a fixture poll. The scenario needs the exit seen before
        // cleanup's first signal and also inside the deadline: `signal` observes the root before it
        // sends, so a root that exited after the deadline but before the first signal is stamped
        // first, even though the deadline fired while the launcher was still waiting for the exit.
        //
        // The product path is the same as in the timeout test: the deadline, a fixed one-second
        // TERM pause and up to a second reaping the root, each stage able to overshoot by one
        // starved wake-up. So the bound is ten seconds from the spawn stamp, which leaves six
        // seconds for those overshoots. Both fixture processes expire at thirty seconds, which
        // keeps more than 2x headroom; cleanup stops both on a green run, so only a red path's
        // teardown waits that long. The launch must return at least a second before either process
        // could expire on its own, read from the arm stamps. The group-membership and stop windows
        // are three seconds, cut short to close a second before natural expiry, because the
        // launcher returns without waiting for the SIGKILLed descendant. The drain's own checks
        // bound the deadline only from below, so `deadlineEnded` checks the two-second deadline and
        // `pauseEnded` checks the one-second pause from the launcher's own turns, which no stall
        // can stretch. The regression this test guards is waiting for EOF until natural expiry.
        // That regression drains to the expiry and returns a completed outcome, so it fails at the
        // timeout-error expectation, and the `#require` after it ends the test before the bound or
        // the margin is read.
        //
        // On attempts 1 and 2, an attempt is a miss, printed and re-run, in four cases:
        // - `startMiss` finds the gate released without readiness in a shape only starvation
        //   produces (`starvedGate`); any other early root exit fails the attempt.
        // - `startMiss` finds the gate released with under fourteen seconds of fixture life left
        //   (the bound, the one-second margin and the three-second window).
        // - Every product check held, and the bound or the margin was crossed by no more than a
        //   `DeschedulingProbe`, started before the launch, saw the runner withhold from the spawn
        //   stamp to the return, granted one probe tick (`cleanupSetAside`); the miss prints the
        //   elapsed and withheld seconds.
        // - Every product check held, but the root did not reach its immediate-exit branch, or its
        //   exit was not seen inside the deadline and before cleanup's first signal.
        //
        // The first two cases read only stamps fixed while the launcher was still inside `spawn`,
        // and the last two are decided only after every product check held, so none of them can
        // hide a regression in the drain or its cleanup; the one launcher time the first two
        // include is the product's own `spawn` (see `startMiss`). The probe never observes the
        // launcher, so a drain that waits too long on a runner that is running the test still
        // fails at once. A failed product check on any attempt fails the test. A pass needs one
        // attempt that both reaches the scenario and passes every check, and the last attempt
        // asserts the scenario and sets nothing aside. The three attempts are a backstop, not a
        // measured rate.
        //
        // Residuals: as in the timeout test, a stall the probe does not see (of the test thread
        // alone, or in lapses under its tolerance) and any stall on the last attempt can still
        // fail a correct launcher's bound or margin. The group-membership and stop windows stay
        // product checks: a stall that lands the return near natural expiry cuts them short, and a
        // starved descendant slow to act on SIGKILL can then fail them with the product correct.
        // An intermittent regression that coincides with enough withheld time is re-run on attempt
        // 1 or 2; a steady one still fails on the last attempt.
        for attempt in 1...3 {
            if try drainTimeoutAfterRootExit(attempt: attempt, lastAttempt: attempt == 3) { return }
        }
        // The last attempt never misses or sets aside, so reaching here is a defect in the
        // attempt, never a pass.
        Issue.record("the last attempt returned without a verdict")
    }

    /// One attempt of the scenario above. Returns true after a failed product check (its recorded
    /// issues fail the test) or after asserting the scenario; returns false only when the scenario
    /// was missed (a readiness-gate miss, a gate released with too little fixture life left, a
    /// crossed bound or margin set aside with its own evidence, or every product check held
    /// without the scenario's exit and order) and another attempt remains.
    private func drainTimeoutAfterRootExit(attempt: Int, lastAttempt: Bool) throws -> Bool {
        let fixture = try Fixture(directory: scratch.directory(),
                                  rootExpiry: 30, descendantExpiry: 30)
        defer { fixture.waitForNaturalExpiry() }
        let startedAt = try fixture.uptimeNanoseconds()
        let children = SpawnStampingChildren(readyFile: fixture.path("descendant"))
        var dependencies = ScriptProcessDependencies()
        dependencies.children = children
        let stampingLauncher = OsascriptLauncher(dependencies: dependencies)
        // Started before the launch, as in `completedCapture`.
        let runner = DeschedulingProbe()
        defer { runner.stop() }
        let result = Result<ScriptOutcome, any Error> {
            try stampingLauncher.launch(fixture.invocation(
                mode: "exit", status: 0, delivery: .timedStdin(script: "x", seconds: 2)))
        }
        let returnedAt = try fixture.uptimeNanoseconds()
        let pid = try #require(children.spawnedPID, "the stamping decorator must have spawned the root")
        let spawnedAt = try #require(children.spawnedAt)
        try Self.requireOneClock(children, fixture, spawnedAt: spawnedAt)
        if !lastAttempt, let miss = try Self.startMiss(children, fixture,
                                                       spawnedAt: spawnedAt, lifeNeeded: 14) {
            print("drain-timeout scenario missed on attempt \(attempt) of 3: \(miss)")
            return false
        }
        _ = try #require(children.readyAt, Comment(rawValue: Self.unready(children, fixture)))
        let error = #expect(throws: AppleScriptRunner.TimeoutError.self) { _ = try result.get() }
        let seconds = try #require(error).seconds
        let firstSignalAt = try #require(children.firstSignalAt, "drain-timeout cleanup must have signalled the group")
        let expiresAt = try fixture.earliestNaturalExpiry()
        let survivors = try fixture.liveMembers(ofGroup: pid, settlingWithin: fixture.stopWindow(3))
        let published = ["root", "descendant"].filter { FileManager.default.fileExists(atPath: fixture.path($0)) }

        // Product checks, on every attempt. The group check reads the kernel's membership of the
        // owned group, so every surviving member is seen whether or not it published an identity;
        // it is sound only if the root leads that group, which is checked too. Messages carry
        // the stamps' offsets from the spawn, since hosted CI is where these fail.
        func offset(_ stamp: UInt64) -> String {
            stamp >= spawnedAt ? "\((stamp - spawnedAt) / 1_000_000) ms after spawn"
                : "\((spawnedAt - stamp) / 1_000_000) ms before spawn"
        }
        let leadsGroup = children.spawnedGroup == pid
        let timeoutReported = seconds == 2
        let stampedInOrder = startedAt <= spawnedAt && spawnedAt <= returnedAt
        // A timed check, not a product check: see the set-aside below.
        let endedBeforeExpiry = stampedInOrder
            && returnedAt - spawnedAt < Self.cleanupBoundNanoseconds
            && returnedAt + Self.cleanupMarginNanoseconds < expiresAt
        // The first signal is stamped on the uptime clock the launcher's `DispatchTime` deadline
        // reads, and the spawn stamp precedes the deadline's start, so a correct launcher's first
        // signal comes at least two seconds after the spawn stamp, less the rounding of
        // `DispatchTime` arithmetic, a tick or so. The check keeps only
        // `DeschedulingProbe.clockRoundingNanoseconds`, a millisecond, in hand for that, since a
        // failure here is never re-run. So a first signal under 1.999 s after the spawn stamp
        // fails: a deadline short by more than a millisecond passes only as far as the gap from the
        // spawn stamp to the deadline's start, the launch loop's overshoot of the deadline and the
        // observation that revalidates before the signal make up for the shortfall. Nothing else in
        // this file bounds a deadline from below. `drainedToDeadline` needs no slack, because a
        // correct launcher returns more than a second past its deadline, after the pause that
        // follows SIGTERM.
        let signalledAtDeadline = firstSignalAt + DeschedulingProbe.clockRoundingNanoseconds
            >= spawnedAt + 2_000_000_000
        let drainedToDeadline = returnedAt >= spawnedAt + 2_000_000_000
        let groupRead = children.spawnedGroup.map { $0 < 0 ? "getpgid failed: the root was gone" : "another group" } ?? "not read"
        #expect(leadsGroup, "the root must lead its own process group, or the group check is vacuous (\(groupRead))")
        #expect(timeoutReported, "the timeout must report the configured two seconds, not \(seconds)")
        #expect(stampedInOrder, "the spawn stamp must fall between the attempt's start and the launch's return (start \(offset(startedAt)), return \(offset(returnedAt)))")
        #expect(signalledAtDeadline, "cleanup's first signal must not precede the two-second drain deadline (first signal \(offset(firstSignalAt)))")
        #expect(drainedToDeadline, "the pending drain must reach its deadline rather than fail early (returned \(offset(returnedAt)))")
        #expect(survivors.isEmpty, "cleanup must stop every member of the owned group, published or not")
        var stoppedPublished = true
        for name in published {
            let stopped = try fixture.stops(fixture.identity(name), within: fixture.stopWindow(3))
            #expect(stopped, name == "descendant"
                    ? "root exit must not discard the authority needed for drain-timeout cleanup (descendant)"
                    : "cleanup must stop the root")
            stoppedPublished = stoppedPublished && stopped
        }
        let deadlineHeld = Self.deadlineEnded(children, within: 2.0)
        let pauseHeld = Self.pauseEnded(children, within: 1.0)
        let productHeld = leadsGroup && timeoutReported && stampedInOrder
            && signalledAtDeadline && drainedToDeadline && survivors.isEmpty && stoppedPublished
            && deadlineHeld && pauseHeld

        // The timed check: the bound and the margin, set aside on attempts 1 and 2 only with their
        // own evidence, and only when every product check held.
        let withheld = runner.lapsed(from: spawnedAt, to: returnedAt)
        if !lastAttempt, productHeld, let stall = Self.cleanupSetAside(
            returnHeld: endedBeforeExpiry, spawnedAt: spawnedAt, returnedAt: returnedAt,
            expiresAt: expiresAt, withheld: withheld) {
            print("drain-timeout scenario missed on attempt \(attempt) of 3: \(stall)")
            return false
        }
        #expect(endedBeforeExpiry, Comment(rawValue:
                "the inherited output pipes must not extend the invocation until natural expiry "
                + "(returned \(offset(returnedAt)), earliest natural expiry \(offset(expiresAt)), "
                + "\(DeschedulingProbe.seconds(withheld)) s of the span withheld by the runner)"))
        if !(productHeld && endedBeforeExpiry) { return true }

        // The scenario: both processes published their identity, the root reached its
        // immediate-exit branch, and the launcher saw the root's exit after its spawn returned,
        // inside the two-second deadline and before cleanup's first group signal. So the exit was
        // the root's own; no signal had been sent when the product saw it. The spawn stamp precedes
        // the deadline's start, and the exit stamp and the deadline read one clock, which a host's
        // sleep pauses for both. The launch loop checks its deadline right after the observation
        // the decorator stamps, so an exit stamped under 1.9 s after the spawn stamp was seen
        // before the deadline, unless the runner withheld the launcher's thread for most of the
        // tenth kept in hand (`drainScenarioMargin`) between that stamp and the check.
        let exiting = FileManager.default.fileExists(atPath: fixture.path("root-exiting"))
        let exitSeenAt = children.exitObservedAt
        let insideDeadline = spawnedAt + 2_000_000_000 - Self.drainScenarioMargin
        let ordered = exitSeenAt.map {
            spawnedAt <= $0 && $0 < insideDeadline && $0 < firstSignalAt
        } == true
        if !(exiting && ordered) && !lastAttempt {
            print("drain-timeout scenario missed on attempt \(attempt) of 3: root-exiting "
                  + "\(exiting), exit seen inside the deadline and before the first signal "
                  + "\(ordered)")
            return false
        }
        #expect(published == ["root", "descendant"],
                "both fixture processes must have published their identity")
        #expect(exiting, Comment(rawValue: "the root must reach its immediate-exit branch; "
                + "missing readiness is a test failure"))
        let exitedAt = try #require(exitSeenAt, "the launcher must have observed the root's exit")
        #expect(spawnedAt <= exitedAt, "the observed exit must postdate the launcher's spawn")
        #expect(exitedAt < insideDeadline, Comment(rawValue:
                "the launcher must see the root's exit inside the two-second deadline (by 1.9 s), "
                + "so the timeout fired in the drain (exit seen \(offset(exitedAt)))"))
        #expect(exitedAt < firstSignalAt,
                "the launcher must see the root's exit before cleanup's first signal, not because of it (exit seen \(offset(exitedAt)), first signal \(offset(firstSignalAt)))")
        return true
    }

    @Test("completed timed capture preserves background work for zero and nonzero root status",
          arguments: [Int32(0), Int32(7)])
    func completedCapturePreservesBackgroundWork(status: Int32) throws {
        // Completion is the subject; the deadline only bounds a regression. The deadline is thirty
        // seconds, past the descendant's own twelve-second expiry. The readiness gate holds the
        // launcher inside `spawn` until the descendant has published its identity. So Python
        // start-up, the fork and the descendant's start-up fall outside the deadline and outside
        // the six-second elapsed bound, which starts at the spawn stamp. The bound is six seconds
        // because the regression it guards, waiting on background work, returns at the descendant's
        // twelve-second natural expiry, twice the bound. The root's alarm is thirty seconds. It is
        // armed before `import ctypes` and the gate does not stop it, so a twelve-second alarm
        // could kill the root during a starved start-up and fail the status and output checks with
        // the product correct. A green root exits on its own, so the longer alarm bounds only a red
        // path, and teardown is set by the descendant's twelve seconds.
        //
        // The liveness check, `keepsRunning(until:)`, observes the descendant every 20 ms for two
        // full seconds from the return, and it refuses a stopped descendant. A single observation
        // can miss a group SIGKILL still in flight and can never see a SIGSTOP. The launch must
        // return three seconds before the descendant could expire on its own (the window plus a
        // one-second margin, read from its arm stamp), so the window closes inside the descendant's
        // lifetime.
        //
        // On attempts 1 and 2, `startMiss` makes an attempt a miss, printed and re-run, in two
        // cases. In the first, the gate released without readiness in a shape only starvation
        // produces (`starvedGate`); any other early root exit fails the attempt. In the second, the
        // gate released with under nine seconds of fixture life left (the bound, the margin and the
        // window); the descendant's alarm, armed before it published, would then fail the margin or
        // the liveness check with the product correct. `startMiss` reads only the gate and arm
        // stamps, fixed while the launcher was still inside `spawn`, so it cannot hide a
        // regression in completion; the one launcher time it includes is the product's own
        // `spawn` (see there).
        //
        // Hosted runners can also withhold the test process after the spawn stamp, for tens of
        // seconds (see docs/learnings/hot/hosted-ci.md). Such a stall lands on the deadline, on the
        // bound and margin, or on the liveness window. A `DeschedulingProbe`, started before the
        // launch, records how long the runner withheld the process. On attempts 1 and 2, a failed
        // timed check is set aside only with its own evidence; the attempt prints the elapsed and
        // withheld seconds and re-runs. The evidence each check needs:
        // - A `TimeoutError` needs 29 s withheld from the spawn stamp to cleanup's first group
        //   signal (`completionTimeoutWithheldNanoseconds`).
        // - The bound and margin need 4.9 s withheld from the spawn stamp to the return
        //   (`completionBoundWithheldNanoseconds`).
        // - A failed liveness check needs its deciding observation no sooner than the descendant's
        //   expiry less a millisecond of rounding (`DeschedulingProbe.clockRoundingNanoseconds`),
        //   with the window withheld for all but 0.2 s of the time from its end to that expiry
        //   (`livenessAllowanceNanoseconds`).
        //
        // Each constant's doc gives its derivation. The probe never observes the launcher, so on a
        // runner that is running the test, a launcher that waits too long or kills its background
        // work still fails at once. Status and output are checked on every attempt with an outcome.
        // A failed check without its own evidence keeps the attempt failing, and the last attempt
        // sets nothing aside.
        //
        // Residuals: a correct launcher still fails on a stall the probe does not see (of the test
        // thread alone, of the fixture's root after the gate, or in lapses under the probe's
        // tolerance) and on any stall on the last attempt. On the last attempt, a gate released
        // late can also fail the margin or the liveness check. In the other direction, the bound's
        // evidence counts only time withheld, not time the launcher had. So on a withholding
        // runner, a launcher that waits for its background work until the descendant's expiry is
        // set aside on attempt 1 or 2 whenever 4.9 s of withheld time fell anywhere in that wait,
        // since its liveness check, decided at that expiry, qualifies too. An intermittent
        // regression that coincides with a stall is re-run, but a steady one still fails on the
        // last attempt.
        for attempt in 1...3 {
            if try completedCapture(status: status, attempt: attempt, lastAttempt: attempt == 3) {
                return
            }
        }
        // The last attempt never misses or sets aside, so reaching here is a defect in the
        // attempt, never a pass.
        Issue.record("the last attempt returned without a verdict")
    }

    /// What a `DeschedulingProbe` must see withheld from the spawn stamp to cleanup's first group
    /// signal (to the return when cleanup sent none) before a completion test's `TimeoutError` is
    /// set aside on attempt 1 or 2. A correct launcher sees the root's exit within milliseconds of
    /// the gate, so it reaches the thirty-second deadline only when nearly all of it was withheld:
    /// thirty seconds less one for its own work before that observation and for the probe's
    /// undercount (a lapse counts from when its tick should have ended, so up to one 50 ms tick of
    /// a stall goes unseen). The span ends at that signal, which the decorator stamps on the same
    /// clock just before sending it, after the timeout was thrown: a stall that delayed a correct
    /// launcher ends before it, while a stall in the cleanup that follows (the one-second TERM
    /// pause and the reap wait) cannot explain a timeout already thrown, so it is not counted.
    private static let completionTimeoutWithheldNanoseconds: UInt64 = 29_000_000_000

    /// What the probe must see withheld from the spawn stamp to the return before the completion
    /// tests' six-second bound and three-second margin are set aside, together, on attempt 1 or 2:
    /// the bound less 1.1 s, which allows the launcher's one-second reap wait plus a tenth for its
    /// observations and captures and for the probe's undercount. On those attempts `startMiss`
    /// leaves nine seconds of descendant life, so a return inside the bound also meets the margin,
    /// and a stall that crosses the margin crosses the bound too.
    private static let completionBoundWithheldNanoseconds: UInt64 = 4_900_000_000

    /// How much of the time left from the liveness window's end to the descendant's expiry may go
    /// unseen by the probe in the window before a failed liveness check is set aside on attempt 1
    /// or 2. A correct launcher's descendant lives until its alarm, which on this clock fires no
    /// sooner than that computed expiry less the kernel's rounding
    /// (`DeschedulingProbe.clockRoundingNanoseconds` covers it), so the check fails that launcher
    /// only when the deciding observation, and so the stamp `keepsRunning` reads after it, came at
    /// that point or later. The observation before that one, stamped before the window's end, found
    /// the descendant alive, and `keepsRunning` then slept its own 20 ms poll, so a correct
    /// launcher fails only after a stall between the two of at least the time left less that
    /// rounding, the poll, the two observations' own cost and the poll's overshoot (longer still
    /// when the deciding observation was the first), and the probe, when it records that stall,
    /// misses at most one 50 ms tick of it. The rounding, the poll and the tick make about 71 ms;
    /// the rest of the 0.2 s, about 0.13 s, is headroom for the observations' own cost and the
    /// poll's overshoot, which a loaded runner stretches. It is not tightened to the sum: a larger
    /// allowance only lets a smaller recorded stall excuse a failure decided no sooner than the
    /// descendant's expiry, never one decided before it, so a launcher that kills its background
    /// work on time still fails.
    private static let livenessAllowanceNanoseconds: UInt64 = 200_000_000

    /// A completion test's outcome, or nil when the launch timed out on attempt 1 or 2 while the
    /// probe saw at least `completionTimeoutWithheldNanoseconds` withheld from the spawn stamp to
    /// `firstSignalAt`, cleanup's first group signal, or to the return when cleanup sent none; that
    /// miss is printed after `missed` with the elapsed and withheld seconds of that span. Any other
    /// error, and a timeout without that evidence or on the last attempt, is thrown and fails the
    /// test as `try result.get()` would.
    private static func completionOutcome(_ result: Result<ScriptOutcome, any Error>,
                                          _ runner: DeschedulingProbe, spawnedAt: UInt64,
                                          firstSignalAt: UInt64?, returnedAt: UInt64,
                                          lastAttempt: Bool,
                                          missed: String) throws -> ScriptOutcome? {
        switch result {
        case .success(let outcome):
            return outcome
        case .failure(let error):
            guard !lastAttempt, let timeout = error as? AppleScriptRunner.TimeoutError else {
                throw error
            }
            let end = firstSignalAt ?? returnedAt
            let withheld = runner.lapsed(from: spawnedAt, to: end)
            guard withheld >= completionTimeoutWithheldNanoseconds else { throw error }
            let elapsed = spawnedAt <= end ? end - spawnedAt : 0
            let threshold = DeschedulingProbe.seconds(completionTimeoutWithheldNanoseconds)
            let ending = firstSignalAt == nil ? "the return" : "cleanup's first group signal"
            print("\(missed): the launch timed out (\(timeout)) while the runner withheld at "
                  + "least the \(threshold) s threshold "
                  + "(\(DeschedulingProbe.seconds(elapsed)) s from the spawn stamp to \(ending), "
                  + "\(DeschedulingProbe.seconds(withheld)) s of it withheld by the runner)")
            return nil
        }
    }

    /// How far `stamp` falls from `origin`, and on which side ("after" or "before"), for a printed
    /// reason that names the side in words, where `offset` would print a minus sign and a clamped
    /// figure would name the wrong side.
    private static func side(of stamp: UInt64, from origin: UInt64)
        -> (gap: UInt64, word: String) {
        stamp >= origin ? (gap: stamp - origin, word: "after")
            : (gap: origin - stamp, word: "before")
    }

    /// Why an attempt of a completion test is set aside, or nil when it is not. Callers ask only on
    /// attempts 1 and 2, and only when status and output held. Nil when no timed check failed, and
    /// nil when any failed check lacks its own evidence: the bound and margin need
    /// `completionBoundWithheldNanoseconds` withheld from the spawn stamp to the return; a failed
    /// liveness check needs its deciding observation no sooner than the descendant's expiry less
    /// `DeschedulingProbe.clockRoundingNanoseconds`, and the window from the return to the last
    /// observation withheld for all but `livenessAllowanceNanoseconds` of the time left from
    /// `windowEnd` to that expiry. A launcher that kills or stops its background work on time is
    /// seen by an observation inside the window, before that expiry, so it still fails. Each reason
    /// carries its elapsed and withheld seconds.
    private static func completionSetAside(returnHeld: Bool, spawnedAt: UInt64,
                                           returnedAt: UInt64, returnWithheld: UInt64,
                                           liveness: (kept: Bool, decidedAt: UInt64),
                                           windowEnd: UInt64, checkedAt: UInt64,
                                           windowWithheld: UInt64,
                                           descendantExpiresAt: UInt64) -> String? {
        guard !(returnHeld && liveness.kept) else { return nil }
        var reasons: [String] = []
        if !returnHeld {
            guard returnWithheld >= completionBoundWithheldNanoseconds else { return nil }
            let elapsed = spawnedAt <= returnedAt ? returnedAt - spawnedAt : 0
            reasons.append("the six-second bound or three-second margin was crossed "
                + "(\(DeschedulingProbe.seconds(elapsed)) s from the spawn stamp, "
                + "\(DeschedulingProbe.seconds(returnWithheld)) s of it withheld by the runner)")
        }
        if !liveness.kept {
            let left = descendantExpiresAt > windowEnd ? descendantExpiresAt - windowEnd : 0
            guard liveness.decidedAt + DeschedulingProbe.clockRoundingNanoseconds
                      >= descendantExpiresAt,
                  windowWithheld + livenessAllowanceNanoseconds >= left else { return nil }
            let window = returnedAt <= checkedAt ? checkedAt - returnedAt : 0
            // Each figure names its side; `left`, clamped at zero when the margin also failed,
            // serves only the guard above.
            let decided = side(of: liveness.decidedAt, from: descendantExpiresAt)
            let expiry = side(of: descendantExpiresAt, from: windowEnd)
            let timing = "\(DeschedulingProbe.seconds(window)) s from the return to the last "
                + "observation, \(DeschedulingProbe.seconds(windowWithheld)) s of it withheld by "
                + "the runner"
            reasons.append("the liveness check was decided \(decided.gap / 1_000_000) ms "
                + "\(decided.word) the descendant's expiry, which came "
                + "\(DeschedulingProbe.seconds(expiry.gap)) s \(expiry.word) the window's end "
                + "(\(timing))")
        }
        return reasons.joined(separator: "; ")
    }

    /// One attempt of the scenario above. Returns true once its product checks have run (their
    /// recorded issues fail the test); returns false only when another attempt remains and either
    /// the scenario was missed before the deadline started or a timed check was set aside.
    private func completedCapture(status: Int32, attempt: Int, lastAttempt: Bool) throws -> Bool {
        let fixture = try Fixture(directory: scratch.directory(), rootExpiry: 30)
        defer { fixture.waitForNaturalExpiry() }
        let children = SpawnStampingChildren(readyFile: fixture.path("descendant"))
        // Started before the launch so it is ticking at the spawn stamp; only lapses inside a
        // measured span count. Stopped on every path, including a failed `#require`, and before the
        // teardown wait above.
        let runner = DeschedulingProbe()
        defer { runner.stop() }
        let result = Result<ScriptOutcome, any Error> {
            try children.launcher.launch(fixture.invocation(
                mode: "exit", status: status, delivery: .timed(seconds: 30)))
        }
        let returnedAt = try fixture.uptimeNanoseconds()
        let spawnedAt = try #require(children.spawnedAt,
                                     "the stamping decorator must have spawned the root")
        let missed = "completed-capture scenario missed on attempt \(attempt) of 3 "
            + "(status \(status))"
        try Self.requireOneClock(children, fixture, spawnedAt: spawnedAt)
        if !lastAttempt, let miss = try Self.startMiss(children, fixture,
                                                       spawnedAt: spawnedAt, lifeNeeded: 9) {
            print("\(missed): \(miss)")
            return false
        }
        _ = try #require(children.readyAt, Comment(rawValue: Self.unready(children, fixture)))
        guard let outcome = try Self.completionOutcome(result, runner, spawnedAt: spawnedAt,
                                                       firstSignalAt: children.firstSignalAt,
                                                       returnedAt: returnedAt,
                                                       lastAttempt: lastAttempt, missed: missed)
        else { return false }
        let descendantExpiresAt = try fixture.naturalExpiry(of: "descendant")
        let expectedOutput = Data("root-output\n".utf8)
        let expectedError = Data("root-error\n".utf8)
        #expect(outcome.terminationStatus == status)
        #expect(outcome.standardOutput == expectedOutput)
        #expect(outcome.standardError == expectedError)
        let outcomeHeld = outcome.terminationStatus == status
            && outcome.standardOutput == expectedOutput && outcome.standardError == expectedError
        let elapsed = spawnedAt <= returnedAt ? returnedAt - spawnedAt : 0
        let bounded = spawnedAt <= returnedAt && elapsed < 6_000_000_000
        let margin = returnedAt + 3_000_000_000 < descendantExpiresAt
        let windowEnd = returnedAt + 2_000_000_000
        let liveness = try fixture.keepsRunning(fixture.identity("descendant"), until: windowEnd)
        let checkedAt = try fixture.uptimeNanoseconds()
        // Read only now: `lapsed` stops the probe, which must also watch the liveness window.
        let returnWithheld = runner.lapsed(from: spawnedAt, to: returnedAt)
        let windowWithheld = runner.lapsed(from: returnedAt, to: checkedAt)
        if !lastAttempt, outcomeHeld, let stall = Self.completionSetAside(
            returnHeld: bounded && margin, spawnedAt: spawnedAt, returnedAt: returnedAt,
            returnWithheld: returnWithheld, liveness: liveness, windowEnd: windowEnd,
            checkedAt: checkedAt, windowWithheld: windowWithheld,
            descendantExpiresAt: descendantExpiresAt) {
            print("\(missed): \(stall)")
            return false
        }
        #expect(bounded, Comment(rawValue:
                "a completed capture must not await background descriptor closure "
                + "(\(DeschedulingProbe.seconds(elapsed)) s from the spawn stamp, "
                + "\(DeschedulingProbe.seconds(returnWithheld)) s of it withheld by the runner)"))
        #expect(margin, Comment(rawValue:
                "a completed capture must return three seconds before the preserved descendant "
                + "could expire on its own, so its two-second liveness window fits (returned "
                + "\(Self.offset(returnedAt, from: spawnedAt)) after the spawn stamp, descendant "
                + "expiry \(Self.offset(descendantExpiresAt, from: spawnedAt)) after it)"))
        #expect(liveness.kept, Comment(rawValue:
                "a completed root outcome must not cancel intentional background work (decided "
                + "\(Self.offset(liveness.decidedAt, from: spawnedAt)) after the spawn stamp, "
                + "descendant expiry \(Self.offset(descendantExpiresAt, from: spawnedAt)) "
                + "after it, \(DeschedulingProbe.seconds(windowWithheld)) s of the window "
                + "withheld by the runner)"))
        return true
    }

    @Test("completed stdin delivery preserves background work that closed its output pipes")
    func completedStdinPreservesBackgroundWork() throws {
        // Completion is the subject, so the thirty-second deadline is incidental: it lies past the
        // fixture's own expiry and bounds only a regression. The launch goes through the readiness
        // gate on the descendant, which publishes before the root reads stdin, so Python start-up,
        // the fork and the handshake finish before the deadline starts. The root's alarm is thirty
        // seconds because it is armed before `import ctypes`, and a starved start-up could outrun a
        // twelve-second one and fail the status and output checks with the product correct; a green
        // root exits on its own, so the longer alarm bounds only a red path. The descendant's alarm
        // is twelve seconds.
        //
        // The checks match the timed sibling, `completedCapturePreservesBackgroundWork`: status and
        // output; a six-second bound from the spawn stamp, which a launcher that waits on its
        // background work crosses at the descendant's twelve-second expiry, twice the bound; a
        // return at least three seconds before that expiry; and a liveness window that runs two
        // full seconds from the return (`keepsRunning(until:)`), so it closes before the expiry,
        // observing every 20 ms and refusing a stopped descendant, because a single observation can
        // miss a SIGKILL still in flight.
        //
        // On attempts 1 and 2 an attempt is a miss, printed and re-run, in these cases. `startMiss`
        // misses a gate that released with under nine seconds of fixture life left (the bound, the
        // margin and the window), or released without readiness in a shape only starvation produces
        // (`starvedGate`); it reads only stamps fixed while the launcher was still inside `spawn`,
        // so a miss says nothing about completion; the one launcher time it includes is the
        // product's own `spawn` (see `startMiss`). The `DeschedulingProbe` sets aside a
        // `TimeoutError` with 29 s withheld from the spawn stamp to cleanup's first group signal, a
        // crossed bound or margin with 4.9 s withheld from the spawn stamp to the return, and a
        // failed liveness check decided no sooner than the descendant's expiry less a millisecond
        // of rounding (`DeschedulingProbe.clockRoundingNanoseconds`) with the window withheld for
        // all but 0.2 s of the time from its end to that expiry (the constants give each
        // derivation). Stdin delivery adds milliseconds before the root's exit, inside the second
        // the 29 s threshold keeps for correct work. The probe never observes the launcher, so a
        // launcher that waits too long, or kills its background work, on a runner that is running
        // the test still fails at once. Status and output are checked on every attempt with an
        // outcome, a failed check without its own evidence keeps the attempt failing, and the last
        // attempt requires readiness, sets nothing aside and runs every check.
        //
        // Residuals: a stall the probe does not see (of the test thread alone, of the fixture's
        // root after the gate, or in lapses under its tolerance) and any stall on the last attempt
        // can still fail a correct launcher, either by pushing the return past the bound (which
        // charges stdin delivery, the root's read and exit and the launcher's return to the
        // product) or by landing the window's last observation after the descendant's alarm, which
        // the margin can leave as little as a second away. On the last attempt a gate released late
        // can also fail the margin with the product correct. The other way round, on a runner that
        // is withholding, a launcher that waits for its background work until the descendant's
        // expiry is set aside on attempt 1 or 2 whenever 4.9 s of withheld time fell in that wait;
        // a steady regression still fails on the last attempt.
        for attempt in 1...3 {
            if try completedStdin(attempt: attempt, lastAttempt: attempt == 3) { return }
        }
        // The last attempt never misses or sets aside, so reaching here is a defect in the
        // attempt, never a pass.
        Issue.record("the last attempt returned without a verdict")
    }

    /// One attempt of the scenario above. Returns true once its product checks have run (their
    /// recorded issues fail the test); returns false only when another attempt remains and either
    /// the scenario was missed before the deadline started or a timed check was set aside.
    private func completedStdin(attempt: Int, lastAttempt: Bool) throws -> Bool {
        let fixture = try Fixture(directory: scratch.directory(), rootExpiry: 30)
        defer { fixture.waitForNaturalExpiry() }
        let children = SpawnStampingChildren(readyFile: fixture.path("descendant"))
        // Started before the launch, as in `completedCapture`.
        let runner = DeschedulingProbe()
        defer { runner.stop() }
        let result = Result<ScriptOutcome, any Error> {
            try children.launcher.launch(fixture.invocation(
                mode: "closed-output", status: 0, delivery: .timedStdin(script: "x", seconds: 30)))
        }
        let returnedAt = try fixture.uptimeNanoseconds()
        let spawnedAt = try #require(children.spawnedAt,
                                     "the stamping decorator must have spawned the root")
        let missed = "completed-stdin scenario missed on attempt \(attempt) of 3"
        try Self.requireOneClock(children, fixture, spawnedAt: spawnedAt)
        if !lastAttempt, let miss = try Self.startMiss(children, fixture,
                                                       spawnedAt: spawnedAt, lifeNeeded: 9) {
            print("\(missed): \(miss)")
            return false
        }
        _ = try #require(children.readyAt, Comment(rawValue: Self.unready(children, fixture)))
        guard let outcome = try Self.completionOutcome(result, runner, spawnedAt: spawnedAt,
                                                       firstSignalAt: children.firstSignalAt,
                                                       returnedAt: returnedAt,
                                                       lastAttempt: lastAttempt, missed: missed)
        else { return false }
        let descendantExpiresAt = try fixture.naturalExpiry(of: "descendant")
        let expectedOutput = Data("root-output\n".utf8)
        let expectedError = Data("root-error\n".utf8)
        #expect(outcome.terminationStatus == 0)
        #expect(outcome.standardOutput == expectedOutput)
        #expect(outcome.standardError == expectedError)
        let outcomeHeld = outcome.terminationStatus == 0
            && outcome.standardOutput == expectedOutput && outcome.standardError == expectedError
        let elapsed = spawnedAt <= returnedAt ? returnedAt - spawnedAt : 0
        let bounded = spawnedAt <= returnedAt && elapsed < 6_000_000_000
        let margin = returnedAt + 3_000_000_000 < descendantExpiresAt
        let windowEnd = returnedAt + 2_000_000_000
        let descendant = try fixture.identity("descendant")
        let liveness = try fixture.keepsRunning(descendant, until: windowEnd)
        let checkedAt = try fixture.uptimeNanoseconds()
        // Read only now: `lapsed` stops the probe, which must also watch the liveness window.
        let returnWithheld = runner.lapsed(from: spawnedAt, to: returnedAt)
        let windowWithheld = runner.lapsed(from: returnedAt, to: checkedAt)
        if !lastAttempt, outcomeHeld, let stall = Self.completionSetAside(
            returnHeld: bounded && margin, spawnedAt: spawnedAt, returnedAt: returnedAt,
            returnWithheld: returnWithheld, liveness: liveness, windowEnd: windowEnd,
            checkedAt: checkedAt, windowWithheld: windowWithheld,
            descendantExpiresAt: descendantExpiresAt) {
            print("\(missed): \(stall)")
            return false
        }
        #expect(bounded, Comment(rawValue:
                "EOF-complete success must not await background work (returned "
                + "\(Self.offset(returnedAt, from: spawnedAt)) after the spawn stamp, "
                + "\(DeschedulingProbe.seconds(returnWithheld)) s of it withheld by the runner)"))
        #expect(margin, Comment(rawValue:
                "EOF-complete success must return three seconds before the preserved descendant "
                + "could expire on its own, so its two-second liveness window fits (returned "
                + "\(Self.offset(returnedAt, from: spawnedAt)) after the spawn stamp, descendant "
                + "expiry \(Self.offset(descendantExpiresAt, from: spawnedAt)) after it)"))
        #expect(liveness.kept, Comment(rawValue:
                "EOF-complete success must preserve background work (returned "
                + "\(Self.offset(returnedAt, from: spawnedAt)) after the spawn stamp, decided "
                + "\(Self.offset(liveness.decidedAt, from: spawnedAt)) after it, descendant "
                + "expiry \(Self.offset(descendantExpiresAt, from: spawnedAt)) after it, "
                + "\(DeschedulingProbe.seconds(windowWithheld)) s of the window withheld)"))
        return true
    }

    private struct Fixture {
        let directory: URL
        /// Seconds from arming to each process's own SIGALRM; twelve by default. Every root the
        /// readiness gate holds arms a thirty-second alarm, because the root arms before `import
        /// ctypes`, the fork and the descendant's start-up, so a starved start-up spends that life
        /// before the deadline starts. The tests whose subject is that cleanup stops the group (the
        /// output-overflow, timeout and drain-timeout tests) pass thirty for both processes: a
        /// regression that runs to natural expiry then returns at more than twice their ten-second
        /// elapsed bounds, and a gate that releases late still leaves their timed checks room.
        /// Cleanup stops both on a green run, so the longer alarms lengthen only a red path's
        /// teardown. The completion tests pass thirty for the root alone: a green root exits on its
        /// own, so its alarm bounds only a red path, while the preserved descendant's alarm is
        /// twelve, because every green run waits it out in teardown.
        let rootExpiry: Int
        let descendantExpiry: Int

        init(directory: URL, rootExpiry: Int = 12, descendantExpiry: Int = 12) {
            self.directory = directory
            self.rootExpiry = rootExpiry
            self.descendantExpiry = descendantExpiry
        }

        func expiry(of name: String) -> Int { name == "root" ? rootExpiry : descendantExpiry }

        // Arm an in-process kernel alarm before publishing readiness or reading stdin. A broken
        // feeder can therefore never strand an unbounded root before child expiry begins. The
        // forked descendant arms its own alarm: alarms are not inherited by fork. /usr/bin/python3
        // is also used by the existing SnapshotLifetimeTests process fixture.
        //
        // Each process publishes `<name>-armed`, the `CLOCK_UPTIME_RAW` time it read just before
        // `alarm()`, ahead of its identity, so a test knows the earliest moment each could expire
        // on its own. The root forks and waits for the descendant's ready byte BEFORE reading
        // stdin: the launcher delivers stdin only after `spawn` returns, so a readiness gate on the
        // descendant's file would otherwise hold until its bound on every stdin delivery. Both
        // alarms are armed before stdin is read, and every mode reads stdin to EOF before it writes
        // or exits.
        private static let rootScript = #"""
        import os, signal, sys, time
        def arm_expiry(seconds):
            signal.signal(signal.SIGALRM, signal.SIG_DFL)
            signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGALRM})
            armed = time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)
            signal.alarm(seconds)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            return armed
        root_armed = arm_expiry(int(sys.argv[4]))
        import ctypes
        # SDK sys/proc_info.h: proc_bsdinfo, PROC_PIDTBSDINFO=3, MAXCOMLEN=16.
        class BSDInfo(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint32) for name in (
                "flags", "status", "xstatus", "pid", "ppid", "uid", "gid",
                "ruid", "rgid", "svuid", "svgid", "reserved")]
            _fields_ += [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)]
            _fields_ += [(name, ctypes.c_uint32) for name in (
                "nfiles", "pgid", "jobc", "tdev", "tpgid")]
            _fields_ += [("nice", ctypes.c_int32), ("seconds", ctypes.c_uint64),
                         ("microseconds", ctypes.c_uint64)]
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        libproc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                       ctypes.c_void_p, ctypes.c_int]
        libproc.proc_pidinfo.restype = ctypes.c_int
        directory, mode, status = sys.argv[1:4]
        def publish(name, value):
            # Write, then rename: a file that exists is complete, even if a kill lands mid-write.
            final = os.path.join(directory, name)
            with open(final + ".tmp", "w") as output:
                output.write(str(value) + "\n")
            os.replace(final + ".tmp", final)
        def publish_identity(name):
            info = BSDInfo()
            size = ctypes.sizeof(info)
            pid = os.getpid()
            if libproc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), size) != size:
                os._exit(92)
            if info.pid != pid:
                os._exit(93)
            publish(name, "%d %d %d" % (pid, info.seconds, info.microseconds))
        root_pid = os.getpid()
        publish("root-armed", root_armed)
        publish_identity("root")
        ready_read, ready_write = os.pipe()
        descendant = os.fork()
        if descendant == 0:
            descendant_armed = arm_expiry(int(sys.argv[5]))
            os.close(ready_read)
            if mode == "closed-output":
                null = os.open(os.devnull, os.O_WRONLY)
                os.dup2(null, 1)
                os.dup2(null, 2)
                os.close(null)
            publish("descendant-armed", descendant_armed)
            publish_identity("descendant")
            os.write(ready_write, b"R")
            os.close(ready_write)
            if mode not in ("wait", "overflow-live"):
                while os.getppid() == root_pid:
                    time.sleep(0.01)
                publish("root-observed-exited", time.clock_gettime_ns(time.CLOCK_UPTIME_RAW))
                if mode == "overflow-after-exit":
                    os.write(1, b"x" * 64)
            while True:
                signal.pause()
        os.close(ready_write)
        ready = os.read(ready_read, 1)
        os.close(ready_read)
        if ready != b"R":
            os._exit(91)
        sys.stdin.buffer.read()
        if mode in ("wait", "overflow-live"):
            if mode == "overflow-live":
                os.write(1, b"x" * 64)
            os.waitpid(descendant, 0)
        else:
            publish("root-exiting", "yes")
            os.write(1, b"root-output\n")
            os.write(2, b"root-error\n")
        os._exit(int(status))
        """#

        func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

        /// Which start-up files the fixture had published when this is read (after the launch
        /// returned), in the order it publishes them, for scenario-miss reports. A missing
        /// `root-armed` means the interpreter never reached the script; a later gap places a
        /// starved or failed start-up between two steps.
        func startupProgress() -> String {
            let reached = ["root-armed", "root", "descendant-armed", "descendant"]
                .filter { FileManager.default.fileExists(atPath: path($0)) }
            return reached.isEmpty ? "fixture published no start-up file"
                : "fixture published \(reached.joined(separator: ", "))"
        }

        func invocation(mode: String, status: Int32, delivery: ScriptDelivery,
                        maximumOutputBytes: Int? = nil) -> ScriptInvocation {
            ScriptInvocation(executablePath: "/usr/bin/python3",
                             arguments: ["-c", Self.rootScript, directory.path, mode,
                                         String(status), String(rootExpiry),
                                         String(descendantExpiry)],
                             delivery: delivery, maximumOutputBytes: maximumOutputBytes)
        }

        /// The `CLOCK_UPTIME_RAW` time a fixture process read just before arming its alarm.
        func armedAt(_ name: String) throws -> UInt64 {
            let text = try String(contentsOfFile: path("\(name)-armed"), encoding: .utf8)
            return try #require(UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                                "\(name)-armed must hold an uptime nanosecond stamp")
        }

        /// The earliest moment a published fixture process can die of its own alarm. The stamp is
        /// read before `alarm()`, so the true expiry is never earlier.
        func naturalExpiry(of name: String) throws -> UInt64 {
            try armedAt(name) + UInt64(expiry(of: name)) * 1_000_000_000
        }

        /// The earliest moment any fixture process can die of its own alarm. The descendant arms
        /// after the root's stamp, so until it publishes its own, the root's stamp bounds it.
        func earliestNaturalExpiry() throws -> UInt64 {
            let rootArmed = try armedAt("root")
            let published = FileManager.default.fileExists(atPath: path("descendant-armed"))
            let descendantArmed = try published ? armedAt("descendant") : rootArmed
            return min(rootArmed + UInt64(rootExpiry) * 1_000_000_000,
                       descendantArmed + UInt64(descendantExpiry) * 1_000_000_000)
        }

        /// A window for observing, after the launch returned, that cleanup stopped the fixture:
        /// `preferred` seconds, cut short to close at least one second before the earliest natural
        /// expiry. A process cleanup never signalled is therefore still live when the window
        /// closes, so the check fails instead of being rescued by the alarm. The one-second margin
        /// survives a host's sleep only because the fixtures' `alarm()` runs on uptime as these
        /// stamps do: per XNU's published source, `setitimer(ITIMER_REAL)` arms from `microuptime`
        /// through a thread call that is not continuous-time, so a sleep pauses the alarm and the
        /// window alike. That has not been measured across a real sleep.
        ///
        /// Residual: nothing bounds when the observation that decides `stops` or `liveMembers` is
        /// made, so a stall of this thread just before it can move it past the earliest natural
        /// expiry, where a survivor its own alarm killed reads as stopped, or as no live member: a
        /// false pass. The window can close as little as a second before that expiry, chiefly on a
        /// last attempt whose gate released late, so there a stall of over a second at the window's
        /// end is enough. `pauseEnded` still requires the SIGTERM and SIGKILL turns, but the
        /// decorator records them even when a regressed backend signals only the root, so this
        /// window is that regression's only guard.
        func stopWindow(_ preferred: TimeInterval) throws -> TimeInterval {
            let closesBy = try earliestNaturalExpiry() - 1_000_000_000
            let now = try uptimeNanoseconds()
            guard now < closesBy else { return 0 }
            return min(preferred, Double(closesBy - now) / 1_000_000_000)
        }

        // Python and Swift explicitly use the same named OS clock, `CLOCK_UPTIME_RAW`, and
        // nanosecond units; it is also the clock the launcher's `DispatchTime` deadlines and the
        // kernel's alarm timer read, and `DeschedulingProbe`'s. The fixtures name it rather than
        // calling `time.monotonic_ns()`, which on the 3.9 `/usr/bin/python3` checked here counts
        // from the interpreter's own start and so cannot be compared across processes.
        func uptimeNanoseconds() throws -> UInt64 {
            var value = timespec()
            guard clock_gettime(CLOCK_UPTIME_RAW, &value) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
        }

        struct Identity {
            let pid: pid_t
            let seconds: Int64
            let microseconds: Int64
        }

        func identity(_ name: String) throws -> Identity {
            let text = try String(contentsOfFile: path(name), encoding: .utf8)
            let fields = text.split(whereSeparator: { $0.isWhitespace })
            try #require(fields.count == 3)
            let pid = try #require(pid_t(fields[0]))
            let seconds = try #require(Int64(fields[1]))
            let microseconds = try #require(Int64(fields[2]))
            try #require(pid > 1 && seconds > 0 && (0..<1_000_000).contains(microseconds))
            return Identity(pid: pid, seconds: seconds, microseconds: microseconds)
        }

        /// Read-only observation; a zombie has stopped executing even if init has not reaped it.
        /// Compare the ready-time PID and kernel start time, so reuse cannot make a survivor
        /// check pass for an unrelated process. Sysctl failure is never treated as death.
        func isRunning(_ identity: Identity) throws -> Bool {
            guard let state = try runState(of: identity) else { return false }
            return state != SZOMB
        }

        /// `isRunning`, and not stopped by a signal either. A preserved process that a regression
        /// SIGSTOPped keeps its PID and start time, so `isRunning` reads it as running; the
        /// liveness checks use this instead. `stops` uses `isRunning`, so a stopped process can
        /// never pass a cleanup check.
        func isExecuting(_ identity: Identity) throws -> Bool {
            guard let state = try runState(of: identity) else { return false }
            return state != SZOMB && state != SSTOP
        }

        /// The kernel's run state (`p_stat`) of the process with this PID and start time, or nil
        /// when no such process exists. Read-only; sysctl failure is never treated as death.
        private func runState(of identity: Identity) throws -> Int32? {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, identity.pid]
            let result = sysctl(&mib, 4, &info, &size, nil, 0)
            if result != 0 {
                if errno == ESRCH { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard size > 0 else { return nil }
            let started = info.kp_proc.p_un.__p_starttime
            guard info.kp_proc.p_pid == identity.pid
                && Int64(started.tv_sec) == identity.seconds
                && Int64(started.tv_usec) == identity.microseconds else { return nil }
            return Int32(info.kp_proc.p_stat)
        }

        /// Whether a preserved process keeps executing until `end`, a `CLOCK_UPTIME_RAW` stamp the
        /// caller sets from the launch's return, observed every 20 ms. It also returns `decidedAt`:
        /// when an observation found the process gone or stopped, a stamp read just after that
        /// observation; otherwise the stamp read just before the last one, which came at or after
        /// `end`. One observation right after the return could read a process that a regression had
        /// just SIGKILLed as still running, because the kill completes only when that process next
        /// runs; observing through the window closes that gap. The window is never cut short: the
        /// last observation comes at or after `end`, so a stall of this thread can drop
        /// observations but never move the last one earlier. Callers check separately that `end`
        /// leaves a second before natural expiry. Read-only: it never signals.
        ///
        /// The completion tests set a failure aside on attempts 1 and 2 only when `decidedAt` came
        /// no sooner than the descendant's expiry less `DeschedulingProbe.clockRoundingNanoseconds`
        /// and a `DeschedulingProbe` saw the window withheld (`livenessAllowanceNanoseconds`). A
        /// failure's stamp follows the observation that found the process gone, so the process was
        /// gone by then: a stall of this thread before or during that observation can only move the
        /// stamp later, which can only make the failure eligible for a set-aside (which still needs
        /// the probe's evidence and only re-runs an attempt), and never makes a death look sooner
        /// than it was.
        ///
        /// Residual: a stall can move the last observation later. The callers' margin can leave
        /// `end` as little as a second before natural expiry, so a stall at the window's end longer
        /// than the margin left can land that observation after the descendant's own alarm and fail
        /// a correct launcher. That remains only for a stall the probe does not see and for the
        /// last attempt, which is never re-run.
        func keepsRunning(_ identity: Identity, until end: UInt64) throws
            -> (kept: Bool, decidedAt: UInt64) {
            while true {
                let at = try uptimeNanoseconds()
                if try !isExecuting(identity) {
                    // Read after the observation, so it bounds the death from above.
                    let after = try uptimeNanoseconds()
                    return (false, after)
                }
                if at >= end { return (true, at) }
                usleep(20_000)
            }
        }

        /// Live (non-zombie) members of a process group, polled until none remain or the settling
        /// time passes. Read-only: it never signals. A reused group id can only add members, so it
        /// can cause a false failure, never a false pass; the fixture never leaves its group.
        func liveMembers(ofGroup group: pid_t, settlingWithin seconds: TimeInterval) throws -> [pid_t] {
            let deadline = try uptimeNanoseconds() + UInt64(seconds * 1_000_000_000)
            while true {
                let members = try liveMembers(ofGroup: group)
                let now = try uptimeNanoseconds()
                if members.isEmpty || now >= deadline { return members }
                usleep(20_000)
            }
        }

        func liveMembers(ofGroup group: pid_t) throws -> [pid_t] {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, group]
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let stride = MemoryLayout<kinfo_proc>.stride
            var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
            size = processes.count * stride
            guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return processes.prefix(size / stride)
                .filter { Int32($0.kp_proc.p_stat) != SZOMB }
                .map { $0.kp_proc.p_pid }
        }

        func stops(_ identity: Identity, within seconds: TimeInterval) throws -> Bool {
            try stops(identity, within: seconds,
                      wallNow: { Date().timeIntervalSinceReferenceDate },
                      monotonicNow: { Double(try uptimeNanoseconds()) / 1_000_000_000 },
                      observe: { try isRunning($0) }, pause: { usleep(20_000) })
        }

        // Private actual-helper seam. Elapsed waiting ignores calendar adjustments;
        // wallNow remains only to verify that no wall-clock fallback is consulted.
        func stops(_ identity: Identity, within seconds: TimeInterval,
                   wallNow: () -> TimeInterval, monotonicNow: () throws -> TimeInterval,
                   observe: (Identity) throws -> Bool, pause: () throws -> Void) throws -> Bool {
            let deadline = try monotonicNow() + seconds
            repeat {
                if try !observe(identity) { return true }
                try pause()
            } while try monotonicNow() < deadline
            return try !observe(identity)
        }

        /// The fixtures, not stale-PID kills or abandoned test workers, bound RED-path cleanup.
        /// Internal descriptor closure is verified separately by ProcessResourceTests. An arbitrary
        /// infinite loop inside the launcher still requires the suite-level bound.
        ///
        /// This wait is teardown-only. It keeps self-expiring fixtures from outliving the test, and
        /// it returns as soon as each process has stopped, so a run whose cleanup already stopped
        /// both pays nothing. The completion tests always wait here for their preserved
        /// descendant's own alarm, and a starved process still has to be scheduled before it can
        /// act on SIGALRM. Under starvation (background QoS, one busy process per core), a window
        /// that leaves only a few seconds past the alarm is too short for the fixtures to stop. So
        /// each process's window, counted from the start of its own wait, is its full expiry plus
        /// 48 seconds: 60 for a twelve-second alarm, 78 for a thirty-second one. Because each alarm
        /// is armed before this wait begins, that leaves at least 48 seconds past the alarm. A
        /// process that never stops still fails here, with its name and the time waited.
        func waitForNaturalExpiry() {
            do {
                for name in ["descendant", "root"] {
                    guard FileManager.default.fileExists(atPath: path(name)) else { continue }
                    let window = expiry(of: name) + 48
                    let start = try uptimeNanoseconds()
                    let stopped = try stops(identity(name), within: TimeInterval(window))
                    let waited = try uptimeNanoseconds() - start
                    #expect(stopped, Comment(rawValue:
                            "the self-expiring synthetic fixture remained live (\(name), waited "
                            + "\(waited / 1_000_000) ms of a \(window)-second teardown window)"))
                }
            } catch {
                Issue.record("could not observe synthetic fixture cleanup: \(error)")
            }
        }
    }
}
