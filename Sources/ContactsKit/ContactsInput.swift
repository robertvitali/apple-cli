import Foundation
import AppleKit

// Input models + validators for create_contact / update_contact, ported from
// apple-contacts-mcp @ 1cd8789 (v0.3.0) server.py validators. Pure (no
// Contacts.framework) so they are unit-testable in CI.
//
// Three-state field semantics for UPDATE (matching the MCP's None/""/value):
//   - absent / JSON null  ⇒ Swift nil  ⇒ "don't touch"
//   - ""  (or [])         ⇒ "clear"
//   - value               ⇒ "set / replace"
// Swift's synthesized Decodable distinguishes nil (absent-or-null) from ""/[]
// (present-empty), which is exactly the distinction the update path needs.
// For CREATE the MCP uses truthy checks, so nil-or-empty both mean "skip".

// MARK: - Labeled-value inputs (one struct per CN family)

public struct ScalarInput: Codable {
    public var label: String?
    public var value: String?
}

public struct PostalInput: Codable {
    public var label: String?
    public var street: String?
    public var sub_locality: String?
    public var city: String?
    public var sub_administrative_area: String?
    public var state: String?
    public var postal_code: String?
    public var country: String?
    public var iso_country_code: String?
}

public struct BirthdayInput: Codable {
    public var year: Int?
    public var month: Int?
    public var day: Int?
}

public struct DateInput: Codable {
    public var label: String?
    public var year: Int?
    public var month: Int?
    public var day: Int?
}

public struct SocialInput: Codable {
    public var label: String?
    public var service: String?
    public var username: String?
    public var url: String?
    public var user_identifier: String?
}

public struct RelationInput: Codable {
    public var label: String?
    public var name: String?
}

public struct IMInput: Codable {
    public var label: String?
    public var service: String?
    public var username: String?
}

/// The full field set accepted by create/update (mirrors the MCP's `fields` dict).
/// All-optional so the same struct serves create (truthy-set) and update (presence).
public struct ContactFields: Codable {
    public var given_name: String?
    public var family_name: String?
    public var middle_name: String?
    public var name_prefix: String?
    public var name_suffix: String?
    public var nickname: String?
    public var organization: String?
    public var job_title: String?
    public var department: String?
    public var phones: [ScalarInput]?
    public var emails: [ScalarInput]?
    public var urls: [ScalarInput]?
    public var postal_addresses: [PostalInput]?
    public var birthday: BirthdayInput?
    public var dates: [DateInput]?
    public var social_profiles: [SocialInput]?
    public var relations: [RelationInput]?
    public var instant_messages: [IMInput]?

    public init() {}

    /// Decode from a `--json` blob. Rejects unknown top-level keys loosely (Swift
    /// ignores unknowns by default, which matches the tolerant-reader contract).
    public static func fromJSON(_ text: String) throws -> ContactFields {
        try checkBoundedInput(text, "--json")
        guard let data = text.data(using: .utf8) else {
            throw AppleError.validation("--json payload is not valid UTF-8")
        }
        do {
            return try JSONDecoder().decode(ContactFields.self, from: data)
        } catch let e as DecodingError {
            throw AppleError.validation("--json payload is not a valid contact object: \(decodingMessage(e))")
        }
    }

    /// Count of simple string keys that are "present" (non-nil) — used to detect an
    /// empty update. (List/birthday/niche presence is added by the update validator.)
    var touchedKeyCount: Int {
        var n = 0
        for v in [given_name, family_name, middle_name, name_prefix, name_suffix,
                  nickname, organization, job_title, department] where v != nil { n += 1 }
        if phones != nil { n += 1 }
        if emails != nil { n += 1 }
        if urls != nil { n += 1 }
        if postal_addresses != nil { n += 1 }
        if birthday != nil { n += 1 }
        if dates != nil { n += 1 }
        if social_profiles != nil { n += 1 }
        if relations != nil { n += 1 }
        if instant_messages != nil { n += 1 }
        return n
    }
}

private func decodingMessage(_ e: DecodingError) -> String {
    switch e {
    case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx),
         .keyNotFound(_, let ctx), .dataCorrupted(let ctx):
        return ctx.debugDescription
    @unknown default:
        return String(describing: e)
    }
}

// MARK: - Validators (mirror server.py _validate_*)

private func trimmedNonEmpty(_ s: String?) -> Bool {
    guard let s else { return false }
    return !s.trimmingCharacters(in: .whitespaces).isEmpty
}

/// create: at least one of given_name / family_name / organization non-empty, then
/// the shared labeled-value validators. Throws `AppleError.validation` on failure.
public func validateCreateInput(_ f: ContactFields) throws {
    if !(trimmedNonEmpty(f.given_name) || trimmedNonEmpty(f.family_name) || trimmedNonEmpty(f.organization)) {
        throw AppleError.validation("At least one of given_name, family_name, or organization must be set.")
    }
    try validateLabeledValueFields(f)
}

/// update: identifier non-empty + at least one field supplied + shared validators.
public func validateUpdateInput(identifier: String, _ f: ContactFields) throws {
    if identifier.trimmingCharacters(in: .whitespaces).isEmpty {
        throw AppleError.validation("identifier must be a non-empty string")
    }
    if f.touchedKeyCount == 0 {
        throw AppleError.validation("At least one field must be supplied to update.")
    }
    try validateLabeledValueFields(f)
}

/// Per-family validators shared by create and update; first failure short-circuits.
public func validateLabeledValueFields(_ f: ContactFields) throws {
    for (i, p) in (f.phones ?? []).enumerated() where !trimmedNonEmpty(p.value) {
        throw AppleError.validation("phones[\(i)].value must be non-empty")
    }
    for (i, e) in (f.emails ?? []).enumerated() {
        let v = (e.value ?? "").trimmingCharacters(in: .whitespaces)
        if v.isEmpty { throw AppleError.validation("emails[\(i)].value must be non-empty") }
        if !v.contains("@") { throw AppleError.validation("emails[\(i)].value must contain '@'") }
    }
    for (i, u) in (f.urls ?? []).enumerated() where !trimmedNonEmpty(u.value) {
        throw AppleError.validation("urls[\(i)].value must be non-empty")
    }
    for (i, a) in (f.postal_addresses ?? []).enumerated() {
        let anyset = [a.street, a.city, a.state, a.postal_code, a.country].contains { trimmedNonEmpty($0) }
        if !anyset {
            throw AppleError.validation(
                "postal_addresses[\(i)] must set at least one of street/city/state/postal_code/country")
        }
    }
    if let b = f.birthday { try validateBirthday(b) }
    for (i, d) in (f.dates ?? []).enumerated() {
        if d.month == nil && d.day == nil && d.year == nil {
            throw AppleError.validation("dates[\(i)] must set at least one of year/month/day")
        }
        if let m = d.month, !(1...12).contains(m) { throw AppleError.validation("dates[\(i)].month must be 1-12") }
        if let day = d.day, !(1...31).contains(day) { throw AppleError.validation("dates[\(i)].day must be 1-31") }
        if let y = d.year, y <= 0 { throw AppleError.validation("dates[\(i)].year must be > 0 if set") }
    }
    for (i, p) in (f.social_profiles ?? []).enumerated() {
        if !(trimmedNonEmpty(p.username) || trimmedNonEmpty(p.url)) {
            throw AppleError.validation("social_profiles[\(i)] must set at least one of username/url")
        }
    }
    for (i, r) in (f.relations ?? []).enumerated() where !trimmedNonEmpty(r.name) {
        throw AppleError.validation("relations[\(i)].name must be non-empty")
    }
    for (i, m) in (f.instant_messages ?? []).enumerated() where !trimmedNonEmpty(m.username) {
        throw AppleError.validation("instant_messages[\(i)].username must be non-empty")
    }
}

private func validateBirthday(_ b: BirthdayInput) throws {
    if let m = b.month, !(1...12).contains(m) { throw AppleError.validation("birthday.month must be 1-12") }
    if let d = b.day, !(1...31).contains(d) { throw AppleError.validation("birthday.day must be 1-31") }
    if let y = b.year, y <= 0 { throw AppleError.validation("birthday.year must be > 0 if set") }
}

/// search: exactly one of name/phone/email/organization non-empty (after trim).
/// Returns (field, value). Mirrors server.py search_contacts selection logic.
public func resolveSearchSelection(
    name: String?, phone: String?, email: String?, organization: String?
) throws -> (field: String, value: String) {
    var provided: [(String, String)] = []
    for (k, v) in [("name", name), ("phone", phone), ("email", email), ("organization", organization)] {
        if let v {
            let t = v.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { provided.append((k, t)) }
        }
    }
    if provided.isEmpty {
        throw AppleError.validation("Exactly one of name, phone, email, organization must be set.")
    }
    if provided.count > 1 {
        let fields = provided.map { $0.0 }.sorted()
        throw AppleError.validation("Exactly one search field allowed; got \(fields).")
    }
    return provided[0]
}
