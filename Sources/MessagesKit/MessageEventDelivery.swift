import Foundation

/// An event and the checkpoint immediately after it. Delivery mode is outside the
/// persisted payload so replay can return the event with its original identity.
struct MessageEventDelivery: Encodable {
    enum Mode: String, Encodable { case live, replay }
    enum Failure: Error { case invalidRecord }

    private let record_type = "event"
    private let delivery_mode: Mode
    private let cursor: String
    private let event: Payload

    /// The journal reader supplies metadata from its pinned snapshot and the
    /// sequence from the event row. Stored JSON cannot choose its own checkpoint.
    struct Reader {
        private let stream: MessageEventStreamID
        private let source: MessageEventStreamID
        private let digest: MessageEventFilterDigest
        private let members: Set<MessageEventGUID>?

        init(metadata: PersistedEventMetadata) {
            stream = metadata.stream
            source = metadata.source
            digest = metadata.filter.digest
            members = metadata.filter.conversations.map(Set.init)
        }

        func decode(_ data: Data, sequence: Int64, mode: Mode) throws -> MessageEventDelivery {
            let payload = try storedPayload(data, sequence: sequence)
            let cursor = try MessageEventCursor(stream: stream, filter: digest, sequence: sequence)
            return MessageEventDelivery(delivery_mode: mode, cursor: cursor.rawValue, event: payload)
        }

        func validateStoredEvent(_ data: Data, sequence: Int64) throws {
            _ = try storedPayload(data, sequence: sequence)
        }

        private func storedPayload(_ data: Data, sequence: Int64) throws -> Payload {
            guard sequence > 0, MessageEventDelivery.hasExpectedShape(data, keys: 26),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data),
                  payload.stream_id == stream.rawValue, payload.source_epoch == source.rawValue,
                  payload.sequence == String(sequence), payload.event_id == stream.rawValue + ":" + payload.sequence
            else { throw Failure.invalidRecord }
            try validate(payload)
            return payload
        }

        /// Writes only the event. The delivery wrapper and cursor belong to each consumer.
        func encode(sequence: Int64, observedAt: String, captureMode: String,
                    conversation: MessageEventGUID, message: MessageEventGUID, rowID: Int64?,
                    changes: [String], availability: Data, projection: Data) throws -> Data {
            guard sequence > 0, availability.count == Payload.componentOrder.count else { throw Failure.invalidRecord }
            var statusByComponent: [String: String] = [:]
            for (component, byte) in zip(Payload.componentOrder, availability) {
                guard Int(byte) < Payload.statusOrder.count else { throw Failure.invalidRecord }
                statusByComponent[component] = Payload.statusOrder[Int(byte)]
            }
            let retained = try Projection.read(projection)
            let payload = Payload(event_id: stream.rawValue + ":" + String(sequence), stream_id: stream.rawValue,
                source_epoch: source.rawValue, sequence: String(sequence), observed_at: observedAt,
                capture_mode: captureMode, conversation_guid: conversation.rawValue, message_guid: message.rawValue,
                message_rowid: Nullable(rowID), change_categories: changes, availability: statusByComponent,
                association: retained.association)
            try validate(payload)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let bytes = try encoder.encode(payload)
            guard bytes.count <= 65_536 else { throw Failure.invalidRecord }
            return bytes
        }

        private func validate(_ payload: Payload) throws {
            guard let chat = try? MessageEventGUID(payload.conversation_guid),
                  members?.contains(chat) != false, payload.isValid else { throw Failure.invalidRecord }
        }
    }

    // A nonoptional wrapper encodes absent values as required JSON nulls.
    private struct Nullable<T: Codable>: Codable {
        let value: T?
        init(_ value: T?) { self.value = value }
        init(from decoder: any Decoder) throws {
            let field = try decoder.singleValueContainer()
            value = field.decodeNil() ? nil : try field.decode(T.self)
        }

        func encode(to encoder: any Encoder) throws {
            var field = encoder.singleValueContainer()
            if let value { try field.encode(value) } else { try field.encodeNil() }
        }
    }

    private struct Association: Codable {
        let target_status, actor_kind: String
        let target_message_guid: Nullable<String>
        let target_part, native_type: Nullable<Int64>
        let supported: Bool

        var isValid: Bool {
            guard ["self", "other", "unknown"].contains(actor_kind) else { return false }
            let type = native_type.value
            let standard = type.map { (2000...2005).contains($0) || (3000...3005).contains($0) } ?? false
            let custom = type == 2006 || type == 3006
            guard (!standard || supported) && (!supported || standard || custom) else { return false }
            let guid = target_message_guid.value
            if let guid {
                guard !guid.utf8.starts(with: "p:".utf8), !guid.utf8.starts(with: "bp:".utf8),
                      (try? MessageEventGUID(guid)) != nil else { return false }
            }
            let part = target_part.value
            switch target_status {
            case "not_associated": return type == 0 && guid == nil && part == nil
            case "unresolved": return guid == nil && part == nil
            case "bare_alias_uncertain": return guid != nil && part == nil
            case "parsed_part": return guid != nil && part.map { (0...Int64(Int32.max)).contains($0) } == true
            default: return false
            }
        }
    }

    private struct Payload: Codable {
        let event_id, stream_id, source_epoch, sequence, observed_at, capture_mode, conversation_guid, message_guid: String
        let message_rowid: Nullable<Int64>
        let change_categories: [String]
        let availability: [String: String]
        let association: Association

        static let categories = ["appeared", "content", "native_context", "edit", "reaction", "attachment",
                                 "delivery", "read", "undo_send", "membership_disappeared"]
        // The order of these two tables describes the eight stored availability bytes.
        static let componentOrder = ["content", "native_context", "edit", "undo_send", "reaction",
                                     "delivery", "read", "attachment"]
        static let statusOrder = ["available", "missing-schema", "null", "wrong-type", "invalid-value",
                                  "malformed", "limited"]
        static let components = Set(componentOrder)
        static let statuses = Set(statusOrder)

        var isValid: Bool {
            guard MessageEventDelivery.validObservationTimestamp(observed_at),
                  capture_mode == "poll" || capture_mode == "reconcile",
                  (try? MessageEventGUID(message_guid)) != nil,
                  !change_categories.isEmpty, change_categories.count <= Self.categories.count,
                  Self.categories.filter(change_categories.contains) == change_categories,
                  Set(availability.keys) == Self.components, availability.values.allSatisfy(Self.statuses.contains),
                  association.isValid else { return false }
            if change_categories.contains("membership_disappeared") {
                return change_categories.count == 1 && message_rowid.value == nil
            }
            guard let row = message_rowid.value, row > 0 else { return false }
            return !change_categories.contains("appeared") || change_categories.count == 1
        }
    }

    /// The baseline keeps the original association for a disappeared membership.
    /// Validate it with the same decoder before trusting its retained dates.
    static func retainedDates(in data: Data) throws -> (edited: String?, retracted: String?) {
        let projection = try Projection.read(data)
        return (projection.date_edited.value, projection.date_retracted.value)
    }

    private struct Projection: Decodable {
        let version: Int64
        let association: Association
        let date_edited, date_retracted: Nullable<String>

        static func read(_ data: Data) throws -> Self {
            guard hasExpectedShape(data, keys: 10),
                  let projection = try? JSONDecoder().decode(Self.self, from: data),
                  projection.version == 1, projection.association.isValid else { throw Failure.invalidRecord }
            return projection
        }
    }

    /// Each object has a fixed set of required fields. Count separators before
    /// decoding can collapse duplicate keys, including escaped spellings.
    private static func hasExpectedShape(_ data: Data, keys expected: Int) -> Bool {
        guard (1...65_536).contains(data.count), !data.contains(0), String(data: data, encoding: .utf8) != nil
        else { return false }
        var quoted = false, escaped = false, afterComma = false
        var integer = false, depth = 0, keys = 0
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            // JSONDecoder also accepts integral floating-point numbers.
            // The persisted format uses integer tokens for all numeric fields.
            if integer {
                switch byte {
                case 48...57: continue
                case 9, 10, 13, 32, 44, 93, 125: integer = false
                default: return false
                }
            }
            switch byte {
            case 9, 10, 13, 32: continue
            case 34: quoted = true
            case 45, 48...57: integer = true
            case 58: keys += 1
            case 91, 123: depth += 1
            case 93, 125:
                guard !afterComma else { return false }
                depth -= 1
            default: break
            }
            afterComma = byte == 44
            guard (0...2).contains(depth), keys <= expected else { return false }
        }
        return !quoted && depth == 0 && keys == expected
    }

    /// Validate the stored extended timestamp without reformatting its fractional seconds or zone.
    private static func validObservationTimestamp(_ value: String) -> Bool {
        guard (20...40).contains(value.utf8.count) else { return false }
        let text = Array(value.utf8)
        func digit(_ i: Int) -> Int? {
            guard i < text.count, (48...57).contains(text[i]) else { return nil }
            return Int(text[i]) - 48
        }
        func pair(_ i: Int) -> Int? {
            guard let a = digit(i), let b = digit(i + 1) else { return nil }
            return a * 10 + b
        }
        guard text[4] == 45, text[7] == 45, text[10] == 84, text[13] == 58, text[16] == 58,
              let century = pair(0), let year = pair(2), let month = pair(5), (1...12).contains(month),
              let day = pair(8), let hour = pair(11), hour < 24,
              let minute = pair(14), minute < 60, let second = pair(17), second < 60 else { return false }
        let leap = year == 0 ? century.isMultiple(of: 4) : year.isMultiple(of: 4)
        let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day > 0, day <= monthDays[month - 1] else { return false }
        var zone = 19
        if text[zone] == 46 {
            zone += 1
            let start = zone
            while digit(zone) != nil { zone += 1 }
            guard zone > start else { return false }
        }
        guard zone < text.count else { return false }
        if text[zone] == 90 { return zone + 1 == text.count }
        guard text[zone] == 43 || text[zone] == 45,
              let hours = pair(zone + 1), hours < 24 else { return false }
        // A numeric UTC offset may contain just hours or may include minutes.
        let remainder = text.count - zone
        if remainder == 3 { return true }
        let colon = remainder == 6 && text[zone + 3] == 58
        guard (remainder == 5 || colon), let minutes = pair(zone + (colon ? 4 : 3)) else { return false }
        return minutes < 60
    }
}
