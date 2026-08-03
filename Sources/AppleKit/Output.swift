import Foundation

/// Machine-facing JSON output — the highest-value, highest-risk part of the CLI
/// contract (agents parse it). stdout carries ONLY this envelope; human/diagnostic
/// text goes to stderr. See docs/DESIGN.md "Output schema as a versioned contract".
///
///   { "schema_version": <int>, "tool": "<domain>", "ok": <bool>, "data": … | "error": … }
///
/// `schema_version` bumps ONLY on a breaking output-shape change. Consumers MUST ignore
/// unknown keys (tolerant reader). Dates are ISO-8601; property names ARE the wire keys
/// verbatim (no key-case conversion) — so payload structs name fields in snake_case.
public enum Output {
    public static let schemaVersion = 1

    // MARK: Encode (pure — unit-testable, no I/O)

    /// `sandbox: true` marks a write envelope produced under the v2 opt-in sandbox
    /// (docs/write-model-v2.md). The parameter is a plain Bool normalized INSIDE — false
    /// omits the key entirely (never emits `"sandbox": false`), so read ops and unsandboxed
    /// writes stay byte-identical to the pre-v2 envelope (ADDITIVE / MINOR) and the natural
    /// call `sandboxActive: sandboxActive` is also the only expressible one; a Bool?
    /// parameter would let a plain `false` auto-promote and silently emit a third state.
    public static func encodeSuccess<T: Encodable>(tool: String, data: T, sandboxActive: Bool = false) throws -> Data {
        try encode(SuccessEnvelope(schema_version: schemaVersion, tool: tool, ok: true,
                                   sandbox: sandboxActive ? true : nil, data: data))
    }

    public static func encodeError(tool: String, type: String, message: String,
                                   status: String? = nil, remediation: String? = nil) throws -> Data {
        try encode(ErrorEnvelope(schema_version: schemaVersion, tool: tool, ok: false,
                                 error: .init(type: type, message: message,
                                              status: status, remediation: remediation)))
    }

    // MARK: Emit (writes the encoded envelope to stdout)

    public static func emit<T: Encodable>(tool: String, data: T, sandboxActive: Bool = false) throws {
        write(try encodeSuccess(tool: tool, data: data, sandboxActive: sandboxActive))
    }

    /// Encode the envelope for an `AppleError`, carrying every field it holds.
    ///
    /// This exists so the mapping from `AppleError` to envelope is ONE named, pure, testable
    /// function rather than an argument list spelled out at each `runGuarded` catch site. Review
    /// flagged that the forwarding of `status`/`remediation` in `runGuarded` was untested, and it
    /// was untestable in the old shape: `runGuarded` writes to stdout and throws `ExitCode`, so a
    /// test could only observe it by capturing file descriptors. Now the part that can be wrong —
    /// which fields get copied — is checkable directly.
    public static func encodeError(tool: String, from error: AppleError) throws -> Data {
        try encodeError(tool: tool, type: error.type, message: error.message,
                        status: error.status, remediation: error.remediation)
    }

    /// Emit the envelope for an `AppleError`. See `encodeError(tool:from:)`.
    public static func emitError(tool: String, from error: AppleError) {
        emitError(tool: tool, type: error.type, message: error.message,
                  status: error.status, remediation: error.remediation)
    }

    public static func emitError(tool: String, type: String, message: String,
                                 status: String? = nil, remediation: String? = nil) {
        if let data = try? encodeError(tool: tool, type: type, message: message,
                                       status: status, remediation: remediation) {
            write(data)
        } else {
            // Never leave stdout empty on an error path: hand-roll a minimal valid envelope,
            // JSON-escaping every interpolated string (RFC 8259) so this last-ditch path can
            // never itself emit malformed JSON — a raw ", \, or control char in `message`
            // would otherwise break the very parse the fallback exists to guarantee.
            // The fallback carries status/remediation too. If it dropped them, the one path that
            // exists BECAUSE encoding failed would also be the one that silently violates the
            // contract those fields establish.
            let extra = (status.map { #","status":\#(jsonString($0))"# } ?? "")
                      + (remediation.map { #","remediation":\#(jsonString($0))"# } ?? "")
            write(Data(#"{"schema_version":\#(schemaVersion),"tool":\#(jsonString(tool)),"ok":false,"error":{"type":\#(jsonString(type)),"message":\#(jsonString(message))\#(extra)}}"#.utf8))
        }
    }

    /// Minimal RFC-8259 JSON string encoder (returns the value WITH surrounding quotes).
    /// Used only by the `emitError` fallback, which must not depend on `JSONEncoder` — the
    /// whole reason it's the fallback is that `JSONEncoder` just failed.
    static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    // Only C0 controls (≤2 hex digits) reach here today, so 4 - hex.count is
                    // never negative — but `max(0,…)` keeps this total if the guard is ever
                    // widened to escape scalars > 0xFFFF (which would trap on a negative count).
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    // MARK: Internals

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        // sortedKeys keeps golden-snapshot tests deterministic; iso8601 fixes date
        // serialization once for the date-heavy domains (Calendar/Reminders/Mail/Messages).
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(value)
    }

    static func write(_ data: Data) {
        // `try?` so a consumer closing the pipe early (`apple … | head`) yields a clean
        // exit, not an uncatchable EPIPE trap. Pair with signal(SIGPIPE, SIG_IGN) at start.
        try? FileHandle.standardOutput.write(contentsOf: data)
        try? FileHandle.standardOutput.write(contentsOf: Data([0x0a])) // trailing newline
    }
}

struct SuccessEnvelope<T: Encodable>: Encodable {
    let schema_version: Int
    let tool: String
    let ok: Bool
    let sandbox: Bool? // synthesized Encodable omits the key when nil (encodeIfPresent)
    let data: T
}

struct ErrorEnvelope: Encodable {
    let schema_version: Int
    let tool: String
    let ok: Bool
    let error: Payload
    struct Payload: Encodable {
        let type: String
        let message: String
        // Optional, so the synthesized Encodable omits them (encodeIfPresent) on the errors that
        // have no authorization dimension. Adding optional fields is MINOR per
        // docs/versioning-policy.md; every existing consumer keeps parsing unchanged.
        let status: String?
        let remediation: String?
    }
}
