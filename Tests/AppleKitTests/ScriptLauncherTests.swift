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
        let started = Date()
        let error = #expect(throws: AppleScriptRunner.TimeoutError.self) {
            _ = try launcher.launch(ScriptInvocation(executablePath: "/bin/sleep",
                                                     arguments: ["30"], delivery: .timed(seconds: 0.05)))
        }
        #expect(try #require(error).seconds == 0.05)
        #expect(Date().timeIntervalSince(started) < 10, "the deadline must not become a new wait")
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
        // THE production hazard: a GUI-driving script that Mail reads whole and then stalls on
        // (a dialog, a lost window). The unbounded form waits forever here; the timed form must
        // end the child and throw, and the child must actually be gone.
        // Through `launchBounded`: a regression that removed the bound would otherwise hang
        // this thread before the elapsed-time assertion below could ever run. 2s rather than
        // 0.5s so a loaded machine gets the pid file written before the child is ended.
        let pidFile = try scratch.directory().appendingPathComponent("pid")
        defer { reapIfLeaked(pidFile) }
        let started = Date()
        let error = #expect(throws: AppleScriptRunner.TimeoutError.self) {
            _ = try launchBounded(ScriptInvocation(
                executablePath: "/bin/sh",
                arguments: ["-c", #"echo $$ > "$0"; cat >/dev/null; sleep 30"#, pidFile.path],
                delivery: .timedStdin(script: "read whole, then stall", seconds: 2)),
                                  pidFile: pidFile, seconds: 20)
        }
        #expect(try #require(error).seconds == 2)
        #expect(Date().timeIntervalSince(started) < 10, "the deadline must not become a new wait")
        let pid = try #require(publishedPid(at: pidFile), "the child never published its pid")
        #expect(hasExited(pid), "the stalled child outlived the deadline")
    }

    @Test("the deadline fires even while the stdin write is blocked on a child that reads nothing")
    func timedStdinFormDeadlineCoversABlockedWrite() throws {
        // A script four times the pipe buffer against a child that never reads it: the write
        // blocks. If the deadline were waited on from the writing thread it could never expire,
        // and this would be an unbounded hang dressed as a timed call. The child also ignores
        // SIGTERM, so the escalation has to reach SIGKILL for the write to be released.
        let pidFile = try scratch.directory().appendingPathComponent("pid")
        defer { reapIfLeaked(pidFile) }
        let started = Date()
        let error = #expect(throws: AppleScriptRunner.TimeoutError.self) {
            _ = try launchBounded(ScriptInvocation(
                executablePath: "/bin/sh",
                arguments: ["-c", #"trap '' TERM; echo $$ > "$0"; while :; do sleep 0.2; done"#,
                            pidFile.path],
                delivery: .timedStdin(script: String(repeating: "a", count: 256 * 1024),
                                      seconds: 2)),
                                  pidFile: pidFile, seconds: 20)
        }
        // TimeoutError, NOT launchFailed: the deadline is the diagnosis here. The write's EPIPE
        // arrives only because the deadline killed the child, and reporting it instead would
        // hide the bound that actually fired.
        #expect(try #require(error).seconds == 2)
        // 2s deadline, then at most two one-second escalation waits.
        #expect(Date().timeIntervalSince(started) < 10)
        let pid = try #require(publishedPid(at: pidFile), "the child never published its pid")
        #expect(hasExited(pid), "the TERM-ignoring child is still alive after the deadline")
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
        // ASSERTING THE THROW IS NOT ENOUGH: both the escalating and the non-escalating paths
        // end at the same `throw TimeoutError`, so a suite that checks only the error and an
        // elapsed bound stays green with the whole KILL block deleted — while the child runs
        // on forever, reparented to launchd, still holding its capture files. So the child
        // publishes its pid and the test asks the OS whether that pid is gone.
        //
        // The command is a FIXED literal; the pid-file path arrives as `$0` through argv (the
        // operand after `sh -c <script>`), never interpolated into script source. The loop
        // (rather than a bare `sleep`) keeps `sh` from exec'ing away its own trap.
        let pidFile = try scratch.directory().appendingPathComponent("pid")
        let started = Date()
        let error = #expect(throws: AppleScriptRunner.TimeoutError.self) {
            _ = try launcher.launch(ScriptInvocation(
                executablePath: "/bin/sh",
                arguments: ["-c", #"trap '' TERM; echo $$ > "$0"; while :; do sleep 0.2; done"#,
                            pidFile.path],
                delivery: .timed(seconds: 2)))
        }
        #expect(try #require(error).seconds == 2)
        let pid = try #require(publishedPid(at: pidFile), "the child never published its pid")
        #expect(hasExited(pid), "the TERM-ignoring child is still alive after the deadline")
        // 2s rather than 0.5s: the deadline has to outlast `sh` reaching its `trap` builtin, and
        // on a loaded machine 500ms did not reliably. Expiring before the trap is INSTALLED makes
        // the child terminable by the SIGTERM this test exists to prove is insufficient.
        // Bounded: 2s deadline, then at most two one-second cleanup waits.
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("SIGTERM is delivered before the SIGKILL escalation, not skipped past")
    func deadlineSendsTerminateBeforeKilling() throws {
        // The order matters and is otherwise unobservable: killing outright works just as well
        // from the caller's side (same `TimeoutError`, same dead child), but denies a child the
        // chance to finish an in-flight Apple event and shut down cleanly. This child TRAPS
        // TERM, records that it arrived, and exits — so the marker is present only if SIGTERM
        // was actually delivered first. Fixed literal; both paths come from argv (`$0`, `$1`).
        //
        // The readiness marker is what keeps the absence of the TERM marker interpretable. It is
        // written IMMEDIATELY AFTER the trap is installed, so:
        //   * TERM marker present                  → SIGTERM was delivered first. The property holds.
        //   * neither marker                       → the deadline expired before `sh` reached its
        //                                            `trap` builtin, an unhandled SIGTERM killed
        //                                            the child, and this run says nothing about
        //                                            ordering. INCONCLUSIVE, not a failure —
        //                                            reporting it as one accuses correct code.
        //   * readiness present, TERM marker absent → the trap was armed and never fired. That is
        //                                            the real regression this test exists for.
        let dir = try scratch.directory()
        let marker = dir.appendingPathComponent("sigterm-seen")
        let ready = dir.appendingPathComponent("trap-installed")
        let error = #expect(throws: AppleScriptRunner.TimeoutError.self) {
            _ = try launcher.launch(ScriptInvocation(
                executablePath: "/bin/sh",
                arguments: ["-c",
                            #"trap 'printf t > "$0"; exit 0' TERM; printf r > "$1"; "#
                            + #"while :; do sleep 0.2; done"#,
                            marker.path, ready.path],
                delivery: .timed(seconds: 2)))
        }
        // 2s rather than 0.5s for the same reason as the escalation test above: a deadline that
        // can expire before `sh` installs its trap wastes the run on the inconclusive branch.
        #expect(try #require(error).seconds == 2)
        if waitForFile(marker) { return }
        if FileManager.default.fileExists(atPath: ready.path) {
            Issue.record("no SIGTERM reached the child — the deadline escalated straight to SIGKILL")
        } else {
            // Inconclusive, not a failure: with no readiness marker the child never reached its
            // `trap` builtin, so an unhandled SIGTERM killed it and the missing TERM marker says
            // nothing about signal ordering.
            withKnownIssue("the child did not install its TERM trap before the deadline expired") {
                Issue.record("inconclusive: no readiness marker")
            }
        }
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

    /// Closes stdin and then lives on, holding stdout and stderr open the whole time.
    /// `exec 0<&-` is the shell's own close, so the EPIPE arrives while the child is very much
    /// alive — the case a delivery failure must not simply wait out.
    private static let closesStdinThenLingers = #"""
        echo $$ > "$0"; exec 0<&-; sleep 30
        """#

    @Test("a failed delivery ends the child rather than waiting on one that lives on")
    func stdinFormEndsAChildThatOutlivesTheFailedDelivery() throws {
        // EPIPE like `stdinFormSurvivesAChildThatNeverReads`, but from a child that is STILL
        // RUNNING and still holding both output descriptors. Collecting the drains first would
        // block until the child felt like exiting — 30 seconds here, unbounded in general, and
        // this form carries no deadline — turning a diagnosed failure into a hang. The launcher
        // must terminate, escalate, and reap before it collects.
        let pidFile = try scratch.directory().appendingPathComponent("pid")
        let started = Date()
        let error = #expect(throws: AppleScriptRunner.RunError.self) {
            _ = try launchBounded(ScriptInvocation(
                executablePath: "/bin/sh",
                arguments: ["-c", Self.closesStdinThenLingers, pidFile.path],
                delivery: .stdin(script: String(repeating: "a", count: 256 * 1024))),
                                  pidFile: pidFile, seconds: 20)
        }
        guard case .launchFailed = try #require(error) else {
            Issue.record("expected launchFailed"); return
        }
        // Well inside the child's 30s: a launcher that waited for EOF could not be here yet.
        #expect(Date().timeIntervalSince(started) < 15,
                "the failed delivery waited on the child instead of ending it")
        let pid = try #require(publishedPid(at: pidFile), "the child never published its pid")
        #expect(hasExited(pid), "the child outlived the failure it caused")
    }

    /// `closesStdinThenLingers`, but deaf to SIGTERM — the child the failed-delivery teardown's
    /// SIGKILL branch exists for. `exec 0<&-` closes stdin so the parent's write takes EPIPE
    /// while the child is alive; the loop keeps `sh` from exec'ing away its own trap.
    private static let closesStdinIgnoresTermAndLingers = #"""
        trap '' TERM; echo $$ > "$0"; exec 0<&-; while :; do sleep 0.2; done
        """#

    @Test("a failed delivery escalates to SIGKILL when the lingering child ignores SIGTERM")
    func stdinFormEscalatesPastAnIgnoredTerminateAfterAFailedDelivery() throws {
        // `stdinFormEndsAChildThatOutlivesTheFailedDelivery` proves the teardown runs, but its
        // child dies on SIGTERM, so the SIGKILL branch of that teardown never executed under
        // test. Delete the escalation and that test stays green while this child lives on
        // forever, reparented to launchd, still holding both output pipes.
        let pidFile = try scratch.directory().appendingPathComponent("pid")
        // If the escalation IS missing, the launcher returns (launchFailed after its graces)
        // with the TERM-deaf child still alive — `launchBounded` only reaps on a hang. Reap it
        // here so a red run does not leak a forever-looping shell into the rest of the suite.
        defer { reapIfLeaked(pidFile) }
        let started = Date()
        let error = #expect(throws: AppleScriptRunner.RunError.self) {
            _ = try launchBounded(ScriptInvocation(
                executablePath: "/bin/sh",
                arguments: ["-c", Self.closesStdinIgnoresTermAndLingers, pidFile.path],
                delivery: .stdin(script: String(repeating: "a", count: 256 * 1024))),
                                  pidFile: pidFile, seconds: 20)
        }
        guard case .launchFailed = try #require(error) else {
            Issue.record("expected launchFailed"); return
        }
        // Bounded by the ladder: 0.05s initial, 0.5s after SIGTERM, 1s after SIGKILL.
        #expect(Date().timeIntervalSince(started) < 15,
                "the failed delivery waited on the child instead of ending it")
        let pid = try #require(publishedPid(at: pidFile), "the child never published its pid")
        #expect(hasExited(pid), "the TERM-ignoring child outlived the failed delivery")
    }

    @Test("under a deadline, a failed delivery is still reported at once — not as a timeout")
    func timedStdinFormReportsAFailedDeliveryImmediately() throws {
        // The mirror of the blocked-write case. The child closes stdin at t≈0 and lingers; the
        // write takes EPIPE at once. A launcher that consulted the delivery only after the
        // deadline would sit out the full 30s here and then call it a TIMEOUT — and a Mail
        // caller would tell the user to go hunting in Sent for a script the interpreter never
        // saw. It must be `launchFailed`, and it must be fast.
        let pidFile = try scratch.directory().appendingPathComponent("pid")
        defer { reapIfLeaked(pidFile) }
        let started = Date()
        let error = #expect(throws: AppleScriptRunner.RunError.self) {
            _ = try launchBounded(ScriptInvocation(
                executablePath: "/bin/sh",
                arguments: ["-c", Self.closesStdinThenLingers, pidFile.path],
                delivery: .timedStdin(script: String(repeating: "a", count: 256 * 1024),
                                      seconds: 30)),
                                  pidFile: pidFile, seconds: 20)
        }
        guard case .launchFailed = try #require(error) else {
            Issue.record("expected launchFailed, not a timeout"); return
        }
        #expect(Date().timeIntervalSince(started) < 10,
                "the delivery failure waited for the deadline instead of being reported")
        let pid = try #require(publishedPid(at: pidFile), "the child never published its pid")
        #expect(hasExited(pid), "the child outlived the failure it caused")
    }

    @Test("the bound covers the output drain: a descendant holding the pipe past exit is a timeout")
    func timedStdinFormBoundsTheDrainAfterExit() throws {
        // Child exit is not EOF. This child reads the script, backgrounds a `sleep` that
        // inherits stdout and stderr, and exits 0 at once. A bound that covered only the wait
        // for termination would now sit in `collected()` until the descendant let go — six
        // seconds here, unbounded for a real `do shell script` daemon. The deadline must
        // expire in the DRAIN and surface as `TimeoutError`, well before the descendant exits.
        // 2s rather than 0.5s so the child reliably reaches `exit 0` inside the bound on a
        // loaded machine — a deadline that expires in the wake loop instead would throw the
        // same error from the wrong place and prove nothing about the drain.
        // The descendant publishes its own pid (`$!` → `$1`) and is short-lived on purpose; the
        // test then waits for it to be gone, so it cannot outlive the test even if group cleanup regresses.
        let dir = try scratch.directory()
        let pidFile = dir.appendingPathComponent("pid")
        let descendantPidFile = dir.appendingPathComponent("descendant-pid")
        let started = Date()
        let error = #expect(throws: AppleScriptRunner.TimeoutError.self) {
            _ = try launchBounded(ScriptInvocation(
                executablePath: "/bin/sh",
                arguments: ["-c", #"echo $$ > "$0"; cat >/dev/null; sleep 6 & echo $! > "$1"; exit 0"#,
                            pidFile.path, descendantPidFile.path],
                delivery: .timedStdin(script: "x", seconds: 2)),
                                  pidFile: pidFile, seconds: 20)
        }
        #expect(try #require(error).seconds == 2)
        #expect(Date().timeIntervalSince(started) < 4,
                "the drain waited for the descendant instead of honouring the deadline")
        let descendant = try #require(publishedPid(at: descendantPidFile),
                                      "the child never published its descendant's pid")
        #expect(hasExited(descendant, within: 10), "the bounded descendant should have stopped")
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
    /// A deadlock regression must FAIL — a plain call would block this thread forever and hang
    /// the suite with no verdict, which reads as an infrastructure problem rather than the bug
    /// it is.
    ///
    /// On expiry the child must be KILLED and the worker joined before the failure is reported:
    /// abandoning them leaks a live subprocess plus its pipe descriptors into every test that
    /// runs afterwards — and that subprocess is the one already established to be sitting on a
    /// full pipe forever. `pidFile` is where the child publishes its own pid (via `$0` in its
    /// argv); without one there is nothing to kill, because the `Process` is owned inside the
    /// launcher and no handle to it crosses the seam.
    private func launchBounded(_ invocation: ScriptInvocation,
                               pidFile: URL,
                               seconds: TimeInterval = 60) throws -> ScriptOutcome {
        final class Box: @unchecked Sendable { var result: Result<ScriptOutcome, any Error>? }
        let box = Box()
        let finished = DispatchSemaphore(value: 0)
        let launcher = self.launcher
        DispatchQueue(label: "apple-cli.test.launch-bounded").async {
            box.result = Result { try launcher.launch(invocation) }
            finished.signal()
        }
        if finished.wait(timeout: .now() + seconds) != .success {
            // SIGKILL, not SIGTERM: this child is wedged writing to a pipe nobody drains, and a
            // handler it may never reach is no use here. Killing it closes its ends of the pipes,
            // which is what lets the abandoned worker finish and be joined.
            //
            // The pid was written by the child up to `seconds` ago, so it may already have exited
            // and had its number recycled. `isOwnChild` closes that window: a recycled pid is
            // overwhelmingly unlikely to ALSO be a direct child of this process. `pid > 1` is
            // belt-and-braces — `$$` is always positive, but `kill(-1, …)` would signal every
            // process this user can reach, and the guard costs one comparison.
            let pid = publishedPid(at: pidFile, within: 1)
            if let pid, pid > 1, isOwnChild(pid) { _ = Darwin.kill(pid, SIGKILL) }
            let joined = finished.wait(timeout: .now() + 10) == .success
            Issue.record("""
                the launch did not finish within \(Int(seconds))s — the child's stdout and \
                stderr are not being drained concurrently\
                \(pid == nil ? " (no pid was published, so nothing could be killed)" : "")\
                \(joined ? "" : " (and the worker did not finish even after the child was killed)")
                """)
            throw LaunchDidNotFinish()
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
        let program = #"""
import os, signal
signal.signal(signal.SIGALRM, signal.SIG_DFL)
signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGALRM})
signal.alarm(5)
os.write(1, b"123456789")
signal.pause()
"""#
        let launcher = OsascriptLauncher(captureDirectory: try scratch.directory())
        let started = Date()
        let failure = try #require(#expect(throws: ScriptOutputLimitExceeded.self) {
            _ = try launcher.launch(ScriptInvocation(executablePath: "/usr/bin/python3",
                arguments: ["-I", "-S", "-c", program],
                delivery: .timedStdin(script: String(repeating: "x", count: 262_144), seconds: 3),
                maximumOutputBytes: 8))
        })
        #expect(failure.maximumOutputBytes == 8)
        #expect(Date().timeIntervalSince(started) < 3,
                "overflow must stop the pending write without waiting for the script deadline")
    }
    // Harmless fixed Python fixture, no subprocesses or Apple operations. Its independent
    // alarm bounds even untimed launcher regressions; no test signals a numeric process ID.
    private static let program = #"""
import os, signal, sys
signal.signal(signal.SIGALRM, signal.SIG_DFL)
signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGALRM})
signal.alarm(5)
os.write(1, bytes.fromhex(sys.argv[1]))
os.write(2, bytes.fromhex(sys.argv[2]))
os._exit(int(sys.argv[3]))
"""#

    private func invocation(mode: Int, output: Data, error: Data,
                            limit: Int?, status: Int = 0) -> ScriptInvocation {
        let delivery: ScriptDelivery
        switch mode {
        case 0: delivery = .inline
        case 1: delivery = .timed(seconds: 3)
        case 2: delivery = .stdin(script: "")
        default: delivery = .timedStdin(script: "", seconds: 3)
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
