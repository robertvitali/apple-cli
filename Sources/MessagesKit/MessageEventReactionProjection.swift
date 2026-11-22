import Foundation

/// Stored with each membership so an event can describe a reaction after its source row disappears.
enum MessageEventReactionProjection {
    typealias Source = MessageEventMessageSource

    private enum Target {
        case notAssociated, unresolved, bare(String), part(String, Int32)

        init(_ address: Source.Observation, type: Int64?) {
            self = .unresolved
            if address.status == .null && type == 0 {
                self = .notAssociated
                return
            }
            guard address.status == .available, address.bytes.count <= 1040 else { return }
            let bytes = address.bytes
            let partPrefix = "p:".utf8, barePrefix = "bp:".utf8
            func guid(_ bytes: Data.SubSequence) -> String? {
                guard !bytes.starts(with: partPrefix), !bytes.starts(with: barePrefix) else { return nil }
                return (try? MessageEventGUID(storedBytes: Data(bytes)))?.rawValue
            }
            if bytes.starts(with: partPrefix) {
                let remainder = bytes.dropFirst(partPrefix.count)
                guard let slash = remainder.firstIndex(of: 47) else { return }
                let digits = remainder[..<slash]
                guard (1...10).contains(digits.count),
                      let index = Int32(String(decoding: digits, as: UTF8.self)), index >= 0,
                      String(index).utf8.elementsEqual(digits),
                      let id = guid(remainder.suffix(from: remainder.index(after: slash))) else { return }
                self = .part(id, index)
            } else if let id = guid(bytes.starts(with: barePrefix) ? bytes.dropFirst(barePrefix.count) : bytes) {
                self = .bare(id)
            }
        }

        var fields: (status: String, guid: String?, part: Int32?) {
            switch self {
            case .notAssociated: ("not_associated", nil, nil)
            case .unresolved: ("unresolved", nil, nil)
            case .bare(let id): ("bare_alias_uncertain", id, nil)
            case .part(let id, let index): ("parsed_part", id, index)
            }
        }
    }

    static func encode(_ observations: [Source.Field: Source.Observation]) throws -> Data {
        func field(_ key: Source.Field) throws -> Source.Observation {
            guard let value = observations[key] else { throw Source.Failure.invalidProjection }
            return value
        }
        func integer(_ key: Source.Field) throws -> Int64? {
            let value = try field(key)
            guard value.status == .available else { return nil }
            guard value.bytes.count == 8 else { throw Source.Failure.invalidProjection }
            return value.bytes.withUnsafeBytes { Int64(bigEndian: $0.loadUnaligned(as: Int64.self)) }
        }
        func date(_ key: Source.Field) throws -> String? {
            let value = try field(key)
            return value.status == .available ? value.bytes.base64EncodedString() : nil
        }
        func nullable<T>(_ value: T?) -> Any {
            if let value { return value }
            return NSNull()
        }

        let type = try integer(.associationType)
        let target = try Target(field(.associationGUID), type: type).fields
        let owner = try integer(.isFromMe), handle = try integer(.handleID)
        let actor: String
        switch owner {
        case 1: actor = "self"
        case 0 where (handle ?? 0) > 0: actor = "other"
        default: actor = "unknown"
        }
        let emoji = try field(.associationEmoji)
        let supported: Bool
        switch type ?? 0 {
        case 2000...2005, 3000...3005: supported = true
        case 2006, 3006:
            supported = emoji.status == .available && emoji.bytes.count <= ChatDB.maximumStoredCustomEmojiBytes
                && ChatDB.storedReactionEmoji(emoji.bytes).map(ChatDB.validCustomReactionEmoji) == true
        default: supported = false
        }
        let association: [String: Any] = ["target_status": target.status, "target_message_guid": nullable(target.guid),
            "target_part": nullable(target.part), "native_type": nullable(type), "actor_kind": actor, "supported": supported]
        // V1 compares the serialized bytes. Preserve Foundation's sorted-key and slash escaping behavior.
        return try JSONSerialization.data(withJSONObject: ["version": 1, "association": association,
            "date_edited": nullable(try date(.dateEdited)), "date_retracted": nullable(try date(.dateRetracted))],
            options: .sortedKeys)
    }
}
