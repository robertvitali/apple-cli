import Foundation
import Darwin

private final class UnlinkedCaptureFile {
    let handle: FileHandle

    init() throws {
        let captureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-cli-osascript.XXXXXX")
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

/// Runs AppleScript via `/usr/bin/osascript` with stdin CLOSED (never blocks on input).
///
/// SECURITY — the load-bearing rule for all six domains: user/data-derived text
/// (recipients, bodies, search terms, note/contact content) MUST be passed as
/// `arguments:` (osascript argv → the script's `on run argv` handler), NEVER
/// string-interpolated into the script source. AppleScript injection here is RCE-class
/// (`do shell script`, cross-recipient send, data exfil). Where a value genuinely must
/// be embedded (rare), route it through `quote(_:)` — never ad-hoc per domain.
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

    public init() {}

    /// Execute an AppleScript. `arguments` are passed as opaque `osascript` argv (available
    /// to the script as `on run argv`) — this is the safe path for all user data. Returns
    /// trimmed stdout.
    public func run(_ script: String, arguments: [String] = []) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // Array args → no shell, no re-splitting; user data never re-enters script source.
        // `--` ends osascript's OPTION parsing, so a value that happens to start with `-`
        // (e.g. `-l`, `-e`, `-s`) is passed as positional argv (`on run argv`), never an
        // osascript option — closing an argument-injection gap (CWE-88) in this shared sink.
        process.arguments = ["-e", script, "--"] + arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice // stdin closed — never hang

        do {
            try process.run()
        } catch {
            throw RunError.launchFailed(String(describing: error))
        }
        // Read stdout to EOF BEFORE waiting, so a large result can't fill the pipe buffer
        // and deadlock the child. (osascript stderr is small — error text — so reading it
        // after wait is safe.)
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            throw RunError.scriptFailed(status: process.terminationStatus,
                                        stderr: String(decoding: errData, as: UTF8.self))
        }
        return String(decoding: outData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Execute an AppleScript with a host-side wall-clock deadline. This overload is opt-in:
    /// existing callers retain their current behavior, while operations whose Apple-event
    /// handlers can swallow a per-event timeout can still impose an overall process bound.
    ///
    /// Regular files are used for output instead of pipes so a large result cannot fill a pipe
    /// while this thread waits for termination. Each mode-0600 file is created in the process's
    /// temporary directory (`TMPDIR`, normally macOS's per-user Darwin temp directory) and
    /// unlinked before osascript starts. It has a pathname only for the short
    /// `mkstemp`→`unlink` window, before live Apple data can be written, and is reclaimed by the
    /// kernel when the handles close.
    public func run(_ script: String, arguments: [String] = [],
                    timeout seconds: TimeInterval) throws -> String {
        guard seconds.isFinite, seconds > 0,
              seconds <= AppleScriptRunner.maximumTimeoutSeconds else {
            throw InvalidTimeoutError(seconds: seconds)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, "--"] + arguments

        let outFile = try UnlinkedCaptureFile()
        let errFile = try UnlinkedCaptureFile()
        process.standardOutput = outFile.handle
        process.standardError = errFile.handle
        process.standardInput = FileHandle.nullDevice

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        do {
            try process.run()
        } catch {
            throw RunError.launchFailed(String(describing: error))
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
            throw TimeoutError(seconds: seconds)
        }

        process.waitUntilExit()
        let outData = try outFile.read()
        let errData = try errFile.read()
        if process.terminationStatus != 0 {
            throw RunError.scriptFailed(status: process.terminationStatus,
                                        stderr: String(decoding: errData, as: UTF8.self))
        }
        return String(decoding: outData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Execute an AppleScript passed via STDIN (`osascript -`) instead of `-e`. Required
    /// ONLY for scripts with a top-level `use framework` (AppleScriptObjC) header, which the
    /// `-e` form does not reliably compile. `arguments` are still opaque argv (`on run argv`)
    /// — the safe path for user data. Empirically (macOS `osascript`), the `-` file operand
    /// ends option parsing, so every trailing arg is delivered as argv even if it begins with
    /// `-` (no `--` terminator needed, and `--` would itself become argv item 1). Prefer
    /// `run(_:arguments:)`; reach for this only for the rare AppleScriptObjC case.
    public func runViaStdin(_ script: String, arguments: [String] = []) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"] + arguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw RunError.launchFailed(String(describing: error))
        }
        // Hand osascript the script on stdin, then close it (EOF) so compilation begins.
        stdinPipe.fileHandleForWriting.write(Data(script.utf8))
        stdinPipe.fileHandleForWriting.closeFile()
        // Read stdout to EOF before waiting so a large result can't deadlock the child.
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            throw RunError.scriptFailed(status: process.terminationStatus,
                                        stderr: String(decoding: errData, as: UTF8.self))
        }
        return String(decoding: outData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Escape a string literal for the RARE case a value must be embedded directly in
    /// script source. Prefer `run(_:arguments:)` over this.
    public static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
