import Foundation
import Darwin

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
    let maximumOutputBytes: Int?

    init(executablePath: String = AppleScriptRunner.osascriptPath,
         arguments: [String],
         delivery: ScriptDelivery = .inline,
         maximumOutputBytes: Int? = nil) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.delivery = delivery
        self.maximumOutputBytes = maximumOutputBytes
    }
}

/// What a finished invocation yielded: exit status plus both streams, undecoded. Decoding and
/// the non-zero-status mapping belong to `AppleScriptRunner`, so every form shares one.
struct ScriptOutcome: Equatable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
}

struct ScriptOutputLimitExceeded: Error {
    let maximumOutputBytes: Int

    init(maximumOutputBytes: Int) {
        precondition(maximumOutputBytes > 0)
        self.maximumOutputBytes = maximumOutputBytes
    }
}

/// Starts a `ScriptInvocation` and reports its outcome. Production binds `OsascriptLauncher`.
protocol ScriptLaunching: Sendable {
    func launch(_ invocation: ScriptInvocation) throws -> ScriptOutcome
}

/// The production launcher owns an isolated process group and all of its I/O descriptors.
struct OsascriptLauncher: ScriptLaunching {
    let captureDirectory: URL
    let dependencies: ScriptProcessDependencies

    init(captureDirectory: URL = FileManager.default.temporaryDirectory,
         dependencies: ScriptProcessDependencies = ScriptProcessDependencies()) {
        self.captureDirectory = captureDirectory
        self.dependencies = dependencies
    }

    func launch(_ invocation: ScriptInvocation) throws -> ScriptOutcome {
        try OwnedScriptProcess(dependencies: dependencies).launch(invocation, captureDirectory: captureDirectory)
    }

    static func outputReadFailure(_ stream: String, _ error: any Error) -> AppleScriptRunner.RunError {
        .launchFailed("could not read osascript \(stream): \(String(describing: error))")
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
    /// Recognizes only errors marked by the shared runner's output-limit policy.
    /// Ordinary errors with identical public fields remain unrelated failures.
    public static func isOutputLimitError(_ error: any Error) -> Bool {
        (error as? AppleError)?.outputLimitOrigin != nil
    }

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
    private let maximumOutputBytes: Int?
    private let environmentValue: () -> String?

    /// Opt-in combined raw stdout/stderr allowance. Nil consults
    /// APPLE_SCRIPT_MAX_OUTPUT_BYTES on each invocation; absence means unlimited.
    public init(maximumOutputBytes: Int? = nil) {
        self.init(launcher: OsascriptLauncher(), maximumOutputBytes: maximumOutputBytes,
                  environmentValue: { ProcessInfo.processInfo.environment["APPLE_SCRIPT_MAX_OUTPUT_BYTES"] })
    }

    /// Module-internal seam. Recording tests default to an absent environment value.
    init(launcher: any ScriptLaunching, maximumOutputBytes: Int? = nil,
         environmentValue: @escaping () -> String? = { nil }) {
        self.launcher = launcher
        self.maximumOutputBytes = maximumOutputBytes
        self.environmentValue = environmentValue
    }

    static func resolveMaximumOutputBytes(explicit: Int?, environment: String?) throws -> Int? {
        if let explicit {
            guard explicit > 0 else { throw AppleError.outputLimitExplicitInvalid() }
            return explicit
        }
        guard let environment else { return nil }
        guard !environment.isEmpty,
              environment.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(environment), value > 0 else {
            throw AppleError.outputLimitEnvironmentInvalid()
        }
        return value
    }

    private func resolvedMaximumOutputBytes() throws -> Int? {
        // Do not even inspect the environment when an explicit API value was supplied.
        try Self.resolveMaximumOutputBytes(explicit: maximumOutputBytes,
                                          environment: maximumOutputBytes == nil ? environmentValue() : nil)
    }

    private func launch(_ invocation: ScriptInvocation) throws -> String {
        do { return try Self.result(of: launcher.launch(invocation)) }
        catch let error as ScriptOutputLimitExceeded {
            throw AppleError.outputLimitExceeded(maximumOutputBytes: error.maximumOutputBytes)
        }
    }

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
        // Signal outcomes retain the signal number (SIGKILL is 9), matching the established
        // rendering "osascript exited 9". ProcessResourceTests.signalOutcome pins the launcher
        // representation; changing it to 128 + signal would change the caller-visible contract.
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
            arguments: AppleScriptRunner.dashEArguments(script: script, arguments: arguments),
            maximumOutputBytes: try resolvedMaximumOutputBytes())
        return try launch(invocation)
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
            delivery: .timed(seconds: seconds),
            maximumOutputBytes: try resolvedMaximumOutputBytes())
        return try launch(invocation)
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
    /// A synchronous nonblocking I/O loop interleaves both output streams and stdin delivery.
    public func runViaStdin(_ script: String, arguments: [String] = []) throws -> String {
        let invocation = ScriptInvocation(arguments: ["-"] + arguments,
                                          delivery: .stdin(script: script),
                                          maximumOutputBytes: try resolvedMaximumOutputBytes())
        return try launch(invocation)
    }

    /// `runViaStdin(_:arguments:)` with a host-side wall-clock deadline — the stdin counterpart
    /// of `run(_:arguments:timeout:)`, for the AppleScriptObjC scripts that drive an Apple app's
    /// GUI and can stall on a dialog or a lost window indefinitely. The bound covers the whole
    /// call — delivery of the script, the interpreter's run, and the drain of its output; on
    /// expiry the child is ended (SIGTERM, then SIGKILL) and `TimeoutError` is thrown. A
    /// descendant retaining the invocation’s process group is included in that cleanup, even
    /// when the root exited before the output pipes reached EOF. A timed-out
    /// run is NOT known to have done nothing: the interpreter may have completed the action
    /// before the deadline landed, so a caller must report the outcome as unconfirmed rather
    /// than as not-done.
    ///
    /// The deadline is validated BEFORE anything is launched, exactly as for the `-e` form.
    public func runViaStdin(_ script: String, arguments: [String] = [],
                            timeout seconds: TimeInterval) throws -> String {
        try AppleScriptRunner.validateTimeout(seconds)
        let invocation = ScriptInvocation(arguments: ["-"] + arguments,
                                          delivery: .timedStdin(script: script, seconds: seconds),
                                          maximumOutputBytes: try resolvedMaximumOutputBytes())
        return try launch(invocation)
    }

    /// Escape a string literal for the RARE case a value must be embedded directly in
    /// script source. Prefer `run(_:arguments:)` over this.
    public static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
