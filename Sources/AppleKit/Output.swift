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

    /// Text-aware emit (Q12 [10]/CAL-05): JSON when `text` is false (the machine contract,
    /// byte-exact), else a generic human rendering — one flat `key: value` pass over the
    /// payload's JSON object, EVERY string value neutralized for the terminal ([17]). Write
    /// surfaces that used bare `emit(...)` silently ignored `--text`; routing them here makes
    /// the globally-advertised flag honest without a hand-written formatter per command.
    /// `--text` is NOT the versioned contract; the JSON path is unchanged.
    public static func emit<T: Encodable>(tool: String, data: T, text: Bool,
                                          sandboxActive: Bool = false) throws {
        guard text else { try emit(tool: tool, data: data, sandboxActive: sandboxActive); return }
        let body = try humanText(data)
        let out = sandboxActive ? "sandbox: true\n" + body : body
        write(Data((out + "\n").utf8))
    }

    /// Print one human `--text` line to stdout with terminal control sequences neutralized
    /// (Q12 [17]). The single primitive every hand-written `--text` renderer should use in
    /// place of `print(...)` so a store-derived string can never carry a driving escape.
    public static func printText(_ line: String) {
        FileHandle.standardOutput.write(Data((TextSanitize.neutralizeForTerminal(line) + "\n").utf8))
    }

    /// One flat pass over the payload's JSON object → `key: value` lines (nested
    /// objects/arrays as compact JSON), every STRING value run through
    /// `TextSanitize.neutralizeForTerminal`. Shared by the domain `--text` paths so the
    /// neutralization ([17]) cannot be forgotten at one sink.
    public static func humanText<T: Encodable>(_ value: T) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(value)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return TextSanitize.neutralizeForTerminal(String(decoding: data, as: UTF8.self))
        }
        return obj.keys.sorted().map { "\($0): \(humanValue(obj[$0]!))" }.joined(separator: "\n")
    }

    private static func humanValue(_ any: Any) -> String {
        if any is NSNull { return "null" }
        if let s = any as? String { return TextSanitize.neutralizeForTerminal(s) }
        // JSONSerialization bridges BOTH JSON booleans and JSON numbers to NSNumber, and
        // `NSNumber(0/1) as? Bool` succeeds — so an `as? Bool` test placed before the NSNumber
        // branch would render a numeric count of 0/1 (moved_count, unread, deleted_count) as
        // "false"/"true". Detect a real JSON boolean by its CFBoolean type id instead of `as?`.
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        if let d = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys, .withoutEscapingSlashes]) {
            // Nested container: neutralize the whole serialized blob so an ANSI byte inside a
            // nested string value can't slip through the compact form.
            return TextSanitize.neutralizeForTerminal(String(decoding: d, as: UTF8.self))
        }
        return TextSanitize.neutralizeForTerminal(String(describing: any))
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

/// Write-model v2 normalization (Q12): stamps `dry_run: false` into the SAME top-level
/// object as the wrapped execute-path payload — flat on the wire, additive (MINOR) — so
/// result models that are SHARED with read paths (calendar's Event, notes' op results)
/// don't grow a permanent optional field just to satisfy the execute-envelope rule
/// ("Every execute-path envelope must emit `dry_run: false` explicitly",
/// docs/write-model-v2.md). Wrap the payload at the emit site:
/// `Output.emit(tool:, data: ExecutedWrite(payload), …)`.
///
/// CONSTRAINTS (review M2/M3): the payload MUST encode into a KEYED container — an array or
/// single-value payload hits Foundation's precondition and aborts with an EMPTY stdout, the
/// exact outcome emitError exists to prevent — and MUST NOT declare its own `dry_run` field
/// (a keyed container silently last-write-wins, so a payload's `dry_run: true` would be
/// overwritten to `false` — the dangerous direction). Every current payload is a keyed
/// struct without the field (swept + reviewed); keep it that way when wiring new writes.
public struct ExecutedWrite<T: Encodable>: Encodable {
    public let payload: T
    public init(_ payload: T) { self.payload = payload }
    private struct DynKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    public func encode(to encoder: Encoder) throws {
        #if DEBUG
        // Fail loudly in debug on the two wiring mistakes the wire cannot signal (review
        // M1/M2): a payload that ALREADY declares dry_run (a preview stamped false is the
        // dangerous direction — "a write happened" when it did not), or a non-keyed payload
        // (array/scalar → Foundation traps with EMPTY stdout, defeating runGuarded). Both are
        // unreachable at every current call site; this converts a future footgun into a test
        // failure rather than a silent lie or a crash.
        if let data = try? JSONEncoder().encode(payload),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            precondition(obj is [String: Any],
                         "ExecutedWrite requires a KEYED payload; got a non-object")
            if let dict = obj as? [String: Any] {
                precondition(dict["dry_run"] == nil,
                             "ExecutedWrite wraps a payload that already declares dry_run — "
                             + "previews must use the plain emit path, never ExecutedWrite")
            }
        }
        #endif
        try payload.encode(to: encoder)
        var c = encoder.container(keyedBy: DynKey.self)
        try c.encode(false, forKey: DynKey("dry_run"))
    }
}
