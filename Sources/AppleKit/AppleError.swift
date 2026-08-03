import Foundation

/// The unified error type. Throwing an `AppleError` from a guarded command body (see
/// `runGuarded` in CommandSupport.swift) emits the JSON error envelope on stdout AND
/// exits with the bound contractual exit code — atomically, so `error.type` and the
/// exit code can never drift. Domains throw these; they do not hand-pair emit + exit.
public struct AppleError: Error {
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

    public init(type: String, message: String, exitCode: Int32,
                status: String? = nil, remediation: String? = nil) {
        self.type = type
        self.message = message
        self.exitCode = exitCode
        self.status = status
        self.remediation = remediation
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
}
