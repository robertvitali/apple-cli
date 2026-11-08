import AppleKit
import CryptoKit
import Foundation

struct MessagesReactionTargetEvidence: Codable, Equatable, Sendable {
    let chatRowID: Int64
    let messageRowID: Int64
    let fromMe: Bool
    let explicitPart: Bool
    let attachmentGUIDBytes: Data?
    let bodyDigest: Data?
    let sandboxParticipant: Data?

    static func digest(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }
}

struct MessagesReactionWorkerTarget {
    let databasePath: String

    func validate(_ payload: MessagesReactionWorkerPayload, deadline: WorkerDeadline) throws {
        try checkMessagesAXDeadline(deadline)
        guard let evidence = payload.evidence, evidence.chatRowID > 0, evidence.messageRowID > 0,
              evidence.bodyDigest.map({ $0.count == 32 }) ?? true else {
            throw MessagesReactionAXError.targetDrift
        }
        let limits = SQLiteReadTransaction.Limits(
            timeout: min(5, Double(deadline.remainingNanoseconds) / 1_000_000_000),
            rows: 2048, bytes: 8 * 1024 * 1024, valueBytes: NativeMessageParts.Limits.default.maxBlobBytes)
        do {
            try SQLiteReader.withBoundedReadTransaction(path: databasePath, limits: limits,
                isCancelled: { Task.isCancelled || deadline.expired }) { scope in
                try validate(payload, evidence: evidence, in: scope)
            }
        } catch {
            try checkMessagesAXDeadline(deadline)
            throw MessagesReactionAXError.targetDrift
        }
        try checkMessagesAXDeadline(deadline)
    }

    private func validate(_ payload: MessagesReactionWorkerPayload, evidence: MessagesReactionTargetEvidence,
                          in scope: SQLiteReadTransaction) throws {
        let drift = MessagesReactionAXError.targetDrift
        _ = try MessagesAttachmentSnapshot.storedColumns(in: scope, table: "chat", required: ["guid"],
            optional: ["style"], unsupported: drift)
        _ = try MessagesAttachmentSnapshot.storedColumns(in: scope, table: "message",
            required: ["guid", "is_from_me", "text", "attributedbody"], unsupported: drift)
        _ = try MessagesAttachmentSnapshot.storedColumns(in: scope, table: "chat_message_join",
            required: ["chat_id", "message_id"], usesRowid: false, unsupported: drift)
        let chat = try MessagesNativeTargetLookup.one(scope, """
            SELECT _rowid_ AS id, CASE WHEN typeof(guid)='text' THEN CAST(guid AS BLOB) END AS guid_bytes
            FROM chat WHERE guid=?1 COLLATE BINARY LIMIT 2
            """, [payload.chatGUID])
        guard chat.values["id"] == .integer(evidence.chatRowID),
              chat.values["guid_bytes"] == .blob(Data(payload.chatGUID.utf8))
        else { throw drift }
        let aliases = ChatDB.reactionAliases(messageGUID: payload.messageGUID, parts: [payload.nativePartIndex])
        let owners = ChatDB.reactionAliasOwnerCandidates(aliases.all)
        let binds = owners.indices.map { "?\($0 + 1)" }.joined(separator: ", ")
        let row = try MessagesNativeTargetLookup.one(scope, """
            SELECT _rowid_ AS id, CASE WHEN typeof(guid)='text' THEN CAST(guid AS BLOB) END AS guid_bytes,
                   is_from_me, typeof(text) AS text_storage, CAST(text AS BLOB) AS text_bytes, attributedBody AS archive
            FROM message WHERE guid COLLATE BINARY IN (\(binds)) LIMIT 2
            """, owners)
        guard row.values["id"] == .integer(evidence.messageRowID),
              row.values["guid_bytes"] == .blob(Data(payload.messageGUID.utf8)),
              row.values["is_from_me"] == .integer(evidence.fromMe ? 1 : 0),
              case .blob(let archive)? = row.values["archive"] else { throw drift }
        let decoded = NativeMessageParts.decode(archive, requireExactText: true)
        guard let part = decoded.uniqueActionPart(requested: evidence.explicitPart ? payload.nativePartIndex : nil),
              part.index == payload.nativePartIndex,
              part.attachmentGUID.map({ Data($0.utf8) }) == evidence.attachmentGUIDBytes else { throw drift }
        let body: String?
        switch row.values["text_storage"] {
        case .text("text"):
            guard let text = try MessagesAttachmentSnapshot.exactText(row.values["text_bytes"]) else { throw drift }
            body = text
        case .text("null"): body = AttributedBody.decode(archive)
        default: throw drift
        }
        guard body.map({ MessagesReactionTargetEvidence.digest(Data($0.utf8)) }) == evidence.bodyDigest else { throw drift }
        // Match the public 10,000-edge limit. Check each storage class before
        // combining duplicate edges, since SQLite treats integer 3 and real 3.0 as equal.
        let membership = try MessagesNativeTargetLookup.one(scope, """
            SELECT count(*) AS edges, sum(
                typeof(chat_id)='integer' AND chat_id=CAST(?2 AS INTEGER)
                AND typeof(message_id)='integer' AND message_id=CAST(?1 AS INTEGER)
            ) AS exact_edges
            FROM (
                SELECT chat_id, message_id FROM chat_message_join
                WHERE \(MessagesNativeTargetLookup.membershipPredicate(column: "message_id", id: evidence.messageRowID))
                LIMIT 10001
            )
            """, [String(evidence.messageRowID), String(evidence.chatRowID)])
        guard case .integer(let edges)? = membership.values["edges"], (1...10_000).contains(edges),
              membership.values["exact_edges"] == .integer(edges) else { throw drift }
        if let expected = evidence.sandboxParticipant {
            _ = try MessagesAttachmentSnapshot.storedColumns(in: scope, table: "handle", required: ["id"], unsupported: drift)
            _ = try MessagesAttachmentSnapshot.storedColumns(in: scope, table: "chat_handle_join",
                required: ["chat_id", "handle_id"], usesRowid: false, unsupported: drift)
            let member = try MessagesNativeTargetLookup.one(scope, """
                SELECT j.chat_id, j.handle_id, h._rowid_ AS handle_owner, CASE WHEN typeof(h.id)='text' THEN CAST(h.id AS BLOB) END AS address, c.style
                FROM chat_handle_join j LEFT JOIN handle h ON h._rowid_=j.handle_id
                LEFT JOIN chat c ON c._rowid_=j.chat_id
                WHERE \(MessagesNativeTargetLookup.membershipPredicate(column: "j.chat_id", id: evidence.chatRowID)) LIMIT 2
                """, [String(evidence.chatRowID)])
            guard member.values["style"] == .integer(45),
                  member.values["chat_id"] == .integer(evidence.chatRowID),
                  case .integer(let id)? = member.values["handle_id"], id > 0,
                  member.values["handle_owner"] == .integer(id),
                  member.values["address"] == .blob(expected) else { throw drift }
        }
    }
}
