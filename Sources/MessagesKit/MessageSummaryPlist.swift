import Foundation

/// Internal representation for bounded native message-summary decoding.
enum MessageSummaryPlist {
    indirect enum Value: Equatable {
        case null, boolean(Bool), integer(Int64), real(Double), date(Double)
        case data(Data), string(String), array([Value]), dictionary([String: Value])
    }

    enum Failure: Error, Equatable { case corrupt, unsupportedFormat, resourceLimit, requestLimit }

    struct Budget {
        var remainingVisits = 65_536
        var remainingBytes = 4 * 1_024 * 1_024
    }

    static func decode(_ data: Data, budget: inout Budget,
                       checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Value {
        try checkCancellation()
        guard data.count <= 1_048_576 else { throw Failure.resourceLimit }
        var reader = Reader(bytes: Array(data))
        return try reader.read(budget: &budget, checkCancellation: checkCancellation)
    }

    private struct Object {
        let start: Int
        let end: Int
        let marker: UInt8
        let payload: Int
        let count: Int
    }

    private struct Reader {
        let bytes: [UInt8]
        var objects: [Object] = []
        var referenceWidth = 0
        var tableStart = 0
        var visits = 0
        var expandedBytes = 0
        var active: Set<Int> = []

        // Validation and repeated traversal both consume work. The caller keeps
        // this budget across summaries, including unsuccessful attempts.
        mutating func charge(visits count: Int = 0, bytes byteCount: Int = 0,
                             budget: inout Budget) throws {
            guard count <= 16_384 - visits, byteCount <= 1_048_576 - expandedBytes else {
                throw Failure.resourceLimit
            }
            guard count <= budget.remainingVisits, byteCount <= budget.remainingBytes else {
                throw Failure.requestLimit
            }
            visits += count
            expandedBytes += byteCount
            budget.remainingVisits -= count
            budget.remainingBytes -= byteCount
        }

        func unsigned(_ position: Int, width: Int, end: Int) throws -> UInt64 {
            guard (1...8).contains(width), position >= 0, position <= end,
                  width <= end - position, end <= bytes.count else { throw Failure.corrupt }
            var value: UInt64 = 0
            for i in position..<(position + width) { value = (value << 8) | UInt64(bytes[i]) }
            return value
        }

        mutating func read(budget: inout Budget, checkCancellation: () throws -> Void) throws -> Value {
            guard bytes.starts(with: Array("bplist00".utf8)) else { throw Failure.unsupportedFormat }
            guard bytes.count >= 40 else { throw Failure.corrupt }
            let trailer = bytes.count - 32
            let offsetWidth = Int(bytes[trailer + 6])
            referenceWidth = Int(bytes[trailer + 7])
            guard (1...8).contains(offsetWidth), (1...8).contains(referenceWidth) else { throw Failure.corrupt }
            let count = try unsigned(trailer + 8, width: 8, end: bytes.count)
            let root = try unsigned(trailer + 16, width: 8, end: bytes.count)
            let table = try unsigned(trailer + 24, width: 8, end: bytes.count)
            guard count > 0, root < count, table >= 8, table <= UInt64(trailer) else { throw Failure.corrupt }
            guard count <= 16_384 else { throw Failure.resourceLimit }
            tableStart = Int(table)
            // count and width are capped before multiplying or allocating.
            guard Int(count) * offsetWidth == trailer - tableStart else { throw Failure.corrupt }
            objects.reserveCapacity(Int(count))
            for i in 0..<Int(count) {
                try checkCancellation()
                try charge(visits: 1, budget: &budget)
                let offset = try unsigned(tableStart + i * offsetWidth, width: offsetWidth, end: trailer)
                guard offset >= 8, offset < table else { throw Failure.corrupt }
                objects.append(try describe(Int(offset)))
            }
            var previousEnd = 8
            for object in objects.sorted(by: { $0.start < $1.start }) {
                guard object.start >= previousEnd else { throw Failure.corrupt }
                previousEnd = object.end
            }
            for object in objects {
                try checkCancellation()
                let kind = object.marker >> 4
                if kind == 0xa || kind == 0xd {
                    let references = object.count * (kind == 0xd ? 2 : 1)
                    for i in 0..<references {
                        try checkCancellation()
                        try charge(visits: 1, budget: &budget)
                        let ref = try unsigned(object.payload + i * referenceWidth,
                                               width: referenceWidth, end: object.end)
                        guard ref < count else { throw Failure.corrupt }
                    }
                }
            }
            // Known unsupported records can be measured safely but must never be
            // interpreted as native metadata, even if unreachable from the root.
            guard !objects.contains(where: { $0.marker >> 4 == 8 || $0.marker == 0x14 }) else {
                throw Failure.unsupportedFormat
            }
            return try value(Int(root), depth: 1, budget: &budget, checkCancellation: checkCancellation)
        }

        func describe(_ start: Int) throws -> Object {
            let marker = bytes[start]
            let kind = marker >> 4
            let low = Int(marker & 0xf)
            var payload = start + 1
            var count = 0
            var byteCount = 0
            switch kind {
            case 0:
                guard marker == 0 || marker == 8 || marker == 9 else { throw Failure.unsupportedFormat }
            case 1:
                guard low <= 4 else { throw Failure.unsupportedFormat }
                byteCount = 1 << low
            case 2:
                guard low == 2 || low == 3 else { throw Failure.unsupportedFormat }
                byteCount = 1 << low
            case 3:
                guard marker == 0x33 else { throw Failure.unsupportedFormat }
                byteCount = 8
            case 8: byteCount = low + 1
            case 4, 5, 6, 0xa, 0xd:
                var length = UInt64(low)
                if low == 15 {
                    guard payload < tableStart, bytes[payload] >> 4 == 1,
                          bytes[payload] & 0xf <= 3 else { throw Failure.corrupt }
                    let width = 1 << Int(bytes[payload] & 0xf)
                    length = try unsigned(payload + 1, width: width, end: tableStart)
                    payload += 1 + width
                }
                guard length <= UInt64(Int.max) else { throw Failure.corrupt }
                count = Int(length)
                let scale: Int
                if kind == 0xa || kind == 0xd {
                    guard count <= 4_096 else { throw Failure.resourceLimit }
                    scale = referenceWidth * (kind == 0xd ? 2 : 1)
                } else {
                    scale = kind == 6 ? 2 : 1
                    let cap = kind == 4 ? 1_048_576 : 262_144
                    guard count <= cap / scale else { throw Failure.resourceLimit }
                }
                byteCount = count * scale
            default: throw Failure.unsupportedFormat
            }
            guard payload <= tableStart, byteCount <= tableStart - payload else { throw Failure.corrupt }
            return Object(start: start, end: payload + byteCount, marker: marker, payload: payload, count: count)
        }

        mutating func value(_ id: Int, depth: Int, budget: inout Budget,
                            checkCancellation: () throws -> Void) throws -> Value {
            try checkCancellation()
            guard depth <= 32 else { throw Failure.resourceLimit }
            guard active.insert(id).inserted else { throw Failure.corrupt }
            defer { active.remove(id) }
            try charge(visits: 1, budget: &budget)
            let object = objects[id]
            let kind = object.marker >> 4
            switch kind {
            case 0:
                return object.marker == 0 ? .null : .boolean(object.marker == 9)
            case 1:
                let raw = try unsigned(object.payload, width: object.end - object.payload, end: object.end)
                return .integer(object.marker == 0x13 ? Int64(bitPattern: raw) : Int64(raw))
            case 2, 3:
                let width = object.end - object.payload
                let raw = try unsigned(object.payload, width: width, end: object.end)
                let number = width == 4 ? Double(Float(bitPattern: UInt32(raw))) : Double(bitPattern: raw)
                return kind == 3 ? .date(number) : .real(number)
            case 4:
                try charge(bytes: object.count, budget: &budget)
                return .data(Data(bytes[object.payload..<object.end]))
            case 5:
                try charge(bytes: object.count, budget: &budget)
                let slice = bytes[object.payload..<object.end]
                guard slice.allSatisfy({ $0 < 128 }) else { throw Failure.corrupt }
                return .string(String(decoding: slice, as: UTF8.self))
            case 6:
                // Three UTF-8 bytes per UTF-16 code unit is a conservative
                // expansion bound, charged before allocating/transcoding.
                try charge(bytes: object.count * 3, budget: &budget)
                var units: [UInt16] = []
                units.reserveCapacity(object.count)
                var needsLowSurrogate = false
                for i in 0..<object.count {
                    if i % 1_024 == 0 { try checkCancellation() }
                    let unit = UInt16(try unsigned(object.payload + i * 2, width: 2, end: object.end))
                    if needsLowSurrogate {
                        guard (0xdc00...0xdfff).contains(unit) else { throw Failure.corrupt }
                        needsLowSurrogate = false
                    } else if (0xd800...0xdbff).contains(unit) {
                        needsLowSurrogate = true
                    } else if (0xdc00...0xdfff).contains(unit) { throw Failure.corrupt }
                    units.append(unit)
                }
                guard !needsLowSurrogate else { throw Failure.corrupt }
                return .string(String(decoding: units, as: UTF16.self))
            case 0xa, 0xd:
                if kind == 0xa {
                    var values: [Value] = []
                    values.reserveCapacity(object.count)
                    for i in 0..<object.count {
                        let ref = try reference(object, index: i)
                        values.append(try value(ref, depth: depth + 1, budget: &budget, checkCancellation: checkCancellation))
                    }
                    return .array(values)
                }
                var values: [String: Value] = [:]
                for i in 0..<object.count {
                    let keyRef = try reference(object, index: i)
                    guard case .string(let key) = try value(keyRef, depth: depth + 1, budget: &budget,
                                                          checkCancellation: checkCancellation),
                          values[key] == nil else { throw Failure.corrupt }
                    let valueRef = try reference(object, index: i + object.count)
                    values[key] = try value(valueRef, depth: depth + 1, budget: &budget, checkCancellation: checkCancellation)
                }
                return .dictionary(values)
            default: throw Failure.unsupportedFormat
            }
        }

        func reference(_ object: Object, index: Int) throws -> Int {
            // Every reference was range-checked before traversal began.
            Int(try unsigned(object.payload + index * referenceWidth, width: referenceWidth, end: object.end))
        }
    }
}
