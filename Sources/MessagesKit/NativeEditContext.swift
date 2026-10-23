import Foundation

extension ChatDB {
    /// Native historical observations; never evidence that a mutation is safe.
    public struct ExactNativeEditContext: Encodable, Equatable, Sendable {
        public let date_edited: ExactNativeStatus.TimestampField
        public let date_retracted: ExactNativeStatus.TimestampField
        public let summary_info: Summary

        public struct Container<Entry: Encodable & Equatable & Sendable>: Encodable, Equatable, Sendable {
            public let status: String
            public let reason: String?
            public let entries: [Entry]?
            enum CodingKeys: String, CodingKey { case status, reason, entries }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(status, forKey: .status)
                try encodeOrNull(&c, reason, .reason)
                try encodeOrNull(&c, entries, .entries)
            }
        }

        public struct PartIndex: Encodable, Equatable, Sendable {
            public let position: Int
            public let status: String
            public let raw_integer: Int64?
            public let original_part_index: Int64?
            enum CodingKeys: String, CodingKey { case position, status, raw_integer, original_part_index }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(position, forKey: .position)
                try c.encode(status, forKey: .status)
                try encodeOrNull(&c, raw_integer, .raw_integer)
                try encodeOrNull(&c, original_part_index, .original_part_index)
            }
        }

        public struct OriginalPart: Encodable, Equatable, Sendable {
            public let source_key: String
            public let original_part_index: Int64?
            public let status: String
            public let location_raw: Int64?
            public let length_raw: Int64?
            enum CodingKeys: String, CodingKey { case source_key, original_part_index, status, location_raw, length_raw }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(source_key, forKey: .source_key)
                try c.encode(status, forKey: .status)
                try encodeOrNull(&c, original_part_index, .original_part_index)
                try encodeOrNull(&c, location_raw, .location_raw)
                try encodeOrNull(&c, length_raw, .length_raw)
            }
        }

        public struct HistoryGroup: Encodable, Equatable, Sendable {
            public let source_key: String
            public let original_part_index: Int64?
            public let status: String
            public let events: [HistoryEvent]?
            enum CodingKeys: String, CodingKey { case source_key, original_part_index, status, events }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(source_key, forKey: .source_key)
                try c.encode(status, forKey: .status)
                try encodeOrNull(&c, original_part_index, .original_part_index)
                try encodeOrNull(&c, events, .events)
            }
        }

        public struct HistoryEvent: Encodable, Equatable, Sendable {
            public let position: Int
            public let status: String
            public let timestamp: ExactNativeStatus.TimestampField
            public let body: HistoryBody
        }

        public struct HistoryBody: Encodable, Equatable, Sendable {
            public let status: String
            public let reason: String?
            public let text: String?
            enum CodingKeys: String, CodingKey { case status, reason, text }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(status, forKey: .status)
                try encodeOrNull(&c, reason, .reason)
                try encodeOrNull(&c, text, .text)
            }
        }

        public struct Summary: Encodable, Equatable, Sendable {
            public let status: String
            public let edited_parts: Container<PartIndex>
            public let retracted_parts: Container<PartIndex>
            public let original_parts: Container<OriginalPart>
            public let edit_history: Container<HistoryGroup>

            static func unavailable(_ status: String) -> Self {
                .init(status: status,
                      edited_parts: .init(status: "unavailable", reason: status, entries: nil),
                      retracted_parts: .init(status: "unavailable", reason: status, entries: nil),
                      original_parts: .init(status: "unavailable", reason: status, entries: nil),
                      edit_history: .init(status: "unavailable", reason: status, entries: nil))
            }
        }
    }
}

/// Interprets already bounded native metadata without repairing or guessing it.
enum NativeEditContextDecoder {
    typealias Context = ChatDB.ExactNativeEditContext
    typealias Value = MessageSummaryPlist.Value
    private typealias Failure = MessageSummaryPlist.Failure

    struct Budget {
        var plist = MessageSummaryPlist.Budget()
        var remainingEvents = 2_048
        var remainingTextUTF16 = 1_048_576
    }

    /// The caller bounds serialized bytes before fetching them. The shared
    /// budget is consumed even when a summary fails or cancellation propagates.
    static func decode(_ data: Data, budget: inout Budget,
                       checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Context.Summary {
        do {
            let bytesBefore = budget.plist.remainingBytes
            let root = try MessageSummaryPlist.decode(data, budget: &budget.plist, checkCancellation: checkCancellation)
            guard case .dictionary(let fields) = root else { return .unavailable("wrong-type") }
            var reader = Reader(budget: budget, expandedBytes: bytesBefore - budget.plist.remainingBytes)
            defer { budget = reader.budget }
            return try reader.summary(fields, checkCancellation: checkCancellation)
        } catch let failure as Failure {
            switch failure {
            case .corrupt: return .unavailable("corrupt")
            case .unsupportedFormat: return .unavailable("unsupported-format")
            case .resourceLimit: return .unavailable("resource-limit")
            case .requestLimit: return .unavailable("request-limit")
            }
        }
    }

    static func timestamp(_ value: Value?, timeZone: TimeZone = .current,
                          format: (Int64, TimeZone) -> (String, String) = NativeMessageTimestamp.formatSeconds) -> ChatDB.ExactNativeStatus.TimestampField {
        guard let value else { return NativeMessageTimestamp.unavailable("missing-key") }
        if case .null = value { return NativeMessageTimestamp.unavailable("null") }
        guard case .integer(let raw) = value else { return NativeMessageTimestamp.unavailable("wrong-type") }
        // Event d is always signed Apple-epoch seconds, not a date-column sentinel.
        guard (-63_113_904_000...252_423_993_599).contains(raw) else {
            return NativeMessageTimestamp.unavailable("invalid-timestamp", raw: raw)
        }
        let (utc, local) = format(raw, timeZone)
        guard NativeMessageTimestamp.valid(utc: utc, local: local), !local.hasPrefix("0000-") else {
            return NativeMessageTimestamp.unavailable("invalid-timestamp", raw: raw)
        }
        // yyyy does not expose BCE, and Calendar's historical Gregorian cutover
        // differs from the formatter's proleptic calendar. Validate local wall
        // seconds directly, including the zone's offset at this exact instant.
        let date = Date(timeIntervalSince1970: Double(raw) + MessageTime.appleUnixOffset)
        let (localSeconds, overflow) = raw.addingReportingOverflow(Int64(timeZone.secondsFromGMT(for: date)))
        guard !overflow, (-63_113_904_000...252_423_993_599).contains(localSeconds) else {
            return NativeMessageTimestamp.unavailable("invalid-timestamp", raw: raw)
        }
        return .init(status: "available", raw: raw, normalized_seconds: raw,
                     normalized_nanoseconds: 0, date: utc, date_local: local)
    }

    private static func integer(_ value: Value?) -> Int64? {
        guard case .integer(let raw)? = value else { return nil }
        return raw
    }

    private static func partKey(_ key: String) -> Int64? {
        let bytes = key.utf8
        guard !bytes.isEmpty, bytes.count <= 10, bytes.allSatisfy({ (48...57).contains($0) }),
              bytes.count == 1 || bytes.first != 48,
              let index = Int64(key), index <= Int64(Int32.max) else { return nil }
        return index
    }

    private static func keys(_ fields: [String: Value]) -> [String] {
        fields.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    private struct Reader {
        var budget: Budget
        var expandedBytes: Int
        var eventCount = 0

        mutating func chargeBytes(_ count: Int) throws {
            guard count <= 1_048_576 - expandedBytes else { throw Failure.resourceLimit }
            guard count <= budget.plist.remainingBytes else { throw Failure.requestLimit }
            expandedBytes += count
            budget.plist.remainingBytes -= count
        }

        mutating func summary(_ fields: [String: Value], checkCancellation: () throws -> Void) throws -> Context.Summary {
            try checkCancellation()
            let edited = try indexes(fields["ep"], checkCancellation: checkCancellation)
            let retracted = try indexes(fields["rp"], checkCancellation: checkCancellation)
            let original = try originals(fields["otr"], checkCancellation: checkCancellation)
            let history = try history(fields["ec"], checkCancellation: checkCancellation)
            try checkCancellation()
            return .init(status: "available", edited_parts: edited, retracted_parts: retracted,
                         original_parts: original, edit_history: history)
        }

        func indexes(_ value: Value?, checkCancellation: () throws -> Void) throws -> Context.Container<Context.PartIndex> {
            guard let value else { return .init(status: "missing-key", reason: nil, entries: nil) }
            guard case .array(let values) = value else { return .init(status: "wrong-type", reason: nil, entries: nil) }
            var seen: Set<Int64> = []
            var entries: [Context.PartIndex] = []
            for (position, value) in values.enumerated() {
                try checkCancellation()
                let raw = integer(value)
                let index = raw.flatMap { (0...Int64(Int32.max)).contains($0) ? $0 : nil }
                let status = raw == nil ? "wrong-type" : index == nil ? "invalid-index"
                    : seen.insert(index!).inserted ? "available" : "duplicate"
                entries.append(.init(position: position, status: status, raw_integer: raw, original_part_index: index))
            }
            return .init(status: entries.allSatisfy { $0.status == "available" } ? "available" : "partial", reason: nil, entries: entries)
        }

        func originals(_ value: Value?, checkCancellation: () throws -> Void) throws -> Context.Container<Context.OriginalPart> {
            guard let value else { return .init(status: "missing-key", reason: nil, entries: nil) }
            guard case .dictionary(let fields) = value else { return .init(status: "wrong-type", reason: nil, entries: nil) }
            var entries: [Context.OriginalPart] = []
            for key in keys(fields) {
                try checkCancellation()
                let index = partKey(key)
                var location: Int64?, length: Int64?
                var status = "wrong-type"
                if case .dictionary(let coordinates)? = fields[key] {
                    location = integer(coordinates["lo"])
                    length = integer(coordinates["le"])
                    if coordinates["lo"] == nil || coordinates["le"] == nil { status = "missing-field" }
                    else if let location, let length {
                        status = location >= 0 && length >= 0 && !location.addingReportingOverflow(length).overflow
                            ? "available" : "invalid-range"
                    }
                }
                entries.append(.init(source_key: key, original_part_index: index,
                                     status: index == nil ? "invalid-part-key" : status,
                                     location_raw: location, length_raw: length))
            }
            return .init(status: entries.allSatisfy { $0.status == "available" } ? "available" : "partial", reason: nil, entries: entries)
        }

        mutating func history(_ value: Value?, checkCancellation: () throws -> Void) throws -> Context.Container<Context.HistoryGroup> {
            guard let value else { return .init(status: "missing-key", reason: nil, entries: nil) }
            guard case .dictionary(let fields) = value else { return .init(status: "wrong-type", reason: nil, entries: nil) }
            var groups: [Context.HistoryGroup] = []
            for key in keys(fields) {
                try checkCancellation()
                let index = partKey(key)
                var events: [Context.HistoryEvent]?
                var status = "wrong-type"
                if case .array(let values)? = fields[key] {
                    var decoded: [Context.HistoryEvent] = []
                    for (position, value) in values.enumerated() {
                        try checkCancellation()
                        guard eventCount < 256 else { throw Failure.resourceLimit }
                        guard budget.remainingEvents > 0 else { throw Failure.requestLimit }
                        eventCount += 1
                        budget.remainingEvents -= 1
                        decoded.append(try event(value, position: position, checkCancellation: checkCancellation))
                    }
                    status = decoded.allSatisfy { $0.status == "available" } ? "available" : "partial"
                    events = decoded
                }
                groups.append(.init(source_key: key, original_part_index: index,
                                    status: index == nil ? "invalid-part-key" : status, events: events))
            }
            return .init(status: groups.allSatisfy { $0.status == "available" } ? "available" : "partial", reason: nil, entries: groups)
        }

        mutating func event(_ value: Value, position: Int, checkCancellation: () throws -> Void) throws -> Context.HistoryEvent {
            guard case .dictionary(let fields) = value else {
                return .init(position: position, status: "invalid-event", timestamp: NativeMessageTimestamp.unavailable("unavailable"),
                             body: .init(status: "unavailable", reason: "invalid-event", text: nil))
            }
            let stamp = timestamp(fields["d"])
            let body = try body(fields["t"], checkCancellation: checkCancellation)
            return .init(position: position, status: stamp.status == "available" && body.status == "available" ? "available" : "partial",
                         timestamp: stamp, body: body)
        }

        mutating func body(_ value: Value?, checkCancellation: () throws -> Void) throws -> Context.HistoryBody {
            guard let value else { return .init(status: "missing-key", reason: nil, text: nil) }
            let data: Data
            switch value {
            case .null: return .init(status: "null", reason: nil, text: nil)
            case .data(let bytes):
                // NativeMessageParts copies its bounded input before traversal.
                try chargeBytes(bytes.count)
                data = bytes
            case .string(let url):
                let prefix = "data:application/octet-stream;base64,"
                // Protocol spelling is byte-exact; String comparison permits Unicode equivalents.
                guard url.utf8.starts(with: prefix.utf8) else { return .init(status: "unsupported-encoding", reason: nil, text: nil) }
                guard url.utf8.count <= 262_144 else { throw Failure.resourceLimit }
                let payload = url.utf8.dropFirst(prefix.utf8.count)
                let count = payload.count
                guard count % 4 == 0, payload.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 43 || $0 == 47 || $0 == 61 }) else {
                    return .init(status: "invalid-base64", reason: nil, text: nil)
                }
                // String input + canonical re-encoding + decoded buffer + the
                // typedstream reader's byte copy are charged before allocation.
                let upperBound = count / 4 * 3
                try chargeBytes(count * 2 + upperBound * 2)
                guard let decoded = Data(base64Encoded: String(decoding: payload, as: UTF8.self)),
                      decoded.base64EncodedString().utf8.elementsEqual(payload) else {
                    return .init(status: "invalid-base64", reason: nil, text: nil)
                }
                data = decoded
            default: return .init(status: "wrong-type", reason: nil, text: nil)
            }
            try checkCancellation()
            let decoded = NativeMessageParts.decode(data)
            try checkCancellation()
            guard (decoded.status == .decoded || decoded.status == .noNativeKeys), let text = decoded.text else {
                return .init(status: "decode-unavailable", reason: decoded.nativePartsReason, text: nil)
            }
            let units = text.utf16.count
            guard units <= budget.remainingTextUTF16 else { throw Failure.requestLimit }
            budget.remainingTextUTF16 -= units
            return .init(status: "available", reason: nil, text: text)
        }
    }
}
