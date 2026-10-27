import AppleKit
import Foundation

/// Binds the selected chat/message and its attachments in one caller-owned read
/// transaction. UI eligibility, participants and native-part checks are separate.
enum MessagesAttachmentTargetSnapshot {
    enum Failure: Error, Equatable { case invalidTarget, unsupportedSchema, targetDrift }

    static func read(in scope: SQLiteReadTransaction, chatRowid: Int64, chatGUID: String,
                     messageRowid: Int64, messageGUID: String) throws -> [MessagesAttachmentSnapshot.Item] {
        guard chatRowid > 0, messageRowid > 0,
              validGUID(chatGUID), validGUID(messageGUID) else { throw Failure.invalidTarget }
        for (table, required) in [("chat", Set(["guid"])), ("message", Set(["guid"])),
                                  ("chat_message_join", Set(["chat_id", "message_id"]))] {
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
        var owners = 0
        try scope.forEachRow("SELECT _rowid_ AS id FROM message WHERE CAST(guid AS BLOB)=CAST(?1 AS BLOB) LIMIT 2", [messageGUID]) { row in
            guard case .integer(let id)? = row.values["id"], id == messageRowid else { throw Failure.targetDrift }
            owners += 1
        }
        guard owners == 1 else { throw Failure.targetDrift }
        var memberships = 0
        try scope.forEachRow("SELECT chat_id, message_id FROM chat_message_join WHERE CAST(message_id AS INTEGER)=CAST(?1 AS INTEGER) LIMIT 2", [String(messageRowid)]) { row in
            guard case .integer(let chat)? = row.values["chat_id"], chat == chatRowid,
                  case .integer(let message)? = row.values["message_id"], message == messageRowid else { throw Failure.targetDrift }
            memberships += 1
        }
        guard memberships == 1 else { throw Failure.targetDrift }
        var matches = 0
        try scope.forEachRow("""
            SELECT CASE WHEN typeof(c.guid)='text' THEN CAST(c.guid AS BLOB) END AS chat_guid,
                   CASE WHEN typeof(m.guid)='text' THEN CAST(m.guid AS BLOB) END AS message_guid,
                   typeof(j.chat_id) AS chat_type, typeof(j.message_id) AS message_type
            FROM chat_message_join AS j
            JOIN chat AS c ON c._rowid_=j.chat_id
            JOIN message AS m ON m._rowid_=j.message_id
            WHERE c._rowid_=CAST(?1 AS INTEGER) AND m._rowid_=CAST(?2 AS INTEGER)
            LIMIT 2
            """, [String(chatRowid), String(messageRowid)]) { row in
            guard case .text("integer")? = row.values["chat_type"],
                  case .text("integer")? = row.values["message_type"],
                  let actualChat = try MessagesAttachmentSnapshot.exactText(row.values["chat_guid"]),
                  let actualMessage = try MessagesAttachmentSnapshot.exactText(row.values["message_guid"]),
                  actualChat.utf8.elementsEqual(chatGUID.utf8),
                  actualMessage.utf8.elementsEqual(messageGUID.utf8) else { throw Failure.targetDrift }
            matches += 1
        }
        guard matches == 1 else { throw Failure.targetDrift }
        return try MessagesAttachmentSnapshot.read(in: scope, messageRowid: messageRowid)
    }

    private static func validGUID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 &&
            !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
}
