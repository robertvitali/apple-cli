import Foundation

/// Encodable payloads for the `data` field of the JSON envelope. Property names are
/// the wire keys verbatim (snake_case) — the machine contract. Each is a strict
/// superset of the corresponding `mac_messages_mcp` tool's (unstructured string)
/// output: every fact the MCP put in its formatted string is a field here, plus
/// structured extras.
enum MessagesModels {}

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
    let chats: [ChatDB.Chat]
}

struct SearchData: Encodable {
    let search_term: String
    let hours: Int
    let threshold: Double
    let match: String
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
