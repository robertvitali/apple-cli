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

    public static func encodeSuccess<T: Encodable>(tool: String, data: T) throws -> Data {
        try encode(SuccessEnvelope(schema_version: schemaVersion, tool: tool, ok: true, data: data))
    }

    public static func encodeError(tool: String, type: String, message: String) throws -> Data {
        try encode(ErrorEnvelope(schema_version: schemaVersion, tool: tool, ok: false,
                                 error: .init(type: type, message: message)))
    }

    // MARK: Emit (writes the encoded envelope to stdout)

    public static func emit<T: Encodable>(tool: String, data: T) throws {
        write(try encodeSuccess(tool: tool, data: data))
    }

    public static func emitError(tool: String, type: String, message: String) {
        if let data = try? encodeError(tool: tool, type: type, message: message) {
            write(data)
        } else {
            // Never leave stdout empty on an error path: hand-roll a minimal valid envelope.
            let safe = message.replacingOccurrences(of: "\"", with: "'")
            write(Data(#"{"schema_version":\#(schemaVersion),"tool":"\#(tool)","ok":false,"error":{"type":"unknown","message":"\#(safe)"}}"#.utf8))
        }
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
    }
}
