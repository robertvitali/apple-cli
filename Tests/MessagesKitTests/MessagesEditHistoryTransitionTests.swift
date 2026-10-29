import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesEditHistoryTransitionTests {
    private typealias Context = ChatDB.ExactNativeEditContext
    private func history(_ texts: [String]?, part: String = "0", timestamp: Int = 1) throws -> Context.Container<Context.HistoryGroup> {
        let fields: [String: Any]
        if let texts {
            fields = ["ec": [part: texts.map { ["d": timestamp, "t": NSArchiver.archivedData(withRootObject: NSAttributedString(string: $0))] as [String: Any] }]]
        } else { fields = [:] }
        let bytes = try PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0)
        var budget = NativeEditContextDecoder.Budget()
        return try NativeEditContextDecoder.decode(bytes, budget: &budget, requireExactHistoryText: true).edit_history
    }

    @Test func firstEditRequiresOriginalAndCurrentRevision() throws {
        #expect(MessagesEditHistoryTransition.matches(before: try history(nil), after: try history(["old", "new"]),
            originalPartIndex: 0, previousText: "old", replacementText: "new"))
        for revisions in [["new"], ["old"], ["other", "new"], ["old", "new", "new"]] {
            #expect(!MessagesEditHistoryTransition.matches(before: try history(nil), after: try history(revisions),
                originalPartIndex: 0, previousText: "old", replacementText: "new"))
        }
    }

    @Test func repeatEditRequiresOneAppendedRevisionAndUnchangedPrefix() throws {
        let before = try history(["original", "old"])
        #expect(MessagesEditHistoryTransition.matches(before: before, after: try history(["original", "old", "new"]),
            originalPartIndex: 0, previousText: "old", replacementText: "new"))
        for revisions in [["original", "new"], ["changed", "old", "new"], ["original", "old"], ["original", "old", "other", "new"]] {
            #expect(!MessagesEditHistoryTransition.matches(before: before, after: try history(revisions),
                originalPartIndex: 0, previousText: "old", replacementText: "new"))
        }
    }

    @Test func byteDistinctHistoryCannotMasqueradeAsUnchanged() throws {
        let composed = "\u{e9}", decomposed = "e\u{301}"
        #expect(composed == decomposed)
        #expect(!MessagesEditHistoryTransition.matches(before: try history([composed, "old"]),
            after: try history([decomposed, "old", "new"]), originalPartIndex: 0,
            previousText: "old", replacementText: "new"))
        #expect(!MessagesEditHistoryTransition.matches(before: try history(nil), after: try history(["old", composed]),
            originalPartIndex: 0, previousText: "old", replacementText: decomposed))
    }

    @Test func missingWrongPartAndSameContentAreNotEditProof() throws {
        #expect(!MessagesEditHistoryTransition.matches(before: try history(nil), after: try history(nil),
            originalPartIndex: 0, previousText: "old", replacementText: "new"))
        #expect(!MessagesEditHistoryTransition.matches(before: try history(nil), after: try history(["old", "new"], part: "1"),
            originalPartIndex: 0, previousText: "old", replacementText: "new"))
        #expect(!MessagesEditHistoryTransition.matches(before: try history(nil), after: try history(["old", "old"]),
            originalPartIndex: 0, previousText: "old", replacementText: "old"))
        #expect(!MessagesEditHistoryTransition.matches(before: try history(["original", "old"]),
            after: try history(["original", "old"], timestamp: 2), originalPartIndex: 0,
            previousText: "old", replacementText: "new"))
    }

    @Test func unrelatedPartHistoryMustRemainByteExact() throws {
        let original = try #require(history(["old"]).entries?.first)
        let revised = try #require(history(["old", "new"]).entries?.first)
        let other = try #require(history(["other"], part: "1").entries?.first)
        let changed = try #require(history(["changed"], part: "1").entries?.first)
        let before = Context.Container(status: "available", reason: nil, entries: [original, other])
        for groups in [[revised, changed], [revised], [revised, other, other]] {
            #expect(!MessagesEditHistoryTransition.matches(before: before,
                after: .init(status: "available", reason: nil, entries: groups),
                originalPartIndex: 0, previousText: "old", replacementText: "new"))
        }
        #expect(MessagesEditHistoryTransition.matches(before: before,
            after: .init(status: "available", reason: nil, entries: [other, revised]),
            originalPartIndex: 0, previousText: "old", replacementText: "new"))
    }

    @Test func incompleteAndNoncanonicalMetadataCannotProveTransition() throws {
        let after = try history(["old", "new"])
        for status in ["partial", "unavailable", "null", "wrong-type"] {
            #expect(!MessagesEditHistoryTransition.matches(
                before: .init(status: status, reason: nil, entries: nil), after: after,
                originalPartIndex: 0, previousText: "old", replacementText: "new"))
        }
        for part in ["00", "-1", "2147483648"] {
            #expect(!MessagesEditHistoryTransition.matches(before: try history(nil),
                after: try history(["old", "new"], part: part), originalPartIndex: 0,
                previousText: "old", replacementText: "new"))
        }
        #expect(!MessagesEditHistoryTransition.matches(before: try history([]), after: after,
            originalPartIndex: 0, previousText: "old", replacementText: "new"))
    }

}
