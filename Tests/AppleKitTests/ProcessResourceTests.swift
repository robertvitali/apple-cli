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
    var syntheticReadUntil: DispatchTime?

    init(trace: ProcessTrace = ProcessTrace()) { self.trace = trace }
    var outstanding: Set<Int32> { lock.withLock { liveDescriptors } }
    var allocationCount: Int { lock.withLock { created } }
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
        return record(try live.capture(in: directory))
    }
    func read(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if let readFailure, fd == failedReadFD { throw DarwinScriptProcessIO.posixError(readFailure) }
        if let until = syntheticReadUntil {
            if DispatchTime.now() >= until { throw DarwinScriptProcessIO.posixError(EIO) }
            usleep(1_000)
            buffer[0] = 120
            return 1
        }
        return try live.read(fd, into: buffer)
    }
    func write(_ fd: Int32, from buffer: UnsafeRawBufferPointer) throws -> Int { try live.write(fd, from: buffer) }
    func captureSnapshot(_ fd: Int32) throws -> Data {
        captureReads += 1
        trace.add("capture\(captureReads)")
        if captureReads == failCaptureRead, let captureFailure { throw captureFailure }
        return try live.captureSnapshot(fd)
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

private final class RecordedChildren: ScriptProcessChildren, @unchecked Sendable {
    let trace: ProcessTrace
    let recordedReaper: RecordedReaper
    private let live = DarwinScriptProcessChildren()
    var reaper: any ScriptProcessReaping { recordedReaper }
    init(_ trace: ProcessTrace) { self.trace = trace; recordedReaper = RecordedReaper(trace) }
    func spawn(_ invocation: ScriptInvocation, input: Int32, output: Int32, error: Int32) throws -> pid_t {
        trace.add("spawn")
        return try live.spawn(invocation, input: input, output: output, error: error)
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
    var reply: Reply {
        get { lock.withLock { selectedReply } }
        set { lock.withLock { selectedReply = newValue } }
    }
    var calls: Int { lock.withLock { callCount } }
    var pendingReplies: Int {
        get { lock.withLock { remainingPending } }
        set { lock.withLock { remainingPending = newValue } }
    }
    func reap(_ pid: pid_t) throws -> Bool {
        try lock.withLock {
            callCount += 1
            if remainingPending > 0 { remainingPending -= 1; return false }
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
    func spawn(_ invocation: ScriptInvocation, input: Int32, output: Int32, error: Int32) throws -> pid_t {
        starts += 1
        return returnedPID // An opaque test value; never submitted to a Darwin child API.
    }
    func observe(_ pid: pid_t) throws -> Int32? {
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
    private static let fixture = #"""
    import os, signal, sys, time
    def expire():
        signal.signal(signal.SIGALRM, signal.SIG_DFL)
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGALRM})
        signal.alarm(6)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    expire()
    mode = sys.argv[1]
    if mode == "signal":
        os.kill(os.getpid(), signal.SIGKILL)
    if mode == "flood":
        while True:
            os.write(1, b"x" * 1024)
            os.write(2, b"progress\n")
            time.sleep(0.001)
    if mode == "exit":
        os.write(1, b"output")
        os.write(2, b"error")
        os._exit(7)
    ready_in, ready_out = os.pipe()
    if os.fork() == 0:
        expire()
        os.close(ready_in)
        if mode == "detached":
            os.setsid()
        os.close(0)
        os.write(ready_out, b"r")
        os.close(ready_out)
        if mode == "detached":
            # Only this detached child writes the private heartbeat. An advancing value after
            # launcher return proves it is still executing without a PID-reuse assumption.
            while True:
                with open(sys.argv[2] + ".next", "w") as heartbeat:
                    heartbeat.write(str(time.monotonic_ns()))
                os.replace(sys.argv[2] + ".next", sys.argv[2])
                time.sleep(0.02)
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

    private func invocation(_ mode: String, delivery: ScriptDelivery) -> ScriptInvocation {
        ScriptInvocation(executablePath: "/usr/bin/python3", arguments: ["-c", Self.fixture, mode], delivery: delivery)
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
        let io = RecordingProcessIO()
        let launcher = OsascriptLauncher(dependencies: .init(io: io))
        let delivery: ScriptDelivery = timed ? .timedStdin(script: String(repeating: "x", count: 262_144), seconds: 4) :
            .stdin(script: String(repeating: "x", count: 262_144))
        let start = Date()
        let error = #expect(throws: AppleScriptRunner.RunError.self) {
            try launcher.launch(invocation("delivery", delivery: delivery))
        }
        guard case .launchFailed(let diagnosis) = try #require(error) else { Issue.record("wrong error"); return }
        #expect(diagnosis.hasPrefix("could not deliver script on stdin:"))
        #expect(io.outstanding.isEmpty)
        #expect(io.allocationCount == 6)
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test("parent descriptors close while a detached descendant still holds the opposite ends")
    func detachedSurvivorDoesNotRetainParentDescriptors() throws {
        let directory = try scratch.directory()
        let heartbeat = directory.appendingPathComponent("heartbeat")
        let io = RecordingProcessIO()
        let launcher = OsascriptLauncher(dependencies: .init(io: io))
        let invocation = ScriptInvocation(executablePath: "/usr/bin/python3",
            arguments: ["-c", Self.fixture, "detached", heartbeat.path],
            delivery: .timedStdin(script: String(repeating: "x", count: 262_144), seconds: 4))
        defer {
            // Child armed its own six-second alarm before readiness. Let that expiry finish
            // before ScratchDirs cleanup, including when the launcher's cancellation regresses.
            usleep(6_200_000)
        }
        let error = #expect(throws: AppleScriptRunner.RunError.self) { try launcher.launch(invocation) }
        guard case .launchFailed(let diagnosis) = try #require(error) else { Issue.record("wrong error"); return }
        #expect(diagnosis.hasPrefix("could not deliver script on stdin:"))
        #expect(io.outstanding.isEmpty)
        let returnedAt = DispatchTime.now().uptimeNanoseconds
        // Python and Dispatch uptime epochs need not be equal: compare two values emitted by
        // the child, with the second read separated from return by an actual elapsed interval.
        let first = try #require(UInt64(String(contentsOf: heartbeat, encoding: .utf8)))
        var advanced = false
        let deadline = Date().addingTimeInterval(0.5)
        repeat {
            usleep(20_000)
            let next = try #require(UInt64(String(contentsOf: heartbeat, encoding: .utf8)))
            if next > first { advanced = true; break }
        } while Date() < deadline
        #expect(advanced, "the detached descendant must execute after the parent descriptors closed")
        #expect(DispatchTime.now().uptimeNanoseconds > returnedAt)
        #expect(io.outstanding.isEmpty)
    }

    @Test("a read failure closes all parent resources and leaves subsequent launches usable", arguments: [1, 2])
    func readFailureClosesResources(stream: Int) throws {
        let io = RecordingProcessIO()
        io.readFailure = EIO
        io.failedReadPipe = stream
        let launcher = OsascriptLauncher(dependencies: .init(io: io))
        let error = #expect(throws: AppleScriptRunner.RunError.self) {
            try launcher.launch(invocation("read", delivery: .timedStdin(script: "x", seconds: 4)))
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
          arguments: [1, 2])
    func captureFailureBeforeReap(read: Int) throws {
        let io = RecordingProcessIO()
        io.captureFailure = Self.sentinel
        io.failCaptureRead = read
        let children = RecordedChildren(io.trace)
        let launcher = OsascriptLauncher(captureDirectory: try scratch.directory(), dependencies: .init(io: io, children: children))
        do {
            _ = try launcher.launch(invocation("capture", delivery: .timed(seconds: 2)))
            Issue.record("expected capture failure")
        } catch {
            #expect((error as NSError) === Self.sentinel)
            #expect((error as NSError).domain == Self.sentinel.domain)
            #expect((error as NSError).code == Self.sentinel.code)
            #expect((error as NSError).userInfo["synthetic"] as? String == "preserve this error")
        }
        let events = io.trace.events
        let observed = try #require(events.firstIndex(of: "observed"))
        let failed = try #require(events.firstIndex(of: "capture\(read)"))
        let term = try #require(events.firstIndex(of: "signal\(SIGTERM)"))
        let kill = try #require(events.firstIndex(of: "signal\(SIGKILL)"))
        let reaped = try #require(events.firstIndex(of: "reaped"))
        #expect(observed < failed && failed < term && term < kill && kill < reaped)
        #expect(io.outstanding.isEmpty)
    }

    @Test("ECHILD revokes signals and does not transfer a child that has already been lost",
          arguments: [false, true])
    func lostChildRevokesAuthority(afterTerm: Bool) throws {
        let io = RecordingProcessIO()
        io.captureFailure = Self.sentinel
        let children = NoSpawnChildren()
        children.observation = afterTerm ? .lostAfterTerm : .lost
        let sink = HeldReaps()
        let launcher = OsascriptLauncher(captureDirectory: try scratch.directory(), dependencies: .init(io: io, children: children, deferred: sink))
        do {
            _ = try launcher.launch(ScriptInvocation(arguments: [], delivery: .timed(seconds: 0.1)))
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
        let io = RecordingProcessIO()
        io.captureFailure = Self.sentinel
        let children = NoSpawnChildren()
        let sink = HeldReaps()
        let launcher = OsascriptLauncher(captureDirectory: try scratch.directory(), dependencies: .init(io: io, children: children, deferred: sink))
        let start = Date()
        do {
            _ = try launcher.launch(ScriptInvocation(arguments: [], delivery: .timed(seconds: 0.1)))
            Issue.record("expected failure")
        } catch { #expect((error as NSError) === Self.sentinel) }
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(children.starts == 1)
        #expect(children.signals == [SIGTERM, SIGKILL])
        #expect(io.outstanding.isEmpty)
        #expect(sink.obligations.count == 1)
        let obligation = try #require(sink.obligations.first)
        #expect(!obligation.poll())
        children.fakeReaper.reply = lost ? .lost : .exited
        #expect(obligation.poll())
        let calls = children.fakeReaper.calls
        #expect(obligation.poll())
        #expect(children.fakeReaper.calls == calls)
        #expect(children.signals == [SIGTERM, SIGKILL])
    }

    @Test("a transient interrupted reap preserves completed output without group cancellation")
    func interruptedSuccessfulReap() throws {
        let children = NoSpawnChildren()
        children.fakeReaper.reply = .exited
        children.fakeReaper.pendingReplies = 1 // Darwin reaper's EINTR result.
        let io = RecordingProcessIO()
        let sink = HeldReaps()
        let launcher = OsascriptLauncher(captureDirectory: try scratch.directory(), dependencies: .init(io: io, children: children, deferred: sink))
        let outcome = try launcher.launch(ScriptInvocation(arguments: [], delivery: .timed(seconds: 0.1)))
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
        let outcome = try launcher.launch(ScriptInvocation(arguments: [], delivery: .timed(seconds: 0.1)))
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
                _ = try launcher.launch(ScriptInvocation(arguments: [], delivery: .timed(seconds: 0.1)))
                Issue.record("expected capture failure")
            } catch { #expect((error as NSError) === Self.sentinel) }
            #expect(children.signals.isEmpty)
            #expect(io.outstanding.isEmpty)
            #expect(sink.obligations.isEmpty)
        }
    }

    @Test("a close error remains a delivery failure and cleanup preserves the first diagnosis")
    func inputCloseFailure() throws {
        let io = RecordingProcessIO()
        io.failInputClose = true
        let error = #expect(throws: AppleScriptRunner.RunError.self) {
            try OsascriptLauncher(dependencies: .init(io: io)).launch(invocation("read", delivery: .timedStdin(script: "x", seconds: 4)))
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
            _ = try launcher.launch(ScriptInvocation(arguments: [], delivery: .timed(seconds: 0.1)))
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
            let deadline = Date().addingTimeInterval(2)
            while !scheduler.isIdle && Date() < deadline { usleep(10_000) }
            #expect(scheduler.isIdle)
            #expect(reaper.calls == 3)
            usleep(150_000)
            #expect(reaper.calls == 3)
        }
    }

    @Test("completion first observed after the deadline is a timeout", arguments: [false, true])
    func lateObservationCannotSucceed(stdin: Bool) throws {
        let children = NoSpawnChildren()
        children.fakeReaper.reply = .exited
        children.pendingObservations = stdin ? 1 : 0
        children.delayedObservationMicroseconds = 100_000
        let io = RecordingProcessIO()
        let sink = HeldReaps()
        let launcher = OsascriptLauncher(captureDirectory: try scratch.directory(), dependencies: .init(io: io, children: children, deferred: sink))
        let delivery: ScriptDelivery = stdin ? .timedStdin(script: "", seconds: 0.02) : .timed(seconds: 0.02)
        #expect(throws: AppleScriptRunner.TimeoutError.self) {
            try launcher.launch(ScriptInvocation(arguments: [], delivery: delivery))
        }
        #expect(children.signals == [SIGTERM, SIGKILL])
        #expect(io.outstanding.isEmpty)
        #expect(sink.obligations.isEmpty)
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
        let outcome = try OsascriptLauncher().launch(invocation("signal", delivery: .timed(seconds: 2)))
        #expect(outcome.terminationStatus == SIGKILL)
    }

    @Test("sustained output cannot postpone the deadline or retain descriptors")
    func outputDeadlineFairness() throws {
        let io = RecordingProcessIO()
        io.syntheticReadUntil = .now() + 4
        let start = Date()
        #expect(throws: AppleScriptRunner.TimeoutError.self) {
            try OsascriptLauncher(dependencies: .init(io: io)).launch(invocation("flood", delivery: .timedStdin(script: "x", seconds: 1)))
        }
        #expect(Date().timeIntervalSince(start) < 3.5)
        #expect(io.outstanding.isEmpty)
    }
}
