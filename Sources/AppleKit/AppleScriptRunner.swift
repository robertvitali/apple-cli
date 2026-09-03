import Foundation
import Darwin

private final class UnlinkedCaptureFile {
    let handle: FileHandle

    init(in directory: URL) throws {
        let captureURL = directory.appendingPathComponent("apple-cli-osascript.XXXXXX")
        var template = Array(captureURL.path.utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { buffer in
            mkstemp(buffer.baseAddress!)
        }
        guard descriptor >= 0 else {
            throw AppleScriptRunner.RunError.launchFailed("cannot create private output capture")
        }
        let unlinked = template.withUnsafeBufferPointer { buffer in
            unlink(buffer.baseAddress!)
        }
        guard unlinked == 0 else {
            close(descriptor)
            throw AppleScriptRunner.RunError.launchFailed("cannot unlink private output capture")
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func read() throws -> Data {
        try handle.seek(toOffset: 0)
        return try handle.readToEnd() ?? Data()
    }
}

/// Reads one of a child's output pipes to EOF on a thread of its own, started at construction.
///
/// WHY BOTH PIPES MUST BE DRAINED AT ONCE: a child writes stdout and stderr independently, and
/// either pipe stops the child once its (~64 KiB) kernel buffer fills. Draining one to EOF and
/// only THEN reading the other deadlocks whenever the child fills the second pipe first — the
/// parent waits for an EOF only a finished child can send, and the child waits for buffer room
/// only the parent can make, forever. Neither stream's size is under this tool's control:
/// `osascript` writes whatever the targeted Apple app hands back, on either stream.
///
/// `collected()` waits on the dispatch group before touching `data`, so the read is ordered
/// after the write it observes.
private final class PipeDrain: @unchecked Sendable {
    private let group = DispatchGroup()
    private let queue: DispatchQueue
    private var data = Data()

    init(_ handle: FileHandle, label: String) {
        queue = DispatchQueue(label: "apple-cli.osascript.\(label)")
        queue.async(group: group) { [self] in
            data = handle.readDataToEndOfFile()
        }
    }

    /// Blocks (`group.wait()`) until the pipe reached EOF, then yields everything it held.
    func collected() -> Data {
        group.wait()
        return data
    }
}

/// How the script source reaches the interpreter, and whether a wall-clock deadline bounds the
/// run. One enum rather than a pair of independent fields because the two are NOT independent:
/// a struct carrying `stdinScript` and `timeout` side by side can express a combination the
/// launcher cannot honour — it would take the stdin path and silently drop the deadline. The
/// illegal state is unspellable here instead.
enum ScriptDelivery: Equatable {
    /// Source rides in `arguments` behind `-e`, with no host-side deadline.
    case inline
    /// Source rides in `arguments` behind `-e`, bounded by a wall-clock deadline in seconds.
    /// `AppleScriptRunner` validates the value before building an invocation, so the launcher
    /// receives only a finite, positive, in-range figure.
    case timed(seconds: TimeInterval)
    /// Source is delivered on stdin (the `osascript -` form); `arguments` stay opaque argv.
    case stdin(script: String)
}

/// One invocation, exactly as it will be handed to the process.
///
/// THE SEAM. `AppleScriptRunner` decides WHAT to run — and owns the security rule that user
/// data travels only as argv — while a `ScriptLaunching` starts it. Splitting the two makes
/// the argv rule assertable directly: a test reads back the invocation the runner built and
/// checks that hostile text landed in `arguments` and nowhere in the script source, instead
/// of inferring it from a live `osascript`'s behaviour.
///
/// Deliberately NOT public. Nothing outside this module can construct one, so the seam adds
/// no caller-reachable way to choose what gets executed.
struct ScriptInvocation: Equatable {
    /// The interpreter. `AppleScriptRunner` ALWAYS leaves this at `/usr/bin/osascript`; it is
    /// a field rather than a constant only so `OsascriptLauncher`'s own process handling can
    /// be exercised against a trivial system binary.
    let executablePath: String
    /// Full argv AFTER the executable — verbatim what the process receives.
    let arguments: [String]
    /// Where the source travels and whether a deadline applies. Exactly one of the three
    /// shapes, so no invocation can ask for two at once.
    let delivery: ScriptDelivery

    init(executablePath: String = AppleScriptRunner.osascriptPath,
         arguments: [String],
         delivery: ScriptDelivery = .inline) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.delivery = delivery
    }
}

/// What a finished invocation yielded: exit status plus both streams, undecoded. Decoding and
/// the non-zero-status mapping belong to `AppleScriptRunner`, so every form shares one.
struct ScriptOutcome: Equatable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
}

/// Starts a `ScriptInvocation` and reports its outcome. Production binds `OsascriptLauncher`.
protocol ScriptLaunching: Sendable {
    func launch(_ invocation: ScriptInvocation) throws -> ScriptOutcome
}

/// The production launcher: a real `Process`, with stdin CLOSED unless the invocation carries
/// a script for it.
///
/// The three shapes below are the three the tool actually uses, and the invocation's
/// `delivery` names exactly one of them.
struct OsascriptLauncher: ScriptLaunching {
    /// Directory the deadline form creates its unlinked capture files in. Production ALWAYS
    /// leaves this at the process temporary directory (`TMPDIR`) — `AppleScriptRunner.init()`
    /// binds `OsascriptLauncher()` and never names one. It is a parameter only so the test that
    /// asserts a timed run leaves no named temp behind can watch a directory nothing else
    /// writes to, instead of set-differencing the shared temp root against every concurrent
    /// process on the machine.
    let captureDirectory: URL

    init(captureDirectory: URL = FileManager.default.temporaryDirectory) {
        self.captureDirectory = captureDirectory
    }

    func launch(_ invocation: ScriptInvocation) throws -> ScriptOutcome {
        switch invocation.delivery {
        case .inline: return try launchPiped(invocation)
        case .timed(let seconds): return try launchWithDeadline(invocation, seconds)
        case .stdin(let script): return try launchWithScriptOnStdin(invocation, script)
        }
    }

    /// Pipes for both output streams, stdin closed, no deadline.
    private func launchPiped(_ invocation: ScriptInvocation) throws -> ScriptOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executablePath)
        process.arguments = invocation.arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice // stdin closed — never hang

        do {
            try process.run()
        } catch {
            throw AppleScriptRunner.RunError.launchFailed(String(describing: error))
        }
        // BOTH streams are drained concurrently, and both before the wait. Reading either one
        // to EOF first would deadlock a child that fills the other in the meantime — see
        // `PipeDrain`. Waiting only after both reached EOF keeps the exit status exact.
        let errDrain = PipeDrain(stderrPipe.fileHandleForReading, label: "piped-stderr")
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errDrain.collected()
        process.waitUntilExit()
        return ScriptOutcome(terminationStatus: process.terminationStatus,
                             standardOutput: outData, standardError: errData)
    }

    /// Regular files are used for output instead of pipes so a large result cannot fill a pipe
    /// while this thread waits for termination. Each mode-0600 file is created in
    /// `captureDirectory` (production: the process temporary directory, `TMPDIR`, normally
    /// macOS's per-user Darwin temp directory) and
    /// unlinked before osascript starts. It has a pathname only for the short
    /// `mkstemp`→`unlink` window, before live Apple data can be written, and is reclaimed by the
    /// kernel when the handles close.
    private func launchWithDeadline(_ invocation: ScriptInvocation,
                                    _ seconds: TimeInterval) throws -> ScriptOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executablePath)
        process.arguments = invocation.arguments

        let outFile = try UnlinkedCaptureFile(in: captureDirectory)
        let errFile = try UnlinkedCaptureFile(in: captureDirectory)
        process.standardOutput = outFile.handle
        process.standardError = errFile.handle
        process.standardInput = FileHandle.nullDevice

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        do {
            try process.run()
        } catch {
            throw AppleScriptRunner.RunError.launchFailed(String(describing: error))
        }

        let deadline = DispatchTime.now() + seconds
        if terminated.wait(timeout: deadline) == .timedOut {
            var cleanup = terminated.wait(timeout: .now())
            if cleanup == .timedOut, process.isRunning {
                process.terminate()
                cleanup = terminated.wait(timeout: .now() + 1)
            }
            if cleanup == .timedOut, process.isRunning {
                // Foundation exposes no race-free process handle for the KILL escalation. The
                // liveness check narrows, but cannot eliminate, the same-user PID-reuse window
                // between child exit/reap and kill(2); macOS Process has no stronger primitive.
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                cleanup = terminated.wait(timeout: .now() + 1)
            }
            if cleanup == .success {
                process.waitUntilExit()
            }
            // If a child remains uninterruptible even after SIGKILL, do not turn the deadline
            // into another unbounded wait. The unlinked captures retain no filesystem names and
            // the kernel reclaims them when the child eventually exits.
            throw AppleScriptRunner.TimeoutError(seconds: seconds)
        }

        process.waitUntilExit()
        return ScriptOutcome(terminationStatus: process.terminationStatus,
                             standardOutput: try outFile.read(),
                             standardError: try errFile.read())
    }

    /// The script travels on stdin (`osascript -`); `arguments` are still opaque argv. The
    /// source arrives as a parameter, from the `.stdin` case's payload, so there is no
    /// "delivered on stdin but no script" state to fall open on.
    private func launchWithScriptOnStdin(_ invocation: ScriptInvocation,
                                         _ script: String) throws -> ScriptOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executablePath)
        process.arguments = invocation.arguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinWriter = stdinPipe.fileHandleForWriting
        // A child that exits before reading the whole script leaves this side writing into a
        // pipe with no reader. That must arrive as an ERROR, not as SIGPIPE — whose default
        // action kills this process outright, taking down a CLI run (or a whole test suite)
        // with no diagnosable failure. `F_SETNOSIGPIPE` scopes the suppression to THIS
        // descriptor, so the launcher does not depend on the caller having ignored the signal
        // process-wide (`Apple.swift` does, but `AppleKit` is a library and cannot assume it).
        //
        // Armed BEFORE the child exists, so a failure costs nothing to report: there is no
        // process to tear down yet. The call cannot fail for this descriptor — `F_SETNOSIGPIPE`
        // rejects only a bad file descriptor (EBADF), and this one was just produced by `Pipe()`
        // and has not been closed — but it is checked rather than discarded, because the one
        // world in which it DOES fail is the world in which the write below kills the process.
        if fcntl(stdinWriter.fileDescriptor, F_SETNOSIGPIPE, 1) == -1 {
            throw AppleScriptRunner.RunError.launchFailed(
                "could not arm the stdin pipe against SIGPIPE: errno \(errno)")
        }

        // Exit is observed through the termination handler, not by polling `isRunning`: the
        // handler fires once and cannot be missed, whereas `isRunning` still reports true for a
        // child that has exited but not yet been collected — the exact state an EPIPE'd write
        // leaves behind, and the state in which signalling its pid is a pid-reuse hazard.
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        do {
            try process.run()
        } catch {
            throw AppleScriptRunner.RunError.launchFailed(String(describing: error))
        }
        // Both output streams start draining BEFORE the stdin write, so a child that answers
        // early — filling either pipe while this side is still writing — cannot wedge the
        // write, and neither stream can wedge the other (see `PipeDrain`).
        let outDrain = PipeDrain(stdoutPipe.fileHandleForReading, label: "stdin-form-stdout")
        let errDrain = PipeDrain(stderrPipe.fileHandleForReading, label: "stdin-form-stderr")

        // Hand osascript the script on stdin, then close it (EOF) so compilation begins.
        // `write(contentsOf:)`, not `write(_:)`: the latter reports failure by raising an
        // Objective-C exception, which Swift cannot catch — the same reason `Output.write`
        // routes its own EPIPE through a throwing call.
        var deliveryFailure: (any Error)?
        do {
            try stdinWriter.write(contentsOf: Data(script.utf8))
        } catch {
            deliveryFailure = error
        }
        do {
            try stdinWriter.close()
        } catch {
            // A close that fails leaves the child without its EOF, so it may read forever — and
            // this form carries no deadline. Treated exactly like a failed write so the teardown
            // below runs, rather than becoming an unbounded wait in `collected()`.
            deliveryFailure = deliveryFailure ?? error
        }
        if let deliveryFailure {
            // The script never arrived, so there is nothing left to wait FOR — and waiting is not
            // safe. A child may close (or simply never read) stdin and live on holding stdout and
            // stderr open, in which case the drains would never see EOF and this call would hang
            // forever on a failure it has already diagnosed. End the child instead, giving SIGTERM
            // a short grace so one that handles it can shut down on its own terms, then escalate to
            // SIGKILL.
            //
            // The `isRunning` re-checks narrow, but cannot eliminate, the same-user PID-reuse
            // window between child exit/reap and the signal — the identical limit
            // `launchWithDeadline` documents, and for the identical reason: macOS `Process`
            // exposes no race-free handle to signal through.
            var cleanup = terminated.wait(timeout: .now() + 0.05)
            if cleanup == .timedOut, process.isRunning {
                process.terminate()
                cleanup = terminated.wait(timeout: .now() + 0.5)
            }
            if cleanup == .timedOut, process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 1)
            }
            // Do NOT collect()/waitUntilExit() on this path. The captures are discarded by the
            // throw below, and `collected()` is a `group.wait()` on a read-to-EOF that only
            // returns once the child's write ends close — which never happens if the child was not
            // actually reaped (uninterruptible D-state, or a grandchild that inherited the pipe).
            // Collecting here would reintroduce exactly the unbounded wait this teardown exists to
            // prevent, on a form that carries no deadline — the same wait `launchWithDeadline`
            // refuses to convert its bound into. Fail fast instead; any still-running drain thread
            // finishes on its own once the fds close.
            //
            // The script never reached the interpreter, so whatever the child did exit with is not
            // an answer to it — reported as a launch failure rather than mapped through
            // `result(of:)`, which would otherwise turn an exit 0 into a silent empty success.
            throw AppleScriptRunner.RunError.launchFailed(
                "could not deliver script on stdin: \(String(describing: deliveryFailure))")
        }
        let outData = outDrain.collected()
        let errData = errDrain.collected()
        process.waitUntilExit()
        return ScriptOutcome(terminationStatus: process.terminationStatus,
                             standardOutput: outData, standardError: errData)
    }
}

/// Runs AppleScript via `/usr/bin/osascript` with stdin CLOSED unless the invocation carries a
/// script for it (`runViaStdin`, the `osascript -` form) — so the `-e` forms can never block on
/// input, and the stdin form blocks only on a script this type supplied itself.
///
/// SECURITY — the load-bearing rule for all six domains: user/data-derived text
/// (recipients, bodies, search terms, note/contact content) MUST be passed as
/// `arguments:` (osascript argv → the script's `on run argv` handler), NEVER
/// string-interpolated into the script source. AppleScript injection here is RCE-class
/// (`do shell script`, cross-recipient send, data exfil). Where a value genuinely must
/// be embedded (rare), route it through `quote(_:)` — never ad-hoc per domain.
///
/// The process launch itself lives behind `ScriptLaunching` (production: `OsascriptLauncher`),
/// so the argv rule above is checkable without a live `osascript`. The seam is module-internal
/// and the public `init()` binds the real launcher, so nothing about a production run changes.
public struct AppleScriptRunner: AppleScriptRunning {
    public enum RunError: Error, CustomStringConvertible {
        case launchFailed(String)
        case scriptFailed(status: Int32, stderr: String)
        public var description: String {
            switch self {
            case .launchFailed(let m): return "osascript launch failed: \(m)"
            case .scriptFailed(let s, _): return "osascript exited \(s)" // stderr kept off the public message (info-leak)
            }
        }
    }

    public struct TimeoutError: Error, CustomStringConvertible {
        public let seconds: TimeInterval
        public init(seconds: TimeInterval) { self.seconds = seconds }
        public var description: String {
            let value = Int(exactly: seconds).map(String.init) ?? String(seconds)
            return "osascript timed out after \(value)s"
        }
    }

    public static let maximumTimeoutSeconds: TimeInterval = 86_400

    public struct InvalidTimeoutError: Error, CustomStringConvertible {
        public let seconds: TimeInterval
        public init(seconds: TimeInterval) { self.seconds = seconds }
        public var description: String { "invalid osascript timeout: \(seconds)" }
    }

    /// The one interpreter this type ever names.
    static let osascriptPath = "/usr/bin/osascript"

    private let launcher: any ScriptLaunching

    public init() { self.init(launcher: OsascriptLauncher()) }

    /// Module-internal seam. Production never calls this; `init()` is the only public spelling
    /// and it binds `OsascriptLauncher`.
    init(launcher: any ScriptLaunching) { self.launcher = launcher }

    /// The argv every `-e` form builds: the script source, then `--`, then the caller's data.
    ///
    /// `--` ends osascript's OPTION parsing, so a value that happens to start with `-`
    /// (e.g. `-l`, `-e`, `-s`) is passed as positional argv (`on run argv`), never an
    /// osascript option — closing an argument-injection gap (CWE-88) in this shared sink.
    /// Array args → no shell, no re-splitting; user data never re-enters script source.
    static func dashEArguments(script: String, arguments: [String]) -> [String] {
        ["-e", script, "--"] + arguments
    }

    /// The shared tail every form runs: a non-zero status becomes `scriptFailed` carrying the
    /// raw stderr, otherwise stdout is decoded as UTF-8 and trimmed.
    static func result(of outcome: ScriptOutcome) throws -> String {
        // KNOWINGLY UNTESTED, and pre-existing: a child killed by a SIGNAL rather than an exit
        // arrives here as `Process.terminationStatus` holding the SIGNAL NUMBER, so the message
        // reads "osascript exited 9" for a SIGKILL. `Process.terminationReason` distinguishes
        // the two, and this mapping does not consult it. Left alone deliberately — changing the
        // rendering would change a user-visible error string, which is a contract change and
        // belongs in its own reviewed batch, not in a test-coverage lane.
        if outcome.terminationStatus != 0 {
            throw RunError.scriptFailed(status: outcome.terminationStatus,
                                        stderr: String(decoding: outcome.standardError, as: UTF8.self))
        }
        return String(decoding: outcome.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Execute an AppleScript. `arguments` are passed as opaque `osascript` argv (available
    /// to the script as `on run argv`) — this is the safe path for all user data. Returns
    /// trimmed stdout.
    public func run(_ script: String, arguments: [String] = []) throws -> String {
        let invocation = ScriptInvocation(
            arguments: AppleScriptRunner.dashEArguments(script: script, arguments: arguments))
        return try AppleScriptRunner.result(of: try launcher.launch(invocation))
    }

    /// Execute an AppleScript with a host-side wall-clock deadline. This overload is opt-in:
    /// existing callers retain their current behavior, while operations whose Apple-event
    /// handlers can swallow a per-event timeout can still impose an overall process bound.
    ///
    /// The deadline is validated BEFORE anything is launched, so an out-of-range value never
    /// starts a process it would then have to tear down.
    public func run(_ script: String, arguments: [String] = [],
                    timeout seconds: TimeInterval) throws -> String {
        guard seconds.isFinite, seconds > 0,
              seconds <= AppleScriptRunner.maximumTimeoutSeconds else {
            throw InvalidTimeoutError(seconds: seconds)
        }
        let invocation = ScriptInvocation(
            arguments: AppleScriptRunner.dashEArguments(script: script, arguments: arguments),
            delivery: .timed(seconds: seconds))
        return try AppleScriptRunner.result(of: try launcher.launch(invocation))
    }

    /// Execute an AppleScript passed via STDIN (`osascript -`) instead of `-e`. Required
    /// ONLY for scripts with a top-level `use framework` (AppleScriptObjC) header, which the
    /// `-e` form does not reliably compile. `arguments` are still opaque argv (`on run argv`)
    /// — the safe path for user data. Empirically (macOS `osascript`), the `-` file operand
    /// ends option parsing, so every trailing arg is delivered as argv even if it begins with
    /// `-` (no `--` terminator needed, and `--` would itself become argv item 1). Prefer
    /// `run(_:arguments:)`; reach for this only for the rare AppleScriptObjC case.
    /// Deliver `script` to `osascript -` on stdin (the AppleScriptObjC / `use framework` form).
    /// Intentionally UNBOUNDED: this form carries no wall-clock deadline, so a child that reads the
    /// script and then never exits or closes stdout blocks the caller indefinitely. It is also the
    /// most deadlock-exposed shape (two live pipes plus a parent-side stdin write), so a caller on a
    /// hang-prone path should prefer the `-e` `run(_:arguments:timeout:)` form. A bounded stdin
    /// overload is a tracked follow-up. Concurrent stdout/stderr drains keep the two streams from
    /// wedging each other and the write (see `launchWithScriptOnStdin`).
    public func runViaStdin(_ script: String, arguments: [String] = []) throws -> String {
        let invocation = ScriptInvocation(arguments: ["-"] + arguments,
                                          delivery: .stdin(script: script))
        return try AppleScriptRunner.result(of: try launcher.launch(invocation))
    }

    /// Escape a string literal for the RARE case a value must be embedded directly in
    /// script source. Prefer `run(_:arguments:)` over this.
    public static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
