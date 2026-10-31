import AppleKit
import Foundation

/// Raw persisted observations only. Marker semantics must be qualified before
/// any caller can interpret these fields as a successful native retraction.
enum MessagesUndoSendObservation {
    enum Failure: Error, Equatable { case unsupportedSchema, invalidObservation }

    enum Field<Value: Equatable & Sendable>: Equatable, Sendable {
        case value(Value)
        case null
        case wrongType
    }

    struct Snapshot: Sendable {
        let identity: MessagesUndoSendIdentity.Snapshot
        let isFromMe: Field<Int64>
        let isSent: Field<Int64>
        let error: Field<Int64>
        let dateEdited: Field<Int64>
        let dateRetracted: Field<Int64>
        let serviceUTF8: Field<Data>
        let textUTF8: Field<Data>
        let attributedBody: Field<Data>
        let summaryInfo: Field<Data>
    }

    static func read(databasePath: String, chat: ChatDB.ExactChatSelector,
                     message: ChatDB.ExactMessageSelector, deadline: WorkerDeadline,
                     isCancelled: @escaping () -> Bool = { false }) throws -> Snapshot {
        if isCancelled() { throw WorkerProtocolError.cancelled }
        try checkMessagesAXDeadline(deadline)
        return try SQLiteReader.withBoundedReadTransaction(path: databasePath,
            limits: .init(timeout: min(5, Double(deadline.remainingNanoseconds) / 1_000_000_000),
                          rows: 4096, bytes: 16_777_216, valueBytes: 1_048_576),
            isCancelled: { isCancelled() || deadline.expired }) { scope in
            try read(in: scope, chat: chat, message: message)
        }
    }

    /// Read within the caller's pinned transaction so attachment membership
    /// can share the exact same snapshot as identity and message fields.
    static func read(in scope: SQLiteReadTransaction, chat: ChatDB.ExactChatSelector,
                     message: ChatDB.ExactMessageSelector) throws -> Snapshot {
        let identity = try MessagesUndoSendIdentity.read(in: scope, chat: chat, message: message)
        // Names and storage classes are fixed source constants, never caller input.
        let fields = [
            ("is_from_me", "integer"), ("is_sent", "integer"), ("error", "integer"),
            ("date_edited", "integer"), ("date_retracted", "integer"),
            ("service", "text"), ("text", "text"),
            ("attributedBody", "blob"), ("message_summary_info", "blob")
        ]
        var columns = Set<String>()
        try scope.forEachTableColumn("message") { row in
            guard case .text(let name)? = row.values["column_name"] else {
                throw Failure.unsupportedSchema
            }
            columns.insert(name.lowercased())
        }
        guard fields.allSatisfy({ columns.contains($0.0.lowercased()) }) else {
            throw Failure.unsupportedSchema
        }
        let projection = fields.map { name, type in
            let value = type == "text" ? "CAST(\(name) AS BLOB)" : name
            return "typeof(\(name)) AS \(name)_type, " +
                "CASE WHEN typeof(\(name))='\(type)' THEN \(value) END AS \(name)_value"
        }.joined(separator: ", ")
        var found: SQLiteReader.Row?
        try scope.forEachRow("SELECT \(projection) FROM message WHERE _rowid_=CAST(?1 AS INTEGER) LIMIT 2",
                             [String(identity.messageRowid)]) { row in
            guard found == nil else { throw Failure.invalidObservation }
            found = row
        }
        guard let row = found else { throw Failure.invalidObservation }
        return try Snapshot(identity: identity,
            isFromMe: integer("is_from_me", row), isSent: integer("is_sent", row),
            error: integer("error", row), dateEdited: integer("date_edited", row),
            dateRetracted: integer("date_retracted", row),
            serviceUTF8: bytes("service", type: "text", row),
            textUTF8: bytes("text", type: "text", row),
            attributedBody: bytes("attributedBody", type: "blob", row),
            summaryInfo: bytes("message_summary_info", type: "blob", row))
    }

    private static func storage(_ name: String, _ row: SQLiteReader.Row) throws -> String {
        guard case .text(let type)? = row.values["\(name)_type"],
              ["null", "integer", "real", "text", "blob"].contains(type) else {
            throw Failure.invalidObservation
        }
        return type
    }

    private static func integer(_ name: String, _ row: SQLiteReader.Row) throws -> Field<Int64> {
        let type = try storage(name, row)
        if type == "null" { return .null }
        guard type == "integer" else { return .wrongType }
        guard case .integer(let value)? = row.values["\(name)_value"] else {
            throw Failure.invalidObservation
        }
        return .value(value)
    }

    private static func bytes(_ name: String, type expected: String,
                              _ row: SQLiteReader.Row) throws -> Field<Data> {
        let type = try storage(name, row)
        if type == "null" { return .null }
        guard type == expected else { return .wrongType }
        guard case .blob(let value)? = row.values["\(name)_value"] else {
            throw Failure.invalidObservation
        }
        return .value(value)
    }
}
