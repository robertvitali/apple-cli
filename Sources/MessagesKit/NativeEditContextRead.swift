import Foundation
import AppleKit

/// Read-only observations, separately bounded from the existing message body.
/// Never used as evidence that a message mutation is safe or eligible.
enum NativeEditContextRead {
    typealias Context = ChatDB.ExactNativeEditContext
    typealias Row = SQLiteReader.Row

    struct Budget {
        var remainingInputBytes = 4_194_304
        var decoder = NativeEditContextDecoder.Budget()
    }

    private enum DateColumn: String, CaseIterable {
        case date_edited, date_retracted
        var typeAlias: String { "native_edit_\(rawValue)_type" }
        var valueAlias: String { "native_edit_\(rawValue)_value" }
    }

    static func projection(columns: Set<String>) -> String {
        var fields = DateColumn.allCases.map { column in
            guard columns.contains(column.rawValue) else {
                return "'missing-schema' AS \(column.typeAlias), NULL AS \(column.valueAlias)"
            }
            return "typeof(m.\(column.rawValue)) AS \(column.typeAlias), "
                + "CASE WHEN typeof(m.\(column.rawValue)) = 'integer' THEN m.\(column.rawValue) "
                + "ELSE NULL END AS \(column.valueAlias)"
        }
        if columns.contains("message_summary_info") {
            fields.append(summaryMetadataProjection)
        } else {
            fields.append("'missing-schema' AS native_edit_summary_type, NULL AS native_edit_summary_length")
        }
        return fields.joined(separator: ", ")
    }

    // length(TEXT) scans characters and can be arbitrarily expensive. The CASE
    // keeps wrong-type values out of both length and byte materialization.
    private static let summaryMetadataProjection = """
        typeof(m.message_summary_info) AS native_edit_summary_type,
        CASE WHEN typeof(m.message_summary_info) = 'blob'
             THEN length(m.message_summary_info) ELSE NULL END AS native_edit_summary_length
        """

    static func context(_ row: Row, requested: Bool, budget: inout Budget,
                        requireExactHistoryText: Bool = false,
                        read: (String, [String]) throws -> [Row],
                        checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Context {
        let summary: Context.Summary
        if requested {
            summary = try fetchSummary(row, budget: &budget, requireExactHistoryText: requireExactHistoryText,
                                       read: read, checkCancellation: checkCancellation)
        } else {
            summary = .unavailable("not-requested")
        }
        return .init(date_edited: date(row, .date_edited), date_retracted: date(row, .date_retracted),
                     summary_info: summary)
    }

    private static func date(_ row: Row, _ column: DateColumn) -> ChatDB.ExactNativeStatus.TimestampField {
        guard case .text(let type)? = row.values[column.typeAlias] else {
            return NativeMessageTimestamp.unavailable("wrong-type")
        }
        switch type {
        case "missing-schema", "null": return NativeMessageTimestamp.unavailable(type)
        case "integer":
            guard case .integer(let raw)? = row.values[column.valueAlias] else {
                return NativeMessageTimestamp.unavailable("wrong-type")
            }
            return NativeMessageStatusDecoder.timestamp(raw: raw)
        default: return NativeMessageTimestamp.unavailable("wrong-type")
        }
    }

    /// A nil status means an eligible nonempty bounded BLOB observation.
    private static func unavailableStatus(_ row: Row, remaining: Int) -> String? {
        guard case .text(let type)? = row.values["native_edit_summary_type"] else { return "wrong-type" }
        switch type {
        case "missing-schema", "null": return type
        case "blob":
            guard case .integer(let length)? = row.values["native_edit_summary_length"], length >= 0 else {
                return "read-error"
            }
            if length == 0 { return "empty" }
            if length > 1_048_576 { return "too-large" }
            if length > remaining { return "request-limit" }
            return nil
        default: return "wrong-type"
        }
    }

    private static func fetchSummary(_ row: Row, budget: inout Budget,
                                     requireExactHistoryText: Bool,
                                     read: (String, [String]) throws -> [Row],
                                     checkCancellation: () throws -> Void) throws -> Context.Summary {
        try checkCancellation()
        if let status = unavailableStatus(row, remaining: budget.remainingInputBytes) {
            return .unavailable(status)
        }
        guard case .integer(let messageRowid)? = row.values["rowid"],
              case .integer(let chatRowid)? = row.values["selected_chat_rowid"],
              case .text(let guid)? = row.values["message_guid"],
              !guid.isEmpty, guid.utf8.count <= 1_024,
              !guid.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return .unavailable("identity-unavailable")
        }
        var binds = [String(messageRowid), guid, String(chatRowid), String(budget.remainingInputBytes)]
        let chatPredicate: String
        switch row.values["chat_guid"] {
        case .null?: chatPredicate = "c.guid IS NULL"
        case .text(let chatGUID)?:
            guard !chatGUID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                return .unavailable("identity-unavailable")
            }
            chatPredicate = "typeof(c.guid) = 'text' AND c.guid COLLATE BINARY = ?5 COLLATE BINARY"
            binds.append(chatGUID)
        default: return .unavailable("identity-unavailable")
        }
        let sql = """
            SELECT \(summaryMetadataProjection),
                   CASE WHEN typeof(m.message_summary_info) = 'blob' THEN
                        CASE WHEN length(m.message_summary_info) BETWEEN 1 AND 1048576
                                  AND length(m.message_summary_info) <= CAST(?4 AS INTEGER)
                             THEN m.message_summary_info ELSE NULL END
                        ELSE NULL END AS native_edit_summary_blob
            FROM chat_message_join cmj
            JOIN chat c ON c.ROWID = cmj.chat_id
            JOIN message m ON m.ROWID = cmj.message_id
            WHERE m.ROWID = ?1 AND typeof(m.guid) = 'text'
              AND m.guid COLLATE BINARY = ?2 COLLATE BINARY
              AND c.ROWID = ?3 AND \(chatPredicate)
            LIMIT 1
            """
        let rows: [Row]
        do {
            rows = try read(sql, binds)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try checkCancellation()
            return .unavailable("read-error")
        }
        try checkCancellation()
        guard let actual = rows.first else { return .unavailable("changed") }
        if let status = unavailableStatus(actual, remaining: budget.remainingInputBytes) {
            return .unavailable(status)
        }
        guard case .blob(let data)? = actual.values["native_edit_summary_blob"],
              case .integer(let length)? = actual.values["native_edit_summary_length"],
              data.count == length, data.count <= budget.remainingInputBytes else {
            return .unavailable("read-error")
        }
        budget.remainingInputBytes -= data.count
        return try NativeEditContextDecoder.decode(data, budget: &budget.decoder,
            requireExactHistoryText: requireExactHistoryText, checkCancellation: checkCancellation)
    }
}
