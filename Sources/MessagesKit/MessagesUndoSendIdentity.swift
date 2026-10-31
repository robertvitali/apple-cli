import AppleKit
import Foundation

/// Stable identity only: not ownership, native-part eligibility or retraction
/// evidence. Before/after readers must read their additional fields in the same
/// transaction as this envelope, and separately qualify native marker semantics.
enum MessagesUndoSendIdentity {
    enum Failure: Error { case invalidTarget, targetNotFound, unsupportedSchema }

    struct Snapshot: Sendable {
        let chatRowid: Int64
        let chatGUID: String
        let chatStyle: Int64
        let messageRowid: Int64
        let messageGUID: String
        let sentDateRaw: Int64
        let participantHandles: [String]

        func matches(_ other: Snapshot) -> Bool {
            chatRowid == other.chatRowid && chatStyle == other.chatStyle &&
                messageRowid == other.messageRowid && sentDateRaw == other.sentDateRaw &&
                chatGUID.utf8.elementsEqual(other.chatGUID.utf8) &&
                messageGUID.utf8.elementsEqual(other.messageGUID.utf8) &&
                participantHandles.count == other.participantHandles.count &&
                zip(participantHandles, other.participantHandles).allSatisfy {
                    $0.utf8.elementsEqual($1.utf8)
                }
        }
    }

    static func read(databasePath: String, chat: ChatDB.ExactChatSelector,
                     message: ChatDB.ExactMessageSelector, deadline: WorkerDeadline,
                     isCancelled: @escaping () -> Bool = { false }) throws -> Snapshot {
        if isCancelled() { throw WorkerProtocolError.cancelled }
        try checkMessagesAXDeadline(deadline)
        return try SQLiteReader.withBoundedReadTransaction(path: databasePath,
            limits: .init(timeout: min(5, Double(deadline.remainingNanoseconds) / 1_000_000_000),
                          rows: 4096, bytes: 1_048_576, valueBytes: 4096),
            isCancelled: { isCancelled() || deadline.expired }) { scope in
            try read(in: scope, chat: chat, message: message)
        }
    }

    static func read(in scope: SQLiteReadTransaction, chat: ChatDB.ExactChatSelector,
                     message: ChatDB.ExactMessageSelector) throws -> Snapshot {
        for (table, columns) in [
            ("chat", Set(["guid", "style"])), ("message", Set(["guid", "date"])),
            ("chat_message_join", Set(["chat_id", "message_id"])),
            ("handle", Set(["id"])), ("chat_handle_join", Set(["chat_id", "handle_id"]))
        ] { try checkTable(table, columns: columns, scope: scope) }
        let chatPredicate: String, chatValue: String
        switch chat {
        case .rowid(let id):
            guard id > 0 else { throw Failure.invalidTarget }
            chatPredicate = "_rowid_=CAST(?1 AS INTEGER)"; chatValue = String(id)
        case .guid(let guid):
            guard safe(guid) else { throw Failure.invalidTarget }
            chatPredicate = "CAST(guid AS BLOB)=CAST(?1 AS BLOB)"; chatValue = guid
        }
        let chatRow = try single(scope, """
            SELECT _rowid_ AS id, style,
                   CASE WHEN typeof(guid)='text' THEN CAST(guid AS BLOB) END AS guid
            FROM chat WHERE \(chatPredicate) LIMIT 2
            """, [chatValue])
        guard case .integer(let chatID)? = chatRow.values["id"], chatID > 0,
              let chatGUID = try exact(chatRow.values["guid"]), safe(chatGUID),
              case .integer(let style)? = chatRow.values["style"], [43, 45].contains(style) else {
            throw Failure.invalidTarget
        }
        let messagePredicate: String, messageValue: String
        switch message {
        case .rowid(let id):
            guard id > 0 else { throw Failure.invalidTarget }
            messagePredicate = "_rowid_=CAST(?1 AS INTEGER)"; messageValue = String(id)
        case .guid(let guid):
            guard safe(guid) else { throw Failure.invalidTarget }
            messagePredicate = "CAST(guid AS BLOB)=CAST(?1 AS BLOB)"; messageValue = guid
        }
        let row = try single(scope, """
            SELECT _rowid_ AS id, date,
                   CASE WHEN typeof(guid)='text' THEN CAST(guid AS BLOB) END AS guid
            FROM message WHERE \(messagePredicate) LIMIT 2
            """, [messageValue])
        guard case .integer(let messageID)? = row.values["id"], messageID > 0,
              let messageGUID = try exact(row.values["guid"]), safe(messageGUID),
              case .integer(let date)? = row.values["date"], date > 0 else { throw Failure.invalidTarget }
        // A caller-supplied row ID does not waive unique GUID ownership.
        for (table, guid, id) in [("chat", chatGUID, chatID), ("message", messageGUID, messageID)] {
            let owner = try single(scope,
                "SELECT _rowid_ AS id FROM \(table) WHERE CAST(guid AS BLOB)=CAST(?1 AS BLOB) LIMIT 2", [guid])
            guard case .integer(let actual)? = owner.values["id"], actual == id else { throw Failure.invalidTarget }
        }
        let membership = try single(scope, """
            SELECT chat_id,message_id FROM chat_message_join
            WHERE CAST(chat_id AS INTEGER)=CAST(?1 AS INTEGER)
              AND CAST(message_id AS INTEGER)=CAST(?2 AS INTEGER) LIMIT 2
            """, [String(chatID), String(messageID)])
        guard case .integer(let joinedChat)? = membership.values["chat_id"], joinedChat == chatID,
              case .integer(let joinedMessage)? = membership.values["message_id"], joinedMessage == messageID else {
            throw Failure.invalidTarget
        }
        var participants: [String] = []
        try scope.forEachRow("""
            SELECT j.chat_id,j.handle_id,h._rowid_ AS actual_handle,
                   CASE WHEN typeof(h.id)='text' THEN CAST(h.id AS BLOB) END AS address
            FROM chat_handle_join j LEFT JOIN handle h ON h._rowid_=j.handle_id
            WHERE CAST(j.chat_id AS INTEGER)=CAST(?1 AS INTEGER) LIMIT 33
            """, [String(chatID)]) { member in
            guard case .integer(let joined)? = member.values["chat_id"], joined == chatID,
                  case .integer(let handle)? = member.values["handle_id"], handle > 0,
                  case .integer(let actual)? = member.values["actual_handle"], actual == handle,
                  let address = try exact(member.values["address"]), safe(address), participants.count < 32,
                  !participants.contains(where: { $0.utf8.elementsEqual(address.utf8) }) else {
                throw Failure.invalidTarget
            }
            participants.append(address)
        }
        guard !participants.isEmpty else { throw Failure.invalidTarget }
        participants.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        return Snapshot(chatRowid: chatID, chatGUID: chatGUID, chatStyle: style,
                        messageRowid: messageID, messageGUID: messageGUID, sentDateRaw: date,
                        participantHandles: participants)
    }

    private static func exact(_ value: SQLiteReader.Row.Value?) throws -> String? {
        try MessagesAttachmentSnapshot.exactText(value)
    }

    private static func safe(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 &&
            !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    private static func single(_ scope: SQLiteReadTransaction, _ sql: String,
                               _ bindings: [String]) throws -> SQLiteReader.Row {
        var found: SQLiteReader.Row?
        try scope.forEachRow(sql, bindings) { row in
            guard found == nil else { throw Failure.invalidTarget }
            found = row
        }
        guard let found else { throw Failure.targetNotFound }
        return found
    }

    private static func checkTable(_ table: String, columns required: Set<String>,
                                   scope: SQLiteReadTransaction) throws {
        let schema = try single(scope,
            "SELECT type,rootpage FROM sqlite_schema WHERE name=?1 COLLATE NOCASE", [table])
        guard case .text("table")? = schema.values["type"], case .integer(let root)? = schema.values["rootpage"],
              root > 0 else { throw Failure.unsupportedSchema }
        var columns = Set<String>()
        try scope.forEachTableColumn(table) { row in
            guard case .text(let name)? = row.values["column_name"] else { throw Failure.unsupportedSchema }
            columns.insert(name.lowercased())
        }
        guard required.isSubset(of: columns), !columns.contains("_rowid_") else {
            throw Failure.unsupportedSchema
        }
    }
}
