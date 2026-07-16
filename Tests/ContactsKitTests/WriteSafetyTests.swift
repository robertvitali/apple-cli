import Testing
@testable import ContactsKit
import AppleKit

// Logic-tier tests for the CONTACTS write-safety decision logic (no Contacts.framework / TCC).
// The fetched-target GUARDS (`requireLabeledContactTarget` / `requireLabeledGroupTarget`) fetch
// from the live store, so their wiring is live-tier only — but the DECISION they make routes
// through the pure `ContactsLabel` selector, which is locked here. Both the create-side label
// gate and the fetched-target guards call `ContactsLabel`, so this also proves they can't drift.

@Suite("Contacts write-safety label selection")
struct ContactsWriteSafetyTests {
    let prefix = TestMode.sandboxPrefix // normalized "apple-cli-test" (never empty)

    @Test("primaryName picks the first non-empty of given → family → org")
    func primaryNameOrder() {
        #expect(ContactsLabel.primaryName(given: "apple-cli-test G", family: "F", organization: "O") == "apple-cli-test G")
        #expect(ContactsLabel.primaryName(given: "   ", family: "apple-cli-test F", organization: "O") == "apple-cli-test F")
        #expect(ContactsLabel.primaryName(given: "", family: "", organization: "apple-cli-test Org") == "apple-cli-test Org")
        #expect(ContactsLabel.primaryName(given: nil, family: nil, organization: nil) == "")
        #expect(ContactsLabel.primaryName(given: "  ", family: nil, organization: "") == "")
    }

    @Test("isLabeled is a strict prefix match that can't be vacated")
    func labeling() {
        #expect(ContactsLabel.isLabeled("apple-cli-test Mom", prefix: prefix) == true)
        #expect(ContactsLabel.isLabeled("Mom", prefix: prefix) == false)
        // Prefix, not substring: a near-miss must NOT pass.
        #expect(ContactsLabel.isLabeled("almost-apple-cli-test thing", prefix: prefix) == false)
        #expect(ContactsLabel.isLabeled("", prefix: prefix) == false)
        // The default prefix is never empty, so no real name is a labeled test item by accident.
        #expect(prefix.isEmpty == false)
    }

    @Test("create-side and fetched-target-guard selection agree (no drift)")
    func selectionConsistency() {
        // A contact labeled by ANY of the three name fields is recognized by the same selector
        // the create gate uses — so create can never label something the guard later rejects.
        for triple in [("apple-cli-test A", "B", "C"), ("", "apple-cli-test B", "C"), ("", "", "apple-cli-test C")] {
            let name = ContactsLabel.primaryName(given: triple.0, family: triple.1, organization: triple.2)
            #expect(ContactsLabel.isLabeled(name, prefix: prefix) == true)
        }
        // A fully-real contact is rejected regardless of which field holds the name.
        for triple in [("Mom", "", ""), ("", "Smith", ""), ("", "", "Acme Inc")] {
            let name = ContactsLabel.primaryName(given: triple.0, family: triple.1, organization: triple.2)
            #expect(ContactsLabel.isLabeled(name, prefix: prefix) == false)
        }
    }
}
