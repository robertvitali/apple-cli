import Foundation
import Testing
@testable import MessagesKit

@Suite struct NativeEditContextTests {
    private func plist(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private func body(_ text: String) -> Data {
        NSArchiver.archivedData(withRootObject: NSAttributedString(string: text))
    }

    private func decode(_ value: Any) throws -> ChatDB.ExactNativeEditContext.Summary {
        var budget = NativeEditContextDecoder.Budget()
        return try NativeEditContextDecoder.decode(try plist(value), budget: &budget)
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    @Test func unavailableEnvelopeAndMissingOrEmptyContainersRemainDistinct() throws {
        for status in ["missing-schema", "null", "wrong-type", "empty", "too-large", "unsupported-format",
                       "corrupt", "resource-limit", "request-limit", "changed", "identity-unavailable",
                       "read-error", "not-requested"] {
            let object = try json(ChatDB.ExactNativeEditContext.Summary.unavailable(status))
            #expect(Set(object.keys) == ["status", "edited_parts", "retracted_parts", "original_parts", "edit_history"])
            for key in ["edited_parts", "retracted_parts", "original_parts", "edit_history"] {
                let container = try #require(object[key] as? [String: Any])
                #expect(Set(container.keys) == ["status", "reason", "entries"])
                #expect(container["status"] as? String == "unavailable")
                #expect(container["reason"] as? String == status)
                #expect(container["entries"] is NSNull)
            }
        }
        let missing = try decode([String: Any]())
        #expect(missing.status == "available")
        #expect(missing.edited_parts.status == "missing-key")
        #expect(missing.edited_parts.entries == nil)
        let empty = try decode(["ep": [], "rp": [], "otr": [:], "ec": [:]] as [String: Any])
        #expect(empty.edited_parts.status == "available")
        #expect(empty.edited_parts.entries == [])
        #expect(empty.retracted_parts.entries == [])
        #expect(empty.original_parts.entries == [])
        #expect(empty.edit_history.entries == [])
        #expect(try decode(["ep": false, "rp": "bad", "otr": [], "ec": 1] as [String: Any]).edited_parts.status == "wrong-type")
        #expect(try decode([1, 2]).status == "wrong-type")
    }

    @Test func originalPartIndexesAreStrictOrderedAndNeverDeduplicated() throws {
        let summary = try decode(["ep": [0, 2, 2, -1, Int64(Int32.max) + 1, true, 1.5, "3"], "rp": [2]] as [String: Any])
        let entries = try #require(summary.edited_parts.entries)
        #expect(summary.edited_parts.status == "partial")
        #expect(entries.map(\.position) == Array(0..<8))
        #expect(entries.map(\.status) == ["available", "available", "duplicate", "invalid-index", "invalid-index", "wrong-type", "wrong-type", "wrong-type"])
        #expect(entries.map(\.raw_integer) == [0, 2, 2, -1, Int64(Int32.max) + 1, nil, nil, nil])
        #expect(entries.map(\.original_part_index) == [0, 2, 2, nil, nil, nil, nil, nil])
        #expect(summary.retracted_parts.entries?.first?.original_part_index == 2)
    }

    @Test func originalCoordinatesPreserveMalformedEntriesAndRawUnits() throws {
        let summary = try decode(["otr": [
            "2": ["lo": 3, "le": 5], "10": ["lo": -1, "le": 2], "00": ["lo": 4, "le": 1],
            "3": ["lo": Int64.max, "le": 1], "4": ["lo": 1], "5": true,
            "6": ["lo": true, "le": 2], "+1": ["lo": 1, "le": 2]
        ]] as [String: Any])
        let entries = try #require(summary.original_parts.entries)
        #expect(summary.original_parts.status == "partial")
        #expect(entries.map(\.source_key) == ["+1", "00", "10", "2", "3", "4", "5", "6"])
        #expect(entries.map(\.status) == ["invalid-part-key", "invalid-part-key", "invalid-range", "available", "invalid-range", "missing-field", "wrong-type", "wrong-type"])
        #expect(entries[0].location_raw == 1)
        #expect(entries[1].original_part_index == nil)
        #expect(entries[3].location_raw == 3)
        #expect(entries[3].length_raw == 5)
        #expect(entries[6].location_raw == nil)
        #expect(entries[7].length_raw == 2)
    }

    @Test func historyPreservesGroupsEventsAndMalformedSiblings() throws {
        let event: [String: Any] = ["d": 0, "t": body("Synthetic history")]
        let summary = try decode(["ec": ["2": [event, false, event], "01": [event], "3": "bad"]] as [String: Any])
        let groups = try #require(summary.edit_history.entries)
        #expect(summary.edit_history.status == "partial")
        #expect(groups.map(\.source_key) == ["01", "2", "3"])
        #expect(groups.map(\.status) == ["invalid-part-key", "partial", "wrong-type"])
        #expect(groups[0].original_part_index == nil)
        #expect(groups[0].events?.count == 1)
        let events = try #require(groups[1].events)
        #expect(events.map(\.position) == [0, 1, 2])
        #expect(events.map(\.status) == ["available", "invalid-event", "available"])
        #expect(events[0].body.text == events[2].body.text)
        #expect(events[1].timestamp.status == "unavailable")
        #expect(events[1].body.reason == "invalid-event")
        #expect(try json(events[1].timestamp)["raw"] is NSNull)
        #expect(Set(try json(events[1].body).keys) == ["status", "reason", "text"])
        #expect(groups[2].events == nil)
    }

    @Test func bodyAndTimestampAvailabilityAreIndependent() throws {
        let summary = try decode(["ec": ["0": [
            ["d": -1, "t": body("")], ["d": false, "t": body("Synthetic")], ["d": 1, "t": Data()],
            ["d": 2, "t": true], ["t": body("Synthetic")], ["d": 3]
        ]]] as [String: Any])
        let events = try #require(summary.edit_history.entries?.first?.events)
        #expect(events[0].status == "available")
        #expect(events[0].body.text == "")
        #expect(events[0].timestamp.date == "2000-12-31T23:59:59Z")
        #expect(events[1].timestamp.status == "wrong-type")
        #expect(events[1].body.status == "available")
        #expect(events[2].timestamp.status == "available")
        #expect(events[2].body.status == "decode-unavailable")
        #expect(events[2].body.text == nil)
        #expect(events[3].body.status == "wrong-type")
        #expect(events[4].timestamp.status == "missing-key")
        #expect(events[5].body.status == "missing-key")
    }

    @Test func dataURLGrammarIsStrictAndNeverFetchesURLs() throws {
        let data = body("Synthetic 🐝")
        let prefix = "data:application/octet-stream;base64,"
        let values: [Any] = [data, prefix + data.base64EncodedString(), "https://example.com/body", "DATA:application/octet-stream;base64,AA==",
                             "data:text/plain;base64,AA==", prefix + "AA=", prefix + "AB==", prefix + "AAB=", prefix + "AA==\n", prefix + "", prefix + "AA=="]
        let summary = try decode(["ec": ["0": values.map { ["d": 0, "t": $0] }]])
        let events = try #require(summary.edit_history.entries?.first?.events)
        #expect(events.map { $0.body.status } == ["available", "available", "unsupported-encoding", "unsupported-encoding", "unsupported-encoding", "invalid-base64", "invalid-base64", "invalid-base64", "invalid-base64", "decode-unavailable", "decode-unavailable"])
        #expect(events[0].body.text == "Synthetic 🐝")
        #expect(events[1].body.text == events[0].body.text)
    }

    @Test func dataURLRejectsCanonicallyEquivalentPrefixSpelling() throws {
        let encoded = body("Synthetic regression").base64EncodedString()
        let prefix = "data:application/octet-stream;base64,"
        let equivalent = "data:application/octet-stream\u{037E}base64,"
        // Swift strings compare canonically; this wire format requires ASCII bytes.
        #expect(equivalent == prefix)
        #expect(!equivalent.utf8.elementsEqual(prefix.utf8))
        let summary = try decode(["ec": ["0": [["d": 0, "t": equivalent + encoded]]]])
        let event = try #require(summary.edit_history.entries?.first?.events?.first)
        #expect(event.body.status == "unsupported-encoding")
        #expect(event.body.text == nil)
        #expect(event.timestamp.status == "available")
    }

    @Test(arguments: [Int64(-63_113_904_000), -1, 0, 1, 9_999_999_999, 10_000_000_000, 252_423_993_599])
    func historyTimesAlwaysUseSignedSeconds(_ raw: Int64) throws {
        let stamp = NativeEditContextDecoder.timestamp(.integer(raw), timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(stamp.status == "available")
        #expect(stamp.raw == raw)
        #expect(stamp.normalized_seconds == raw)
        #expect(stamp.normalized_nanoseconds == 0)
        if raw == 0 { #expect(stamp.date == "2001-01-01T00:00:00Z") }
        if raw == -63_113_904_000 { #expect(stamp.date == "0001-01-01T00:00:00Z") }
        if raw == 252_423_993_599 { #expect(stamp.date == "9999-12-31T23:59:59Z") }
        if raw <= 0 { #expect(NativeMessageStatusDecoder.timestamp(raw: raw).status != "available") }
        if raw == 10_000_000_000 { #expect(NativeMessageStatusDecoder.timestamp(raw: raw).normalized_seconds == 10) }
    }

    @Test func invalidTimestampBoundsAndFormattingRetainRaw() throws {
        for raw in [Int64.min, -63_113_904_001, 252_423_993_600, Int64.max] {
            let stamp = NativeEditContextDecoder.timestamp(.integer(raw))
            #expect(stamp.status == "invalid-timestamp")
            #expect(stamp.raw == raw)
            #expect(stamp.date == nil)
        }
        let rollover = NativeEditContextDecoder.timestamp(.integer(252_423_993_599), timeZone: TimeZone(secondsFromGMT: 3600)!)
        #expect(rollover.status == "invalid-timestamp")
        let earlyRollover = NativeEditContextDecoder.timestamp(.integer(-63_113_904_000), timeZone: TimeZone(secondsFromGMT: -3600)!)
        #expect(earlyRollover.status == "invalid-timestamp")
        let failed = NativeEditContextDecoder.timestamp(.integer(1), format: { _, _ in ("bad", "bad") })
        #expect(failed.status == "invalid-timestamp")
        #expect(failed.raw == 1)
        #expect(NativeEditContextDecoder.timestamp(.null).status == "null")
        #expect(NativeEditContextDecoder.timestamp(.real(1)).status == "wrong-type")
    }

    @Test func eventAndTextBudgetsDiscardWholeSummaryWithoutRefund() throws {
        let event: [String: Any] = ["d": 0, "t": body("Synthetic")]
        let data = try plist(["ec": ["0": [event, event]]])
        var budget = NativeEditContextDecoder.Budget()
        budget.remainingEvents = 1
        let limited = try NativeEditContextDecoder.decode(data, budget: &budget)
        #expect(limited.status == "request-limit")
        #expect(limited.edit_history.entries == nil)
        #expect(budget.remainingEvents == 0)
        budget = .init()
        budget.remainingTextUTF16 = 10
        let textLimited = try NativeEditContextDecoder.decode(data, budget: &budget)
        #expect(textLimited.status == "request-limit")
        #expect(textLimited.edit_history.entries == nil)
        #expect(budget.remainingTextUTF16 == 1)
        #expect(budget.plist.remainingBytes < 4_194_304)
        let tooMany = try plist(["ec": ["0": Array(repeating: event, count: 257)]])
        budget = .init()
        #expect(try NativeEditContextDecoder.decode(tooMany, budget: &budget).status == "resource-limit")
    }

    @Test func cancellationPropagatesAndMalformedBlobHasNoPartialOutput() throws {
        var budget = NativeEditContextDecoder.Budget()
        #expect(throws: CancellationError.self) {
            try NativeEditContextDecoder.decode(try plist(["ep": [0]]), budget: &budget,
                                               checkCancellation: { throw CancellationError() })
        }
        #expect(try NativeEditContextDecoder.decode(Data("xml".utf8), budget: &budget).status == "unsupported-format")
        #expect(try NativeEditContextDecoder.decode(Data("bplist00".utf8), budget: &budget).status == "corrupt")
    }

    @Test func nullEventFieldsAndUnavailableEncodingRetainEveryKey() throws {
        // Synthetic bplist {ec: {"0": [{d: null, t: null}]}}. Foundation's plist
        // serializer cannot create a null, so encode this small object table.
        let objects: [[UInt8]] = [[0xd1, 1, 2], [0x52, 0x65, 0x63], [0xd1, 3, 4], [0x51, 0x30],
                                  [0xa1, 5], [0xd2, 6, 7, 8, 8], [0x51, 0x64], [0x51, 0x74], [0]]
        var bytes = Array("bplist00".utf8)
        var offsets: [UInt8] = []
        for object in objects { offsets.append(UInt8(bytes.count)); bytes += object }
        let table = bytes.count
        bytes += offsets
        bytes += [0, 0, 0, 0, 0, 0, 1, 1]
        for number in [objects.count, 0, table] {
            for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: UInt64(number) >> shift)) }
        }
        var budget = NativeEditContextDecoder.Budget()
        let summary = try NativeEditContextDecoder.decode(Data(bytes), budget: &budget)
        let event = try #require(summary.edit_history.entries?.first?.events?.first)
        #expect(event.status == "partial")
        #expect(event.timestamp.status == "null")
        #expect(event.body.status == "null")
        let stamp = try json(event.timestamp)
        #expect(Set(stamp.keys) == ["status", "raw", "normalized_seconds", "normalized_nanoseconds", "date", "date_local"])
        for key in stamp.keys where key != "status" { #expect(stamp[key] is NSNull) }
        let body = try json(event.body)
        #expect(body["reason"] is NSNull)
        #expect(body["text"] is NSNull)
        let missing = try json(summary.edited_parts)
        #expect(missing["reason"] is NSNull)
        #expect(missing["entries"] is NSNull)
    }

    @Test func semanticCancellationAndSharedByteBudgetAreNotSwallowed() throws {
        let data = try plist(["ec": ["0": [["d": 0, "t": body("Synthetic")]]]])
        var budget = NativeEditContextDecoder.Budget()
        var checks = 0
        _ = try NativeEditContextDecoder.decode(data, budget: &budget, checkCancellation: { checks += 1 })
        let cancelAt = checks - 1
        var current = 0
        budget = .init()
        #expect(throws: CancellationError.self) {
            try NativeEditContextDecoder.decode(data, budget: &budget, checkCancellation: {
                current += 1
                if current == cancelAt { throw CancellationError() }
            })
        }
        #expect(budget.remainingEvents == 2_047)
        #expect(budget.plist.remainingBytes < 4_194_304)
        var parserBudget = MessageSummaryPlist.Budget()
        _ = try MessageSummaryPlist.decode(data, budget: &parserBudget)
        budget = .init()
        budget.plist.remainingBytes = 4_194_304 - parserBudget.remainingBytes
        let limited = try NativeEditContextDecoder.decode(data, budget: &budget)
        #expect(limited.status == "request-limit")
        #expect(limited.edit_history.entries == nil)
        #expect(budget.plist.remainingBytes == 0)
    }
}
