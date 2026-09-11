import Foundation

/// The unified error type. Throwing an `AppleError` from a guarded command body (see
/// `runGuarded` in CommandSupport.swift) emits the JSON error envelope on stdout AND
/// exits with the bound contractual exit code — atomically, so `error.type` and the
/// exit code can never drift. Domains throw these; they do not hand-pair emit + exit.
public struct AppleError: Error, CustomReflectable {
    enum OutputLimitOrigin {
        case configuration
        case overflow
    }

    // Non-wire provenance. Public constructors cannot manufacture it, and only this
    // type's dedicated factories and bulk copy may set it.
    private(set) var outputLimitOrigin: OutputLimitOrigin?

    /// Preserve the pre-provenance public-field description used by legacy diagnostics.
    /// Reflection must not turn a private classifier into stdout/stderr message content.
    public var customMirror: Mirror {
        let fields: [(label: String?, value: Any)] = [
            (label: "type", value: type as Any),
            (label: "message", value: message as Any),
            (label: "exitCode", value: exitCode as Any),
            (label: "status", value: status as Any),
            (label: "remediation", value: remediation as Any),
            (label: "applied", value: applied as Any),
            (label: "sandbox", value: sandbox as Any),
        ]
        return Mirror(self, children: fields, displayStyle: .struct)
    }

    public let type: String        // becomes error.type in the JSON envelope
    public let message: String
    public let exitCode: Int32

    /// TCC authorization status (`denied` / `restricted` / `notDetermined`), surfaced as
    /// `error.status`. The oracles return this ALONGSIDE the message on an authorization failure,
    /// and an agent is expected to branch on it — retry after prompting vs. send the user to
    /// System Settings vs. give up because MDM forbids it. We previously folded it into the prose
    /// of `error.message`, which is not machine-readable, so that branch was unavailable.
    public let status: String?

    /// Human-facing copy telling the user how to grant access, surfaced as `error.remediation`.
    /// Same rationale: the oracle returns it as its own key so a client can display it verbatim.
    public let remediation: String?

    /// Ids a bulk mutation ALREADY applied before it failed mid-loop, surfaced as `error.applied`
    /// (extra33 / SEC-M2). A bulk op (`mail move`/`mark`/`flag`/`delete`) mutates per id; if one id
    /// hard-fails, the earlier ones are already changed. Reporting them lets a retry EXCLUDE them —
    /// move/delete are not idempotent, so re-targeting an already-moved id is a real hazard. nil on
    /// every non-bulk error (encodeIfPresent omits the key), so no other envelope changes shape.
    public let applied: [String]?

    /// `true` when the opt-in sandbox (write-model v2) REFUSED this operation — an unlabeled
    /// target, a non-self recipient, a sandbox-incompatible rule shape. Surfaced as
    /// `error.sandbox`, the error-envelope counterpart of the SUCCESS envelope's `sandbox: true`:
    /// on success it means "this write executed under the sandbox", on a refusal it means "the
    /// sandbox is why this write did NOT execute". nil (key omitted) on every error the sandbox
    /// did not cause — including the path-confinement `safety_violation`, which fires regardless of
    /// sandbox state — so a consumer can distinguish a sandbox refusal from any other failure.
    public let sandbox: Bool?

    public init(type: String, message: String, exitCode: Int32,
                status: String? = nil, remediation: String? = nil,
                applied: [String]? = nil, sandbox: Bool? = nil) {
        self.type = type
        self.message = message
        self.exitCode = exitCode
        self.status = status
        self.remediation = remediation
        self.applied = applied
        self.sandbox = sandbox
        self.outputLimitOrigin = nil
    }

    /// Re-wrap this error with the bulk partial-mutation context: earlier confirmed ids plus a
    /// message naming the failing id. Preserves `type` / `exitCode` / `status` / `remediation` so
    /// the underlying failure's classification and exit code are unchanged — this only ADDS the
    /// applied list and prepends an explanatory sentence. `applied` stays nil when empty (the
    /// first id failed, so no earlier changes were confirmed). The failed operation may have
    /// changed its item before throwing; callers must verify that item before retrying it.
    public func addingBulkContext(applied: [String], failedID: String) -> AppleError {
        let note = applied.isEmpty
            ? "bulk mutation failed at '\(failedID)'; no earlier changes were confirmed. "
            : "bulk mutation failed at '\(failedID)' after \(applied.count) earlier message(s) were confirmed changed; "
              + "EXCLUDE the ids in `applied` from a retry. "
        let uncertainty = "The failed item may have changed; verify its state before retrying — "
        var result = AppleError(type: type, message: note + uncertainty + message, exitCode: exitCode,
                          status: status, remediation: remediation,
                          applied: applied.isEmpty ? nil : applied, sandbox: sandbox)
        result.outputLimitOrigin = outputLimitOrigin
        return result
    }

    static func outputLimitEnvironmentInvalid() -> AppleError {
        var error = validation("APPLE_SCRIPT_MAX_OUTPUT_BYTES must be a positive decimal byte count")
        error.outputLimitOrigin = .configuration
        return error
    }

    static func outputLimitExplicitInvalid() -> AppleError {
        var error = validation("maximumOutputBytes must be a positive byte count")
        error.outputLimitOrigin = .configuration
        return error
    }

    static func outputLimitExceeded(maximumOutputBytes: Int) -> AppleError {
        precondition(maximumOutputBytes > 0)
        var error = upstream("osascript output exceeded the configured limit of \(maximumOutputBytes) bytes; no partial result returned. The operation may have completed; verify its state before retrying.")
        error.outputLimitOrigin = .overflow
        return error
    }

    public static func validation(_ m: String) -> AppleError {
        .init(type: AppleErrorType.validation, message: m, exitCode: AppleExit.usage)
    }
    public static func notFound(_ m: String) -> AppleError {
        .init(type: AppleErrorType.notFound, message: m, exitCode: AppleExit.notFound)
    }
    public static func upstream(_ m: String) -> AppleError {
        .init(type: AppleErrorType.upstream, message: m, exitCode: AppleExit.upstream)
    }
    /// `status` and `remediation` are optional so the ~30 existing call sites keep compiling, but
    /// a TCC-denial site SHOULD pass them — that is the whole point of the fields. A denial raised
    /// without a status is indistinguishable, to a machine consumer, from the old behaviour.
    public static func permissionDenied(_ m: String,
                                        status: String? = nil,
                                        remediation: String? = nil) -> AppleError {
        .init(type: AppleErrorType.permissionDenied, message: m,
              exitCode: AppleExit.permissionDenied, status: status, remediation: remediation)
    }
    public static func notImplemented(_ m: String) -> AppleError {
        .init(type: AppleErrorType.notImplemented, message: m, exitCode: AppleExit.unknown)
    }
    public static func unknown(_ m: String) -> AppleError {
        .init(type: AppleErrorType.unknown, message: m, exitCode: AppleExit.unknown)
    }
    /// A policy-based safety refusal — a write the guard deliberately declines (a sandbox /
    /// label / recipient gate, or a write-destination confinement). Emits `error.type =
    /// "safety_violation"` (the string the Contacts MCP uses) at exit 77 (EX_NOPERM), so a client
    /// can tell a deliberate refusal from a real failure. Canonical home for what MailKit's
    /// `mailSafety` and the former ContactsKit `safetyViolation` each spelled separately.
    ///
    /// Pass `sandbox: true` ONLY at the sandbox-policy gates (unlabeled target / non-self recipient
    /// / sandbox-incompatible rule) — it sets `error.sandbox` so a consumer sees the sandbox is why
    /// the write was refused. Leave it false for confinement/other refusals that fire regardless of
    /// sandbox state.
    public static func safetyViolation(_ m: String, sandbox: Bool = false) -> AppleError {
        .init(type: AppleErrorType.safetyViolation, message: m,
              exitCode: AppleExit.permissionDenied, sandbox: sandbox ? true : nil)
    }
}

/// Contractual exit codes (documented in README + docs/DESIGN.md). Repurposing a code
/// is a MAJOR change; adding a new code for a previously-generic failure is MINOR.
public enum AppleExit {
    public static let success: Int32 = 0
    public static let usage: Int32 = 64            // EX_USAGE — bad flags / args
    public static let notFound: Int32 = 65          // requested entity does not exist
    public static let upstream: Int32 = 69          // EX_UNAVAILABLE — Apple app / DB unavailable
    public static let unknown: Int32 = 70           // EX_SOFTWARE — unexpected internal error
    public static let permissionDenied: Int32 = 77  // EX_NOPERM — TCC not granted
}

/// Canonical `error.type` strings for the JSON envelope.
public enum AppleErrorType {
    public static let validation = "validation_error"
    public static let notFound = "not_found"
    public static let permissionDenied = "authorization_denied"
    public static let upstream = "upstream_error"
    public static let notImplemented = "not_implemented"
    public static let unknown = "unknown"
    public static let safetyViolation = "safety_violation"
}
