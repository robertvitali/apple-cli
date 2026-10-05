import Darwin
import Foundation
import Testing
import TestSupport
@testable import AppleKit

private final class ProcessTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var events: [String] { lock.withLock { values } }
}

/// All allocations and closes go to the actual kernel. Recording an FD twice without an
/// intervening close is a failure; successful closes remove that allocation's generation.
private final class RecordingProcessIO: ScriptProcessIO, @unchecked Sendable {
    let live = DarwinScriptProcessIO()
    let trace: ProcessTrace
    private let lock = NSLock()
    private var liveDescriptors = Set<Int32>()
    private var created = 0
    private var captureReads = 0
    var readFailure: Int32?
    var failedReadPipe = 1
    private var pipesCreated = 0
    private var failedReadFD: Int32?
    var captureFailure: NSError?
    var failCaptureRead = 1
    var failSecondCaptureAllocation = false
    var failInputClose = false
    var inputWriter: Int32?
    /// With a value, every read returns one synthetic byte instead of reading, until that many
    /// seconds after the first read, and then fails with EIO: output that never stops by itself but
    /// does end. It is timed from the first read, so a readiness hold before the launcher's
    /// deadline cannot shorten it.
    var syntheticReadSeconds: Double?
    private var syntheticReadEnd: DispatchTime?
    private var readStamps: [DispatchTime] = []
    var capturePayloads: [Data] = []
    var captureSizeFailure: NSError?
    var captureGrowthBeforeSnapshot: Data?
    private var capturesCreated = 0
    var sizeObservations = 0
    var snapshotAllowances: [Int?] = []
    var readBufferSizes: [Int] = []

    init(trace: ProcessTrace = ProcessTrace()) { self.trace = trace }
    var outstanding: Set<Int32> { lock.withLock { liveDescriptors } }
    var allocationCount: Int { lock.withLock { created } }
    /// When each `read` was called, on the clock the launcher's deadline reads (`DispatchTime`).
    var readTimes: [DispatchTime] { lock.withLock { readStamps } }
    private func record(_ fd: Int32) -> Int32 {
        lock.withLock {
            #expect(liveDescriptors.insert(fd).inserted)
            created += 1
        }
        trace.add("allocate")
        return fd
    }
    func pipe() throws -> (read: Int32, write: Int32) {
        let pair = try live.pipe()
        if inputWriter == nil { inputWriter = pair.write }
        if pipesCreated == failedReadPipe { failedReadFD = pair.read }
        pipesCreated += 1
        return (record(pair.read), record(pair.write))
    }
    func nullInput() throws -> Int32 { record(try live.nullInput()) }
    func capture(in directory: URL) throws -> Int32 {
        if failSecondCaptureAllocation, allocationCount == 2 { throw DarwinScriptProcessIO.posixError(EMFILE) }
        let fd = record(try live.capture(in: directory))
        if capturesCreated < capturePayloads.count {
            _ = try capturePayloads[capturesCreated].withUnsafeBytes { try live.write(fd, from: $0) }
        }
        capturesCreated += 1
        return fd
    }
    func read(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let calledAt = DispatchTime.now()
        let syntheticEnd: DispatchTime? = lock.withLock {
            readStamps.append(calledAt)
            if let seconds = syntheticReadSeconds, syntheticReadEnd == nil {
                syntheticReadEnd = calledAt + seconds
            }
            return syntheticReadEnd
        }
        readBufferSizes.append(buffer.count)
        if let readFailure, fd == failedReadFD { throw DarwinScriptProcessIO.posixError(readFailure) }
        if let until = syntheticEnd {
            if DispatchTime.now() >= until { throw DarwinScriptProcessIO.posixError(EIO) }
            usleep(1_000)
            buffer[0] = 120
            return 1
        }
        return try live.read(fd, into: buffer)
    }
    func write(_ fd: Int32, from buffer: UnsafeRawBufferPointer) throws -> Int { try live.write(fd, from: buffer) }
    func captureSize(_ fd: Int32) throws -> off_t {
        sizeObservations += 1
        trace.add("size")
        if let captureSizeFailure { throw captureSizeFailure }
        return try live.captureSize(fd)
    }
    func captureSnapshot(_ fd: Int32, maximumBytes: Int? = nil, configuredLimit: Int? = nil) throws -> Data {
        captureReads += 1
        snapshotAllowances.append(maximumBytes)
        trace.add("capture\(captureReads)")
        if captureReads == failCaptureRead, let captureFailure { throw captureFailure }
        if captureReads == 2, let growth = captureGrowthBeforeSnapshot {
            _ = try growth.withUnsafeBytes { try live.write(fd, from: $0) }
        }
        return try live.captureSnapshot(fd, maximumBytes: maximumBytes, configuredLimit: configuredLimit)
    }
    func close(_ fd: Int32) throws {
        try live.close(fd)
        #expect(lock.withLock { liveDescriptors.remove(fd) } != nil)
        trace.add("close")
        // The real close already happened: injecting the error must not leak a test fixture FD.
        if failInputClose, fd == inputWriter { throw DarwinScriptProcessIO.posixError(EIO) }
    }
}

private final class RecordedReaper: ScriptProcessReaping, @unchecked Sendable {
    let trace: ProcessTrace
    private let live = DarwinScriptProcessReaper()
    private let lock = NSLock()
    private var completed = false
    init(_ trace: ProcessTrace) { self.trace = trace }
    var reaped: Bool { lock.withLock { completed } }
    func reap(_ pid: pid_t) throws -> Bool {
        let result = try live.reap(pid)
        if result { lock.withLock { completed = true }; trace.add("reaped") }
        return result
    }
}

/// Forwards every child operation to the Darwin backend and records it in the trace. It also
/// stamps, on `CLOCK_MONOTONIC`, when `spawn` returned and when cleanup first signalled the group,
/// so an elapsed bound can start where the launcher's deadline starts instead of before process
/// start-up.
///
/// With `readyFile`, `spawn` also holds the launcher until the root has published that file, for at
/// most `holdSeconds` (sixty by default; a hold ends as soon as the file appears or the root
/// exits). The launcher starts its deadline when `spawn` returns, so the root's interpreter
/// start-up, which a starved runner can stretch by tens of seconds, falls outside it. This is the
/// readiness gate of `OwnedProcessCleanupTests.SpawnStampingChildren`. It allocates no descriptors,
/// so allocation counts are unchanged. `sawReady` records whether the file was there when the hold
/// ended, so a test can tell an attempt whose start-up ran into the deadline from one whose
/// start-up did not; `readyAtFirstSignal` records whether it existed when cleanup first signalled
/// the group, so a timeout is judged by what the fixture had done when the launcher gave up rather
/// than by what it did during cleanup.
///
/// While the gate holds, the launcher is still inside `spawn`: it has not started its deadline,
/// delivered stdin, observed or signalled, so a gate miss can hide no fault in those steps. The
/// product's `spawn`, which sets up the child's descriptors, signal mask and defaults and process
/// group, runs before the hold, so the gate also watches the root. It asks with a wait that passes
/// WNOWAIT, as the product's own `observe` does, so it never reaps the root: the launcher owns
/// reaping and still finds the exit. A root that exits ends the hold at once, and
/// `exitedBeforeReady` records whether the file was still missing then. In every mode the gated
/// tests use, the root publishes before it can exit or, in the detached mode, cannot exit before
/// the descendant publishes, so such a root died in start-up, of its own expiry or of a fault in
/// that setup, before the launcher had done anything past starting it. Callers fail it on any
/// attempt (`earlyExit`), except a death by the root's own SIGALRM seen no sooner than its expiry
/// after `spawn` was called: the root cannot arm before then, so that is its alarm firing on time
/// while the runner withheld it, and on an attempt that is not the last it is a miss; on the last
/// it fails like any other early exit. A hold that ran out with the root still running is a miss
/// too.
private final class RecordedChildren: ScriptProcessChildren, @unchecked Sendable {
    let trace: ProcessTrace
    let recordedReaper: RecordedReaper
    private let live = DarwinScriptProcessChildren()
    private let readyFile: String?
    private let holdSeconds: UInt64
    private let lock = NSLock()
    private var stamps: (spawned: UInt64?, firstSignal: UInt64?) = (nil, nil)
    private var seen: Bool?
    private var exitedEarly: Bool?
    private var exitNote: String?
    private var alarmAfterCall: UInt64?
    private var readyAtSignal: Bool?
    var reaper: any ScriptProcessReaping { recordedReaper }
    init(_ trace: ProcessTrace, readyFile: String? = nil, holdSeconds: UInt64 = 60) {
        self.trace = trace
        self.readyFile = readyFile
        self.holdSeconds = holdSeconds
        recordedReaper = RecordedReaper(trace)
    }

    /// Nanoseconds on `CLOCK_MONOTONIC`. It cannot throw, so a stamp taken after a successful spawn
    /// can never strand the child; a failed clock read returns zero and fails the bound.
    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC) }

    var spawnedAt: UInt64? { lock.withLock { stamps.spawned } }
    var firstSignalAt: UInt64? { lock.withLock { stamps.firstSignal } }
    /// Whether the gate saw `readyFile` when its hold ended; nil without a gate or a spawn.
    var sawReady: Bool? { lock.withLock { seen } }
    /// Whether the gate saw the root exit while `readyFile` was still missing; nil without a gate
    /// or a spawn. False both for a root that published and for a hold that ran out.
    var exitedBeforeReady: Bool? { lock.withLock { exitedEarly } }
    /// How the root ended and when the gate saw it, when `exitedBeforeReady` is true.
    var earlyExit: String? { lock.withLock { exitNote } }
    /// When the root exited before it published by dying of SIGALRM: nanoseconds from the call into
    /// `spawn` to when the gate saw the death. Nil otherwise.
    var earlyAlarmAfterCall: UInt64? { lock.withLock { alarmAfterCall } }
    /// Whether `readyFile` existed when the group was first signalled; nil without a gate or a
    /// signal.
    var readyAtFirstSignal: Bool? { lock.withLock { readyAtSignal } }

    /// The root's exit as a non-reaping wait reports it, or nil while it runs or when the wait
    /// fails. WNOWAIT, as in the product's own `observe`, leaves the exit for the launcher to
    /// observe and reap.
    private static func exitWithoutReaping(_ pid: pid_t) -> siginfo_t? {
        var information = siginfo_t()
        guard waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT) == 0,
              information.si_pid == pid else { return nil }
        return information
    }

    func spawn(_ invocation: ScriptInvocation, input: Int32, output: Int32, error: Int32) throws -> pid_t {
        trace.add("spawn")
        let called = Self.now()
        let pid = try live.spawn(invocation, input: input, output: output, error: error)
        if let readyFile {
            let began = Self.now()
            let limit = began + holdSeconds * 1_000_000_000
            var rootExit: siginfo_t?
            while !FileManager.default.fileExists(atPath: readyFile), Self.now() < limit {
                if let ended = Self.exitWithoutReaping(pid) { rootExit = ended; break }
                usleep(5_000)
            }
            let endedAt = Self.now()
            // Read after the exit was seen, so a file the root renamed into place before it exited
            // counts as published.
            let ready = FileManager.default.fileExists(atPath: readyFile)
            let note = rootExit.map { ended -> String in
                let how = ended.si_code == CLD_EXITED ? "exit status \(ended.si_status)"
                    : "signal \(ended.si_status)"
                let after = String(format: "%.2f",
                                   endedAt >= began ? Double(endedAt - began) / 1e9 : 0)
                return "\(how), seen \(after) s after the real spawn returned"
            }
            lock.withLock {
                if seen == nil {
                    seen = ready
                    exitedEarly = rootExit != nil && !ready
                    exitNote = ready ? nil : note
                    if let ended = rootExit, !ready, ended.si_code == CLD_KILLED,
                       ended.si_status == SIGALRM, endedAt >= called {
                        alarmAfterCall = endedAt - called
                    }
                }
            }
        }
        let at = Self.now()
        lock.withLock { if stamps.spawned == nil { stamps.spawned = at } }
        return pid
    }
    func observe(_ pid: pid_t) throws -> Int32? {
        let result = try live.observe(pid)
        if result != nil { trace.add("observed") }
        return result
    }
    func signal(group: pid_t, signal: Int32) throws {
        // A deliberately broken reap-before-signal mutation cannot reach a reused group.
        guard !recordedReaper.reaped else {
            Issue.record("attempted signalling after reaping")
            throw DarwinScriptProcessIO.posixError(ECHILD)
        }
        let at = Self.now()
        let ready = readyFile.map { FileManager.default.fileExists(atPath: $0) }
        lock.withLock {
            if stamps.firstSignal == nil { stamps.firstSignal = at; readyAtSignal = ready }
        }
        trace.add("signal\(signal)")
        try live.signal(group: group, signal: signal)
    }
}

private final class FakeReaper: ScriptProcessReaping, @unchecked Sendable {
    enum Reply { case pending, exited, lost }
    private let lock = NSLock()
    private var selectedReply: Reply = .pending
    private var callCount = 0
    private var remainingPending = 0
    private var naturalEnd: DispatchTime?
    private var stamps: [DispatchTime] = []
    var reply: Reply {
        get { lock.withLock { selectedReply } }
        set { lock.withLock { selectedReply = newValue } }
    }
    var calls: Int { lock.withLock { callCount } }
    var pendingReplies: Int {
        get { lock.withLock { remainingPending } }
        set { lock.withLock { remainingPending = newValue } }
    }
    /// From this time on the child reaps as exited whatever `reply` says: a natural end, so a
    /// cleanup that waits for the child returns late instead of never.
    var reapableAt: DispatchTime? {
        get { lock.withLock { naturalEnd } }
        set { lock.withLock { naturalEnd = newValue } }
    }
    /// When each `reap` call was made, on the clock the launcher's reap window reads
    /// (`DispatchTime`), so a test can check that window from the launcher's own turns.
    var reapTimes: [DispatchTime] { lock.withLock { stamps } }
    func reap(_ pid: pid_t) throws -> Bool {
        try lock.withLock {
            callCount += 1
            stamps.append(DispatchTime.now())
            if remainingPending > 0 { remainingPending -= 1; return false }
            if let naturalEnd, DispatchTime.now() >= naturalEnd { return true }
            switch selectedReply {
            case .pending: return false
            case .exited: return true
            case .lost: throw DarwinScriptProcessIO.posixError(ECHILD)
            }
        }
    }
}

/// A fully synthetic backend: there is NO live spawn, signal, or wait forwarding route.
/// Parent descriptors remain real so rare ownership states still exercise their closure.
private final class NoSpawnChildren: ScriptProcessChildren, @unchecked Sendable {
    enum Observation { case exited, pending, lost, lostAfterTerm }
    let fakeReaper = FakeReaper()
    var reaper: any ScriptProcessReaping { fakeReaper }
    var observation: Observation = .exited
    var signals: [Int32] = []
    var starts = 0
    var returnedPID: pid_t = Int32.max - 1
    var signalError: Int32?
    var pendingObservations = 0
    var delayedObservationMicroseconds: useconds_t = 0
    /// Every observation (a nil signal) and every signal, in call order, with when the call was
    /// made on the clock the launcher's pause reads (`DispatchTime`).
    var timeline: [(signal: Int32?, at: DispatchTime)] = []
    func spawn(_ invocation: ScriptInvocation, input: Int32, output: Int32, error: Int32) throws -> pid_t {
        starts += 1
        return returnedPID // An opaque test value; never submitted to a Darwin child API.
    }
    func observe(_ pid: pid_t) throws -> Int32? {
        timeline.append((signal: nil, at: DispatchTime.now()))
        if pendingObservations > 0 { pendingObservations -= 1; return nil }
        if delayedObservationMicroseconds > 0 {
            let delay = delayedObservationMicroseconds
            delayedObservationMicroseconds = 0
            usleep(delay)
        }
        switch observation {
        case .exited: return 0
        case .pending: return nil
        case .lost: throw DarwinScriptProcessIO.posixError(ECHILD)
        case .lostAfterTerm:
            if signals.contains(SIGTERM) { throw DarwinScriptProcessIO.posixError(ECHILD) }
            return 0
        }
    }
    func signal(group: pid_t, signal: Int32) throws {
        timeline.append((signal: signal, at: DispatchTime.now()))
        signals.append(signal)
        if let signalError { throw DarwinScriptProcessIO.posixError(signalError) }
    }
}

private final class HeldReaps: ScriptDeferredReaping, @unchecked Sendable {
    var obligations: [ScriptPendingReap] = []
    func accept(_ pending: ScriptPendingReap) { obligations.append(pending) }
}

@Suite("process resource ownership")
struct ProcessResourceTests {
    private let scratch = ScratchDirs("process-resources")
    private static let sentinel = NSError(domain: "synthetic.capture.failure", code: 71,
                                         userInfo: ["synthetic": "preserve this error"])

    // Every root and forked descendant arms an independent expiry before reading/writing or
    // waiting. No test-side PID signals. The root waits for child readiness before exposing EPIPE
    // or output readiness. The detached control is outside production group-cleanup scope.
    //
    // Options follow the mode as `name=value` arguments, so a test that needs more room on a
    // starved runner can have it while every other caller keeps the six-second expiry: `expiry`
    // (seconds) arms the root and its descendant, and `descendant-expiry` overrides the
    // descendant's. `ready` names a file the root publishes, by write-then-rename, for the
    // RecordedChildren readiness gate: in flood mode once output is pending, in the forking modes
    // just before the fork. `heartbeat` names the detached descendant's heartbeat file; its first
    // value is written before readiness, and the descendant stops when `<heartbeat>.stop` appears,
    // acknowledging with `<heartbeat>.stopped`.
    private static let fixture = #"""
    import os, signal, sys, time
    mode = sys.argv[1]
    options = dict(argument.split("=", 1) for argument in sys.argv[2:])
    expiry = int(options.get("expiry", "6"))
    def expire(seconds):
        signal.signal(signal.SIGALRM, signal.SIG_DFL)
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGALRM})
        signal.alarm(seconds)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    def publish(path, text=""):
        with open(path + ".next", "w") as handle:
            handle.write(text)
        os.replace(path + ".next", path)
    def ready():
        if "ready" in options:
            publish(options["ready"])
    expire(expiry)
    if mode == "signal":
        os.kill(os.getpid(), signal.SIGKILL)
    if mode == "flood":
        os.write(1, b"x" * 1024)
        os.write(2, b"progress\n")
        ready()
        while True:
            os.write(1, b"x" * 1024)
            os.write(2, b"progress\n")
            time.sleep(0.001)
    if mode == "exit":
        os.write(1, b"output")
        os.write(2, b"error")
        os._exit(7)
    ready()
    ready_in, ready_out = os.pipe()
    if os.fork() == 0:
        expire(int(options.get("descendant-expiry", expiry)))
        os.close(ready_in)
        if mode == "detached":
            os.setsid()
        os.close(0)
        if mode == "detached":
            # Only this detached child writes the private heartbeat. An advancing value after
            # launcher return proves it is still executing without a PID-reuse assumption. The
            # first value precedes readiness, so it exists before the root can close stdin and
            # the launcher can return.
            heartbeat = options["heartbeat"]
            publish(heartbeat, str(time.monotonic_ns()))
        os.write(ready_out, b"r")
        os.close(ready_out)
        if mode == "detached":
            # The test asks for the stop and waits for the acknowledgement, after which nothing
            # more is written, before its scratch directory is removed.
            while not os.path.exists(heartbeat + ".stop"):
                time.sleep(0.02)
                publish(heartbeat, str(time.monotonic_ns()))
            publish(heartbeat + ".stopped")
            os._exit(0)
        while True:
            signal.pause()
    os.close(ready_out)
    os.read(ready_in, 1)
    os.close(ready_in)
    if mode in ("delivery", "detached"):
        os.close(0)
    os.write(1, b"ready")
    os.write(2, b"ready")
    if mode == "capture":
        os._exit(0)
    while True:
        signal.pause()
    """#

    private func invocation(_ mode: String, delivery: ScriptDelivery,
                            maximumOutputBytes: Int? = nil,
                            options: [String] = []) -> ScriptInvocation {
        ScriptInvocation(executablePath: "/usr/bin/python3",
                         arguments: ["-c", Self.fixture, mode] + options,
                         delivery: delivery, maximumOutputBytes: maximumOutputBytes)
    }

    /// The launcher's observations in its pause between the first SIGTERM and the first SIGKILL:
    /// every observation between the two but the last, which is the check SIGKILL makes before it
    /// is sent. Nil when either signal is missing or they are out of order, which the signal checks
    /// report.
    private static func pauseTurns(
        _ timeline: [(signal: Int32?, at: DispatchTime)]
    ) -> [DispatchTime]? {
        guard let term = timeline.firstIndex(where: { $0.signal == SIGTERM }),
              let kill = timeline.firstIndex(where: { $0.signal == SIGKILL }), term < kill
        else { return nil }
        return timeline[(term + 1)..<kill].dropLast().map { $0.at }
    }

    /// Checks a window from the launcher's own turns. `turns` are the stamps the launcher made
    /// inside the window, on the clock its deadline reads (`DispatchTime`). The first comes after
    /// the window's deadline was set and every one but the last before that deadline, so under any
    /// load the second-to-last is less than `seconds` after the first: a stall can only drop turns
    /// from that span, never stretch it. Fewer than three stamps leave the window unmeasured (with
    /// two, the second-to-last is the first); a correct launcher leaves it unmeasured only when the
    /// runner withheld it for most of the window, and a launcher that waits blindly in place of the
    /// window always does. Returns whether the window was measured; an unmeasured one records an
    /// issue only when `required`. Issues carry the caller's line through the `#_sourceLocation`
    /// default; a default built from `#line` and `#column` would carry this declaration's line
    /// instead.
    @discardableResult
    private static func checkWindow(_ turns: [DispatchTime], within seconds: Double,
                                    _ window: String, required: Bool,
                                    sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        guard turns.count >= 3 else {
            if required {
                Issue.record("\(window): \(turns.count) turns, too few to measure the window",
                             sourceLocation: sourceLocation)
            }
            return false
        }
        let first = turns[0]
        let last = turns[turns.count - 2]
        let span = (Double(last.uptimeNanoseconds) - Double(first.uptimeNanoseconds)) / 1e9
        #expect(last < first + seconds, """
            \(window) must end at \(seconds) s (its second-to-last turn came \(span) s after \
            its first)
            """, sourceLocation: sourceLocation)
        return true
    }

    /// The most of one recorded stall a `DeschedulingProbe` misses: a lapse counts from when its
    /// tick should have ended, so up to one 50 ms tick of the stall before that goes unseen.
    /// `crossedOnlyByStall` grants it once, and only when the probe recorded a stall in the span.
    /// Each bound it serves keeps seconds above the launcher's own worst case (three for the
    /// fairness test's signal bound, more for the others), which absorbs the tick the probe can
    /// miss of each further stall.
    private static let stallUndercountNanoseconds: UInt64 = 50_000_000

    /// Whether a crossed wall-clock bound may be set aside on attempt 1 or 2: a `DeschedulingProbe`
    /// recorded a stall in the bound's own span, and the time of that span it did not see withheld,
    /// `elapsed` less `withheld`, stays under `bound`, granted `stallUndercountNanoseconds`. The
    /// probe never observes the launcher, so time the launcher spends waiting on its own thread
    /// leaves the probe on time and counts against it in full: a launcher that spends the bound
    /// itself still fails, however long the runner also withheld the process. Callers ask only
    /// about a bound already crossed, and never on the last attempt.
    private static func crossedOnlyByStall(elapsed: UInt64, withheld: UInt64,
                                           bound: UInt64) -> Bool {
        withheld > 0 && elapsed < bound + withheld + stallUndercountNanoseconds
    }

    /// How an attempt's readiness gate ended, for the early-exit rule (see `RecordedChildren`).
    private enum EarlyExit { case none, failed, missed(String) }

    /// Classifies a gate that saw the root exit while the ready file was still missing. The
    /// launcher was still inside `spawn` and had started nothing, so the root died in start-up, of a
    /// fault in the product's `spawn` setup or of its own expiry. A death by SIGALRM seen no sooner
    /// than `expiry` seconds (less a tenth for clock slew) after the call into `spawn` is the root's
    /// own alarm firing on time, which only a runner that withheld the root for its whole expiry
    /// produces, so on an attempt that is not the last it is a miss. Any other early exit, and that
    /// one on the last attempt, records an issue at the caller's line (through the
    /// `#_sourceLocation` default) and fails the attempt; it is never re-run.
    private static func earlyExit(_ children: RecordedChildren, _ scenario: String,
                                  expiry: UInt64, lastAttempt: Bool,
                                  sourceLocation: SourceLocation = #_sourceLocation) -> EarlyExit {
        guard children.exitedBeforeReady == true else { return .none }
        let due = expiry * 1_000_000_000 - 100_000_000
        if !lastAttempt, let after = children.earlyAlarmAfterCall, after >= due {
            return .missed(String(format: "the root died of its own %llu-second alarm before it "
                + "published, %.2f s after the spawn call", expiry, Double(after) / 1e9))
        }
        Issue.record("""
            \(scenario): the root exited before the readiness file appeared \
            (\(children.earlyExit ?? "no detail")), so the launcher never ran the scenario
            """, sourceLocation: sourceLocation)
        return .failed
    }

    /// Whether a timed-out attempt shows only the shape a root's slow start-up leaves, so that it
    /// may be re-run. Every part is read from the gate and the trace, none from a product check:
    /// the gate's hold ran out without `ready` with the root still running, decided while the
    /// launcher was still inside `spawn`; the launcher's first signal came at least `seconds` after
    /// the spawn stamp, so it held its whole deadline (the stamp precedes the deadline's start and
    /// the signal follows its expiry; a millisecond is allowed for clock rounding); and the trace
    /// shows the root's exit observed at most twice before that signal. A launcher that acts on an
    /// observed exit leaves at most the observation on its last turn and the one its first signal
    /// makes to revalidate; one that sat on an observed exit observes it again on every turn.
    ///
    /// Whether the root published `ready` by the return is deliberately not asked: a root still in
    /// start-up when the deadline expires is stopped by the timeout's group signals before it can
    /// publish, so asking would fail a correct launcher whenever start-up outlasts the gate and the
    /// deadline together, without separating any launcher fault from that. A fault that keeps every
    /// root from running still fails the last attempt, which runs every check.
    private static func startupRanIntoDeadline(_ result: Result<ScriptOutcome, any Error>,
                                               _ children: RecordedChildren,
                                               deadline seconds: UInt64) -> Bool {
        guard case .failure(let failure) = result, failure is AppleScriptRunner.TimeoutError,
              children.sawReady == false, children.exitedBeforeReady == false,
              let spawnedAt = children.spawnedAt,
              let signalledAt = children.firstSignalAt,
              signalledAt >= spawnedAt + seconds * 1_000_000_000 - 1_000_000
        else { return false }
        let beforeSignal = children.trace.events.prefix(while: { !$0.hasPrefix("signal") })
        return beforeSignal.filter { $0 == "observed" }.count <= 2
    }

    @Test("bounded capture rejects its observed extent before attempting an unreadable payload")
    func outputLimitSnapshotBeforeRead() throws {
        let file = try scratch.directory().appendingPathComponent("write-only")
        try Data("123456789".utf8).write(to: file)
        let fd = open(file.path, O_WRONLY | O_CLOEXEC)
        try #require(fd >= 0)
        defer { _ = Darwin.close(fd) }
        let io = DarwinScriptProcessIO()
        #expect(try io.captureSize(fd) == 9)
        let overflow = try #require(#expect(throws: ScriptOutputLimitExceeded.self) {
            _ = try io.captureSnapshot(fd, maximumBytes: 8, configuredLimit: 8)
        })
        #expect(overflow.maximumOutputBytes == 8)
        // Once size fits, the same descriptor must still report the real pread EBADF.
        let readError = try #require(#expect(throws: NSError.self) {
            _ = try io.captureSnapshot(fd, maximumBytes: 9, configuredLimit: 9)
        })
        #expect(readError.domain == NSCocoaErrorDomain)
        #expect((readError.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(EBADF))
    }

    @Test("zero remaining capture allowance accepts empty and refuses positive extent")
    func outputLimitZeroRemainder() throws {
        let io = DarwinScriptProcessIO()
        let fd = try io.capture(in: scratch.directory())
        defer { try? io.close(fd) }
        #expect(try io.captureSnapshot(fd, maximumBytes: 0, configuredLimit: 8).isEmpty)
        _ = try Data([1]).withUnsafeBytes { try io.write(fd, from: $0) }
        let overflow = try #require(#expect(throws: ScriptOutputLimitExceeded.self) {
            _ = try io.captureSnapshot(fd, maximumBytes: 0, configuredLimit: 8)
        })
        #expect(overflow.maximumOutputBytes == 8)
        let failure = try #require(#expect(throws: NSError.self) { _ = try io.captureSize(-1) })
        #expect(failure.domain == NSCocoaErrorDomain)
        #expect((failure.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(EBADF))
    }

    @Test("aggregate capture overflow and growth retain configured limit and close all allocations",
          arguments: [false, true], [false, true])
    func outputLimitCaptureGrowth(growing: Bool, cleanupFails: Bool) throws {
        let io = RecordingProcessIO()
        io.capturePayloads = [Data("1234".utf8), growing ? Data() : Data("56789".utf8)]
        if growing { io.captureGrowthBeforeSnapshot = Data("56789".utf8) }
        let children = NoSpawnChildren()
        children.fakeReaper.reply = .exited
        if cleanupFails { children.signalError = EIO }
        let launcher = OsascriptLauncher(captureDirectory: try scratch.directory(), dependencies: .init(io: io, children: children))
        // An incidental deadline that nothing waits on (see lostChildRevokesAuthority).
        let overflow = try #require(#expect(throws: ScriptOutputLimitExceeded.self) {
            _ = try launcher.launch(ScriptInvocation(arguments: [], delivery: .timed(seconds: 30),
                                                     maximumOutputBytes: 8))
        })
        #expect(overflow.maximumOutputBytes == 8)
        #expect(io.sizeObservations == 2)
        #expect(io.snapshotAllowances == (growing ? [8, 4] : []))
        #expect(children.signals == [SIGTERM, SIGKILL])
        #expect(children.fakeReaper.calls == 1)
        #expect(io.outstanding.isEmpty && io.allocationCount == 3)
    }

    @Test("pipe read requests stay within remaining allowance plus one without Int.max overflow",
          arguments: [8, Int.max])
    func outputLimitReadRequestBound(limit: Int) throws {
        let io = RecordingProcessIO()
        let launcher = OsascriptLauncher(dependencies: .init(io: io))
        let invocation = ScriptInvocation(executablePath: "/bin/echo", arguments: ["123456789"],
                                          maximumOutputBytes: limit)
        if limit == 8 {
            #expect(throws: ScriptOutputLimitExceeded.self) { _ = try launcher.launch(invocation) }
            #expect(io.readBufferSizes.allSatisfy { (1...9).contains($0) })
        } else {
            #expect(try launcher.launch(invocation).standardOutput == Data("123456789\n".utf8))
            #expect(io.readBufferSizes.allSatisfy { (1...65_536).contains($0) })
        }
        #expect(!io.readBufferSizes.isEmpty)
        #expect(io.outstanding.isEmpty)
    }

    @Test("limited size observations preserve the original read error and unlimited avoids them",
          arguments: [false, true])
    func outputLimitCaptureErrorCompatibility(limited: Bool) throws {
        let io = RecordingProcessIO()
        io.captureSizeFailure = Self.sentinel
        let children = NoSpawnChildren()
        children.fakeReaper.reply = .exited
        let launcher = OsascriptLauncher(captureDirectory: try scratch.directory(), dependencies: .init(io: io, children: children))
        // An incidental deadline that nothing waits on (see lostChildRevokesAuthority).
        let invocation = ScriptInvocation(arguments: [], delivery: .timed(seconds: 30),
                                          maximumOutputBytes: limited ? 8 : nil)
        if limited {
            do { _ = try launcher.launch(invocation); Issue.record("expected original capture error") }
            catch { #expect((error as NSError) === Self.sentinel) }
            #expect(io.sizeObservations == 1 && io.snapshotAllowances.isEmpty)
            #expect(children.signals == [SIGTERM, SIGKILL])
        } else {
            #expect(try launcher.launch(invocation).standardOutput.isEmpty)
            #expect(io.sizeObservations == 0 && io.snapshotAllowances == [nil, nil])
            #expect(children.signals.isEmpty)
        }
        #expect(io.outstanding.isEmpty)
    }

    @Test("overflow during the final capture snapshots signals the owned group before reap")
    func outputLimitCaptureSignalsBeforeReap() throws {
        // The overflow comes from the final snapshot after the root's exit: the root writes "ready"
        // to both captures and exits, and the second snapshot first grows them by nine bytes, past
        // the 16-byte limit. A root that died before writing would leave only the nine injected
        // bytes, inside the limit. The descendant independently expires six seconds after its fork,
        // which precedes the root's exit; the teardown waits through that bound even on RED, where
        // an incorrectly successful capture leaves it live.
        //
        // The deadline is not the subject and is handled as in captureFailureBeforeReap: the root
        // publishes `ready` just before it forks, and the RecordedChildren gate holds the
        // launcher's deadline until then, for up to sixty seconds, so Python start-up falls outside
        // it. The deadline is 120 seconds, and a launcher that never acts on the exit still fails,
        // with a timeout, after 120. A timed-out attempt in the shape `startupRanIntoDeadline`
        // describes prints why and is re-run, at most twice; the last attempt and every other
        // outcome run every check, and a root that exits before it publishes fails the attempt on
        // any attempt, unless its own alarm killed it on time on an attempt that is not the last
        // (`earlyExit`). The root must not die of its own alarm before it writes, so its expiry is
        // 240 seconds, past the gate, the deadline and the cleanup together: a starved root then
        // times out and the group cleanup stops it. That adds no survivor: the root exits by itself
        // once it has written, and the group cleanup stops it otherwise, so the six-second wait
        // still covers the only process that can outlive a launch.
        defer { usleep(6_200_000) }
        for attempt in 1...3 {
            let ready = try scratch.directory().appendingPathComponent("ready").path
            let io = RecordingProcessIO()
            io.captureGrowthBeforeSnapshot = Data("123456789".utf8)
            let children = RecordedChildren(io.trace, readyFile: ready)
            let launcher = OsascriptLauncher(captureDirectory: try scratch.directory(),
                                             dependencies: .init(io: io, children: children))
            let base = invocation("capture", delivery: .timed(seconds: 120),
                                  options: ["expiry=240", "descendant-expiry=6", "ready=\(ready)"])
            let result = Result<ScriptOutcome, any Error> {
                try launcher.launch(ScriptInvocation(executablePath: base.executablePath,
                    arguments: base.arguments, delivery: base.delivery, maximumOutputBytes: 16))
            }
            if case .missed(let why) = Self.earlyExit(children, "the output-limit scenario",
                                                      expiry: 240, lastAttempt: attempt == 3) {
                print("output-limit scenario missed on attempt \(attempt) of 3: \(why)")
                continue
            }
            if attempt < 3, Self.startupRanIntoDeadline(result, children, deadline: 120) {
                print("output-limit scenario missed on attempt \(attempt) of 3: the readiness gate "
                      + "expired after 60 s and the 120 s deadline ran out before the root exited")
                continue
            }
            let failure = try #require(#expect(throws: ScriptOutputLimitExceeded.self) {
                _ = try result.get()
            })
            #expect(failure.maximumOutputBytes == 16)
            let events = io.trace.events
            let observed = try #require(events.firstIndex(of: "observed"))
            let snapshot = try #require(events.firstIndex(of: "capture2"))
            let term = try #require(events.firstIndex(of: "signal\(SIGTERM)"))
            let kill = try #require(events.firstIndex(of: "signal\(SIGKILL)"))
            let reap = try #require(events.firstIndex(of: "reaped"))
            #expect(observed < snapshot && snapshot < term && term < kill && kill < reap)
            #expect(io.outstanding.isEmpty)
            return
        }
        // The last attempt never misses or sets aside, so reaching here is a defect in the
        // attempt, never a pass.
        Issue.record("the last attempt returned without a verdict")
    }

    @Test("spawn and partial capture setup failures close every returned allocation")
    func setupRollback() throws {
        for partial in [false, true] {
            let io = RecordingProcessIO()
            io.failSecondCaptureAllocation = partial
            let children = RecordedChildren(io.trace)
            let dir = try scratch.directory()
            let launcher = OsascriptLauncher(captureDirectory: dir, dependencies: .init(io: io, children: children))
            #expect(throws: AppleScriptRunner.RunError.self) {
                try launcher.launch(ScriptInvocation(executablePath: "/does-not-exist/synthetic", arguments: [], delivery: .timed(seconds: 1)))
            }
            #expect(io.outstanding.isEmpty)
            #expect(io.allocationCount == (partial ? 2 : 3))
            #expect(io.trace.events.contains("spawn") == !partial)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        }
    }

    @Test("EPIPE keeps delivery classification and releases descriptors while descendants hold output",
          arguments: [false, true])
    func deliveryFailureClosesResources(timed: Bool) throws {
        // The elapsed bound proves the launcher returns on EPIPE instead of waiting for the
        // descendant that still holds stdout and stderr. The root publishes `ready` just before it
        // forks, the RecordedChildren gate holds the launcher until then, for up to sixty seconds,
        // and the bound is thirty seconds from the spawn stamp, so Python start-up falls outside
        // it. Both fixture processes expire sixty seconds after they start, so a launcher that
        // keeps polling output after EPIPE returns only then and fails the bound with 2x headroom.
        // The timed variant's deadline is ninety seconds, thirty past that expiry, since EPIPE
        // comes at the latest when both holders of the stdin read end have expired. It is not the
        // subject; the launcher checks it before acting on a ready descriptor, so a short one would
        // turn an EPIPE that has already happened into a timeout whenever the test process stalls
        // past it. The bound is checked even when the classification fails, so a stall long enough
        // to reach the deadline is reported with its elapsed time.
        //
        // Hosted runners can withhold the test process after the spawn stamp for tens of seconds
        // (see docs/learnings/hot/hosted-ci.md), and a wall-clock bound charges that to the
        // launcher. A `DeschedulingProbe`, started before the launch, records a lower bound on the
        // time withheld from the spawn stamp to the return, the bound's own span. On attempts 1
        // and 2 a crossed bound is set aside, printed and re-run when the probe recorded a stall
        // in that span and the time it did not see withheld stays under thirty seconds, granted
        // one probe tick (`crossedOnlyByStall`). A launcher that keeps polling output after EPIPE
        // spends the thirty seconds on its own thread, which leaves the probe on time, so it still
        // fails at once. The last attempt sets nothing aside.
        //
        // An attempt whose gate hold ran out, with the root still running and the ready file not in
        // place, is a miss: its deadline and its stamp may include start-up. That is decided from
        // what the gate saw alone, while the launcher was still inside `spawn`, before it started
        // its deadline, delivered any stdin, observed or signalled, so it cannot hide a fault in
        // those steps. Such an attempt prints why and is re-run, at most twice, with a fresh ready
        // file. A root that exits before it publishes ends the hold at once and fails the attempt,
        // on any attempt, unless its own alarm killed it on time on an attempt that is not the last
        // (`earlyExit`). The last attempt runs every check and also requires the gate to have seen
        // `ready`, so that it exercised the scenario: after a hold that ran out the root may still
        // die before it forks (of its own expiry, or of a launcher fault in its descriptors or
        // arguments), and the EPIPE of a dead root passes the classification, the bound and the
        // descriptor checks with no descendant holding output. Any failed check on any attempt
        // fails the test.
        for attempt in 1...3 {
            if try deliveryFailureAttempt(timed: timed, attempt: attempt,
                                          lastAttempt: attempt == 3) {
                return
            }
        }
        // The last attempt never misses or sets aside, so reaching here is a defect in the
        // attempt, never a pass.
        Issue.record("the last attempt returned without a verdict")
    }

    /// One attempt of the scenario above. Returns true once its checks have run (a failed check
    /// records its issue and fails the test); returns false only when another attempt remains and
    /// either the readiness gate ran out before the root published, with the root still running,
    /// or the thirty-second bound was crossed only by time the probe saw withheld.
    private func deliveryFailureAttempt(timed: Bool, attempt: Int,
                                        lastAttempt: Bool) throws -> Bool {
        func seconds(_ from: UInt64, _ to: UInt64) -> String {
            let nanoseconds = to >= from ? Double(to - from) : -Double(from - to)
            return String(format: "%.2f s", nanoseconds / 1_000_000_000)
        }
        // A fresh directory per attempt, so a root that published after an earlier attempt's gate
        // released cannot release this attempt's gate early.
        let ready = try scratch.directory().appendingPathComponent("ready").path
        let io = RecordingProcessIO()
        let children = RecordedChildren(io.trace, readyFile: ready)
        let launcher = OsascriptLauncher(dependencies: .init(io: io, children: children))
        let script = String(repeating: "x", count: 262_144)
        let delivery: ScriptDelivery = timed ? .timedStdin(script: script, seconds: 90)
            : .stdin(script: script)
        // Started before the launch so it is ticking at the spawn stamp; only lapses inside the
        // bound's span count. Stopped on every path, including a failed `#require`.
        let runner = DeschedulingProbe()
        defer { runner.stop() }
        let launchedAt = RecordedChildren.now()
        let result = Result<ScriptOutcome, any Error> {
            try launcher.launch(invocation("delivery", delivery: delivery,
                                           options: ["expiry=60", "ready=\(ready)"]))
        }
        let returnedAt = RecordedChildren.now()
        let early = Self.earlyExit(children, "the EPIPE scenario (timed \(timed))", expiry: 60,
                                   lastAttempt: lastAttempt)
        if case .missed(let why) = early {
            print("EPIPE scenario missed on attempt \(attempt) of 3 (timed \(timed)): \(why)")
            return false
        }
        let earlyExit: Bool
        if case .failed = early { earlyExit = true } else { earlyExit = false }
        // Decided before any check, from what the gate saw while the launcher was inside `spawn`:
        // only a hold that ran out with the root still running is a miss.
        if children.sawReady == false && children.exitedBeforeReady == false && !lastAttempt {
            let released = children.spawnedAt.map { seconds(launchedAt, $0) } ?? "?"
            print("EPIPE scenario missed on attempt \(attempt) of 3 (timed \(timed)): the "
                  + "readiness gate released \(released) after the launch began, before the root "
                  + "published")
            return false
        }
        let error = #expect(throws: AppleScriptRunner.RunError.self) { _ = try result.get() }
        if !earlyExit {
            #expect(children.sawReady == true,
                    "the readiness gate ran out before the root published, on the last attempt")
        }
        let spawnedAt = try #require(children.spawnedAt,
                                     "the recording backend must have spawned the root")
        let gate = children.sawReady == true ? "held until the root published"
            : "released before the root published"
        let bound: UInt64 = 30_000_000_000
        let ordered = spawnedAt <= returnedAt
        let elapsed = ordered ? returnedAt - spawnedAt : 0
        let bounded = ordered && elapsed < bound
        let withheld = runner.lapsed(from: spawnedAt, to: returnedAt)
        let stalled = ordered && !bounded && !lastAttempt && !earlyExit
            && Self.crossedOnlyByStall(elapsed: elapsed, withheld: withheld, bound: bound)
        let timing = "returned \(seconds(spawnedAt, returnedAt)) after the spawn stamp, "
            + "\(DeschedulingProbe.seconds(withheld)) s of it withheld by the runner"
        if !stalled {
            #expect(bounded, """
                the launcher must return on EPIPE well before the processes holding its output \
                expire (\(timing); the readiness gate \(gate))
                """)
        }
        guard case .launchFailed(let diagnosis) = try #require(error) else {
            Issue.record("wrong error")
            return true
        }
        #expect(diagnosis.hasPrefix("could not deliver script on stdin:"))
        #expect(io.outstanding.isEmpty)
        #expect(io.allocationCount == 6)
        if stalled {
            print("EPIPE scenario missed on attempt \(attempt) of 3 (timed \(timed)): the 30 s "
                  + "bound was crossed by no more than the time the runner withheld (\(timing))")
            return false
        }
        return true
    }

    @Test("parent descriptors close while a detached descendant still holds the opposite ends")
    func detachedSurvivorDoesNotRetainParentDescriptors() throws {
        // The deadline, the heartbeat checks and the teardown are timed for a starved runner; none
        // of them is the subject, which is the classification and descriptor checks (see
        // docs/learnings/hot/hosted-ci.md). The RecordedChildren gate holds the launcher, for up to
        // sixty seconds, until the descendant has published its first heartbeat, which it does
        // after it has detached and closed its stdin. So Python start-up, the fork and the detach
        // fall outside the deadline, what is left inside it is one write, one read and one close,
        // and once the gate has passed the timeout cleanup cannot reach the descendant. The
        // deadline is sixty seconds because the launcher checks it before acting on a ready
        // descriptor, so a stall of the test process past a short one turns an EPIPE that has
        // already happened into a timeout, as in deliveryFailureClosesResources. A launcher that
        // keeps waiting on the output the descendant holds still times out, at sixty seconds, with
        // the heartbeat in place, and fails. The heartbeat's first value precedes readiness, which
        // the root awaits before it closes stdin, so it exists before the launcher can return. Its
        // advance must appear within thirty seconds on a monotonic clock; the poll stops at the
        // first advance, and a descendant that never runs again still fails it, only later.
        //
        // Both fixture processes expire after 180 seconds, past the gate (sixty), the deadline
        // (sixty), the cleanup's two seconds and the poll (thirty) together. No test-side signal is
        // sent: the teardown asks every attempt's descendant to stop and waits for its
        // acknowledgement until 185 seconds after that attempt's launch returned, by which time the
        // descendant's own expiry, armed as its first act after the fork, has stopped it even if
        // the request never worked, so nothing outlives the scratch directories. A missing
        // acknowledgement fails the test only after the launch reported the delivery failure, the
        // one outcome that proves the descendant reached the loop that answers; after any other
        // outcome it may never have been forked, or the group cleanup stopped it before it
        // detached, and the test fails on that outcome instead.
        //
        // If the gate's sixty seconds run out first, the deadline starts with start-up still
        // running and an attempt can time out with no heartbeat at all. That is a miss, not a
        // launcher fault: the root closes stdin only after the descendant's readiness, which
        // follows its first heartbeat, so with no heartbeat EPIPE could not occur and the timeout
        // was the right outcome. Both halves are read when the timeout's cleanup first signals the
        // group: whether the heartbeat existed then, so a heartbeat that appears during cleanup
        // cannot turn a right timeout into a failure, and whether the full deadline had passed by
        // then, so cleanup time cannot make an early timeout look full. Such an attempt prints why
        // and is re-run in a fresh directory, at most twice, and the last attempt requires the
        // heartbeat. Every other outcome runs every check and is never re-run, so a timeout with
        // the heartbeat in place at the first signal, or one reported before the sixty seconds were
        // up, fails the test. The miss also needs the root to have been running when the gate's
        // hold ran out: the root cannot exit before the heartbeat appears, so one that does ends
        // the hold and fails the attempt, on any attempt, unless its own alarm killed it on time on
        // an attempt that is not the last (`earlyExit`). Residual: the root closes stdin a moment
        // after the heartbeat appears, so a gate that ran out and a deadline that expires in that
        // moment still fail a correct launcher.
        var teardowns: [(heartbeat: String, reached: Bool, settledBy: DispatchTime)] = []
        defer {
            for teardown in teardowns {
                _ = FileManager.default.createFile(atPath: teardown.heartbeat + ".stop",
                                                   contents: nil)
            }
            for teardown in teardowns {
                let stopped = teardown.heartbeat + ".stopped"
                while !FileManager.default.fileExists(atPath: stopped),
                      DispatchTime.now() < teardown.settledBy {
                    usleep(20_000)
                }
                if teardown.reached && !FileManager.default.fileExists(atPath: stopped) {
                    Issue.record("the detached descendant never acknowledged the stop request")
                }
            }
        }
        for attempt in 1...3 {
            let heartbeat = try scratch.directory().appendingPathComponent("heartbeat")
            let io = RecordingProcessIO()
            let children = RecordedChildren(io.trace, readyFile: heartbeat.path)
            let launcher = OsascriptLauncher(dependencies: .init(io: io, children: children))
            let request = invocation("detached",
                delivery: .timedStdin(script: String(repeating: "x", count: 262_144), seconds: 60),
                options: ["expiry=180", "heartbeat=\(heartbeat.path)"])
            let result = Result<ScriptOutcome, any Error> { try launcher.launch(request) }
            var reached = false
            if case .failure(let failure) = result,
               let run = failure as? AppleScriptRunner.RunError,
               case .launchFailed(let diagnosis) = run {
                reached = diagnosis.hasPrefix("could not deliver script on stdin:")
            }
            teardowns.append((heartbeat: heartbeat.path, reached: reached,
                              settledBy: DispatchTime.now() + 185))
            if case .missed(let why) = Self.earlyExit(children, "the detached-survivor scenario",
                                                      expiry: 180, lastAttempt: attempt == 3) {
                print("detached-survivor scenario missed on attempt \(attempt) of 3: \(why)")
                continue
            }
            // The miss is decided before any product check, from the gate and from what was in
            // place at the first group signal. The spawn stamp precedes the launcher's deadline and
            // that signal follows its expiry, so a full deadline puts at least sixty seconds
            // between them (a millisecond is allowed for clock rounding).
            var missed = false
            if case .failure(let failure) = result, failure is AppleScriptRunner.TimeoutError,
               children.sawReady == false, children.exitedBeforeReady == false,
               let spawnedAt = children.spawnedAt,
               let signalledAt = children.firstSignalAt, signalledAt >= spawnedAt + 59_999_000_000 {
                missed = children.readyAtFirstSignal == false
            }
            if missed && attempt < 3 {
                print("detached-survivor scenario missed on attempt \(attempt) of 3: the readiness "
                      + "gate expired after 60 s and the 60 s deadline ran out before the "
                      + "descendant's first heartbeat, so the root still held stdin")
                continue
            }
            try #require(!missed, """
                the detached descendant never published its first heartbeat before the deadline \
                in three attempts
                """)
            let error = #expect(throws: AppleScriptRunner.RunError.self) { _ = try result.get() }
            guard case .launchFailed(let diagnosis) = try #require(error) else {
                Issue.record("wrong error")
                return
            }
            #expect(diagnosis.hasPrefix("could not deliver script on stdin:"))
            #expect(io.outstanding.isEmpty)
            let returnedAt = DispatchTime.now().uptimeNanoseconds
            // Python and Dispatch uptime epochs need not be equal: compare two values emitted by
            // the child, with the second read separated from return by an actual elapsed interval.
            let first = try #require(UInt64(String(contentsOf: heartbeat, encoding: .utf8)))
            var advanced = false
            let deadline = DispatchTime.now() + 30
            repeat {
                usleep(20_000)
                let next = try #require(UInt64(String(contentsOf: heartbeat, encoding: .utf8)))
                if next > first { advanced = true; break }
            } while DispatchTime.now() < deadline
            #expect(advanced,
                    "the detached descendant must execute after the parent descriptors closed")
            #expect(DispatchTime.now().uptimeNanoseconds > returnedAt)
            #expect(io.outstanding.isEmpty)
            return
        }
        // The last attempt never misses or sets aside, so reaching here is a defect in the
        // attempt, never a pass.
        Issue.record("the last attempt returned without a verdict")
    }

    @Test("a read failure closes all parent resources and leaves subsequent launches usable", arguments: [1, 2], [false, true])
    func readFailureClosesResources(stream: Int, limited: Bool) throws {
        // The deadline only keeps a regression from hanging. The injected EIO needs a readiness
        // event on the failing pipe, which comes once the root has started, forked and written
        // "ready", or at the latest when the fixture's own six-second expiry, armed once Python has
        // started, hangs the pipe up. The launcher starts its deadline when `spawn` returns, so
        // Python start-up runs inside it, and it checks the deadline before every read, so a pipe
        // event it reaches late because the test process was not scheduled still reports a timeout.
        // The deadline is not the subject, so it is widened rather than gated: the RecordedChildren
        // gate would take start-up out of it but none of the scheduling delay (see
        // docs/learnings/hot/hosted-ci.md). At 120 seconds a correct run never comes near it, and a
        // launcher that swallows the read failure still fails, with a timeout in place of the
        // RunError. The fixture's six-second expiry stays, since it is the earliest fallback event.
        let io = RecordingProcessIO()
        io.readFailure = EIO
        io.failedReadPipe = stream
        let launcher = OsascriptLauncher(dependencies: .init(io: io))
        let error = #expect(throws: AppleScriptRunner.RunError.self) {
            try launcher.launch(invocation("read", delivery: .timedStdin(script: "x", seconds: 120),
                                           maximumOutputBytes: limited ? 64 : nil))
        }
        guard case .launchFailed(let diagnosis) = try #require(error) else { Issue.record("wrong error"); return }
        #expect(diagnosis.hasPrefix("could not read osascript stdin-form-"))
        #expect(io.outstanding.isEmpty)
        io.readFailure = nil
        let next = try launcher.launch(invocation("exit", delivery: .inline))
        #expect(next == ScriptOutcome(terminationStatus: 7, standardOutput: Data("output".utf8), standardError: Data("error".utf8)))
        #expect(io.outstanding.isEmpty)
        #expect(io.allocationCount == 11)
    }

    @Test("both completed capture reads retain signal authority and propagate the original error",
          arguments: [1, 2], [false, true])
    func captureFailureBeforeReap(read: Int, limited: Bool) throws {
        // The child is real: RecordedChildren forwards to the Darwin backend, and only the snapshot
        // read fails synthetically. The launcher starts its deadline when `spawn` returns and
        // checks it before acting on an observed exit, so a root whose Python start-up outlasts the
        // deadline ends in a timeout with no capture read for the sentinel to come from, and on a
        // starved runner widening the deadline alone does not prevent that. Nothing here is about
        // the deadline. The root publishes `ready` just before it forks, and the RecordedChildren
        // gate holds the launcher's deadline until then, for up to sixty seconds; what is left
        // inside the deadline is a fork, a one-byte handshake, two writes and an exit, and the
        // root's own six-second alarm ends it even if those stall. The 120-second deadline only
        // keeps a launcher that never acts on the exit from hanging, and such a launcher still
        // fails, with a timeout.
        //
        // A timed-out attempt is a missed scenario only in the shape `startupRanIntoDeadline`
        // describes: the gate's hold ran out without `ready` with the root still running, the first
        // signal came a full deadline after the spawn stamp, and the trace shows no exit the
        // launcher sat on. Such an attempt prints why and is re-run, at most twice; the last
        // attempt runs every check, and every other outcome runs them at once. A root that exits
        // before it publishes fails the attempt on any attempt, unless its own alarm killed it on
        // time on an attempt that is not the last (`earlyExit`).
        for attempt in 1...3 {
            let ready = try scratch.directory().appendingPathComponent("ready").path
            let io = RecordingProcessIO()
            io.captureFailure = Self.sentinel
            io.failCaptureRead = read
            let children = RecordedChildren(io.trace, readyFile: ready)
            let launcher = OsascriptLauncher(captureDirectory: try scratch.directory(),
                                             dependencies: .init(io: io, children: children))
            let result = Result<ScriptOutcome, any Error> {
                try launcher.launch(invocation("capture", delivery: .timed(seconds: 120),
                                               maximumOutputBytes: limited ? 64 : nil,
                                               options: ["ready=\(ready)"]))
            }
            if case .missed(let why) = Self.earlyExit(children, "the capture-failure scenario "
                                                      + "(read \(read), limited \(limited))",
                                                      expiry: 6, lastAttempt: attempt == 3) {
                print("capture-failure scenario missed on attempt \(attempt) of 3 (read \(read), "
                      + "limited \(limited)): \(why)")
                continue
            }
            if attempt < 3, Self.startupRanIntoDeadline(result, children, deadline: 120) {
                print("capture-failure scenario missed on attempt \(attempt) of 3 (read \(read), "
                      + "limited \(limited)): the readiness gate expired after 60 s and the 120 s "
                      + "deadline ran out before the root exited")
                continue
            }
            switch result {
            case .success: Issue.record("expected capture failure")
            case .failure(let error):
                let failure = error as NSError
                #expect(failure === Self.sentinel)
                #expect(failure.domain == Self.sentinel.domain)
                #expect(failure.code == Self.sentinel.code)
                #expect(failure.userInfo["synthetic"] as? String == "preserve this error")
            }
            let events = io.trace.events
            let observed = try #require(events.firstIndex(of: "observed"))
            let failed = try #require(events.firstIndex(of: "capture\(read)"))
            let term = try #require(events.firstIndex(of: "signal\(SIGTERM)"))
            let kill = try #require(events.firstIndex(of: "signal\(SIGKILL)"))
            let reaped = try #require(events.firstIndex(of: "reaped"))
            #expect(observed < failed && failed < term && term < kill && kill < reaped)
            #expect(io.outstanding.isEmpty)
            return
        }
        // The last attempt never misses or sets aside, so reaching here is a defect in the
        // attempt, never a pass.
        Issue.record("the last attempt returned without a verdict")
    }

    @Test("ECHILD revokes signals and does not transfer a child that has already been lost",
          arguments: [false, true])
    func lostChildRevokesAuthority(afterTerm: Bool) throws {
        // The synthetic child is observed on the launcher's first turn, but the launcher checks its
        // deadline right after that observation, so a stall of a starved test thread past a short
        // deadline would replace the sentinel with a timeout. Nothing here is about the deadline
        // and nothing waits on it, so it is thirty seconds; the same holds for the other tests that
        // refer here.
        let io = RecordingProcessIO()
        io.captureFailure = Self.sentinel
        let children = NoSpawnChildren()
        children.observation = afterTerm ? .lostAfterTerm : .lost
        let sink = HeldReaps()
        let launcher = OsascriptLauncher(captureDirectory: try scratch.directory(), dependencies: .init(io: io, children: children, deferred: sink))
        do {
            _ = try launcher.launch(ScriptInvocation(arguments: [], delivery: .timed(seconds: 30)))
            Issue.record("expected failure")
        } catch {
            if afterTerm { #expect((error as NSError) === Self.sentinel) }
            else { #expect(error is AppleScriptRunner.RunError) }
        }
        #expect(children.starts == 1) // Pure fake entry; NoSpawnChildren cannot spawn any OS child.
        #expect(children.signals == (afterTerm ? [SIGTERM] : []))
        #expect(children.fakeReaper.calls == 0)
        #expect(sink.obligations.isEmpty)
        #expect(io.outstanding.isEmpty)
    }

    @Test("bounded cleanup transfers only a reap obligation and retains the initiating error",
          arguments: [false, true])
    func eventualReapTransfer(lost: Bool) throws {
        // The deadline is incidental (see lostChildRevokesAuthority). The subject is the
        // capture-failure cleanup's 0.5 s pause after SIGTERM and its 1.0 s reap window. Both are
        // timed from when the launcher reaches them, so a stopwatch from the launch would count
        // every stall of the test thread; instead they are checked from the launcher's own turns
        // (`checkWindow`): the pause's observations, which follow its deadline check, and the reap
        // window's reaps, which precede its check, stamped on the clock it reads. Unloaded, a
        // window longer by more than a turn or two (ten milliseconds each) fails; a starved run may
        // miss a lengthened window but cannot fail a correct one. Both checks rest on one
        // observation per pause turn and one reap per window turn, as the launcher makes; a
        // launcher restructured otherwise needs them revisited.
        //
        // A window with fewer than three turns is unmeasured. A launcher that waits blindly in
        // place of a window always leaves that, a correct one only when the runner withheld it for
        // most of the window. The miss is decided from the turn counts before any check; the
        // attempt still runs every check a stall cannot fail, prints why and is re-run, at most
        // twice. The last attempt fails on a window it could not measure, so a blind wait always
        // fails, as does a correct launcher withheld that long three times running.
        //
        // A stall that pushes a reap to sixty seconds or more after the launch (`reapableAt`,
        // below) changes what a correct launcher leaves: the fake child is then reapable by
        // itself, so that reap succeeds and nothing is transferred. A `DeschedulingProbe`, started
        // before the launch, records a lower bound on the time withheld from the launch to the
        // return. On attempts 1 and 2, an attempt that transferred nothing and returned at or
        // after `reapableAt` is a miss when the probe saw all but two seconds of that span withheld
        // (`cleanupOwnTimeNanoseconds`). That is decided before the obligation checks, and such an
        // attempt skips only them, since a natural reap leaves no obligation to count or poll;
        // every other check runs, it prints why and it is re-run. Without that evidence, or on
        // the last attempt, the obligation checks run and fail, so a launcher that waits until
        // the child is reapable by itself, on a runner that is running the test, still fails at
        // once.
        //
        // The elapsed time from the launch is the "never returns" bound, thirty seconds on a
        // monotonic clock. A stall can fail it, so it is not checked on an attempt re-run for an
        // unmeasured window, and on attempts 1 and 2 a crossed bound is set aside, printed and
        // re-run when the probe recorded a stall in the launch and the time it did not see
        // withheld stays under thirty seconds, granted one probe tick (`crossedOnlyByStall`); the
        // span is the launch, on the probe's clock, while the bound reads `DispatchTime`. The fake
        // child becomes reapable by itself sixty seconds after the launch begins (`reapableAt`;
        // cleared before the polls below, and nothing else reaps in between) and the delivery
        // deadline is 120 seconds, so a cleanup that waits for the child returns at about sixty
        // and one that waits for the deadline at about 120, each at least twice the bound and
        // spent on the launcher's own thread; the first also fails the reap window and the
        // transfer check. Residual: a wait outside both windows (before the pause, between them,
        // or after the reap loop) leaves the turns unchanged and is caught only by that bound, as
        // is a window lengthened by less than one of its own turns.
        for attempt in 1...3 {
            if try eventualReapAttempt(lost: lost, attempt: attempt, lastAttempt: attempt == 3) {
                return
            }
        }
        // The last attempt never misses or sets aside, so reaching here is a defect in the
        // attempt, never a pass.
        Issue.record("the last attempt returned without a verdict")
    }

    /// The most of its own time a correct launcher spends in the capture-failure cleanup, rounded
    /// up: the 0.5 s pause after SIGTERM and the 1.0 s reap window, plus half a second for its
    /// turns and the probe's undercount. An attempt whose child became reapable by itself is a miss
    /// only when the probe saw all but this much of the launch withheld.
    private static let cleanupOwnTimeNanoseconds: UInt64 = 2_000_000_000

    /// One attempt of the scenario above. Returns true once its checks have run (a failed check
    /// records its issue and fails the test); returns false only when another attempt remains and
    /// a window went unmeasured, the fake child became reapable by itself while the probe saw all
    /// but `cleanupOwnTimeNanoseconds` of the launch withheld, or the thirty-second bound was
    /// crossed only by time the probe saw withheld.
    private func eventualReapAttempt(lost: Bool, attempt: Int, lastAttempt: Bool) throws -> Bool {
        let io = RecordingProcessIO()
        io.captureFailure = Self.sentinel
        let children = NoSpawnChildren()
        let sink = HeldReaps()
        let launcher = OsascriptLauncher(captureDirectory: try scratch.directory(),
                                         dependencies: .init(io: io, children: children,
                                                             deferred: sink))
        // Started before the launch so it is ticking when the launch begins; only lapses between
        // the launch and its return count. Stopped on every path, including a failed `#require`.
        let runner = DeschedulingProbe()
        defer { runner.stop() }
        let start = DispatchTime.now()
        // The probe's span, on its own clock (`CLOCK_MONOTONIC`), which `DispatchTime` is not.
        let launchedAt = RecordedChildren.now()
        let reapableAt = start + 60
        children.fakeReaper.reapableAt = reapableAt
        let result = Result<ScriptOutcome, any Error> {
            try launcher.launch(ScriptInvocation(arguments: [], delivery: .timed(seconds: 120)))
        }
        let returnedAt = RecordedChildren.now()
        let returned = DispatchTime.now()
        let elapsed = Double(returned.uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        children.fakeReaper.reapableAt = nil
        let reaps = children.fakeReaper.reapTimes
        let pause = Self.pauseTurns(children.timeline)
        // Decided before any check, from the turn counts alone. Missing or misordered signals are
        // never a miss: the checks below fail them.
        let missed = pause.map { $0.count < 3 || reaps.count < 3 } ?? false
        let span = launchedAt <= returnedAt ? returnedAt - launchedAt : 0
        let withheld = runner.lapsed(from: launchedAt, to: returnedAt)
        let timing = "\(DeschedulingProbe.seconds(span)) s from the launch to the return, "
            + "\(DeschedulingProbe.seconds(withheld)) s of it withheld by the runner"
        // Decided before the obligation checks: nothing transferred, a return at or after the time
        // the fake child became reapable by itself, and a recorded stall covering all but the
        // launcher's own cleanup time.
        let reapedNaturally = !lastAttempt && sink.obligations.isEmpty && returned >= reapableAt
            && withheld > 0 && withheld + Self.cleanupOwnTimeNanoseconds >= span
        let boundStalled = !lastAttempt && elapsed >= 30
            && Self.crossedOnlyByStall(elapsed: span, withheld: withheld,
                                       bound: 30_000_000_000)
        switch result {
        case .success: Issue.record("expected failure")
        case .failure(let error): #expect((error as NSError) === Self.sentinel)
        }
        if (!missed || lastAttempt) && !boundStalled && !reapedNaturally {
            #expect(elapsed < 30, """
                cleanup must give up on the reap (returned after \(elapsed) s; \(timing))
                """)
        }
        let turns = try #require(pause, "cleanup must send SIGTERM and then SIGKILL")
        Self.checkWindow(turns, within: 0.5, "the pause after SIGTERM", required: lastAttempt)
        Self.checkWindow(reaps, within: 1.0, "the reap window", required: lastAttempt)
        #expect(children.starts == 1)
        #expect(children.signals == [SIGTERM, SIGKILL])
        #expect(io.outstanding.isEmpty)
        if !reapedNaturally {
            #expect(sink.obligations.count == 1)
            let obligation = try #require(sink.obligations.first)
            #expect(!obligation.poll())
            children.fakeReaper.reply = lost ? .lost : .exited
            #expect(obligation.poll())
            let calls = children.fakeReaper.calls
            #expect(obligation.poll())
            #expect(children.fakeReaper.calls == calls)
        }
        #expect(children.signals == [SIGTERM, SIGKILL])
        var reasons: [String] = []
        if missed && !lastAttempt {
            reasons.append("\(turns.count) pause turns and \(reaps.count) reaps, too few to "
                           + "measure both windows")
        }
        if reapedNaturally {
            reasons.append("the fake child became reapable by itself after a stall, so nothing "
                           + "was transferred (\(timing))")
        } else if boundStalled {
            reasons.append("the 30 s bound was crossed by no more than the time the runner "
                           + "withheld (\(timing))")
        }
        if !reasons.isEmpty {
            print("reap-transfer scenario missed on attempt \(attempt) of 3 (lost \(lost)): "
                  + reasons.joined(separator: "; "))
            return false
        }
        return true
    }

    @Test("a transient interrupted reap preserves completed output without group cancellation")
    func interruptedSuccessfulReap() throws {
        let children = NoSpawnChildren()
        children.fakeReaper.reply = .exited
        children.fakeReaper.pendingReplies = 1 // Darwin reaper's EINTR result.
        let io = RecordingProcessIO()
        let sink = HeldReaps()
        let launcher = OsascriptLauncher(captureDirectory: try scratch.directory(), dependencies: .init(io: io, children: children, deferred: sink))
        // An incidental deadline that nothing waits on (see lostChildRevokesAuthority).
        let outcome = try launcher.launch(ScriptInvocation(arguments: [],
                                                           delivery: .timed(seconds: 30)))
        #expect(outcome == ScriptOutcome(terminationStatus: 0, standardOutput: Data(), standardError: Data()))
        #expect(children.fakeReaper.calls == 2)
        #expect(children.signals.isEmpty)
        #expect(sink.obligations.isEmpty)
        #expect(io.outstanding.isEmpty)
    }

    @Test("a successful outcome survives bounded transfer of an unresolved reap")
    func successfulPendingReapTransfer() throws {
        let children = NoSpawnChildren()
        let io = RecordingProcessIO()
        let sink = HeldReaps()
        let launcher = OsascriptLauncher(captureDirectory: try scratch.directory(), dependencies: .init(io: io, children: children, deferred: sink))
        // An incidental deadline that nothing waits on (see lostChildRevokesAuthority); the
        // product's own one-second reap window, which transfers the obligation, is separate from
        // it.
        let outcome = try launcher.launch(ScriptInvocation(arguments: [],
                                                           delivery: .timed(seconds: 30)))
        #expect(outcome.terminationStatus == 0)
        #expect(children.signals.isEmpty)
        #expect(io.outstanding.isEmpty)
        #expect(sink.obligations.count == 1)
        children.fakeReaper.reply = .exited
        #expect(try #require(sink.obligations.first).poll())
    }

    @Test("invalid and caller group identities can never reach a signal backend")
    func invalidGroupIdentities() throws {
        for identity in [pid_t(0), -1, 1, getpgrp()] {
            let children = NoSpawnChildren()
            children.returnedPID = identity
            children.fakeReaper.reply = .exited
            let io = RecordingProcessIO()
            io.captureFailure = Self.sentinel
            let sink = HeldReaps()
            let launcher = OsascriptLauncher(captureDirectory: try scratch.directory(), dependencies: .init(io: io, children: children, deferred: sink))
            do {
                // An incidental deadline that nothing waits on (see lostChildRevokesAuthority).
                _ = try launcher.launch(ScriptInvocation(arguments: [],
                                                         delivery: .timed(seconds: 30)))
                Issue.record("expected capture failure")
            } catch { #expect((error as NSError) === Self.sentinel) }
            #expect(children.signals.isEmpty)
            #expect(io.outstanding.isEmpty)
            #expect(sink.obligations.isEmpty)
        }
    }

    @Test("a close error remains a delivery failure and cleanup preserves the first diagnosis")
    func inputCloseFailure() throws {
        // An incidental deadline that nothing waits on (see lostChildRevokesAuthority). The
        // injected close failure comes on the launcher's second turn, without waiting for the
        // child, but the launcher checks the deadline on the first, so a stall of the test process
        // past a short deadline would report a timeout instead. A launcher that ignores the close
        // failure still fails the error check: both fixture processes end at their six-second
        // alarms and the launch returns a status-14 outcome with no error, well before the
        // thirty-second deadline.
        let io = RecordingProcessIO()
        io.failInputClose = true
        let error = #expect(throws: AppleScriptRunner.RunError.self) {
            try OsascriptLauncher(dependencies: .init(io: io))
                .launch(invocation("read", delivery: .timedStdin(script: "x", seconds: 30)))
        }
        guard case .launchFailed(let diagnosis) = try #require(error) else { Issue.record("wrong error"); return }
        #expect(diagnosis.hasPrefix("could not deliver script on stdin:"))
        #expect(io.outstanding.isEmpty)
    }

    @Test("signal and reap errors cannot replace an earlier capture failure")
    func cleanupErrorPrecedence() throws {
        let io = RecordingProcessIO()
        io.captureFailure = Self.sentinel
        let children = NoSpawnChildren()
        children.signalError = EPERM
        children.fakeReaper.reply = .lost
        let sink = HeldReaps()
        let launcher = OsascriptLauncher(captureDirectory: try scratch.directory(), dependencies: .init(io: io, children: children, deferred: sink))
        do {
            // An incidental deadline that nothing waits on (see lostChildRevokesAuthority); a
            // timeout would replace the sentinel whose precedence is the subject.
            _ = try launcher.launch(ScriptInvocation(arguments: [], delivery: .timed(seconds: 30)))
            Issue.record("expected capture failure")
        } catch { #expect((error as NSError) === Self.sentinel) }
        #expect(children.signals == [SIGTERM, SIGKILL])
        #expect(io.outstanding.isEmpty)
        #expect(sink.obligations.isEmpty)
    }

    @Test("the shared scheduler drains registrations and restarts after becoming idle")
    func eventualReaperScheduler() throws {
        let scheduler = ScriptEventualReaper()
        #expect(scheduler.isIdle)
        for lost in [false, true] {
            let reaper = FakeReaper()
            reaper.reply = lost ? .lost : .exited
            reaper.pendingReplies = 2
            scheduler.accept(ScriptPendingReap(pid: Int32.max - 1, reaper: reaper))
            // Three 100 ms timer turns on a Dispatch queue, which a starved host can delay by
            // seconds. The wait stops as soon as the scheduler is idle and the check below still
            // fails if it never drains, so it allows thirty seconds, on a monotonic clock.
            let deadline = DispatchTime.now() + 30
            while !scheduler.isIdle && DispatchTime.now() < deadline { usleep(10_000) }
            #expect(scheduler.isIdle)
            #expect(reaper.calls == 3)
            usleep(150_000)
            #expect(reaper.calls == 3)
        }
    }

    @Test("completion first observed after the deadline is a timeout", arguments: [false, true], [false, true])
    func lateObservationCannotSucceed(stdin: Bool, limited: Bool) throws {
        // The timeout's cleanup pauses a full second between SIGTERM and SIGKILL, and the fake root
        // keeps answering as exited without ending the pause, so the pause runs its whole second
        // here. That window is checked from the launcher's own observations, as in
        // eventualReapTransfer, because an elapsed "never returns" bound would let a pause several
        // seconds long pass. A pause with fewer than three observations is unmeasured: that attempt
        // still runs every other check (a stall can fail none of them), prints why and is re-run,
        // at most twice, and the last attempt fails on it. The reap loop is shared with the
        // capture-failure path and measured in eventualReapTransfer; here the first reap succeeds,
        // as this test's no-transfer check needs.
        for attempt in 1...3 {
            let lastAttempt = attempt == 3
            let children = NoSpawnChildren()
            children.fakeReaper.reply = .exited
            children.pendingObservations = stdin ? 1 : 0
            children.delayedObservationMicroseconds = 100_000
            let io = RecordingProcessIO()
            if limited { io.capturePayloads = [Data("123456789".utf8)] }
            let sink = HeldReaps()
            let launcher = OsascriptLauncher(captureDirectory: try scratch.directory(),
                                             dependencies: .init(io: io, children: children,
                                                                 deferred: sink))
            let delivery: ScriptDelivery = stdin ? .timedStdin(script: "", seconds: 0.02)
                : .timed(seconds: 0.02)
            let result = Result<ScriptOutcome, any Error> {
                try launcher.launch(ScriptInvocation(arguments: [], delivery: delivery,
                                                     maximumOutputBytes: limited ? 8 : nil))
            }
            let pause = Self.pauseTurns(children.timeline)
            // Decided before any check, from the observation count alone. Missing or misordered
            // signals are never a miss: the signal check below fails them.
            let missed = pause.map { $0.count < 3 } ?? false
            #expect(throws: AppleScriptRunner.TimeoutError.self) { _ = try result.get() }
            #expect(children.signals == [SIGTERM, SIGKILL])
            #expect(io.outstanding.isEmpty)
            #expect(sink.obligations.isEmpty)
            #expect(io.sizeObservations == 0,
                    "the elapsed deadline must win before a capture-size check")
            if let pause {
                Self.checkWindow(pause, within: 1.0, "the timeout's pause after SIGTERM",
                                 required: lastAttempt)
            }
            if missed && !lastAttempt {
                print("late-observation pause missed on attempt \(attempt) of 3 (stdin \(stdin), "
                      + "limited \(limited)): \(pause?.count ?? 0) observations, too few to "
                      + "measure the window")
                continue
            }
            return
        }
        // The last attempt never misses or sets aside, so reaching here is a defect in the
        // attempt, never a pass.
        Issue.record("the last attempt returned without a verdict")
    }

    @Test("the capture snapshot preserves the shared offset and reads the observed extent")
    func captureSnapshotPreservesOffset() throws {
        let io = DarwinScriptProcessIO()
        let fd = try io.capture(in: scratch.directory())
        defer { try? io.close(fd) }
        let bytes = Data("first".utf8)
        #expect(try bytes.withUnsafeBytes { try io.write(fd, from: $0) } == bytes.count)
        #expect(lseek(fd, 0, SEEK_CUR) == 5)
        #expect(try io.captureSnapshot(fd) == bytes)
        #expect(lseek(fd, 0, SEEK_CUR) == 5)
        let append = Data("second".utf8)
        #expect(try append.withUnsafeBytes { try io.write(fd, from: $0) } == append.count)
        #expect(try io.captureSnapshot(fd) == Data("firstsecond".utf8))
    }

    @Test("live capture pread failures preserve a Cocoa error with the actual POSIX cause")
    func captureErrorConversion() throws {
        let io = DarwinScriptProcessIO()
        let pair = try io.pipe()
        defer { try? io.close(pair.read); try? io.close(pair.write) }
        var buffer = [UInt8](repeating: 0, count: 1)
        var captureError: NSError?
        do {
            _ = try buffer.withUnsafeMutableBytes { try DarwinScriptProcessIO.captureRead(pair.read, into: $0, offset: 0) }
            Issue.record("pread on a pipe must fail")
        } catch { captureError = error as NSError }
        let actual = try #require(captureError)
        #expect(actual.domain == NSCocoaErrorDomain)
        #expect(actual.code == NSFileReadUnknownError)
        let underlying = try #require(actual.userInfo[NSUnderlyingErrorKey] as? NSError)
        #expect(underlying.domain == NSPOSIXErrorDomain)
        #expect(underlying.code == Int(ESPIPE))
        // This is the corresponding live seek failure, not FileHandle's logical closed-handle
        // error or its platform-specific handling of readToEnd on a write-only descriptor.
        let handle = FileHandle(fileDescriptor: pair.read, closeOnDealloc: false)
        do {
            try handle.seek(toOffset: 0)
            Issue.record("seek on a pipe must fail")
        } catch {
            let old = error as NSError
            #expect(old.domain == actual.domain && old.code == actual.code)
            let cause = try #require(old.userInfo[NSUnderlyingErrorKey] as? NSError)
            #expect(cause.domain == underlying.domain && cause.code == underlying.code)
        }
    }

    @Test("signal outcomes retain the signal number rather than shell encoding")
    func signalOutcome() throws {
        // The root kills itself only after Python start-up, which a deadline starting at `spawn`
        // must not race (see captureFailureBeforeReap); the deadline is not the subject. Under
        // heavy machine-wide load the root can take more than thirty seconds to reach its kill, so
        // the deadline is 120 seconds. It only bounds a regression: a shell-encoded status (128 +
        // 9) still fails the check below at once, and a launcher that never reports the exit still
        // fails, at the deadline. The root's own alarm is armed just before its kill, so a root
        // descheduled between the two for its whole expiry would die of SIGALRM and report 14;
        // `expiry=60` makes that race need a sixty-second stall and changes nothing else the root
        // does.
        let outcome = try OsascriptLauncher().launch(
            invocation("signal", delivery: .timed(seconds: 120), options: ["expiry=60"]))
        #expect(outcome.terminationStatus == SIGKILL)
    }

    @Test("sustained output cannot postpone the deadline or retain descriptors")
    func outputDeadlineFairness() throws {
        // The one-second timeout is the subject, so output must contest it. The root publishes
        // `ready` once its first output is pending, and the RecordedChildren gate holds the
        // launcher's deadline until then, so Python start-up neither counts against the bounds
        // below nor leaves the timeout uncontested. The first group signal, which the timeout
        // sends, must come within four seconds of the gated spawn stamp (the deadline plus three of
        // headroom; this is what output could postpone). Cleanup begins at that signal and must end
        // within twenty seconds of it: its own budget is the one-second TERM pause (the flood root
        // ignores SIGTERM) plus the one-second reap window, each timed from when the launcher
        // reaches it, so stalls add up there.
        //
        // The reads are also checked from the launcher's own turns (`checkWindow`). Every read
        // follows a deadline check and the deadline is set before the first read, so the
        // second-to-last read is less than a second after the first under any load, while a
        // launcher whose deadline output can postpone keeps reading. An attempt whose gate hold ran
        // out without `ready`, with the root still running, or that made fewer than three reads,
        // did not test fairness. That is decided before any check; the attempt still runs every
        // check a stall cannot fail, prints why and is re-run, at most twice, and the last attempt
        // runs every check and also requires the gate to have seen `ready` and the reads to be
        // measured. A root that exits before it publishes ends the hold at once and fails the
        // attempt, on any attempt, unless its own alarm killed it on time on an attempt that is not
        // the last (`earlyExit`).
        //
        // The synthetic output ends in EIO sixty seconds after the first read, so the gate's hold
        // cannot shorten it. A launcher whose deadline output can postpone reads until then and
        // fails the error type, the read window and the signal bound; one that keeps draining
        // output after it signals returns about fifty-nine seconds after the signal, more than
        // twice the twenty allowed.
        //
        // Hosted runners can withhold the test process after the spawn stamp for tens of seconds
        // (see docs/learnings/hot/hosted-ci.md), and the two elapsed bounds charge that to the
        // launcher. A `DeschedulingProbe`, started before the launch, records a lower bound on the
        // time withheld in each bound's own span: the spawn stamp to the first signal, and that
        // signal to the return. On attempts 1 and 2 a crossed bound is set aside, printed and
        // re-run when the probe recorded a stall in its span and the time it did not see withheld
        // stays under the bound, granted one probe tick (`crossedOnlyByStall`). Both regressions
        // above spend their time reading on the launcher's own thread, which leaves the probe on
        // time, so they still fail at once. The last attempt sets nothing aside.
        for attempt in 1...3 {
            if try fairnessAttempt(attempt: attempt, lastAttempt: attempt == 3) { return }
        }
        // The last attempt never misses or sets aside, so reaching here is a defect in the
        // attempt, never a pass.
        Issue.record("the last attempt returned without a verdict")
    }

    /// One attempt of the scenario above. Returns true once its checks have run (a failed check
    /// records its issue and fails the test); returns false only when another attempt remains and
    /// either the attempt did not test fairness or an elapsed bound was crossed only by time the
    /// probe saw withheld.
    private func fairnessAttempt(attempt: Int, lastAttempt: Bool) throws -> Bool {
        let ready = try scratch.directory().appendingPathComponent("ready").path
        let io = RecordingProcessIO()
        io.syntheticReadSeconds = 60
        let children = RecordedChildren(io.trace, readyFile: ready)
        let launcher = OsascriptLauncher(dependencies: .init(io: io, children: children))
        // Started before the launch so it is ticking at the spawn stamp; only lapses inside a
        // bound's own span count. Stopped on every path, including a failed `#require`.
        let runner = DeschedulingProbe()
        defer { runner.stop() }
        let result = Result<ScriptOutcome, any Error> {
            try launcher.launch(invocation("flood", delivery: .timedStdin(script: "x", seconds: 1),
                                           options: ["ready=\(ready)"]))
        }
        let returnedAt = RecordedChildren.now()
        let reads = io.readTimes
        let early = Self.earlyExit(children, "the fairness scenario", expiry: 6,
                                   lastAttempt: lastAttempt)
        if case .missed(let why) = early {
            print("fairness scenario missed on attempt \(attempt) of 3: \(why)")
            return false
        }
        let earlyExit: Bool
        if case .failed = early { earlyExit = true } else { earlyExit = false }
        // Decided before any check: the gate's half while the launcher was inside `spawn` (only a
        // hold that ran out with the root still running), the other from the read count alone.
        let gateMissed = children.sawReady == false && children.exitedBeforeReady == false
        let missed = gateMissed || reads.count < 3
        #expect(throws: AppleScriptRunner.TimeoutError.self) { _ = try result.get() }
        Self.checkWindow(reads, within: 1.0, "the reads before the timeout", required: lastAttempt)
        #expect(io.outstanding.isEmpty)
        if missed && !lastAttempt && !earlyExit {
            let why = gateMissed
                ? "the readiness gate expired after 60 s before the root's output was pending"
                : "only \(reads.count) reads came before the timeout, too few to measure"
            print("fairness scenario missed on attempt \(attempt) of 3: \(why)")
            return false
        }
        if !earlyExit {
            #expect(children.sawReady == true,
                    "the readiness gate expired before the flood root's output was pending")
        }
        let spawnedAt = try #require(children.spawnedAt,
                                     "the recording backend must have spawned the root")
        let signalledAt = try #require(children.firstSignalAt,
                                       "the timeout must signal the owned group")
        let signalBound: UInt64 = 4_000_000_000
        let signalOrdered = spawnedAt <= signalledAt
        let toSignal = signalOrdered ? signalledAt - spawnedAt : 0
        let signalBounded = signalOrdered && toSignal < signalBound
        let cleanupBound: UInt64 = 20_000_000_000
        let cleanupOrdered = signalledAt <= returnedAt
        let toReturn = cleanupOrdered ? returnedAt - signalledAt : 0
        let cleanupBounded = cleanupOrdered && toReturn < cleanupBound
        let signalWithheld = runner.lapsed(from: spawnedAt, to: signalledAt)
        let cleanupWithheld = runner.lapsed(from: signalledAt, to: returnedAt)
        let signalTiming = "\(DeschedulingProbe.seconds(toSignal)) s from the spawn stamp to the "
            + "first signal, \(DeschedulingProbe.seconds(signalWithheld)) s of it withheld by the "
            + "runner"
        let cleanupTiming = "\(DeschedulingProbe.seconds(toReturn)) s from the first signal to "
            + "the return, \(DeschedulingProbe.seconds(cleanupWithheld)) s of it withheld by the "
            + "runner"
        let canSetAside = !lastAttempt && !earlyExit
        let signalStalled = canSetAside && signalOrdered && !signalBounded
            && Self.crossedOnlyByStall(elapsed: toSignal, withheld: signalWithheld,
                                       bound: signalBound)
        let cleanupStalled = canSetAside && cleanupOrdered && !cleanupBounded
            && Self.crossedOnlyByStall(elapsed: toReturn, withheld: cleanupWithheld,
                                       bound: cleanupBound)
        if !signalStalled {
            #expect(signalBounded,
                    "sustained output must not postpone the one-second deadline (\(signalTiming))")
        }
        if !cleanupStalled {
            #expect(cleanupBounded, "timeout cleanup must stay bounded (\(cleanupTiming))")
        }
        var stalls: [String] = []
        if signalStalled {
            stalls.append("the 4 s signal bound was crossed by no more than the time the runner "
                          + "withheld (\(signalTiming))")
        }
        if cleanupStalled {
            stalls.append("the 20 s cleanup bound was crossed by no more than the time the "
                          + "runner withheld (\(cleanupTiming))")
        }
        if !stalls.isEmpty {
            print("fairness scenario missed on attempt \(attempt) of 3: "
                  + stalls.joined(separator: "; "))
            return false
        }
        return true
    }
}
