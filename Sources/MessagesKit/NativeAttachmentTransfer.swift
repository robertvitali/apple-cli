import AppleKit

extension ChatDB {
    /// A native transfer observation, not proof that a local file is readable.
    public struct NativeAttachmentTransfer: Encodable, Equatable, Sendable {
        public let status: String
        public let raw: Int64?
        public let state: String?

        enum CodingKeys: String, CodingKey { case status, raw, state }
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(status, forKey: .status)
            try encodeOrNull(&container, raw, .raw)
            try encodeOrNull(&container, state, .state)
        }
    }
}

enum NativeAttachmentTransferDecoder {
    // Native names preserve thumbnail and recoverable error distinctions.
    private static let states = ["waiting-for-accept", "accepted", "preparing", "transferring", "finalizing",
                                 "finished", "error", "recoverable-error", "rejected", "thumbnail"]

    static func projection(columns: Set<String>) -> String {
        guard columns.contains("transfer_state") else {
            return "'missing-schema' AS native_transfer_type, NULL AS native_transfer_value"
        }
        // Never materialize malformed text or arbitrary blobs from this column.
        return "typeof(a.transfer_state) AS native_transfer_type, "
            + "CASE WHEN typeof(a.transfer_state) = 'integer' THEN a.transfer_state "
            + "ELSE NULL END AS native_transfer_value"
    }

    static func decode(_ row: SQLiteReader.Row) -> ChatDB.NativeAttachmentTransfer {
        decode(storageType: row.values["native_transfer_type"], value: row.values["native_transfer_value"])
    }

    static func decode(storageType: SQLiteReader.Row.Value?, value: SQLiteReader.Row.Value?) -> ChatDB.NativeAttachmentTransfer {
        guard case .text(let type)? = storageType else {
            return .init(status: "wrong-type", raw: nil, state: nil)
        }
        switch type {
        case "missing-schema", "null": return .init(status: type, raw: nil, state: nil)
        case "integer":
            guard case .integer(let raw)? = value else {
                return .init(status: "wrong-type", raw: nil, state: nil)
            }
            guard raw >= 0 && raw < Int64(states.count) else {
                return .init(status: "unknown-state", raw: raw, state: nil)
            }
            return .init(status: "available", raw: raw, state: states[Int(raw)])
        default: return .init(status: "wrong-type", raw: nil, state: nil)
        }
    }
}
