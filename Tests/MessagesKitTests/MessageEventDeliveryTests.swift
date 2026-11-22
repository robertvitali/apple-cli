import CryptoKit
import Foundation
import Testing
@testable import MessagesKit

struct MessageEventDeliveryTests {
    private let stream = "01234567-89ab-cdef-0123-456789abcdef"
    private let source = "00000000-0000-0000-0000-000000000001"
    private let chat = "synthetic-é"

    private func reader() throws -> MessageEventDelivery.Reader {
        let filter = try MessageEventFilter(conversations: [chat])
        let meta = try PersistedEventMetadata(format: 1, initialized: 1, stream: Data(stream.utf8),
            source: Data(source.utf8), filterBytes: filter.canonicalBytes,
            filterDigest: Data(SHA256.hash(data: filter.canonicalBytes)), generation: 1, head: 1)
        return MessageEventDelivery.Reader(metadata: meta)
    }

    private var event: [String: Any] {
        let statuses = ["content", "native_context", "edit", "undo_send", "reaction", "delivery", "read", "attachment"]
        return ["event_id": stream + ":1", "stream_id": stream, "source_epoch": source, "sequence": "1",
                "observed_at": "2024-02-29T23:59:59.123456-04:30", "capture_mode": "reconcile",
                "conversation_guid": chat, "message_guid": "synthetic-🦋", "message_rowid": Int64.max,
                "change_categories": ["content", "attachment"], "availability": Dictionary(uniqueKeysWithValues:
                    statuses.map { ($0, $0 == "attachment" ? "missing-schema" : "available") }),
                "association": ["target_status": "unresolved", "actor_kind": "unknown", "supported": false,
                                "target_message_guid": NSNull(), "target_part": NSNull(), "native_type": NSNull()]]
    }

    private func pack(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    @Test func liveAndReplayPreserveTheSamePayloadAndCursor() throws {
        let reader = try reader()
        var events = [event]
        var removed = event
        removed["message_rowid"] = NSNull()
        removed["change_categories"] = ["membership_disappeared"]
        events.append(removed)
        var reaction = event
        reaction["association"] = ["target_status": "parsed_part", "actor_kind": "other", "supported": true,
                                   "target_message_guid": "another-guid", "target_part": Int32.max, "native_type": 2006]
        events.append(reaction)
        for item in events {
            let raw = try pack(item)
            let filter = try MessageEventFilter(conversations: [chat])
            for mode in [MessageEventDelivery.Mode.live, .replay] {
                let frame = try reader.decode(raw, sequence: 1, mode: mode)
                let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(frame)) as? [String: Any])
                #expect(Set(object.keys) == ["record_type", "delivery_mode", "cursor", "event"])
                #expect(object["record_type"] as? String == "event")
                #expect(object["delivery_mode"] as? String == mode.rawValue)
                #expect(object["cursor"] as? String == "v1." + stream + "." + filter.digest.rawValue + ".1")
                #expect(try pack(#require(object["event"] as? [String: Any])) == raw)
            }
        }
    }

    @Test func captureEncodesTheOriginalEventBytesForLiveAndReplay() throws {
        let codec = try reader()
        let statuses = Data([0, 1, 2, 3, 4, 5, 6, 0])
        let association: [String: Any] = ["target_status": "parsed_part", "actor_kind": "other",
            "target_message_guid": "archive/a🦋", "target_part": 3, "native_type": 2000, "supported": true]
        let projection = try pack(["version": 1, "association": association, "date_edited": "AAAAAAAAAAA=",
                                   "date_retracted": NSNull()])
        for disappeared in [false, true] {
            let changes = disappeared ? ["membership_disappeared"] : ["content", "attachment"]
            let bytes = try codec.encode(sequence: 1, observedAt: "2024-02-29T23:59:59.123456-04:30",
                captureMode: "reconcile", conversation: MessageEventGUID(chat),
                message: MessageEventGUID("synthetic-🦋"), rowID: disappeared ? nil : Int64.max,
                changes: changes, availability: statuses, projection: projection)
            var expected = event
            expected["association"] = association
            expected["availability"] = ["content": "available", "native_context": "missing-schema", "edit": "null",
                "undo_send": "wrong-type", "reaction": "invalid-value", "delivery": "malformed", "read": "limited",
                "attachment": "available"]
            if disappeared { expected["message_rowid"] = NSNull() }
            expected["change_categories"] = changes
            #expect(bytes == (try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys, .withoutEscapingSlashes])))
            for mode in [MessageEventDelivery.Mode.live, .replay] {
                _ = try codec.decode(bytes, sequence: 1, mode: mode)
            }
        }
    }

    @Test func captureRejectsInvalidInputsBeforeProducingARecord() throws {
        let codec = try reader()
        let association = try #require(event["association"])
        let valid = try pack(["version": 1, "association": association, "date_edited": NSNull(), "date_retracted": NSNull()])
        func encode(_ projection: Data, count: Int64 = 1, chatID: String? = nil,
                    statuses: Data = Data(repeating: 0, count: 8), changes: [String] = ["read"]) throws -> Data {
            try codec.encode(sequence: count, observedAt: "2024-02-29T23:59:59Z", captureMode: "poll",
                conversation: MessageEventGUID(chatID ?? chat), message: MessageEventGUID("message"), rowID: 3,
                changes: changes, availability: statuses, projection: projection)
        }
        #expect(throws: MessageEventDelivery.Failure.invalidRecord) { try encode(valid, count: 0) }
        #expect(throws: MessageEventDelivery.Failure.invalidRecord) { try encode(valid, chatID: chat.decomposedStringWithCanonicalMapping) }
        #expect(throws: MessageEventDelivery.Failure.invalidRecord) { try encode(valid, statuses: Data(repeating: 0, count: 7)) }
        #expect(throws: MessageEventDelivery.Failure.invalidRecord) { try encode(valid, statuses: Data(repeating: 7, count: 8)) }
        #expect(throws: MessageEventDelivery.Failure.invalidRecord) { try encode(valid, changes: ["read", "delivery"]) }
        #expect(throws: MessageEventDelivery.Failure.invalidRecord) { try encode(valid, changes: ["membership_disappeared"]) }
        let invalidProjections: [[String: Any]] = [["association": association],
            ["version": 2, "association": association, "date_edited": NSNull(), "date_retracted": NSNull()],
            ["version": 1, "association": association, "date_edited": 0, "date_retracted": NSNull()]]
        for projection in invalidProjections {
            let bytes = try pack(projection)
            #expect(throws: MessageEventDelivery.Failure.invalidRecord) { try encode(bytes) }
        }
    }

    @Test func mismatchedOrMalformedPersistedValuesAreRefused() throws {
        let reader = try reader()
        let fields: [(String, Any)] = [
            ("stream_id", source), ("source_epoch", stream), ("event_id", stream + ":01"), ("sequence", "01"),
            ("observed_at", "2023-02-29T00:00:00Z"), ("capture_mode", "live"),
            ("conversation_guid", "\u{FEFF}" + chat), ("stream_id", "\u{FEFF}" + stream),
            ("conversation_guid", chat.decomposedStringWithCanonicalMapping), ("message_guid", "\u{FEFF}id"),
            ("message_rowid", true), ("message_rowid", 0), ("message_rowid", NSNull()),
            ("change_categories", ["read", "content"]), ("change_categories", ["appeared", "read"]),
            ("change_categories", ["membership_disappeared"]), ("availability", [:]), ("extra", "private")]
        for (key, value) in fields {
            var item = event
            item[key] = value
            let raw = try pack(item)
            #expect(throws: MessageEventDelivery.Failure.invalidRecord) { try reader.decode(raw, sequence: 1, mode: .live) }
        }
        for key in event.keys {
            var item = event
            item.removeValue(forKey: key)
            let raw = try pack(item)
            #expect(throws: MessageEventDelivery.Failure.invalidRecord) { try reader.decode(raw, sequence: 1, mode: .replay) }
        }
        let raw = try pack(event)
        for wrong: Int64 in [0, -1, 2, .max] {
            #expect(throws: MessageEventDelivery.Failure.invalidRecord) { try reader.decode(raw, sequence: wrong, mode: .replay) }
        }
    }

    @Test func retainedAssociationUsesExactStringsAndRequiresBothDates() throws {
        let association = try #require(event["association"] as? [String: Any])
        var projection: [String: Any] = ["version": 1, "association": association,
                                         "date_edited": "AAAAAAAAAAA=", "date_retracted": NSNull()]
        let dates = try MessageEventDelivery.retainedDates(in: pack(projection))
        #expect(dates.edited == "AAAAAAAAAAA=" && dates.retracted == nil)
        var malformed = association
        malformed["actor_kind"] = "\u{FEFF}unknown"
        projection["association"] = malformed
        let altered = try pack(projection)
        #expect(throws: MessageEventDelivery.Failure.invalidRecord) { try MessageEventDelivery.retainedDates(in: altered) }
        projection["association"] = association
        projection["extra"] = projection.removeValue(forKey: "date_retracted")
        let missing = try pack(projection)
        #expect(throws: MessageEventDelivery.Failure.invalidRecord) { try MessageEventDelivery.retainedDates(in: missing) }
    }

    @Test func ambiguousOrNoncanonicalJSONIsRefused() throws {
        let reader = try reader()
        let text = String(decoding: try pack(event), as: UTF8.self)
        let duplicate = #"{"seque\u006ece":"1","# + text.dropFirst()
        let fractional = text.replacingOccurrences(of: String(Int64.max), with: "1.0")
        let exponential = text.replacingOccurrences(of: String(Int64.max), with: "1e0")
        let overflow = text.replacingOccurrences(of: String(Int64.max), with: "9223372036854775808")
        for raw in [Data(duplicate.utf8), Data((text.dropLast() + ",}").utf8),
                    Data(fractional.utf8), Data(exponential.utf8), Data(overflow.utf8),
                    try #require(text.data(using: .utf16LittleEndian)), Data(repeating: 32, count: 65_537)] {
            #expect(throws: MessageEventDelivery.Failure.invalidRecord) { try reader.decode(raw, sequence: 1, mode: .replay) }
        }
    }
}
