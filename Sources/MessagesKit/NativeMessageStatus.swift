import Foundation
import AppleKit

extension ChatDB {
    /// Native row observations, never mutation authority or per-recipient receipts.
    public struct ExactNativeStatus: Encodable, Equatable, Sendable {
        public let error: ErrorField
        public let is_delivered: BooleanField
        public let is_read: BooleanField
        public let date_delivered: TimestampField
        public let date_read: TimestampField

        public struct ErrorField: Encodable, Equatable, Sendable {
            public let status: String
            public let raw: Int64?
            public let is_error: Bool?
            enum CodingKeys: String, CodingKey { case status, raw, is_error }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(status, forKey: .status)
                try encodeOrNull(&c, raw, .raw)
                try encodeOrNull(&c, is_error, .is_error)
            }
        }

        public struct BooleanField: Encodable, Equatable, Sendable {
            public let status: String
            public let raw: Int64?
            public let value: Bool?
            enum CodingKeys: String, CodingKey { case status, raw, value }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(status, forKey: .status)
                try encodeOrNull(&c, raw, .raw)
                try encodeOrNull(&c, value, .value)
            }
        }

        public struct TimestampField: Encodable, Equatable, Sendable {
            public let status: String
            public let raw: Int64?
            public let normalized_seconds: Int64?
            /// Subsecond remainder, not total nanoseconds since the epoch.
            public let normalized_nanoseconds: Int64?
            public let date: String?
            public let date_local: String?
            enum CodingKeys: String, CodingKey {
                case status, raw, normalized_seconds, normalized_nanoseconds, date, date_local
            }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(status, forKey: .status)
                try encodeOrNull(&c, raw, .raw)
                try encodeOrNull(&c, normalized_seconds, .normalized_seconds)
                try encodeOrNull(&c, normalized_nanoseconds, .normalized_nanoseconds)
                try encodeOrNull(&c, date, .date)
                try encodeOrNull(&c, date_local, .date_local)
            }
        }
    }
}

/// Isolates optional native metadata from legacy reads and send-success proofs.
enum NativeMessageStatusDecoder {
    private enum Column: String, CaseIterable {
        case error, is_delivered, is_read, date_delivered, date_read
        var typeAlias: String { "native_status_\(rawValue)_type" }
        var valueAlias: String { "native_status_\(rawValue)_value" }
    }
    private typealias Status = ChatDB.ExactNativeStatus

    static func projection(columns: Set<String>) -> String {
        Column.allCases.map { column in
            guard columns.contains(column.rawValue) else {
                return "'missing-schema' AS \(column.typeAlias), NULL AS \(column.valueAlias)"
            }
            // Identifiers come only from the fixed enum. Project the storage type
            // without asking SQLiteReader to decode malformed TEXT or BLOB bytes.
            return "typeof(m.\(column.rawValue)) AS \(column.typeAlias), "
                + "CASE WHEN typeof(m.\(column.rawValue)) = 'integer' THEN m.\(column.rawValue) "
                + "ELSE NULL END AS \(column.valueAlias)"
        }.joined(separator: ", ")
    }

    static func decode(_ row: SQLiteReader.Row) -> ChatDB.ExactNativeStatus {
        let error = integer(row, .error)
        return Status(error: .init(status: error.status, raw: error.raw, is_error: error.raw.map { $0 != 0 }),
                      is_delivered: boolean(row, .is_delivered), is_read: boolean(row, .is_read),
                      date_delivered: timestamp(row, .date_delivered), date_read: timestamp(row, .date_read))
    }

    private static func integer(_ row: SQLiteReader.Row, _ column: Column) -> (status: String, raw: Int64?) {
        integer(storageType: row.values[column.typeAlias], value: row.values[column.valueAlias])
    }

    private static func integer(storageType: SQLiteReader.Row.Value?, value: SQLiteReader.Row.Value?) -> (status: String, raw: Int64?) {
        guard case .text(let type)? = storageType else { return ("wrong-type", nil) }
        switch type {
        case "missing-schema": return ("missing-schema", nil)
        case "null": return ("null", nil)
        case "integer":
            guard case .integer(let raw)? = value else { return ("wrong-type", nil) }
            return ("available", raw)
        default: return ("wrong-type", nil)
        }
    }

    private static func boolean(_ row: SQLiteReader.Row, _ column: Column) -> Status.BooleanField {
        boolean(storageType: row.values[column.typeAlias], value: row.values[column.valueAlias])
    }

    static func boolean(storageType: SQLiteReader.Row.Value?, value: SQLiteReader.Row.Value?) -> ChatDB.ExactNativeStatus.BooleanField {
        let field = integer(storageType: storageType, value: value)
        guard let raw = field.raw else { return .init(status: field.status, raw: nil, value: nil) }
        guard raw == 0 || raw == 1 else { return .init(status: "invalid-boolean", raw: raw, value: nil) }
        return .init(status: "available", raw: raw, value: raw == 1)
    }

    private static func timestamp(_ row: SQLiteReader.Row, _ column: Column) -> Status.TimestampField {
        let field = integer(row, column)
        guard let raw = field.raw else { return unavailableTimestamp(field.status, raw: nil) }
        return timestamp(raw: raw)
    }

    private static func unavailableTimestamp(_ status: String, raw: Int64?) -> Status.TimestampField {
        .init(status: status, raw: raw, normalized_seconds: nil, normalized_nanoseconds: nil,
              date: nil, date_local: nil)
    }

    static func timestamp(raw: Int64, timeZone: TimeZone = .current,
                          format: (Int64, TimeZone) -> (String, String) = NativeMessageTimestamp.formatSeconds) -> ChatDB.ExactNativeStatus.TimestampField {
        guard raw > 0 else { return unavailableTimestamp(raw == 0 ? "zero-sentinel" : "negative", raw: raw) }
        // Repository compatibility heuristic: <= ten digits is Apple-epoch
        // seconds, larger integers are nanoseconds. Preserve raw for consumers.
        let seconds = raw <= 9_999_999_999 ? raw : raw / 1_000_000_000
        let remainder = raw <= 9_999_999_999 ? 0 : raw % 1_000_000_000
        let (utc, local) = format(seconds, timeZone)
        guard NativeMessageTimestamp.valid(utc: utc, local: local) else {
            return unavailableTimestamp("invalid-timestamp", raw: raw)
        }
        return .init(status: "available", raw: raw, normalized_seconds: seconds,
                     normalized_nanoseconds: remainder, date: utc, date_local: local)
    }

}
