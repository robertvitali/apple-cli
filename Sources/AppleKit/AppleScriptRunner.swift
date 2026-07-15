import Foundation

/// Runs AppleScript via `/usr/bin/osascript` with stdin CLOSED (never blocks on input).
///
/// SECURITY — the load-bearing rule for all six domains: user/data-derived text
/// (recipients, bodies, search terms, note/contact content) MUST be passed as
/// `arguments:` (osascript argv → the script's `on run argv` handler), NEVER
/// string-interpolated into the script source. AppleScript injection here is RCE-class
/// (`do shell script`, cross-recipient send, data exfil). Where a value genuinely must
/// be embedded (rare), route it through `quote(_:)` — never ad-hoc per domain.
public struct AppleScriptRunner {
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

    public init() {}

    /// Execute an AppleScript. `arguments` are passed as opaque `osascript` argv (available
    /// to the script as `on run argv`) — this is the safe path for all user data. Returns
    /// trimmed stdout.
    public func run(_ script: String, arguments: [String] = []) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // Array args → no shell, no re-splitting; user data never re-enters script source.
        process.arguments = ["-e", script] + arguments

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

    /// Escape a string literal for the RARE case a value must be embedded directly in
    /// script source. Prefer `run(_:arguments:)` over this.
    public static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
