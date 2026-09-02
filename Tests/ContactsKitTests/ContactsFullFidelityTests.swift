import Foundation
import Testing
import Contacts
@testable import ContactsKit
import AppleKit

// Full-fidelity CN round trip: every labeled-value family through the CREATE builder, the
// serializer, and the UPDATE applier. The narrower suites cover names, phones and emails; the
// remaining families (postal addresses, niche dates, social profiles, relations, instant
// messages) are only reachable through `--json`, so they are exercised here as one record.
//
// Framework-linked but store-free: `CNMutableContact` needs no `CNContactStore`.
// No personal data — reserved placeholders only (AGENTS.md).

private func everyFamily() -> ContactFields {
    var f = ContactFields()
    f.given_name = "Jane"
    f.family_name = "Doe"
    f.organization = "Example Org"
    f.phones = [ScalarInput(label: "mobile", value: "+1-555-0120")]
    f.emails = [ScalarInput(label: "work", value: "jane@example.com")]
    f.urls = [ScalarInput(label: "homepage", value: "https://example.org")]
    f.postal_addresses = [PostalInput(
        label: "home", street: "1 Main St", sub_locality: "Downtown", city: "Exampleville",
        sub_administrative_area: "Example County", state: "CA", postal_code: "00000",
        country: "United States", iso_country_code: "US")]
    f.birthday = BirthdayInput(year: 1990, month: 5, day: 17)
    f.dates = [DateInput(label: "anniversary", year: 2015, month: 6, day: 1)]
    f.social_profiles = [SocialInput(label: "other", service: "Example",
                                     username: "jane", url: "https://example.org/jane",
                                     user_identifier: "12345")]
    f.relations = [RelationInput(label: "spouse", name: "Alice Roe")]
    f.instant_messages = [IMInput(label: "work", service: "Example", username: "jane")]
    return f
}

@Suite("Contact full-fidelity round trip (every labeled-value family)")
struct ContactsFullFidelityTests {
    @Test("the create builder populates every family, and the serializer reads them all back")
    func buildAndSerialize() throws {
        let fields = everyFamily()
        try validateCreateInput(fields)                     // the record is valid input
        let contact = buildMutableContact(from: fields)
        let out = serializeContact(contact, includeNiche: true)

        #expect(out.urls.first?.label_raw == "_$!<HomePage>!$_")
        #expect(out.urls.first?.value == "https://example.org")

        let postal = try #require(out.postal_addresses.first)
        #expect(postal.label_raw == "_$!<Home>!$_")
        #expect(postal.street == "1 Main St")
        #expect(postal.sub_locality == "Downtown")
        #expect(postal.city == "Exampleville")
        #expect(postal.sub_administrative_area == "Example County")
        #expect(postal.state == "CA")
        #expect(postal.postal_code == "00000")
        #expect(postal.country == "United States")
        #expect(postal.iso_country_code == "US")

        #expect(out.birthday?.year == 1990)

        let date = try #require(out.dates?.first)
        #expect(date.label_raw == "anniversary")            // custom label passes through
        #expect(date.year == 2015)
        #expect(date.month == 6)
        #expect(date.day == 1)

        let social = try #require(out.social_profiles?.first)
        #expect(social.service == "Example")
        #expect(social.username == "jane")
        #expect(social.url == "https://example.org/jane")
        #expect(social.user_identifier == "12345")

        #expect(out.relations?.first?.name == "Alice Roe")
        #expect(out.instant_messages?.first?.service == "Example")
        #expect(out.instant_messages?.first?.username == "jane")
    }

    @Test("the update applier REST-PUT replaces every family it is given")
    func applyReplacesEveryFamily() throws {
        let contact = buildMutableContact(from: everyFamily())

        var replacement = ContactFields()
        replacement.urls = [ScalarInput(label: "work", value: "https://example.com")]
        replacement.postal_addresses = [PostalInput(label: "work", street: "1 Main St")]
        replacement.birthday = BirthdayInput(year: nil, month: 12, day: 25)
        replacement.dates = [DateInput(label: "other", year: nil, month: 3, day: 4)]
        replacement.social_profiles = [SocialInput(label: "home", service: "Example",
                                                   username: "alice", url: nil, user_identifier: nil)]
        replacement.relations = [RelationInput(label: "friend", name: "Bob Roe")]
        replacement.instant_messages = [IMInput(label: "home", service: "Example", username: "bob")]
        applyUpdateFields(to: contact, from: replacement)

        let out = serializeContact(contact, includeNiche: true)
        #expect(out.urls.map(\.value) == ["https://example.com"])
        #expect(out.postal_addresses.map(\.street) == ["1 Main St"])
        // Empty postal components round-trip as "" rather than dropping the field.
        #expect(out.postal_addresses.first?.city == "")
        #expect(out.birthday?.year == nil)
        #expect(out.birthday?.month == 12)
        #expect(out.dates?.first?.year == nil)              // year-less date component survives
        #expect(out.dates?.first?.month == 3)
        // Empty/absent social components are stored as nil and serialize as "".
        #expect(out.social_profiles?.first?.url == "")
        #expect(out.social_profiles?.first?.user_identifier == "")
        #expect(out.relations?.map(\.name) == ["Bob Roe"])
        #expect(out.instant_messages?.map(\.username) == ["bob"])
        // Untouched families are left exactly as they were.
        #expect(out.phones.map(\.value) == ["+1-555-0120"])
    }

    @Test("a PRESENT birthday encodes as an object; the key is null only when it is empty")
    func birthdayEncoding() throws {
        func birthday(of fields: ContactFields) throws -> Any? {
            let bytes = try Output.encodeSuccess(
                tool: "contacts", data: serializeContact(buildMutableContact(from: fields), includeNiche: false))
            let root = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            return try #require(root["data"] as? [String: Any])["birthday"]
        }
        let present = try #require(try birthday(of: everyFamily()) as? [String: Any])
        #expect(present["year"] as? Int == 1990)
        #expect(present["month"] as? Int == 5)
        #expect(present["day"] as? Int == 17)

        var noBirthday = everyFamily()
        noBirthday.birthday = nil
        #expect(try birthday(of: noBirthday) is NSNull)
    }

    @Test("a labeled value with NO label serializes an empty label pair")
    func unlabeledValues() {
        let contact = CNMutableContact()
        contact.givenName = "Jane"
        contact.phoneNumbers = [CNLabeledValue(label: nil, value: CNPhoneNumber(stringValue: "+1-555-0121"))]
        contact.urlAddresses = [CNLabeledValue(label: nil, value: "https://example.org" as NSString)]
        let out = serializeContact(contact, includeNiche: false)
        #expect(out.phones.first?.label_raw == "")
        #expect(out.phones.first?.label == "")
        #expect(out.urls.first?.label_raw == "")
    }

    @Test("builders skip empty scalars and empty lists (create truthy semantics)")
    func createSkipsEmpties() {
        var f = ContactFields()
        f.given_name = ""            // empty ⇒ skipped on CREATE
        f.family_name = "Doe"
        f.middle_name = ""
        f.organization = ""
        f.phones = []                // empty list ⇒ skipped on CREATE
        f.postal_addresses = []
        f.dates = []
        f.social_profiles = []
        f.relations = []
        f.instant_messages = []
        f.birthday = BirthdayInput() // all-nil ⇒ skipped
        let c = buildMutableContact(from: f)
        #expect(c.givenName == "")
        #expect(c.familyName == "Doe")
        #expect(c.phoneNumbers.isEmpty)
        #expect(c.birthday == nil)
    }

    @Test("an all-family record survives a vCard export/parse round trip")
    func vcardRoundTrip() throws {
        let contact = buildMutableContact(from: everyFamily())
        let data = try CNContactVCardSerialization.data(with: [contact])
        let parsed = try CNContactVCardSerialization.contacts(with: data)
        let out = serializeContact(try #require(parsed.first), includeNiche: false)
        #expect(out.given_name == "Jane")
        #expect(out.family_name == "Doe")
        #expect(out.postal_addresses.first?.city == "Exampleville")
        #expect(out.emails.first?.value == "jane@example.com")
    }
}
