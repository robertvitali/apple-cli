import Foundation

// Encodable payload structs — the `data` object of the `apple contacts` JSON
// envelope. Field names ARE the wire keys (snake_case, no case conversion), matching
// apple-contacts-mcp @ 1cd8789 (v0.3.0) verbatim so the CLI's JSON is a strict
// superset of the MCP's per-tool response (every MCP field preserved inside `data`).

// MARK: - Labeled-value leaves (mirror _serialize_labeled_values entries)

/// `{label_raw, label, value}` — phones / emails / urls.
public struct LabeledScalar: Encodable {
    public let label_raw: String
    public let label: String
    public let value: String
}

/// `{label_raw, label, street, sub_locality, city, sub_administrative_area, state,
/// postal_code, country, iso_country_code}` (mirror _serialize_postal_address).
public struct LabeledPostal: Encodable {
    public let label_raw: String
    public let label: String
    public let street: String
    public let sub_locality: String
    public let city: String
    public let sub_administrative_area: String
    public let state: String
    public let postal_code: String
    public let country: String
    public let iso_country_code: String
}

/// `{label_raw, label, service, username, url, user_identifier}` (social profiles).
public struct LabeledSocialProfile: Encodable {
    public let label_raw: String
    public let label: String
    public let service: String
    public let username: String
    public let url: String
    public let user_identifier: String
}

/// `{label_raw, label, name}` (contact relations).
public struct LabeledRelation: Encodable {
    public let label_raw: String
    public let label: String
    public let name: String
}

/// `{label_raw, label, service, username}` (instant-message addresses).
public struct LabeledIM: Encodable {
    public let label_raw: String
    public let label: String
    public let service: String
    public let username: String
}

/// `{year?, month?, day?}` — birthday sub-object; each component omitted when unset
/// (synthesized Encodable uses encodeIfPresent for optionals). Mirrors the MCP's
/// NSNotFound filtering (`0 < n < 10000`) applied in the serializer.
public struct DateParts: Encodable {
    public let year: Int?
    public let month: Int?
    public let day: Int?
    public init(year: Int?, month: Int?, day: Int?) {
        self.year = year; self.month = month; self.day = day
    }
    /// True when no component survived filtering — the MCP maps this to `null`.
    public var isEmpty: Bool { year == nil && month == nil && day == nil }
}

/// `{label_raw, label, year?, month?, day?}` — niche `dates` entry (never null; a
/// list entry always carries the label pair even if all components filter out).
public struct LabeledDate: Encodable {
    public let label_raw: String
    public let label: String
    public let year: Int?
    public let month: Int?
    public let day: Int?
}

// MARK: - Contact record (mirror _serialize_contact)

/// Full contact record. Custom `encode(to:)` reproduces two MCP behaviors exactly:
/// `birthday` is ALWAYS present (null or object), and the four niche families are
/// present ONLY when `include_niche` was requested.
public struct Contact: Encodable {
    public let id: String
    public let given_name: String
    public let family_name: String
    public let middle_name: String
    public let name_prefix: String
    public let name_suffix: String
    public let nickname: String
    public let organization: String
    public let job_title: String
    public let department: String
    public let phones: [LabeledScalar]
    public let emails: [LabeledScalar]
    public let urls: [LabeledScalar]
    public let postal_addresses: [LabeledPostal]
    public let birthday: DateParts?
    // Niche P3 families — nil ⇒ omit key entirely (include_niche was false).
    public let dates: [LabeledDate]?
    public let social_profiles: [LabeledSocialProfile]?
    public let relations: [LabeledRelation]?
    public let instant_messages: [LabeledIM]?

    enum CodingKeys: String, CodingKey {
        case id, given_name, family_name, middle_name, name_prefix, name_suffix
        case nickname, organization, job_title, department
        case phones, emails, urls, postal_addresses, birthday
        case dates, social_profiles, relations, instant_messages
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(given_name, forKey: .given_name)
        try c.encode(family_name, forKey: .family_name)
        try c.encode(middle_name, forKey: .middle_name)
        try c.encode(name_prefix, forKey: .name_prefix)
        try c.encode(name_suffix, forKey: .name_suffix)
        try c.encode(nickname, forKey: .nickname)
        try c.encode(organization, forKey: .organization)
        try c.encode(job_title, forKey: .job_title)
        try c.encode(department, forKey: .department)
        try c.encode(phones, forKey: .phones)
        try c.encode(emails, forKey: .emails)
        try c.encode(urls, forKey: .urls)
        try c.encode(postal_addresses, forKey: .postal_addresses)
        // birthday: key ALWAYS present; null when no components (MCP `birthday: null`).
        if let birthday, !birthday.isEmpty {
            try c.encode(birthday, forKey: .birthday)
        } else {
            try c.encodeNil(forKey: .birthday)
        }
        // Niche families: present only when include_niche fetched them.
        if let dates { try c.encode(dates, forKey: .dates) }
        if let social_profiles { try c.encode(social_profiles, forKey: .social_profiles) }
        if let relations { try c.encode(relations, forKey: .relations) }
        if let instant_messages { try c.encode(instant_messages, forKey: .instant_messages) }
    }
}

/// 4-field summary (list_contacts / search_contacts / group members).
public struct ContactSummary: Encodable {
    public let id: String
    public let given_name: String
    public let family_name: String
    public let organization: String
}

/// `{id, name, container_id}` (list_groups / create_group / rename_group entry).
public struct Group: Encodable {
    public let id: String
    public let name: String
    public let container_id: String
}

/// `{id, name, type, is_default}` (list_containers entry).
public struct Container: Encodable {
    public let id: String
    public let name: String
    public let type: String
    public let is_default: Bool
}

// MARK: - Per-command result envelopes (the `data` object)

public struct AuthResult: Encodable {
    public let status: String
    public let remediation: String?
}

public struct ListContactsResult: Encodable {
    public let contacts: [ContactSummary]
    public let count: Int
    public let offset: Int
    public let limit: Int
}

public struct GetContactResult: Encodable {
    public let contact: Contact
}

public struct SearchContactsResult: Encodable {
    public let contacts: [ContactSummary]
    public let count: Int
    public let search_field: String
    public let search_value: String
    public let limit: Int
    // Superset extras (Contactor --deep folded in). Omitted (nil) in default mode.
    public let deep: Bool?
}

public struct ListGroupsResult: Encodable {
    public let groups: [Group]
    public let count: Int
    public let limit: Int
}

public struct GroupMembersResult: Encodable {
    public let group_identifier: String
    public let contacts: [ContactSummary]
    public let count: Int
    public let limit: Int
}

public struct ListContainersResult: Encodable {
    public let containers: [Container]
    public let count: Int
    public let limit: Int
}

public struct ExportVCardResult: Encodable {
    public let vcard: String
    public let count: Int
    public let notes: [String]
    // Superset extra: file path when --out used.
    public let written_to: String?
}

public struct ImportVCardResult: Encodable {
    public let identifiers: [String]
    public let count: Int
    public let group_id: String?  // id-echo: ALWAYS present (null when absent), per MCP.
    enum CodingKeys: String, CodingKey { case identifiers, count, group_id }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(identifiers, forKey: .identifiers)
        try c.encode(count, forKey: .count)
        try encodeOrNull(&c, group_id, .group_id)
    }
}

/// Encode an optional String as its value or an explicit JSON `null` (never omit) —
/// for id-echo / nullable fields the MCP always emits as a present key.
private func encodeOrNull<K: CodingKey>(
    _ c: inout KeyedEncodingContainer<K>, _ value: String?, _ key: K
) throws {
    if let value { try c.encode(value, forKey: key) } else { try c.encodeNil(forKey: key) }
}

public struct ReadNoteResult: Encodable {
    public let identifier: String
    public let note: String
}

public struct ReadPhotoResult: Encodable {
    public let identifier: String
    public let image_data: String?  // ALWAYS present (null on no-photo), per MCP.
    public let format: String?      // ALWAYS present (null on no-photo), per MCP.
    public let size_bytes: Int
    // Superset extra: file path when --out used (raw bytes written there); omit when nil.
    public let written_to: String?
    enum CodingKeys: String, CodingKey { case identifier, image_data, format, size_bytes, written_to }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(identifier, forKey: .identifier)
        try encodeOrNull(&c, image_data, .image_data)
        try encodeOrNull(&c, format, .format)
        try c.encode(size_bytes, forKey: .size_bytes)
        try c.encodeIfPresent(written_to, forKey: .written_to)
    }
}

/// create_contact success echo: `{identifier, group_id, container_id}` (id-echo
/// fields null when the corresponding input was absent).
public struct CreateContactResult: Encodable {
    public let identifier: String
    public let group_id: String?      // id-echo: ALWAYS present (null when absent), per MCP.
    public let container_id: String?  // id-echo: ALWAYS present (null when absent), per MCP.
    enum CodingKeys: String, CodingKey { case identifier, group_id, container_id }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(identifier, forKey: .identifier)
        try encodeOrNull(&c, group_id, .group_id)
        try encodeOrNull(&c, container_id, .container_id)
    }
}

/// Bare `{identifier}` echo (update / delete / write_note / write_photo / delete_group).
public struct IdentifierResult: Encodable {
    public let identifier: String
}

/// Membership echo `{contact_identifier, group_identifier}` (add/remove member).
public struct MembershipResult: Encodable {
    public let contact_identifier: String
    public let group_identifier: String
}

/// `{group: {...}}` (create_group / rename_group).
public struct GroupResult: Encodable {
    public let group: Group
}
