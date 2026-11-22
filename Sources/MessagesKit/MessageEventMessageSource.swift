import AppleKit
import CryptoKit
import Foundation

/// Message rows used by initial capture, later polls and journal upgrades.
enum MessageEventMessageSource {
    enum Failure: Error { case invalidMembership, invalidProjection }

    // The v1 component hashes consume fields in this order.
    enum Field: String, CaseIterable {
        case text, attributedBody, threadOriginatorGUID = "thread_originator_guid"
        case threadOriginatorPart = "thread_originator_part", summary = "message_summary_info"
        case dateEdited = "date_edited", dateRetracted = "date_retracted"
        case associationType = "associated_message_type", associationGUID = "associated_message_guid"
        case associationEmoji = "associated_message_emoji", isFromMe = "is_from_me", handleID = "handle_id"
        case date, error, isDelivered = "is_delivered", dateDelivered = "date_delivered"
        case isRead = "is_read", dateRead = "date_read"

        var storage: String {
            switch self {
            case .text, .threadOriginatorGUID, .threadOriginatorPart, .associationGUID, .associationEmoji: "text"
            case .attributedBody, .summary: "blob"
            default: "integer"
            }
        }

        var isBoolean: Bool { self == .isFromMe || self == .isDelivered || self == .isRead }
    }

    struct Membership {
        let chatRowID, messageRowID: Int64
        let chatGUID, messageGUID: Data

        init(_ row: SQLiteReader.Row, pass: MessageEventConversationLookup.Pass) throws {
            guard case .integer(let chat)? = row.values["c"], chat > 0, row.values["cid"] == .integer(chat),
                  case .integer(let message)? = row.values["m"], message > 0, row.values["mid"] == .integer(message),
                  case .blob(let cg)? = row.values["cg"], case .blob(let mg)? = row.values["mg"],
                  (try? MessageEventGUID(storedBytes: cg)) != nil, (try? MessageEventGUID(storedBytes: mg)) != nil,
                  pass.id == nil ? pass.guid == nil : (pass.id == chat && pass.guid == cg)
            else { throw Failure.invalidMembership }
            chatRowID = chat
            messageRowID = message
            chatGUID = cg
            messageGUID = mg
        }
    }

    struct Observation {
        enum Status: String {
            case available, null, missingSchema = "missing-schema", wrongType = "wrong-type"
            case invalidValue = "invalid-value", malformed
        }

        let status: Status
        let bytes: Data

        init(_ field: Field, row: SQLiteReader.Row) throws {
            guard case .text(let kind)? = row.values[field.rawValue + "_t"],
                  let value = row.values[field.rawValue + "_v"] else { throw Failure.invalidProjection }
            if kind != field.storage {
                guard value == .null else { throw Failure.invalidProjection }
                switch kind {
                case "null": status = .null
                case "missing-schema": status = .missingSchema
                case "text", "integer", "real", "blob": status = .wrongType
                default: throw Failure.invalidProjection
                }
                bytes = Data()
                return
            }
            switch (kind, value) {
            case ("integer", .integer(let number)):
                status = field.isBoolean && number != 0 && number != 1 ? .invalidValue : .available
                bytes = withUnsafeBytes(of: number.bigEndian) { Data($0) }
            case ("text", .blob(let data)), ("blob", .blob(let data)):
                if kind == "text" && !data.isValidEventSourceUTF8 {
                    status = .malformed
                    bytes = Data(SHA256.hash(data: data))
                } else {
                    status = .available
                    bytes = data
                }
            default: throw Failure.invalidProjection
            }
        }
    }

    static func query(in db: SQLiteReadTransaction, filtered: Bool, summaryOnly: Bool = false) throws -> String {
        let invalid = MessageEventSourceSchema.Failure.invalidSourceSchema
        let columns = try MessagesAttachmentSnapshot.storedColumns(in: db, table: "message", required: ["guid"],
            optional: Set(Field.allCases.map { $0.rawValue.lowercased() }), unsupported: invalid)
        _ = try MessagesAttachmentSnapshot.storedColumns(in: db, table: "chat", required: ["guid"], unsupported: invalid)
        _ = try MessagesAttachmentSnapshot.storedColumns(in: db, table: "chat_message_join",
            required: ["chat_id", "message_id"], usesRowid: false, unsupported: invalid)
        var select = ["j.chat_id AS c", "j.message_id AS m", "c._rowid_ AS cid", "m._rowid_ AS mid"]
        for (column, alias) in [("c.guid", "cg"), ("m.guid", "mg")] {
            select.append("CASE WHEN typeof(\(column))='text' AND length(CAST(\(column) AS BLOB)) BETWEEN 1 AND 1024 THEN CAST(\(column) AS BLOB) END AS \(alias)")
        }
        for field in summaryOnly ? [.summary] : Field.allCases {
            let name = field.rawValue
            guard columns.contains(name.lowercased()) else {
                select += ["'missing-schema' AS \(name)_t", "NULL AS \(name)_v"]
                continue
            }
            let column = "m." + name
            let value = field.storage == "text" ? "CAST(\(column) AS BLOB)" : column
            select += ["typeof(\(column)) AS \(name)_t",
                       "CASE WHEN typeof(\(column))='\(field.storage)' THEN \(value) END AS \(name)_v"]
        }
        let membership = " FROM chat_message_join j LEFT JOIN chat c ON c._rowid_=j.chat_id LEFT JOIN message m ON m._rowid_=j.message_id"
        let predicate = filtered ? " WHERE j.chat_id=CAST(?1 AS INTEGER)" : ""
        return "SELECT " + select.joined(separator: ",") + membership + predicate + " ORDER BY j.chat_id,j.message_id"
    }
}

extension Data {
    var isValidEventSourceUTF8: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            do {
                _ = try UTF8Span(validating: span)
                return true
            } catch {
                return false
            }
        }
        #endif
        return String(data: self, encoding: .utf8) != nil
    }
}
