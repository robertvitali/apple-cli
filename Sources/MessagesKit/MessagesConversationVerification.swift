import AppleKit
import Foundation

/// Read-only observed-state evidence. No result, or any thrown error, is not
/// permission to repeat a send or resolve a pending handoff.
enum MessagesConversationVerification {
    enum Failure: Error { case ambiguous, invalidObservation, invalidRequest, limitExceeded }
    enum Observation: String, Sendable {
        case presentAtBaseline = "present_at_baseline"
        case firstObservedAfterBaseline = "first_observed_after_baseline"
        case unestablished
    }
    struct Evidence: Sendable {
        let messageRowid: Int64
        let messageGUID: String
        let conversation: MessagesConversationStore.Conversation
        let observation: Observation
        var creationAttribution: String { "unproven" }
    }

    static func read(databasePath: String, baseline: MessagesConversationBaseline.Snapshot,
                     initialText: String, deadline: WorkerDeadline,
                     isCancelled: @escaping () -> Bool = { false }) throws -> Evidence? {
        func checkpoint() throws {
            if isCancelled() { throw WorkerProtocolError.cancelled }
            if deadline.expired { throw WorkerProtocolError.deadlineExpired }
        }
        try checkpoint()
        guard initialText.utf8.prefix(2049).count <= 2048, !initialText.utf8.contains(0),
              !initialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.invalidRequest
        }
        return try SQLiteReader.withBoundedReadTransaction(path: databasePath,
            limits: .init(timeout: min(5, Double(deadline.remainingNanoseconds) / 1_000_000_000),
                          rows: 65_536, bytes: 16_777_216, valueBytes: 1_048_576),
            isCancelled: { isCancelled() || deadline.expired }) { scope in
                try MessagesConversationStore.validateSchema(in: scope)
                // Finish enumeration before dependent reads: the transaction forbids
                // reentrant queries and a truncated set cannot prove uniqueness.
                var rows: [SQLiteReader.Row] = []
                try scope.forEachRow("""
                    SELECT _rowid_ AS id,
                           CASE WHEN typeof(guid)='text' THEN CAST(guid AS BLOB) END AS guid,
                           typeof(text) AS text_type,
                           CASE WHEN typeof(text)='text' THEN CAST(text AS BLOB) END AS text,
                           attributedBody,is_from_me,is_sent,error,service
                    FROM message WHERE _rowid_>CAST(?1 AS INTEGER) ORDER BY _rowid_ LIMIT 513
                    """, [String(baseline.maximumMessageRowid)]) { row in
                        guard rows.count < 512 else { throw Failure.limitExceeded }
                        rows.append(row)
                    }
                var result: Evidence?
                for row in rows {
                    try checkpoint()
                    guard case .integer(let id)? = row.values["id"], id > baseline.maximumMessageRowid,
                          case .integer(let own)? = row.values["is_from_me"], own == 0 || own == 1,
                          case .text(let service)? = row.values["service"] else { throw Failure.invalidObservation }
                    guard own == 1, service == "iMessage" else { continue }
                    let text = try exactText(row)
                    try checkpoint()
                    guard text.utf8.elementsEqual(initialText.utf8) else { continue }
                    guard case .integer(1)? = row.values["is_sent"],
                          case .integer(0)? = row.values["error"] else { throw Failure.invalidObservation }
                    let messageGUID = try guid(row.values["guid"])
                    try verifyMessageGUID(messageGUID, rowid: id, in: scope)
                    let conversation = try conversation(for: id, in: scope)
                    guard conversation.recipients == baseline.requestedRecipients,
                          conversation.style == (baseline.requestedRecipients.count > 1 ? 43 : 45) else { continue }
                    if baseline.requestedRecipients.count == 1, baseline.matchingConversations.count == 1 {
                        guard conversation.hasSameIdentity(as: baseline.matchingConversations[0]) else {
                            throw Failure.invalidObservation
                        }
                    }
                    try requireNoAttachments(messageRowid: id, in: scope)
                    guard result == nil else { throw Failure.ambiguous }
                    let observation: Observation
                    if baseline.matchingConversations.contains(where: { $0.hasSameIdentity(as: conversation) }) {
                        observation = .presentAtBaseline
                    } else if conversation.rowid > baseline.maximumChatRowid,
                              !baseline.matchingConversations.contains(where: {
                                  $0.guid.utf8.elementsEqual(conversation.guid.utf8)
                              }) {
                        observation = .firstObservedAfterBaseline
                    } else { observation = .unestablished }
                    result = Evidence(messageRowid: id, messageGUID: messageGUID,
                                      conversation: conversation, observation: observation)
                }
                try checkpoint()
                return result
            }
    }

    private static func exactText(_ row: SQLiteReader.Row) throws -> String {
        let column: String?
        switch row.values["text_type"] {
        case .text("null"): column = nil
        case .text("text"):
            guard case .blob(let bytes)? = row.values["text"],
                  let value = String(data: bytes, encoding: .utf8) else { throw Failure.invalidObservation }
            column = value
        default: throw Failure.invalidObservation
        }
        switch row.values["attributedBody"] {
        case .null:
            guard let column else { throw Failure.invalidObservation }
            return column
        case .blob(let bytes):
            let decoded = NativeMessageParts.decode(bytes, requireExactText: true)
            guard let body = decoded.text, decoded.status == .decoded || decoded.status == .noNativeKeys else {
                throw Failure.invalidObservation
            }
            if let column, !column.utf8.elementsEqual(body.utf8) { throw Failure.invalidObservation }
            // A creation send is text only. Known attachment parts cannot be
            // accepted just because their body text happens to match.
            if let parts = decoded.nativeParts, parts.contains(where: { $0.attachmentGUID != nil }) {
                throw Failure.invalidObservation
            }
            return body
        default: throw Failure.invalidObservation
        }
    }

    private static func guid(_ value: SQLiteReader.Row.Value?) throws -> String {
        guard case .blob(let bytes)? = value, !bytes.isEmpty, bytes.count <= 512,
              let guid = String(data: bytes, encoding: .utf8),
              !guid.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw Failure.invalidObservation
        }
        return guid
    }

    private static func verifyMessageGUID(_ guid: String, rowid: Int64,
                                          in scope: SQLiteReadTransaction) throws {
        var found = false
        try scope.forEachRow("SELECT _rowid_ AS id FROM message WHERE CAST(guid AS BLOB)=CAST(?1 AS BLOB) LIMIT 2",
                            [guid]) { row in
            guard !found, case .integer(let id)? = row.values["id"], id == rowid else {
                throw Failure.invalidObservation
            }
            found = true
        }
        guard found else { throw Failure.invalidObservation }
    }

    private static func conversation(for messageRowid: Int64,
                                     in scope: SQLiteReadTransaction) throws -> MessagesConversationStore.Conversation {
        var chatID: Int64?
        try scope.forEachRow("""
            SELECT chat_id,message_id FROM chat_message_join
            WHERE CAST(message_id AS INTEGER)=CAST(?1 AS INTEGER) LIMIT 2
            """, [String(messageRowid)]) { row in
                guard chatID == nil, case .integer(let chat)? = row.values["chat_id"], chat > 0,
                      case .integer(let message)? = row.values["message_id"], message == messageRowid else {
                    throw Failure.invalidObservation
                }
                chatID = chat
            }
        guard let chatID else { throw Failure.invalidObservation }
        var header: MessagesConversationStore.Header?
        try scope.forEachRow("""
            SELECT _rowid_ AS id,style,service_name,
                   CASE WHEN typeof(guid)='text' THEN CAST(guid AS BLOB) END AS guid
            FROM chat WHERE _rowid_=CAST(?1 AS INTEGER) LIMIT 2
            """, [String(chatID)]) { row in
                guard header == nil, case .integer(let id)? = row.values["id"], id == chatID,
                      case .integer(let style)? = row.values["style"], [43, 45].contains(style),
                      case .text("iMessage")? = row.values["service_name"],
                      case .blob(let guid)? = row.values["guid"] else { throw Failure.invalidObservation }
                header = .init(rowid: id, style: style, guidBytes: guid)
            }
        guard let header else { throw Failure.invalidObservation }
        let members = try MessagesConversationStore.members(chatRowid: chatID, in: scope)
        return try MessagesConversationStore.verifiedConversation(header: header, members: members, in: scope)
    }

    private static func requireNoAttachments(messageRowid: Int64, in scope: SQLiteReadTransaction) throws {
        try scope.forEachRow("""
            SELECT message_id FROM message_attachment_join
            WHERE CAST(message_id AS INTEGER)=CAST(?1 AS INTEGER) LIMIT 1
            """, [String(messageRowid)]) { _ in throw Failure.invalidObservation }
    }
}
