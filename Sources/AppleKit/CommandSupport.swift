import Foundation
import ArgumentParser

/// Single source of truth for the binary version. Keep in lockstep with CHANGELOG +
/// the git tag at release time (docs/versioning-policy.md drift gate).
public enum AppleVersion {
    public static let current = "0.0.0" // pre-1.0: cuts 1.0.0 at full six-domain parity
    public static var schema: Int { Output.schemaVersion }
}

/// Cross-cutting flags every domain command mixes in via `@OptionGroup`, so the global
/// surface (`--json`/`--text`, `--dry-run`/`--execute`, `--test-mode`) is IDENTICAL
/// across all six domains instead of six divergent reinventions.
public struct GlobalOptions: ParsableArguments {
    public init() {}

    @Flag(name: .long, help: "Emit human-readable text instead of the default JSON output.")
    public var text = false

    @Flag(name: .long, help: "Preview a write/destructive operation without performing it.")
    public var dryRun = false

    @Flag(name: .long, help: "Actually perform a write/destructive operation (overrides the dry-run default).")
    public var execute = false

    @Flag(name: .long, help: "Operate only on labeled test data (required for live writes); see TEST-CLEANUP.md.")
    public var testMode = false

    /// Output is JSON by DEFAULT (stdout = machine JSON); `--text` opts into a human rendering.
    public var json: Bool { !text }

    /// Destructive verbs default to dry-run; a real mutation requires an explicit `--execute`.
    public var willExecute: Bool { execute && !dryRun }
}

/// Run a command body so ANY thrown error becomes a JSON envelope on stdout + the bound
/// contractual exit code. Guarantees the stdout-JSON + exit-code contract on every path,
/// including errors that would otherwise escape to ArgumentParser (non-JSON stderr, exit 1).
///
///     public func run() throws {
///         try runGuarded(tool: "messages") { /* ... may throw AppleError ... */ }
///     }
public func runGuarded(tool: String, _ body: () throws -> Void) throws {
    do {
        try body()
    } catch let error as AppleError {
        Output.emitError(tool: tool, type: error.type, message: error.message)
        throw ExitCode(error.exitCode)
    } catch let code as ExitCode {
        throw code // an already-intended exit (e.g. success)
    } catch {
        Output.emitError(tool: tool, type: AppleErrorType.unknown, message: String(describing: error))
        throw ExitCode(AppleExit.unknown)
    }
}
