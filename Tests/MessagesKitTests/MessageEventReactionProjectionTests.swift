import AppleKit
import Foundation
import Testing
@testable import MessagesKit

struct MessageEventReactionProjectionTests {
    private typealias Source = MessageEventMessageSource

    private func projection(target: String?, type: Int64?, owner: Int64 = 0, handle: Int64 = 1,
                            emoji: Data = Data(), omitted: Source.Field? = nil) throws -> Data {
        let input: [(Source.Field, SQLiteReader.Row.Value)] = [
            (.associationType, type.map(SQLiteReader.Row.Value.integer) ?? .null),
            (.associationGUID, target.map { .blob(Data($0.utf8)) } ?? .null),
            (.associationEmoji, .blob(emoji)), (.isFromMe, .integer(owner)), (.handleID, .integer(handle)),
            (.dateEdited, .integer(-1)), (.dateRetracted, .null),
        ]
        var observations: [Source.Field: Source.Observation] = [:]
        for (field, value) in input where field != omitted {
            observations[field] = try Source.Observation(field, row: .init(values: [
                field.rawValue + "_t": .text(value == .null ? "null" : field.storage),
                field.rawValue + "_v": value]))
        }
        return try MessageEventReactionProjection.encode(observations)
    }

    @Test func versionOneBytesAndDatesAreStable() throws {
        let data = try projection(target: "p:2147483647/id-1", type: 3005, owner: 1)
        let expected = #"{"association":{"actor_kind":"self","native_type":3005,"supported":true,"target_message_guid":"id-1","target_part":2147483647,"target_status":"parsed_part"},"date_edited":"\/\/\/\/\/\/\/\/\/\/8=","date_retracted":null,"version":1}"#
        #expect(data == Data(expected.utf8))
        let dates = try MessageEventDelivery.retainedDates(in: data)
        #expect(dates.edited == "//////////8=" && dates.retracted == nil)
    }

    @Test(arguments: ["bp:bp:id", "p:1/p:2/id", "p:+2/id", "p:02/id", "p:-0/id", "p:2147483648/id",
                      "p:0/", "p:0/\u{FEFF}id", "\u{FEFF}id", "x\u{0000}y"])
    func malformedAddressRemainsUnresolved(_ address: String) throws {
        let data = try projection(target: address, type: 2001)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reaction = try #require(json["association"] as? [String: Any])
        #expect(reaction["target_status"] as? String == "unresolved")
        #expect(reaction["target_message_guid"] is NSNull && reaction["target_part"] is NSNull)
    }

    @Test func uncertainInformationStaysExplicit() throws {
        for (target, type, owner, handle, emoji, status, actor, supported) in [
            (nil as String?, 0 as Int64?, 0 as Int64, 0 as Int64, Data(), "not_associated", "unknown", false),
            (nil, nil, 2, 5, Data(), "unresolved", "unknown", false),
            ("bp:message", 2006, 0, 2, Data("👍".utf8), "bare_alias_uncertain", "other", true),
            ("message", 3006, 1, 0, Data("\u{feff}👍".utf8), "bare_alias_uncertain", "self", false),
            ("p:0/id", 2007, 0, -1, Data(), "parsed_part", "unknown", false),
        ] {
            let data = try projection(target: target, type: type, owner: owner, handle: handle, emoji: emoji)
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let reaction = try #require(json["association"] as? [String: Any])
            #expect(reaction["target_status"] as? String == status)
            #expect(reaction["actor_kind"] as? String == actor)
            #expect(reaction["supported"] as? Bool == supported)
            _ = try MessageEventDelivery.retainedDates(in: data)
        }
        #expect(throws: Source.Failure.invalidProjection) {
            try projection(target: nil, type: 0, omitted: .dateRetracted)
        }
    }
}
