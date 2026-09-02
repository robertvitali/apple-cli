import Testing
import Foundation
@testable import ContactsKit
import AppleKit

// Validators ported from apple-contacts-mcp server.py (_validate_*), plus the
// search-selection and update None/""/value logic. Pure — no Contacts TCC.

/// Assert `body` throws an `AppleError` whose type is `validation_error`.
private func expectValidation(_ body: () throws -> Void, _ msg: Comment? = nil,
                              sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        try body()
        Issue.record(msg ?? "expected validation_error but nothing was thrown", sourceLocation: sourceLocation)
    } catch let e as AppleError {
        #expect(e.type == "validation_error", msg, sourceLocation: sourceLocation)
    } catch {
        Issue.record("expected AppleError, got \(error)", sourceLocation: sourceLocation)
    }
}

@Suite("create_contact validation")
struct CreateValidationTests {
    @Test("requires ≥1 of given/family/organization") func requiresName() {
        expectValidation { try validateCreateInput(ContactFields()) }
        var f = ContactFields(); f.given_name = "   "  // whitespace-only ⇒ still empty
        expectValidation { try validateCreateInput(f) }
    }
    @Test("accepts a single name field") func acceptsName() throws {
        var f = ContactFields(); f.organization = "Acme"
        try validateCreateInput(f)  // must not throw
    }
    @Test("labeled-value field rules") func labeledValues() {
        var f = ContactFields(); f.given_name = "A"
        f.phones = [ScalarInput(label: "mobile", value: "  ")]
        expectValidation { try validateCreateInput(f) }

        f.phones = nil; f.emails = [ScalarInput(label: nil, value: "no-at-sign")]
        expectValidation { try validateCreateInput(f) }

        f.emails = [ScalarInput(label: nil, value: "ok@example.com")]
        do { try validateCreateInput(f) } catch { Issue.record("valid email should pass: \(error)") }

        f.emails = nil; f.postal_addresses = [PostalInput()]  // all empty
        expectValidation { try validateCreateInput(f) }

        f.postal_addresses = nil; f.birthday = BirthdayInput(year: nil, month: 13, day: nil)
        expectValidation { try validateCreateInput(f) }

        f.birthday = BirthdayInput(year: 1990, month: 5, day: 17)
        do { try validateCreateInput(f) } catch { Issue.record("valid birthday should pass: \(error)") }
    }
    @Test("niche family rules") func niche() {
        var f = ContactFields(); f.given_name = "A"
        f.dates = [DateInput(label: "anniv", year: nil, month: nil, day: nil)]  // no component
        expectValidation { try validateCreateInput(f) }
        f.dates = nil; f.social_profiles = [SocialInput()]  // no username/url
        expectValidation { try validateCreateInput(f) }
        f.social_profiles = nil; f.relations = [RelationInput(label: "spouse", name: "")]
        expectValidation { try validateCreateInput(f) }
        f.relations = nil; f.instant_messages = [IMInput(label: nil, service: "x", username: "")]
        expectValidation { try validateCreateInput(f) }
    }
}

@Suite("update_contact validation")
struct UpdateValidationTests {
    @Test("empty identifier rejected") func emptyId() {
        var f = ContactFields(); f.given_name = "A"
        expectValidation { try validateUpdateInput(identifier: "  ", f) }
    }
    @Test("requires ≥1 supplied field") func requiresField() {
        expectValidation { try validateUpdateInput(identifier: "ID", ContactFields()) }
    }
    @Test("clear via empty string counts as a supplied field") func clearCounts() throws {
        var f = ContactFields(); f.given_name = ""   // present ⇒ clear, counts as touched
        try validateUpdateInput(identifier: "ID", f)  // must not throw
    }
    @Test("clear via empty list counts as a supplied field") func clearListCounts() throws {
        var f = ContactFields(); f.phones = []
        try validateUpdateInput(identifier: "ID", f)
    }
}

@Suite("search selection (exactly one field)")
struct SearchSelectionTests {
    @Test("none set → validation") func none() {
        expectValidation { _ = try resolveSearchSelection(name: nil, phone: nil, email: nil, organization: nil) }
        expectValidation { _ = try resolveSearchSelection(name: "  ", phone: nil, email: nil, organization: nil) }
    }
    @Test("multiple set → validation") func multiple() {
        expectValidation {
            _ = try resolveSearchSelection(name: "a", phone: "b", email: nil, organization: nil)
        }
    }
    @Test("exactly one → (field, trimmed value)") func one() throws {
        let (f, v) = try resolveSearchSelection(name: "  Jane  ", phone: nil, email: nil, organization: nil)
        #expect(f == "name")
        #expect(v == "Jane")
        let (f2, v2) = try resolveSearchSelection(name: nil, phone: nil, email: nil, organization: "Acme")
        #expect(f2 == "organization")
        #expect(v2 == "Acme")
    }
}
