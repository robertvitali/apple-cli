import Foundation
import Testing
@testable import MessagesKit

@Suite struct NativeEditRealTimestampTests {
    private let utc = TimeZone(secondsFromGMT: 0)!

    private struct Wire: Decodable {
        let raw: Int64?
        let raw_real: Double?
    }

    private func object(_ stamp: ChatDB.ExactNativeEditContext.HistoryTimestamp) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(stamp)) as? [String: Any])
    }

    /// One scalar object, one-byte offset/reference widths, and a standard
    /// binary-plist trailer. Construct storage types without NSNumber coercion.
    private func scalar(_ marker: UInt8, _ payload: [UInt8]) throws -> MessageSummaryPlist.Value {
        let tableOffset = 9 + payload.count
        var data = Data("bplist00".utf8)
        data.append(marker)
        data.append(contentsOf: payload)
        data.append(8)
        data.append(contentsOf: Array(repeating: 0, count: 6) + [1, 1])
        for value in [UInt64(1), 0, UInt64(tableOffset)] {
            data.append(contentsOf: bytes(value))
        }
        var budget = MessageSummaryPlist.Budget()
        return try MessageSummaryPlist.decode(data, budget: &budget)
    }

    private func bytes(_ value: UInt64) -> [UInt8] {
        stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: value >> $0) }
    }

    @Test func fractionalNativeEventSecondsAreAvailable() {
        let stamp = NativeEditContextDecoder.timestamp(.real(1.25), timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(stamp.status == "available")
        #expect(stamp.normalized_seconds == 1)
        #expect(stamp.normalized_nanoseconds == 250_000_000)
        #expect(stamp.date == "2001-01-01T00:00:01Z")
    }

    @Test func normalizationHandlesNegativeFractionsTiesAndCarry() throws {
        let cases: [(Double, Int64, Int64)] = [
            (1.25, 1, 250_000_000), (-0.25, -1, 750_000_000),
            (0, 0, 0), (-0.0, 0, 0), (-1, -1, 0),
            (1.0 / 1024, 0, 976_563),
            // Binary64 multiplication lands on the tie although the exact
            // rational value is just below it; the contract uses Double math.
            (1.5e-9, 0, 2),
            (0.9999999996, 1, 0), (-Double.leastNonzeroMagnitude, 0, 0),
            (800_000_000.125, 800_000_000, 125_000_000)
        ]
        for (raw, seconds, nanos) in cases {
            let stamp = NativeEditContextDecoder.timestamp(.real(raw), timeZone: utc)
            #expect(stamp.status == "available")
            #expect(stamp.raw == nil)
            #expect(stamp.raw_real?.bitPattern == raw.bitPattern)
            #expect(stamp.normalized_seconds == seconds)
            #expect(stamp.normalized_nanoseconds == nanos)
            #expect(stamp.date == NativeMessageTimestamp.formatSeconds(seconds, utc).0)
        }
        var formatted: Int64?
        _ = NativeEditContextDecoder.timestamp(.real(0.9999999996), timeZone: utc, format: { seconds, zone in
            formatted = seconds
            return NativeMessageTimestamp.formatSeconds(seconds, zone)
        })
        #expect(formatted == 1)
    }

    @Test func rawStorageTypesAndFloat32WideningRemainObservable() throws {
        let integer = try scalar(0x13, bytes(1))
        let real = try scalar(0x23, bytes(Double(1).bitPattern))
        #expect(integer == .integer(1))
        #expect(real == .real(1))
        let integerStamp = NativeEditContextDecoder.timestamp(integer, timeZone: utc)
        let realStamp = NativeEditContextDecoder.timestamp(real, timeZone: utc)
        #expect(integerStamp.raw == 1 && integerStamp.raw_real == nil)
        #expect(realStamp.raw == nil && realStamp.raw_real == 1)
        #expect(integerStamp.date == realStamp.date)
        let float: Float = 0.1
        let widened = try scalar(0x22, Array(bytes(UInt64(float.bitPattern)).suffix(4)))
        #expect(widened == .real(Double(float)))
        let stamp = NativeEditContextDecoder.timestamp(widened, timeZone: utc)
        #expect(stamp.raw_real?.bitPattern == Double(float).bitPattern)
        #expect(stamp.normalized_seconds == 0)
        #expect(stamp.normalized_nanoseconds == 100_000_001)
    }

    @Test func encodedRealNumbersRoundTripWithoutChangingIntegerEvidence() throws {
        for raw in [800_000_000.125, Double(252_423_993_600).nextDown, 1, 0, -0.0] {
            let stamp = NativeEditContextDecoder.timestamp(.real(raw), timeZone: utc)
            let encoded = try JSONEncoder().encode(stamp)
            let decoded = try JSONDecoder().decode(Wire.self, from: encoded)
            #expect(decoded.raw == nil)
            if raw == 0 {
                // JSON consumers need not preserve the sign of zero.
                #expect(decoded.raw_real == 0)
            } else {
                #expect(decoded.raw_real?.bitPattern == raw.bitPattern)
            }
            let value = try object(stamp)
            #expect(Set(value.keys) == ["status", "raw", "raw_real", "normalized_seconds",
                                       "normalized_nanoseconds", "date", "date_local"])
            #expect(value["raw"] is NSNull)
        }
        let integer = try object(NativeEditContextDecoder.timestamp(.integer(-1), timeZone: utc))
        #expect(integer["raw"] as? Int == -1)
        #expect(integer["raw_real"] is NSNull)
        #expect(integer["normalized_nanoseconds"] as? Int == 0)
    }

    @Test func realCalendarBoundsAndUnavailableValuesRetainFiniteEvidence() throws {
        let lower = Double(-63_113_904_000)
        let upper = Double(252_423_993_600)
        for raw in [lower, lower.nextUp, upper.nextDown] {
            #expect(NativeEditContextDecoder.timestamp(.real(raw), timeZone: utc).status == "available")
        }
        let last = NativeEditContextDecoder.timestamp(.real(upper.nextDown), timeZone: utc)
        #expect(last.normalized_seconds == 252_423_993_599)
        #expect(last.normalized_nanoseconds == 999_969_482)
        for raw in [lower.nextDown, upper, upper.nextUp, Double.greatestFiniteMagnitude] {
            let stamp = NativeEditContextDecoder.timestamp(.real(raw), timeZone: utc)
            #expect(stamp.status == "invalid-timestamp")
            #expect(stamp.raw == nil && stamp.raw_real == raw)
            #expect(stamp.normalized_seconds == nil && stamp.date == nil)
        }
        for (raw, offset) in [(lower, -3600), (upper.nextDown, 3600)] {
            let stamp = NativeEditContextDecoder.timestamp(.real(raw), timeZone: TimeZone(secondsFromGMT: offset)!)
            #expect(stamp.status == "invalid-timestamp")
            #expect(stamp.raw_real == raw && stamp.date_local == nil)
        }
        let badFormat = NativeEditContextDecoder.timestamp(.real(1.25), format: { _, _ in ("bad", "bad") })
        #expect(badFormat.status == "invalid-timestamp" && badFormat.raw_real == 1.25)
        for raw in [Double.nan, .infinity, -.infinity] {
            let stamp = NativeEditContextDecoder.timestamp(.real(raw), timeZone: utc)
            let value = try object(stamp)
            #expect(stamp.status == "invalid-timestamp")
            for key in value.keys where key != "status" { #expect(value[key] is NSNull) }
        }
    }

    @Test func unsupportedTypesStayDistinctFromMissingAndNull() throws {
        for value: MessageSummaryPlist.Value in [.boolean(true), .string("1.25"), .date(1.25), .array([]), .dictionary([:]), .data(Data())] {
            let stamp = NativeEditContextDecoder.timestamp(value)
            #expect(stamp.status == "wrong-type")
            #expect(stamp.raw == nil && stamp.raw_real == nil)
        }
        #expect(NativeEditContextDecoder.timestamp(nil).status == "missing-key")
        #expect(NativeEditContextDecoder.timestamp(.null).status == "null")
    }

    @Test func realHistoryEventsDecodeThroughBinaryPlistWithIndependentBodyState() throws {
        let body = NSArchiver.archivedData(withRootObject: NSAttributedString(string: "Synthetic history"))
        let data = try PropertyListSerialization.data(fromPropertyList: ["ec": ["0": [
            false, ["d": 1.25, "t": body], ["d": -0.25, "t": 7]
        ]]] as [String: Any], format: .binary, options: 0)
        var budget = NativeEditContextDecoder.Budget()
        let summary = try NativeEditContextDecoder.decode(data, budget: &budget)
        let events = try #require(summary.edit_history.entries?.first?.events)
        #expect(events.count == 3)
        #expect(events[0].status == "invalid-event")
        #expect(try object(events[0].timestamp)["raw_real"] is NSNull)
        #expect(events[1].status == "available")
        #expect(events[1].timestamp.raw_real == 1.25)
        #expect(events[1].body.text == "Synthetic history")
        #expect(events[2].status == "partial")
        #expect(events[2].timestamp.status == "available")
        #expect(events[2].timestamp.normalized_seconds == -1)
        #expect(events[2].body.text == nil)
    }
}
