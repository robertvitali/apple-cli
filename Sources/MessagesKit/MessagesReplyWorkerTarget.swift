import AppleKit
import Foundation

/// Recheck the exact database address at each native handoff. AX independently
/// checks retained UI objects; a database match does not identify an AX object.
struct MessagesReplyWorkerTarget {
    let databasePath: String

    func validate(_ request: MessagesReplySendRequest, deadline: WorkerDeadline) throws {
        try checkMessagesAXDeadline(deadline)
        let limits = SQLiteReadTransaction.Limits(
            timeout: min(5, Double(deadline.remainingNanoseconds) / 1_000_000_000),
            rows: 2048, bytes: 8 * 1024 * 1024, valueBytes: NativeMessageParts.Limits.default.maxBlobBytes)
        do {
            try SQLiteReader.withBoundedReadTransaction(path: databasePath, limits: limits,
                isCancelled: { Task.isCancelled || deadline.expired }) { scope in
                try validate(request, in: scope)
            }
        } catch {
            try checkMessagesAXDeadline(deadline)
            throw MessagesReplyComposerAXError.targetDrift
        }
        try checkMessagesAXDeadline(deadline)
    }

    private func validate(_ request: MessagesReplySendRequest, in scope: SQLiteReadTransaction) throws {
        for (name, columns, usesRowid): (String, Set<String>, Bool) in [
            ("chat", ["guid", "style"], true), ("handle", ["id"], true),
            ("chat_message_join", ["chat_id", "message_id"], false),
            ("chat_handle_join", ["chat_id", "handle_id"], false),
            ("message", ["guid", "text", "attributedbody", "is_from_me",
                         "thread_originator_guid", "thread_originator_part"], true)
        ] {
            _ = try MessagesAttachmentSnapshot.storedColumns(in: scope, table: name, required: columns,
                usesRowid: usesRowid, unsupported: MessagesReplyComposerAXError.targetDrift)
        }
        let chat = try one(scope, """
            SELECT _rowid_ AS id, style, CASE WHEN typeof(guid)='text' THEN CAST(guid AS BLOB) END AS guid_bytes
            FROM chat WHERE guid=?1 COLLATE BINARY LIMIT 2
            """, request.chatGUID)
        let chatID = request.expectedChatRowID
        guard chat.values["id"] == .integer(chatID), chat.values["style"] == .integer(45),
              chat.values["guid_bytes"] == .blob(Data(request.chatGUID.utf8)) else {
            throw MessagesReplyComposerAXError.targetDrift
        }

        let member = try one(scope, """
            SELECT j.chat_id, j.handle_id, h._rowid_ AS owner, typeof(h.id) AS storage, CAST(h.id AS BLOB) AS address
            FROM chat_handle_join j LEFT JOIN handle h ON h._rowid_=j.handle_id
            WHERE \(MessagesNativeTargetLookup.membershipPredicate(column: "j.chat_id", id: chatID)) LIMIT 2
            """, String(chatID))
        guard member.values["chat_id"] == .integer(chatID), case .integer(let id)? = member.values["handle_id"],
              id > 0, member.values["owner"] == .integer(id), member.values["storage"] == .text("text"),
              let address = try MessagesAttachmentSnapshot.exactText(member.values["address"]),
              request.expectedParticipantHandles.count == 1,
              address.utf8.elementsEqual(request.expectedParticipantHandles[0].utf8) else { throw MessagesReplyComposerAXError.targetDrift }

        let selected = try message(in: scope, guid: request.messageGUID, chatID: chatID)
        guard selected.id == request.expectedMessageRowID, selected.fromMe == request.expectedIsFromMe,
              let part = selected.decoded.uniqueActionPart(requested: request.explicitPart ? request.nativePartIndex : nil),
              part.index == request.nativePartIndex,
              part.attachmentGUID.map({ Data($0.utf8) }) == request.expectedAttachmentGUID.map({ Data($0.utf8) }),
              let body = selected.body, body.utf8.count == request.expectedBodyUTF8Length,
              try AppleAutomationJournal.targetDigest(forOpaqueIdentifier: body).value == request.expectedBodySHA256
        else { throw MessagesReplyComposerAXError.targetDrift }

        let origin = selected.origin
        if origin.available && origin.reason == "no-linkage" {
            guard request.expectedThreadRelationshipSHA256 == nil else { throw MessagesReplyComposerAXError.targetDrift }
            return
        }
        guard origin.available, origin.reason == "available", let guid = origin.message_guid,
              !guid.utf8.elementsEqual(request.messageGUID.utf8), let index = origin.native_part,
              selected.decoded.uniqueActionPart(requested: nil) != nil else { throw MessagesReplyComposerAXError.targetDrift }
        let root = try message(in: scope, guid: guid, chatID: chatID)
        guard root.id != selected.id, root.linkageIsNull,
              let rootPart = root.decoded.uniqueActionPart(requested: nil), rootPart.index == index
        else { throw MessagesReplyComposerAXError.targetDrift }
        let target = ChatDB.ExactReplyTarget(chat_rowid: chatID, chat_guid: request.chatGUID, message_rowid: selected.id,
            message_guid: request.messageGUID, native_part: part.index, part_guid: part.attachmentGUID,
            participant_handle: address, is_from_me: selected.fromMe, thread_root: .init(message_rowid: root.id,
                message_guid: guid, native_part: index, part_guid: rootPart.attachmentGUID, is_from_me: root.fromMe),
            thread_originator: origin)
        guard try replyRelationshipDigest(target) == request.expectedThreadRelationshipSHA256 else { throw MessagesReplyComposerAXError.targetDrift }
    }

    private struct Message {
        let id: Int64
        let fromMe: Bool
        let body: String?
        let decoded: NativeMessageParts.Decoded
        let origin: ChatDB.ExactThreadOriginator
        let linkageIsNull: Bool
    }

    private func message(in scope: SQLiteReadTransaction, guid: String, chatID: Int64) throws -> Message {
        let row = try one(scope, """
            SELECT _rowid_ AS id, CASE WHEN typeof(guid)='text' THEN CAST(guid AS BLOB) END AS message_guid_bytes,
                   is_from_me, typeof(text) AS body_type, CAST(text AS BLOB) AS body_bytes,
                   attributedBody AS archive, typeof(thread_originator_guid) AS guid_type,
                   CAST(thread_originator_guid AS BLOB) AS guid_bytes, typeof(thread_originator_part) AS part_type,
                   CAST(thread_originator_part AS BLOB) AS part_bytes
            FROM message WHERE guid=?1 COLLATE BINARY LIMIT 2
            """, guid)
        guard case .integer(let id)? = row.values["id"], id > 0,
              row.values["message_guid_bytes"] == .blob(Data(guid.utf8)),
              case .integer(let owner)? = row.values["is_from_me"], owner == 0 || owner == 1,
              case .blob(let archive)? = row.values["archive"] else { throw MessagesReplyComposerAXError.targetDrift }
        let membership = try one(scope, """
            SELECT chat_id, message_id FROM chat_message_join
            WHERE \(MessagesNativeTargetLookup.membershipPredicate(column: "message_id", id: id)) LIMIT 2
            """, String(id))
        guard membership.values["chat_id"] == .integer(chatID), membership.values["message_id"] == .integer(id) else {
            throw MessagesReplyComposerAXError.targetDrift
        }
        func text(_ name: String) throws -> String? {
            if row.values[name + "_type"] == .text("null") { return nil }
            guard row.values[name + "_type"] == .text("text"),
                  let value = try MessagesAttachmentSnapshot.exactText(row.values[name + "_bytes"]) else {
                throw MessagesReplyComposerAXError.targetDrift
            }
            return value
        }
        let originGUID = try text("guid"), originPart = try text("part")
        let origin = ChatDB.exactThreadOriginator(.init(values: [
            "thread_originator_guid": originGUID.map(SQLiteReader.Row.Value.text) ?? .null,
            "thread_originator_part": originPart.map(SQLiteReader.Row.Value.text) ?? .null
        ]), columnsAvailable: true)
        let decoded = NativeMessageParts.decode(archive, requireExactText: true)
        return Message(id: id, fromMe: owner == 1, body: try text("body") ?? AttributedBody.decode(archive), decoded: decoded,
                       origin: origin, linkageIsNull: originGUID == nil && originPart == nil)
    }

    private func one(_ scope: SQLiteReadTransaction, _ sql: String, _ bind: String) throws -> SQLiteReader.Row {
        try MessagesNativeTargetLookup.one(scope, sql, [bind])
    }
}
