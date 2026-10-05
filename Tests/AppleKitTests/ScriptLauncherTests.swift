import Darwin
import Foundation
import Testing
import TestSupport
@testable import AppleKit

/// A launcher that records what it was asked to run and returns a canned outcome.
///
/// It never starts a process, which is the point: the rule these tests exist to pin is about
/// what `AppleScriptRunner` PUTS in the invocation, and that is observable here directly rather
/// than inferred from a live interpreter's behaviour.
private final class RecordingLauncher: ScriptLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ScriptInvocation] = []
    private let status: Int32
    private let out: Data
    private let err: Data
    private let failure: (any Error)?

    init(status: Int32 = 0, out: Data = Data(), err: Data = Data(), failure: (any Error)? = nil) {
        self.status = status
        self.out = out
        self.err = err
        self.failure = failure
    }

    func launch(_ invocation: ScriptInvocation) throws -> ScriptOutcome {
        lock.withLock { recorded.append(invocation) }
        if let failure { throw failure }
        return ScriptOutcome(terminationStatus: status, standardOutput: out, standardError: err)
    }

    var invocations: [ScriptInvocation] { lock.withLock { recorded } }
    /// The single recorded invocation, or `nil` when there was not exactly one.
    ///
    /// Optional rather than `recorded[0]`: a regression where the runner stops launching should
    /// report one clean failure, not trap and take every other result in the run down with it.
    /// And `count == 1` rather than `first`, so a runner that launched TWICE — a retry loop, a
    /// double-dispatch — is a failure here instead of being masked by reading only the first.
    var only: ScriptInvocation? { lock.withLock { recorded.count == 1 ? recorded[0] : nil } }
}

/// The argv rule that makes every AppleScript sink in this tool safe.
///
/// SECURITY, not tidiness: user- and store-derived text must reach `osascript` as argv (`on run
/// argv`) and must never be interpolated into script SOURCE, because AppleScript injection here
/// is RCE-class (`do shell script`, cross-recipient send, exfiltration). Before the launcher
/// seam existed that rule could only be checked by running a live interpreter and inspecting
/// what came back — which tests a symptom rather than the invariant. These read the invocation
/// the runner built.
///
/// Every launcher here is a `RecordingLauncher`: no process starts, and no `osascript` runs.
@Suite("AppleScript argv invariance")
struct AppleScriptArgvTests {

    /// Every metacharacter class that has ever been used to break out of a quoted context, plus
    /// a payload that would be a real RCE if it were ever compiled as source rather than read as
    /// data. Deliberately includes the option-looking values `-e` and `-l`, which is why the
    /// runner emits `--`.
    private static let hostile = [
        #""quoted""#,
        #"back\slash"#,
        "line\nbreak",
        "do shell script \"echo pwned\"",
        "\") & (do shell script \"id\") & (\"",
        "-e",
        "-l",
        "tab\tsep",
        "unicode ‑ – — ‹›",
    ]

    private static let script = "on run argv\nreturn item 1 of argv\nend run"

    @Test("hostile arguments travel as argv and never enter the script source")
    func hostileArgumentsStayOutOfSource() throws {
        let launcher = RecordingLauncher(out: Data("ok".utf8))
        _ = try AppleScriptRunner(launcher: launcher).run(Self.script, arguments: Self.hostile)

        let invocation = try #require(launcher.only)
        // The constant, not a literal: the assertion and the production default must not be
        // able to drift apart.
        #expect(invocation.executablePath == AppleScriptRunner.osascriptPath)
        #expect(invocation.arguments == ["-e", Self.script, "--"] + Self.hostile)
        #expect(invocation.delivery == .inline)

        // The script source is argv item 1 and is byte-identical to what the caller passed:
        // no hostile fragment reached it, and nothing was escaped INTO it either.
        #expect(invocation.arguments[1] == Self.script)
        for value in Self.hostile {
            #expect(!invocation.arguments[1].contains(value))
        }
    }

    @Test("`--` separates the source from the data so an option-shaped value stays positional")
    func optionTerminatorPrecedesUserData() throws {
        let launcher = RecordingLauncher()
        _ = try AppleScriptRunner(launcher: launcher).run("return 1", arguments: ["-e", "evil"])
        let argv = try #require(launcher.only).arguments
        // Exactly one `--`, immediately after the source, before anything caller-supplied.
        #expect(argv == ["-e", "return 1", "--", "-e", "evil"])
        #expect(argv.firstIndex(of: "--") == 2)
    }

    @Test("the timed overload builds the same argv and carries the deadline")
    func timedFormBuildsTheSameArgv() throws {
        let launcher = RecordingLauncher(out: Data("ok".utf8))
        _ = try AppleScriptRunner(launcher: launcher).run(Self.script, arguments: Self.hostile,
                                                          timeout: 12)
        let invocation = try #require(launcher.only)
        #expect(invocation.executablePath == AppleScriptRunner.osascriptPath)
        #expect(invocation.arguments == ["-e", Self.script, "--"] + Self.hostile)
        #expect(invocation.delivery == .timed(seconds: 12))
    }

    @Test("the stdin form puts the source on stdin and keeps argv to `-` plus the data")
    func stdinFormKeepsSourceOutOfArgv() throws {
        let launcher = RecordingLauncher(out: Data("ok".utf8))
        _ = try AppleScriptRunner(launcher: launcher).runViaStdin(Self.script,
                                                                  arguments: Self.hostile)
        let invocation = try #require(launcher.only)
        #expect(invocation.executablePath == AppleScriptRunner.osascriptPath)
        #expect(invocation.delivery == .stdin(script: Self.script))
        // `-` ends option parsing on macOS osascript, so no `--` is added — and adding one would
        // itself become argv item 1 and shift every caller index.
        #expect(invocation.arguments == ["-"] + Self.hostile)
        #expect(!invocation.arguments.contains("--"))
    }

    @Test("the timed stdin form keeps the same argv shape and carries the deadline")
    func timedStdinFormKeepsSourceOutOfArgv() throws {
        // The bounded overload must change NOTHING about where user data travels: source on
        // stdin, `-` plus the data in argv, no `--`. Only the delivery gains the deadline.
        let launcher = RecordingLauncher(out: Data("ok".utf8))
        _ = try AppleScriptRunner(launcher: launcher).runViaStdin(Self.script,
                                                                  arguments: Self.hostile,
                                                                  timeout: 12)
        let invocation = try #require(launcher.only)
        #expect(invocation.executablePath == AppleScriptRunner.osascriptPath)
        #expect(invocation.delivery == .timedStdin(script: Self.script, seconds: 12))
        #expect(invocation.arguments == ["-"] + Self.hostile)
        #expect(!invocation.arguments.contains("--"))
        #expect(!invocation.arguments.contains(Self.script), "source must not reach argv")
    }

    @Test("the timed stdin form applies the same deadline validation, before launching")
    func invalidStdinDeadlineNeverReachesTheLauncher() throws {
        let launcher = RecordingLauncher()
        let runner = AppleScriptRunner(launcher: launcher)
        for bad: TimeInterval in [0, -1, .nan, .infinity,
                                  AppleScriptRunner.maximumTimeoutSeconds + 1] {
            let error = #expect(throws: AppleScriptRunner.InvalidTimeoutError.self) {
                _ = try runner.runViaStdin("return 1", timeout: bad)
            }
            let reported = try #require(error).seconds
            // `==` is false for NaN against itself, so NaN is compared by kind.
            #expect(bad.isNaN ? reported.isNaN : reported == bad)
        }
        #expect(launcher.invocations.isEmpty, "nothing may be started on an invalid deadline")
        _ = try runner.runViaStdin("return 1", timeout: AppleScriptRunner.maximumTimeoutSeconds)
        #expect(try #require(launcher.only).delivery
                == .timedStdin(script: "return 1",
                               seconds: AppleScriptRunner.maximumTimeoutSeconds))
    }

    @Test("an invalid deadline is refused before anything is launched")
    func invalidDeadlineNeverReachesTheLauncher() throws {
        let launcher = RecordingLauncher()
        let runner = AppleScriptRunner(launcher: launcher)
        #expect(throws: AppleScriptRunner.InvalidTimeoutError.self) {
            _ = try runner.run("return 1", timeout: 0)
        }
        #expect(throws: AppleScriptRunner.InvalidTimeoutError.self) {
            _ = try runner.run("return 1", timeout: -1)
        }
        #expect(throws: AppleScriptRunner.InvalidTimeoutError.self) {
            _ = try runner.run("return 1", timeout: .nan)
        }
        // `.infinity` is the value that would otherwise reach `DispatchTime.now() + seconds` and
        // trap; its rendering is asserted too, because `Int(exactly:)` is nil for it and the
        // fallback path is what produces the message a user actually sees.
        let infinite = #expect(throws: AppleScriptRunner.InvalidTimeoutError.self) {
            _ = try runner.run("return 1", timeout: .infinity)
        }
        #expect(try #require(infinite).description == "invalid osascript timeout: inf")
        #expect(launcher.invocations.isEmpty, "nothing may be started on an invalid deadline")
    }

    @Test("the maximum deadline is accepted, one second past it is not")
    func deadlineBoundary() throws {
        let launcher = RecordingLauncher()
        let runner = AppleScriptRunner(launcher: launcher)
        _ = try runner.run("return 1", timeout: AppleScriptRunner.maximumTimeoutSeconds)
        #expect(try #require(launcher.only).delivery
                == .timed(seconds: AppleScriptRunner.maximumTimeoutSeconds))
        #expect(throws: AppleScriptRunner.InvalidTimeoutError.self) {
            _ = try runner.run("return 1", timeout: AppleScriptRunner.maximumTimeoutSeconds + 1)
        }
    }
}

/// The shared tail every form runs: status mapping and stdout decoding.
@Suite("AppleScript outcome mapping")
struct AppleScriptOutcomeTests {

    @Test("stdout is decoded as UTF-8 and trimmed of surrounding whitespace")
    func trimsStdout() throws {
        let launcher = RecordingLauncher(out: Data("  \n\tresult value\n\n".utf8))
        #expect(try AppleScriptRunner(launcher: launcher).run("x") == "result value")
    }

    @Test("interior whitespace survives; only the ends are trimmed")
    func keepsInteriorLayout() throws {
        let launcher = RecordingLauncher(out: Data("\na\n\nb\n".utf8))
        #expect(try AppleScriptRunner(launcher: launcher).run("x") == "a\n\nb")
    }

    @Test("a zero exit discards stderr — a warning is not part of the result")
    func zeroStatusIgnoresStderr() throws {
        // osascript writes advisories to stderr on runs that succeed. Folding those into the
        // return value would put them in the JSON envelope's data, so the success path must read
        // stdout and nothing else.
        let launcher = RecordingLauncher(out: Data("ok".utf8), err: Data("warning".utf8))
        #expect(try AppleScriptRunner(launcher: launcher).run("x") == "ok")
    }

    @Test("invalid UTF-8 is replacement-decoded rather than throwing")
    func lossyDecodesInvalidUTF8() throws {
        let launcher = RecordingLauncher(out: Data([0x61, 0xFF, 0x62]))
        #expect(try AppleScriptRunner(launcher: launcher).run("x") == "a\u{FFFD}b")
    }

    @Test("a non-zero exit becomes scriptFailed carrying the status and the raw stderr")
    func nonZeroExitMapsToScriptFailed() throws {
        let launcher = RecordingLauncher(status: 2, out: Data("partial".utf8),
                                         err: Data("boom\n".utf8))
        let error = #expect(throws: AppleScriptRunner.RunError.self) {
            _ = try AppleScriptRunner(launcher: launcher).run("x")
        }
        guard case .scriptFailed(let status, let stderr) = try #require(error) else {
            Issue.record("expected scriptFailed"); return
        }
        #expect(status == 2)
        #expect(stderr == "boom\n")
        // stderr stays OFF the public description — it can quote store content (info-leak).
        #expect(try #require(error).description == "osascript exited 2")
    }

    @Test("a launch failure propagates as launchFailed with a descriptive message")
    func launchFailurePropagates() throws {
        let launcher = RecordingLauncher(
            failure: AppleScriptRunner.RunError.launchFailed("no such file"))
        let error = #expect(throws: AppleScriptRunner.RunError.self) {
            _ = try AppleScriptRunner(launcher: launcher).runViaStdin("x")
        }
        #expect(try #require(error).description == "osascript launch failed: no such file")
    }

    @Test("quote escapes backslashes before quotes so the result re-reads as one literal")
    func quoteEscaping() {
        #expect(AppleScriptRunner.quote("plain") == "\"plain\"")
        #expect(AppleScriptRunner.quote("say \"hi\"") == "\"say \\\"hi\\\"\"")
        #expect(AppleScriptRunner.quote(#"c:\path"#) == #""c:\\path""#)
        #expect(AppleScriptRunner.quote(#"\""#) == #""\\\"""#)
        #expect(AppleScriptRunner.quote("") == "\"\"")
    }

    @Test("the timeout error renders whole seconds without a decimal point")
    func timeoutDescription() {
        #expect(AppleScriptRunner.TimeoutError(seconds: 30).description
                == "osascript timed out after 30s")
        #expect(AppleScriptRunner.TimeoutError(seconds: 0.5).description
                == "osascript timed out after 0.5s")
    }
}

/// Test-only decorator over the real child operations, for the tests in this file whose deadline is
/// their subject, or whose wall-clock bound must not include process start-up.
///
/// `OsascriptLauncher` starts its deadline when `spawn` returns, so whatever a child does before
/// the scenario exists (interpreter start-up, installing a trap, publishing its pid) would
/// otherwise run inside that deadline, and on a starved runner it could still be running when the
/// deadline fires. `spawn` therefore holds the launcher until the child has published `readyFile`,
/// then stamps, on `CLOCK_UPTIME_RAW` (the clock the launcher's `DispatchTime` deadline reads),
/// when it returned. Elapsed bounds start at that stamp, so they measure the launcher rather than
/// start-up. With no `readyFile` there is no hold: `spawn` stamps as soon as the real spawn
/// returns, for a child that has nothing to publish.
///
/// The hold is bounded at `gateSeconds`, sixty seconds. While it holds, the launcher is still
/// inside `spawn` (no deadline, delivery, observation or signal yet), so its length says nothing
/// about the launcher, and it ends as soon as the file appears, so a healthy run pays nothing for
/// it. An expired hold is what turns an attempt into a missed scenario, and a re-run starts the
/// child's start-up over, so under sustained starvation a long hold is worth more than another
/// attempt. Every watchdog over a gated launch is 120 seconds so it covers the hold.
///
/// The hold also ends as soon as the child exits without having published `readyFile`, since such
/// a child never can. The exit is read with `waitid(WNOWAIT)`, the same non-consuming observation
/// the launcher makes, so the child stays waitable for the launcher's own observation and reap;
/// the file is read once more after an exit is seen, so a child that published and then exited
/// between two polls still counts as ready. `exitedBeforeReady` records the early exit. It is
/// never a missed scenario, because it is no evidence that the runner was slow: until the hold
/// ends the launcher has not started its deadline, delivered input or signalled, so the child
/// ended by itself or through what the product's `spawn` set up. Every test that gates fails the
/// attempt at once on it, on any attempt, with an issue naming the early exit. The one exception
/// is a fixture that arms an alarm before it publishes (the pending-input overflow test's):
/// `earlyAlarmAfterCall` records when a death by SIGALRM was seen, from the call into `spawn`,
/// before which the child cannot arm, so that test can tell its fixture's alarm firing on time
/// while the runner withheld it from any other early exit.
///
/// The decorator also stamps the launcher's first observation of the root's exit, records every
/// group signal the launcher sends, and stamps every observation and group signal on
/// `DispatchTime`, the clock the launcher's own waits read. A test can then tell a scenario the
/// runner missed from a product failure, and check a window the launcher times from the launcher's
/// own turns. The signals still go to the real process group: the decorator observes the product,
/// it never acts for it.
private final class ReadyGatedChildren: ScriptProcessChildren, @unchecked Sendable {
    /// One group signal the launcher sent: which group, when, and whether `kill` accepted it.
    struct SentSignal {
        let number: Int32
        let group: pid_t
        let at: UInt64?
        let delivered: Bool
    }

    /// One call the launcher made into this decorator, stamped on `DispatchTime` when it began: an
    /// observation of the root (`signal` is nil) or a group signal.
    struct Turn {
        let signal: Int32?
        let at: DispatchTime
    }

    private static let gateSeconds: Double = 60
    private let real = DarwinScriptProcessChildren()
    private let readyFile: String?
    private let lock = NSLock()
    private var spawned: (pid: pid_t, at: UInt64?, ready: Bool, exitedUnready: Bool,
                          alarmAfterCall: UInt64?, called: UInt64?)?
    private var exitObserved: UInt64?
    private var sent: [SentSignal] = []
    private var turns: [Turn] = []
    var reaper: any ScriptProcessReaping { real.reaper }

    init(readyFile: URL?) { self.readyFile = readyFile?.path }

    /// `CLOCK_UPTIME_RAW` in nanoseconds, the clock `DispatchTime` and `DeschedulingProbe` read, or
    /// `nil` if the clock could not be read. It does not throw, so a clock failure after a
    /// successful `spawn` cannot strand a child the launcher has not yet taken ownership of; a
    /// missing stamp fails the test at its `#require` instead.
    static func uptimeNanoseconds() -> UInt64? {
        var value = timespec()
        guard clock_gettime(CLOCK_UPTIME_RAW, &value) == 0 else { return nil }
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }

    /// How `pid` exited, read with `WNOWAIT` so the child stays waitable for the launcher, or nil
    /// while it runs. It never reaps. A failed read other than `EINTR` answers nil: an observation
    /// error is not an exit, so the gate keeps holding and its own bound decides.
    private static func exitUnreaped(_ pid: pid_t) -> siginfo_t? {
        var information = siginfo_t()
        while waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT) != 0 {
            guard errno == EINTR else { return nil }
        }
        return information.si_pid == pid ? information : nil
    }

    /// A production launcher whose child operations run through this decorator. The capture
    /// directory has no default: every caller passes a `ScratchDirs` directory, so a timed launch's
    /// captures stay out of the shared temp root.
    func launcher(captureDirectory: URL) -> OsascriptLauncher {
        var dependencies = ScriptProcessDependencies()
        dependencies.children = self
        return OsascriptLauncher(captureDirectory: captureDirectory, dependencies: dependencies)
    }

    /// When `spawn` returned, after the readiness gate. `nil` before a spawn or on a clock failure.
    var spawnedAt: UInt64? { lock.withLock { spawned?.at } }
    /// When `spawn` was called, before the real spawn. `nil` before a spawn or on a clock failure.
    var calledAt: UInt64? { lock.withLock { spawned?.called } }
    /// The root `spawn` returned, which leads its own process group.
    var spawnedPID: pid_t? { lock.withLock { spawned?.pid } }
    /// Whether `readyFile` existed when the gate released (true with no gate); false means the gate
    /// timed out, or ended early because the child exited first (`exitedBeforeReady`).
    var wasReadyAtSpawn: Bool { lock.withLock { spawned?.ready ?? false } }
    /// Whether the gate saw the child exit before `readyFile` appeared, which ended the hold early.
    /// Always false with no gate.
    var exitedBeforeReady: Bool { lock.withLock { spawned?.exitedUnready ?? false } }
    /// When the child exited before `readyFile` appeared by dying of SIGALRM: nanoseconds from the
    /// call into `spawn` to when the gate saw the death. Nil otherwise.
    var earlyAlarmAfterCall: UInt64? { lock.withLock { spawned?.alarmAfterCall } }
    /// When the launcher first observed the root's exit, if it did.
    var exitObservedAt: UInt64? { lock.withLock { exitObserved } }
    /// Every group signal the launcher sent, in order.
    var signals: [SentSignal] { lock.withLock { sent } }
    /// Every observation and group signal the launcher made, in order. The launcher makes them all
    /// from the one thread that owns the launch, so this order is the order it made them in.
    var timeline: [Turn] { lock.withLock { turns } }

    func spawn(_ invocation: ScriptInvocation, input: Int32, output: Int32,
               error: Int32) throws -> pid_t {
        let called = Self.uptimeNanoseconds()
        let pid = try real.spawn(invocation, input: input, output: output, error: error)
        var ready = true
        var exitedUnready = false
        var alarmAfterCall: UInt64?
        if let readyFile {
            let limit = DispatchTime.now() + Self.gateSeconds
            ready = FileManager.default.fileExists(atPath: readyFile)
            while !ready, DispatchTime.now() < limit {
                if let ended = Self.exitUnreaped(pid) {
                    // A child that published and then exited between two polls did publish.
                    ready = FileManager.default.fileExists(atPath: readyFile)
                    exitedUnready = !ready
                    if exitedUnready, ended.si_code == CLD_KILLED, ended.si_status == SIGALRM,
                       let called, let seen = Self.uptimeNanoseconds(), seen >= called {
                        alarmAfterCall = seen - called
                    }
                    break
                }
                usleep(5_000)
                ready = FileManager.default.fileExists(atPath: readyFile)
            }
        }
        let at = Self.uptimeNanoseconds()
        lock.withLock {
            if spawned == nil {
                spawned = (pid, at, ready, exitedUnready, alarmAfterCall, called)
            }
        }
        return pid
    }

    func observe(_ pid: pid_t) throws -> Int32? {
        let turn = DispatchTime.now()
        lock.withLock { turns.append(Turn(signal: nil, at: turn)) }
        let status = try real.observe(pid)
        if status != nil, let at = Self.uptimeNanoseconds() {
            lock.withLock { if exitObserved == nil { exitObserved = at } }
        }
        return status
    }

    func signal(group: pid_t, signal number: Int32) throws {
        let at = Self.uptimeNanoseconds()
        let turn = DispatchTime.now()
        lock.withLock { turns.append(Turn(signal: number, at: turn)) }
        do {
            try real.signal(group: group, signal: number)
            record(SentSignal(number: number, group: group, at: at, delivered: true))
        } catch {
            record(SentSignal(number: number, group: group, at: at, delivered: false))
            throw error
        }
    }

    private func record(_ signal: SentSignal) { lock.withLock { sent.append(signal) } }
}

/// `OsascriptLauncher` — the production process handling, exercised against trivial system
/// binaries.
///
/// NO `osascript` RUNS HERE, and none may be added: driving the real interpreter means driving
/// whichever Apple app the script targets, against the operator's live data. What is under test
/// is process plumbing that has nothing to do with which interpreter is on the other end —
/// both streams drained concurrently and before the wait, the exit status, the script delivered
/// on stdin, the deadline and its SIGTERM→SIGKILL escalation, and a launch that cannot start at
/// all. `/bin/echo`, `/bin/cat`, `/usr/bin/false`, `/bin/sleep` and `/bin/sh` running a FIXED
/// literal script answer all of those deterministically and read nothing of the operator's. The
/// `executablePath` field they use is module-internal for exactly this reason: it gives the test
/// a harmless interpreter without giving any caller a choice of one.
@Suite("osascript launcher process handling")
struct OsascriptLauncherTests {

    private let launcher = OsascriptLauncher()
    private let scratch = ScratchDirs("script-launcher")

    @Test("the piped form returns stdout, an empty stderr, and exit 0")
    func pipedSuccess() throws {
        let outcome = try launcher.launch(
            ScriptInvocation(executablePath: "/bin/echo", arguments: ["hello world"]))
        #expect(outcome.terminationStatus == 0)
        #expect(String(decoding: outcome.standardOutput, as: UTF8.self) == "hello world\n")
        #expect(outcome.standardError.isEmpty)
    }

    @Test("the piped form reports a non-zero status with whatever the child wrote to stderr")
    func pipedFailureCarriesStderr() throws {
        let outcome = try launcher.launch(
            ScriptInvocation(executablePath: "/bin/cat",
                             arguments: ["/no/such/file/apple-cli-launcher-test"]))
        #expect(outcome.terminationStatus != 0)
        #expect(outcome.standardOutput.isEmpty)
        #expect(!outcome.standardError.isEmpty, "cat reports a missing file on stderr")
    }

    @Test("an exit status with no output at all is still reported faithfully")
    func pipedSilentFailure() throws {
        let outcome = try launcher.launch(
            ScriptInvocation(executablePath: "/usr/bin/false", arguments: []))
        #expect(outcome.terminationStatus == 1)
        #expect(outcome.standardOutput.isEmpty)
        #expect(outcome.standardError.isEmpty)
    }

    @Test("a result larger than a pipe buffer is read whole rather than deadlocking")
    func pipedLargeOutput() throws {
        // 256 KiB, comfortably past the 64 KiB pipe buffer that would block the child if the
        // reader waited for termination first.
        let payload = String(repeating: "abcdefgh", count: 32 * 1024)
        let outcome = try launcher.launch(
            ScriptInvocation(executablePath: "/bin/echo", arguments: [payload]))
        #expect(outcome.terminationStatus == 0)
        #expect(outcome.standardOutput.count == payload.utf8.count + 1)
    }

    @Test("a missing interpreter fails to launch instead of hanging")
    func pipedLaunchFailure() throws {
        let error = #expect(throws: AppleScriptRunner.RunError.self) {
            _ = try launcher.launch(ScriptInvocation(
                executablePath: "/nonexistent/apple-cli-launcher-test", arguments: []))
        }
        guard case .launchFailed = try #require(error) else {
            Issue.record("expected launchFailed"); return
        }
    }

    @Test("the stdin form delivers the script on stdin and closes it so the child can finish")
    func stdinFormDeliversTheScript() throws {
        let script = "line one\nline two\n"
        let outcome = try launcher.launch(
            ScriptInvocation(executablePath: "/bin/cat", arguments: [], delivery: .stdin(script: script)))
        #expect(outcome.terminationStatus == 0)
        #expect(String(decoding: outcome.standardOutput, as: UTF8.self) == script)
    }

    @Test("the stdin form still surfaces a non-zero status")
    func stdinFormFailure() throws {
        // The child CONSUMES stdin before exiting. A child that ignores it (`/usr/bin/false`,
        // as this used to be) races the parent's write: if the exit wins, the write takes EPIPE
        // and the launcher correctly reports `launchFailed`, so the test fails on the status it
        // asserts and reads as "the runner broke" rather than "the test assumed an ordering".
        // Observed under load. Only the two tests that exist to exercise EPIPE leave stdin unread.
        let outcome = try launcher.launch(ScriptInvocation(
            executablePath: "/bin/sh", arguments: ["-c", "cat >/dev/null; exit 1"],
            delivery: .stdin(script: "x")))
        #expect(outcome.terminationStatus == 1)
    }

    @Test("the deadline form captures output through its unlinked temp files")
    func deadlineFormSuccess() throws {
        let outcome = try launcher.launch(
            ScriptInvocation(executablePath: "/bin/echo", arguments: ["timed"], delivery: .timed(seconds: 30)))
        #expect(outcome.terminationStatus == 0)
        #expect(String(decoding: outcome.standardOutput, as: UTF8.self) == "timed\n")
        #expect(outcome.standardError.isEmpty)
    }

    @Test("the deadline form reports a non-zero status and its stderr")
    func deadlineFormFailure() throws {
        let outcome = try launcher.launch(
            ScriptInvocation(executablePath: "/bin/cat",
                             arguments: ["/no/such/file/apple-cli-launcher-test"], delivery: .timed(seconds: 30)))
        #expect(outcome.terminationStatus != 0)
        #expect(!outcome.standardError.isEmpty)
    }

    @Test("a child that outlives the deadline is terminated and the wait ends")
    func deadlineTerminatesAStalledChild() throws {
        // The fifty-millisecond deadline is the subject. The ten-second bound runs from the
        // decorator's stamp, taken as soon as the real spawn returns: `sleep` publishes nothing, so
        // there is no readiness gate, and its start-up does not matter because SIGTERM ends it
        // either way. A correct run takes at most about two seconds from that stamp (the deadline,
        // the one-second TERM grace and at most the one-second reap wait).
        //
        // A `DeschedulingProbe` records how long the runner withheld the process inside the
        // measured window. A crossed bound with at least the headroom withheld is a missed
        // scenario, printed and re-run at most twice. The probe never observes the launcher, so a
        // launcher that waits too long crosses the bound without a lapse and fails at once. The
        // last attempt applies the bound whatever the probe saw, and the reported deadline is
        // checked on every attempt.
        for attempt in 1...3 {
            if try terminatesStalledChild(attempt: attempt, lastAttempt: attempt == 3) { return }
        }
        Issue.record("stalled-child scenario: the last attempt returned without a verdict")
    }

    /// The stalled-child test's elapsed bound, from the decorator's stamp to `launch` returning.
    private static let stalledChildBoundNanoseconds: UInt64 = 10_000_000_000

    /// How far `stalledChildBoundNanoseconds` sits above the launcher's own worst case on this
    /// path, rounded down: the fifty-millisecond deadline, the one-second TERM grace and the
    /// one-second reap wait (`OwnedScriptProcess.cancel(timeout:)`).
    private static let stalledChildHeadroomNanoseconds: UInt64 = 7_900_000_000

    /// One attempt of `deadlineTerminatesAStalledChild`. Returns true after a failed product check
    /// (its recorded issues fail the test) or after asserting the scenario; returns false only when
    /// the deadline was reported correctly, another attempt remains, and the bound was crossed
    /// while the runner withheld at least the headroom from the process.
    private func terminatesStalledChild(attempt: Int, lastAttempt: Bool) throws -> Bool {
        let children = ReadyGatedChildren(readyFile: nil)
        let stamped = children.launcher(captureDirectory: try scratch.directory())
        // Started before the launch so it is ticking at the stamp; only lapses inside the measured
        // window count. Stopped on every path, including a failed `#require`.
        let runner = DeschedulingProbe()
        defer { runner.stop() }
        let error = #expect(throws: AppleScriptRunner.TimeoutError.self) {
            _ = try stamped.launch(ScriptInvocation(executablePath: "/bin/sleep",
                                                    arguments: ["30"],
                                                    delivery: .timed(seconds: 0.05)))
        }
        let returnedAt = try #require(ReadyGatedChildren.uptimeNanoseconds())
        let seconds = try #require(error).seconds
        let spawnedAt = try #require(children.spawnedAt, "the launcher never spawned the child")

        // Product checks, on every attempt. The bound is set aside, and the attempt re-run, only
        // when it was crossed while the probe saw the runner withhold at least the headroom inside
        // the measured window, and never on the last attempt.
        let timeoutReported = seconds == 0.05
        let ordered = spawnedAt <= returnedAt
        let elapsed = ordered ? returnedAt - spawnedAt : 0
        let bounded = ordered && elapsed < Self.stalledChildBoundNanoseconds
        let withheld = runner.lapsed(from: spawnedAt, to: returnedAt)
        let runnerStalled = ordered && !bounded && !lastAttempt
            && withheld >= Self.stalledChildHeadroomNanoseconds
        let timing = "\(DeschedulingProbe.seconds(elapsed)) s from the stamp, "
            + "\(DeschedulingProbe.seconds(withheld)) s of it withheld by the runner"
        #expect(timeoutReported, "the timeout must report the configured 0.05 s, not \(seconds)")
        if !runnerStalled {
            #expect(bounded, "the deadline must not become a new wait (\(timing))")
        }
        if !timeoutReported || !runnerStalled { return true }
        let headroom = DeschedulingProbe.seconds(Self.stalledChildHeadroomNanoseconds)
        print("""
            stalled-child scenario missed on attempt \(attempt) of 3: the bound was crossed \
            while the runner withheld at least the \(headroom) s headroom (\(timing))
            """)
        return false
    }

    @Test("the timed stdin form delivers the script and returns within the deadline")
    func timedStdinFormSuccess() throws {
        let script = "line one\nline two\n"
        let outcome = try launcher.launch(ScriptInvocation(
            executablePath: "/bin/cat", arguments: [],
            delivery: .timedStdin(script: script, seconds: 30)))
        #expect(outcome.terminationStatus == 0)
        #expect(String(decoding: outcome.standardOutput, as: UTF8.self) == script)
    }

    @Test("the timed stdin form still surfaces a non-zero status")
    func timedStdinFormFailure() throws {
        let outcome = try launcher.launch(ScriptInvocation(
            executablePath: "/bin/sh", arguments: ["-c", "cat >/dev/null; exit 1"],
            delivery: .timedStdin(script: "x", seconds: 30)))
        #expect(outcome.terminationStatus == 1)
    }

    @Test("a child that reads the script and then never exits is ended at the deadline")
    func timedStdinFormTerminatesAStalledChild() throws {
        // THE production hazard: a GUI-driving script that Mail reads whole and then stalls on (a
        // dialog, a lost window). The unbounded form waits forever here; the timed form must end
        // the child and throw, and the child must actually be gone. Through `launchBounded`: a
        // regression that removed the bound would otherwise hang this thread before the
        // elapsed-time assertion below could ever run.
        //
        // The two-second deadline is the subject. It is gated on the pid file so it does not cover
        // `sh` start-up, and the elapsed bound starts at the gated stamp; a correct run takes about
        // three seconds from it (the deadline plus the full one-second TERM grace). The pid and
        // exit windows are thirty seconds because a child the launcher could not reap within its
        // one-second wait is reaped later and answers `kill(pid, 0)` until then. The stall is
        // ninety seconds so that a launcher that never ends the child still fails the exit check,
        // rather than the child exiting on its own inside the window.
        //
        // The child traps nothing, so a gate that expires with `sh` still starting lets the
        // deadline's SIGTERM end `sh` before it writes its pid: the run reports TimeoutError(2)
        // within the bound and leaves no pid, and the code did nothing wrong. Such an attempt is a
        // missed scenario only once the root the launcher spawned is gone (`leftNoRoot`), so a
        // launch that left the child running fails instead. An attempt whose bound was crossed
        // while a `DeschedulingProbe` saw the runner withhold at least the headroom is also a miss.
        // Misses are printed and re-run at most twice. A failed product check on any attempt fails
        // the test, the exit check applies on every attempt whose child published its pid, and the
        // last attempt applies the bound whatever the probe saw. The watchdog is 120 seconds so it
        // covers the sixty-second gate.
        for attempt in 1...3 {
            if try terminatesStalledStdinChild(attempt: attempt, lastAttempt: attempt == 3) {
                return
            }
        }
        Issue.record("stalled-stdin-child scenario: the last attempt returned without a verdict")
    }

    /// One attempt of `timedStdinFormTerminatesAStalledChild`. Returns true after a failed product
    /// check (its recorded issues fail the test) or after asserting the scenario; returns false
    /// only when every product check that applied held, another attempt remains, and the scenario
    /// was missed: the child never published its pid, or the bound was crossed while the runner
    /// withheld at least the headroom from the process.
    private func terminatesStalledStdinChild(attempt: Int, lastAttempt: Bool) throws -> Bool {
        let pidFile = try scratch.directory().appendingPathComponent("pid")
        defer { reapIfLeaked(pidFile) }
        let children = ReadyGatedChildren(readyFile: pidFile)
        let gated = children.launcher(captureDirectory: try scratch.directory())
        // Started before the launch so it is ticking when the gate releases; only lapses inside the
        // measured window count. Stopped on every path, including a failed `#require`.
        let runner = DeschedulingProbe()
        defer { runner.stop() }
        let error = #expect(throws: AppleScriptRunner.TimeoutError.self) {
            _ = try launchBounded(ScriptInvocation(
                executablePath: "/bin/sh",
                arguments: ["-c", #"echo $$ > "$0"; cat >/dev/null; sleep 90"#, pidFile.path],
                delivery: .timedStdin(script: "read whole, then stall", seconds: 2)),
                                  pidFile: pidFile, seconds: 120, using: gated)
        }
        let returnedAt = try #require(ReadyGatedChildren.uptimeNanoseconds())
        if children.exitedBeforeReady {
            Issue.record("the child exited before publishing its pid, so the scenario never began")
            return true
        }
        let seconds = try #require(error).seconds
        let spawnedAt = try #require(children.spawnedAt,
                                     "the gated launcher never spawned the child")

        // Product checks, on every attempt. The bound is set aside, and the attempt re-run, only
        // when it was crossed while the probe saw the runner withhold at least the headroom inside
        // the measured window, and never on the last attempt.
        let timeoutReported = seconds == 2
        let ordered = spawnedAt <= returnedAt
        let elapsed = ordered ? returnedAt - spawnedAt : 0
        let bounded = ordered && elapsed < Self.timeoutBoundNanoseconds
        let withheld = runner.lapsed(from: spawnedAt, to: returnedAt)
        let runnerStalled = ordered && !bounded && !lastAttempt
            && withheld >= Self.timeoutHeadroomNanoseconds
        let timing = "\(DeschedulingProbe.seconds(elapsed)) s from the gated stamp, "
            + "\(DeschedulingProbe.seconds(withheld)) s of it withheld by the runner"
        #expect(timeoutReported,
                "the timeout must report the configured two seconds, not \(seconds)")
        if !runnerStalled {
            #expect(bounded, "the deadline must not become a new wait (\(timing))")
        }
        var missed: [String] = []
        if let pid = publishedPid(at: pidFile, within: 30) {
            let exited = hasExited(pid, within: 30)
            #expect(exited, "the stalled child outlived the deadline")
            if !exited { return true }
        } else {
            // The scenario: the child published its pid before the deadline's SIGTERM. Missing it,
            // the root `spawn` returned must still be gone.
            if !leftNoRoot(children) { return true }
            missed.append("""
                no pid was published \
                (gate \(children.wasReadyAtSpawn ? "released on the pid file" : "timed out"))
                """)
        }
        if runnerStalled {
            let headroom = DeschedulingProbe.seconds(Self.timeoutHeadroomNanoseconds)
            missed.append("""
                the bound was crossed while the runner withheld at least the \(headroom) s \
                headroom (\(timing))
                """)
        }
        if missed.isEmpty || !timeoutReported || !(bounded || runnerStalled) { return true }

        if !lastAttempt {
            print("""
                stalled-stdin-child scenario missed on attempt \(attempt) of 3: \
                \(missed.joined(separator: "; "))
                """)
            return false
        }
        Issue.record("the child never published its pid")
        return true
    }

    @Test("the deadline fires even while the stdin write is blocked on a child that reads nothing")
    func timedStdinFormDeadlineCoversABlockedWrite() throws {
        // A script four times the pipe buffer against a child that never reads it: the write
        // blocks. If the deadline were waited on from the writing thread it could never expire, and
        // this would be an unbounded hang dressed as a timed call. The child also ignores SIGTERM,
        // so the escalation has to reach SIGKILL for the write to be released.
        //
        // The two-second deadline is the subject, and it is gated on the pid file. The pid is
        // written after the trap, so its existence proves the trap was armed before the deadline
        // started and only SIGKILL can release the write. Ungated, a deadline that beat the trap
        // would kill `sh` with SIGTERM: the run would still report TimeoutError(2), the pid check
        // would fail against correct code, and the SIGKILL branch this test exists for would never
        // run. The elapsed bound starts at the gated stamp, and a correct run takes about three
        // seconds from it. The pid and exit windows are thirty seconds; the child loops for about
        // ninety seconds unless killed, so a missing escalation still fails the exit check.
        //
        // If the gate times out with `sh` still starting, the deadline starts before the trap is
        // armed, and the SIGTERM can kill `sh` before it writes its pid: the run reports
        // TimeoutError(2) within the bound but leaves no pid, and the code did nothing wrong. Such
        // an attempt is a missed scenario only once the root the launcher spawned is gone
        // (`leftNoRoot`), so a launch that left the child running is never re-run. The ten-second
        // bound gets the escalation test's `DeschedulingProbe` set-aside: a starved host can
        // withhold more than the bound's headroom, and because `launchBounded` already leaves out
        // the stall time it can see, the bound would otherwise be the one check still charging the
        // launcher with the runner's stall. A crossed bound with at least the headroom withheld is
        // a miss; one without fails at once. A wider bound would stop separating a launcher that
        // stretches its escalation waits from a correct run. Misses are printed and re-run at most
        // twice, a failed product check on any attempt fails the test, the exit check applies on
        // every attempt whose child published its pid, and the last attempt applies the bound
        // whatever the probe saw. The gate holds up to sixty seconds and the watchdog is 120 so it
        // covers it.
        for attempt in 1...3 {
            if try deadlineCoversBlockedWrite(attempt: attempt, lastAttempt: attempt == 3) {
                return
            }
        }
        Issue.record("blocked-write scenario: the last attempt returned without a verdict")
    }

    /// One attempt of `timedStdinFormDeadlineCoversABlockedWrite`. Returns true after a failed
    /// product check (its recorded issues fail the test) or after asserting the scenario; returns
    /// false only when every product check that applied held, another attempt remains, and the
    /// scenario was missed: the child never published its pid, or the bound was crossed while the
    /// runner withheld at least the headroom from the process.
    private func deadlineCoversBlockedWrite(attempt: Int, lastAttempt: Bool) throws -> Bool {
        let pidFile = try scratch.directory().appendingPathComponent("pid")
        defer { reapIfLeaked(pidFile) }
        let children = ReadyGatedChildren(readyFile: pidFile)
        let gated = children.launcher(captureDirectory: try scratch.directory())
        // Started before the launch so it is ticking when the gate releases; only lapses inside the
        // measured window count. Stopped on every path, including a failed `#require`.
        let runner = DeschedulingProbe()
        defer { runner.stop() }
        let error = #expect(throws: AppleScriptRunner.TimeoutError.self) {
            _ = try launchBounded(ScriptInvocation(
                executablePath: "/bin/sh",
                arguments: ["-c", #"trap '' TERM; echo $$ > "$0"; "#
                            + #"i=0; while [ $i -lt 450 ]; do sleep 0.2; i=$((i+1)); done"#,
                            pidFile.path],
                delivery: .timedStdin(script: String(repeating: "a", count: 256 * 1024),
                                      seconds: 2)),
                                  pidFile: pidFile, seconds: 120, using: gated)
        }
        let returnedAt = try #require(ReadyGatedChildren.uptimeNanoseconds())
        if children.exitedBeforeReady {
            Issue.record("the child exited before publishing its pid, so the scenario never began")
            return true
        }
        // TimeoutError, NOT launchFailed: the deadline is the diagnosis here. The write's EPIPE
        // arrives only because the deadline killed the child, and reporting it instead would
        // hide the bound that actually fired.
        let seconds = try #require(error).seconds
        let spawnedAt = try #require(children.spawnedAt,
                                     "the gated launcher never spawned the child")

        // Product checks, on every attempt. 2s deadline, then at most two one-second escalation
        // waits, from the gated stamp. The bound is set aside, and the attempt re-run, only when it
        // was crossed while the probe saw the runner withhold at least the headroom inside the
        // measured window, and never on the last attempt.
        let timeoutReported = seconds == 2
        let ordered = spawnedAt <= returnedAt
        let elapsed = ordered ? returnedAt - spawnedAt : 0
        let bounded = ordered && elapsed < Self.timeoutBoundNanoseconds
        let withheld = runner.lapsed(from: spawnedAt, to: returnedAt)
        let runnerStalled = ordered && !bounded && !lastAttempt
            && withheld >= Self.timeoutHeadroomNanoseconds
        let timing = "\(DeschedulingProbe.seconds(elapsed)) s from the gated stamp, "
            + "\(DeschedulingProbe.seconds(withheld)) s of it withheld by the runner"
        #expect(timeoutReported,
                "the timeout must report the configured two seconds, not \(seconds)")
        if !runnerStalled {
            #expect(bounded, "the deadline must not become a new wait (\(timing))")
        }
        var missed: [String] = []
        if let pid = publishedPid(at: pidFile, within: 30) {
            let exited = hasExited(pid, within: 30)
            #expect(exited, "the TERM-ignoring child is still alive after the deadline")
            if !exited { return true }
        } else {
            // The scenario: the child armed its trap and published its pid before SIGKILL. Missing
            // it, the root `spawn` returned must still be gone.
            if !leftNoRoot(children) { return true }
            missed.append("""
                no pid was published \
                (gate \(children.wasReadyAtSpawn ? "released on the pid file" : "timed out"))
                """)
        }
        if runnerStalled {
            let headroom = DeschedulingProbe.seconds(Self.timeoutHeadroomNanoseconds)
            missed.append("""
                the bound was crossed while the runner withheld at least the \(headroom) s \
                headroom (\(timing))
                """)
        }
        if missed.isEmpty || !timeoutReported || !(bounded || runnerStalled) { return true }

        if !lastAttempt {
            print("""
                blocked-write scenario missed on attempt \(attempt) of 3: \
                \(missed.joined(separator: "; "))
                """)
            return false
        }
        Issue.record("the child never published its pid")
        return true
    }

    @Test("the stdin form fails to launch a missing interpreter")
    func stdinFormLaunchFailure() throws {
        let error = #expect(throws: AppleScriptRunner.RunError.self) {
            _ = try launcher.launch(ScriptInvocation(
                executablePath: "/nonexistent/apple-cli-launcher-test", arguments: [],
                delivery: .stdin(script: "x")))
        }
        guard case .launchFailed = try #require(error) else {
            Issue.record("expected launchFailed"); return
        }
    }

    @Test("a child that ignores SIGTERM is escalated to SIGKILL and is actually dead after")
    func deadlineEscalatesPastAnIgnoredTerminate() throws {
        // `terminate()` sends SIGTERM; a child that ignores it is exactly the case the KILL
        // escalation exists for, and without it the deadline leaves a live orphan behind.
        //
        // ASSERTING THE THROW IS NOT ENOUGH: both the escalating and the non-escalating paths end
        // at the same `throw TimeoutError`, so a suite that checks only the error and an elapsed
        // bound stays green with the whole KILL block deleted — while a TERM-deaf child runs on,
        // reparented to launchd, still holding its capture files. So the child publishes its pid
        // and the test asks the OS whether that pid is gone.
        //
        // The command is a FIXED literal; the pid-file path arrives as `$0` through argv (the
        // operand after `sh -c <script>`), never interpolated into script source. The loop (rather
        // than a bare `sleep`) keeps `sh` from exec'ing away its own trap. It ends by itself after
        // 450 turns of `sleep 0.2`, about ninety seconds, far past the deadline and the
        // thirty-second exit window, so a missing escalation still fails the exit check, and a
        // child a red run leaves behind ends within that time. The launch goes through
        // `launchBounded`, with the 120-second watchdog every gated launch has: a launcher whose
        // deadline never fires then returns when the loop ends, or is stopped by the watchdog, and
        // fails either way, instead of hanging the suite with no verdict.
        //
        // A deadline that expires before the trap is INSTALLED makes the child terminable by the
        // SIGTERM this test exists to prove is insufficient, and no deadline length guarantees the
        // trap on a starved runner while `sh` start-up sits inside the deadline. So the two-second
        // deadline, the subject, is gated on the pid, which `sh` writes after the trap, and the
        // elapsed bound starts at the gated stamp. An attempt whose gate timed out with no pid is a
        // missed scenario, not a product failure, but only once the root the launcher spawned is
        // gone (`leftNoRoot`), so a launch that left the child running is never re-run.
        //
        // The ten-second bound keeps six seconds of headroom above the launcher's own worst case
        // (the two-second deadline, the one-second TERM grace and the one-second reap wait), and a
        // starved, swapping host can withhold far more than that from the whole test process. A
        // `DeschedulingProbe` thread records how long the runner withheld the process inside the
        // measured window; a crossed bound with at least the headroom withheld is a missed
        // scenario, because the bound measured the runner. The probe never observes the launcher,
        // so a launcher that waits too long crosses the bound without a lapse and fails at once,
        // and an attempt whose bound was set aside can only be re-run, never pass. Misses are
        // printed and re-run at most twice, a failed product check on any attempt fails the test,
        // the exit check applies on every attempt whose child published its pid, and the last
        // attempt applies the bound whatever the probe saw.
        for attempt in 1...3 {
            if try escalatesPastIgnoredTerminate(attempt: attempt, lastAttempt: attempt == 3) {
                return
            }
        }
        Issue.record("escalation scenario: the last attempt returned without a verdict")
    }

    /// The elapsed bound of the gated two-second-deadline tests (the escalation test, the stalled
    /// stdin child and the blocked write), from the gated stamp to `launch` returning.
    private static let timeoutBoundNanoseconds: UInt64 = 10_000_000_000

    /// How far `timeoutBoundNanoseconds` sits above the launcher's own worst case on that path: the
    /// two-second deadline, the one-second TERM grace and the one-second reap wait
    /// (`OwnedScriptProcess.cancel(timeout:)`), four seconds in all, which leaves six of the
    /// ten-second bound. A correct launcher crosses the bound only if the runner withholds at least
    /// this much of the measured window from the launcher's thread; `DeschedulingProbe` sees only
    /// part of that (see there).
    private static let timeoutHeadroomNanoseconds: UInt64 = 6_000_000_000

    /// One attempt of `deadlineEscalatesPastAnIgnoredTerminate`. Returns true after a failed
    /// product check (its recorded issues fail the test) or after asserting the scenario; returns
    /// false only when every product check that applied held, another attempt remains, and the
    /// scenario was missed: the child never published its pid, or the bound was crossed while the
    /// runner withheld at least the headroom from the process.
    private func escalatesPastIgnoredTerminate(attempt: Int, lastAttempt: Bool) throws -> Bool {
        let pidFile = try scratch.directory().appendingPathComponent("pid")
        // A missing escalation leaves the TERM-deaf child looping for about ninety seconds; end it
        // here so a red run does not leak it into the rest of the suite.
        defer { reapIfLeaked(pidFile) }
        let children = ReadyGatedChildren(readyFile: pidFile)
        let gated = children.launcher(captureDirectory: try scratch.directory())
        // Started before the launch so it is ticking when the gate releases; only lapses inside the
        // measured window count. Stopped on every path, including a failed `#require`.
        let runner = DeschedulingProbe()
        defer { runner.stop() }
        let error = #expect(throws: AppleScriptRunner.TimeoutError.self) {
            _ = try launchBounded(ScriptInvocation(
                executablePath: "/bin/sh",
                arguments: ["-c",
                            #"trap '' TERM; echo $$ > "$0"; "#
                            + #"i=0; while [ $i -lt 450 ]; do sleep 0.2; i=$((i+1)); done"#,
                            pidFile.path],
                delivery: .timed(seconds: 2)),
                                  pidFile: pidFile, seconds: 120, using: gated)
        }
        let returnedAt = try #require(ReadyGatedChildren.uptimeNanoseconds())
        if children.exitedBeforeReady {
            Issue.record("the child exited before publishing its pid, so the scenario never began")
            return true
        }
        let seconds = try #require(error).seconds
        let spawnedAt = try #require(children.spawnedAt,
                                     "the gated launcher never spawned the child")

        // Product checks, on every attempt. Bounded: 2s deadline, then at most two one-second
        // cleanup waits, from the gated stamp. The bound is set aside, and the attempt re-run, only
        // when it was crossed while the probe saw the runner withhold at least the headroom inside
        // the measured window, and never on the last attempt.
        let timeoutReported = seconds == 2
        let ordered = spawnedAt <= returnedAt
        let elapsed = ordered ? returnedAt - spawnedAt : 0
        let bounded = ordered && elapsed < Self.timeoutBoundNanoseconds
        let withheld = runner.lapsed(from: spawnedAt, to: returnedAt)
        let runnerStalled = ordered && !bounded && !lastAttempt
            && withheld >= Self.timeoutHeadroomNanoseconds
        let timing = "\(DeschedulingProbe.seconds(elapsed)) s from the gated stamp, "
            + "\(DeschedulingProbe.seconds(withheld)) s of it withheld by the runner"
        #expect(timeoutReported,
                "the timeout must report the configured two seconds, not \(seconds)")
        if !runnerStalled {
            #expect(bounded, "the deadline must not become a new wait (\(timing))")
        }
        // Thirty seconds: a child the launcher could not reap within its one-second wait is reaped
        // later and answers `kill(pid, 0)` until then. The child loops for about ninety seconds
        // unless killed, so a missing escalation still fails this check, on every attempt whose
        // child published.
        var missed: [String] = []
        if let pid = publishedPid(at: pidFile, within: 30) {
            let exited = hasExited(pid, within: 30)
            #expect(exited, "the TERM-ignoring child is still alive after the deadline")
            if !exited { return true }
        } else {
            // The scenario: the child armed its trap and published its pid before the deadline. An
            // attempt that missed it counts as missed only once the root `spawn` returned is gone
            // (`leftNoRoot`); a launch that left that root running fails at once.
            if !leftNoRoot(children) { return true }
            missed.append("""
                no pid was published \
                (gate \(children.wasReadyAtSpawn ? "released on the pid file" : "timed out"))
                """)
        }
        if runnerStalled {
            let headroom = DeschedulingProbe.seconds(Self.timeoutHeadroomNanoseconds)
            missed.append("""
                the bound was crossed while the runner withheld at least the \(headroom) s \
                headroom (\(timing))
                """)
        }
        if missed.isEmpty || !timeoutReported || !(bounded || runnerStalled) { return true }

        if !lastAttempt {
            print("""
                escalation scenario missed on attempt \(attempt) of 3: \
                \(missed.joined(separator: "; "))
                """)
            return false
        }
        Issue.record("the child never published its pid")
        return true
    }

    @Test("SIGTERM is delivered before the SIGKILL escalation, not skipped past")
    func deadlineSendsTerminateBeforeKilling() throws {
        // The order matters and is otherwise unobservable: killing outright works just as well from
        // the caller's side (same `TimeoutError`, same dead child), but denies a child the chance
        // to finish an in-flight Apple event and shut down cleanly. This child TRAPS TERM, records
        // that it arrived, and exits — so the marker is present only if SIGTERM was actually
        // delivered first. Fixed literal; both paths come from argv (`$0`, `$1`).
        //
        // The child's loop ends by itself after 450 turns of `sleep 0.2`, about ninety seconds, far
        // past the deadline and the thirty-second root check, so a launcher whose signals miss the
        // child still fails that check, and a child a red run leaves behind ends within that time.
        // The launch goes through `launchBounded`, with the 120-second watchdog every gated launch
        // has, and the readiness marker carries the child's pid for the watchdog to end it by: a
        // launcher whose deadline never fires then returns when the loop ends, or is stopped by the
        // watchdog, and fails either way, instead of hanging the suite with no verdict.
        //
        // The readiness marker is written IMMEDIATELY AFTER the trap is installed, and the deadline
        // is gated on it, so unless the gate times out the deadline starts only once the trap is
        // armed. A missing TERM marker with the readiness marker present means the trap was armed
        // and never fired: the regression this test exists for. One exception lets a starved runner
        // accuse correct code: `sh` runs its trap only after the group-signalled `sleep 0.2`
        // returns, so a runner that starves it through the launcher's fixed one-second TERM grace
        // (a product constant the test cannot widen) lets SIGKILL land first. The gated decorator
        // records every group signal the launcher sends. That record is the launcher's own, so when
        // the trap did not fire it is checked whether or not the child armed its trap, and a record
        // that fails is the regression at once. A child starved through a correctly delivered
        // grace, or one that never armed its trap, under a record that held and with the spawned
        // root gone (`leftNoRoot`), is a missed scenario: printed and re-run at most twice, and the
        // last attempt fails on it. The TERM marker is the only pass condition.
        //
        // Three checks bound the grace's length on every attempt: SIGKILL's turn comes a full
        // second or more after SIGTERM's on the launcher's own clock, which holds for a full grace
        // under any load and fails a grace shortened by more than one pause turn (its 10 ms poll
        // plus that poll's lateness); the grace's pause stops observing within that second; and
        // SIGTERM to SIGKILL takes under two seconds on the decorator's stamps. Only the last can
        // fail a correct launcher under a stall, so its crossing is a missed scenario when a
        // `DeschedulingProbe` saw the runner withhold at least the bound's headroom over the
        // launcher's own worst case inside that span, as every other bound here is set aside, and
        // never on the last attempt; a launcher that waits a second or more past the grace, on a
        // runner that is running the test, fails at once.
        for attempt in 1...3 {
            if try terminatesBeforeKilling(attempt: attempt, lastAttempt: attempt == 3) { return }
        }
        Issue.record("TERM-before-KILL scenario: the last attempt returned without a verdict")
    }

    /// The launcher's TERM grace before SIGKILL on a timeout, one second, less the rounding that
    /// `DeschedulingProbe.clockRoundingNanoseconds` covers. The SIGTERM stamp is taken inside the
    /// launcher's SIGTERM call, before `kill`, so it precedes that call's return and the pause
    /// deadline the launcher sets after it (`OwnedScriptProcess.cancel(timeout:)`: `DispatchTime`
    /// now plus a second). The SIGKILL stamp is taken inside the SIGKILL call, which the launcher
    /// makes only after its pause found that deadline passed. Both stamps read the clock
    /// `DispatchTime` reads, so a full grace puts at least a second between them by construction,
    /// less rounding, under any load. `waitedOut`, on the launcher's own turns, checks the same
    /// second before this is read.
    private static let terminateGraceNanoseconds: UInt64 =
        1_000_000_000 - DeschedulingProbe.clockRoundingNanoseconds

    /// The same grace as the launcher sets it: its pause runs to `DispatchTime.now()` plus this,
    /// taken once its SIGTERM call has returned.
    private static let terminateGraceSeconds: Double = 1.0

    /// The bound on SIGTERM to SIGKILL on a timeout, on the decorator's `CLOCK_UPTIME_RAW` stamps.
    /// A correct launcher takes the one-second grace, the ten-millisecond pause turn that crosses
    /// its end and SIGKILL's own check, so this leaves about a second; a launcher that waits a
    /// second or more beyond the grace crosses it.
    private static let graceBoundNanoseconds: UInt64 = 2_000_000_000

    /// How far `graceBoundNanoseconds` sits above the launcher's own worst case on that span,
    /// rounded down: the one-second grace, the pause turn that crosses its end (an observation and
    /// a ten-millisecond poll) and SIGKILL's own observation, about 1.02 seconds, leave 0.98, and
    /// rounding down to 0.9 keeps the poll's overshoot and one 50 ms `DeschedulingProbe` tick, the
    /// most of a stall a lapse leaves unseen, in hand. A correct launcher crosses the bound only if
    /// the runner withholds at least this much of the span from the launcher's thread; the probe
    /// sees only part of that (see there).
    private static let graceHeadroomNanoseconds: UInt64 = 900_000_000

    /// One attempt of `deadlineSendsTerminateBeforeKilling`. Returns true once the run is settled:
    /// the TERM marker appeared with every check held, or a check failed (its recorded issue fails
    /// the test). Returns false only when every product check held, the timeout was reported
    /// correctly, another attempt remains, and the scenario was missed: the child never armed its
    /// trap, the armed child was starved through a correctly delivered grace, the grace was left
    /// unmeasured, or SIGTERM to SIGKILL crossed its bound while the runner withheld at least the
    /// headroom of that span.
    private func terminatesBeforeKilling(attempt: Int, lastAttempt: Bool) throws -> Bool {
        let dir = try scratch.directory()
        let marker = dir.appendingPathComponent("sigterm-seen")
        let ready = dir.appendingPathComponent("trap-installed")
        let children = ReadyGatedChildren(readyFile: ready)
        let gated = children.launcher(captureDirectory: try scratch.directory())
        // A launcher whose signals missed the child's group returns with this TERM-trapping child
        // looping for about ninety seconds, and the early returns below leave it there; end the
        // root the launch spawned so a red run does not leak it into the rest of the suite, behind
        // the recycled-pid guard `leftNoRoot` uses. A root the launcher ended is reaped, or a
        // zombie the signal cannot touch, so this changes nothing on a green run.
        defer {
            if let root = children.spawnedPID, root > 1, isOwnChild(root) {
                _ = Darwin.kill(root, SIGKILL)
            }
        }
        // Started before the launch so it is ticking through the grace; only lapses between the two
        // signals count. Stopped on every path, including a failed `#require`.
        let runner = DeschedulingProbe()
        defer { runner.stop() }
        // The readiness marker holds the child's pid, written after the trap, so it is both the
        // gate and the file `launchBounded` reads to end a child its watchdog gave up on.
        let error = #expect(throws: AppleScriptRunner.TimeoutError.self) {
            _ = try launchBounded(ScriptInvocation(
                executablePath: "/bin/sh",
                arguments: ["-c",
                            #"trap 'printf t > "$0"; exit 0' TERM; echo $$ > "$1"; "#
                            + #"i=0; while [ $i -lt 450 ]; do sleep 0.2; i=$((i+1)); done"#,
                            marker.path, ready.path],
                delivery: .timed(seconds: 2)),
                                  pidFile: ready, seconds: 120, using: gated)
        }
        if children.exitedBeforeReady {
            Issue.record("""
                the child exited before it published its readiness marker, so the scenario never \
                began
                """)
            return true
        }
        let seconds = try #require(error).seconds
        let timeoutReported = seconds == 2
        #expect(timeoutReported,
                "the timeout must report the configured two seconds, not \(seconds)")

        // Product check, on every attempt: the grace's length, from the launcher's own turns on its
        // own clock. Every observation between SIGTERM and SIGKILL but the last (SIGKILL's own
        // check) is a turn of the grace's pause. The pause checks its deadline before each
        // observation, so the first stamp falls after that deadline was set and every stamp but the
        // last before it: the second-to-last is under a second after the first under any load,
        // because a stall can only drop turns from the span. A launcher always sends both signals
        // on a timeout, so a missing pair is itself the regression. Fewer than three turns leave
        // the length unmeasured, which a correct launcher shows only when the runner withheld its
        // thread for most of the grace: a missed scenario, not a pass. This rests on one
        // observation per pause turn, as the launcher makes; a launcher restructured otherwise
        // needs it revisited.
        let timeline = children.timeline
        guard let termTurn = timeline.firstIndex(where: { $0.signal == SIGTERM }),
              let killTurn = timeline.firstIndex(where: { $0.signal == SIGKILL }),
              termTurn < killTurn else {
            Issue.record("the timeout did not send SIGTERM and then SIGKILL to the child's group")
            return true
        }

        // Product check, on every attempt: SIGKILL waited out the whole grace. The SIGTERM turn is
        // stamped before that signal is sent; the launcher sets its pause deadline once the signal
        // call has returned, with the same `DispatchTime` arithmetic as here; and its SIGKILL turn
        // comes only after a check that found that deadline passed. So this holds under any load,
        // whether or not the trap fired, and a grace shortened by more than one pause turn (its
        // 10 ms poll plus that poll's lateness) fails it at once.
        let graceStart = timeline[termTurn].at
        let graceEnd = timeline[killTurn].at
        let waitedOut = graceEnd >= graceStart + Self.terminateGraceSeconds
        let waited = Double(graceEnd.uptimeNanoseconds) - Double(graceStart.uptimeNanoseconds)
        #expect(waitedOut, """
            the timeout's SIGKILL must wait out the full one-second TERM grace (it came \
            \(String(format: "%.3f", waited / 1_000_000_000)) s after SIGTERM)
            """)
        if !waitedOut { return true }

        let grace = timeline[(termTurn + 1)..<killTurn].dropLast().map { $0.at }
        if grace.count >= 3 {
            let first = grace[0]
            let penultimate = grace[grace.count - 2]
            let ended = penultimate < first + Self.terminateGraceSeconds
            let span = Double(penultimate.uptimeNanoseconds)
                - Double(first.uptimeNanoseconds)
            #expect(ended, """
                the TERM grace must end at one second (still observing after \
                \(String(format: "%.3f", span / 1_000_000_000)) s)
                """)
            if !ended { return true }
        }

        // Product check, on every attempt: SIGTERM to SIGKILL ends inside its bound, on the
        // decorator's `CLOCK_UPTIME_RAW` stamps, the probe's clock. The checks above cannot see a
        // wait outside the pause's observing turns; this bound can. It is the one grace check a
        // stall can make a correct launcher fail, and a correct launcher crosses it only when the
        // runner withholds at least the headroom (`graceHeadroomNanoseconds`) of the span, so a
        // crossing is a missed scenario when the probe saw at least that much withheld inside the
        // span, as every other bound in this file is set aside, and never on the last attempt. A
        // launcher that waits too long, on a runner that is running the test, fails at once.
        let sent = children.signals
        guard let termSentAt = sent.first(where: { $0.number == SIGTERM })?.at,
              let killSentAt = sent.first(where: { $0.number == SIGKILL })?.at,
              termSentAt <= killSentAt else {
            Issue.record("the decorator did not stamp the timeout's SIGTERM and SIGKILL in order")
            return true
        }
        let signalSpan = killSentAt - termSentAt
        let spanBounded = signalSpan < Self.graceBoundNanoseconds
        let spanWithheld = runner.lapsed(from: termSentAt, to: killSentAt)
        let spanStalled = !spanBounded && !lastAttempt
            && spanWithheld >= Self.graceHeadroomNanoseconds
        let spanTiming = "\(DeschedulingProbe.seconds(signalSpan)) s from SIGTERM to SIGKILL, "
            + "\(DeschedulingProbe.seconds(spanWithheld)) s of it withheld by the runner"
        if !spanStalled {
            #expect(spanBounded, "SIGKILL must follow the TERM grace at once (\(spanTiming))")
            if !spanBounded { return true }
        }

        var missed: [String] = []
        if !waitForFile(marker) {
            // The trap never fired. Starvation explains that only if the launcher sent SIGTERM to
            // the child's own group, `kill` accepted it, and SIGKILL followed no sooner than the
            // grace. Anything else (SIGKILL first, no SIGTERM at all, a SIGTERM that missed the
            // child's group, or a shortened grace) is the regression, whether or not the child had
            // armed its trap: the record is the launcher's, not the child's. The order and the
            // grace on the launcher's turns were checked above; this adds the target group,
            // `kill`'s answer and the span on the decorator's stamps.
            let graceDelivered: Bool
            if let root = children.spawnedPID,
               let termIndex = sent.firstIndex(where: { $0.number == SIGTERM }),
               let killIndex = sent.firstIndex(where: { $0.number == SIGKILL }),
               termIndex < killIndex, sent[termIndex].delivered, sent[termIndex].group == root,
               let termAt = sent[termIndex].at, let killAt = sent[killIndex].at,
               killAt >= termAt {
                graceDelivered = killAt - termAt >= Self.terminateGraceNanoseconds
            } else {
                graceDelivered = false
            }
            guard graceDelivered else {
                Issue.record("""
                    SIGTERM was not delivered to the child's own group a full grace before SIGKILL
                    """)
                return true
            }
            if !leftNoRoot(children) { return true }
            if FileManager.default.fileExists(atPath: ready.path) {
                missed.append("""
                    the armed child was starved through the full TERM grace, so SIGKILL \
                    reached it before its trap ran
                    """)
            } else {
                missed.append("""
                    the child never armed its TERM trap \
                    (gate \(children.wasReadyAtSpawn ? "released on the marker" : "timed out"))
                    """)
            }
        }
        if grace.count < 3 {
            missed.append("""
                the launcher made \(grace.count) turns in the TERM grace, too few to measure it
                """)
        }
        if spanStalled {
            let headroom = DeschedulingProbe.seconds(Self.graceHeadroomNanoseconds)
            missed.append("""
                SIGTERM to SIGKILL crossed its bound while the runner withheld at least the \
                \(headroom) s headroom of that span (\(spanTiming))
                """)
        }
        if missed.isEmpty || !timeoutReported { return true }

        if !lastAttempt {
            print("""
                TERM-before-KILL scenario missed on attempt \(attempt) of 3: \
                \(missed.joined(separator: "; "))
                """)
            return false
        }
        Issue.record("""
            TERM-before-KILL scenario missed on all three attempts, though every product check \
            held on the last: \(missed.joined(separator: "; "))
            """)
        return true
    }

    /// The pid the child wrote, waiting briefly for the write to land. `nil` if it never did.
    private func publishedPid(at url: URL, within seconds: TimeInterval = 5) -> pid_t? {
        pollUntil(seconds) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Whether `pid` is still a DIRECT CHILD of this process, asked of the kernel rather than
    /// assumed from a file this test read. Guards the one `SIGKILL` this suite sends at a pid it
    /// did not obtain from a live handle: if the child has already exited and its number been
    /// recycled, the replacement is almost certainly not parented to this process, so the signal
    /// is withheld instead of landing on an unrelated one.
    private func isOwnChild(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_eproc.e_ppid == getpid()
    }

    /// Ends a test-owned child that a FAILING assertion path would otherwise leave running: the
    /// pid it published, if it is still a direct child of this process (`isOwnChild` — the same
    /// recycled-pid guard `launchBounded` applies). A child the launcher ended correctly has
    /// been reaped and is no longer anyone's child, so this signals nothing on a green run.
    private func reapIfLeaked(_ pidFile: URL) {
        guard let pid = publishedPid(at: pidFile, within: 0.2), pid > 1, isOwnChild(pid) else {
            return
        }
        _ = Darwin.kill(pid, SIGKILL)
    }

    /// Whether the root a gated launch spawned is gone, for an attempt whose child never reached
    /// its scenario (no pid, or no TERM marker). Such an attempt is a missed scenario only if the
    /// launch left nothing running: the root is the launcher's own child, whatever the child's
    /// files say, and a launcher whose signals missed it leaves it alive. Records the failure when
    /// it is not gone, and ends that root itself (the same recycled-pid guard as `reapIfLeaked`),
    /// since no file names it. Thirty seconds, for the reason the exit checks on a published pid
    /// give.
    private func leftNoRoot(_ children: ReadyGatedChildren) -> Bool {
        guard let root = children.spawnedPID else {
            Issue.record("the gated launcher never spawned the child")
            return false
        }
        if hasExited(root, within: 30) { return true }
        Issue.record("the child missed its scenario and was still running after the deadline")
        if root > 1, isOwnChild(root) { _ = Darwin.kill(root, SIGKILL) }
        return false
    }

    /// Whether `pid` is gone. `kill(pid, 0)` asks the kernel about liveness without sending a
    /// signal; `ESRCH` is "no such process", which for a child this process already reaped is
    /// the answer as soon as it dies.
    private func hasExited(_ pid: pid_t, within seconds: TimeInterval = 5) -> Bool {
        pollUntil(seconds) { Darwin.kill(pid, 0) != 0 && errno == ESRCH ? true : nil } ?? false
    }

    /// Whether `url` appeared within the window.
    private func waitForFile(_ url: URL, within seconds: TimeInterval = 5) -> Bool {
        pollUntil(seconds) { FileManager.default.fileExists(atPath: url.path) ? true : nil }
            ?? false
    }

    /// Retries `probe` until it answers or the window closes. A bounded poll rather than a
    /// sleep-and-hope: it returns the moment the state is observable, and it cannot hang.
    private func pollUntil<T>(_ seconds: TimeInterval, _ probe: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let answer = probe() { return answer }
            usleep(20_000)
        } while Date() < deadline
        return probe()
    }

    @Test("the deadline form fails to launch a missing interpreter without waiting it out")
    func deadlineFormLaunchFailure() throws {
        let error = #expect(throws: AppleScriptRunner.RunError.self) {
            _ = try launcher.launch(ScriptInvocation(
                executablePath: "/nonexistent/apple-cli-launcher-test", arguments: [],
                delivery: .timed(seconds: 30)))
        }
        guard case .launchFailed = try #require(error) else {
            Issue.record("expected launchFailed"); return
        }
    }

    @Test("the capture files are unlinked, so a timed run leaves no named temp behind")
    func deadlineFormLeavesNoNamedTemps() throws {
        // A private capture directory rather than a filtered scan of the shared temp root: only
        // this launcher writes here, so "the directory is empty" is an exact statement about
        // this invocation instead of a set-difference that any concurrent process — or another
        // test's timed launch — could land inside.
        let captures = try scratch.directory()
        let scoped = OsascriptLauncher(captureDirectory: captures)
        _ = try scoped.launch(ScriptInvocation(executablePath: "/bin/echo", arguments: ["x"],
                                               delivery: .timed(seconds: 30)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: captures.path).isEmpty)
    }

    @Test("a run that BLOWS the deadline also leaves no named temp behind")
    func deadlineTimeoutLeavesNoNamedTemps() throws {
        // The branch the unlink design actually exists for: the child is still holding both
        // descriptors when `TimeoutError` is thrown, so nothing on this side gets to tidy up.
        // Because the files were unlinked before launch, there is still no name to leak.
        let captures = try scratch.directory()
        let scoped = OsascriptLauncher(captureDirectory: captures)
        #expect(throws: AppleScriptRunner.TimeoutError.self) {
            _ = try scoped.launch(ScriptInvocation(executablePath: "/bin/sleep",
                                                   arguments: ["30"],
                                                   delivery: .timed(seconds: 0.05)))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: captures.path).isEmpty)
    }

    /// 256 KiB — four times the ~64 KiB pipe buffer — written to STDERR before a single byte
    /// reaches stdout, with stdout held open throughout. A launcher that drains stdout to EOF
    /// first can never finish this child: the child blocks writing stderr, so it never exits,
    /// so stdout never reaches EOF, so the parent never gets to read stderr.
    ///
    /// Fixed literal, no interpolation; the pid file arrives as `$0` through argv so
    /// `launchBounded` can reap the child if the launch is abandoned. `printf` and `echo` are
    /// shell builtins, so this forks nothing.
    ///
    /// The trailing `cat` is what makes the stdin-form caller deterministic: it consumes the
    /// script instead of racing the parent's write against its own exit. Free for the piped
    /// caller, whose stdin is `/dev/null`, so `cat` returns at once.
    private static let floodStderrThenStdout = #"""
        echo $$ > "$0"; i=0; while [ $i -lt 256 ]; do printf '%1024s' '' >&2; i=$((i+1)); done; printf ok; cat >/dev/null
        """#

    /// The mirror image: 256 KiB on STDOUT *before* the child reads a byte of stdin, then a
    /// `cat` that discards whatever arrives. A launcher that writes the whole script to stdin
    /// before it starts draining wedges on this child in both directions at once — the parent
    /// blocked writing stdin that nobody is reading, the child blocked writing stdout that
    /// nobody is reading. Same argv discipline: the pid file is `$0`.
    private static let floodStdoutThenReadStdin = #"""
        echo $$ > "$0"; i=0; while [ $i -lt 256 ]; do printf '%1024s' ''; i=$((i+1)); done; cat >/dev/null
        """#

    /// Exits without reading stdin at all, so a script larger than the pipe buffer cannot be
    /// delivered and the write end sees EPIPE.
    private static let exitWithoutReadingStdin = #"""
        echo $$ > "$0"; exit 0
        """#

    @Test("the piped form drains a child that fills stderr while stdout stays open")
    func pipedLargeStderrDoesNotDeadlock() throws {
        let pidFile = try scratch.directory().appendingPathComponent("pid")
        let outcome = try launchBounded(ScriptInvocation(
            executablePath: "/bin/sh",
            arguments: ["-c", Self.floodStderrThenStdout, pidFile.path]), pidFile: pidFile)
        #expect(outcome.terminationStatus == 0)
        #expect(String(decoding: outcome.standardOutput, as: UTF8.self) == "ok")
        #expect(outcome.standardError.count == 256 * 1024)
    }

    @Test("the stdin form drains a child that fills stderr while stdout stays open")
    func stdinFormLargeStderrDoesNotDeadlock() throws {
        let pidFile = try scratch.directory().appendingPathComponent("pid")
        let outcome = try launchBounded(ScriptInvocation(
            executablePath: "/bin/sh",
            arguments: ["-c", Self.floodStderrThenStdout, pidFile.path],
            delivery: .stdin(script: "unread")), pidFile: pidFile)
        #expect(outcome.terminationStatus == 0)
        #expect(String(decoding: outcome.standardOutput, as: UTF8.self) == "ok")
        #expect(outcome.standardError.count == 256 * 1024)
    }

    @Test("the stdin form interleaves output and delivery so a big script cannot wedge either pipe")
    func stdinFormDrainsBeforeWriting() throws {
        // Input and output must make progress together in the launcher. 256 KiB of script — four times the pipe
        // buffer — against a child that answers with 256 KiB of its own before it reads any of
        // it. Write-then-drain deadlocks here; drain-then-write completes.
        let pidFile = try scratch.directory().appendingPathComponent("pid")
        let outcome = try launchBounded(ScriptInvocation(
            executablePath: "/bin/sh",
            arguments: ["-c", Self.floodStdoutThenReadStdin, pidFile.path],
            delivery: .stdin(script: String(repeating: "a", count: 256 * 1024))), pidFile: pidFile)
        #expect(outcome.terminationStatus == 0)
        #expect(outcome.standardOutput.count == 256 * 1024)
        #expect(outcome.standardError.isEmpty)
    }

    @Test("a child that exits without reading stdin is a typed failure, not a killed process")
    func stdinFormSurvivesAChildThatNeverReads() throws {
        // EPIPE on the stdin write. With the plain `FileHandle.write(_:)` this raised an
        // Objective-C exception Swift cannot catch — or, without `F_SETNOSIGPIPE`, delivered
        // SIGPIPE and killed the whole process. Either way the run ended with no diagnosable
        // failure. The script is deliberately larger than the ~64 KiB pipe buffer, so the write
        // cannot complete into the buffer of a child that has already gone.
        let pidFile = try scratch.directory().appendingPathComponent("pid")
        let error = #expect(throws: AppleScriptRunner.RunError.self) {
            _ = try launchBounded(ScriptInvocation(
                executablePath: "/bin/sh",
                arguments: ["-c", Self.exitWithoutReadingStdin, pidFile.path],
                delivery: .stdin(script: String(repeating: "a", count: 256 * 1024))),
                              pidFile: pidFile)
        }
        guard case .launchFailed = try #require(error) else {
            Issue.record("expected launchFailed"); return
        }
        // Not `scriptFailed`: the child exited 0, and reporting that as success would hand the
        // caller an empty result for a script the interpreter never saw.
        #expect(try #require(error).description.hasPrefix("osascript launch failed:"))
    }

    /// Closes stdin and then lives on, holding stdout and stderr open the whole time. `exec 0<&-`
    /// is the shell's own close, so the EPIPE arrives while the child is very much alive — the case
    /// a delivery failure must not simply wait out. Used by both the untimed and the timed
    /// failed-delivery tests.
    ///
    /// It creates `$1` once stdin is closed, so the gated launcher can hold its first write until
    /// the EPIPE is certain. It lingers about ninety seconds, so a launcher that waits for EOF
    /// lands far outside a bound measured from the gated stamp, and a launcher that returns without
    /// ending it still fails the thirty-second exit check. It lingers in one-second steps rather
    /// than one long `sleep`, so a SIGKILL that reaches only `sh` (the leak reaper's, or the
    /// watchdog's) orphans at most a one-second `sleep`, and a child orphaned outright still ends
    /// on its own. Fixed literal; both paths arrive through argv (`$0`, `$1`).
    private static let closesStdinPublishesThenLingers = #"""
        echo $$ > "$0"; exec 0<&-; : > "$1"; i=0; while [ $i -lt 90 ]; do sleep 1; i=$((i+1)); done
        """#

    @Test("a failed delivery ends the child rather than waiting on one that lives on")
    func stdinFormEndsAChildThatOutlivesTheFailedDelivery() throws {
        // EPIPE like `stdinFormSurvivesAChildThatNeverReads`, but from a child that is STILL
        // RUNNING and still holding both output descriptors. Collecting the drains first would
        // block until the child felt like exiting — about ninety seconds here, unbounded in
        // general, and this form carries no deadline — turning a diagnosed failure into a hang. The
        // launcher must terminate, escalate, and reap before it collects.
        //
        // The fifteen-second bound runs from the decorator's stamp, not from before the spawn: the
        // child creates `$1` after closing stdin and the gated launcher holds its first write until
        // then, so the bound measures the EPIPE, the half-second TERM grace, SIGKILL and the reap,
        // not `sh` start-up or any time the runner withheld the process before the child closed
        // stdin. The child lingers ninety seconds, so a launcher that waited for EOF cannot meet
        // the bound. The watchdog is 120 seconds so it covers the sixty-second gate.
        //
        // A `DeschedulingProbe` records how long the runner withheld the process inside the
        // measured window. A crossed bound is a missed scenario when the runner withheld at least
        // the headroom, or when the gate timed out before the child closed stdin (so start-up was
        // measured again); such an attempt is printed and re-run, at most twice. Neither condition
        // depends on the launcher: the probe never observes it, and the gate releases before the
        // launcher acts, so a launcher that waits on the child crosses the bound with neither and
        // fails at once. An attempt whose bound was set aside can only be re-run, never pass; the
        // last attempt applies the bound whatever happened, and the classification and exit checks
        // apply on every attempt.
        for attempt in 1...3 {
            if try endsChildAfterFailedDelivery(attempt: attempt, lastAttempt: attempt == 3) {
                return
            }
        }
        Issue.record("failed-delivery scenario: the last attempt returned without a verdict")
    }

    /// The failed-delivery tests' elapsed bound, from the gated stamp to `launch` returning, shared
    /// by the TERM-ignoring variant. Well inside the ninety-second linger, and the TERM-ignoring
    /// child lives about as long on its own: a launcher that waited for EOF could not be back.
    private static let failedDeliveryBoundNanoseconds: UInt64 = 15_000_000_000

    /// How far `failedDeliveryBoundNanoseconds` sits above the launcher's own worst case on this
    /// path: the half-second TERM grace and the one-second reap wait
    /// (`OwnedScriptProcess.cancel(timeout:)`) after an EPIPE on the first write, which is
    /// immediate because the child closed stdin before the gate released. That is 1.5 seconds in
    /// all, leaving 13.5 of the fifteen-second bound. A correct launcher crosses the bound only if
    /// the runner withholds at least this much of the measured window from the launcher's thread;
    /// `DeschedulingProbe` sees only part of that (see there).
    private static let failedDeliveryHeadroomNanoseconds: UInt64 = 13_500_000_000

    /// One attempt of `stdinFormEndsAChildThatOutlivesTheFailedDelivery`. Returns true after a
    /// failed product check (its recorded issues fail the test) or after asserting the scenario;
    /// returns false only when every product check that applied held, another attempt remains, and
    /// the bound was crossed in a missed scenario: the runner withheld at least the headroom from
    /// the process, or the gate timed out before the child closed stdin.
    private func endsChildAfterFailedDelivery(attempt: Int, lastAttempt: Bool) throws -> Bool {
        let dir = try scratch.directory()
        let pidFile = dir.appendingPathComponent("pid")
        let stdinClosed = dir.appendingPathComponent("stdin-closed")
        // A launcher that returned without ending the child would leave it lingering into the tests
        // that follow; end it here so a red run does not leak it.
        defer { reapIfLeaked(pidFile) }
        let children = ReadyGatedChildren(readyFile: stdinClosed)
        let gated = children.launcher(captureDirectory: try scratch.directory())
        // Started before the launch so it is ticking when the gate releases; only lapses inside the
        // measured window count. Stopped on every path, including a failed `#require`.
        let runner = DeschedulingProbe()
        defer { runner.stop() }
        let error = #expect(throws: AppleScriptRunner.RunError.self) {
            _ = try launchBounded(ScriptInvocation(
                executablePath: "/bin/sh",
                arguments: ["-c", Self.closesStdinPublishesThenLingers, pidFile.path,
                            stdinClosed.path],
                delivery: .stdin(script: String(repeating: "a", count: 256 * 1024))),
                                  pidFile: pidFile, seconds: 120, using: gated)
        }
        let returnedAt = try #require(ReadyGatedChildren.uptimeNanoseconds())
        if children.exitedBeforeReady {
            Issue.record("the child exited before it closed stdin, so the scenario never began")
            return true
        }
        guard case .launchFailed = try #require(error) else {
            Issue.record("expected launchFailed"); return true
        }
        let spawnedAt = try #require(children.spawnedAt,
                                     "the gated launcher never spawned the child")

        // Product checks, on every attempt. The bound is set aside, and the attempt re-run, only
        // when it was crossed in a missed scenario, and never on the last attempt.
        let ordered = spawnedAt <= returnedAt
        let elapsed = ordered ? returnedAt - spawnedAt : 0
        let bounded = ordered && elapsed < Self.failedDeliveryBoundNanoseconds
        let withheld = runner.lapsed(from: spawnedAt, to: returnedAt)
        var missed: [String] = []
        if withheld >= Self.failedDeliveryHeadroomNanoseconds {
            let headroom = DeschedulingProbe.seconds(Self.failedDeliveryHeadroomNanoseconds)
            missed.append("the runner withheld at least the \(headroom) s headroom")
        }
        if !children.wasReadyAtSpawn {
            missed.append("the gate timed out before the child closed stdin")
        }
        let setAside = ordered && !bounded && !lastAttempt && !missed.isEmpty
        let timing = "\(DeschedulingProbe.seconds(elapsed)) s from the gated stamp, "
            + "\(DeschedulingProbe.seconds(withheld)) s of it withheld by the runner"
        if !setAside {
            #expect(bounded,
                    "the failed delivery waited on the child instead of ending it (\(timing))")
        }
        let pid = try #require(publishedPid(at: pidFile), "the child never published its pid")
        // Thirty seconds: a child the launcher could not reap within its one-second wait is reaped
        // later and answers `kill(pid, 0)` until then. The child lingers ninety seconds, so a
        // launcher that never ended it still fails this check.
        let exited = hasExited(pid, within: 30)
        #expect(exited, "the child outlived the failure it caused")
        if !setAside || !exited { return true }
        print("""
            failed-delivery scenario missed on attempt \(attempt) of 3: the bound was crossed \
            (\(timing)) and \(missed.joined(separator: "; "))
            """)
        return false
    }

    /// `closesStdinPublishesThenLingers`, but deaf to SIGTERM and looping for about ninety seconds
    /// unless killed (450 turns of `sleep 0.2`, so a child a red run leaves behind still ends) —
    /// the child the failed-delivery teardown's SIGKILL branch exists for. `exec 0<&-` closes stdin
    /// so the parent's write takes EPIPE while the child is alive, and the loop keeps `sh` from
    /// exec'ing away its own trap. It creates `$1` once stdin is closed, after the trap is armed,
    /// so the gated launcher holds its first write until the EPIPE is certain and only SIGKILL can
    /// end the child. Fixed literal; both paths arrive through argv.
    private static let closesStdinIgnoresTermAndLingers = #"""
        trap '' TERM; echo $$ > "$0"; exec 0<&-; : > "$1"
        i=0; while [ $i -lt 450 ]; do sleep 0.2; i=$((i+1)); done
        """#

    @Test("a failed delivery escalates to SIGKILL when the lingering child ignores SIGTERM")
    func stdinFormEscalatesPastAnIgnoredTerminateAfterAFailedDelivery() throws {
        // `stdinFormEndsAChildThatOutlivesTheFailedDelivery` proves the teardown runs, but its
        // child dies on SIGTERM, so the SIGKILL branch of that teardown never executed under test.
        // Delete the escalation and that test stays green while this child lives on for about
        // ninety seconds, reparented to launchd, still holding both output pipes.
        //
        // It runs as that sibling does: the child creates `$1` once stdin is closed, the gated
        // launcher holds its first write until then, and the fifteen-second bound runs from the
        // decorator's stamp, so neither `sh` start-up nor time the runner withheld the process
        // before the child closed stdin counts against the launcher. A crossed bound is a missed
        // scenario when a `DeschedulingProbe` saw the runner withhold at least the headroom, or
        // when the gate timed out before the child closed stdin; such an attempt is printed and
        // re-run, at most twice, can never pass, and the last attempt applies the bound whatever
        // happened. The classification and exit checks apply on every attempt. The exit window is
        // thirty seconds, for the sibling's reason; the child loops for about ninety seconds unless
        // killed, so a missing escalation still fails it. The watchdog is 120 seconds so it covers
        // the sixty-second gate.
        for attempt in 1...3 {
            if try escalatesAfterFailedDelivery(attempt: attempt, lastAttempt: attempt == 3) {
                return
            }
        }
        Issue.record("""
            failed-delivery escalation scenario: the last attempt returned without a verdict
            """)
    }

    /// One attempt of `stdinFormEscalatesPastAnIgnoredTerminateAfterAFailedDelivery`. Returns true
    /// after a failed product check (its recorded issues fail the test) or after asserting the
    /// scenario; returns false only when every product check that applied held, another attempt
    /// remains, and the bound was crossed in a missed scenario: the runner withheld at least the
    /// headroom from the process, or the gate timed out before the child closed stdin.
    private func escalatesAfterFailedDelivery(attempt: Int, lastAttempt: Bool) throws -> Bool {
        let dir = try scratch.directory()
        let pidFile = dir.appendingPathComponent("pid")
        let stdinClosed = dir.appendingPathComponent("stdin-closed")
        // If the escalation IS missing, the launcher returns (launchFailed after its graces) with
        // the TERM-deaf child still alive — `launchBounded` only reaps on a hang. Reap it here so a
        // red run does not leak a looping shell into the rest of the suite for ninety seconds.
        defer { reapIfLeaked(pidFile) }
        let children = ReadyGatedChildren(readyFile: stdinClosed)
        let gated = children.launcher(captureDirectory: try scratch.directory())
        // Started before the launch so it is ticking when the gate releases; only lapses inside the
        // measured window count. Stopped on every path, including a failed `#require`.
        let runner = DeschedulingProbe()
        defer { runner.stop() }
        let error = #expect(throws: AppleScriptRunner.RunError.self) {
            _ = try launchBounded(ScriptInvocation(
                executablePath: "/bin/sh",
                arguments: ["-c", Self.closesStdinIgnoresTermAndLingers, pidFile.path,
                            stdinClosed.path],
                delivery: .stdin(script: String(repeating: "a", count: 256 * 1024))),
                                  pidFile: pidFile, seconds: 120, using: gated)
        }
        let returnedAt = try #require(ReadyGatedChildren.uptimeNanoseconds())
        if children.exitedBeforeReady {
            Issue.record("the child exited before it closed stdin, so the scenario never began")
            return true
        }
        guard case .launchFailed = try #require(error) else {
            Issue.record("expected launchFailed"); return true
        }
        let spawnedAt = try #require(children.spawnedAt,
                                     "the gated launcher never spawned the child")

        // Product checks, on every attempt. Bounded by the ladder: the EPIPE at once, 0.5s after
        // SIGTERM, then at most 1s for the reap after SIGKILL. The bound is set aside, and the
        // attempt re-run, only when it was crossed in a missed scenario, and never on the last
        // attempt.
        let ordered = spawnedAt <= returnedAt
        let elapsed = ordered ? returnedAt - spawnedAt : 0
        let bounded = ordered && elapsed < Self.failedDeliveryBoundNanoseconds
        let withheld = runner.lapsed(from: spawnedAt, to: returnedAt)
        var missed: [String] = []
        if withheld >= Self.failedDeliveryHeadroomNanoseconds {
            let headroom = DeschedulingProbe.seconds(Self.failedDeliveryHeadroomNanoseconds)
            missed.append("the runner withheld at least the \(headroom) s headroom")
        }
        if !children.wasReadyAtSpawn {
            missed.append("the gate timed out before the child closed stdin")
        }
        let setAside = ordered && !bounded && !lastAttempt && !missed.isEmpty
        let timing = "\(DeschedulingProbe.seconds(elapsed)) s from the gated stamp, "
            + "\(DeschedulingProbe.seconds(withheld)) s of it withheld by the runner"
        if !setAside {
            #expect(bounded,
                    "the failed delivery waited on the child instead of ending it (\(timing))")
        }
        let pid = try #require(publishedPid(at: pidFile), "the child never published its pid")
        let exited = hasExited(pid, within: 30)
        #expect(exited, "the TERM-ignoring child outlived the failed delivery")
        if !setAside || !exited { return true }
        print("""
            failed-delivery escalation scenario missed on attempt \(attempt) of 3: the bound was \
            crossed (\(timing)) and \(missed.joined(separator: "; "))
            """)
        return false
    }

    @Test("under a deadline, a failed delivery is still reported at once — not as a timeout")
    func timedStdinFormReportsAFailedDeliveryImmediately() throws {
        // The mirror of the blocked-write case. The child closes stdin and lingers; the write takes
        // EPIPE at once. A launcher that consulted the delivery only after the deadline would sit
        // out the full deadline here and then call it a TIMEOUT — and a Mail caller would tell the
        // user to go hunting in Sent for a script the interpreter never saw. It must be
        // `launchFailed`, and it must be fast.
        //
        // As in the untimed failed-delivery test, the child creates `$1` once stdin is closed
        // (`closesStdinPublishesThenLingers`), the gated launcher holds its first write until then,
        // and the ten-second bound runs from the decorator's stamp, so `sh` start-up and any time
        // the process is withheld before the child is ready do not count against the launcher. A
        // crossed bound is a missed scenario when a `DeschedulingProbe` saw the runner withhold at
        // least the headroom, or when the gate timed out before the child closed stdin. Neither
        // depends on the launcher: the probe never observes it, and the gate releases before the
        // launcher acts. A missed attempt is printed and re-run, at most twice, and can never pass;
        // the last attempt applies the bound whatever happened.
        //
        // The deadline is not the subject, only what the launcher must not wait for, so it is 120
        // seconds: after an expired gate it starts while `sh` may still be starting, and a deadline
        // that fired before the child closed stdin would report TimeoutError against correct code.
        // A launcher that sat the deadline out still fails, on the error type, the bound or the
        // watchdog: the child holds its pipes for ninety seconds, nine times the bound. The exit
        // window is thirty seconds, for the untimed test's reason, and the watchdog is 120 seconds
        // so it covers the sixty-second gate.
        for attempt in 1...3 {
            if try reportsFailedDeliveryAtOnce(attempt: attempt, lastAttempt: attempt == 3) {
                return
            }
        }
        Issue.record("timed failed-delivery scenario: the last attempt returned without a verdict")
    }

    /// The timed failed-delivery test's elapsed bound, from the gated stamp to `launch` returning.
    /// Far inside the child's ninety-second linger and the 120-second deadline.
    private static let immediateFailureBoundNanoseconds: UInt64 = 10_000_000_000

    /// How far `immediateFailureBoundNanoseconds` sits above the launcher's own worst case on this
    /// path: the half-second TERM grace and the one-second reap wait
    /// (`OwnedScriptProcess.cancel(timeout:)`) after an EPIPE on the first write, which is
    /// immediate because the child closed stdin before the gate released.
    private static let immediateFailureHeadroomNanoseconds: UInt64 = 8_500_000_000

    /// One attempt of `timedStdinFormReportsAFailedDeliveryImmediately`. Returns true after a
    /// failed product check (its recorded issues fail the test) or after asserting the scenario;
    /// returns false only when every product check that applied held, another attempt remains, and
    /// the bound was crossed in a missed scenario: the runner withheld at least the headroom from
    /// the process, or the gate timed out before the child closed stdin.
    private func reportsFailedDeliveryAtOnce(attempt: Int, lastAttempt: Bool) throws -> Bool {
        let dir = try scratch.directory()
        let pidFile = dir.appendingPathComponent("pid")
        let stdinClosed = dir.appendingPathComponent("stdin-closed")
        defer { reapIfLeaked(pidFile) }
        let children = ReadyGatedChildren(readyFile: stdinClosed)
        let gated = children.launcher(captureDirectory: try scratch.directory())
        // Started before the launch so it is ticking when the gate releases; only lapses inside the
        // measured window count. Stopped on every path, including a failed `#require`.
        let runner = DeschedulingProbe()
        defer { runner.stop() }
        let error = #expect(throws: AppleScriptRunner.RunError.self) {
            _ = try launchBounded(ScriptInvocation(
                executablePath: "/bin/sh",
                arguments: ["-c", Self.closesStdinPublishesThenLingers, pidFile.path,
                            stdinClosed.path],
                delivery: .timedStdin(script: String(repeating: "a", count: 256 * 1024),
                                      seconds: 120)),
                                  pidFile: pidFile, seconds: 120, using: gated)
        }
        let returnedAt = try #require(ReadyGatedChildren.uptimeNanoseconds())
        if children.exitedBeforeReady {
            Issue.record("the child exited before it closed stdin, so the scenario never began")
            return true
        }
        guard case .launchFailed = try #require(error) else {
            Issue.record("expected launchFailed, not a timeout"); return true
        }
        let spawnedAt = try #require(children.spawnedAt,
                                     "the gated launcher never spawned the child")

        // Product checks, on every attempt. The bound is set aside, and the attempt re-run, only
        // when it was crossed in a missed scenario, and never on the last attempt.
        let ordered = spawnedAt <= returnedAt
        let elapsed = ordered ? returnedAt - spawnedAt : 0
        let bounded = ordered && elapsed < Self.immediateFailureBoundNanoseconds
        let withheld = runner.lapsed(from: spawnedAt, to: returnedAt)
        var missed: [String] = []
        if withheld >= Self.immediateFailureHeadroomNanoseconds {
            let headroom = DeschedulingProbe.seconds(Self.immediateFailureHeadroomNanoseconds)
            missed.append("the runner withheld at least the \(headroom) s headroom")
        }
        if !children.wasReadyAtSpawn {
            missed.append("the gate timed out before the child closed stdin")
        }
        let setAside = ordered && !bounded && !lastAttempt && !missed.isEmpty
        let timing = "\(DeschedulingProbe.seconds(elapsed)) s from the gated stamp, "
            + "\(DeschedulingProbe.seconds(withheld)) s of it withheld by the runner"
        if !setAside {
            #expect(bounded, """
                the delivery failure waited for the deadline instead of being reported (\(timing))
                """)
        }
        let pid = try #require(publishedPid(at: pidFile), "the child never published its pid")
        let exited = hasExited(pid, within: 30)
        #expect(exited, "the child outlived the failure it caused")
        if !setAside || !exited { return true }
        print("""
            timed failed-delivery scenario missed on attempt \(attempt) of 3: the bound was \
            crossed (\(timing)) and \(missed.joined(separator: "; "))
            """)
        return false
    }

    @Test("the bound covers the output drain: a descendant holding the pipe past exit is a timeout")
    func timedStdinFormBoundsTheDrainAfterExit() throws {
        // Child exit is not EOF. This child reads the script, backgrounds a `sleep` that inherits
        // stdout and stderr, and exits 0 at once. A bound that covered only the wait for
        // termination would now sit in `collected()` until the descendant let go — twenty seconds
        // here, unbounded for a real `do shell script` daemon. The deadline must expire in the
        // DRAIN and surface as `TimeoutError`, well before the descendant exits. Two seconds, from
        // the gate's release, leave the child time to read EOF and reach `exit 0` inside the
        // deadline — a deadline that expires in the wake loop instead would throw the same error
        // from the wrong place and prove nothing about the drain. The descendant publishes its own
        // pid (`$!` → `$1`) and is short-lived on purpose; the test then waits for it to be gone,
        // so it cannot outlive the test even if group cleanup regresses.
        //
        // The two-second deadline (the subject) is gated on the root's pid, which it writes before
        // `cat`, so `sh` start-up does not run inside it; the descendant's pid cannot be the gate,
        // because it is written only after stdin EOF, which a held launcher has not delivered. The
        // elapsed bound is ten seconds from the gated stamp. A correct run takes about three
        // seconds, because it always waits out the full one-second TERM grace after the deadline,
        // so it sits about seven below the bound; a drain-to-EOF regression waits for the
        // descendant's twenty seconds, ten above it. The teardown wait for the descendant is thirty
        // seconds and the watchdog 120, which covers the sixty-second gate.
        //
        // The launcher's own worst case on this path is four seconds (the two-second deadline, the
        // one-second TERM grace and the one-second reap wait), so a starved runner that withholds
        // more than the remaining six seconds can push a correct run past the bound. A wider bound
        // would need a longer-lived descendant to stay below a drain-to-EOF regression, and the
        // longest stalls would still cross it. Instead a `DeschedulingProbe` records how long the
        // runner withheld the process inside the measured window, and a crossed bound with at least
        // the six-second headroom withheld is a missed scenario. So is an attempt with no
        // descendant pid, or one whose root exit was not seen inside the deadline and before
        // cleanup began. A missed attempt is printed and re-run, at most twice; it can never pass,
        // and the last attempt applies every check whatever the probe saw. An attempt missed on the
        // descendant or the exit also says whether the readiness gate released on the pid file or
        // timed out. The probe never observes the launcher, so a drain that waits for the
        // descendant on a host that is running the test crosses the bound without a lapse and fails
        // at once. A failed product check on any attempt fails the test.
        for attempt in 1...3 {
            if try boundsTheDrainAfterExit(attempt: attempt, lastAttempt: attempt == 3) { return }
        }
        Issue.record("drain-timeout scenario: the last attempt returned without a verdict")
    }

    /// The drain test's elapsed bound, from the gated stamp to `launch` returning.
    private static let drainBoundNanoseconds: UInt64 = 10_000_000_000

    /// How far `drainBoundNanoseconds` sits above the launcher's own worst case on this path: the
    /// two-second deadline expiring in the drain, then the timeout cleanup's one-second TERM grace
    /// and one-second reap wait (`OwnedScriptProcess.cancel(timeout:)`). A correct launcher crosses
    /// the bound only if the runner withholds at least this much of the measured window from the
    /// launcher's thread; `DeschedulingProbe` sees only part of that (see there).
    private static let drainHeadroomNanoseconds: UInt64 = 6_000_000_000

    /// The tenth of a second the drain's scenario check keeps in hand where it infers, from the
    /// decorator's stamp of the root's exit, that the launcher saw that exit before its deadline.
    /// The stamp and the deadline read one clock; the margin covers the gap between the stamp and
    /// the launcher's next deadline check, with the figure and the reason of
    /// `OwnedProcessCleanupTests.drainScenarioMargin`.
    private static let drainScenarioMargin: UInt64 = 100_000_000

    /// Nanoseconds as seconds with two decimals, for the drain check's offsets from the gated
    /// stamp. `DeschedulingProbe.seconds` keeps one decimal, which would print an exit stamped 1.95
    /// seconds after the gated stamp as "1.9 s" beside "not seen by 1.9 s", and an exit in the
    /// upper half of the margin band as "2.0 s", the same as a late one.
    private static func offsetSeconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.2f", Double(nanoseconds) / 1_000_000_000)
    }

    /// One attempt of `timedStdinFormBoundsTheDrainAfterExit`. Returns true after a failed product
    /// check (its recorded issues fail the test), after a descendant that did not stop, or after
    /// asserting the scenario; returns false only when every product check that applied held,
    /// another attempt remains, and the scenario was missed: no descendant pid, the root's exit not
    /// seen before cleanup and under 1.9 seconds after the gated stamp (`drainScenarioMargin` short
    /// of the deadline), or the bound crossed while the runner withheld at least the headroom from
    /// the process.
    private func boundsTheDrainAfterExit(attempt: Int, lastAttempt: Bool) throws -> Bool {
        let dir = try scratch.directory()
        let pidFile = dir.appendingPathComponent("pid")
        let descendantPidFile = dir.appendingPathComponent("descendant-pid")
        let children = ReadyGatedChildren(readyFile: pidFile)
        let gated = children.launcher(captureDirectory: try scratch.directory())
        // Started before the launch so it is ticking when the gate releases; only lapses inside the
        // measured window count. Stopped on every path, including a failed `#require`.
        let runner = DeschedulingProbe()
        defer { runner.stop() }
        let error = #expect(throws: AppleScriptRunner.TimeoutError.self) {
            _ = try launchBounded(ScriptInvocation(
                executablePath: "/bin/sh",
                arguments: ["-c",
                            #"echo $$ > "$0"; cat >/dev/null; "#
                            + #"sleep 20 & echo $! > "$1"; exit 0"#,
                            pidFile.path, descendantPidFile.path],
                delivery: .timedStdin(script: "x", seconds: 2)),
                                  pidFile: pidFile, seconds: 120, using: gated)
        }
        let returnedAt = try #require(ReadyGatedChildren.uptimeNanoseconds())
        if children.exitedBeforeReady {
            Issue.record("the child exited before publishing its pid, so the scenario never began")
            return true
        }
        let seconds = try #require(error).seconds
        let spawnedAt = try #require(children.spawnedAt,
                                     "the gated launcher never spawned the child")

        // Product checks, on every attempt. The bound is set aside, and the attempt re-run, only
        // when it was crossed while the probe saw the runner withhold at least the headroom inside
        // the measured window, and never on the last attempt.
        let timeoutReported = seconds == 2
        let ordered = spawnedAt <= returnedAt
        let elapsed = ordered ? returnedAt - spawnedAt : 0
        let bounded = ordered && elapsed < Self.drainBoundNanoseconds
        let withheld = runner.lapsed(from: spawnedAt, to: returnedAt)
        let runnerStalled = ordered && !bounded && !lastAttempt
            && withheld >= Self.drainHeadroomNanoseconds
        let timing = "\(DeschedulingProbe.seconds(elapsed)) s from the gated stamp, "
            + "\(DeschedulingProbe.seconds(withheld)) s of it withheld by the runner"
        #expect(timeoutReported,
                "the timeout must report the configured two seconds, not \(seconds)")
        if !runnerStalled {
            #expect(bounded, """
                the drain waited for the descendant instead of honouring the deadline (\(timing))
                """)
        }

        // Teardown on every attempt, not a product check: the descendant expires on its own after
        // twenty seconds, and this waits that out (failing if it never stops). One that did not
        // stop has already failed the test, so the attempt ends there instead of being re-run.
        let descendant = publishedPid(at: descendantPidFile)
        if let descendant {
            let stopped = hasExited(descendant, within: 30)
            #expect(stopped, "the bounded descendant should have stopped")
            if !stopped { return true }
        }
        if !timeoutReported || !(bounded || runnerStalled) { return true }

        // The scenario: the root exited inside the deadline, as the launcher itself saw before
        // cleanup's first signal (or with no cleanup signal at all), leaving the descendant on the
        // pipes, so the timeout fired in the drain rather than in the wait for exit.
        //
        // Before cleanup's first signal is not enough on its own. Cleanup checks the root again
        // just before that signal, so a root that exited after the deadline fired, in the wait for
        // exit, but before cleanup began is also stamped first, and would count as a drain timeout
        // it was not. The exit must also have been seen less than the two-second deadline after the
        // gated stamp. The launcher sets its deadline after that stamp, on `DispatchTime`, which
        // reads the uptime clock the exit is stamped on, so the two differ only by rounding (and a
        // host's sleep pauses both). What the check keeps in hand, `drainScenarioMargin`, as that
        // file's `insideDeadline` does, is for the gap between the decorator's exit stamp and the
        // launcher's next deadline check: the launch loop checks its deadline right after the
        // observation the decorator stamps, so a correct launcher spends microseconds there, and an
        // exit stamped under 1.9 seconds after the gated stamp was seen before the deadline, in the
        // launcher's main loop. A correct root exits milliseconds after stdin EOF, far inside that,
        // so an exit seen later is a missed scenario, printed and re-run, that fails only the last
        // attempt.
        //
        // A residual remains: the inference does not hold if the launcher's thread was withheld for
        // most of that tenth between the decorator's stamp and its deadline check. Both messages
        // give the exit's and the first signal's offsets from the gated stamp to a hundredth of a
        // second (`offsetSeconds`), so a log can tell the margin band from a late exit.
        let exitSeenFirst: Bool
        let signals = children.signals
        let observed = children.exitObservedAt
        if let observed {
            let beforeCleanup = signals.isEmpty
                || (signals[0].at.map { observed < $0 } ?? false)
            exitSeenFirst = beforeCleanup
                && observed + Self.drainScenarioMargin < spawnedAt + 2_000_000_000
        } else {
            exitSeenFirst = false
        }
        let exitOffset = observed.map {
            $0 >= spawnedAt ? "\(Self.offsetSeconds($0 - spawnedAt)) s" : "before it"
        } ?? "never"
        let signalOffset = signals.first?.at.map {
            $0 >= spawnedAt ? "\(Self.offsetSeconds($0 - spawnedAt)) s" : "before it"
        } ?? "none"
        let offsets = "exit seen \(exitOffset), first signal \(signalOffset) after the gated stamp"
        var missed: [String] = []
        if descendant == nil || !exitSeenFirst {
            missed.append("""
                descendant pid \(descendant == nil ? "missing" : "published"), root exit \
                \(exitSeenFirst ? "seen" : "not seen") by 1.9 s and before cleanup (\(offsets); \
                gate \(children.wasReadyAtSpawn ? "released on the pid file" : "timed out"))
                """)
        }
        if runnerStalled {
            let headroom = DeschedulingProbe.seconds(Self.drainHeadroomNanoseconds)
            missed.append("""
                the bound was crossed while the runner withheld at least the \(headroom) s \
                headroom (\(timing))
                """)
        }
        if !missed.isEmpty && !lastAttempt {
            print("""
                drain-timeout scenario missed on attempt \(attempt) of 3: \
                \(missed.joined(separator: "; "))
                """)
            return false
        }
        #expect(descendant != nil, "the child never published its descendant's pid")
        #expect(exitSeenFirst, """
            the root's exit must be seen by 1.9 s and before cleanup, so the timeout fired in the \
            drain (\(offsets))
            """)
        return true
    }

    // Catchable read failures and post-failure usability are exercised at the actual I/O
    // boundary by ProcessResourceTests.readFailureClosesResources. No worker helper remains.

    @Test("a script larger than the pipe buffer is delivered whole, not truncated")
    func stdinFormDeliversAScriptLargerThanThePipeBuffer() throws {
        // Four times the ~64 KiB pipe buffer, echoed straight back. `stdinFormDeliversTheScript`
        // only covers a script that fits in the buffer in one write, so nothing pinned the loop
        // that delivers a bigger one — and a short write that did not throw would hand the
        // interpreter a TRUNCATED script: a prefix that can still compile and run a partial
        // action whose trailing guard was cut off.
        let script = String(repeating: "a", count: 256 * 1024)
        let pidFile = try scratch.directory().appendingPathComponent("pid")
        let outcome = try launchBounded(ScriptInvocation(
            executablePath: "/bin/sh", arguments: ["-c", #"echo $$ > "$0"; cat"#, pidFile.path],
            delivery: .stdin(script: script)), pidFile: pidFile)
        #expect(outcome.terminationStatus == 0)
        #expect(outcome.standardOutput.count == script.utf8.count)
        #expect(outcome.standardOutput == Data(script.utf8), "every byte, in order")
    }

    /// Thrown when `launchBounded` gives up, so a re-introduced deadlock ends the test rather
    /// than the whole run.
    private struct LaunchDidNotFinish: Error {}

    /// Runs a launch on a thread of its own and refuses to wait past `seconds`.
    ///
    /// A deadlock regression must FAIL — a plain call would block this thread forever and hang the
    /// suite with no verdict, which reads as an infrastructure problem rather than the bug it is.
    ///
    /// On expiry the child must be KILLED and the worker joined before the failure is reported:
    /// abandoning them leaks a live subprocess plus its pipe descriptors into every test that runs
    /// afterwards — and that subprocess is the one already established to be sitting on a full pipe
    /// forever. `pidFile` is where the child publishes its own pid (a path in its argv); without
    /// one there is nothing to kill, because the `Process` is owned inside the launcher and no
    /// handle to it crosses the seam.
    ///
    /// `gated` runs the launch through a `ReadyGatedChildren` launcher instead of the suite's plain
    /// one. Its readiness gate holds the launch for up to sixty seconds before the deadline starts,
    /// so `seconds` must leave room for that gate as well as the scenario; every gated caller
    /// passes 120.
    ///
    /// `seconds` counts only time this process was scheduled. The watchdog is not a product bound:
    /// it stands in for "never", so a deadlock fails instead of hanging. A single wall-clock wait
    /// would race the launcher it guards: a host-wide stall can wake the waiting thread after its
    /// budget before the launcher's threads have had the CPU to run the deadline and escalation a
    /// test exists to check, and it would then kill the child and report a deadlock against correct
    /// code. So the watchdog waits in quarter-second ticks; a tick that wakes more than half a
    /// second late means the thread was not scheduled for the excess, and the excess is not
    /// counted. A deadlock still fails after `seconds` of scheduled time, and at the latest five
    /// minutes of wall time past `seconds`, so chronic starvation cannot turn the watchdog itself
    /// into a hang. Every product check stays with the callers, including their elapsed-time
    /// bounds, which this does not touch. The stall time that was not counted is printed when the
    /// launch finishes, and it goes in the issue when the watchdog fires.
    private func launchBounded(_ invocation: ScriptInvocation,
                               pidFile: URL,
                               seconds: TimeInterval = 60,
                               using gated: OsascriptLauncher? = nil) throws -> ScriptOutcome {
        final class Box: @unchecked Sendable { var result: Result<ScriptOutcome, any Error>? }
        let box = Box()
        let finished = DispatchSemaphore(value: 0)
        let launcher = gated ?? self.launcher
        DispatchQueue(label: "apple-cli.test.launch-bounded").async {
            box.result = Result { try launcher.launch(invocation) }
            finished.signal()
        }
        // The tick, the lateness that marks a stall, and the most wall time past `seconds` that
        // stalls may add: five minutes, longer than the host-wide stalls of about 170 seconds seen
        // under deliberate starvation. `uptimeNanoseconds` is monotonic; the guarded subtractions
        // only keep a surprise from trapping on unsigned underflow.
        let tick: UInt64 = 250_000_000
        let lateness: UInt64 = 500_000_000
        let stallAllowance: UInt64 = 300_000_000_000
        let budget = UInt64(seconds * 1_000_000_000)
        let started = DispatchTime.now().uptimeNanoseconds
        var lastWake = started
        var stalled: UInt64 = 0
        var allowanceSpent = false
        var done = false
        while true {
            if finished.wait(timeout: .now() + .nanoseconds(Int(tick))) == .success {
                done = true
                break
            }
            let now = DispatchTime.now().uptimeNanoseconds
            let gap = now >= lastWake ? now - lastWake : 0
            lastWake = now
            if gap > tick + lateness { stalled += gap - tick }
            let elapsed = now >= started ? now - started : 0
            let scheduled = elapsed > stalled ? elapsed - stalled : 0
            allowanceSpent = elapsed >= budget + stallAllowance
            if scheduled >= budget || allowanceSpent {
                // One last look before acting: a launch that finished as the budget ran out has
                // already reaped its child, and killing or failing it would accuse correct code.
                done = finished.wait(timeout: .now()) == .success
                break
            }
        }
        let stalledSeconds = String(format: "%.1f", Double(stalled) / 1_000_000_000)
        if !done {
            // SIGKILL, not SIGTERM: this child is wedged writing to a pipe nobody drains, and a
            // handler it may never reach is no use here. Killing it closes its ends of the pipes,
            // which is what lets the abandoned worker finish and be joined.
            //
            // The pid was written by the child up to `seconds` ago (longer, if stalls were not
            // counted), so it may already have exited and had its number recycled. `isOwnChild`
            // closes that window: a recycled pid is overwhelmingly unlikely to ALSO be a direct
            // child of this process. `pid > 1` is belt-and-braces — `$$` is always positive, but
            // `kill(-1, …)` would signal every process this user can reach, and the guard costs one
            // comparison.
            //
            // The pid wait is five seconds and the join thirty: both run only on this failure path,
            // where a starved child may still be writing its pid and a starved worker may still be
            // unwinding after the kill. Neither changes the verdict, because the issue below is
            // recorded either way. They only make it less likely that a live child or worker leaks
            // into the tests that run after.
            let pid = publishedPid(at: pidFile, within: 5)
            if let pid, pid > 1, isOwnChild(pid) { _ = Darwin.kill(pid, SIGKILL) }
            let joined = finished.wait(timeout: .now() + 30) == .success
            Issue.record("""
                the launch did not finish within its \(Int(seconds))s watchdog \
                (\(stalledSeconds)s of stalls not counted\
                \(allowanceSpent ? "; the five-minute stall allowance ran out first" : "")) — the \
                child's stdout and stderr are not being drained concurrently\
                \(pid == nil ? " (no pid was published, so nothing could be killed)" : "")\
                \(joined ? "" : " (and the worker did not finish even after the child was killed)")
                """)
            throw LaunchDidNotFinish()
        }
        if stalled > 0 {
            print("""
                launch watchdog: \(stalledSeconds)s of stalls not counted against its \
                \(Int(seconds))s
                """)
        }
        return try #require(box.result).get()
    }
}

@Suite("AppleScript output-limit error provenance")
struct ScriptOutputLimitErrorTests {
    private var errors: [AppleError] {
        [.outputLimitEnvironmentInvalid(), .outputLimitExplicitInvalid(),
         .outputLimitExceeded(maximumOutputBytes: 64)]
    }

    @Test("error reflection preserves the legacy public-field presentation and hides origin")
    func reflectionPreservesLegacyDescription() throws {
        let metadata = AppleError(type: "synthetic_type", message: "synthetic \"message\"", exitCode: 71,
                                  status: "synthetic-status", remediation: "synthetic-remediation",
                                  applied: ["synthetic-id"], sandbox: true)
        let expected = #"AppleError(type: "synthetic_type", message: "synthetic \"message\"", exitCode: 71, status: Optional("synthetic-status"), remediation: Optional("synthetic-remediation"), applied: Optional(["synthetic-id"]), sandbox: Optional(true))"#
        #expect(String(describing: metadata) == expected)
        #expect(String(reflecting: metadata) == "AppleKit." + expected)
        for error in errors {
            let expected = "AppleError(type: \(String(reflecting: error.type)), message: \(String(reflecting: error.message)), exitCode: \(error.exitCode), status: nil, remediation: nil, applied: nil, sandbox: nil)"
            #expect(String(describing: error) == expected)
            #expect(String(reflecting: error) == "AppleKit." + expected)
            let legacyWrapper = AppleError.upstream("wrapper: \(error)")
            let root = try #require(try JSONSerialization.jsonObject(
                with: Output.encodeError(tool: "mail", from: legacyWrapper)) as? [String: Any])
            let payload = try #require(root["error"] as? [String: Any])
            #expect(payload["message"] as? String == "wrapper: " + expected)
        }
    }

    @Test("dedicated factories retain exact public classification and private provenance")
    func factoryContracts() {
        let expected = [
            ("validation_error", Int32(64), "APPLE_SCRIPT_MAX_OUTPUT_BYTES must be a positive decimal byte count"),
            ("validation_error", Int32(64), "maximumOutputBytes must be a positive byte count"),
            ("upstream_error", Int32(69), "osascript output exceeded the configured limit of 64 bytes; no partial result returned. The operation may have completed; verify its state before retrying."),
        ]
        for (error, contract) in zip(errors, expected) {
            #expect(AppleScriptRunner.isOutputLimitError(error))
            #expect(error.type == contract.0)
            #expect(error.exitCode == contract.1)
            #expect(error.message == contract.2)
            #expect(error.status == nil && error.remediation == nil)
            #expect(error.applied == nil && error.sandbox == nil)
        }
    }

    @Test("identical public fields and nested descriptions cannot forge provenance")
    func ordinaryErrorsRemainUnmarked() {
        for error in errors {
            let copy = AppleError(type: error.type, message: error.message, exitCode: error.exitCode)
            #expect(!AppleScriptRunner.isOutputLimitError(copy))
            #expect(!AppleScriptRunner.isOutputLimitError(AppleError.validation(error.message)))
            #expect(!AppleScriptRunner.isOutputLimitError(AppleError.upstream(error.message)))
            let nested = NSError(domain: "synthetic", code: Int(error.exitCode), userInfo: [
                NSLocalizedDescriptionKey: error.message, NSUnderlyingErrorKey: error,
            ])
            #expect(!AppleScriptRunner.isOutputLimitError(nested))
        }
    }

    @Test("bulk copies preserve provenance and existing metadata while empty applied stays absent")
    func bulkCopiesPreserveOrigin() {
        for error in errors {
            let ordinary = AppleError(type: error.type, message: error.message, exitCode: error.exitCode,
                                      status: "synthetic-status", remediation: "synthetic-remediation",
                                      sandbox: true)
            for applied in [[], ["synthetic-prior"]] {
                for original in [error, ordinary] {
                    let copied = original.addingBulkContext(applied: applied, failedID: "synthetic-failed")
                    #expect(AppleScriptRunner.isOutputLimitError(copied)
                            == AppleScriptRunner.isOutputLimitError(original))
                    #expect(copied.type == original.type && copied.exitCode == original.exitCode)
                    #expect(copied.status == original.status && copied.remediation == original.remediation)
                    #expect(copied.sandbox == original.sandbox)
                    #expect(copied.applied == (applied.isEmpty ? nil : applied))
                    #expect(copied.message.hasSuffix(original.message))
                    #expect(copied.message.contains("The failed item may have changed"))
                }
            }
        }
    }

    @Test("marked errors emit exactly the existing envelope keys without provenance")
    func wireShapeDoesNotExposeOrigin() throws {
        for error in errors {
            for applied in [[], ["synthetic-prior"]] {
                let copied = error.addingBulkContext(applied: applied, failedID: "synthetic-failed")
                let root = try #require(try JSONSerialization.jsonObject(
                    with: Output.encodeError(tool: "notes", from: copied)) as? [String: Any])
                #expect(Set(root.keys) == ["schema_version", "tool", "ok", "error"])
                #expect(root["ok"] as? Bool == false)
                #expect(root["tool"] as? String == "notes")
                let payload = try #require(root["error"] as? [String: Any])
                let expectedKeys: Set<String> = applied.isEmpty ? ["type", "message"] : ["type", "message", "applied"]
                #expect(Set(payload.keys) == expectedKeys)
                #expect(payload["type"] as? String == copied.type)
                #expect(payload["message"] as? String == copied.message)
                #expect(payload["applied"] as? [String] == copied.applied)
            }
        }
    }
}

@Suite("AppleScript output-limit configuration")
struct ScriptOutputLimitConfigurationTests {
    @Test("strict decimal configuration accepts only positive representable byte counts")
    func resolution() throws {
        #expect(try AppleScriptRunner.resolveMaximumOutputBytes(explicit: nil, environment: nil) == nil)
        for (text, value) in [("1", 1), ("0001", 1), (String(Int.max), Int.max)] {
            #expect(try AppleScriptRunner.resolveMaximumOutputBytes(explicit: nil, environment: text) == value)
        }
        for text in ["", "0", "000", "-1", "+1", " 1", "1 ", "1\n", "1.0", "1KiB", "١", "１", String(Int.max) + "0"] {
            let error = try #require(#expect(throws: AppleError.self) {
                _ = try AppleScriptRunner.resolveMaximumOutputBytes(explicit: nil, environment: text)
            })
            #expect(error.message == "APPLE_SCRIPT_MAX_OUTPUT_BYTES must be a positive decimal byte count")
            #expect(error.exitCode == 64 && AppleScriptRunner.isOutputLimitError(error))
        }
        for value in [0, -1, Int.min] {
            let error = try #require(#expect(throws: AppleError.self) {
                _ = try AppleScriptRunner.resolveMaximumOutputBytes(explicit: value, environment: "1")
            })
            #expect(error.message == "maximumOutputBytes must be a positive byte count")
            #expect(error.exitCode == 64 && AppleScriptRunner.isOutputLimitError(error))
        }
        #expect(try AppleScriptRunner.resolveMaximumOutputBytes(explicit: 7, environment: "invalid") == 7)
    }

    @Test("explicit configuration never reads environment and invalid configuration never launches")
    func explicitPrecedence() throws {
        let launcher = RecordingLauncher()
        var reads = 0
        let reader = { reads += 1; return "synthetic-invalid-environment" }
        let runner = AppleScriptRunner(launcher: launcher, maximumOutputBytes: 7, environmentValue: reader)
        _ = try runner.run("x")
        #expect(try #require(launcher.only).maximumOutputBytes == 7)
        #expect(reads == 0)
        let invalidLauncher = RecordingLauncher()
        let invalid = AppleScriptRunner(launcher: invalidLauncher, maximumOutputBytes: 0, environmentValue: reader)
        #expect(throws: AppleError.self) { _ = try invalid.run("x") }
        #expect(reads == 0 && invalidLauncher.invocations.isEmpty)
        let fromEnvironment = AppleScriptRunner(launcher: invalidLauncher, environmentValue: reader)
        #expect(throws: AppleError.self) { _ = try fromEnvironment.run("x") }
        #expect(reads == 1 && invalidLauncher.invocations.isEmpty)
    }

    @Test("each of four run forms resolves once per invocation with unchanged delivery and argv")
    func invocationWiring() throws {
        let launcher = RecordingLauncher()
        let sequence: [String?] = [nil, "0002", "3", "4"]
        var reads = 0
        let runner = AppleScriptRunner(launcher: launcher, environmentValue: {
            defer { reads += 1 }
            return sequence[reads]
        })
        _ = try runner.run("source", arguments: ["-arg"])
        _ = try runner.run("source", arguments: ["-arg"], timeout: 2)
        _ = try runner.runViaStdin("source", arguments: ["-arg"])
        _ = try runner.runViaStdin("source", arguments: ["-arg"], timeout: 2)
        #expect(reads == 4)
        #expect(launcher.invocations.map(\.maximumOutputBytes) == [nil, 2, 3, 4])
        #expect(launcher.invocations.map(\.delivery) == [.inline, .timed(seconds: 2), .stdin(script: "source"), .timedStdin(script: "source", seconds: 2)])
        #expect(launcher.invocations.map(\.arguments) == [["-e", "source", "--", "-arg"], ["-e", "source", "--", "-arg"], ["-", "-arg"], ["-", "-arg"]])
        let absent = RecordingLauncher()
        _ = try AppleScriptRunner(launcher: absent).run("x")
        #expect(try #require(absent.only).maximumOutputBytes == nil)
    }

    @Test("invalid timeout precedes invalid output configuration without reading environment")
    func timeoutPrecedence() {
        let launcher = RecordingLauncher()
        var reads = 0
        let runner = AppleScriptRunner(launcher: launcher, maximumOutputBytes: 0,
                                       environmentValue: { reads += 1; return "invalid" })
        #expect(throws: AppleScriptRunner.InvalidTimeoutError.self) { _ = try runner.run("x", timeout: 0) }
        #expect(throws: AppleScriptRunner.InvalidTimeoutError.self) { _ = try runner.runViaStdin("x", timeout: 0) }
        #expect(reads == 0 && launcher.invocations.isEmpty)
    }

    @Test("the shared runner boundary maps typed overflow in every delivery form")
    func typedOverflowMapping() throws {
        let launcher = RecordingLauncher(failure: ScriptOutputLimitExceeded(maximumOutputBytes: 9))
        let runner = AppleScriptRunner(launcher: launcher)
        let calls: [() throws -> String] = [
            { try runner.run("synthetic-source", arguments: ["synthetic-argument"]) },
            { try runner.run("synthetic-source", timeout: 1) },
            { try runner.runViaStdin("synthetic-source") },
            { try runner.runViaStdin("synthetic-source", timeout: 1) },
        ]
        for call in calls {
            let error = try #require(#expect(throws: AppleError.self) { _ = try call() })
            #expect(AppleScriptRunner.isOutputLimitError(error))
            #expect(error.message == AppleError.outputLimitExceeded(maximumOutputBytes: 9).message)
            #expect(error.exitCode == 69 && error.type == "upstream_error")
        }
        #expect(launcher.invocations.count == 4)
    }
}

@Suite("AppleScript raw output byte boundaries")
struct ScriptOutputLimitBoundaryTests {
    private let scratch = ScratchDirs("script-output-limit")

    @Test("overflow aborts while stdin is pending and the empty sibling stream remains open")
    func overflowDuringPendingInput() throws {
        // The fixture writes nine bytes, one past the eight-byte limit, while the launcher's stdin
        // write is still pending, and the launcher must report the overflow without waiting for
        // that write. The error type is the primary check. It, the reported limit and the
        // stop-before-exit check run on every attempt, before the elapsed bound can be set aside,
        // and a failed one is never re-run.
        //
        // The ten-second bound only guards a regression that reports the overflow late. It sits
        // well below the fixture's sixty-second alarm and the 120-second deadline: the alarm is
        // armed after the fixture's stamp, so a launcher that waits on the pending write ends at
        // least sixty seconds after that stamp, far past the bound whenever the bound starts near
        // it. The bound starts after the child's start-up, at the later of two `CLOCK_UPTIME_RAW`
        // stamps. One is the gated launcher's stamp when `spawn` returns, which waits until the
        // fixture publishes its ready file (its path is in argv) or sixty seconds pass. The other
        // is the fixture's own stamp, read before it arms its alarm and published as the ready
        // file's content by write-then-rename so the gate never sees a partial file; it can be the
        // later one only when the gate expired while Python was still starting. The fixture names
        // that clock rather than calling `time.monotonic_ns()`, which on the 3.9
        // `/usr/bin/python3` checked here counts from the interpreter's own start and so cannot be
        // compared across processes. Neither stamp moves product work out of the bound, because
        // the launcher cannot detect the overflow before the fixture writes it, after both stamps.
        // Correct work inside the bound is little more than the overflow ladder: the fixture's
        // write, detection, the half-second TERM grace, SIGKILL and at most a one-second reap.
        //
        // The deadline is not the subject here, only what the launcher must not wait for. It starts
        // when the gate releases, and Python start-up under starvation has taken more than thirty
        // seconds, so 120 seconds leaves room for the rest of start-up after an expired gate; a
        // deadline that fired first would report `TimeoutError` in place of the overflow against
        // correct code.
        //
        // The bound alone cannot catch a launcher that waits out the alarm: when the gate releases
        // on the file, a gate thread withheld after the file appeared moves the gated stamp later
        // while the alarm stays where it was armed, so such a launcher could end inside the bound.
        // So the launcher's first group signal must also come before its first observation of the
        // fixture's exit, or with no exit observed at all. The fixture cannot exit by itself before
        // its alarm, so a launcher whose SIGTERM came first stopped it in time wherever the bound
        // started, while one that waited the alarm out observed the exit first or never signalled.
        //
        // The alarm is armed before the fixture writes and renames its ready file, so its sixty
        // seconds run from there through the publish, the gate's release, the fixture's stdout
        // write, and the launcher's read of the overflow and its SIGTERM. A runner that withholds
        // the fixture or the launcher for sixty seconds in all anywhere in that window lets the
        // alarm end the fixture first. When the alarm lands before the publish while the gate still
        // holds, the gate sees the death; seen no sooner than sixty seconds after the call into
        // `spawn`, that is a miss on attempts 1 and 2 and a failure on the last. Otherwise a
        // correct launcher fails the attempt at once, on any attempt, the last included: on the
        // error type when the alarm lands before the stdout write (including after a gate that ran
        // out first), and on the stop check when it lands after that write and before the SIGTERM.
        // Host-wide stalls of about 170 seconds have been seen under deliberate starvation
        // (`launchBounded`), so sixty seconds is within reach of a stall already seen: this is a
        // residual of the method, not a window no stall reaches.
        //
        // As with the stopwatches in `OsascriptLauncherTests`, a crossed bound is a missed
        // scenario, printed and re-run at most twice, when a `DeschedulingProbe` saw the runner
        // withhold at least the headroom inside the measured window, or when the gate expired after
        // the fixture had stamped: the launcher cannot return before the fixture's write, so the
        // fixture's publish and write, begun before the bound and finished after the gate gave up,
        // lie inside it. A fixture stamp taken after the gate gave up is starvation before the
        // bound, which then holds only a few syscalls of fixture work, so it is no reason. (The
        // failed-delivery tests differ: their bound starts at the gated stamp, so any expired gate
        // leaves the child's start-up inside it.) Neither reason observes the launcher, since the
        // gate releases before it acts, so a launcher that reports the overflow late on a runner
        // that is running the test crosses the bound with neither and fails at once. A set-aside
        // attempt can only be re-run, never pass, and the last attempt applies the bound whatever
        // happened.
        for attempt in 1...3 {
            if try overflowStopsPendingWrite(attempt: attempt, lastAttempt: attempt == 3) {
                return
            }
        }
        Issue.record("pending-input overflow scenario: the last attempt returned without a verdict")
    }

    /// The pending-input overflow test's elapsed bound, from the later of the gated stamp and the
    /// fixture's own stamp to `launch` returning.
    private static let pendingInputBoundNanoseconds: UInt64 = 10_000_000_000

    /// How far `pendingInputBoundNanoseconds` sits above the launcher's own worst case on this path
    /// once it has read the overflowing byte: the half-second TERM grace and the one-second reap
    /// wait (`OwnedScriptProcess.cancel(timeout:)`). Unlike the drain bound, and a failed-delivery
    /// bound whose gate released, this bound holds fixture work even when the gate released on its
    /// file: the launcher cannot return before the fixture writes its nine bytes, so the bound
    /// holds that stdout write and, after an expired gate, arming the alarm and publishing as well.
    /// A correct launcher crosses the bound only if the runner withholds at least this much of the
    /// measured window from the launcher's thread or from the fixture. `DeschedulingProbe` sees
    /// only part of the first (see there) and none of the second, so an expired gate after the
    /// fixture stamped is a set-aside reason too; a fixture withheld after a gate that released on
    /// its file, before its stdout write, leaves neither reason and still fails a correct launcher.
    private static let pendingInputHeadroomNanoseconds: UInt64 = 8_500_000_000

    /// One attempt of `overflowDuringPendingInput`. Returns true after a failed product check (its
    /// recorded issues fail the test) or after asserting the scenario; returns false only when
    /// every product check held, another attempt remains, and the bound was crossed in a missed
    /// scenario: the runner withheld at least the headroom from the process, the gate timed out
    /// after the fixture took its stamp but before it published it, or the gate saw the fixture die
    /// of its own alarm on time before it published.
    private func overflowStopsPendingWrite(attempt: Int, lastAttempt: Bool) throws -> Bool {
        let program = #"""
import os, signal, sys, time
signal.signal(signal.SIGALRM, signal.SIG_DFL)
signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGALRM})
stamp = time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)
signal.alarm(60)
with open(sys.argv[1] + ".partial", "w") as partial:
    partial.write(str(stamp))
os.rename(sys.argv[1] + ".partial", sys.argv[1])
os.write(1, b"123456789")
signal.pause()
"""#
        let ready = try scratch.directory().appendingPathComponent("ready")
        let children = ReadyGatedChildren(readyFile: ready)
        let launcher = children.launcher(captureDirectory: try scratch.directory())
        // Started before the launch so it is ticking when the gate releases; only lapses inside the
        // measured window count. Stopped on every path, including a failed `#require`.
        let runner = DeschedulingProbe()
        defer { runner.stop() }
        // The outcome is held, not checked, until the early-exit rule below has run, so a fixture
        // that died of its own alarm before it published is a miss rather than a wrong error.
        let result = Result<ScriptOutcome, any Error> {
            try launcher.launch(ScriptInvocation(executablePath: "/usr/bin/python3",
                arguments: ["-I", "-S", "-c", program, ready.path],
                delivery: .timedStdin(script: String(repeating: "x", count: 262_144),
                                      seconds: 120),
                maximumOutputBytes: 8))
        }
        let returnedAt = try #require(ReadyGatedChildren.uptimeNanoseconds())
        if children.exitedBeforeReady {
            // The fixture arms its sixty-second alarm before it publishes, so a death by SIGALRM
            // seen no sooner than that after the call into `spawn` is the alarm firing on time
            // while the runner withheld the fixture: a miss, never on the last attempt. The stamps
            // and the kernel's alarm timer read one clock, so "no sooner" keeps only
            // `DeschedulingProbe.clockRoundingNanoseconds` in hand, for the microsecond the kernel
            // truncates when it arms the alarm. Any other early exit fails at once.
            if !lastAttempt, let after = children.earlyAlarmAfterCall,
               after >= 60_000_000_000 - DeschedulingProbe.clockRoundingNanoseconds {
                print("pending-input overflow scenario missed on attempt \(attempt) of 3: the "
                      + "fixture died of its own 60-second alarm before it published, "
                      + "\(DeschedulingProbe.seconds(after)) s after the spawn call")
                return false
            }
            Issue.record("""
                the fixture exited before it published its ready file, so the scenario never began
                """)
            return true
        }
        let thrown = #expect(throws: ScriptOutputLimitExceeded.self) { _ = try result.get() }
        let failure = try #require(thrown)
        let spawnedAt = try #require(children.spawnedAt,
                                     "the gated launcher never spawned the fixture")
        // Product checks, on every attempt, before the bound: the error type (above), the limit it
        // reports, and the stop below.
        let limitReported = failure.maximumOutputBytes == 8
        #expect(limitReported, """
            the overflow must report the configured eight bytes, not \(failure.maximumOutputBytes)
            """)
        // The overflow was detected, so the fixture had already renamed its ready file into place.
        let stampText = try String(contentsOf: ready, encoding: .utf8)
        let fixtureAt = try #require(UInt64(stampText),
                                     "the ready file did not hold the fixture's stamp")
        // The fixture's stamp and the decorator's stamps read one clock, so the stamp falls in the
        // window they bound by construction: after the call into `spawn`, before which the fixture
        // cannot run; before `launch` returned, since the overflow it writes after publishing was
        // detected; and, when the gate released on the ready file, before `spawnedAt`. A stamp
        // outside that window is on another clock (a partial migration, off by the host's
        // accumulated sleep or slew), a harness defect rather than a launcher fault, so it fails
        // the attempt on any attempt, before the bound below can misread it.
        let calledAt = try #require(children.calledAt,
                                    "the gated launcher never stamped the call into spawn")
        func sinceCall(_ stamp: UInt64) -> String {
            stamp >= calledAt ? "\((stamp - calledAt) / 1_000_000) ms"
                : "-\((calledAt - stamp) / 1_000_000) ms"
        }
        let onOneClock = calledAt <= fixtureAt && fixtureAt <= returnedAt
            && (!children.wasReadyAtSpawn || fixtureAt <= spawnedAt)
        try #require(onOneClock, """
            the fixture's stamp and the decorator's stamps are not on one clock: the fixture \
            stamped \(sinceCall(fixtureAt)) after the call into spawn, which returned \
            \(sinceCall(spawnedAt)) after it (the gate \
            \(children.wasReadyAtSpawn ? "released on the ready file" : "timed out")), and the \
            launch returned \(sinceCall(returnedAt)) after it; the decorator reads \
            CLOCK_UPTIME_RAW, so the fixture must read time.CLOCK_UPTIME_RAW
            """)
        // The launcher stopped the fixture before the fixture could end by itself: its first group
        // signal came before its first observation of the exit.
        let firstSignal = children.signals.first?.at
        let exitObserved = children.exitObservedAt
        let stoppedInTime: Bool
        if let firstSignal {
            stoppedInTime = exitObserved.map { firstSignal < $0 } ?? true
        } else {
            stoppedInTime = false
        }
        #expect(stoppedInTime, """
            overflow must stop the fixture before it ends at its own alarm (first signal \
            \(firstSignal == nil ? "never sent" : "sent after the exit was observed"))
            """)

        // The bound, from the later of the two stamps. It is set aside, and the attempt re-run,
        // only when it was crossed in a missed scenario, and never on the last attempt: the probe
        // saw the runner withhold at least the headroom inside the measured window, or the gate
        // timed out after the fixture had stamped, so the fixture's publish and write straddled the
        // bound's start and lay inside it. An expired gate with the stamp taken after the gate gave
        // up is starvation before the bound, not inside it, and counts for nothing.
        let start = max(spawnedAt, fixtureAt)
        let ordered = start <= returnedAt
        let elapsed = ordered ? returnedAt - start : 0
        let bounded = ordered && elapsed < Self.pendingInputBoundNanoseconds
        let withheld = runner.lapsed(from: start, to: returnedAt)
        var missed: [String] = []
        if withheld >= Self.pendingInputHeadroomNanoseconds {
            let headroom = DeschedulingProbe.seconds(Self.pendingInputHeadroomNanoseconds)
            missed.append("the runner withheld at least the \(headroom) s headroom")
        }
        if !children.wasReadyAtSpawn && fixtureAt < spawnedAt {
            missed.append("the gate timed out after the fixture stamped and before it published")
        }
        let setAside = ordered && !bounded && !lastAttempt && !missed.isEmpty
        let gate = children.wasReadyAtSpawn ? "released on the ready file" : "timed out"
        let timing = "\(DeschedulingProbe.seconds(elapsed)) s from the start of the bound, "
            + "\(DeschedulingProbe.seconds(withheld)) s of it withheld by the runner"
        if !setAside {
            #expect(bounded, """
                overflow must stop the pending write without waiting for the script deadline \
                (\(timing); the readiness gate \(gate))
                """)
        }
        if !limitReported || !stoppedInTime || !setAside { return true }
        print("""
            pending-input overflow scenario missed on attempt \(attempt) of 3: the bound was \
            crossed (\(timing)) and \(missed.joined(separator: "; "))
            """)
        return false
    }
    // Harmless fixed Python fixture, no subprocesses or Apple operations. Its independent alarm
    // bounds even untimed launcher regressions; no test signals a numeric process ID. Ninety
    // seconds, thirty below the timed forms' 120-second deadline (see `invocation`).
    private static let program = #"""
import os, signal, sys
signal.signal(signal.SIGALRM, signal.SIG_DFL)
signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGALRM})
signal.alarm(90)
os.write(1, bytes.fromhex(sys.argv[1]))
os.write(2, bytes.fromhex(sys.argv[2]))
os._exit(int(sys.argv[3]))
"""#

    /// One fixture launch in delivery form `mode` (0 inline, 1 timed capture, 2 stdin, 3 timed
    /// stdin) that writes `output` and `error` and exits with `status`.
    ///
    /// Nothing in this suite is about the deadline: the subject is combined raw-byte counting and
    /// its classification, and the timed forms only have to carry a deadline. The launcher starts
    /// the deadline when `spawn` returns, so Python start-up runs inside it, and checks it after
    /// every observation, so an exit observed late because the test process itself was not
    /// scheduled still reports a timeout, which surfaces as `TimeoutError` where an outcome or an
    /// overflow is expected. A deadline of a few seconds times out this way under load (see
    /// docs/learnings/hot/hosted-ci.md), and under deliberate local starvation (background QoS, a
    /// busy process on every core) these fixtures, which write at most nine bytes and exit, have
    /// needed more than thirty seconds. So the deadline is widened rather than gated: 120 seconds
    /// gives room for everything the child does before the scenario. A correct run never comes near
    /// it, so a passing run pays nothing, and a launcher that never completes a timed launch still
    /// fails with `TimeoutError`.
    ///
    /// The fixture's alarm is ninety seconds, thirty below the deadline: long enough that a starved
    /// inline or stdin child is not killed between arming it and `_exit` (which would read as a
    /// signal status), and below the deadline so it remains the independent bound for the untimed
    /// forms. The checks do not depend on either figure: nine bytes throw
    /// `ScriptOutputLimitExceeded(8)`, seven or eight return the exact bytes with status 0, status
    /// 7 maps to `scriptFailed`, and overflow takes precedence.
    private func invocation(mode: Int, output: Data, error: Data,
                            limit: Int?, status: Int = 0) -> ScriptInvocation {
        let delivery: ScriptDelivery
        switch mode {
        case 0: delivery = .inline
        case 1: delivery = .timed(seconds: 120)
        case 2: delivery = .stdin(script: "")
        default: delivery = .timedStdin(script: "", seconds: 120)
        }
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        return ScriptInvocation(executablePath: "/usr/bin/python3",
                                arguments: ["-I", "-S", "-c", Self.program, hex(output), hex(error), String(status)],
                                delivery: delivery, maximumOutputBytes: limit)
    }

    @Test("all delivery forms count combined raw bytes at N-1, N and N+1",
          arguments: [0, 1, 2, 3], [0, 1, 2])
    func byteBoundaries(mode: Int, stream: Int) throws {
        let launcher = OsascriptLauncher(captureDirectory: try scratch.directory())
        let bytes = Data([0xC3, 0xA9, 0, 0xFF, 65, 66, 67, 68, 69])
        for count in [7, 8, 9] {
            let payload = Data(bytes.prefix(count))
            let split = stream == 0 ? count : (stream == 1 ? 0 : count / 2)
            let out = Data(payload.prefix(split))
            let err = Data(payload.dropFirst(split))
            let request = invocation(mode: mode, output: out, error: err, limit: 8)
            if count > 8 {
                let failure = try #require(#expect(throws: ScriptOutputLimitExceeded.self) {
                    _ = try launcher.launch(request)
                })
                #expect(failure.maximumOutputBytes == 8)
            } else {
                let result = try launcher.launch(request)
                #expect(result.standardOutput == out && result.standardError == err)
                #expect(result.terminationStatus == 0)
            }
        }
    }

    @Test("unlimited and under-limit nonzero outcomes retain existing bytes and classification",
          arguments: [0, 1, 2, 3])
    func compatibility(mode: Int) throws {
        let launcher = OsascriptLauncher(captureDirectory: try scratch.directory())
        let output = Data("unlimited-output".utf8)
        let unlimited = try launcher.launch(invocation(mode: mode, output: output, error: Data(), limit: nil))
        #expect(unlimited.standardOutput == output)
        let errorBytes = Data("synthetic-error".utf8)
        let failed = try launcher.launch(invocation(mode: mode, output: Data(), error: errorBytes, limit: 64, status: 7))
        #expect(failed.terminationStatus == 7 && failed.standardError == errorBytes)
        let mapped = try #require(#expect(throws: AppleScriptRunner.RunError.self) {
            _ = try AppleScriptRunner.result(of: failed)
        })
        guard case .scriptFailed(let status, let stderr) = mapped else {
            Issue.record("expected existing scriptFailed classification"); return
        }
        #expect(status == 7 && stderr == "synthetic-error")
    }

    @Test("observed overflow takes precedence over nonzero status and later launch remains usable",
          arguments: [0, 1, 2, 3])
    func overflowBeforeStatus(mode: Int) throws {
        let launcher = OsascriptLauncher(captureDirectory: try scratch.directory())
        let failure = try #require(#expect(throws: ScriptOutputLimitExceeded.self) {
            _ = try launcher.launch(invocation(mode: mode, output: Data("12345".utf8),
                                               error: Data("6789".utf8), limit: 8, status: 7))
        })
        #expect(failure.maximumOutputBytes == 8)
        let next = try launcher.launch(invocation(mode: mode, output: Data("ok".utf8), error: Data(), limit: 8))
        #expect(next.standardOutput == Data("ok".utf8))
    }
}
