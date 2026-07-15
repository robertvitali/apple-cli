import Foundation
import Contacts

// CNContact ↔ model translation, ported 1:1 from apple-contacts-mcp @ 1cd8789
// (v0.3.0) contacts_connector.py serializers/builders. Building/serializing
// CN*Contact objects needs the framework LINKED but no CNContactStore access,
// so these are unit-testable in CI without a Contacts TCC grant.

// MARK: - Label pair (mirror _serialize_labeled_values label handling)

/// `(label_raw, label)` — raw token (or "") plus the localized human string (or "").
func labelPair(_ raw: String?) -> (labelRaw: String, label: String) {
    guard let raw else { return ("", "") }
    return (raw, CNLabeledValue<NSString>.localizedString(forLabel: raw))
}

// MARK: - Date components (mirror _serialize_birthday / _serialize_date_components_value)

/// NSNotFound-safe component read: keep only 0 < n < 10000 (Apple uses a huge
/// sentinel for unset components and allows year-less dates).
private func safeComponent(_ v: Int?) -> Int? {
    guard let v, v > 0, v < 10_000 else { return nil }
    return v
}

/// Birthday → `DateParts?`; nil when no component survives (MCP `birthday: null`).
func birthdayParts(_ dc: DateComponents?) -> DateParts? {
    guard let dc else { return nil }
    let p = DateParts(year: safeComponent(dc.year), month: safeComponent(dc.month), day: safeComponent(dc.day))
    return p.isEmpty ? nil : p
}

// MARK: - Contact serialization

/// 4-field summary (list_contacts / search_contacts / group members). Only touches
/// id/given/family/org — safe with the minimal fetch key set.
func serializeSummary(_ c: CNContact) -> ContactSummary {
    ContactSummary(
        id: c.identifier,
        given_name: c.givenName,
        family_name: c.familyName,
        organization: c.organizationName
    )
}

/// Full P1 record (+ P3 niche families when `includeNiche`). The contact MUST have
/// been fetched with the matching key set (accessing an unfetched CN key traps).
func serializeContact(_ c: CNContact, includeNiche: Bool) -> Contact {
    let phones = c.phoneNumbers.map { lv -> LabeledScalar in
        let (raw, human) = labelPair(lv.label)
        return LabeledScalar(label_raw: raw, label: human, value: lv.value.stringValue)
    }
    let emails = c.emailAddresses.map { lv -> LabeledScalar in
        let (raw, human) = labelPair(lv.label)
        return LabeledScalar(label_raw: raw, label: human, value: lv.value as String)
    }
    let urls = c.urlAddresses.map { lv -> LabeledScalar in
        let (raw, human) = labelPair(lv.label)
        return LabeledScalar(label_raw: raw, label: human, value: lv.value as String)
    }
    let postal = c.postalAddresses.map { lv -> LabeledPostal in
        let (raw, human) = labelPair(lv.label)
        let a = lv.value
        return LabeledPostal(
            label_raw: raw, label: human,
            street: a.street, sub_locality: a.subLocality, city: a.city,
            sub_administrative_area: a.subAdministrativeArea, state: a.state,
            postal_code: a.postalCode, country: a.country, iso_country_code: a.isoCountryCode)
    }

    var dates: [LabeledDate]?
    var social: [LabeledSocialProfile]?
    var relations: [LabeledRelation]?
    var ims: [LabeledIM]?
    if includeNiche {
        dates = c.dates.map { lv -> LabeledDate in
            let (raw, human) = labelPair(lv.label)
            let comps = lv.value as DateComponents
            return LabeledDate(label_raw: raw, label: human,
                               year: safeComponent(comps.year),
                               month: safeComponent(comps.month),
                               day: safeComponent(comps.day))
        }
        social = c.socialProfiles.map { lv -> LabeledSocialProfile in
            let (raw, human) = labelPair(lv.label)
            let p = lv.value
            return LabeledSocialProfile(label_raw: raw, label: human,
                                        service: p.service, username: p.username,
                                        url: p.urlString, user_identifier: p.userIdentifier)
        }
        relations = c.contactRelations.map { lv -> LabeledRelation in
            let (raw, human) = labelPair(lv.label)
            return LabeledRelation(label_raw: raw, label: human, name: lv.value.name)
        }
        ims = c.instantMessageAddresses.map { lv -> LabeledIM in
            let (raw, human) = labelPair(lv.label)
            return LabeledIM(label_raw: raw, label: human,
                             service: lv.value.service, username: lv.value.username)
        }
    }

    return Contact(
        id: c.identifier,
        given_name: c.givenName, family_name: c.familyName, middle_name: c.middleName,
        name_prefix: c.namePrefix, name_suffix: c.nameSuffix, nickname: c.nickname,
        organization: c.organizationName, job_title: c.jobTitle, department: c.departmentName,
        phones: phones, emails: emails, urls: urls, postal_addresses: postal,
        birthday: birthdayParts(c.birthday),
        dates: dates, social_profiles: social, relations: relations, instant_messages: ims)
}

// MARK: - Builders (mirror _build_mutable_contact / _apply_update_fields)

private func emptyToNil(_ s: String?) -> String? {
    guard let s, !s.isEmpty else { return nil }
    return s
}

private func buildPostalAddress(_ a: PostalInput) -> CNPostalAddress {
    let addr = CNMutablePostalAddress()
    if let v = a.street, !v.isEmpty { addr.street = v }
    if let v = a.sub_locality, !v.isEmpty { addr.subLocality = v }
    if let v = a.city, !v.isEmpty { addr.city = v }
    if let v = a.sub_administrative_area, !v.isEmpty { addr.subAdministrativeArea = v }
    if let v = a.state, !v.isEmpty { addr.state = v }
    if let v = a.postal_code, !v.isEmpty { addr.postalCode = v }
    if let v = a.country, !v.isEmpty { addr.country = v }
    if let v = a.iso_country_code, !v.isEmpty { addr.isoCountryCode = v }
    return addr
}

private func dateComponents(year: Int?, month: Int?, day: Int?) -> DateComponents {
    var dc = DateComponents()
    if let y = year { dc.year = y }
    if let m = month { dc.month = m }
    if let d = day { dc.day = d }
    return dc
}

private func phoneValues(_ items: [ScalarInput]) -> [CNLabeledValue<CNPhoneNumber>] {
    items.map { CNLabeledValue(label: labelToAppleToken($0.label ?? ""),
                               value: CNPhoneNumber(stringValue: $0.value ?? "")) }
}
private func stringValues(_ items: [ScalarInput]) -> [CNLabeledValue<NSString>] {
    items.map { CNLabeledValue(label: labelToAppleToken($0.label ?? ""),
                               value: ($0.value ?? "") as NSString) }
}
private func postalValues(_ items: [PostalInput]) -> [CNLabeledValue<CNPostalAddress>] {
    items.map { CNLabeledValue(label: labelToAppleToken($0.label ?? ""), value: buildPostalAddress($0)) }
}
private func dateValues(_ items: [DateInput]) -> [CNLabeledValue<NSDateComponents>] {
    items.map {
        let dc = dateComponents(year: $0.year, month: $0.month, day: $0.day) as NSDateComponents
        return CNLabeledValue(label: labelToAppleToken($0.label ?? ""), value: dc)
    }
}
private func socialValues(_ items: [SocialInput]) -> [CNLabeledValue<CNSocialProfile>] {
    items.map {
        let p = CNSocialProfile(urlString: emptyToNil($0.url), username: emptyToNil($0.username),
                                userIdentifier: emptyToNil($0.user_identifier), service: emptyToNil($0.service))
        return CNLabeledValue(label: labelToAppleToken($0.label ?? ""), value: p)
    }
}
private func relationValues(_ items: [RelationInput]) -> [CNLabeledValue<CNContactRelation>] {
    items.map { CNLabeledValue(label: labelToAppleToken($0.label ?? ""),
                               value: CNContactRelation(name: $0.name ?? "")) }
}
private func imValues(_ items: [IMInput]) -> [CNLabeledValue<CNInstantMessageAddress>] {
    items.map { CNLabeledValue(label: labelToAppleToken($0.label ?? ""),
                               value: CNInstantMessageAddress(username: $0.username ?? "", service: $0.service ?? "")) }
}

/// CREATE builder — truthy semantics (nil OR empty ⇒ skip). Mirrors
/// `_build_mutable_contact` + `_apply_niche_fields_to_mutable`.
func buildMutableContact(from f: ContactFields) -> CNMutableContact {
    let c = CNMutableContact()
    if let v = f.given_name, !v.isEmpty { c.givenName = v }
    if let v = f.family_name, !v.isEmpty { c.familyName = v }
    if let v = f.middle_name, !v.isEmpty { c.middleName = v }
    if let v = f.name_prefix, !v.isEmpty { c.namePrefix = v }
    if let v = f.name_suffix, !v.isEmpty { c.nameSuffix = v }
    if let v = f.nickname, !v.isEmpty { c.nickname = v }
    if let v = f.organization, !v.isEmpty { c.organizationName = v }
    if let v = f.job_title, !v.isEmpty { c.jobTitle = v }
    if let v = f.department, !v.isEmpty { c.departmentName = v }
    if let xs = f.phones, !xs.isEmpty { c.phoneNumbers = phoneValues(xs) }
    if let xs = f.emails, !xs.isEmpty { c.emailAddresses = stringValues(xs) }
    if let xs = f.urls, !xs.isEmpty { c.urlAddresses = stringValues(xs) }
    if let xs = f.postal_addresses, !xs.isEmpty { c.postalAddresses = postalValues(xs) }
    if let b = f.birthday, !(b.year == nil && b.month == nil && b.day == nil) {
        c.birthday = dateComponents(year: b.year, month: b.month, day: b.day)
    }
    if let xs = f.dates, !xs.isEmpty { c.dates = dateValues(xs) }
    if let xs = f.social_profiles, !xs.isEmpty { c.socialProfiles = socialValues(xs) }
    if let xs = f.relations, !xs.isEmpty { c.contactRelations = relationValues(xs) }
    if let xs = f.instant_messages, !xs.isEmpty { c.instantMessageAddresses = imValues(xs) }
    return c
}

/// UPDATE applier — presence semantics (nil ⇒ skip; "" / [] ⇒ clear; value ⇒ set;
/// lists are REST-PUT full replacement). Mirrors `_apply_update_fields`.
func applyUpdateFields(to c: CNMutableContact, from f: ContactFields) {
    if let v = f.given_name { c.givenName = v }
    if let v = f.family_name { c.familyName = v }
    if let v = f.middle_name { c.middleName = v }
    if let v = f.name_prefix { c.namePrefix = v }
    if let v = f.name_suffix { c.nameSuffix = v }
    if let v = f.nickname { c.nickname = v }
    if let v = f.organization { c.organizationName = v }
    if let v = f.job_title { c.jobTitle = v }
    if let v = f.department { c.departmentName = v }
    if let xs = f.phones { c.phoneNumbers = phoneValues(xs) }
    if let xs = f.emails { c.emailAddresses = stringValues(xs) }
    if let xs = f.urls { c.urlAddresses = stringValues(xs) }
    if let xs = f.postal_addresses { c.postalAddresses = postalValues(xs) }
    if let b = f.birthday { c.birthday = dateComponents(year: b.year, month: b.month, day: b.day) }
    if let xs = f.dates { c.dates = dateValues(xs) }
    if let xs = f.social_profiles { c.socialProfiles = socialValues(xs) }
    if let xs = f.relations { c.contactRelations = relationValues(xs) }
    if let xs = f.instant_messages { c.instantMessageAddresses = imValues(xs) }
}
