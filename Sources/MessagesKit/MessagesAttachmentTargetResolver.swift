import AppleKit
import Foundation

/// Reads only retrieval evidence. Budgets and deadlines are cooperative and do
/// not preempt a kernel I/O call. No whole-store copy or presentation enrichment.
enum MessagesAttachmentTargetResolver {
    enum Failure: Error { case invalidTarget, targetNotFound, unsupportedSchema, sandboxViolation }
    struct Capture {
        let request: MessagesAttachmentRetrievalRequest
        let items: [MessagesAttachmentSnapshot.Item]
    }

    static func read(databasePath: String, chat: ChatDB.ExactChatSelector,
                     message: ChatDB.ExactMessageSelector, partIndex: Int,
                     sandboxPrefix: String?, deadline: WorkerDeadline,
                     isCancelled: @escaping () -> Bool = { false }) throws -> Capture {
        func checkpoint() throws {
            if isCancelled() { throw WorkerProtocolError.cancelled }
            try checkMessagesAXDeadline(deadline)
        }
        try checkpoint()
        guard partIndex >= 0 else { throw Failure.invalidTarget }
        let timeout = min(5, Double(deadline.remainingNanoseconds) / 1_000_000_000)
        return try SQLiteReader.withBoundedReadTransaction(path: databasePath,
            limits: .init(timeout: timeout, rows: 4096, bytes: 16 * 1024 * 1024,
                          valueBytes: NativeMessageParts.Limits.default.maxBlobBytes),
            isCancelled: { isCancelled() || deadline.expired }) { scope in
            for (table, columns) in [
                ("chat", Set(["guid", "style"])),
                ("message", Set(["guid", "text", "attributedbody", "is_from_me"])),
                ("handle", Set(["id"])),
                ("chat_handle_join", Set(["chat_id", "handle_id"]))
            ] { try checkTable(table, columns: columns, scope: scope) }

            let chatRow: SQLiteReader.Row
            switch chat {
            case .rowid(let id):
                guard id > 0 else { throw Failure.invalidTarget }
                chatRow = try single(scope, "SELECT _rowid_ AS id, CASE WHEN typeof(guid)='text' THEN CAST(guid AS BLOB) END AS guid, style FROM chat WHERE _rowid_=CAST(?1 AS INTEGER) LIMIT 2", [String(id)])
            case .guid(let guid):
                guard safe(guid) else { throw Failure.invalidTarget }
                chatRow = try single(scope, "SELECT _rowid_ AS id, CASE WHEN typeof(guid)='text' THEN CAST(guid AS BLOB) END AS guid, style FROM chat WHERE CAST(guid AS BLOB)=CAST(?1 AS BLOB) LIMIT 2", [guid])
            }
            guard case .integer(let chatID)? = chatRow.values["id"], chatID > 0,
                  let chatGUID = try MessagesAttachmentSnapshot.exactText(chatRow.values["guid"]), safe(chatGUID) else { throw Failure.invalidTarget }

            let messageRow: SQLiteReader.Row
            switch message {
            case .rowid(let id):
                guard id > 0 else { throw Failure.invalidTarget }
                messageRow = try single(scope, "SELECT _rowid_ AS id, CASE WHEN typeof(guid)='text' THEN CAST(guid AS BLOB) END AS guid, typeof(text) AS text_type, CASE WHEN typeof(text)='text' THEN CAST(text AS BLOB) END AS text, attributedBody, is_from_me FROM message WHERE _rowid_=CAST(?1 AS INTEGER) LIMIT 2", [String(id)])
            case .guid(let guid):
                guard safe(guid) else { throw Failure.invalidTarget }
                messageRow = try single(scope, "SELECT _rowid_ AS id, CASE WHEN typeof(guid)='text' THEN CAST(guid AS BLOB) END AS guid, typeof(text) AS text_type, CASE WHEN typeof(text)='text' THEN CAST(text AS BLOB) END AS text, attributedBody, is_from_me FROM message WHERE CAST(guid AS BLOB)=CAST(?1 AS BLOB) LIMIT 2", [guid])
            }
            guard case .integer(let messageID)? = messageRow.values["id"], messageID > 0,
                  let messageGUID = try MessagesAttachmentSnapshot.exactText(messageRow.values["guid"]), safe(messageGUID),
                  case .integer(let fromMe)? = messageRow.values["is_from_me"], (0...1).contains(fromMe),
                  case .blob(let blob)? = messageRow.values["attributedBody"] else { throw Failure.invalidTarget }
            try checkpoint()
            let decoded = NativeMessageParts.decode(blob, requireExactText: true)
            try checkpoint()
            guard decoded.nativePartsAvailable,
                  let part = decoded.nativeParts?.first(where: { $0.index == partIndex }),
                  let attachmentGUID = part.attachmentGUID else { throw Failure.invalidTarget }
            let body: String?
            switch (messageRow.values["text_type"], messageRow.values["text"]) {
            case (.text("text"), .blob):
                guard let text = try MessagesAttachmentSnapshot.exactText(messageRow.values["text"]),
                      text.utf8.count <= 65_536 else { throw Failure.invalidTarget }
                body = text
            case (.text("null"), .null): body = decoded.text
            default: throw Failure.invalidTarget
            }
            if let sandboxPrefix {
                // Native direct-chat style, matching existing strict reply eligibility.
                guard case .integer(45)? = chatRow.values["style"],
                      body?.hasPrefix(sandboxPrefix) == true else { throw Failure.sandboxViolation }
            }

            var participants: [String] = []
            try scope.forEachRow("""
                SELECT j.chat_id, j.handle_id, h._rowid_ AS actual_handle, CASE WHEN typeof(h.id)='text' THEN CAST(h.id AS BLOB) END AS address
                FROM chat_handle_join AS j LEFT JOIN handle AS h ON h._rowid_=j.handle_id
                WHERE CAST(j.chat_id AS INTEGER)=CAST(?1 AS INTEGER) LIMIT 33
                """, [String(chatID)]) { row in
                guard case .integer(let joinedChat)? = row.values["chat_id"], joinedChat == chatID,
                      case .integer(let joinedHandle)? = row.values["handle_id"], joinedHandle > 0,
                      case .integer(let actualHandle)? = row.values["actual_handle"], actualHandle == joinedHandle,
                      let address = try MessagesAttachmentSnapshot.exactText(row.values["address"]), safe(address),
                      participants.count < 32,
                      !participants.contains(where: { $0.utf8.elementsEqual(address.utf8) }) else { throw Failure.invalidTarget }
                participants.append(address)
            }
            participants.sort { Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8)) }
            if sandboxPrefix != nil, participants.count != 1 { throw Failure.sandboxViolation }
            let items = try MessagesAttachmentTargetSnapshot.read(in: scope, chatRowid: chatID,
                chatGUID: chatGUID, messageRowid: messageID, messageGUID: messageGUID)
            guard items.contains(where: { $0.identity.guid == Data(attachmentGUID.utf8) }),
                  let membership = MessagesAttachmentMembership(items.map(\.identity)) else { throw Failure.invalidTarget }
            let request = try MessagesAttachmentRetrievalRequest(chatRowid: chatID, chatGUID: chatGUID,
                messageRowid: messageID, messageGUID: messageGUID, nativePartIndex: partIndex,
                nativePartGUID: nil, selectedAttachmentGUID: attachmentGUID, participantHandles: participants,
                isFromMe: fromMe == 1, membershipCount: membership.count, membershipSHA256: membership.sha256,
                sandboxPrefix: sandboxPrefix)
            try checkpoint()
            return Capture(request: request, items: items)
        }
    }

    private static func safe(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 &&
            !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    private static func single(_ scope: SQLiteReadTransaction, _ sql: String, _ bindings: [String]) throws -> SQLiteReader.Row {
        var found: SQLiteReader.Row?
        try scope.forEachRow(sql, bindings) { row in
            guard found == nil else { throw Failure.invalidTarget }
            found = row
        }
        guard let found else { throw Failure.targetNotFound }
        return found
    }

    private static func checkTable(_ table: String, columns required: Set<String>, scope: SQLiteReadTransaction) throws {
        var count = 0
        try scope.forEachRow("SELECT type, rootpage FROM sqlite_schema WHERE name=?1 COLLATE NOCASE", [table]) { row in
            guard case .text("table")? = row.values["type"],
                  case .integer(let root)? = row.values["rootpage"], root > 0 else { throw Failure.unsupportedSchema }
            count += 1
        }
        guard count == 1 else { throw Failure.unsupportedSchema }
        var columns = Set<String>()
        try scope.forEachTableColumn(table) { row in
            guard case .text(let name)? = row.values["column_name"] else { throw Failure.unsupportedSchema }
            columns.insert(name.lowercased())
        }
        guard required.isSubset(of: columns), !columns.contains("_rowid_") else { throw Failure.unsupportedSchema }
    }
}
