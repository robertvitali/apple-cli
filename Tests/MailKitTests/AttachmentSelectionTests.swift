import Testing
import Foundation
@testable import MailKit
import AppleKit

// Logic-tier coverage for `mail attachments save`'s selection/de-collision logic — moved to Swift
// (from AppleScript name-matching) specifically so a message with duplicate attachment names can
// be unit-tested without a live Mac + TCC: positional index resolution, basename de-collision, and
// the --dir/--out/--name/--indices mutual-exclusion gates. See CommandHelpers.swift for the
// functions under test and WriteManageCommands.swift's AttachmentsSave for how they compose.

@Suite("Attachment save — selection + de-collision")
struct AttachmentSelectionTests {

    // "image.png" deliberately duplicated at positions 0 and 2 — the case the prior name-matching
    // AppleScript got wrong (an --indices 0 request would ALSO save position 2, since both share
    // a name).
    static let names = ["image.png", "notes.txt", "image.png", "report.pdf"]

    // MARK: resolveAttachmentIndices

    @Test("default (no --name, no --indices) selects every position, ascending")
    func defaultSelectsAll() {
        #expect(resolveAttachmentIndices(names: Self.names, name: nil, indices: nil) == [0, 1, 2, 3])
    }

    @Test("--indices resolves to exactly the requested positions, ascending regardless of input order")
    func indicesResolvesAscending() {
        // Position 0 ONLY — proves the fix: the duplicate at position 2 is NOT also selected.
        #expect(resolveAttachmentIndices(names: Self.names, name: nil, indices: "0") == [0])
        #expect(resolveAttachmentIndices(names: Self.names, name: nil, indices: "3,0") == [0, 3])
    }

    @Test("--indices out-of-range positions are dropped, not errored")
    func indicesClampsOutOfRange() {
        #expect(resolveAttachmentIndices(names: Self.names, name: nil, indices: "1,99") == [1])
    }

    @Test("--name resolves to EVERY position matching that exact name — the duplicate case")
    func nameResolvesAllDuplicates() {
        #expect(resolveAttachmentIndices(names: Self.names, name: "image.png", indices: nil) == [0, 2])
    }

    @Test("--name with no match resolves to an empty selection")
    func nameNoMatch() {
        #expect(resolveAttachmentIndices(names: Self.names, name: "missing.zip", indices: nil) == [])
    }

    // MARK: requireNameXorIndices

    @Test("--name and --indices together is a validation error")
    func nameAndIndicesRejected() {
        let err = #expect(throws: AppleError.self) { try requireNameXorIndices(name: "x", indices: "0") }
        #expect(err?.exitCode == 64)
    }

    @Test("--name alone, --indices alone, or neither is fine")
    func nameXorIndicesAllowedCases() {
        #expect(throws: Never.self) { try requireNameXorIndices(name: "x", indices: nil) }
        #expect(throws: Never.self) { try requireNameXorIndices(name: nil, indices: "0") }
        #expect(throws: Never.self) { try requireNameXorIndices(name: nil, indices: nil) }
    }

    // MARK: requireDirXorOut

    @Test("neither --dir nor --out is a validation error")
    func dirOrOutRequired() {
        #expect(throws: AppleError.self) { try requireDirXorOut(dir: nil, out: nil) }
    }

    @Test("both --dir and --out is a validation error")
    func dirAndOutRejected() {
        let err = #expect(throws: AppleError.self) { try requireDirXorOut(dir: "/tmp", out: "/tmp/x") }
        #expect(err?.exitCode == 64)
    }

    @Test("exactly one of --dir/--out is fine")
    func dirXorOutAllowedCases() {
        #expect(throws: Never.self) { try requireDirXorOut(dir: "/tmp", out: nil) }
        #expect(throws: Never.self) { try requireDirXorOut(dir: nil, out: "/tmp/x") }
    }

    // MARK: requireSingleForOut

    @Test("--out with a multi-attachment selection is a validation error")
    func outRequiresExactlyOne() {
        let err = #expect(throws: AppleError.self) { try requireSingleForOut(out: "/tmp/x", selectedCount: 2) }
        #expect(err?.exitCode == 64)
    }

    @Test("--out with zero matched attachments is a validation error (not a silent no-op)")
    func outRejectsZeroMatches() {
        #expect(throws: AppleError.self) { try requireSingleForOut(out: "/tmp/x", selectedCount: 0) }
    }

    @Test("--out with exactly one selected attachment is fine")
    func outAllowsExactlyOne() {
        #expect(throws: Never.self) { try requireSingleForOut(out: "/tmp/x", selectedCount: 1) }
    }

    @Test("the exactly-one check is skipped entirely when --out wasn't given")
    func outCheckSkippedWhenNotGiven() {
        #expect(throws: Never.self) { try requireSingleForOut(out: nil, selectedCount: 5) }
    }

    // MARK: safeAttachmentBasename

    @Test("a plain attachment name passes through unchanged")
    func basenamePlain() {
        #expect(safeAttachmentBasename("photo.jpg", fallbackIndex: 0) == "photo.jpg")
    }

    @Test("a path-traversal name collapses to its basename (zip-slip class)")
    func basenameStripsTraversal() {
        #expect(safeAttachmentBasename("../../etc/passwd", fallbackIndex: 0) == "passwd")
        #expect(safeAttachmentBasename("a/b/c.txt", fallbackIndex: 0) == "c.txt")
    }

    @Test("a degenerate name (empty / '.' / '..') falls back to a safe placeholder")
    func basenameFallsBackOnDegenerate() {
        #expect(safeAttachmentBasename("", fallbackIndex: 3) == "attachment-3")
        #expect(safeAttachmentBasename(".", fallbackIndex: 3) == "attachment-3")
        #expect(safeAttachmentBasename("..", fallbackIndex: 3) == "attachment-3")
    }

    // MARK: deCollidedBasenames

    @Test("unique basenames pass through unchanged")
    func deCollideNoOp() {
        #expect(deCollidedBasenames(["a.png", "b.txt"]) == ["a.png", "b.txt"])
    }

    @Test("duplicate basenames get -1, -2, … spliced before the extension")
    func deCollideSuffixesDuplicates() {
        #expect(deCollidedBasenames(["image.png", "image.png", "image.png"])
                == ["image.png", "image-1.png", "image-2.png"])
    }

    @Test("duplicate EXTENSIONLESS basenames get -1, -2, … appended directly")
    func deCollideSuffixesExtensionless() {
        #expect(deCollidedBasenames(["README", "README"]) == ["README", "README-1"])
    }

    @Test("de-collision composed with the master fixture: positions 0 and 2 never collide on disk")
    func deCollideEndToEndWithFixture() {
        let wanted = resolveAttachmentIndices(names: Self.names, name: "image.png", indices: nil)
        let basenames = deCollidedBasenames(wanted.map { safeAttachmentBasename(Self.names[$0], fallbackIndex: $0) })
        #expect(basenames == ["image.png", "image-1.png"])
    }

    @Test("a literal name that coincidentally matches the de-collision target still can't collide")
    func deCollideSkipsOverAnAlreadyUsedLiteral() {
        // Second attachment is a GENUINELY DISTINCT file that happens to already be named
        // "image-1.png" — the naive "count occurrences of the ORIGINAL name" approach would
        // still assign the second "image.png" to "image-1.png", silently overwriting it. Global
        // uniqueness (checked against every name already emitted) must skip to "image-2.png".
        let out = deCollidedBasenames(["image.png", "image-1.png", "image.png"])
        #expect(out == ["image.png", "image-1.png", "image-2.png"])
        #expect(Set(out).count == out.count)   // the actual invariant that matters: no duplicates
    }
}
