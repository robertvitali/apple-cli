import Testing
import Foundation
import TestSupport
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
            [summary("a", "Alice"), summary("b", "Bob")],
            [summary("b", "Bob2"), summary("c", "Cy")],   // b duplicate (first wins)
            [summary("a", "Alice2"), summary("d", "Dee")],
        ]
        let out = unionSummariesByID(lists, cap: 200)
        #expect(out.map(\.id) == ["a", "b", "c", "d"])
        #expect(out.first?.given_name == "Alice")  // first-seen 'a' kept, not "Alice2"
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
        let vcard = ["BEGIN:VCARD", "VERSION:3.0", "N:Doe;Jane;;;", "FN:Jane Doe", "END:VCARD", ""]
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

@Suite("readBoundedFile under the shared tilde policy")
struct ReadBoundedFileTildeTests {
    private let scratch = ScratchDirs("contacts-bounded-file")

    /// Asserted as an exact refusal, not "does not read the other home", so the test fails on
    /// every macOS release, including those whose Foundation leaves the spelling cwd-relative.
    @Test("another user's ~user spelling, or a tilde with a combining mark, is refused before any read")
    func refusesForeignSpellings() {
        let other = NSUserName() == "root" ? "~daemon" : "~root"
        for raw in [other + "/.profile", "~no-such-user-apple-cli/x", "~\u{0301}/x"] {
            do {
                _ = try readBoundedFile(raw, "note")
                Issue.record("expected a refusal for \(raw)")
            } catch let error as AppleError {
                #expect(error.type == "validation_error")
                #expect(error.message == "cannot read the note file: " + TildeSpelling.refusalMessage(raw))
            } catch {
                Issue.record("expected AppleError, got \(error)")
            }
        }
    }

    /// The ceiling is measured on the path that is read. The trailing-slash spelling is the
    /// regression case: `attributesOfItem(atPath:)` finds nothing for `…/big.bin/` while the read
    /// resolves it, so measuring the raw spelling skipped the limit. `~/…` skipped it the same way,
    /// but a test cannot place a 25 MB file in the account's real home.
    @Test("the size ceiling is measured on the path that is read, including a trailing-slash spelling")
    func sizeCeilingIsMeasuredOnTheReadPath() throws {
        let dir = try scratch.directory()
        let small = dir.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: small)
        #expect(try readBoundedFile(small.path, "note") == Data("hello".utf8))

        let big = dir.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(maxContactsInputBytes + 1))
        try handle.close()
        for spelling in [big.path, big.path + "/"] {
            do {
                _ = try readBoundedFile(spelling, "image")
                Issue.record("expected the size ceiling to refuse \(spelling)")
            } catch let error as AppleError {
                #expect(error.type == "validation_error")
                #expect(error.message.hasPrefix("image file exceeds the 25 MB limit"))
            }
        }
    }
}
