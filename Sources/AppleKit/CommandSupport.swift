import Foundation
import ArgumentParser

/// Single source of truth for the binary version. Keep in lockstep with CHANGELOG +
/// the git tag at release time (docs/versioning-policy.md drift gate).
public enum AppleVersion {
    public static let current = "26.0.0" // release.yml-managed; first tag is v26.0.0 at D2 (platform-keyed — see AGENTS.md "Versioning + releases")
    public static var schema: Int { Output.schemaVersion }
}

/// Cross-cutting flags every domain command mixes in via `@OptionGroup`, so the global
/// surface (`--json`/`--text`, `--dry-run`/`--execute`, `--test-mode`) is IDENTICAL
/// across all six domains instead of six divergent reinventions.
public struct GlobalOptions: ParsableArguments {
    public init() {}

    @Flag(name: .long, help: "Emit human-readable text instead of the default JSON output.")
    public var text = false

    @Flag(name: .long, help: "Preview a write/destructive operation without performing it (always wins — over --execute, APPLE_DRY_RUN, and any surface default).")
    public var dryRun = false

    @Flag(name: .long, help: "Explicitly perform the write (write-model-v2 domains execute by default; this also overrides APPLE_DRY_RUN and any remaining dry-run defaults).")
    public var execute = false

    @Flag(name: .long, help: "Engage the opt-in SANDBOX: writes restricted to apple-cli-test-labeled items and self-only allowlisted recipients (APPLE_TEST_RECIPIENTS). Domains not yet on write-model v2 additionally require it (with APPLE_TEST_MODE=1) for live writes.")
    public var testMode = false

    /// Output is JSON by DEFAULT (stdout = machine JSON); `--text` opts into a human rendering.
    public var json: Bool { !text }

    /// Write-model v2 (docs/write-model-v2.md): whether this invocation EXECUTES, resolved
    /// once from flag + env precedence. Call it ONCE at the top of `run()` and thread the
    /// result — the spec's bind-once discipline exists because guards, previews, and the
    /// envelope's `dry_run` key must all agree on a single answer per invocation.
    ///
    /// Precedence: `--dry-run` > `--execute` > `APPLE_DRY_RUN` (operator-level persistent
    /// preview default; `--execute` beats it deliberately — explicit invocation-level
    /// intent wins over an ambient default, and the agent-proof layer is the sandbox plus
    /// the APPLE_ALLOW_* gates, not this variable) > the surface's own default. General
    /// writes execute by default (`defaultDryRun: false` — the oracle executes on call);
    /// the trash surface passes `defaultDryRun: true` (oracle B's `manage_trash` defaults
    /// `dry_run=True`, and keeping that IS parity). `defaultDryRun` has NO default value
    /// on purpose: every surface states its own.
    /// THROWING: an unparseable APPLE_DRY_RUN refuses the command (validation_error, 64)
    /// instead of silently resolving to execute — carried by the signature, not by a
    /// promise that a preamble ran first.
    ///
    /// `envVar` is a seam for the logic tier, matching the one `TestMode.sandboxActive(flag:
    /// envVar:)` already carries, and it exists for the same reason: a test that needs the
    /// env-SET branch must own a UNIQUE variable rather than `setenv`-ing the real
    /// `APPLE_DRY_RUN`, because swift-testing runs suites in PARALLEL and the process
    /// environment is global. Once a domain flips to write-model v2 its own tests call this
    /// method, so a test that mutates the real variable races them — observed at a 6-in-12
    /// failure rate when the Contacts flip made `resolveWrite` the first domain reader of
    /// `APPLE_DRY_RUN` while `WriteModelV2CoreTests` still owned it globally. Production
    /// callers never pass this.
    public func willExecute(defaultDryRun: Bool, envVar: String = TestMode.dryRunVar) throws -> Bool {
        Self.resolveExecute(dryRunFlag: dryRun, executeFlag: execute,
                            envDryRun: try TestMode.truthyEnv(envVar),
                            defaultDryRun: defaultDryRun)
    }

    /// Pure precedence core (unit-testable without env mutation).
    static func resolveExecute(dryRunFlag: Bool, executeFlag: Bool,
                               envDryRun: Bool, defaultDryRun: Bool) -> Bool {
        if dryRunFlag { return false }
        if executeFlag { return true }
        if envDryRun { return false }
        return !defaultDryRun
    }
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
        Output.emitError(tool: tool, from: error)
        throw ExitCode(error.exitCode)
    } catch let code as ExitCode {
        throw code // an already-intended exit (e.g. success)
    } catch {
        Output.emitError(tool: tool, type: AppleErrorType.unknown, message: String(describing: error))
        throw ExitCode(AppleExit.unknown)
    }
}
