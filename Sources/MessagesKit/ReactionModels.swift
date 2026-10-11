import Foundation

extension ChatDB {
    public struct ExactReactionInspect: Encodable, Equatable, Sendable {
        public let status: String
        public let chat: ExactReactionChatTarget
        public let message: ExactReactionMessageTarget
        public let target: ExactReactionTarget
        public let current_outgoing: ExactCurrentOutgoingReaction
        public let reactions_by_author: [ExactReactionAuthorState]
        public let evidence: ExactReactionEvidence

        enum CodingKeys: String, CodingKey {
            case status, chat, message, target, current_outgoing, reactions_by_author, evidence
        }
    }

    public struct ExactReactionChatTarget: Encodable, Equatable, Sendable {
        public let rowid: Int64
        public let guid: String?

        enum CodingKeys: String, CodingKey { case rowid, guid }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(rowid, forKey: .rowid)
            try encodeOrNull(&c, guid, .guid)
        }
    }

    public struct ExactReactionMessageTarget: Encodable, Equatable, Sendable {
        public let rowid: Int64
        public let guid: String?

        enum CodingKeys: String, CodingKey { case rowid, guid }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(rowid, forKey: .rowid)
            try encodeOrNull(&c, guid, .guid)
        }
    }

    public struct ExactReactionTarget: Encodable, Equatable, Sendable {
        public let chat_rowid: Int64
        public let chat_guid: String?
        public let message_rowid: Int64
        public let message_guid: String?
        public let part_index: Int?
        public let mutation_eligible: Bool

        enum CodingKeys: String, CodingKey {
            case chat_rowid, chat_guid, message_rowid, message_guid, part_index, mutation_eligible
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(chat_rowid, forKey: .chat_rowid)
            try encodeOrNull(&c, chat_guid, .chat_guid)
            try c.encode(message_rowid, forKey: .message_rowid)
            try encodeOrNull(&c, message_guid, .message_guid)
            try encodeOrNull(&c, part_index, .part_index)
            try c.encode(mutation_eligible, forKey: .mutation_eligible)
        }
    }

    public struct ExactCurrentOutgoingReaction: Encodable, Equatable, Sendable {
        public let status: String
        public let key: String?
        public let reaction: ExactReactionValue?

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.status == rhs.status && lhs.key.map { Array($0.utf8) } == rhs.key.map { Array($0.utf8) }
                && lhs.reaction == rhs.reaction
        }

        enum CodingKeys: String, CodingKey { case status, key, reaction }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(status, forKey: .status)
            try encodeOrNull(&c, key, .key)
            try encodeOrNull(&c, reaction, .reaction)
        }
    }

    public struct ExactReactionAuthorState: Encodable, Equatable, Sendable {
        public let author: ExactReactionAuthor
        public let current: ExactReactionValue?
        public let events: [ExactReactionEvent]
        /// A null current is authoritative absence only when status is "absent".
        /// Unknown folds retain author identity and all bounded event evidence.
        public let status: String

        init(author: ExactReactionAuthor, current: ExactReactionValue?, events: [ExactReactionEvent],
             status: String? = nil) {
            self.author = author
            self.current = current
            self.events = events
            self.status = status ?? (current == nil ? "absent" : "present")
        }

        enum CodingKeys: String, CodingKey { case author, current, events, status }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(author, forKey: .author)
            try encodeOrNull(&c, current, .current)
            try c.encode(events, forKey: .events)
            try c.encode(status, forKey: .status)
        }
    }

    public struct ExactReactionAuthor: Encodable, Equatable, Sendable {
        public let kind: String
        public let handle_id: Int64?
        public let is_from_me: Bool?

        enum CodingKeys: String, CodingKey { case kind, handle_id, is_from_me }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(kind, forKey: .kind)
            try encodeOrNull(&c, handle_id, .handle_id)
            try encodeOrNull(&c, is_from_me, .is_from_me)
        }
    }

    public struct ExactReactionValue: Encodable, Equatable, Sendable {
        public let key: String
        public let name: String
        public let emoji: String?
        public let supported: Bool

        // String's canonical equivalence is too broad for persisted reaction identity.
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.key.utf8.elementsEqual(rhs.key.utf8)
                && lhs.name.utf8.elementsEqual(rhs.name.utf8)
                && lhs.emoji.map { Array($0.utf8) } == rhs.emoji.map { Array($0.utf8) }
                && lhs.supported == rhs.supported
        }

        enum CodingKeys: String, CodingKey { case key, name, emoji, supported }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(key, forKey: .key)
            try c.encode(name, forKey: .name)
            try encodeOrNull(&c, emoji, .emoji)
            try c.encode(supported, forKey: .supported)
        }
    }

    public struct ExactReactionEvent: Encodable, Equatable, Sendable {
        public let rowid: Int64
        public let message_guid: String?
        public let action: String
        public let associated_message_guid: String?
        public let reaction: ExactReactionValue
        public let normalized_seconds: Int64?
        public let normalized_nanoseconds: Int64?

        enum CodingKeys: String, CodingKey {
            case rowid, message_guid, action, associated_message_guid, reaction
            case normalized_seconds, normalized_nanoseconds
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(rowid, forKey: .rowid)
            try encodeOrNull(&c, message_guid, .message_guid)
            try c.encode(action, forKey: .action)
            try encodeOrNull(&c, associated_message_guid, .associated_message_guid)
            try c.encode(reaction, forKey: .reaction)
            try encodeOrNull(&c, normalized_seconds, .normalized_seconds)
            try encodeOrNull(&c, normalized_nanoseconds, .normalized_nanoseconds)
        }
    }

    public struct ExactReactionEvidence: Encodable, Equatable, Sendable {
        public let row_limit: Int
        public let rows_examined: Int
        public let rows_capped: Bool
        public let unknown_reasons: [String]
    }
}
