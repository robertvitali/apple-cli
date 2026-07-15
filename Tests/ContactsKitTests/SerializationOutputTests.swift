import Testing
import Foundation
import Contacts
@testable import ContactsKit
import AppleKit

// Serialization + output-shape parity. Building/serializing CN objects and parsing
// vCards needs the framework LINKED but no CNContactStore access, so these run in CI.

/// Encode a payload through the real envelope and return the inner `data` object.
private func dataObject<T: Encodable>(_ v: T) throws -> [String: Any] {
    let bytes = try Output.encodeSuccess(tool: "contacts", data: v)
    let root = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    return try #require(root["data"] as? [String: Any])
}

@Suite("Contact serialization (from a built CNContact)")
struct ContactSerializationTests {
    private func sampleFields() -> ContactFields {
        var f = ContactFields()
        f.given_name = "Ada"; f.family_name = "Lovelace"; f.organization = "Analytical"
        f.phones = [ScalarInput(label: "mobile", value: "+1-555-0100")]
        f.emails = [ScalarInput(label: "work", value: "ada@example.com")]
        return f
    }

    @Test("labeled values carry label_raw (Apple token) + localized label + value") func labeled() {
        let c = buildMutableContact(from: sampleFields())
        let out = serializeContact(c, includeNiche: false)
        #expect(out.given_name == "Ada")
        #expect(out.family_name == "Lovelace")
        #expect(out.phones.count == 1)
        #expect(out.phones[0].label_raw == "_$!<Mobile>!$_")
        #expect(out.phones[0].label == "mobile")        // localizedStringForLabel round-trip
        #expect(out.phones[0].value == "+1-555-0100")
        #expect(out.emails[0].label_raw == "_$!<Work>!$_")
        #expect(out.emails[0].value == "ada@example.com")
    }

    @Test("birthday key ALWAYS present — null when unset") func birthdayNull() throws {
        let c = buildMutableContact(from: sampleFields())  // no birthday
        let obj = try dataObject(serializeContact(c, includeNiche: false))
        #expect(obj.keys.contains("birthday"))
        #expect(obj["birthday"] is NSNull)
    }

    @Test("birthday serializes present components, omits unset ones") func birthdayParts() {
        var f = sampleFields(); f.birthday = BirthdayInput(year: nil, month: 12, day: 10)
        let c = buildMutableContact(from: f)
        let out = serializeContact(c, includeNiche: false)
        #expect(out.birthday != nil)
        #expect(out.birthday?.year == nil)
        #expect(out.birthday?.month == 12)
        #expect(out.birthday?.day == 10)
    }

    @Test("niche families absent by default, present (as keys) when requested") func niche() throws {
        let c = buildMutableContact(from: sampleFields())
        let plain = try dataObject(serializeContact(c, includeNiche: false))
        for k in ["dates", "social_profiles", "relations", "instant_messages"] {
            #expect(!plain.keys.contains(k), "\(k) must be absent without --niche")
        }
        let rich = try dataObject(serializeContact(c, includeNiche: true))
        for k in ["dates", "social_profiles", "relations", "instant_messages"] {
            #expect(rich.keys.contains(k), "\(k) must be present with --niche")
        }
    }
}

@Suite("birthdayParts filtering (NSNotFound guard)")
struct BirthdayPartsTests {
    @Test("nil components → nil (MCP birthday: null)") func allNil() {
        #expect(birthdayParts(nil) == nil)
        #expect(birthdayParts(DateComponents()) == nil)
    }
    @Test("valid components pass; out-of-range (>=10000) filtered") func range() {
        let p = birthdayParts(DateComponents(year: 1990, month: 5, day: 17))
        #expect(p?.year == 1990 && p?.month == 5 && p?.day == 17)
        let filtered = birthdayParts(DateComponents(year: 20000, month: 6, day: 1))
        #expect(filtered?.year == nil)   // 20000 dropped
        #expect(filtered?.month == 6)
    }
}

@Suite("update None/\"\"/value semantics")
struct UpdateSemanticsTests {
    @Test("nil skips, \"\" clears, value sets; lists REST-PUT replace") func semantics() {
        var base = ContactFields()
        base.given_name = "Ada"; base.family_name = "Old"
        base.phones = [ScalarInput(label: "mobile", value: "+1")]
        let c = buildMutableContact(from: base)
        #expect(c.givenName == "Ada")
        #expect(c.phoneNumbers.count == 1)

        var upd = ContactFields()
        upd.given_name = ""        // clear
        upd.family_name = "New"    // set
        // phones nil ⇒ untouched; middle_name nil ⇒ untouched
        applyUpdateFields(to: c, from: upd)
        #expect(c.givenName == "")           // cleared
        #expect(c.familyName == "New")       // set
        #expect(c.phoneNumbers.count == 1)   // untouched (skip)

        var clearList = ContactFields()
        clearList.phones = []      // REST-PUT clear
        applyUpdateFields(to: c, from: clearList)
        #expect(c.phoneNumbers.isEmpty)      // cleared
    }
}

@Suite("vCard parse (3.0 and 4.0 input) + export")
struct VCardTests {
    @Test("parse vCard 3.0") func parse30() throws {
        let vcard = ["BEGIN:VCARD", "VERSION:3.0", "N:Lovelace;Ada;;;", "FN:Ada Lovelace",
                     "TEL;type=CELL:+1-555-0100", "END:VCARD", ""].joined(separator: "\r\n")
        let parsed = try CNContactVCardSerialization.contacts(with: Data(vcard.utf8))
        #expect(parsed.count == 1)
        let out = serializeContact(parsed[0], includeNiche: false)
        #expect(out.given_name == "Ada")
        #expect(out.family_name == "Lovelace")
        #expect(out.phones.first?.value == "+1-555-0100")
    }
    @Test("parse vCard 4.0") func parse40() throws {
        let vcard = ["BEGIN:VCARD", "VERSION:4.0", "N:Turing;Alan;;;", "FN:Alan Turing",
                     "EMAIL:alan@example.com", "END:VCARD", ""].joined(separator: "\r\n")
        let parsed = try CNContactVCardSerialization.contacts(with: Data(vcard.utf8))
        #expect(parsed.count == 1)
        let out = serializeContact(parsed[0], includeNiche: false)
        #expect(out.given_name == "Alan")
        #expect(out.family_name == "Turing")
        #expect(out.emails.first?.value == "alan@example.com")
    }
    @Test("export emits vCard 3.0") func export30() throws {
        var f = ContactFields(); f.given_name = "Grace"; f.family_name = "Hopper"
        let c = buildMutableContact(from: f)
        let data = try CNContactVCardSerialization.data(with: [c])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("BEGIN:VCARD"))
        #expect(text.contains("VERSION:3.0"))   // Apple serializes 3.0
    }
}

@Suite("Output-shape parity (nullable / id-echo fields ALWAYS present)")
struct OutputShapeTests {
    @Test("create id-echo fields null when absent") func createEcho() throws {
        let obj = try dataObject(CreateContactResult(identifier: "X", group_id: nil, container_id: nil))
        #expect(obj["identifier"] as? String == "X")
        #expect(obj.keys.contains("group_id") && obj["group_id"] is NSNull)
        #expect(obj.keys.contains("container_id") && obj["container_id"] is NSNull)
    }
    @Test("read_photo no-photo emits image_data:null, format:null, size_bytes:0") func photoNull() throws {
        let obj = try dataObject(ReadPhotoResult(
            identifier: "X", image_data: nil, format: nil, size_bytes: 0, written_to: nil))
        #expect(obj["image_data"] is NSNull)
        #expect(obj["format"] is NSNull)
        #expect(obj["size_bytes"] as? Int == 0)
        #expect(!obj.keys.contains("written_to"))  // extra: omitted when unused
    }
    @Test("auth remediation present only when not authorized") func authRemediation() throws {
        let ok = try dataObject(AuthResult(status: "authorized", remediation: nil))
        #expect(ok["status"] as? String == "authorized")
        #expect(!ok.keys.contains("remediation"))
        let denied = try dataObject(AuthResult(status: "denied", remediation: "grant it"))
        #expect(denied["remediation"] as? String == "grant it")
    }
    @Test("import_vcard group_id null when absent") func importEcho() throws {
        let obj = try dataObject(ImportVCardResult(identifiers: ["a"], count: 1, group_id: nil))
        #expect(obj.keys.contains("group_id") && obj["group_id"] is NSNull)
    }
}
