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
    private let launcher = OsascriptLauncher()
    private let scratch = ScratchDirs("owned-process-cleanup")

    private enum StopProbeFailure: Error, Equatable { case callLimit, clockRead }

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

    @Test("output overflow stops inheriting descendants during live output and after root exit",
          arguments: ["live-capture", "live-pipe", "after-exit"])
    func outputLimitStopsOwnedDescendants(phase: String) throws {
        let fixture = try Fixture(directory: scratch.directory())
        defer { fixture.waitForNaturalExpiry() }
        let delivery: ScriptDelivery = phase == "live-capture" ? .timed(seconds: 3) : .timedStdin(script: "x", seconds: 3)
        let mode = phase == "after-exit" ? "overflow-after-exit" : "overflow-live"
        let started = Date()
        let failure = try #require(#expect(throws: ScriptOutputLimitExceeded.self) {
            _ = try launcher.launch(fixture.invocation(mode: mode, status: 0, delivery: delivery, maximumOutputBytes: 32))
        })
        #expect(failure.maximumOutputBytes == 32)
        #expect(Date().timeIntervalSince(started) < 6)
        if phase == "after-exit" {
            #expect(FileManager.default.fileExists(atPath: fixture.path("root-observed-exited")))
        }
        #expect(try fixture.stops(fixture.identity("root"), within: 0.5))
        #expect(try fixture.stops(fixture.identity("descendant"), within: 0.5),
                "overflow must stop the inheriting descendant, not just the root")
    }

    @Test("a timeout stops the TERM-ignoring root and its TERM-ignoring descendant",
          arguments: [false, true])
    func timeoutStopsOwnedGroup(stdin: Bool) throws {
        let fixture = try Fixture(directory: scratch.directory())
        defer { fixture.waitForNaturalExpiry() }
        let started = Date()
        let error = #expect(throws: AppleScriptRunner.TimeoutError.self) {
            _ = try launcher.launch(fixture.invocation(
                mode: "wait", status: 0,
                delivery: stdin ? .timedStdin(script: "x", seconds: 2) : .timed(seconds: 2)))
        }
        #expect(try #require(error).seconds == 2)
        #expect(Date().timeIntervalSince(started) < 6,
                "timeout cleanup must complete before the fixture's 12-second natural expiry")
        let root = try fixture.identity("root")
        let descendant = try fixture.identity("descendant")
        #expect(try fixture.stops(root, within: 0.5), "the root survived cancellation")
        #expect(try fixture.stops(descendant, within: 0.5),
                "the descendant survived cancellation; stopping only the root is insufficient")
    }

    @Test("a drain timeout stops the descendant after the root has exited")
    func timeoutAfterRootExitStopsOwnedGroup() throws {
        let fixture = try Fixture(directory: scratch.directory())
        defer { fixture.waitForNaturalExpiry() }
        let started = Date()
        let monotonicStart = try fixture.monotonicNanoseconds()
        let error = #expect(throws: AppleScriptRunner.TimeoutError.self) {
            _ = try launcher.launch(fixture.invocation(
                mode: "exit", status: 0, delivery: .timedStdin(script: "x", seconds: 2)))
        }
        #expect(try #require(error).seconds == 2)
        #expect(Date().timeIntervalSince(started) < 6,
                "the inherited output pipes must not extend the invocation until natural expiry")
        #expect(FileManager.default.fileExists(atPath: fixture.path("root-exiting")),
                "the root must reach its immediate-exit branch; missing readiness is a test failure")
        let observationText = try String(contentsOfFile: fixture.path("root-observed-exited"),
                                         encoding: .utf8)
        let observedExit = try #require(UInt64(observationText.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(observedExit >= monotonicStart && observedExit < monotonicStart + 1_500_000_000,
                "root exit must be observed well before the two-second deadline, not caused by cleanup")
        #expect(try fixture.monotonicNanoseconds() >= monotonicStart + 2_000_000_000,
                "the pending drain must reach its deadline rather than fail early")
        #expect(try fixture.stops(fixture.identity("root"), within: 0.5))
        #expect(try fixture.stops(fixture.identity("descendant"), within: 0.5),
                "root exit must not discard the authority needed for drain-timeout cleanup")
    }

    @Test("completed timed capture preserves background work for zero and nonzero root status",
          arguments: [Int32(0), Int32(7)])
    func completedCapturePreservesBackgroundWork(status: Int32) throws {
        let fixture = try Fixture(directory: scratch.directory())
        defer { fixture.waitForNaturalExpiry() }
        let started = Date()
        let outcome = try launcher.launch(fixture.invocation(
            mode: "exit", status: status, delivery: .timed(seconds: 2)))
        #expect(outcome.terminationStatus == status)
        #expect(outcome.standardOutput == Data("root-output\n".utf8))
        #expect(outcome.standardError == Data("root-error\n".utf8))
        #expect(Date().timeIntervalSince(started) < 6,
                "a completed capture must not await background descriptor closure")
        #expect(try fixture.isRunning(fixture.identity("descendant")),
                "a completed root outcome must not cancel intentional background work")
    }

    @Test("completed stdin delivery preserves background work that closed its output pipes")
    func completedStdinPreservesBackgroundWork() throws {
        let fixture = try Fixture(directory: scratch.directory())
        defer { fixture.waitForNaturalExpiry() }
        let outcome = try launcher.launch(fixture.invocation(
            mode: "closed-output", status: 0, delivery: .timedStdin(script: "x", seconds: 2)))
        #expect(outcome.terminationStatus == 0)
        #expect(outcome.standardOutput == Data("root-output\n".utf8))
        #expect(outcome.standardError == Data("root-error\n".utf8))
        #expect(try fixture.isRunning(fixture.identity("descendant")),
                "EOF-complete success must preserve background work")
    }

    private struct Fixture {
        let directory: URL

        // Arm an in-process kernel alarm before publishing readiness or reading stdin.
        // A broken feeder can therefore never strand an unbounded root before child expiry
        // begins. The forked descendant arms its own alarm: alarms are not inherited by fork.
        // /usr/bin/python3 is also used by the existing SnapshotLifetimeTests process fixture.
        private static let rootScript = #"""
        import os, signal, sys
        def arm_expiry():
            signal.signal(signal.SIGALRM, signal.SIG_DFL)
            signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGALRM})
            signal.alarm(12)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
        arm_expiry()
        import ctypes, time
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
        directory, mode, status = sys.argv[1:]
        def publish(name, value):
            with open(os.path.join(directory, name), "w") as output:
                output.write(str(value) + "\n")
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
        publish_identity("root")
        sys.stdin.buffer.read()
        ready_read, ready_write = os.pipe()
        descendant = os.fork()
        if descendant == 0:
            arm_expiry()
            os.close(ready_read)
            if mode == "closed-output":
                null = os.open(os.devnull, os.O_WRONLY)
                os.dup2(null, 1)
                os.dup2(null, 2)
                os.close(null)
            publish_identity("descendant")
            os.write(ready_write, b"R")
            os.close(ready_write)
            if mode not in ("wait", "overflow-live"):
                while os.getppid() == root_pid:
                    time.sleep(0.01)
                publish("root-observed-exited", time.clock_gettime_ns(time.CLOCK_MONOTONIC))
                if mode == "overflow-after-exit":
                    os.write(1, b"x" * 64)
            while True:
                signal.pause()
        os.close(ready_write)
        ready = os.read(ready_read, 1)
        os.close(ready_read)
        if ready != b"R":
            os._exit(91)
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

        func invocation(mode: String, status: Int32, delivery: ScriptDelivery,
                        maximumOutputBytes: Int? = nil) -> ScriptInvocation {
            ScriptInvocation(executablePath: "/usr/bin/python3",
                             arguments: ["-c", Self.rootScript, directory.path, mode, String(status)],
                             delivery: delivery, maximumOutputBytes: maximumOutputBytes)
        }

        // Python and Swift explicitly use the same named OS clock and nanosecond units.
        func monotonicNanoseconds() throws -> UInt64 {
            var value = timespec()
            guard clock_gettime(CLOCK_MONOTONIC, &value) == 0 else {
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
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, identity.pid]
            let result = sysctl(&mib, 4, &info, &size, nil, 0)
            if result != 0 {
                if errno == ESRCH { return false }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard size > 0 else { return false }
            let started = info.kp_proc.p_un.__p_starttime
            return info.kp_proc.p_pid == identity.pid
                && Int64(started.tv_sec) == identity.seconds
                && Int64(started.tv_usec) == identity.microseconds
                && Int32(info.kp_proc.p_stat) != SZOMB
        }

        func stops(_ identity: Identity, within seconds: TimeInterval) throws -> Bool {
            try stops(identity, within: seconds,
                      wallNow: { Date().timeIntervalSinceReferenceDate },
                      monotonicNow: { Double(try monotonicNanoseconds()) / 1_000_000_000 },
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
        /// Internal descriptor closure is verified separately by ProcessResourceTests.
        /// An arbitrary infinite loop inside the launcher still requires the suite-level bound.
        func waitForNaturalExpiry() {
            do {
                for name in ["descendant", "root"] {
                    guard FileManager.default.fileExists(atPath: path(name)) else { continue }
                    #expect(try stops(identity(name), within: 16),
                            "the self-expiring synthetic fixture remained live")
                }
            } catch {
                Issue.record("could not observe synthetic fixture cleanup: \(error)")
            }
        }
    }
}
