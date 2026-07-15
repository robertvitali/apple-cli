import Testing
import Foundation
@testable import ContactsKit
import AppleKit

// Tests for the pure command-support helpers extracted for testability: the search
// --deep union/dedup, the page-size cap, vCard dry-run validation, and input-size bounds.

private func summary(_ id: String, _ given: String = "") -> ContactSummary {
    ContactSummary(id: id, given_name: given, family_name: "", organization: "")
}

@Suite("effectiveLimit (min(limit, cap))")
struct EffectiveLimitTests {
    @Test("clamps to cap, passes through below cap") func clamp() {
        #expect(effectiveLimit(500, cap: 200) == 200)
        #expect(effectiveLimit(50, cap: 200) == 50)
        #expect(effectiveLimit(200, cap: 200) == 200)
        #expect(effectiveLimit(1, cap: 200) == 1)
    }
}

@Suite("unionSummariesByID (search --deep)")
struct UnionDedupTests {
    @Test("dedupes by id, preserves first-seen order") func dedupOrder() {
        let lists = [
            [summary("a", "Ada"), summary("b", "Bob")],
            [summary("b", "Bob2"), summary("c", "Cy")],   // b duplicate (first wins)
            [summary("a", "Ada2"), summary("d", "Dee")],
        ]
        let out = unionSummariesByID(lists, cap: 200)
        #expect(out.map(\.id) == ["a", "b", "c", "d"])
        #expect(out.first?.given_name == "Ada")  // first-seen 'a' kept, not "Ada2"
    }
    @Test("honors the cap") func cap() {
        let lists = [(0..<300).map { summary("id\($0)") }]
        let out = unionSummariesByID(lists, cap: 200)
        #expect(out.count == 200)
    }
    @Test("empty input → empty") func empty() {
        #expect(unionSummariesByID([], cap: 200).isEmpty)
        #expect(unionSummariesByID([[]], cap: 200).isEmpty)
    }
}

@Suite("vCard dry-run validation (ContactsStore.validateVCard)")
struct VCardValidateTests {
    @Test("valid 3.0 → parsed count") func valid() throws {
        let vcard = ["BEGIN:VCARD", "VERSION:3.0", "N:Test;Ada;;;", "FN:Ada Test", "END:VCARD", ""]
            .joined(separator: "\r\n")
        #expect(try ContactsStore.validateVCard(text: vcard) == 1)
    }
    @Test("malformed / empty → validation_error") func malformed() {
        for bad in ["not a vcard at all", "", "   "] {
            do {
                _ = try ContactsStore.validateVCard(text: bad)
                Issue.record("expected validation_error for \(bad.debugDescription)")
            } catch let e as AppleError {
                #expect(e.type == "validation_error")
            } catch {
                Issue.record("expected AppleError, got \(error)")
            }
        }
    }
}

@Suite("Input-size bounds")
struct InputBoundsTests {
    @Test("small input passes") func small() throws {
        try checkBoundedInput("small payload", "--json")
    }
    @Test("over-limit input rejected") func overLimit() {
        let big = String(repeating: "x", count: maxContactsInputBytes + 1)
        do {
            try checkBoundedInput(big, "--json")
            Issue.record("expected validation_error for oversized input")
        } catch let e as AppleError {
            #expect(e.type == "validation_error")
        } catch {
            Issue.record("expected AppleError, got \(error)")
        }
    }
}
