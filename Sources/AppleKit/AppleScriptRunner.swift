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
/// `collected()` waits on the dispatch group before touching `result`, so the read is ordered
/// after the write it observes.
///
/// The read is the THROWING `readToEnd()`, never `readDataToEndOfFile()`: the latter reports a
/// read failure (EIO, EBADF) by raising an Objective-C exception, which Swift cannot catch — and
/// on this background queue an uncaught exception aborts the whole process. The same asymmetry
/// the stdin write side already closed (`write(contentsOf:)` over `write(_:)`). A failed read
/// is held here and re-thrown by `collected()`, so it reaches the caller as an ordinary error.
/// Module-internal (not private) only so the throw can be pinned with a handle that cannot be
/// read, without a child process to provoke the failure.
final class PipeDrain: @unchecked Sendable {
    private let group = DispatchGroup()
    private let queue: DispatchQueue
    private let label: String
    private var result: Result<Data, any Error> = .success(Data())

    init(_ handle: FileHandle, label: String) {
        self.label = label
        queue = DispatchQueue(label: "apple-cli.osascript.\(label)")
        queue.async(group: group) { [self] in
            result = Result { try handle.readToEnd() ?? Data() }
        }
    }

    /// Blocks (`group.wait()`) until the pipe reached EOF, then yields everything it held — or
    /// throws the read failure that ended the drain early.
    func collected() throws -> Data {
        group.wait()
        return try held()
    }

    /// `collected()` with an absolute expiry: `nil` when the pipe had not reached EOF by
    /// `deadline`. A child's EXIT does not imply EOF — a descendant that inherited the write end
    /// (an osascript `do shell script` that backgrounded something) keeps the pipe open after
    /// the child is gone — so a bounded form must bound this wait too, not only the wait for
    /// termination. On `nil` the drain thread stays blocked, holding its handle, until whoever
    /// holds the write end lets go.
    func collected(by deadline: DispatchTime) throws -> Data? {
        guard group.wait(timeout: deadline) == .success else { return nil }
        return try held()
    }

    private func held() throws -> Data {
        do {
            return try result.get()
        } catch {
            throw OsascriptLauncher.outputReadFailure(label, error)
        }
    }
}

/// Writes the script to the child's stdin and closes it (EOF), on a thread of its own, started
/// at construction.
///
/// On its own thread so a wall-clock deadline can fire DURING the write: a child that reads
/// none of its stdin blocks a write larger than the (~64 KiB) pipe buffer indefinitely, and a
/// deadline waited on from the same thread as that write could never expire. Ending the child
/// closes its read end, at which point the write takes EPIPE and this thread finishes on its own.
///
/// `write(contentsOf:)`, not `write(_:)`: the latter reports failure by raising an Objective-C
/// exception, which Swift cannot catch — the same reason `Output.write` routes its own EPIPE
/// through a throwing call.
///
/// Completion is PUSHED (`onFinish`) rather than only waited on, so the launcher can wait for
/// "delivery finished OR child exited OR deadline" as one event and react to a failed delivery
/// the moment it happens — not after a deadline that has nothing to do with it.
private final class StdinFeeder: @unchecked Sendable {
    enum State {
        case pending
        /// The script arrived whole and the child saw EOF.
        case delivered
        case failed(any Error)
    }

    private let queue = DispatchQueue(label: "apple-cli.osascript.stdin-feeder")
    private let lock = NSLock()
    private var current: State = .pending

    init(_ handle: FileHandle, script: String, onFinish: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            var failure: (any Error)?
            do {
                try handle.write(contentsOf: Data(script.utf8))
            } catch {
                failure = error
            }
            do {
                try handle.close()
            } catch {
                // A close that fails leaves the child without its EOF, so it may read forever.
                // Treated exactly like a failed write so the caller's teardown runs.
                failure = failure ?? error
            }
            lock.withLock { current = failure.map(State.failed) ?? .delivered }
            onFinish()
        }
    }

    /// The delivery's state right now; final once `onFinish` has fired.
    var state: State { lock.withLock { current } }
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
    /// Source is delivered on stdin, bounded by a wall-clock deadline in seconds — the stdin
    /// counterpart of `.timed`. Validated by `AppleScriptRunner` the same way, so the launcher
    /// receives only a finite, positive, in-range figure.
    case timedStdin(script: String, seconds: TimeInterval)
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
    /// Where the source travels and whether a deadline applies. Exactly one of the four
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
/// The shapes below are the ones the tool actually uses, and the invocation's `delivery` names
/// exactly one of them.
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
        case .stdin(let script): return try launchWithScriptOnStdin(invocation, script, deadline: nil)
        case .timedStdin(let script, let seconds):
            return try launchWithScriptOnStdin(invocation, script, deadline: seconds)
        }
    }

    /// The `Process` every form starts from: the invocation's interpreter and verbatim argv.
    private static func makeProcess(_ invocation: ScriptInvocation) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executablePath)
        process.arguments = invocation.arguments
        return process
    }

    /// Starts `process`, reporting a failed spawn as `launchFailed`.
    private static func start(_ process: Process) throws {
        do {
            try process.run()
        } catch {
            throw AppleScriptRunner.RunError.launchFailed(String(describing: error))
        }
    }

    /// A read of the child's output that failed outright (EIO, EBADF) — as opposed to output
    /// that is merely non-zero-status. Mapped to `launchFailed` rather than `scriptFailed`
    /// because no usable outcome exists: the status may be fine, but the stream it would be
    /// judged against was lost, and reporting a status without its output would let an exit 0
    /// pass as a silent empty success. `launchFailed` is also the case no domain ever retries.
    static func outputReadFailure(_ stream: String, _ error: any Error) -> AppleScriptRunner.RunError {
        .launchFailed("could not read osascript \(stream): \(String(describing: error))")
    }

    /// The grace periods of the one SIGTERM → SIGKILL ladder, in seconds.
    private struct EndGraces {
        /// How long to wait for a child that may already be on its way out before signalling.
        /// `0` is a single non-blocking poll of the termination signal, not "skip the check".
        let initial: TimeInterval
        /// How long SIGTERM gets before escalation.
        let term: TimeInterval
        /// How long SIGKILL gets before the child is given up on.
        let kill: TimeInterval
    }

    /// Ends a child this launcher is done waiting for: a brief initial wait (it may already be
    /// exiting), then SIGTERM with a grace so a child that handles it can shut down on its own
    /// terms, then SIGKILL. Returns whether the child is KNOWN to have terminated — its
    /// termination handler fired — so a caller can reap it; `false` means it stayed
    /// uninterruptible past both signals, and the caller must not turn that into another
    /// unbounded wait.
    ///
    /// ONE ladder for every form, so a future change to how a child is ended (a process-group
    /// kill, say) lands once. The `isRunning` re-checks narrow, but cannot eliminate, the
    /// same-user PID-reuse window between child exit/reap and the signal: Foundation exposes no
    /// race-free process handle to signal through, and macOS `Process` has no stronger
    /// primitive.
    ///
    /// `terminated` must not have been consumed by a successful wait already — this ladder waits
    /// on it itself. A caller whose wait DID succeed knows the child exited and skips the ladder.
    private static func endChild(_ process: Process, terminated: DispatchSemaphore,
                                 graces: EndGraces) -> Bool {
        var cleanup = terminated.wait(timeout: .now() + graces.initial)
        if cleanup == .timedOut, process.isRunning {
            process.terminate()
            cleanup = terminated.wait(timeout: .now() + graces.term)
        }
        if cleanup == .timedOut, process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            cleanup = terminated.wait(timeout: .now() + graces.kill)
        }
        return cleanup == .success
    }

    /// Pipes for both output streams, stdin closed, no deadline.
    private func launchPiped(_ invocation: ScriptInvocation) throws -> ScriptOutcome {
        let process = Self.makeProcess(invocation)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice // stdin closed — never hang

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        try Self.start(process)
        // BOTH streams are drained concurrently, and both before the wait. Reading either one
        // to EOF first would deadlock a child that fills the other in the meantime — see
        // `PipeDrain`. Waiting only after both reached EOF keeps the exit status exact.
        let errDrain = PipeDrain(stderrPipe.fileHandleForReading, label: "piped-stderr")
        let outData: Data
        let errData: Data
        do {
            // The throwing read, for the reason `PipeDrain` gives: `readDataToEndOfFile()`
            // raises an uncatchable Objective-C exception on a failed read.
            do {
                outData = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
            } catch {
                throw Self.outputReadFailure("stdout", error)
            }
            errData = try errDrain.collected()
        } catch {
            // A read that failed outright leaves a child that may still be running with no
            // one reading its output. End it rather than abandon it — every other failure path
            // in this launcher does — then report the read failure, not the child's status.
            // The stderr drain is not collected on this path; its thread finishes once the
            // ended child's write end closes (or stays blocked if the child proved
            // uninterruptible — the same accepted limit as the stdin form's teardown).
            _ = Self.endChild(process, terminated: terminated,
                              graces: EndGraces(initial: 0.05, term: 0.5, kill: 1))
            throw error
        }
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
        let process = Self.makeProcess(invocation)

        let outFile = try UnlinkedCaptureFile(in: captureDirectory)
        let errFile = try UnlinkedCaptureFile(in: captureDirectory)
        process.standardOutput = outFile.handle
        process.standardError = errFile.handle
        process.standardInput = FileHandle.nullDevice

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        try Self.start(process)

        let deadline = DispatchTime.now() + seconds
        if terminated.wait(timeout: deadline) == .timedOut {
            if Self.endChild(process, terminated: terminated,
                             graces: EndGraces(initial: 0, term: 1, kill: 1)) {
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
    /// source arrives as a parameter, from the `.stdin` / `.timedStdin` case's payload, so
    /// there is no "delivered on stdin but no script" state to fall open on.
    ///
    /// With a `deadline`, the whole call is bounded by that many seconds of wall clock: the
    /// delivery of the script, the child's run, AND the drain of its output to EOF. On expiry
    /// the child is ended (SIGTERM, then SIGKILL) and `TimeoutError` is thrown. The one thing
    /// the bound cannot do is end a DESCENDANT that inherited the pipes — `endChild` signals
    /// the direct child only — so a descendant that outlives the deadline is reported (the
    /// drain's bounded wait expires, `TimeoutError`) but not killed, and the feeder and drain
    /// threads it keeps blocked (three workers, three descriptors) live as long as it does.
    /// Without a deadline the form is unbounded, exactly as before.
    private func launchWithScriptOnStdin(_ invocation: ScriptInvocation,
                                         _ script: String,
                                         deadline: TimeInterval?) throws -> ScriptOutcome {
        let process = Self.makeProcess(invocation)

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
        // Two semaphores with two jobs. `terminated` is the termination ladder's own signal
        // (`endChild` waits on it). `wake` fires on EVERY event this call waits for — child
        // exit and delivery finishing — so one bounded wait covers "whichever comes first".
        let terminated = DispatchSemaphore(value: 0)
        let wake = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminated.signal()
            wake.signal()
        }
        try Self.start(process)
        // Both output streams start draining BEFORE the stdin write, so a child that answers
        // early — filling either pipe while this side is still writing — cannot wedge the
        // write, and neither stream can wedge the other (see `PipeDrain`).
        let outDrain = PipeDrain(stdoutPipe.fileHandleForReading, label: "stdin-form-stdout")
        let errDrain = PipeDrain(stderrPipe.fileHandleForReading, label: "stdin-form-stderr")

        // Hand osascript the script on stdin, then close it (EOF) so compilation begins. On a
        // thread of its own (see `StdinFeeder`) so the deadline can expire even while the
        // write is blocked on a child that reads nothing.
        let feeder = StdinFeeder(stdinWriter, script: script) { wake.signal() }

        // ONE absolute expiry for the whole call: the wait below, and the drains after it,
        // are all measured against it, so nothing after the child's exit can outlive the bound.
        let bound: (seconds: TimeInterval, expiry: DispatchTime)? = deadline.map { ($0, .now() + $0) }

        // Whether the child's exit has already been observed. Recorded rather than re-derived
        // because a successful semaphore wait CONSUMES the termination signal: the teardown
        // ladder waits on the same semaphore, and handed a consumed one it would read a
        // finished child as still running and signal a pid that may since have been reused.
        var childExited = false
        var delivered = false
        while !(childExited && delivered) {
            if let bound {
                if wake.wait(timeout: bound.expiry) == .timedOut {
                    // Same escalation and the same refusal as `launchWithDeadline`: end the
                    // child, but never turn the deadline into another unbounded wait — no
                    // collect on a child that may be uninterruptible. The feeder and drain
                    // threads finish on their own once the last copies of the pipe ends
                    // close — with the child, unless a descendant inherited them, in which
                    // case they stay blocked (three workers, three fds) for as long as that
                    // descendant lives: the same only-the-direct-child-is-signalled limit the
                    // drain bound below documents, and bounded for a one-shot CLI. The ladder
                    // is skipped when the exit was already observed (the deadline can expire
                    // while only the feeder is still pending): its semaphore is consumed then,
                    // and there is no child left to signal.
                    if childExited || Self.endChild(process, terminated: terminated,
                                                    graces: EndGraces(initial: 0, term: 1, kill: 1)) {
                        process.waitUntilExit()
                    }
                    throw AppleScriptRunner.TimeoutError(seconds: bound.seconds)
                }
            } else {
                wake.wait()
            }
            // Which event(s) woke this side. Both are checked every time: they can land
            // together, and the feeder finishing is what makes a delivery failure visible
            // IMMEDIATELY rather than after a deadline that has nothing to do with it.
            if !childExited, terminated.wait(timeout: .now()) == .success {
                childExited = true
            }
            switch feeder.state {
            case .pending:
                continue
            case .delivered:
                delivered = true
            case .failed(let deliveryFailure):
                // The script never arrived, so there is nothing left to wait FOR — and waiting
                // is not safe. A child may close (or simply never read) stdin and live on
                // holding stdout and stderr open, in which case the drains would never see EOF
                // and this call would hang forever on a failure it has already diagnosed. End
                // the child instead (unless its exit was already observed), giving SIGTERM a
                // short grace so one that handles it can shut down on its own terms, then
                // escalate to SIGKILL.
                if !childExited {
                    _ = Self.endChild(process, terminated: terminated,
                                      graces: EndGraces(initial: 0.05, term: 0.5, kill: 1))
                }
                // Do NOT collect()/waitUntilExit() on this path. The captures are discarded by
                // the throw below, and `collected()` is a wait on a read-to-EOF that only
                // returns once the child's write ends close — which never happens if the child
                // was not actually reaped (uninterruptible D-state, or a grandchild that
                // inherited the pipe). Collecting here would reintroduce exactly the unbounded
                // wait this teardown exists to prevent, on a form that may carry no deadline —
                // the same wait `launchWithDeadline` refuses to convert its bound into. Fail
                // fast instead; any still-running drain thread finishes on its own once the fds
                // close.
                //
                // The script never reached the interpreter, so whatever the child did exit with
                // is not an answer to it — reported as a launch failure rather than mapped
                // through `result(of:)`, which would otherwise turn an exit 0 into a silent
                // empty success.
                throw AppleScriptRunner.RunError.launchFailed(
                    "could not deliver script on stdin: \(String(describing: deliveryFailure))")
            }
        }
        // The child is gone and the script arrived whole. The drains are the last thing the
        // bound has to cover: exit does not imply EOF (see `PipeDrain.collected(by:)`), and a
        // descendant holding the pipe past the expiry is reported as a timeout rather than
        // waited on. There is no child left to end on that path — `endChild` signals the direct
        // child only, and it has already exited.
        let outData: Data
        let errData: Data
        if let bound {
            guard let out = try outDrain.collected(by: bound.expiry),
                  let err = try errDrain.collected(by: bound.expiry) else {
                process.waitUntilExit()
                throw AppleScriptRunner.TimeoutError(seconds: bound.seconds)
            }
            (outData, errData) = (out, err)
        } else {
            outData = try outDrain.collected()
            errData = try errDrain.collected()
        }
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
        try AppleScriptRunner.validateTimeout(seconds)
        let invocation = ScriptInvocation(
            arguments: AppleScriptRunner.dashEArguments(script: script, arguments: arguments),
            delivery: .timed(seconds: seconds))
        return try AppleScriptRunner.result(of: try launcher.launch(invocation))
    }

    /// The one deadline rule every timed form applies before it launches anything: finite,
    /// positive, and at most `maximumTimeoutSeconds`.
    static func validateTimeout(_ seconds: TimeInterval) throws {
        guard seconds.isFinite, seconds > 0,
              seconds <= AppleScriptRunner.maximumTimeoutSeconds else {
            throw InvalidTimeoutError(seconds: seconds)
        }
    }

    /// Execute an AppleScript passed via STDIN (`osascript -`) instead of `-e`. Required
    /// ONLY for scripts with a top-level `use framework` (AppleScriptObjC) header, which the
    /// `-e` form does not reliably compile. `arguments` are still opaque argv (`on run argv`)
    /// — the safe path for user data. Empirically (macOS `osascript`), the `-` file operand
    /// ends option parsing, so every trailing arg is delivered as argv even if it begins with
    /// `-` (no `--` terminator needed, and `--` would itself become argv item 1). Prefer
    /// `run(_:arguments:)`; reach for this only for the rare AppleScriptObjC case.
    ///
    /// Intentionally UNBOUNDED: this overload carries no wall-clock deadline, so a child that
    /// reads the script and then never exits or closes stdout blocks the caller indefinitely. It
    /// is also the most deadlock-exposed shape (two live pipes plus a parent-side stdin write),
    /// so a caller on a hang-prone path should use `runViaStdin(_:arguments:timeout:)` instead.
    /// Concurrent stdout/stderr drains keep the two streams from wedging each other and the
    /// write (see `launchWithScriptOnStdin`).
    public func runViaStdin(_ script: String, arguments: [String] = []) throws -> String {
        let invocation = ScriptInvocation(arguments: ["-"] + arguments,
                                          delivery: .stdin(script: script))
        return try AppleScriptRunner.result(of: try launcher.launch(invocation))
    }

    /// `runViaStdin(_:arguments:)` with a host-side wall-clock deadline — the stdin counterpart
    /// of `run(_:arguments:timeout:)`, for the AppleScriptObjC scripts that drive an Apple app's
    /// GUI and can stall on a dialog or a lost window indefinitely. The bound covers the whole
    /// call — delivery of the script, the interpreter's run, and the drain of its output; on
    /// expiry the child is ended (SIGTERM, then SIGKILL) and `TimeoutError` is thrown. A
    /// descendant the script spawned that outlives the deadline holding the output pipes is
    /// reported the same way but not ended (only the direct child is signalled). A timed-out
    /// run is NOT known to have done nothing: the interpreter may have completed the action
    /// before the deadline landed, so a caller must report the outcome as unconfirmed rather
    /// than as not-done.
    ///
    /// The deadline is validated BEFORE anything is launched, exactly as for the `-e` form.
    public func runViaStdin(_ script: String, arguments: [String] = [],
                            timeout seconds: TimeInterval) throws -> String {
        try AppleScriptRunner.validateTimeout(seconds)
        let invocation = ScriptInvocation(arguments: ["-"] + arguments,
                                          delivery: .timedStdin(script: script, seconds: seconds))
        return try AppleScriptRunner.result(of: try launcher.launch(invocation))
    }

    /// Escape a string literal for the RARE case a value must be embedded directly in
    /// script source. Prefer `run(_:arguments:)` over this.
    public static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
