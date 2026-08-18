import Foundation

/// Live tests + MCP-parity comparisons write to the REAL Apple stores (there is no
/// separate sandbox), under a track-and-cleanup discipline: create only clearly-labeled
/// test items (name-prefixed `sandboxPrefix`), log each to TEST-CLEANUP.md, and delete
/// only those tracked items via the MCP afterward. This type provides the FAIL-CLOSED
/// guard that turns that discipline into enforcement — call it before any live write.
public enum TestMode {
    /// The two write-model v2 environment variables, named ONCE so the preamble
    /// (`validateWriteEnvironment`) and every reader are provably paired on the same keys.
    public static let testModeVar = "APPLE_TEST_MODE"
    public static let dryRunVar = "APPLE_DRY_RUN"

    /// Prefix every test item's name carries so it's recognizable + cleanable.
    public static var sandboxPrefix: String {
        normalizedPrefix(from: ProcessInfo.processInfo.environment["APPLE_TEST_SANDBOX"])
    }

    /// The built-in prefix, IGNORING `APPLE_TEST_SANDBOX`. `sandboxPrefix` is caller-redefinable
    /// (a convenience for reversible test ops), which means a caller could point it at a prefix
    /// real mail already carries — harmless when the op is reversible, unacceptable when it is not.
    /// IRREVERSIBLE operations therefore label-check against THIS constant, so widening the
    /// override cannot widen what an erase is allowed to touch.
    public static let canonicalSandboxPrefix = "apple-cli-test"

    /// Pure normalization (unit-testable without mutating process env): an empty or
    /// whitespace-only `APPLE_TEST_SANDBOX` is treated as ABSENT and falls back to the
    /// default prefix — otherwise the override would vacate the label gate
    /// (`name.hasPrefix("")` is always true), letting ANY name pass a sandbox label check.
    static func normalizedPrefix(from raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "apple-cli-test" : trimmed
    }

    /// Allowlisted recipients for Messages/Mail test SENDS (operator self only). Comma-sep
    /// in `APPLE_TEST_RECIPIENTS`. A send to anything not on this list is a dangerous action.
    public static var allowedRecipients: [String] {
        (ProcessInfo.processInfo.environment["APPLE_TEST_RECIPIENTS"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - Write-model v2 (docs/write-model-v2.md)

    /// The values a v2 boolean environment variable accepts as TRUE, case-insensitively.
    /// There are deliberately NO falsy spellings: you disable by UNSETTING the variable.
    static let truthyValues: Set<String> = ["1", "true", "yes"]

    /// FAIL-LOUD boolean env parsing (write-model v2): unset/empty → false; a truthy
    /// spelling → true; ANY other non-empty value → `validation_error` (exit 64). A typo'd
    /// `APPLE_TEST_MODE=ture` must refuse the write, not silently run it live — and
    /// `APPLE_DRY_RUN=off` must not silently mean "not dry-run". Both variables parse
    /// through THIS one helper so their contracts cannot drift.
    public static func truthyEnv(_ name: String) throws -> Bool {
        try parseTruthy(name: name, raw: ProcessInfo.processInfo.environment[name])
    }

    /// Pure core of `truthyEnv` (unit-testable without mutating process env). Deliberately
    /// STRICT about whitespace ("1 " is an error): a shell-quoting artifact should be
    /// surfaced, not guessed around — the same fail-loud rationale as unknown spellings.
    static func parseTruthy(name: String, raw: String?) throws -> Bool {
        guard let raw, !raw.isEmpty else { return false }
        if truthyValues.contains(raw.lowercased()) { return true }
        // Echo at most a snippet of the value: the two v2 variables are never secrets, but
        // this API is generic over the name — don't turn a misuse into a full disclosure.
        let shown = raw.count > 32 ? raw.prefix(32) + "…" : Substring(raw)
        throw AppleError.validation(
            "\(name)=\(shown) is not a recognized value (use 1, true, or yes — or unset it). "
            + "Refusing to guess whether you meant on or off.")
    }

    /// Non-throwing accessor over `truthyEnv`, for the few Bool-property contexts that cannot
    /// throw (e.g. the Contacts env-gate reader). Gate logic on the v2 write path must use the THROWING readers
    /// (`truthyEnv`, `sandboxActive(flag:)`, `GlobalOptions.willExecute(defaultDryRun:)`) —
    /// the fail-loud contract is carried by the type system there, not by call-order
    /// discipline.
    public static func isTruthyEnv(_ name: String) -> Bool {
        (try? truthyEnv(name)) ?? false
    }

    /// v2 sandbox activation: `APPLE_TEST_MODE` truthy OR the `--test-mode` flag — EITHER
    /// signal alone engages it. In v2 the sandbox is a RESTRICTION (label-gated targets,
    /// self-only sends), and a restriction should be the easy thing to turn on; v1's
    /// two-factor gate guarded against accidental WRITES, v2's single signal guards
    /// against accidental UNSANDBOXED writes — each fails safe for its own model.
    /// THROWING, and the env is validated EAGERLY (no `||` short-circuit): an unparseable
    /// APPLE_TEST_MODE refuses the command (validation_error, 64) even when `--test-mode`
    /// was passed — the fail-loud contract holds on every path, enforced by the signature.
    /// `envVar` is a seam for the logic tier (tests validate the throwing composition with
    /// a test-owned variable name instead of mutating APPLE_TEST_MODE, which 15 v1 gate
    /// sites read concurrently); production callers never pass it.
    public static func sandboxActive(flag: Bool, envVar: String = testModeVar) throws -> Bool {
        let env = try truthyEnv(envVar)
        return flag || env
    }

    /// Belt-and-braces write-command preamble (v2): validate BOTH v2 env variables
    /// fail-loud before any work. The throwing readers above make this NON-load-bearing
    /// (a skipped preamble cannot fail open — the readers themselves throw); its value is
    /// failing BEFORE partial work, and validating APPLE_TEST_MODE even on commands that
    /// never consult the sandbox. Call INSIDE `runGuarded` (top of the guarded body) so
    /// the thrown AppleError becomes the domain's validation_error envelope + exit 64 —
    /// outside runGuarded it would escape to ArgumentParser as a malformed unknown/70.
    public static func validateWriteEnvironment() throws {
        _ = try truthyEnv(testModeVar)
        _ = try truthyEnv(dryRunVar)
    }
}
