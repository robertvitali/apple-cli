import Foundation

/// Exact limits reported by capture. Only these fixed names can reach an output record.
enum MessageEventCaptureLimit: String, Error, Encodable, CaseIterable {
    case rowLimit, byteLimit, valueLimit, journalCapacity, schemaCapacity
    case sourceScanSteps, memberships, captureEvents, captureEventBytes
    case attachmentAssociations, attachmentsPerMembership, attachmentGUIDBytes
}

/// Control records describe the journal without consuming an event sequence.
enum MessageEventWatchControl: Encodable {
    case started(MessageEventCursor)
    case resumed(after: MessageEventCursor, head: Int64, oldest: Int64?)
    case gap(MessageEventCursor)
    case restored(MessageEventCursor)
    case schemaChanged(MessageEventCursor)
    case capacityExceeded(MessageEventCursor, limit: MessageEventCaptureLimit? = nil)

    private enum CodingKeys: String, CodingKey {
        case type = "record_type"
        case stream = "stream_id"
        case cursor = "last_committed_cursor"
        case after = "resume_after_cursor"
        case head = "head_sequence"
        case oldest = "oldest_retained_sequence"
        case limit
        case limitations = "observation_limitations"
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        let type: String
        let committed: MessageEventCursor
        switch self {
        case .started(let cursor):
            guard cursor.sequence == 0 else { throw MessageEventCursorFailure.invalidCursor }
            committed = cursor
            type = "stream_started"
            try fields.encode("0", forKey: .head)
            try fields.encodeNil(forKey: .oldest)
            try fields.encode(Self.limitations, forKey: .limitations)
        case .resumed(let after, let head, let oldest):
            try after.validateReplay(stream: after.stream, filter: after.filter, head: head, oldestRetained: oldest)
            committed = try MessageEventCursor(stream: after.stream, filter: after.filter, sequence: head)
            type = "stream_resumed"
            try fields.encode(after.rawValue, forKey: .after)
            try fields.encode(String(head), forKey: .head)
            try fields.encode(oldest.map(String.init), forKey: .oldest)
            try fields.encode(Self.limitations, forKey: .limitations)
        case .gap(let cursor):
            committed = cursor
            type = "observation_gap"
        case .restored(let cursor):
            committed = cursor
            type = "observation_restored"
        case .schemaChanged(let cursor):
            committed = cursor
            type = "schema_changed"
        case .capacityExceeded(let cursor, let limit):
            committed = cursor
            type = "capacity_exceeded"
            try fields.encodeIfPresent(limit, forKey: .limit)
        }
        try fields.encode(type, forKey: .type)
        try fields.encode(committed.stream.rawValue, forKey: .stream)
        try fields.encode(committed.rawValue, forKey: .cursor)
    }

    private static let limitations = ["snapshot_polling", "intermediate_changes_may_be_unobserved"]
}
