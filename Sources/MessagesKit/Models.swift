import Foundation

/// Encodable payloads for the `data` field of the JSON envelope. Property names are
/// the wire keys verbatim (snake_case) — the machine contract. Each is a strict
/// superset of the corresponding `mac_messages_mcp` tool's (unstructured string)
/// output: every fact the MCP put in its formatted string is a field here, plus
/// structured extras.
enum MessagesModels {}

/// Encode an optional as its value or an explicit JSON `null` — never omitting the key.
///
/// Swift's SYNTHESIZED `Encodable` omits a nil optional entirely (measured, not assumed), which
/// is the shape every optional in this module shipped with and must keep. Fields whose contract
/// is documented as `<type>|null` have to be present either way, so a caller can distinguish
/// "no value here" from "an older binary that did not emit this key"; those go through this
/// helper. Used by the payloads below and by the row shapes in `ChatDB.swift`.
func encodeOrNull<K: CodingKey, V: Encodable>(
    _ c: inout KeyedEncodingContainer<K>, _ value: V?, _ key: K
) throws {
    if let value { try c.encode(value, forKey: key) } else { try c.encodeNil(forKey: key) }
}

struct ContactCandidateData: Encodable {
    let name: String
    let phone: String
    let score: Double
    let matched_on: String
}

struct RecentData: Encodable {
    let hours: Int
    let limit: Int
    let contact: String?
    let resolved_handle_rowids: [Int64]?
    let ambiguous: Bool
    let candidates: [ContactCandidateData]?
    let note: String?
    /// Echoes `--direct-only`, so a caller can tell a filtered read from an unfiltered one
    /// without re-deriving it from the messages.
    let direct_only: Bool
    /// Whether the filter was actually APPLIED. `direct_only: true` with this false means the
    /// store cannot say which chat a message belongs to, so group-chat messages are still in
    /// the result. Always present. stdout JSON is the only channel a machine consumer is told
    /// to trust, so a filter that did not run has to be visible here and not only on stderr.
    let direct_only_applied: Bool
    let count: Int
    let messages: [ChatDB.Message]
}

struct FindContactData: Encodable {
    let query: String
    let count: Int
    let contacts: [ContactCandidateData]
}

struct ChatsData: Encodable {
    let count: Int
    /// Echoes `--name`; ALWAYS present, null when no filter was given.
    let name_filter: String?
    let chats: [ChatDB.Chat]

    enum CodingKeys: String, CodingKey { case count, name_filter, chats }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(count, forKey: .count)
        try encodeOrNull(&c, name_filter, .name_filter)
        try c.encode(chats, forKey: .chats)
    }
}

struct SearchData: Encodable {
    let search_term: String
    let hours: Int
    let threshold: Double
    let match: String
    /// Echoes `--direct-only`, matching the `recent` payload.
    let direct_only: Bool
    /// Whether the filter was actually applied — see `RecentData.direct_only_applied`.
    let direct_only_applied: Bool
    let count: Int
    let scanned: Int
    let truncated: Bool
    let messages: [ChatDB.ScoredMessage]
}

struct ContactsCheckData: Encodable {
    struct Sample: Encodable { let number: String; let name: String }
    let count: Int
    let samples: [Sample]
}

struct DoctorData: Encodable {
    let full_disk_access: Bool
    let messages_db: ChatDB.DBCheck
    let addressbook: AddressBook.Diagnostic
    let contacts_with_handles: Int
    let notes: [String]
}

// MARK: - Send payloads

struct SendPreview: Encodable {
    let action: String          // "send"
    let executed: Bool          // false in preview
    let dry_run: Bool
    let group_chat: Bool
    let recipient: String
    let resolved_handle: String
    let display_name: String?
    let service_plan: String    // "iMessage→SMS auto" | "group chat"
    let message: String
    let note: String
}

struct SendResult: Encodable {
    let action: String          // "send"
    let executed: Bool          // true
    let ok: Bool
    let group_chat: Bool
    let recipient: String
    let resolved_handle: String
    let display_name: String?
    let service_used: String?
    let message: String
}

struct SendAmbiguousData: Encodable {
    let action: String          // "send"
    let executed: Bool          // false
    let ambiguous: Bool         // true
    let recipient: String
    let note: String
    let candidates: [ContactCandidateData]
}
