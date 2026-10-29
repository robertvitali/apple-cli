import Foundation

public enum NativeMessageParts {
    public enum Status: String, Equatable, Codable, Sendable {
        case absentBlob = "absent-blob"
        case noNativeKeys = "no-native-keys"
        case unsupported = "unsupported"
        case corrupt = "corrupt"
        case decoded = "decoded"
    }

    public struct UTF16Range: Equatable, Codable, Sendable {
        public let location: Int
        public let length: Int
        public init(location: Int, length: Int) {
            self.location = location
            self.length = length
        }
    }

    public struct NativePart: Equatable, Codable, Sendable {
        public let index: Int
        public var utf16Ranges: [UTF16Range]
        public let attachmentGUID: String?
        public init(index: Int, utf16Ranges: [UTF16Range], attachmentGUID: String?) {
            self.index = index
            self.utf16Ranges = utf16Ranges
            self.attachmentGUID = attachmentGUID
        }
    }

    public struct Mention: Equatable, Sendable {
        public let identifier: String
        public let utf16Range: UTF16Range
    }

    /// Optional read metadata; never evidence for mutation targeting.
    public struct MentionObservation: Equatable, Sendable {
        public let entries: [Mention]?
        public let reason: String?
    }

    public struct Decoded: Equatable, Sendable {
        public let text: String?
        public let status: Status
        public let nativePartsAvailable: Bool
        public let nativePartsReason: String
        public let nativeParts: [NativePart]?
        public let mentions: MentionObservation?

        init(text: String?, status: Status, nativePartsAvailable: Bool,
                    nativePartsReason: String, nativeParts: [NativePart]?,
                    mentions: MentionObservation? = nil) {
            self.text = text
            self.status = status
            self.nativePartsAvailable = nativePartsAvailable
            self.nativePartsReason = nativePartsReason
            self.nativeParts = nativeParts
            self.mentions = mentions
        }
    }

    public struct Limits: Sendable {
        public static let `default` = Limits()

        public let maxBlobBytes: Int
        public let maxObjects: Int
        public let maxSharedStrings: Int
        public let maxTypedGroups: Int
        public let maxDepth: Int
        public let maxStringBytes: Int
        public let maxTextUTF16Units: Int
        public let maxRuns: Int
        public let maxDictEntries: Int
        public let maxTotalDictEntries: Int
        public let maxGUIDBytes: Int

        public init(maxBlobBytes: Int = 1_048_576,
                    maxObjects: Int = 4_096,
                    maxSharedStrings: Int = 4_096,
                    maxTypedGroups: Int = 8_192,
                    maxDepth: Int = 32,
                    maxStringBytes: Int = 262_144,
                    maxTextUTF16Units: Int = 262_144,
                    maxRuns: Int = 4_096,
                    maxDictEntries: Int = 512,
                    maxTotalDictEntries: Int = 4_096,
                    maxGUIDBytes: Int = 1_024) {
            self.maxBlobBytes = maxBlobBytes
            self.maxObjects = maxObjects
            self.maxSharedStrings = maxSharedStrings
            self.maxTypedGroups = maxTypedGroups
            self.maxDepth = maxDepth
            self.maxStringBytes = maxStringBytes
            self.maxTextUTF16Units = maxTextUTF16Units
            self.maxRuns = maxRuns
            self.maxDictEntries = maxDictEntries
            self.maxTotalDictEntries = maxTotalDictEntries
            self.maxGUIDBytes = maxGUIDBytes
        }
    }

    private enum DecodeError: Error, CustomStringConvertible {
        case fail(Status, String)

        var description: String {
            switch self {
            case .fail(_, let reason): reason
            }
        }

        var status: Status {
            switch self {
            case .fail(let status, _): status
            }
        }
    }

    private struct RunAttributes: Equatable {
        var partIndex: Int?
        var attachmentGUID: String?
        var mentionIdentifier: String?
        var mentionFailure: String?
    }

    private enum Value: Equatable {
        case string(String, utf8Unchanged: Bool)
        case int(Int)
        case dictionary(RunAttributes)
        case skipped
    }

    private enum Slot: Equatable {
        case placeholder
        case resolving
        case value(Value)
        case classDescriptor(name: String, version: Int, superclass: Int?)
        case cString(String)
    }

    public static func decode(_ data: Data?, limits: Limits = .default, collectMentions: Bool = false, requireExactText: Bool = false) -> Decoded {
        guard let data else {
            return Decoded(text: nil, status: .absentBlob, nativePartsAvailable: false,
                           nativePartsReason: "absent-blob", nativeParts: nil)
        }
        return decode(data, limits: limits, collectMentions: collectMentions, requireExactText: requireExactText)
    }

    public static func decode(_ data: Data, limits: Limits = .default, collectMentions: Bool = false, requireExactText: Bool = false) -> Decoded {
        do {
            guard data.count <= limits.maxBlobBytes else { throw DecodeError.fail(.corrupt, "blob-too-large") }
            var reader = Reader(bytes: Array(data), limits: limits, collectMentions: collectMentions, requireExactText: requireExactText)
            return try reader.decodeAttributedString()
        } catch let error as DecodeError {
            return Decoded(text: nil, status: error.status, nativePartsAvailable: false,
                           nativePartsReason: error.description, nativeParts: nil)
        } catch {
            return Decoded(text: nil, status: .unsupported, nativePartsAvailable: false,
                           nativePartsReason: "unsupported", nativeParts: nil)
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        let limits: Limits
        let collectMentions: Bool
        let requireExactText: Bool
        var mentionEntries: [Mention] = []
        var mentionFailure: String?
        var cursor = 0
        var stringTable: [String] = []
        var slots: [Slot] = []
        var typedGroups = 0
        var totalDictEntries = 0

        mutating func decodeAttributedString() throws -> Decoded {
            try consumeHeader()
            let version = try readUnsignedInteger()
            guard version == 1000 else { throw DecodeError.fail(.unsupported, "unsupported-version") }
            try expectTypeGroup("@")

            let rootSlot = try allocate(.placeholder)
            slots[rootSlot] = .resolving
            try expectByte(0x84)
            let rootClass = try readClassDescriptor(depth: 0)
            try requireChain(rootClass,
                             allowed: [["NSMutableAttributedString", "NSAttributedString", "NSObject"],
                                       ["NSAttributedString", "NSObject"]],
                             reason: "unsupported-root-class")

            let textValue = try readObjectValue(depth: 0)
            guard case .string(let text, let unchanged) = textValue else {
                throw DecodeError.fail(.corrupt, "wrong-kind-root-string")
            }
            guard !requireExactText || unchanged else { throw DecodeError.fail(.corrupt, "changed-root-text-bytes") }
            guard text.utf16.count <= limits.maxTextUTF16Units else {
                throw DecodeError.fail(.corrupt, "text-too-large")
            }

            let runs = try readRuns(textUTF16Length: text.utf16.count)
            try expectByte(0x86)
            guard cursor == bytes.count else { throw DecodeError.fail(.corrupt, "trailing-bytes") }

            slots[rootSlot] = .value(.skipped)
            let parts = try collapse(runs)
            return Decoded(text: text,
                           status: parts.isEmpty ? .noNativeKeys : .decoded,
                           nativePartsAvailable: true,
                           nativePartsReason: parts.isEmpty ? "empty-known" : "available",
                           nativeParts: parts,
                           mentions: mentionObservation(text: text))
        }

        private func mentionObservation(text: String) -> MentionObservation? {
            guard collectMentions else { return nil }
            if let mentionFailure { return .init(entries: nil, reason: mentionFailure) }
            if !mentionEntries.isEmpty {
                // One bounded buffer avoids rescanning text for each endpoint.
                let units = Array(text.utf16)
                func scalarBoundary(_ offset: Int) -> Bool {
                    guard offset > 0, offset < units.count else { return true }
                    return !((0xD800...0xDBFF).contains(units[offset - 1])
                             && (0xDC00...0xDFFF).contains(units[offset]))
                }
                for entry in mentionEntries {
                    let range = entry.utf16Range
                    guard range.location >= 0, range.length > 0,
                          range.location <= units.count,
                          range.length <= units.count - range.location,
                          scalarBoundary(range.location), scalarBoundary(range.location + range.length) else {
                        return .init(entries: nil, reason: "invalid-mention-range")
                    }
                }
            }
            return .init(entries: mentionEntries, reason: nil)
        }

        private mutating func collectMention(_ attrs: RunAttributes, location: Int, length: Int) {
            guard collectMentions, mentionFailure == nil else { return }
            if let failure = attrs.mentionFailure {
                mentionFailure = failure
            } else if let identifier = attrs.mentionIdentifier {
                if length == 0 {
                    mentionFailure = "invalid-mention-range"
                } else if mentionEntries.count == 256 {
                    mentionFailure = "mention-count-limit"
                } else {
                    mentionEntries.append(.init(identifier: identifier,
                                                utf16Range: .init(location: location, length: length)))
                }
            }
            if mentionFailure != nil { mentionEntries.removeAll(keepingCapacity: false) }
        }

        private mutating func readRuns(textUTF16Length: Int) throws -> [(Int, UTF16Range, String?)] {
            var attrCache: [Int: RunAttributes] = [:]
            var out: [(Int, UTF16Range, String?)] = []
            var location = 0
            var runCount = 0

            while let next = peek(), next != 0x86 {
                guard runCount < limits.maxRuns else { throw DecodeError.fail(.corrupt, "run-limit") }
                try expectTypeGroup("iI")
                let attrRef = try readSignedInteger()
                let length = try readUnsignedInteger()
                guard location + length <= textUTF16Length else {
                    throw DecodeError.fail(.corrupt, "range-overflow")
                }

                let attrs: RunAttributes
                if attrRef == 0 {
                    attrs = RunAttributes()
                } else if let cached = attrCache[attrRef] {
                    attrs = cached
                } else {
                    let value = try readObjectValue(depth: 0)
                    guard case .dictionary(let parsed) = value else {
                        throw DecodeError.fail(.corrupt, "wrong-kind-dictionary")
                    }
                    attrs = parsed
                    attrCache[attrRef] = parsed
                }

                if attrs.partIndex == nil, attrs.attachmentGUID != nil {
                    throw DecodeError.fail(.corrupt, "orphan-attachment-guid")
                }
                if let index = attrs.partIndex {
                    guard index >= 0 else { throw DecodeError.fail(.corrupt, "negative-part-index") }
                    guard length > 0 else { throw DecodeError.fail(.corrupt, "zero-length-part-run") }
                    out.append((index, UTF16Range(location: location, length: length), attrs.attachmentGUID))
                }
                collectMention(attrs, location: location, length: length)
                location += length
                runCount += 1
            }
            guard location == textUTF16Length else { throw DecodeError.fail(.corrupt, "range-underflow") }
            return out
        }

        private func collapse(_ runs: [(Int, UTF16Range, String?)]) throws -> [NativePart] {
            var guidByIndex: [Int: String?] = [:]
            var parts: [NativePart] = []
            for (index, range, guid) in runs {
                if let known = guidByIndex[index], known.map({ Data($0.utf8) }) != guid.map({ Data($0.utf8) }) {
                    throw DecodeError.fail(.corrupt, "conflicting-attachment-guid")
                }
                guidByIndex.updateValue(guid, forKey: index)
                if let existing = parts.indices.first(where: {
                    parts[$0].index == index && parts[$0].attachmentGUID.map({ Data($0.utf8) }) == guid.map({ Data($0.utf8) })
                }) {
                    if let last = parts[existing].utf16Ranges.last, last.location + last.length == range.location {
                        parts[existing].utf16Ranges[parts[existing].utf16Ranges.count - 1] =
                            UTF16Range(location: last.location, length: last.length + range.length)
                    } else {
                        parts[existing].utf16Ranges.append(range)
                    }
                } else {
                    parts.append(NativePart(index: index, utf16Ranges: [range], attachmentGUID: guid))
                }
            }
            return parts
        }

        private mutating func readObjectValue(depth: Int) throws -> Value {
            guard depth <= limits.maxDepth else { throw DecodeError.fail(.corrupt, "depth-limit") }
            try expectTypeGroup("@")
            if peek() == 0x85 {
                cursor += 1
                return .skipped
            }
            if isReferenceToken(peek()) {
                let index = try readReferenceIndex(reason: "dangling-reference")
                guard index < slots.count else { throw DecodeError.fail(.corrupt, "dangling-reference") }
                switch slots[index] {
                case .value(let value): return value
                case .resolving: throw DecodeError.fail(.corrupt, "reference-cycle")
                case .placeholder: throw DecodeError.fail(.corrupt, "unresolved-reference")
                case .classDescriptor, .cString: throw DecodeError.fail(.corrupt, "wrong-kind-reference")
                }
            }

            let objectSlot = try allocate(.placeholder)
            slots[objectSlot] = .resolving
            try expectByte(0x84)
            let classSlot = try readClassDescriptor(depth: depth + 1)
            let chain = try classChainNames(from: classSlot)
            let value: Value
            if try chainMatches(classSlot, ["NSMutableString", "NSString", "NSObject"]) ||
                (try chainMatches(classSlot, ["NSString", "NSObject"])) {
                try expectTypeGroup("+")
                value = try readInlineUTF8StringValue()
                try expectByte(0x86)
            } else if try chainMatchesAny(classSlot, [["NSDictionary", "NSObject"],
                                                       ["NSMutableDictionary", "NSDictionary", "NSObject"]]) {
                value = .dictionary(try readDictionaryPayload(depth: depth + 1))
                try expectByte(0x86)
            } else if try chainMatches(classSlot, ["NSNumber", "NSValue", "NSObject"]) {
                value = .int(try readNSNumberInteger())
                try expectByte(0x86)
            } else if try chainMatches(classSlot, ["NSURL", "NSObject"]) {
                try expectTypeGroup("c")
                _ = try readUnsignedInteger()
                _ = try readObjectValue(depth: depth + 1)
                try expectByte(0x86)
                value = .skipped
            } else if try chainMatchesAny(classSlot, [["NSData", "NSObject"],
                                                       ["NSMutableData", "NSData", "NSObject"]]) {
                // Opaque attribute metadata carries raw bytes, not object slots.
                // Consume only its exact declared byte array; never unarchive it
                // or permit it to supply a native part index or attachment GUID.
                try expectTypeGroup("i")
                let count = try readUnsignedInteger()
                guard count <= limits.maxBlobBytes else { throw DecodeError.fail(.corrupt, "data-byte-limit") }
                try expectTypeGroup("[\(count)c]")
                guard count <= bytes.count - cursor else { throw DecodeError.fail(.corrupt, "truncated-data") }
                cursor += count
                try expectByte(0x86)
                value = .skipped
            } else if chain.contains("NSString") || chain.contains("NSMutableString") {
                throw DecodeError.fail(.unsupported, "unsupported-string-class")
            } else {
                throw DecodeError.fail(.unsupported, "unknown-unskippable-object")
            }
            slots[objectSlot] = .value(value)
            return value
        }

        private mutating func readDictionaryPayload(depth: Int) throws -> RunAttributes {
            try expectTypeGroup("i")
            let count = try readUnsignedInteger()
            guard count <= limits.maxDictEntries else { throw DecodeError.fail(.corrupt, "dictionary-entry-limit") }
            totalDictEntries += count
            guard totalDictEntries <= limits.maxTotalDictEntries else {
                throw DecodeError.fail(.corrupt, "dictionary-total-entry-limit")
            }

            var attrs = RunAttributes()
            var seenPart = false
            var seenGuid = false
            var seenMention = false
            for _ in 0..<count {
                let key = try readObjectValue(depth: depth + 1)
                let value = try readObjectValue(depth: depth + 1)
                guard case .string(let keyString, let keyUTF8Unchanged) = key else { throw DecodeError.fail(.corrupt, "wrong-kind-key") }
                switch keyString {
                case "__kIMMessagePartAttributeName":
                    guard keyUTF8Unchanged else { throw DecodeError.fail(.corrupt, "changed-native-key-bytes") }
                    guard !seenPart else { throw DecodeError.fail(.corrupt, "duplicate-part-key") }
                    guard case .int(let index) = value else { throw DecodeError.fail(.corrupt, "wrong-kind-part-index") }
                    guard index >= 0 else { throw DecodeError.fail(.corrupt, "negative-part-index") }
                    attrs.partIndex = index
                    seenPart = true
                case "__kIMFileTransferGUIDAttributeName":
                    guard keyUTF8Unchanged else { throw DecodeError.fail(.corrupt, "changed-native-key-bytes") }
                    guard !seenGuid else { throw DecodeError.fail(.corrupt, "duplicate-guid-key") }
                    guard case .string(let guid, let unchanged) = value else { throw DecodeError.fail(.corrupt, "wrong-kind-attachment-guid") }
                    guard unchanged else { throw DecodeError.fail(.corrupt, "changed-attachment-guid-bytes") }
                    guard !guid.isEmpty else { throw DecodeError.fail(.corrupt, "empty-attachment-guid") }
                    guard guid.utf8.count <= limits.maxGUIDBytes else { throw DecodeError.fail(.corrupt, "guid-too-large") }
                    attrs.attachmentGUID = guid
                    seenGuid = true
                case "__kIMMentionConfirmedMention" where collectMentions && keyUTF8Unchanged:
                    if seenMention {
                        attrs.mentionFailure = "duplicate-mention-key"
                    } else if case .string(let identifier, let utf8Unchanged) = value {
                        if !utf8Unchanged {
                            attrs.mentionFailure = "invalid-mention-identifier"
                        } else if identifier.utf8.count > 1_024 {
                            attrs.mentionFailure = "mention-identifier-limit"
                        } else if identifier.isEmpty || identifier.unicodeScalars.contains(where: {
                            $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
                        }) {
                            attrs.mentionFailure = "invalid-mention-identifier"
                        } else {
                            attrs.mentionIdentifier = identifier
                        }
                    } else {
                        attrs.mentionFailure = "invalid-mention-identifier"
                    }
                    seenMention = true
                default:
                    break
                }
            }
            return attrs
        }

        private mutating func readNSNumberInteger() throws -> Int {
            try expectTypeGroup("*")
            let declared = try readCStringPointer()
            guard ["q", "i", "s"].contains(declared) else {
                throw DecodeError.fail(.unsupported, "unsupported-number-type")
            }
            try expectTypeGroup(declared)
            let value = try readSignedInteger()
            switch declared {
            case "s": guard value >= Int(Int16.min), value <= Int(Int16.max) else { throw DecodeError.fail(.corrupt, "number-overflow") }
            case "i": guard value >= Int(Int32.min), value <= Int(Int32.max) else { throw DecodeError.fail(.corrupt, "number-overflow") }
            case "q": break
            default: throw DecodeError.fail(.unsupported, "unsupported-number-type")
            }
            return value
        }

        private mutating func readClassDescriptor(depth: Int) throws -> Int {
            guard depth <= limits.maxDepth else { throw DecodeError.fail(.corrupt, "depth-limit") }
            if isReferenceToken(peek()) {
                let index = try readReferenceIndex(reason: "dangling-class-reference")
                guard index < slots.count else { throw DecodeError.fail(.corrupt, "dangling-class-reference") }
                guard case .classDescriptor = slots[index] else {
                    throw DecodeError.fail(.corrupt, "wrong-kind-class-reference")
                }
                return index
            }
            try expectByte(0x84)
            let name = try readSharedString(reason: "truncated-class-name")
            let version = try readUnsignedInteger()
            let slot = try allocate(.classDescriptor(name: name, version: version, superclass: nil))
            let superclass: Int?
            if peek() == 0x85 {
                cursor += 1
                superclass = nil
            } else {
                superclass = try readClassDescriptor(depth: depth + 1)
            }
            slots[slot] = .classDescriptor(name: name, version: version, superclass: superclass)
            return slot
        }

        private func requireChain(_ slot: Int, allowed: [[String]], reason: String) throws {
            let names = try classChainNames(from: slot)
            guard allowed.contains(names), try classChainVersionsAreExpected(from: slot) else {
                throw DecodeError.fail(.unsupported, reason)
            }
        }

        private func chainMatches(_ slot: Int, _ expected: [String]) throws -> Bool {
            try classChainNames(from: slot) == expected && classChainVersionsAreExpected(from: slot)
        }

        private func chainMatchesAny(_ slot: Int, _ expected: [[String]]) throws -> Bool {
            let names = try classChainNames(from: slot)
            guard expected.contains(names) else { return false }
            return try classChainVersionsAreExpected(from: slot)
        }

        private func classChainNames(from slot: Int) throws -> [String] {
            var names: [String] = []
            var seen = Set<Int>()
            var current: Int? = slot
            while let index = current {
                guard index < slots.count, !seen.contains(index) else { throw DecodeError.fail(.corrupt, "class-reference-cycle") }
                seen.insert(index)
                guard case .classDescriptor(let name, _, let superclass) = slots[index] else {
                    throw DecodeError.fail(.corrupt, "wrong-kind-class-reference")
                }
                names.append(name)
                current = superclass
                guard names.count <= limits.maxDepth else { throw DecodeError.fail(.corrupt, "depth-limit") }
            }
            return names
        }

        private func classChainVersionsAreExpected(from slot: Int) throws -> Bool {
            var seen = Set<Int>()
            var current: Int? = slot
            while let index = current {
                guard index < slots.count, !seen.contains(index) else { throw DecodeError.fail(.corrupt, "class-reference-cycle") }
                seen.insert(index)
                guard case .classDescriptor(let name, let version, let superclass) = slots[index] else {
                    throw DecodeError.fail(.corrupt, "wrong-kind-class-reference")
                }
                let expected = (name == "NSString" || name == "NSMutableString") ? 1 : 0
                guard version == expected else { return false }
                current = superclass
            }
            return true
        }

        private mutating func readTypeGroup() throws -> String {
            typedGroups += 1
            guard typedGroups <= limits.maxTypedGroups else { throw DecodeError.fail(.corrupt, "typed-group-limit") }
            return try readSharedString(reason: "truncated-type-group")
        }

        private mutating func expectTypeGroup(_ expected: String) throws {
            let actual = try readTypeGroup()
            guard actual == expected else { throw DecodeError.fail(.unsupported, "unexpected-type-group") }
        }

        private mutating func readSharedString(reason: String) throws -> String {
            if peek() == 0x84 {
                cursor += 1
                let count = try readUnsignedInteger()
                guard count <= limits.maxStringBytes, cursor + count <= bytes.count else {
                    throw DecodeError.fail(.corrupt, reason)
                }
                let raw = bytes[cursor..<(cursor + count)]
                cursor += count
                guard let value = String(bytes: raw, encoding: .ascii) else {
                    throw DecodeError.fail(.corrupt, "invalid-ascii")
                }
                guard stringTable.count < limits.maxSharedStrings else {
                    throw DecodeError.fail(.corrupt, "shared-string-limit")
                }
                stringTable.append(value)
                return value
            }
            let index = try readReferenceIndex(reason: "dangling-string-reference")
            guard index < stringTable.count else { throw DecodeError.fail(.corrupt, "dangling-string-reference") }
            return stringTable[index]
        }

        private mutating func readCStringPointer() throws -> String {
            if isReferenceToken(peek()) {
                let index = try readReferenceIndex(reason: "dangling-cstring-reference")
                guard index < slots.count else { throw DecodeError.fail(.corrupt, "dangling-cstring-reference") }
                guard case .cString(let value) = slots[index] else {
                    throw DecodeError.fail(.corrupt, "wrong-kind-cstring-reference")
                }
                return value
            }
            try expectByte(0x84)
            let value = try readSharedString(reason: "truncated-cstring")
            _ = try allocate(.cString(value))
            return value
        }

        private mutating func readInlineUTF8StringValue() throws -> Value {
            let count = try readUnsignedInteger()
            guard count <= limits.maxStringBytes, cursor + count <= bytes.count else {
                throw DecodeError.fail(.corrupt, "truncated-string")
            }
            let raw = bytes[cursor..<(cursor + count)]
            cursor += count
            guard let value = String(bytes: raw, encoding: .utf8) else {
                throw DecodeError.fail(.corrupt, "invalid-utf8")
            }
            // Foundation can strip a leading BOM. Preserve legacy decoded strings,
            // but never expose changed bytes as an exact native key or identity.
            return .string(value, utf8Unchanged: value.utf8.elementsEqual(raw))
        }

        private mutating func readReferenceIndex(reason: String) throws -> Int {
            let signed = try readSignedInteger()
            let index = signed + 110
            guard index >= 0 else { throw DecodeError.fail(.corrupt, reason) }
            return index
        }

        private mutating func readUnsignedInteger() throws -> Int {
            guard let tag = peek() else { throw DecodeError.fail(.corrupt, "truncated") }
            cursor += 1
            if tag < 0x80 { return Int(tag) }
            if tag == 0x81 {
                guard cursor + 2 <= bytes.count else { throw DecodeError.fail(.corrupt, "truncated-int16") }
                let value = Int(bytes[cursor]) | (Int(bytes[cursor + 1]) << 8)
                cursor += 2
                return value
            }
            if tag == 0x82 {
                guard cursor + 4 <= bytes.count else { throw DecodeError.fail(.corrupt, "truncated-int32") }
                let raw = UInt32(bytes[cursor]) | (UInt32(bytes[cursor + 1]) << 8)
                    | (UInt32(bytes[cursor + 2]) << 16) | (UInt32(bytes[cursor + 3]) << 24)
                cursor += 4
                guard raw <= UInt32(Int32.max) else { throw DecodeError.fail(.corrupt, "integer-overflow") }
                return Int(raw)
            }
            throw DecodeError.fail(.corrupt, "unsupported-integer-encoding")
        }

        private mutating func readSignedInteger() throws -> Int {
            guard let tag = peek() else { throw DecodeError.fail(.corrupt, "truncated") }
            cursor += 1
            if tag < 0x80 { return Int(tag) }
            if tag == 0x81 {
                guard cursor + 2 <= bytes.count else { throw DecodeError.fail(.corrupt, "truncated-int16") }
                let raw = UInt16(bytes[cursor]) | (UInt16(bytes[cursor + 1]) << 8)
                cursor += 2
                return Int(Int16(bitPattern: raw))
            }
            if tag == 0x82 {
                guard cursor + 4 <= bytes.count else { throw DecodeError.fail(.corrupt, "truncated-int32") }
                let raw = UInt32(bytes[cursor]) | (UInt32(bytes[cursor + 1]) << 8)
                    | (UInt32(bytes[cursor + 2]) << 16) | (UInt32(bytes[cursor + 3]) << 24)
                cursor += 4
                return Int(Int32(bitPattern: raw))
            }
            if tag >= 0x92 { return Int(Int8(bitPattern: tag)) }
            throw DecodeError.fail(.corrupt, "unsupported-integer-encoding")
        }

        private mutating func allocate(_ slot: Slot) throws -> Int {
            guard slots.count < limits.maxObjects else { throw DecodeError.fail(.corrupt, "object-limit") }
            slots.append(slot)
            return slots.count - 1
        }

        private mutating func consumeHeader() throws {
            guard bytes.count >= 13 else { throw DecodeError.fail(.corrupt, "truncated-header") }
            guard bytes[0] == 0x04, bytes[1] == 0x0b,
                  Array(bytes[2..<13]) == Array("streamtyped".utf8) else {
                throw DecodeError.fail(.unsupported, "unsupported-header")
            }
            cursor = 13
        }

        private mutating func expectByte(_ expected: UInt8) throws {
            guard let actual = peek() else { throw DecodeError.fail(.corrupt, "truncated") }
            guard actual == expected else { throw DecodeError.fail(.corrupt, "unexpected-byte") }
            cursor += 1
        }

        private func isReferenceToken(_ byte: UInt8?) -> Bool {
            guard let byte else { return false }
            return byte != 0x84 && byte != 0x85 && byte != 0x86
        }

        private func peek() -> UInt8? {
            guard cursor < bytes.count else { return nil }
            return bytes[cursor]
        }
    }
}
